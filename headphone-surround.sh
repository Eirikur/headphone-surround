#!/usr/bin/env bash
# headphone-surround.sh - virtual surround for headphones on PipeWire.
#
# Adds two output devices (pick either in the sound menu):
#
#   "Headphone Surround - Film"
#       7.1 virtual speakers rendered for headphones with a HeSuVi impulse
#       response captured from a commercial virtualizer (Dolby Headphone,
#       Dolby Atmos, DTS Headphone:X, ...). 5.1/7.1 film audio goes straight
#       to the virtual speakers. Stereo is QS-decoded to quad (default), or
#       spread by PipeWire's own upmixer ("film-stereo psd").
#
#   "Headphone Surround - Music"
#       Stereo is matrix-decoded to quad (Sansui QS with Vario-Matrix-style
#       steering, or Hafler/DynaQuad difference signal), then the four
#       channels are placed on virtual front (+-30 deg) and back speakers
#       with the same impulse response.
#
# The QS decoder is a small LADSPA plugin whose C source is inside this
# script; it is compiled with gcc during install.
#
# Why not EasyEffects' convolver: in EasyEffects 7.x it only filters
# left->left and right->right (no cross-ear paths), so it cannot place
# virtual speakers. EasyEffects is not needed for this.
#
# Tested on Linux Mint 22.3 (PipeWire 1.0.5, WirePlumber 0.4). Everything is
# per-user (files under your home directory) except apt packages.
#
# Usage: headphone-surround.sh help

set -euo pipefail

VERSION=3.0
MARKER="# managed-by: headphone-surround.sh"
FILM_SINK="effect_input.headphone_surround"
FILM_DESC="Headphone Surround - Film"
MUSIC_SINK="effect_input.headphone_surround_music"
MUSIC_DESC="Headphone Surround - Music"
DEFAULT_IR="atmos"
DEFAULT_MATRIX="qs"        # Music device: qs | hafler
DEFAULT_FILM_STEREO="qs"   # stereo on the Film device: qs | hafler | psd
DEFAULT_STEERING="0.5"     # 0 = basic QS matrix, 1 = strongest steering
DEFAULT_GAIN_DB="-6"       # convolution adds level; this keeps peaks below clipping

CFG="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/headphone-surround"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/headphone-surround"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/headphone-surround"
STATE="$STATE_DIR/state"
HRIR="$DATA/hrir"
PLUGIN="$DATA/lib/hs_qs.so"

FC_CONF="$CFG/filter-chain.conf.d/60-headphone-surround.conf"
UPMIX_CONFS=(
    "$CFG/pipewire-pulse.conf.d/60-headphone-surround-upmix.conf"   # PulseAudio apps (most)
    "$CFG/client.conf.d/60-headphone-surround-upmix.conf"           # native PipeWire apps
    "$CFG/client-rt.conf.d/60-headphone-surround-upmix.conf"
)

# HeSuVi 2.0.0.1 installer (pinned). 7-Zip unpacks it; nothing in it is run.
HESUVI_URL="https://sourceforge.net/projects/hesuvi/files/HeSuVi_2.0.0.1.exe/download"
HESUVI_SHA256="a31774714d8f7a87ae4fd5bdbaa4bfa294a808296bdcc9e9935da4b427a601ba"

# Presets from HeSuVi's own descriptions. All installed ones work with "select".
SUGGESTED="
atmos|Dolby Atmos for headphones (7.1)
dh++|Dolby Headphone DH-2 Cinema
dh+|Dolby Headphone DH-1 Studio
dht|Dolby Home Theater v4 headphone virtualizer
dtshx|DTS Headphone:X
gsx|Sennheiser GSX 7.1
sonic|Windows Sonic 7.1
sbx67|Creative SBX Pro Studio Surround 67
cmss_ent|Creative CMSS-3D Entertainment mode
ooyh1|Out Of Your Head (AIX studio)
waves|Waves NX
nahimic|Nahimic 3
"
# Not installed: speaker-only (dvs), "no upmix" sets (ssc), passthrough (none),
# 7-channel sets (razer, hear, "-" variants) that this filter cannot use.
SKIP_RE='^(dvs|ssc_|none)'

# --- helpers -----------------------------------------------------------------
info() { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

state_get() { [[ -f $STATE ]] && grep -m1 "^$1=" "$STATE" | cut -d= -f2- || true; }
state_set() {
    mkdir -p "$STATE_DIR"
    touch "$STATE"
    grep -v "^$1=" "$STATE" > "$STATE.tmp" || true
    printf '%s=%s\n' "$1" "$2" >> "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}

ours() { [[ -f $1 ]] && grep -qF "$MARKER" "$1"; }

# Print "<channels> <rate>" for a WAV file (reads the header only).
wav_info() {
    python3 -I - "$1" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    if f.read(4) != b"RIFF": print("0 0"); sys.exit()
    f.read(4)
    if f.read(4) != b"WAVE": print("0 0"); sys.exit()
    while True:
        hdr = f.read(8)
        if len(hdr) < 8: print("0 0"); sys.exit()
        cid, size = hdr[:4], struct.unpack("<I", hdr[4:])[0]
        if cid == b"fmt ":
            _, ch, rate = struct.unpack("<HHI", f.read(8))
            print(ch, rate); sys.exit()
        f.seek(size + (size & 1), 1)
PY
}

is_hrir() { [[ $(wav_info "$1") == "14 48000" ]]; }

db_to_lin() { python3 -I -c "import sys; print(round(10 ** (float(sys.argv[1]) / 20), 4))" "$1"; }

require_user_pipewire() {
    [[ $EUID -ne 0 ]] || die "run this as your normal user, not root (it asks for sudo when needed)."
    command -v pactl >/dev/null || die "pactl not found (package pulseaudio-utils)."
    pactl info 2>/dev/null | grep -q "on PipeWire" \
        || die "the sound server is not PipeWire. Linux Mint 22+ uses PipeWire by default."
    systemctl --user cat filter-chain.service >/dev/null 2>&1 \
        || die "filter-chain.service not found (it ships with pipewire-bin)."
}

pkg_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == "install ok installed" ]]; }

ensure_packages() {
    local need=() p
    for p in 7zip curl python3 gcc libc6-dev; do pkg_installed "$p" || need+=("$p"); done
    ((${#need[@]})) || return 0
    info "Installing packages: ${need[*]} (sudo)"
    sudo apt-get update -qq
    sudo apt-get install -y "${need[@]}"
    state_set PKGS_INSTALLED "$(state_get PKGS_INSTALLED) ${need[*]}"
}

fetch_hesuvi() {
    if compgen -G "$HRIR/*.wav" >/dev/null; then return; fi
    local exe="$CACHE/HeSuVi_2.0.0.1.exe"
    mkdir -p "$CACHE" "$HRIR"
    if [[ ! -f $exe ]]; then
        info "Downloading HeSuVi impulse responses (27 MB, SourceForge)"
        curl -fL --retry 3 --progress-bar -o "$exe.part" "$HESUVI_URL"
        local got; got=$(sha256sum "$exe.part" | cut -d' ' -f1)
        [[ $got == "$HESUVI_SHA256" ]] || { rm -f "$exe.part"; die "checksum mismatch for HeSuVi download (got $got). Not using it."; }
        mv "$exe.part" "$exe"
    fi
    local tmp; tmp=$(mktemp -d)
    7z e -y -bso0 -bsp0 -o"$tmp" "$exe" 'HeSuVi/hrir/*.wav' >/dev/null
    local f n count=0
    for f in "$tmp"/*.wav; do
        n=$(basename "$f" .wav)
        LC_ALL=C grep -qxE '[a-z0-9_+]+' <<< "$n" || continue
        [[ $n =~ $SKIP_RE ]] && continue
        is_hrir "$f" || continue
        mv "$f" "$HRIR/$n.wav"; count=$((count + 1))
    done
    rm -rf "$tmp"
    ((count)) || die "no usable HeSuVi files were extracted."
    info "Installed $count HeSuVi presets"
}

# QS / Hafler decoder: a small LADSPA plugin, compiled here from the source
# below and loaded by PipeWire's filter-chain. Rebuilt when the source changes.
plugin_source() {
    cat <<'CSRC'
/* hs_qs - QS / Hafler quad decoder for headphone-surround.sh (LADSPA plugin)
 *
 * Two plugins in one file:
 *   hs_qs_music  stereo in -> LF RF LB RB
 *   hs_qs_film   same, plus a "Detect" input. While Detect carries any signal
 *                (a real multichannel source), the stereo pair passes through
 *                untouched and the decoded backs are muted.
 *
 * QS decode (Sansui basic matrix, j = +90 deg):
 *   LF =  .924 LT + .383 RT        RF = .383 LT + .924 RT
 *   LB = -.924 jLT + .383 jRT      RB = .383 jLT - .924 jRT
 * The 90 deg pair comes from two IIR all-pass chains (Olli Niemitalo's
 * wideband phase-difference network), so there is almost no added latency.
 *
 * Steering (Vario-Matrix style, not Sansui's circuit): the dominant direction
 * is measured from left/right level ratio and in-phase vs anti-phase ratio.
 * Outputs nearest that direction are raised and the others lowered, keeping
 * the total power of the basic decode. Steering = 0 gives the basic matrix.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ---- minimal LADSPA 1.1 ABI (so ladspa-sdk is not needed) ---- */
typedef float LADSPA_Data;
typedef void *LADSPA_Handle;
typedef int LADSPA_PortDescriptor;
typedef int LADSPA_PortRangeHintDescriptor;
typedef struct { LADSPA_PortRangeHintDescriptor HintDescriptor; LADSPA_Data LowerBound, UpperBound; } LADSPA_PortRangeHint;
typedef struct LADSPA_Descriptor {
    unsigned long UniqueID; const char *Label; int Properties;
    const char *Name, *Maker, *Copyright;
    unsigned long PortCount;
    const LADSPA_PortDescriptor *PortDescriptors;
    const char *const *PortNames;
    const LADSPA_PortRangeHint *PortRangeHints;
    void *ImplementationData;
    LADSPA_Handle (*instantiate)(const struct LADSPA_Descriptor *, unsigned long);
    void (*connect_port)(LADSPA_Handle, unsigned long, LADSPA_Data *);
    void (*activate)(LADSPA_Handle);
    void (*run)(LADSPA_Handle, unsigned long);
    void (*run_adding)(LADSPA_Handle, unsigned long);
    void (*set_run_adding_gain)(LADSPA_Handle, LADSPA_Data);
    void (*deactivate)(LADSPA_Handle);
    void (*cleanup)(LADSPA_Handle);
} LADSPA_Descriptor;
#define P_IN_AUDIO   (1 | 8)
#define P_OUT_AUDIO  (2 | 8)
#define P_IN_CTRL    (1 | 4)
#define H_BOUNDS     (0x1 | 0x2)
#define H_DEF_0      0x200
#define H_DEF_MID    0x0C0
#define H_INTEGER    0x20
#define PROP_HARD_RT 0x4

enum { IN_L, IN_R, OUT_LF, OUT_RF, OUT_LB, OUT_RB, C_STEER, C_MODE, IN_DETECT, NPORTS };

/* ---- 90 degree phase-difference network ---- */
static const double COEF_A[4] = { 0.6923878, 0.9360654322959, 0.9882295226860, 0.9987488452737 };
static const double COEF_B[4] = { 0.4021921162426, 0.8561710882420, 0.9722909545651, 0.9952884791278 };

typedef struct { double x1[4], x2[4], y1[4], y2[4]; } Chain;

static inline double flush(double v) { return fabs(v) < 1e-20 ? 0.0 : v; }

static inline double chain_run(Chain *c, const double *a, double x) {
    for (int i = 0; i < 4; i++) {
        double a2 = a[i] * a[i];
        double y = a2 * (x + c->y2[i]) - c->x2[i];
        c->x2[i] = c->x1[i]; c->x1[i] = x;
        c->y2[i] = c->y1[i]; c->y1[i] = flush(y);
        x = y;
    }
    return x;
}

typedef struct {
    LADSPA_Data *port[NPORTS];
    double rate;
    Chain aL, bL, aR, bR;
    double dL, dR;                 /* one-sample delay on the A path */
    double eL, eR, eS, eD;         /* direction envelopes */
    double eP[4];                  /* basic-output power envelopes */
    double g[4];                   /* smoothed output gains */
    double kEnv, kGain, kFade;
    double fade;                   /* 0 = decode, 1 = pass-through */
    long hold, holdLen;
    int film;
} QS;

static const double DIR[4][2] = {  /* (left-right, front-back) of each corner */
    {  0.7071,  0.7071 }, { -0.7071,  0.7071 }, {  0.7071, -0.7071 }, { -0.7071, -0.7071 } };

static LADSPA_Handle instantiate(const LADSPA_Descriptor *d, unsigned long rate) {
    QS *q = calloc(1, sizeof(QS));
    if (!q) return NULL;
    q->rate = (double)rate;
    q->film = (d->PortCount == NPORTS);
    q->kEnv  = 1.0 - exp(-1.0 / (0.020 * rate));   /* 20 ms direction detector */
    q->kGain = 1.0 - exp(-1.0 / (0.005 * rate));   /*  5 ms gain smoothing */
    q->kFade = 1.0 / (0.300 * rate);               /* 300 ms crossfade */
    q->holdLen = (long)(10.0 * rate);              /* keep pass-through 10 s after surround stops */
    for (int i = 0; i < 4; i++) q->g[i] = 1.0;
    return q;
}

static void connect_port(LADSPA_Handle h, unsigned long p, LADSPA_Data *buf) {
    if (p < NPORTS) ((QS *)h)->port[p] = buf;
}

static void activate(LADSPA_Handle h) {
    QS *q = h;
    LADSPA_Data *ports[NPORTS];
    memcpy(ports, q->port, sizeof ports);
    double rate = q->rate, kEnv = q->kEnv, kGain = q->kGain, kFade = q->kFade;
    long holdLen = q->holdLen; int film = q->film;
    memset(q, 0, sizeof *q);
    memcpy(q->port, ports, sizeof ports);
    q->rate = rate; q->kEnv = kEnv; q->kGain = kGain; q->kFade = kFade;
    q->holdLen = holdLen; q->film = film;
    for (int i = 0; i < 4; i++) q->g[i] = 1.0;
}

static void run(LADSPA_Handle h, unsigned long n) {
    QS *q = h;
    const LADSPA_Data *inL = q->port[IN_L], *inR = q->port[IN_R];
    const LADSPA_Data *det = q->film ? q->port[IN_DETECT] : NULL;
    LADSPA_Data *o[4] = { q->port[OUT_LF], q->port[OUT_RF], q->port[OUT_LB], q->port[OUT_RB] };
    double steer = q->port[C_STEER] ? *q->port[C_STEER] : 0.0;
    int hafler = q->port[C_MODE] ? (*q->port[C_MODE] >= 0.5f) : 0;
    if (steer < 0) steer = 0;
    if (steer > 1) steer = 1;
    const double c = 0.924, s = 0.383, eps = 1e-12;

    for (unsigned long i = 0; i < n; i++) {
        double L = inL[i], R = inR[i];
        double out[4];

        if (hafler) {
            out[0] = L; out[1] = R; out[2] = 0.7 * (L - R); out[3] = 0.7 * (R - L);
        } else {
            /* 0 deg (A path, delayed one sample) and +90 deg (B path) */
            double L0 = q->dL, R0 = q->dR;
            q->dL = chain_run(&q->aL, COEF_A, L);
            q->dR = chain_run(&q->aR, COEF_A, R);
            double L9 = chain_run(&q->bL, COEF_B, L);
            double R9 = chain_run(&q->bR, COEF_B, R);

            double b[4] = { c * L0 + s * R0,  s * L0 + c * R0,
                           -c * L9 + s * R9,  s * L9 - c * R9 };

            /* direction detector */
            double k = q->kEnv, sum = L0 + R0, dif = L0 - R0;
            q->eL += k * (L0 * L0 - q->eL);
            q->eR += k * (R0 * R0 - q->eR);
            q->eS += k * (sum * sum - q->eS);
            q->eD += k * (dif * dif - q->eD);
            double vx = (q->eL - q->eR) / (q->eL + q->eR + eps);
            double vy = (q->eS - q->eD) / (q->eS + q->eD + eps);

            double want[4], pb = 0, pw = 0;
            for (int j = 0; j < 4; j++) {
                q->eP[j] += k * (b[j] * b[j] - q->eP[j]);
                double w = 1.0 + steer * (vx * DIR[j][0] + vy * DIR[j][1]);
                want[j] = w * w;
                pb += q->eP[j];
                pw += want[j] * want[j] * q->eP[j];
            }
            double norm = sqrt((pb + eps) / (pw + eps));
            for (int j = 0; j < 4; j++) {
                q->g[j] += q->kGain * (want[j] * norm - q->g[j]);
                out[j] = b[j] * q->g[j];
            }
            for (int j = 0; j < 4; j++) q->eP[j] = flush(q->eP[j]);
            q->eL = flush(q->eL); q->eR = flush(q->eR);
            q->eS = flush(q->eS); q->eD = flush(q->eD);
        }

        if (det) {  /* film: real surround present -> pass the pair through */
            if (fabsf(det[i]) > 1e-6f) q->hold = q->holdLen;
            else if (q->hold > 0) q->hold--;
            double target = q->hold > 0 ? 1.0 : 0.0;
            if (q->fade < target) q->fade = fmin(target, q->fade + 10 * q->kFade);  /* in quickly */
            else if (q->fade > target) q->fade = fmax(target, q->fade - q->kFade);
            double f = q->fade;
            out[0] = f * L + (1 - f) * out[0];
            out[1] = f * R + (1 - f) * out[1];
            out[2] *= (1 - f);
            out[3] *= (1 - f);
        }
        for (int j = 0; j < 4; j++) o[j][i] = (LADSPA_Data)out[j];
    }
}

static void cleanup(LADSPA_Handle h) { free(h); }

static const LADSPA_PortDescriptor PDESC[NPORTS] = {
    P_IN_AUDIO, P_IN_AUDIO, P_OUT_AUDIO, P_OUT_AUDIO, P_OUT_AUDIO, P_OUT_AUDIO,
    P_IN_CTRL, P_IN_CTRL, P_IN_AUDIO };
static const char *const PNAMES[NPORTS] = {
    "In L", "In R", "Out LF", "Out RF", "Out LB", "Out RB", "Steering", "Mode", "Detect" };
static const LADSPA_PortRangeHint PHINTS[NPORTS] = {
    {0,0,0}, {0,0,0}, {0,0,0}, {0,0,0}, {0,0,0}, {0,0,0},
    { H_BOUNDS | H_DEF_MID, 0, 1 },
    { H_BOUNDS | H_DEF_0 | H_INTEGER, 0, 1 },
    {0,0,0} };

static const LADSPA_Descriptor DESC[2] = {
    { 0x48535101, "hs_qs_music", PROP_HARD_RT, "QS/Hafler quad decoder", "headphone-surround.sh", "MIT",
      NPORTS - 1, PDESC, PNAMES, PHINTS, NULL,
      instantiate, connect_port, activate, run, NULL, NULL, NULL, cleanup },
    { 0x48535102, "hs_qs_film", PROP_HARD_RT, "QS/Hafler quad decoder, multichannel bypass", "headphone-surround.sh", "MIT",
      NPORTS, PDESC, PNAMES, PHINTS, NULL,
      instantiate, connect_port, activate, run, NULL, NULL, NULL, cleanup },
};

const LADSPA_Descriptor *ladspa_descriptor(unsigned long i) { return i < 2 ? &DESC[i] : NULL; }
CSRC
}

build_plugin() {
    local dir="$DATA/lib" src
    mkdir -p "$dir"
    src=$(plugin_source)
    if [[ -f $PLUGIN && -f $dir/hs_qs.c ]] && [[ $(cat "$dir/hs_qs.c") == "$src" ]]; then return; fi
    command -v gcc >/dev/null || die "gcc is needed to build the decoder. Run: $0 install"
    printf '%s\n' "$src" > "$dir/hs_qs.c"
    gcc -O2 -fPIC -shared -o "$PLUGIN.tmp" "$dir/hs_qs.c" -lm || die "building the decoder plugin failed."
    mv "$PLUGIN.tmp" "$PLUGIN"
    info "Built the QS decoder plugin"
}

# Preset name or a path to your own 14-channel 48 kHz HeSuVi-format WAV.
resolve_ir() {
    local p
    if [[ $1 == *.wav && -f $1 ]]; then p=$(realpath "$1"); else p="$HRIR/$1.wav"; fi
    if [[ ! -f $p ]]; then
        case $1 in
            steering|matrix|film-stereo|gain|device)
                die "'$1' is a command, not a preset. Use: $0 $1 <value>   (see: $0 help)" ;;
        esac
        die "preset '$1' not found. See: $0 list"
    fi
    [[ $p != *'"'* ]] || die "file path must not contain double quotes."
    is_hrir "$p" || die "$p is not a HeSuVi 7.1 file (need 14 channels, 48 kHz)."
    printf '%s\n' "$p"
}

# --- config rendering --------------------------------------------------------
# HeSuVi channel layout: speaker -> "left-ear-channel right-ear-channel"
declare -A EARS=( [FL]="0 1" [SL]="2 3" [RL]="4 5" [FC]="6 13" [FR]="8 7" [SR]="10 9" [RR]="12 11" [LFE]="6 13" )

# conv_pair <prefix> <speaker> <ir>: two convolver nodes (left ear, right ear)
conv_pair() {
    local l r; read -r l r <<< "${EARS[$2]}"
    echo "          { type = builtin label = convolver name = $1${2}_L config = { filename = \"$3\" channel = $l } }"
    echo "          { type = builtin label = convolver name = $1${2}_R config = { filename = \"$3\" channel = $r } }"
}

mixer_node() {  # name inputs gain
    local i ctl=""
    for ((i = 1; i <= $2; i++)); do ctl+=" \"Gain $i\" = $3"; done
    echo "          { type = builtin label = mixer name = $1 control = {$ctl } }"
}

out_props() {  # node name
    # Send to the chosen hardware output. Without a fixed target the two
    # surround devices would feed into each other when one is the default.
    # If that device is unplugged, WirePlumber falls back to another output.
    local target=""
    [[ -n ${HW:-} ]] && target="target.object  = \"$HW\""
    cat <<EOF
      playback.props = {
        node.name      = "$1"
        node.passive   = true
        $target
        audio.channels = 2
        audio.position = [ FL FR ]
      }
EOF
}

qs_node() {  # name label mode   (LADSPA decoder node)
    local mode=0; [[ $3 == hafler ]] && mode=1
    echo "          { type = ladspa name = $1 plugin = \"$PLUGIN\" label = $2 control = { \"Steering\" = $STEER \"Mode\" = $mode } }"
}

link() { echo "          { output = \"$1\" input = \"$2\" }"; }

# both ear convolvers of a speaker get the same source, and feed mixL/mixR input <n>
feed_speaker() {  # prefix speaker source-port mixer-input
    link "$3" "$1${2}_L:In"
    link "$3" "$1${2}_R:In"
    link "$1${2}_L:Out" "mixL:In $4"
    link "$1${2}_R:Out" "mixR:In $4"
}

render_film() {  # ir gain stereo-mode
    local ir=$1 gain=$2 mode=$3 sp
    local speakers=(FL FR FC LFE RL RR SL SR)
    cat <<EOF
  # Film: 7.1 in -> binaural out. Stereo: $mode
  { name = libpipewire-module-filter-chain
    flags = [ nofail ]
    args = {
      node.description = "$FILM_DESC"
      media.name       = "$FILM_DESC"
      filter.graph = {
        nodes = [
EOF
    for sp in "${speakers[@]}"; do
        echo "          { type = builtin label = copy name = in$sp }"
        conv_pair f "$sp" "$ir"
    done
    if [[ $mode != psd ]]; then
        # Any signal on the other six channels means a real multichannel
        # source; the decoder then passes the front pair through untouched.
        qs_node qs hs_qs_film "$mode"
        mixer_node detect 6 1.0
        mixer_node sumRL 2 1.0
        mixer_node sumRR 2 1.0
    fi
    mixer_node mixL 8 "$gain"
    mixer_node mixR 8 "$gain"
    echo "        ]"
    echo "        links = ["
    if [[ $mode == psd ]]; then
        local i=1
        for sp in "${speakers[@]}"; do feed_speaker f "$sp" "in$sp:Out" $i; i=$((i + 1)); done
    else
        link "inFL:Out" "qs:In L"
        link "inFR:Out" "qs:In R"
        local i=1
        for sp in FC LFE RL RR SL SR; do link "in$sp:Out" "detect:In $i"; i=$((i + 1)); done
        link "detect:Out" "qs:Detect"
        link "inRL:Out" "sumRL:In 1"; link "qs:Out LB" "sumRL:In 2"
        link "inRR:Out" "sumRR:In 1"; link "qs:Out RB" "sumRR:In 2"
        feed_speaker f FL  "qs:Out LF"  1
        feed_speaker f FR  "qs:Out RF"  2
        feed_speaker f FC  "inFC:Out"   3
        feed_speaker f LFE "inLFE:Out"  4
        feed_speaker f RL  "sumRL:Out"  5
        feed_speaker f RR  "sumRR:Out"  6
        feed_speaker f SL  "inSL:Out"   7
        feed_speaker f SR  "inSR:Out"   8
    fi
    cat <<EOF
        ]
        inputs  = [ "inFL:In" "inFR:In" "inFC:In" "inLFE:In" "inRL:In" "inRR:In" "inSL:In" "inSR:In" ]
        outputs = [ "mixL:Out" "mixR:Out" ]
      }
      capture.props = {
        node.name      = "$FILM_SINK"
        media.class    = Audio/Sink
        audio.channels = 8
        audio.position = [ FL FR FC LFE RL RR SL SR ]
      }
EOF
    out_props "effect_output.headphone_surround"
    echo "    }"
    echo "  }"
}

render_music() {  # ir gain matrix
    local ir=$1 gain=$2 mode=$3
    cat <<EOF
  # Music: stereo -> $mode decode to quad -> binaural out
  { name = libpipewire-module-filter-chain
    flags = [ nofail ]
    args = {
      node.description = "$MUSIC_DESC"
      media.name       = "$MUSIC_DESC"
      filter.graph = {
        nodes = [
EOF
    qs_node qs hs_qs_music "$mode"
    local sp; for sp in FL FR RL RR; do conv_pair m "$sp" "$ir"; done
    mixer_node mixL 4 "$gain"
    mixer_node mixR 4 "$gain"
    echo "        ]"
    echo "        links = ["
    feed_speaker m FL "qs:Out LF" 1
    feed_speaker m FR "qs:Out RF" 2
    feed_speaker m RL "qs:Out LB" 3
    feed_speaker m RR "qs:Out RB" 4
    cat <<EOF
        ]
        inputs  = [ "qs:In L" "qs:In R" ]
        outputs = [ "mixL:Out" "mixR:Out" ]
      }
      capture.props = {
        node.name      = "$MUSIC_SINK"
        media.class    = Audio/Sink
        audio.channels = 2
        audio.position = [ FL FR ]
      }
EOF
    out_props "effect_output.headphone_surround_music"
    echo "    }"
    echo "  }"
}

render_config() {  # ir-path gain-db music-matrix film-stereo
    local gain; gain=$(db_to_lin "$2")
    echo "$MARKER"
    echo "# preset: $1   gain: $2 dB   music: $3   film stereo: $4   steering: $STEER"
    echo "context.modules = ["
    render_film "$1" "$gain" "$4"
    render_music "$1" "$gain" "$3"
    echo "]"
}

render_upmix() {  # film-stereo mode
    echo "$MARKER"
    if [[ $1 == psd ]]; then
        cat <<EOF
# Spread stereo streams over all speakers of a surround output (Film device).
stream.properties = {
    channelmix.upmix        = true
    channelmix.upmix-method = psd     # stereo -> centre + surround channels
    channelmix.lfe-cutoff   = 150     # fill LFE below 150 Hz
    channelmix.fc-cutoff    = 12000
    channelmix.rear-delay   = 12.0    # ms; helps the surrounds sound separate
}
EOF
    else
        cat <<EOF
# Keep stereo as stereo on surround outputs: the Film device decodes it itself
# (QS/Hafler), and needs the other channels silent to know it is stereo.
stream.properties = {
    channelmix.upmix = false
}
EOF
    fi
}

write_file() {  # path; content on stdin. Refuses to replace files it did not create.
    local path=$1
    if [[ -e $path ]] && ! ours "$path"; then
        die "$path exists and was not made by this script. Move it away and retry."
    fi
    mkdir -p "$(dirname "$path")"
    cat > "$path.tmp" && mv "$path.tmp" "$path"
}

sink_present() { pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$1"; }

wait_for_sink() {
    local i
    for i in $(seq 1 50); do sink_present "$1" && return 0; sleep 0.2; done
    return 1
}

current() {  # fill IR / GAIN / MATRIX from state, with defaults
    IR=$(state_get CURRENT_IR);  IR=${IR:-$DEFAULT_IR}
    GAIN=$(state_get GAIN_DB);   GAIN=${GAIN:-$DEFAULT_GAIN_DB}
    MATRIX=$(state_get MATRIX);  MATRIX=${MATRIX:-$DEFAULT_MATRIX}
    FILM_STEREO=$(state_get FILM_STEREO); FILM_STEREO=${FILM_STEREO:-$DEFAULT_FILM_STEREO}
    STEER=$(state_get STEERING); STEER=${STEER:-$DEFAULT_STEERING}
    HW=$(state_get HW_SINK)
}

is_ours() { [[ $1 == "$FILM_SINK" || $1 == "$MUSIC_SINK" ]]; }

hw_sinks() {  # real output devices (not ours, not other filters)
    pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -vE '^effect_input\.|^easyeffects' || true
}

# Write the filter config from state and restart only the filter service
# (other audio keeps playing; the surround devices blink for a moment).
apply() {
    current
    local path; path=$(resolve_ir "$IR")
    build_plugin
    local was; was=$(pactl get-default-sink 2>/dev/null || true)
    local backup="$FC_CONF.previous"
    [[ -f $FC_CONF ]] && cp "$FC_CONF" "$backup"
    render_config "$path" "$GAIN" "$MATRIX" "$FILM_STEREO" | write_file "$FC_CONF"
    systemctl --user restart filter-chain.service
    if ! { wait_for_sink "$FILM_SINK" && wait_for_sink "$MUSIC_SINK"; }; then
        local log; log=$(journalctl --user -u filter-chain -n 8 --no-pager 2>/dev/null || true)
        if [[ -f $backup ]]; then
            mv "$backup" "$FC_CONF"
            systemctl --user restart filter-chain.service
            wait_for_sink "$FILM_SINK" || true
            warn "the new settings failed to load, so the previous ones were put back."
        fi
        printf '%s\n' "$log" >&2
        die "surround devices did not appear with the new settings."
    fi
    rm -f "$backup"
    # keep whichever surround device was the default
    if is_ours "$was"; then pactl set-default-sink "$was"; fi
}

# Write the upmix setting for the Film stereo mode. Restarts pipewire-pulse
# only when the setting changed (audio apps blink for a second).
apply_upmix() {
    local f changed=no new
    new=$(render_upmix "$1")
    for f in "${UPMIX_CONFS[@]}"; do
        if [[ ! -f $f || $(cat "$f") != "$new" ]]; then
            printf '%s\n' "$new" | write_file "$f"; changed=yes
        fi
    done
    if [[ $changed == yes ]]; then
        info "Restarting pipewire-pulse for the new stereo setting (audio apps blink for a second)"
        local was; was=$(pactl get-default-sink 2>/dev/null || true)
        systemctl --user restart pipewire-pulse.service
        wait_for_sink "$FILM_SINK" || true
        if is_ours "$was"; then pactl set-default-sink "$was" 2>/dev/null || true; fi
    fi
}

# --- commands --------------------------------------------------------------
cmd_install() {
    require_user_pipewire
    local before; before=$(pactl get-default-sink 2>/dev/null || true)
    ensure_packages
    fetch_hesuvi
    if [[ -n ${1:-} ]]; then resolve_ir "$1" >/dev/null; state_set CURRENT_IR "$1"; fi
    rm -rf "$DATA/matrix"   # FIR kernels from version 2, replaced by the plugin
    build_plugin
    current; resolve_ir "$IR" >/dev/null

    if [[ -n $before ]] && ! is_ours "$before"; then
        state_set PREV_DEFAULT_SINK "$before"
        [[ -n $(state_get HW_SINK) ]] || state_set HW_SINK "$before"
    fi
    if [[ $(systemctl --user is-enabled filter-chain.service 2>/dev/null) != enabled ]]; then
        systemctl --user enable filter-chain.service
        state_set ENABLED_FILTER_CHAIN yes
    fi
    local reinstall=no; ours "$FC_CONF" && reinstall=yes
    info "Starting the surround devices"
    apply
    apply_upmix "$FILM_STEREO"
    if [[ $reinstall == no ]]; then
        wait_for_sink "$FILM_SINK" && pactl set-default-sink "$FILM_SINK"
    fi

    info "Done. Preset $IR, stereo on Film: $FILM_STEREO, music: $MATRIX, steering $STEER."
    echo "  Surround is sent to: ${HW:-(automatic)}   change with: $0 device"
    echo "  Pick \"$FILM_DESC\" or \"$MUSIC_DESC\" in the sound menu."
    echo "  Native PipeWire apps that were already open (e.g. mpv) need a restart for stereo changes."
    echo "  Compare presets:  $0 list   then   $0 select <preset>"
    echo "  Turn off:         $0 uninstall"
    easyeffects_note
}

cmd_select() {
    [[ -n ${1:-} ]] || die "usage: $0 select <preset>   (see: $0 list)"
    require_user_pipewire
    ours "$FC_CONF" || die "not installed. Run: $0 install"
    resolve_ir "$1" >/dev/null
    state_set CURRENT_IR "$1"
    apply
    info "Now using $1"
}

cmd_matrix() {
    [[ ${1:-} == qs || ${1:-} == hafler ]] || die "usage: $0 matrix qs|hafler"
    require_user_pipewire
    ours "$FC_CONF" || die "not installed. Run: $0 install"
    state_set MATRIX "$1"
    apply
    info "Music device now decodes with $1"
}

cmd_film_stereo() {
    [[ ${1:-} =~ ^(qs|hafler|psd)$ ]] || die "usage: $0 film-stereo qs|hafler|psd"
    require_user_pipewire
    ours "$FC_CONF" || die "not installed. Run: $0 install"
    state_set FILM_STEREO "$1"
    apply
    apply_upmix "$1"
    info "Stereo on the Film device: $1"
}

cmd_steering() {
    [[ ${1:-} =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || die "usage: $0 steering <0..1>   0 = basic QS, 1 = strongest  (now: $(current; echo "$STEER"))"
    require_user_pipewire
    ours "$FC_CONF" || die "not installed. Run: $0 install"
    state_set STEERING "$1"
    apply
    info "QS steering now $1"
}

cmd_gain() {
    [[ ${1:-} =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || die "usage: $0 gain <dB>   e.g. $0 gain -8  (now: $(state_get GAIN_DB))"
    require_user_pipewire
    ours "$FC_CONF" || die "not installed. Run: $0 install"
    state_set GAIN_DB "$1"
    apply
    info "Output gain now $1 dB"
}

cmd_device() {
    require_user_pipewire
    current
    if [[ -z ${1:-} ]]; then
        echo "Surround output is sent to (current marked *):"
        local s; while read -r s; do
            [[ -n $s ]] || continue
            if [[ $s == "$HW" ]]; then echo "  * $s"; else echo "    $s"; fi
        done <<< "$(hw_sinks)"
        echo "Change with: $0 device <name>"
        return
    fi
    hw_sinks | grep -qxF "$1" || die "no output device named '$1'. Run: $0 device"
    ours "$FC_CONF" || die "not installed. Run: $0 install"
    state_set HW_SINK "$1"
    apply
    info "Surround now plays through $1"
}

cmd_list() {
    current
    echo "Presets to compare (current marked *):"
    local name desc mark
    while IFS='|' read -r name desc; do
        [[ -n $name ]] || continue
        mark="  "; [[ $name == "$IR" ]] && mark="* "
        [[ -f $HRIR/$name.wav ]] || mark="? "
        printf '  %s%-10s %s\n' "$mark" "$name" "$desc"
    done <<< "$SUGGESTED"
    if [[ -d $HRIR ]]; then
        echo
        printf 'All installed: '
        (cd "$HRIR" && ls -- *.wav 2>/dev/null | sed 's/\.wav$//' | tr '\n' ' ')
        echo
    fi
    echo
    echo "You can also select the path of your own 14-channel 48 kHz HeSuVi-format WAV."
}

easyeffects_note() {
    if pgrep -x easyeffects >/dev/null 2>&1; then
        warn "EasyEffects is running. It takes over the default output, so its effects"
        warn "(e.g. crossfeed in your MySurround preset) would stack on top. Either quit it,"
        warn "or set its output device to a Headphone Surround device and bypass its"
        warn "convolver and crossfeed (keep only EQ)."
    fi
}

cmd_status() {
    current
    echo "headphone-surround $VERSION"
    if ours "$FC_CONF"; then echo "  installed:     yes"; else echo "  installed:     no"; fi
    echo "  preset:        $IR"
    echo "  music matrix:  $MATRIX"
    echo "  film stereo:   $FILM_STEREO"
    echo "  QS steering:   $STEER"
    echo "  gain:          $GAIN dB"
    echo "  plays through: ${HW:-(automatic)}"
    local s; for s in "$FILM_SINK" "$MUSIC_SINK"; do
        if sink_present "$s"; then echo "  running:       $s"; fi
    done
    echo "  default:       $(pactl get-default-sink 2>/dev/null || echo '?')"
    local up; up=$(pw-config -n pipewire-pulse.conf merge stream.properties 2>/dev/null | grep -c '"channelmix.upmix": true' || true)
    if ((up)); then echo "  pipewire upmix: on"; else echo "  pipewire upmix: off"; fi
    easyeffects_note
}

cmd_uninstall() {
    local purge=no
    [[ ${1:-} == --purge ]] && purge=yes
    require_user_pipewire

    local def; def=$(pactl get-default-sink 2>/dev/null || true)
    if [[ $def == "$FILM_SINK" || $def == "$MUSIC_SINK" ]]; then
        local prev; prev=$(state_get PREV_DEFAULT_SINK)
        if [[ -n $prev ]] && sink_present "$prev"; then
            pactl set-default-sink "$prev"
            info "Default output restored to $prev"
        fi
    fi

    local f removed=0
    for f in "$FC_CONF" "${UPMIX_CONFS[@]}"; do
        if ours "$f"; then rm -f "$f"; removed=$((removed + 1)); fi
    done
    info "Removed $removed config file(s)"

    if [[ $(state_get ENABLED_FILTER_CHAIN) == yes ]]; then
        systemctl --user disable --now filter-chain.service
    else
        systemctl --user restart filter-chain.service
    fi
    info "Restarting pipewire-pulse to turn off upmix (audio apps blink for a second)"
    systemctl --user restart pipewire-pulse.service

    if [[ $purge == yes ]]; then
        rm -rf "$DATA" "$CACHE"
        info "Removed impulse responses and download cache"
        local pkgs; pkgs=$(state_get PKGS_INSTALLED | xargs)
        if [[ -n $pkgs ]]; then
            read -r -p "Remove packages this script installed ($pkgs)? apt will show what else goes. [y/N] " a
            [[ $a == [yY]* ]] && sudo apt-get remove $pkgs
        fi
        rm -rf "$STATE_DIR"
    else
        echo "  Presets kept in $DATA (use 'uninstall --purge' to delete them)."
    fi
    info "Uninstalled."
}

usage() {
    cat <<EOF
headphone-surround.sh $VERSION - virtual surround for headphones (PipeWire)

  install [preset]      set up (default preset: $DEFAULT_IR) and make Film the default output
  select <preset>       switch preset, e.g. dh++ (Dolby Headphone DH-2 Cinema)
  matrix qs|hafler      decoder for the Music device (default: $DEFAULT_MATRIX)
  film-stereo qs|hafler|psd
                        how the Film device handles stereo (default: $DEFAULT_FILM_STEREO;
                        psd = PipeWire's upmixer). 5.1/7.1 sources are never decoded.
  steering <0..1>       QS direction steering (default: $DEFAULT_STEERING; 0 = basic matrix)
  device [name]         list hardware outputs, or choose where surround plays
  gain <dB>             output trim (default: $DEFAULT_GAIN_DB). Lower it if you hear clipping
  list                  show presets
  status                show what is active
  uninstall [--purge]   remove; --purge also deletes presets and offers to remove packages
  render-config [preset] print the PipeWire config without installing

Switch devices from the sound menu: "$FILM_DESC" for video,
"$MUSIC_DESC" for stereo music, or your plain headphones to bypass both.
EOF
}

case ${1:-help} in
    install)        shift; cmd_install "$@" ;;
    select)         shift; cmd_select "$@" ;;
    matrix)         shift; cmd_matrix "$@" ;;
    film-stereo)    shift; cmd_film_stereo "$@" ;;
    steering)       shift; cmd_steering "$@" ;;
    device)         shift; cmd_device "$@" ;;
    gain)           shift; cmd_gain "$@" ;;
    list)           cmd_list ;;
    status)         cmd_status ;;
    uninstall)      shift; cmd_uninstall "$@" ;;
    render-config)  shift; current; [[ -n ${1:-} ]] && IR=$1
                    p=$(resolve_ir "$IR"); render_config "$p" "$GAIN" "$MATRIX" "$FILM_STEREO" ;;
    help|-h|--help) usage ;;
    *)              usage; exit 1 ;;
esac

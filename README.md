# Headphone Surround

Virtual surround for headphones on Linux Mint 22+ (PipeWire). Adds two outputs to the sound menu:

- **Headphone Surround - Film**: 7.1 virtual speakers. 5.1/7.1 film audio goes in directly and is never decoded. Stereo is QS-decoded to quad (switchable).
- **Headphone Surround - Music**: stereo is decoded to quad with a Sansui QS matrix with Vario-Matrix-style steering (or Hafler/DynaQuad), then placed on virtual front and back speakers.

Both use HeSuVi impulse responses captured from commercial virtualizers (Dolby Atmos, Dolby Headphone, DTS Headphone:X, ...). The QS decoder is a small plugin built from C source inside the script (install adds gcc if it's missing).

## Install / remove

```
./headphone-surround.sh install            # downloads presets, makes Film the default output
./headphone-surround.sh uninstall          # removes the config, restores your old default output
./headphone-surround.sh uninstall --purge  # also deletes the downloaded presets
```

Install restarts PipeWire's PulseAudio layer, so audio apps blink for a second. Stop Persona first.

## Everyday use

Pick the output in the sound menu:

| Listening to | Choose |
|---|---|
| Films, TV, games | Headphone Surround - Film |
| Stereo music | Headphone Surround - Music |
| Plain, no processing | Family (your headphone jack) |

Media players that were already open (e.g. mpv) need a restart after a `film-stereo` change.

## Commands

```
./headphone-surround.sh list              # presets (current one marked *)
./headphone-surround.sh select dh++       # switch preset; other audio keeps playing
./headphone-surround.sh matrix hafler     # Music device: hafler or qs
./headphone-surround.sh steering 0.5      # QS steering 0..1 (0 = basic matrix, default 0.5)
./headphone-surround.sh film-stereo qs    # stereo on Film: qs, hafler, or psd (PipeWire's upmixer)
./headphone-surround.sh gain -8           # output level in dB (default -6); lower it if you hear clipping
./headphone-surround.sh device            # list hardware outputs / choose where surround plays
./headphone-surround.sh status
```

## Presets worth comparing

| Preset | What it is |
|---|---|
| `atmos` | Dolby Atmos for headphones (default) |
| `dh++` | Dolby Headphone DH-2 Cinema |
| `dh+` | Dolby Headphone DH-1 Studio |
| `dht` | Dolby Home Theater v4 |
| `dtshx` | DTS Headphone:X |
| `gsx` | Sennheiser GSX 7.1 |
| `sonic` | Windows Sonic |
| `sbx67` | Creative SBX Pro Studio |
| `cmss_ent` | Creative CMSS-3D Entertainment |
| `ooyh1` | Out Of Your Head (AIX studio) |

These are recordings of each processor's output, not the live algorithm. You can also `select` the path of any 14-channel 48 kHz HeSuVi-format WAV.

## Good to know

- QS steering finds the dominant direction and raises the nearest speakers (adjacent separation about 3 dB at 0, 12 dB at 0.7, 15 dB at 1). It's Vario-Matrix-style logic, not Sansui's circuit or a SurroundMaster emulation. With a strong centre voice it pulls the back ambience down; lower it if music sounds less open.
- `steering 0` is the basic QS matrix. It's close to the first version you heard, but not identical (that one rolled off bass in the backs).
- The Film device detects real 5.1/7.1 sources (any signal on the centre or surround channels) and then plays them discretely. It returns to QS decoding 10 seconds after the surround channels go silent.
- While Film is the default output, all system sound (including Persona's voice) goes through it. To avoid that, set your headphones as the default and choose a surround device per app.
- `film-stereo psd` turns on PipeWire's upmixer for every multichannel output, including HDMI. In `qs`/`hafler` mode PipeWire's upmix is off. Uninstall removes the setting.
- If EasyEffects is running, its effects stack on top of the surround. Quit it, or point its output at a surround device and bypass its convolver and crossfeed.
- Files: config in `~/.config/pipewire/*.conf.d/60-headphone-surround*`, presets in `~/.local/share/headphone-surround/`.
- If a surround device doesn't appear: `journalctl --user -u filter-chain -n 30`.

## Sources

- HeSuVi: https://sourceforge.net/projects/hesuvi/
- PipeWire filter-chain: `man libpipewire-module-filter-chain`
- QS matrix: https://en.wikipedia.org/wiki/QS_Regular_Matrix

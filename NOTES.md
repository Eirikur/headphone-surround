# Next ideas

## Effect control (like Sansui's "AV Surround Effect" slider)

The Sansui S-XV1000 had an "AV Surround Effect" slider (0–10) beside its QS Surround / Theater / Multi-Dimension modes. A working QS unit made concert scenes sound like the hall's back wall was behind you.

Plan: an `effect <0..10>` command for the QS decoder that sets:
- the back-channel level (0 = fronts only, 10 = strongest)
- a short back-channel delay, about 10–20 ms, so the reverb is heard as coming from a distant wall instead of nearby speakers

For concert material, try low steering (`steering 0`–`0.2`): steering lowers the backs, and with them the hall reverb, whenever a strong front source dominates.

## Open question

"Current setting not changing" when switching. Not reproduced yet; need to know where it was seen (`list`, `status`, or Cinnamon Sound settings).

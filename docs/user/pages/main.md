# MAIN

The voice list and the selected voice's main parameter. Back to [Screen Controls](../controls.md).

- **E2** - Select voice (1-7)
- **E3** - Adjust selected voice's main parameter (ALT+E3 in finer steps)
  - Resonator: Frequency
  - FM: Modulation index
  - Folder: Fold amount
  - Sub: Drift amount
  - Pulse: Pulse width
  - Karplus: Decay time
  - Ring: Frequency ratio
  - Any voice whose source is a buffer: buffer position (`pos`)
  - Any voice whose source is the input: grain size (`size`)
- **K2** - Randomize selected voice parameters (buffer parameters for a buffer-sourced voice, only grain parameters for an input-sourced one)
- **K3** - Start the selected voice if it is off; if it is running, lock/unlock it (it never stops a voice and never fires a triggered grain: stop voices from the grid, a scene or a MIDI note off)

The voice list on the left marks each voice `+` (running) or `-` (stopped), then its short name (`reso`, `fm`, `fold`, `sub`, `pulse`, `karp`, `ring`) and `[L]` when locked. The right side shows the selected voice's full name, ON/OFF and its main parameter. `[TRIG]` on the main parameter row means the selected voice is in triggered grain mode.

The arc's MAIN rings are in [Monome Arc](../arc.md).

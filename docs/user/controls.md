# Screen Controls

The five screen pages and what the encoders and keys do on each. Back to the [README](../../README.md).

## Screen Pages

The screen has five pages: **MAIN**, **FX**, **LFO**, **BUFFER** and **SETUP**.

- **E1** - Select the page (turn left toward MAIN, right toward SETUP; one page per short turn, without acceleration)

Every page shows the page name, master density (`dens:`), the `[M]` mutation indicator and the `S1`-`S8` scene indicator at the top, and the page's key hints on the bottom row. E2, E3, K2 and K3 do something different on each page. The arc follows the page too (see [Monome Arc](arc.md)).

Master density is no longer on E1: adjust it on the first row of the FX page, with arc ring 1 on the MAIN page, or in the PARAMETERS menu.

### MAIN

- **E2** - Select voice (1-7)
- **E3** - Adjust selected voice's main parameter
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
- **K3** - Start the selected voice if it is off; if it is running, freeze/unfreeze it (it never stops a voice and never fires a triggered grain: stop voices from the grid, a scene or a MIDI note off)

The voice list on the left marks each voice `+` (running) or `-` (stopped), then its short name (`reso`, `fm`, `fold`, `sub`, `pulse`, `karp`, `ring`) and `[F]` when frozen. The right side shows the selected voice's full name, ON/OFF and its main parameter. `[TRIG]` on the main parameter row means the selected voice is in triggered grain mode.

### FX

A scrolling list of the effects settings, five rows at a time: master density, tape drift, filter type / freq / res / mix, delay time / feedback (`fdbk`) / mix, reverb mix / size / damp. The selected row is bright.

- **E2** - Select a row
- **E3** - Adjust the selected row's value
- **K3** - Bypass the filter (mix to 0), or bring it back at the last mix it had above 0, however that was set (fully on if it has never been above 0). The hint row shows `K3:filter bypass` or `K3:filter on`

### BUFFER

Where a voice's source is chosen and its buffer is filled, so it works without a grid. The left column shows the selected voice, its source (`src: buf 2`), and the record duration and level. The right column lists the eight buffers: number, name (the file name, shortened, or `take <n>` for a recording, or `empty`) and length in seconds, or `REC` while recording. A take shows `REC` until the engine reports what it captured (a moment after the recording ends): then it becomes `take <n>`, or `empty` if nothing was captured (a stop right after the start; a take or file the engine reports late, such as a slow read at start, is still picked up, unless the buffer was cleared, loaded or recorded into meanwhile). A loaded file shows its name at once. If the file cannot be loaded (missing, unreadable, an unsupported format, empty, or damaged so that it stops decoding part way), the buffer goes back to what it held before (the earlier file and its audio, or `empty`; if the file disappears in the moment between the checks and the read, as when a drive is unplugged, the buffer is left `empty`), the hint row shows `buf <n> load failed` for 1.5 s, and the file is not reloaded at the next start. The selected voice's buffer is bright, buffers holding audio are mid, empty ones dim.

- **E2** - Select voice (the same selection as MAIN)
- **E3** - Cycle the voice's source: synth, buf 1 ... buf 8, input
- **K3** - Record the input into the voice's buffer for the record duration (replacing what was there); press again while recording to stop early and keep what was captured. Voices playing that buffer are silent while it records and play the new take as soon as it is done
- **K2** - Load a sound file into the voice's buffer: K2 acts when released and opens the file browser at `~/dust/audio`
- **K2 + K3** - Hold K2 and press K3 to save the voice's buffer to `~/dust/audio/strata/<date-time>-buf<n>.wav` (each K3 press while K2 is held saves again; releasing K2 then does not open the file browser). For 1.5 s the hint row confirms it with `saved buf <n>`, shows `buf <n> busy` while the buffer is recording or waiting for its take, or `buf <n> empty` when the buffer holds no audio; nothing is saved in the last two cases
- The hint row reads `K2:load K3:rec K2+3:save` (`K3:stop` while the buffer records, `K3:...` while a take that has ended waits for the engine; K3 does nothing then). When the voice's source is the synth or the input there is no buffer: K2 and K3 do nothing and the hint row reads `K2:- K3:- E3:source`

Record duration and level are on arc rings 3 and 4 of this page (and in PARAMETERS > buffers).

### LFO

One row per LFO: `L1`-`L3` (the selected one bright), one cycle of its shape, a dot that follows the LFO while it runs, its destination (`filt freq`, `v2 main`, ...) and `on`/`off` with its depth.

- **E2** - Select an LFO
- **E3** - Adjust the selected LFO's depth (1 % steps)
- **K2** - Next destination (wraps from the last voice's scan back to none)
- **K3** - Turn the selected LFO on or off
- Shape, rate, mode, phase and the other LFO settings are in PARAMETERS > LFO 1-3

### SETUP

Shows how many grids are connected and their sizes, whether an arc is connected, how many of the 8 scene slots hold a scene, how many buffers were restored when the script started (`buffers: 3 restored`, counting a buffer once the engine reports audio in it; `buffers: 2 ok, 1 missing` when remembered files were not found), and the MIDI input: the port Strata listens to and the device on it (`midi 1: <device>`, shortened if the name is long, or `none`) and the channel mode (`ch: per voice`).

- **E2** - MIDI port (1-4)
- **E3** - MIDI channel mode (per voice, or omni to the selected voice)
- **K3** - Save scenes to disk (same as PARAMETERS > save scenes to disk)

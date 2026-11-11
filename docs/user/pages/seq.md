# SEQ

All seven patterns, the sequencer's transport and the tempo, so patterns can be made without a grid. Back to [Screen Controls](../controls.md).

- **E2** - Move the step cursor (steps 1-16)
- **E3** - Set the step's level: 0 (off) to 15, the level the step accents its voice at (the same levels the grid shows)
- **K2** - Play/stop the patterns
- **K3** - Turn the step on (at 15) or off
- **ALT+E2** - Move to another voice's row; the selected voice follows (MAIN, VOICE and BUFFER show it too)
- **ALT+E3** - Change the tempo (1 BPM per detent)
- **ALT+K2** - Clear the selected voice's pattern
- **ALT+K3** - Randomize the selected voice's pattern (about half the steps on, at levels 8-15)

Each voice has a row: its number on the left (bright for the selected voice), sixteen cells and `+` (running) or `-` (stopped) on the right. A set step is a filled cell as bright as its level; an empty step is a dim outline, so even a level-1 step reads as set. The cursor is a bright square around the selected step. While the patterns play, the column of the step playing is drawn brighter on every row, and the header shows the play mark and the tempo (`▶ 120 bpm`).

A step on a stopped voice starts it; on a running voice it accents it (the step's level is the accent's velocity). Edits show on a connected grid at once. The arc's button plays and stops the patterns; the arc's SEQ rings are in [Monome Arc](../arc.md).

The patterns step in sixteenth notes on norns' clock (PARAMETERS > CLOCK), so with the clock's source set to MIDI or Link they follow that tempo. They also follow its transport: a start from the source (a MIDI start, a Link start with "link start/stop sync" enabled, or PARAMETERS > CLOCK > reset on the internal clock) plays the patterns from step 1 on its first beat, even if they were already playing, and a stop stops them. K2, the grid's play key and the arc's button start them at once instead, on whatever beat the clock is at.

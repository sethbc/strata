# SEQ

All seven patterns, the sequencer's transport and the tempo, so patterns can be made without a grid, and an edit view for each voice's length, division, swing and gate and for what each step holds (see [Sequencer](../sequencer.md)). Back to [Screen Controls](../controls.md).

## The patterns

- **E2** - Move the step cursor (steps 1-16)
- **E3** - Set the step's level: 0 (off) to 15, the level the step accents its voice at (the same levels the grid shows)
- **K2** - Play/stop the patterns
- **K3** - Turn the step on (at 15) or off
- **ALT+E2** - Move to another voice's row; the selected voice follows (MAIN, VOICE and BUFFER show it too)
- **ALT+E3** - Change the tempo (1 BPM per detent)
- **ALT+K2** - Randomize the selected voice's pattern (about half the steps on, at levels 8-15) when you let go of K2. Press it again within 5 seconds to bring the old pattern back; editing any of that voice's steps ends the undo. Hold K2 past half a second and let go to open the edit view on the step under the cursor (the hint says `K2:edit`)
- **ALT+K3** - Clear the selected voice's pattern

Each voice has a row: its number on the left (bright for the selected voice), sixteen cells and `+` (running) or `-` (stopped) on the right. A set step is a filled cell as bright as its level; an empty step is a dim outline, so even a level-1 step reads as set. The steps past a voice's length are small dots: the voice does not play them until its length grows. A `G` before the `+` or `-` marks a gated voice (one heard only while a step's gate is open). The cursor is a bright square around the selected step. While the patterns play, each row's playing step is drawn brighter: every voice plays at its own length and division, so the rows' playing steps differ. The header shows the play mark beside the tempo (`▶ 120 bpm`) while they play. The tempo is always in the header on this page, whether or not the patterns play; it takes the place of `[M]` and `REC`/`ARM`, which other pages show there.

A step on a stopped voice starts it; on a running voice it accents it (the step's level is the accent's velocity). Edits show on a connected grid at once. The arc's button plays and stops the patterns; the arc's SEQ rings are in [Monome Arc](../arc.md).

The patterns step on norns' clock (PARAMETERS > CLOCK), so with the clock's source set to MIDI or Link they follow that tempo. They also follow an external source's transport: a start from the source (a MIDI start, or a Link start with "link start/stop sync" enabled) plays the patterns from step 1 on its first beat, even if they were already playing, and a stop stops them. On the internal clock nothing starts or stops them but you: PARAMETERS > CLOCK > reset restarts the clock's beat and leaves the patterns as they are. K2, the grid's play keys and the arc's button start them on whatever beat the clock is at (or on the next beat or bar with quantized actions on, the `quantize` row below; pressed again before then, they take the waiting start back, and a transport start or stop drops it).

## The edit view

ALT+K2 held opens it on the selected voice and the step under the cursor. The line under the header shows them (`v3 step 5`) and the voice's sixteen steps, the one being edited outlined. Below it, a list in three sections:

- **voice** - `length` (1-16 steps), `division` (`1/32` to `1 bar`), `swing` (50-75 %), `gate` (off or on), `gate len` (the gate's length in steps, `0.50 st`), `gate rel` (its release, `0.10 s`), `euclid` (a Euclidean fill: `5/12 +2` is 5 hits over the voice's 12 steps, turned by 2) and `clear` (K3 clears the pattern)
- **step** (named after the step: `step 5`) - `level` (0-15), `prob` (the chance it plays, `80%`), `ratchet` (hits, `x2`), `gate` (the step's own gate length, `2.00 st`, or `off` for the voice's), `note` (a scale degree from the voice's pitch, `+3`, or `off`), the step locks `pos` (`0.42`), `pitch` (`1.50x`) and `size` (`0.12 s`), each `off` until set, and `bookmark` (`2` or `off`; only for a buffer voice whose buffer holds audio)
- **chain** - `chain` (off or on), `from`, `scenes` and `bars`, and `quantize` (quantized actions: off, beat or bar), the settings every voice shares

- **E2** - Move through the list
- **E3** - Change the value. A step lock, note or bookmark that is `off` starts from the voice's own value (a lock) or 0 (a note) and steps from there: one detent up from `off` on `pos` with the voice at 0.30 locks it to 0.31. Turning below the start of its range sets it `off` again. `euclid` sets the hits; `prob` at 100 % and `ratchet` at `x1` are a plain step
- **ALT+E2** - Move to another step of the voice
- **ALT+E3** - Fine adjustment (a tenth of a detent) on the continuous rows; on `euclid` the rotation
- **K2** - Back to the patterns
- **K3** - Turn the step on (at 15) or off; on the `clear` row, clear the voice's pattern
- **ALT+K2** - A quick press randomizes the voice's pattern (or undoes it), as on the patterns. Held past half a second, letting go resets the row under the cursor: a lock, note, gate or bookmark of the step to `off`, `prob` to 100 %, `ratchet` to one hit, the level to 0, a setting to its default (the hint says `K2:reset`). On `euclid` and `clear`, which have nothing to reset, the hint says `K2:cancel` and letting go does nothing
- **ALT+K3** - Clear the voice's pattern

The `note` row edits the step's first note. A step can hold a chord of up to 8 notes (scenes and the chain keep them); the row changes only the first, and `off` clears them all.

## The step editor

Holding a step key on a grid opens the same edit view for that voice and step over whichever page is showing (see [Grid](../grid.md)). E2, E3, K2, K3 and their ALT layer work as above, on that voice and step; E1 does nothing while it is open, and K2 closes it, as letting go of the grid key does. The arc's rings edit the step while it is open:

- **Ring 1** - `pos`, **ring 2** - `pitch`, **ring 3** - `size` (a full turn for the whole range; from `off` at the voice's own value, and turning below the start of the range sets it `off`)
- **Ring 4** - `prob` (whole percents, a full turn for 0-100 %)
- With **ALT** held: **ring 1** - `ratchet`, **ring 2** - `note`, **ring 3** - `bookmark` (dark without bookmarks), **ring 4** - `level` (20 ticks a step)

# VOICE

Every parameter of the selected voice. Back to [Screen Controls](../controls.md).

The selected voice is the one picked on MAIN (or from the grid). The line under the header shows it as on MAIN's list (`3- karp [L]`: its number, `+` running or `-` stopped, its short name, `[L]` when locked) and, at the right, the section the cursor is in and its place among the voice's sections (`grain 2/4`).

Below it, five rows at a time, the voice's parameters in four sections, each under a dim section name:
- **synth** - the synth's own parameters (everything but level and pan). A buffer-sourced voice shows its buffer position, rate and scan here instead, then its loop start and loop length (see [Audio Sources and Buffers](../sources-and-buffers.md)); an input-sourced voice has no synth section (its sections are then counted out of three)
- **input** - an input-sourced voice only: its history, how far back in the input it plays (0 s is now; up to 16 s, 60 s on the high performance setting)
- **grain** - size, density, pitch, position spread, envelope, mode
- **crossmod** - modulation speed, then for each of the three slots its source, amplitude amount and frequency amount. A source shows the voice's number and short name (`3 fold`), or `none`
- **mix** - source (`synth`, `buf 1`-`buf 8`, `input`), level (amp), pan (the Sub has no pan) and freeze. With the high performance setting a freeze mode row follows: `hold` or `spectral`
- **filter & sends** - the voice's own filter (type, freq, res, mix; mix 0 leaves it out) and its delay and reverb sends (see [Global Controls and Effects](../effects.md))

### Freeze

E3 on the freeze row turns it on or off. A frozen voice's grains keep playing what they were playing, while pitch, spread, grain size and density still move:
- **a synth voice**: the last 4 seconds of its synth, which stops being recorded. Its buffer scan moves backward through those 4 seconds and around again (a synth voice has no scan row here or on the grid: set `v<i>_buf_scan` in the PARAMS menu, or point an LFO at `v<i> scan`);
- **an input voice**: the 4 seconds of input up to where it was playing (its history), so freezing never jumps to the present. The input keeps recording; unfreezing goes back to it;
- **a buffer voice**: its scan stops at the current position.

Frozen grains play from about half a second before the moment you froze. `spectral` (high setting only) holds one sound spectrum instead and keeps granulating it; on the standard setting, and for a buffer voice, freeze always holds. Changing the voice's source unfreezes it. Scenes save freeze and its mode, but never the audio: a recalled frozen scene freezes whatever the voice plays at the end of the transition. Randomize and mutations never change it. Map it to a MIDI CC in PARAMS > MAP. On the grid it has keys on the 256, 128h and 128v layouts ([Grid](../grid.md)).

Each value is the parameter's own text with its unit, shortened when it does not fit beside its name. The row under the cursor is bright.

- **E2** - Move the cursor; past a section's last row it goes on into the next section
- **E3** - Adjust the row under the cursor (ALT+E3 in finer steps)
- **K2** - Jump to the previous section's first row (in the first section, to its first row)
- **K3** - Jump to the next section's first row
- **ALT+K2** - Reset the row under the cursor to its default
- **ALT+K3** - Lock or unlock the voice (as on MAIN: a locked voice is skipped by randomize and mutations)

The hint row shows `K2:prev K3:next`, and with ALT (K1 held) `K2:reset K3:lock` or `K3:unlock`.

When the voice's source changes (from the grid, MIDI, a scene or the mix section itself) the sections change with it. The cursor stays on its parameter when the new sections still have it (grain pitch stays on grain pitch when the synth section goes), and otherwise moves to the nearest row. Selecting another voice keeps the cursor on the same parameter of that voice where it has one, and a change and back (input and back to synth, another voice and back) returns it to where it was.

**Arc.** While an arc is connected, a short mark at the left edge shows the rows its four rings edit: the cursor's group of four rows (rows 1-4, 5-8, ... of the voice's list, counting only parameter rows). The arc's button starts or stops the selected voice. See [Monome Arc](../arc.md).

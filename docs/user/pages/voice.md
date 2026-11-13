# VOICE

Every parameter of the selected voice. Back to [Screen Controls](../controls.md).

The selected voice is the one picked on MAIN (or from the grid). The line under the header shows it as on MAIN's list (`3- fold [L]`: its number, `+` running or `-` stopped, its short name, `[L]` when locked) and, at the right, the section the cursor is in and its place among the voice's sections (`grain 2/6`).

Below it, five rows at a time, the voice's parameters in seven sections, each under a dim section name:
- **synth** - the synth's own parameters (everything but level and pan). A buffer-sourced voice shows its buffer position, rate and scan here instead, then its loop start and loop length (see [Audio Sources and Buffers](../sources-and-buffers.md)); an input-sourced voice has no synth section and shows its input section instead
- **input** - an input-sourced voice only: its history, how far back in the input it plays (0 s is now; up to 16 s, 60 s on the high performance setting)
- **grain** - size, density, pitch, position spread, envelope, mode
- **crossmod** - modulation speed, then for each of the three slots its source, amplitude amount and frequency amount. A source shows the voice's number and short name (`3 fold`), or `none`
- **mix** - source (`synth`, `buf 1`-`buf 8`, `input`), level (amp), pan (the Sub has no pan) and freeze. With the high performance setting a freeze mode row follows: `hold` or `spectral`
- **notes** - `note cap` (1-8, default 8): how many notes the voice plays at once, its own and up to seven more from the note pool all voices share; at 1 it plays one note at a time, as before 3.5. PSETs keep it, scenes do not. Nothing plays more than one note yet: MIDI and the sequencer will play chords through it. Then `press target`, `press depth`, `slide target` and `slide depth`: what each note's pressure and slide move and how far (-100 to +100 %; amp at +100 % and main at +50 % by default), as [Expression](../modulation.md#expression) describes. The targets are `off`, `amp`, `level`, `main`, `size`, `density`, `position` and `cutoff`; E3 offers `position` on a buffer voice only, and on any other voice a target left at `position` does nothing. Scenes and PSETs keep all four. Nothing sends pressure or slide yet: 3.5's MIDI input will
- **variation** - reverse, pitch, pan and size jitter, intervals, interval probability and quantize (see [Voices and Granular Processing](../voices-and-grains.md))
- **filter & sends** - the voice's own filter (type, freq, res, mix; mix 0 leaves it out), its delay and reverb sends (see [Global Controls and Effects](../effects.md)), then `mute` and `solo` (off/on; see [Mute and solo](../voices-and-grains.md#mute-and-solo))

### Bookmarks

A voice reading a buffer has an eighth section, **bookmarks**: four rows, `bookmark 1` to `bookmark 4`, each a position in the buffer (0-1 of its length, default 0, 0.25, 0.5 and 0.75). E3 edits one like any row. A row only sets its position (as a grid's store key does); a bookmark is recalled with BUFFER's `bm` field (E3, no grid needed: see [BUFFER](buffer.md)) or a grid's bookmark keys, or by a pattern step's bookmark lock ([Sequencer](../sequencer.md)). See [Voices and Granular Processing](../voices-and-grains.md#bookmarks).

### Freeze

E3 on the freeze row turns it on or off. A frozen voice's grains keep playing what they were playing, while pitch, spread, grain size and density still move:
- **a synth voice**: the last 4 seconds of its synth, which stops being recorded. Its buffer scan moves backward through those 4 seconds and around again (a synth voice has no scan row here or on the grid: set `v<i>_buf_scan` in the PARAMS menu, or point an LFO at `v<i> scan`);
- **an input voice**: the 4 seconds of input up to where it was playing (its history), so freezing never jumps to the present. The input keeps recording; unfreezing goes back to it. Its buffer scan moves backward through those 4 seconds and around again, as for a synth voice (an input voice has no scan row either: set `v<i>_buf_scan` in the PARAMS menu, or point an LFO at `v<i> scan`);
- **a buffer voice**: its scan stops at the current position.

Frozen grains play from about half a second before the moment you froze. `spectral` (high setting only) holds one sound spectrum instead and keeps granulating it; on the standard setting, and for a buffer voice, freeze always holds. Changing the voice's source unfreezes it. Scenes save freeze and its mode, but never the audio: a recalled frozen scene freezes whatever the voice plays at the end of the transition. Randomize and mutations never change it. Map it to a MIDI CC in PARAMS > MAP. On the grid it has keys on the 256, 128h and 128v layouts ([Grid](../grid.md)).

Each value is the parameter's own text with its unit, shortened when it does not fit beside its name. The row under the cursor is bright.

- **E2** - Move the cursor; past a section's last row it goes on into the next section
- **E3** - Adjust the row under the cursor (ALT+E3 in finer steps)
- **K2** - Jump to the previous section's first row (in the first section, to its first row)
- **K3** - Jump to the next section's first row
- **ALT+K2** - Randomize the section under the cursor, when you let go of K2. Press it again within 5 seconds, in the same section of the same voice, to undo it (the synth section of a buffer voice counts as a section of its own, so after switching the source between the synth and a buffer, the press randomizes what the section shows). Hold it longer than half a second to reset the row under the cursor to its default instead
- **ALT+K3** - Lock or unlock the voice (as on MAIN: a locked voice is skipped by randomize and mutations)

The hint row shows `K2:prev K3:next`. With ALT (K1 held) it shows `K2:rand`, `K2:undo` while a quick press would undo, or `K2:locked` on a locked voice (whose rows a quick press leaves alone), then `K3:lock` or `K3:unlock`. Once ALT+K2 has been held half a second it shows `K2:reset`, and letting go resets the row (a locked voice's too).

### Randomize

A quick ALT+K2 changes only the section the cursor is in, within ranges that keep the voice playable. It never changes the level, the source or anything that rewires the voice:
- **synth** - every synth parameter across its range, as MAIN's randomize does. A buffer voice: its position, its rate (0.5-2, as many octaves down as up) and its scan (-0.5 to 0.5), then a loop start (0-0.75) and a loop length that fits after it (at least 0.05)
- **input** - the history, from 0 to its top
- **grain** - size (0.05-0.35), density (2-40), pitch (0.5-2.5), spread (0-0.6) and the envelope. The mode stays
- **crossmod** - the speed (0.2-10 Hz) and each slot's amplitude and frequency amounts (-0.5 to 0.5). The sources stay
- **mix** - the pan (-0.8 to 0.8). The Sub has no pan, so the press does nothing there. The source, level, freeze and freeze mode stay
- **notes** - the four expression rows: each target a choice the voice offers (never `off`, and `position` on a buffer voice only) and each depth across -100 to +100 %. The note cap stays
- **variation** - reverse (0-50 %), pitch jitter (0-6 st), pan and size jitter (0-0.5) and interval probability (0-100 %). The intervals, the custom intervals and quantize stay
- **filter & sends** - the filter's type, freq (100-8000 Hz) and res (0-0.7), and both sends (0-60 %). The filter's mix stays, so a filter left out stays out
- **bookmarks** - four new positions, in order: bookmark 1 is the lowest

There is one undo for the whole script: a randomize on another page, in another section or of another voice replaces it, and so does editing a parameter it changed. See [Screen Controls](../controls.md#alt-k1-held).

When the voice's source changes (from the grid, MIDI, a scene or the mix section itself) the sections change with it. The cursor stays on its parameter when the new sections still have it (grain pitch stays on grain pitch when the synth section goes), and otherwise moves to the nearest row. Selecting another voice keeps the cursor on the same parameter of that voice where it has one, and a change and back (input and back to synth, another voice and back) returns it to where it was.

**Arc.** While an arc is connected, a short mark at the left edge shows the rows its four rings edit: the cursor's group of four rows (rows 1-4, 5-8, ... of the voice's list, counting only parameter rows). The arc's button starts or stops the selected voice. See [Monome Arc](../arc.md).

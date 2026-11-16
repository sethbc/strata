## Must not break

- The editor shows over the page only through `S.lib.ui_modal` (`push` at `open`, `pop` at `close`); it is opened only by K3 on BUFFER's `slices` field (and by layout states and tests), and `open(slot)` refuses (returns false, pushes nothing) a slot with no audio (`S.lib.samples.settings(slot)` nil).
- It keeps no slice or setting of its own. Markers change only through `S.lib.slices.add_marker`, `delete_marker` and `nudge_marker`; the file's settings only through `S.lib.samples.set` and `set_bars`; slices are made again only through `S.lib.slices.make`. It reads `S.lib.slices.markers`, `count`, `analyzing`, `playing`, `SLICES.max`, `S.lib.samples.settings`, `bars`, `gain`, `SAMPLES` (`modes`, `tempo_min`, `tempo_max`), `S.lib.waveforms.frames`, `rate` (48 kHz without it), `bins` and `S.lib.playheads.position`, `has_audio`, `moving`. It sends no engine command.
- The first marker (frame 0) is never nudged or deleted.
- A nudge is `round(d × nudge_seconds × rate)` frames (`nudge_seconds` 0.001, ALT `fine_nudge_seconds` 0.0001; half away from 0, so 4.8 is 5 and -4.8 is -5); a nudge of 0 frames sends nothing.
- A change that makes the slices again (the mode, or the amount in `equal` or `transients`) flashes `edits dropped` when the record was `edited` before it. In `off` the amount sets `count` and makes nothing.
- The MIDI key: the note hook (`S.register_note_hook`, `slice editor`, its `heard`: every MIDI note a voice receives, before the slice filter, so a note outside a slicing voice's slices too, design §3.7) only notes the note's number while the editor is open on the `key` row; the next 48 Hz step (`S.lib.lfos.on_step`) sets it through `S.lib.samples.set`, so a hook sends nothing. A close forgets a noted key.
- The slot emptied under the editor closes it: its listener on `S.lib.samples.on_bind` (registered once, at the first open, behind `binds_heard`) closes the editor when its slot's bind leaves no settings record.
- The modules it reads (`S.lib.slices`, `S.lib.samples`, `S.lib.waveforms`) are read at each use and never checked to be there: a missing module or function fails loudly. The amount's bounds are the file settings' (`S.lib.samples.SAMPLES.count_min`, `count_max` and `sensitivity_max`, the bounds `S.lib.samples.set` checks): no copies.
- The hint row fits 128 px: `K2:back K3:add E3:nudge` (the other modal editors' style; E2's pick shows as the bright `slice i/n`), with ALT `E2 rows E3 fine K3 delete`; rows `E2 slices E3 edit K2 back`, with ALT `E2 rows E3 edit`. A "hints" flash (BUFFER's, `buffer_page_flash`) shows in their place.

## Owns

- `lib/ui/slice_editor.lua` (`S.lib.ui_slice_editor`, 3.7 design §3.7, decision 14): `EDITOR` (the tunables, `layout`, `levels`, `flashes`), `open(slot)`, `close()`, `is_open()`, `state()` (`{slot, marker, view, row}`), `pick_marker(d)`, `pick_row(name)`, `nudge(d, fine)`, `add()`, `delete()`, `turn_row(name, d)`, `amount_range(record?)`, `tempo_range()`, `ring_fractions()`, BUFFER's `slot_text(slot)` and `starts(slot)`, and `owner` (whose `arc_delta` and `arc_redraw` `lib/arc/buffer.lua` sets, `docs/notes/lua/arc-pages.md`). Its unit tests: `test/unit/ui_slice_editor_test.lua` (with `h.slice_doubles`' editor doubles, set as fields of the real `S.lib.slices`, `S.lib.samples` and `S.lib.waveforms`).
- No clock, cleanup step or registry of its own: a note hook and an `on_step` function.

## Views and controls

- Markers view (where `open` starts, on marker 1): E2 picks a marker (clamped); E3 nudges it, ALT+E3 finely; K3 (press) adds a marker at the selected voice's playhead (`S.lib.playheads.position`) when the voice reads the slot and runs, else at the middle of the selected slice (to the next marker, or the slot's frames for the last); ALT+K3 deletes the selected marker and selects the one before. After a nudge or an add the marker nearest the frame meant is selected. An add that leaves the count as it was flashes `64 slices max` at `SLICES.max` markers, else `too close`. ALT+E2 enters the rows view on the row last picked.
- Rows view: ALT+E2 picks a row of `EDITOR.rows` (`mode`, `amount`, `tempo`, `bars`, `key`, `norm`), E3 turns it, E2 goes back to the markers; K3 does nothing.
  - `mode`: 1-3 of `SAMPLES.modes`, then `make`.
  - `amount`: `sensitivity` 0-100 in `transients`, else `count` `SAMPLES.count_min`-`count_max` (2-64), then `make` (not in `off`).
  - `tempo`: 0.1 a detent, at most `tempo_max`; below `tempo_min` it clears (nil); from nil a turn up sets the clock's tempo (`clock.get_tempo()`, rounded to 0.1, clamped), a turn down does nothing.
  - `bars`: each detent tries the counts of `EDITOR.bars` (1/4 to 32) beyond the current one in its direction through `set_bars`, taking the first whose tempo it accepts; none: it stops.
  - `key`: unset, then 0-127; from unset a turn up starts at `S.lib.notes.NOTES.rate_root_note` (60), a turn down does nothing (`musicutil.note_num_to_name(key, true)`: norns' names, 60 is `C3`, so C-2 to G8, as the zones editor's).
  - `norm`: up on, down off; on shows `S.lib.samples.gain(slot)` as `%+.1fdB`.
- K2 (press, no ALT) closes. `animates()` while `S.lib.playheads.moving(slot)` or the slot is `analyzing`.

## Layout

`EDITOR.layout` and `EDITOR.levels`:
- The title on y 16: `buf <n>` at x 0 (15), `slices` right-aligned at x 127 (10).
- Marker ticks: 1x3 px at y 18-20 at `x = floor(marker / frames × 128)` (clamped 0-127), the selected one 15, the others 6, drawn over the playing slices' spans: a line on y 20 at 12 from a slice's start to one pixel before the next marker (or the end), for every slice `S.lib.slices.playing(v)` lists for a voice reading the slot.
- The waveform: the slot's 64 points (`bins(slot, 64)`), each a 2 px wide filled rect from x `2(k - 1)`, half-height `round(peak × 5)` around y 27 (y 22-32), at 6; no peaks: a flat line on y 27 at 1.
- The selected voice's playhead (while it reads the slot, which has audio, and runs): a line from y 22 to 32 at 15.
- Four lines of two fields (`mode`/`amount`, `slice`/`at`, `tempo`/`bars`, `key`/`norm`), three in view from y 41, 7 apart (41, 48, 55), through `S.lib.ui_field_list.draw` with the cursor on the slice line (markers view) or the picked row's line, so one line above it stays in view; the scroll marker at x 127. Left field: label at x 0, value right-aligned at x 68; right field: label at x 72, value right-aligned at x 124. The picked field (rows view) or the slice line (markers view): label 10, value 15; the rest: label 3, value 8 (a label dimmer than its value, so a line's two fields read apart). `analyzing` replaces the slice field's label and value while the slot is analyzed. Values: `off`/`equal`/`transients`; `count` `64` or `sens` `100%`; `5/12`; `2.410s` (to the millisecond below 100 s, `295.31s` from it); `120.0` or `--`; `1/4`, `1/2`, whole bars, else `1.50`; `C#-2` or `--`; `off` or `+24.1dB`.
- The widest values (`transients` beside `mode`, `C#-2`, `+24.1dB`, `295.31s`) fit with at least 3 px between label and value. BUFFER's layout states draw the editor (`slice editor <name>`): 1, 12 and 64 markers (the last on the 300 s tier), analyzing, the full and edits dropped flashes, and each row picked at the widest values (`LAYOUT.widest_slices`); they always draw the editor (a missing module raises).

## BUFFER's slices field and marks

`slot_text(slot)`: `--` (no audio), `off`, else `EDITOR.short_modes[mode]` and `S.lib.slices.count(slot)` (`eq 12`, `tr 64`: `tran 64` would cut BUFFER's `slices` label). `starts(slot)`: the markers over the slot's frames, nil with fewer than two; BUFFER draws one pixel per column on y 10 (`docs/notes/lua/pages/buffer.md`).

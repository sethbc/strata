## Must not break

- The page has no clock of its own: its record's `animates` (`any_lfo_running`) is true while any of the six LFOs runs (in the window or not), so `draw_frame` marks the screen dirty on every frame then (15 fps) and the dots move; with all six off an idle frame draws nothing (#423). Everything else it shows asks for a redraw when it changes (every param action through `redraw_on_param_changes`, `enc`, `key`, the rings), turning the last LFO off included. `cleanup` stops the frame clock with `stop_frame_clock()`.
- The rows are a window of three (`S.lib.lfos.window(S.selected_lfo)`, the first of `selected - 1`, clamped to 1..`NUM_LFOS - 2`): LFOs 1-3 with LFO 1 or 2 selected, 4-6 with 5 or 6. `row_top(n)` is nil outside the window and nothing draws there.
- The dot's height follows the depth the LFO plays: it swings around the row's middle line by `value / 2 × effective_depth / 100` of the wave's height, so at depth 0 it sits on the line (#520). A free engine-run LFO's dot is Lua's estimate of the engine's phase (the engine is never resynced), so it is drawn hollow (a stroked 3×3 rect); every other dot is filled.
- Changing `S.selected_lfo` goes through `select_lfo` (K2/K3, MOD's K3 through `show_lfo`): it forgets ring 4's carried ticks (`lfo:4`) on any change and the depth rings' (`lfo:1`-`lfo:3`) when the window moves; a selection inside the window keeps theirs.
- Every E3 edit goes through `enc_param_delta(3, id, d)` (center detents, ALT+E3 fine on the rate), except the on/off field, ALT+E3 on the destination and ALT+E3 on a percent (whole steps through `delta_with_detent`: a fine step of a one-percent control rounds back).
- Turning an LFO on or off from the page (ALT+K3, E3 on the on/off field, ALT+K2 held on it, the arc button) goes through `set_lfo_running`, `set_binary_param` (#538).
- `lfo_dest_group_starts()` is derived from `S.LFO_DESTINATIONS`, never hardcoded: an index whose entry's `group` differs from the one before starts a group, so each registration's seven voices are one (#511) and the global registrations one after them (#580). Groups only add jump targets.
- The strip measures with `screen.text_extents`, so it fits whatever the real font draws; the layout tests use the stub's widths (`stubs.text_width`, norns' font advances).
- Rows and strip stay between y 10 and 56 (above the hint row's glyphs) for every selected LFO: `LFO_PAGE.row_first_y` 11, `row_spacing` 13, `strip_height` 8.
- Rows are 13 px apart so the right-hand column keeps a blank pixel row between its strings: a destination (baseline top + 4) sits 6 px under the row above's `on|off` text, and 7 px over its own, which its descender clears (#422).
- The wave ends at x 63 (`wave_x` 12, `wave_width` 52) so the window mark (`mark_x` 66, the first row's lower line) ends before the widest state text (`off 100% R`, from x 82).
- The routed mark reads `S.lib.matrix` defensively (`S.lib.matrix and S.lib.matrix.uses_source("lfo" .. n)`): the matrix (package 1h) may not be loaded.

## Owns

- `lib/pages/lfo.lua` (`S.lib.pages_lfo`): the LFO record, `redraw_lfo`, `lfo_wave_value`, `lfo_dest_group_starts`, `lfo_dest_group_jump` (global); `lfo_running`, `select_lfo_by`, `show_lfo`, `row_top`, `strip_y`, `layout` (`LFO_PAGE`) as module fields; `LFO_FIELDS`, `set_lfo_running`, `select_lfo`, `strip_view`, `any_lfo_running`, `routed` (local). The strip cursor `S.lfo_field`.
- The LFOs themselves (`S.selected_lfo`, `S.LFO_DESTINATIONS`, the phase, value, rates and depths) are `lib/lfos.lua`'s (`docs/notes/lua/lfos.md`).
- Its unit tests: `test/unit/pages_lfo_test.lua`. Its rings: `lib/arc/lfo.lua` (`docs/notes/lua/arc-pages.md`).

## The page

Rows (`draw_lfo_row`, for the window's three LFOs):
- `row_top(n)` = `row_first_y` (11) + (n - first) × `row_spacing` (13), plus `strip_height` (8) for the rows under the selected LFO.
- `L<n>` at x 0 (baseline top + 7; level 15 for the selected LFO, 4 otherwise).
- One cycle of the shape as a 52-px polyline from x 12 to 63: value 1 at the row top and 0 at top + 10, level 6 running / 2 off, from `lfo_wave_value(shape, phase)`: the deterministic shapes as `S.lib.lfos.shape_u` plays them, a random shape's wave is a fixed picture of its kind, never a trace of its values (`LFO_PAGE.random_displays`: s&h two steps, smooth a curve, drunk a wander, as 3.3 drew its random shape), and the dot is the value the LFO plays (Lua's draws; an engine LFO draws its own, of the same kind).
- While the LFO runs and has stepped, a 3×3 dot at x = 12 + `phase(n)` × 51, y = bottom - (0.5 + value / 2 × depth' / 100) × 10, filled, or stroked for a free engine-run LFO.
- The window mark (`1-3`, `2-4`, `3-5`, `4-6`) at x 66 on the first row's lower line (top + 11), level 4.
- Right-aligned at x 127: the destination label with `~` when it runs in the engine (`S.lib.lfos.label(n)`, baseline top + 4) and `on|off <depth>%`, then ` R` while the matrix routes the LFO (top + 11).

The strip (`draw_strip`), at baseline `strip_y()` = `row_top(S.selected_lfo)` + 18:
- `LFO_FIELDS` in order, each a label (the hint), `param(n)`, `value(n)` and `whole` for a percent: `dest` (`v3 pitch~`), `shape`, `mode`, `rate` (`0.25Hz` by `%.3gHz`, or the division in clocked mode, and ` max` while it runs in Lua above 10 Hz: `S.lib.lfos.capped`), `depth` (`25%`), `offset` (`+20%`), `phase` (`ph 30%`), `rate mod` (`rmod L1`), `rate amt` (`ramt -40%`), `depth mod` (`dmod none`), `depth amt` (`damt +15%`), `on/off`.
- `strip_view(widths, cursor, marker_width)`: the smallest first field such that the fields from it to the cursor fit, packing `strip_gap` (6) apart from x 0 (or after a `<` and a gap when first > 1), each field before the last needing room for a gap and `>` before `strip_right` (127). The cursor's field at level 15, the others and the markers at 4.

Input:
- E2 moves `S.lfo_field` (1-12, clamped). E3: `enc_param_delta(3, field.param(S.selected_lfo), d)`; the on/off field turns the LFO on for d > 0, off for d < 0; the rate field edits the rate (free) or the division (clocked).
- `alt_enc`: on the destination, `lfo_dest_group_jump` once per detent; on a percent field, whole steps; elsewhere it returns false, so `enc` runs with ALT held (fine on the rate, whole steps on an option).
- `lfo_dest_group_jump(index, d)`: the first start above `index` (d > 0) or the last start below it (d < 0); `index` itself when there is none. 3.4's starts are 1, 2, 13, 21, ..., 61, 69, 76, 83, 90, 97, then 104 for the global registrations.
- K2/K3: `select_lfo_by(-1|1)`, clamped to 1..`NUM_LFOS`.
- `alt_key`: ALT+K2 calls `S.lib.ui_alt.k2_down` and acts on release (`alt_key_release` calls `k2_up(record)`, #557); ALT+K3 toggles the selected LFO. A quick release runs `randomize_section`: the selected LFO's shape (any of the eight), its rate (free: `0.05 × 200 ^ random()`, even in octaves over 0.05-10 Hz) or division (clocked: any of the 22), and its phase (a whole 0-100); destination, mode, depth, offset, on/off and the four mod params are kept, so a running LFO keeps running. The section is `lfo <n> free` or `lfo <n> clocked` and the voice nil: each LFO holds its own undo, a mode switch drops the undo of the rate no longer shown, and no voice's mutation ends it. `alt_hold` sets the field's param to `param_default(id)`. `animates` is also true while ALT+K2 is down, for the `K2:reset` hint. `arc_button` is the same toggle.
- Hints: `K2/K3:lfo E3:<label>`; with ALT `K2:rand|undo|reset K3:on|off`, plus ` E3:group` on the destination field (`K2:reset K3:off E3:group` is the longest). With K1 let go while ALT+K2 is down, `k2_hint(record)` alone.
- `show_lfo(n)` (MOD's K3 on an LFO row): selects LFO n and shows the page.
- `layout_states`: each field as cursor on LFOs 1 and 6 at their widest (`lfo1 dest` ... `lfo6 on/off`), each window (`window 1-3` ... `window 4-6`), `engine-run and modulated`, `rate max`, `clocked` (1/16), the three `descender` states (#422) and `ALT+K2 held past the hold time`.

## Must not break

- The page has no clock of its own: `draw_frame` marks the screen dirty on every frame while it is shown (15 fps), so the dots move. `cleanup` stops the frame clock with `stop_frame_clock()`.
- Changing `S.selected_lfo` (K2/K3) calls `forget_arc_ticks("lfo:4")`, so ring 4's carried ticks never step another LFO's clocked rate. Only a real change forgets them (K3 on LFO 3 forgets nothing); the depth rings' keys (`lfo:1`-`lfo:3`) are never forgotten here.
- Every E3 edit goes through `enc_param_delta(3, id, d)` (center detents, ALT+E3 fine on a control param), except the on/off field and ALT+E3 on the destination.
- Turning an LFO on or off from the page (ALT+K3, E3 on the on/off field, ALT+K2 on it, the arc button) goes through `set_lfo_running`, which puts `lfo_offset_<n>` back: the library's state action re-bangs the baseline, and its `change_offset` sets the offset to 0. Never `params:set("lfo_<n>", ...)` directly from the page.
- `lfo_dest_group_starts()` is derived from `S.LFO_DESTINATIONS` and `NUM_VOICES` (none, the first global, then `v1 main` and every `per_voice` after it), never hardcoded. Adding a global destination or a per-voice destination keeps it right as long as the voice destinations stay last, `v1 main` first, the same number per voice.
- The strip measures with `screen.text_extents`, so it fits whatever the real font draws; the layout tests use the stub's estimate (`stubs.text_width`), which is wider, so the device shows at least as many fields as the renders.
- Rows and strip stay between y 10 and 56 (above the hint row's glyphs) for every selected LFO: `LFO_PAGE.row_first_y` 12, `row_spacing` 12, `strip_height` 8. The rows test in `test/unit/pages_lfo_test.lua` checks it.

## Owns

- `lib/pages/lfo.lua` (`S.lib.pages_lfo`): the LFO record, `redraw_lfo`, `lfo_shape_value`, `lfo_dest_group_starts`, `lfo_dest_group_jump` (global); `lfo_running`, `row_top`, `strip_y`, `layout` (`LFO_PAGE`) as module fields; `LFO_FIELDS`, `set_lfo_running`, `select_lfo_by`, `strip_view` (local). The strip cursor `S.lfo_field`.
- The LFOs themselves (`S.lfos`, `S.selected_lfo`, `S.LFO_DESTINATIONS`, `S.lfo_last_raw`, `lfo_phase_estimate`) are `lib/lfos.lua`'s (`docs/notes/lua/lfos.md`), as is the 25 % default depth.
- Its unit tests: `test/unit/pages_lfo_test.lua`. Its rings: `lib/arc/lfo.lua` (`docs/notes/lua/arc-pages.md`).

## The page

Rows (`draw_lfo_row`):
- One row per LFO. `row_top(n)` = `LFO_PAGE.row_first_y` (12) + (n - 1) × `row_spacing` (12), plus `strip_height` (8) for the rows under the selected LFO.
- `L<n>` at x 0 (baseline top + 7; level 15 for `S.selected_lfo`, 4 otherwise).
- One cycle of the shape as a 64-px polyline from x `wave_x` (12) to 75: value 1 at the row top and 0 at top + `wave_height` (10), level 6 running / 2 off, from `lfo_shape_value(shape, phase)` (a mirror of the library's shape math; random is drawn as two held steps).
- While the LFO runs and has sent a value, a 3×3 dot at x = 12 + `lfo_phase_estimate(n)` × 63, y from `S.lfo_last_raw[n]`.
- Right-aligned at x 127: the destination label (baseline top + 5) and `on|off <depth>%` (top + 11).

The strip (`draw_strip`), at baseline `strip_y()` = `row_top(S.selected_lfo)` + `strip_baseline` (18):
- `LFO_FIELDS` in order: `dest` (`strata_lfo<n>_dest`, its label), `shape` (`lfo_shape_<n>`), `mode` (`lfo_mode_<n>`), `rate` (`lfo_free_<n>` as `%.1fs`, or `lfo_clocked_<n>`'s option string in clocked mode: the field's param follows the mode), `depth` (`lfo_depth_<n>`, `%.0f%%`), `offset` (`lfo_offset_<n>`, signed `+20%`), `on/off` (`lfo_<n>`). Each has a label (the hint), `param(n)` and `value(n)`.
- `strip_view(widths, cursor, marker_width)`: the smallest first field such that the fields from it to the cursor fit, packing `strip_gap` (6) apart from x 0 (or after a `<` and a gap when first > 1), each field before the last needing room for a gap and `>` before `strip_right` (127). The cursor's field at level 15, the others and the markers at 4; `>` right-aligned at 127.
- Offset: norns' LFO library (`lua/lib/lfo.lua` in norns) adds `(max - min) × offset` to `scaled`, and `apply_lfo` sends `scaled` × half the destination's range, so a 20 % offset moves the destination by 20 % of its range.

Input:
- E2 moves `S.lfo_field` (1-7, clamped). E3: `enc_param_delta(3, field.param(S.selected_lfo), d)`; the on/off field turns the LFO on for d > 0, off for d < 0.
- `alt_enc`: on the destination, ALT+E3 applies `lfo_dest_group_jump` once per detent and returns true; on any other field it returns false, so `enc` runs with ALT held (fine on the free period, whole steps on number and option params).
- `lfo_dest_group_jump(index, d)`: the first start above `index` (d > 0) or the last start below it (d < 0); `index` itself when there is none. Today the starts are 1, 2, 13, 21, ..., 61.
- K2/K3: `select_lfo_by(-1|1)`, clamped to 1..`NUM_LFOS`.
- `alt_key`: ALT+K2 sets the field's param to `param_default(id)` (depth 25, destination none, free period 4 s, offset 0, on/off off); ALT+K3 toggles the selected LFO. `arc_button` is the same toggle.
- Hints: `K2/K3:lfo E3:<label>`; with ALT `K2:reset K3:on|off`.
- `layout_states`: `lfo1`-`lfo3` (each selected, running, on the last destination), `field-dest` ... `field-state` (LFO 2 with wide values: v7 scan, random, 300 s, 100 %, -50 %), `clocked` (LFO 3 at `5/16`), `free` (LFO 1 at 0.1 s).

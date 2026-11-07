## Must not break

- The page has no clock of its own: `draw_frame` marks the screen dirty on every frame while it is shown (15 fps), so the dots move. `cleanup` stops the frame clock with `stop_frame_clock()`.
- Changing `S.selected_lfo` calls `forget_arc_lfo_period_ticks()`, so ring 4's carried ticks never step another LFO's clocked rate.
- E3 edits the depth through `enc_param_delta` (whole percents: a number param).

## Owns

- `lib/pages/lfo.lua` (`S.lib.pages_lfo`): the LFO record, `redraw_lfo`, `lfo_enc`, `lfo_key`, `lfo_hints`, `lfo_shape_value` (global); `LFO_PAGE` (local).
- The LFOs themselves (`S.lfos`, `S.selected_lfo`, `S.LFO_DESTINATIONS`, `S.lfo_last_raw`, `lfo_phase_estimate`) are `lib/lfos.lua`'s (`docs/notes/lua/lfos.md`).
- Its unit tests: `test/unit/pages_lfo_test.lua`. Its rings: `lib/arc/lfo.lua` (`docs/notes/lua/arc-pages.md`).

## The page

`redraw_lfo`, `lfo_enc`, `lfo_key`:
- One row per LFO. Row top = `LFO_PAGE.row_first_y` (16) + (n - 1) × `LFO_PAGE.row_spacing` (15), so rows fill y 16-57.
- `L<n>` at x 0 (baseline top + 7; level 15 for `S.selected_lfo`, 4 otherwise).
- One cycle of the shape as a 64-px polyline from x `LFO_PAGE.wave_x` (12) to 75: value 1 at the row top and 0 at top + `LFO_PAGE.wave_height` (10), level 6 running / 2 off, from `lfo_shape_value(shape, phase)` (a mirror of the library's shape math; random is drawn as two held steps).
- While the LFO runs and has sent a value, a 3×3 dot at x = 12 + `lfo_phase_estimate(n)` × 63, y from `S.lfo_last_raw[n]`.
- Right-aligned at x 127: the destination label (baseline top + 5) and `on|off <depth>%` (top + 11).
- Hints `E3:depth K2:dest K3:on|off`. No ALT keys yet.
- E2 selects `S.selected_lfo`, E3 `enc_param_delta(3, "lfo_depth_<n>", d)` (percent), K2 steps `strata_lfo<n>_dest` (wrapping to none), K3 toggles `lfo_<n>` between 1 and 2.

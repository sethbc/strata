## Must not break

- E3 edits through `enc_param_delta` (never `params:delta`), so ALT+E3 is fine and the center detents apply.
- K3's restore value is `S.fx_last_mix[effect]` (filter, delay, reverb), which each mix param's action records whenever the mix is set above 0, however it was set (E3, PARAMS, scenes, K3). Never record it from the page alone.
- Section labels (`selectable = false` rows) take no cursor stop: always move through `S.lib.ui_field_list` (`move`, `clamp`), and clamp `S.fx_row` before use.
- K3 acts on the effect of the row under the cursor (`row.effect`); master rows (density, drift) do nothing, and their hint is `E3:value`.
- Every row stays inside 128×64 at both ends of its range and every row position (the FX layout test and `layout_states`).

## Owns

- `lib/pages/fx.lua` (`S.lib.pages_fx`): the FX record, `redraw_fx`, `fx_enc`, `fx_key`, `fx_hints`; `S.FX_PAGE` (rows and layout), `S.fx_row` (the selected row, an index into `S.FX_PAGE.rows`).
- `S.fx_last_mix` (per effect: filter, delay, reverb) is set up in `lib/params_setup.lua` (`docs/notes/lua/params.md`).
- Its unit tests: `test/unit/pages_fx_test.lua`. Its rings: `lib/arc/fx.lua` (`docs/notes/lua/arc-pages.md`).

## The page

`redraw_fx`, `fx_enc`, `fx_key`:
- `S.FX_PAGE.rows`: four section labels (master, filter, delay, reverb; no `param_id`, `selectable = false`, drawn at level 2 at x=0) and 12 param rows `{label, param_id, format, effect}`: density, drift; filter type/freq/res/mix; delay time/fdbk/mix; reverb mix/size/damp. `format` is a `string.format` pattern, a function of the value (`percent`), or nil for the param's own string.
- Filter mix, delay feedback and mix, reverb mix and damping show in percent (`50%`).
- `S.FX_PAGE.visible_rows` (5) rows at y=18-50 (`first_row_y` 18, `row_spacing` 8), drawn through `S.lib.ui_field_list.draw`. Param labels at x=6, value right-aligned at x=124. The selected row at level 15, the others at 4. The view keeps one row above the cursor. A 1 px scroll marker at x=127 (from the helper).
- E2 moves over selectable rows (clamped), E3 is `enc_param_delta(3, <row param>, d)`.
- K3 toggles the cursor row's `<effect>_mix` between 0 and `S.fx_last_mix[effect]` (initially filter 1, delay 0.3, reverb 0.3).
- Hint: `K3:<effect> bypass` when that mix is above 0, else `K3:<effect> on`; master rows `E3:value`.
- `layout_states`: first row, last row at maximum values, filter freq at 20000 Hz.

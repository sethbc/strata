## Must not break

- E3 edits through `enc_param_delta` (never `params:delta`), so ALT+E3 is fine and the center detents apply.
- K3's restore value is `S.fx_last_mix.filter`, which the `filter_mix` param action records whenever the mix is set above 0, however it was set (E3, PARAMS, scenes, K3). Never record it from the page alone.
- Every row stays inside 128×64 at both ends of its range and every row position (the FX layout test).

## Owns

- `lib/pages/fx.lua` (`S.lib.pages_fx`): the FX record, `redraw_fx`, `fx_enc`, `fx_key`, `fx_hints`; `S.FX_PAGE` (rows and layout), `S.fx_row` (the selected row).
- `S.fx_last_mix` (per effect: filter, delay, reverb) is set up in `lib/params_setup.lua` (`docs/notes/lua/params.md`).
- Its unit tests: `test/unit/pages_fx_test.lua`. Its rings: `lib/arc/fx.lua` (`docs/notes/lua/arc-pages.md`).

## The page

`redraw_fx`, `fx_enc`, `fx_key`:
- A scrolling list of `S.FX_PAGE.rows` (`{label, param_id, format}`; `format` is a `string.format` pattern, or nil for the param's own string): density, tape drift, filter type/freq/res/mix, delay time/fdbk/mix, reverb mix/size/damp.
- `S.FX_PAGE.visible_rows` (5) rows at y=18-50 (`first_row_y` 18, `row_spacing` 8). Label at x=0, value right-aligned at x=127. The selected row (`S.fx_row`) at level 15, the others at 4. The view keeps one row above the selection.
- E2 selects the row (clamped), E3 is `enc_param_delta(3, <row param>, d)`.
- K3 toggles `filter_mix` between 0 and `S.fx_last_mix.filter` (initially 1).
- Hint: `K3:filter bypass` when the mix is above 0, else `K3:filter on`. No ALT keys yet.

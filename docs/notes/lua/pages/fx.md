## Must not break

- E3 edits through `enc_param_delta` (never `params:delta`), so ALT+E3 is fine and the center detents apply.
- K3 on a delay or reverb row toggles that effect's bypass param (`delay_bypass`, `reverb_bypass`, `S.lib.voice_mix.BYPASS`) through `params:set` and never touches its mix; only that param frees the engine node. K3 on a filter row keeps 3.1's mix toggle (the filter is never freed).
- The filter's restore value is `S.fx_last_mix.filter`, written only in `lib/params_setup.lua`: `filter_mix`'s action sets it when the mix rises above the mix before (E3, PARAMS, scenes, PSET), and `S.lib.params_setup.toggle_filter_mix()` sets it to the mix at the press before turning a mix above 0 to 0. Never write it from the page. K3 on a filter row calls `toggle_filter_mix` and nothing else (#235). The delay and reverb have no restore mix: their bypass params keep it.
- Section labels (`selectable = false` rows) take no cursor stop: always move through `S.lib.ui_field_list` (`move`, `clamp`), and clamp `S.fx_row` before use. Select a row by its param id (the layout states use `row_of`), never by a hard-coded index (#114).
- K3 acts on the effect of the row under the cursor (`row.effect`); master rows (density, drift) do nothing, and their hint is `E3:value`.
- Every row stays inside 128×64 at both ends of its range and every row position, `byp` included (the FX layout test and `layout_states`).

## States

The filter's restore mix (`S.fx_last_mix.filter`, and the mix before the last change, local to `lib/params_setup.lua`, starting at 0). The filter mix itself is a param; no invariant is registered.

| Event | Mix | Restore mix | Mix before |
|-------|-----|-------------|------------|
| `filter_mix` set higher than the mix before (E3, PARAMS, scene, PSET) | x | x | x |
| `filter_mix` set equal or lower (a turn down, a fade, a PSET bang of the same value) | x | unchanged | x |
| K3 (`toggle_filter_mix`) with a mix above 0 | 0 | the mix at the press | 0 |
| K3 with a mix of 0 | the restore mix | unchanged | 0 (the restore starts a new run, so a later turn down below it is the new level) |

Known cost (decision 1): turned down from 80% to 30% and later to 0, K3 restores 80%.

## Owns

- `lib/pages/fx.lua` (`S.lib.pages_fx`): the FX record, `redraw_fx`, `fx_enc`, `fx_key`, `fx_hints`; `S.FX_PAGE` (rows and layout), `S.fx_row` (the selected row, an index into `S.FX_PAGE.rows`).
- `S.fx_last_mix` (only `.filter`) is set up in `lib/params_setup.lua` (`docs/notes/lua/params.md`).
- The bypass params are `lib/voice_mix.lua`'s (`docs/notes/lua/voice-mix.md`).
- Its unit tests: `test/unit/pages_fx_test.lua`. Its rings: `lib/arc/fx.lua` (`docs/notes/lua/arc-pages.md`).

## The page

`redraw_fx`, `fx_enc`, `fx_key`:
- `S.FX_PAGE.rows`: four section labels (master, filter, delay, reverb; no `param_id`, `selectable = false`, drawn at level 2 at x=0; the delay's and reverb's carry `bypass = "<effect>"`) and 12 param rows `{label, param_id, format, effect}`: density, drift; filter type/freq/res/mix; delay time/fdbk/mix; reverb mix/size/damp. `format` is a `string.format` pattern, a function of the value (`percent`), or nil for the param's own string.
- Filter mix, delay feedback and mix, reverb mix and damping show in percent (`50%`).
- A bypassed effect's section row shows `S.FX_PAGE.bypass_text` (`byp`) right-aligned at the value column, at `bypass_level` (4). The mix row keeps showing the mix.
- `S.FX_PAGE.visible_rows` (5) rows at y=18-50 (`first_row_y` 18, `row_spacing` 8), drawn through `S.lib.ui_field_list.draw`. Param labels at x=6, value right-aligned at x=124. The selected row at level 15, the others at 4. The view keeps one row above the cursor. A 1 px scroll marker at x=127 (from the helper).
- E2 moves over selectable rows (clamped), E3 is `enc_param_delta(3, <row param>, d)`.
- K3: on a delay or reverb row, `params:set(<effect>_bypass, 1 - current)`; on a filter row, `S.lib.params_setup.toggle_filter_mix()` (the mix between 0 and `S.fx_last_mix.filter`, initially 1).
- Hint: `K3:<effect> bypass` while the effect is on (delay and reverb: not bypassed; filter: mix above 0), else `K3:<effect> on`; master rows `E3:value`. A delay or reverb mix of 0 is still "on".
- `layout_states`: first row, last row at maximum values, filter freq at 20000 Hz, the delay and reverb both bypassed (cursor on delay time, so both section rows show `byp`).

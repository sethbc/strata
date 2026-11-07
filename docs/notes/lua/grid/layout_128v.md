## Must not break

- Pattern keys (columns 1-7) go through `step_key` with 16 positions down the voice's column, so a step's level follows the row of the second key.
- The layout has one page today: column 8 is its controls.

## Owns

- `lib/grid/layout_128v.lua` (`S.lib.grid_layout_128v`): `grid_key_128v`, `grid_redraw_128v` (global); it registers `S.registry.grid_layouts["128v"]`.
- Its unit tests: `test/unit/grid_layout_128v_test.lua`.

## Keys

- Columns 1-7, rows 1-16: `step_key(port, x, y, z, x, y, y, PATTERN_LENGTH)` (voice = column, step = row).
- Column 8: rows 1-7 `toggle_voice(y)`; row 9 `pattern_toggle()`; rows 10-16 `select_grid_voice(y - 9)`, lit for the selected voice (it matters only for the 256's faders).

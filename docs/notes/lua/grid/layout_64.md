## Must not break

- The 64 shows and edits only steps 1-8 (`math.min(PATTERN_LENGTH, cols)`), but patterns still play all 16; never write steps past the shown ones from this layout.
- Pattern keys go through `step_key` with 8 positions (its column count), so column 8 sets level 15 and column 4 level 8.

## Owns

- `lib/grid/layout_64.lua` (`S.lib.grid_layout_64`): `grid_key_64`, `grid_redraw_64` (global); it registers `S.registry.grid_layouts["64"]`.
- Its unit tests: `test/unit/grid_layout_64_test.lua`.

## Keys

- Rows 1-7: `step_key(port, x, y, z, y, x, x, visible_steps)` with `visible_steps = math.min(PATTERN_LENGTH, S.grids[port].cols)` (8).
- Row 8: column 1 `pattern_toggle()`; columns 3-7 toggle voices 1-5.

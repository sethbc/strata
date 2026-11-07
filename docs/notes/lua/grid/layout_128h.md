## Must not break

- Pattern keys (rows 1-7 on pages 1 and 2) go through `step_key` (16 positions, the column) and scene save keys (page 3, row 3) through `scene_save_key`, as on the 256.
- Row 8 works on every page.
- Page 2 has no faders yet: it draws and acts as the patterns page.

## Owns

- `lib/grid/layout_128h.lua` (`S.lib.grid_layout_128h`): `grid_key_128h`, `grid_redraw_128h` (global); it registers `S.registry.grid_layouts["128h"]`.
- Its unit tests: `test/unit/grid_layout_128h_test.lua`.

## Keys

- Rows 1-7 (pages 1 and 2): `step_key(port, x, y, z, y, x, x, PATTERN_LENGTH)`.
- Row 8, every page: columns 1-4 `pattern_toggle()` (all four light while playing); column 5 page 1 (patterns), 6 page 2, 7 page 3 (scenes); columns 9-15 `toggle_voice(x - 8)`; column 16 `select_grid_voice` of the next voice (it matters only for the 256's faders).
- Page 3 (scenes): row 1 instant recall, row 2 recall with the transition time, row 3 `scene_save_key` (0.5 s hold), row 4 sequence length 1-8, row 5 column 1 sequencer on/off.

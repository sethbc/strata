## Must not break

- Pattern keys (rows 1-7 on page 1 only) go through `step_key` (16 positions, the column) and scene save keys (page 3, row 3) through `scene_save_key`, as on the 256. Pages 2, 4 and 5 never toggle steps.
- Row 8 works on every page and is handled before the page's own keys.
- The faders on page 2 use the 256's fader list and mapping (`fader_param_ids`, `fader_page_count`, `set_fader_param`, `grid_redraw_fader_row` from `lib/grid/faders.lua`), four per fader page (`GRID_LAYOUT.fader_rows`), so `S.param_page` means the same page on both layouts. Row 5 accepts only columns up to `fader_page_count(S.grid_voice_select)`.
- Page 4 goes through the core's helpers only (`source_key`/`source_level`, `record_key`/`record_level`, `clear_key`/`CLEAR_LEVEL`) and `S.lib.freeze`, so its keys and LEDs match the 256's page 4. The layout adds no clock, hold or per-port state of its own.
- Page 5 (positions) and page 4's strip go through `S.lib.positions` only (`grid_key`, `strip_key`, `grid_level`, `strip_level`), never `jump`/`set_loop` directly. The layout's `z == 0` early return does not exist: a release reaches `positions.grid_key` (page 5) and `strip_key` (page 4's strip) so held pairs and the store and hold keys end.
- A strip key's release goes to the voice it was pressed for (`port_state(port).strip_voice[key]`), so changing the grid voice while a key is held cannot leave a hold on.
- Pages are per port (`S.lib.grid_core.page(port)` / `set_page`): two 128h grids show and change their own pages.

## Owns

- `lib/grid/layout_128h.lua` (`S.lib.grid_layout_128h`): `grid_key_128h`, `grid_redraw_128h` (global); it registers `S.registry.grid_layouts["128h"]`. Its geometry is the table `LAYOUT_128H` (also `S.lib.grid_layout_128h.LAYOUT`); its helpers are locals.
- Its unit tests: `test/unit/grid_layout_128h_test.lua`.

## Keys

- Row 8, every page: columns 1-4 `pattern_toggle()` (all four light while playing); columns 5-8 `set_page(port, 1..4)` (patterns, faders, scenes, sources; the shown page at 15, others 4); columns 9-15 `toggle_voice(x - 8)` (running 12, stopped 2); column 16 `select_grid_voice` of the next voice, wrapping 7 -> 1 (LED 8).
- Page 1 (patterns): rows 1-7 `step_key(port, x, y, z, y, x, x, PATTERN_LENGTH)`; LEDs from `step_brightness`.
- Page 2 (faders): rows 1-4 `set_fader_param(S.grid_voice_select, (S.param_page - 1) * 4 + row, x)`, drawn with `grid_redraw_fader_row` (bar 8, value 15); row 5 sets `S.param_page` (selected 15, others 4); row 6 columns 1-7 `select_grid_voice` (selected 15, others 4); row 7 columns 1-7 `toggle_lock` (locked 12, others 2).
- Page 3 (scenes): row 1 instant recall, row 2 recall with the transition time, row 3 `scene_save_key` (0.5 s hold, 15 while pending), row 4 sequence length 1-8, row 5 column 1 sequencer on/off.
- Page 4 (sources): rows 1-7, columns 1-10 `source_key(y, x)` (row = voice, column = source option as on the 256's rows 9-15); columns 13-16 hold the slots, four per row: rows 1-2 `record_key` for slots 1-4 and 5-8, rows 3-4 `clear_key` for the same slots. Column 12 is each voice's freeze key (`S.lib.freeze.toggle(y)`; LED 15 frozen, 3 not), as on the 256's page 4. Column 11 and rows 5-7 of columns 13-16 are dark and do nothing.
- Page 5 (positions): reached by pressing the sources key (row 8, column 8) while on page 4; pressed on page 5 it goes back to page 4 (LED 15 on page 4, 10 on page 5). Rows 1-7 are voice v's 16 position cells (`grid_key(port, y, x, 16, z)`, LEDs `grid_level(y, x, 16)`; a press also selects the grid voice). Row 8 is unchanged; columns 5-7 still pick pages 1-3.
- Page 4's strip is the grid voice's (`S.grid_voice_select`): row 5 columns 13-16 bookmarks 1-4, row 6 columns 13 store, 14 hold, 15 whole (`strip_key`, `strip_level`). Column 16 of row 6 and row 7 stay dark. The record keys' armed level (11) is the core's `record_level`.
- Redraws: the faders follow changes made elsewhere through the existing `any_page(2)` and `any_page(4)` redraws (drift, source changes, buffer state), which count every layout's page 2 and 4. FX changes do not redraw it: its page 4 shows no FX (`fx_fader_changed` checks `any_fx_faders()`, and this layout's record has no `fx_faders_page`).

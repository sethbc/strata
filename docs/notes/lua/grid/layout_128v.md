## Must not break

- Pattern keys (columns 1-7 on the patterns page) go through `step_key` with 16 positions down the voice's column, so a step's level follows the row of the second key. No other page edits patterns.
- Column 8 rows 1-7 (voice toggles), row 8 (the page key) and row 9 (play / stop) work the same on every page. Rows 10-16 select the voice on pages 1-3 only; on the positions page they are the strip (see Keys). On the sources page, column 8 is slot 8's record (row 12) and clear (row 13) keys, and its other rows 10-16 do nothing and stay dark.
- The page key cycles 1 → 2 → 3 → 4 → 5 → 1 through `S.lib.grid_core.set_page`, per port, and its LED is `LAYOUT_128V.page_levels[page]` (3, 6, 9, 12, 15). Never keep a page of the layout's own.
- The faders are the 256's faders turned upright: row y sets what the 256's column `17 - y` sets (`set_fader_param`, so warps and zero columns hold), and the LED row of a value is `17 - fader_position(id)`. Four faders per fader page (`GRID_LAYOUT.fader_rows`), so `S.param_page` means the same page on every grid. The page selector lights only up to `fader_page_count`.
- Scene saves go through `scene_save_key` (the 0.5 s hold); the scene's number is the key's row. Columns 1-3 light at the core's scene levels (`scene_recall_level`, `scene_fade_level`, `scene_save_level`): 8 populated, 2 empty, 10 the slot the running sequencer recalls next (#303), 15 the current scene, which beats the position, so the scene a fade goes to blinks (#254).
- Sources page LEDs come from `source_level`, `record_level` and `CLEAR_LEVEL` (`lib/grid/core.lua`), as on the 256 and 128h.
- The positions page (5) is the only one that passes releases (z 0) on: `S.lib.positions.grid_key` and `strip_key` need them for held keys. Pages 1-4 never call `S.lib.positions`; `grid_key` selects the grid voice itself, the strip acts on `S.grid_voice_select`.
- The geometry and its own LED levels live in the one `LAYOUT_128V` table (`S.lib.grid_layout_128v.LAYOUT`); the pages are `S.constants.GRID_PAGES` (aliased `PAGES`, the page key cycles `PAGES.count`), a position column has `PAGES.position_cells` cells (#451), and the voice, play, pick and lock keys, the fader page keys and the scene keys light at the core's shared levels (#526, #452).
- The positions page lights the grid voice's column, the voice the strip acts on, one level up (`grid_level + 1`, at most 15), so a grid voice that reads no buffer shows a floor of 1 (#444).

## Owns

- `lib/grid/layout_128v.lua` (`S.lib.grid_layout_128v`): `grid_key_128v`, `grid_redraw_128v` (global); everything else is local. It registers `S.registry.grid_layouts["128v"]`.
- Its unit tests: `test/unit/grid_layout_128v_test.lua`.

## Pages

`S.lib.grid_core.page(port)`: 1 patterns, 2 faders, 3 scenes, 4 sources, 5 positions. (8,8) steps to the next one.

## Keys

- Column 8, every page: rows 1-7 `toggle_voice(y)`; row 8 the page key; row 9 `pattern_toggle()`.
- Column 8, every page: rows 1-7 light 12 running, 2 stopped; row 9 15 playing, 4 stopped.
- Column 8, pages 1-3: rows 10-16 `select_grid_voice(y - 9)`, the selected voice at 15, the others at 4.
- Patterns page, columns 1-7: `step_key(port, x, y, z, x, y, y, PATTERN_LENGTH)` (voice = column, step = row).
- Faders page: columns 1-4 `set_fader_param(S.grid_voice_select, (S.param_page - 1) * 4 + x, 17 - y)`; column 5 row y sets `S.param_page` (rows 1 to `fader_page_count`). Column 6 and column 7 rows 1-9 do nothing; column 7 rows 10-16 toggle the lock of voices 1-7 (`toggle_lock`). LEDs: a bar at 8 from row 16 up to the value's row, which is at 15; the page selector at 15 for the shown page, 4 for the others; the lock keys at 12 locked, 2 not (`LAYOUT_128V.lock_column`, the core's `lock_level`).
- Scenes page: column 1 rows 1-8 `recall_scene(y, 0)`; column 2 rows 1-8 `recall_scene(y, scene_transition_time)` (LED 6 populated, 2 empty); column 3 rows 1-8 `scene_save_key` (15 while the hold is pending, else 4); column 4 row 1 toggles `scene_sequencer_enabled` (15 on, 4 off; through `set_binary_param`, so a controller mapped to it follows, #538), rows 9-16 set `scene_sequence_length` 1-8 (8 within the length, 2 beyond).
- Sources page: columns 1-7 rows 1-10 `source_key(x, y)` (row 1 synth, rows 2-9 buffers 1-8, row 10 input); row 11 dark; row 12 columns 1-8 `record_key(x)`; row 13 columns 1-8 `clear_key(x)`; row 14 columns 1-7 each voice's freeze key (`S.lib.freeze.toggle(x)`; LED 15 frozen, 3 not).
- Positions page (5), columns 1-7: `S.lib.positions.grid_key(port, x, y, 16, z)` (voice = column, cell = row; row 1 the slot's start), LEDs from `grid_level`, the grid voice's column one level up (#444). Column 8 rows 10-16: `strip_key(port, S.grid_voice_select, key, z)` with keys 1-4, `"store"`, `"hold"`, `"whole"`; LEDs from `strip_level`. Rows 1-9 of column 8 work as on every page.

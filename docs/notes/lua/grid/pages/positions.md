## Must not break

- **Every key passes its pane**: side 1's cells go through `S.lib.positions.grid_key(port, y, x, GRID_PAGES.position_cells, z, pane.index)` and side 2's marks through `S.lib.positions.strip_key(port, y, mark, z, pane.index)`, so each press record keeps that pane's view and ends with its own pane's page, side or half change, never the other pane's (`docs/notes/lua/positions.md`). A press never passes no pane.
- **The page reads the positions module's records only through `S.lib.positions`** (`grid_key`, `strip_key`, `grid_level`, `strip_level`): the module's record stays at `port_state(port).positions`, the module's own; the page has no state of its own (it would be `pane.state()`, never `port_state`). It sends no engine command for the heads or bookmarks: jumps and recalls enter only through `S.lib.positions`.
- **The cells are always sixteen** (`GRID_PAGES.position_cells`): on a 64's half the pane shows cells 1-8 or 9-16 and a two-key loop is made within the half shown; the cells' level passes the port (`grid_level(v, cell, 16, port)`), as a slice row's bank is the port's.
- **The slots' keys are side 2's columns 9-16** (slot `x - 8`, `slot_column` 8): line 1 `grid_core.record_key`, line 2 `grid_core.clear_key`, at the press only; LEDs `record_level(slot)` and `CLEAR_LEVEL`. Lines 3-7 there are dark and do nothing.
- **Redraws come from elsewhere**: the playheads' 15 Hz clock repaints while any pane shows the page (`any_page(GRID_PAGES.positions)`, either side) and `S.lib.positions.display_signature()` changes; a slot's state reaches side 2 through `lib/buffers.lua`'s poll gate (`any_page(sources) or any_page(positions, 2)`) and `buffer_display_changed`. Param actions never redraw it; the page has no `signature` and no fader lines.

## Owns

- `lib/grid/pages/positions.lua` (`S.lib.grid_pages_positions`): its record (`M.record`, `sides = 2`), registered at `GRID_PAGES.positions`, and `M.POSITIONS_PAGE` (side 2's columns: `marks` 6 store, 7 hold, 8 whole; `slot_column` 8; `record_line` 1, `clear_line` 2).
- Unit tests: `test/unit/grid_pages_positions_test.lua`, on every arrangement of the pane harness; the marks' waiting blink on side 2 in `test/unit/playheads_test.lua`; the press records' pane in `test/unit/positions_test.lua`.

## Keys and LEDs (design §10.7)

Side 1 (lines 1-7 are voices 1-7):

| x | Press | Release | LED |
|---|---|---|---|
| 1-16 | `grid_key(port, y, x, 16, 1, pane.index)`: a jump (quantized), with a key of the line held a loop, on a slice row its slice | `grid_key(..., 0, ...)` | `grid_level(y, x, 16, port)` |

Side 2:

| Line | x | Press | Release | LED |
|---|---|---|---|---|
| 1-7 | 1-4 | `strip_key(port, y, x, 1, pane.index)`: recall (quantized), with ST held store, on a slice row the bank | `strip_key(..., 0, ...)` | `strip_level(y, x, port)` |
| 1-7 | 5 | nothing | | 0 |
| 1-7 | 6 ST, 7 HD, 8 WH | `"store"`, `"hold"`, `"whole"` | ends store and hold | `strip_level` |
| 1 | 9-16 | `record_key(x - 8)` | - | `record_level`: 11 armed, 15 recording, 8 audio, 2 free |
| 2 | 9-16 | `clear_key(x - 8)` | - | `CLEAR_LEVEL` 4 |
| 3-7 | 9-16 | nothing | | 0 |

The lit page key pressed again shows the other side (the pane engine's, `page_key`). Turned (the 128v), the cells and side 2's keys run down each voice's column; on a 64 side 2's marks are the left half, the slots the right. Both panes of a 256 can show the page, on a side each or the same: a voice's store and hold are held per view, so one pane's release or page change never ends the other's.

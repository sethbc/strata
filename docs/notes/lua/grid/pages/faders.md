## Must not break

- **The fader lines are the pane engine's** (`faders(pane)`: lines 1-4, `first` 1, sixteen keys each), set and drawn through `set_param_from_column` and `fader_position`, so a fader runs the touch hooks once, as `"grid"`, and a gesture recorder records it. They are fader `(S.param_page - 1) * GRID_LAYOUT.fader_rows + line` of `fader_param_ids(S.grid_voice_select)`, or `S.lib.grid_faders.shown_macro_ids()[line]` while the port shows the macros, both read at each call.
- **`faders(pane)` lists only params that exist** (`params.lookup`): the engine's `draw_line` reads `fader_position` outside the faders containment (`lib/grid/pane.lua`), so an id that is no param would raise on the draw path. A line with no fader (a last page of fewer than four, an empty macro slot) is left out: dark, and its keys reach `press`, which does nothing for lines 1-4.
- **Whether the port shows the macros is `pane.state().macros`** (true or nil), per port and forgotten with its grid; never `port_state` directly (P20). A bank key sets it, a page key or a voice key clears it. The bank itself is global (`S.lib.macros.bank()`): a bank key on one grid changes the bank every surface shows.
- **n, the count of type keys, is the registry's** (`#S.lib.types.list()`, read at each draw and press), never a literal (D4, ruling 64): key x is `S.lib.types.list()[x]`, keys past n are dark and dead.
- **A type key applies at once through `S.lib.types.set(S.grid_voice_select, key)`**, whose `v<i>_type` action cancels the voice's pending VOICE choice (ruling 63), so the grid's later act stands; the same action clamps `S.param_page` to the new type's page count, so the page keeps no clamp of its own (#855).
- **The page sets `S.param_page` only with a page key (`x <= fader_page_count`), and `S.grid_voice_select` only through `select_grid_voice`** (which clamps the page too); the source and type actions (`lib/voices.lua`) clamp the page when the grid voice's list shrinks.
- **`signature(pane)`** is the grid voice, `S.param_page`, its page count, the macros flag, the bank and the voice's type key: a type set on VOICE, a bank set on MOD and a page count moved by a source change show within a drift tick. The fader lines' positions are followed by the engine.

## Owns

- `lib/grid/pages/faders.lua` (`S.lib.grid_pages_faders`): its record (`M.record`), registered at `GRID_PAGES.faders`; `M.FADERS_PAGE` (the lines, `page_keys` 10, `first_bank` 12, the levels).
- Unit tests: `test/unit/grid_pages_faders_test.lua`, on every arrangement of the pane harness that shows the keys each test needs.

## Keys and LEDs (design §10.4, ruling 31)

| Line | x | Press | LED |
|---|---|---|---|
| 1-4 | 1-16 | fader lines (the engine's): the grid voice's page's four, or the shown bank's while `macros`; no fader: dark, dead | bar 8, value 15 |
| 5 | 1-10 | `macros = nil`, `S.param_page = x` if `x <= fader_page_count(voice)`; else nothing | `fader_page_level(x)` 15 / 4 while not `macros`, 4 while `macros`; 0 past the count |
| 5 | 12-15 | `S.lib.macros.set_bank(x - 11)`, `macros = true` | 15 the bank while `macros`; else 6 a bank with targets, 2 empty |
| 6 | 1..n | `S.lib.types.set(voice, list()[x].key)` (its action clamps the page) | 15 the voice's type, 4 another |
| 7 | 1-7 | `macros = nil`, `select_grid_voice(x)` | 15 picked, 4 other (`GRID_LEVELS.picked`, `unpicked`) |
| 5, 6, 7 | the rest | nothing | 0 |

Turned (the 128v) the lines run down columns 1-7 and the faders up columns 1-4 (row 16 the minimum). On a 64's halves the left shows p1-p8, types 1-8 and V1-V7, the right p9-p10, the banks (x 12-15 at its columns 4-7) and types 9-12; both draw the four faders across the half's eight keys. A key redraws the grids through the core's key handler; nothing of the page needs a redraw of its own.

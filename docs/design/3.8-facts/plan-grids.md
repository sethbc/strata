# Plan facts: the grids (0e, 1k, 1l, 1m, 2c, 4b, 4c)

Read on `main` at 2edbfa96: `docs/design/3.8-design.md` (whole), `docs/design/3.8-facts/lua-grids.md` (whole), `lib/grid/core.lua` (963 lines), `lib/grid/faders.lua` (317), the four `lib/grid/layout_*.lua` (256: 665, 128h: 406, 128v: 318, 64: 210), the grid parts of `lib/positions.lua`, `lib/playheads.lua`, `lib/buffers.lua`, `lib/waveforms.lua`, `lib/params_setup.lua`, `lib/delay_sync.lua`, `lib/state.lua`, `lib/constants.lua`, `docs/notes/lua/grid-core.md` and the test files that press or read grid keys. Measured: `lua test/run.lua grid_` passes **230 tests** on `main` today (core 74, 256 58, 128h 42, 128v 32, 64 24; the facts' 222 is older); calls of `press(`, `tap(`, `get_led(` or `hold(` with a numeric argument in the five grid test files: core 251, 256 460, 128h 332, 128v 229, 64 156 (1,428; a broader grep than the facts' 904, same idea: a lower bound). Nothing was run on a device. "Proposed" marks a name or value the design leaves open.

## 0. What the merged code makes unavoidable (all seven packages)

1. **A page change ends every held key of the port today.** `set_page(port, page)` (`lib/grid/core.lua:85-93`) calls `end_port_step_gestures(port)` and `end_port_holds(port)`, which cancel every hold, forget every key role and drop every step key on the port. With two panes on a 256, a page change on one pane would end the other pane's held step, its CL hold, a held tempo key's repeat and a held fill. The core needs a per-pane end: `end_pane_keys(port, pane)` over the pane's own physical keys, never a strip key. The design is silent.
2. **Fill ends at a page change today** (`layout_256.lua:282-294`: its `still` test is `pressed_as(port, x, y, "fill")`, and a page change forgets roles; test "fill ends when its grid is removed or shows another page", `grid_layout_256_test.lua:544`). On a strip that is the same on every page, the natural rule is that a page key leaves fill held. Proposed: strip keys are never ended by a page change (fill, tempo repeat, a mute, NV); a grid's removal still ends them. A call for the planner.
3. **`lib/positions.lua` tags every grid press with `S.lib.grid_core.page(port)`** (`:428, 485, 587, 596`) and ends it when the port's page differs (`end_stale_port`, `:482-518`). With two panes the tag must be the pane's view. The positions page package (1m) must edit `lib/positions.lua`, which §14 does not give it.
4. **Three layout record fields go with the one-strip layouts**: `selects_grid_voice` (read by `positions.lua:533-536, 575, 625, 637, 645, 662, 950-952`), `rows_show_grid_voice` (`positions.lua:542-545, 566`) and `strip_page` (`playheads.lua:238-251`). In the pane model every layout's strips are the 256's (each voice's own line), so `positions.lua`'s one-strip branches (`store_down`, `any_voice`, the grid voice's strip) become dead, and nine `positions_test.lua` tests that plug a 16x8 or 8x8 to get them change (listed under 0e, Tests).
5. **The slots' record and clear keys move to page 5's second side**, but `lib/buffers.lua:830` redraws the grids on a slot's state change only while a grid shows the sources page (`any_page(GRID_PAGES.sources)`). After 1m it must also redraw while one shows positions side 2: one line of `lib/buffers.lua`, which 1d also edits (its source tests).
6. **The scenes page's SV key is on the left half** (x 2 of line 7) and scenes 9-16 are on the right half: on a 64 a player cannot hold SV and see scenes 9-16 at once. The design is silent (proposal under 1l).
7. **A 256 starts on patterns over voices**, but the voices page is wave 4's (4c). Until it lands the lower pane needs a fallback (proposed: a start page with no record starts on patterns).
8. **The stub state in `test/unit/stubs_test.lua:17-40`** lists every registry and `register_*` function a module calls at include; the patterns page's `S.register_grid_page` call at include would fail there unless 0e adds `grid_pages = {}` and `register_grid_page = function() end`.
9. **No grid page can use the fader helpers as they are on a 64 half**: `fader_zero_column`, `fader_column_fraction`, `set_param_from_column` and `fader_position` (`lib/grid/faders.lua:67-158`) all read `GRID_LAYOUT.fader_width` (16). An eight-key fader needs a width argument.
10. **The FX page's new params have no redraw path to the grids.** Only the five params of today's FX faders call `fx_fader_changed()` (`params_setup.lua:501, 513, 538, 550, 562`; `delay_sync.lua:163`). Proposed: the drift tick's follow covers every shown fader line (0e), so 4b needs no action edits.

## Package 0e: the pane engine

### 1. Files

Created:
- `lib/grid/pane.lua` (`S.lib.grid_pane`): the pane object, the arranger (`arrange(spec)`), the strips, fader lines, the 64's chooser, the follow of shown panes. Estimate 450-550 lines.
- `lib/grid/pages/patterns.lua` (`S.lib.grid_pages_patterns`): about 40 lines.
- `test/unit/grid_pane_test.lua`: the strips, panes, arrangements, the chooser, fader lines, per-pane key ends, the registry (tests listed below).
- `test/unit/grid_pages_patterns_test.lua`: the patterns page in pane coordinates on every arrangement.
- `docs/notes/lua/grid/pane.md` (opens with `## Must not break`), `docs/notes/lua/grid/pages/patterns.md`.
- `docs/user/grid/pages/patterns.md`.
- `changes/<branch>.md`.

Edited (main sites):
- `lib/grid/core.lua`: `GRID_LAYOUT` `:39-53` shrinks; `S.grid_pages` `:30-36` becomes `S.grid_panes`; `page`/`set_page`/`any_page` `:73-101` gain the pane; `end_port_holds` `:222-228` and `end_port_step_gestures` `:378-384` gain a key filter; `scene_save_key` `:386-393` and `scene_save_level` `:479-482` (and `SCENE_LEVELS.save_pending`, `save_idle` at `:464-465`) are removed; the record-field readers `:542-573` (`any_fx_faders` kept as a one-line alias, `any_modulation_shown` removed); `forget_port` `:248-257` forgets `S.grid_panes[port]`; header comment `:1-13`.
- `lib/grid/faders.lua`: width arguments on four functions (`:67-73, 79-88, 94-108, 146-158`); removed: `set_param_fraction` `:110-124` (only the XY pad used it), `set_fader_param` `:137-142`, `grid_redraw_fader_row` `:160-168`, the 128s' macro key and its helpers `:230-292` (`MACRO_PAGE`, `shows_macros`, `macro_page_key`, `leave_macros`, `macro_page_level`, `shown_fader_ids`, `shows_modulation`), `grid_redraw_faders` `:301-314`; `follow_faders` `:212-228` generalized; header `:1-10`.
- The four layout files shrink to arrangers, about 20-30 lines each (`lib/grid/layout_256.lua` 665 lines, `layout_128h.lua` 406, `layout_128v.lua` 318, `layout_64.lua` 210 today). Every global they define goes (13 names, listed under Names).
- `lib/constants.lua:141` (`GRID_HOLD`), `:145-146` (`GRID_PAGES`), `:157-158` (`GRID_LEVELS`).
- `lib/state.lua`: the registry `grid_pages` beside `grid_layouts` (`:33`) and `M.register_grid_page` (new, about 25 lines, after `register_io_section` `:583-601`).
- `strata.lua:160-167`: one include line after `lib/grid/faders` for `lib/grid/pane`, one for `lib/grid/pages/patterns`, before the four layouts.
- `lib/playheads.lua:238-251` (`shows_positions` becomes `S.lib.grid_core.any_page(POSITION_PAGE)`; `strip_page` gone).
- `lib/positions.lua`: the one-strip code made dead by point 4 of §0 (`:339-345` comment, `:533-545`, `:566`, `:575`, `:596-680` the `selects_grid_voice` branches and `store_down`, `:940-955` the invariant's two branches). Measured with grep: 20 lines name `selects_grid_voice`, `rows_show_grid_voice` or `store_down`. (Alternatively leave them to 1m; see Risks.)
- `lib/params_setup.lua:50-53`: the comment "no other layout shows them" (no code change if `any_fx_faders` stays as an alias).
- Tests: `test/unit/grid_core_test.lua` (re-based), the four `test/unit/grid_layout_*_test.lua` (shrink to arrangement tests), `test/unit/structure_test.lua:440-449` (`MODULE_HOMES`), `test/unit/stubs_test.lua:17-40` (the stub state), `test/unit/docs_test.lua:938-950` and `:1946-1980`, `test/helpers.lua` (the pane harness), and the outside files under Tests.
- Docs: `docs/notes/lua/grid-core.md` (183 lines: its "Must not break" items 8, 10, 11, 14, 15, 17, 20, 22, 25, 30, "Layouts" `:67-80`, "Pages, held keys and holds" `:82-94`, "Keys" `:146-149`, "Faders" `:151-179`, "Registering a grid layout" `:181-183`), the four `docs/notes/lua/grid/layout_*.md` (30-99 lines each, rewritten as arrangement notes), `docs/notes/lua/playheads.md`, `docs/notes/lua/positions.md` (the one-strip lines), `docs/user/grid.md` (92 lines: "Supported Grid Sizes" `:9-23`, "Holds and Two-Key Gestures" `:24-41`, "Multi-Grid Support" `:85-92`; "Positions" `:42-72` stays until 1m), the four `docs/user/grid/<size>.md`, `docs/user/sequencer.md:47` (the fill keys' coordinates), README.md:77 (the grid index line).
- `AGENTS.md` lines that become false (word counts measured with `wc -w` on each line; the file has 7,744 words today):
  - `:120` (15 words) `grid_core_test.lua (the faders through grid_layout_256_test.lua)`: the fader maths tests move to `grid_core_test.lua` (below).
  - `:121` (19 words) the layout row: kept, with the notes and tests it names.
  - New rows (proposed, about 45 words): `| lib/grid/pane.lua | grid_pane | docs/notes/lua/grid/pane.md | grid_pane_test.lua |` and `| lib/grid/pages/<page>.lua: patterns, faders, scenes, sources, positions, voices, fx | grid_pages_<page> | docs/notes/lua/grid/pages/<page>.md | grid_pages_<page>_test.lua |` (each later page package appends its name to the second row, a registration line).
  - `:127` (46 words): "Each screen page, grid layout and the arc's page rings have their own user page (`docs/user/grid/<size>.md`, ...)": add grid pages (`docs/user/grid/pages/<page>.md`).
  - `:136` (registry counts, "eight close at init, the other 24 stay open"): 25 open with `grid_pages` (0d also edits this line for its type registry: a registration conflict, keep both changes).
  - `:276` (58 words) "a grid layout (`docs/notes/lua/grid-core.md`)": "a grid page or layout (`docs/notes/lua/grid/pane.md`)".
  - `:340` (43 words), `:341` (45 words), `:342` (29 words), `:343` (28 words): the grid rules, rewritten (proposal below), about 200 words for these 145.
  - `:345` (29 words): add `docs/user/grid/pages/<page>.md`.
  - Net about +100 words; 0a's 800 free words cover it.

Proposed text for `AGENTS.md:340-343`:
- "Grid pages are one file each (`lib/grid/pages/<page>.lua`), registered with `S.register_grid_page` and written in pane coordinates (x 1-16, lines 1-7; a line is a voice on patterns, sources, positions and voices); the four layout files only arrange panes (`S.lib.grid_pane.arrange`), picked by the exact `cols`/`rows` in `grid_layout()`. Patterns are `S.patterns[voice][step]`. Anything the grid shows calls `grid_redraw()` when it changes, wherever it changes (cheap without a grid). `docs/notes/lua/grid/pane.md`"
- "Grid state is per port and pane (`page(port, pane)`, `any_page(n)`, `S.grid_held[port]`, `port_state(port)`): no page names a physical key or keeps state in a local or on `S`; a page change ends only its pane's keys, never a strip's. Pattern keys go through `pane.step_key`, delayed key actions through `on_hold`, a whole-pattern replacement through `S.lib.sequencer.replace_pattern` (`docs/notes/lua/grid-core.md`)."
- "The position page (page 5, `POSITION_PAGE` in `lib/playheads.lua`) repaints from the playheads' 15 Hz clock when `S.lib.positions.display_signature()` changes; param actions never redraw it (`docs/notes/lua/playheads.md`)."
- "A fader line is a page's `faders(pane)` entry, set and drawn by the pane engine alone (its keys, eight on a 64's half, upward on the 128v) and followed by the drift tick; the faders page shows `fader_param_ids`. Review whether a feature needs a key on a grid page."

### 2. Names

**Constants** (`lib/constants.lua`):
- `GRID_PAGES` (`:145-146`, today `{patterns = 1, faders = 2, scenes = 3, sources = 4, positions = 5, count = 5, position_cells = 16}`) becomes `{patterns = 1, faders = 2, scenes = 3, sources = 4, positions = 5, voices = 6, fx = 7, count = 7, names = {"patterns", "faders", "scenes", "sources", "positions", "voices", "fx"}, position_cells = 16}` (proposed `names`, which `register_grid_page` checks a record's name against). A page's sides are its record's (`sides = 2` on positions), not a constant: nothing needs the sides of a page with no record.
- `GRID_HOLD` (`:141`, today `{scene_save_seconds = 0.5, half_toggle_seconds = 0.5, step_edit_seconds = 0.3}`): proposed `{scene_save_seconds = 0.5, step_edit_seconds = 0.3, chooser_seconds = 0.5, tempo_repeat_delay = 0.5, tempo_repeat_seconds = 0.1}`. `half_toggle_seconds` goes (its one reader, `layout_64.lua:86`, goes); `chooser_seconds` keeps the 64's 0.5 s feel. `scene_save_seconds` stays: the recorders' clear (`core.lua:407`) and 4c's CL and RN read it (rename optional; `AGENTS.md:305` names only `step_edit_seconds`).
- `GRID_LEVELS` (`:157-158`): add `side_two = 10` (a page key while its page shows its second side; 10 is today's 128h page-5 level, `layout_128h.lua:54`). Everything else stays.

**Registry** (`lib/state.lua`): `M.registry.grid_pages = {}`, keyed by page index. `M.register_grid_page(record)`: fields `name` (string, required, equal to `GRID_PAGES.names[index]`), `index` (whole 1..`GRID_PAGES.count`, required, unique), `press` (fn(pane, x, y, z), required), `redraw` (fn(pane, led), required), `sides` (1 or 2, default 1), `faders` (fn(pane) -> list of `{line, first, keys, id}`, optional), `signature` (fn(pane) -> string, optional). Any other field, a duplicate index or name, or a name that is not the index's refuses with `kind .. ": " .. message` at level 3, as `register_io_section` does (`:591-601`, through `require_named` and `require_functions`). **Open**: read at each press and redraw, never at init, like `grid_layouts` and `pages`; not in `INIT_READ` (`:68-69`). Reason: tests can put a probe record in an index that has none in their own fresh `S`, and nothing reads the registry once.

**State** (`lib/grid/core.lua`):
- `S.grid_pages[port]` (a number) becomes `S.grid_panes[port][pane] = {page, side, half}` (proposed name, so it never reads as the registry `S.registry.grid_pages` or the modules `S.lib.grid_pages_<page>`). Only `core.lua` reads it today (`:34, 75, 92, 256`; grep of `lib/`, `test/`, `docs/notes/`).
- `M.page(port, pane)`: pane defaults to 1, so the five outside callers (`playheads.lua:245`, `positions.lua:428, 485, 587, 596`) and the tests that call `page(port)` keep working; a port with no entry reads its layout's start page.
- `M.side(port, pane)` (new): 1 or 2.
- `M.half(port, pane)` (new): 1 or 2, a 64's shown half (`nil`-safe: 1).
- `M.set_page(port, page, pane, side)`: today `(port, page)`; pane defaults to 1, side to 1. Refuses a port that is not a grid port (as today), a page outside 1..`count`, a pane above the layout's `panes` (1 with no grid), a side above the record's `sides` (1 for a page with no record). **It accepts a page with no record** (drawn dark), so the outside tests that gate on `any_page(n)` keep working between 0e and the page packages (below); only the strips refuse such a page. A change of page, side or half ends the pane's keys (`end_pane_keys`).
- `M.set_half(port, pane, half)` (new): the 64's chooser; ends the pane's keys on a change.
- `M.view(port, pane)` (new): `pane .. ":" .. page .. ":" .. side .. ":" .. half`, a string a press record keeps to know whether its pane still shows what it was pressed on (1m's positions).
- `M.any_page(page, side)`: true while any pane of any connected grid shows the page (and the side, when given).
- `M.end_pane_keys(port, pane)` (new): for each held, consumed, pending-hold, role or step key of the port whose physical position the layout puts in that pane (`layout.pane_at(x, y)`), what `end_port_holds` and `end_port_step_gestures` do today. Strip keys (`pane_at` nil) are never touched.
- `M.end_port_holds(port)` and `M.end_port_step_gestures(port)` stay for `forget_port` and the invariants (`end_port_step_gestures` is also called by the 64's half switch today; the chooser calls `set_half`, which calls `end_pane_keys`).
- `M.any_fx_faders()` (`:554-560`) becomes `return M.any_page(S.constants.GRID_PAGES.fx)`, so `params_setup.lua:55` and `delay_sync.lua:163` need no edit. Proposed: keep the name (the alternative, editing two files 1a and 1b own in wave 1, is a conflict).
- Removed: `M.scene_save_key` (`:388-393`; the design saves with SV held, §10.5), `M.scene_save_level` (`:480-482`) and `SCENE_LEVELS.save_pending`, `save_idle`, `M.any_modulation_shown` (`:567-573`), the record fields `fx_faders_page`, `selects_grid_voice`, `rows_show_grid_voice`, `strip_page`, `shows_modulation`.
- Kept as they are: `held`, `hold_pending`, `on_hold`, `consume`, `consumed`, `press_as`, `pressed_as`, `port_state`, `existing_port_state`, `level_for_position`, `step_key`, `end_step_gestures`, `gesture_key`, `gesture_level`, `voice_level`, `lock_level`, `play_level`, `scene_recall_level`, `scene_fade_level`, `source_key`, `source_level`, `record_key`, `record_level`, `clear_key`, `CLEAR_LEVEL`, `LEVELS`, `layout_of`, the rotation, the virtual grids, `reconcile_ports`. Globals kept: `grid_init`, `grid_key`, `grid_redraw`, `select_grid_voice`.
- `GRID_LAYOUT` (`:39-51`) becomes `{fader_rows = 4, fader_width = 16}` (`fader_first_row`, `param_page_row`, the buffer, FX and source rows go with the 256's pages); `M.GRID_LAYOUT` stays (faders.lua's alias, `fader_page_count`, `faders_signature`).
- The layout record (`S.registry.grid_layouts[<key>]`) becomes what `S.lib.grid_pane.arrange(spec)` returns: `{key = fn(port, x, y, z), redraw = fn(port, device), panes = n, pane_at = fn(x, y) -> pane or nil, start_pages = {page, ...}}`. The core's dispatch (`handle_key` `:832-842`, `grid_redraw` `:887-905`) is unchanged: it calls `layout.key` and `layout.redraw`.

**Faders** (`lib/grid/faders.lua`), the width argument (default `GRID_LAYOUT.fader_width`, so every caller that passes none keeps 16):
- `fader_zero_column(param_id, width)` (`:67`): clamp to `2..width - 1`.
- `fader_column_fraction(param_id, x, width)` (`:79`).
- `set_param_from_column(param_id, x, width)` (`:94`): still runs the touch hooks as `"grid"`.
- `fader_position(param_id, width)` (`:146`).
- Kept: `voice_level_fader_keys` (global; `lib/voices.lua:357, 438` call it), `fader_param_ids`, `fader_page_count` (global; `select_grid_voice`, `lib/voices.lua:390`, `params_setup.lua:965`), `M.fx_fader_id`, `M.faders_signature`, `M.shown_macro_ids`, `M.modulation_signature`, `M.fader_page_level`.
- `M.follow_faders()` (`:216-228`; `lib/mutation.lua:297`, the 10 Hz drift tick, calls it): proposed to become the follow of every shown pane: the signature is the concatenation, over every connected grid's every pane, of `view(port, pane)`, each shown fader line's `fader_position(id, keys_shown)` and the page record's `signature(pane)` when it has one; the grids redraw when it differs from the last look. Kept under this name, so `lib/mutation.lua` needs no edit. Its body may call `S.lib.grid_pane.signature()`.
- `MODULE_HOMES` for `lib/grid/faders.lua` (`structure_test.lua:441-443`) loses `set_fader_param`, `grid_redraw_fader_row`, `grid_redraw_faders`.

**The pane engine** (`lib/grid/pane.lua`, `S.lib.grid_pane`), proposed:
- `M.arrange(spec) -> layout record`. A spec:
  - 128h: `{panes = {{x = 0, y = 0, strip = {row = 8, keys = "upper"}}}}`
  - 256: `{panes = {{x = 0, y = 0, strip = {row = 8, keys = "upper"}}, {x = 0, y = 8, strip = {row = 16, keys = "lower"}}}, start = {GRID_PAGES.patterns, GRID_PAGES.voices}}`
  - 128v: `{turned = true, panes = {{strip = {column = 8, keys = "upper"}}}}`
  - 64: `{half = true, panes = {{strip = {row = 8, keys = "small"}}}}`
  `start` defaults to patterns for every pane; a start page with no record starts on patterns.
- `M.STRIPS`: `upper = {"play", "fill", "page 1" .. "page 7", "voice 1" .. "voice 7"}`, `lower = {"tempo -", "tempo +", "page 1" .. "page 7", "mute 1" .. "mute 7"}`, `small = {"chooser", "voice 1" .. "voice 7"}`, built from `GRID_PAGES.count` and `NUM_VOICES` (2 + 7 + 7 = 16 keys; a test asserts the sum).
- The pane object, built per key and per redraw for (port, pane index) and passed to the page record: `port`, `index` (1 top, 2 bottom), `page`, `side`, `width` (16, or 8 on a 64), `offset` (0, or 8 on a 64's right half), `turned` (the 128v), `shows(x)` (whether pane column x is on the grid), and wrappers that take pane coordinates and call the core with the physical key: `held(x, y)`, `hold_pending(x, y)`, `on_hold(x, y, seconds, fn)`, `consume(x, y)`, `consumed(x, y)`, `press_as(x, y, role)`, `pressed_as(x, y, role)`, `step_key(x, y, z, voice, step)` (passes position `x - offset` of `width` positions, so the level gesture follows 16 keys, or 8 on a half, as today: `grid_core_test.lua:412, 424, 433`), `gesture_key(x, y, z, k)`, `state()` (the page's per-port table, `port_state(port)[page name]`). The redraw's second argument `led(x, y, level)` is in pane coordinates and drops a key the grid does not show. Wrappers are needed because a Lua call `f(port, pane.at(x, y), ...)` keeps only the first of `at`'s two results.
- Coordinates: 128h `(x, y)`; 256 pane 1 `(x, y)`, pane 2 `(x, y + 8)`; 128v pane `(x, y)` at physical column y, row x, the strip down column 8; 64 pane column x at physical column `x - offset` when `offset < x <= offset + 8`.
- Fader lines: an entry `{line = y, first = x0, keys = 16 or 8, id = param_id}` of `record.faders(pane)`. The engine owns those keys: a press (z 1) sets `set_param_from_column(id, k, shown)`, where `shown` is `keys` (or 8 for a 16-key fader on a 64 half) and k the key's place along the fader from its minimum; a release does nothing. On the 128v a fader runs up: k = `first + keys - row` for rows `first .. first + keys - 1` (row 16 the minimum, as today's 128v faders, `layout_128v.lua:65-69`). On a 64 a 16-key fader is drawn on either half across its eight keys; an 8-key fader shows only on the half it lies in (the voices page's level, columns 9-16, on the right half). The draw is today's: 8 up to the value, 15 at it (`faders.lua:162-168`). The page's `press` and `redraw` never see a fader line's keys.
- Dispatch order for a physical key: the strip; else, on a 64 while the chooser shows, the chooser; else a fader line; else `record.press(pane, x, y, z)` (a press, and a release not consumed, as the core passes it today). A pane on a page with no record draws dark and takes no keys.
- Each pane's redraw runs contained (`S.lib.ui_frame.contained_call`, keyed `port .. ":" .. pane`), as each layout's is today (`core.lua:899`), so a failing page spares the other pane and the strips.
- `M.signature()`: what `follow_faders` compares (above).

**The strips** (§10.2), every key, at press unless said (levels from `GRID_LEVELS` and today's layouts):

| Key | Press | Hold | Release | LED |
|---|---|---|---|---|
| PL (upper 1) | `pattern_toggle()` | - | - | `play_level()` 15 playing, 4 stopped |
| FL (upper 2) | `press_as(.., "fill")`, `S.lib.conditions.hold_fill("grid:" .. port, true, still)` | held = on | `hold_fill(holder, false)` | 15 while `S.lib.conditions.fill()`, 4 otherwise (`layout_256.lua:49-50`) |
| P1-P7 (upper 3-9, lower 3-9) | page with no record: nothing; page not shown on this pane: `set_page(port, n, pane, 1)`; shown and `sides` 2: the other side | - | - | 0 no record; shown: 15 side 1, `side_two` 10 side 2; other 2 (`page_shown`, `page_other`) |
| O1-O7 (upper 10-16, small 2-8) | `toggle_voice(v)` | - | - | `voice_level(v)` 12 / 6 silenced / 2 stopped |
| T- T+ (lower 1, 2) | `params:delta("tempo", -1 / 1)`, `header_flash(string.format("tempo %d", util.round(S.lib.params_setup.clock_tempo_now())))` | after `tempo_repeat_delay` 0.5 s, again every `tempo_repeat_seconds` 0.1 s while held (an `on_hold` that re-arms itself) | the release cancels the repeat | 15 while held, 4 otherwise (`layout_256.lua:32-33`) |
| M1-M7 (lower 10-16) | `set_binary_param("v<i>_mute", ...)` toggled | - | - | proposed 15 muted, 4 not (the key shows its own state; a solo's silencing shows on O at 6) |
| NV (small 1) | `press_as("chooser")`, arms `on_hold(chooser_seconds)` | 0.5 s: the chooser shows (consumed) | before the hold: `pattern_toggle()` (only when `pressed_as`); after it: the chooser closes | `play_level()`; 15 while the chooser shows |

The 64's chooser, on the pane's rows while NV is held past 0.5 s: column c (1-7) is page c; row 1 its left half, row 2 its right half, rows 3 and 4 the halves of side 2. A press sets the page, side and half at once (`set_page`, `set_half`: the pane's keys end) and the chooser stays shown until NV comes up. LEDs: the shown page, side and half 15; another key of a page with a record 4; the side-2 rows of a one-sided page and every key of a page with no record 0; rows 5-7 and column 8 dark. A chooser key's release does nothing (its role is "chooser"). A key held on the pane when the chooser opens is ended (`end_pane_keys`), as a page change ends it. NV released while a chooser key is held: the chooser closes; that key's release reaches the page with no role and does nothing.

**The patterns page** (`lib/grid/pages/patterns.lua`, §10.3): `S.register_grid_page({name = "patterns", index = GRID_PAGES.patterns, press = ..., redraw = ...})`. Press: for line y in 1..`NUM_VOICES` and x in 1..`PATTERN_LENGTH`, `pane.step_key(x, y, z, y, x)`. Redraw: `led(step, voice, step_brightness(voice, step))` for every voice and step. Its coordinates are today's page 1 on all four sizes (256 rows 1-7, 128h rows 1-7, 128v columns 1-7 down rows 1-16, 64 rows 1-7 columns 1-8 of a half), so the step tests keep their keys.

**Globals removed** (`MODULE_HOMES`, `structure_test.lua:444-449`): `grid_key_256`, `grid_key_256_transport`, `grid_key_256_lock`, `grid_redraw_256`, `grid_redraw_256_buffers`, `grid_redraw_256_sources`, `grid_redraw_256_page_row`, `grid_redraw_256_transport`, `grid_redraw_256_lock`, `grid_key_128h`, `grid_redraw_128h`, `grid_key_128v`, `grid_redraw_128v`, `grid_key_64`, `grid_redraw_64` (15 names), and faders.lua's three above. No test outside the grid files and `structure_test.lua` names any of them (grep of `test/` and `lib/`). New globals: none.

**Includes** (`strata.lua:162-167`): `S.lib.grid_core`, `S.lib.grid_faders`, then `S.lib.grid_pane = include("lib/grid/pane")(S)`, `S.lib.grid_pages_patterns = include("lib/grid/pages/patterns")(S)` (each later page package adds its line here), then the four layouts. No start or cleanup step is added: the grids' start step (`START_ORDER.grids`) and cleanup step 170 stay the core's.

**Names the tests reach**: `local_value("grid_held")` (`S.grid_held`, kept), `S.registry.grid_layouts[...]` (kept; 9 sites in `grid_core_test.lua`, 1 in each of the 64, 128h and 256 files, 2 in `pages_setup_test.lua:686, 691`, 1 in `docs_test.lua:1960`).

### 3. Order and seams

- Needs 0a only. Runs beside 0b, 0c and 0d; none of them edits `lib/grid/`. Shared lines: `strata.lua`'s includes (0d adds `lib/types.lua` and seven `lib/types/*.lua`: registration lines, keep both), `AGENTS.md:136` (0d's registry count too), the `AGENTS.md` module table.
- Gives every page package: `S.register_grid_page`, the pane object and its wrappers, fader lines, `record.signature`, `GRID_PAGES.voices`/`fx`, `view(port, pane)`, `any_page(page, side)`, the test harness (below), `docs/user/grid/pages/` and `docs/notes/lua/grid/pages/`.
- Between 0e and the page packages `main` has patterns only: no faders, scenes, sources, positions, voices or FX on any grid. Nothing is released between (design §0.5).
- `AGENTS.md` rules it rewrites (in its own commit, §14): `:340-343` and `:345` above. "Must not break" items of `grid-core.md` it rewrites: 10 (`scene_save_level` leaves the shared levels), 11 (`GRID_PAGES` gains `voices`, `fx`, `count` 7), 14 (the fader page keys are the faders page's line 5, 1k's), 15 (pages per port and pane; `any_fx_faders` is `any_page(fx)`), 20 (roles end with their pane's page change; strip keys keep theirs), 22 (`scene_save_key` gone; pattern keys through `pane.step_key`), 25 (freeze keys: 4c's), 30 (each page's notes file). New items for `docs/notes/lua/grid/pane.md`: a page never names a physical coordinate; a fader line's keys are the engine's; a page change ends only its pane's keys, never a strip key; a page with no record is dark and its page key dead; each pane's redraw is contained.

### 4. Tests

**The harness** (proposed, `test/helpers.lua`): `h.grid_pane(context, arrangement, opts)` returns `{port, device, show(page, side, half), press(x, y, z), tap(x, y), led(x, y)}` in pane coordinates: `led` returns nil for a key the arrangement does not show. `h.GRID_ARRANGEMENTS` lists six: `"128h"`, `"256 top"`, `"256 bottom"`, `"128v"`, `"64 left"`, `"64 right"`; a page test loops over them (or over those that show the keys it needs). Each maps a pane key to its physical key with the layout's own `arrange` spec, so a test never writes a physical coordinate. Proposed: a probe page record put straight into `S.registry.grid_pages[GRID_PAGES.fx]` (no record there until 4b; after 4b the test's own fresh `S` is overwritten for that test only) with `sides = 2` and fader lines, for the engine's tests of sides and faders before any page has them.

**The five grid test files' 230 tests** (by name; "keep" is a re-base of the page keys and the hold vehicle at most):
- `grid_core_test.lua` (74): keep about 58 (the step keys and the step editor `:22-240, 340-460, 781-812`, hot-plug, the guards, rotation `:1385-1561`, virtual grids and the facade `:1586-1785`, the contained redraw, `scene_recall_level` `:1129-1236`, the shared-levels test `:1252` re-based to the strips, cleanup). Re-based hold vehicle: `:298`, `:487`, `:514` use the scene save hold (`press(1, 4, 3, 1)` on page 3) and must hold a step key (0.3 s editor) or arm `core.on_hold` on a held key; `:298`'s solo and recorder parts go to 4c and 1l. Deleted: `:462` ("a scene save needs a 0.5 s hold"), `:723` (record selects grid voice), `:749` and `:899` (hold-saves), `:1237` (`scene_save_level`). Moved: `:242`, `:281` (recorders) to 1l; `:702` (FX redraw gate) to 4b; `:1300` (faders follow) to 1k; `:614` (re-based to a patterns key). `:581`, `:593` (source and slot helpers) stay with the helpers in core.
- `grid_layout_256_test.lua` (58): keep in 0e (strips, patterns): `:144`, `:221`, `:478`, `:494` (one PL), `:512` (FL at x 2), `:544` (re-based: a page change keeps fill), `:696`, `:732`, `:745` (tempo by 1 on row 16), `:963`, `:1324`, `:1504`, `:1522` (re-based to a probe page). Fader maths tests that call `fader_param_ids` and friends directly, `:1593`, `:1614`, `:1629`, `:1649`, `:1666`, and `:99` (zero column), move to `grid_core_test.lua` (the AGENTS row then names it). Moved to 1k: `:11`, `:323`, `:1141`, `:1182`, `:1342`, part of `:1241` (the banks). To 1l: `:191`, `:759`, `:1167`, `:1193`, `:1377`, part of `:1241` (the recorders). To 1m: `:1011`, `:1023`, `:1058`, `:1075`, `:1119`, `:1554`, part of `:362`/`:372` (record and clear). To 2c: `:362`, `:372` (sources). To 4b: `:238`, `:272`, `:300`. To 4c: `:585`, `:623`, `:655`, `:669` (copy, re-specified), `:826`, `:875`, `:907`, `:1284`, `:1484`. Deleted: `:453` (re-written as the engine's sweep), `:790`, `:930` (the freeze modifier), `:1000` (x 12 page key), `:1041`, `:1105`, `:1417` (`set_param_fraction`), `:1435` (the pad).
- `grid_layout_128h_test.lua` (42): keep `:72`, `:348`, `:387`, `:965`, part of `:979` (step toggles at release); re-write `:89` (PL x 1, FL x 2) and `:124` (P keys x 3-9) as strip tests in `grid_pane_test.lua`. To 1k: `:137` (but the lock part to 4c), `:1082`. To 1l: `:324`, `:756`, `:779`, `:940`, `:998`. To 1m: `:453`, `:482`, `:494`, `:512`, `:544`, `:636`, `:654`, `:675`, `:1021`, `:1051`, `:1067` (re-specified for per-voice lines). To 2c: `:223`, `:264`. To 4c: `:361`, the freeze part of `:979`. Deleted: `:44` (sweep, re-written), `:208` (next voice), `:303` (hold-save), `:423` (sources key to page 5), `:438` (grid voice select), `:528`, `:572`, `:588`, `:618`, `:701`, `:726`, `:822`, `:875`, `:913` (the macro key).
- `grid_layout_128v_test.lua` (32): keep `:82`, `:147`, `:362`, `:800`, part of `:813`; re-write `:115` (the strip down column 8). To 1k: `:204`, `:886`. To 1l: `:255`, `:303`, `:630`, `:653`, `:777`, `:833`. To 1m: `:397`, `:424`, `:530`, `:856`. To 2c: `:168`. To 4c: `:42` (locks), `:340`, the freeze part of `:813`. Deleted: `:23` (sweep), `:98` (page cycle), `:327`, `:441`, `:479`, `:510`, `:541`, `:565`, `:597`, `:700`, `:744`.
- `grid_layout_64_test.lua` (24): keep `:82`, `:98`, `:251`, `:408`, `:473` (through the chooser), `:491`, `:515`, `:548`; re-write `:112` and `:156` (NV tap, the chooser per port, a removed grid's hold). To 1m: `:318`, `:334`, `:427`, `:438`, `:456`, `:567`. Deleted: `:48` (sweep), `:176`, `:229` (play key's half and beat levels), `:295` (the hold cycle), `:349`, `:380`, `:600`, `:632` (the grid voice's position rows).
- Afterward each layout test file keeps a few arrangement tests: the layout draws on a hot-plugged grid (I2/I3), its panes and strips sit where its spec says, a page's line runs down (128v) or is halved (64).

**Tests outside the grid files that press or read grid keys**, and what each needs between 0e and the page packages:

| File:line | What it does | 0e | Needs |
|---|---|---|---|
| `params_setup_test.lua:133-136, 150-154, 179-184, 595-601` | the 256's tempo keys at (5-8, 8), ±10 and ±1, after the page key (13, 8) | re-base to T- (1, 16), T+ (2, 16), steps of 1; drop the page key presses; `:127`'s 133 +10 -10 +1 = 134 becomes one T+ | 0e |
| `ui_test.lua:602` | (13, 14) on a 256 starts voice 5 | (14, 8): O5 | 0e |
| `midi_in_test.lua:306` | (12, 14) on a 256 toggles voice 4 | (13, 8): O4 | 0e |
| `system_37_test.lua:34, 604` | `fill_key = {x = 9, y = 8}` | `{x = 2, y = 8}` | 0e |
| `buffers_test.lua:1058` | (16, 8) shows page 4, then a poll redraws the grid | `S.lib.grid_core.set_page(1, GRID_PAGES.sources)` (accepted with no record); still asserts the redraw through `buffers.lua:830` | 0e |
| `mutation_test.lua:524-535` | the 256's faders page follows a drift tick (`get_led(16, 11)`) | delete in 0e | 1k re-adds it in its page test |
| `pages_seq_test.lua:260-270, 417-429` | 128h step LEDs and a step key press | unchanged (patterns keys are today's) | 0e |
| `strata_test.lua:62-83` | cleanup darkens a 256 | unchanged | - |
| `playheads_test.lua:313-360, 429, 539-540, 605` | `set_page(1, 5)` and the refresh count | unchanged (set_page accepts page 5 with no record; the clock's gate is `any_page(5)`) | 0e edits `shows_positions` |
| `playheads_test.lua:475-600` | `key_led(device, v, n) = get_led(n, 8 + v)`: the 256's page-5 strips | delete or park in 0e | 1m re-bases to side 2 through the harness |
| `waveforms_test.lua:162-172, 335-336` | `set_page(1, 1)`/`(1, 5)` and the redraw count | unchanged | - |
| `positions_test.lua:97-206, 589-680, 1133-1379` | `positions.grid_key`/`strip_key` called directly, `set_page(1, 5)` | unchanged | 1m adds the pane argument |
| `positions_test.lua:210, 226, 752, 765, 779, 821, 838, 857, 946` | one-strip behavior through a plugged 16x8 or 8x8 (`selects_grid_voice`), and the 128h's store LED at (13, 6) | rewrite or delete in 0e (the fields go): `:210` becomes "a position press never changes the grid voice" | 0e |
| `io_system_test.lua:478-488` | flips the remote 16x16 between pages 2 and 3, which must differ in at least 96 cells (`:1085-1086` asserts a full tick) | flip the top pane between patterns and a page with no record, or both panes; **measure** that one flip still fills the 96-cell tick | 0e |
| `pages_setup_test.lua:686, 691` | `layout_of(1)` after a rotation | unchanged | - |
| `structure_test.lua:440-449` | `MODULE_HOMES` | remove the 18 names | 0e |
| `stubs_test.lua:17-40` | the stub state's registries | add `grid_pages = {}`, `register_grid_page = function() end` | 0e |
| `docs_test.lua:938-950` | `docs/user/grid/` has at least 4 files, each linked from `grid.md` as `(grid/<basename>)` | the link must use the path below `docs/user/` (`grid/pages/patterns.md`); `find` recurses, so the pages are counted | 0e |
| `docs_test.lua:1946-1980` | every file in `docs/user/grid/` is a registered layout's, each links `../grid.md#positions` and gives the loop's edges "in either order"; at least 3 say "Record into buffer" | layouts are the top-level files only; the pages are `docs/user/grid/pages/<name>.md`, one per registered record (a new check); the Positions and record-key checks move to the positions page in 1m (until then: `grid.md` keeps `## Positions`) | 0e, then 1m |

**New tests** (proposed; `grid_pane_test.lua` unless named):
- "the upper strip: play, fill, seven page keys, seven voice keys" (each key on a 128h and the 256's row 8; LEDs 15/4, 15/4, 15/2/0, 12/6/2).
- "a page key of a page with no record is dark and does nothing; set_page shows it dark".
- "the lit page key shows the next side, and its light tells the side" (probe page, `sides = 2`: 15, then 10, then 15).
- "a 256 shows two panes; row 16's page keys move the lower one; it starts on patterns over voices, over patterns while voices has no record".
- "row 16's tempo keys step by 1 and flash; held, they repeat after 0.5 s every 0.1 s until released" (tempo after 1 s held = start + 6).
- "row 16's mute keys toggle v<i>_mute and light 15 muted, 4 not".
- "a page change ends only its pane's keys": a step held in pane 2 survives pane 1's page change and toggles at release; a held T+ keeps repeating; FL keeps fill on; the step held in pane 1 toggles nothing.
- "a key held into another page acts there in no role" (probe page that acts at release).
- "the 128v turns the pane: a line runs down, the strip runs down column 8, a fader line runs up" (probe fader at line 1: row 16 sets the minimum, row 1 the maximum).
- "the 64 shows a half: columns 9-16 on the right; a 16-key fader across eight keys on either half; an 8-key fader only on its half".
- "NV: a tap plays at release; held 0.5 s it shows the chooser, which picks page, side and half; its release plays nothing"; "a chooser key's release does nothing"; "the chooser opening ends a held step".
- "a fader line sets exactly 0 at its zero column at 16 and at 8 keys" (width argument; `fader_zero_column(id, 8)` within 2-7).
- "the drift tick redraws a grid when a shown fader line or a page's signature changes, and idle ticks repaint nothing".
- "a page whose redraw fails spares the other pane and the strips, and prints once".
- "register_grid_page refuses a duplicate index, a name that is not the index's, sides outside 1-2, a missing press or redraw, an unknown field".
- "every key of every registered page runs on every arrangement" (the sweep the four layout files had: each later page is in it when it registers).
- "any_page(n) and any_page(n, side) are true while any pane of any grid shows them"; "view(port, pane) changes with the page, side and half".
- "the strips sum to sixteen keys" (`2 + GRID_PAGES.count + NUM_VOICES`).
- `grid_pages_patterns_test.lua`: on every arrangement: "a step toggles at its release", "a second key of the line sets the held step's level (16 positions, 8 on a half)", "a held step opens the step editor at 0.3 s and its release closes it", "the LEDs are step_brightness, the sounding step between steps (#113)".
- `grid_core_test.lua` gains: "set_page(port, page) shows the page on pane 1" and the fader maths moved from the 256's file.

### 5. Risks and open points

- **`lib/positions.lua` in 0e or 1m.** 0e removes the record fields, so `positions.lua`'s one-strip branches are dead from 0e on. Removing them in 0e keeps the module honest and makes the nine positions tests change once; leaving them to 1m makes 0e smaller and leaves dead code on `main` for a wave. Recommended: 0e removes them; 1m adds the pane.
- **A strip key held across a page change** (fill, a tempo repeat, a mute) stays held under the proposal; today a page change ends fill. A call.
- **Two panes on one page and side** (a 256 with patterns over patterns, both on page 2): allowed, harmless; per-port page state (the macro bank shown, the FX set, the morph corner) is shared by both panes. The design says "the picked FX set is per port", which fits.
- **`io_system_test.lua`'s 96-cell flip** may no longer fill a tick between 0e and the page packages (unsure: the patterns' lit cells depend on its random patterns; not measured).
- The 64 strip has no fill and no tempo keys, as today; the 128v has no tempo keys (as §10.2's strips draw them).
- The tempo repeat's times (0.5 s, then 0.1 s) are proposals (§ "Left to the builder").
- Unsure: whether the local-variable headroom of `lib/grid/core.lua`'s constructor and `lib/state.lua`'s constructor allows the additions (the structure test checks 30 free; not measured).

## Package 1k: the faders page (`lib/grid/pages/faders.lua`)

### 1. Files
Created: `lib/grid/pages/faders.lua`, `test/unit/grid_pages_faders_test.lua`, `docs/notes/lua/grid/pages/faders.md`, `docs/user/grid/pages/faders.md`, `changes/<branch>.md`. Edited (registration lines): `strata.lua` (one include), the `AGENTS.md` pages row (append `faders`), `docs/user/grid.md` (one link). Also `docs/user/effects.md:22` ("the grid's fader pages ... ([16×16](grid/256.md))") points at the new page.

### 2. Names and the key table
`S.register_grid_page({name = "faders", index = GRID_PAGES.faders, press, redraw, faders, signature})`. State: `pane.state().macros` (true while the port shows the bank's macros; per port, forgotten with the grid, as `port_state(port).macro_faders` is today, `faders.lua:241-268`).

| Line | x | Press | LED | Calls |
|---|---|---|---|---|
| 1-4 | 1-16 | fader lines (the engine's): the picked voice's faders `(S.param_page - 1) * 4 + line` of `fader_param_ids(S.grid_voice_select)`, or the shown bank's four (`S.lib.grid_faders.shown_macro_ids()`) while `macros`; a line with no fader is dark and dead | bar 8, value 15 | `faders(pane)` |
| 5 | 1-8 | `macros = nil`, `S.param_page = x` when `x <= fader_page_count(S.grid_voice_select)` (7 or 8 pages, `docs/decisions/3.8.md:53`); past the count nothing | `fader_page_level(x)` 15 shown / 4 other while not `macros`; 4 while `macros`; 0 past the count | `M.fader_page_level` |
| 5 | 9 | nothing | 0 | |
| 5 | 10-13 | `S.lib.macros.set_bank(b)`, `macros = true` | 15 the bank while `macros`; else 6 a bank with targets, 2 empty (`layout_256.lua:72, 130-134`) | `S.lib.macros.set_bank`, `bank`, `bank_has_targets` |
| 5 | 14-16 | nothing | 0 | |
| 6 | 1..n | set the picked voice's type to the x-th type at once | 15 the voice's type, 4 another, 0 past n | 0d: `S.lib.types.list()`, `S.lib.types.of(voice_idx)`, `S.lib.types.set(voice_idx, key)` |
| 6 | n+1..16 | nothing | 0 | n = the registry's count (12 at the release, 7 until 1f-1j land) |
| 7 | 1-7 | `macros = nil`, `select_grid_voice(x)` | 15 picked, 4 other (`LEVELS.picked`, `unpicked`) | `select_grid_voice` |
| 7 | 8-16 | nothing | 0 | |

`signature(pane)`: `S.grid_voice_select`, `S.param_page`, `fader_page_count`, `macros`, `S.lib.macros.bank()` and the picked voice's type index (the type keys light from it, and a type set on VOICE redraws no grid of its own). The fader lines' positions are followed by the engine. Turned (128v): line 5's keys run down column 5, the types down column 6, the voices down column 7; the four faders run up columns 1-4 (today's 128v faders page). On a 64: the left half shows the four faders across eight keys, p1-p8, types 1-8 and V1-V7; the right half the same faders, the banks (x 10-13 at columns 2-5) and types 9-12.

### 3. Order and seams
Needs 0e, and 0d for the type keys (wave 1 runs after wave 0, so 0d is on `main`). The type key "acts at once" (design calls list): `S.lib.types.set` must apply at once and follow §2.3's rules (works on a locked voice, clears an undo holding a synth key, keeps a frozen voice frozen); the VOICE row's settle is VOICE's alone. If 0d names it otherwise, use 0d's name (unsure: 0d's exact signature is its gatherer's).

### 4. Tests
Moved from the 256's file and re-based to pane coordinates (across the arrangements that show each key): `:11` (faders set and show, I8), `:323` (a buffer voice's faders), `:1141` (a page key past the last page), `:1182` (a fader runs the touch hooks once, as `"grid"`), `:1342` (the macros follow a bank change), the bank part of `:1241`; from the 128h and 128v files `:137`, `:204`, `:1082`, `:886` (the last page reached); from `grid_core_test.lua:1300` (the faders follow a param set off the grid within a tick); from `mutation_test.lua:524-535` (a drift tick brings a param set elsewhere). New: "a bank key shows its four macros and a fader page key goes back to the voice"; "a type key sets the picked voice's type at once and lights it; keys past the registry's count are dark"; "a type set on VOICE shows on the type row within a drift tick"; "the 64's halves show eight-key faders and both halves' keys".

### 5. Risks
- Since the groundwork a voice has 7 or 8 fader pages; with every type's keys on every voice (0d) `fader_param_ids` still follows the current type (`param_order`), so the count holds (unsure until 0d lands; the page test should assert `fader_page_count` <= 8 on every type).
- The bank is global (`S.lib.macros.bank()`): a bank key on one grid changes the bank every surface shows, as the 256's row 9 does today.

## Package 1l: the scenes page (`lib/grid/pages/scenes.lua`)

### 1. Files
Created: `lib/grid/pages/scenes.lua`, `test/unit/grid_pages_scenes_test.lua`, `docs/notes/lua/grid/pages/scenes.md`, `docs/user/grid/pages/scenes.md`, `changes/<branch>.md`. Registration lines: `strata.lua`, the AGENTS pages row, `docs/user/grid.md`. User docs with today's coordinates: `docs/user/scenes.md:18, 28, 37, 52`, `docs/user/modulation.md:63` (the pad), README.md:20 ("an XY pad on the 16×16 grid").

### 2. Names and the key table
`S.register_grid_page({name = "scenes", index = GRID_PAGES.scenes, press, redraw, faders, signature})`. State: `pane.state().corner` (1-4, A at first; per port).

| Line | x | Press | Release | LED | Calls |
|---|---|---|---|---|---|
| 1 | 1-16 | SV held in its role: `S.lib.scenes.save(x)`; else `S.lib.quantize.schedule("scene", function() recall_scene(x, 0) end, "S" .. x)` | - | `scene_recall_level(x)` 15/10/8/2 | `recall_scene`, `S.lib.scenes.save` |
| 2 | 1-16 | SV held: save x; else the same with `params:get("scene_transition_time")` | - | `scene_fade_level(x)` 6/2 | |
| 3 | 1-16 | `params:set("morph_" .. ({"a","b","c","d"})[corner], x)` | - | 15 the corner's scene, 6 populated, 2 empty (`layout_256.lua:79, 187-191`) | |
| 4 | 1-16 | fader line: `morph` | - | bar | `faders(pane)` |
| 5 | 1-16 | fader line: `morph_y` | - | bar | |
| 6 | 1-16 | `params:set("scene_sequence_length", x)` | - | 8 within the length, 2 beyond | |
| 7 | 1 SQ | `set_binary_param("scene_sequencer_enabled", ...)` toggled (echoes to a MIDI map, #538) | - | 15 on, 4 off | |
| 7 | 2 SV | `pane.press_as(2, 7, "save")` | ends | 15 while held in its role, 4 otherwise | |
| 7 | 4-7 cA-cD | `corner = x - 3` | - | 15 picked, 4 other | |
| 7 | 9-12 G1-G4 | `pane.gesture_key(x, 7, 1, x - 8)` | `pane.gesture_key(x, 7, 0, x - 8)` (acts at release; a 0.5 s hold clears) | `gesture_level(k)` 2/5/10/15 | `grid_core.gesture_key` |
| 7 | 3, 8, 13-16 | nothing | | 0 | |

SV edge cases: the save acts at the scene key's press, while SV is held in its role (`pane.pressed_as(2, 7, "save")`), and saves only (no recall). SV released before the scene key comes down: the scene key recalls. A scene key held, then SV pressed: nothing (only a press saves). SV held across a page change of its pane: its role is forgotten (`end_pane_keys`), so a scene key on the new scenes view recalls. On a 256 with scenes in both panes, each pane's SV serves its own pane (its role is the pane's key). A save while a fade runs follows `S.lib.scenes.save`'s own rules. No hold time: SV replaces the 0.5 s save hold (the design's §10.10).

**The 64's right half** (open in the design): SV sits at x 2, on the left half; scenes 9-16 are on the right half. Proposed: on a pane of width 8 showing columns 9-16, x 16 of line 7 (dark on a full pane) acts as SV, so scenes 9-16 can be saved on a 64. The alternatives are no saving of 9-16 on a 64 (use the screen), or SV on both halves of every pane (two SV keys, against the design's anti-goal). A call for the planner.

`signature(pane)`: the corner, `morph_a`..`morph_d` (as `faders.lua:202-210` reads them), the sequence length, `scene_sequencer_enabled`; the morph lines are followed by the engine. Turned: lines run down columns 1-7 (column 7's keys down rows 1-16). Halves: scenes 1-8 left, 9-16 right; line 7's SQ, SV and the corners left, the recorders right.

### 3. Order and seams
Needs 0e. Uses the core's `scene_recall_level`, `scene_fade_level`, `gesture_key`, `gesture_level` as they are. Removes nothing of the core (0e already removed `scene_save_key`). `set_param_fraction` is gone with the pad (0e); line 5 uses `set_param_from_column` through the fader line, so a gesture recorder records `morph_y` as a grid touch, as the pad did.

### 4. Tests
Moved and re-based: `grid_core_test.lua:242`, `:281` (recorders at release, two at once), `grid_layout_256_test.lua:191`, `:759`, `:1167`, `:1193`, `:1377`, the recorders of `:1241`; the 128h's `:324`, `:756`, `:779`, `:940`, `:998`; the 128v's `:255`, `:303`, `:630`, `:653`, `:777`, `:833`. New: "SV held with a recall key saves that scene and recalls nothing; a recall key alone recalls"; "SV released first: the scene key recalls"; "SV held across a page change saves nothing"; "a corner key picks which of morph_a to morph_d line 3 shows and sets, per port"; "lines 4 and 5 set morph and morph_y as grid touches a recorder records"; "on a 64's right half x 16 of line 7 is SV" (if the call stands); "a sequence-length key repaints the grid once (#161)".

### 5. Risks
- The XY pad's two-axis press goes; a gesture that recorded the pad played both params as grid touches, and the two faders do the same, one at a time.
- `docs/user/modulation.md:63` and README.md:20 name the pad.

## Package 1m: the positions page and its second side (`lib/grid/pages/positions.lua`)

### 1. Files
Created: `lib/grid/pages/positions.lua`, `test/unit/grid_pages_positions_test.lua`, `docs/notes/lua/grid/pages/positions.md`, `docs/user/grid/pages/positions.md` (it takes `docs/user/grid.md`'s "Positions" `:42-63` and "Slice rows" `:64-72`, and the docs test's loop-edge and record-key checks), `changes/<branch>.md`. **Edited outside its page** (the design gives it none): `lib/positions.lua` (the pane argument and the view tag: `grid_key` `:560-589`, `strip_key` `:593-675`, `press_slice_key` `:428`, `end_stale_port` `:482-518`), `test/unit/positions_test.lua` (the direct calls gain the pane), `lib/buffers.lua:830` (the gate, §0 point 5), `test/unit/playheads_test.lua:475-600` (the strips' LEDs on side 2), `test/unit/docs_test.lua:1952-1980` (the Positions and record-key checks on the page's user doc), `docs/notes/lua/positions.md`, `docs/user/slices.md:33`. Registration lines as above.

### 2. Names and the key table
`S.register_grid_page({name = "positions", index = GRID_PAGES.positions, sides = 2, press, redraw})`.
- `S.lib.positions.grid_key(port, voice_idx, cell, cells, z, pane)` (today 5 arguments, `positions.lua:560`): pane defaults to 1. Each press record keeps `view = S.lib.grid_core.view(port, pane)` in place of `page = S.lib.grid_core.page(port)` (`:428`, `:587`), and `end_stale_port` (`:482-518`) ends an entry whose pane's view differs. `M.strip_key(port, voice_idx, key, z, pane)` (`:593`) likewise for `record.hold[voice] = view`, `record.store[voice] = view`.
- `S.lib.buffers` (`:830`): `if any_page(GRID_PAGES.sources) or any_page(GRID_PAGES.positions, 2) then grid_redraw() end`.

Side 1 (lines = voices, x = cell 1-16):

| Line | x | Press | Release | LED |
|---|---|---|---|---|
| 1-7 | 1-16 | `S.lib.positions.grid_key(port, y, x, GRID_PAGES.position_cells, 1, pane.index)`: jump (quantized), a held pair sets the loop, a slice row plays its slice (buffer voices only) | `grid_key(..., 0, pane.index)`: ends a held key or a slice | `S.lib.positions.grid_level(y, x, 16, port)` (playhead 15, record head 13, held 11, loop 4-8, outside 1-3; slices 15/11/9/0) |

Side 2:

| Line | x | Press | Release | LED |
|---|---|---|---|---|
| 1-7 | 1-4 | `strip_key(port, y, x, 1, pane.index)`: recall (quantized); with ST held, store; on a slice row the bank | `strip_key(..., 0, ...)` | `strip_level(y, x, port)` |
| 1-7 | 5 | nothing | | 0 |
| 1-7 | 6 ST | `strip_key(port, y, "store", 1, ...)` | ends store | `strip_level(y, "store", port)` 15 held / 4 |
| 1-7 | 7 HD | `"hold"` | ends the scan hold | 15 while held by anyone / 4 |
| 1-7 | 8 WH | `"whole"` | - | 15 while whole / 4 |
| 1 | 9-16 | `grid_core.record_key(x - 8)` (again while recording stops and keeps; armed cancels) | - | `record_level(slot)` 11/15/8/2 |
| 2 | 9-16 | `grid_core.clear_key(x - 8)` | - | `CLEAR_LEVEL` 4 |
| 3-7 | 9-16 | nothing | | 0 |

Turned: cells run down each voice's column; side 2's keys down the column. Halves: cells 1-8 or 9-16 (a two-key loop only within the shown half on a 64); side 2's marks on the left half, the slots on the right. Redraws: the playheads' 15 Hz clock (`any_page(5)` after 0e) and the peaks read; the slots through `buffers.lua:830`.

### 3. Order and seams
Needs 0e (`view`, the side, the dead one-strip code already gone if 0e takes it). `lib/positions.lua` is no other wave-1 package's in §14, but 1d edits "one line at each site" of the source tests: `positions.lua:67` (`voice_uses_buffer`) and `playheads.lua:40` read a source test; land 1m after 1d or keep the edits apart (different lines). `lib/buffers.lua` is 1d's too (its sources): one line each.

### 4. Tests
Moved and re-based to the harness on side 1 and side 2: the 256's `:1011`, `:1023`, `:1058`, `:1075`, `:1119`, `:1554` and the record and clear parts of `:362`/`:372`; the 128h's `:453`, `:482`, `:494`, `:512`, `:544`, `:636`, `:654`, `:675`, `:1021`, `:1051`, `:1067`; the 128v's `:397`, `:424`, `:530`, `:856`; the 64's `:318`, `:334`, `:427`, `:438`, `:456`, `:567`; `playheads_test.lua:475-600` (the marks' LEDs on side 2). New: "a press on a 256's lower pane is ended by the lower pane's page change, not the upper's" (the view tag); "positions over its second side on a 256: a store held below stores a bookmark recalled above"; "side 2's record and clear keys record and clear slots 1-8 and light from record_level"; "a slot's state change redraws a grid on side 2"; "the 64's halves show cells 1-8 and 9-16".

### 5. Risks
- The page key pressed again on a grid already on side 2 goes back to side 1 (a cycle of two): the design says "the page's next side".
- A record key's level follows the slot's status, which the playheads clock does not watch: the `buffers.lua:830` line is required (and record state changes that do not go through that poll: unsure; `lib/record.lua` was not read for its redraws).

## Package 2c: the sources page (`lib/grid/pages/sources.lua`)

### 1. Files
Created: `lib/grid/pages/sources.lua`, `test/unit/grid_pages_sources_test.lua`, `docs/notes/lua/grid/pages/sources.md`, `docs/user/grid/pages/sources.md`, `changes/<branch>.md`. Registration lines as above. User docs: `docs/user/sources-and-buffers.md` (its grid line).

### 2. Names and the key table
`S.register_grid_page({name = "sources", index = GRID_PAGES.sources, press, redraw, signature})`. Source options after 1d: 1 synth, 2-9 buffers 1-8, 10 input, 11-17 voices 1-7 (`SOURCE_VOICE_FIRST` 11, design §1); the input channel `v<i>_input_channel` (stereo, left, right). Names are 1d's (`S.constants.SOURCE_VOICE_FIRST`, `SOURCE_INPUT`, `voice_uses_voice(i)`, `voice_uses_input(i)`).

| Line v | x | Press | LED |
|---|---|---|---|
| v | x = v (own) | source not synth: `params:set("v<v>_source", SOURCE_SYNTH)`; synth: the voice's own output (`SOURCE_VOICE_FIRST + v - 1`); own output: back to synth | synth 15; own output blinks 15/6 (0.5 s each); otherwise 4 |
| v | x in 1-7, x ~= v | `v<v>_source = SOURCE_VOICE_FIRST + x - 1` | 15 selected; 4 the read voice running, 2 stopped (proposed) |
| v | 8 `in` | not input: input (the channel kept); input: the next channel (stereo -> left -> right -> stereo) | selected: stereo 15, left 11, right 7 (proposed); not selected 4 |
| v | 9-16 | `v<v>_source = SOURCE_SYNTH + (x - 8)` (buffer x - 8) | 15 selected, 2 a free slot (`S.lib.buffers.is_free`), 4 a slot holding audio |

`grid_core.source_key` and `source_level` (`core.lua:489-500`) number options 1-10 and give an input or voice option `is_free(option - 1)` (no such slot: 4); the page keeps its own mapping and levels (it may call `source_key(voice, option)`, which accepts any option up to `#SOURCE_OPTIONS`, 17 after 1d). `signature(pane)`: the blink phase (`math.floor(util.time() * 2) % 2`) while a voice reads its own output, and each voice's input channel. Freeze leaves this page (it is the voices page's FZ). Redraws: `buffers.lua:830`'s gate (already the sources page), `toggle_voice` redraws the grids.

### 3. Order and seams
Needs 1d (the seventeen sources, the channel param). Uses nothing of 1m (the slot keys are on positions' second side). Must not assume the positions page exists.

### 4. Tests
Moved: the sources parts of the 256's `:362`, `:372`; the 128h's `:223`, `:264`; the 128v's `:168`. New: "the own column: synth, pressed again the voice's own output (blinking), again synth"; "another voice's column reads that voice"; "in steps the channel while selected"; "a slot holding audio is brighter than a free one"; "the blink redraws through the drift tick only while a voice reads itself".

### 5. Risks
- The blink needs a periodic redraw; the drift tick is 10 Hz, so a 0.5 s blink is drawn within 0.1 s of each change (fine).
- The own-voice press cycle (synth -> own -> synth) is a proposal; the design says only "pressed again while lit, it is the voice's own output".

## Package 4b: the FX page (`lib/grid/pages/fx.lua`)

### 1. Files
Created: `lib/grid/pages/fx.lua`, `test/unit/grid_pages_fx_test.lua`, `docs/notes/lua/grid/pages/fx.md`, `docs/user/grid/pages/fx.md`, `changes/<branch>.md`. Registration lines as above. Comments: `lib/params_setup.lua:50-53` and `lib/delay_sync.lua:163` keep calling `any_fx_faders()` (0e's alias); no edit needed.

### 2. Names and the key table
`S.register_grid_page({name = "fx", index = GRID_PAGES.fx, press, redraw, faders, signature})`. State: `pane.state().set` (1 DL, 2 RV, 3 MA; DL at first; per port, as the design calls).

| Line | x | Press | LED |
|---|---|---|---|
| 1-5 | 1-16 | fader lines of the set: DL `S.lib.grid_faders.fx_fader_id("delay_time")` (the division while synced, `faders.lua:130-135`), `delay_feedback`, `delay_mix`, `delay_pingpong`, `shimmer_delay`; RV `reverb_mix`, `reverb_size`, `reverb_damp`, `shimmer_reverb`, `delay_to_reverb`; MA `filter_freq`, `filter_res`, `filter_mix`, `master_density`, `drift_amount` | bar |
| 6 | 1-3 | `set = x` | 15 picked, 4 other |
| 6 | 5-9 | `params:set("shimmer_interval", x - 4)` | 15 the interval, 4 another |
| 7 | 1 db | `set_binary_param("delay_bypass", ...)` toggled | proposed 8 the delay plays, 2 bypassed (as a mute key shows what is heard) |
| 7 | 2 ds | `delay_sync` toggled | 15 on, 4 off |
| 7 | 3 DF | `delay_freeze` toggled | 15 frozen, 4 not |
| 7 | 4 DC | `delay_clear` (a trigger: `params:set("delay_clear", 1)`, 1b's form) | 15 while held, 4 |
| 7 | 6 rb | `reverb_bypass` toggled | 8 / 2 |
| 7 | 7 RF | high tier: `reverb_freeze` toggled; standard: nothing | 15 / 4; dark (0) on standard (`S.performance.tier`) |
| 7 | 9-11 | `params:set("filter_type", x - 8)` (1 lowpass, 2 highpass, 3 bandpass, `params_setup.lua:483-485`) | 15 the type, 4 another |
| 7 | 12 fm | `S.lib.params_setup.toggle_filter_mix()` (`:40-48`: never writes `S.fx_last_mix` itself, AGENTS "Filter restore mix") | 15 mix above 0, 4 at 0 |
| 6, 7 | the rest | nothing | 0 |

`signature(pane)`: the set, `shimmer_interval`, the seven binaries and `filter_type`, `filter_mix > 0`, `delay_sync` (the time line's param changes with it). The fader lines follow through the engine, so the new params need no `fx_fader_changed` call.

### 3. Order and seams
Needs 1a (`delay_to_reverb`; `delay_mix`/`reverb_mix` as levels), 1b (`delay_freeze`, `delay_clear`, `S.lib.fx_hold`), 2a (`shimmer_delay`, `shimmer_reverb`, `shimmer_interval`, five values), 3a (`reverb_freeze` and what says it is available; proposed `S.performance.tier == "high"` unless 3a gives a function). Names are the design's (§7); confirm each against the landed packages. A bypass ends a freeze in Lua (§7.3: the bypass param's action sets the freeze off), so `db` needs nothing extra.

### 4. Tests
Moved: the 256's `:238` (FX faders), `:272` (the division while synced), `:300` (a scene transition redraws once per step), `grid_core_test.lua:702` (the redraw gate, now `any_page(fx)`). New: "the three sets' five faders"; "the interval keys"; "line 7's keys and LEDs"; "RF is dark and does nothing on the standard tier"; "fm toggles the filter mix and leaves S.fx_last_mix to params_setup"; "a param set elsewhere reaches the FX page within a drift tick"; "the set is per port".

### 5. Risks
- `delay_clear`'s param form (a trigger) is 1b's; if it is an action-only param, the press calls 1b's function (`S.lib.fx_hold.clear()` or similar: unsure).
- Five rows of faders at 16 keys, eight on a 64: the time fader's division picks twelve values over eight keys there.

## Package 4c: the voices page (`lib/grid/pages/voices.lua`)

### 1. Files
Created: `lib/grid/pages/voices.lua`, `test/unit/grid_pages_voices_test.lua`, `docs/notes/lua/grid/pages/voices.md`, `docs/user/grid/pages/voices.md`, `changes/<branch>.md`. Registration lines as above. User docs: `docs/user/pages/voice.md:28` ("On the grid it has keys on the 256, 128h and 128v layouts"), `docs/notes/lua/freeze.md`, `docs/notes/lua/sequencer.md` (the 256's paste).

### 2. Names and the key table
`S.register_grid_page({name = "voices", index = GRID_PAGES.voices, press, redraw, faders, signature})`. State per port: `pane.state().patterns = {voice, steps}` (pattern clipboard), `pane.state().sound = {voice}` (voice copy). Line v is voice v.

| x | Key | Press | Hold | LED |
|---|---|---|---|---|
| 1 | MU | `set_binary_param("v<v>_mute", ...)` toggled | - | proposed 15 muted, 4 not (as the 256's lower strip) |
| 2 | SO | `v<v>_solo` toggled | - | 15 soloed, 4 not |
| 3 | LK | `toggle_lock(v)` | - | `lock_level(v)` 12/2 |
| 4 | FZ | `S.lib.freeze.toggle_quantized(v)` (waits for the beat under `quantize_actions`) | - | 15 frozen, 3 not (`layout_256.lua:41-42`) |
| 5 | CL | arms `pane.on_hold(5, v, GRID_HOLD.scene_save_seconds, ...)` | 0.5 s: `clear_pattern(v)`, `grid_redraw()`, `request_redraw()` | 15 while pending, 2 otherwise (`layout_256.lua:58-59`) |
| 6 | RN | the same | 0.5 s: `randomize_pattern(v)` | 15 / 2 |
| 7 | PC | no copy: copy v's steps (a snapshot); a copy of another voice: `S.lib.sequencer.replace_pattern(v, steps)` (the copy stays for more pastes); the copied voice's key: drop the copy | - | 15 the copied voice, 4 the others while a copy exists, 2 with none (`layout_256.lua:36-38`) |
| 8 | VC | no copy: mark v; a mark of another voice: `S.lib.voice_presets.copy(mark, v)` (3b; the mark stays); the marked voice's key: drop the mark | - | 15 / 4 / 2 |
| 9-16 | lv | a fader line of 8 keys, `v<v>_amp` (the voice's level, MAIN's `level`) | - | bar |

Edge cases (the design's "a copy dropped", "a release order", "a key held across a page change"): every key here acts at its press, but CL and RN, which act at their hold; their release before 0.5 s does nothing, and a page change of their pane cancels the hold (`end_pane_keys`). A copy (PC or VC) survives a page change and a pane's page change (per port), and goes with the grid (`forget_port`). Pressing the copied voice's key drops the copy; there is no other way, so a copy from another voice needs that press first (no KX key). A paste of a pattern ends the pasted voice's step gestures on every grid (`replace_pattern` -> `end_step_gestures`). A voice copy reads the source voice's sound at the paste (3b's `copy` captures then), not at the copy press: the LED says only which voice is marked. A voice copy onto a voice in a running fade lets the fade go of it (3b's `release_voice`) and is undone by ALT+K2 on VOICE (3b's `hold_voice`). Mute and solo stay separate keys (the 256's tap-to-mute, hold-to-solo goes). The 256's lower strip's mutes and this page's MU are one action in two places (§10's allowed repeat).

`signature(pane)`: each voice's mute, solo, lock, freeze, the clipboards. Turned: the eight keys run down rows 1-8 of each voice's column, the level fader up rows 9-16. Halves: the left half shows the eight keys, the right half the level fader across its eight keys.

### 3. Order and seams
Needs 3b (`S.lib.voice_presets.copy(from, to)`, `S.lib.mutation.hold_voice`, `S.lib.scenes.release_voice`). Uses `toggle_lock`, `S.lib.freeze.toggle_quantized`, `clear_pattern`, `randomize_pattern`, `S.lib.sequencer.replace_pattern` as they are. The 256 starts on patterns over voices only once this lands (0e's fallback before).

### 4. Tests
Moved: the 256's `:585`, `:623`, `:655`, `:669` (copy and paste, re-specified: a press on the copied voice drops the copy), `:826` (clear and randomize at 0.5 s), `:875` (locks), `:907` (freeze), `:1284` (mute and solo, now two keys), `:1484` (freeze waits for the beat); the 128h's `:361`; the 128v's `:42`, `:340`; the solo and recorder-free parts of `grid_core_test.lua:298`. New: "VC marks a voice, another VC press loads its sound into that voice through voice_presets.copy, the marked key drops it"; "the level fader sets v<v>_amp across eight keys on every arrangement"; "CL held across a page change clears nothing"; "a copy survives a page change and goes with the grid".

### 5. Risks
- "lv is the voice's level": `v<v>_amp` is proposed (the MAIN `level`); 1a's new `v<v>_dry` is the other reading. A call.
- MU's level: the 256's mute key today is 2 muted, 15 soloed, 8 otherwise (one key for both); with two keys the proposal is 15 on, 4 off for each.

## The order the six page packages land, and what none may assume

- 1k, 1l and 1m need only 0e (1k also 0d's `S.lib.types`, on `main` before wave 1): any order in wave 1. 1m edits `lib/positions.lua`, `lib/buffers.lua:830` and `playheads_test.lua`, and 1d edits source-test lines in `positions.lua` and `buffers.lua`: different lines; land 1m before or after 1d, never in the same batch without a rebase check.
- 2c needs 1d (wave 2). 4b needs 1a, 1b, 2a, 3a; 4c needs 3b (wave 4). Each owns only its page file, its test file, its notes file and its user page, plus three registration lines: an include in `strata.lua`, its name in the AGENTS pages row, a link in `docs/user/grid.md` (keep both at a conflict, in page order).
- No page assumes another exists: every strip key of a page with no record is dark and dead; the 256's lower pane falls back to patterns until 4c; the engine's sweep test covers whatever pages are registered.
- No page writes per-port state outside `pane.state()` (its own name's table), nor any physical coordinate, nor a core helper's physical key without the pane's wrapper.
- No page re-implements the strips, the page keys, the chooser or fader drawing; a page that needs a new kind of key (a blink, a repeat) asks for it in the pane engine through its own `signature` and the core's `on_hold`, not by editing `lib/grid/pane.lua` or `lib/grid/core.lua` (owned by 0e; a needed change there is a separate pull request).
- The page-key LED of a page with two sides is the engine's; only the positions page has two.

## For the planner

1. **A page change must end only its own pane's keys.** `set_page` today ends every hold, role and step key of the port (`lib/grid/core.lua:85-93, 222-228, 378-384`); two panes need `end_pane_keys(port, pane)` from the layout's `pane_at`, and strip keys are never ended. The design is silent.
2. **1m must edit `lib/positions.lua`, `lib/buffers.lua:830` and `playheads_test.lua`**, which §14 gives it nowhere: positions tags each press with `page(port)` (`positions.lua:428, 587, 596`) and the slot keys' redraw gate is the sources page only.
3. **0e must remove three layout record fields and with them `positions.lua`'s one-strip code** (20 grep lines; `selects_grid_voice`, `rows_show_grid_voice`, `strip_page`), and rewrite nine `positions_test.lua` tests (`:210, 226, 752, 765, 779, 821, 838, 857, 946`) that plug a 16x8 or 8x8 to get them.
4. **`set_page` should accept a page with no record** (drawn dark; only strip keys refuse it), or `buffers_test.lua:1058`, `playheads_test.lua:313-360`, `waveforms_test.lua:162-172` and `io_system_test.lua:486` lose their redraw gates between 0e and the page packages.
5. **The four fader helpers need a width argument** (`faders.lua:67, 79, 94, 146` read a fixed 16) for the 64's eight-key faders and the voices page's level; fader lines belong to the engine, declared by `faders(pane)`.
6. **Keep `any_fx_faders()` and `follow_faders()` as names** (one-line alias, generalized body), so `params_setup.lua:55`, `delay_sync.lua:163` and `mutation.lua:297`, owned by wave-1 packages, need no edit; the drift tick's follow of every shown fader line gives 4b's new params their redraw.
7. **Of the 230 grid tests about 85 stay with 0e, about 90 move to the six page packages, about 55 are deleted** (counts by name, above); fader maths tests move to `grid_core_test.lua`, and a pane harness with six arrangements replaces physical coordinates.
8. **`test/unit/stubs_test.lua:17-40` and `structure_test.lua:440-449` must change in 0e** (the stub state's registries; 18 global names leave `MODULE_HOMES`), and `docs_test.lua:938-950, 1946-1980` assume every file under `docs/user/grid/` is a layout's.
9. **Three calls the design leaves open**: whether fill survives a page change (proposed yes), SV on a 64's right half (proposed x 16 on a half pane), and whether `lv` is `v<v>_amp` or 1a's `v<v>_dry` (proposed amp).
10. **0e's `AGENTS.md` edits are about +100 words** (`:120-121, 127, 136, 276, 340-345` plus two rows) and `:136`'s registry count is also 0d's line.

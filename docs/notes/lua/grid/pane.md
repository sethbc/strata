## Must not break

- **A page never names a physical coordinate**: it is written in pane coordinates (x 1-16 along a line, y 1-7 the lines; a line is a voice on patterns, sources, positions and voices) and reaches the core only through the pane object's wrappers (`pane.step_key`, `pane.on_hold`, `pane.press_as`, ...) and draws only through `led(x, y, level)`, so it is the same on every layout. Only the pane engine maps a pane key to a physical one.
- **A fader line's keys are the engine's**: a page lists its lines in `faders(pane)`; the engine sets them (`set_param_from_column(id, k, keys)`) and draws them, and the page's `press` and `redraw` never see those keys.
- **A page change ends only its pane's keys, never a strip key** (ruling 54): the strips' keys (fill, a tempo repeat, a mute, NV) go on across any page change; a grid's removal and cleanup still end them.
- **A page with no record is dark and its page key dead**; `set_page` still shows it (ruling 55), and a start page with no record starts on patterns.
- **Each pane's redraw is contained** (`S.lib.ui_frame.contained_call`, keyed `port .. ":" .. pane`, label `grid page redraw`), so a failing page prints once per distinct message and spares the other pane and the strips.
- The registry is open: `S.registry.grid_pages` is read at each press, redraw and follow, never at include or init, so a test can put a probe page at a free index of its own `S` (`h.probe_grid_page`, `h.no_grid_page`).
- The strips are built from `GRID_PAGES.count` and `NUM_VOICES` and sum to sixteen keys (`2 + 7 + 7`); a test pins it.
- Per-port state (the 64's chooser, a page's `pane.state()`) lives in `port_state(port)`, so it goes with the grid.

## Owns

- `lib/grid/pane.lua` (`S.lib.grid_pane`, included after `lib/grid/faders.lua` and before the pages and the layouts): `arrange(spec)`, `STRIPS`, `physical(layout, pane, x, y, half)` (the harness's way to a key), `signature()`. Locals: `PANE` (widths, the strip line, the strip and chooser levels, the chooser's rows), `KEY_ACTIONS`, the geometry of each arranged record (`geometries`, weak keys), `physical_of`, `locate`, `pane_object`, `shown_lines`, `place_on`, `draw_line`, the chooser (`chooser_shown`, `chooser_choice`, `chooser_key`, `draw_chooser`, `chooser_strip_key`), `tempo_key`, `page_key`, `strip_key`, `strip_level`, `take_key`, `draw_page`, `draw_grid`, `redraw_errors`.
- The registry `S.registry.grid_pages` and `S.register_grid_page` (`lib/state.lua`, `docs/notes/lua/state-and-voices.md`).
- Unit tests: `test/unit/grid_pane_test.lua`; the harness in `test/helpers.lua` (`h.grid_pane`, `h.GRID_ARRANGEMENTS`, `h.probe_grid_page`, `h.no_grid_page`, `h.resize_grid`).

## The model (design §10.1)

A grid is one or two **panes**, each showing one of the seven pages (`S.constants.GRID_PAGES`: patterns 1, faders 2, scenes 3, sources 4, positions 5, voices 6, fx 7), with a strip of fixed keys. State is per port and pane (`S.grid_panes[port][pane] = {page, side, half}`, the core's). `S.param_page` and `S.grid_voice_select` stay shared by every grid.

### The arranger

`arrange(spec) -> {key = fn(port, x, y, z), redraw = fn(port, device), panes, pane_at = fn(x, y) -> pane or nil, start_pages}`. A spec:
- 128h: `{panes = {{x = 0, y = 0, strip = {row = 8, keys = "upper"}}}}`
- 256: `{panes = {{x = 0, y = 0, strip = {row = 8, keys = "upper"}}, {x = 0, y = 8, strip = {row = 16, keys = "lower"}}}, start = {patterns, voices}}`
- 128v: `{turned = true, panes = {{strip = {column = 8, keys = "upper"}}}}` (pane x is the physical row, y the column)
- 64: `{half = true, panes = {{strip = {row = 8, keys = "small"}}}}` (pane column x at physical column `x - offset` while `offset < x <= offset + 8`)

`start` defaults to patterns for every pane; the core reads `start_pages` for a pane with no entry and starts a page with no record on patterns. `pane_at(x, y)` is the pane of a physical key, nil for a strip key or none; the core's `end_pane_keys` reads it.

### The pane object

Built per key and per redraw for (port, pane) and handed to the page: `port`, `index` (1 top, 2 bottom), `page`, `side`, `width` (16, or 8 on a 64), `offset` (0, or 8 on a 64's right half), `turned` (the 128v), `shows(x)`, `state()` (`port_state(port)[record.name]`, made on demand; a port's two panes on one page share it), and the wrappers in pane coordinates, each calling the core with the physical key (nil off the pane): `held`, `hold_pending`, `on_hold(x, y, seconds, fn)`, `consume`, `consumed`, `press_as(x, y, role)`, `pressed_as(x, y, role)`, `gesture_key(x, y, z, k)` and `step_key(x, y, z, voice, step)`, which passes position `x - offset` of `width`, so a level follows the keys shown. The redraw's `led(x, y, level)` takes pane coordinates and drops a key the grid does not show and any y outside 1-7.

### Dispatch

For a physical key: the strip; else, on a 64 while the chooser shows, the chooser; else a fader line of the pane's page; else the page's `press(pane, x, y, z)` (a press, and a release the core did not swallow as consumed). A pane on a page with no record takes no keys and draws dark. The redraw draws each pane (its page contained, then its fader lines; or the chooser), then its strip.

### The strips (design §10.2)

`STRIPS.upper = {"play", "fill", "page 1" .. "page 7", "voice 1" .. "voice 7"}` (the 128h's row 8, the 256's row 8, the 128v's column 8 top to bottom), `STRIPS.lower = {"tempo -", "tempo +", "page 1" .. "page 7", "mute 1" .. "mute 7"}` (the 256's row 16), `STRIPS.small = {"chooser", "voice 1" .. "voice 7"}` (the 64's row 8). In pane coordinates the strip is line 8, x its key.

| Key | Press | Hold / release | LED |
|---|---|---|---|
| PL | `pattern_toggle()` | - | `play_level()` 15 / 4 |
| FL | `press_as(.., "fill")`, `S.lib.conditions.hold_fill("grid:" .. port, true, still)`, `still` true while the key is held in its role | release: `hold_fill(holder, false)`; never ended by a page change | 15 while `fill()`, 4 |
| P1-P7 | no record: nothing; not shown: `set_page(port, n, pane, 1)`; shown with `sides` 2: the other side | - | 0 no record; shown 15 (side 2: `side_two` 10); other 2 |
| O1-O7 | `toggle_voice(v)` | - | `voice_level(v)` 12 / 6 / 2 |
| T- T+ | `params:delta("tempo", -1 / 1)`, flash `tempo %d` from `S.lib.params_setup.clock_tempo_now()` | held: again after `GRID_HOLD.tempo_repeat_delay` (0.5 s), then every `tempo_repeat_seconds` (0.1 s), an `on_hold` that arms itself; the release stops it | 15 held, 4 |
| M1-M7 | `v<i>_mute` toggled through `set_binary_param` | - | 15 muted, 4 |
| NV | `press_as(.., "chooser")`, `on_hold(GRID_HOLD.chooser_seconds)` shows the chooser and ends the pane's keys | release before the hold: `pattern_toggle()`; after: the chooser closes, nothing plays | `play_level()`; 15 while the chooser shows |

### The 64's chooser

While NV is held past 0.5 s (`port_state(port).chooser`): column c is page c; row 1 its left half, row 2 its right, rows 3 and 4 side 2's halves. A press sets page, side and half at once (`set_page`, `set_half`: the pane's keys end) and is consumed, so its release does nothing; the chooser stays until NV comes up. LEDs: the shown choice 15, a registered page's other keys 4, a one-sided page's side-2 rows and a page with no record 0 (and dead). Column 8 and rows 5-7 are dark and dead while it shows. The chooser opening ends the pane's held keys, as a page change does.

### Fader lines

A page's `faders(pane)` returns `{{line, first, keys, id}, ...}` (keys 16 or 8). A line that fits the pane's shown columns is set and drawn as it is (its key k is `x - first + 1`; on the 128v it runs up, `k = first + keys - x`, row 16 the minimum); a line wider than a 64's half is drawn across the half's eight keys (`k = x - offset`, at 8 keys); an 8-key line on the other half is not shown (its keys reach the page). A press (z 1) runs `set_param_from_column(id, k, keys shown)`; a release does nothing. The draw is a bar at 8 up to `fader_position(id, keys shown)`, 15 there.

### The follow

`signature()`: for each pane of each connected grid (ports in order) whose page has fader lines or a `signature`, `view(port, pane)`, each shown line's position and `record.signature(pane)`; nil when no pane has any. `S.lib.grid_faders.follow_faders()` (the drift tick) redraws the grids when it differs from its last look, so a page needs no param action of its own to follow a param set elsewhere.

## Registering a page

A file `lib/grid/pages/<name>.lua` (`S.lib.grid_pages_<name>`, its include in `strata.lua` after the pane engine's and before the layouts') calls `S.register_grid_page({name, index = S.constants.GRID_PAGES.<name>, press, redraw, sides?, faders?, signature?})` at include; its notes are `docs/notes/lua/grid/pages/<name>.md`, its user page `docs/user/grid/pages/<name>.md` (linked from `docs/user/grid.md`), its tests `test/unit/grid_pages_<name>_test.lua`, written on the harness (`h.grid_pane` over `h.GRID_ARRANGEMENTS`). Refused (naming `register_grid_page`): a duplicate index, a name that is not `GRID_PAGES.names[index]`, `sides` not 1 or 2, a missing `press` or `redraw`, any other field.

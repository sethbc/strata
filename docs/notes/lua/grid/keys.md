## Must not break

- **A cell key is the core's, as a step key is**: a lane's line takes its keys through `pane.cell_key(x, y, z, id, index, on_tap, on_value)` only, and the core (`lib/grid/core.lua`, `cell_key`) alone decides a tap from a second key. A tap's `on_tap` runs at the release (`release_cell_key`, from `handle_key`, whatever the page does with `z == 0`), and only for a held cell that is neither consumed nor ended; a second key of the same `id` on the same port calls the held cell's own `on_value(held index, position, positions)` and consumes both keys. No hold clock and no editor belong to a cell.
- **A pane's change ends a held cell as it ends a held step**: `end_pane_keys` (a page, side or half change, the 64's chooser opening) and `forget_port` (an unplug, a rotation, a plug, cleanup) drop the cell entries of the keys they reach, so the key's release taps nothing and its line takes no value from it. A pattern's replacement leaves a held cell (its lane values are no step gesture).
- **`still` carries a token of its own press, never the press time or a role**: every press puts a fresh token at the key (`press_tokens`), and `still(port, x, y)` (the pane's `pane.still(x, y)`) compares the token it read with the key's. The harness clock does not move between a release and the next press, so a press time would be true again for a later press; a role string is true again for a later press in the same role. A pattern's replacement never ends a still: a loop and a roll outlive a replacement and end with their key (3.9's 5a, 5b).
- **Only a held key is a cell key or has a press token**: the `grid keys` invariant (`docs/notes/lua/grid-core.md`, Machines) walks both tables with the other per-key ones.
- **The step view is computed, never recorded** (3.9's 3c): `step_view(port)` reads `step_editor.key`, `S.lib.pages_seq.step_editor()` and what the panes show, so it ends with the editor however the editor ends. Its start (`open_step_editor`, a second open ending the first's) and its end (`end_step_view`, which `close_step_editor` calls before it forgets its editor, then repaints the grids) end the view pane's keys through `end_pane_keys(port, pane, spare)`, sparing the editor's key: that key keeps its step entry and consumed mark, so the editor stays open and the `grid keys` invariant's #930 clause holds. `close_step_editor_of` reads the view, forgets `step_editor.key` before the close (a close that raises leaves no key on an ended gesture) and ends the view's keys itself after it, so `end_step_view` there finds no view.

## Machines

### grid cell key
- **State:** per port and key, `cell_keys[port][x][y]` (a core local): `{id, index, on_tap, on_value}` for a held cell, `{id, second = true}` for a spent second key; read through `held_cell(port, x, y)` (the id and index of a held cell, nil for a spent second key or no cell), with the key's `held` and `consumed`. The table follows one key, (5, 2) of a 256's pane 1 showing a two-sided probe whose every key is a cell key of its line (`"line 2"`, index 5), and a second key (8, 2) of the same line.
- **Invariant:** none of its own: the `grid keys` invariant (`docs/notes/lua/grid-core.md`) checks that only a held key is a cell key.
- **Test:** `test/unit/grid_core_test.lua`: "grid cell key: every cell is decided" and its rows; on every arrangement, `test/unit/grid_pane_test.lua`'s "a cell tap calls on_tap at its release", "a second key gives the held cell its place" and "a held cell ends at a side change and at an unplug"; the 64's chooser: "the 64's chooser opening ends a press's still and a held cell".

`held` is a held cell, `spent` one a second key consumed, `dropped` a held key whose cell a pane's change ended and `ended` a spent one so ended. The checks release both keys and count the taps and the values set.

| State | Event | Next | Effect |
|---|---|---|---|
| `up` | `press` | `held` | the line's held cell; its release taps index 5 |
| `up` | `release` | `up` | a release the core never saw pressed does nothing |
| `up` | `second key` | `up` | the other key is a held cell of its own and taps 8 |
| `up` | `page change` | `up` | nothing held |
| `up` | `side change` | `up` | nothing held |
| `up` | `unplug` | `up` | nothing held |
| `held` | `press` | `held` | a press with no release before it starts over; one tap at the release |
| `held` | `release` | `up` | `on_tap(5)` |
| `held` | `second key` | `spent` | `on_value(5, 8, 16)`; both keys consumed, neither release taps |
| `held` | `page change` | `dropped` | the pane's keys end; the release taps nothing |
| `held` | `side change` | `dropped` | the same |
| `held` | `unplug` | `up` | the port is forgotten; plugged back, the release taps nothing |
| `spent` | `press` | `held` | a held cell again; its release taps |
| `spent` | `release` | `up` | nothing taps |
| `spent` | `second key` | `spent` | the second key pressed again sets the value again |
| `spent` | `page change` | `ended` | the cell ends; the consumed mark stays |
| `spent` | `side change` | `ended` | the same |
| `spent` | `unplug` | `up` | the port is forgotten |
| `dropped` | `press` | `held` | a held cell again |
| `dropped` | `release` | `up` | nothing taps |
| `dropped` | `second key` | `dropped` | no held cell on its line: the other key is its own and taps 8 |
| `dropped` | `page change` | `dropped` | nothing more to end |
| `dropped` | `side change` | `dropped` | nothing more to end |
| `dropped` | `unplug` | `up` | the port is forgotten |
| `ended` | `press` | `held` | a held cell again |
| `ended` | `release` | `up` | nothing taps |
| `ended` | `second key` | `ended` | the other key is its own and taps 8; no value |
| `ended` | `page change` | `ended` | nothing more to end |
| `ended` | `side change` | `ended` | nothing more to end |
| `ended` | `unplug` | `up` | the port is forgotten |

### grid key still
- **State:** per port and key, `press_tokens[port][x][y]` (a core local, a fresh table at each press, cleared at the release, by `end_pane_keys` and by `forget_port`), against the token a `still` function read when it was made (`M.still(port, x, y)`, through `pane.still(x, y)`). The table follows the still the first press of (3, 2) gave, on a 64 on port 1 showing a two-sided probe whose every press asks `pane.still` of its place.
- **Invariant:** none of its own: the `grid keys` invariant (`docs/notes/lua/grid-core.md`) checks that only a held key has a press token.
- **Test:** `test/unit/grid_core_test.lua`: "grid key still: every cell is decided" and its rows; on every arrangement, `test/unit/grid_pane_test.lua`'s "still is true while the press is down and false after its release, a page change, a side change, a half change and an unplug, and false for a later press of the same key" and "the 64's chooser opening ends a press's still and a held cell".

`still` is the key down with its still true, `gone` the key down with it false, `up` the key up (its still false). A press's own still is true (the checks of the press rows).

| State | Event | Next | Effect |
|---|---|---|---|
| `up` | `press` | `gone` | a later press is not that press; its own still is true |
| `up` | `release` | `up` | nothing held |
| `up` | `page change` | `up` | nothing held |
| `up` | `side change` | `up` | nothing held |
| `up` | `half change` | `up` | nothing held |
| `up` | `pattern replaced` | `up` | nothing held |
| `up` | `unplug` | `up` | nothing held |
| `still` | `press` | `gone` | a press with no release before it is a new press |
| `still` | `release` | `up` | false from the release on |
| `still` | `page change` | `gone` | the pane's keys end; the key stays held |
| `still` | `side change` | `gone` | the same |
| `still` | `half change` | `gone` | the same |
| `still` | `pattern replaced` | `still` | a replacement never ends a still |
| `still` | `unplug` | `up` | the port is forgotten |
| `gone` | `press` | `gone` | a later press is its own press |
| `gone` | `release` | `up` | nothing more to end |
| `gone` | `page change` | `gone` | nothing more to end |
| `gone` | `side change` | `gone` | nothing more to end |
| `gone` | `half change` | `gone` | nothing more to end |
| `gone` | `pattern replaced` | `gone` | nothing more to end |
| `gone` | `unplug` | `up` | the port is forgotten |

### step view
- **State:** derived, with no record (design section 7): `step_view(port)` is `{voice, step, pane}` exactly while the step editor is open from a key of that port (`step_editor.key`, still that port's editor, whose voice and step it gives) and a pane of the port shows the patterns page's side 2: the key's own pane if it does, else the first other one. The table follows a 256 on port 1: the top pane shows patterns' side 1, where the key (5, 1) is voice 1's step 5; another key (7, 3) is voice 3's step 7, whose hold is a second open; the bottom pane shows side 2 (`closed`, `open`) or side 1 (`closed, no side 2`, `editor`). The bar key is (8, 4) of the bottom pane: chance's key 8 in the view. `editor` is the editor open with no view.
- **Invariant:** none: the view is read from the editor's key, the open editor and the panes, so no state of its own can disagree with them; the `grid keys` invariant checks the editor's key.
- **Test:** `test/unit/grid_pages_patterns_test.lua`: "step view: every cell is decided" and its rows; on every arrangement, "a held step opens the editor, and the step view where the port shows side 2", "with no side 2 shown the hold opens the editor alone and the pane stays the page", "a bar key sets the step's value and the screen's row shows it", "the last key of a bar clears it", "K2 closes the editor and the view with the key still down", "the key's release closes both; the pane is the page again", "entering the view ends that pane's other held keys and leaves the opening key held", "a free lane's bar is dark and its keys set nothing" and "a lane cell held 0.3 s opens nothing"; `test/unit/grid_core_test.lua`'s "step_view is nil with no editor, an editor no key of the port opened, and no side 2 shown (3.9's 3c)" "end_pane_keys spares the key it is given (3.9's 3c)", "a step editor close that raises leaves no key recorded for the step view (3.9's 3c)" and "a second open from another port ends the first port's step view and its pane's keys (3.9's 3c)"; and the patterns tests "with side 2 on both panes of a 256 the view is the key's pane and the other stays the page" and "LN armed before the view is still armed after it".

| State | Event | Next | Effect |
|---|---|---|---|
| `closed` | `hold` | `open` | the editor opens and the bottom pane is the view: line 7 dark |
| `closed` | `release` | `closed` | nothing held |
| `closed` | `K2` | `closed` | K2 reaches the page |
| `closed` | `key's pane page` | `closed` | the top pane shows voices |
| `closed` | `view's pane page` | `closed, no side 2` | the bottom pane shows voices |
| `closed` | `view's pane side` | `closed, no side 2` | the bottom pane shows side 1 |
| `closed` | `unplug` | `closed, no side 2` | no grid shows anything |
| `closed` | `replacement` | `closed` | nothing held |
| `closed` | `bar key` | `closed` | a chance cell's tap: cell 8 takes 53, step 5 nothing |
| `closed` | `another key's hold` | `open` | voice 3's step 7 in the editor and the view; key (5, 1)'s release closes nothing |
| `closed` | `close all` | `closed` | nothing open to close |
| `closed, no side 2` | `hold` | `editor` | the editor alone; the panes stay their pages |
| `closed, no side 2` | `release` | `closed, no side 2` | nothing held |
| `closed, no side 2` | `K2` | `closed, no side 2` | K2 reaches the page |
| `closed, no side 2` | `key's pane page` | `closed, no side 2` | the top pane shows voices |
| `closed, no side 2` | `view's pane page` | `closed, no side 2` | the bottom pane shows voices |
| `closed, no side 2` | `view's pane side` | `closed` | the bottom pane shows side 2 |
| `closed, no side 2` | `unplug` | `closed, no side 2` | the port is forgotten |
| `closed, no side 2` | `replacement` | `closed, no side 2` | nothing held |
| `closed, no side 2` | `bar key` | `closed, no side 2` | a side 1 tap: voice 4's step 8 on |
| `closed, no side 2` | `another key's hold` | `editor` | voice 3's step 7 in the editor alone; key (5, 1)'s release closes nothing |
| `closed, no side 2` | `close all` | `closed, no side 2` | nothing open to close |
| `editor` | `hold` | `editor` | a press with no release before it reopens the editor; the release toggles nothing |
| `editor` | `release` | `closed, no side 2` | the editor closes; nothing toggles |
| `editor` | `K2` | `closed, no side 2` | the editor closes; the key's release toggles nothing |
| `editor` | `key's pane page` | `closed, no side 2` | the key's gesture ends and the editor closes |
| `editor` | `view's pane page` | `editor` | the bottom pane shows voices |
| `editor` | `view's pane side` | `open` | the bottom pane shows side 2: the view starts |
| `editor` | `unplug` | `closed, no side 2` | the port is forgotten; the editor closes |
| `editor` | `replacement` | `closed, no side 2` | the editor closes; the key's release toggles nothing |
| `editor` | `editor's replacement` | `editor` | ruling 71: the editor stays open |
| `editor` | `bar key` | `editor` | a side 1 tap: voice 4's step 8 on, step 5's chance untouched |
| `editor` | `another key's hold` | `editor` | a second open: voice 3's step 7; the first key's release closes nothing |
| `editor` | `close all` | `closed, no side 2` | the modal stack's close (cleanup's step) closes the editor; the key's release toggles nothing |
| `open` | `hold` | `open` | the editor reopens and the view with it; the release toggles nothing |
| `open` | `release` | `closed` | both end: the bottom pane is the lane side again |
| `open` | `K2` | `closed` | both end with the key down: the lane side again; the release toggles nothing |
| `open` | `key's pane page` | `closed` | the key's gesture ends, so the editor and the view: the lane side again |
| `open` | `view's pane page` | `editor` | the view ends with its pane's page; the editor stays |
| `open` | `view's pane side` | `editor` | the same; side 2 shown again, the view is back |
| `open` | `unplug` | `closed, no side 2` | the port is forgotten; both end |
| `open` | `replacement` | `closed` | both end: the lane side again; the release toggles nothing |
| `open` | `editor's replacement` | `open` | ruling 71: the editor and the view stay |
| `open` | `bar key` | `open` | step 5's prob 53; the editor's prob row shows `53%` |
| `open` | `another key's hold` | `open` | a second open: the view shows voice 3's step 7; the first key's release closes nothing |
| `open` | `close all` | `closed` | both end: the lane side again; the key's release toggles nothing |

`closed` and `closed, no side 2` with `editor's replacement` are impossible: the editor's own replacement runs only from its open owner's rows and keys (`run_replacement`).

## Owns

3.9's package 3a added three key interfaces to the core and their pane wrappers (`docs/notes/lua/grid/pane.md`, The pane object), for the patterns page's lane side (3b), the step view (3c), the loop (5a), the roll (5b) and the perform side (5c):

- **The step key's second key** (`step_key`'s `second`): documented with the step keys, `docs/notes/lua/grid-core.md` (Pages, held keys and holds; Machines, `grid keys`).
- **Cell keys**: `cell_key(port, x, y, z, id, index, position, positions, on_tap, on_value)`, `held_cell(port, x, y)`. A line has at most one held cell a port, whichever pane its keys are in, as a voice has one held step (#450); the second key's `position` is its place along its own pane's shown keys (16, or 8 on a 64's half). Anything out of range (an id that is no string, an index or position outside 1..`PATTERN_LENGTH`, a callback that is no function, a key not held) does nothing.
- **`still(port, x, y)`**: a function of no argument for the press now down at the key. A key not held gives one that is always false, and so does `pane.still` for a place the pane does not show. A page passes the function to whatever must end with its key (5a's `set_loop`, 5b's `roll`), which asks it each time it acts.

3.9's package 3c added the step view's two core functions, for the patterns page (`docs/notes/lua/grid/pages/patterns.md`, The step view):

- **`step_view(port)`**: `{voice, step, pane}` or nil (Machines, `step view`): nil for a port with no layout, an editor no key of the port opened (another port's, or one opened from Lua, as SEQ's layout states do) and a port showing no patterns side 2. The voice and step are the open editor's, so its ALT+E2 moves the view's step (the editor repaints the grids then).
- **`end_step_view(port)`**: SEQ's `close_step_editor(port)` calls it before it forgets its editor (the controller's ruling 3c-1), so K2 and the modal stack's `close_all` reach it (an end of the key's gesture goes through `close_step_editor_of`, which ends the view itself); it ends the view pane's keys, sparing the editor's key. `end_pane_keys(port, pane, spare)` takes that key as `{x, y}`.

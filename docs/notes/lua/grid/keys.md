## Must not break

- **A cell key is the core's, as a step key is**: a lane's line takes its keys through `pane.cell_key(x, y, z, id, index, on_tap, on_value)` only, and the core (`lib/grid/core.lua`, `cell_key`) alone decides a tap from a second key. A tap's `on_tap` runs at the release (`release_cell_key`, from `handle_key`, whatever the page does with `z == 0`), and only for a held cell that is neither consumed nor ended; a second key of the same `id` on the same port calls the held cell's own `on_value(held index, position, positions)` and consumes both keys. No hold clock and no editor belong to a cell.
- **A pane's change ends a held cell as it ends a held step**: `end_pane_keys` (a page, side or half change, the 64's chooser opening) and `forget_port` (an unplug, a rotation, a plug, cleanup) drop the cell entries of the keys they reach, so the key's release taps nothing and its line takes no value from it. A pattern's replacement leaves a held cell (its lane values are no step gesture).
- **`still` carries a token of its own press, never the press time or a role**: every press puts a fresh token at the key (`press_tokens`), and `still(port, x, y)` (the pane's `pane.still(x, y)`) compares the token it read with the key's. The harness clock does not move between a release and the next press, so a press time would be true again for a later press; a role string is true again for a later press in the same role. A pattern's replacement never ends a still: a loop and a roll outlive a replacement and end with their key (3.9's 5a, 5b).
- **Only a held key is a cell key or has a press token**: the `grid keys` invariant (`docs/notes/lua/grid-core.md`, Machines) walks both tables with the other per-key ones.

## Machines

### grid cell key
- **State:** per port and key, `cell_keys[port][x][y]` (a core local): `{id, index, on_tap, on_value}` for a held cell, `{id, second = true}` for a spent second key; read through `held_cell(port, x, y)` (the id and index of a held cell, nil for a spent second key or no cell), with the key's `held` and `consumed`. The table follows one key, (5, 2) of a 256's pane 1 showing a two-sided probe whose every key is a cell key of its line (`"line 2"`, index 5), and a second key (8, 2) of the same line.
- **Invariant:** none of its own: the `grid keys` invariant (`docs/notes/lua/grid-core.md`) checks that only a held key is a cell key.
- **Test:** `test/unit/grid_core_test.lua`: "grid cell key: every cell is decided" and its rows; on every arrangement, `test/unit/grid_pane_test.lua`'s "a cell tap calls on_tap at its release", "a second key gives the held cell its place" and "a held cell ends at a side change and at an unplug".

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
- **Test:** `test/unit/grid_core_test.lua`: "grid key still: every cell is decided" and its rows; on every arrangement, `test/unit/grid_pane_test.lua`'s "still is true while the press is down and false after its release, a page change, a side change, a half change and an unplug, and false for a later press of the same key".

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

## Owns

3.9's package 3a added three key interfaces to the core and their pane wrappers (`docs/notes/lua/grid/pane.md`, The pane object), for the patterns page's lane side (3b), the step view (3c), the loop (5a), the roll (5b) and the perform side (5c):

- **The step key's second key** (`step_key`'s `second`): documented with the step keys, `docs/notes/lua/grid-core.md` (Pages, held keys and holds; Machines, `grid keys`).
- **Cell keys**: `cell_key(port, x, y, z, id, index, position, positions, on_tap, on_value)`, `held_cell(port, x, y)`. A line has at most one held cell a port, whichever pane its keys are in, as a voice has one held step (#450); the second key's `position` is its place along its own pane's shown keys (16, or 8 on a 64's half). Anything out of range (an id that is no string, an index or position outside 1..`PATTERN_LENGTH`, a callback that is no function, a key not held) does nothing.
- **`still(port, x, y)`**: a function of no argument for the press now down at the key. A key not held gives one that is always false, and so does `pane.still` for a place the pane does not show. A page passes the function to whatever must end with its key (5a's `set_loop`, 5b's `roll`), which asks it each time it acts.

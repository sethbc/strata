## Must not break

- **No params, no target**: the module registers only IO's `wtape` section. Nothing is sent by default and nothing is sent at start or cleanup.
- **One command per press, through `S.lib.io_ii.send`**: `record`, `play` and `loop_active` alternate 1 and 0 (the first press sends 1); `reverse`, `loop_start` and `loop_end` send no argument. Command names are crow's descriptor's (`docs/design/3.6-facts/crow-ii.md` section 2, W/).
- **The bus must lead**: while `S.lib.io_ii.leads()` is false, or the ii module is absent, a press sends nothing, changes no row text and flashes `ii bus is not strata's`; the section's status is `[--]`.
- **A row changes only when `send` returned true** (build ruling 13): while the bus leads and `send` returns false (the line was dropped: the queue is full, or under overload the line is refused while other lines take their turn, `docs/notes/lua/io/ii.md`), the row's text and an alternating row's next value stay as they were, the flash is `ii busy`, and the next press sends the same value again.
- **Rows show what was last queued**, `-` before any command (`on` and `off` for a toggle, `sent` for the others): Strata cannot read W/'s state, so a row can disagree with the module.
- **Rows have fixed labels** (`record`, `play`, `reverse`, `loop start`, `loop end`, `loop`): the live value is in each row's `text`. Each row's hint is its label, but the two loop points' are `start` and `end` (`WTAPE.rows[k].hint`), so the hint row is never cut (`test/unit/pages_io_test.lua` checks every layout state's rows).

## Owns

- `lib/io/wtape.lua` (`S.lib.io_wtape`): `WTAPE` (the rows and texts), IO's `wtape` section (title `w/ tape`) with `layout_states` for the bus not leading, leading before any command and leading after commands. There is one path for a press: no state or flag is ever asked about. A leading state reaches its look as a player does (build ruling 12): it plugs a crow, turns the `ii` section's `ii_bus` rig row to `strata` through the page (`S.lib.pages_io.go_to_row` by its key, then E3; the module never calls `S.lib.io_rig.set` or `step`), and "after commands" presses the six rows with K3, each reached by `go_to_row` by its `id` (the row's label). E3 turns toward `strata` one detent at a time by the order of `S.lib.io_rig.RIG.specs.ii_bus.values`, from wherever the setting stands, and the value (never the row's text) is read after each. A direct write to the rig cannot be committed here: `test/unit/structure_test.lua` fails any file but the IO page that calls anything of `S.lib.io_rig` beside `get`, `text`, `on_change` and `RIG`. Where the ii module or that row is absent the state stays on the not-leading look; where the row is present and the bus still does not lead it raises.
- Tests: `test/unit/io_wtape_test.lua`.
- User page: `docs/user/io/w.md`.

## How it works

`press(spec)` checks the bus, sends, and records the shown text only when `send` returned true. The module keeps two small tables (the shown text and a toggle's last value), never saved. Unverified on the device until the 4.0 hardware check.

## Must not break

- **No params, no target**: the module registers only IO's `wtape` section. Nothing is sent by default and nothing is sent at start or cleanup.
- **One command per press, through `S.lib.io_ii.send`**: `record`, `play` and `loop_active` alternate 1 and 0 (the first press sends 1); `reverse`, `loop_start` and `loop_end` send no argument. Command names are crow's descriptor's (`docs/design/3.6-facts/crow-ii.md` section 2, W/).
- **The bus must lead**: while `S.lib.io_ii.leads()` is false, or the ii module is absent, a press sends nothing, changes no row text and flashes `ii bus is not strata's`; the section's status is `[--]`.
- **Rows show what was last sent**, `-` before any command (`on` and `off` for a toggle, `sent` for the others): Strata cannot read W/'s state, so a row can disagree with the module.
- **Rows have fixed labels** (`record`, `play`, `reverse`, `loop start`, `loop end`, `loop`): the live value is in each row's `text`.

## Owns

- `lib/io/wtape.lua` (`S.lib.io_wtape`): `WTAPE` (the rows and texts), IO's `wtape` section (title `w/ tape`) with `layout_states` for the bus not leading, leading before any command and leading after commands. Those two leading states set a module flag that the page renders use where no bus leads; it sends nothing.
- Tests: `test/unit/io_wtape_test.lua`.
- User page: `docs/user/io/w.md`.

## How it works

`press(spec)` checks the bus, sends, then records the shown text. The module keeps two small tables (the shown text and a toggle's last value), never saved. Unverified on the device until the 4.0 hardware check.

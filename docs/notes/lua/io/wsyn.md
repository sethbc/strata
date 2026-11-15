## Must not break

- **Nothing is sent by default**: every `v<i>_out_wsyn` is 0, so no voice is routed and no call reaches `S.lib.io_ii`. The module sends only through `S.lib.io_ii.send` (which sends only while Strata leads the bus), never `crow` or `ii.` text of its own.
- **Absent ii module, absent params**: with no `S.lib.io_ii`, or before `add_params` ran, `routed(voice)` is false, `rows(voice)` is empty (the IO page raises on a `param` row whose param does not exist), `note_on` sends nothing and nothing reads a param.
- **A note is one `("wsyn", "play_note", volts, velocity * wsyn_level)`**: volts are `S.lib.io_targets.volts(pitch)` clamped to -5..5 (`WSYN.volts_limit`); a note off sends nothing (W/ shapes and ends its own notes in AR mode).
- **`ready` is `ar_mode` 1 then `voices` 4**, in that order; the device has no `release`.
- **A route's change ends the voice's target notes**: `v<i>_out_wsyn`'s action calls `S.lib.io_targets.route_changed(voice)`.
- **The toggles are binary** (plan ruling 25), shown as a `param` row with `binary = {[0] = "off", [1] = "on"}`; the eight params (seven toggles and `wsyn_level`, 0 to 10 V, default 5) are PSET-only.

## Owns

- `lib/io/wsyn.lua` (`S.lib.io_wsyn`): `WSYN` (every tunable), `add_params()` (called by the ii bus module's group `strata_out_ii`), the ii device `wsyn` (`param_count` 8) and the note target `wsyn` (rows `w/ syn` and `w/ level` on IO's `voice` section).
- Tests: `test/unit/io_wsyn_test.lua`, with `S.lib.io_ii` a recording double.
- User page: `docs/user/io/w.md`.

## How it works

The command names and argument order are crow's descriptor's (`docs/design/3.6-facts/crow-ii.md` section 2, W/). W/ allocates its own four voices and steals the oldest. Unverified on the device until the 4.0 hardware check.

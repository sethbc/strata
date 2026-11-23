## Must not break

- **The module handles no `/param` path.** norns runs its own `/param/<id> <value>` handling after `osc.event` returns (`docs/design/3.6-facts/iii-osc-nb-softcut.md` section 2), so `osc.event` only records the sender and the id's arrival time (`state.arrived`) and never sets a param.
- **`osc.event` is set by the start step `io_osc` (96) and set to nil by the cleanup step (148)**; the structure test's `EVENT_HOLDERS` lists `lib/io/osc.lua osc` as a holder that is not a MIDI vport.
- **Nothing by default**: with `osc_feedback` off, or no sender known, no clock runs and nothing is sent. The feedback clock (one clock of `S.lib.clocks`, #870, `docs/notes/lua/clocks.md`) exists only while feedback is on and a sender is known (`M.running()`, and `M.clock_id()` its handle's id for tests); it is stopped with `S.lib.clocks.stop` when feedback goes off (retired, never canceled, while its resume may be posted, so it ends at that wake sending nothing) and canceled with `S.lib.clocks.cancel` at cleanup.
- **Rig settings are read only**: `S.lib.io_rig.get` and `on_change`, never `set` or `step` (a structure test).
- **Every message is contained** (`S.lib.ui_frame.contained_call`): one that raises prints once and does not reach norns' event. A wrong address, argument or voice prints one line, `strata: osc <path> ignored: <why>`, and does nothing; the actions print their own line for a range they refuse. The module calls no engine command itself, only `S.lib.io_actions`.
- **A tick sends at most `OSC.sends_per_tick` (32) messages**: the scene, the voices' `running` and the patterns first (at most nine), then the params that differ from what the sender has, the longest-waiting first (the tick each was first seen differing, then the watch list's order; `state.since`), each with its value now; the rest wait for the next tick. A param that changes every tick therefore cannot shut out later ones: each is sent by the second tick after its change (a test with forty params changing for ten ticks).
- **A value that arrived is not echoed**: a `/param/<id>` for a watched id sets its `last_sent` to the arrived value and its `arrived` time, and the tick skips an id that arrived within `OSC.echo_seconds` (0.25). An id that is not watched is recorded nowhere, so a sender cannot grow the tables (`M.tracked()` counts the arrivals).
- **Baseline**: starting the clock records every watched value and the three states as already known, so only changes are sent; `/strata/hello` clears those records, so the next tick sends everything watched (a scene is sent only once `S.current_scene` is set).

## What it owns

`lib/io/osc.lua` (`S.lib.io_osc`): `M.OSC = {sends_per_tick = 32, feedback_hz = 15, echo_seconds = 0.25, watch}` (`watch` is the starting watch list: the sixteen macros and each voice's `v<i>_mute` and `v<i>_amp`, the params of `tools/touchosc/lib/layout.lua`), `M.running()` and `M.clock_id()`.

| Address in | Does |
|---|---|
| `/strata/scene <n>` | `io_actions.recall_scene(n)` |
| `/strata/voice/<n>/run <0, 1 or 2>` | `io_actions.run_voice(n, mode)` (voice 1 to 7) |
| `/strata/voice/<n>/retrigger <velocity>` | `io_actions.retrigger(n, velocity)` |
| `/strata/patterns <0, 1 or 2>` | `io_actions.patterns(mode)` |
| `/strata/fill <0, 1 or 2>` | `io_actions.fill(mode)` (3.7: fill's latch) |
| `/strata/watch <param id>` | adds a param that exists to the watch list |
| `/strata/hello` | marks every watched value and the three states due |

Every message with a `from` host sets the last sender (feedback goes to `{host, osc_port}`); a sender that differs from the last asks for a redraw (`request_redraw()`), since IO's `osc` title shows it and the page does not animate. Feedback, from a 15 Hz clock: `/param/<id> <value>` for each watched param whose value differs from the last sent, `/strata/scene <n>`, `/strata/voice/<n>/running <0 or 1>` and `/strata/patterns <0 or 1>` when they change.

IO's `osc` section: rig rows `osc_feedback` and `osc_port`; its status is the sender's host or `no sender`. Its layout states are `no sender` and `with a sender` (the rig setting cannot be set from the module, so a state shows the setting as it is).

`tools/touchosc/lib/layout.lua` is the layouts' description and `tools/touchosc/generate.py` writes `extras/touchosc/strata-tablet.tosc` and `strata-phone.tosc` from it, the same bytes every run (node IDs are uuid5 of their paths), and `generate.py --check` exits non-zero when a committed file differs (`tools/touchosc/README.md`); the `.tosc` format is unofficial and unverified in TouchOSC.

Tests: `test/unit/io_osc_test.lua`.

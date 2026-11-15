## Must not break

- **One door, one leader.** Every ii message in the script goes through `M.send`, `M.send_off` or `M.send_direct`, and each returns false and sends nothing unless `M.leads()`. The flag `leads()` reads is the module's own: set when the rig's `ii_bus` becomes `strata` with a crow there, or a crow is set up under `strata`, and cleared only at the end of the leaving sequence (the rig tells its listeners after its value has changed, so the rig cannot be what `send` reads while the lead is given up). Under `off` and `teletype` no line starting `ii.` reaches crow but Teletype's three handlers and `ii.reset_events(ii.self)`; a test drives both settings and holds it.
- **Text only.** Each message is one line, `ii.<device>.<command>(<args>)`, each argument written by `S.lib.io_crow.number` and joined by `, ` (`()` with none), sent with `S.lib.io_crow.send_now`, as crow receives `ii["<device>"]["<command>"](args)` (`docs/design/3.6-facts/crow-ii.md` §2). Teletype's handlers are lines of crow-side Lua calling `tell` with a fixed event name (`strata_tt1` to `strata_tt3`), received through `S.lib.io_crow.on_event`: no function is ever assigned through the `crow` proxy.
- **The queue is bounded and in order.** `send` and `send_off` add a line to the queue (true), or with `II.queue_max` (48) waiting drop it and count it (`M.dropped()`, false). The LFO clock's step sends the first `II.sends_per_step` (4) through `send_now`, about 20 in each 0.1 s crow window, so a chord to several devices is spread over a few steps and never lands on crow's own 16-message leader queue at once (design §6.2, crow-ii.md §2). Notes are delayed only by this rate. `send_direct` never queues: it is for a device's `release`, which runs when no step will come.
- **The leaving sequence runs in this order, with the flag still set**, when the rig leaves `strata` with a crow there and at the cleanup step (144): `S.lib.io_targets.end_target(name)` for each registered device, so the offs of notes still sounding join the queue; the queue's offs (`send_off`'s) sent at once in order, at most `II.cleanup_sends` (14), everything else waiting dropped (not counted in `dropped()`, which counts the queue's overflow); each device's `release`; then the flag cleared and anything a release queued dropped. The targets' own cleanup step (142) has already ended every note, so at cleanup their offs are what waits.
- **A crow that leaves** empties the queue and clears the flag, and nothing is sent and no device released: there is nothing to send through. Its return under `strata` makes every device ready again.
- **Teletype is answered only under `teletype`.** The three handlers go at each crow setup and at once when the rig turns to `teletype` with a crow there; leaving `teletype` with a crow there sends `ii.reset_events(ii.self)`, what `crow.reset()` runs to put crow's own handlers back (crow-ii.md §1). An event that arrives under another setting does nothing. No line names `call4` or a `query` (a query handler that does not return a number crashes crow inside its interrupt path, crow-ii.md §3).
- **The devices are the registry's**, read at each use (`S.registry.ii_devices`, ruling 8): their `ready` and `release` run in registration order, each through `S.lib.ui_frame.contained_call`, so one that raises prints a line and the next still runs.
- The module never sets a rig value: a layout state reaches the bus row as a user does (`show_section`, the row by its key, E2, E3) and raises when it cannot (ruling 26).

## Owns

`lib/io/ii.lua` (`S.lib.io_ii`, 3.6, design §6.1, §6.2, §6.4):
- `M.II = {sends_per_step = 4, queue_max = 48, cleanup_sends = 14}`.
- `M.leads()`, `M.send(device, command, ...)`, `M.send_off(device, command, ...)`, `M.send_direct(device, command, ...)`, `M.queued()`, `M.dropped()`; `M.stop()`, the cleanup step's body (the structure test watches it).
- `M.add_params()`: the group `strata_out_ii` (`out ii`) whose count is the sum of the registered devices' `param_count`, then each device's `add_params()` in registration order; no group when the sum is 0. Called by `lib/params_setup.lua`'s `{"out ii", "io_ii"}` record. The devices' own packages (Just Friends, W/, ER-301, TELEXo) add the params.
- The crow hooks `on_setup("ii", ...)` and `on_gone("ii", ...)`, the events `strata_tt1` to `strata_tt3`, a rig listener on `ii_bus`, an LFO step hook (the queue), IO's `ii` section, the start step `io_ii` (93) and the cleanup step `io_ii` (144).
- Tests: `test/unit/io_ii_test.lua`. The device packages' tests stand a double in its place with exactly `leads`, `send`, `send_off`, `send_direct` and `add_params`.

## The bus setting

| `ii_bus` | Strata sends | Answers |
|---|---|---|
| `off` (default) | nothing | nothing |
| `strata` | the devices' messages, while a crow is there | nothing |
| `teletype` | the three handlers, at each crow setup | `CROW.C1` to `C3` |

A change with a crow there: leaving `strata` runs the leaving sequence; leaving `teletype` sends `ii.reset_events(ii.self)`; arriving at `strata` takes the lead (each device's `ready`); arriving at `teletype` sends the handlers. From `strata` to `teletype` the sequence runs first.

## Teletype's calls

Each event goes to `S.lib.io_actions` (`docs/notes/lua/io/actions.md`), which checks its voice, scene, macro and mode and prints one line for anything out of range; this module checks what only it knows: `k`, the velocity (0 to 127) and the macro value (0 to 16383), each with one `strata: teletype call3 ignored: ...` line.

| Event | Arguments | Runs |
|---|---|---|
| `strata_tt1` | `n` | `recall_scene(n)` |
| `strata_tt2` | `v, x` | `run_voice(v, x)` |
| `strata_tt3` | `1, v, x` | `retrigger(v, x / 127)` |
| | `2, v, x` | `freeze(v, x)` |
| | `3, v, x` | `mute(v, x)` |
| | `4, m, x` | `macro(m, x / 16383)` |
| | `5, _, x` | `patterns(x)` |

## The section

IO's `ii` section has one `rig` row, `bus leader`, on `ii_bus` (the page shows the rig's text, `off`, `strata` or `teletype`). Its title shows `[--]` without a crow, else `<n> dropped` once the queue has dropped any (the count is the session's). Layout states: without a crow; a crow with the bus off; Strata leads; Teletype leads; messages dropped.

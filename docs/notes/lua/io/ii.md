## Must not break

- **One door, one leader.** Every ii message in the script goes through `M.send`, `M.send_off` or `M.send_direct`, and each returns false and sends nothing unless `M.leads()`. The flag `leads()` reads is the module's own: set when the rig's `ii_bus` becomes `strata` with a crow there, or a crow is set up under `strata`, and cleared only at the end of the leaving sequence (the rig tells its listeners after its value has changed, so the rig cannot be what `send` reads while the lead is given up). Under `off` and `teletype` no line starting `ii.` reaches crow but Teletype's three handlers and `ii.reset_events(ii.self)`; a test drives both settings and holds it.
- **Text only.** Each message is one line, `ii.<device>.<command>(<args>)`, each argument written by `S.lib.io_crow.number` and joined by `, ` (`()` with none), sent with `S.lib.io_crow.send_now`, as crow receives `ii["<device>"]["<command>"](args)` (`docs/design/3.6-facts/crow-ii.md` §2). Teletype's handlers are lines of crow-side Lua calling `tell` with a fixed event name (`strata_tt1` to `strata_tt3`), received through `S.lib.io_crow.on_event`: no function is ever assigned through the `crow` proxy.
- **The queue is bounded and in order.** `send` adds a line to the queue (true), or with `II.queue_max` (48) waiting drops it and counts it (`M.dropped()`, false). The LFO clock's step sends the first `II.sends_per_step` (4) through `send_now`, about 20 in each 0.1 s crow window, so a chord to several devices is spread over a few steps and never lands on crow's own 16-message leader queue at once (design §6.2, crow-ii.md §2). Notes are delayed only by this rate. `send_direct` never queues: it is for a device's `release`, which runs when no step will come.
- **The leaving sequence runs in this order, with the flag still set**, when the rig leaves `strata` with a crow there and at the cleanup step (144): `S.lib.io_targets.end_target(name)` for each registered device, so the offs of notes still sounding join the queue; the queue's offs (`send_off`'s) sent at once in order, at most `II.cleanup_sends` (14), everything else waiting dropped (not counted in `dropped()`, which counts the queue's overflow); each device's `release`; then the flag cleared and anything a release queued dropped. The targets' own cleanup step (142) has already ended every note, so at cleanup their offs are what waits.
- **A full queue never drops an off** (ruling 21). A dropped off is one nothing puts right: the ER-301's off is `tr(port, 0)` and it has no `release`; the TELEXo's are `tr(n, 0)` and, in `envelope`, `env(n, 0)`, and its `release` sends only `env_act(n, 0)` (the 2e brief), so a lost trigger low leaves the gate high (Just Friends and W/ synth send no off: each shapes its own notes). So while Strata leads, `send_off` always takes its line: with fewer than 48 waiting it joins; with 48 waiting it takes the place of the newest waiting line that is not an off (that line dropped and counted, as a dropped `send` is) and goes to the end of the queue. The off is then after every line that waited, its own on included, so offs keep their order and never overtake their note's on. When the displaced line is that very note's on (the same device, command and first argument, the port or output: `ii.er301.tr(3, 1)` for `ii.er301.tr(3, 0)`), the device never gets either: the off goes too, the pair counted once, and `send_off` returns false. With 48 offs waiting the off joins anyway (49 for a moment; the four devices' line counts never reach it). Each queued entry keeps its device, command, first argument (as `S.lib.io_crow.number` writes it) and whether it is an off beside its text, so nothing is parsed back out of a line.
- **Past fourteen offs at the leaving sequence, lines stay high.** `II.cleanup_sends` stands as the design gives it (from crow's own 16-message leader queue, which no document lets us measure): with more than fourteen gates high at the moment the bus is given up (it takes every voice on two gate devices and more), the offs are sent in queue order and the lines past the fourteenth stay high until something else lowers them (that port's next note, or the device itself). The 4.0 hardware check measures it.
- **A crow that leaves** empties the queue and clears the flag, and nothing is sent and no device released: there is nothing to send through. Its return under `strata` makes every device ready again. The section's `[--]` is drawn by crow's own `request_redraw()`, which its remove handler calls after the `on_gone` hooks (a test pins it).
- **The lead is taken once**: `take_lead` returns at once while the flag is set. norns keeps one crow, and a second one plugged in calls `norns.crow.add` again with no remove (crow-ii.md §1), so its setup runs the hook while Strata leads: no device is made ready twice and the queue is kept.
- **The group stays whole** (ruling 15): each device's `add_params` runs through `contained_call`. The module compares the params it added (the paramset's count before and after) with its registered `param_count`: when fewer (it raised, or miscounted), the rest are hidden separators `<device>_unused_<n>` (`params:hide`, as the keyed options hide their text param) and one line names the device and both counts (`strata: ii device a added 1 of its 3 params: 2 hidden in their place`), so the next device's params stay inside the group; when more, the group cannot be mended (norns takes the next `n` params), and one line says so (`... added 4 params, more than its 2: the out ii group ends before the last 2`). A device that raised also prints `contained_call`'s own failure line. The other devices' params are added as if nothing happened.
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

IO's `ii` section has one `rig` row, `bus leader`, on `ii_bus`, reading `off`, `strata leads` or `teletype leads` (the rig spec's display labels, `S.lib.io_rig.text`; `docs/notes/lua/io/rig.md`). Its title shows `[--]` without a crow, else `<n> dropped` once the queue has dropped any (the count is the session's). Layout states: without a crow; a crow with the bus off; Strata leads; Teletype leads; messages dropped.

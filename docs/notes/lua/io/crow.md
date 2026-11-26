## Must not break

- **Text only, one door.** Every line to crow goes through `M.send_now(line)` or `M.send_value(key, line)`, each one `crow.send(line)`; the only other call is norns' own `crow.reset()` at an add. No function is ever assigned through the `crow` proxy (each would take one of norns' 45 event keys for the session, `docs/design/3.6-facts/crow-ii.md` §1): a handler crow needs is a line of crow-side Lua calling `tell` with a fixed event name, received in `norns.crow.events` through `M.on_event`. The crow stub counts assignments (`context.crow.function_assignments`) and a test holds it at 0.
- **One number writer.** Every number in a line is written by `M.number(value)`: at most four decimals, no trailing zeros or point, never `-0`, anything not finite `0` (plan ruling 20). The tests pin the lines in that form.
- **Nothing by default.** With every crow param at its default the module sends nothing: a jack's off line (`input[n].mode('none')`, `output[n].volts = 0`) goes only when Strata itself has set that jack up since crow's last reset (`state.set_up`), so a setup, a jack norns' clock gives back and a key that resolves to `off` send nothing for a jack left off; the cleanup lines go only when some mode or source is not `off`. Without a crow, and after the cleanup step, `send_now` and `send_value` return false and nothing waits.
- **A handler sends crow's arguments as text tell can write.** crow calls a change handler with a boolean (crow `lua/input.lua:150`, `change(val ~= 0)`) and `tell` raises on one (`luaL_checkstring`, crow `lib/lualink.c:158-175`), so the change line sends `s and 1 or 0`, as crow's own default does (`lua/input.lua:30`); a stream handler gets a number (`L_handle_stream`'s `lua_pushnumber`). The tests pin both lines whole.
- **An output's source is kept by key** (`S.lib.io_keyed`, `docs/notes/lua/io/keyed.md`): `crow_out<n>_source` is an option for the menu and the screen and `crow_out<n>_source_key` the key a PSET keeps, so a modulation source registered by a later release never moves a saved choice; a key the list lacks reads as `off` on the jack and is kept. After `io_keyed` resolves the saved keys, the `io_crow` PSET hook compares each effective key with `state.applied_source`. Each changed jack runs the same output setup and target route change as a manual edit, including on a silent read.
- **One budget**, as `lib/engine_sync.lua`'s: `CROW.lines_per_window` (32) per `CROW.window_seconds` (0.1 s), every line counted (the reset too). `send_now` always sends: notes, gates, pulses, setups and the ii bus's messages (`lib/io/ii.lua`) never wait. `send_value` sends while the window's count is under the limit; otherwise the key's line waits, the newest winning, in the order the keys first waited, for the next window, sent from the flush clock, which ends at its own wake once nothing waits and is canceled only at cleanup (#654), through `S.lib.clocks.cancel`. A crow that goes drops what waits.
- **norns' own crow clock keeps its jacks.** While `clock_source` is `crow` (option 4) no line names `input[1]` and its events are ignored; the output `clock_crow_out` names (option n + 1 is output n) gets no line, follows nothing, pulses nothing and routes no voice. The LFO step notices either change and sends a jack given back its lines again (an off jack's only if Strata had set it up). A reconnect under clock source crow needs nothing of the module: norns' `_norns.crow.add` calls `norns.crow.clock_enable()` itself after the script's `norns.crow.add` returns (`lua/core/crow.lua:9-19` in norns), and the module's add sends no line naming `input[1]`.
- **The hot-plug handlers are the module's from its start step** (92): `norns.crow.add` runs `crow.reset()` (as norns' default does), then `M.setup()`, then the `on_setup` hooks, and installs the events again; `norns.crow.remove` drops what waits, ends the output clocks and runs the `on_gone` hooks. Cleanup (145) sets both to functions that do nothing, as the MIDI and grid handlers are (#468), so a crow plugged in after it gets no line. norns restores its own at script clear.
- **A gate source always sends its level** when it is applied (0 V when its voice has no note): a jack moved off a sounding voice is never left high, since the voice it left loses its notes after the jack has moved and their offs no longer name it.
- **One clock per clock output**, ended before its replacement, when its source changes and when crow goes, and at cleanup. Each running output clock keeps the division it started with. After a PSET read, a clock still on the same source restarts only if the loaded division differs. An unchanged division keeps its pending pulse (#1128). Every clock of the module is `S.lib.clocks`' (#870, `docs/notes/lua/clocks.md`): an output's is stopped with `S.lib.clocks.stop` (retired, never canceled, while its resume may be posted, and then it ends at that wake sending no pulse), and the cleanup step cancels with `S.lib.clocks.cancel`.
- Every event handler and hook another module gives runs through `S.lib.ui_frame.contained_call`.

## Machines

### crow jacks
- **State:** `state.set_up[kind][n]` (`input` 1 to 2, `output` 1 to 4): nil, never sent since crow's last reset; true, a setting sent; false, its off line sent (both nil and false send no off line); reset at each add (`crow.reset()`). Beside it `state.owners` (norns' clock's jacks, compared at each step by `follow_owners`) and `state.clocks[n]` (a clock output's handle).
- **Invariant:** `crow`: `set_up` names only jacks that exist, each true or false.
- **Test:** `test/unit/io_crow_test.lua`: "the crow invariant names a jack that does not exist", "the crow invariant names a jack whose key is not a number", "the crow invariant names a set_up value that is neither true nor false" and "the crow invariant holds with jacks set up and set off".

No table: a jack's source kind (off, mod, pitch, gate, clock) is its param's record, read at each use, and `set_up` is a belief nothing reads back from crow.

## Owns

`lib/io/crow.lua` (`S.lib.io_crow`, 3.6, design §5):
- `M.CROW`: the tunables (`lines_per_window`, `window_seconds`, `stream_seconds`, `slew_seconds`, `change_volts`, `change_hysteresis`, `follow_fraction`, `pulse_seconds`, `pulse_volts`, `gate_volts`).
- `M.present()` (`norns.crow.dev ~= nil`), `M.number(value)`, `M.send_now(line)`, `M.send_value(key, line)`, `M.setup()`.
- `M.on_event(name, fn)`: `fn(...)` for each `^^name(...)` line, set in `norns.crow.events` at once and again after each add; the same name again replaces it. `M.on_setup(name, fn)`, `M.on_gone(name, fn)`: run after each add's setup (and at the start with a crow there), and when crow goes. The ii bus module installs Teletype's handlers through these.
- For tests: `M.budget_state() -> {sent, pending}` and `M.clocks() -> {flush, outputs = {[n] = id}}` (the handles' ids).
- The group `strata_crow` (24 params, PSET-only, `add_params()`, called by `lib/params_setup.lua`'s record), the modulation sources `crow1` and `crow2`, the note target `crow`, IO's `crow` section, the start step `io_crow` (92), the cleanup step `io_crow` (145) and the invariant `crow`.
- Tests: `test/unit/io_crow_test.lua`.

## Params

Every default is the first option, but `div`'s (`1`). An input's mode and range, and an output's source, range and div, send that jack's lines again (and restart an output's clock); an input's action and voice are read at each rise and send nothing. The group has 24 params: each output's source is two (`crow_out<n>_source` and its hidden `crow_out<n>_source_key`).

| Param | Values |
|---|---|
| `crow_in<n>_mode` (n 1, 2) | `off`, `cv`, `trigger` |
| `crow_in<n>_range` | `-5..5`, `0..5`, `0..10` |
| `crow_in<n>_action` | `retrigger`, `next scene`, `freeze`, `record`, `patterns`, `fill` |
| `crow_in<n>_voice` | 0 (the selected voice, `sel`) to 7 |
| `crow_out<n>_source` (n 1 to 4), kept by key in `crow_out<n>_source_key` | `off`; each modulation source's key registered by init (`S.lib.mod_sources.registered()` when the params are added); `v1 pitch` to `v7 pitch`; `v1 gate` to `v7 gate`; `clock` |
| `crow_out<n>_range` | `0..5`, `0..10`, `-5..5` |
| `crow_out<n>_div` | `1/16`, `1/8`, `1/4`, `1/2`, `1`, `2`, `4` beats |

## Lines

The crow-side text of a handler is the module's; its event name and the `mode(...)` call are pinned (`docs/design/3.6-facts/crow-ii.md` §1).

| Jack and setting | Lines |
|---|---|
| input `cv` | `input[n].stream = function(v) tell('strata_in', n, v) end`, then `input[n].mode('stream', 0.02)` |
| input `trigger` | `input[n].change = function(s) tell('strata_change', n, s and 1 or 0) end`, then `input[n].mode('change', 1, 0.1, 'rising')` |
| input `off` (a jack Strata set up since the reset) | `input[n].mode('none')` |
| output on a modulation source | `output[n].slew = 0.02`, then from the LFO step `output[n].volts = <v>` through `send_value("out" .. n, ...)` when `v` moved by more than 1/200 of the range; `v = low + fraction(key) * (high - low)` |
| output `v<i> pitch` | `output[n].slew = 0` (and the newest note's volts when one sounds); a note's `output[n].volts = <(pitch - 60) / 12, clamped to the range>` through `send_now` |
| output `v<i> gate` | `output[n].slew = 0` and its level, 5 V when a note sounds and 0 V otherwise (so a gate moved off a sounding voice goes low: the voice it left has its notes ended by the targets core after the jack's lines, and its note off no longer names the jack); `output[n].volts = 5` at the voice's first sounding note, `0` when its last ends |
| output `clock` | `output[n].action = pulse(0.01, 5)`, then `output[n]()` every `div` beats from the output's norns clock |
| output `off` (a jack Strata set up since the reset) | `output[n].volts = 0` |
| cleanup, some param set | `output[1..4].volts = 0`, then `input[1..2].mode('none')` |

## Inputs

- `cv`: `strata_in(n, volts)` keeps the volts; the source `crow<n>` (name `CR<n>`, section `crow`, visible while the mode is `cv`) reads them over the range param's volts (its `range` table is updated in place). Before a value, or with the mode left, it reads as no modulation.
- `trigger`: `strata_change(n, 1)` runs the action through `S.lib.io_actions`: `retrigger(voice, 1)`, `next_scene()`, `freeze(voice, 2)`, `record()`, `patterns(2)`, `fill(2)` (3.7: a rise toggles fill's latch; a trigger cannot hold it); voice 0 is the selected voice, which the actions module resolves. A fall does nothing.

## The target `crow`

Registered with `S.register_note_target` at include. `routed(voice)` when any output norns' clock does not own has that voice's pitch or gate as its source. One note at a time per voice, the newest: a note on sends each pitch output its volts and, when it is the voice's first sounding note, each gate output 5 V; a note off of the newest sends the pitch of the newest left, and the last note's off sends the gates 0 V. `stop_all` forgets every note and sends the gates 0 V. `rows(voice)` gives none: its settings are the section's. A source param's action calls `S.lib.io_targets.route_changed(voice)` for the voice it left and the voice it joined, when that module is loaded. The volts are worked out here, `(pitch - 60) / 12` (design §3.5).

## IO's section

`crow`: status `[--]` without a crow. A `detail` row per input (`in n`, text mode and range; fields mode, range, action, voice) and per output (`out n`, text source and range, ending ` ~` when the source is an LFO that `S.lib.lfos.is_engine_run`: Lua's model of it, decision 20; fields source, range, div). A jack norns' clock owns is a status row, `in 1  clock (norns)` or `out n  clock (norns)`. Layout states: without a crow, with a crow, a detail list open, an output marked `~`, norns' clock on its jacks.

## Must not break

- LFOs modulate around the stored value and never `params:set` their destination.
- **An LFO's destination is its home routing** (the groundwork before 3.8, design §4): the matrix's slot 16 + n, `S.lib.matrix.home(n)` (`docs/notes/lua/matrix.md`), source `lfo<n>`, its depth, offset and on/off the LFO's own params. The module stores no destination: `destination(n)` is the `S.LFO_DESTINATIONS` entry whose key the home holds (the `none` entry for `""` or a key this build lacks).
- **Who plays a home** (`owns(n, id)`): a fast entry (its fixed param one of the five fast ones, `v<i>_grain_pitch`, `buf_pos`, `grain_size`, `filter_freq`, `amp`: the entry's `fast`) is the LFO's engine node, at any rate; a direct destination (a macro) is handed over by the LFO's own step; every other one the matrix sums (`home_m(n)`) with the R routings on the param into its one extra offset, at most `LFO.lua_max_hz` (10 Hz). `v<i> main` is never fast (it can resolve to any param): on a buffer or input voice it resolves to a fast param the LFO does not own, which the matrix sends as `setFastOffset` (ruling 16). `owns` answers by kind, whatever the LFO's on/off and depth, as `S.lib.envelopes.owns` does.
- **One clock** (`S.lfo_clock`) steps all six, every `1 / LFO.step_hz` s (48 Hz), in index order, from the start step `lfo_clock` (125) to the cleanup step `lfos` (120); the `lfo clock` invariant checks it, its coroutine included (`clock.threads`: a clock canceled or ended behind the module's back breaks it, as the scene sequencer's does). Only `S.lib.lfos.stop_clock()` (cleanup's, and a test's that wants a quiet scheduler) stops it. Its sleep is outside every deferrable write: each send of a step goes inside `S.lib.engine_sync.deferrable` (the drain), and nothing inside yields.
- **At most `LFO.sends_per_step` (12) sends a step**, the LFOs' and the matrix's together, in one round robin (`mark_due(key, send)`): keys in the order first marked, a later mark of a key replacing its send, the next step starting where the last stopped. A Lua destination's key is its param id, and the matrix marks it once with every LFO's home and R routing on the param summed, so it sends once.
- **A due key that reaches no engine takes no slot** (#644): the drain asks `S.lib.engine_sync.reaches_engine(key)` before it counts a key against the 12 (`docs/notes/lua/engine-sync.md`, the send budget's "What counts": a stopped voice's param, a key with no engine sender, the master density with no voice running); such a key still runs in its turn, inside `deferrable`, so its value is recorded and the LFO's compare (`expected_value`) reads what it read before. A stopped voice's moving LFO never takes a running voice's slot, and the voice's start sends its values with the matrix's extra offsets (an LFO's home among them since the groundwork before 3.8, ruling 18: `start_value`), the LFO's next step its moved one.
- **A direct destination takes no slot and no budget message** (#636): a param whose engine sender reaches no engine registers with `direct_destination(param_id)` (the macros', `docs/notes/lua/macros.md`). An LFO homed on it (`step_direct`) holds it (`direct.held[n]`) and runs `S.engine_senders[id]` itself with `direct_value(id)` (the stored value plus every holding LFO's `offset_for(id, home_m(n))`, clamped once), once a step after the six LFOs and before the hooks (every LFO on it stepped), when that moved by `LFO.send_threshold` along its range from the value it last handed over, and at once at a release (off, depth 0, another home, cleanup: `release_direct`); never through `mark_due` or `send_engine_value`. `modulates(id)` is whether an LFO holds it (the macros' hook reads it).
- **A Lua home's send is the matrix's** (`docs/notes/lua/matrix.md`): skipped under `LFO.send_threshold` (1/1000) of the destination's range along its warp, compared with `S.lib.engine_sync.expected_value(id)`; a sum that returns to 0 is sent once more. **A restore of a Lua destination** (the LFO off, at depth 0, on another destination, a `main` that re-resolved) **arrives at the matrix's next step** through the round robin and the budget (ruling 17; until 3.7 it was sent at once); a direct destination's restore stays immediate. A home whose m is exactly 0 holds no offset, so its end sends nothing.
- **A control param's action never calls the engine** (AGENTS.md): the rate, depth, offset, phase and mod amounts mark their LFO `edited` (and the phase `sync_due`), and the next step sends them; the on/off, shape, mode, division and mod source actions and a home's change (`home_changed`) reconcile the engine at once, except while a scene applies (below).
- **A scene's LFO settings reach the engine together** (0e's review): while a scene applies (`S.scene_recall_in_progress`: an instant recall, a fade's end, morph's discrete entries), the shape, mode, division and mod source actions and `home_changed` only mark the LFO `edited` (and `sync_due`) without reconciling (the matrix's block sets the homes before the globals); the next step sends the LFO once (`setFastLfo`, then `syncFastLfo` only when a sync is due: the shape changed, or a mode, division or phase change asked for one) with the scene's destination, shape, mode or division, rate and depth all in place, never a mix of old and new. The on/off state, applied last of an LFO's fields, still starts or stops it at once, with its settings in place. A plain edit outside a scene reaches the engine at once, as before. This also ends 3.6's fault where a recalled shape change sent the old rate and depth for one step.
- **An edit by a deferrable source goes through the round robin and the send budget** (#633): a control param set while `S.deferrable_write` is set (a macro apply, morph, gesture playback) marks its LFO `deferred` instead of `edited` (a phase edit marks nothing: its param moved from `phase_seen`, below), and the next step marks the LFO's `setFastLfo` (a phase edit: its `syncFastLfo` alone) due in the round robin, inside the 12 a step and counted in `ENGINE_BUDGET`. Every other edit goes at once, uncapped: a hand edit, and a scene fade's step, which sets its params outside `deferrable` as a recall does (`docs/notes/lua/engine-sync.md`), so a 2 s fade of an LFO's depth sends its 20 `setFastLfo` at once (#875).
- **An engine-run LFO's commands**: `setFastLfo(n - 1, voice - 1, destination, shape - 1, rate', depth' / 100, 2 × offset / 100)` at a start, a new voice, destination or shape, and a hand edit; then `syncFastLfo(n - 1, phase(n))` after a start, a shape, mode, division or phase change, every bar (`LFO.bar_beats`, 4) for a clocked LFO and at once when the beats fall (a transport start); `stopFastLfo(n - 1)` when it is turned off, its depth goes to 0 or its destination stops being fast. Its modulated rate is resent past `LFO.engine_rate_threshold` (0.5 %) and its depth past 1/1000, through the round robin. Never more than one node per LFO: a running node is moved or replaced by `setFastLfo`, never started again.
- **Every round-robin send of an engine LFO counts against the send budget**: it is `S.lib.engine_sync.send_engine_value` of the key `lfo<n> engine` (`setFastLfo`) or `lfo<n> sync` (`syncFastLfo`), whose engine senders (registered at include time) read the LFO's settings or phase when they deliver, so a send that waited for the next window carries the newest, and send nothing once the LFO's node has gone (stopped, off, depth 0 or a Lua destination), so a waiting send never starts one again.
- **A clocked engine LFO's rate reads `S.lib.params_setup.beat_seconds_now()`**, and a change of its base rate (its division at the tempo) past `LFO.engine_rate_threshold` goes out in the step that sees it, ahead of the round robin and not counted in `sends_per_step` (at most one send per LFO), so a tempo change (the param, Link, MIDI clock) reaches every clocked engine LFO within one step however full the round robin is.
- **A modulation input reads a lower-numbered LFO only** (`strata_lfo<n>_rate_mod` and `_depth_mod` offer none, L1 .. L(n-1)), so the six evaluate in index order with no loop. A source that is off reads 0.
- Every resolved destination is a control param, and every label, with `~` when it is fast, fits the LFO page's right column (49 px). A global destination's param (`S.register_lfo_global_destination`) is checked at the clock's start step, once every params record has run: one that is not a control param raises, naming its label.
- `with_lfo_offsets` (`lib/engine_sync.lua`) keeps its name (ruling 21) and holds no LFO term: an LFO's offset on a Lua param is the matrix's extra offset.
- **A destination is stored by its key, never its index** (3.7, design decision 24), in the home routing: the matrix's live file, a PSET's `.matrix.data` and a scene's `matrix` block hold `[16 + n] = {source = "lfo<n>", dest = <key>}` when it is set. A key is the param id the destination moves, `v<i>_main` for a voice's main entry, or `""` for none, and no two entries share one (a second destination of one param is an error naming the register function). A key the list lacks is kept and reads as none (ruling 19): the page shows `none` until its row is turned, it does not play, and the matrix names it (`matrix: <path>: LFO <n>'s destination <key> is unknown here; kept, and it does not play`) at each file load and once a session for a scene. **A PSET written by 3.7** has `strata_lfo<n>_dest` and `_dest_key` lines that name no param now: norns' `ParamSet:read` skips them silently, and its version 1 `.matrix.data` loads through the side file's floor with every home `""`, so its LFOs come back aimed at nothing. A 3.7 MIDI map of `strata_lfo<n>_dest` is left to the player (ruling 20).
- **The list is ordered by voice**: none, the globals, each voice's destinations together, the macros. A registered per-voice destination (`S.registry.lfo_destinations`) joins its voice's group after the built-in ones, in registration order; a registered global one joins the globals, unless its param is a macro's (`macro_<m>`), which make the last group. Indices move whenever a destination is added, so nothing stores one: `destination_index(n)` and `destination_id(index)` translate for the LFO page. The full list is built at init (`add_lfo_params`); include time builds the built-in ones only, into the same table, with the key-to-index map.
- The LFOs' scene fields are `S.lib.lfos.SCENE_FIELDS`, which `lib/scenes.lua` appends to `S.SCENE_GLOBAL_PARAMS` after its built-in globals, the records themselves: a change to an LFO's scene fields is made here, never in `lib/scenes.lua`, and a new field needs its `default`. `S.lib.lfos.transition_stops(n, scene_data)` is what a fade asks of an LFO (#408).
- **A param set without its action** (a silent PSET read, which also loads the homes from the side file) converges at the next step: an LFO found off, or at depth 0, lets its direct destination go (`step_direct`), its Lua destination go (the matrix) and its engine LFO stop; a home that changed gives the old one back; a running engine LFO's rate, depth or offset that moved is sent in the round robin (the step compares each with what the engine has: the rate past `LFO.engine_rate_threshold`, the depth and the offset past 1/1000), and a phase param other than the one the engine was last synced to (`phase_seen`) syncs it there (#634).
- **A restart syncs**: the on action run on a running LFO (a bang, #251) restarts its phase at the phase param and syncs an engine LFO's node to it, without replacing the node.
- No step raises (#517): each LFO's step, each `on_step` hook and each send run through `S.lib.ui_frame.contained_call`, which prints `strata: LFO <n> step failed:` (or `LFO step hook`, `LFO send`) with the traceback, once per distinct message, and the clock and the other LFOs go on. A Lua home is resolved in the matrix's read of it (`strata: matrix home <n> failed:`); the LFO's own step resolves only a fast home (a fixed param) and reads a direct one's key.
- The page randomize (#557) sets `strata_lfo<n>_shape`, `_rate`, `_division` and `_phase`, so their actions call `note_param_edit` (an edit of a held param ends the randomize undo). A new randomized LFO param needs the same call.

## Machines

### lfo clock
- **State:** `S.lfo_clock` (the clock's id), the module's `clock_runs`, and the clock's coroutine in `clock.threads`: running from the start step `lfo_clock` (125) to the cleanup step `lfos` (120) or `stop_clock()`, else stopped.
- **Invariant:** `lfo clock`: the clock runs exactly while `clock_runs` is set, its coroutine alive (one canceled or ended behind the module's back breaks it).
- **Test:** `test/unit/lfos_test.lua`: "lfo clock: every cell is decided" and its rows (each state counts the steps a hook sees from then on; the state is read from `S.lfo_clock` and `clock.threads`), and "the LFO clock invariant holds from the start step to cleanup".

`lib/lfos.lua` cancels its clock only as the script starts or ends (the start step, cleanup and a test's `stop_clock`), when no resume can go astray: it is one of the nine files that keep `clock.cancel` and do not use the clock helper (`docs/notes/lua/clocks.md`). Every cell is a row.

| State | Event | Next | Effect |
|---|---|---|---|
| `stopped` | `the start step` | `running` | the global destinations checked, then a clock that sleeps `1 / LFO.step_hz` s and runs a step |
| `stopped` | `time passes` | `stopped` | no step runs |
| `stopped` | `the cleanup step` | `stopped` | nothing to cancel (what the step does to waiting sends is the round robin's `the cleanup step`) |
| `stopped` | `stop_clock` | `stopped` | nothing |
| `running` | `the start step` | `running` | the kept clock canceled and a new one started, so a wake runs one step (a normal init never meets this) |
| `running` | `time passes` | `running` | one step at each wake (the step pipeline, below) |
| `running` | `the cleanup step` | `stopped` | `stop_clock()` cancels it, and no `stopFastLfo` is sent (#461); the step also empties the round robin (its table's `the cleanup step`), gives every direct destination back and forgets the engine copies |
| `running` | `stop_clock` | `stopped` | canceled |

### LFO place
- **State:** derived at every step from three facts, never stored: the on param (`strata_lfo<n>`), the depth param and the kind of the home's entry (`S.lib.lfos.destination(n)`: `fast`, a direct destination's key, any other). What was handed on is beside it: `state[n].engine` (the engine's copy), `direct.held[n]` and the matrix's `held` (`docs/notes/lua/matrix.md`, matrix holding). No accessor names the place yet (package 4c's `place(n)`); `is_engine_run(n)`, `engine_playing(n)`, `home_m(n) ~= nil`, `owns(n, id)` and `modulates(id)` each answer a part.
- **Invariant:** none: every combination of the three is a place the next step converges to, and a stored place would be a second record of the params (the clock's invariant is `lfo clock`).
- **Two facts:** the depth param at 0 is both an amount and "no engine node" (the node stops, and a depth swept through 0 starts it again with a sync; the fade's `stop_target` and a home's ramp through 0 rely on it); `state[n].engine` is both "a node exists" and the settings last sent to it; `home_m(n)` is nil for "does not play" (off, or the depth param 0) and 0 for "plays at 0" (the matrix adds nothing either way, and a direct destination stays held).
- **Test:** `test/unit/lfos_test.lua`: "an LFO on a fast destination runs in the engine", "engine LFOs a macro moves at 30 Hz stay inside the round robin's 12 a step and the budget's count (#633)", "a silent PSET read reaches a running engine LFO's offset and phase at the next step, once (#634)", "an LFO turned off gives its Lua destination back at the next step, once" and the recall tests ("a recall that changes every LFO setting sends nothing at once, then one setFastLfo and its sync").

The five places: `off` (the on param 0: nothing held); `idle` (on, at depth 0 or with its home none or unknown: nothing held); `engine` (on, depth above 0, a fast home: `state[n].engine` holds the node's settings); `direct` (on, depth above 0, a macro: `direct.held[n]` is its id); `matrix` (on, depth above 0, any other home: the matrix sums it into `held.lua[id]`, or `held.fast[id]` for a `v<i>_main` that resolves to a fast param, ruling 16). A transient of one step is legal: `state[n].engine` kept while the params no longer play in the engine (a silent read, a scene's apply), until the step stops the node.

No `h.transition_table` holds this table (design section 5 makes it a smaller entry, a table and no test): a place is derived from params many writers move, its causes reach the engine, the matrix and the macros, and most of its cells are paths in time rather than a next state; the modulation walk (package 3c) checks the places against a model fed by the engine calls. The table is the cause-to-path table: what each cause sends and when, at once (in the action), at the next step outside the round robin (uncounted, at most one send an LFO a step), or at the next step through the round robin (`mark_due`) and the send budget.

| State | Event | Next | Effect |
|---|---|---|---|
| `off` | on (its action, a bang included) | its home's place | `turned`: the phase starts at the phase param; `engine`: `setFastLfo` and `syncFastLfo` at once; `direct`: held and handed over at the next step; `matrix`: summed at the next step, sent through the round robin |
| `engine` | on again (a bang) | `engine` | the phase restarts and `syncFastLfo` goes at once, the node kept (#251) |
| `engine` | off | `off` | `stopFastLfo` at once |
| `direct` | off | `off` | the macro given back at once (`release_direct`) |
| `matrix` | off | `off` | given back at the matrix's next step, through the round robin (ruling 17) |
| `engine` | depth to 0 | `idle` | `stopFastLfo` at the next step, outside the round robin |
| `direct` | depth to 0 | `idle` | the macro given back at once (the depth action) |
| `matrix` | depth to 0 | `idle` | given back at the matrix's next step, through the round robin |
| `idle` | depth above 0 (by hand or a deferrable source) | its home's place | `engine`: `setFastLfo` and `syncFastLfo` at the next step, outside the round robin (a start, whoever moved the depth); `direct`: held at the next step; `matrix`: summed at the next step, through the round robin |
| `engine` | a hand edit of the rate, depth, offset or a mod amount, or a scene fade's step | `engine` | `setFastLfo` at the next step, outside the round robin (`edited`); a fade's step sets its params outside `deferrable`, so a 2 s fade sends its 20 `setFastLfo` so (#875) |
| `engine` | a hand edit of the phase | `engine` | `setFastLfo` and `syncFastLfo` at the next step, outside the round robin |
| `engine` | an edit by a deferrable source (a macro, morph, gesture playback) | `engine` | `lfo<n> engine` marked at the next step, through the round robin and the budget (`deferred`, #633); a phase edit `lfo<n> sync` alone, the same way |
| `engine` | the shape, mode, division or a mod source | `engine` | `setFastLfo` at once, and `syncFastLfo` for the shape, a mode or a clocked LFO's division; while a scene applies only marked, and sent once at the next step |
| `engine` | its home to another fast destination | `engine` | `setFastLfo` at once (a new voice or destination); only marked while a scene applies |
| `engine` | its home to a Lua destination | `matrix` | `stopFastLfo` at once; summed from the matrix's next step |
| `engine` | its home to a macro | `direct` | `stopFastLfo` at once; held at the next step |
| `matrix` | its home to a fast destination | `engine` | `setFastLfo` and `syncFastLfo` at once; the old param given back at the matrix's next step |
| `matrix` | its home to another Lua destination | `matrix` | the matrix's next step sums the new param and gives the old one back, both through the round robin |
| `direct` | its home changed | the new home's place | the macro given back at once (`home_changed`), then as the rows above |
| `matrix` | a voice's source switch (a home on `v<i>_main`) | `matrix` | `main` resolves again at the matrix's next step: the new param summed (a fast one through `setFastOffset`), the old one given back |
| `engine` | a modulated rate past `LFO.engine_rate_threshold`, or depth past 1/1000 (its mod inputs) | `engine` | `lfo<n> engine` marked, through the round robin and the budget |
| `engine` | the tempo (a clocked LFO's base rate past `LFO.engine_rate_threshold`) | `engine` | `setFastLfo` in the step that sees it, ahead of the round robin |
| `engine` | a bar, or the beats fall (a clocked LFO; a transport start) | `engine` | `syncFastLfo` in the step |
| `engine` | a silent set of the rate, depth or offset | `engine` | nothing at the set; compared at the next step and sent through the round robin (#634) |
| `engine` | a silent set of the phase | `engine` | nothing at the set; `lfo<n> sync` at the next step, through the round robin (`phase_seen`) |
| `off` | a silent set on | its home's place | nothing at the set; at the next step as the on row (an engine node's `setFastLfo` and `syncFastLfo` outside the round robin), its phase where the stale position lands |
| `engine` | a silent set off, or of the depth to 0 | `off` or `idle` | nothing at the set; `stopFastLfo` at the next step |
| `direct` | a silent set off, or of the depth to 0 | `off` or `idle` | nothing at the set; the macro given back at the next step (the step's `release_direct`) |
| any place | a silent PSET read | the place the read's params give | the module has no PSET hook: its params converge at the next step, as the silent sets above; the matrix's hook loads the homes and tells each changed one (`home_changed`, reconciled then, with the read's LFO params in place); and the `voice_params` hook, the last, sets the read's per-voice params with their actions (#951, `docs/notes/lua/params.md`), so a Lua home on one is summed over its new stored value at the next step |
| any place | a recall (instant, a fade's end, morph's discrete crossing) | the scene's place | the block sets the home, the globals only mark the LFO (`S.scene_recall_in_progress`); the on/off, applied last, starts or stops it at once with the scene's settings in place; else the next step sends it once (0e's review) |
| `engine` | a voice's start or stop | `engine` | nothing: the node lives outside the voices |

### step pipeline
- **State:** where `step_all` is in a step, one synchronous call that never yields; the local `step_hooks` (the `on_step` hooks in registration order: `strata.lua`'s include order, then the start steps'), `direct.due` and the round robin (below).
- **Invariant:** none: a step runs its four phases in one call, so no other code sees one half done; the clock's invariant is `lfo clock`.
- **Test:** `test/unit/lfos_test.lua`: "the step hooks run macros, envelopes and random sequences before the matrix, and the notes flush last" (each hook's source file from `debug.getinfo`).

| State | Event | Next | Effect |
|---|---|---|---|
| `asleep` | the clock's wake | `LFOs` | `util.time()` read once for the step |
| `LFOs` | each LFO's step, in index order | `hand-overs` | its phase, value, rate' and depth'; an engine home reconciled (`reconcile_engine`), a direct one held and marked, a Lua one left to the matrix; each contained (`LFO <n> step`) |
| `hand-overs` | each marked direct destination | `hooks` | handed over once with every holding LFO's offset (`send_direct`), contained (`LFO send`) |
| `hooks` | each hook, in registration order | `drain` | contained (`LFO step hook`); a hook marks sends, the matrix's sums its routings and homes |
| `drain` | the round robin's turn | `asleep` | at most `LFO.sends_per_step` (12) due keys that reach the engine, each inside `deferrable` |

The hooks run in this order on this build: `midi_in`, `scan`, `conditions`, `macros`, `random_sequences`, `envelopes`, `matrix`, `expression`, `slices`, `io/targets`, `io/midi_out`, `io/crow`, `io/ii`, `delay_sync`, `ui/slice_editor` (all registered at include time), then the notes flush (`START_ORDER.notes_load`, 109) and the arp's shuffle (`START_ORDER.arp`, 112). No `h.transition_table` holds the phases' table (design section 5 makes it a smaller entry, a table and no test): a step runs its phases in one call, so no event can find it between two; the hooks' order is held by the test named, and the modulation walk (package 3c) runs whole steps. Four relations matter, and the test holds them: the macros', the envelopes' and the random sequences' hooks run before the matrix's (each hands the matrix what it sums in the same step; moving one after it lags every routing it feeds by a step, 21 ms), and the notes flush runs after every hook registered at include time (`lib/expression.lua`'s marks are sent in the same step). The arp's shuffle runs after the flush; it sends the arp's lists (counted with `count_sends`), never a note's expression, so its place there costs nothing.

### round robin
- **State:** the local `queue`: `keys` (every key in the order first marked, never removed), `known[key]`, `due[key]` (the send waiting, or nil) and `cursor` (where the next drain starts). Per key: `unknown`, `known` (no send waiting) or `due`.
- **Invariant:** none: every combination of the fields is legal; a key once known stays known.
- **Two facts:** a key's place in `keys` is both that it is known and its turn in the round robin's order of fairness.
- **Test:** `test/unit/lfos_test.lua`: "round robin: every cell is decided" and its rows (one key's state, read from the module's `queue`, with twelve filler keys that reach the engine known ahead of it and the drain starting at the first, so `a full step` is one whose twelve fillers are all due), "at most 12 sends a step, round robin, and every due key within two steps", "a stopped voice's due sends take none of a step's 12; a running voice's stay capped at 12 (#644)"; `test/unit/engine_sync_test.lua`: "a keyed id holds a space and starts v<i>_ only as its voice's gated sender".

Every cell is a row. One more way out of `due` is not in the table, since no outside key meets it: an LFO's own keys (`lfo<n> engine`, `lfo<n> sync`) are withdrawn by `send_fast_lfo` and a stop (`reconcile_engine`); every other module's send reads its state when it runs, so it is never withdrawn.

| State | Event | Next | Effect |
|---|---|---|---|
| `unknown` | `mark_due` | `due` | appended to `keys`, after every key known |
| `unknown` | `a step` | `unknown` | nothing |
| `unknown` | `a full step` | `unknown` | nothing |
| `unknown` | `the cleanup step` | `unknown` | nothing |
| `known` | `mark_due` | `due` | the send waits for its turn; the key keeps its place |
| `known` | `a step` | `known` | passed over, taking no slot |
| `known` | `a full step` | `known` | passed over |
| `known` | `the cleanup step` | `known` | nothing waits |
| `due` | `mark_due` | `due` | the newer send replaces the one waiting, in the same place |
| `due` | `a step` | `known` | sent inside `deferrable`; it takes one of the step's 12 only when `S.lib.engine_sync.reaches_engine(key)` (#644) |
| `due` | `a full step` | `due` | the 12 are taken before its turn: it waits, and the next step's drain starts with it |
| `due` | `the cleanup step` | `known` | withdrawn (`queue.due = {}`): it is never sent |

A key is a param id (a Lua destination's, shared by the LFOs, the matrix and the macros: one send carries every layer) or a keyed id that no param holds. A keyed id holds a space (no param id can be it) and does not start `v<i>_`, so a voice's sync (`forget_sent_voice_values`, `docs/notes/lua/engine-sync.md`) keeps the value it recorded: `lfo<n> engine`, `lfo<n> sync`, `matrix fast <voice> <destination>`, `env route <k>`, `delay sync`. A voice's own keyed ids (`lib/scan.lua`'s `v<i>_follow rate` and `v<i>_scan sync`, senders gated on the voice) start `v<i>_` on purpose: the voice's sync and start drop a value of theirs. The value `lfo<n> engine` and `lfo<n> sync` hand to the budget (the depth / 100, the phase) is read by nothing (#928): the senders read the LFO when they deliver, and the value is there for the budget, which keeps a waiting send as its key's value.

## Owns

`lib/lfos.lua` (`S.lib.lfos`):
- `S.LFO_DESTINATIONS`, `S.selected_lfo`, `S.lfo_clock`;
- the global `add_lfo_params`;
- the tunables `LFO` (`S.lib.lfos.LFO`) and `FAST_DESTINATIONS`; the readers `param_id(n, field)`, `fast_destination(param_id)`, `destination(n)`, `destination_index(n)`, `destination_id(index)`, `destination_groups()`, `label(n)`, `is_on(n)`, `is_clocked(n)`, `is_engine_run(n)`, `engine_playing(n)` (on, on a fast destination, at a depth above 0: what MAIN's `~` reads, package 2a), `window(selected)`, `phase(n)`, `value(n)`, `has_stepped(n)`, `base_rate(n)`, `effective_rate(n)`, `effective_depth(n)`, `capped(n)`, `describe(n)`, `shape_u(shape, phase)`; `offset_for(param_id, m)`, `m_for(param_id, base, value)`; the queue `mark_due(key, send)` and `on_step(fn)`; `direct_destination(param_id)`, `modulates(id)`, `direct_value(id)`; the home routing's `owns(n, id)`, `home_m(n)` and `home_changed(n)` (`S.lib.matrix.set_home` and the matrix's loads call it: a direct destination is given back at once, and the engine gets the LFO's settings); the engine senders `lfo<n> engine` and `lfo<n> sync`;
- `SCENE_FIELDS` and `transition_stops`;
- the modulation sources `lfo1`..`lfo6`;
- the start step `lfo_clock`, the cleanup step `lfos` and the invariant `lfo clock`.

Elsewhere:
- The LFO page is `lib/pages/lfo.lua` (`docs/notes/lua/pages/lfo.md`), the arc's LFO rings `lib/arc/lfo.lua` (`docs/notes/lua/arc-pages.md`).
- `forget_arc_lfo_period_ticks` is in `lib/arc/core.lua`; the mode action calls it for the selected LFO.
- The five fast destinations' engine side is the modulation area (`docs/notes/engine/modulation.md`).
- The grid has no LFO controls.

Six LFOs (`NUM_LFOS`, the engine's `numFastLfos`). They are not the per-voice drift (`drift_update`, `docs/notes/lua/mutation.md`). norns' `lua/lib/lfo.lua` is no longer used (3.4, design Question 1).

## Params

`add_lfo_params()`, called from `init` after the FX group (the "lfos" `S.registry.params` record), builds the whole destination list and adds one group per LFO, `strata_lfo_<n>` ("LFO n", `LFO.group_size` 12 params; groups cannot nest). The destination is no param since the groundwork before 3.8 (its home routing; 3.7's `strata_lfo<n>_dest` and `_dest_key` went):

| Param | Kind | Default |
|---|---|---|
| `strata_lfo<n>` | binary toggle (on) | 0 |
| `strata_lfo<n>_shape` | option: sine, tri, square, up, down, s&h, smooth, drunk | 1 |
| `strata_lfo<n>_mode` | option: free, clocked | 1 |
| `strata_lfo<n>_rate` | control 0.003-50 Hz, exp, step 0 | 0.25 |
| `strata_lfo<n>_division` | option: 1/16 ... 1024 (the library's 22 clocked rates) | 13 (`4`) |
| `strata_lfo<n>_depth` | control 0-100 %, step 1 | 25 |
| `strata_lfo<n>_offset` | control -100..100 %, step 1 | 0 |
| `strata_lfo<n>_phase` | control 0-100 %, step 1 | 0 |
| `strata_lfo<n>_rate_mod`, `_depth_mod` | option: none, L1 .. L(n-1) | 1 |
| `strata_lfo<n>_rate_mod_amt`, `_depth_mod_amt` | control -100..100 %, step 1 | 0 |

The percents' quantum is one percent a detent. A division of value r is a period of 4r beats.

## Destinations

`S.LFO_DESTINATIONS` is the ordered list of `{label, key, resolve, group, fast}` the LFO page steps through and a home's key names, by voice (3.7):
- `none`;
- the globals (group `global`): `density`, `drift`, `filt freq`, `filt res`, `filt mix`, `dly time`, `dly fdbk`, `dly mix`, `rev mix`, `rev size`, `rev damp`, then any registered global destination (`S.register_lfo_global_destination(label, param_id, group)`) whose group is `global` (the default): today `dly>rev` (`delay_to_reverb`, `lib/voice_mix.lua`, 3.8), then `shim dly` and `shim rev` (`shimmer_delay`, `shimmer_reverb`, `lib/shimmer.lua`, 3.8);
- per voice (group `voice <i>`): `v<i> main` (key `v<i>_main`, `main_param_id(i)`, resolved on every step so it follows the voice's source), `v<i> size`, `dens`, `pitch`, `spread`, `pos`, `rate`, `scan`, then each `S.register_lfo_destination(label, suffix)` record's `v<i> <label>` in registration order: today `shape`, `skew` (`lib/grain.lua`, 3.8), `hist` (`lib/history.lua`), `vfilt`, `dsend`, `rsend`, `amp` (`lib/voice_mix.lua`), 15 a voice;
- the macros (group `macros`): `macro 1` .. `macro 16`, registered globals whose registration names the group `macros` (#729: the group is the registration's, never read from the param's name);
- The numbers follow from the registrations, never fixed: 1 none, then the globals (the 11 built-in ones and every registered global, today `dly>rev`, `shim dly` and `shim rev`: 2-15 on this build), each voice's run (15 a voice on this build, voice i from 16 + 15 (i - 1)), the macros last (121-136, 136 in all on this build; 3.7's were 1 none, 2-12 the globals, 13 a voice, the macros 104-119); a test reads `S.LFO_DESTINATIONS` and `destination_groups()` where it can, since every package that registers a destination moves the later ones. A label that repeats one is an error naming the register function.
- `S.lib.lfos.destination_groups()` is `{{name, first, last}, ...}` in list order, none aside: `global`, `voice 1` .. `voice 7`, `macros`. ALT+E3 jumps by it (#511, #580; `docs/notes/lua/pages/lfo.md`), MOD's routing view by each entry's `group`, and the matrix's destinations (`S.lib.matrix.destination_ids()`) and the macros' targets follow the list's order.
- `fast` (`{voice, destination}`) marks an entry whose fixed param is fast: `v<i> size`, `pitch`, `pos`, `vfilt` and `amp`. `is_engine_run(n)` is LFO n's home's entry having it, whether or not the LFO is on: a reader that means "moves the voice now" reads `engine_playing(n)` (on, `is_engine_run`, depth above 0: the same answer the engine sends follow), so MAIN's `~` (design §2.6, while the LFO is on; package 2a) is `engine_playing(n)` for an LFO on the selected voice.

## The clock and a step

Each step (`step_all`), every 1/48 s:
- each LFO in index order (`step_lfo`): off, its value is 0. On: a free LFO's position advances by the rate it played since the last step times the time since (`util.time()`, so a late wake-up does not slow it); a clocked LFO's phase is `(beats / period + clocked_offset + phase)` mod 1, with `clocked_offset` integrating only what rate modulation adds, so an unmodulated clocked LFO is exact against the clock. A wrap draws a random shape's next value. Then its value (2u - 1), rate' and depth' (`evaluate`), and its home: the engine's settings (`reconcile_engine`) on a fast one, else a direct one held and marked (`step_direct`); a Lua home is the matrix's hook's;
- the direct destinations the LFOs moved (a macro's), each handed over once, contained;
- the `on_step` hooks (the macros', `docs/notes/lua/macros.md`, the matrix's, which sums each playing Lua home, then the note module's expression flush, registered at its start step so it runs after every hook registered at include time, `docs/notes/lua/notes.md`, and the arp's shuffle after it: Machines, step pipeline), each contained;
- the drain: at most 12 of the due keys that reach the engine, in the round robin, each inside `deferrable` (a key that reaches none runs in its turn without a slot, #644).

`phase(n)` is computed when read: a free LFO's from its last step plus the time since at the rate it plays, a clocked one's from `clock.get_beats()`, so the page's dot is smooth. `value(n)` is the last step's (and, at the turn-on, the start's).

## Shapes and modulation

- u(φ): sine `(sin 2πφ + 1) / 2`, tri `2φ` then `2 - 2φ`, square 1 then 0, up φ, down `1 - φ`; s&h holds the cycle's draw; smooth runs from the last draw to this one; drunk the same, each draw the last plus up to ±`LFO.drunk_step` (0.2), reflected into 0..1. A turn-on draws afresh (drunk from 0.5).
- A home's `m = value × depth' / 100 + 2 × offset / 100` half ranges (`home_m(n)`, nil while the LFO is off or its depth param is 0): the matrix adds it to the param's sum, sent as `stored + sum × half the range`, clamped once by `with_lfo_offsets` with every other extra offset on the param; a direct destination's `direct_value` adds it the same way.
- `rate' = clamp(rate × 4 ^ (amount × s), 0.003 Hz, ceiling)` (the run's ceiling: 10 Hz in Lua, 50 in the engine); clocked, the division's rate at `beat_seconds_now()` times the same factor. `depth' = clamp(depth × (1 + amount × s), 0, 100)`. s is the source's `value`.
- `offset_for(param_id, m)` is `m × half the param's range` (a Lua destination's, as `with_lfo_offsets` adds it); `m_for(param_id, base, value)` inverts design §3.3's laws: pitch `/1.875`, position `/0.5`, size `/0.245`, cutoff `log(value / base) / log(31.62)`, amp `value / base - 1` (0 at base 0); any other param by half its range.

## Restores

A Lua destination is given back by the matrix: at its next step the LFO's home adds nothing to the param's sum, so the extra offset goes (or shrinks) and the param is marked due once (ruling 17). A direct destination is given back at once by `release_direct(n)` (its sender gets `direct_value(id)` without LFO n), called by the on/off action (off), the depth action (0), `home_changed`, a step whose home stopped playing, moved elsewhere or turned fast, and cleanup.

## Scenes

- `SCENE_FIELDS` per LFO, in recall order: shape, mode, division, rate, depth, offset, phase, rate_mod, rate_mod_amt, depth_mod, depth_mod_amt, then the state. Rate, depth and offset are continuous (`lfo = n`; the depth's `stop_target` 0); the rest switch at a transition's end. Every control field and the state carry `range` (the param's), which `validate_scene` checks; option fields are checked as option indices. Each default is its param's.
- The destination is the home routing, in the matrix's scene block `matrix` (`docs/notes/lua/matrix.md`, Storage): blocks apply before the globals, and while the scene applies `home_changed` only marks the LFO, so the next step sends it once with every setting the recall put in place (0e's review). A home whose destination differs between two scenes ramps the LFO's depth (`strata_lfo<n>_depth`) through 0 in a transition and switches at the midpoint, at morph's crossing (0.52 and 0.48), the matrix's rule for every routing; until 3.7 the destination switched at a fade's end. With `transition_stops`, the depth's target is 0 and the switch is harmless.
- `transition_stops(n, scene_data)`: LFO n runs now and the scene has it off.

## PSETs

No PSET hook of the module's own: a PSET's LFO lines are read as norns reads any param's, and the homes with the matrix's side file (`.matrix.data`, after the params). 3.7 deleted 3.3's LFO library import, from scenes and PSETs alike (design decision 21).

## Sources

`lfo1`..`lfo6` (`S.register_mod_source`): name `L<n>`, section `lfos`, range -1..1, `value` = `value(n)`, `describe` = `describe(n)` (`v3 pitch~ 25% <L2`), `row`: E3 the depth (`delta_with_detent`), fine E3, K3 `S.lib.pages_lfo.show_lfo(n)`, hints `K3:lfo E3:depth`.

## Cleanup

Step 120: `stop_clock()` cancels the clock, nothing waits in the round robin, and every direct destination is given back (`release_direct`); the matrix's cleanup step (118) forgets the Lua ones' offsets. norns frees the engine before `cleanup()` (#461), and an engine LFO's node with it, so no `stopFastLfo` is sent, and no test asserts an engine send from the step.

## Must not break

- **Only `S.lib.envelopes` calls `engine.setFastEnv` and `engine.stopFastEnv`** (plan's One door each), and only from the engine senders of its route keys, never from a hook, a param action or the step itself: every send goes through the LFOs' round robin (`S.lib.lfos.mark_due`) and the send budget (`S.lib.engine_sync.send_engine_value`, inside `deferrable`).
- **A route is a matrix slot**: `ENVELOPES.routes` (16) equals `MATRIX_SLOTS` and the engine's `numEnvRoutes`; routing k's route is `k - 1`.
- **The matrix leaves an owned routing out of its sum** (`docs/notes/lua/matrix.md`): a playing routing from `env<v>` to a fast destination plays only in its engine node, so a hit never reaches the fast channel twice. Everything else about the routing (its depth and on/off params, its scene block entry, its PSET and live files, `uses_source`, `affects`) is the matrix's as for any routing.
- **A step builds no table**: a voice's settings and a route's wanted settings are filled into tables made once (one per voice, one per route); only a send that hands new settings to the budget copies them (the budget keeps what it was handed, and the route's own table is filled again at the next step).
- **What a route has is the budget's answer**: the engine has or will have `S.lib.engine_sync.expected_value("env route <k>")`: the settings table last handed on (waiting or delivered), `false` once a stop was handed on, nil before any send. A step marks the route due when its owned settings differ from it, or when it holds settings and the slot is no longer owned; the round robin's send reads the routing again when it runs and hands on nothing when it already matches. So a stop is sent once, a set once per change, and nothing at all while no envelope is routed to a fast destination (a test counts the calls).
- **A hit never sends**: the `voice_hit` hook only records the voice's hit (its time, the level then and its hold), as a hook must (`docs/notes/lua/engine-sync.md`). The engine fires its routes from its own `voiceHit` (`docs/notes/engine/envelopes.md`).
- **An ended envelope stays ended** (#969): with the loop off, a hit whose run is over reads 0 until the next hit, whatever its times are set to after, as `\strataEnvelope`'s done `EnvGen` holds its end (a `setFastEnv` sends no `t_hit`). Every envelope param's action runs `retire` before `add_voice_param`'s action stores the new value, since the stored values are what the model reads and only an action changes them.
- **`shape` is the engine's shape**: `\strataEnvelope`'s segments (attack from the level at the hit to 1, decay to the sustain, the hold, release to 0, each `from + (to - from) × (1 - exp(curve × t / T)) / (1 - exp(curve))`, a line at curve 0), with sustain 0 holding and releasing in no time, and a loop that starts again from 0 with the same hold. A change to the def's shape changes this function in the same change.
- **The six params are scene fields that default to the engine def's values** (`docs/notes/engine/envelopes.md`, `\strataEnvelope`'s arguments): a scene saved before them loads every envelope as 3.7 starts. They are never VOICE rows, faders, a randomize's or a mutation's (`fader = false`, no `voice_rows`, no `randomize`: plan ruling 35).

## Machines

### envelope model
- **State:** per voice, the local `hits[v]` (nil before its first hit, else `{time, from, hold, ended}`) and `looping[v]` (the loop as its action last set it, which the stored `env_loop` equals); the settings are read from `S.voices[v].values` at each use (`settings`). The state is derived when read: `no hit`, `running` (the loop off, less time since the hit than its run: attack, decay and, with a sustain above 0, the hold and the release), `ended` (the loop off, and the hit's `ended` set or the run over), or `looping` (the loop on, which always holds a hit: turning it on records one); `S.lib.envelopes.value(v)` is the level. `ended` on the hit is the one stored fact (#969): once the settings change, the run's end can no longer be worked out from them, so each envelope param's action sets it (`retire`) at the settings the run had, before the new value is stored.
- **Invariant:** none: every pair of a hit and the loop flag is legal, and the level is computed from them when read.
- **Test:** `test/unit/envelopes_test.lua`: "envelope model: every cell is decided" and its rows (voice 3 at the defaults, a run of 0.205 s; the state read from the module's `hits` and the stored settings; `looping` entered in its third cycle), "turning loop off finishes the cycle it is in, as the engine does", "a silent raise of a time after the end leaves the level at 0", "an ended envelope whose times were raised starts again when the loop goes on"; and the modulation walk (`test/unit/modulation_walk_test.lua`), whose model fails any level above 0 after an end it saw until the next hit.

Every cell is a row. A silent PSET read is no event of its own here: the `voice_params` hook, the last PSET hook (#951), sets each envelope param the read moved with its action, so the read reaches the model as the rows' `the loop on`, `the loop off` and a changed time do.

| State | Event | Next | Effect |
|---|---|---|---|
| `no hit` | `a hit` | `running` | from 0, with the hit's hold |
| `no hit` | `time passes` | `no hit` | nothing |
| `no hit` | `the loop on` | `looping` | a hit recorded now, from 0, with no hold, as the engine's node starts at once |
| `no hit` | `the loop off` | `no hit` | nothing |
| `no hit` | `a longer decay` | `no hit` | nothing |
| `running` | `a hit` | `running` | a new run from the level it is at, as `EnvGen` does |
| `running` | `time passes` | `ended` | its run's end: the level 0 |
| `running` | `the loop on` | `looping` | the hit runs on, then loops |
| `running` | `the loop off` | `running` | nothing (it was off) |
| `running` | `a longer decay` | `running` | the level follows the new settings at once (read when used) |
| `ended` | `a hit` | `running` | a new run from 0 |
| `ended` | `time passes` | `ended` | the level stays 0 |
| `ended` | `the loop on` | `looping` | a new hit now, from 0, with no hold |
| `ended` | `the loop off` | `ended` | nothing (it was off) |
| `ended` | `a longer decay` | `ended` | the level stays 0 (#969): the action marks the hit `ended` at the settings it ran with before it stores the new value, as the engine's done `EnvGen` holds its end |
| `looping` | `a hit` | `looping` | a new run from the level it is at, looping |
| `looping` | `time passes` | `looping` | each cycle again from 0, with the same hold |
| `looping` | `the loop on` | `looping` | nothing (it was on) |
| `looping` | `the loop off` | `running` | in its first cycle the hit runs on; in a later one the hit moves to the cycle's start (from 0, the same hold), so the cycle finishes as the engine's does |
| `looping` | `a longer decay` | `looping` | the cycle follows the new settings at once |

### envelope route
- **State:** per route k, the send budget's record under `env route <k>` (`S.lib.engine_sync.expected_value`): nil (never sent), a settings table (the engine has or will have the node so), or `false` (a stop was handed on). The module keeps no record of its own; what the route should carry is `route_want(k)`, a pure read of the routing and its source voice's settings, and `S.lib.envelopes.owns(k)` says whether it is the engine's.
- **Invariant:** none: the record is what was handed on, and the step's compare brings it to the routing.
- **Two facts:** nil and `false` both mean "no node": nil that nothing was ever sent, `false` that a stop was.
- **Test:** `test/unit/envelopes_test.lua`: "envelope route: every cell is decided" and its rows (route 3, from `env2` to voice 5's cutoff at 50 %; each event is a change and two LFO steps; the state read from the budget's record), "a routing from an envelope to a fast destination is the engine's", "turning the routing off, to a Lua destination or to another source stops its route", "with no envelope routed nothing is sent".

Every cell is a row. `route it` makes the routing owned (set and on); `unroute it` turns it off, as a Lua destination, another source, depth 0 or a cleared routing would; `a setting changed` is a param of the source voice, as the depth, the destination or the source voice would be.

| State | Event | Next | Effect |
|---|---|---|---|
| `nil` | `route it` | `settings` | marked due; the round robin's send hands a copy to the budget, whose sender sends `setFastEnv` |
| `nil` | `a step` | `nil` | nothing |
| `nil` | `a setting changed` | `nil` | nothing: no routing owns the route |
| `nil` | `unroute it` | `nil` | nothing: no stop is sent for a route that never had settings |
| `settings` | `route it` | `settings` | nothing: the same settings |
| `settings` | `a step` | `settings` | nothing |
| `settings` | `a setting changed` | `settings` | marked due; `setFastEnv` again (the engine moves the node) |
| `settings` | `unroute it` | `false` | marked due; `stopFastEnv` once |
| `false` | `route it` | `settings` | marked due; `setFastEnv` |
| `false` | `a step` | `false` | nothing |
| `false` | `a setting changed` | `false` | nothing |
| `false` | `unroute it` | `false` | nothing: the stop went once |

## Owns

`lib/envelopes.lua` (`S.lib.envelopes`, 3.7 package 2f, design §7, decision 4), included after `lib/random_sequences.lua` and before `lib/matrix.lua`:
- `M.ENVELOPES` (`S.constants.ENVELOPES`): `routes` 16, `time_min` 0.001, `time_max` 10, `approximate_under` 0.05 s. The module's own names and defaults are its local `ENV` table.
- The voice-param record `envelopes` (count 6, `fader = false`, no VOICE rows), per voice: `v<i>_env_attack`, `v<i>_env_decay`, `v<i>_env_release` (control 0.001-10 s, exp; defaults 0.005, 0.2, 0.2; shown `5ms`, `200ms`, `1.5s`, `10s`), `v<i>_env_sustain` (control 0-1, 0), `v<i>_env_curve` (control -8 to 8, -4) and `v<i>_env_loop` (option off, on; off). The five controls crossfade in scenes (`scene_ranges` refuses one outside its range); the loop is discrete, switched at a transition's end. Each action marks the voice's routes; turning the loop on starts an envelope that is not running.
- `shape(settings, elapsed, hold, from)`: pure, `settings` `{attack, decay, sustain, release, curve, loop}`.
- `value(voice)`: `shape` now, from the voice's last hit (0 before any hit, once that hit's run has ended with the loop off until the next hit, and for a voice outside 1..7).
- `owns(k)`: whether matrix routing k is the engine's, the matrix's one answer (`S.lib.matrix.status(k)` is `owned`, #926); the matrix's step reads the status itself, so it calls no `owns`. `source_voice(k)`: the voice whose envelope routing k's source is (`env<v>`), else nil, which `status` reads to tell an envelope's routing from any other.
- The sources `env1`..`env7` (section `envelopes`, names `EN1`..`EN7`, range 0-1, no `row`): `describe` is the attack and decay (`5ms 200ms`), with `~` in front while the envelope reaches a Lua destination through a playing routing and its attack or decay, as shown in whole ms, is under 50 ms (the exp map stores 0.05 as 0.04999..., so an unrounded compare would mark a time shown as `50ms`) (MOD's row says the model is coarse there, as IO marks an engine LFO's model); `fields` lists six rows, `attack`, `decay`, `sustain`, `release`, `curve`, `loop`, each `params:string` and `enc_param_delta(3, id, d)`; the five control rows give the same function as their `fine_enc` (it turns finely under ALT itself), so MOD's ALT hint names `E3:fine` there, and `loop`, an option, has none.
- The `voice_hit` hook `envelopes`, an LFO step hook, and the engine senders of the 16 route keys `env route <k>`.
- Its tests: `test/unit/envelopes_test.lua` (and the matrix's hand-off in `test/unit/matrix_test.lua`). Its user page: `docs/user/modulators.md` (Envelopes).

## The model

The hook keeps, per voice, the last hit: `util.time()`, the level `value` had at that moment (a new hit starts its attack from the level it is at, as `EnvGen` does) and the hold: `info.gate_seconds` when the hit carries it (a gated step's), else the voice's gate length (`S.lib.sequencer.gate_seconds`) when `seq_gate` is on, else 0. A hit is what `docs/notes/lua/engine-sync.md` (One hit) says: a start no retrigger follows, a retrigger (a step, a MIDI note, an action) and a played extra note's start; a chord step is one hit.

The matrix reads `value` through the source (`S.lib.mod_sources.normalized`, unipolar) at each 48 Hz step for a Lua destination: exact for slow envelopes, coarse under about 50 ms (a step is about 21 ms, and the Lua path lags the value it sends). The model and the engine differ where `docs/notes/engine/envelopes.md` (Hits) says: a start its retrigger follows is one hit here and two there, chord notes are hits only there, and a start Lua rolls back fires the engine's routes only.

The loop's changes (the `env_loop` action, kept per voice in `looping`; a set to the value it has changes nothing): turning it on with no hit, or once the last hit's envelope has ended, records a hit with no hold from 0, so the model runs from then, as the engine's node starts at once; a running envelope runs on and then loops. Turning it off mid-loop moves the hit to the start of the cycle it is in (from 0, the same hold), so the model finishes that cycle as the engine's `EnvGen` does; in the first cycle the hit runs on as it is. The action writes `env_loop`'s stored value (`S.voices[v].values`, which `add_voice_param`'s action sets) and `looping` together, and the model and the node read the same stored flag (`settings`). A silent PSET read (`params:read(n, true)`, a script's or a mod's; norns' PSET menu reads with actions) runs no action as it reads; then the `voice_params` hook, the last PSET hook (#951, `docs/notes/lua/params.md`), sets each envelope param whose stored value is not the read's with its action, as a read with actions would: the stored value, `looping` and the routes follow the file, so the model and the node agree (#875).

## The routes

Each step (the hooks run in registration order: the envelopes' before the matrix's) brings each slot's route to its routing:
- **Owned** (`S.lib.matrix.playing(k)` gives a fast destination id, `S.lib.lfos.fast_destination`, and the source is `env<v>`): the route should carry `{source v, voice, destination, depth / 100, the source voice's attack, decay, sustain, release, curve, loop 0/1}`, sent as `engine.setFastEnv(k - 1, v - 1, voice - 1, destination, depth / 100, attack, decay, sustain, release, curve, loop)`. A new destination or source voice is a set, never a stop and a set: the engine moves the route's node.
- **Not owned** (off, depth 0, cleared, a Lua destination, another source) while the route has settings: `engine.stopFastEnv(k - 1)`.

The engine sender delivers the value it is handed, which the round robin's send works out when it runs: a value that waited in the budget is never older than the routing. A param change of voice v marks every route v fires (at most sixteen); the same step's compare finds them too.

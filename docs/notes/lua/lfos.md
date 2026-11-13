## Must not break

- LFOs modulate around the stored value and never `params:set` their destination. A Lua-run LFO sends `with_lfo_offsets(id, params:get(id))` through `S.lib.engine_sync.send_engine_value`, with its offset `m` in `S.lfo_scaled[n]` and its param in `S.lfo_last_dest[n]`; an engine-run LFO sets neither.
- **The destination decides where an LFO runs** (design 3.4 Question 2): a destination entry whose fixed param is one of the five fast ones (`v<i>_grain_pitch`, `buf_pos`, `grain_size`, `filter_freq`, `amp`: the entry's `fast`) runs in the engine, at any rate; every other one, `v<i> main` included (it can resolve to any param), runs in Lua, at most `LFO.lua_max_hz` (10 Hz).
- **One clock** (`S.lfo_clock`) steps all six, every `1 / LFO.step_hz` s (48 Hz), in index order, from the start step `lfo_clock` (125) to the cleanup step `lfos` (120); the `lfo clock` invariant checks it, its coroutine included (`clock.threads`: a clock canceled or ended behind the module's back breaks it, as the scene sequencer's does). Only `S.lib.lfos.stop_clock()` (cleanup's, and a test's that wants a quiet scheduler) stops it. Its sleep is outside every deferrable write: each send of a step goes inside `S.lib.engine_sync.deferrable` (the drain), and nothing inside yields.
- **At most `LFO.sends_per_step` (12) sends a step**, the LFOs' and the matrix's together, in one round robin (`mark_due(key, send)`): keys in the order first marked, a later mark of a key replacing its send, the next step starting where the last stopped. A Lua destination's key is its param id, so two LFOs (or an LFO and the matrix) on one param send once.
- **A due key that reaches no engine takes no slot** (#644): the drain asks `S.lib.engine_sync.reaches_engine(key)` before it counts a key against the 12 (`docs/notes/lua/engine-sync.md`, the send budget's "What counts": a stopped voice's param, a key with no engine sender, the master density with no voice running); such a key still runs in its turn, inside `deferrable`, so its value is recorded and the LFO's compare (`expected_value`) reads what it read before. A stopped voice's moving LFO never takes a running voice's slot, and the voice's start sends its stored values, the LFO's next step its modulated one (the start forgets what was recorded).
- **A direct destination takes no slot and no budget message** (#636): a param whose engine sender reaches no engine registers with `direct_destination(param_id)` (the macros', `docs/notes/lua/macros.md`). An LFO on it runs `S.engine_senders[id]` itself with `with_lfo_offsets(id, params:get(id))`, once a step after the six LFOs and before the hooks (every LFO on it stepped), when that moved by `LFO.send_threshold` along its range from the value it last handed over, and at once at a restore; never through `mark_due` or `send_engine_value`.
- **A Lua send is skipped under `LFO.send_threshold`** (1/1000) of the destination's range, measured along its warp (`destination_position`: an exponential range in octaves, #406) with a step-0 copy of its spec, never the param's own spec. Restores are always sent, at once. The compare is with `S.lib.engine_sync.expected_value(id)`, the value the engine has or will have (a value waiting in the send budget counts, #591); a nil expected value always sends, so a voice sync's dropped value is healed.
- **A control param's action never calls the engine** (AGENTS.md): the rate, depth, offset, phase and mod amounts mark their LFO `edited` (and the phase `sync_due`), and the next step sends them; the on/off, destination, shape, mode, division and mod source actions reconcile the engine at once.
- **An edit by a deferrable source goes through the round robin and the send budget** (#633): a control param set while `S.deferrable_write` is set (a macro apply, morph, gesture playback, a fade) marks its LFO `deferred` instead of `edited` (a phase edit marks nothing: its param moved from `phase_seen`, below), and the next step marks the LFO's `setFastLfo` (a phase edit: its `syncFastLfo` alone) due in the round robin, inside the 12 a step and counted in `ENGINE_BUDGET`. Only a hand edit goes at once, uncapped.
- **An engine-run LFO's commands**: `setFastLfo(n - 1, voice - 1, destination, shape - 1, rate', depth' / 100, 2 × offset / 100)` at a start, a new voice, destination or shape, and a hand edit; then `syncFastLfo(n - 1, phase(n))` after a start, a shape, mode, division or phase change, every bar (`LFO.bar_beats`, 4) for a clocked LFO and at once when the beats fall (a transport start); `stopFastLfo(n - 1)` when it is turned off, its depth goes to 0 or its destination stops being fast. Its modulated rate is resent past `LFO.engine_rate_threshold` (0.5 %) and its depth past 1/1000, through the round robin. Never more than one node per LFO: a running node is moved or replaced by `setFastLfo`, never started again.
- **Every round-robin send of an engine LFO counts against the send budget**: it is `S.lib.engine_sync.send_engine_value` of the key `lfo<n> engine` (`setFastLfo`) or `lfo<n> sync` (`syncFastLfo`), whose engine senders (registered at include time) read the LFO's settings or phase when they deliver, so a send that waited for the next window carries the newest, and send nothing once the LFO's node has gone (stopped, off, depth 0 or a Lua destination), so a waiting send never starts one again.
- **A clocked engine LFO's rate reads `S.lib.params_setup.beat_seconds_now()`**, and a change of its base rate (its division at the tempo) past `LFO.engine_rate_threshold` goes out in the step that sees it, ahead of the round robin and not counted in `sends_per_step` (at most one send per LFO), so a tempo change (the param, Link, MIDI clock) reaches every clocked engine LFO within one step however full the round robin is.
- **A modulation input reads a lower-numbered LFO only** (`strata_lfo<n>_rate_mod` and `_depth_mod` offer none, L1 .. L(n-1)), so the six evaluate in index order with no loop. A source that is off reads 0.
- Every resolved destination is a control param, and every label, with `~` when it is fast, fits the LFO page's right column (49 px). A global destination's param (`S.register_lfo_global_destination`) is checked at the clock's start step, once every params record has run: one that is not a control param raises, naming its label.
- `S.lfo_last_dest`/`S.lfo_scaled` are declared in `lib/engine_sync.lua`, included before `lib/lfos.lua`, because param actions read them; `with_lfo_offsets` sums them for `n = 1..NUM_LFOS`.
- Destination indices are stored in PSETs and scenes (`strata_lfo<n>_dest`), so the 68 built-in destinations never move. Registered destinations (`S.registry.lfo_destinations`) go after all of them, in registration order: a per-voice record by voice 1-7, a global one as one destination, so a later registration only appends. 3.4's `v<i> amp` is registered from `lib/voice_mix.lua` after `rsend` (97-103), so the macros' global entries follow from 104. The list is built at init (`add_lfo_params`), never at include time.
- The LFOs' scene fields are `S.lib.lfos.SCENE_FIELDS`, which `lib/scenes.lua` appends to `S.SCENE_GLOBAL_PARAMS` after its built-in globals, the records themselves: a change to an LFO's scene fields is made here, never in `lib/scenes.lua`, and needs a scene migration. `S.lib.lfos.transition_stops(n, scene_data)` is what a fade asks of an LFO (#408).
- 3.3's settings are imported, never lost: the scene migration (`before_version` 6) converts and drops the library's `lfo_*` fields of LFOs 1-3, filling only what is missing (it runs again on a scene saved while the format is still 5); the PSET hook converts them only when the file has `lfo_shape_1` and no `strata_lfo1_shape`, sets every LFO param such a PSET cannot hold to its default, and passes the read's `silent` on to every set.
- **A param set without its action** (a silent PSET read) converges at the next step: an LFO found off, or at depth 0, lets its Lua destination go (`restore_lfo_destination`) and its engine LFO stop; a destination that changed gives the old one back; a running engine LFO's rate, depth or offset that moved is sent in the round robin (the step compares each with what the engine has: the rate past `LFO.engine_rate_threshold`, the depth and the offset past 1/1000), and a phase param other than the one the engine was last synced to (`phase_seen`) syncs it there (#634).
- **A restart syncs**: the on action run on a running LFO (a bang, #251) restarts its phase at the phase param and syncs an engine LFO's node to it, without replacing the node.
- No step raises (#517): each LFO's step, each `on_step` hook and each send run through `S.lib.ui_frame.contained_call`, which prints `strata: LFO <n> step failed:` (or `LFO step hook`, `LFO send`) with the traceback, once per distinct message, and the clock and the other LFOs go on.
- The page randomize (#557) sets `strata_lfo<n>_shape`, `_rate`, `_division` and `_phase`, so their actions call `note_param_edit` (an edit of a held param ends the randomize undo). A new randomized LFO param needs the same call.

## Owns

`lib/lfos.lua` (`S.lib.lfos`):
- `S.LFO_DESTINATIONS`, `S.selected_lfo`, `S.lfo_clock`;
- the globals `lfo_destination_id`, `restore_lfo_destination`, `add_lfo_params`;
- the tunables `LFO` (`S.lib.lfos.LFO`) and `FAST_DESTINATIONS`; the readers `param_id(n, field)`, `fast_destination(param_id)`, `destination(n)`, `label(n)`, `is_on(n)`, `is_clocked(n)`, `is_engine_run(n)`, `engine_playing(n)` (on, on a fast destination, at a depth above 0: what MAIN's `~` reads, package 2a), `window(selected)`, `phase(n)`, `value(n)`, `has_stepped(n)`, `base_rate(n)`, `effective_rate(n)`, `effective_depth(n)`, `capped(n)`, `describe(n)`, `shape_u(shape, phase)`; `offset_for(param_id, m)`, `m_for(param_id, base, value)`; the queue `mark_due(key, send)` and `on_step(fn)`; `direct_destination(param_id)`; the engine senders `lfo<n> engine` and `lfo<n> sync`;
- `SCENE_FIELDS`, `transition_stops`, the scene migration `lfos` and the PSET hook `lfos`;
- the modulation sources `lfo1`..`lfo6`;
- the start step `lfo_clock`, the cleanup step `lfos` and the invariant `lfo clock`.

Elsewhere:
- The LFO page is `lib/pages/lfo.lua` (`docs/notes/lua/pages/lfo.md`), the arc's LFO rings `lib/arc/lfo.lua` (`docs/notes/lua/arc-pages.md`).
- `forget_arc_lfo_period_ticks` is in `lib/arc/core.lua`; the mode action calls it for the selected LFO.
- The five fast destinations' engine side is the modulation area (`docs/notes/engine/modulation.md`).
- The grid has no LFO controls.

Six LFOs (`NUM_LFOS`, the engine's `numFastLfos`). They are not the per-voice drift (`drift_update`, `docs/notes/lua/mutation.md`). norns' `lua/lib/lfo.lua` is no longer used (3.4, design Question 1).

## Params

`add_lfo_params()`, called from `init` after the FX group (the "lfos" `S.registry.params` record), builds the destination labels and adds one group per LFO, `strata_lfo_<n>` ("LFO n", `LFO.group_size` 13 params; groups cannot nest):

| Param | Kind | Default |
|---|---|---|
| `strata_lfo<n>` | binary toggle (on) | 0 |
| `strata_lfo<n>_dest` | option, the destination list | 1 (none) |
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

`S.LFO_DESTINATIONS` is the ordered `strata_lfo<n>_dest` option list of `{label, resolve, group, fast}`:
- `none`, `density`, `drift`, `filt freq`, `filt res`, `filt mix`, `dly time`, `dly fdbk`, `dly mix`, `rev mix`, `rev size`, `rev damp`;
- then per voice: `v<i> main` (`main_param_id(i)`, resolved on every step so it follows the voice's source), `v<i> size`, `dens`, `pitch`, `spread`, `pos`, `rate`, `scan`;
- 12 + 8 per voice = 68 entries (`S.lib.lfos.BUILT_IN_DESTINATIONS`);
- then, built at init by `add_lfo_params` (`lfo_destination_labels`), the registered ones, in registration order: for each `S.register_lfo_destination(label, suffix)`, `v1 <label>` ... `v7 <label>`; for each global record (`S.register_lfo_global_destination(label, param_id)`), one destination. A label that repeats one is an error naming the register function.
- 3.4's list: 69-75 `v<i> hist`, 76-82 `vfilt`, 83-89 `dsend`, 90-96 `rsend`, 97-103 `amp`, then the globals (`macro 1` .. `macro 16`, 104-119, from package 1e).
- `group` is what ALT+E3 jumps by (#511, #580): `none`, `global`, `v<i>`, `registered <k>` per per-voice record and `registered globals` for every global one.
- `fast` (`{voice, destination}`) marks an entry whose fixed param is fast: `v<i> size`, `pitch`, `pos`, `vfilt` and `amp`. `is_engine_run(n)` is LFO n's entry having it, whether or not the LFO is on: a reader that means "moves the voice now" reads `engine_playing(n)` (on, `is_engine_run`, depth above 0: the same answer the engine sends follow), so MAIN's `~` (design §2.6, while the LFO is on; package 2a) is `engine_playing(n)` for an LFO on the selected voice.

## The clock and a step

Each step (`step_all`), every 1/48 s:
- each LFO in index order (`step_lfo`): off, its value is 0. On: a free LFO's position advances by the rate it played since the last step times the time since (`util.time()`, so a late wake-up does not slow it); a clocked LFO's phase is `(beats / period + clocked_offset + phase)` mod 1, with `clocked_offset` integrating only what rate modulation adds, so an unmodulated clocked LFO is exact against the clock. A wrap draws a random shape's next value. Then its value (2u - 1), rate' and depth' (`evaluate`), and its destination: the engine's settings (`reconcile_engine`), or a Lua send (`step_lua`);
- the direct destinations the LFOs moved (a macro's), each handed over once, contained;
- the `on_step` hooks (the macros', `docs/notes/lua/macros.md`, the matrix's, then the note module's expression flush, registered at its start step so it runs after every hook registered at include time, `docs/notes/lua/notes.md`), each contained;
- the drain: at most 12 of the due keys that reach the engine, in the round robin, each inside `deferrable` (a key that reaches none runs in its turn without a slot, #644).

`phase(n)` is computed when read: a free LFO's from its last step plus the time since at the rate it plays, a clocked one's from `clock.get_beats()`, so the page's dot is smooth. `value(n)` is the last step's (and, at the turn-on, the start's).

## Shapes and modulation

- u(φ): sine `(sin 2πφ + 1) / 2`, tri `2φ` then `2 - 2φ`, square 1 then 0, up φ, down `1 - φ`; s&h holds the cycle's draw; smooth runs from the last draw to this one; drunk the same, each draw the last plus up to ±`LFO.drunk_step` (0.2), reflected into 0..1. A turn-on draws afresh (drunk from 0.5).
- Lua's offset: `m = value × depth' / 100 + 2 × offset / 100` half ranges, sent as `stored + m × half the range`, clamped by `with_lfo_offsets` once with every other LFO's and extra offset on the param.
- `rate' = clamp(rate × 4 ^ (amount × s), 0.003 Hz, ceiling)` (the run's ceiling: 10 Hz in Lua, 50 in the engine); clocked, the division's rate at `beat_seconds_now()` times the same factor. `depth' = clamp(depth × (1 + amount × s), 0, 100)`. s is the source's `value`.
- `offset_for(param_id, m)` is `m × half the param's range` (a Lua destination's, as `with_lfo_offsets` adds it); `m_for(param_id, base, value)` inverts design §3.3's laws: pitch `/1.875`, position `/0.5`, size `/0.245`, cutoff `log(value / base) / log(31.62)`, amp `value / base - 1` (0 at base 0); any other param by half its range.

## Restores

`restore_lfo_destination(n)`: clears `S.lfo_last_dest[n]`/`S.lfo_scaled[n]` and sends `send_param_to_engine(id, params:get(id))` (the stored value plus any other offset on it); a direct destination's sender gets that value itself, at once. Called by the on/off action (off), the depth action (0), the destination action, a step whose `main` destination re-resolved or turned fast, and cleanup.

## Scenes

- `SCENE_FIELDS` per LFO, in recall order: shape, mode, division, rate, depth, offset, phase, rate_mod, rate_mod_amt, depth_mod, depth_mod_amt, dest, then the state. Rate, depth and offset are continuous (`lfo = n`; the depth's `stop_target` 0); the rest switch at a transition's end. Every control field and the state carry `range` (the param's), which `validate_scene` checks; option fields are checked as option indices. Each default is its param's.
- `transition_stops(n, scene_data)`: LFO n runs now and the scene has it off.
- The migration `lfos` (`before_version` 6): for LFOs 1-3, the library's `lfo_shape_<n>` (sine, tri, square, random, up, down → 1, 2, 3, 6, 4, 5), `lfo_mode_<n>` (1 clocked, 2 free → 2, 1), `lfo_clocked_<n>` (the same index), `lfo_free_<n>` (a period: `rate = 1 / period`), `lfo_depth_<n>`, `lfo_offset_<n>` and `lfo_<n>` (1 off, 2 on → 0, 1); a random shape plays at twice the rate (rate doubled, the division with half the period, nearest in octaves). Then the old fields are dropped. A scene with no depth for LFO 1-3 gets 0 (3.3's migration default); `migrate_scene` fills the rest with the defaults (LFOs 4-6 off). An old value outside its options converts to 0, which `validate_scene` rejects.

## PSETs

The PSET hook `lfos` (`read(path_base, number, pset_path, silent)`): when the file has `lfo_shape_1` and no `strata_lfo1_shape`, every LFO param such a PSET cannot hold goes to its default (LFO 1-3's rate and depth inputs and amounts; all of LFOs 4-6, off last), and LFOs 1-3 are set from the library's lines with the scene migration's conversions (plus `lfo_phase_<n>`), the state last, so the PSET plays as it did in 3.3; `imported 3.3 LFO settings` is printed. Every set passes the read's `silent` on (the PSET actions hand it to the hooks, `docs/notes/lua/params.md`); after a silent read the next step brings the engine and the Lua destinations to the params. `strata_lfo<n>_dest` has already loaded. The PSET is not rewritten.

## Sources

`lfo1`..`lfo6` (`S.register_mod_source`): name `L<n>`, section `lfos`, range -1..1, `value` = `value(n)`, `describe` = `describe(n)` (`v3 pitch~ 25% <L2`), `row`: E3 the depth (`delta_with_detent`), fine E3, K3 `S.lib.pages_lfo.show_lfo(n)`, hints `K3:lfo E3:depth`.

## Cleanup

Step 120: `stop_clock()` cancels the clock, nothing waits in the round robin, and every Lua destination is restored as in 3.3. norns frees the engine before `cleanup()` (#461), and an engine LFO's node with it, so no `stopFastLfo` is sent, and no test asserts an engine send from the step.

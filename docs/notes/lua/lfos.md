## Must not break

- LFOs modulate around the stored value and never `params:set` their destination. A Lua-run LFO sends `with_lfo_offsets(id, params:get(id))` through `S.lib.engine_sync.send_engine_value`, with its offset `m` in `S.lfo_scaled[n]` and its param in `S.lfo_last_dest[n]`; an engine-run LFO sets neither.
- **The destination decides where an LFO runs** (design 3.4 Question 2): a destination entry whose fixed param is one of the five fast ones (`v<i>_grain_pitch`, `buf_pos`, `grain_size`, `filter_freq`, `amp`: the entry's `fast`) runs in the engine, at any rate; every other one, `v<i> main` included (it can resolve to any param), runs in Lua, at most `LFO.lua_max_hz` (10 Hz).
- **One clock** (`S.lfo_clock`) steps all six, every `1 / LFO.step_hz` s (48 Hz), in index order, from the start step `lfo_clock` (125) to the cleanup step `lfos` (120); the `lfo clock` invariant checks it, its coroutine included (`clock.threads`: a clock canceled or ended behind the module's back breaks it, as the scene sequencer's does). Only `S.lib.lfos.stop_clock()` (cleanup's, and a test's that wants a quiet scheduler) stops it. Its sleep is outside every deferrable write: each send of a step goes inside `S.lib.engine_sync.deferrable` (the drain), and nothing inside yields.
- **At most `LFO.sends_per_step` (12) sends a step**, the LFOs' and the matrix's together, in one round robin (`mark_due(key, send)`): keys in the order first marked, a later mark of a key replacing its send, the next step starting where the last stopped. A Lua destination's key is its param id, so two LFOs (or an LFO and the matrix) on one param send once.
- **A due key that reaches no engine takes no slot** (#644): the drain asks `S.lib.engine_sync.reaches_engine(key)` before it counts a key against the 12 (`docs/notes/lua/engine-sync.md`, the send budget's "What counts": a stopped voice's param, a key with no engine sender, the master density with no voice running); such a key still runs in its turn, inside `deferrable`, so its value is recorded and the LFO's compare (`expected_value`) reads what it read before. A stopped voice's moving LFO never takes a running voice's slot, and the voice's start sends its stored values, the LFO's next step its modulated one (the start forgets what was recorded).
- **A direct destination takes no slot and no budget message** (#636): a param whose engine sender reaches no engine registers with `direct_destination(param_id)` (the macros', `docs/notes/lua/macros.md`). An LFO on it runs `S.engine_senders[id]` itself with `with_lfo_offsets(id, params:get(id))`, once a step after the six LFOs and before the hooks (every LFO on it stepped), when that moved by `LFO.send_threshold` along its range from the value it last handed over, and at once at a restore; never through `mark_due` or `send_engine_value`.
- **A Lua send is skipped under `LFO.send_threshold`** (1/1000) of the destination's range, measured along its warp (`destination_position`: an exponential range in octaves, #406) with a step-0 copy of its spec, never the param's own spec. Restores are always sent, at once. The compare is with `S.lib.engine_sync.expected_value(id)`, the value the engine has or will have (a value waiting in the send budget counts, #591); a nil expected value always sends, so a voice sync's dropped value is healed.
- **A control param's action never calls the engine** (AGENTS.md): the rate, depth, offset, phase and mod amounts mark their LFO `edited` (and the phase `sync_due`), and the next step sends them; the on/off, destination, shape, mode, division and mod source actions reconcile the engine at once, except while a scene applies (below).
- **A scene's LFO settings reach the engine together** (0e's review): while a scene applies (`S.scene_recall_in_progress`: an instant recall, a fade's end, morph's discrete entries), the shape, mode, division and mod source actions only mark the LFO `edited` (and `sync_due`) without reconciling, and the destination block sets its key silently; the next step sends the LFO once (`setFastLfo`, then `syncFastLfo` only when a sync is due: the shape changed, or a mode, division or phase change asked for one) with the scene's destination, shape, mode or division, rate and depth all in place, never a mix of old and new. The on/off state, applied last of an LFO's fields, still starts or stops it at once, with its settings in place. A plain edit outside a scene reaches the engine at once, as before. This also ends 3.6's fault where a recalled shape change sent the old rate and depth for one step.
- **An edit by a deferrable source goes through the round robin and the send budget** (#633): a control param set while `S.deferrable_write` is set (a macro apply, morph, gesture playback, a fade) marks its LFO `deferred` instead of `edited` (a phase edit marks nothing: its param moved from `phase_seen`, below), and the next step marks the LFO's `setFastLfo` (a phase edit: its `syncFastLfo` alone) due in the round robin, inside the 12 a step and counted in `ENGINE_BUDGET`. Only a hand edit goes at once, uncapped.
- **An engine-run LFO's commands**: `setFastLfo(n - 1, voice - 1, destination, shape - 1, rate', depth' / 100, 2 × offset / 100)` at a start, a new voice, destination or shape, and a hand edit; then `syncFastLfo(n - 1, phase(n))` after a start, a shape, mode, division or phase change, every bar (`LFO.bar_beats`, 4) for a clocked LFO and at once when the beats fall (a transport start); `stopFastLfo(n - 1)` when it is turned off, its depth goes to 0 or its destination stops being fast. Its modulated rate is resent past `LFO.engine_rate_threshold` (0.5 %) and its depth past 1/1000, through the round robin. Never more than one node per LFO: a running node is moved or replaced by `setFastLfo`, never started again.
- **Every round-robin send of an engine LFO counts against the send budget**: it is `S.lib.engine_sync.send_engine_value` of the key `lfo<n> engine` (`setFastLfo`) or `lfo<n> sync` (`syncFastLfo`), whose engine senders (registered at include time) read the LFO's settings or phase when they deliver, so a send that waited for the next window carries the newest, and send nothing once the LFO's node has gone (stopped, off, depth 0 or a Lua destination), so a waiting send never starts one again.
- **A clocked engine LFO's rate reads `S.lib.params_setup.beat_seconds_now()`**, and a change of its base rate (its division at the tempo) past `LFO.engine_rate_threshold` goes out in the step that sees it, ahead of the round robin and not counted in `sends_per_step` (at most one send per LFO), so a tempo change (the param, Link, MIDI clock) reaches every clocked engine LFO within one step however full the round robin is.
- **A modulation input reads a lower-numbered LFO only** (`strata_lfo<n>_rate_mod` and `_depth_mod` offer none, L1 .. L(n-1)), so the six evaluate in index order with no loop. A source that is off reads 0.
- Every resolved destination is a control param, and every label, with `~` when it is fast, fits the LFO page's right column (49 px). A global destination's param (`S.register_lfo_global_destination`) is checked at the clock's start step, once every params record has run: one that is not a control param raises, naming its label.
- `S.lfo_last_dest`/`S.lfo_scaled` are declared in `lib/engine_sync.lua`, included before `lib/lfos.lua`, because param actions read them; `with_lfo_offsets` sums them for `n = 1..NUM_LFOS`.
- **A destination is stored by its key, never its index** (3.7, design decision 24): `strata_lfo<n>_dest` is an `S.lib.io_keyed` option, so a PSET keeps the hidden `strata_lfo<n>_dest_key` and a scene the block of that name. A key is the param id the destination moves, `v<i>_main` for a voice's main entry or `none`, and no two entries share one (a second destination of one param is an error naming the register function). A key the list lacks reads as none, with one console line (`strata: LFO <n>'s destination <key> is not in this version: none`), and is kept, as `S.lib.io_keyed` keeps it. An index from before 3.7 (a PSET's `strata_lfo<n>_dest` line, a scene's `strata_lfo<n>_dest` field) is not converted: it reads as none, silently. **The one transient** (0e's review, accepted by ruling: old formats are no longer converted, and the param keeps its id): norns' `ParamSet:read` sets a param from its line whatever its save flag, so a 3.6 PSET's `strata_lfo<n>_dest: N` line runs the option's action with the new list's entry N. An LFO the PSET has on, whose entry N is fast, starts or moves its engine LFO there until `S.lib.io_keyed`'s hook, after the read, sets none and stops it: the rest of that read plus the node's 20 ms release, once per old PSET, engine destinations only (a Lua destination waits for a step, by which time it is none). A PSET written by 3.7 has no such line.
- **The list is ordered by voice**: none, the globals, each voice's destinations together, the macros. A registered per-voice destination (`S.registry.lfo_destinations`) joins its voice's group after the built-in ones, in registration order; a registered global one joins the globals, unless its param is a macro's (`macro_<m>`), which make the last group. Indices move whenever a destination is added, so nothing but the option itself may hold one. The full list is built at init (`add_lfo_params`); include time builds the built-in ones only, into the same table.
- The LFOs' scene fields are `S.lib.lfos.SCENE_FIELDS`, which `lib/scenes.lua` appends to `S.SCENE_GLOBAL_PARAMS` after its built-in globals, the records themselves: a change to an LFO's scene fields is made here, never in `lib/scenes.lua`, and a new field needs its `default`. `S.lib.lfos.transition_stops(n, scene_data)` is what a fade asks of an LFO (#408).
- **A param set without its action** (a silent PSET read) converges at the next step: an LFO found off, or at depth 0, lets its Lua destination go (`restore_lfo_destination`) and its engine LFO stop; a destination that changed gives the old one back; a running engine LFO's rate, depth or offset that moved is sent in the round robin (the step compares each with what the engine has: the rate past `LFO.engine_rate_threshold`, the depth and the offset past 1/1000), and a phase param other than the one the engine was last synced to (`phase_seen`) syncs it there (#634).
- **A restart syncs**: the on action run on a running LFO (a bang, #251) restarts its phase at the phase param and syncs an engine LFO's node to it, without replacing the node.
- No step raises (#517): each LFO's step, each `on_step` hook and each send run through `S.lib.ui_frame.contained_call`, which prints `strata: LFO <n> step failed:` (or `LFO step hook`, `LFO send`) with the traceback, once per distinct message, and the clock and the other LFOs go on.
- The page randomize (#557) sets `strata_lfo<n>_shape`, `_rate`, `_division` and `_phase`, so their actions call `note_param_edit` (an edit of a held param ends the randomize undo). A new randomized LFO param needs the same call.

## Owns

`lib/lfos.lua` (`S.lib.lfos`):
- `S.LFO_DESTINATIONS`, `S.selected_lfo`, `S.lfo_clock`;
- the globals `lfo_destination_id`, `restore_lfo_destination`, `add_lfo_params`;
- the tunables `LFO` (`S.lib.lfos.LFO`) and `FAST_DESTINATIONS`; the readers `param_id(n, field)`, `fast_destination(param_id)`, `destination(n)`, `destination_groups()`, `label(n)`, `is_on(n)`, `is_clocked(n)`, `is_engine_run(n)`, `engine_playing(n)` (on, on a fast destination, at a depth above 0: what MAIN's `~` reads, package 2a), `window(selected)`, `phase(n)`, `value(n)`, `has_stepped(n)`, `base_rate(n)`, `effective_rate(n)`, `effective_depth(n)`, `capped(n)`, `describe(n)`, `shape_u(shape, phase)`; `offset_for(param_id, m)`, `m_for(param_id, base, value)`; the queue `mark_due(key, send)` and `on_step(fn)`; `direct_destination(param_id)`; the engine senders `lfo<n> engine` and `lfo<n> sync`;
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

`add_lfo_params()`, called from `init` after the FX group (the "lfos" `S.registry.params` record), builds the destination labels and adds one group per LFO, `strata_lfo_<n>` ("LFO n", `LFO.group_size` 14 params, the destination's hidden key included; groups cannot nest):

| Param | Kind | Default |
|---|---|---|
| `strata_lfo<n>` | binary toggle (on) | 0 |
| `strata_lfo<n>_dest` | option, the destination list (`S.lib.io_keyed`: not saved; its key is) | 1 (none) |
| `strata_lfo<n>_dest_key` | hidden text, the destination's key | `none` |
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

`S.LFO_DESTINATIONS` is the ordered `strata_lfo<n>_dest` option list of `{label, key, resolve, group, fast}`, by voice (3.7):
- `none`;
- the globals (group `global`): `density`, `drift`, `filt freq`, `filt res`, `filt mix`, `dly time`, `dly fdbk`, `dly mix`, `rev mix`, `rev size`, `rev damp`, then any registered global destination (`S.register_lfo_global_destination(label, param_id, group)`) whose group is `global` (the default);
- per voice (group `voice <i>`): `v<i> main` (key `v<i>_main`, `main_param_id(i)`, resolved on every step so it follows the voice's source), `v<i> size`, `dens`, `pitch`, `spread`, `pos`, `rate`, `scan`, then each `S.register_lfo_destination(label, suffix)` record's `v<i> <label>` in registration order: today `hist` (`lib/history.lua`), `vfilt`, `dsend`, `rsend`, `amp` (`lib/voice_mix.lua`), 13 a voice;
- the macros (group `macros`): `macro 1` .. `macro 16`, registered globals whose registration names the group `macros` (#729: the group is the registration's, never read from the param's name);
- 3.7's list: 1 none, 2-12 the globals, voice i at 13 + 13 (i - 1) to 25 + 13 (i - 1), the macros 104-119. A label that repeats one is an error naming the register function.
- `S.lib.lfos.destination_groups()` is `{{name, first, last}, ...}` in list order, none aside: `global`, `voice 1` .. `voice 7`, `macros`. ALT+E3 jumps by it (#511, #580; `docs/notes/lua/pages/lfo.md`), MOD's routing view by each entry's `group`, and the matrix's destinations (`S.lib.matrix.destination_ids()`) and the macros' targets follow the list's order.
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

- `SCENE_FIELDS` per LFO, in recall order: shape, mode, division, rate, depth, offset, phase, rate_mod, rate_mod_amt, depth_mod, depth_mod_amt, then the state. Rate, depth and offset are continuous (`lfo = n`; the depth's `stop_target` 0); the rest switch at a transition's end. Every control field and the state carry `range` (the param's), which `validate_scene` checks; option fields are checked as option indices. Each default is its param's.
- The destination is a scene block per LFO (3.7), `strata_lfo<n>_dest_key` (`S.register_scene_block`, discrete: it switches at a transition's end): its key, captured from the hidden text param. `apply` sets the key and its option **silently** (a key this build lacks: option 1, with its console line printed there): blocks apply before the globals, and an action would reach the engine with the LFO's old rate and depth for a step (0e's review). The next step converges as after a silent PSET read: a changed destination gives the old one back and sends the new one with every setting the recall put in place. A fade applies it at its end with the other discrete entries. `validate` takes a string `S.lib.io_keyed.refuses` passes; a scene without the block (saved before 3.7) gets `none`.
- `transition_stops(n, scene_data)`: LFO n runs now and the scene has it off.

## PSETs

No PSET hook of the module's own: a PSET's LFO lines are read as norns reads any param's, and the destination's key through `S.lib.io_keyed`'s hook (`docs/notes/lua/io/keyed.md`). 3.7 deleted 3.3's LFO library import, from scenes and PSETs alike (design decision 21).

## Sources

`lfo1`..`lfo6` (`S.register_mod_source`): name `L<n>`, section `lfos`, range -1..1, `value` = `value(n)`, `describe` = `describe(n)` (`v3 pitch~ 25% <L2`), `row`: E3 the depth (`delta_with_detent`), fine E3, K3 `S.lib.pages_lfo.show_lfo(n)`, hints `K3:lfo E3:depth`.

## Cleanup

Step 120: `stop_clock()` cancels the clock, nothing waits in the round robin, and every Lua destination is restored as in 3.3. norns frees the engine before `cleanup()` (#461), and an engine LFO's node with it, so no `stopFastLfo` is sent, and no test asserts an engine send from the step.

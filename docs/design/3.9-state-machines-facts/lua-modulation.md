# Facts: the state machines of modulation (Lua)

Gathered on 2026-11-21 from `main` at a1c8e8b4 (3.8.0) by a read-only audit of this area, for `docs/design/3.9-state-machines-design.md`. Line numbers are that commit's. In the tables, a recommendation is one of: (a) leave the code and add a state table to the notes; (b) one named state value with one transition function; (c) a table-driven test of the transitions, code unchanged; (d) nothing. The design weighs them again and does not always follow them. A probe is a scratch unit test the audit ran against the harness: the seven probe files are in `probes.md`.

All paths are from the repository's root. The area's 259 unit tests pass.

## Summary

| # | Machine | Owner | States | Transition bugs | Rec. | Confidence |
|---|---|---|---|---|---|---|
| 1 | LFO play place and engine reconcile | `lib/lfos.lua` | 5 places, 5 flags | about 9: #251, #409, #633, #634, #636, `7f0d946c`, `b11d2167`, two of `70031efa`'s | (a)+(c) | high |
| 2 | Matrix destination holding | `lib/matrix.lua` | 3 Lua, 2 fast | 5: #647, `04289436`, #760, #741, `e1b1426a` | (c) with 1, (a) | medium-high |
| 3 | Scene-apply batching (the flag read at `lib/lfos.lua:860`) | lfos and scenes | 2 | 2: `7f0d946c`, `b11d2167` | (a), in 1's walk | medium |
| 4 | 48 Hz clock and step pipeline | `lib/lfos.lua` | 2, plus hook order | 2: `70031efa`, #517 | (a), small (c) | medium |
| 5 | Round-robin queue | `lib/lfos.lua` | 3 per key | 3: #636, #644, `70031efa` | (a) | medium |
| 6 | Matrix learn | `lib/matrix.lua` | 2, plus retired clocks | 3: #595, #626, `df1b6fb2` | (d) | high |
| 7 | Envelope route | `lib/envelopes.lua` | 3 | 1: `4a320aed` | (d), copy it | high |
| 8 | Envelope model | `lib/envelopes.lua` | 3, plus loop flag | 1: `4a320aed` | (a) | medium |
| 9 | Routing "plays" status | matrix, MOD page | 7 derived | 0 | (a) | low |
| 10 | Scatter | `lib/scatter.lua` | none in Lua | 0 in Lua | (d), copy it | high |
| 11 | MOD target and routing views, LFO page | `lib/pages/` | cursors | 0 | (d) | high |

The five things most worth knowing:

1. **These are reconcilers, so a stored state value would be wrong here.** Each 48 Hz step derives what should play from params and compares it with what the engine was handed. The worst bugs (#591, #647) came from a second record of what was sent. The fitting tool is a seeded random walk that asserts convergence after a step, as `test/notes_model.lua` does for notes.
2. **Every bug was a wrong transition or send path between legal states; none was an illegal state.** The area has two relevant invariants, no States table in any of its eight notes files, and no model coverage.
3. **One notes rule is false.** `docs/notes/lua/lfos.md:13` says a fade's LFO edits go through the round robin and the budget. I ran it: a 2 s fade ran the depth action 20 times, none inside `deferrable`, and sent 20 `setFastLfo`, none through the budgeted key.
4. **Lua's beliefs about engine nodes are open loop.** No poll reports back, voice events never reset them, and only a script load rebuilds them. A depth of 0 means both "amount 0" and "no node".
5. **Four UX gaps, two confirmed by running.** MAIN's `~` omits an LFO on a voice's Lua destination; MOD's L rows show no on/off; a kept unknown destination reads `none`; a learn armed by mistake rewires a routing with no undo.

## Full report

### Shape of the area

Nearly every machine here is level-triggered:

- A 48 Hz step works out what should play from params and the home routings.
- It compares that with a record of what the engine was handed.
- It sends the difference.

Param actions add shortcuts for immediacy (`turned`, `settings_changed`, `release_direct`, the `edited` flags). The bug history sits in those shortcuts and in duplicated records.

Two constraints rule out a naive explicit machine:

- State can change with no event: a silent PSET read, a `v<i>_main` that re-resolves when a voice's source switches, a deferrable writer. The step must re-derive anyway, so a stored enum would be a cache that goes stale.
- The matrix adds offsets and never sets a param, and none of this state may be a param, scene or PSET field.

The 200-local limit is no obstacle: by a rough count of top-level `local` lines, `lib/lfos.lua` has 58, `lib/matrix.lua` 61 and `lib/pages/mod.lua` 111.

### 1. LFO play place and engine reconcile

**Owner.** `lib/lfos.lua`.
- State: `state[n]` (263-268), `direct` (437), and the matrix's `held` (`lib/matrix.lua:250`).
- Transitions: `turned` (827-848), `settings_changed` (856-863), `home_changed` (869-872), `edited` (880-888), `reconcile_engine` (643-672), `step_direct` (565-572), `release_direct` (450-455), `step_lfo` (695-737), cleanup (810-817).
- Late-delivery guards: `has_node` and the keyed senders (608-623).

**States.** Five places, derived from the on param, the depth param and the home entry's kind:

| Place | Condition | Encoded by |
|---|---|---|
| OFF | on = 0 | nothing held |
| IDLE | on, depth 0 or home none or unknown | nothing held |
| ENGINE | on, depth > 0, fast home | `state[n].engine` is a table |
| DIRECT | on, depth > 0, macro home | `direct.held[n]` is the id |
| MATRIX | on, depth > 0, any other home | `held.lua[id]`, or `held.fast[id]` for a `v<i>_main` that resolves to a fast param |

Five flags sit on top: `edited`, `deferred`, `sync_due`, `phase_seen`, `bar`. The modes are free and clocked only (`lib/lfos.lua:45`); "sync" is a command, not a mode.

Representable but unintended:
- `state[n].engine` set while not `engine_playing(n)`. This is a real transient of at most one step after a recall, a silent read or a depth edit.
- `engine` and `direct.held` both set. I traced every home change through `home_changed`, which releases first, so I believe it cannot happen (inferred).
- `edited` or `deferred` true on an off or Lua-run LFO. The non-engine branch never clears them (733-735). Harmless, since the first engine send clears them (inferred).

**Events.**

| Event | Path |
|---|---|
| On action, including a bang | `turned`: phase reset, `sync_due`, reconcile at once (#251) |
| Off | `release_direct` at once, `stopFastLfo` at once; a Lua home is given back at the matrix's next step (ruling 17) |
| Depth to 0 | direct released at once; the engine node stops at the next step |
| Hand edit of a control | `edited`: next step, sent at once and uncounted |
| Deferrable edit | `deferred`: next step, round robin and budget (#633) |
| Shape, mode, division, mod source | reconcile at once, or only marked during a scene apply |
| Home change | `release_direct`, then as above |
| Silent set | converges at the next step (#634) |
| Bar boundary, beats fall | `sync_due` (726-729, 683-688) |
| Tempo change | resent in the step, ahead of the round robin (628-631) |

Outside writers: `set_home`, `tell_homes` and the `through_zero` switch (`lib/matrix.lua:648`, `556`, `841`), and any param writer.

Outside readers: `lib/pages/main.lua:141`, `lib/pages/lfo.lua:258`, `lib/macros.lua:264` and `288`, `lib/matrix.lua:384-387`, `lib/io/crow.lua:635`, `lib/io/midi_out.lua:899`.

**Guards.**
- No invariant covers the place; "lfo clock" covers only the clock.
- No States table. `docs/notes/lua/lfos.md` lines 5 to 16 and 23 are transition rules in prose.
- No model coverage.
- `test/unit/lfos_test.lua` has 60 tests, all by example. The recall cases at 973-1132 are the closest to a table.

**History.**
- Introduced in 3.4 (`94539240`), replacing norns' LFO library.
- #636 (`8520fde0`) added the direct hand-over.
- The groundwork before 3.8 (`85a7a2b1`) moved the destination into the matrix's slots 17 to 22 and deleted the LFO's own Lua send and restore state.
- The design chose this so the store, the sum and the scene block are the matrix's (`docs/design/3.8-groundwork-design.md:56`).

Bugs, all wrong transitions:
- #251: on to on had no restart.
- #409: a mode switch left the clocked offset.
- #633: a deferrable edit took the at-once path.
- #634: a silent edit took no path.
- #636: bookkeeping took slots.
- `7f0d946c` and `b11d2167`: a recall sent the old rate and depth for one step.
- `70031efa`: cleanup sent a stop to a freed engine, and a bang did not sync the node.

**What the user sees.**
- `~` on the destination label, by kind, shown even while the LFO is off.
- `max` on a capped rate.
- A hollow dot for a free engine-run LFO (`lib/pages/lfo.lua:257-258`).
- An `R` mark while the matrix routes it.

UX gaps:
- MAIN's `~` is not shown for a Lua-run LFO homed on a voice's Lua param, though an R routing to the same param shows it. `affects` covers slots 1 to 16 only (`lib/matrix.lua:222-228`). I ran it: an LFO on `v1_grain_density` held a 2.43 offset with `engine_modulated(1)` false, and R1 to the same param gave true.
- MOD's L rows show no on/off. `describe` gave `v1 dens 50%` for an off LFO, and source rows are never dimmed (`lib/pages/mod.lua:789-792`).
- A home key this build lacks shows `none`; only the console names it (ruling 19).
- A clocked engine-run LFO with a random shape draws a filled dot from Lua's draws, while the engine makes its own. An R routing from it plays Lua's sequence, not the home's (inferred from `docs/notes/lua/pages/lfo.md:28`).

**Recommendation: (a) and (c).**
- Add a place table and a cause-to-path table (at once, round robin, next step) to `docs/notes/lua/lfos.md`.
- Add a seeded random walk. Ops: on, off, depth, home, shape, mode, a silent set, a recall, a fade, a source switch, a macro on the depth. Then one step, then compare a model fed by `context.engine_calls` with the derived place.
- Optional: a pure `place(n)` accessor that stores nothing, to unify `is_engine_run`, `engine_playing`, `home_m ~= nil`, `owns` and `capped`.
- Not (b): a stored state is a second record.

Cost is one test module. The risk is false alarms on the documented one-step transients; the walk itself detects them. Blast radius is high, since every modulated sound passes through here.

### 2. Matrix destination holding

**Owner.** `lib/matrix.lua`: `held` (250), `update_lua` (405-419), `update_fast` (426-437), `read_routing` (368-376), `read_home` (383-390), `idle` (440-447), cleanup (867-875).

**States.**
- Per Lua param: not held, held (an offset), returning (one send as the sum reaches 0). Since #760 there is also "playing but exactly 0", which holds nothing.
- Per fast channel: untracked, or tracked while the sum or the channel's expected value is not 0.
- The engine-side value lives in the budget's record (`expected_value`), not here.

**Events.** Each step sums again from scratch. Outside inputs are `set_fast_extra` (the macros write and clear it, 490-505), `lib/delay_sync.lua`'s `time_unheard` (395-397), and a voice sync forgetting sent values.

**Guards.** No invariant, no States table, no model. There are 67 example tests, many of them transition cases.

**History, all wrong transitions.**
- #647 and `04289436`: the matrix's own record of what it handed disagreed with the budget's.
- #760: an exact-0 sum resent every step.
- #741: a synced delay's time resent 34 to 48 times a second.
- `e1b1426a`: fast sends bypassed the budget.

**What the user sees.** `~` on a fast destination; a dim row for an off or incomplete routing. Nothing shows that a routing's source LFO is off.

**Recommendation.** (c), in machine 1's walk: after a step, each channel's last `setFastOffset` equals `offset(id)`, and an idle step sends nothing. Plus (a), a three-row table. Blast radius medium.

### 3. Scene-apply batching

**The flag.** Its writer sets it around `apply_entries`' entry loop and clears it under `xpcall` (`lib/scenes.lua:566-584`). That covers an instant recall, a fade's end and morph's discrete crossing.

**What the read at `lib/lfos.lua:860` assumes** beyond "a recall is running":
- The rest of this LFO's settings arrive in the same synchronous run.
- The matrix block set the home before the globals.
- The on/off entry comes last (`lib/lfos.lua:986-997`), because `turned` is not gated and reconciles at once.
- An LFO step follows to flush the mark.

Morph's discrete-only apply breaks the first assumption for rate, depth and offset. That is harmless, since the step sends what is there (inferred). The read is a batching hint that depends on scene field order, not a scene-state fact.

**Guards.** The recall tests at `test/unit/lfos_test.lua:973-1132`; no invariant.

**Bugs.** `7f0d946c` and `b11d2167`, both wrong ordering.

**Recommendation.** (a): state the four assumptions in `docs/notes/lua/lfos.md`; put a recall op in the walk.

### 4. The 48 Hz clock and step pipeline

**Owner.** `lib/lfos.lua`: `clock_runs` and `S.lfo_clock` (765-789), `stop_clock` (770-776), `step_all` (743-761), `on_step` (420-424).

**States.** Running or stopped, with the "lfo clock" invariant (794-803). That part is explicit and well kept.

**The implicit part.** A step is four phases: the six LFOs, the direct hand-overs, the hooks, the drain. Seventeen modules register hooks. Their order is `strata.lua`'s include order (lines 71 to 124). The hooks are unnamed functions in a local list, not a registry. The notes state order relations that matter: macros before matrix, envelopes before matrix, random sequences before matrix, the notes flush last. I found no test that pins them.

**History.** `70031efa` made the invariant see a dead coroutine. #517 added containment.

**Recommendation.** (a): a pipeline table in the notes. A small (c): name the hooks so a test can assert the four relations. A wrong order costs one step of lag, so the blast radius is low to medium.

### 5. Round-robin queue

**Owner.** `lib/lfos.lua:387-417`.

**States per key.** Unknown, known and idle, or due with a send function. Keys are never removed. Their position holds two facts: membership and fairness order.

**Guards.** The cap and two-step tests (`test/unit/lfos_test.lua:224-321`). No invariant.

**The idiom worth copying.** A due send reads current state when it runs, so most marks never need withdrawing. Only the LFO's own keys are withdrawn (596, 648, 812).

**Bugs.** #636, #644, and the tempo-ahead rule of `70031efa`: all slot accounting.

**Recommendation.** (a). Also write down the key convention and consider a test for it: a keyed id holds a space and never starts `v<i>_`, or a voice sync would forget it (`lib/engine_sync.lua:454-465`). I found no test of this.

### 6. Matrix learn

**Owner.** `lib/matrix.lua`: `learning` and `learn_clock` (702-711), `cancel_learn` (713-727), `learn` (733-751), the touch hook (767-778).

**States.** Idle, or armed for routing k with a live clock, plus retired clocks. A token guards a late wake.

**Outside cancellers.** MOD's `close_view` and `move_routing` (`lib/pages/mod.lua:466-469`, `1152-1157`), and cleanup. A page change does not cancel it (ruling 80).

**Guards.** The "matrix learn" invariant (879-889); tests at `test/unit/matrix_test.lua:926` and `967`.

**Bugs.**
- #595: a page change canceled it, so it could not be finished without a grid.
- #626: a clock was canceled with its resume possibly posted.
- `df1b6fb2`: learn stayed armed for a routing no longer shown.

**What the user sees.** A header notice on every page (`lib/pages/mod.lua:1083-1090`).

UX gap: off MOD, only a touch or the 10 s timeout ends it. A touched destination param rewires the routing and edits the param, with no undo (`lib/matrix.lua:774-777`).

**Recommendation.** (d) here. The retire-don't-cancel code is hand-copied, and a shared one-shot timeout helper would make it explicit once, but that is cross-area work.

### 7. Envelope route

**Owner.** `lib/envelopes.lua`: `route_want` (184-196), the senders (234-251), `reconcile` (257-262), `mark_routes_of` (273-277).

**States per route.** The budget's record under `env route <k>`: nil (never sent), a settings table (has or will have), or `false` (a stop was handed on).

**Guards.** The module keeps no record of its own. The send compares when it runs (245-250). Tests at `test/unit/envelopes_test.lua:245-340` and `389`. No invariant, no table.

**Bugs.** One: `4a320aed` fixed handing the route's own reused table to the budget, so later compares always matched.

**Recommendation.** (d). This is the cleanest pattern in the area and worth copying: desired state from a pure function, the engine's state from one owner, a send that compares late. Include it in the walk.

### 8. Envelope model

**Owner.** `lib/envelopes.lua`: `hits` (110), the hit hook (132-135), `looping` and `loop_changed` (144-166).

**States per voice.** No hit, running, ended; the loop flag on top.

**Divergence from the engine.** Three documented cases (`docs/notes/lua/engine-sync.md:52`).

**Notes inconsistency.** `docs/notes/lua/envelopes.md:30` says Strata never reads a PSET silently. `docs/notes/lua/lfos.md:23` and `docs/notes/lua/scatter.md:6` handle silent reads.

**Bugs.** One: turning the loop off mid-cycle (`4a320aed`).

**What the user sees.** `~` before the times when a sub-50 ms envelope reaches a Lua destination.

**Recommendation.** (a): a small table, and reconcile the silent-read claims.

### 9. Routing "plays" status

Seven derived conditions: empty, incomplete, unknown part, off, depth 0, summed, engine-owned. There are three definitions:
- `playing` (`lib/matrix.lua:196-204`);
- MOD's `routing_complete` and `routing_plays` (`lib/pages/mod.lua:286-296`), which count depth 0 as playing and do not check that a main entry resolves;
- `owns` (`lib/envelopes.lua:202-206`).

No bugs. Recommendation: (a). A `status(k)` accessor would help only if a fourth reader appears.

### 10. Scatter

`lib/scatter.lua:63-66` sends the whole state in one message from every param, lock change and silent read. Lua keeps no state and no belief. It has no bugs on the Lua side; #610 was the engine's. Recommendation: (d), and copy the idea where a command is cheap.

### 11. MOD views and the LFO page

- The target and routing views are cursor fields under `change_view`. Row `kind` is a type tag, not a lifecycle.
- The LFO page has cursors only.
- The ring carries use two idioms: MOD compares a context key at use (`lib/arc/mod.lua:42-49`); the LFO page forgets explicitly (`lib/pages/lfo.lua:184-187`, `lib/lfos.lua:924`). The context key cannot be forgotten, so it is the one to copy.

Recommendation: (d).

### Pattern 1: clocks canceled while a resume may be posted

| Clock | Rule |
|---|---|
| `S.matrix_learn_clock` | retire rule (`lib/matrix.lua:706-727`), with an invariant |
| `S.lfo_clock` | canceled at cleanup (771-776), and at the start step if one already exists (781), which I believe is unreachable in a normal init (inferred) |
| `S.matrix_save_clock` | never canceled while running; a burst returns while it exists (`lib/side_files.lua:175`); canceled only in cleanup's `save_now` (185-191) |
| `S.engine_budget_clock` | never canceled (#654) |

Envelopes, scatter, mod sources and both pages have no clocks.

### Pattern 2: a field holding two facts

- A depth of 0 is both an amount and "no node". Consequences: a depth swept through 0 stops the node and restarts it with a resync; the fade's `stop_target` (`lib/lfos.lua:990`) and the home's ramp through 0 (`lib/matrix.lua:841`) rely on this.
- `state[n].engine` is both "a node exists" and "what was last sent".
- The route record's nil and `false` both mean no node.
- `S.engine_param_values["lfo<n> engine"]` holds a depth nobody reads (`lib/lfos.lua:618`); the key exists only to be counted.
- `home_m` returns nil for "not playing" and 0 for "playing at zero".

### Pattern 3: pending values flushed or canceled elsewhere

- `edited`, `deferred` and `sync_due` are set by param actions and flushed only by the clock's next step.
- A keyed budget value is dropped only by a newer send of the same key, never by a voice event.
- `held.fast_extras` is written and cleared by the macros; the matrix trusts them.
- Learn is canceled by MOD's page code.
- The pending live-file write is flushed by cleanup.
- The `through_zero` switch closures are held and fired by the scene fade and by morph (`lib/scenes.lua:752-754`).

### Pattern 4: Lua mirrors of engine state

| Belief | Held in | Reset by |
|---|---|---|
| LFO node exists, and its settings | `state[n].engine` | Lua's own stop or cleanup only |
| Route settings | the budget's record | never, short of a script load |
| Fast offset per channel | `S.engine_param_values["matrix fast ..."]` | never; relies on the engine's persistent offset node |
| Engine LFO phase | Lua's estimate (`lib/lfos.lua:361-370`) | pushed one way at a start, shape, mode, division or phase change, each bar, a transport start |
| Scatter | none | not needed |

Voice start, stop and sync reset none of these. That is correct, because the nodes live outside the voices. Nothing reads back: a command the engine's guards ignore is still recorded as sent (inferred). Cleanup sends nothing (#461). When a silent read turns an LFO on, its phase starts where the stale position lands: I saw 0.138 where the phase param was 0.

### Stale claims to fix

"A fade" is listed as a deferrable source in `docs/notes/lua/lfos.md:13`, `lib/lfos.lua:636` and `876`, and `test/unit/lfos_test.lua:582`. It is not: `lib/scenes.lua:747-750` writes outside `deferrable`, as the probe confirmed. `docs/notes/lua/engine-sync.md:21` already has it right.

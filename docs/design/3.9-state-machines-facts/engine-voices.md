# Facts: the state machines of the engine's voices, notes, grains, rings and freeze

Gathered on 2026-11-21 from `main` at a1c8e8b4 (3.8.0) by a read-only audit of this area, for `docs/design/3.9-state-machines-design.md`. Line numbers are that commit's. In the tables, a recommendation is one of: (a) leave the code and add a state table to the notes; (b) one named state value with one transition function; (c) a table-driven test of the transitions, code unchanged; (d) nothing. The design weighs them again and does not always follow them. A probe is a scratch unit test the audit ran against the harness: the seven probe files are in `probes.md`.

this message is the whole report. Nothing in the repo was changed and no engine check was run, so every claim about behavior comes from reading the code, notes, git history and issues.

## Summary

| # | Machine | Owner | Real states | Transition bugs | Rec. | Confidence |
|---|---|---|---|---|---|---|
| 1 | Freeze, per voice (with its copy routine and ring writers) | `StrataFreeze.sc` | 8, plus "stale" and "type waiting" | 11: #259, #260, #494, #495, #535, #801, #809, #834, #858, c5165ff5, #798/X7 | b-lite (one accessor) + a | medium-high |
| 2 | A voice's own synth sets | `StrataLifecycle.sc` | 5 per synth, × unconfirmed | 11: fc4f919b, dada0c54 (two), 37e88500, bb1aecd2, #46, #47, #497, #498, #458, #325 | a + c | high |
| 3 | Extra-note slot and pool | `StrataNotes.sc` | 3 × cutting × 4 kinds | 4 in the engine (#682, #683, 0635ba0f, db879f96), #690 on the Lua side | c | high |
| 4 | Engine states Lua cannot see | protocol | 11 listed | #858, #382, #325, #690 | a | medium |
| 5 | Own note (slot 0) park | `StrataNotes.sc` | 2 × 3 | 1 fix round (rulings 44, 47-49) | a | medium |
| 6 | Start confirmation | `StrataLifecycle.sc:244-302` | 4 | #497, 0635ba0f | d | medium |
| 7 | Mix stage `replacing` | `StrataMix.sc:202-215` | 2 | 0 found | d, one small fix | low-medium |
| 8 | Scan (mode, hold, one shot ended) | `StrataPositions.sc` | server-side | #742 | d | medium |
| 9 | Area phases | `Engine_Strata.sc:120-168` | 5 | #499, #503 | d (copy it) | high |
| 10 | Voice type and its waiting switch | `StrataLifecycle.sc:354-392` | derived | 2, both caught at design time | d (copy it) | high |
| 11 | `sendToSynth` bracket, one-bundle rules | `StrataUtil.sc:95-97` | protocol | #498, #535, #834 | d | high |

Five things most worth knowing:

1. **The engine's invariant check covers two conditions, and no historical bug ever tripped either.** `warnInvariant` fires only when a superseded synth sits in `releasingSynths` beside a live one, or when an area's `stop`/`free` raises. Every stacking, stuck-voice and late-callback bug was a wrong transition between tracked-legal states, or a state sclang could not see.
2. **`test/notes_model.lua` has drifted from the engine.** It dates from 2026-11-13 and knows neither 3.8's voice sources (its `kind_for` says voice or stream where the engine says `\input`) nor 3.7's per-voice root note. The test never uses a voice source, so the first is invisible; I did not check whether the walk ever sends a root other than 60. The engine check has no per-slot model of its own, only pool bounds.
3. **Freeze "kind" is computed by four predicates over different field subsets.** `frozenSynthVoice` ignores which source was frozen, so a stale freeze misreads there. Only Lua's send order (freeze before `voiceOn`) keeps that unreachable. One accessor would fix it without changing stored state.
4. **Budgets rule out the obvious remedies.** AGENTS.md is at 7,923 of 8,000 words. The engine check is at 1,768 s of 1,800 s, and `docs/status.md:27` puts the room at about 30 s. So new rules go in notes files, and new checks must be no-yield walks over the engine's own bookkeeping.
5. **Two patterns are worth copying.** The voice type keeps no record of a waiting switch, only the live synth's `defName` against `voiceDefFor`, and has had no post-ship bug. The area phases are named hooks with tracked rollback lists.

## Full report

### 0. Constraints on any refactor

- Extension files add methods only, and `lib/Engine_Strata.sc` is never edited. New state can only live in `areaState[\<area>]`. The lifecycle sets are instance variables (`Engine_Strata.sc:50-55`), and the checks read them directly: `lifecycle.scd` references `releasingSynths` 17 times, `fadingSynths` 16; `types.scd` references `cuttingSynths` 13.
- Any new method that keeps a closure and is called from a function must go through `areaCall` and be listed in `AREA_CALL_METHODS` (`test/unit/structure_test.lua:1497`; #211, #689). A single "transition" method taking a function argument would fall under this rule.
- `voiceHit` deliberately has no `try` and allocates nothing (`StrataVoices.sc:293-301`). A per-command transition table that builds Events on every hit would work against that.
- Many transitions are correct only as one bundle (`switchGrainSynth`, `unfreezeWithControl`, `switchVoiceType`). A state value set in sclang says nothing about what the server did in which block.
- SuperCollider 3.13 on norns differs from 3.14 in behavior that mattered (#801: `Phasor`'s first-sample trigger).

### 1. What the invariant check covers

- `warnInvariant` (`StrataUtil.sc:75-78`) posts `Strata invariant broken: …`. `test/run_engine_check.sh:361` fails the run on that line.
- It has three call sites:
  - `cutFadingSynths` (`StrataLifecycle.sc:409`): a running voice switched with a voice or grain synth still in `releasingSynths`.
  - `releaseVoice` (`:477`): a different synth releasing under a key that is live.
  - `runAreaPhases` (`StrataUtil.sc:240`): an area's `stop` or `free` raised.
- It runs inline, in production and in the check, on every running source switch and every `voiceOff`. Nothing runs after other commands.
- The two lifecycle lines were added after #46 for paths believed unreachable (02dca90f). The check provokes them only with stand-in synths (6157b7a3).
- The runner adds end-of-area checks only (`test/engine_check.scd:806-813`): no voice, grain or mod synth left, no note in a slot, polls in place. `noteNodesAgree` (`:703-720`) compares slots with the server tree where a check calls it.
- Looking at what each historical bug was:
  - Stacked synths (fc4f919b, dada0c54, bb1aecd2, #46) were synths legitimately in the fading and cutting sets, or untracked. They were wrong transitions, and the invariant could not see them.
  - #497 was a state sclang could not distinguish: `register(true)` made a never-started synth `isPlaying`.
  - #494 and #495 were a legal state with wrong shared data.
  - #858 was an engine transition Lua never heard of.
- So the pattern matches the Lua side: the invariant catches illegal states, and the bugs were transitions.

### 2. Machines

#### M1. Freeze (per voice)

**Owner.** State is in `allocFreezeState` (`StrataFreeze.sc:72-100`). Writers are `freezeVoice` (`:221-248`), `unfreezeVoice` (`:262-284`), `holdCopyRing` (`:642-648`), `copyInputToCopyRing` (`:423-480`), `abandonCopy` (`:557-563`) and the stop hook (`:53`).

**States.** Encoded by `\frozen`, `\mode`, `\source`, `\copied`, `\copies`, `\faded`, `\stopped`, plus `grainControls[v][\freeze]`, the writer node and the copy-writer key. The real set:
- unfrozen;
- hold on synth (writer paused with `run`);
- spectral on synth (writer replaced), with the derived sub-state "type switch waiting";
- hold on a slot (the engine only records it);
- copy pending, hold or spectral (frozen, `\copied` false, a routine alive, readers possibly faded);
- copy held;
- copy held with a spectral copy writer;
- stale: frozen on a source the voice no longer has, reachable only while stopped.

Representable but meant impossible: `\copied` with source 0; a copy writer with mode hold; `\mode` set with `\frozen` false; spectral on the standard tier.

**Events.**

| Event | Effect |
|---|---|
| `freeze` > 0.5 | `freezeVoice`: unfreezes first if mode or source differ, bumps `ringChanges` |
| `freeze` ≤ 0.5 | `unfreezeWithControl`, one bundle (`:299-307`) |
| `freezeMode` while frozen | unfreeze and freeze in one bundle (`:199-210`, #834) |
| Running source switch | `unfreezeVoice` (`StrataLifecycle.sc:326`) |
| Copy routine steps | Each guarded by `current` (`:426-427`): `\copies`, `ringChanges`, `\stopped` |
| Routine exhausts attempts or span refused | `abandonCopy`, then the `freezeEnded` poll |
| `voiceOff` | Nothing; a stopped voice stays frozen |
| Area `stop` | `\stopped` set |

**Outside readers and writers.**
- `StrataNotes.sc:136-138` (`frozenSynthVoice`).
- `StrataVoices.sc:200-201` (`spectralHoldsVoice`).
- `StrataLifecycle.sc:327` writes `ringChanges`.
- `StrataFreeze.sc:340` writes the rings area's `\writers`.
- `StrataFreeze.sc:93-99` wraps the grains area's `history` handler.

**Guards.** Tokens as above. `freeze.scd` has 53 checks, by example (about 25 scenarios, `freeze.md:90-103`). `types.scd` covers "whatever ends the freeze, one case a path". Nothing asserts `ringChanges` directly.

**History.**
- 68a7ffa5 (11-07) introduced it.
- c5165ff5: `freeze` 1 was sent on a switch (an order bug).
- #259: two places decided what a grain synth reads; fixed with `grainReadPairs`.
- #260: a registry was never pruned.
- #494, #495: the copy lived in the voice's own ring, so other grain synths replayed it at full level. Fixed with a separate copy ring (9c5380aa).
- #535: the re-point and `freeze` 0 landed in different blocks.
- #801: the 3.13 `Phasor` issue.
- #809, #835: late copies.
- #834: three messages where one bundle was needed.
- #858: an abandoned hold left Lua showing frozen.
- #798/X7: the type switch under a spectral freeze.

**Why it has this shape.** The copy is the one ring write not made by a writer node. It needs a fade wait and a `server.sync`, hence the routine and the tokens.

**What the player hears.**
- During a late copy, `[F]` shows while the voice plays live audio half a second late (`freeze.md:8`).
- After eight failures `[F]` clears (#858).
- Both need a server queue held for seconds.
- I found no state the player cannot leave.

**Hypothesis: one read accessor, plus a table.** Four predicates compute "what kind of frozen" from different subsets:
- `frozenOnInput` (`:171-174`): the frozen source only.
- `spectralHoldsVoice` (`:180-183`): mode and frozen source.
- `readsInputCopy` (`:665-669`): both sources and `\copied`.
- `frozenSynthVoice` (`StrataNotes.sc:136-138`): `grainSource` and `\frozen`, never the frozen source.

In the stale state `frozenSynthVoice` is true for a voice whose ring is not held. `ownNotePairs` (`StrataNotes.sc:498-507`) would then route the own note to the grain synth, and `noteKindFor` (`:154-160`) would make stream notes. This is unreachable from Lua because a start sends `freeze` before `voiceOn` (`docs/notes/lua/freeze.md:25`). I inferred this by reading, not by running it; the engine check's "no freeze resent" cases start voices in exactly that state.

Recommendation: one accessor, say `freezeKind(voice)`, returning `\none`, `\holdSynth`, `\spectralSynth`, `\holdSlot`, `\copyPending`, `\copyHeld` or `\stale`, with the four predicates rewritten over it. Add a state × event table to `freeze.md`. No stored state changes.
- Cost: about 30 lines and no check time.
- What could break: `frozenSynthVoice` changing answer in the stale case. `notes.scd` and `freeze.scd`'s stopped-and-moved cases would show it.
- Bug history 11, blast radius high (level bursts, silence), confidence medium-high.

Two related notes:
- The comment at `StrataFreeze.sc:214-216` and `freeze.md:73` say Lua resends `freeze` after `voiceOn`. Since #325 a start sends it before. Those lines look stale.
- Ring writers (running, paused, spectral, plus the copy writer) are not a separate machine; they are a projection of this one.

#### M2. A voice's own synths

**Owner.** Sets are declared at `Engine_Strata.sc:20,50-55` and allocated at `StrataVoices.sc:41-60`. Transitions are in `StrataLifecycle.sc`:
- `gateVoice` (`:143-202`), `releaseVoice` (`:471-487`);
- `switchGrainSynth` (`:323-352`), `switchVoiceType` (`:385-392`);
- `replaceFadingSynths` (`:428-433`), `cutVoiceSynth` (`:437-442`), `freeCuttingSynths` (`:451-457`);
- `voiceSynthFreed` (`:223-237`), the single exit;
- `forgetFailedStarts` (`:283-291`).

**States, per synth.**

| State | Encoded by | Server envelope |
|---|---|---|
| live | `synths[key]` | gate 1 |
| releasing | `releasingSynths[v][key]`, with `releasedGrainSource[v]` | gate 0, can be re-gated |
| fading | `fadingSynths[v]` | forced release, never re-gated |
| cutting | `cuttingSynths[v]` | `kill` 1 |
| gone | in no set | freed |

Unconfirmed is orthogonal (M6). The voice's running state is derived by `voiceRunning` (`StrataUtil.sc:45-47`).

Representable but meant impossible: one synth in two sets; a mod synth fading or cutting; a releasing synth beside a live one under the same key (warned); more than one fading generation.

**Events.** `voiceOn`, `voiceOff`, `setGrainSource` (running or stopped), `setVoiceType`, `/n_end`, `/n_go`, the 0.5 s confirm timeout (evaluated lazily), area `stop`.

**Outside readers.** `StrataBuffers.sc:249` reads `grainSlots`. `setSynth` and `voiceRunning` are used widely. There are no outside writers of the three sets.

**Guards.**
- The two warnings in section 1.
- `lifecycle.scd`, 121 checks by example, plus the no-yield tracked-count stress `checkStopStartCycles` (`lifecycle.scd:100-133`, a fixed sequence of 24 commands).
- The memory area's worst cases.

**History.** All eleven bugs fell between 11-03 and 11-10.
- fc4f919b: releasing grain synths were unbounded when scrolling sources.
- dada0c54: a second forced release is ignored by `EnvGen`, so the kill fade was added; and a synth gated off in its first block never freed, so `openedGate` was added.
- 37e88500: placement next to a synth that may already have freed.
- bb1aecd2: switches inside one 50 ms cut piled up.
- #46: stop, source, start and switch cycles piled up.
- #47: no `sendToSynth`; fading buffer grain synths were not told of slot changes.
- #497: a failed `/s_new` was re-gated forever.
- #498: the `/error -1` bracket hid later failed starts.
- #458: `setGrainParam(kill)` cut every restart 50 ms in.
- #325: a started voice's first grain played the last run's values.

There have been none since, although 3.5 (notes) and 3.8 (types) added transitions; ruling 15 caught one at plan time (`docs/decisions/3.8.md:184`).

**What the player hears.** Stacking exhausts the 8 MB real-time pool and audio drops out. That is fixed and held by memory floors.

One open gap: a failed start leaves the voice silent while it shows as running. `forgetFailedStarts` runs only at a `voiceOn`, and Lua sends `voiceOn` only from `start_voice` on an inactive voice (`lib/engine_sync.lua:770-784`). So the recovery is to stop and start the voice, and nothing tells the player. It needs pool exhaustion, which the budget prevents.

**Hypothesis: a + c, and not b.** A symbol per synth would be a second record beside four containers that tests reach directly, which is the duplication the modulation audit warns against.
- (a) Replace the paragraph-long prose at `lifecycle.md:17-29` with a table of the five sets × eight events.
- (c) Add a `checkOwnSynths(voice)`-style function in the runner: sets disjoint, no mod synth fading or cutting, nothing releasing under a live key, at most one grain and one voice synth fading. Assert it after every command of a seeded no-yield walk over `voiceOn`, `voiceOff`, `setGrainSource`, `setVoiceType`, `freeze`, `freezeMode` and `noteOn`. This is `checkStopStartCycles`' technique made random.
- Cost: a few seconds of check time, which must be measured against the 30 s of room. Calling it from the runner's `commandTo` for every command is tempting; the checks have about 1,790 command call sites and some loop, so measure first.
- What could break: nothing in the engine; the code is unchanged.
- Bug history 11, blast radius high, confidence high.

A note for agents: `voiceSynthFreed`'s restart has no rate limit. #458 was a 20 Hz restart loop. Any future cause of a live synth freeing itself would loop again.

#### M3. Extra-note slot and pool

**Owner.** `StrataNotes.sc`. The record is at `:100-104`. Writers of `state`, `synth` and `cutting` are the `onFree` (`:279-280`), `freeNoteCutting` (`:299`), `cutNote` (`:321-326`), `releaseNote` (`:343`), `startNote` (`:382-383`) and `stopNotes` (`:636`). All are in one file.

**States.** `\empty`, `\live` or `\releasing`; × a cutting synth present or not; × kind (`\voice`, `\buffer`, `\input`, `\stream`). This is the one machine in my area with a named state symbol.

Representable but meant impossible: live with a nil synth. `noteSynths` (`:125`) checks for it; `releaseNote` (`:341-342`) and `extraNoteOn`'s live branch (`:409`) do not.

**Events.**

| Event | Effect |
|---|---|
| `noteOn` on live / releasing / empty | re-pitch and accent / cut and start / start (`:407-416`) |
| `noteOff`, cut 0 or 1 | release / cut |
| `voiceOff` | live notes release |
| Running source switch | all cut, live ones restarted (`:595-604`) |
| Type switch | live `\voice` notes cut and restarted (`:613-621`) |
| Synth voice's unfreeze | stream notes cut, live ones restarted as voice synths (`:527-539`) |
| `setNotePool`, `makeNoteRoom` | oldest cut |
| `/n_end` | slot empties or cutting clears |
| Confirm timeout | failed start forgotten at the slot's next command |

**Guards.** `notes.scd`, 59 checks, with one seeded walk.

**History.** #682 (a restarted stream note out of tune), #683 (an added chord key did not open the step gate), 0635ba0f (a failed start held pool room), db879f96 (rulings 44, 45, 47), #714 (a check race). #690 was Lua-side and found by the Lua model.

**Coordinator's fact 2: does the engine check test the same rules?** `checkPoolRandom` (`notes.scd:848-888`) runs 2,000 seeded commands, but:
- it asserts only held ≤ pool and cutting ≤ pool after each command, and `noteNodesAgree` at the end;
- it never sends `setGrainSource`, `freeze`, `setVoiceType` or `noteRegion`;
- it compares no per-slot state, kind or pitch with a model.

Those rules are checked engine-side by example only.

**Spot-check of `test/notes_model.lua` against the engine.** The model's last change was 2026-11-13 (`git log`), before 3.7 and 3.8.
1. `Model:kind_for` (`notes_model.lua:43-48`) against `noteKindFor` (`StrataNotes.sc:154-160`): they diverge. The engine returns `\input` for voice sources 10-16; the model falls through to stream or voice. The walk's sources are synth, slot 1 and input only (`strata_test.lua:432`), so no test sees it.
2. `absolute_rate` (`notes_model.lua:40`, fixed root 60) against `absoluteNoteRate` (`StrataNotes.sc:37-39`, per-voice `rootNotes`): they diverge when Lua sends a `rootNote` other than 60. I did not check whether the walk ever does.
3. `noteOn` on a releasing slot (`notes_model.lua:161-167`) against `extraNoteOn` (`:412-415`), and `setNotePool` (`:180-190`) against `:466-475`: they match.

The model has no `setVoiceType`. That is harmless for slot state, since a restart keeps state and order.

**Hypothesis: c.** Extend the Lua walk's sources to a voice source and a type change, fix `kind_for`, and consider a docs test tying the model's kind rule to the engine's. On the engine side, add switches and freezes to `checkPoolRandom` with a per-slot check (state ⇔ synth; kind matches the voice at start). Cost: seconds. Bug history 4 + 1, blast radius medium, confidence high.

#### M4. Engine states Lua cannot see

| Engine state | What tells Lua it ended |
|---|---|
| Voice releasing (tail up to 30 s, `StrataVoiceDefs.sc:63`) | nothing; Lua's `voice.active` is already false |
| Fading and cutting synths | nothing, and nothing is needed |
| Failed start (silent while active) | nothing; ends at the next stop and start |
| Late-gate restart (`voiceSynthFreed`) | nothing; harmless |
| Freeze copy pending or late | console line only (`StrataFreeze.sc:463`) |
| Freeze abandoned | `freezeEnded` (#858), the only freeze report |
| Freeze of a stopped voice, including stale | nothing; the next start's `freeze` send reconciles it |
| Type switch waiting under spectral | nothing; derived on both sides, user docs explain it |
| Note slot releasing (still counts in the pool) | nothing; Lua counts on its own |
| Note refused, pool full of live notes | console line (`StrataNotes.sc:378`) |
| Failed note start | nothing; heals at the slot's next note |
| Mix stage replaced after bad values | console line (`StrataMix.sc:212`) |
| One-shot scan ended (level 0) | nothing; Lua estimates the playhead (another auditor's area) |
| Guarded command ignored | console line |

The unfreeze on a source switch is implemented twice: in the engine (`StrataLifecycle.sc:326`) and in Lua's `source_change` hook. No report passes between them. #690 lived in that seam.

**Hypothesis: a.** Put this table in `voices.md` or `freeze.md`. A new poll is not justified for any row except perhaps a failed start, and that one needs a device measurement first.

#### M5. Own note (slot 0)

**Owner.** `StrataNotes.sc:480-586`.

**States.** `parked` × where the note sounds: the voice synth on a synth voice, the grain synth on a buffer or input voice, or both while a synth voice is frozen (`ownNoteGateKeys`, `:573-578`). All derived.

**History.** One fix round, db879f96 (rulings 44, 47, 48, 49).

**What the player hears.** One accepted artifact: a short tail at an unfreeze under a note parked during the freeze (`notes.md:12`).

**Hypothesis: a.** A 2 × 3 table in `notes.md`. Its correctness also depends on the `frozenSynthVoice` unification under M1.

#### M6. Start confirmation

**Owner.** `watchStart` (`StrataLifecycle.sc:244-254`), `startFailed` (`:271-274`), `endFailedStart` (`:296-302`), and `forgetFailedNoteStarts` (`StrataNotes.sc:289-293`).

**States.** Unconfirmed → confirmed (`/n_go`), ended (`/n_end`), or failed (0.5 s passed, evaluated lazily).

**History.** #497, 0635ba0f.

**Hypothesis: d.** It is small and guarded, and it is checked by holding an `/s_new` back from a bundle. The player-facing gap is listed under M2.

#### M7. Mix stage

**Owner.** `replaceBadVoiceMix` (`StrataMix.sc:202-215`).

**States.** `\replacing[voice]` false or true; it is cleared by a one-shot `/n_go` responder (`:211`).

**Inferred, not verified.** If the replacement's `/s_new` failed there would be no `/n_go`. `\replacing` would stay true and `synths[key]` would name a missing node. Plain sends to it would then fail, and the voice would stay silent until the engine reloads. It would need pool exhaustion at that instant.

**Related, another auditor's area.** The step gate and mute are server-side envelope state in the modulation area (`StrataModulation.sc:223-239`), with values kept in `grainControls`.

**Hypothesis: d,** plus a timeout on the flag. No bug history.

#### M8. Scan

**Owner.** `StrataPositions.sc`.

**States.** The state lives in UGens (`slotScanPhase`, `:137-146`), plus the transient `scrubRate`, `scanHold` and `t_scanReset`, and `\regionResets` (`:34`, `:91-95`), a one-block window that de-duplicates two resets (#742).

**What the player hears.** One shot ended means silence until a hit, by design.

**Hypothesis: d.** The Lua playhead mirror belongs to another auditor.

#### M9. Area phases (already explicit; copy it)

**Owner.** `alloc` and `free` (`Engine_Strata.sc:120-168`), `runAreaPhases` (`StrataUtil.sc:237-243`).

**States.** Allocated → defs added → commands added → started → stopped → freed, with rollback.

**Guards.** Named hooks, the `allocated` and `started` lists, `areas = nil` after a rollback, and a per-area `try`.

**History.** #499, #503.

**Two weak spots.**
- "Am I past stop?" is re-encoded per area: `\stopped` in freeze, modulation, envelopes and onsets (grep), `synths.clear` in voices (`StrataVoices.sc:307`), and `slotChanges` in buffers. One flag set by `runAreaPhases` would unify them. It crosses other auditors' areas and the gain is small.
- `stopVoices` and `freeMixBuses` are not safe after a partial `allocState`, where rings and out rings are (`StrataRings.sc:191`). The `try` contains the error.

**Hypothesis: d.**

#### M10. Voice type (already clean; copy it)

**Owner.** `voiceTypeWaits` (`StrataLifecycle.sc:364-367`), `applyWaitingVoiceType` (`:374-376`), and `gateVoice`'s cut (`:165-168`).

**Shape.** One stored fact, `areaState[\voices][\types]`. "Waiting" and "releasing synth of another type" are both derived from `defName`. This is the reconciler shape the modulation audit praised: there is no second record, so there are no drift bugs.

**Hypothesis: d.**

#### M11. Message protocols

- `sendToSynth`'s `/error -1 … -2` bracket (#498).
- One-bundle rules (#535, #834).
- "Freeze before `voiceOn`" (#325).

These are conventions, not state. The checks that read the wire (`h.wireUnits`) are the right guard.

**Hypothesis: d.**

### 3. Where the engine keeps two records of one fact

- **Ring writers.** `synths[ringWrite<i>]` and `areaState[\rings][\writers][i]` are both written at `StrataRings.sc:166-175` and `StrataFreeze.sc:339-340`. No engine code reads the second; only checks do (`freeze.scd:759`, `rings.scd:561`). The out rings do the same (`StrataOutRings.sc:73-79`). It is a dead duplicate.
- **Frozen.** `\frozen[v]` and `grainControls[v][\freeze]` (`StrataFreeze.sc:233/236`, `:267/272`, `:303`) are kept in step by a prose rule (`freeze.md:19`).
- **Frozen source.** Freeze's `\source` and `grainSource` are intentionally two, and are read inconsistently (M1).
- **Note record.** `state` and `synth` (M3).
- **Released grain source.** `releasedGrainSource[v]` is stored apart from the releasing synth it describes. The voice-synth analogue is derived (`:165`).
- **Playing.** NodeWatcher's `isPlaying` (asserted by `register(true)`) and `unconfirmedStarts`. The first record's lie was #497.
- **Reader registries.** `grainSlots`, `ringReaders` and `inputReaders` hold the same synths in three registries. They are safe because there is one exit, `forgetGrainReader` (`StrataLifecycle.sc:258-262`). #260 was the time one had no exit.
- **Kept controls.** `voiceControls` and `grainControls` are the engine's copy of Lua's voices table. This is by design, for restarts.

### 4. State tables in the notes

`record.md`'s table (state when the command arrives × command → effect → reports) has no equal in my area.

| Notes file | What it has | What it lacks |
|---|---|---|
| `freeze.md` | a table of state keys (`:27-42`); "What each source holds" (`:62-67`) | state × event |
| `notes.md` | a per-command table (`:36-42`); per-state prose (`:58-62`) | the cuts and restarts that a switch, type change or unfreeze cause |
| `lifecycle.md` | prose only (`:17-29`, single paragraphs of several hundred words) | any table |
| `types.md`, `positions.md`, `mix.md`, `structure.md` (Areas) | prose only | any table |

In order of value, the tables to add are lifecycle (M2), freeze (M1), note slot (M3) and the unseen-states list (M4).

### 5. Not verified

- The mix `replacing` stuck state (M7) and the stale `frozenSynthVoice` misread (M1) come from reading alone.
- I did not measure what an after-every-command invariant would cost in check time.
- I did not confirm that the Lua walk never sends a `rootNote` other than 60.
- I did not read the grain SynthDef bodies (`StrataGrainDefs.sc:186-491`) line by line; `ringGrainReader`'s per-block freeze hold (#535) is taken from the notes.

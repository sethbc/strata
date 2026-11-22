# Facts: the state machines of the engine's buffers, recording, files, effects and modulation

Gathered on 2026-11-21 from `main` at a1c8e8b4 (3.8.0) by a read-only audit of this area, for `docs/design/3.9-state-machines-design.md`. Line numbers are that commit's. In the tables, a recommendation is one of: (a) leave the code and add a state table to the notes; (b) one named state value with one transition function; (c) a table-driven test of the transitions, code unchanged; (d) nothing. The design weighs them again and does not always follow them. A probe is a scratch unit test the audit ran against the harness: the seven probe files are in `probes.md`.

## Summary

| # | Machine | Owner | States | Transition bugs | Rec. | Confidence |
|---|---|---|---|---|---|---|
| 1 | Recording take | `StrataRecord.sc` | 11 | about 10: #22, d94f5d71, 8e7f212c, #261, #311, #373, #374, #455, #457, #313 | c, walking record.md's table | high |
| 2 | Buffer slot and its generations | `StrataBuffers.sc` | 7 | about 8: 37e88500, #22, #5, 6177c537, #375, #456, #578, 381019bf | a | high |
| 3 | File write and the mover | `StrataFiles.sc`, `StrataWaveform.sc` | 6 + 5 | about 8: 967949f0, #127, f0d998c9, fd73492b, 3c30c513, 0635a8dd, 335bea95, #312 | a | medium |
| 4 | Engine LFO node place | `StrataModulation.sc` | 4 | 2: 12872c74, #611 | a | high |
| 5 | Effect bypass | `StrataEffects.sc` | 3 | 1: #308 | a | high |
| 6 | Delay freeze and clear | `StrataDelay.sc` | in-graph | 1: a20e29ce, plus one latent | a | medium |
| 7 | Onset analysis | `StrataOnsets.sc` | 5 | 0 | d, plus one guard | medium |
| 8 | Tuning set | `StrataScale.sc` | 2 | 0 | d | high |
| 9 | Envelope route, scatter | `StrataEnvelopes.sc`, `StrataModulation.sc` | 3 each | 0 | d | high |
| 10 | Poll numbering | several | explicit | 5, all fixed by the pattern | d, copy it | high |
| 11 | Performance tier | `StrataPerformance.sc` | one decision | #153, #493, #500 (agreement, not transition) | d | high |

Five things most worth knowing:

1. **No state invariant covers these areas.** `warnInvariant` is called three times, none here; the only line my areas can raise is an area's `stop` or `free` raising (`StrataUtil.sc:240`). Almost every bug here was a wrong transition between legal states. Two were illegal states (#261, 12872c74); an end-of-area sweep written in the check would have caught those at no run time.

2. **record.md's 13 rows match the code, with two imprecisions and one missing phase.** The table has no "ending" phase (synth freed, peaks or frame count pending). There, a bad load cancels a stopped take but not a one-shot that ended on its own. The record check covers the rows by example across `record.scd` and `buffers.scd`, never as a table.

3. **Three engine states have no certain end report.**
   - A long load's check routine has no `try` (`StrataBuffers.sc:305-313`); saves and onset passes do.
   - `analyzeBuffer` never supersedes: six commands run six concurrent passes, each with its own temporary files and report.
   - Every command the guards ignore (LFO, envelope, offset, tuning) posts one console line and reports nothing.

4. **The engine keeps two or more records of one fact in five places.** Each bug cluster sits on one of them: `takes` against `recordSynths` and `stopReplies`; `bufferFrames` against `announced`; `bypassed`, `pendingFrees` and `synths[key]`; `running` and `released` against the node; four copies of a slot's overview.

5. **Freeze and bypass are coupled only by Lua's ordering.** The engine keeps `frozen` through a bypass and a lift creates the node with it. A node born frozen has its input closed and, by `Gate`'s source, a held time of 0 (inferred, not run).

A constraint on every option (c): the areas sum to 1768 s and a docs test fails past 1800 s (`docs/status.md:27`).

---

## Full report

File names below are under `lib/engine/` unless a path is given. Nothing was run; "inferred" marks what I read but did not execute.

### 0. Cross-cutting answers

**What `Strata invariant broken` covers.** `warnInvariant` (`StrataUtil.sc:75`) has three call sites: two in `StrataLifecycle.sc` (409, 477) and `runAreaPhases` (`StrataUtil.sc:240`). In my areas only the last applies. Wrong-transition bugs were the majority: a late reply acting on a newer slot, a cancel leaving the wrong content, a report in the wrong order. The two illegal states were:
- #261: `stopReplies[i]` set with no take, so `slotRecording` was true with nothing recording.
- 12872c74: an LFO place holding a synth that never started.

A check-side sweep after each area, reading the engine's getters, would cost no engine code and no run time. Candidate assertions:
- `stopReplies[i]` set implies a stopping replace take in `takes[i]`.
- `recordSynths[i]` set implies it is `takes[i][\synth]`.
- `bypassed`, `pendingFrees` and `synths[key]` form one of three legal triples.
- Every LFO and route place's synth is in `nodeChannels`.
- `writeGenerations` and `pathRenames` are empty, and the mover's `pending` is 0.
- `announced[i]` equals `bufferStateSeconds(i)` when no take is live.

**Engine states Lua cannot see.**

| Engine state | What tells Lua it ended |
|---|---|
| Long load in its check (`StrataBuffers.sc:305`) | `bufferState` 0 then the length, or `bufferLoadFailed`. A superseded check reports nothing (`buffers.md:9`). An sclang error in the routine reports nothing: no `try` (inferred as reachable). |
| Load fading, reading, peaks pending | `bufferState` length, after the peaks rename (`StrataBuffers.sc:381`). A stopped mover delays it up to 1 s (`StrataWaveform.sc:113`). |
| Take waiting or preparing | `armed`, only with a delay or threshold (`StrataRecord.sc:426`). |
| Take ending | `ended` or `canceled`. I traced every `slotChanged` caller: each is preceded by `stopRecording` or re-keys the take (`StrataRecord.sc:703`). Three exceptions follow. |
| Onset pass | `bufferOnsets`, exactly once, unless the engine stopped (`StrataOnsets.sc:79`). |
| Save | `bufferSaveResult`, once; never if pending at free (`waveform.md:54`). |
| LFO, route, scatter node; bypass fade or free; clear window; pending tuning set; slot gain reset to 1 | Nothing. |

The three exceptions for a take: a command under one frame is counted and returns silently (`StrataRecord.sc:403-405`, unreachable from Lua); an engine free; and a record synth whose `/s_new` failed, which only a `stopRecord` resolves (`StrataRecord.sc:707-714`). So a playable recording with no Lua fallback depends on `recordSynthFreed` firing.

**Guard-ignored commands.** `fastModIndicesValid` and `fastModValuesFinite` (`StrataModulation.sc:524-540`) post one line and the command does nothing: no `received`, no node, no channel change. The engine holds offsets only, so a mismatch is a stale LFO, route or offset. It persists until Lua's value next changes, since Lua records the command as sent.

Depth 0 differs by kind:
- `setFastLfo` depth 0 keeps or makes a node writing `offset` alone (`:256`); only `stopFastLfo` removes it.
- `setScatter` depth 0 releases the node (`:471-476`).
- `setFastEnv` depth 0 keeps a node writing 0.

Commands are also dropped silently while the area is `stopped` (`:380`, `:458`, `:510`). A re-gate that reaches a dead node is repaired when its `/n_end` arrives (`:356`), so that mismatch never persists.

**Duplicated records.**
- `takes[i]` (the Event) against `recordSynths[i]` and `stopReplies[i]`. `slotRecording` reads the latter two (`StrataRecord.sc:314`), never `takes`. #261 was this.
- `bufferFrames[i]` against `announced[i]` (`StrataBuffers.sc:51`, `:220`), deliberate since 381019bf. One documented path leaves them apart indefinitely (`buffers.md:18`): a playable arming canceled by a new `recordBuffer` inside its peaks rename. Lua never sends it.
- `bufferSampleRates[i]` against the server buffer's own rate, which survives a clear (#310).
- `slotChanges`, `bufferLoads` and `loadsSuperseded`: three counters, the third a shadow of the first in load numbers (`StrataBuffers.sc:440-446`).
- The overview: sclang's `\peaks`, the peak buffer, `\written` and the file (`StrataWaveform.sc:26-29`). #313, #401 and #523 were these drifting.
- `place[\running]` and `[\released]` against the node; `bypassed`, `pendingFrees` and `synths[key]` for three states.
- The mover's `alive` against `exited` and `/proc`; `pending` against the ack files.
- `writeSlot`'s `writeGenerations`, `pathRenames` and four closure flags (`StrataFiles.sc:295-305`).

**Constraints that make a naive explicit FSM wrong here.**
- Extension files add methods only and `lib/Engine_Strata.sc` is never edited, so new state can only live in `areaState`.
- Each transition's deferred continuation is a closure in a `sched`, `fork`, `onFree` or OSC reply. Any method that keeps one must be reached through `areaCall` (#211, #689; `StrataUtil.sc:207`). A generic transition function taking action closures multiplies those frames.
- sclang's view of a node lags the server (`sendToSynth`, `StrataUtil.sc:95`). "Released, liveness unknown" is a real state that a clean enum would hide.
- Chunk loops yield through `yieldToCommands`, so commands interleave inside one transition.
- Lists must not grow in responders, and 3.13 and 3.14 differ (`Sweep`, `Signal` mod).

### 1. Recording take

**Owner.** State is `takes[i]` (`StrataRecord.sc:69`), `recordSynths`, `stopReplies`, `recordCounts` and the take's fields `kind, started, sent, stopping, change, peaksBefore, peaksWrittenAt` (`:417-423`). Transitions: `recordSlot` :395, `prepareTake` :454, `startTake` :480, `sendTake` :501, `takeArmed` :542, `refreshRecordPeaks` :569, `recordSynthFreed` :605, `endTake` :644, `stopRecordSlot` :680, `stopRecording` :289, `cancelSlotRecording` :326.

**Real states.**
- none
- waiting unprepared (a `sched` pending, :433)
- preparing (fade wait, then zero, then sync, :463-468)
- shrinking peaks (`/b_getn` pending, :486)
- sent and paused (a timestamped `/n_run`, :520)
- sent and unarmed (threshold)
- recording (`started`)
- stopping unconfirmed (gate 0, sync pending, :707)
- stopping (5 ms fade)
- ending (synth freed; `/c_get` or peaks pending, :626, :650)
- ended (take nil; the scratch write runs detached)

Representable and meant impossible: `stopReplies` set with no take (#261); two record synths in one slot; `started` without `sent`.

**Outside writers and readers.** `applyLoad`, `rejectLoad` and `clearSlot` call `stopRecording` and `slotRecording` (`StrataBuffers.sc:302, 341, 405, 453`); `analyzeSlot` reads `slotRecording` (`StrataOnsets.sc:94`). Grain synths read the head bus. On the Lua side, `lib/record.lua:287-355` mirrors it with `takes[slot].phase`.

**record.md's table against the code.** Rows 1 to 13 hold. Two imprecisions:
- Row 2's `bufferState max(V, D)` is sent only when the length changed (`:549`).
- Row 4's "reports nothing" misses a failed server read, which still reports `emptied` (`StrataBuffers.sc:376`).

One missing phase, "ending". A bad load cancels a stopped replace take, because `stopReplies` is set. It does not cancel a one-shot that ended on its own, because `slotRecording` is then false while `takes[i]` is not nil; that take completes after the `bufferLoadFailed`. A new recording or a clear in that phase reports `canceled` for a take whose audio was complete (`:292-299`). Lua copes with both. Inferred by reading.

**How it is guarded.** `slotChanges` against `take[\change]` on every delayed step; identity tests (`=== take`); the node-ID match at arming (:190). Tests: 63 cases by example in `record.scd`, one rapid-sequence test (`record.scd:1323`), and rows 5 and 10 in `buffers.scd`. No row walk.

**History.**
- Born at e69a5a3a (3.0); `slotChanges` came with 37e88500 for a record and clear race.
- 7327529a (#22): a bad load during a recording.
- d94f5d71: `stopReplies` added.
- e676079a: the 3.3 rewrite.
- 8e7f212c: the head reset on a retake, and a stop crossing the arming reply.
- 3717c7d6 (#261).
- fb994860 (#311, #373, #374, #455, #457): the state table.
- f022affa (#312, #313).
- #376 and #565 were timing, not state.

The Event with flags came from the 3.3 design. `stopReplies` and `recordSynths` are class variables from 3.0 and could not move.

**What the player sees.** `ARM`, `REC`, `K3:...`. A take armed by level empties its buffer at the command (`:428-437`; `record.md:6`) and holds it empty until the level arrives or K3 cancels, which leaves it empty (row 7). The user page says only that a take "silences the voices" (`docs/user/pages/buffer.md:34`). Recoverable by reloading the file.

**Hypothesis: (c).** Walk the 13 rows as a table (command sequence, expected reports in order, slot frames), replacing the overlapping example tests so the area's 122 s stays flat. Add the ending phase as rows 14 to 16 and a phase table to record.md. (b) is wrong here: `started` and `sent` deliberately lag the server, and each phase's continuation is a closure. Risk: timing flakes in the walk; the runner's `/fail` and report-order assertions would show it. Bug count 10, blast radius high (audio loss, a wrong name in `buffers.data`).

### 2. Buffer slot and its generations

**Owner.** `bufferFrames`, `bufferSampleRates`, `slotChanges`, `bufferLoads`, `loadsSuperseded`, `announced`, `gains` (`StrataBuffers.sc:37-51`). Transitions: `loadSlot` :275, `applyLoad` :339, `rejectLoad` :404, `afterSlotFade` :424, `slotChanged` :440, `clearSlot` :450, `bufferChanged` :210.

**Real states.**
- empty
- audio
- one or more long checks pending (the slot unchanged)
- fading to a load
- zeroed and reading
- read, peaks pending: the file's rate with 0 frames, the documented exception to "an empty slot is at the server's rate" (`buffers.md:8`)
- fading to a clear

**Outside writers.** Record: `StrataRecord.sc:458, 550, 655`. Readers: files, onsets, lifecycle (`slotLengthPairs`), waveform.

**How it is guarded.** The generation at every deferred step (`StrataBuffers.sc:371, 378, 427`; `StrataWaveform.sc:77, 318, 355`; `StrataOnsets.sc:112`). The check covers interleavings by example (30 named cases, plus older unnamed ones).

**History.** 69d09b75 (3.0), then 37e88500, 7327529a (fade before zero), 3ff9a46b and 73541d0d and 6177c537 (#5), 601c260c (long files), #375, #456, 381019bf, b51ec9ea (#578).

A stop that keeps a take bumps the counter and re-keys the take (`StrataRecord.sc:703-704`). `writeSlotPeaks` therefore needs a `current` function for arming (`StrataWaveform.sc:76`). That is the sign that one counter serves two meanings: "anything changed" and "this operation's token".

**What the player sees.** A long load shows `...`; a superseded load is silent.

**Hypothesis: (a).** A state by event table in buffers.md, with the three counters named by role, plus the invariant sweep. One small explicit step is worth considering: have `applyLoad` pass the file's rate to the peaks write rather than set `bufferSampleRates` early. That removes the "file's rate, 0 frames" state and one of #374's two guards. It changes a signature, not behavior. Bug count 8, radius high, confidence high.

### 3. File write and the mover

**Owner.** `writeSlot` (`StrataFiles.sc:268-373`): server write, interleaving, waiting on an older rename, handed off, reported; or abandoned; or failed. The mover Event is `alive, exited, freed, pending, pid, file` (`StrataWaveform.sc:144`). Each rename moves through queued, acknowledged or failed, or timed out to a subprocess with a slow poll (`:221-258`).

**How it is guarded.** `writeGenerations[path] == generation`, `pathRenames`, the `reported` and `finished` flags, and fault hooks. The check is thorough by case (`files.md:31`, `waveform.md:60`).

**History.** Every bug was "report exactly once" or "renames land in order": 967949f0, #127, f0d998c9, fd73492b, 14b3ae62, 3c30c513, 0635a8dd, 1fa66ffe, 335bea95, #312.

**What the player sees.** `saving`, then `saved` or `save failed`. Nothing if the engine is freed mid-save.

**Hypothesis: (a).** One table each in files.md and waveform.md. The code is local and fault-injected; a rewrite risks the once-only reports for no player gain. Confidence medium.

### 4. Engine LFO node place

**Owner.** `areaState[\modulation][\lfos][n]` (`StrataModulation.sc:109`). Transitions: `setFastLfo` :377, `stopFastLfo` :421, `syncFastLfo` :433, `fastLfoEnded` :351, `startFastLfo` :309.

**Real states.**
- none
- running (fresh)
- releasing (`running` false, `released` true)
- re-gated (`running` and `released` both true; the node may already be dead on the server)

`released` is a one-way latch for "liveness uncertain", cleared only by a fresh node (:319).

| Event | none | running | releasing | re-gated |
|---|---|---|---|---|
| set, same shape | new node | set | re-gate, to re-gated | set |
| set, new shape | new node | `Synth.replace` | free and new in one bundle, to running | the same |
| stop | no-op | releasing | no-op | releasing |
| node end | n/a | restart at the anchor | none; zero the channel | restart at the anchor |

**How it is guarded.** A 20 Hz command series for 2 s asserting one node at each step (`modulation.scd:567`), plus three held-interpreter race cases (:629, :865, :913).

**History.** fa1be4c6, then 12872c74 (`Synth.replace` on a dead node left the LFO silent) and 9e310f5a (#611, the phase lost on restart).

**Hypothesis: (a).** Put the table above in modulation.md. The series test already checks an invariant at every step. Confidence high.

Envelope routes (`StrataEnvelopes.sc:108-155`) and scatter (`StrataModulation.sc:456-504`) are the same pattern without replace; no lifecycle bugs. (d), pointing at the LFO table.

### 5. Effect bypass

**Owner.** `bypassed`, `pendingFrees` (a token), `synths[key]` (`StrataEffects.sc:53-55`). One method, `setEffectBypass` :440.

| State | `bypassed` | token | node |
|---|---|---|---|
| running | false | none | yes |
| fading | true | set | yes |
| freed | true | none | none |

Bypass moves running to fading. A lift moves fading to running (the token dropped, the level restored) and freed to running (a new node in place with `fadeIn` 1). The timer moves fading to freed when its token still matches. No other area reads the state (grep).

**How it is guarded.** Toggling at 20 Hz and 15 Hz, a lift inside the fade, and the late-handler timing (`effects.md:53`).

**History.** 0ea24cd5; #308 (a click at the lift); f828bb03.

**Hypothesis: (a).** The three-row table in effects.md. Already one method; (b) would add a fourth record. Confidence high.

### 6. Delay freeze and clear

The states are in the graph (`hold`, the `Trig1` window, the `Gate` on time; `StrataDelay.sc:125-141`). sclang keeps only `controls[\frozen]`.

**Freeze sent while bypassed.** It is kept (`StrataDelay.sc:164-169`). During the fade it is set on the dying node; after the free it is only kept.

**A lift with kept `frozen` 1.** `startDelay` passes it (:188). `hold` starts at 1, so the input is closed on a zeroed line and the delay is silent until a release. `Gate.kr` starts at level 0 and never opens (`~/src/supercollider/server/plugins/TriggerUGens.cpp:1057-1075`), so the held time is 0, not the kept time. On release the time glides up from 0 over the 0.1 s lag. Inferred from the source, not run. The delay check asserts the control is kept, not what the node plays.

**A lift while Lua shows frozen but the engine's kept value is 0.** A live, unfrozen delay with the screen saying frozen. The engine reports neither case.

**Other gaps.** A delay frozen then cleared stays frozen on silence (`delay.md:22`). A time lengthened inside a clear window brings back old audio (`delay.md:10`).

**History.** 4b251ce8; a20e29ce (a step at the clear's end).

**Hypothesis: (a).** A four-row table of freeze by bypass in delay.md, saying which side owns each guard, before #819's reverb freeze adds a second copy of the coupling.

### 7. Onset analysis

Counted, server write, chunk loop, file, rename, report (`StrataOnsets.sc:88-127`). Guarded by `slotChanges` and `stopped` at every step, with a `try`.

A newer analysis does not cancel an older one (`onsets.md:39`). Six commands make six passes, six pairs of float temporaries (115 MB a pass at 300 s) and six reports. One more inferred edge: a pass that hands off its rename, then finds the slot changed, deletes the path (`:265`). With a stuck mover that could delete a newer pass's file.

**Hypothesis: (d)**, plus one guard: add `analyses[index] == count` to `current` (`:112`), so an older pass stops at its next chunk and reports failed. Lua already acts on the newest only. About 1 s of check time.

### 8. Tuning set

`pending` is nil or `(count, period, tones, received)` (`StrataScale.sc:216`). A valid `setTuning` replaces it; an invalid one leaves an older set in place (:208-215). The last tone validates and commits, or drops the set (:239-250). `tuning.scd` covers broken sets well.

The gap is open loop. Lua validates in doubles and records `engine_text` on send (`lib/tuning.lua:304-308`); the engine sees float32. Tones 100.0000001 and 100.0000002 arrive equal, and 1199.99999 arrives as 1200.0 (checked in Python), so the engine keeps the old tuning with one console line while Lua believes the new one. Inferred, not run. **(d)** in the engine; the fix belongs in Lua's validation.

### 9. Poll numbering

Count the command first, name the number in the report, act in Lua only on a match. `bufferLoads`, `bufferSaves`, `recordCounts`, `analyses` and freeze's `ended` all follow it, with one table (`buffers.md:26-33`) and a docs test tying the packing to the decoders (#459). It fixed #5, #127, #578, #312 and #858. This is the pattern to copy; the tuning set and the modulation commands lack it.

### 10. Performance tier

One decision at alloc (`StrataPerformance.sc:62-82`), no lifecycle. Its bugs (#153, #493, #500) were about the two languages reading one file alike. **(d).**

### Which machines have a table

- Has one: recording (`record.md:60-74`, commands by coarse phase) and the polls' encodings (`buffers.md:26`).
- Has none: the slot, the file write, the mover, the bypass, the LFO, route and scatter places, freeze by bypass, the tuning set and the onset pass. Their notes hold key tables and prose rules.

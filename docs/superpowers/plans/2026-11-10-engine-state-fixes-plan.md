# Engine State Fixes and CI Timeouts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four engine findings of the state machine audit (#259 to #262) and give every CI job a timeout (#225).

**Architecture:** Each engine fix is a few lines in one area, proved by a check in that area's `test/engine_check/<area>.scd`. The freeze fix gives the freeze area one function that says what a ring grain synth reads; the start, the re-gate and the pointing at a copy all use it. The CI fix is `timeout-minutes` on each job, pinned by a docs test.

**Tech Stack:** SuperCollider (sclang 3.13 on norns and CI, 3.14 locally) through `test/run_engine_check.sh` and `test/run_engine_check_313.sh` (Docker); Lua 5.3 and LuaJIT for the suite (`lua test/run.lua`, `luajit test/run.lua`, `lua test/sync_check.lua`).

**Spec:** GitHub issues #259, #260, #261, #262 and #225. Read the task's issue before starting it (`gh issue view <n>`). This plan follows `docs/superpowers/plans/2026-11-10-state-machine-fixes-plan.md`, which left the four engine issues out.

## Global Constraints

- **No interface change.** No engine command, signature or poll changes, no SynthDef control, bus or buffer changes, no file under `lib/` other than the `lib/engine/` files a task lists. AGENTS.md's command table is untouched. `lib/Engine_Strata.sc` is never edited; extension files add methods only, never variables.
- **AGENTS.md's engine invariants hold**, in particular: messages to synths that can end on their own go through `sendToSynth`; replace, never stack; freeze changes a voice's ring writer only with `run` or `Synth.replace`; history is 0 inside a frozen input copy; a source switch unfreezes first; every delayed step of a recording runs only if `slotChanges` is unchanged.
- **Red, then green, in the engine check.** Add the task's checks, run its area, see them fail for the reason the task names, implement, see the area pass: `STRATA_ENGINE_CHECK_AREAS=<area> STRATA_SC_PORT=<port> test/run_engine_check.sh`. Then every area on the same port (`STRATA_SC_PORT=<port> test/run_engine_check.sh`), then the task's areas on SuperCollider 3.13: `STRATA_ENGINE_CHECK_AREAS=<areas> test/run_engine_check_313.sh -n 3` (three passes of three).
- **Ports:** Task 1 uses `STRATA_SC_PORT=57210`, Task 2 `57230`, Task 3 `57250`. Never 57110 to 57130.
- **The Lua suite passes** on every task: `lua test/run.lua`, `luajit test/run.lua`, `lua test/sync_check.lua`.
- **Docs in the same change:** the area's notes file (`docs/notes/engine/<area>.md`; a new rule goes in its "Must not break" list) and a changelog fragment `changes/<branch-with-dashes>.md`. Never CHANGELOG.md, never `docs/status.md`.
- **One pull request per task**, its body starting `Fixes #<n>.`; rebase, never merge main in; US English; never name the maintainer.

## Review Focus

1. **A frozen input voice restarted while its copy is still waiting for its fade:** the new grain synth reads the input ring at the voice's history, and the copy at history 0 once it lands. Task 3, check (e).
2. **A frozen input voice whose source changed while it was stopped:** the grain synth `voiceOn` starts reads the new source and is never counted as a reader of the copy. Task 3, check (f).
3. **A voice unfrozen after a restart:** the restarted grain synth goes back to the input ring at the kept history. Task 3, check (d).
4. **`stopRecord` sent twice on an armed take:** the second is a no-op, the slot changes once and no awaited frame count is left. Task 2, check (c).
5. **A voice index that is not an integer** (1.5): ignored like one out of range. Task 1's check.

## Decisions

- **No `docs/status.md` line for this plan.** It lands in the session that writes it, and the first plan's last task removes the neighboring bullet. Cost if wrong: an interrupted session leaves the plan file with no pointer; the five open issues still name the work.
- **CI timeouts:** `lua` 15 minutes (the issue's figure; it runs in about 3), `engine-shard` 15 (its check stops at 600 s, setup takes about 1 minute), `engine` 5 (it runs one shell test). Cost if wrong: a slow runner fails a job that would have passed; rerun it.
- **Left as it is:** a source changed while a frozen voice is stopped leaves the engine's freeze state on the old source until Lua's resend of `freeze` after `voiceOn` (a few milliseconds of the held ring). #259 names three gaps; this is not one of them.

---

### Task 1: voiceOff and retrigger check their voice index (#262)

**Files:**
- Modify: `lib/engine/StrataVoices.sc` (the `retrigger` and `voiceOff` commands)
- Modify: `docs/notes/engine/voices.md`
- Test: `test/engine_check/voices.scd`
- Create: `changes/fix-262-voice-index-check.md`

**Interfaces:**
- Consumes: `validVoice(voice)` (`lib/engine/StrataUtil.sc`): true for an integer in 0..`numVoices` - 1.
- Produces: nothing new.

Branch `fix/262-voice-index-check`. Area `voices`, port 57210.

- [ ] **Step 1: Add the check**, at the end of `test/engine_check/voices.scd`, before `h.stopAllVoices`:

```supercollider
// an index outside the voices, or not an integer, is ignored (#262)
// for each of [-1, engine.numVoices, 99, 1.5]: command.(\voiceOff, index) and
// command.(\retrigger, index, 1.0), each inside a try that counts what it raises
// before and after: synthNames.(context.xg).size, engine.synths.size
check.((raised == 0) and: { before == after } and: { engine.releasingSynths.size == engine.numVoices },
    "voiceOff and retrigger ignore a voice index outside the voices (% raised)".format(raised));
```

- [ ] **Step 2: Run the area and see it fail.** `voiceOff` raises for every index (`releaseVoice` indexes `releasingSynths` with it), so `raised` is 4.
- [ ] **Step 3: Check the index in both commands:** `var voice = msg[1]; if (this.validVoice(voice)) { ... }` around each body, as `setGrainParam` does.
- [ ] **Step 4: Run the area, every area, then `voices` on 3.13.**
- [ ] **Step 5: Notes and fragment.** `docs/notes/engine/voices.md`: every voice command checks its index with `validVoice` and ignores any other. The fragment: one `### Fixed` bullet.
- [ ] **Step 6: Commit:** `fix(engine): voiceOff and retrigger ignore a voice index outside the voices (#262)`.

---

### Task 2: a stopped unarmed take leaves no awaited frame count (#261)

**Files:**
- Modify: `lib/engine/StrataRecord.sc` (`stopRecording`)
- Modify: `docs/notes/engine/record.md`
- Test: `test/engine_check/record.scd`
- Create: `changes/fix-261-stop-replies.md`

**Interfaces:**
- Consumes: `stopReplies[index]` (the slot change whose frame count a stopped replace take still awaits), `take[\change]`, `slotRecording(index)`.
- Produces: nothing new.

Branch `fix/261-stop-replies`. Area `record`, port 57230. The path: `stopRecordSlot` sets `stopReplies[index]` for a replace take that was sent but has not armed, and its routine then calls `stopRecording`, which forgets the take; `recordSynthFreed` returns before the line that clears `stopReplies`.

- [ ] **Step 1: Add the checks** in `test/engine_check/record.scd`:

```supercollider
// (a) in "record: an armed recording stopped before it starts keeps nothing",
//     add to its condition:
//       engine.stopReplies[1].isNil and: { engine.slotRecording(1).not }
// (b)
test.("record: a bad load after an armed take was stopped cancels nothing", {
    // reset.(1); record.(1, 0.3, 1.0, 0, 0, 0.9); settle.(0.1); stopRecord 1; settle.(0.1)
    // changes = engine.slotChanges[1]; start = nowReports.value
    // h.command(\loadBuffer, 1, <a path with no file>, 0); settle.(0.1)
    // check: engine.slotChanges[1] == changes, and reportsFor.(1, start) is empty
});
// (c) Review Focus 4
test.("record: a second stopRecord on an armed take changes nothing", {
    // reset.(1); record.(1, 0.3, 1.0, 0, 0, 0.9); settle.(0.1)
    // changes = engine.slotChanges[1]; stopRecord 1; stopRecord 1; settle.(0.1)
    // check: engine.slotChanges[1] == (changes + 1), engine.stopReplies[1].isNil,
    //        engine.recordSynths[1].isNil, engine.bufferFrames[1] == 0
});
```

- [ ] **Step 2: Run the area and see (a), (b) and (c) fail:** `stopReplies[1]` still holds the stop's change, so `slotRecording(1)` is true and the bad load cancels a recording that is not there (a canceled report, one more slot change).
- [ ] **Step 3: Clear it where the take is forgotten.** In `stopRecording`, inside `if (take.notNil)`: `if (stopReplies[index] == take[\change]) { stopReplies[index] = nil }`.
- [ ] **Step 4: Run the area, every area, then `record` on 3.13.**
- [ ] **Step 5: Notes and fragment.** `docs/notes/engine/record.md`: `stopReplies` is set only while a stopped replace take's frame count is awaited, and cleared by the reply, by the next slot change or where the take is forgotten. The fragment: one `### Fixed` bullet (a failed load after stopping an armed recording no longer reports a recording canceled).
- [ ] **Step 6: Commit:** `fix(engine): a stopped unarmed take leaves no awaited frame count behind (#261)`.

---

### Task 3: one function says what a ring grain synth reads (#259, #260)

**Files:**
- Modify: `lib/engine/StrataFreeze.sc` (`freezeVoice`, `pointAtVoiceRing`, four new methods)
- Modify: `lib/engine/StrataLifecycle.sc` (`grainControlPairs`, `startGrainSynth`, `ringPairs`, `watchVoiceSynth`)
- Modify: `docs/notes/engine/freeze.md`, `docs/notes/engine/lifecycle.md`
- Test: `test/engine_check/freeze.scd`
- Create: `changes/fix-259-freeze-grain-read.md`

**Interfaces:**
- Consumes: `areaState[\freeze]` (`\frozen`, `\source`, `\copied`, `\inputReaders`), `ringBuffersFor(voice, source)`, `grainControls[voice][\history]`, `grainSource[voice]`, `inputSource`.
- Produces, in `lib/engine/StrataFreeze.sc`:
  - `readsInputCopy { arg voice; }` returns a Boolean: `grainSource[voice]` is the input, the voice is frozen, `state[\source][voice]` is the input and `state[\copied][voice]`.
  - `grainReadPairs { arg voice; }` returns `\strataGrainRing` control pairs, `[\bufL, bufnum, \bufR, bufnum, \phaseBus, index, \history, seconds]`: the synth source reads the voice's ring at history 0; the input source reads the input ring at `grainControls[voice][\history] ? 0`, or, when `readsInputCopy(voice)`, the voice's ring at history 0; a buffer source gives `[]`.
  - `noteInputReader { arg voice, synth; }`: when `readsInputCopy(voice)`, `inputReaders[synth] = (voice: voice, until: nil)`.
  - `forgetInputReader { arg synth; }`: removes `synth` from `inputReaders`.

Branch `fix/259-freeze-grain-read`. Areas `freeze`, `lifecycle`, `rings`, `grains`, `positions` and `memory`; port 57250. Two commits: #259, then #260.

Today `startGrainSynth` and `gateVoice` decide what a grain synth reads from `grainSource` alone, `pointAtVoiceRing` from the freeze state, and Lua's resend of `freeze` after `voiceOn` reconciles them. The checks below send **no** resend after `voiceOn` unless they say so.

- [ ] **Step 1: Add the checks for #259** in `test/engine_check/freeze.scd`. (a) to (f) go in the input voice's section (voice index 3, on the input at history 2, frozen with its copy in: `state[\copied][3]`); (h) goes in the high engine's section, where a mode change while frozen is already checked. `live` is `engine.synths[\grain3]`, `voiceRing.(3)` and `inputRing` as the file defines them.

```supercollider
// (a) "a re-gated grain synth of a frozen input voice keeps reading the copy at history 0"
//     voiceOff 3, then voiceOn 3 at once (its grain synth still releasing: the same node)
//     getControl.(live, \history) == 0, getControl.(live, \bufL) == voiceRing.(3)[0].bufnum
// (b) "a frozen input voice's new grain synth reads the copy"
//     voiceOff 3; wait until its grain synth has freed; voiceOn 3 (another node)
//     bufL == voiceRing.(3)[0].bufnum, phaseBus == rings[\phaseBuses][3].index, history == 0,
//     freeze == 1, state[\inputReaders][live] is there with until nil
// (c) "a grain synth restarted by a late gate on a frozen input voice reads the copy"
//     free the live grain synth on the server (as lifecycle.scd's late gate check does);
//     wait until engine.synths[\grain3] is another node: the same five assertions as (b)
// (d) "an unfreeze reaches a restarted reader" (Review Focus 3)
//     after (c): setGrainParam 3 freeze 0
//     bufL == inputRing[0].bufnum, history == 2
// (e) "a restart inside a copy's wait reads the input ring, then the copy" (Review Focus 1)
//     with a fading reader of the voice ring so the copy waits (as "The fade before a copy" does):
//     freeze, then restart the live grain synth as in (c) inside the wait
//     at once: bufL == inputRing[0].bufnum, history == 2
//     after the wait: bufL == voiceRing.(3)[0].bufnum, history == 0
// (f) "a source changed while a frozen input voice was stopped starts on the new source" (Review Focus 2)
//     frozen with its copy in; voiceOff 3; setGrainSource 3 1; wait until the grain synth has freed; voiceOn 3
//     live.defName == \strataGrainBuf, state[\inputReaders][live].isNil
// (h) "a freezeMode change keeps a frozen voice's freeze control" (the high engine, `other`)
//     voice 0 frozen spectral; setGrainParam 0 freezeMode 0
//     other.grainControls[0][\freeze] == 1
```

- [ ] **Step 2: Run `freeze` and see them fail:** (a) history reads 2; (b), (c) `bufL` is the input ring's; (h) the kept control is 0. (d), (e) and (f) may pass before the change (a restarted synth never left the input ring): they pin what the change must keep, so say in the report which did.
- [ ] **Step 3: Implement #259.**
  - `lib/engine/StrataFreeze.sc`: add `readsInputCopy`, `grainReadPairs` and `noteInputReader`. `freezeVoice` sets `grainControls[voice][\freeze] = 1` where it sets `state[\frozen][voice] = true`. `pointAtVoiceRing` sends `grainReadPairs(voice)` and calls `noteInputReader(voice, synth)`; its guard is unchanged.
  - `lib/engine/StrataLifecycle.sc`: `grainControlPairs` ends with `pairs ++ this.grainReadPairs(voice)` in place of the synth source's `[\history, 0]` (last, so they win over the kept history). `startGrainSynth` no longer adds `ringPairs(voice)` (the control pairs carry the ring) and calls `this.noteInputReader(voice, synth)` where it sets `ringReaders[synth]`. `ringPairs` goes (Step 0: no other caller).
  - `returnToInputRing` keeps its own pairs: it sets back synths the voice may no longer own (a source switch calls it with `grainSource` already changed).
- [ ] **Step 4: Run `freeze`, `lifecycle`, `rings`, `grains`, `positions` and `memory`; all pass.**
- [ ] **Step 5: Commit:** `fix(engine): one function says what a ring grain synth reads, for the start, the re-gate and a freeze (#259)`.
- [ ] **Step 6: Add the check for #260:**

```supercollider
// (g) "inputReaders forgets a reader that frees"
//     frozen with its copy in; three times: voiceOff 3; wait until its grain synth has freed;
//     voiceOn 3; setGrainParam 3 freeze 1
//     state[\inputReaders].size == 1, and its key is engine.synths[\grain3]
```

- [ ] **Step 7: Run `freeze` and see (g) fail:** four entries, three of them freed synths.
- [ ] **Step 8: Implement #260.** Add `forgetInputReader`; `watchVoiceSynth`'s `onFree` calls it beside `this.ringReaders.removeAt(synth)`.
- [ ] **Step 9: Run the six areas, every area, then the six on 3.13.**
- [ ] **Step 10: Notes and fragment.** `docs/notes/engine/freeze.md`: "Must not break" gains "what a ring grain synth reads is `grainReadPairs`' answer: the start, the re-gate and `pointAtVoiceRing` all send it, never pairs of their own" and "`inputReaders` holds only playing synths"; the state table's `\inputReaders` row and the kept `freeze` control (1 while frozen, 0 after an unfreeze) follow. `docs/notes/engine/lifecycle.md`: `grainControlPairs` carries the ring and its history; `ringPairs` is gone. The fragment: `### Fixed` bullets for a player (a frozen input voice restarted, or re-gated inside its release, keeps playing its frozen audio from the first grain).
- [ ] **Step 11: Commit:** `fix(engine): inputReaders forgets a reader when it frees (#260)`.

---

### Task 4: every CI job has a timeout (#225)

**Files:**
- Modify: `.github/workflows/test.yml`
- Test: `test/unit/docs_test.lua` (beside "CI's engine shards run every engine check area exactly once")
- Create: `changes/ci-225-job-timeouts.md`

**Interfaces:** none.

Branch `ci/225-job-timeouts`. Lua only: no engine check run.

- [ ] **Step 1: Write the failing test:**

```lua
test("every CI job has a timeout", function()
  -- read .github/workflows/test.yml; for each job under `jobs:` (lua, engine-shard, engine),
  -- its `timeout-minutes:` at the job's own indent:
  --   lua -> 15, engine-shard -> 15, engine -> 5
  -- every job found has one (a job added later without a timeout fails here)
  -- the shard's covers its check: the `timeout <seconds>` of its "Engine check" step
  --   (600) plus 180 s of setup is at most timeout-minutes * 60
end)
```

- [ ] **Step 2: Run `lua test/run.lua docs` and see it fail:** no job has `timeout-minutes`.
- [ ] **Step 3: Add `timeout-minutes`** to the three jobs (15, 15, 5), each with a one-line comment saying what it covers (GitHub's default is 360 minutes).
- [ ] **Step 4: Run all three Lua checks; all pass.**
- [ ] **Step 5: Fragment:** `### Changed`, one bullet starting `Development:`.
- [ ] **Step 6: Commit:** `ci: every job has a timeout (#225)`.

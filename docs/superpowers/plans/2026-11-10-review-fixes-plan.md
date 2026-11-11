# Whole-Project Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every finding of the whole-project code review run before 3.3.0 (GitHub issues #300 to #535, label `whole-project-review`, 236 in all), so that 3.3.0 ships with none open.

**Architecture:** No redesign. Each task is one pull request that fixes a set of issues in files it alone owns (packages are drawn by file ownership, from AGENTS.md's module table), so tasks run in parallel and land one at a time. Every finding gets its failing test or check first; a finding that cannot be made to fail is closed with the reason. Wave 0 lands the two security fixes and the critical findings; later waves fix the rest, area by area.

**Tech Stack:** Lua 5.3 and LuaJIT against `test/norns_stubs.lua` (`lua test/run.lua`, `luajit test/run.lua`, `lua test/sync_check.lua`); SuperCollider 3.14.1 and 3.13 (Docker) for the engine check (`test/run_engine_check.sh`, `test/run_engine_check_313.sh`).

**Spec:** the GitHub issues each task names, read whole with their comments (`gh issue view <n> --comments`): the problem, how it shows, the direction of the fix, the "Also reported by" duplicates, and, for 27 of them, a fix design posted as a comment (the design, then its prototype diff). **Where a design comment and the issue's own direction differ, the design wins; where this plan and either differ, this plan wins.** The review's files are in the main checkout's `.superpowers/sdd/2026-11-10-whole-project-review/` (`issues.md`; `seats/<seat>/findings.json`; the designs in `seats/F1/`, `seats/F2/`, `seats/F3/`). A prototype diff is a reference, never a patch to apply: the worker writes the failing test first, then the fix.

## Global Constraints

- Everything in AGENTS.md applies, and `docs/process/agents.md` for the roles, briefs, reports, reviews and merging.
- **Every issue a task names is fixed in that task**, or, if its failing test cannot be written (the defect cannot be shown), reported with the reason so the controller closes it with that reason. A finding is never deferred, and none is folded silently into another task.
- **Failing test first** (`superpowers:test-driven-development`): each issue's test or engine check fails on `main` for the reason the issue names, then passes. A test-gap finding is fixed by the test it names, which must catch the mutation it names. A docs finding is fixed against the code (the code wins unless the task says the code is wrong).
- **Saved data:** scenes stay version 4, `buffers.data` version 2, PSETs load unchanged, unless a task says otherwise.
- **The engine command interface** (AGENTS.md's table and poll descriptions) is unchanged unless a task says otherwise; a task that changes it updates the table in the same commit.
- **3.3's sound and controls by default:** a change a player can hear or see is one a task names, or one the issue's fix necessarily makes (the report names it).
- **Names the tests read stay:** every field of `S` and `S.constants` that a test reaches through `local_value` or `find_upvalue` keeps its name and meaning unless the task says otherwise.
- **Locals:** 30 free locals in each file's main chunk and each constructor (the locals probe). New state goes in an existing table or one new table per feature.
- **Ownership:** a task edits only the files it lists, plus registration lines (AGENTS.md, Working in parallel); a test outside its list that its intended change breaks gets the minimum lines changed, listed in the report.
- **Docs in the same pull request:** the module's notes file ("Must not break" and what it owns), the `docs/user/` page for anything a player sees, AGENTS.md only for the lines the task names.
- **Engine tasks** run their own check areas while working (`STRATA_ENGINE_CHECK_AREAS`, on the task's own `STRATA_SC_PORT`, with `QT_QPA_PLATFORM=offscreen`), then every area on 3.14.1 and on 3.13 in Docker before pushing, and report #131's rate on 3.13 (passed, failed, crashed, out of how many, how many at once). A red waveform area is more likely #211 than a regression: rerun it before concluding. In sclang, keep each `try` a statement of its own (a `try` that raises inside a larger expression corrupts that expression).
- **Changelog:** each task adds `changes/<branch with / as ->.md` (`### Added` / `### Changed` / `### Fixed`); no task edits CHANGELOG.md or `docs/status.md`.
- **US English** in code, comments and docs. Docs, commits and pull requests never name the maintainer.
- **Isolation:** each dispatch names a scratch folder `scratchpad/<task>/`; a worker writes only there and in its own worktree. Deletes are `rm -rf -- "${dir:?}"` on a spelled-out path inside the worker's own folder; worktrees go only with `git worktree remove`. Never bare `git stash`.
- **After every task:** all three checks pass (`lua test/run.lua`, `luajit test/run.lua`, `lua test/sync_check.lua`). The baseline on `main` at 28d89d8 is 898 tests, 0 failures.
- **Pull requests:** the controller opens each with `Fixes #a. Fixes #b.` for every issue it closes, and lands them one at a time by rebase (`gh pr merge --rebase`) after CI is green.

## Decisions

Made by the maintainer on 2026-11-10, every one as recommended ("all as recommended"). The release copies them into `docs/decisions.md` with the cost if wrong; the numbers are the measured ones in each issue's design comment.

1. **#305, the resonant highpass:** rebuilt as input minus lowpass minus bandpass, with a rise limit of 100 octaves a second on the cutoff (option (a) of the design). If wrong: one number (`cutoffRiseRate`) for (b), or the complement dropped for (c).
2. **#306, the master pitch shifter:** window 0.01 s and dispersion 0, the level taken as it comes (option (a)); the changelog lists it under sound changes (brighter and louder: +4.4 dB above 1 kHz, +1.4 to +3.7 dB RMS). If wrong: a master trim, option (b).
3. **#314, the Pulse `res`:** turned around in the engine (0.1 flat to 1 sharpest; the default 0.3 becomes 0.8), scenes migrated to format 5 and PSETs mirrored on read through a hidden format param, so saved sounds stay the same (option (1)). This task is the one exception to "scenes stay version 4". If wrong: a relabel to `rq` with a second migration.
4. **#494 and #495, the input freeze's copy:** a copy ring of its own per voice (+10.8 MB of ordinary RAM on both tiers; the high tier's step-down thresholds move up by 10,500 kB), option A. If wrong: option B's policing, with the rings freed.
5. **#301 and #328, SETUP's load scenes:** asks for a second K3 only when a scene captured in this session is not in the file (`K3 again: drop unsaved`, 2 s), option (a).
6. **#327, when the data files are written:** `scenes.data` at every scene save and `buffers.data` whenever a slot's remembered path or start changes, skipped when the file already holds the same bytes.
7. **#321, a capped synced take:** the whole beats that fit (a whole slot only when not one beat fits, shown `<1b max`), option (a); the release lists it under the 3.3 design's deviations.
8. **#303, the scene sequencer's light at 10:** the code is fixed to light the scene the running sequencer recalls next, as the changelog and the user pages say.
9. **#323, the 8x16 layout:** a rotation setting per grid port on SETUP, kept in the data folder, that calls norns' `Grid:rotation` and forgets the port's state; the docs say how to choose it.
10. **#333, MIDI ports:** all of norns' ports (`#midi.vports`, 16) can be chosen.
11. **#302, README's install routes:** `;install <the repository's URL>` in maiden's REPL, or `git clone` into `~/dust/code`, then SYSTEM > RESTART; no catalog route (a norns-community submission is the maintainer's to make).
12. **#442 and #443, the 256's scenes page and row 15:** page 3 gets rows 8 (play and tempo) and 16 (lock, hold, copy and paste) as the other pages have; row 15's clear and randomize keys light at 2 and act only after the scene save's half-second hold (lit 15 while pending).
13. **No decision needed, going ahead as designed:** #309 (a 15 Hz highpass inside the FM and Ring voices), #308 (a node a bypass lift creates fades its input in over 50 ms), #325 (Lua sends the source and every grain value before `voiceOn`).

## Review Focus

Wave 0's, most likely to bite a player first. Each line's test is in the task named.

1. **A norns delivers every poll value as a float** (matron's `lua_pushnumber`): a slot index used as a table key or in a param id must be floored, in every decoder. Test in Task 3 (the stubs fire floats, so every existing poll test runs the device's path).
2. **A data file that is not what `tab.save` writes** (hand-edited, truncated, from another program, or hostile): it never runs, never hangs start-up, and is kept as a backup. Test in Task 2 (`decode never runs the file: code, a loop and a truncated file are unreadable`).
3. **A sample folder whose name holds shell syntax** (a quote, `$`, a backtick, `;`): it lists its files and runs nothing. Test in Task 1.
4. **A card that fills during the engine's start:** the engine still loads, runs standard, and leaves no `.part`. Test in Task 4.
5. **A folder that cannot be listed** (missing, or not readable): it says so rather than claiming it holds no files. Test in Task 1.

Waves 1 to 4's:

6. **A card that fills while playing**, now that every scene save writes `scenes.data`: the write fails, the previous file stays byte for byte, SETUP flashes the failure, and a later load asks before it would drop the unsaved scene. Tests in Task 5 (#301's design).
7. **A scene or PSET saved by a 3.3 development build** (format 4, Pulse res with the old meaning): it loads sounding the same, shows the mirrored value, and saves as format 5. Tests in Task 12.
8. **The PARAMS menu with K3 held** turns a number param by 1/20: every number param of Strata's still holds a whole number, and `midi_device` never raises. Test in Task 22 (#534).
9. **The standard tier with every freeze in use** after the copy rings: the memory check's worst cases still leave the free real-time memory AGENTS.md requires, and the ordinary-RAM total stays inside the tier. Check in Task 11.
10. **An external clock that starts and stops** (MIDI or Link transport): the pattern clock follows it and a held step never sticks. Test in Task 21 (#530).

---

## Wave 0: security and critical fixes

Four tasks, file-disjoint except `lib/buffers.lua` (Task 2 edits `restore_buffers_from_file`, Task 3 the `buffer slots` invariant: different functions, so whichever lands second rebases). They run in parallel. Each task's spec is its issue's design comment, which gives the change, the tests and the docs; the brief adds the branch, the ownership and the commit.

**Every task's steps** are the same six, so each task lists only what differs:

- [ ] **Step 1:** write the failing tests (or engine check) the design's "Test first" names, in the files the task lists.
- [ ] **Step 2:** run them (`lua test/run.lua <filter>` on Lua 5.3; or `STRATA_ENGINE_CHECK_AREAS=<area> test/run_engine_check.sh`); expect the failure the design names.
- [ ] **Step 3:** implement the design's change in the files the task lists.
- [ ] **Step 4:** run all three checks (and for an engine task every engine area on 3.14.1 and on 3.13); expect each to pass.
- [ ] **Step 5:** docs (the notes file's "Must not break", the user page if a player sees it) and the changelog fragment.
- [ ] **Step 6:** commit with the task's message and push.

### Task 1: a sample folder reaches the shell only as one quoted word (#465)

Closes #465 (`X2-08`, also reported as `L2-05`). Spec: #465's design comment.

**Files:**
- Modify: `lib/files.lua` (`shell_quote`, `list_folder`, `sound_files`, `M.random_into`, `M.fill_empty`, the header comment)
- Test: `test/unit/files_test.lua`; `test/unit/structure_test.lua` (one test: no `util.scandir` in `strata.lua` or `lib/`)
- Docs: `docs/notes/lua/files.md`; `docs/user/pages/buffer.md` only if it lists the flashes
- Fragment: `changes/fix-465-folder-quoting.md`

**Interfaces:**
- Produces: `cannot open <folder>` (a folder that cannot be listed) apart from `no files in <folder>` (a folder with no sound file), from `random_into` and `fill_empty`.

**Tests (from the design):** `a folder named with a quote, a dollar sign, a backtick or a command lists its files and runs nothing` (the eleven folder names the design lists; no marker file exists afterward); `a folder that cannot be listed says so and loads nothing`; the structure test. Mutations they must catch: the quote replacement dropped; double quotes put back.

**Branch:** `fix/465-folder-quoting`. **Commit:** `fix(files): a sample folder reaches the shell only as one single-quoted word (#465)`.

### Task 2: the data files are parsed, never run (#464)

Closes #464 (`X2-07`). Spec: #464's design comment, landing on its own as the design's "To land this before the rest of #301" paragraph describes: `lib/data_files.lua` gets `decode`, `read` and `read_text` only (#301's task adds `encode`, `write` and the backups to the same module later).

**Files:**
- Create: `lib/data_files.lua` (S.lib name `data_files`); `test/unit/data_files_test.lua`; `docs/notes/lua/data-files.md`
- Modify: `strata.lua` (its include, a registration line); `lib/scenes.lua` (`read_scenes_file`); `lib/buffers.lua` (`restore_buffers_from_file`)
- Test: `test/unit/structure_test.lua` (no `tab.load` in `strata.lua` or `lib/`); `test/unit/scenes_test.lua`, `test/unit/buffers_test.lua` (their `raises on load` fixtures keep passing)
- Docs: `docs/notes/lua/scenes.md`, `docs/notes/lua/buffers.md` (the `tab.load` through `pcall` lines); AGENTS.md's module table (one row for `lib/data_files.lua`, its notes and its test file)
- Fragment: `changes/fix-464-parse-data-files.md`

**Interfaces:**
- Produces: `S.lib.data_files.decode(text) -> value | nil, message`; `S.lib.data_files.read(path) -> value | nil, "missing" | nil, "unreadable", why`; `S.lib.data_files.read_text(path)` (as the design gives it); the module's own constants table `DATA_FILES` (a local, exposed as `M.DATA_FILES`), holding `max_bytes` (the prototype's value). #301's task consumes all three and adds its own fields to that table.

**Tests (from the design):** `decode never runs the file: code, a loop and a truncated file are unreadable` (its eleven texts; the good file reads; no marker file afterward); every layout `tab.save` writes on Lua 5.3 and LuaJIT decodes to the same value (strings with every escape `%q` writes, `inf`/`-inf`/`nan`, shared and self-referencing tables), written by norns' own `tabutil` (`~/src/norns/lua/lib/tabutil.lua`) rather than by hand; the structure test. Mutation it must catch: `read` going back to `tab.load`.

**Branch:** `fix/464-parse-data-files`. **Commit:** `fix(data files): scenes.data and buffers.data are parsed, never run as Lua (#464)`.

### Task 3: every poll decoder floors its slot; the stubs deliver floats (#300)

Closes #300 (`X1-01`, also reported as `L2-01`). Spec: #300's design comment.

**Files:**
- Modify: `lib/record.lua` (`record_state_changed`); `lib/buffers.lua` (the `buffer slots` invariant: the two clauses the design gives); `test/norns_stubs.lua` (`poll.fire`, `util.time`, `clock.get_tempo`, `clock.get_beats` return floats)
- Test: `test/unit/record_test.lua`; `test/unit/stubs_test.lua`
- Docs: `docs/notes/lua/record.md` (Must not break: every poll decoder floors its slot, and why); `docs/notes/lua/test-harness/stubs.md` (values are floats, as matron pushes them)
- Fragment: `changes/fix-300-float-polls.md`

**Interfaces:**
- Produces: the stubs deliver every poll value, `util.time()`, `clock.get_tempo()` and `clock.get_beats()` as floats; test helpers keep passing whole numbers (`fire` converts). Every later task's poll tests run the device's path.

**Tests (from the design):** `recordState reports arrive as floats: an ended dub is take <n> on its scratch path`; the stubs test (a poll fired with `3` arrives as a float); the three existing tests the design names fail on today's code under the new stubs, on Lua 5.3. Then the sweep the issue asks for: every poll handler and every other value a norns hands the script as a float (`grep` every `polls`/`poll` callback, `util.time`, clock values, `params:get` of a number param) is checked for use as a table key, a param id or a `string.format("%d")` argument, and each one found either floors already or is fixed here with a test. The report lists each site checked. (The PARAMS menu's fractional number params are #534, another task's.)

**Branch:** `fix/300-float-polls`. **Commit:** `fix(record): a recording's end on a norns floors its slot; the stubs deliver floats (#300)`.

### Task 4: a performance file that cannot be flushed never stops the engine loading (#493)

Closes #493 (`E1-01`). Spec: #493's design comment.

**Files:**
- Modify: `lib/engine/StrataPerformance.sc` (`writeActivePerformance`, `allocPerformance`)
- Test: `test/engine_check/performance.scd` (the two cases the design gives)
- Docs: `docs/notes/engine/performance.md` (Must not break: the failed write names the flush and the read-back)
- Fragment: `changes/fix-493-performance-flush.md`

**Interfaces:** none new; the file Lua reads is unchanged.

**Tests (from the design):** `performance: a .part that cannot be flushed runs standard, leaves no .part and finishes alloc` (skipped with a line where `/dev/full` does not exist) and its `/dev/null` case. Mutations they must catch: `file.close` moved back outside the `try`; the read-back replaced by `File.exists`. Engine: the performance area on its own port while working; every area on 3.14.1 and on 3.13 before pushing.

**Branch:** `fix/493-performance-flush`. **Commit:** `fix(engine): a performance file that cannot be flushed runs standard and never stops alloc (#493)`.

---

## Waves 1 to 4: every other finding

Each task below is one pull request closing the issues it lists. Its spec is those issues, whole, with their comments (the designs named are comments on the issue); the Decisions above settle the questions they raise. Every task follows the six steps of wave 0, with **one failing test or engine check per issue** first, as the issue's direction (or its design's "Test first") names it; a test-gap issue's test must catch the mutation the issue names; a docs issue is fixed against the code, and its failing test is a docs check where AGENTS.md's docs checks can pin it (otherwise the report says why none can).

Where a task's Files list a shared file with a scope in parentheses, the task edits only that part; two tasks of one wave never edit the same part. The later of two tasks that touch one file rebases on the earlier (the controller lands them in wave order).

| Task | Wave | Starts after | Model | Port |
|---|---|---|---|---|
| 5 persistence | 1 | Tasks 2, 3 merged | opus | |
| 6 engine effects and mix | 1 | | opus | 57720 |
| 7 engine voices, lifecycle, structure | 1 | | opus | 57730 |
| 8 engine grain reads | 1 | | opus | 57740 |
| 9 record state (engine and Lua) | 1 | Task 3 merged | opus | 57750 |
| 14 LFOs | 1 | | opus | |
| 15 MIDI | 1 | | sonnet | |
| 16 arc | 1 | | sonnet | |
| 17 the 256 and the sequencer's light | 1 | | opus | |
| 19 engine check runner and CI | 1 | | sonnet | 57790 |
| 10 engine files and waveforms | 2 | Task 9 merged | opus | 57760 |
| 11 freeze, performance, memory | 2 | Tasks 4, 6, 7, 8 merged | opus | 57770 |
| 12 the Pulse res | 2 | Tasks 5, 7 merged | opus | 57780 |
| 13 Lua buffers and files | 2 | Tasks 1, 5, 9 merged | opus | |
| 20 params, state, registries | 2 | wave 1 merged | sonnet | |
| 21 engine sync and the sequencer | 2 | wave 1 merged | opus | |
| 22 scenes, mutation, variation, loops | 2 | Task 5 merged | opus | |
| 23 positions and playheads | 2 | Task 17 merged | sonnet | |
| 24 UI core | 2 | wave 1 merged | opus | |
| 25 the test harness | 2 | Task 3 merged | opus | |
| 18 the BUFFER page | 3 | Tasks 9, 13 merged | opus | |
| 26 pages and hints | 3 | wave 2 merged | sonnet | |
| 27 grid core and layouts | 3 | Tasks 17, 23 merged | opus | |
| 28 user docs and README | 4 | wave 3 merged | opus | |

### Task 5: the data files are written safely, and the screen says so (#301, #327, #328, #463, #466, #467, #518)

Spec: #301's design (it covers #327, #328, #463, #466 and #467); Decisions 5 and 6. #518: a load from disk clears `S.current_scene` unless that slot's data is unchanged, with a test.

**Files:**
- Modify: `lib/data_files.lua` (adds `encode`, `write`, the backups and the `.v<n>` copies to Task 2's module); `lib/scenes.lua` (the disk functions: reading and saving `scenes.data`, `request_load`, the load's current scene); `lib/buffers.lua` (`save_buffers_to_disk` and the remember hook that writes on a path change); `lib/pages/setup.lua` (the outcome flash, the problem list, the load prompt); `lib/params_setup.lua` (the PARAMS load scenes trigger)
- Test: `test/unit/data_files_test.lua`, `scenes_test.lua`, `buffers_test.lua`, `pages_setup_test.lua`, `structure_test.lua` (no `tab.save` in `strata.lua` or `lib/`)
- Docs: `docs/notes/lua/data-files.md`, `scenes.md`, `buffers.md`, `pages/setup.md`; `docs/user/scenes.md`, `params.md`, `pages/setup.md`; README.md (only #327's sentence); AGENTS.md (the invariant bullet the design names)

**Interfaces:** consumes `S.lib.data_files.decode/read/read_text` (Task 2). Produces `S.lib.data_files.write(path, value) -> true | false, why`, `S.lib.scenes.request_load()`, `S.scene_file.unsaved`.

**Branch:** `fix/301-safe-data-files`. **Commit:** `fix(scenes, buffers): the data files are written to a checked .part and renamed, at every change (#301)`.

### Task 6: engine effects and the mix stage (#305, #306, #308, #364, #365, #367, #460, #462)

Spec: the designs on #305 (option (a)), #306 (option (a)) and #308; `seats/F1/proposed-checks.diff` holds F1's checks as run. #306's sound change goes under the fragment's `### Changed` with the measured numbers.

**Files:**
- Modify: `lib/engine/StrataEffects.sc`, `lib/engine/StrataMix.sc`
- Test: `test/engine_check/effects.scd`, `test/engine_check/mix.scd`, `test/engine_check.scd` (only #365's lines), `test/unit/docs_test.lua` (only the defaults checks of #364 and #460)
- Docs: `docs/notes/engine/effects.md`, `mix.md`, `structure.md` (#462); `docs/user/effects.md`, `docs/user/params.md` (#306's drift text only)

**Branch:** `fix/engine-effects-mix`. **Commit:** `fix(engine): the highpass and the drift shifter stop spiking and fluttering; effects and mix checks pinned (#305, #306, #308)`.

### Task 7: engine voices, lifecycle and structure (#309, #458, #497, #498, #499, #501, #504, #505, #507, #508, #525)

Spec: #309's design (a 15 Hz highpass on the FM carrier and the Ring product before the voice bus). #499 is the one task allowed to edit `lib/Engine_Strata.sc`, and only its generic `alloc` and `free` (a rollback when an area raises in `alloc`, containment in `free`); AGENTS.md's rule otherwise stands. #458's fix rejects engine-owned controls in the engine and in the engine stub alike.

**Files:**
- Modify: `lib/engine/StrataVoiceDefs.sc` (only the FM and Ring highpass), `lib/engine/StrataVoices.sc`, `lib/engine/StrataUtil.sc`, `lib/engine/StrataLifecycle.sc`, `lib/Engine_Strata.sc` (only `alloc` and `free`), `test/norns_stubs.lua` (only the engine stub's control-name check)
- Test: `test/engine_check/voices.scd`, `lifecycle.scd`, `structure.scd` (#525); `test/unit/stubs_test.lua`
- Docs: `docs/notes/engine/voices.md`, `lifecycle.md`, `memory.md` (#497), `freeze.md` (#508's bullets), `structure.md` (#499); AGENTS.md (the `Engine_Strata.sc` sentence, if #499 changes what it may hold)

**Branch:** `fix/engine-voices-lifecycle`. **Commit:** `fix(engine): DC blocked in the FM and Ring voices; failed starts and area errors contained (#309, #499)`.

### Task 8: engine grain reads: loops, rings, variation and the head guard (#304, #307, #310, #335, #363, #366, #368, #369, #370, #371, #496, #532, #535)

Spec: the designs on #304, #307 and #310 (F2; `seats/F2/grain-reads.diff` combines them) and #363 (F1). Order inside the task: #304's commit before #363's, #307's before #535's (the designs ask for it). #307: the review's candidate fix (a head latched per block) is rejected; the design reads a shifted copy only in the wrap block. #532 is bounded in the engine (no Lua file of this task). `CHANGELOG.md`'s old sentence (#368) is left to the release task.

**Files:**
- Modify: `lib/engine/StrataGrainDefs.sc`, `StrataLoop.sc`, `StrataRings.sc`, `StrataVariation.sc`, `StrataRecord.sc` (only `slotHeadGuard` and the grain-start helpers the three designs change), `lib/params_setup.lua` (only #363's position spec, if its design needs it)
- Test: `test/engine_check/loops.scd`, `rings.scd`, `variation.scd`, `grains.scd`, `record.scd` (only #310's head-guard checks), `test/engine_check.scd` (only #307's lines)
- Docs: `docs/notes/engine/loops.md`, `rings.md`, `grains.md`, `variation.md`, `memory.md` (#370), `record.md` (#310); `docs/user/voices-and-grains.md` (#368, #369), `docs/user/sources-and-buffers.md` and `docs/user/pages/voice.md` (#335)

**Branch:** `fix/engine-grain-reads`. **Commit:** `fix(engine): grains stay inside the valid region, across a ring's wrap and at any rate (#304, #307, #310)`.

### Task 9: the record state, engine and Lua (#311, #373, #374, #376, #378, #379, #380, #455, #457, #459)

Spec: #311's design, which covers #373, #374 and #455 with the state table both sides follow. #459's test ties the three event polls' packing to Lua's decoders (`docs_test.lua` or `buffers_test.lua`, as the issue says).

**Files:**
- Modify: `lib/engine/StrataRecord.sc` (the recording's state, its delays and its reports), `lib/engine/StrataBuffers.sc` (only the load-in-flight interplay the design names), `lib/record.lua`, `lib/buffers.lua` (only the record and load branches the design names)
- Test: `test/engine_check/record.scd`, `buffers.scd`; `test/unit/record_test.lua`, `buffers_test.lua`, `docs_test.lua` (only #459's check)
- Docs: `docs/notes/engine/record.md`, `buffers.md`; `docs/notes/lua/record.md`, `buffers.md`; `docs/user/pages/buffer.md` (#373); AGENTS.md (the record lines the design changes)

**Branch:** `fix/record-state`. **Commit:** `fix(record): a load during a synced take, a canceled take and an overdub over a load follow one state table (#311)`.

### Task 10: engine files, waveforms and peaks (#312, #313, #330, #351, #375, #377, #381, #401, #456, #522, #523)

Spec: the designs on #312 (a new non-periodic poll, `takeWriteFailed`) and #313. #312 changes the engine command interface: AGENTS.md's poll descriptions gain `takeWriteFailed`, in the same commit. #456 changes the engine's rounding of a slot's seconds.

**Files:**
- Modify: `lib/engine/StrataFiles.sc`, `StrataWaveform.sc`, `StrataBuffers.sc` (#375, #456), `StrataRecord.sc` (only the scratch take's write, the overview and the peaks refresh); `lib/buffers.lua` (only the new poll's handler, #401 and #522); `lib/waveforms.lua`; `lib/playheads.lua` (only #330's containment)
- Test: `test/engine_check/files.scd`, `waveform.scd`, `buffers.scd`, `record.scd` (only these issues' checks); `test/unit/buffers_test.lua`, `waveforms_test.lua`, `playheads_test.lua`
- Docs: `docs/notes/engine/files.md`, `waveform.md`, `buffers.md` (#377); `docs/notes/lua/waveforms.md`, `buffers.md`; `docs/user/sources-and-buffers.md` (#312, #351, #522); AGENTS.md (the poll)

**Branch:** `fix/engine-files-waveforms`. **Commit:** `fix(engine): a scratch take that cannot be written is reported; overviews and peaks follow the audio (#312, #313)`.

### Task 11: freeze, performance and memory (#344, #346, #372, #494, #495, #500, #502, #503, #506, #509)

Spec: the design on #494 and #495 (one design), option A of Decision 4: a copy ring per voice; AGENTS.md's buffer-memory line gains the copy rings, and `highMemoryBytes` moves by the design's number. #372 (the crossmod, bend and accent block written seven times) is a refactor with no sound change: the engine check passes unchanged before and after it, as its own commit.

**Files:**
- Modify: `lib/engine/StrataFreeze.sc`, `StrataPerformance.sc`, `StrataRings.sc` (the copy rings' allocation), `StrataMix.sc`, `StrataGrainDefs.sc` and `StrataLifecycle.sc` (only what #495 and #372 change), `StrataVoiceDefs.sc` (only #372); `lib/performance.lua` (only #500's parser, which must stay identical to the engine's)
- Test: `test/engine_check/freeze.scd`, `performance.scd`, `memory.scd`; `test/unit/performance_test.lua`
- Docs: `docs/notes/engine/freeze.md`, `performance.md`, `memory.md`, `rings.md`; `docs/notes/lua/performance.md`; `docs/user/technical.md` (#344, #346); AGENTS.md (the buffer-memory and freeze lines)

**Branch:** `fix/engine-freeze-copy-rings`. **Commit:** `fix(engine): an input freeze's copy lives in a ring of its own, so no grain synth replays it (#494, #495)`.

### Task 12: the Pulse voice's res turns the right way (#314)

Spec: #314's design, option (1) of Decision 3: the engine mirrors the control (0.1 flat to 1 sharpest), the Lua default becomes 0.8, scenes migrate to format 5 (`SCENE_DATA_VERSION` 5, the mirror applied once as the file loads, `validate_scene` and the migration default), and a PSET saved before is mirrored after its read through a hidden format param, until it is saved again. This is the one task that changes saved data.

**Files:**
- Modify: `lib/engine/StrataVoiceDefs.sc` (only the Pulse voice); `lib/voices.lua`, `lib/constants.lua` (`SCENE_DATA_VERSION`), `lib/params_setup.lua` (the Pulse res spec and the hidden format param with its read hook), `lib/scenes.lua` (only the format 5 migration)
- Test: `test/engine_check/voices.scd` (the direction players see); `test/unit/scenes_test.lua`, `params_setup_test.lua`, `voices_test.lua`
- Docs: `docs/notes/engine/voices.md`, `docs/notes/lua/scenes.md`, `params.md`; `docs/user/params.md`, `docs/user/voices-and-grains.md`; AGENTS.md (`SCENE_DATA_VERSION (5)`)

**Branch:** `fix/314-pulse-res`. **Commit:** `fix(voices): the Pulse res raises the resonance; scenes and PSETs keep their sound (#314)`.

### Task 13: Lua buffers and files (#317, #326, #399, #400, #402, #404, #405, #436, #480, #512, #516, #524)

Spec: the designs on #317 (with #399) and #326. #402: `valid_buffer_slot` accepts `3.0` and rejects `3.5` with `slot == math.floor(slot)`, never `math.type` (#300's design). #480 makes the params stub list a file param's folder as norns does.

**Files:**
- Modify: `lib/buffers.lua` (the load, settle, restore and slot-check functions), `lib/files.lua` (#512 and #402's guard), `lib/record.lua`, `lib/waveforms.lua`, `lib/playheads.lua`, `lib/positions.lua` (only #402's slot guards and #404's rules), `lib/constants.lua` (#516), `lib/params_setup.lua` (only #524's PSET reload), `lib/pages/buffer.lua` (only #326's length and #436's name), `test/norns_stubs.lua` (only #480's file param)
- Test: `test/unit/buffers_test.lua`, `files_test.lua`, `record_test.lua`, `waveforms_test.lua`, `positions_test.lua`, `pages_buffer_test.lua`, `stubs_test.lua`
- Docs: `docs/notes/lua/buffers.md`, `files.md`, `record.md`; `docs/decisions.md` (#399's entry, only if the fix changes what it records)

**Branch:** `fix/lua-buffers-files`. **Commit:** `fix(buffers): late long loads are adopted, high-rate files start anywhere, slots are checked as whole numbers (#317, #326)`.

### Task 14: LFOs (#340, #406, #409, #415, #416, #423, #511, #517, #520, #528)

#511: the registered destinations get group starts per voice without changing any index (saved indices keep their meaning). #517: the glide clock, the LFO apply and the mutation tick get the frame clock's containment (a protected call, the traceback kept, one report per message).

**Files:**
- Modify: `lib/lfos.lua`, `lib/pages/lfo.lua`, `test/stub_lfo.lua`, `lib/positions.lua` and `lib/mutation.lua` (only #517's containment), `lib/ui/frame.lua` (only #423's animation test, if needed)
- Test: `test/unit/lfos_test.lua`, `pages_lfo_test.lua`, `positions_test.lua` and `mutation_test.lua` (only #517's)
- Docs: `docs/notes/lua/lfos.md`, `pages/lfo.md`; `docs/user/modulation.md`, `docs/user/pages/lfo.md`, `docs/user/params.md` (#528); `docs/decisions.md` (#406's entry)

**Branch:** `fix/lfos`. **Commit:** `fix(lfos): slow exponential LFOs move smoothly; the dot follows the phase and depth (#406, #409)`.

### Task 15: MIDI (#333, #407, #413, #469, #529)

Decision 10: the `midi_device` param reaches `#midi.vports`. #529: all notes off (CC 123) and all sound off (CC 120) stop the voices MIDI started.

**Files:**
- Modify: `lib/midi_in.lua`, `lib/params_setup.lua` (only the `midi_device` param)
- Test: `test/unit/midi_in_test.lua`
- Docs: `docs/notes/lua/midi.md`; `docs/user/midi.md`, `docs/user/pages/setup.md` and `docs/user/params.md` (only the MIDI lines)

**Branch:** `fix/midi`. **Commit:** `fix(midi): every norns port can be chosen; held keys survive a mode change; panic CCs stop notes (#333, #407)`.

### Task 16: arc (#355, #357, #437, #439, #440, #510, #519)

#510: a whole-step ring at its first position lights at least one LED. #519: after Strata's own deltas, send the feedback norns' `params:delta` sends to a mapped controller (confirm against `~/src/norns/lua/core/paramset.lua` first; if norns sends none, the report says so and the issue is closed with that reason).

**Files:**
- Modify: `lib/arc/core.lua`, `lib/arc/*.lua` (#439's brightness pins, #510), `lib/ui/detent.lua` and `lib/ui/params.lua` (only #519)
- Test: `test/unit/arc_core_test.lua`, `arc_pages_test.lua`, `ui_detent_test.lua` (only #519's)
- Docs: `docs/notes/lua/arc-core.md`, `arc-pages.md`; `docs/user/arc.md`, `docs/user/grid.md` (only #355's sentence)

**Branch:** `fix/arc`. **Commit:** `fix(arc): a ring's first position lights; a device with no port is ignored; brightness pinned (#437, #510)`.

### Task 17: the 256 and the scene sequencer's light (#303, #354, #359, #442, #443, #449, #454)

Decisions 8 and 12. #303: `lib/scenes.lua` gets one answer for the slot the running sequencer recalls next, and the three scene pages light it at 10; the test runs the sequencer through the clock (`context.clock.run_for` across two scene durations) and reads the LEDs.

**Files:**
- Modify: `lib/grid/layout_256.lua`; `lib/grid/layout_128h.lua` and `lib/grid/layout_128v.lua` (only the scene recall LED of #303); `lib/scenes.lua` (only the new next-slot function)
- Test: `test/unit/grid_layout_256_test.lua`, `grid_layout_128h_test.lua`, `grid_layout_128v_test.lua`, `grid_layout_64_test.lua` (#449, #454), `scenes_test.lua` (the next-slot function)
- Docs: `docs/notes/lua/grid/layout_256.md`; `docs/user/grid/256.md`, `128h.md`, `128v.md`, `docs/user/grid.md` (#354); `docs/design/3.1-design.md` is left as written (a design records what was decided)

**Branch:** `fix/grid-256-scenes`. **Commit:** `fix(grid): the next scene lights at 10; the 256's scenes page gets transport and lock; row 15 needs a hold (#303, #442, #443)`.

### Task 18: the BUFFER page (#321, #336, #431, #432, #433, #434, #435, #438)

Spec: #321's design, option (a) of Decision 7 (`take_length()` read by the recorder and the `len` field). The fragment lists #321 as a deviation from the 3.3 design.

**Files:**
- Modify: `lib/pages/buffer.lua`, `lib/record.lua` (only `take_length` and its callers), `lib/ui/frame.lua` (only #434 and #435), `lib/ui/header.lua` and `lib/files.lua` (only #432's flash text), `lib/playheads.lua` and `lib/positions.lua` (only #433's slot check), `strata.lua` (only #435's redraw path, never `init` or `cleanup`)
- Test: `test/unit/pages_buffer_test.lua`, `record_test.lua`, `ui_test.lua`
- Docs: `docs/notes/lua/pages/buffer.md`, `ui/redraws.md`; `docs/user/pages/buffer.md`, `pages/voice.md`, `params.md` and `voices-and-grains.md` (only #336's bookmark sentences); `docs/decisions.md` (#434's entry, if it changes)

**Branch:** `fix/buffer-page`. **Commit:** `fix(buffer page): a capped synced take is whole beats; bm recalls; no playhead on an empty slot (#321, #431, #433)`.

### Task 19: the engine check runner and CI (#331, #332, #345, #471, #472, #485, #486, #490, #491, #492, #533)

#533: move `actions/checkout`'s pin to the current major's latest release, by commit with its comment (`gh api repos/actions/checkout/releases/latest`). #490: the workflow gets `permissions: contents: read` and norns is pinned by its full commit. This task may edit `docs/status.md`, only the lines these issues name.

**Files:**
- Modify: `test/run_engine_check.sh`, `test/run_engine_check_313.sh`, `test/engine_check.scd` (the runner part), `test/StrataTestNoBoot.sc.in`, `.github/workflows/test.yml`, `.gitignore` (#332), `test/helpers.lua` (only #491's area order)
- Test: `test/unit/structure_test.lua` (#332, #492), `test/engine_check/structure.scd` (#492)
- Docs: `docs/notes/lua/test-harness/engine-check-runner.md`, `docs/notes/lua/test-harness.md`, `docs/notes/engine/structure.md` (#491, #492); `docs/user/technical.md` (#345); `docs/status.md`; AGENTS.md (the engine check's run time and area order sentences)

**Branch:** `fix/engine-check-runner-ci`. **Commit:** `fix(ci): an interrupted engine check leaves nothing on its port; a stray .sc fails; CI pinned and scoped (#331, #332, #490)`.

### Task 20: params, state and registries (#315, #316, #384, #385, #386, #387, #388, #389, #390, #393, #394, #396, #470)

#386 and #387: the displayed decimals and units are the params' own (no value or default changes). #470: the notes' invariants table, voice fields and registries list are brought up to the code.

**Files:**
- Modify: `lib/params_setup.lua` (the specs, the separators, the tempo handler's global), `lib/constants.lua`, `lib/voices.lua`, `lib/state.lua`, `lib/engine_sync.lua` (only #384's late registration), `lib/mutation.lua` (only #389's cached specs)
- Test: `test/unit/params_setup_test.lua`, `registries_test.lua`, `lfos_test.lua` (#316), `voices_test.lua`
- Docs: `docs/notes/lua/params.md`, `engine-sync.md` (#316), `state-and-voices.md`, `scenes.md` (#470); AGENTS.md (#470's lines)

**Branch:** `fix/params-state`. **Commit:** `fix(params): every voice param has its spec, units and decimals; late registrations refused (#315, #316, #384)`.

### Task 21: engine sync and the sequencer (#325, #382, #392, #397, #414, #418, #461, #527, #530)

Spec: #325's design (Lua sends the source and every grain value before `voiceOn`; the engine is unchanged). #530: the pattern clock follows an external clock's transport (start and stop).

**Files:**
- Modify: `lib/engine_sync.lua`, `lib/sequencer.lua`, `lib/params_setup.lua` (only #392's crossmod slots), `lib/constants.lua` (only #397's comment)
- Test: `test/unit/engine_sync_test.lua`, `sequencer_test.lua`, `structure_test.lua` (only #325's start-step lines)
- Docs: `docs/notes/lua/engine-sync.md`, `sequencer.md`, `state-and-voices.md` (#461); `docs/user/pages/seq.md` (#530)

**Branch:** `fix/engine-sync-sequencer`. **Commit:** `fix(engine sync): a started voice's first grain plays its new values; the pattern clock follows the transport (#325, #530)`.

### Task 22: scenes, mutation, variation and loops (#318, #329, #408, #410, #411, #412, #417, #513, #531, #534)

Spec: #318's design (a turn marks itself; it makes the stub's `params:delta` go through the param's own `delta`), then #534 on it (each of Strata's number params gets a `delta` that steps whole numbers, as norns' option param does). #513: the sequencer skips an empty slot at once, as the user page says.

**Files:**
- Modify: `lib/scenes.lua` (the recall, fade and sequencer functions), `lib/mutation.lua`, `lib/variation.lua`, `lib/loops.lua`, `lib/ui/detent.lua` (only #318's turn mark), `lib/params_setup.lua` (only #318's freq delta and #534's number deltas), `lib/midi_in.lua` (only #534's `midi_device` action), `test/norns_stubs.lua` (only `params:delta`)
- Test: `test/unit/scenes_test.lua`, `mutation_test.lua`, `variation_test.lua`, `loops_test.lua`, `midi_in_test.lua` (#534), `stubs_test.lua`
- Docs: `docs/notes/lua/scenes.md`, `mutation.md`, `variation.md`, `loops.md`; `docs/user/scenes.md` (#513), `docs/user/modulation.md` (#410); AGENTS.md (the loop pairs bullet, #531)

**Branch:** `fix/scenes-variation`. **Commit:** `fix(variation): a fade or a mapped CC leaves a quantized note on its tone; number params step whole (#318, #534)`.

### Task 23: positions and playheads (#322, #398, #403, #445, #515)

#515: one running glide clock reads the latest fling, with a test that counts the clocks started over a run of deltas.

**Files:**
- Modify: `lib/positions.lua`, `lib/playheads.lua`, `lib/grid/layout_128h.lua` (only #322's strip), the four layouts (only #445's strip and store), `lib/grid/layout_256.lua` (only #398's row cache)
- Test: `test/unit/positions_test.lua`, `playheads_test.lua`, `grid_layout_128h_test.lua`, `grid_layout_256_test.lua`, `grid_layout_128v_test.lua`, `grid_layout_64_test.lua` (only these issues')
- Docs: `docs/notes/lua/positions.md`, `playheads.md`, `docs/notes/lua/grid/layout_128h.md`

**Branch:** `fix/positions-playheads`. **Commit:** `fix(positions): the strips follow off-grid changes and a non-buffer voice; one glide clock (#322, #445)`.

### Task 24: the UI core (#320, #424, #425, #426, #427, #428, #429, #514)

#426 and #424 may edit `strata.lua`'s `redraw`, `key` and `enc` only (never `init` or `cleanup`). #514: `fit_text` stops when a pass removed nothing.

**Files:**
- Modify: `lib/ui/frame.lua`, `lib/ui/keys.lua`, `lib/ui/menu_watch.lua`, `lib/ui/cursors.lua`, `lib/ui/text.lua`, `lib/pages/main.lua` (only #429's dead code), `strata.lua` (only `redraw`, `key`, `enc`)
- Test: `test/unit/ui_test.lua`, `ui_detent_test.lua` (#427), `ui_layout_test.lua` (#428)
- Docs: `docs/notes/lua/ui-core.md` and `docs/notes/lua/ui/*.md`; `docs/notes/lua/pages/main.md` (#429)

**Branch:** `fix/ui-core`. **Commit:** `fix(ui): a failing animates() or draw is contained; nothing runs before init (#320, #424, #426)`.

### Task 25: the test harness (#473, #474, #475, #476, #477, #478, #479, #481, #482, #483, #484, #487, #488, #489, #521)

A stub made stricter may fail tests that relied on the looseness: each such test is fixed in the minimum lines, and a fault it finds in the script is reported (the controller files it). #479 (text widths) may move layout results: the page renders are looked at before and after.

**Files:**
- Modify: `test/norns_stubs.lua` (the screen, grid, engine, params, util, fileselect, metro and menu stubs), `test/helpers.lua`, `test/run.lua`, `test/render_pages.py` (#474)
- Test: `test/unit/stubs_test.lua`, `docs_test.lua` (#489), `structure_test.lua` (#488)
- Docs: `docs/notes/lua/test-harness.md`, `docs/notes/lua/test-harness/*.md`

**Branch:** `fix/test-harness`. **Commit:** `test(harness): the stubs refuse what norns refuses; printed errors and empty unit files fail (#473, #475, #484)`.

### Task 26: pages and hints (#319, #339, #341, #349, #352, #383, #419, #420, #421, #422, #430)

**Files:**
- Modify: `lib/pages/fx.lua`, `scenes.lua`, `setup.lua`, `voice.lua`, `main.lua`, `lfo.lua` (#422, #430), `seq.lua`; `lib/ui/field_list.lua` (#319), `lib/ui/header.lua` (#341, #349), `lib/ui/voice_rows.lua` (#352), `lib/arc/seq.lua` and `lib/params_setup.lua` (only #383's redraw)
- Test: the `test/unit/pages_<page>_test.lua` of each page changed, `ui_layout_test.lua`
- Docs: `docs/notes/lua/pages/*.md`, `docs/notes/lua/ui/layout-and-renders.md`; `docs/user/pages/*.md`, `docs/user/controls.md`, `docs/user/tips.md`, `docs/user/voices-and-grains.md` (#339), `docs/user/modulation.md` (#341)

**Branch:** `fix/pages-hints`. **Commit:** `fix(pages): hints offer only keys that act; SETUP scrolls to its last rows; lines clear their descenders (#319, #419, #422)`.

### Task 27: grid core and layouts (#323, #324, #334, #360, #361, #441, #444, #446, #447, #448, #450, #451, #452, #453, #468, #526)

Decision 9: a rotation setting per grid port on SETUP, kept in the data folder (not a param), that calls `S.grids[port]:rotation(n)` after `attach_grid` and when it changes, then forgets the port's page, held keys and layout state; the stub's grid vport gets a `rotation` that swaps cols and rows as norns' `Grid:rotation` does. #468 may edit `lib/arc/core.lua`, `lib/engine_sync.lua` and `lib/midi_in.lua` only for the cleanup of their handlers.

**Files:**
- Modify: `lib/grid/core.lua`, `lib/grid/faders.lua`, `lib/grid/layout_256.lua`, `layout_128h.lua`, `layout_128v.lua`, `layout_64.lua`, `lib/pages/setup.lua` (only the rotation rows), `lib/sequencer.lua` (only #441 and #446), `lib/playheads.lua`, `lib/positions.lua` and `lib/waveforms.lua` (only #451's constants), `lib/constants.lua` (#451, #526), `test/norns_stubs.lua` (only the grid vport's `rotation`)
- Test: `test/unit/grid_core_test.lua`, `grid_layout_*_test.lua`, `pages_setup_test.lua`
- Docs: `docs/notes/lua/grid-core.md`, `docs/notes/lua/grid/layout_*.md`, `docs/notes/lua/pages/setup.md`; `docs/user/grid.md`, `docs/user/grid/*.md`, `docs/user/pages/setup.md`, `docs/user/scenes.md` (#334)

**Branch:** `fix/grid-core-layouts`. **Commit:** `fix(grid): a 128 can be turned to the 8x16 layout; one layout's error spares the others (#323, #441)`.

### Task 28: user docs and README (#302, #337, #338, #342, #343, #347, #348, #350, #353, #356, #358, #362, #391, #395)

Decision 11 for #302. #350 brings README's version line and feature list to 3.3.0, and #391's test ties `strata.lua`'s header version to the newest version in CHANGELOG.md (written so it passes once the release task merges the fragments; until then it compares against the version the release will carry, as the issue's direction says). #342: the code's glide times are measured and the page says them.

**Files:**
- Modify: README.md; `docs/user/params.md`, `effects.md`, `technical.md` (#347), `sources-and-buffers.md` and `pages/buffer.md` (#348), `voices-and-grains.md` (#395), `grid/*.md` (#353, #356, #358, #362)
- Test: `test/unit/docs_test.lua` (README names `;install` and no catalog tab; #391's version test)
- Docs: as above

**Branch:** `docs/user-docs-readme`. **Commit:** `docs: README's install routes work; the params, grid and technical pages match the code (#302, #350)`.

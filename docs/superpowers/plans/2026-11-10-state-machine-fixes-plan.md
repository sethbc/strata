# State Machine Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the holes an audit of Strata's implicit state machines found in the Lua script (27 issues, #232-#258): a display that says one thing while the state is another, a release or cancel path that misses a holder, an optimistic write with no way back, a clock with no error containment; and make the illegal states fail in the tests from now on.

**Architecture:** No state machine is rewritten and no flag is replaced by an enum: every flag is the residue of a filed fix, and the tests read them by name. Each task instead applies one of the four habits the best machines in the code already have: one owner with a small interface, derive instead of storing twice, a holder or token every late step checks, and a clock that clears its state on an error. Wave 0 adds a registry of invariants that the test harness checks after every unit test, and fixes the docs that drifted; every later task is one issue and one pull request, pairing a fix a player can see with the owner function, the notes and the invariant that keep it fixed.

**Tech Stack:** Lua 5.3 and LuaJIT against `test/norns_stubs.lua` (`lua test/run.lua`, `luajit test/run.lua`, `lua test/sync_check.lua`). No engine code changes, so no engine check runs.

**Spec:** GitHub issues #232-#258, one per task (Task N closes #(231 + N)), and the "Decisions" section below, which records the six calls the maintainer made on 2026-11-10. Read the task's issue before starting it (`gh issue view <n>`). The audit also filed #259-#262 (engine; held for the pre-4.0 review, outside this plan).

## Global Constraints

- Everything in AGENTS.md applies, and `docs/process/agents.md` for the roles, briefs, reports, reviews and merging.
- **Lua only.** No file under `lib/engine/`, no `lib/Engine_Strata.sc`, no engine command, signature or poll changes. `strata.lua`'s `init`, `cleanup` and `key` are not edited.
- **No saved data changes:** scenes stay version 4, `buffers.data` version 2, PSETs load unchanged. No new param, no param id or default changes.
- **Names the tests read stay:** every field of `S` and `S.constants` a test reaches through `local_value` or `find_upvalue` keeps its name and meaning, unless the task says otherwise.
- **3.3's sound and controls by default:** no key changes its action. The visible changes are exactly the ones each task names.
- **Locals:** the locals probe needs 30 free locals in each file's main chunk and each constructor. New state goes into an existing table or one new table per feature.
- **One issue, one pull request.** Branch and fragment names are in "Branches and fragments". A task edits only the files it lists, plus registration lines; a test outside its files that breaks because of the intended change gets the minimum lines changed, listed in the report.
- **Every task registers the invariant of the state it touches** (`S.register_invariant`, Task 1) where the task names one, and adds a "States" table to its notes file: the fields that encode the state, the legal combinations, and the one function per transition.
- **Docs in the same pull request:** the module's notes file ("Must not break" and "Owns"), the user page for anything a player sees, AGENTS.md only for the lines the task names.
- **Screen changes** follow AGENTS.md's layout rules: run the page renders and look at them (`lua test/render_pages.lua /tmp/strata-renders && python3 test/render_pages.py /tmp/strata-renders --font ~/src/norns/resources/norns.ttf`, written to the worker's own scratch folder instead of `/tmp`).
- **Changelog:** each task adds `changes/<fragment>.md` (`### Added` / `### Changed` / `### Fixed`); no task edits CHANGELOG.md. `docs/status.md` is edited only by the last task to merge, which removes this plan's open item (the plan's own pull request added it).
- **US English** in code, comments and docs. Docs, commits and pull requests never name the maintainer.
- **Isolation.** Each task's dispatch names a scratch folder `scratchpad/<task>/`; a worker writes only there and in its own worktree. Deletes are `rm -rf -- "${dir:?}"` on a path inside the worker's own folder, spelled out; worktrees go only with `git worktree remove`.
- **Every finding is fixed, never deferred:** a review's findings are fixed in the same pull request; a problem found outside the task gets its own issue and pull request.
- **After every task:** `lua test/run.lua`, `luajit test/run.lua` and `lua test/sync_check.lua` pass ("all three checks"). The baseline on `main` at 335bea9 is 786 tests, 0 failures.

## Decisions

Made by the maintainer on 2026-11-10, each as recommended. The release that carries these fixes copies them into `docs/decisions.md` with the cost if wrong.

1. **Filter restore value** (Task 4): it follows the filter mix only when the mix rises, and K3 records the mix as it is when it turns the filter off. If wrong: after 80% is turned down to 30% and later to 0, K3 restores 80%; one rule in `lib/params_setup.lua`.
2. **Store on the 128h, 128v and 64** (Task 8): store belongs to the port while its key is down, so a bookmark press stores for the grid voice shown. If wrong: remember the voice store was pressed for instead; one branch in `lib/positions.lua`.
3. **Fade cue** (Task 23): the fading target blinks, one change per fade step, on the header's scene mark, SCENES' slot and the grids' recall keys. If wrong: one function, `S.lib.scenes.shows_current`.
4. **BUFFER hold hint** (Task 17): while K2, ALT+K2 or ALT+K3 is down the hint row names what its release will do and changes at 0.5 s, drawn by the frame clock. If wrong: one function in the page's hints.
5. **Layout gaps** (Tasks 26, 27): the 128h shows the scene sequencer's position at 10, as the 256 and 128v do; the 128v gets lock keys on its faders page, column 7 rows 10-16. If wrong: one constant each.
6. **Timing:** everything here merges before 3.3's final review and hardware check; `release/3.3` is rebased over it and merges the fragments, as it did for #217 and #218.

Calls made while planning, for the controller to confirm or overrule in the ledger:
- A voice sync still drops a scan hold whose key is down ("a started voice never inherits a hold" stays); the hold LED then goes dim, since it now shows the hold itself (Task 7).
- A locked voice's MAIN hint reads `K2:locked`; no flash (Task 19).
- A saved scene flashes `saved S<n>` in the header, from one `S.lib.scenes.save` that the grid's hold and SCENES' ALT+K3 share; `capture_scene` itself stays silent, since tests and layout states call it (Task 21).
- A fade that does not land puts the previous scene back as current; a fade's target is still current from its first step, as the grid notes say (Task 22).
- Devices are reconciled when the norns menu closes, the only place a port can change without `add` or `remove` (Task 25).

## Review Focus

The conditions the issues imply but no single task's obvious tests reach, most likely to bite a player first. Each line's test is in the task named.

1. **Two grids of different kinds at once.** A 256 (a store key per voice) beside a 128h (one per port): each grid's store LED shows only its own key, and a hold from one grid survives the other's release. Tests in Task 8 (`"the store LED is the port's own"`) and Task 7 (`"two holders: the scan stays held until the last lets go"`).
2. **A PSET load bangs every param.** The filter's restore value must come out as the loaded mix (or stay, for a mix of 0), and a running LFO's dot must not jump. Tests in Task 4 (`"a PSET load leaves the restore value at the loaded mix"`) and Task 20.
3. **A hold whose holder disappears.** Cleanup, or a grid unplugged, while a voice is held by a grid and the arc: every holder is released, one `scanHold 0` goes out, nothing stays lit. Test in Task 7 (`"cleanup and an unplugged grid release their holds"`).
4. **A fade superseded mid-way.** By another fade, then by an instant recall, then failing: the current scene is always the last one that landed or the one now fading, never a target that was abandoned, and nothing keeps blinking. Tests in Task 22 (`"a fade superseded by a fade that fails goes back to the last scene that landed"`) and Task 23 (`"a superseded fade's target stops blinking at once"`).
5. **The norns menu takes a held key.** K2 down on BUFFER when the menu opens: the hint row goes back to the page's hints, the page stops animating, and the key's release (which the menu swallows) does nothing later. Test in Task 17 (`"the menu opening ends the hold hint"`).

---

## File Structure

One responsibility per file; within a wave the owners are disjoint apart from the lines named. Where several tasks edit one file, the order is the "Starts after" column of the next section.

| File | What changes | Tasks |
|---|---|---|
| `lib/state.lua` | the `invariants` and `menu_close` registries | 1, 25 |
| `test/helpers.lua` | invariants checked after each test | 1 |
| `test/norns_stubs.lua` | a port reassignment without callbacks | 25 |
| `lib/ui/keys.lua` | a page change forgets K2/K3 press marks | 1 (registration), 3 |
| `lib/params_setup.lua`, `lib/pages/fx.lua` | the filter's restore value and its toggle | 4 |
| `lib/performance.lua`, `lib/pages/setup.lua` | a failed write; the running tier's reason | 5, 6 |
| `lib/positions.lua` | hold holders, store per port, the recalled mark | 7, 8, 9 |
| `lib/arc/buffer.lua` | the arc as a holder | 7 |
| `lib/playheads.lua` | the tick contains its errors | 10 |
| `lib/sequencer.lua` | `replace_pattern`; the pattern clock's error path | 1 (registration), 11, 12 |
| `lib/grid/core.lua` | `end_port_step_gestures`, `layout_of`, `reconcile_ports`, the levels from `status` | 1 (registration), 8, 11, 16, 21, 25 |
| `lib/grid/layout_256.lua`, `layout_128h.lua`, `layout_128v.lua`, `layout_64.lua` | one line or field each for 8, 11, 23; the 128h's LED; the 128v's lock keys | 8, 11, 23, 26, 27 |
| `lib/buffers.lua`, `lib/record.lua`, `lib/files.lua` | the dub's start, the start undo, the busy guard, `status` | 1 (registration), 13, 14, 15, 16 |
| `lib/pages/buffer.lua` | the busy flash from `save_buffer`'s reason, `status`, the hold hint | 15, 16, 17 |
| `lib/midi_in.lua` | a note's owner | 18 |
| `lib/pages/main.lua` | the locked hint | 19 |
| `lib/lfos.lua` | the dot's reset | 20 |
| `lib/scenes.lua` | `save`, one transition end, the fade cue's state | 1 (registration), 11 (one line), 21, 22, 23 |
| `lib/ui/header.lua`, `lib/pages/scenes.lua` | the fade cue; the overwrite prompt | 21, 23, 24 |
| `lib/ui/flash.lua` | registration only | 1 |
| `lib/ui/menu_watch.lua`, `lib/arc/core.lua` | menu-close hooks; the arc's reconcile | 25 |
| docs under `docs/notes/`, `docs/user/`, AGENTS.md, `docs/status.md` | the drift fixes, then each task's own | 2, each task |

## Branches and fragments

Fragment: `changes/<branch with "/" as "-">.md`. Scratch folder: `scratchpad/sm-<task number>/`. "Starts after" means the task's branch is cut from `main` once those tasks have merged (they share a file or an interface); tasks with the same "Starts after" run in parallel, and pull requests that touch the same file still land one at a time (`docs/process/agents.md`).

| Task | Issue | Branch | Starts after |
|---|---|---|---|
| 1 | #232 | `test/232-invariants` | - |
| 2 | #233 | `docs/233-notes-drift` | 1 |
| 3 | #234 | `fix/234-key-page-round-trip` | 2 |
| 4 | #235 | `fix/235-filter-restore-mix` | 2 |
| 5 | #236 | `fix/236-performance-write-failure` | 2 |
| 6 | #237 | `feat/237-running-tier-reason` | 5 |
| 7 | #238 | `fix/238-scan-hold-holders` | 2 |
| 8 | #239 | `fix/239-store-follows-grid-voice` | 7, 11 |
| 9 | #240 | `fix/240-recalled-bookmark-source` | 8 |
| 10 | #241 | `fix/241-playhead-tick-errors` | 2 |
| 11 | #242 | `fix/242-step-gestures-end` | 2 |
| 12 | #243 | `fix/243-pattern-clock-errors` | 11 |
| 13 | #244 | `fix/244-dub-cancel-keeps-start` | 2 |
| 14 | #245 | `fix/245-start-reload-undo` | 13 |
| 15 | #246 | `fix/246-save-busy-guard` | 14 |
| 16 | #247 | `fix/247-buffer-status` | 15, 8, 25 |
| 17 | #248 | `feat/248-buffer-hold-hint` | 16, 3 |
| 18 | #249 | `fix/249-midi-note-owner` | 2 |
| 19 | #250 | `fix/250-locked-randomize-hint` | 2 |
| 20 | #251 | `fix/251-lfo-dot-reset` | 2 |
| 21 | #252 | `feat/252-scene-saved-flash` | 11 |
| 22 | #253 | `fix/253-abandoned-fade` | 21 |
| 23 | #254 | `feat/254-fade-cue` | 22, 8, 26, 27 |
| 24 | #255 | `fix/255-overwrite-prompt` | 23 |
| 25 | #256 | `fix/256-device-reassign` | 11 |
| 26 | #257 | `fix/257-128h-sequencer-led` | 2 |
| 27 | #258 | `feat/258-128v-lock-keys` | 2 |

Waves, read off the table: **0** is 1 then 2. **1** is 3, 4, 5, 7, 10, 11, 13, 18, 19, 20, 26, 27. **2** is 6, 8, 12, 14, 21, 25. **3** is 9, 15, 22. **4** is 16, 23. **5** is 17, 24.

**Coordination with 3.3.** `release/3.3` (one commit, rebased on 335bea9) waits for its final whole-release review. This plan lands on `main` first; the release worker then rebases `release/3.3`, merges this plan's fragments into CHANGELOG.md and copies the Decisions above into `docs/decisions.md`, and the final review covers these changes with the rest. No task edits a file only the release commit rewrites (CHANGELOG.md, the workflow); Task 2's AGENTS.md and notes edits are the ones the release worker will meet in its rebase.

## How to read the tests

**All three checks** means `lua test/run.lua`, `luajit test/run.lua` and `lua test/sync_check.lua`, run from the worktree root; each exits 0.

**Test shorthand** (the 3.3 plan's). A test block gives each test's name and its assertions in comments; the implementer writes the setup and the `h.` calls, modeled on the neighboring tests of the same file. `a -> b` and `a == b` are `assert_equal(a, b)` (a number with `(near)` is `assert_near` within 1e-6); `f() -> g(1)` means calling `f` sends the engine call `g(1)` (`context.calls_named`); `;` starts the next case on the same setup. Every number is an exact value from this plan or from the code's arithmetic.

**Stub entry points:** `load_strata`, `finish_startup`, `local_value`, `show_page`, `tap`, `hint_text`, `next_frame`, `assert_screen_layout`; `context.polls.fire(name, value)`, `context.set_time(t)`, `context.clock.run_for(seconds)`, `context.calls_named(name)`, `context.clear_engine_calls()`, `context.audio.register(path, {channels, frames, rate})`, `_menu.set_mode(true | false)`. A clock error the scheduler reports fails the test unless the test claims it (`clock.take_errors`).

**Poll values used below:** `bufferState` is `slot_index * 1000 + seconds` (slot 1 holding 16 s is 16; slot 2 at 0 s is 1000); `bufferLoadFailed` is `(load * 2 + emptied) * 8 + slot_index` (slot 1's second load, not emptied, is 32); `recordState` is `((n * 4) + state) * 8 + slot_index` (slot 1's first recording: armed 32, recording 40, ended 48, canceled 56).

**Every task's steps** are the same six, so each task below lists only what differs:

- [ ] **Step 1:** write the task's failing tests in the test file it names.
- [ ] **Step 2:** run `lua test/run.lua <filter>`; expect the failure the task names.
- [ ] **Step 3:** implement, in the files the task lists.
- [ ] **Step 4:** run all three checks; expect each to exit 0.
- [ ] **Step 5:** docs, the "States" table and the changelog fragment.
- [ ] **Step 6:** commit with the task's message and push.

---

## Wave 0: the harness and the docs

### Task 1 (#232): Invariants checked after every test

**Files:**
- Modify: `lib/state.lua`, `test/helpers.lua`; one registration each in `lib/scenes.lua`, `lib/sequencer.lua`, `lib/grid/core.lua`, `lib/ui/keys.lua`, `lib/buffers.lua`, `lib/ui/flash.lua`
- Test: `test/unit/registries_test.lua`, `test/unit/stubs_test.lua`
- Docs: `docs/notes/lua/state-and-voices.md` (registering an invariant), `docs/notes/lua/test-harness/run-and-helpers.md`, AGENTS.md (the registries list in "Lua modules and `S`"), `changes/test-232-invariants.md`

**Interfaces:**
- Produces: `S.registry.invariants` (a list of `{name, fn}`) and `S.register_invariant(name, fn)`: `name` a non-empty string, unique; `fn()` returns nil while the invariant holds, else a string saying what is broken. Never called on the device.
- Produces: `h.check_invariants()` returns a list of `"<name>: <message>"` strings for the script the current test loaded (empty when none is broken; an invariant that raises is listed with its error). `h.allow_broken_invariants(reason)` (`reason` a non-empty string) turns the check off for the current test.
- Produces: `h.run_test` runs the check after a test that passed, reported no clock error, and called `load_strata` itself; a broken invariant fails the test with `"invariants broken after the test:"` and the list. The flags are saved and restored around a nested `run_test`.
- Seed invariants, each registered in the module that owns the state, under these names:
  - `"scene transition"` (`lib/scenes.lua`): `S.scene_transition_active == (S.SCENE_TRANSITION.next_step_due ~= nil)`, and `S.scene_transition_clock` is nil whenever the flag is false.
  - `"pattern clock"` (`lib/sequencer.lua`): `S.pattern_playing == (S.pattern_clock ~= nil)`.
  - `"grid keys"` (`lib/grid/core.lua`): every consumed key and every key with a pending hold is a held key.
  - `"key presses"` (`lib/ui/keys.lua`): every `S.key_press_alt[n]` has an `S.key_press_page[n]`.
  - `"buffer slots"` (`lib/buffers.lua`): for every slot, `finishing` implies `recording`; `checking_from ~= nil` implies `confirm_since ~= nil`; `settled_empty` and `loaded` are never both set.
  - `"flash slots"` (`lib/ui/flash.lua`): a slot with a text has a clock.

**Tests:**

```lua
-- registries_test.lua
test("register_invariant checks its arguments and refuses a duplicate name", function()
  -- load_strata(); an empty name, a non-function and a second "pattern clock" each raise; a new name with a function is accepted
end)
-- stubs_test.lua
test("a broken invariant is reported by name, a held one is not", function()
  -- load_strata(); #h.check_invariants() -> 0; S.pattern_playing = true (no clock) -> one line starting "pattern clock:"
  -- S.register_invariant("raises", function() error("boom") end) -> a line starting "raises:" that contains "boom"
  -- h.allow_broken_invariants("this test breaks them on purpose")
end)
test("run_test fails a passing test that leaves an invariant broken, unless it allowed it", function()
  -- h.run_test(function() load_strata(); local_value("S").pattern_playing = true end) -> false, the error contains "pattern clock"
  -- the same with h.allow_broken_invariants("on purpose") called first -> true
  -- h.run_test(function() end) -> true (it loaded nothing, so the script an earlier test left is not checked)
  -- end with load_strata(), so this test leaves nothing broken
end)
```

**Step 2 expects:** FAIL, `S.register_invariant` is nil.

**Step 3 notes:** `load_strata` marks the current test as having loaded. If a seed invariant fails anywhere in the existing suite, stop and report NEEDS_CONTEXT with the test's name and the broken line: it is either a wrong invariant or a real defect, and the controller rules (a real one gets its own issue). Do not weaken an invariant or add `allow_broken_invariants` to an existing test without that ruling.

**Commit:** `test: invariants registered per module, checked after every unit test (#232)`

### Task 2 (#233): Docs drift, pinned by tests

**Files:**
- Modify: `docs/notes/lua/state-and-voices.md`, AGENTS.md, `docs/notes/lua/positions.md`, `docs/notes/lua/grid-core.md`, `docs/user/grid.md`; the header comment of `lib/grid/layout_256.lua` and the lock comment at the top of `lib/voices.lua`
- Test: `test/unit/docs_test.lua`
- Docs: `changes/docs-233-notes-drift.md`

**Interfaces:** none.

**Tests:**

```lua
test("the notes' start and cleanup tables list every step of START_ORDER and CLEANUP_ORDER", function()
  -- each number in S.constants.START_ORDER is the first cell of a row of state-and-voices.md's start table, and each row's number is in START_ORDER; the same for CLEANUP_ORDER and the cleanup table
end)
test("every constant AGENTS.md quotes with a value has that value", function()
  -- in the "Named constants" paragraph, each `NAME` (number) pair: S.constants[NAME] -> number (BUFFER_DATA_VERSION -> 2)
end)
test("state-and-voices.md names every registry", function()
  -- each key of S.registry appears in backticks in the file
end)
```

**Step 2 expects:** FAIL: steps 65, 140, 150, 122, 124, 126, 128, 132 and 135 are missing; `BUFFER_DATA_VERSION` reads 1; registries are missing.

**Step 3 notes:** fix exactly what #233 lists. AGENTS.md's "Transient scan state" bullet says what the code does: a grain restart ends the glide, and every voice sync sends `scrubRate 0` and `scanHold 0`.

**Commit:** `docs: notes and AGENTS.md match the code again, with tests that keep them so (#233)`

---

## Wave 1

### Task 3 (#234): A page change forgets K2/K3 presses

**Files:**
- Modify: `lib/ui/keys.lua`
- Test: `test/unit/ui_alt_test.lua`, `test/unit/pages_buffer_test.lua`
- Docs: `docs/notes/lua/ui/alt-and-keys.md`, `changes/fix-234-key-page-round-trip.md`

**Interfaces:**
- Produces: `S.lib.ui_keys.set_ui_page(page)`, on a change of page, clears every entry of `S.key_press_page` and `S.key_press_alt`. `S.alt_held` is untouched (ALT held across E1 stays ALT), and no ALT-release hook runs.

**Tests:**

```lua
-- ui_alt_test.lua (with logging_fx_record, as "K1 let go first" uses it)
test("a key held across a page change and back runs no release", function()
  -- key(2, 1); show_page("MAIN"); show_page("FX"); key(2, 0) -> log "key 2"
  -- key(1, 1); key(2, 1); show_page("MAIN"); S.alt_held -> true; show_page("FX"); key(2, 0); key(1, 0) -> log "alt_key 2"
  -- S.key_press_page[2] and S.key_press_alt[2] -> nil after each page change
end)
-- pages_buffer_test.lua
test("ALT+K2 held from BUFFER to another page and back clears nothing", function()
  -- a loaded slot 1; context.set_time(100); key(1, 1); key(2, 1); show_page("SCENES"); show_page("BUFFER"); context.set_time(100.2); key(2, 0); key(1, 0)
  -- #context.calls_named("clearBuffer") -> 0; the same held to 100.7 fills nothing
end)
```

**Step 2 expects:** FAIL: the log gains `key_release 2`, and `clearBuffer` is sent.

**Commit:** `fix(ui): a page change forgets the K2 and K3 held on the old page (#234)`

### Task 4 (#235): The filter's restore value

**Files:**
- Modify: `lib/params_setup.lua` (the `filter_mix` action), `lib/pages/fx.lua` (`fx_key`)
- Test: `test/unit/pages_fx_test.lua`
- Docs: `docs/notes/lua/pages/fx.md`, `docs/user/pages/fx.md`, AGENTS.md (the "Filter restore mix" bullet), `changes/fix-235-filter-restore-mix.md`

**Interfaces:**
- Produces: `S.fx_last_mix.filter` changes in two places only, both in `lib/params_setup.lua`: `filter_mix`'s action sets it to the new mix when the new mix is higher than the mix before (the mix before starts at the param's default, 0), and `S.lib.params_setup.toggle_filter_mix()` sets it to the current mix before turning a mix above 0 to 0.
- Produces: `S.lib.params_setup.toggle_filter_mix()`: a mix above 0 becomes 0; a mix of 0 becomes `S.fx_last_mix.filter`. FX's K3 on a filter row calls it and nothing else.

**Tests:**

```lua
test("K3 restores the filter mix it had before it was turned down a step at a time", function()
  -- FX, the filter mix row; params:set("filter_mix", 0.8); enc(3, -1) until the mix is 0 (at most 200 turns); key(3, 1) -> mix 0.8 (near)
end)
test("K3 restores the mix a scene fade took to 0", function()
  -- mix 0.6, capture_scene(1); mix 0, capture_scene(2); recall_scene(1, 0); recall_scene(2, 2); context.clock.run_for(3) -> mix 0; key(3, 1) on the mix row -> 0.6 (near)
end)
test("K3 off keeps the mix as it was at the press", function()
  -- mix 0.8, then 0.3; key(3, 1) -> 0; key(3, 1) -> 0.3 (near)
end)
test("turned down to 0.3 and later to 0, K3 restores the last mix it rose to", function()
  -- mix 0.8, 0.3, 0; key(3, 1) -> 0.8 (near)  (decision 1's known cost)
end)
test("a PSET load leaves the restore value at the loaded mix", function()
  -- a PSET load sets a param and then bangs it: params:set("filter_mix", 0.6); params:lookup_param("filter_mix"):bang()
  -- then params:set("filter_mix", 0) and the same bang; key(3, 1) on the mix row -> 0.6 (near)
end)
```

**Step 2 expects:** FAIL: the first test restores 0.01. The two existing K3 tests of the file keep passing unedited.

**Commit:** `fix(fx): K3 restores the filter mix it rose to, not the last step before 0 (#235)`

### Task 5 (#236): A failed performance write is not a saved setting

**Files:**
- Modify: `lib/performance.lua` (`set_setting`), `lib/pages/setup.lua` (`step_performance_field`)
- Test: `test/unit/performance_test.lua`, `test/unit/pages_setup_test.lua`
- Docs: `docs/notes/lua/performance.md`, `docs/notes/lua/pages/setup.md`, `docs/user/pages/setup.md`, `changes/fix-236-performance-write-failure.md`

**Interfaces:**
- Produces: `S.lib.performance.set_setting(key, value)` returns true only when `performance.data` is in place with the new value. An unknown key or value, or a failed write, returns false and leaves `S.performance_setting` (and so `setting()`) as it was; a failed write prints its one console line.
- Produces: on false, `step_performance_field` flashes `"setting not saved"` on SETUP's hint row (`S.lib.ui_flash.start("hints", text, nil, UI_PAGES.index.SETUP)`).

**Tests:**

```lua
-- performance_test.lua (io.open replaced for the test: nil for a "w" open of a path ending "performance.data.part"; put back in every exit)
test("a failed write keeps the old setting and returns false", function()
  -- set_setting("performance", "high") -> false; setting().performance -> "auto"; no performance.data in the data folder
  -- with io.open back: set_setting("performance", "high") -> true; setting().performance -> "high"
end)
-- pages_setup_test.lua
test("a setting that could not be saved shows the old value and says so", function()
  -- SETUP, the cursor on performance, the same failing io.open; enc(3, 1); redraw()
  -- hint_text -> "setting not saved"; the field still shows "auto"; no row shows "(next start)"
end)
```

**Step 2 expects:** FAIL: `set_setting` returns true and the setting reads "high".

**Commit:** `fix(setup): a performance setting that could not be written is not shown as saved (#236)`

### Task 7 (#238): The scan hold has holders

**Files:**
- Modify: `lib/positions.lua`, `lib/arc/buffer.lua`
- Test: `test/unit/positions_test.lua`, `test/unit/arc_pages_test.lua`
- Docs: `docs/notes/lua/positions.md`, `docs/notes/lua/arc-pages.md`, `docs/user/grid.md` (the hold key's LED), `changes/fix-238-scan-hold-holders.md`

**Interfaces:**
- Produces: `S.lib.positions.hold_scan(voice_idx, on, holder)`; `holder` is any non-nil key and defaults to `"caller"`. The grid passes `"grid:" .. port`, the arc `"arc"`.
  - `on`: nothing for a voice that is not a buffer voice (no holder is recorded). Otherwise the holder joins the voice's set; when the set was empty the playhead is advanced, the hold becomes true and `scanHold 1` is sent (while the voice runs).
  - off: the holder leaves the set, whatever the voice's source is now; when the set becomes empty and the voice was held, the playhead is advanced, the hold becomes false and `scanHold 0` is sent (while the voice runs). A release by a holder that is not in the set changes nothing.
- Produces: the `bookmarks` record's `sync` empties the voice's set (and sends `scrubRate 0` and `scanHold 0`, as now); the cleanup step empties every set, sending `scanHold 0` once per held voice.
- Produces: `S.lib.positions.strip_level(voice_idx, "hold")` is `LEVELS.key_down` (15) while `scan_held(voice_idx)`, else `LEVELS.key_up` (4): the LED shows the hold, whoever holds it. `record.hold[voice]` stays the port's record of the voices it holds, for the release sweep and `end_stale_port`.
- Produces: `lib/arc/buffer.lua` holds again on the next ALT ring 1 turn when its voice is no longer held (`held_voice ~= S.selected_voice or not S.lib.positions.scan_held(held_voice)`).
- Registers the invariant `"scan holds"`: for every voice, the hold is true exactly when its set of holders is not empty.

**Tests:**

```lua
-- positions_test.lua (buffer_voices() and with_grid(S, 16, 8), as the #221 tests)
test("the hold LED follows the scan hold, not the key", function()
  -- voice 1 running on a buffer; strip_key(1, 1, "hold", 1) -> strip_level(1, "hold") 15, scanHold 1 sent
  -- toggle_voice(1) twice (stop, start), the key still down -> strip_level 4, the last scanHold sent for voice 0 is 0, scan_held(1) false
  -- strip_key(1, 1, "hold", 0) -> no further scanHold call
end)
test("a synth voice's hold key stays dim and holds nothing", function()
  -- voice 3 on the synth; strip_key(1, 3, "hold", 1) -> strip_level(3, "hold") 4, no scanHold call, scan_held(3) false
end)
test("two holders: the scan stays held until the last lets go", function()
  -- hold_scan(1, true, "grid:1"); hold_scan(1, true, "arc") -> one scanHold 1 in all
  -- hold_scan(1, false, "arc") -> no scanHold 0, scan_held(1) true; hold_scan(1, false, "grid:1") -> scanHold 0, scan_held(1) false
end)
test("a release by a port that holds nothing changes nothing", function()
  -- hold_scan(1, true, "arc"); strip_key(1, 1, "hold", 0) on a 256 (with_grid(S, 16, 16)) -> scan_held(1) true, no scanHold 0
end)
test("a hold let go after the voice left its buffer is forgotten", function()
  -- voice 1 stopped on a buffer; strip_key(1, 1, "hold", 1); params:set("v1_source", 1); strip_key(1, 1, "hold", 0) -> scan_held(1) false
end)
test("cleanup and an unplugged grid release their holds", function()
  -- voice 1 held through strip_key(1, 1, "hold", 1) and hold_scan(1, true, "arc"); grid.remove of port 1's device; context.clock.run_for(0.1) -> scan_held(1) true (the arc holds)
  -- cleanup() -> scan_held(1) false, exactly one scanHold 0 for voice 0
end)
-- arc_pages_test.lua
test("BUFFER's ALT ring 1 holds again after the voice restarted", function()
  -- BUFFER, voice 1 running on a buffer, K1 down; a ring 1 turn -> scanHold 1; toggle_voice(1) twice; a ring 1 turn -> scanHold 1 again; K1 up -> scanHold 0
end)
```

**Step 2 expects:** FAIL: the first test's LED stays 15; the third sends `scanHold 0` at the arc's release.

**Step 3 notes:** `"a voice sync sends scrubRate 0 and scanHold 0"`, the #221 release tests and `"a scan hold or a held position key ends when its grid changes page or goes away"` keep passing unedited.

**Commit:** `fix(positions): the scan hold counts its holders and its LED shows the hold (#238)`

### Task 10 (#241): The playhead tick contains its errors

**Files:**
- Modify: `lib/playheads.lua`
- Test: `test/unit/playheads_test.lua`
- Docs: `docs/notes/lua/playheads.md`, `changes/fix-241-playhead-tick-errors.md`

**Interfaces:**
- Produces: the clock's loop runs `tick` through `xpcall(tick, with_traceback)`; a failing tick prints `"strata: playhead tick failed: "` and the traceback, once per distinct message (a good tick forgets it, as `draw_frame_part` does), and the loop goes on.

**Tests:**

```lua
test("a failing tick is reported and the clock keeps ticking", function()
  -- S.lib.positions.end_stale_holds replaced: it raises on its first call and counts the later ones
  -- context.clock.run_for(0.3) -> at least 2 later calls; S.lib.playheads.clock_id() ~= nil; the scheduler reported no clock error
end)
```

**Step 2 expects:** FAIL: a clock error is reported and no later call comes.

**Commit:** `fix(playheads): an error in a tick no longer ends the playhead clock (#241)`

### Task 11 (#242): Whole-pattern writers end step gestures

**Files:**
- Modify: `lib/sequencer.lua`, `lib/grid/core.lua`, `lib/grid/layout_256.lua` (`copy_paste_key`), `lib/grid/layout_64.lua` (`switch_half`), `lib/scenes.lua` (the pattern restore in `recall_scene_instant`)
- Test: `test/unit/sequencer_test.lua`, `test/unit/grid_core_test.lua`, `test/unit/grid_layout_64_test.lua`
- Docs: `docs/notes/lua/sequencer.md`, `docs/notes/lua/grid-core.md`, AGENTS.md (one sentence in the grid pattern bullet: a whole-pattern replacement goes through `S.lib.sequencer.replace_pattern`), `changes/fix-242-step-gestures-end.md`

**Interfaces:**
- Produces: `S.lib.sequencer.replace_pattern(voice_idx, steps)`: a voice outside 1..`NUM_VOICES` or a `steps` that is not a table does nothing; otherwise steps 1..`PATTERN_LENGTH` take `steps[step]` floored to a whole number and then clamped to 0..`MAX_STEP_LEVEL` (a missing or non-number entry is 0), and `S.lib.grid_core.end_step_gestures(voice_idx)` runs. It redraws nothing: callers do. `clear_pattern`, `randomize_pattern`, the 256's paste and the scene recall's restore all write through it; no other code assigns a whole pattern.
- Produces: `S.lib.grid_core.end_port_step_gestures(port)`: forgets that port's step keys (the keys stay held; their releases do nothing). The 64's `switch_half` calls it.

**Tests:**

```lua
-- sequencer_test.lua
test("replace_pattern copies sixteen whole levels in range and ignores a bad voice", function()
  -- replace_pattern(1, {15, 3.7, -2, 99, "x"}) -> S.patterns[1] is 15, 3, 0, 15, 0 and eleven 0s; replace_pattern(0, {...}) and (8, {...}) change nothing
end)
-- grid_core_test.lua (a 256 on port 1)
test("clear, randomize and a scene recall end a held step gesture, as a paste does", function()
  -- press and hold step 3 of voice 1; press voice 1's clear key (1, 15); press step 9 of voice 1 -> S.patterns[1][3] 0 and [1][9] 15
  -- the same with randomize ((9, 15)): after it, step 3 keeps the level randomize gave it and step 9 toggles from what randomize gave it
  -- the same with capture_scene(1) of an empty pattern, a held step 3, recall_scene(1, 0), then step 9 -> [1][3] 0 and [1][9] 15
end)
-- grid_layout_64_test.lua
test("switching halves ends a held step gesture", function()
  -- hold (3, 1) in half 1 (step 3 on at 15); hold the play key (1, 8) for 0.6 s (half 2); press (8, 1) -> S.patterns[1][16] 15 and [1][3] still 15
end)
```

**Step 2 expects:** FAIL: step 3 comes back at level 8 in the cleared pattern and step 9 stays 0.

**Step 3 notes:** randomize keeps its draws (`math.random() > 0.5`, then `math.random(8, 15)`) in the same order, so seeded tests keep their values.

**Commit:** `fix(grid): every whole-pattern change ends the voice's held step gesture (#242)`

### Task 13 (#244): A canceled dub keeps the file's start

**Files:**
- Modify: `lib/buffers.lua` (`recording_started`), `lib/record.lua` (`record_buffer`, the ended report)
- Test: `test/unit/buffers_test.lua`, `test/unit/record_test.lua`
- Docs: `docs/notes/lua/buffers.md`, `docs/notes/lua/record.md`, `changes/fix-244-dub-cancel-keeps-start.md`

**Interfaces:**
- Produces: `S.lib.buffers.recording_started(slot, playable)`: cancels the slot's pending start reload either way. A replace take (`playable` false or nil) sets `start` 0 and forgets `sample_rate` and `file_seconds`; a playable recording leaves all three.
- Produces: a playable recording's "ended" report (it becomes `take <n>` on the scratch path) sets `start` 0 and forgets `sample_rate` and `file_seconds`; its "canceled" report changes none of them.

**Tests:**

```lua
-- record_test.lua (a 60 s file: context.audio.register(path, {channels = 2, frames = 2880000, rate = 48000}); standard tier, so slots hold 16 s)
test("a canceled dub keeps the file's start, rate and length", function()
  -- load_buffer(1, path); fire bufferState 16; S.lib.buffers.set_start(1, 12); context.clock.run_for(0.4); fire bufferState 16
  -- params:set("record_feedback", 50); params:set("record_threshold", 2); record_buffer(1); record_buffer(1); fire recordState 56
  -- S.buffers[1]: start 12, file_seconds 60, sample_rate 48000, path the file, recording false
end)
test("a dub that ends becomes take n with start 0 and no file length", function()
  -- the same up to the first record_buffer(1); fire recordState 40, then 48
  -- S.buffers[1]: name "take 1", start 0, file_seconds nil, sample_rate nil
end)
-- buffers_test.lua
test("a replace take forgets the file's start, rate and length at once", function()
  -- the same file (2880000 frames at 48000), load and start; record_buffer(1) with feedback 0 -> start 0, file_seconds nil, sample_rate nil
end)
```

**Step 2 expects:** FAIL: the first test reads start 0 and `file_seconds` nil.

**Step 3 notes:** the test `"a recording, a clear or another file sets the start back to 0"` replaces `S.lib.record.state` with a fake to reach the playable branch; rewrite that part to call `record_buffer` with feedback above 0, and list the lines in the report. `"record_buffer calls S.lib.buffers.recording_started for the slot"` gains the second argument.

**Commit:** `fix(buffers): a canceled dub keeps the file's start, rate and length (#244)`

### Task 18 (#249): A MIDI note has one owner

**Files:**
- Modify: `lib/midi_in.lua`
- Test: `test/unit/midi_in_test.lua`
- Docs: `docs/notes/lua/midi.md`, `changes/fix-249-midi-note-owner.md`

**Interfaces:**
- Produces: a note on whose channel and note already belong to another voice (`note_voice[ch][note]`) first releases that voice: its `held` entry goes (unless another channel still plays that note on it) and `midi_note_off_for` runs for it.
- Produces: a note off clears `held[voice][note]` only when no channel's `note_voice` still maps that note to the voice.
- Registers the invariant `"midi notes"`: `held[voice][note]` is set exactly when some channel's `note_voice[ch][note]` is that voice.

**Tests:**

```lua
test("omni, voice off: a repeated note on after the selection moved releases the first voice", function()
  -- midi_channel_mode 2, midi_note_off 2; note on 60 ch 1 (voice 1 selected, it starts); select voice 2; note on 60 ch 1 again
  -- next(S.midi_state.held[1]) -> nil and voice 1 stopped; voice 2 runs; note off 60 ch 1 twice -> voice 2 stopped, nothing held
end)
test("omni: the same note on two channels holds the voice until both are off", function()
  -- voice 1 selected; note on 60 ch 1 and ch 2; note off 60 ch 1 -> voice 1 still running, held[1][60] true; note off 60 ch 2 -> stopped
end)
```

**Step 2 expects:** FAIL: `held[1][60]` stays set and voice 1 keeps running; in the second test the first note off stops the voice.

**Commit:** `fix(midi): a note on releases the note's previous voice, and a note off waits for every channel (#249)`

### Task 19 (#250): The locked hint

**Files:**
- Modify: `lib/pages/main.lua` (`main_hints`)
- Test: `test/unit/pages_main_test.lua`
- Docs: `docs/notes/lua/pages/main.md`, `docs/user/pages/main.md`, `changes/fix-250-locked-randomize-hint.md`

**Interfaces:**
- Produces: with ALT held, MAIN's K2 hint is `undo` while the selected voice's undo is available, else `locked` for a locked voice, else `rand`.

**Tests:**

```lua
test("ALT's K2 hint reads locked for a locked voice", function()
  -- MAIN, voice 1 locked, K1 down -> hint_text "K2:locked K3:unlock"; ALT+K2 changes no param of voice 1
  -- voice 2 randomized, then locked, inside the undo window -> "K2:undo K3:unlock"
end)
```

**Step 2 expects:** FAIL: the hint reads `K2:rand K3:unlock`.

**Commit:** `fix(main): ALT's K2 hint says locked when randomize would do nothing (#250)`

### Task 20 (#251): The LFO dot resets only when the LFO starts

**Files:**
- Modify: `lib/lfos.lua` (the `lfo_<n>` wrapper)
- Test: `test/unit/lfos_test.lua`
- Docs: `docs/notes/lua/lfos.md`, `changes/fix-251-lfo-dot-reset.md`

**Interfaces:**
- Produces: the wrapper calls `note_lfo_reset(n)` only when the state goes from off to on (it keeps whether the LFO was on, per LFO, beside `offset_before_state`).

**Tests:**

```lua
test("setting a running LFO's state again leaves the phase dot where it is", function()
  -- LFO 1 on; context.clock.run_for(0.3); before = lfo_phase_estimate(1); params:lookup_param("lfo_1"):bang() -> lfo_phase_estimate(1) == before (near)
  -- off, then on -> the estimate restarts (it equals the estimate of a freshly started LFO)
end)
```

**Step 2 expects:** FAIL: the estimate jumps after the bang.

**Commit:** `fix(lfo): the phase dot restarts only when the LFO does (#251)`

### Task 26 (#257): The 128h shows the scene sequencer's position

**Files:**
- Modify: `lib/grid/layout_128h.lua` (`redraw_scene_page`, `LAYOUT_128H.sequencer_position_level = 10`)
- Test: `test/unit/grid_layout_128h_test.lua`
- Docs: `docs/notes/lua/grid/layout_128h.md`, `docs/user/grid/128h.md`, `changes/fix-257-128h-sequencer-led.md`

**Interfaces:** none.

**Tests:**

```lua
test("128h: the scene page lights the sequencer's position at 10, the current scene at 15", function()
  -- page 3, scenes 1-3 captured, scene 1 current, the sequencer on at position 2 -> LED (2, 1) 10, (1, 1) 15, (3, 1) 8; the sequencer off -> (2, 1) 8
end)
```

**Step 2 expects:** FAIL: (2, 1) is 8 with the sequencer on.

**Commit:** `fix(grid): the 128h's scene page shows the sequencer's position (#257)`

### Task 27 (#258): Lock keys on the 128v

**Files:**
- Modify: `lib/grid/layout_128v.lua` (`grid_key_128v_faders`, `grid_redraw_128v_faders`; `LAYOUT_128V.lock_column = 7`, `locked_level = 12`, `unlocked_level = 2`)
- Test: `test/unit/grid_layout_128v_test.lua`
- Docs: `docs/notes/lua/grid/layout_128v.md`, `docs/user/grid/128v.md`, `docs/user/grid.md` (the lock keys per layout), `changes/feat-258-128v-lock-keys.md`

**Interfaces:**
- Produces: on the faders page, column 7 rows 10-16 are the lock keys of voices 1-7 (`toggle_lock`), lit 12 locked and 2 not. Rows 1-9 of column 7 stay dark and do nothing.

**Tests:**

```lua
test("128v: the faders page's column 7 locks and unlocks voices 1-7", function()
  -- page 2; press (7, 12) -> S.frozen[3] true, LED (7, 12) 12, (7, 10) 2; again -> false, 2
  -- press (7, 9) -> no voice locked; on page 1 a press at (7, 12) is voice 7's step 12, as before
end)
```

**Step 2 expects:** FAIL: `S.frozen[3]` stays false.

**Commit:** `feat(grid): lock keys on the 128v's faders page (#258)`

---

## Wave 2

### Task 6 (#237): SETUP says why the running tier differs

**Files:**
- Modify: `lib/performance.lua`, `lib/pages/setup.lua` (`add_performance_rows`, `setup_rows`)
- Test: `test/unit/performance_test.lua`, `test/unit/pages_setup_test.lua`
- Docs: `docs/notes/lua/performance.md`, `docs/notes/lua/pages/setup.md`, `docs/user/pages/setup.md`, `changes/feat-237-running-tier-reason.md`

**Interfaces:**
- Produces: `S.lib.performance.running_note()`: `"active file not written"` when `S.performance.reason` contains `"could not be written"`; `"old active file kept"` when it contains `"could not be replaced"`; else nil. SETUP shows it as a dim note row directly under the `running:` row.
- Produces: `S.lib.performance.step_down_cause()`: `"no meminfo"` when the reason contains `"meminfo unreadable"`, else `"memory"`. SETUP's step-down note reads `"<setting> s -> <running> s (<cause>)"`.

**Tests:**

```lua
-- performance_test.lua (active files written with h.write_performance_active, as the neighboring tests build them)
test("running_note and step_down_cause read the engine's reason", function()
  -- reason "standard: performance_active.data could not be written" -> "active file not written"
  -- reason "high: the old performance_active.data (it could not be replaced)" -> "old active file kept"
  -- reason "auto: Raspberry Pi 4 Model B Rev 1.4" -> nil; step_down_cause() "memory"
  -- reason "high: setting; buffer 300 s -> 16 s (meminfo unreadable)" -> step_down_cause() "no meminfo"
end)
-- pages_setup_test.lua
test("SETUP shows why the running tier is not the setting's", function()
  -- the first reason above: the row after "running: standard" shows "active file not written"; assert_screen_layout passes with the cursor at both ends
  -- a high active file at 16 s under a 300 s setting with the meminfo reason: a row shows "300 s -> 16 s (no meminfo)"
  -- a plain "auto: ..." reason: no note row under "running:" (the row count is as before)
end)
```

**Step 2 expects:** FAIL: `running_note` is nil.

**Commit:** `feat(setup): SETUP says why the running tier differs from the setting (#237)`

### Task 8 (#239): Store follows the grid voice

**Files:**
- Modify: `lib/positions.lua`, `lib/grid/core.lua` (`layout_of`), and one field or argument each in `lib/grid/layout_256.lua`, `lib/grid/layout_128h.lua`, `lib/grid/layout_128v.lua`, `lib/grid/layout_64.lua`
- Test: `test/unit/positions_test.lua`, `test/unit/grid_core_test.lua`, `test/unit/grid_layout_128h_test.lua`, `test/unit/grid_layout_128v_test.lua`, `test/unit/grid_layout_64_test.lua`
- Docs: `docs/notes/lua/positions.md`, `docs/notes/lua/grid-core.md` (the layout record's fields), `docs/user/grid/128h.md`, `docs/user/grid/128v.md`, `docs/user/grid/64.md`, `changes/fix-239-store-follows-grid-voice.md`

**Interfaces:**
- Produces: the layout records of the 128h, 128v and 64 carry `selects_grid_voice = true` (the 256's has none). `S.lib.grid_core.layout_of(port)` returns the connected port's layout record, or nil. `lib/positions.lua` reads that field and no longer reads the grid's size.
- Produces: on a port whose layout selects a grid voice, the port's positions record holds `store_down` (the page of the press, nil when up) instead of `store[voice]`: a `"store"` press sets it, its release clears it and `pressed`; a bookmark press on that port stores for the voice the layout names when `store_down` is set. `end_stale_port` clears it when the port is gone or shows another page. The 256 keeps `store[voice]`.
- Produces: `S.lib.positions.strip_level(voice_idx, key, port)`: with a `port`, `"store"` and a stored bookmark's level read only that port's record; without one, any port's (the playhead clock's signature). Every layout's redraw passes its port.

**Tests:**

```lua
-- grid_layout_128h_test.lua (page 4; voices 1 and 2 on buffers, the grid voice 1)
test("128h: store held, the grid voice changed: a bookmark press stores for the voice shown", function()
  -- hold store (13, 6); press (16, 8) -> the grid voice 2; press bookmark 1 (13, 5)
  -- voice 2 stopped: v2_bookmark_1 is its buf_pos mapped into its loop, v2_buf_pos is unchanged (no recall), v1_bookmark_1 unchanged
  -- LED (13, 6) 15 and (13, 5) 15 while held; release store; press (13, 5) -> a recall (v2_buf_pos is the bookmark)
end)
-- grid_layout_128v_test.lua, grid_layout_64_test.lua: the same gesture with the layout's own keys
--   128v, page 5: store (8, 14), the grid voice changed by a position press in voice 2's column, bookmark 1 (8, 10)
--   64, the positions view: store (6, 3), the grid voice changed by (2, 7), bookmark 1 (1, 3)
-- positions_test.lua
test("the store LED is the port's own", function()
  -- a 256 on port 1 and a 128h on port 2; strip_key(2, 1, "store", 1) -> strip_level(1, "store", 2) 15, strip_level(1, "store", 1) 4, strip_level(1, "store") 15
end)
-- grid_core_test.lua
test("a layout record says whether a position press selects the grid voice", function()
  -- S.registry.grid_layouts["256"].selects_grid_voice -> nil; "128h", "128v" and "64" -> true
  -- layout_of(port) is the record of a connected 128h; nil for a port with no grid
end)
```

**Step 2 expects:** FAIL: the bookmark press recalls (voice 2's `buf_pos` moves and `v2_bookmark_1` keeps its value).

**Step 3 notes:** `"a strip store's release ends store for the voice it was pressed for, after a grid voice change"` still passes (the release ends the port's store); `"on a 256 a strip store's release ends only its own voice"` passes unedited.

**Commit:** `fix(positions): on one-strip grids store follows the grid voice while its key is down (#239)`

### Task 12 (#243): A failing step stops the pattern clock cleanly

**Files:**
- Modify: `lib/sequencer.lua` (`pattern_clock_start`)
- Test: `test/unit/sequencer_test.lua`
- Docs: `docs/notes/lua/sequencer.md`, `changes/fix-243-pattern-clock-errors.md`

**Interfaces:**
- Produces: each step's body runs through `xpcall(..., with_traceback)`. On an error the clock forgets its own id (`S.pattern_clock = nil`, so it never cancels itself), calls `pattern_clock_stop()` and raises the error again.

**Tests:**

```lua
test("an error in a step stops the pattern clock and shows it stopped", function()
  -- S.patterns[1][1] = 15, voice 1 stopped, toggle_voice replaced by one that raises once; pattern_clock_start()
  -- one clock error, claimed with clock.take_errors; S.pattern_playing false, S.pattern_clock nil, S.lib.sequencer.sounding_step() nil
  -- pattern_toggle() -> playing again (one press)
end)
```

**Step 2 expects:** FAIL: `S.pattern_playing` stays true.

**Commit:** `fix(sequencer): an error in a step stops the pattern clock instead of leaving it lit (#243)`

### Task 14 (#245): A failed start reload puts the start back

**Files:**
- Modify: `lib/buffers.lua`
- Test: `test/unit/buffers_test.lua`
- Docs: `docs/notes/lua/buffers.md`, `changes/fix-245-start-reload-undo.md`

**Interfaces:**
- Produces: each slot keeps `sent_start`, the start of the load last sent for it (0 after a clear, a replace take, a dub that ended and at init; `apply_buffer_state` sets it to the state's start). `buffer_state_before_load` records `start = buffer.sent_start`. `buffers.data` still saves `buffer.start`.

**Tests:**

```lua
test("a start reload that fails puts the start back", function()
  -- the 60 s file loaded and settled (load 1); set_start(1, 12); context.clock.run_for(0.4) -> loadBuffer(0, path, 12) sent (load 2)
  -- fire bufferLoadFailed 32 -> S.buffers[1].start 0, path and name the file's, file_seconds 60
  -- set_start(1, 12) again, the reload settles (bufferState 16); set_start(1, 20); run_for(0.4); fire bufferLoadFailed 64 (load 4) -> start 12
end)
```

**Step 2 expects:** FAIL: the start reads 12 after the first failure.

**Commit:** `fix(buffers): a start reload that fails puts the slot's start back (#245)`

### Task 21 (#252): A saved scene says so

**Files:**
- Modify: `lib/scenes.lua`, `lib/grid/core.lua` (`scene_save_key`), `lib/pages/scenes.lua` (`scenes_alt_key`)
- Test: `test/unit/scenes_test.lua`, `test/unit/grid_core_test.lua`, `test/unit/pages_scenes_test.lua`
- Docs: `docs/notes/lua/scenes.md`, `docs/notes/lua/pages/scenes.md`, `docs/user/scenes.md`, `docs/user/grid.md`, `changes/feat-252-scene-saved-flash.md`

**Interfaces:**
- Produces: `S.lib.scenes.save(scene_num)`: for a slot in 1..`NUM_SCENES`, `capture_scene(scene_num)`, `header_flash("saved S" .. scene_num)`, `grid_redraw()`, `request_redraw()`, returning true; any other slot does nothing and returns false. The grid's save hold and SCENES' ALT+K3 save through it; `capture_scene` stays silent.

**Tests:**

```lua
-- scenes_test.lua
test("S.lib.scenes.save captures and flashes; capture_scene stays silent", function()
  -- save(3) -> true, S.scenes[3].populated, S.lib.ui_flash.text("header") "saved S3"; save(0) and save(9) -> false
  -- a fresh load: capture_scene(3) -> S.lib.ui_flash.text("header") nil
end)
-- grid_core_test.lua
test("a scene saved on a grid hold flashes saved in the header", function()
  -- a 256, page 3, hold (4, 3) for 0.6 s -> S.lib.ui_flash.text("header") "saved S4"; a release at 0.3 s -> nil
end)
-- pages_scenes_test.lua
test("ALT+K3 on SCENES flashes saved", function()
  -- the cursor on empty slot 2, ALT+K3 -> "saved S2" in the header
end)
```

**Step 2 expects:** FAIL: `S.lib.scenes.save` is nil.

**Commit:** `feat(scenes): a saved scene flashes saved in the header, from the grid and the screen (#252)`

### Task 25 (#256): Devices reassigned in the menu

**Files:**
- Modify: `lib/state.lua` (the `menu_close` registry), `lib/ui/menu_watch.lua`, `lib/grid/core.lua`, `lib/arc/core.lua`, `test/norns_stubs.lua`
- Test: `test/unit/registries_test.lua`, `test/unit/grid_core_test.lua`, `test/unit/arc_core_test.lua`, `test/unit/stubs_test.lua`
- Docs: `docs/notes/lua/grid-core.md`, `docs/notes/lua/arc-core.md`, `docs/notes/lua/ui/alt-and-keys.md` (the menu watch), `docs/notes/lua/test-harness/stubs.md`, `docs/notes/lua/state-and-voices.md` and AGENTS.md (the registry), `changes/fix-256-device-reassign.md`

**Interfaces:**
- Produces: `S.registry.menu_close` and `S.register_menu_close(fn)` (a function; checked as the other register functions are). The menu watch's wrapper runs each hook, in its own `pcall` (a failure prints one line and never stops the menu closing), after norns' `set_mode(false)` returns, while the watch is active. The registry is read when the wrapper is built (the `menu_watch` start step), so hooks are registered at include time, or in a test's `before_init`.
- Produces: `S.lib.grid_core.reconcile_ports()`: for each port 1..`S.MAX_GRID_PORTS`, a vport holding a device that is not attached (or holds another device than the one attached) is forgotten and attached, as `grid.add` does; an attached port whose vport is empty is detached and forgotten, as `grid.remove` does; then `grid_redraw()` and `request_redraw()`. Registered as a menu-close hook.
- Produces: `S.lib.arc_core.reconcile()`: when the followed vport holds no device, follow `first_arc_port()` if there is one, else `S.arc_connected = false`; when it holds one, `S.arc_connected = true`; then `request_redraw()`. Registered as a menu-close hook.
- Produces (stubs): `context.grid.reassign(from_port, to_port)` and `context.arc.reassign(from_port, to_port)` move a device between vports as norns' `update_devices` does (the vports' `device`, the grid's `cols` and `rows`, the device's `port`), calling no `add` or `remove`.
- Registers the invariant `"arc connection"`: `S.arc_connected == (S.arc_device ~= nil and S.arc_device.device ~= nil)`.

**Tests:**

```lua
-- registries_test.lua
test("register_menu_close checks its argument, and the hooks run as the menu closes", function()
  -- a non-function raises; _menu.set_mode(true); _menu.set_mode(false) -> a hook registered before init ran once; a hook that raises does not stop the next one
end)
-- grid_core_test.lua
test("a grid moved to another port in SYSTEM > DEVICES works once the menu closes", function()
  -- a 128h on port 1; _menu.set_mode(true); context.grid.reassign(1, 2); _menu.set_mode(false)
  -- S.grids[1] nil, S.grids[2] attached; a step press on port 2 toggles S.patterns[1][1]; SETUP shows "grid: 1 connected"
end)
-- arc_core_test.lua
test("an arc moved to another port in SYSTEM > DEVICES is followed once the menu closes", function()
  -- an arc on port 1; menu open; context.arc.reassign(1, 3); menu closed -> S.arc_connected true, a ring turn on port 3 moves its param
  -- the arc's vport emptied with no other arc -> S.arc_connected false and SETUP shows "arc: none"
end)
-- stubs_test.lua
test("reassign moves a device between vports and calls no add or remove", function() end)
```

**Step 2 expects:** FAIL: `context.grid.reassign` is nil; with it, the press on port 2 does nothing.

**Step 3 notes:** check the stubs against norns' `lua/core/grid.lua` and `arc.lua` (`update_devices`) before changing them.

**Commit:** `fix(devices): a grid or arc moved in SYSTEM > DEVICES works when the menu closes (#256)`

---

## Wave 3

### Task 9 (#240): The recalled mark remembers its source

**Files:**
- Modify: `lib/positions.lua`
- Test: `test/unit/positions_test.lua`
- Docs: `docs/notes/lua/positions.md`, `changes/fix-240-recalled-bookmark-source.md`

**Interfaces:**
- Produces: `recall_bookmark` remembers the bookmark with the voice's source at that time; `S.lib.positions.last_recalled(voice_idx)` returns the bookmark only while the voice still has that source, else nil. The two hooks that clear it stay.

**Tests:**

```lua
test("a scene recall that switches a stopped voice's source forgets its last recalled bookmark", function()
  -- as "a scene recall that switches a running voice's source forgets its last recalled bookmark", with voice 1 stopped: recall_bookmark(1, 2); a scene with voice 1 on another buffer, recalled at once
  -- last_recalled(1) -> nil; strip_level(1, 2) -> 6
end)
```

**Step 2 expects:** FAIL: `last_recalled(1)` is 2.

**Commit:** `fix(positions): the last-recalled mark goes when the voice's source does, stopped or not (#240)`

### Task 15 (#246): The busy check lives in save_buffer

**Files:**
- Modify: `lib/buffers.lua` (`save_buffer`, `save_buffer_loop`), `lib/pages/buffer.lua` (`save_cursor_slot`)
- Test: `test/unit/buffers_test.lua`, `test/unit/pages_buffer_test.lua`
- Docs: `docs/notes/lua/buffers.md`, `docs/notes/lua/pages/buffer.md`, `changes/fix-246-save-busy-guard.md`

**Interfaces:**
- Produces: `save_buffer(slot)` and `save_buffer_loop(slot)` return true when the save was sent, else false and a reason: `"invalid"` (not a slot), `"busy"` (the slot is recording or finishing; one console line) or `"empty"` (it reports no length). One local `send_save(slot, path, start, length, loop)` counts the save, tracks it and calls `engine.saveBuffer`.
- Produces: `save_cursor_slot` flashes from the reason (`"buf <n> busy"`, `"buf <n> empty"`, or `"saving buf <n>"` with `" loop"`) and no longer checks the recording itself.

**Tests:**

```lua
-- buffers_test.lua
test("the save param sends nothing while the slot records", function()
  -- a loaded, settled slot 1; record_feedback 50; record_buffer(1); the buf1_save trigger -> no saveBuffer, S.buffers[1].saves_sent 0
end)
test("save_buffer and save_buffer_loop say why they sent nothing", function()
  -- save_buffer(0) -> false, "invalid"; an empty slot -> false, "empty"; recording -> false, "busy"; a loaded one -> true; the same four for save_buffer_loop
end)
```

**Step 2 expects:** FAIL: `saveBuffer` is sent during the recording.

**Step 3 notes:** `"ALT+K3 saves the slot on release before 0.5 s and its loop region after it"` passes unedited (its busy and empty flashes keep their texts).

**Commit:** `fix(buffers): no save is sent for a slot that is recording, whoever asks (#246)`

### Task 22 (#253): A fade that does not land puts the previous scene back

**Files:**
- Modify: `lib/scenes.lua`
- Test: `test/unit/scenes_test.lua`
- Docs: `docs/notes/lua/scenes.md`, `changes/fix-253-abandoned-fade.md`

**Interfaces:**
- Produces: `S.SCENE_TRANSITION.target` (the scene a running fade goes to) and `S.SCENE_TRANSITION.previous` (the current scene before it), both nil when no fade runs, set and cleared with `S.scene_transition_active` and `next_step_due` by one local function that ends a transition. `cancel_scene_transition`, the step error and the fade's end all end it through that function.
- Produces: ending a transition sets `S.current_scene` back to `previous`. So: a canceled fade and a fade whose step fails leave the previous scene current; a fade's end restores it and then `recall_scene_instant` sets the target on success; `recall_scene` cancels first and then reads the current scene as the new fade's `previous`.
- Produces: the `"scene transition"` invariant also requires `(target ~= nil) == S.scene_transition_active`.

**Tests:**

```lua
test("a fade whose step fails leaves the previous scene current", function()
  -- as "an error inside a scene transition's fade clears the transition flag": recall_scene(2, 0); recall_scene(1, 4); a param action that raises in a later step
  -- S.current_scene -> 2; target and previous nil
end)
test("a canceled fade leaves the previous scene current", function()
  -- recall_scene(2, 0); recall_scene(1, 4) -> S.current_scene 1 at once; cancel_scene_transition() -> 2
  -- the same through the sequencer's overrun (as "the scene sequencer moves on when a transition never finishes") and a scenes file load during the fade
end)
test("a fade superseded by a fade that fails goes back to the last scene that landed", function()
  -- recall_scene(1, 0); recall_scene(2, 4); recall_scene(3, 4) -> current 3, previous 1; a failing step -> current 1
  -- recall_scene(2, 4); recall_scene(3, 0) -> current 3, target nil
end)
test("a fade that lands makes its target current", function()
  -- recall_scene(2, 0); recall_scene(1, 2); context.clock.run_for(2.5) -> current 1, target nil
end)
```

**Step 2 expects:** FAIL: the current scene stays 1 after the failing step.

**Commit:** `fix(scenes): a fade that does not land leaves the previous scene current (#253)`

---

## Wave 4

### Task 16 (#247): One answer to "what does this slot hold"

**Files:**
- Modify: `lib/buffers.lua`, `lib/files.lua` (`fill_empty`), `lib/pages/buffer.lua` (`slot_is_empty`), `lib/grid/core.lua` (`source_level`)
- Test: `test/unit/buffers_test.lua`, `test/unit/files_test.lua`, `test/unit/grid_core_test.lua`
- Docs: `docs/notes/lua/buffers.md` (the "States" table is this function), `docs/notes/lua/files.md`, `docs/notes/lua/pages/buffer.md`, `docs/notes/lua/grid-core.md`, `changes/fix-247-buffer-status.md`

**Interfaces:**
- Produces: `S.lib.buffers.status(slot)`, derived from the slot's fields and `S.lib.record.state(slot)`, nil for a slot out of range; the first that applies:
  1. `"armed"`: its take's phase is `"armed"`;
  2. `"finishing"`: `finishing`;
  3. `"loop"`, `"dub"` or `"recording"`: `recording`, with a playable take that loops, a playable take that does not, or a replace take;
  4. `"loading"`: `confirm_since` is set (a load the engine has not confirmed, checking or not);
  5. `"loaded"`: `loaded`;
  6. `"unsettled"`: `settled_empty` is `"load"` or `"restore"` (a named load that reported no length yet; a later report adopts it);
  7. `"missing"`: `missing_path` is set;
  8. `"empty"`.
- Produces: `S.lib.buffers.is_free(slot)`: the status is `"empty"` or `"missing"`. `fill_empty`, BUFFER's `slot_is_empty` and the grid's `source_level` (level 2) use it; none keeps its own test. No stored field changes.

**Tests:**

```lua
-- buffers_test.lua
test("status names what a slot holds, one answer for every reader", function()
  -- fresh -> "empty"; load_buffer(1, path) -> "loading"; fire bufferState 4 -> "loaded"
  -- load_buffer(2, path); context.set_time(now + 1.1); fire bufferState 1000 -> "unsettled", is_free(2) false; fire bufferState 1004 -> "loaded"
  -- record_buffer(3) with feedback 0 -> "recording"; its timer ends -> "finishing"
  -- slot 1 with feedback 50 and a threshold -> "armed"; recordState 40 -> "dub"; slot 4 with record_loop on, recordState 43 -> "loop"
  -- a remembered file missing at start -> "missing", is_free true; status(0) and status(9) -> nil
end)
-- files_test.lua
test("fill_empty leaves a named load the engine has not reported yet", function()
  -- slot 2 "unsettled" as above; fill_empty() in a folder of files -> no loadBuffer for slot index 1; the other empty slots are filled
end)
-- grid_core_test.lua
test("a named, unsettled slot's source key is not shown as empty", function()
  -- source_level(1, the option of slot 2) -> 4; an empty slot's -> 2
end)
```

**Step 2 expects:** FAIL: `S.lib.buffers.status` is nil.

**Commit:** `fix(buffers): one status per slot, so fill, the page and the grid agree on empty (#247)`

### Task 23 (#254): The fading target blinks

**Files:**
- Modify: `lib/scenes.lua`, `lib/ui/header.lua` (the scene mark), `lib/pages/scenes.lua` (the slot's level), and the recall keys' level in `lib/grid/layout_256.lua`, `lib/grid/layout_128h.lua`, `lib/grid/layout_128v.lua`
- Test: `test/unit/scenes_test.lua`, `test/unit/ui_header_test.lua`, `test/unit/pages_scenes_test.lua`, `test/unit/grid_layout_256_test.lua`, `test/unit/grid_layout_128h_test.lua`, `test/unit/grid_layout_128v_test.lua`
- Docs: `docs/notes/lua/scenes.md`, `docs/notes/lua/pages/scenes.md`, `docs/notes/lua/ui/header-and-flashes.md`, the three layouts' notes, `docs/user/scenes.md`, `docs/user/pages/scenes.md`, `docs/user/grid.md`, `changes/feat-254-fade-cue.md`

**Interfaces:**
- Consumes: Task 22's `S.SCENE_TRANSITION.target` and its one function that ends a transition.
- Produces: `S.SCENE_TRANSITION.step`: the number of the fade step applied last (1 from the recall itself, since the first step runs at once), set before that step's redraws; nil when no fade runs.
- Produces: `S.lib.scenes.fading_to()`: the target while a fade runs, else nil. `S.lib.scenes.shows_current(slot)`: true when `slot == S.current_scene` and either no fade goes to it or the step applied last is odd.
- Produces: every display of the current scene asks `shows_current`: the grids' recall keys are 15 when it is true, else their level without it (8 populated, or 10 at the sequencer's position); SCENES' slot is 15, else 4; the header's `S<n>` keeps its level (10 with the sequencer on, 6 without), else 2.

**Tests:**

```lua
-- scenes_test.lua (a 2 s fade: 20 steps of 0.1 s)
test("the fading target blinks once per step and is steady when it lands", function()
  -- recall_scene(1, 0); recall_scene(2, 2) -> fading_to() 2, shows_current(2) true (step 1), shows_current(1) false
  -- context.clock.run_for(0.1) -> shows_current(2) false (step 2); run_for(0.1) -> true (step 3)
  -- run_for(2.5) -> fading_to() nil, S.SCENE_TRANSITION.step nil, shows_current(2) true
end)
test("a superseded fade's target stops blinking at once", function()
  -- recall_scene(2, 2); run_for(0.1); recall_scene(3, 0) -> fading_to() nil, shows_current(3) true, shows_current(2) false
  -- recall_scene(2, 2); run_for(0.1); cancel_scene_transition() -> fading_to() nil, shows_current(3) true
end)
-- ui_header_test.lua, pages_scenes_test.lua, the three layout tests: at step 2 of that fade
--   the header draws "S2" at level 2; SCENES draws slot 2's number at level 4; each grid's recall key of scene 2 is 8
--   at step 3: 6, 15 and 15
```

**Step 2 expects:** FAIL: `S.lib.scenes.fading_to` is nil.

**Step 3 notes:** look at the SCENES renders and the header at both phases. The 64 has no scene keys.

**Commit:** `feat(scenes): the scene a fade goes to blinks until it lands (#254)`

---

## Wave 5

### Task 17 (#248): The hint row names what a held key's release will do

**Files:**
- Modify: `lib/pages/buffer.lua` (`buffer_hints`, the record's `animates`)
- Test: `test/unit/pages_buffer_test.lua`
- Docs: `docs/notes/lua/pages/buffer.md`, `docs/user/pages/buffer.md`, `docs/user/controls.md`, `changes/feat-248-buffer-hold-hint.md`

**Interfaces:**
- Consumes: Task 3 (a page change forgets `S.key_press_page`).
- Produces: a key counts as down for the hint while `S.key_press_page[n]` is BUFFER's index and the page noted its press time. While one is down, `buffer_hints` returns, before and from 0.5 s (`BUFFER_PAGE.hold_seconds`):
  - plain K2: `"K2 up: load"`, then `"K2 up: random"`;
  - ALT+K2: `"K2 up: clear"`, then `"K2 up: fill"`;
  - ALT+K3: `"K3 up: save"`, then `"K3 up: save loop"`.
  With none down the hints are as before. The record's `animates` is also true while such a key is down, so the row changes at 0.5 s with no clock of its own.

**Tests:**

```lua
test("the hint row names what a held key's release will do, and changes at 0.5 s", function()
  -- BUFFER; context.set_time(100); key(2, 1); redraw() -> hint_text "K2 up: load"; context.set_time(100.6); next_frame(context) -> "K2 up: random"; key(2, 0) (random_into stubbed) -> the page's own hints
  -- key(1, 1); key(2, 1) at 110 -> "K2 up: clear"; at 110.6 -> "K2 up: fill"; ALT+K3 at 120 -> "K3 up: save"; at 120.6 -> "K3 up: save loop"
  -- the record's animates() is true while the key is down and false after; assert_screen_layout passes at each text
end)
test("the menu opening ends the hold hint", function()
  -- key(2, 1) at 100; _menu.set_mode(true); _menu.set_mode(false); redraw() -> the page's own hints; animates() false (nothing moves on the slot)
  -- key(2, 1); show_page("SCENES"); show_page("BUFFER") -> the page's own hints
end)
```

**Step 2 expects:** FAIL: the hint reads `K2:ld/rnd K3:rec` while K2 is down.

**Commit:** `feat(buffer): the hint row names what a held key's release will do (#248)`

### Task 24 (#255): The overwrite prompt is the page's own

**Files:**
- Modify: `lib/pages/scenes.lua`
- Test: `test/unit/pages_scenes_test.lua`
- Docs: `docs/notes/lua/pages/scenes.md`, `docs/notes/lua/ui/header-and-flashes.md` (SCENES no longer uses the hints flash), `docs/user/pages/scenes.md`, `changes/fix-255-overwrite-prompt.md`

**Interfaces:**
- Produces: the confirmation is armed while `S.scenes_page.armed_slot` is the cursor's slot and `util.time() < S.scenes_page.armed_until`. `scenes_hints` returns the prompt (`"K3 again: overwrite S<n>"`) while armed, with or without ALT. Neither `draw` nor `hints` writes state or calls `S.lib.ui_flash`.
- Produces: the second ALT+K3 confirms when armed and no flash covers the hint row (`S.lib.ui_flash.text("hints") == nil`); otherwise it arms again. A cursor move disarms (`move_cursor`, as now, without touching the flash).
- Produces: the record's `animates`: false when nothing is armed; when the arming has lapsed it disarms and returns true once (the frame that removes the prompt); otherwise true.
- Produces: the page never starts or ends a `"hints"` flash; the `armed` layout state arms through `S.scenes_page`.
- Registers the invariant `"scenes prompt"`: `armed_slot` is nil or a slot in 1..`NUM_SCENES`.

**Tests:**

```lua
test("the overwrite prompt is the page's hint while armed and lapses after 2 s", function()
  -- a populated slot 1 under the cursor; ALT+K3 at 100 -> hint_text "K3 again: overwrite S1", nothing saved, S.lib.ui_flash.text("hints") nil
  -- context.set_time(102.1); next_frame(context) -> "K3:save" with ALT held; S.scenes_page.armed_slot nil
  -- ALT+K3 twice within 2 s -> saved (the header flashes "saved S1")
end)
test("a flash from another page neither erases the prompt nor confirms through it", function()
  -- armed at 100; buffer_page_flash("buf 1 load failed") -> hint_text still the prompt (the flash is BUFFER's)
  -- a "hints" flash with no page covers the row: ALT+K3 -> not saved, armed again; once it ends, ALT+K3 twice saves
end)
test("drawing SCENES asks for no redraw and ends no flash", function()
  -- a "hints" flash showing on SCENES; redraw() -> the flash still shows; UI_PAGES.screen_dirty is not set by the draw
end)
```

**Step 2 expects:** FAIL: the first test finds the prompt in `S.lib.ui_flash.text("hints")`.

**Step 3 notes:** the three existing prompt tests (`"the overwrite flash goes when the cursor leaves the slot by another route"`, `"a replaced overwrite prompt never confirms: ALT+K3 asks again"`, `"S.lib.pages_scenes.move_cursor moves, disarms and clears the prompt"`) keep their intent; change only the lines that read the flash, and list them in the report. As the last task to merge, also remove this plan's open item from `docs/status.md`.

**Commit:** `fix(scenes): the overwrite prompt is the page's own state, not a shared flash (#255)`

---

## Out of scope

- **Engine findings** #259 (what a frozen voice's grain synth reads), #260 (`inputReaders` never pruned), #261 (a stale `stopReplies`), #262 (`voiceOff` and `retrigger` unchecked): none is audible beyond a few milliseconds and each needs full engine-check runs, so they wait for the pre-4.0 review.
- **Stamping the press page in the grid core** (a release delivered only on the page of its press): Task 7's holders remove the one symptom it had; not planned.
- **A capture during a fade** stores the half-faded mix: Task 23's cue shows the fade; the capture itself is unchanged.
- **Enums or a state-machine library** in place of the flags: rejected for every machine (the flags are fix residue the tests read by name).

## Self-review notes

- **Spec coverage:** issues #232-#258 map to Tasks 1-27 in order; decisions 1-5 are Tasks 4, 8, 23, 17, and 26 with 27; decision 6 is "Coordination with 3.3".
- **Names across tasks:** `S.register_invariant` (1) is used by 7, 18, 22, 24, 25; `S.lib.sequencer.replace_pattern` and `end_port_step_gestures` (11); `layout_of` and `strip_level`'s third argument (8); `S.SCENE_TRANSITION.target`, `previous` (22) and `step`, `fading_to`, `shows_current` (23); `S.lib.scenes.save` (21) is what 24's confirmed save calls; `status` and `is_free` (16); `save_buffer`'s reasons (15); `recording_started(slot, playable)` (13) and `sent_start` (14).
- **Review Focus:** each of the five lines names its test, and each test is in its task's block (Tasks 4, 7, 8, 17, 20, 22, 23).

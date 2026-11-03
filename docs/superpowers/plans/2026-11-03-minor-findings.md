# Strata 3.0.1: Deferred Minor Findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every minor finding the 3.0 task reviews and final reviews deferred, so 3.0.1 has no known defects short of hardware tuning.

**Architecture:** No new features. Five tasks grouped by area: test and harness gaps, Lua UI/arc/key/MIDI polish, Lua buffer/scene/LFO state, engine robustness and smoothness, docs and CHANGELOG 3.0.1. Every behaviour change gets a test in `test/run.lua` or `test/engine_check.scd`.

**Tech Stack:** Lua 5.3 (norns matron) + LuaJIT, SuperCollider 3.13 (norns) / 3.14 (dev), harness `test/run.lua`, `test/norns_stubs.lua`, `test/sync_check.lua`, `test/run_engine_check.sh`; GitHub Actions jobs `lua` and `engine` (required on `main`).

**Spec:** The deferred findings listed in each task below (copied from the 3.0 review ledger), judged against `docs/superpowers/specs/2026-11-03-confluence-features-design.md` and CLAUDE.md. Where a finding says "tune on hardware" this plan fixes a decision instead, recorded under the task.

## Global Constraints

- Branch `minor-fixes` off `main`; land through a pull request (main is protected: `lua` and `engine` checks must pass, branch up to date).
- Lua/SC sync: every `engine.X(...)` has a matching `this.addCommand(\X, "sig")`; argument counts and types match; voice index `voice_idx - 1`; `test/sync_check.lua` passes after every task.
- Named constants only; `strata.lua` main chunk is at 183/200 locals: group any new constants into an existing table (`GRID_LAYOUT`, `BUFFER_PAGE`, `FX_PAGE`, `LFO_PAGE`, `ARC_LFO`, `MIDI`, `midi_state`) or a new one, never add a pile of top-level locals.
- All state changes through `params:set`; the `voices` table is the source of truth; engine writes only through param actions, `sync_voice_to_engine`, or `send_param_to_engine`.
- Stubs mirror the real norns libraries in `~/src/norns/lua`; check behaviour there before changing them.
- No new synth nodes per event; at most one releasing grain synth and one releasing voice synth per voice after each processed source switch; nothing leaks.
- Screen 128×64, no overlap at any value; every page has a hint row at y 62.
- Before each commit: `lua test/run.lua`, `luajit test/run.lua`, `lua test/sync_check.lua`, `test/run_engine_check.sh` all pass (run the engine check twice when timing-based checks change). Timing-based engine checks leave margin for a slow CI runner (JACK dummy driver, 1024-frame periods).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Every task updates CLAUDE.md/README.md for what it changes.

## Already resolved (verify, do not redo)

Fixed by later 3.0 work: placeholder-page hints (every page is built), retrigger velocity clamp (`msg[2].clip(0, 1)`), `saveBuffer` path standardisation (`writeSlot`), recording-slot stutter (`hasAudio` gate), `setGrainSource` sent first, BUFFER-page `fit_text` cache, re-gated buffer grain `bufFrames`/`bufRateScale`, local headroom, `releaseVoice` same-block leak (kill fade + opened gate), `grain_env` validation range (`DISCRETE_GRAIN_KEYS`). Task 1's implementer confirms each with one grep and lists them in the report.

## Review Focus

1. Scene recall with the per-voice sync suppressed (Task 3): after an instant recall and after a smooth transition, every running voice's engine state equals its Lua state — pinned by Task 3's `engine_state_for_voice` comparison after both recall kinds.
2. Buffer `loaded` from the poll (Task 3): a loaded sound file still shows its name before the poll arrives, and a take that captured nothing never shows as loaded — pinned in Task 3.
3. Arc ring rescale (Task 2): the LFO depth rings' whole-percent accumulation and the clocked-rate ring are unaffected; every other ring sweeps its range in the decided number of ticks — pinned in Task 2.
4. Grain node ordering (Task 4): after any sequence of source switches within a release window, every bus-reading grain synth runs before every mirroring one, and every grain synth before the voice's `\strataMod` — pinned in Task 4.
5. Input-source crossmod (Task 4): amplitude crossmod reaches an input-sourced voice and still does not double-apply on a synth-sourced voice — pinned in Task 4.

---

### Task 1: Test and harness gaps

**Files:**
- Modify: `test/run.lua`, `test/norns_stubs.lua`, `test/engine_check.scd`

**Interfaces:**
- Consumes: existing helpers `load_strata`, `local_value`, `engine_state_for_voice`, `assert_screen_layout`, `context.arc`, `context.midi.send`, `context.polls.fire`, `context.clock.advance`.
- Produces: a single param-type table in the stub; nothing later tasks call.

Findings (each a test that must exist and pass; where it fails, the defect it exposes belongs to this task):
1. "arc rings follow the page" asserts MAIN draws 4 rings, FX, LFO and BUFFER draw their 4 rings, SETUP none (count rings with at least one segment).
2. A smooth scene transition keeps `filter_type` at its start value at every step and lands on the target at the end.
3. Stub param type codes come from one table (`PARAM_TYPE_CODES`); the locals and `ParamSet` constants are built from it; an unknown `args.type` raises an error.
4. The static check for string comparisons of `param.t` also catches single quotes and reversed comparisons (`"option" == p.t`).
5. `bufferState` poll values NaN, +inf, -inf, -1 and 800 are ignored without error.
6. Remove the unused `before = deep_copy(buffers)` in the BUFFER arc test; the `v2_buf_pos` assertion compares against the value captured before the turn.
7. A slot cleared before exit is saved as `""` and not restored on the next start.
8. Fold the text-only LFO page test into the row-drawing test (one test, both assertions).
9. A MIDI-held voice stopped by K3, by the grid voice toggle, and by a scene recall: its later note-off changes nothing and leaves no held note recorded.
10. Engine check: a triggered-mode `\strataGrain` on a running synth voice is silent (peak < 0.001 over 0.3 s) with no trigger and sounds (peak > 0.01) after `retrigger`.

- [ ] **Step 1:** Write tests 1-10; run `lua test/run.lua` and `test/run_engine_check.sh`; record which fail.
- [ ] **Step 2:** Make the harness changes (3, 4); fix any product defect a new test exposes, minimally, and record it in the report.
- [ ] **Step 3:** All four checks pass (engine check twice).
- [ ] **Step 4:** Commit `test: close the deferred test gaps from the 3.0 reviews`.

---

### Task 2: UI, arc, keys and MIDI polish

**Files:**
- Modify: `strata.lua` (`arc_key`, `ARC_FX_RINGS`, `ARC_BUFFER_RINGS`, `MAIN_PARAMS` arc scales, `arc_lfo_delta`, `lfo_enc`, `buffer_key`, `redraw_buffer`, `forget_keys_held_through_menu`, MIDI pitchbend / `select_voice_by`)
- Modify: `test/run.lua`, `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: `UI_PAGES`, `ui_page`, `param_range`, `param_fraction`, `arc_whole_steps`, `midi_state`, `select_voice_by`, `save_buffer`.
- Produces: `MAIN_PAGE` (index of MAIN, in an existing table); `ARC_TICKS_PER_SWEEP` (in an existing table); `buffer_page_flash(text)` for a transient BUFFER hint.

Findings and decisions:
1. `arc_key` tests the page by index (`ui_page == MAIN_PAGE`), not by the string `"MAIN"`.
2. Arc ring speeds (decision replacing "tune on hardware"): every continuous ring on MAIN (rings 1-4), FX and BUFFER sweeps its param's whole range in `ARC_TICKS_PER_SWEEP` = 512 arc ticks (half a revolution of the arc's 1024 ticks; verify the tick count in `~/src/norns/lua/core/arc.lua` / monome docs and adjust the constant's comment, not the decision). Implement as a delta in normalized units (`params:delta` scaled so 512 ticks = full controlspec range, warp respected via `param_fraction` / `spec:map`). LFO depth rings keep `ARC_LFO.ticks_per_percent`; the clocked-rate ring keeps `ARC_LFO.ticks_per_rate`. Test: 512 ticks of +1 on each such ring moves its param from min to max (exp params included), 256 ticks to the controlspec midpoint of its warp.
3. LFO ring 4's carried remainder (`arc_lfo_ticks[4]`) resets when `selected_lfo` changes (E2 on the LFO page) and when the selected LFO's mode changes.
4. BUFFER page K2+K3 save shows a transient hint for 1.5 s: `saved buf <n>` after `save_buffer` sent a save, `buf <n> empty` when the slot reports 0 s (nothing saved). `buffer_page_flash(text)` stores the text and an expiry (`util.time()`), `redraw_buffer` draws it instead of the normal hint until it expires, a `clock.run` redraws once at expiry (cancelled in `cleanup`). Test both texts, the expiry, and `assert_screen_layout` with the flash shown.
5. Held keys through the norns menu: if `~/src/norns/lua/core/menu.lua` lets a script observe the menu opening (e.g. wrapping `_menu.set_mode` safely, restoring the original in `cleanup`), clear `key_press_page` and the K2-save flag there as well as in the 10 Hz tick; if no safe hook exists, keep the tick and document the <100 ms gap as a known limitation. Record which.
6. Omni-mode pitchbend follows the selection: when `selected_voice` changes in `omni to selected` mode while the wheel is off centre, the previously selected voice is re-centred (`bend` 1) and the current wheel value is applied to the newly selected voice. Test both.

- [ ] **Step 1:** Write the tests for 1-6; run, see them fail.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** All four checks pass; update README (arc speeds, save confirmation, omni bend) and CLAUDE.md (arc scale rule, flash, menu decision).
- [ ] **Step 4:** Commit `fix: arc ring speeds, BUFFER save confirmation, omni bend follows selection, page-index arc key`.

---

### Task 3: Buffer, scene and LFO state in Lua

**Files:**
- Modify: `strata.lua` (`record_buffer`, `finish_buffer_take`, `buffer_state_changed`, `load_buffers_from_disk`, `save_buffers_to_disk`, `redraw_setup`, `recall_scene_instant`, `v<i>_source` action, `drift_update`, `toggle_voice`, `add_voice_params`, `gentle_mutate`, `fx_fader_changed`)
- Modify: `test/run.lua`, `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: `buffers`, `buffers_restored`, `buffer_autosave_blocked`, `engine_param_value`, `DISCRETE_GRAIN_KEYS`, `scene_transition_active`, `sync_voice_values_to_engine`.
- Produces: `mean_reverting_step(current, base, step, reversion)`; a `scene_recall_in_progress` flag (in an existing state table if locals are tight).

Findings and decisions:
1. A take's `loaded`/name come from the engine: after a recording ends (timer or stop), the slot shows `REC`-finishing state (hint `...`) until the poll reports its seconds; seconds > 0 → `loaded = true`, `name = "take <n>"`, `path` = scratch take; 0 → back to empty. A record press while finishing is ignored (no new recording, no stop). Loading a file stays optimistic (name shown at once) but `loaded` clears if the poll later reports 0 s for that slot after the load. Tests: stop within the start-up window → slot ends empty; normal take → loaded after the poll; press during finishing → no engine call.
2. `buffers_restored` counts slots whose poll confirmed seconds > 0 after the restore; SETUP shows `buffers: k restored` from that count (and `, m missing` when remembered files are missing).
3. A remembered path whose file is missing is kept in `buffers.data` on the next exit (the slot stays empty and the console names it), so a sample on an unmounted drive comes back later. Test across two restarts.
4. `buffer_autosave_blocked` is reset at the top of `load_buffers_from_disk`.
5. Scene recall sets each voice's source without the source action's full `sync_voice_values_to_engine` (flag `scene_recall_in_progress`); after all params are set, each running voice whose source changed gets one `sync_voice_values_to_engine`. Test: instant recall and smooth transition both leave `engine_state_for_voice` equal to the Lua state for every running voice, and a recall that switches one voice's source sends at most one full sync for that voice.
6. `mean_reverting_step(current, base, step, reversion)` replaces the duplicated drift formula for grain pitch and `buf_pos` (behaviour identical; existing drift tests pass unchanged).
7. `toggle_voice`'s `voiceOn` grain density uses `engine_param_value` for both factors (same source as the sync).
8. `add_voice_params` builds every id as `prefix .. key`.
9. `gentle_mutate` skips any grain key in `DISCRETE_GRAIN_KEYS` by an explicit guard (a test mutates with every grain key present and probability 1).
10. `fx_fader_changed` does not redraw the grid while `scene_transition_active` (the transition loop redraws once per step); test counts grid redraws per transition step on page 4.

- [ ] **Step 1:** Write the tests for 1-10; run, see them fail (6-8 are refactors: existing tests must stay green).
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** All four checks pass; update README (buffer take states, restore counts, missing files) and CLAUDE.md (buffers table, scene recall sync, drift helper).
- [ ] **Step 4:** Commit `fix: engine-confirmed buffer takes and restores, one sync per scene recall, drift helper`.

---

### Task 4: Engine robustness and smoothness

**Files:**
- Modify: `lib/Engine_Strata.sc`, `test/engine_check.scd`, `CLAUDE.md`, `README.md`

**Interfaces:**
- Consumes: `startGrainSynth`, `replaceGrainSynth`, `cutFadingSynths`, `releasingSynths`, `bufferChanged`, `loadSlot`, `recordSlot`, `stopRecordSlot`, `clearSlot`, `writeSlot`, `interleaveFiles`, `controlPairs`, `grainControlPairs`.
- Produces: `slotChanges[i]` (per-slot change counter); per-def control-name cache built in `alloc`.

Findings and decisions:
1. Filter type changes crossfade: replace the `Select.ar` switch with three filters weighted by `(filterType.round == i).lag(0.02)` (sum = 1 in steady state). Engine check: a type change while mix = 1 produces no sample step larger than the steady-state signal's (compare max abs first difference across the change against the one before it on a sine input).
2. Grain-mode changes fade: `spreadLevel` gets `.lag(0.05)`; README states that position spread and grain density do nothing in triggered mode.
3. `stopRecord` followed by `clearBuffer` before the `/c_get` reply: a per-slot `slotChanges[i]` counter that load, record, clear and stop increment; the stop's reply applies only if the counter is unchanged. Engine check: stop then clear in the same call → `bufferFrames` stays 0 and no scratch write.
4. Grain node ordering holds for any switch history: bus-reading (synth-source) grain synths are added at the head of `processGroup`, mirroring (buffer and input) grain synths `\addBefore` the voice's live `\strataMod`; no grain synth is placed relative to a releasing synth (this also removes the `/s_new`-to-a-just-freed-target race). Engine check: switches 0→3→9→0 within 1 s, then every bus-reading grain synth precedes every mirroring one and all precede the voice's mod synth in `/g_queryTree` order.
5. `mirrorOut` is safe by default: both grain SynthDefs default `mirrorLevel = 0` and the engine sets it explicitly; `\strataGrainBuf` gains `mirrorLevel` (engine sets 1).
6. `controlPairs` uses a per-def control-name `Set` cached in `alloc`.
7. `loadSlot` sets `bufferFrames`, `bufferSampleRates`, the reading grain synths and the poll in the `readChannel` completion action, not before.
8. A failed newest write removes its `writeGenerations` entry; `alloc` deletes stale `*.part` files in `scratchDir`.
9. Crossmod reaches input-sourced voices: `\strataGrain` gains `modBus1..3`/`modAmpAmt1..3` applied to amplitude only when `modLevel = 1` (input source; synth source keeps 0 so the voice synth's crossmod is not doubled); frequency crossmod has no meaning for live input and is documented as ignored. Engine check: an input-sourced voice's grain synth reads its routed mod bus; a synth-sourced one has `modLevel` 0.
10. Interleave speed: replace the per-frame closure in `interleaveFiles` with an array-level interleave (e.g. `[left, right].lace(2 * n)` on each chunk); keep the 8192-frame chunking, yielding and generation checks. Engine check: an interleaved file equals the expected samples (existing WAV checks), and a 16 s write completes; report the before/after time.
11. Remove the stray double blank line after the master Limiter.
12. CLAUDE.md: a re-gated grain synth keeps the `PitchShift` window of the `grainSize` it was created with.

- [ ] **Step 1:** Write the engine checks for 1, 3, 4, 5, 9, 10; run `test/run_engine_check.sh`, see them fail.
- [ ] **Step 2:** Implement 1-12.
- [ ] **Step 3:** All four checks pass (engine check at least twice).
- [ ] **Step 4:** Commit `fix(engine): smooth filter and grain-mode switches, safe ordering and defaults, record/clear race, input crossmod, faster save`.

---

### Task 5: Docs and CHANGELOG 3.0.1

**Files:**
- Modify: `CHANGELOG.md`, `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: nothing.

Findings:
1. CHANGELOG 3.0 "Deviations" gains R7 (grain-side accent only for the input source), R8 (input grain synth mirrors to the voice bus) and R9 (scratch directory is an engine variable).
2. README: the grain-processor sentence says **pan spread** (not position spread) is shared by both grain synths; the LFO params note about `lfo_min`/`lfo_max`/`lfo_baseline` is its own sentence, not run into the param list.
3. CHANGELOG `## Version 3.0.1` (2026-11-03): one bullet per user-visible fix from Tasks 2-4 plus a line for the test additions; CLAUDE.md Version History gains a matching 3.0.1 entry.
4. Every claim the earlier tasks touched is consistent across README, CLAUDE.md and CHANGELOG; the CLAUDE.md command table still matches the engine (the docs test enforces it).

- [ ] **Step 1:** Edit the three files.
- [ ] **Step 2:** All four checks pass.
- [ ] **Step 3:** Commit `docs: 3.0.1 changelog and doc fixes`.

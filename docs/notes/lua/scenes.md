## Must not break

- A new captured field needs `validate_scene` coverage (and a `SCENE_GLOBAL_PARAMS` entry for a global param) and a migration default (`SCENE_GLOBAL_PARAMS.default`, `S.VOICE_SCENE_DEFAULTS` or `S.SCENE_BLOCK_DEFAULTS`), or older files stop loading.
- Discrete keys (`DISCRETE_GRAIN_KEYS`, source, mod sources, freeze and active states, tempo, filter type, mutation and LFO settings) switch at the end of a transition, never crossfade. Continuous params fade linearly from start values snapshotted once.
- A recall stops the voices it stops before setting their sources and params, starts the voices it starts after their params, and sends at most one full sync per running voice whose source changed (`S.scene_recall_in_progress`).
- Every recall cancels a running transition first. The transition clock clears `S.scene_transition_active` and `S.scene_transition_clock` on every exit (end, cancel, error).
- The sequencer never cuts a transition short. It waits for the transition's end, bounded by `SCENE_TRANSITION.overrun_seconds` measured from the fade's progress, never from its start.
- `load_scenes_from_disk` runs `tab.load` through `pcall`. On any failure it keeps the current scenes and moves the file aside, or blocks the autosave (`S.scene_autosave_blocked`), so a bad file is never overwritten.
- Bounds-check the scene number (1..`NUM_SCENES`) and check the slot is populated before recalling.

## Owns

`lib/scenes.lua` (`S.lib.scenes`) holds the whole scene system:
- `S.scenes`, `S.current_scene`, and the sequencer and transition state on `S` (`S.scene_sequencer_clock`, `S.scene_sequencer_enabled`, `S.scene_sequencer_position`, `S.scene_transition_clock`, `S.scene_transition_active`, `S.scene_recall_in_progress`, `S.scene_autosave_blocked`, `S.scenes_loaded`);
- `S.SCENE_GLOBAL_PARAMS`, `S.VOICE_SCENE_DEFAULTS`, `S.SCENE_BLOCK_DEFAULTS`, `S.SCENE_TRANSITION`;
- capture, recall, transitions, the scene sequencer, migration, validation and scenes.data;
- the global `with_traceback` error handler;
- `S.lib.scenes.scene_data_dir` and `S.lib.scenes.move_aside_unloadable_file`, used by `lib/buffers.lua`;
- cleanup steps 30 (save the scenes), 100 (the sequencer) and 110 (the transition).

Patterns are `S.patterns` (`lib/sequencer.lua`). The grid's scene page is in `docs/notes/lua/grid-and-sequencer.md`, the header's scene indicator in `docs/notes/lua/ui-and-pages.md`.

## What a scene holds

- **Storage**: `S.scenes`, 8 slots (1-8). The `lib/scenes.lua` constructor builds the array afresh on every script load, empty by default.
- **Data**, a complete snapshot:
  - every voice parameter (synthesis, granular including the buffer params, cross-modulation) and each voice's source (not buffer contents);
  - voice active and freeze states;
  - pattern data (all 7 voices × 16 steps);
  - global parameters: master density, tempo, filter, delay, reverb, drift, mutations, and each LFO's shape, mode, rate, depth, destination and state.
- **Sequencer**: automatic scene progression with configurable timing.
- **Transitions**: instant recall, or a smooth crossfade between scenes.

## Capture

`capture_scene(scene_num)`:

```lua
function capture_scene(scene_num)
  -- Captures the complete current state:
  -- - all voice parameters (params, grain, crossmod)
  -- - voice active/frozen states
  -- - all pattern data
  -- - global parameters (density, tempo, reverb, mutations, etc.)
  S.scenes[scene_num].data = scene_data
  S.scenes[scene_num].populated = true
end
```

- Deep copies every value (no references).
- Keeps both the `S.voices` state and the norns param values.
- Copies patterns step by step, to avoid shared references.
- Stores a new table each time, so capturing into a slot during a fade does not change that fade's end.

## Recall

`recall_scene(scene_num, transition_time)`:

```lua
function recall_scene(scene_num, transition_time)
  -- Validates the slot (validate_scene) and cancels any running transition
  -- Instant recall (transition_time = 0) -> recall_scene_instant()
  -- OR smooth transition (transition_time > 0)
  --   - start values snapshotted once by scene_transition_targets()
  --   - SCENE_TRANSITION.steps (20) steps of util.linlin(0, 1, start, target, step / steps)
  --   - only continuous params fade; the rest switch at the end
end
```

Bounds check first:

```lua
function recall_scene(scene_num, transition_time)
  if scene_num < 1 or scene_num > NUM_SCENES then return end
  if not S.scenes[scene_num].populated then
    print("scene " .. scene_num .. " is empty")
    return
  end
  -- safe to proceed
end
```

Voice activation:
- checks whether a voice's state needs to change (on → off or off → on);
- starts and stops voices with `toggle_voice()`;
- restores freeze states with the scene.

Patterns:
- restored after all parameter changes;
- `grid_redraw()` is called so the grid shows them;
- the pattern sequencer keeps playing if it was running.

### Source changes and the full sync

`recall_scene_instant` sets `S.scene_recall_in_progress` while it sets params:
- The body runs in an `xpcall` with `with_traceback`. The flag is always cleared, the end-of-recall syncs run for whatever was applied before an error, and only then is the error raised again with `error(recall_error, 0)`, so the engine never lags the Lua state.
- While the flag is set, the `v<i>_source` action sends `setGrainSource` but not its `sync_voice_values_to_engine` (which would send the old values to the new grain synth before the recalled ones).
- After every param is set and the flag is cleared, each voice that is running and whose source changed gets one `sync_voice_values_to_engine`. A voice the recall starts is synced by `toggle_voice` instead.

Order of voice changes (#46):
- A voice the recall stops is stopped (`toggle_voice`) before its source and params are set, so its release tail keeps the outgoing scene's values (param actions reach the engine only while a voice is active).
- A voice the recall starts is started after its params.
- The engine only records a stopped voice's source, so a recall never builds a grain synth for the new source only to release it at once. Scenes on/synth, off/input, on/buffer recalled in quick succession used to leave the engine more synths than its real-time memory bound (see Real-time memory in `docs/notes/engine.md`).

So a recall sends at most one full sync per voice, after its params. An instant recall and a smooth transition (which ends in `recall_scene_instant`) both leave the engine with the Lua state of every running voice.

A failed instant recall keeps the previous scene current (`docs/status.md`, Decisions).

### Smooth transitions

- `scene_transition_targets(scene_data)` snapshots `{id, start, target, step}` for every continuous param *once*, before the fade: voice params, grain params, crossmod amp/freq amounts, mod speed, and the continuous globals in `SCENE_GLOBAL_PARAMS` (master density, filter freq/res/mix, delay time/feedback/mix, reverb, drift).
- 20 steps whatever the transition time. Step k sets `util.linlin(0, 1, start, target, k / 20)`, so the fade is linear over the whole time. Never re-read the current value inside the loop: that makes the fade front-loaded.
- A number param (`step` 1: the LFO depths `lfo_depth_<n>`, which do not round themselves) is rounded to whole numbers during the fade, so arc and E3 depth steps land on whole percents again. The end applies the scene's exact value.
- Not interpolated: mod sources, grain envelope shapes and grain modes (`DISCRETE_GRAIN_KEYS`), freeze and active states, tempo, filter type and mutation settings. They switch at the end through `recall_scene_instant()`, which also lands every param exactly on its target.
- Any recall calls `cancel_scene_transition()` first, which cancels the clock and clears `S.scene_transition_active`.
- `S.scene_transition_clock` / `S.scene_transition_active` track the running transition; `cancel_scene_transition()` clears both.
- A successful `load_scenes_from_disk()` cancels a running transition before it replaces the scenes. Otherwise the fade's end would apply the file's data for that slot, or fail on a slot that is now empty. The fade stops where it is.

The transition clock clears `S.scene_transition_active` and `S.scene_transition_clock` on every exit:
- at its end, before `recall_scene_instant`, which it passes the scene data it read when the fade started;
- when canceled;
- when a param action raises an error during a fade step. Each step runs in an `xpcall` with the global handler `with_traceback`, outside the `clock.sleep`, and the error is raised again with its traceback, so maiden shows where the param action failed. `with_traceback` adds a traceback only when the message has none yet.

## Scene sequencer

`scene_sequencer_start()`:

```lua
function scene_sequencer_start()
  S.scene_sequencer_clock = clock.run(function()
    clock.sleep(0)  -- start on the next scheduler tick (after a PSET read)
    while S.scene_sequencer_enabled do
      recall_scene(S.scene_sequencer_position, transition_time)
      local held = math.max(scene_duration, transition_time)
      clock.sleep(held)
      wait_for_scene_transition()
      -- wrap with the length as it is now
      S.scene_sequencer_position = S.scene_sequencer_position + 1
      if S.scene_sequencer_position > params:get("scene_sequence_length") then S.scene_sequencer_position = 1 end
    end
  end)
end
```

Timing:
- Everything that does not fade is applied only by the `recall_scene_instant` at the end of the fade, and the next recall cancels a running fade first. So the sequencer never cuts a transition short.
- A scene lasts `max(scene_duration, transition_time)`.
- Then the sequencer waits, checking every `SCENE_TRANSITION.settle_seconds` (0.01 s), until `S.scene_transition_active` clears. The fade's 20 sleeps add up scheduling delay, so with equal times the sequencer would otherwise wake first.
- It also waits for a transition started by a manual recall.
- A manual recall still cancels a running transition (the sequencer's or its own).
- An empty scene is skipped after `scene_duration` alone (no transition starts).

The bounded wait (`wait_for_scene_transition`), so a transition whose clock is gone cannot stop the sequencer:
- A transition whose next step (or end) is `SCENE_TRANSITION.overrun_seconds` (1 s) late is canceled (`cancel_scene_transition`, with a console message), and the sequencer moves on.
- The bound follows the fade's progress, not its start. The transition clock records in `SCENE_TRANSITION.next_step_due` the `util.time()` at which its next step or its end is due: set when the transition starts and before each step's sleep, nil when no transition runs.
- So a healthy fade whose 21 wake-ups each run late under load (60 ms each puts a 16 s fade's end 1.3 s past its transition time) is never cut short, and one that stalls is caught `overrun_seconds` after its next step was due.
- The same applies to a transition the sequencer did not start (a manual recall's) or one left running because the sequencer's own recall failed validation.

Errors:
- An error in the sequencer's own recall (an instant recall, or the first fade step, which runs inside the sequencer's clock) is caught there with `xpcall` and printed with its traceback (`scene sequencer: scene <n> failed: ...`). The sequencer keeps going.
- That is safe: the recall has already cleared `S.scene_transition_active`, `S.scene_transition_clock` and `S.scene_recall_in_progress`, and the next scene may recall fine (stopping would end a long ambient run over one bad action).
- A failing scene still holds for its duration, so a repeating error prints at most once per scene.
- Errors in later fade steps are raised in the transition's clock, not the sequencer's.

Length and PSET loads:
- The sequencer advances with the `scene_sequence_length` it reads after the wait, so a sequence shortened while a scene plays wraps to scene 1 (it never jumps to the new last scene).
- Its clock does nothing until the next scheduler tick (`clock.sleep(0)`). norns' `params:read` (a PSET load from the PARAMS menu) sets params one by one in file order, and `scene_sequencer_enabled` comes before the transition time, duration, length, FX, LFO and voice params. Started inside the read, the sequencer would recall scene 1 with the old transition time and the PSET's later lines would then overwrite it. On the next tick the read has finished.
- `scene_sequencer_start` and `pattern_clock_start` cancel their running clock before starting a new one (tests check that a restart leaves one clock).
- The `scene_sequencer_enabled` param action starts and stops the sequencer. Cleanup step 100 stops it through that param, then `scene_sequencer_stop()`.

## Parameters

In the PARAMS menu (strata_scenes section):
- `scene_sequencer_enabled` (binary): start/stop automatic scene progression.
- `scene_transition_time` (0-30 s, default 2 s): crossfade duration for smooth transitions.
- `scene_duration` (4-120 s, default 16 s): how long each scene plays before advancing.
- `scene_sequence_length` (1-8, default 4): how many scenes to cycle through.
- Triggers "save scenes to disk" and "load scenes from disk".

## Disk persistence

- **Location**: `~/dust/data/strata/scenes.data`.
- **Format**: a Lua table serialized with norns' `tab` library: `{version = SCENE_DATA_VERSION, scenes = {...}}` (version 2).
  - Version 1 files (`{version = 1, ...}`, or the bare scenes array written before 2.1) are migrated on load and print `migrated scenes file from version 1`. The next save writes version 2.
  - Any other version is rejected.
- **Migration**: `load_scenes_from_disk()` runs `migrate_scene(scene, from_version)` on every loaded slot before `validate_scene_data()`.
  - It fills only what is missing, so it runs for every version.
  - Each global from its `SCENE_GLOBAL_PARAMS` entry's `default` (the param default).
  - Top-level blocks from `S.SCENE_BLOCK_DEFAULTS` (`{key, default}`).
  - Per-voice fields from `S.VOICE_SCENE_DEFAULTS` (`{path = keys inside data.voices[i], default}`), filled only when the parent table exists.
  - Malformed scenes are left for validation to reject.
  - A later scene field adds its default to one of these tables. `S.VOICE_SCENE_DEFAULTS` holds the grain envelope and mode, `source` and the three buffer params. `S.SCENE_BLOCK_DEFAULTS` is empty: the LFO settings are globals in `SCENE_GLOBAL_PARAMS`.
- **Robust loading**: `tab.load` runs the file as Lua unprotected, so `load_scenes_from_disk()` calls it through `pcall`.
  - On any failure (error, unknown version, invalid data after migration) it prints a message and keeps the current scenes (empty at startup).
  - It preserves the file: it is renamed to `scenes.data.bak`, so the save in `cleanup()` cannot destroy it. If the rename fails, `S.scene_autosave_blocked` makes `cleanup()` skip the auto-save.
  - Missing slots in a valid file are filled with empty scenes.
- **Auto-save**: `cleanup()` saves the scenes when the script exits (step 30), but only once `load_scenes_from_disk()` has run in this session (`S.scenes_loaded`, set when it returns). A start that failed before init's loads (the engine did not load, an error earlier in `init`) therefore never overwrites the saved file with the empty in-memory state (#72). buffers.data has the same guard (`docs/notes/lua/buffers.md`).
- **Auto-load**: its start step (`START_ORDER.scenes_load`) loads them at init, before the buffers.
- **Manual**: the PARAMS triggers "save scenes to disk" and "load scenes from disk"; SETUP K3 saves.
- **What is saved**: all 8 slots, their populated state and their data. Scenes persist across reboots, building a library of sonic palettes.

## Validation

Always validate scene data before using it, so a corrupted file cannot crash the script.

`validate_scene(scene)` checks one slot; `validate_scene_data(scene_table)` checks every present slot of a loaded table (missing slots are allowed and filled on load). A populated scene must contain everything `recall_scene_instant()` reads:

```lua
-- every SCENE_GLOBAL_PARAMS id is a number (master_density, tempo, mutation_*, filter_*, delay_*, reverb_*,
--   drift_amount, and per LFO lfo_shape/mode/clocked/free/depth_<n>, strata_lfo<n>_dest, lfo_<n>);
--   an option param's value is an integer from 1 to its option count
-- data.voices: NUM_VOICES tables, each with
--   active (boolean), source (integer 1..#SOURCE_OPTIONS), params (only known keys, numbers),
--   grain (only GRAIN_PARAM_IDS keys, numbers; env/mode integers 1..option count),
--   crossmod.slot1..3 {source = integer 0..NUM_VOICES, amp_amt, freq_amt numbers}, crossmod.speed number
-- data.frozen: NUM_VOICES booleans
-- data.patterns: NUM_VOICES x PATTERN_LENGTH integers 0..15
```

When adding a field to `capture_scene()`:
- add it to `validate_scene()` (and to `SCENE_GLOBAL_PARAMS`, with its `default`, for a global param), or recall will not restore it;
- give it a migration default (`SCENE_GLOBAL_PARAMS.default`, `S.VOICE_SCENE_DEFAULTS` or `S.SCENE_BLOCK_DEFAULTS`), so older files still load.

When to validate:
- always before loading scenes from disk (`load_scenes_from_disk`);
- before recalling (`recall_scene` calls `validate_scene`);
- after receiving scene data from any other source.

Error handling patterns:

```lua
-- Graceful degradation with console messages
if not scene_data or not scene_data.voices then
  print("error: scene " .. scene_num .. " has invalid data")
  return
end

-- Nil-safe iteration
if scene_data.voices[i] and scene_data.voices[i].params then
  for key, target_val in pairs(scene_data.voices[i].params) do
    -- safe to access
  end
end
```

## Usage

Manual performance, from grid page 3:
1. Build a sound.
2. Press a row 3 button to save it to a scene slot.
3. Change parameters.
4. Save to another slot.
5. Press row 1 buttons to switch between scenes instantly.
6. Press row 2 buttons to crossfade between scenes.

Automatic sequencing:

```lua
params:set("scene_transition_time", 3)    -- 3 second crossfades
params:set("scene_duration", 20)          -- 20 seconds per scene
params:set("scene_sequence_length", 4)    -- cycle through scenes 1-4
params:set("scene_sequencer_enabled", 1)  -- start the sequencer
-- Result: scenes 1→2→3→4→1... with 3 s crossfades, 20 s each
```

Composition workflow:
1. Create 4-8 distinct scenes with different voice combinations and parameters.
2. Set the transition time (0 s for rhythmic changes, 5-10 s for ambient evolution).
3. Set the scene duration for the pacing you want.
4. Enable the sequencer for hands-free long-form composition.
5. Mutations still evolve non-frozen voices during scenes.

## With other systems

- **Freeze**: frozen states are captured and restored per scene.
- **Mutations**: mutation settings are per scene, so the sequencer can alternate between static and evolving scenes.
- **Pattern sequencer**: pattern data is saved per scene, so scenes can switch rhythms.
- **Cross-modulation**: routing is per scene, for evolving relationships between voices.
- **Drift**: keeps running during scenes unless voices are frozen. The global LFOs keep running with the LFO settings the scene recalled.

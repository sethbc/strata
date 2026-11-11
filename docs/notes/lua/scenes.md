## Must not break

- A new captured field needs `validate_scene` coverage (and a `SCENE_GLOBAL_PARAMS` entry for a global param) and a migration default (`SCENE_GLOBAL_PARAMS.default`, `S.VOICE_SCENE_DEFAULTS` or `S.SCENE_BLOCK_DEFAULTS`), or older files stop loading.
- Discrete keys (`DISCRETE_GRAIN_KEYS`, source, mod sources, lock and active states, tempo, filter type, mutation and LFO settings) switch at the end of a transition, never crossfade. Continuous params fade linearly from start values snapshotted once.
- A recall stops the voices it stops before setting their sources and params, starts the voices it starts after their params, and sends at most one full sync per running voice whose source changed (`S.scene_recall_in_progress`).
- Every recall clears the randomize undo (`clear_undo`, `lib/mutation.lua`): `recall_scene` after validation, `recall_scene_instant` at its start.
- Every recall cancels a running transition first. Every exit of a transition (end, cancel, error) goes through the one local `end_scene_transition(how)`, which clears `S.scene_transition_active`, `S.scene_transition_clock` and the `SCENE_TRANSITION` fields together (#253). A fade that does not land puts the previous scene back as current, never leaving its target current; a landing keeps the target current while `recall_scene_instant` applies it, so no redraw during the landing shows the previous scene, and puts the previous scene back only if that recall fails. Inside the transition's clock its id is forgotten, never canceled.
- Every display of the current scene (the header's `S<n>`, SCENES' slot, the grids' recall keys) asks `S.lib.scenes.shows_current(slot)`, never compares with `S.current_scene` itself, so the scene a fade goes to blinks on all of them alike and is steady once it lands (#254). `SCENE_TRANSITION.step` is set before each step's redraws and cleared by `end_scene_transition` before a landing applies its scene.
- The sequencer never cuts a transition short. It waits for the transition's end, bounded by `SCENE_TRANSITION.overrun_seconds` measured from the fade's progress, never from its start.
- `load_scenes_from_disk` reads the file through `S.lib.data_files.read`, which parses it and never runs it as Lua (#464, `docs/notes/lua/data-files.md`); never `tab.load`. On any failure it keeps the current scenes and moves the file aside to its first free backup name (`.bak`, `.bak.2` ... `.bak.9`, never over an earlier backup, #466), or blocks the autosave (`S.scene_autosave_blocked`), so a bad file is never overwritten.
- scenes.data is written only by `save_scenes_to_disk`, through `S.lib.data_files.write` (a checked `.part` renamed into place, nothing written when the file holds the same bytes, #301); never `tab.save`. A failed write leaves the file as it was and never prints `saved`; it sets `S.scene_file.problem = "not saved"` and `unsaved`.
- Every user's scene save (`S.lib.scenes.save`) writes the file at once through `S.lib.scenes.autosave` (#327), and its header flash says `saved S<n>` only when the scene is on disk, `S<n> not on disk` otherwise (a failed or blocked write). `S.scene_file.unsaved` is true exactly while a scene captured in this session may not be in the file; set it wherever a scene reaches memory without reaching the file.
- A load the player asks for goes through `S.lib.scenes.request_load` (SETUP's K3, the PARAMS trigger), which asks for a second request within `SCENE_LOAD.confirm_seconds` (2 s) while `S.scene_file.unsaved`, and loads at once otherwise (#328). init's load calls `load_scenes_from_disk` directly.
- A file of an older format is kept as `scenes.data.v<n>` (`keep_copy`) before the first save replaces it, and a failure to keep it fails the save (#467): at every instant scenes.data is the old file or the new one, whole.
- A load keeps `S.current_scene` only when the file's scene in that slot encodes to the same text as the one it replaces (`S.lib.data_files.encode`); otherwise it is 0 (#518).
- Bounds-check the scene number (1..`NUM_SCENES`) and check the slot is populated before recalling.
- The registered fields are read at init, never at include time: `S.registry.scene_fields` joins `S.SCENE_GLOBAL_PARAMS` in the scenes load's start step (before the file is read), and the voice params' scene keys (`S.registry.voice_params`) are read at each capture, transition, recall, migration and validation.
- Each LFO's `lfo_offset_<n>` is set before its `lfo_<n>` (#103). The state switch (at a transition's end, or in an instant recall) re-bangs the library's baseline, which zeroes the offset, and `lib/lfos.lua`'s `lfo_<n>` wrapper puts the recalled offset back. Never drop that wrapper or move the offset after the state without a test.
- A registered voice param's scene key needs its default in `scene_defaults` (the param's default; a test checks), and a key that must not crossfade needs a whole `{min, max}` in `discrete`. Discrete extras are set at a transition's end, after the voice's source.

## Owns

`lib/scenes.lua` (`S.lib.scenes`) holds the whole scene system:
- `S.scenes`, `S.current_scene`, and the sequencer and transition state on `S` (`S.scene_sequencer_clock`, `S.scene_sequencer_enabled`, `S.scene_sequencer_position`, `S.scene_sequencer_recall_due`, `S.scene_transition_clock`, `S.scene_transition_active`, `S.scene_recall_in_progress`, `S.scene_autosave_blocked`, `S.scenes_loaded`, `S.scene_file`);
- `S.lib.scenes.autosave()`, `S.lib.scenes.request_load()` and `S.lib.scenes.SCENE_LOAD` (Disk persistence, below);
- `S.SCENE_GLOBAL_PARAMS`, `S.VOICE_SCENE_DEFAULTS`, `S.SCENE_BLOCK_DEFAULTS`, `S.SCENE_TRANSITION` (with a running fade's `next_step_due`, `target`, `previous` and `step`);
- `S.lib.scenes.fading_to()` (the scene a running fade goes to, else nil) and `S.lib.scenes.shows_current(slot)` (whether the displays light the slot as the current scene);
- `S.lib.scenes.sequencer_next_slot()` (#303): the slot the running sequencer recalls next, else nil. While `S.scene_sequencer_recall_due` (set by `scene_sequencer_start` and each advance, cleared by the loop just before it recalls or skips the position, and by `scene_sequencer_stop`) it is the position (1 past `scene_sequence_length`, as the loop's guard); otherwise the position + 1, wrapped to 1 past the length as it is now, as the advance does. Through a hold the position is the scene playing (or the empty slot it waits on), so the grids' scene pages light this one at 10, never the position. The skip of an empty slot redraws the grids, so the light moves on there too. The "scene sequencer" invariant: no recall is due while the sequencer is off;
- capture, recall, transitions, the scene sequencer, migration, validation and scenes.data;
- the global `with_traceback` error handler;
- `S.lib.scenes.scene_data_dir`, `S.lib.scenes.move_aside_unloadable_file` and `SCENE_LOAD.start_flash_seconds`, used by `lib/buffers.lua`;
- cleanup steps 30 (save the scenes), 100 (the sequencer) and 110 (the transition).

Patterns are `S.patterns` (`lib/sequencer.lua`). The grid's scene pages are in `docs/notes/lua/grid/layout_256.md` and `docs/notes/lua/grid/layout_128h.md`, the header's scene indicator in `docs/notes/lua/ui/header-and-flashes.md`.

## What a scene holds

- **Storage**: `S.scenes`, 8 slots (1-8). The `lib/scenes.lua` constructor builds the array afresh on every script load, empty by default.
- **Data**, a complete snapshot:
  - every voice parameter (synthesis, granular including the buffer params, cross-modulation) and each voice's source (not buffer contents);
  - voice active and lock states (stored as `frozen`);
  - pattern data (all 7 voices × 16 steps);
  - global parameters: master density, tempo, filter, delay, reverb, drift, mutations, and each LFO's shape, mode, rate, depth, offset, destination and state;
  - format 3 (3.2): each voice's registered params (`data.voices[i].extras[key]`, the keys of every record's `scene_defaults`), the registered global fields (`S.registry.scene_fields`, stored like the other globals) and each LFO's offset (`lfo_offset_<n>`, #103).
- **Sequencer**: automatic scene progression with configurable timing.
- **Transitions**: instant recall, or a smooth crossfade between scenes.

## Capture

`S.lib.scenes.save(scene_num)` is the user's save (the grid's hold and SCENES' ALT+K3): for a slot in 1..`NUM_SCENES` it calls `capture_scene`, writes scenes.data (`S.lib.scenes.autosave`, #327), flashes `saved S<n>` in the header when the scene is on disk or `S<n> not on disk` when the write failed or was blocked, redraws grid and screen and returns true; any other slot does nothing and returns false. `capture_scene` itself stays silent and writes nothing (tests and layout states call it).

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
- restores lock states (stored as `frozen`) with the scene.

Patterns:
- restored after all parameter changes, each voice's through `S.lib.sequencer.replace_pattern` (which ends a step held on the grid, #242);
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
- The engine only records a stopped voice's source, so a recall never builds a grain synth for the new source only to release it at once. Scenes on/synth, off/input, on/buffer recalled in quick succession used to leave the engine more synths than its real-time memory bound (see Real-time memory in `docs/notes/engine/memory.md`).

So a recall sends at most one full sync per voice, after its params. An instant recall and a smooth transition (which ends in `recall_scene_instant`) both leave the engine with the Lua state of every running voice.

A failed instant recall keeps the previous scene current (`docs/decisions.md`, 3.0.2), and a fade that does not land puts it back (#253, below). A failed `recall_scene_instant(scene_num, scene_data, current_if_failed)` never makes its scene current: it sets `S.current_scene` to `current_if_failed` when one is given (a fade's landing passes its `previous`; nil leaves the current scene as it is), then redraws the screen and grids once and raises its error, so they show the scene that is current and whatever was applied.

### Smooth transitions

- `scene_transition_targets(scene_data)` snapshots `{id, start, target, step}` for every continuous param *once*, before the fade: voice params, grain params, crossmod amp/freq amounts, mod speed, and the continuous globals in `SCENE_GLOBAL_PARAMS` (master density, filter freq/res/mix, delay time/feedback/mix, reverb, drift, and per LFO the free period, depth and offset).
- 20 steps whatever the transition time. Step k sets `util.linlin(0, 1, start, target, k / 20)`, so the fade is linear over the whole time. Never re-read the current value inside the loop: that makes the fade front-loaded.
- A number param (`step` 1: the LFO depths `lfo_depth_<n>` and offsets `lfo_offset_<n>`, which do not round themselves) is rounded to whole numbers during the fade, so arc and E3 depth and offset steps land on whole percents again. The end applies the scene's exact value.
- Not interpolated: mod sources, grain envelope shapes and grain modes (`DISCRETE_GRAIN_KEYS`), lock and active states, tempo, filter type and mutation settings, a registered voice param's discrete keys (`discrete`) and a registered field with `discrete = true`. They switch at the end through `recall_scene_instant()`, which also lands every param exactly on its target.
- The registered voice params that are not discrete crossfade like the built-in ones (`scene_transition_targets`, by key name); a registered field without `discrete` crossfades with the continuous globals.
- `recall_scene_instant` sets a voice's extras (by key name) after its source, params, grain and crossmod values, so a discrete one such as freeze lands after the source it belongs to.
- Any recall ends a running transition first (`end_scene_transition("superseded")`, which cancels the clock without a redraw, as the recall redraws itself).
- `S.scene_transition_clock` / `S.scene_transition_active` track the running transition; `cancel_scene_transition()` ends it.
- The fade cue (#254): each step sets `SCENE_TRANSITION.step` to its number (1 to 20; the first runs inside the recall) after its params and before its `request_redraw()` and `grid_redraw()`. `shows_current(slot)` is true when `slot == S.current_scene` and either `fading_to()` is not the slot or `step` is nil or odd, so the target is lit from the recall (while step 1 sets its params, before it sets `step`, a param action's direct `grid_redraw` lights it too) and after steps 1, 3, 5, ..., and dark after the even ones: a 2 s fade changes every 0.1 s. Dark is each display's level without the current scene: the header's `S<n>` at 2 (its level is 10 with the scene sequencer on, 6 without), SCENES' slot at 4, a recall key at 8 (populated) or 10 (the slot the sequencer recalls next). `end_scene_transition` clears `step`, so a landing's redraws, a cancel and a superseding recall all show the current scene steady.
- A successful `load_scenes_from_disk()` cancels a running transition before it replaces the scenes. Otherwise the fade's end would apply the file's data for that slot, or fail on a slot that is now empty. The fade stops where it is. The cancel puts the previous scene back as current; the load then keeps it current only if the file holds the same scene in its slot (#518).

#### States

| State | `S.scene_transition_active` | `SCENE_TRANSITION.next_step_due` | `SCENE_TRANSITION.target` | `SCENE_TRANSITION.previous` | `SCENE_TRANSITION.step` | `S.scene_transition_clock` | `S.current_scene` |
|-------|-----|-----|-----|-----|-----|-----|-----|
| idle | false | nil | nil | nil | nil | nil | the last scene that landed (0 = none) |
| fading | true | the `util.time()` its next step or end is due | the scene it goes to | the current scene before it | the number of the step applied last (1-20) | its clock (or a lost id, which the sequencer's overrun ends) | `target` |

- idle to fading: `recall_scene(n, t)` with `t > 0`, after ending any running transition. Before the first step runs it sets five of the seven columns, in this order: `S.scene_transition_active` (true), `next_step_due` (now), `target` (n), `previous` (`S.current_scene`) and `S.current_scene` (n), so the first step's redraw lights the target. The first step, which runs inside `clock.run`, sets `step` (1) before its redraws. The seventh, `S.scene_transition_clock`, is assigned when `clock.run` returns, after the first step (nil while it runs).
- fading to fading: each later step sets `step` to its number before its redraws (the only write of `step` outside `end_scene_transition`).
- fading to idle: only `end_scene_transition(how)`, local to `lib/scenes.lua`. It clears every field and returns the fade's `previous`. How it ends:
  - `"canceled"`: `cancel_scene_transition()` (the sequencer's overrun, a scenes file load, cleanup). It cancels the clock, sets `S.current_scene` back to `previous`, and redraws the screen (`request_redraw()`) and grids (`grid_redraw()`) whenever a fade was running, also a fade back to the current scene: its blink phase (`step`) ended, so a mark left dark at an even step is lit again.
  - `"superseded"`: a new recall. The same, without the redraw: the recall redraws itself (and a failed `recall_scene_instant` redraws before it raises).
  - `"failed"`: a fade step's error, inside the clock. The id is forgotten; `previous` is put back and the screen and grids are redrawn (as for a cancel, also when `previous` was the target), then the error is raised again.
  - `"landing"`: the fade's end, inside the clock. The id is forgotten and the target stays current while `recall_scene_instant` applies it, so no grid or screen redraw inside that recall (a voice it starts or stops) shows `previous`. The landing passes the `previous` that `end_scene_transition` returns to `recall_scene_instant` as `current_if_failed`: only if the recall fails is `previous` current again, set before that recall's one failure redraw.
- So the current scene is always the last one that landed or the one now fading: a fade superseded by another keeps the first fade's `previous`, since the second reads the scene the first put back.
- The `"scene transition"` invariant (`S.register_invariant`) checks that `next_step_due`, `target` and `step` are set exactly while the flag is (`step` is nil exactly when no fade runs), and that no clock is kept while idle.

Every exit of the transition clock ends the transition:
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
- **Format**: a Lua table in the layout norns' `tab.save` writes (written by `S.lib.data_files.encode`, each table's keys in a fixed order): `{version = SCENE_DATA_VERSION, scenes = {...}}` (version 4, since 3.3).
  - Version 1 and 2 files (`{version = 1, ...}` or `{version = 2, ...}`, or the bare scenes array written before 2.1) are migrated on load and print `migrated scenes file from version <n>`. The next save keeps the older file as `scenes.data.v<n>`, then writes the current version.
  - Version 3 adds each voice's `extras` (the registered voice params), the registered global fields and the LFO offsets. With nothing registered, a migrated voice gets an empty `extras`.
  - When to bump `SCENE_DATA_VERSION`: once per release that adds scene fields, never per field. Migration fills whatever is missing whatever the file's version, so a field added within an unreleased format (the LFO offsets joined format 3 before 3.2 shipped) needs only its default; a version 3 file written without them migrates like an older one.
  - Version 4 (3.3) changes no field: a version 3 file migrates with only its version changed (registered defaults fill as before), and the next save writes 4. A voice-param record's `scene_ranges` limits a continuous extra in `validate_scene`.
  - Any other version is rejected.
- **Migration**: `load_scenes_from_disk()` runs `migrate_scene(scene, from_version)` on every loaded slot before `validate_scene_data()`.
  - It fills only what is missing, so it runs for every version.
  - Each global from its `SCENE_GLOBAL_PARAMS` entry's `default` (the param default).
  - Top-level blocks from `S.SCENE_BLOCK_DEFAULTS` (`{key, default}`).
  - Per-voice fields from `S.VOICE_SCENE_DEFAULTS` (`{path = keys inside data.voices[i], default}`), filled only when the parent table exists.
  - Each voice's `extras` table, then every registered voice param's default (`scene_defaults`) inside it.
  - Then each registered record's optional `normalize_scene(extras)` on that table, in registration order: it puts back what the params would allow where a hand edit left values inconsistent (loops: a start past 0.999 or a length past `1 - start`), so a recall, which sets the extras without the params' cross-clamps, ends where the params would. It leaves anything but numbers to `validate_scene`.
  - The registered global fields from their `default`, as entries of `SCENE_GLOBAL_PARAMS`.
  - Malformed scenes are left for validation to reject.
  - A later scene field adds its default to one of these tables. `S.VOICE_SCENE_DEFAULTS` holds the grain envelope and mode, `source` and the three buffer params. `S.SCENE_BLOCK_DEFAULTS` is empty: the LFO settings are globals in `SCENE_GLOBAL_PARAMS`.
- **What is known of the file**: `S.scene_file = {version, problem, backup, unsaved}`. `version` is the format read when older than `SCENE_DATA_VERSION` (nil when none was read, or once a save replaced it); `problem` is nil, `"unreadable"` (the file could not be loaded) or `"not saved"` (the last write failed); `backup` is the name an unreadable file was kept under (nil while it is still in place); `unsaved` is true while a scene captured in this session may not be in the file (a failed or blocked write). SETUP lists a problem (`docs/notes/lua/pages/setup.md`).
- **Robust loading**: `load_scenes_from_disk()` reads the file with `S.lib.data_files.read`, a parser of `tab.save`'s layout, so nothing in the file runs (#464). It returns `"loaded"`, `"missing"` or `"unreadable"`, and requests a redraw. A missing file prints `no saved scenes file found`; one that is not that layout (code, a truncated file) prints `error loading scenes file: <why>`, why naming the byte.
  - On any failure (unreadable, unknown version, invalid data after migration) it prints a message and keeps the current scenes (empty at startup).
  - It preserves the file: it is renamed to its first free backup name, `scenes.data.bak`, then `.bak.2` ... `.bak.9` (`S.lib.data_files.set_aside`; an earlier backup is never replaced, #466), and `S.scene_file` records `problem = "unreadable"` and the backup. If every name is taken or the rename fails, `S.scene_autosave_blocked` stops the scene saves' writes and `cleanup()`'s, and `backup` stays nil.
  - Its start step flashes `scenes unreadable (SETUP)` on the hint row, on whatever page comes up, for `SCENE_LOAD.start_flash_seconds` (4 s) (#463). The line `-- Load saved scenes from disk` stays as it is: a test patches the script at it.
  - On `"loaded"` it sets `version` (an older format), clears `problem`, `backup` and `unsaved`, and keeps `S.current_scene` only if the slot's scene is unchanged (#518).
  - Missing slots in a valid file are filled with empty scenes.
- **Saving** (`save_scenes_to_disk()`, true and `"written"` or `"unchanged"`, or false and why): it makes the folder, keeps an older format's file as `scenes.data.v<n>` first when `S.scene_file.version` is set (`keep_copy`: once per content, the copy whole or absent; a failure fails the save, #467), then writes `{version = SCENE_DATA_VERSION, scenes = S.scenes}` through `S.lib.data_files.write`.
  - Success: `version` nil, `unsaved` false, a `"not saved"` problem cleared (and an `"unreadable"` one with no backup: the write replaced the file still in place), `S.scene_autosave_blocked` false; `scenes saved to ...` printed only for `"written"`.
  - Failure: `problem = "not saved"`, `unsaved` true, `error: scenes not saved to <file> (<why>); the file is as it was`, and the file as it was.
- **Auto-save** (#327): every user's scene save writes the file, through `S.lib.scenes.autosave()`: nil (and `unsaved` set) when the scenes were never loaded in this session or `S.scene_autosave_blocked`, else `save_scenes_to_disk()`. `cleanup()` saves too (step 30), with the same two guards: only once `load_scenes_from_disk()` has run in this session (`S.scenes_loaded`, set when it returns), so a start that failed before init's loads (the engine did not load, an error earlier in `init`) never overwrites the saved file with the empty in-memory state (#72), and not while blocked. With nothing new the exit writes nothing (the bytes are the same). buffers.data has the same guards (`docs/notes/lua/buffers.md`).
- **Auto-load**: its start step (`START_ORDER.scenes_load`) loads them at init, before the buffers.
- **Manual**: the PARAMS triggers "save scenes to disk" (`save_scenes_to_disk`) and "load scenes from disk", and SETUP's `save scenes` and `load scenes` (K3). Both loads go through `S.lib.scenes.request_load()` (#328): while `S.scene_file.unsaved` the first request arms (`SCENE_LOAD.armed_until`, `confirm_seconds` = 2 s ahead) and returns `"confirm"` (SETUP flashes `K3 again: drop unsaved` for the 2 s; the PARAMS trigger prints a line), and a second inside the window loads; otherwise it loads at once, and returns what `load_scenes_from_disk` returns. With scenes written at every save, memory and the file hold the same scenes, so a stray load drops nothing.
- **What is saved**: all 8 slots, their populated state and their data. Scenes persist across reboots, building a library of sonic palettes.

## Validation

Always validate scene data before using it, so a corrupted file cannot crash the script.

`validate_scene(scene)` checks one slot; `validate_scene_data(scene_table)` checks every present slot of a loaded table (missing slots are allowed and filled on load). Every "number" below is a finite number: NaN, `inf` and `-inf` are invalid values (the data files' reader reads `inf` and `nan` as numbers, and `tab.load` read `1e999` as `inf`, #464). A populated scene must contain everything `recall_scene_instant()` reads:

```lua
-- every SCENE_GLOBAL_PARAMS id is a number (master_density, tempo, mutation_*, filter_*, delay_*, reverb_*,
--   drift_amount, and per LFO lfo_shape/mode/clocked/free/depth/offset_<n>, strata_lfo<n>_dest, lfo_<n>);
--   an option param's value is an integer from 1 to its option count; an entry with a range
--   ({min, max}: lfo_offset_<n>, -100..100) holds a value inside it
-- data.voices: NUM_VOICES tables, each with
--   active (boolean), source (integer 1..#SOURCE_OPTIONS), params (only known keys, numbers),
--   grain (only GRAIN_PARAM_IDS keys, numbers; env/mode integers 1..option count),
--   crossmod.slot1..3 {source = integer 0..NUM_VOICES, amp_amt, freq_amt numbers}, crossmod.speed number,
--   extras (a table: only registered scene keys, numbers; a discrete key an integer in its {min, max})
-- a registered discrete global: an integer (0..1 for a binary, min..max for a number, 1..count for an option)
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
2. Hold a row 3 button for half a second (`scene_save_seconds`) to save it to a scene slot.
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

- **Lock**: locked states (`frozen`) are captured and restored per scene.
- **Mutations**: mutation settings are per scene, so the sequencer can alternate between static and evolving scenes.
- **Pattern sequencer**: pattern data is saved per scene, so scenes can switch rhythms.
- **Cross-modulation**: routing is per scene, for evolving relationships between voices.
- **Drift**: keeps running during scenes unless voices are frozen. The global LFOs keep running with the LFO settings the scene recalled.

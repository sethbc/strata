## Must not break

- `include("lib/state")()` builds a fresh `S` on every call, so a script reload keeps nothing from the last run. Never keep a table from an earlier `S`.
- State that more than one module uses is a field of `S` under its plain name. The tests find it by that name (`local_value`), so renaming it breaks them.
- `S.voices` is the only source of values. The engine holds no per-voice defaults.
- Source tests use `voice_uses_synth(i)` / `voice_uses_buffer(i)`. Never `not voice_uses_synth` (that includes input).
- `init` holds no start steps of its own: after the params are added and wrapped it runs the steps modules register with `S.register_start` at a free order in `START_ORDER`. Every metro, clock, poll, device and file load starts in such a step.
- `cleanup()` holds no steps of its own. Every metro, clock, poll and handler is stopped by a step its module registers with `S.register_cleanup` at a free order in `CLEANUP_ORDER`. Two steps never share an order (start or cleanup).
- Bounds-check every index (voice, scene, step, slot, grid coordinate) before indexing, so tables never grow by accident.
- Cancel a running clock before starting its replacement.
- A state whose fields have illegal combinations has an invariant, registered with `S.register_invariant` in the module that owns the state. Nothing runs the invariants on the device; the test harness checks them after every unit test.

## Owns

- `strata.lua`: the entry points only.
  - `S`, the includes, `init`, `redraw`, `enc`, `key`, `cleanup`.
  - init's start-up clock (`STARTUP`, `cancel_startup_clock`) and its start step, and E1's start step (`enc` lives here too).
  - The module rules (constructor shape, `S`, `S.lib` names, includes, registries) are under "Modules and `S`" below. AGENTS.md's module table lists the files in include order.
- `lib/state.lua`: `S` itself.
  - `S.registry` (`pages`, `params`, `start`, `cleanup`, `grid_layouts`, `voice_params`, `scene_fields`, `source_change`, `param_filters`, `lfo_destinations`, `fx_params`, `grain_restart`, `alt_release`, `menu_close`, `invariants`), `S.register_start`, `S.register_cleanup`, `S.register_invariant`, `S.lib`.
  - The `__declared` key set the tests use: a key ever assigned into `S`, even to nil, is recorded there.
- `lib/constants.lua`: `S.constants`, a plain table. The constants and fixed tables (`NUM_VOICES`, `UI_PAGES`, `MAIN_PARAMS`, `GRAIN_PARAM_IDS`, `START_ORDER`, `CLEANUP_ORDER`, ...).
- `lib/voices.lua`: `S.lib.voices`, which has no fields.
  - `S.voices`, `S.frozen`, `S.selected_voice`. There is no density field: the master density is the param `master_density` (read through `engine_param_value` or `params:get`).
  - The global source tests `voice_uses_synth`, `voice_uses_buffer`, `voice_source_label`, `voice_buffer_slot`.

## Voice state

Each `S.voices[i]` holds:
- `name`: the voice type.
- `active`: whether it runs.
- `source`: the grain source, a `SOURCE_OPTIONS` index. 1 = synth, 2..`NUM_BUFFERS` + 1 = buffer 1-8, `NUM_BUFFERS` + 2 = input (`SOURCE_SYNTH`, `SOURCE_INPUT`).
- `param_order`: the `params` keys in order (PARAMS menu order and grid fader order; amp/pan last).
- `params`: the synthesis params (per voice type). Their values are also the param defaults.
- `grain`: size, density, pitch, spread, env (grain envelope option index), mode (grain mode option index), buf_pos, buf_rate, buf_scan.
- `extras`: the values of every registered per-voice param (`add_voice_extra`, keyed by the param's key: freeze, variation, loops, history, the voice mix). Built fresh at init by `add_voice_params`; the voice sync, scenes (`capture_scene`, `validate_scene`) and VOICE read it, and randomize and mutations never do.
- `crossmod`: `slot1`..`slot3` (`source`, `amp_amt`, `freq_amt`) and `speed`.

The engine mirrors this table:
- param actions forward changes while a voice is active (through `send_param_to_engine`, see `docs/notes/lua/engine-sync.md`);
- `sync_voice_to_engine` pushes everything when a voice starts.

## Start-up

`init()` (`strata.lua`) runs each `S.registry.params` record's `add`, then `redraw_on_param_changes()`, then the `S.registry.start` records in ascending `order`, so every step can read the params.
- Each module registers its steps as it loads: `S.register_start(S.constants.START_ORDER.<step>, fn)` (`lib/state.lua`), beside its cleanup step.
- Two steps at one order are refused, so the sort always gives one sequence.
- A step that fails stops the ones after it. The scenes and buffers loads then never run, so `S.scenes_loaded` and `S.buffers_loaded` stay false and cleanup does not overwrite the files (#72).

The sequence (`START_ORDER` in `lib/constants.lua`):

| Order | Step | Module |
|-------|------|--------|
| 5 | set `S.started`: from here on `redraw`, `key` and `enc` act (before it norns can route them to the script, #426) | `lib/ui/frame.lua` |
| 10 | build MAIN's voice list (`update_voice_list`) | `lib/pages/main.lua` |
| 15 | add every registered voice-param record's `layout_states` to VOICE's | `lib/pages/voice.lua` |
| 20 | E1: acceleration off, `E1_TICKS_PER_PAGE` ticks per page | `strata.lua` |
| 30 | watch the norns menu opening (`watch_menu_opening`) | `lib/ui/menu_watch.lua` |
| 40 | create and start the drift metro (`S.drift_metro`, 0.1 s, `drift_update`) | `lib/mutation.lua` |
| 50 | create the mutation metro (`S.mutation_metro`, `mutation_rate`, `gentle_mutate`); the `mutation_enabled` param starts it | `lib/mutation.lua` |
| 60 | set and start the `bufferState`, `bufferLoadFailed` and `bufferSaveResult` polls (`S.buffer_polls`) | `lib/buffers.lua` |
| 65 | set and start the `recordState` poll (`record_poll`) | `lib/record.lua` |
| 70 | connect the arc (`arc_init`) | `lib/arc/core.lua` |
| 80 | connect the grids (`grid_init`) | `lib/grid/core.lua` |
| 90 | listen for MIDI (`midi_init`) | `lib/midi_in.lua` |
| 100 | add the registered scene fields to `S.SCENE_GLOBAL_PARAMS`, then load scenes.data (`load_scenes_from_disk`, sets `S.scenes_loaded`) | `lib/scenes.lua` |
| 110 | reload the remembered buffers, after the scenes, which may use them (`load_buffers_from_disk`, sets `S.buffers_loaded`) | `lib/buffers.lua` |
| 120 | the start-up clock (below) | `strata.lua` |
| 130 | start the frame clock (`start_frame_clock`) | `lib/ui/frame.lua` |
| 140 | start the peaks read loop (`S.lib.waveforms.read_clock`, one tick per frame) | `lib/waveforms.lua` |
| 150 | start the playhead clock (`start_clock`) | `lib/playheads.lua` |

Adding a step:
- A new resource gets its start in the module that owns it, at a free order at its place in this sequence (the orders are spaced by 10), next to its cleanup step.
- The test "init runs every registered start step in today's order" (`test/unit/structure_test.lua`) logs each step's observable effects (engine calls, polls, metros, clocks, devices, files read, redraws, prints). It fails if a step moves, merges with another or is missing. Add the new step and its effects to `start_steps()` there.

The start-up clock starts voice 1 at once and voice 2 `STARTUP.voice_delay_seconds` (0.5 s) later, from a clock (`clock.sleep` works only inside `clock.run`):

```lua
cancel_startup_clock()
STARTUP.clock = clock.run(function()
  toggle_voice(1)
  clock.sleep(STARTUP.voice_delay_seconds)
  STARTUP.clock = nil
  -- leave voice 2 alone if a MIDI note or grid press started it meanwhile
  if not S.voices[2].active then toggle_voice(2) end
end)
```

## Cleanup

`cleanup()` (`strata.lua`) runs the `S.registry.cleanup` records in ascending `order`.
- Each module registers its steps as it loads: `S.register_cleanup(S.constants.CLEANUP_ORDER.<step>, fn)` (`lib/state.lua`).
- Two steps at one order are refused, so the sort always gives one sequence.
- A step that fails stops the ones after it.

The sequence (`CLEANUP_ORDER` in `lib/constants.lua`):

| Order | Step | Module |
|-------|------|--------|
| 10 | give the clock back the tempo handler found at init, if the script's is still installed (`restore_tempo_change_handler`) | `lib/params_setup.lua` |
| 20 | give the norns menu its own `_menu.set_mode` back (`unwatch_menu_opening`), before anything that can fail | `lib/ui/menu_watch.lua` |
| 30 | save the scenes (skipped, with a message, if `load_scenes_from_disk` never ran in this session, `S.scenes_loaded`, or if scenes.data failed to load and could not be moved aside) | `lib/scenes.lua` |
| 40 | save the buffer paths (skipped the same way for buffers.data, with `S.buffers_loaded`) | `lib/buffers.lua` |
| 50 | cancel init's start-up clock (`cancel_startup_clock`, while it waits to start voice 2) | `strata.lua` |
| 60 | stop the frame clock | `lib/ui/frame.lua` |
| 70 | stop the drift metro | `lib/mutation.lua` |
| 80 | stop the mutation metro and set `mutation_enabled` to 0, so param and state agree | `lib/mutation.lua` |
| 85 | cancel the randomize undo's expiry clock | `lib/mutation.lua` |
| 90 | stop the pattern clock | `lib/sequencer.lua` |
| 100 | stop the scene sequencer through its param (`scene_sequencer_enabled` 0 when the param exists, then `scene_sequencer_stop`) | `lib/scenes.lua` |
| 110 | cancel a scene transition | `lib/scenes.lua` |
| 120 | stop the LFOs that init built (through their state params, like the library's menu) and give their destinations back their stored values | `lib/lfos.lua` |
| 122 | stop the playhead clock (`stop_clock`) | `lib/playheads.lua` |
| 124 | cancel every voice's scrub glide and scan hold (`scrubRate` and `scanHold` back to 0) | `lib/positions.lua` |
| 126 | stop the peaks read loop (`S.lib.waveforms.stop`) | `lib/waveforms.lua` |
| 128 | cancel each slot's pending start reload of a long file | `lib/buffers.lua` |
| 130 | stop the buffer polls and the recording timers (the engine finishes or frees any recording itself) | `lib/buffers.lua` |
| 132 | stop the `recordState` poll and forget the takes | `lib/record.lua` |
| 135 | stop the BUFFER page's `amp_in_l` and `amp_in_r` input meter polls (`stop_input_meter`) | `lib/pages/buffer.lua` |
| 140 | cancel the flash clocks (the header's and the hint row's, `S.lib.ui_flash.cancel_all`) | `lib/ui/flash.lua` |
| 150 | detach the MIDI handler, before the voices go off | `lib/midi_in.lua` |
| 160 | `engine.voiceOff` for every running voice | `lib/engine_sync.lua` |
| 170 | leave every connected grid dark | `lib/grid/core.lua` |
| 180 | leave the arc dark | `lib/arc/core.lua` |

Adding a step:
- A new resource gets its stop in the module that starts it, at a free order at its place in this sequence (the orders are spaced by 10).
- The test "cleanup runs every registered step in today's order" (`test/unit/structure_test.lua`) logs each step's observable effect. It fails if a step moves, merges with another or is missing. Add the new step's effect to its `CLEANUP_STEPS` list.

Clocks: cancel the running one before starting its replacement.

```lua
if S.scene_transition_clock then
  clock.cancel(S.scene_transition_clock)
  S.scene_transition_clock = nil
end
S.scene_transition_clock = clock.run(function()
  -- clock body
end)
```

This prevents:
- orphaned clock coroutines;
- concurrent clocks making a parameter oscillate;
- leaks from metros never stopped;
- params that disagree with the state they control.

## Bounds checks

Check before indexing:
- every voice index (1 to `NUM_VOICES`);
- every scene index (1 to `NUM_SCENES`);
- every pattern step (1 to `PATTERN_LENGTH`);
- grid button coordinates;
- parameter ranges.

The scene and pattern examples are in `docs/notes/lua/scenes.md` and `docs/notes/lua/sequencer.md`.

## Modules and `S`

`strata.lua` holds only the entry points: the shared table `S`, one `include("lib/<path>")` per module in dependency order, `init`, `redraw`, `enc`, `key`, `cleanup`, and the start steps only the script can own (init's start-up clock, `STARTUP` and `cancel_startup_clock`, and E1's settings). Everything else is in `lib/`.

- **`S`** (`lib/state.lua`: `local S = include("lib/state")()`) is the table the script and its modules share. Each call builds a fresh one, so a script reload keeps nothing from the previous run. State that more than one module uses is a field of `S` under its plain name (`S.voices`, `S.scenes`, `S.ui_page`, `S.engine_senders`, ...); state only one module uses stays local to it. `S.constants` is `lib/constants.lua`, a plain table.
- **Includes**: only `strata.lua` calls `include`, once per module, always as `include("lib/<path>")` (never `"strata/lib/..."`: the install folder may have another name). norns' `include` is `dofile`, so a second include would make a second copy with separate state. A test checks all three.
- **A module** is a constructor, `return function(S) local M = {} ... return M end`, ending with exactly `  return M` and `end` (the locals probe relies on it). Its table is `S.lib.<name>`: `S.lib.scenes` for `lib/scenes.lua`, `S.lib.<dir>_<basename>` in a subfolder (`S.lib.ui_keys`, `S.lib.grid_layout_256`). A local function another module calls becomes a field of that table (`S.lib.ui_text.fit_text`). Functions that were global stay global, defined in their module (`MODULE_HOMES` in the tests says where). Aliasing constants at the top of a constructor (`local NUM_VOICES = S.constants.NUM_VOICES`) is fine.
- **Where things live**: a module's table is `S.lib.<name>` (top-level `lib/` files) or `S.lib.<dir>_<basename>` (subfolders); shared state is on `S` under its plain name; the registries are `S.registry.pages`, `S.registry.params`, `S.registry.start`, `S.registry.cleanup`, `S.registry.grid_layouts`, and `voice_params`, `scene_fields`, `source_change`, `param_filters`, `lfo_destinations`, `fx_params`, `grain_restart`, `alt_release`, `menu_close` and `invariants` (`lib/state.lua`).
- **Registries** (`S.registry`, filled as the modules load): `pages` (one record per screen page), `params` (init runs each record's `add`, in PARAMS menu order), `grid_layouts` (`{key, redraw}` per grid size), `start` (init runs each step by order after the params) and `cleanup`; and, for 3.2's features, `voice_params` (per-voice param records), `scene_fields` (global scene fields), `source_change` (hooks after a source change), `param_filters` (one value filter per voice param key), `lfo_destinations` (per-voice LFO destinations), `fx_params` (params after the fx group's own), and, for 3.3, `grain_restart` (`S.register_grain_restart(fn(voice_idx))`: run by `lib/engine_sync.lua` after every `engine.voiceOn` and every `engine.setGrainSource` that changes a running voice's source), `alt_release` (`S.register_alt_release(fn())`: run when ALT goes from held to not held), `menu_close` (`S.register_menu_close(fn())`: run each time the norns menu closes, after norns' `set_mode(false)` returns, each hook in its own `pcall`, so one that fails prints a line and never stops the menu closing or the next hook; the menu watch's start step reads the registry as it builds its wrapper, so hooks register at include time; `docs/notes/lua/ui/alt-and-keys.md`) and `invariants` (`S.register_invariant(name, fn)`: `{name, fn}` records the test harness checks after every unit test, never run on the device; see "Registering an invariant" below). A voice-param record's optional `scene_ranges` (`{<key> = {min, max}}`, continuous keys only, holding the key's default) makes `validate_scene` reject a scene whose extra lies outside it. Each has a register function on `S` (`S.register_voice_params`, ...) that checks its argument and refuses a duplicate name. The readers read them at init (inside a `register_params` add or later), never at include time, so a registering module's include order never matters. "Registering start and cleanup steps" below and `docs/notes/lua/params.md` (Registering params) say how to add to each.
- **`S.performance`** (`{tier, buffer_seconds, max_grains, history_seconds, reason}`): the tier the engine runs, read from the engine's `performance_active.data` by `S.lib.performance.read_active` in the first params record (`"performance"`, before any param is added); a missing or invalid file gives a copy of `S.constants.STANDARD_PERFORMANCE`. Every tier-dependent spec reads it (`record_duration` goes to `S.performance.buffer_seconds`). The setting itself (`performance.data`) is SETUP's, never a param.
- Tests reach script state with `local_value(name)` and `find_upvalue(name)`: a field of `S`, then of `S.constants`, then an upvalue of a global function.

## Registering start and cleanup steps

- **Registering a start step**: `S.register_start(S.constants.START_ORDER.<step>, fn)` in the module that owns the resource, next to its cleanup step, and one line in `START_ORDER` (`lib/constants.lua`) at a free order at its place in the sequence (spaced by 10; two steps never share one). init runs the steps after the params are added, so a step can read them. `init` itself is never edited. Add the step's effects to `start_steps()` in `test/unit/structure_test.lua`.
- **Registering an invariant**: `S.register_invariant(name, fn)` in the module that owns the state, where it can see that state's private tables. `name` is a non-empty string no other invariant uses (a test failure names it); `fn()` returns nil while the invariant holds, else a string saying what is broken (which slot, key or field, and its value). `h.run_test` (`test/helpers.lua`) runs every registered invariant after each unit test that loaded the script, passed and reported no clock error, and fails the test that left one broken; nothing runs them on the device, so `fn` may be as thorough as the test needs. A test that breaks one on purpose calls `h.allow_broken_invariants(reason)`. Each task that fixes a state registers its invariant. The invariants registered today:

  | Name | Module | Holds |
  |------|--------|-------|
  | `scene transition` | `lib/scenes.lua` | `S.scene_transition_active == (S.SCENE_TRANSITION.next_step_due ~= nil)`, `S.SCENE_TRANSITION.target` and `.step` are set exactly while the flag is true, and `S.scene_transition_clock` is nil whenever the flag is false |
  | `scene sequencer` | `lib/scenes.lua` | `S.scene_sequencer_recall_due` is true only while the sequencer is on |
  | `pattern clock` | `lib/sequencer.lua` | `S.pattern_playing == (S.pattern_clock ~= nil)` |
  | `midi notes` | `lib/midi_in.lua` | a note is held on a voice (`S.midi_state.held`) exactly while some channel's note on maps it there (`note_voice`), and every `started` entry is a voice index set to true |
  | `scan holds` | `lib/positions.lua` | a voice's scan is held exactly while it has a holder |
  | `strip store` | `lib/positions.lua` | a port holds store one way only: its one store key (`store_down`) on a layout that selects a grid voice, a key per voice (`store`) on the others |
  | `scenes prompt` | `lib/pages/scenes.lua` | `S.scenes_page.armed_slot` is nil or a whole scene number in 1..`NUM_SCENES` |
  | `grid keys` | `lib/grid/core.lua` | every consumed key and every key with a pending hold (`on_hold`) is a held key (`S.grid_held`), and a port has an attached device recorded (`attached_devices[port]`) exactly while it is attached (`S.grids[port]`) |
  | `arc connection` | `lib/arc/core.lua` | `S.arc_connected == (S.arc_device ~= nil and S.arc_device.device ~= nil)` |
  | `key presses` | `lib/ui/keys.lua` | every `S.key_press_alt[n]` has an `S.key_press_page[n]` |
  | `buffer slots` | `lib/buffers.lua` | for every slot of `S.buffers`: `finishing` implies `recording`, `checking_from ~= nil` implies `confirm_since ~= nil`, and `settled_empty` and `loaded` are never both set; a name `take <number>` is the slot's own `take <n>`, and a scratch path `buf*.wav` is `buf<whole number>.wav` (#300); `start == sent_start` unless a start reload is pending (`start_reload_clocks[slot]`, #245) |
  | `flash slots` | `lib/ui/flash.lua` | a flash slot with a text has a clock |
- **Registering a cleanup step**: `S.register_cleanup(S.constants.CLEANUP_ORDER.<step>, fn)` in the module that starts the resource, and one line in `CLEANUP_ORDER` (`lib/constants.lua`) at a free order at its place in the sequence (orders are spaced by 10; two steps never share one). `cleanup()` itself is never edited.

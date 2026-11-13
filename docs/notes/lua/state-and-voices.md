## Must not break

- `include("lib/state")()` builds a fresh `S` on every call, so a script reload keeps nothing from the last run. Never keep a table from an earlier `S`.
- State that more than one module uses is a field of `S` under its plain name. The tests find it by that name (`local_value`), so renaming it breaks them.
- `S.voices` is the only source of values. The engine holds no per-voice defaults.
- Source tests use `voice_uses_synth(i)` / `voice_uses_buffer(i)`. Never `not voice_uses_synth` (that includes input).
- `init` holds no start steps of its own: after the params are added and wrapped it runs the steps modules register with `S.register_start` at a free order in `START_ORDER`. Every metro, clock, poll, device and file load starts in such a step.
- `cleanup()` holds no steps of its own. Every metro, clock, poll and handler is stopped by a step its module registers with `S.register_cleanup` at a free order in `CLEANUP_ORDER`. Two steps never share an order (start or cleanup).
- Bounds-check every index (voice, scene, step, slot, grid coordinate) before indexing, so tables never grow by accident.
- Cancel a running clock before starting its replacement.
- Lua allows 200 locals in one function, and each file's main chunk and each module's constructor must keep at least 30 free (the locals probe, `docs/notes/test-harness/run-and-helpers.md`, Module safety nets; `strata.lua`'s main chunk uses 5). Group a feature's constants in one table (as `LFO_PAGE`, `GRID_LAYOUT`, `BUFFER_PAGE`, `FX_PAGE` and `BUFFER_SETTLE` do) rather than adding many `local`s, and split a module that runs short.
- A state whose fields have illegal combinations has an invariant, registered with `S.register_invariant` in the module that owns the state. Nothing runs the invariants on the device; the test harness checks them after every unit test.

## Owns

- `strata.lua`: the entry points only.
  - `S`, the includes, `init`, `redraw`, `enc`, `key`, `cleanup`.
  - init's start-up clock (`STARTUP`, `cancel_startup_clock`) and its start step, and E1's start step (`enc` lives here too).
  - The module rules (constructor shape, `S`, `S.lib` names, includes, registries) are under "Modules and `S`" below. AGENTS.md's module table lists the files in include order.
- `lib/state.lua`: `S` itself.
  - `S.registry` (`pages`, `params`, `start`, `cleanup`, `grid_layouts`, `voice_params`, `scene_fields`, `source_change`, `param_filters`, `lfo_destinations`, `fx_params`, `grain_restart`, `alt_release`, `menu_close`, `invariants`, and 3.4's `scene_blocks`, `scene_migrations`, `pset_hooks`, `param_touch`, `lock_change`, `step_outputs`, `mod_sources`, and 3.5's `voice_stop`, `freeze_change`), `S.register_start`, `S.register_cleanup`, `S.register_invariant`, `S.lib`.
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
- a start (`S.lib.engine_sync.start_voice`, from `toggle_voice` or a pattern step) pushes everything: the source and the grain values before `engine.voiceOn`, the voice-level values after it (`docs/notes/lua/engine-sync.md`).

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
| 62 | set and start the input level polls `amp_in_l` and `amp_in_r` (`START_ORDER.input_level`; a poll a norns lacks is skipped) (3.4) | `lib/input_level.lua` |
| 65 | set and start the `recordState` poll (`record_poll`) | `lib/record.lua` |
| 70 | connect the arc (`arc_init`) | `lib/arc/core.lua` |
| 80 | read the grid rotations (`grids.data`), then connect the grids (`grid_init`) | `lib/grid/core.lua` |
| 90 | listen for MIDI (`midi_init`), then repair norns' MIDI map: a map on one of 3.3's own LFO ids moves to its 3.4 param or goes, and no other map is touched (`S.lib.midi_in.repair_midi_map`, #602) | `lib/midi_in.lua` |
| 100 | add the registered scene fields to `S.SCENE_GLOBAL_PARAMS`, then load scenes.data (`load_scenes_from_disk`, sets `S.scenes_loaded`) | `lib/scenes.lua` |
| 105 | load the macros' targets from data/strata/macros.data (`START_ORDER.macros_load`; a missing file loads them empty, one it cannot use is set aside, an unknown target id is kept with a console line), then redraw the screen and grids (3.4) | `lib/macros.lua` |
| 107 | load the gesture recorders, stopped, from data/strata/gestures.data (`START_ORDER.gestures_load`; a missing file loads them empty, one it cannot use is set aside), then redraw the screen and grids (3.4) | `lib/gestures.lua` |
| 108 | load the matrix's routings from data/strata/matrix.data (`START_ORDER.matrix_load`; a missing file loads them empty, one it cannot use is set aside, an unknown source key or destination id is kept with a console line), then redraw the screen (3.4) | `lib/matrix.lua` |
| 109 | read the note pool from data/strata/notes.data (`START_ORDER.notes_load`; a missing file leaves the tier's default, one it cannot use too, with a console line), send it (`setNotePool`) and join the expression flush to the LFO clock's step hooks (3.5) | `lib/notes.lua` |
| 110 | reload the remembered buffers, after the scenes, which may use them (`load_buffers_from_disk`, sets `S.buffers_loaded`) | `lib/buffers.lua` |
| 120 | the start-up clock (below) | `strata.lua` |
| 125 | check every global LFO destination's param, then start the LFO clock (`S.lfo_clock`, 48 Hz, 3.4) | `lib/lfos.lua` |
| 130 | start the frame clock (`start_frame_clock`) | `lib/ui/frame.lua` |
| 140 | start the peaks read loop (`S.lib.waveforms.read_clock`, one tick per frame) | `lib/waveforms.lua` |
| 150 | start the playhead clock (`start_clock`) | `lib/playheads.lua` |
| 160 | follow an external clock's transport: install `clock.transport.start` and `stop`, which act only when `clock_source` is not internal, keeping the handlers found (#530) | `lib/sequencer.lua` |

Every order in `START_ORDER` has its step: `test/unit/structure_test.lua` checks one order per step and one registered step per order.

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
- norns frees the engine before it calls `cleanup()` (`Script.clear` in `lua/core/script.lua` calls `_norns.free_engine()` first, and the engine's `deinit` frees its command responders before anything else, #461). So no engine command a step sends arrives: the voices stop at once with the engine, never through a release, and step 160's `voiceOff`s, the scrub glide's `scrubRate 0` (step 124) and the LFOs' restored values (step 120) reach no handler. Steps 120 and 124 stay for the Lua state they also put back (the LFOs stopped through their state params, the glides and scan holds ended); step 160 sends only its `voiceOff`s (each followed by the voice-stop hooks, 3.5) and changes no Lua state of its own, so on norns it does nothing (it is kept: dropping it changes nothing a player hears). Nothing in cleanup may count on the engine. The stub's engine is never freed, so the unit tests accept these calls.

The sequence (`CLEANUP_ORDER` in `lib/constants.lua`):

| Order | Step | Module |
|-------|------|--------|
| 10 | give the clock back the tempo handler found at init, if the script's is still installed (`restore_tempo_change_handler`) | `lib/params_setup.lua` |
| 20 | give the norns menu its own `_menu.set_mode` back (`unwatch_menu_opening`), before anything that can fail | `lib/ui/menu_watch.lua` |
| 30 | save the scenes (skipped, with a message, if `load_scenes_from_disk` never ran in this session, `S.scenes_loaded`, or if scenes.data failed to load and could not be moved aside) | `lib/scenes.lua` |
| 32 | save the macros' targets to data/strata/macros.data at once, canceling the write that waits (`S.macro_save_clock`) (`CLEANUP_ORDER.macros_save`; skipped if their start step never ran) (3.4) | `lib/macros.lua` |
| 34 | save the gesture recorders to data/strata/gestures.data at once, canceling the write that waits (`S.gesture_save_clock`) (`CLEANUP_ORDER.gestures_save`; skipped if their start step never ran; a recording is saved as if it stopped then) (3.4) | `lib/gestures.lua` |
| 36 | save the matrix's routings to data/strata/matrix.data at once, canceling the write that waits (`S.matrix_save_clock`) (`CLEANUP_ORDER.matrix_save`; skipped if its start step never ran) (3.4) | `lib/matrix.lua` |
| 40 | save the buffer paths (skipped the same way for buffers.data, with `S.buffers_loaded`) | `lib/buffers.lua` |
| 50 | cancel init's start-up clock (`cancel_startup_clock`, while it waits to start voice 2) | `strata.lua` |
| 60 | stop the frame clock | `lib/ui/frame.lua` |
| 70 | stop the drift metro | `lib/mutation.lua` |
| 80 | stop the mutation metro and set `mutation_enabled` to 0, so param and state agree | `lib/mutation.lua` |
| 85 | cancel the randomize undo's expiry clock | `lib/mutation.lua` |
| 90 | stop the pattern clock and give the clock back the transport handlers found at init, if the script's are still installed | `lib/sequencer.lua` |
| 95 | stop every gesture recorder: a recording ends (kept, stopped), every free loop's metro stops and every quantized loop's clock and 10-minute clock are canceled (`gestures`, 3.4) | `lib/gestures.lua` |
| 97 | cancel every quantized action that waits (`quantize`, 3.4; the flashes' own step ends its header flash) | `lib/quantize.lua` |
| 100 | stop the scene sequencer through its param (`scene_sequencer_enabled` 0 when the param exists, then `scene_sequencer_stop`) | `lib/scenes.lua` |
| 110 | cancel a scene transition | `lib/scenes.lua` |
| 112 | cancel the morph clock (`S.morph_clock`) and drop the apply it waited for (3.4) | `lib/morph.lua` |
| 114 | cancel the macros' apply clock (`S.macro_clock`), dropping every apply that waits, and learn's timeout (`S.macro_learn_clock`) (`CLEANUP_ORDER.macros`, 3.4) | `lib/macros.lua` |
| 118 | cancel matrix learn's timeout (`S.matrix_learn_clock`) and forget the matrix's offsets (its extra offsets and fast sums), sending nothing; the matrix steps in the LFO clock and has no clock of its own (`CLEANUP_ORDER.matrix`, 3.4) | `lib/matrix.lua` |
| 119 | end the note module's expression flush (`S.lib.notes.stop_flush`): nothing is due and its LFO step hook sends nothing after it (`CLEANUP_ORDER.notes`, 3.5) | `lib/notes.lua` |
| 120 | cancel the LFO clock, release every engine-run LFO (`stopFastLfo`) and give every Lua-run LFO's destination its stored value back | `lib/lfos.lua` |
| 122 | stop the playhead clock (`stop_clock`) | `lib/playheads.lua` |
| 124 | cancel every voice's scrub glide and scan hold (`scrubRate` and `scanHold` back to 0) | `lib/positions.lua` |
| 126 | stop the peaks read loop (`S.lib.waveforms.stop`) | `lib/waveforms.lua` |
| 127 | cancel the send budget's flush clock (`S.engine_budget_clock`) and drop the values waiting for it (3.4; the engine is already freed, #461) | `lib/engine_sync.lua` |
| 128 | cancel each slot's pending start reload of a long file | `lib/buffers.lua` |
| 130 | stop the buffer polls and the recording timers (the engine finishes or frees any recording itself) | `lib/buffers.lua` |
| 132 | stop the `recordState` poll and forget the takes | `lib/record.lua` |
| 135 | stop the `amp_in_l` and `amp_in_r` input level polls and clear their callbacks (3.4: the polls moved from the BUFFER page, `input_meter` keeps its order) | `lib/input_level.lua` |
| 140 | cancel the flash clocks (the header's and the hint row's, `S.lib.ui_flash.cancel_all`) | `lib/ui/flash.lua` |
| 150 | detach the MIDI handler, before the voices go off, and set `midi.add`/`midi.remove` to no-ops | `lib/midi_in.lua` |
| 160 | `engine.voiceOff` for every running voice, each followed by the voice-stop hooks (3.5) (it reaches no handler on norns: the engine is already freed, above) | `lib/engine_sync.lua` |
| 170 | clear every grid vport's key handler, put its grid back to rotation 0 and leave it dark, set `grid.add`/`grid.remove` to no-ops | `lib/grid/core.lua` |
| 180 | clear the arc vport's handlers, leave the arc dark, set `arc.add`/`arc.remove` to no-ops | `lib/arc/core.lua` |

Every order in `CLEANUP_ORDER` has its step, checked as for the start steps above.

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
- **Where things live**: a module's table is `S.lib.<name>` (top-level `lib/` files) or `S.lib.<dir>_<basename>` (subfolders); shared state is on `S` under its plain name; the registries are `S.registry.pages`, `S.registry.params`, `S.registry.start`, `S.registry.cleanup`, `S.registry.grid_layouts`, and `voice_params`, `scene_fields`, `source_change`, `param_filters`, `lfo_destinations`, `fx_params`, `grain_restart`, `alt_release`, `menu_close`, `invariants`, `scene_blocks`, `scene_migrations`, `pset_hooks`, `param_touch`, `lock_change`, `step_outputs`, `mod_sources`, `voice_stop` and `freeze_change` (`lib/state.lua`).
- **Registries** (`S.registry`, filled as the modules load): `pages` (one record per screen page), `params` (init runs each record's `add`, in PARAMS menu order), `grid_layouts` (`{key, redraw}` per grid size), `start` (init runs each step by order after the params) and `cleanup`; and, for 3.2's features, `voice_params` (per-voice param records), `scene_fields` (global scene fields), `source_change` (hooks after a source change), `param_filters` (one value filter per voice param key), `lfo_destinations` (per-voice LFO destinations), `fx_params` (params after the fx group's own), and, for 3.3, `grain_restart` (`S.register_grain_restart(fn(voice_idx))`: run by `lib/engine_sync.lua` after every `engine.voiceOn` and every `engine.setGrainSource` that changes a running voice's source, every one of which is sent through `S.lib.engine_sync.send_grain_source`, `docs/notes/lua/engine-sync.md`), `alt_release` (`S.register_alt_release(fn())`: run when ALT goes from held to not held), `menu_close` (`S.register_menu_close(fn())`: run each time the norns menu closes, after norns' `set_mode(false)` returns, each hook in its own `pcall`, so one that fails prints a line and never stops the menu closing or the next hook; the menu watch's start step reads the registry as it builds its wrapper, so hooks register at include time; `docs/notes/lua/ui/alt-and-keys.md`) and `invariants` (`S.register_invariant(name, fn)`: `{name, fn}` records the test harness checks after every unit test, never run on the device; see "Registering an invariant" below). 3.4's (design §0.1, §8.10, §10.1; package 0a), each register function refusing a duplicate name and a field outside its record's set:
  - `scene_blocks` (`S.register_scene_block({key, default = fn() -> value, capture = fn() -> value, validate = fn(value) -> boolean, apply = fn(value), discrete = true, through_zero = fn(from_value, to_value) -> {{id, switch = fn()}, ...}})`: a top-level scene block `lib/scenes.lua` captures, validates and applies, switched at a transition's end; `through_zero`, optional, names the depths that ramp through 0 in a transition or a morph);
  - `scene_migrations` (`S.register_scene_migration({name, before_version, migrate = fn(scene)})`: run by `lib/scenes.lua` on every loaded scene older than `before_version`, by `before_version` then registration);
  - `pset_hooks` (`S.register_pset_hook({name, write = fn(path_base, number), read = fn(path_base, number, pset_path, silent), delete = fn(path_base, number)})`, each function optional: run by the PSET actions `lib/params_setup.lua` installs, `docs/notes/lua/params.md`);
  - `param_touch` (`S.register_param_touch(fn(param_id, source))`: run after each user edit of a param, once it is set: `"enc"` and `"arc"` from `delta_with_detent` (`lib/ui/detent.lua`, `opts.source` naming an arc ring's whole steps; never for a detent the hold swallows), `"grid"` from `set_param_from_column` (`lib/grid/faders.lua`); a plain `params:set`, the drift, a mutation or a recall is no touch. `lib/engine_sync.lua`'s hook clears the param's base override);
  - `lock_change` (`S.register_lock_change(fn(voice_idx, locked))`: run by `toggle_lock` after the flip, with the new state, and by a scene recall's lock states);
  - `step_outputs` (`S.register_step_output({name, play = fn(event), stop = fn(), available = fn(voice_idx) -> boolean})`, `stop` and `available` optional: each pattern hit's outputs, `lib/sequencer.lua`);
  - `mod_sources` (`S.register_mod_source({key, name, section, value = fn() -> number, range = {min, max}, describe = fn() -> string, visible = fn() -> boolean, row = {enc, fine_enc, press, alt_press, hints}})`: `name` at most 4 characters, `range[1] < range[2]` (below 0: bipolar); `describe`, `visible`, `row` and each row function optional; read only through `S.lib.mod_sources`, `docs/notes/lua/mod-sources.md`);
  - 3.5's (design §0.1; package 0a), plain hooks that refuse a non-function: `voice_stop` (`S.register_voice_stop(fn(voice_idx))`: run after every `engine.voiceOff` the script sends, all in `lib/engine_sync.lua`: `toggle_voice`'s stop, once the voice is marked stopped; a start that failed once its `voiceOn` went, before the error is raised again; cleanup step 160, per running voice) and `freeze_change` (`S.register_freeze_change(fn(voice_idx, frozen))`: run by every `v<i>_freeze` action, once the value is stored and sent, `frozen` true for 1, before the action's grid redraw; `lib/freeze.lua`). Each hook of both runs protected, as the LFO step hooks do (`S.lib.ui_frame.contained_call`): one that raises prints `strata: voice stop hook failed: ` or `strata: freeze change hook failed: ` with its traceback, once per distinct message per hook, and is skipped, so the next hook, the stop (its redraws, a failed start's own error, cleanup's other `voiceOff`s and later steps) and the freeze action's grid redraw still go on;
  - and two extensions: `S.register_lfo_global_destination(label, param_id)` appends `{label, param_id, global = true}` to `lfo_destinations` (one destination, in registration order with the per-voice ones; the labels share one namespace), and `S.register_scene_field` takes an optional `set = fn(value)`, kept on the field's record: what a recall, a transition step and `apply_entries` call in place of `params:set`.
  `scene_blocks`, `scene_migrations` and `pset_hooks` close at init, as `voice_params`, `scene_fields`, `lfo_destinations`, `fx_params`, `start` and `menu_close` do (#384); `param_touch`, `lock_change`, `step_outputs`, `mod_sources`, `voice_stop` and `freeze_change` are read at each use and stay open. A voice-param record's optional `scene_ranges` (`{<key> = {min, max}}`, continuous keys only, holding the key's default) makes `validate_scene` reject a scene whose extra lies outside it. Each has a register function on `S` (`S.register_voice_params`, ...) that checks its argument and refuses a duplicate name. The readers read them at init (inside a `register_params` add or later), never at include time, so a registering module's include order never matters. "Registering start and cleanup steps" below and `docs/notes/lua/params.md` (Registering params) say how to add to each.
- **`S.performance`** (`{tier, buffer_seconds, max_grains, history_seconds, reason}`): the tier the engine runs, read from the engine's `performance_active.data` by `S.lib.performance.read_active` in the first params record (`"performance"`, before any param is added); a missing or invalid file gives a copy of `S.constants.STANDARD_PERFORMANCE`. Every tier-dependent spec reads it (`record_duration` goes to `S.performance.buffer_seconds`). The setting itself (`performance.data`) is SETUP's, never a param.
- Tests reach script state with `local_value(name)` and `find_upvalue(name)`: a field of `S`, then of `S.constants`, then an upvalue of a global function.

## Registering start and cleanup steps

- **Registering a start step**: `S.register_start(S.constants.START_ORDER.<step>, fn)` in the module that owns the resource, next to its cleanup step, and one line in `START_ORDER` (`lib/constants.lua`) at a free order at its place in the sequence (spaced by 10; two steps never share one). init runs the steps after the params are added, so a step can read them. `init` itself is never edited. Add the step's effects to `start_steps()` in `test/unit/structure_test.lua`.
- **Registering an invariant**: `S.register_invariant(name, fn)` in the module that owns the state, where it can see that state's private tables. `name` is a non-empty string no other invariant uses (a test failure names it); `fn()` returns nil while the invariant holds, else a string saying what is broken (which slot, key or field, and its value). `h.run_test` (`test/helpers.lua`) runs every registered invariant after each unit test that loaded the script, passed and reported no clock error, and fails the test that left one broken; nothing runs them on the device, so `fn` may be as thorough as the test needs. A test that breaks one on purpose calls `h.allow_broken_invariants(reason)`. Each task that fixes a state registers its invariant. The invariants registered today:

  | Name | Module | Holds |
  |------|--------|-------|
  | `scene transition` | `lib/scenes.lua` | `S.scene_transition_active == (S.SCENE_TRANSITION.next_step_due ~= nil)`, `S.SCENE_TRANSITION.target` and `.step` are set exactly while the flag is true, and `S.scene_transition_clock` is nil whenever the flag is false |
  | `scene sequencer` | `lib/scenes.lua` | `S.scene_sequencer_recall_due` is true only while the sequencer is on, and `S.scene_sequencer_enabled == (S.scene_sequencer_clock ~= nil)` with that clock's coroutine not dead (#329) |
  | `pattern clock` | `lib/sequencer.lua` | `S.pattern_playing == (S.pattern_clock ~= nil)` |
  | `midi notes` | `lib/midi_in.lua` | a note is held on a voice (`S.midi_state.held`) exactly while some channel's note on maps it there (`note_voice`), and every `started` entry is a voice index set to true |
  | `scan holds` | `lib/positions.lua` | a voice's scan is held exactly while it has a holder |
  | `strip store` | `lib/positions.lua` | a port holds store one way only: its one store key (`store_down`) on a layout that selects a grid voice, a key per voice (`store`) on the others |
  | `scenes prompt` | `lib/pages/scenes.lua` | `S.scenes_page.armed_slot` and `S.scenes_page.naming` are each nil or a whole scene number in 1..`NUM_SCENES`, and `naming` is set exactly while the page keeps an open name entry's callback |
  | `grid keys` | `lib/grid/core.lua` | every consumed key and every key with a pending hold (`on_hold`) is a held key (`S.grid_held`), and a port has an attached device recorded (`attached_devices[port]`) exactly while it is attached (`S.grids[port]`) |
  | `arc connection` | `lib/arc/core.lua` | `S.arc_connected == (S.arc_device ~= nil and S.arc_device.device ~= nil)` |
  | `key presses` | `lib/ui/keys.lua` | every `S.key_press_alt[n]` has an `S.key_press_page[n]` |
  | `buffer slots` | `lib/buffers.lua` | for every slot of `S.buffers`: `finishing` implies `recording`, `checking_from ~= nil` implies `confirm_since ~= nil`, and `settled_empty` and `loaded` are never both set; a name `take <number>` is the slot's own `take <n>`, and a scratch path `buf*.wav` is `buf<whole number>.wav` (#300); `start == sent_start` unless a start reload is pending (`start_reload_clocks[slot]`, #245) |
  | `input level` | `lib/input_level.lua` | from the start step to cleanup, both input polls run (`amp_in_l`, `amp_in_r`; a poll a norns lacks is skipped) |
  | `flash slots` | `lib/ui/flash.lua` | a flash slot with a text has a clock |
  | `param turn` | `lib/ui/detent.lua` | `S.turning_param` is nil between events (a turn marks its param only while it sets it, #318) |
  | `engine budget` | `lib/engine_sync.lua` | a value waits for the send budget only while its flush clock runs (`S.engine_budget_clock`, which may run on with nothing waiting to its next wake and ends there, never canceled while the script runs, #654), that clock's coroutine is not dead, and every waiting id has a value (3.4) |
  | `modal owner` | `lib/ui/modal.lua` | no owner is on the modal stack twice, and every key down on an owner is on one that is pushed (3.4) |
  | `morph clock` | `lib/morph.lua` | a morph move, a value left for the next apply or a waiting crossing (#653) always has `S.morph_clock` to apply it, and that clock's coroutine is not dead (3.4) |
  | `quantize` | `lib/quantize.lua` | a quantized action waits (`S.lib.quantize.actions[key]`) exactly while its clock runs (3.4) |
  | `gesture recorders` | `lib/gestures.lua` | at most one recorder records; pattern_time's `rec` is 1 exactly while its recorder records; a free loop's metro (`pattern.play`, with the metro itself running) or a quantized loop's clock (its coroutine alive) runs exactly while it plays, never both, and the right one for its loop; the 10-minute clock runs exactly while it records an event or more; it overdubs only while it plays; it is empty exactly when it holds no event and does not record; `gesture_<k>_play` is 1 exactly while it plays (3.4) |
  | `macro apply` | `lib/macros.lua` | a macro waits for its apply exactly while the apply clock runs (`S.macro_clock`), and that clock's coroutine is not dead (3.4) |
  | `macro learn` | `lib/macros.lua` | learn waits for a touch exactly while its timeout clock runs (`S.macro_learn_clock`) (3.4) |
  | `matrix learn` | `lib/matrix.lua` | matrix learn waits for a touch exactly while its timeout clock runs (`S.matrix_learn_clock`) (3.4) |
  | `lfo clock` | `lib/lfos.lua` | the LFO clock (`S.lfo_clock`) runs from its start step to cleanup, and only then (3.4) |
  | `step editor` | `lib/pages/seq.lua` | the step editor is open exactly while its owner is the modal one (`S.lib.ui_modal.top()`) (3.4) |
  | `notes` | `lib/notes.lua` | the note pool is a whole number in 0..`NOTE_POOL.max`, the extra notes held never exceed it, and a stopped voice holds none (3.5) |
- **Registering a cleanup step**: `S.register_cleanup(S.constants.CLEANUP_ORDER.<step>, fn)` in the module that starts the resource, and one line in `CLEANUP_ORDER` (`lib/constants.lua`) at a free order at its place in the sequence (orders are spaced by 10; two steps never share one). `cleanup()` itself is never edited.

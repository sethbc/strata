## Must not break

- `include("lib/state")()` builds a fresh `S` on every call, so a script reload keeps nothing from the last run. Never keep a table from an earlier `S`.
- State that more than one module uses is a field of `S` under its plain name. The tests find it by that name (`local_value`), so renaming it breaks them.
- `S.voices` is the only source of values. The engine holds no per-voice defaults.
- Source tests use `voice_uses_synth(i)`, `voice_uses_buffer(i)`, `voice_uses_input(i)` and `voice_uses_voice(i)` (3.8), exactly one of which holds for a voice. Never `not voice_uses_synth` or "neither synth nor buffer" (that includes input and voice sources).
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
  - `S.registry` (`pages`, `params`, `start`, `cleanup`, `grid_layouts`, `voice_params`, `scene_fields`, `source_change`, `param_filters`, `lfo_destinations`, `fx_params`, `grain_restart`, `alt_release`, `menu_close`, `invariants`, and 3.4's `scene_blocks`, `pset_hooks`, `param_touch`, `lock_change`, `step_outputs`, `mod_sources`, and 3.5's `voice_stop`, `freeze_change`, and 3.6's `note_hooks`, `scene_recalled`, `silence_change`, `note_targets`, `ii_devices`, `macro_targets`, `io_sections`, and 3.7's `voice_hit`, `scene_applied`, and 3.8's `grid_pages`, `voice_types`), `S.register_start`, `S.register_cleanup`, `S.register_invariant`, `S.lib`.
  - The `__declared` key set the tests use: a key ever assigned into `S`, even to nil, is recorded there.
- `lib/constants.lua`: `S.constants`, a plain table. The constants and fixed tables (`NUM_VOICES`, `UI_PAGES`, `GRAIN_MODE_OPTIONS`, `START_ORDER`, `CLEANUP_ORDER`, ...; 3.8 removed `MAIN_PARAMS`: each voice type's record holds its `main` and `list_name`, `docs/notes/lua/types.md`).
  - Beside the eleven `AGENTS.md` quotes (Named constants): `STANDARD_BUFFER_SECONDS` (16), `STANDARD_PERFORMANCE`, `BUFFER_DATA_VERSION` (3), `NUM_BOOKMARKS` (4), `WAVEFORM_POINTS` (64), `RECORD_SOURCES`, `RECORD_SYNC`, `FILES`, `WAVEFORMS`, `PLAYHEADS` and `SCRUB`; 3.4's `NUM_MACROS` (16), `MACRO_BANK_SIZE` (4), `MACRO_TARGETS` (8), `MATRIX_SLOTS` (16), `NUM_GESTURES` (4), `SCENE_BANK_SIZE` (8), `SCENE_NAME_MAX` (12), `GRID_HOLD.step_edit_seconds` (0.3), `ENGINE_BUDGET` (`messages_per_window` 150, `window_seconds` 0.1: the deferrable sends' budget, `lib/engine_sync.lua`), `NUM_FAST_DESTINATIONS` (5) and `FAST_MOD_NOTE_SLOTS` (1); and 3.5's `NOTE_POOL` (`max` 16 and each tier's default).
- `lib/voices.lua`: `S.lib.voices`, with `is_synth_key(voice_idx, key)` (whether `key` is in the voice's `param_order`, its current type's keys; false before init; a synth-key test is never `values[key] ~= nil`).
  - `S.voices`, `S.locked`, `S.selected_voice`. There is no density field: the master density is the param `master_density` (read through `engine_param_value` or `params:get`).
  - The global source tests `voice_uses_synth`, `voice_uses_buffer`, `voice_uses_input`, `voice_uses_voice` (3.8), `voice_source_voice` (the voice 1-7 a voice source reads, else nil), `voice_source_label` (the option's name, `v<j>` for a voice source), `voice_buffer_slot`. The four 3.8 names take any index: one that is no voice gives false, false, nil and `""`, never an error (the grid calls them from its keys); the two older predicates index the voice.
  - The three built-in voice-param records (the groundwork before 3.8), registered last in its constructor and so the first of `S.registry.voice_params`: `synth` (3.8: `v<i>_type` and every voice type's synth keys, `docs/notes/lua/types.md`), `grain` (`source` and the eight grain and buffer params; its fader group holds `lib/grain.lua`'s shape and skew where 3.7's envelope was) and `crossmod` (`docs/notes/lua/params.md`, Voice params).
- `lib/grain.lua` (3.8): the grain's controls, the fourth voice-param record, `docs/notes/lua/grain.md`.
- `lib/types.lua` and `lib/types/<key>.lua` (3.8): the voice types, `docs/notes/lua/types.md`.

## Voice state

Each `S.voices[i]` holds:
- `name`: the voice's current type's key (3.8: its `v<i>_type`; set at init by the synth record's `add_first` and by every type change; nil before init, so nothing reads it at include time).
- `active`: whether it runs.
- `source`: the grain source, a `SOURCE_OPTIONS` index. 1 = synth, 2..`NUM_BUFFERS` + 1 = buffer 1-8, `NUM_BUFFERS` + 2 = input, then (3.8) `SOURCE_VOICE_FIRST` (`SOURCE_INPUT` + 1) + j - 1 = voice j's output ring, j 1-7 (`SOURCE_SYNTH`, `SOURCE_INPUT`, `SOURCE_VOICE_FIRST`; `#SOURCE_OPTIONS` is 17). Option n is sent as `setGrainSource(v, n - 1)`.
- `param_order`: the voice's current type's synth keys in order (a copy of its record's; grid fader order; amp/pan last; nil before init). Whether a key is one is `S.lib.voices.is_synth_key(i, key)`, never `values[key] ~= nil`.
- `values`: every value of the voice, by key, its param id without `v<i>_` (the groundwork before 3.8; 3.7's four tables `params`, `grain`, `crossmod` and `extras` are gone): the synthesis params (3.8: every voice type's keys, `freq`, `amp`, ..., the current type's and the others', each default its type record's), the grain and buffer params (`grain_size`, `grain_density`, `grain_pitch`, `grain_spread`, `grain_mode`, an option index, `buf_pos`, `buf_rate`, `buf_scan`), crossmod (`mod_source_<n>`, `mod_amp_amt_<n>`, `mod_freq_amt_<n>` for each slot, `mod_speed`), and each registered per-voice param (`add_voice_param` stores every one, the built-in records' included: freeze, variation, loops, history, the voice mix, ...). The fourteen `out_*` and `zone*` params are not in it. A voice's start and sync (`S.lib.params_setup.voice_engine_parts`), scenes (`capture_voice`) and the pages read it.

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
| 16 | fill IO's `layout_states`: per registered section, in the page's order, `<name> at the top`, then each of the section's own states after the same (`START_ORDER.io_layout_states`, 3.6) | `lib/pages/io.lua` |
| 20 | E1: acceleration off, `E1_TICKS_PER_PAGE` ticks per page | `strata.lua` |
| 30 | watch the norns menu opening (`watch_menu_opening`) | `lib/ui/menu_watch.lua` |
| 40 | create and start the drift metro (`S.drift_metro`, 0.1 s, `drift_update`) | `lib/mutation.lua` |
| 50 | create the mutation metro (`S.mutation_metro`, `mutation_rate`, `gentle_mutate`); the `mutation_enabled` param starts it | `lib/mutation.lua` |
| 55 | make the tunings folder, data/strata/tunings/ (`START_ORDER.tuning`); nothing is sent: the engine starts in the default tuning (3.8) | `lib/tuning.lua` |
| 60 | set and start the `bufferState`, `bufferLoadFailed` and `bufferSaveResult` polls (`S.buffer_polls`) | `lib/buffers.lua` |
| 61 | read the files' settings from data/strata/samples.data (`START_ORDER.samples_load`, before the buffers' restore; a missing file gives none, one it cannot use is set aside as `samples.data.bak` with a console line and gives none) (3.7) | `lib/samples.lua` |
| 62 | set and start the input level polls `amp_in_l` and `amp_in_r` (`START_ORDER.input_level`; a poll a norns lacks is skipped) (3.4) | `lib/input_level.lua` |
| 64 | set and start the `bufferOnsets` poll, the transients pass's report (`START_ORDER.slices_poll`) (3.7) | `lib/slices.lua` |
| 65 | set and start the `recordState` poll (`record_poll`) | `lib/record.lua` |
| 70 | connect the arc (`arc_init`) | `lib/arc/core.lua` |
| 80 | read the grid rotations (`grids.data`), then connect the grids (`grid_init`) | `lib/grid/core.lua` |
| 85 | read the rig settings from data/strata/io.data (`START_ORDER.io_rig`; a missing file gives the defaults, one it cannot use is set aside as `io.data.bak` with a console line and gives the defaults; no listener is told) (3.6) | `lib/io/rig.lua` |
| 88 | keep the `midi.add` and `midi.remove` found installed and install the MIDI ports' own, which tell the ports' `on_change` listeners and then call the kept ones, and note each port's device (3.6) | `lib/io/ports.lua` |
| 90 | listen for MIDI (`midi_init`) | `lib/midi_in.lua` |
| 92 | set `norns.crow.add` (crow's reset, then the settings' lines and the `on_setup` hooks) and `norns.crow.remove` (what waits dropped, the output clocks ended, the `on_gone` hooks) directly, install the crow events, and with a crow already there send its setup (`START_ORDER.io_crow`, 3.6) | `lib/io/crow.lua` |
| 93 | with a crow already there, do what the rig's `ii_bus` asks: under `strata` take the lead (each ii device's `ready`), under `teletype` send Teletype's three handlers; under `off`, or without a crow, nothing (`START_ORDER.io_ii`, 3.6) | `lib/io/ii.lua` |
| 94 | claim and listen to the E16's and the fader box's ports (`START_ORDER.io_controllers`; none while the rig's ports are off), listen to the rig's port keys and the ports' `on_change`, and start the echo clock while a port is set (3.6) | `lib/io/controllers.lua` |
| 95 | claim each port the rig names for a remote grid or arc that holds a device, listen to it and ask it for its hello; with `midi_grid` on, attach what `grid.connect()` returns when it is a MIDI grid (`START_ORDER.io_remote`, 3.6) | `lib/io/remote.lua` |
| 96 | set `osc.event` (the OSC addresses of `S.lib.io_osc`) and start the feedback clock if feedback is on and a sender is known (`START_ORDER.io_osc`, 3.6) | `lib/io/osc.lua` |
| 97 | start the tape loop when `tapeloop` is already on (`START_ORDER.io_tape`; with its default, nothing) (3.6) | `lib/io/tape.lua` |
| 100 | add the registered scene fields to `S.SCENE_GLOBAL_PARAMS`, then load scenes.data (`load_scenes_from_disk`, sets `S.scenes_loaded`) | `lib/scenes.lua` |
| 105 | load the macros' targets from data/strata/macros.data (`START_ORDER.macros_load`; a missing file loads them empty, one it cannot use is set aside, an unknown target id is kept with a console line), then redraw the screen and grids (3.4) | `lib/macros.lua` |
| 107 | load the gesture recorders, stopped, from data/strata/gestures.data (`START_ORDER.gestures_load`; a missing file loads them empty, one it cannot use is set aside), then redraw the screen and grids (3.4) | `lib/gestures.lua` |
| 108 | load the matrix's routings from data/strata/matrix.data (`START_ORDER.matrix_load`; a missing file loads them empty, one it cannot use is set aside, an unknown source key or destination id is kept with a console line), then redraw the screen (3.4) | `lib/matrix.lua` |
| 109 | read the note pool from data/strata/notes.data (`START_ORDER.notes_load`; a missing file leaves the tier's default, one it cannot use too, with a console line), send it (`setNotePool`) and join the expression flush to the LFO clock's step hooks (3.5) | `lib/notes.lua` |
| 110 | reload the remembered buffers, after the scenes, which may use them (`load_buffers_from_disk`, sets `S.buffers_loaded`) | `lib/buffers.lua` |
| 111 | load the random sequences' values from data/strata/sequences.data (`START_ORDER.sequences_load`; with no file it can use, every value is drawn and the timed write started, one it cannot use is set aside), then redraw the screen (3.7) | `lib/random_sequences.lua` |
| 112 | join the arpeggiator's shuffle to the LFO clock's step hooks, once (`START_ORDER.arp`; sends nothing) (3.8) | `lib/arp.lua` |
| 113 | read the voice preset library from data/strata/voices.data (`START_ORDER.voice_presets_load`; missing: an empty library; one it cannot use is set aside, and one that cannot be set aside blocks every write this session) (3.8) | `lib/voice_presets.lua` |
| 117 | with a factory index in the script's folder (3.8 ships none: then nothing is read further and nothing written), read `factory.data`: a pending set the index lists loads again; no marker, no scenes file found at this start (`S.scene_file.start_outcome` `"missing"`) and a first-run set write `{pending = <key>, loaded = {}}` and start its load, not awaited; no marker otherwise writes `{loaded = {}}`; an unusable one is set aside and written afresh (`START_ORDER.factory_first_run`, ruling 51, 3.8) | `lib/factory.lua` |
| 120 | the start-up clock (below) | `strata.lua` |
| 125 | check every global LFO destination's param, then start the LFO clock (`S.lfo_clock`, 48 Hz, 3.4) | `lib/lfos.lua` |
| 130 | start the frame clock (`start_frame_clock`) | `lib/ui/frame.lua` |
| 140 | start the peaks read loop (`S.lib.waveforms.read_clock`, one tick per frame) | `lib/waveforms.lua` |
| 150 | start the playhead clock (`start_clock`) | `lib/playheads.lua` |
| 160 | follow an external clock's transport: install `clock.transport.start` and `stop`, which act only when `clock_source` is not internal, keeping the handlers found (#530) | `lib/sequencer.lua` |
| 161 | register the `targets` step output (`START_ORDER.io_targets`), so it plays after `voices`, which the sequencer registers as it loads (3.6) | `lib/io/targets.lua` |

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
| 33 | save the random sequences' values to data/strata/sequences.data at once, canceling the write that waits (`S.sequences_save_clock`) (`CLEANUP_ORDER.sequences_save`; skipped if their start step never ran; drift's draws are saved here) (3.7) | `lib/random_sequences.lua` |
| 34 | save the gesture recorders to data/strata/gestures.data at once, canceling the write that waits (`S.gesture_save_clock`) (`CLEANUP_ORDER.gestures_save`; skipped if their start step never ran; a recording is saved as if it stopped then) (3.4) | `lib/gestures.lua` |
| 36 | save the matrix's routings to data/strata/matrix.data at once, canceling the write that waits (`S.matrix_save_clock`) (`CLEANUP_ORDER.matrix_save`; skipped if its start step never ran) (3.4) | `lib/matrix.lua` |
| 37 | write the files' settings to data/strata/samples.data at once, canceling the write that waits (`CLEANUP_ORDER.samples_save`; skipped if its start step never ran, or if a file it could not use could not be moved aside) (3.7) | `lib/samples.lua` |
| 38 | write the rig settings to data/strata/io.data once more (`CLEANUP_ORDER.io_rig_save`; skipped if its start step never ran) (3.6) | `lib/io/rig.lua` |
| 40 | save the buffer paths (skipped the same way for buffers.data, with `S.buffers_loaded`) | `lib/buffers.lua` |
| 50 | cancel init's start-up clock (`cancel_startup_clock`, while it waits to start voice 2) | `strata.lua` |
| 60 | stop the frame clock | `lib/ui/frame.lua` |
| 70 | stop the drift metro | `lib/mutation.lua` |
| 80 | stop the mutation metro and set `mutation_enabled` to 0, so param and state agree | `lib/mutation.lua` |
| 85 | cancel the randomize undo's expiry clock | `lib/mutation.lua` |
| 86 | cancel every voice's type-row settle clock and forget its pending choice, applying nothing (3.8) | `lib/types.lua` |
| 90 | stop the pattern clock and give the clock back the transport handlers found at init, if the script's are still installed | `lib/sequencer.lua` |
| 95 | stop every gesture recorder: a recording ends (kept, stopped), every free loop's metro stops and every quantized loop's clock and 10-minute clock are canceled (`gestures`, 3.4) | `lib/gestures.lua` |
| 97 | cancel every quantized action that waits (`quantize`, 3.4; the flashes' own step ends its header flash) | `lib/quantize.lua` |
| 100 | stop the scene sequencer through its param (`scene_sequencer_enabled` 0 when the param exists, then `scene_sequencer_stop`) | `lib/scenes.lua` |
| 110 | cancel a scene transition | `lib/scenes.lua` |
| 112 | cancel the morph clock (`S.morph_clock`) and drop the apply it waited for (3.4) | `lib/morph.lua` |
| 114 | cancel the macros' apply clock (`S.macro_clock`), dropping every apply that waits, and learn's timeout (`S.macro_learn_clock`) (`CLEANUP_ORDER.macros`, 3.4) | `lib/macros.lua` |
| 116 | cancel a factory set's load clock (`S.factory_clock`) where it is: a copy cut short leaves its `.part`, which the next load writes over, and nothing is marked loaded (`CLEANUP_ORDER.factory`, 3.8) | `lib/factory.lua` |
| 117 | end the zones editor's learn: cancel its timeout (`S.zones_learn_clock`) and every retired one, and clear the MIDI module's note tap (`CLEANUP_ORDER.zones_learn`, 3.5) | `lib/ui/zones.lua` |
| 118 | cancel matrix learn's timeout (`S.matrix_learn_clock`) and forget the matrix's offsets (its extra offsets and fast sums), sending nothing; the matrix steps in the LFO clock and has no clock of its own (`CLEANUP_ORDER.matrix`, 3.4) | `lib/matrix.lua` |
| 119 | end the note module's expression flush (`S.lib.notes.stop_flush`): nothing is due and its LFO step hook sends nothing after it (`CLEANUP_ORDER.notes`, 3.5) | `lib/notes.lua` |
| 120 | cancel the LFO clock, empty the round robin and give every direct destination (an LFO on a macro) back (`release_direct`); no `stopFastLfo` is sent (the engine is already freed) and the Lua homes' offsets are the matrix's (118) | `lib/lfos.lua` |
| 122 | stop the playhead clock (`stop_clock`) | `lib/playheads.lua` |
| 124 | cancel every voice's scrub glide and scan hold (`scrubRate` and `scanHold` back to 0) | `lib/positions.lua` |
| 126 | stop the peaks read loop (`S.lib.waveforms.stop`) | `lib/waveforms.lua` |
| 127 | cancel the send budget's flush clock (`S.engine_budget_clock`) and drop the values waiting for it (3.4; the engine is already freed, #461) | `lib/engine_sync.lua` |
| 128 | cancel each slot's pending start reload of a long file | `lib/buffers.lua` |
| 130 | stop the buffer polls and the recording timers (the engine finishes or frees any recording itself) | `lib/buffers.lua` |
| 131 | stop the `bufferOnsets` poll and cancel the clock that reads the onsets files (`CLEANUP_ORDER.slices_poll`) (3.7) | `lib/slices.lua` |
| 132 | stop the `recordState` poll and forget the takes | `lib/record.lua` |
| 135 | stop the `amp_in_l` and `amp_in_r` input level polls and clear their callbacks (3.4: the polls moved from the BUFFER page, `input_meter` keeps its order) | `lib/input_level.lua` |
| 140 | cancel the flash clocks (the header's and the hint row's, `S.lib.ui_flash.cancel_all`) | `lib/ui/flash.lua` |
| 142 | end every target note at once (`S.lib.io_targets.stop_all`: each sounding note's off to the targets its on went to, then each target's `stop_all`), before the MIDI handlers go; the LFO clock has stopped, so no off waits for a step (`CLEANUP_ORDER.io_targets`, 3.6) | `lib/io/targets.lua` |
| 143 | drop MIDI out's express queue and send nothing more (`CLEANUP_ORDER.io_midi_out`, after the targets ended every note at 142, whose offs went out) (3.6) | `lib/io/midi_out.lua` |
| 144 | stop the ii bus (`S.lib.io_ii.stop`): while Strata leads, each device's notes ended, the waiting offs sent at once (14 at most, the rest dropped), each device's `release`, then the lead cleared; after it nothing is queued or sent, before crow's step (`CLEANUP_ORDER.io_ii`, 3.6) | `lib/io/ii.lua` |
| 145 | end crow's flush clock and output clocks and drop what waits; when some crow param is not `off`, send `output[n].volts = 0` for the four outputs and `input[n].mode('none')` for the two inputs (a jack norns' clock owns excepted); set `norns.crow.add` and `remove` to functions that do nothing (#468) (`CLEANUP_ORDER.io_crow`, 3.6) | `lib/io/crow.lua` |
| 146 | end the controllers' echo clock and release the E16's and the fader box's ports (`CLEANUP_ORDER.io_controllers`, before the MIDI handler) (3.6) | `lib/io/controllers.lua` |
| 147 | cancel the remote devices' draw clock, send each remote grid and arc CC 4 = 0, detach them, stop listening, release their ports, and detach the midigrid (left dark) (`CLEANUP_ORDER.io_remote`, 3.6) | `lib/io/remote.lua` |
| 148 | cancel the OSC feedback clock, forget the sender and set `osc.event` to nil (`CLEANUP_ORDER.io_osc`, 3.6) | `lib/io/osc.lua` |
| 149 | stop the tape loop (`CLEANUP_ORDER.io_tape`: both softcut voices disabled and the mixer's three cut levels put back; nothing when the tape was never on) (3.6) | `lib/io/tape.lua` |
| 150 | detach the MIDI handler (its `S.lib.io_ports` listener), before the voices go off, and clear the note tap | `lib/midi_in.lua` |
| 152 | put back the `midi.add` and `midi.remove` the start step found, clear every vport `event` the ports set and forget their listeners (3.6) | `lib/io/ports.lua` |
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
- **Where things live**: a module's table is `S.lib.<name>` (top-level `lib/` files) or `S.lib.<dir>_<basename>` (subfolders); shared state is on `S` under its plain name; the registries are `S.registry.pages`, `S.registry.params`, `S.registry.start`, `S.registry.cleanup`, `S.registry.grid_layouts`, and `voice_params`, `scene_fields`, `source_change`, `param_filters`, `lfo_destinations`, `fx_params`, `grain_restart`, `alt_release`, `menu_close`, `invariants`, `scene_blocks`, `pset_hooks`, `param_touch`, `lock_change`, `step_outputs`, `mod_sources`, `voice_stop`, `freeze_change`, `note_hooks`, `scene_recalled`, `silence_change`, `note_targets`, `ii_devices`, `macro_targets`, `io_sections`, `voice_hit`, `scene_applied`, `grid_pages` and `voice_types` (`lib/state.lua`).
- **Registries** (`S.registry`, filled as the modules load): `pages` (one record per screen page), `params` (init runs each record's `add`, in PARAMS menu order), `grid_layouts` (`{key, redraw, panes, pane_at, start_pages}` per grid size, each made by `S.lib.grid_pane.arrange`), `start` (init runs each step by order after the params) and `cleanup`; and, for 3.2's features, `voice_params` (per-voice param records), `scene_fields` (global scene fields), `source_change` (hooks after a source change), `param_filters` (one value filter per voice param key), `lfo_destinations` (per-voice LFO destinations), `fx_params` (params after the fx group's own), and, for 3.3, `grain_restart` (`S.register_grain_restart(fn(voice_idx))`: run by `lib/engine_sync.lua` after every `engine.voiceOn` and every `engine.setGrainSource` that changes a running voice's source, every one of which is sent through `S.lib.engine_sync.send_grain_source`, `docs/notes/lua/engine-sync.md`), `alt_release` (`S.register_alt_release(fn())`: run when ALT goes from held to not held), `menu_close` (`S.register_menu_close(fn())`: run each time the norns menu closes, after norns' `set_mode(false)` returns, each hook in its own `pcall`, so one that fails prints a line and never stops the menu closing or the next hook; the menu watch's start step reads the registry as it builds its wrapper, so hooks register at include time; `docs/notes/lua/ui/alt-and-keys.md`) and `invariants` (`S.register_invariant(name, fn)`: `{name, fn}` records the test harness checks after every unit test, never run on the device; see "Registering an invariant" below). 3.4's (design §0.1, §8.10, §10.1; package 0a), each register function refusing a duplicate name and a field outside its record's set:
  - `scene_blocks` (`S.register_scene_block({key, default = fn() -> value, capture = fn() -> value, validate = fn(value) -> boolean, apply = fn(value), discrete = true, through_zero = fn(from_value, to_value) -> {{id, switch = fn()}, ...}})`: a top-level scene block `lib/scenes.lua` captures, validates and applies, switched at a transition's end; `through_zero`, optional, names the depths that ramp through 0 in a transition or a morph);
  - `pset_hooks` (`S.register_pset_hook({name, write = fn(path_base, number), read = fn(path_base, number, pset_path, silent), delete = fn(path_base, number)})`, each function optional: run by the PSET actions `lib/params_setup.lua` installs, `docs/notes/lua/params.md`);
  - `param_touch` (`S.register_param_touch(fn(param_id, source))`: run after each user edit of a param, once it is set: `"enc"` and `"arc"` from `delta_with_detent` (`lib/ui/detent.lua`, `opts.source` naming an arc ring's whole steps; never for a detent the hold swallows), `"grid"` from `set_param_from_column` (`lib/grid/faders.lua`); a plain `params:set`, the drift, a mutation or a recall is no touch. `lib/engine_sync.lua`'s hook clears the param's base override);
  - `lock_change` (`S.register_lock_change(fn(voice_idx, locked))`: run by `toggle_lock` after the flip, with the new state, and by a scene recall's lock states);
  - `step_outputs` (`S.register_step_output({name, play = fn(event), stop = fn(), available = fn(voice_idx) -> boolean})`, `stop` and `available` optional: each pattern hit's outputs, `lib/sequencer.lua`);
  - `mod_sources` (`S.register_mod_source({key, name, section, value = fn() -> number, range = {min, max}, describe = fn() -> string, visible = fn() -> boolean, row = {enc, fine_enc, press, alt_press, hints}, fields})`: `name` at most 4 characters, `range[1] < range[2]` (below 0: bipolar); `describe`, `visible`, `row` and each row function optional; 3.7's optional `fields`, MOD's settings rows (a list of `{label, value, enc, fine_enc, press}`, each `label` 1 to 8 characters and `value` a function, the rest optional functions, any other key refused; or a function returning one, read at each draw); read only through `S.lib.mod_sources`, `docs/notes/lua/mod-sources.md`);
  - 3.5's (design §0.1; package 0a), plain hooks that refuse a non-function: `voice_stop` (`S.register_voice_stop(fn(voice_idx))`: run after every `engine.voiceOff` the script sends, all in `lib/engine_sync.lua`: `toggle_voice`'s stop, once the voice is marked stopped; a start that failed once its `voiceOn` went, before the error is raised again; cleanup step 160, per running voice) and `freeze_change` (`S.register_freeze_change(fn(voice_idx, frozen))`: run by every `v<i>_freeze` action, once the value is stored and sent, `frozen` true for 1, before the action's grid redraw; `lib/freeze.lua`). Each hook of both runs protected, as the LFO step hooks do (`S.lib.ui_frame.contained_call`): one that raises prints `strata: voice stop hook failed: ` or `strata: freeze change hook failed: ` with its traceback, once per distinct message per hook, and is skipped, so the next hook, the stop (its redraws, a failed start's own error, cleanup's other `voiceOff`s and later steps) and the freeze action's grid redraw still go on;
  - 3.6's (design §0.1; package 0a), each read at each use and run contained (`S.lib.ui_frame.contained_call`): `note_hooks` (`S.register_note_hook({name, started, ended, moved, expressed, heard})`, each function optional, called with `(voice_idx, slot, note)`: run by `lib/notes.lua`, `docs/notes/lua/notes.md`; 3.7's `heard(voice_idx, note, velocity)` by `lib/midi_in.lua` for every MIDI note a voice receives, `docs/notes/lua/midi.md`), `scene_recalled` (`S.register_scene_recalled(fn(scene_num))`: once per recall, `docs/notes/lua/scenes.md`), `silence_change` (`S.register_silence_change(fn(voice_idx, silenced))`: each voice whose `silenced` answer a mute or solo changed, `docs/notes/lua/voice-mix.md`), `note_targets` (`S.register_note_target({name, routed, note_on, note_off, express, stop_all, rows, status, layout_states})`, the first four required, `layout_states` a list of `{name, setup = fn(context)}` checked as an IO section's: the targets 3.6's note targets module plays), `ii_devices` (`S.register_ii_device({name, ports, ready, release, param_count, add_params})`: `ports` required, true or false, whether every command of the device with an argument takes the port it addresses first (the ii queue's turns, #717); `param_count` a finite whole number, 0 by default, above 0 only with `add_params`; the registry keeps a copy with the count filled in, the caller's table left as given; read by 3.6's ii module) and `macro_targets` (`S.register_macro_target(id, label)`: two non-empty strings, never a `macro_<n>` id; the catalog lists each after the matrix depths, `docs/notes/lua/macros.md`);
  - 3.6's `io_sections` (`S.register_io_section({name, title, rows = fn() -> {row, ...}, status = fn() -> string | nil, layout_states = {{name, setup = fn(context)}, ...}})`, package 0c): the IO page's sections (`lib/pages/io.lua`, `docs/notes/lua/pages/io.md`); `title` a string or a function returning one, `rows` required, `status` and `layout_states` optional; a second name or a field outside the set is refused; read at each use, so it stays open;
  - 3.7's `voice_hit` (design §0.2, package 0b): `S.register_voice_hit({name, hit = fn(voice_idx, info)})`, `hit` a function, a second name or another field refused; read at each use, so it stays open. `lib/engine_sync.lua` tells every hook once per hit (a retrigger, a played extra note's start, a start no retrigger follows), with `info = {velocity, source, slot, gate_seconds}` (`source` `"step"`, `"note"`, `"action"` or `"start"`), each through `S.lib.ui_frame.contained_call`; a hook never sends and never yields (`docs/notes/lua/engine-sync.md`, 3.7's seams);
  - 3.7's `scene_applied` (1d's review): `S.register_scene_applied({name, fn = fn()})`, `fn` a function, a second name or another field refused; read at each use, so it stays open. `lib/scenes.lua`'s `apply_entries` runs every hook once, right after it clears `S.scene_recall_in_progress` (an instant recall, a fade's landing, morph's discrete entries; after an error too), each through `S.lib.ui_frame.contained_call` (`strata: scene applied hook <name> failed: `, once per message); the delay's held send uses it (`docs/notes/lua/delay-sync.md`), and so does the scan, which settles a stopped voice's follow factor after a recall (#739, `docs/notes/lua/scan.md`);
  - 3.8's `voice_types` (design §2.1, package 0d): `S.register_voice_type(record)`, one record a type from its own `lib/types/<key>.lua`, kept in type order with the `index` the registry gives it (`docs/notes/lua/types.md`); closes at init;
  - 3.8's `grid_pages` (design §10.1, package 0e): `S.register_grid_page({name, index, press = fn(pane, x, y, z), redraw = fn(pane, led), sides, faders = fn(pane) -> {{line, first, keys, id}, ...}, signature = fn(pane) -> string})`, `sides` (1 or 2), `faders` and `signature` optional, kept at `S.registry.grid_pages[index]`: `index` a page of `S.constants.GRID_PAGES` (1 to `count`) no record holds, `name` that page's (`GRID_PAGES.names[index]`), `press` and `redraw` functions; any other field refused. Read at each press and redraw by `lib/grid/pane.lua` (`docs/notes/lua/grid/pane.md`), so it stays open and a test can put a probe record at a free index of its own `S`;
  - and two extensions: `S.register_lfo_global_destination(label, param_id, group)` appends `{label, param_id, global = true, group}` to `lfo_destinations` (one destination, in registration order with the per-voice ones; the labels share one namespace; `group`, the destination list's group it joins, is `global` (the default) or `macros`, and any other is refused, #729), and `S.register_scene_field` takes an optional `set = fn(value)`, kept on the field's record: what a recall, a transition step and `apply_entries` call in place of `params:set`.
  `scene_blocks` and `pset_hooks` close at init (3.7 removed `scene_migrations`: no conversion is keyed on a scenes format, `docs/notes/lua/scenes.md`), as `voice_params`, `scene_fields`, `lfo_destinations`, `fx_params`, `start`, `menu_close` and 3.8's `voice_types` do (#384): nine in all (`INIT_READ`, `lib/state.lua`). The other 25 are never closed: `pages`, `params`, `cleanup`, `grid_layouts`, `source_change`, `param_filters`, `grain_restart`, `alt_release`, `invariants`, `param_touch`, `lock_change`, `step_outputs`, `mod_sources`, `voice_stop`, `freeze_change`, 3.6's seven (`note_hooks`, `scene_recalled`, `silence_change`, `note_targets`, `ii_devices`, `macro_targets`, `io_sections`) 3.7's `voice_hit` and `scene_applied` and 3.8's `grid_pages`, most read at each use. A voice-param record's optional `scene_ranges` (`{<key> = {min, max}}`, continuous keys only, holding the key's default) makes `validate_scene` reject a scene whose extra lies outside it; its `scene_defaults` may be a function of the voice that gives the table (3.7, each voice's table checked, all with the same keys), read through `S.voice_scene_defaults(record, voice_idx)`; its `count` and `voice_keys` may be functions of the voice too (the groundwork before 3.8); a record with any of the three a function is checked at init, voice by voice (3.8, ruling 19: `S.check_voice_params`, run by `add_voice_params`, since such a function may read the voice types), the others at registration; read through `S.voice_param_count(record, voice_idx)` and `S.voice_keys_of(record, voice_idx)`. Each has a register function on `S` (`S.register_voice_params`, ...) that checks its argument and refuses a duplicate name. The readers read them at init (inside a `register_params` add or later), never at include time, so a registering module's include order never matters. "Registering start and cleanup steps" below and `docs/notes/lua/params.md` (Registering params) say how to add to each.
- **`S.performance`** (`{tier, buffer_seconds, max_grains, history_seconds, reason}`): the tier the engine runs, read from the engine's `performance_active.data` by `S.lib.performance.read_active` in the first params record (`"performance"`, before any param is added); a missing or invalid file gives a copy of `S.constants.STANDARD_PERFORMANCE`. Every tier-dependent spec reads it (`record_duration` goes to `S.performance.buffer_seconds`). The setting itself (`performance.data`) is SETUP's, never a param.
- Tests reach script state with `local_value(name)` and `find_upvalue(name)`: a field of `S`, then of `S.constants`, then an upvalue of a global function.

### The module table

Every module, in include order (`strata.lua`'s includes), with its `S.lib` name, notes file and unit test files (under test/unit/, one per module). `AGENTS.md` lists only the rows that break the naming rule: a top-level module `lib/<name>.lua` is `S.lib.<name>`, with its notes in `docs/notes/lua/<name>.md` (underscores as hyphens) and its tests in `test/unit/<name>_test.lua`; a module in a subfolder of lib/ keeps a row there. A new module adds its row here, at its include place.

| Module | S.lib name | Notes | Unit tests |
|--------|--------------|-------|------------|
| `strata.lua` (entry points) | | `docs/notes/lua/state-and-voices.md` | strata_test.lua, structure_test.lua |
| `lib/state.lua`, `lib/constants.lua` | S itself, S.constants | `docs/notes/lua/state-and-voices.md` | structure_test.lua, registries_test.lua |
| `lib/voices.lua` | `voices` | `docs/notes/lua/state-and-voices.md` | voices_test.lua |
| `lib/grain.lua` | `grain` | `docs/notes/lua/grain.md` | grain_test.lua |
| `lib/types.lua` | `types` | `docs/notes/lua/types.md` | types_test.lua |
| `lib/types/<key>.lua` (one per voice type, in type order: `resonator`, `fm`, `folder`, `sub`, `pulse`, `karplus`, `ring`, `wave`, `additive`, `noise`, `saw`, `formant`) | `types_<key>` | `docs/notes/lua/types.md` | types_test.lua, types_<key>_test.lua |
| `lib/ui/frame.lua` | `ui_frame` | `docs/notes/lua/ui-core.md` | ui_test.lua, ui_layout_test.lua |
| `lib/engine_sync.lua` | `engine_sync` | `docs/notes/lua/engine-sync.md` | engine_sync_test.lua |
| `lib/data_files.lua` | `data_files` | `docs/notes/lua/data-files.md` | data_files_test.lua |
| `lib/chance.lua` | `chance` | `docs/notes/lua/chance.md` | chance_test.lua |
| `lib/side_files.lua` | `side_files` | `docs/notes/lua/data-files.md` (Side files) | side_files_test.lua |
| `lib/buffers.lua` | `buffers` | `docs/notes/lua/buffers.md` | buffers_test.lua |
| `lib/record.lua` | `record` | `docs/notes/lua/record.md` | record_test.lua |
| `lib/lfos.lua` | `lfos` | `docs/notes/lua/lfos.md` | lfos_test.lua |
| `lib/mutation.lua` | `mutation` | `docs/notes/lua/mutation.md` | mutation_test.lua |
| `lib/scenes.lua` | `scenes` | `docs/notes/lua/scenes.md` | scenes_test.lua |
| `lib/midi_in.lua` | `midi_in` | `docs/notes/lua/midi.md` | midi_in_test.lua |
| `lib/history.lua` | `history` | `docs/notes/lua/history.md` | history_test.lua |
| `lib/freeze.lua` | `freeze` | `docs/notes/lua/freeze.md` | freeze_test.lua |
| `lib/loops.lua` | `loops` | `docs/notes/lua/loops.md` | loops_test.lua |
| `lib/tuning.lua` | `tuning` | `docs/notes/lua/tuning.md` | tuning_test.lua |
| `lib/variation.lua` | `variation` | `docs/notes/lua/variation.md` | variation_test.lua |
| `lib/voice_mix.lua` | `voice_mix` | `docs/notes/lua/voice-mix.md` | voice_mix_test.lua |
| `lib/performance.lua` | `performance` | `docs/notes/lua/performance.md` | performance_test.lua |
| `lib/files.lua` | `files` | `docs/notes/lua/files.md` | files_test.lua |
| `lib/waveforms.lua` | `waveforms` | `docs/notes/lua/waveforms.md` | waveforms_test.lua |
| `lib/samples.lua` | `samples` | `docs/notes/lua/samples.md` | samples_test.lua |
| `lib/playheads.lua` | `playheads` | `docs/notes/lua/playheads.md` | playheads_test.lua |
| `lib/positions.lua` | `positions` | `docs/notes/lua/positions.md` | positions_test.lua |
| `lib/scan.lua` | `scan` | `docs/notes/lua/scan.md` | scan_test.lua |
| `lib/bookmarks.lua` | `bookmarks` | `docs/notes/lua/bookmarks.md` | bookmarks_test.lua |
| `lib/ui/modal.lua` | `ui_modal` | `docs/notes/lua/ui/pages-and-dispatch.md` | ui_modal_test.lua |
| `lib/quantize.lua` | `quantize` | `docs/notes/lua/quantize.md` | quantize_test.lua |
| `lib/conditions.lua` | `conditions` | `docs/notes/lua/conditions.md` | conditions_test.lua |
| `lib/mod_sources.lua` | `mod_sources` | `docs/notes/lua/mod-sources.md` | mod_sources_test.lua |
| `lib/macros.lua` | `macros` | `docs/notes/lua/macros.md` | macros_test.lua |
| `lib/scatter.lua` | `scatter` | `docs/notes/lua/scatter.md` | scatter_test.lua |
| `lib/morph.lua` | `morph` | `docs/notes/lua/morph.md` | morph_test.lua |
| `lib/gestures.lua` | `gestures` | `docs/notes/lua/gestures.md` | gestures_test.lua |
| `lib/input_level.lua` | `input_level` | `docs/notes/lua/input-level.md` | input_level_test.lua |
| `lib/random_sequences.lua` | `random_sequences` | `docs/notes/lua/random-sequences.md` | random_sequences_test.lua |
| `lib/envelopes.lua` | `envelopes` | `docs/notes/lua/envelopes.md` | envelopes_test.lua |
| `lib/matrix.lua` | `matrix` | `docs/notes/lua/matrix.md` | matrix_test.lua |
| `lib/notes.lua` | `notes` | `docs/notes/lua/notes.md` | notes_test.lua |
| `lib/arp.lua` | `arp` | `docs/notes/lua/arp.md` | arp_test.lua |
| `lib/mpe.lua` | `mpe` | `docs/notes/lua/mpe.md` | mpe_test.lua |
| `lib/expression.lua` | `expression` | `docs/notes/lua/expression.md` | expression_test.lua |
| `lib/slices.lua` | `slices` | `docs/notes/lua/slices.md` | slices_test.lua |
| `lib/io/<name>.lua`: `rig`, `ports` (before `lib/midi_in.lua`), `actions`, `keyed`, `targets`, `midi_out`, `crow`, `ii`, `jf`, `wsyn`, `wtape`, `er301`, `txo`, `nb`, `controllers`, `remote`, `osc`, `tape` | `io_<name>` | `docs/notes/lua/io/<name>.md` | io_<name>_test.lua |
| `lib/delay_sync.lua` | `delay_sync` | `docs/notes/lua/delay-sync.md` | delay_sync_test.lua |
| `lib/voice_presets.lua` | `voice_presets` | `docs/notes/lua/voice-presets.md` | voice_presets_test.lua |
| `lib/fx_hold.lua` | `fx_hold` | `docs/notes/lua/fx-hold.md` | fx_hold_test.lua |
| `lib/factory.lua` | `factory` | `docs/notes/lua/factory.md` | factory_test.lua |
| `lib/shimmer.lua` | `shimmer` | `docs/notes/lua/shimmer.md` | shimmer_test.lua |
| `lib/params_setup.lua` | `params_setup` | `docs/notes/lua/params.md` | params_setup_test.lua |
| `lib/ui/params.lua`, `lib/ui/header.lua`, `lib/ui/flash.lua`, `lib/ui/text.lua`, `lib/ui/keys.lua`, `lib/ui/menu_watch.lua` | `ui_params`, `ui_header`, `ui_flash`, `ui_text`, `ui_keys`, `ui_menu_watch` | `docs/notes/lua/ui-core.md` | ui_test.lua, ui_header_test.lua, ui_pages_test.lua |
| `lib/ui/field_list.lua` | `ui_field_list` | `docs/notes/lua/ui-core.md` | ui_field_list_test.lua |
| `lib/ui/voice_rows.lua`, `lib/ui/cursors.lua` | `ui_voice_rows`, `ui_cursors` | `docs/notes/lua/ui-core.md` | ui_cursors_test.lua |
| `lib/ui/alt.lua` | `ui_alt` | `docs/notes/lua/ui-core.md` | ui_alt_test.lua |
| `lib/ui/detent.lua` | `ui_detent` | `docs/notes/lua/ui-core.md` | ui_detent_test.lua |
| `lib/ui/zones.lua` | `ui_zones` | `docs/notes/lua/ui-core.md` (The zones editor) | ui_zones_test.lua |
| `lib/ui/slice_editor.lua` | `ui_slice_editor` | `docs/notes/lua/ui/slice-editor.md` | ui_slice_editor_test.lua |
| `lib/ui/scale_editor.lua` | `ui_scale_editor` | `docs/notes/lua/ui/scale-editor.md` | ui_scale_editor_test.lua |
| `lib/pages/<page>.lua`: `main`, `voice`, `seq`, `fx`, `lfo`, `mod`, `buffer`, `scenes`, `setup`, `io` | `pages_<page>` (`pages_main`, ...) | `docs/notes/lua/pages/<page>.md` (`docs/notes/lua/pages/main.md`, ...) | pages_<page>_test.lua (pages_main_test.lua, ...) |
| `lib/arc/core.lua` | `arc_core` | `docs/notes/lua/arc-core.md` | arc_core_test.lua |
| `lib/arc/main.lua`, `lib/arc/voice.lua`, `lib/arc/seq.lua`, `lib/arc/fx.lua`, `lib/arc/lfo.lua`, `lib/arc/mod.lua`, `lib/arc/buffer.lua`, `lib/arc/scenes.lua`, `lib/arc/io.lua` | `arc_main`, `arc_voice`, `arc_seq`, `arc_fx`, `arc_lfo`, `arc_mod`, `arc_buffer`, `arc_scenes`, `arc_io` | `docs/notes/lua/arc-pages.md` | arc_pages_test.lua |
| `lib/grid/core.lua`, `lib/grid/faders.lua` | `grid_core`, `grid_faders` | `docs/notes/lua/grid-core.md` | grid_core_test.lua |
| `lib/grid/pane.lua` | `grid_pane` | `docs/notes/lua/grid/pane.md` | grid_pane_test.lua |
| `lib/grid/pages/<page>.lua`: `patterns`, `faders`, `scenes`, `sources`, `positions`, `voices`, `fx` | `grid_pages_<page>` (`grid_pages_patterns`, ...) | `docs/notes/lua/grid/pages/<page>.md` | grid_pages_<page>_test.lua |
| `lib/grid/layout_<size>.lua`: `256`, `128h`, `128v`, `64` | `grid_layout_<size>` (`grid_layout_256`, ...) | `docs/notes/lua/grid/layout_<size>.md` (`docs/notes/lua/grid/layout_256.md`, ...) | grid_layout_<size>_test.lua (grid_layout_256_test.lua, ...) |
| `lib/sequencer.lua` | `sequencer` | `docs/notes/lua/sequencer.md` | sequencer_test.lua |
| `lib/Engine_Strata.sc`, `lib/engine/Strata*.sc` (an area, or a set of defs, a file) | | `docs/notes/engine/<area>.md`, one per check area | `test/engine_check.scd` (the engine check's runner) and `test/engine_check/<area>.scd` |
| the test harness (`test/norns_stubs.lua`, `test/sync_check.lua`, ...) | | `docs/notes/test-harness.md` | stubs_test.lua, docs_test.lua |
| the page renders (`test/render_pages.lua`, `test/render_pages.py`, run on demand) | | `docs/notes/lua/ui/layout-and-renders.md` | ui_layout_test.lua (the JSON dump) |

## Registering start and cleanup steps

- **Registering a start step**: `S.register_start(S.constants.START_ORDER.<step>, fn)` in the module that owns the resource, next to its cleanup step, and one line in `START_ORDER` (`lib/constants.lua`) at a free order at its place in the sequence (spaced by 10; two steps never share one). init runs the steps after the params are added, so a step can read them. `init` itself is never edited. Add the step's effects to `start_steps()` in `test/unit/structure_test.lua`.
- **Registering an invariant**: `S.register_invariant(name, fn)` in the module that owns the state, where it can see that state's private tables. `name` is a non-empty string no other invariant uses (a test failure names it); `fn()` returns nil while the invariant holds, else a string saying what is broken (which slot, key or field, and its value). `h.run_test` (`test/helpers.lua`) runs every registered invariant after each unit test that loaded the script, passed and reported no clock error, and fails the test that left one broken; nothing runs them on the device, so `fn` may be as thorough as the test needs. A test that breaks one on purpose calls `h.allow_broken_invariants(reason)`. Each task that fixes a state registers its invariant. The invariants registered today:

  | Name | Module | Holds |
  |------|--------|-------|
  | `scene transition` | `lib/scenes.lua` | `S.scene_transition_active == (S.SCENE_TRANSITION.next_step_due ~= nil)`, `S.SCENE_TRANSITION.target`, `.step` and `.released` (3.8, a table) are set exactly while the flag is true, and `S.scene_transition_clock` is nil whenever the flag is false |
  | `scene sequencer` | `lib/scenes.lua` | `S.scene_sequencer_recall_due` is true only while the sequencer is on, and `S.scene_sequencer_enabled == (S.scene_sequencer_clock ~= nil)` with that clock's coroutine not dead (#329) |
  | `pattern clock` | `lib/sequencer.lua` | `S.pattern_playing == (S.pattern_clock ~= nil)` |
  | `midi ports` | `lib/io/ports.lua` | a MIDI vport's `event` is the ports' dispatcher exactly while the port has a listener |
  | `midi notes` | `lib/midi_in.lua` | a note is held on a voice (`S.midi_state.held`) exactly while some channel's note on maps it there (`note_voice`), and every `started` entry is a voice index set to true |
  | `scan holds` | `lib/positions.lua` | a voice's scan is held exactly while it has a holder |
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
  | `zones editor` | `lib/ui/zones.lua` | the zones editor's learn waits exactly while its timeout clock is pending (`S.zones_learn_clock`, its coroutine alive) and the note tap is set, and only while the editor is open; the open editor's own owner is the modal one (or beneath SEQ's step editor), the closed editor's never (3.5) |
  | `scale editor` | `lib/ui/scale_editor.lua` | the open scale and tuning editor's own owner is the modal one (or beneath SEQ's step editor), the closed editor's never; its cursor is on a row and a class, and a pending tuning choice is one of its choices (3.8) |
  | `factory` | `lib/factory.lua` | a factory set's load clock (`S.factory_clock`) is a live coroutine while it is set; the open list's own owner is the modal one (or beneath SEQ's step editor), the closed list's never, and its cursor is on a set (3.8) |
  | `lfo clock` | `lib/lfos.lua` | the LFO clock (`S.lfo_clock`) runs from its start step to cleanup, and only then (3.4) |
  | `step editor` | `lib/pages/seq.lua` | the step editor is open exactly while its owner is the modal one (`S.lib.ui_modal.top()`) (3.4) |
  | `notes` | `lib/notes.lua` | the note pool is a whole number in 0..`NOTE_POOL.max`, the extra notes held never exceed it, and a stopped voice holds none (3.5) |
  | `arp` | `lib/arp.lua` | only a running arpeggiating voice holds notes in its list, at most `ARP.max_steps` - 1, each owner and key once and none also in a slot (3.8) |
  | `rig` | `lib/io/rig.lua` | every rig setting holds a value of its spec (`RIG.specs`), and no other key is held (3.6) |
  | `targets` | `lib/io/targets.lua` | every sounding target note names only registered targets (at least one), and no voice's id has two pending offs or an off for a note no longer sounding (3.6) |
  | `midi out` | `lib/io/midi_out.lua` | no port has two MPE voices nor a plain voice's channel inside an MPE voice's zone on it, and no note or channel count is negative (3.6) |
  | `remote` | `lib/io/remote.lua` | a remote grid or arc is attached (or, for the arc, followed unless a monome arc took over) exactly while its port's hello is held, on a claimed port; the midigrid is attached while held; the draw clock runs exactly while a remote device is attached (3.6) |
- **Registering a cleanup step**: `S.register_cleanup(S.constants.CLEANUP_ORDER.<step>, fn)` in the module that starts the resource, and one line in `CLEANUP_ORDER` (`lib/constants.lua`) at a free order at its place in the sequence (orders are spaced by 10; two steps never share one). `cleanup()` itself is never edited.

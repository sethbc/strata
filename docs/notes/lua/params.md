## Must not break

- Param ids are unique and prefixed (`strata_fx`, ...). norns has built-ins such as `reverb`, and the stub's system params make a collision fail.
- A group's size `n` equals the number of params that follow it. Groups cannot nest; the test stub errors on a group opened inside another, or one left short.
- The PARAMS menu order is the order of the `S.registry.params` records, and `init` runs each record's `add` in that order.
- A control param that reaches the engine stores its value and calls `send_param_to_engine` from its action, with a sender in `S.engine_senders` (`docs/notes/lua/engine-sync.md`).
- The actions of the voice params `randomize_voice` sets (the synthesis params, `buf_pos`, `buf_rate`, `buf_scan`, `grain_size`, `grain_pitch`) call `note_param_edit(param_id)`, so an edit ends the randomize undo (`docs/notes/lua/mutation.md`).
- `redraw_on_param_changes()` runs once, after the last param is added. A param added, or an action set with `params:set_action`, after it runs requests no redraws.
- The tempo handler is installed once (never chaining to itself) and given back only while the script's is still installed.
- The script never bangs its params, so Lua defaults are what the engine plays, and the filter and delay SynthDef defaults must equal the Lua param defaults (a test checks).
- The registries (`S.registry.voice_params`, `fx_params`, `param_filters`, `source_change`) are read at init, inside a params record's `add`, never at include time, so a module that registers can be included before or after this one.
- Six registries are closed once init begins to read them (`S.close_registries()`, run by the first params record, `performance`): `voice_params`, `scene_fields`, `lfo_destinations`, `fx_params`, `start` and `menu_close`. A register function raises after that, naming the registry (#384), so a late record is never silently ignored. Register at include time. A record with a field outside the documented set is refused too, naming the field (#385).
- A registered record's `add` (with its `add_first`, if any) adds exactly `count` params (an error names the record otherwise), and every key its `grain_keys`, `scene_defaults` and `voice_rows.rows` name is one of the params it added with `add_voice_extra`.
- Registered voice params are never on the 256 fader pages (`fader` is never true) and never touched by randomize or mutations: they live in `S.voices[i].extras`, which neither reads.
- The fx group's size is its 11 params plus every registered fx record's `count`, and the registered fx params follow tape drift.
- Every number param a params record adds (Strata's own, the LFO library's, never norns' system params) steps whole numbers through its own `delta` (#534): norns' PARAMS menu turns a param by `d / 20` while K3 is held, and norns' number param adds that unrounded, so without it `midi_device` raised and the mod sources, the sequence length and `record_beats` held fractions. `register_params` replaces each one's `delta` after its record's `add`, with one that rounds `d` away from 0 as norns' option param does; the same loop lists each one in `pset.number_params` for the PSET read hook (#554).
- A filtered synthesis param's own `delta` marks a turn (`turn_on_own_delta`, #318): norns' PARAMS menu turns E3 with the param object's `delta`, which never passes `delta_with_detent`.
- **PSETs keep their sound** (#314): every PSET saved holds the hidden number param `strata_pset_format` (`PSET_FORMAT`, 2), and `params.action_read`, set in the master record, runs `M.migrate_read_pset(filename, silent)` after every read. A file of a format below `PULSE_RES.pset_format` (no `strata_pset_format` line is format 1: saved before 3.3) gets the Pulse voice's `res` mirrored after the read when the file sets it (`PULSE_RES.mirror - res`, from the value the read set, so a PSET read again is never mirrored twice; keyed on a voice having a `res` param, not on voice 5); the hook then puts `strata_pset_format` back to `PSET_FORMAT`, so the next save writes today's format and is never mirrored. Every change goes through `params:set` with the read's `silent`. A later change of a param's meaning bumps `PSET_FORMAT` and adds its conversion to the hook, keyed on the file's format.
- **A PSET's number params load whole** (#554): after the read the hook rounds every number param a params record added (`pset.number_params`, collected by `register_params`: Strata's own, the registered voice params and the LFO library's, never norns' system params) to its step, a whole number (`util.round`). A non-silent read runs each param's action with the file's value first (norns sets each line through the param's own `set`), so a number param whose action reaches the engine makes its value whole in the action, through `pset.whole(param_id, x)`, before storing or sending it, and writes a fraction back silently (the param shows what is stored, and the hook has nothing left to round or resend): the crossmod sources (`setModSource` carries an `"i"`, which matron casts: 0.05 - 1 was voice 1) and every number param `add_voice_extra` builds (the custom intervals, sent with `setGrainParam`). A new number param whose action reaches the engine does the same. The others (`tempo`, `scene_sequence_length`, `midi_device`, `record_beats`, the LFO library's) reach no engine command with their value, and the hook rounds them.
- `S.performance` is never the constant `S.constants.STANDARD_PERFORMANCE` itself (a copy, or the table `lib/performance.lua` reads at init). A tier-dependent spec reads it when its param is added (`record_duration`'s maximum is `S.performance.buffer_seconds`).

## Owns

`lib/params_setup.lua` (`S.lib.params_setup`):
- the PARAMS menu: one `S.registry.params` record `{name, add}` per part (performance, master, mutations, scenes, fx, lfos, buffers, record, positions, midi, scale, voices), added with its local `register_params(name, add)`;
- the PSET read hook: the hidden `strata_pset_format` param (in the master record, after the `strata` separator), `params.action_read` and `S.lib.params_setup.migrate_read_pset(filename, silent)` (#314, #554), with the number params it rounds (`pset.number_params`, filled by `register_params` as each record's `add` runs);
- `add_voice_params`, `get_param_spec` (a copy of an entry of one table built once; a name with no entry is an error, #315, and every spec carries its display units, `s`, `Hz`, `/s` or `x`, and the params whose step is finer than 0.01 a three-decimal formatter: display only, never a value, #386, #387), `redraw_on_param_changes`;
- `S.fx_last_mix` (`{filter}`: `filter_mix`'s action stores the mix when it rises and `toggle_filter_mix` (FX's K3 on a filter row) stores the mix at the press, which K3 restores from 0; the delay and reverb keep their mix through their bypass params) and `fx_fader_changed` (the grid's FX faders);
- the tempo-follow handlers `follow_clock_tempo`, `install_tempo_change_handler`, `restore_tempo_change_handler`;
- the readers of the voice-param, fx-param, param-filter and source-change registries (below), and `S.lib.params_setup.add_voice_extra`;
- `S.performance` (the tier's values, standard until `lib/performance.lua` fills it at init);
- cleanup step 10: the tempo handler given back.

## Parameter system

Every adjustable value is a norns param:
1. Defined in its `S.registry.params` record with `params:add{}`, run from `init()`.
2. With an `action` function that updates the engine.
3. Read with `params:get("id")`, set with `params:set("id", value)`.
4. Grouped with `params:add_separator()`, or `params:add_group(id, name, n)` for a collapsible section (`strata_fx`, `strata_lfos`, `strata_buffers`, `strata_midi`; the LFO library adds `lfo_group_<n>` itself).

Menu order:
- `strata` (the hidden `strata_pset_format`, master density, tempo), `strata_mutations` (named `mutations`), `strata_scenes` (named `scenes`);
- the fx, lfo destinations, LFO 1-3 and buffers groups, then the `strata_record` and `strata_positions` groups, the `midi` group and the `scale` section;
- then each voice's synthesis (after any registered record's `add_first` params), granular and cross-modulation sections, and, when any voice-param record is registered, its `voice <i> extras` section.

## Registries

`lib/state.lua` holds the registries and their register functions; each checks its argument and refuses a duplicate name. This module reads four of them at init (scenes, the LFOs and VOICE read the rest: `docs/notes/lua/scenes.md`, `docs/notes/lua/lfos.md`, `docs/notes/lua/ui/field-list-and-cursors.md`).

**Voice params** (`S.register_voice_params(record)`, `S.registry.voice_params`). A module's per-voice params, as one record:

```lua
{ name = "freeze", count = 2, add = function(voice_idx) ... end,
  add_first = nil,             -- optional fn(voice_idx): params a PSET must read before the built-in ones
  grain_keys = { freeze = "freeze", freeze_mode = { name = "freezeMode", value = function(x) return x - 1 end } },
  sync = nil,                  -- optional fn(voice_idx): the voice sync's sends after grain_keys (setGrainParam only)
  scene_defaults = { freeze = 0, freeze_mode = 1 },   -- each the param's default
  discrete = { freeze = {0, 1}, freeze_mode = {1, 2} }, -- whole range; the other scene keys crossfade
  voice_rows = { section = "mix", rows = {"freeze", "freeze_mode"}, when = nil, before = nil },
  layout_states = nil,         -- optional {{name, setup = fn(context)}}
  normalize_scene = nil,       -- optional fn(extras): a loaded scene's values made consistent (migrate_scene)
  fader = false }
```

- `add_voice_params(i)` adds, after the cross-modulation params, a separator `voice <i> extras` and then each record's params, in registration order, through its `add(i)`. A record may also have `add_first = fn(voice_idx)`: its params come right after the `voice <i>: <name>` separator, ahead of the synthesis params, because norns reads a PSET line by line in param order and a filter on a built-in param may read them (variation's `quantize`, read by the `freq` filter: #125). Both add with `add_voice_extra`, and together they add exactly `count` params.
- `add` calls `S.lib.params_setup.add_voice_extra(voice_idx, record, key, param)` for each param: `param` is a `params:add` table without an `id` (its own `action`, if any, runs last). The param's id is `v<i>_<key>`. Its action:
  1. runs `S.registry.param_filters[key]` (a changed value is written back with `params:set(id, v, true)`);
  2. stores the value in `S.voices[i].extras[key]` (`add_voice_params` makes `extras` fresh at each init);
  3. calls `note_param_edit` and `send_param_to_engine`;
  4. runs the param's own action.
- A key in `grain_keys` gets an `S.engine_senders` entry: `setGrainParam` with the engine name (and `value(x)`, if given), only while the voice runs. `sync_voice_values_to_engine` sends every record's grain keys (by key name) and then its `sync` (`docs/notes/lua/engine-sync.md`). A start sends them before `engine.voiceOn`, with the other grain values, so a record's `sync` sends grain params only (`setGrainParam`): `voiceOn` resets the voice-level controls, and a test fails on anything else before it (#325). The variation record's (the intervals and `scaleNote`) and the bookmarks record's (`scrubRate` 0 and `scanHold` 0) do.

**Param filters** (`S.register_param_filter(key, fn)`, one per key). `fn(voice_idx, value, previous, turned) -> value` runs in the action of every `v<i>_<key>` voice param, the synthesis params (`param_order`) as well as registered ones, before the value is stored. `previous` is the value stored before; `turned` is true when the set is a turn of this param (`S.turning_param == id`: an encoder detent or arc tick through `delta_with_detent`, a mutation step, or the param's own `delta`, #318; `docs/notes/lua/ui/detents-and-fine.md`). A synthesis param whose key has a filter gets a `delta` that marks the turn (`turn_on_own_delta`), since norns' PARAMS menu turns E3 with the param object's `delta` and `params:delta` calls it too. 3.2's quantized `freq` uses it; the loop filters ignore `turned`.

**Source change hooks** (`S.register_source_change(fn)`). `fn(voice_idx, source)` runs in every `v<i>_source` action right after the source is stored and sent, before the voice's sync and the grid redraw (so the sync sends what the hooks set: a switch never sends the old freeze first), except while `S.scene_recall_in_progress`: a recall sets every value itself. 3.2's freeze clears itself through one.

**Fx params** (`S.register_fx_params({name, count, add})`). The fx group's size is 11 plus every record's `count`; init runs each `add()` after tape drift, in registration order, and checks the count.

**`S.performance`** (`{tier, buffer_seconds, max_grains, history_seconds}`). This module's constructor sets it to a copy of `S.constants.STANDARD_PERFORMANCE` (standard: 16 s buffers, 128 grains, 16 s of input history). lib/performance.lua fills it at init (`read_active`), from the `"performance"` params record, which runs before any param is added ([performance.md](performance.md)). Every tier-dependent spec reads it as its param is added: `record_duration` goes from 0.5 s to `S.performance.buffer_seconds`.

## Tempo

- The script's `tempo` param is initialized from `clock_tempo`, with its range, read with `param_range("clock_tempo")`: 1-300, so a scene captured at any clock tempo recalls it exactly.
- Its action sets `clock_tempo`. Grid tempo buttons adjust `tempo`. The pattern clock only syncs (`docs/notes/lua/sequencer.md`), so external clock sources still work.
- `install_tempo_change_handler()` (from `init`, in the master params record) installs the global `follow_clock_tempo` as `clock.tempo_change_handler`.
  - It keeps the previous handler in `previous_tempo_change_handler`, a local of the module (#394), and calls it after its own work.
  - Installing again is a no-op, so the handler never chains to itself.
- `restore_tempo_change_handler()` (from `cleanup()`, step 10) puts the previous handler back only while the script's is still installed, so a handler installed after it stays.
- A tempo set elsewhere (PARAMETERS > CLOCK, an external source) is thus mirrored into `tempo` silently, clamped to the param's range (an external source's tempo reaches the handler unclamped).
- So scenes and grid buttons always start from the playing tempo.

## Registering params

- **Registering a param group**: one `register_params(name, add)` call in `lib/params_setup.lua`, at its place in the PARAMS menu (the registration order is the menu order). Keep the group's body in the owning module where you can, and call it from `add` (as the "lfos" record calls `add_lfo_params`).
- **Registering per-voice params** (3.2's freeze, variation, loops, history, voice filter and sends): one `S.register_voice_params(record)` call in the owning module's constructor; nothing central lists the params. The record is `{name, count, add = fn(voice_idx), add_first = fn(voice_idx), grain_keys, sync, scene_defaults, discrete, voice_rows = {section, rows, when, before}, layout_states, normalize_scene = fn(extras), fader = false}`. `add` adds exactly `count` params, each with `S.lib.params_setup.add_voice_extra(voice_idx, record, key, param)` (id `v<i>_<key>`, value in `S.voices[i].extras[key]`); they follow the voice's cross-modulation params under a `voice <i> extras` separator, except the optional `add_first`'s, which come ahead of the voice's synthesis params: norns reads a PSET in param order, so a param that a built-in param's filter reads must load first (variation's `quantize` before `freq`, #125). Its grain keys reach the engine through their senders and the voice sync, its scene keys are captured, crossfaded (or, `discrete`, set at the end after the source), validated and migrated (`normalize_scene`, if any, makes a loaded scene's values consistent), its rows join the VOICE page (a binary param is a `"binary"` row) and its `layout_states` VOICE's. Registered params never reach randomize, mutations or the 256 fader pages.
- **Registering the other shared spots**: `S.register_scene_field({id, default, discrete})` (a global scene field, read after `SCENE_GLOBAL_PARAMS`), `S.register_source_change(fn(voice_idx, source))` (runs in each `v<i>_source` action once the source is stored and sent, before the voice's sync, never during a scene recall), `S.register_param_filter(key, fn(voice_idx, value, previous, turned) -> value)` (one per key; every `v<i>_<key>` action applies it before storing), `S.register_lfo_destination(label, suffix)` (`v<i> <label>`, after every built-in destination, by registration then voice, so stored indices keep their meaning) and `S.register_fx_params({name, count, add})` (the fx group grows by `count`; its params follow the 11). Each is one line in the owning module.

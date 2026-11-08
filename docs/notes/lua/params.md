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
- A registered record's `add` (with its `add_first`, if any) adds exactly `count` params (an error names the record otherwise), and every key its `grain_keys`, `scene_defaults` and `voice_rows.rows` name is one of the params it added with `add_voice_extra`.
- Registered voice params are never on the 256 fader pages (`fader` is never true) and never touched by randomize or mutations: they live in `S.voices[i].extras`, which neither reads.
- The fx group's size is its 11 params plus every registered fx record's `count`, and the registered fx params follow tape drift.
- `S.performance` is never the constant `S.constants.STANDARD_PERFORMANCE` itself (a copy, or the table `lib/performance.lua` reads at init). A tier-dependent spec reads it when its param is added (`record_duration`'s maximum is `S.performance.buffer_seconds`).

## Owns

`lib/params_setup.lua` (`S.lib.params_setup`):
- the PARAMS menu: one `S.registry.params` record `{name, add}` per part (master, mutations, scenes, fx, lfos, buffers, midi, voices), added with its local `register_params(name, add)`;
- `add_voice_params`, `get_param_spec`, `redraw_on_param_changes`;
- `S.fx_last_mix` (`{filter}`: `filter_mix`'s action stores its last non-zero value, which the FX page's K3 restores; the delay and reverb keep their mix through their bypass params) and `fx_fader_changed` (the grid's FX faders);
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
- `strata` (master density, tempo), `strata_mutations`, `strata_scenes`;
- the fx, lfo destinations, LFO 1-3, buffers and midi groups;
- then each voice's synthesis (after any registered record's `add_first` params), granular and cross-modulation sections, and, when any voice-param record is registered, its `voice <i> extras` section.

## Registries

`lib/state.lua` holds the registries and their register functions; each checks its argument and refuses a duplicate name. This module reads four of them at init (scenes, the LFOs and VOICE read the rest: `docs/notes/lua/scenes.md`, `docs/notes/lua/lfos.md`, `docs/notes/lua/ui-core.md`).

**Voice params** (`S.register_voice_params(record)`, `S.registry.voice_params`). A module's per-voice params, as one record:

```lua
{ name = "freeze", count = 2, add = function(voice_idx) ... end,
  add_first = nil,             -- optional fn(voice_idx): params a PSET must read before the built-in ones
  grain_keys = { freeze = "freeze", freeze_mode = { name = "freezeMode", value = function(x) return x - 1 end } },
  sync = nil,                  -- optional fn(voice_idx): the voice sync's sends after grain_keys
  scene_defaults = { freeze = 0, freeze_mode = 1 },   -- each the param's default
  discrete = { freeze = {0, 1}, freeze_mode = {1, 2} }, -- whole range; the other scene keys crossfade
  voice_rows = { section = "mix", rows = {"freeze", "freeze_mode"}, when = nil, before = nil },
  layout_states = nil,         -- optional {{name, setup = fn(context)}}
  fader = false }
```

- `add_voice_params(i)` adds, after the cross-modulation params, a separator `voice <i> extras` and then each record's params, in registration order, through its `add(i)`. A record may also have `add_first = fn(voice_idx)`: its params come right after the `voice <i>: <name>` separator, ahead of the synthesis params, because norns reads a PSET line by line in param order and a filter on a built-in param may read them (variation's `quantize`, read by the `freq` filter: #125). Both add with `add_voice_extra`, and together they add exactly `count` params.
- `add` calls `S.lib.params_setup.add_voice_extra(voice_idx, record, key, param)` for each param: `param` is a `params:add` table without an `id` (its own `action`, if any, runs last). The param's id is `v<i>_<key>`. Its action:
  1. runs `S.registry.param_filters[key]` (a changed value is written back with `params:set(id, v, true)`);
  2. stores the value in `S.voices[i].extras[key]` (`add_voice_params` makes `extras` fresh at each init);
  3. calls `note_param_edit` and `send_param_to_engine`;
  4. runs the param's own action.
- A key in `grain_keys` gets an `S.engine_senders` entry: `setGrainParam` with the engine name (and `value(x)`, if given), only while the voice runs. `sync_voice_values_to_engine` sends every record's grain keys (by key name) and then its `sync` (`docs/notes/lua/engine-sync.md`).

**Param filters** (`S.register_param_filter(key, fn)`, one per key). `fn(voice_idx, value, previous) -> value` runs in the action of every `v<i>_<key>` voice param, the synthesis params (`param_order`) as well as registered ones, before the value is stored. `previous` is the value stored before. 3.2's quantized `freq` uses it.

**Source change hooks** (`S.register_source_change(fn)`). `fn(voice_idx, source)` runs in every `v<i>_source` action right after the source is stored and sent, before the voice's sync and the grid redraw (so the sync sends what the hooks set: a switch never sends the old freeze first), except while `S.scene_recall_in_progress`: a recall sets every value itself. 3.2's freeze clears itself through one.

**Fx params** (`S.register_fx_params({name, count, add})`). The fx group's size is 11 plus every record's `count`; init runs each `add()` after tape drift, in registration order, and checks the count.

**`S.performance`** (`{tier, buffer_seconds, max_grains, history_seconds}`). This module's constructor sets it to a copy of `S.constants.STANDARD_PERFORMANCE` (standard: 16 s buffers, 128 grains, 16 s of input history). lib/performance.lua fills it at init (`read_active`), from the `"performance"` params record, which runs before any param is added ([performance.md](performance.md)). Every tier-dependent spec reads it as its param is added: `record_duration` goes from 0.5 s to `S.performance.buffer_seconds`.

## Tempo

- The script's `tempo` param is initialized from `clock_tempo`, with its range, read with `param_range("clock_tempo")`: 1-300, so a scene captured at any clock tempo recalls it exactly.
- Its action sets `clock_tempo`. Grid tempo buttons adjust `tempo`. The pattern clock only syncs (`docs/notes/lua/sequencer.md`), so external clock sources still work.
- `install_tempo_change_handler()` (from `init`, in the master params record) installs the global `follow_clock_tempo` as `clock.tempo_change_handler`.
  - It keeps the previous handler in `previous_tempo_change_handler` and calls it after its own work.
  - Installing again is a no-op, so the handler never chains to itself.
- `restore_tempo_change_handler()` (from `cleanup()`, step 10) puts the previous handler back only while the script's is still installed, so a handler installed after it stays.
- A tempo set elsewhere (PARAMETERS > CLOCK, an external source) is thus mirrored into `tempo` silently, clamped to the param's range (an external source's tempo reaches the handler unclamped).
- So scenes and grid buttons always start from the playing tempo.

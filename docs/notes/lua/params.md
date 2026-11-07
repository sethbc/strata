## Must not break

- Param ids are unique and prefixed (`strata_fx`, ...). norns has built-ins such as `reverb`, and the stub's system params make a collision fail.
- A group's size `n` equals the number of params that follow it. Groups cannot nest; the test stub errors on a group opened inside another, or one left short.
- The PARAMS menu order is the order of the `S.registry.params` records, and `init` runs each record's `add` in that order.
- A control param that reaches the engine stores its value and calls `send_param_to_engine` from its action, with a sender in `S.engine_senders` (`docs/notes/lua/engine-sync.md`).
- `redraw_on_param_changes()` runs once, after the last param is added. A param added, or an action set with `params:set_action`, after it runs requests no redraws.
- The tempo handler is installed once (never chaining to itself) and given back only while the script's is still installed.
- The script never bangs its params, so Lua defaults are what the engine plays, and the filter and delay SynthDef defaults must equal the Lua param defaults (a test checks).

## Owns

`lib/params_setup.lua` (`S.lib.params_setup`):
- the PARAMS menu: one `S.registry.params` record `{name, add}` per part (master, mutations, scenes, fx, lfos, buffers, midi, voices), added with its local `register_params(name, add)`;
- `add_voice_params`, `get_param_spec`, `redraw_on_param_changes`;
- `S.fx_filter_last_mix` (read by the FX page's K3) and `fx_fader_changed` (the grid's FX faders);
- the tempo-follow handlers `follow_clock_tempo`, `install_tempo_change_handler`, `restore_tempo_change_handler`;
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
- then each voice's synthesis, granular and cross-modulation sections.

## Tempo

- The script's `tempo` param is initialized from `clock_tempo`, with its range, read with `param_range("clock_tempo")`: 1-300, so a scene captured at any clock tempo recalls it exactly.
- Its action sets `clock_tempo`. Grid tempo buttons adjust `tempo`. The pattern clock only syncs (`docs/notes/lua/grid-and-sequencer.md`), so external clock sources still work.
- `install_tempo_change_handler()` (from `init`, in the master params record) installs the global `follow_clock_tempo` as `clock.tempo_change_handler`.
  - It keeps the previous handler in `previous_tempo_change_handler` and calls it after its own work.
  - Installing again is a no-op, so the handler never chains to itself.
- `restore_tempo_change_handler()` (from `cleanup()`, step 10) puts the previous handler back only while the script's is still installed, so a handler installed after it stays.
- A tempo set elsewhere (PARAMETERS > CLOCK, an external source) is thus mirrored into `tempo` silently, clamped to the param's range (an external source's tempo reaches the handler unclamped).
- So scenes and grid buttons always start from the playing tempo.

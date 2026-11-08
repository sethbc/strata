## Must not break

- LFOs modulate around the stored value and never `params:set` their destination. `apply_lfo` sends `with_lfo_offsets(id, params:get(id))` through `send_engine_value`.
- Strata restores a destination explicitly (the library stops calling the action when an LFO is off or its depth is 0): on a destination change, state off and depth 0. Restores are always sent, never deduped.
- The library owns every `lfo_*` param id and sizes its own group. Never pass a separator to `add_params` or wrap its params in a Strata group (norns groups cannot nest).
- Every resolved destination is a control param, and every destination label fits the LFO page's right column (49 px).
- `S.lfo_last_dest`/`S.lfo_scaled` are declared in `lib/engine_sync.lua`, included before `lib/lfos.lua`, because param actions read them.
- The offset survives on/off (#103): the library's `lfo_<n>` action re-bangs `lfo_baseline_<n>`, whose `change_offset` sets `lfo_offset_<n>` to 0, so the `lfo_<n>` wrapper's `before` saves the offset and its `after` sets it back when it changed (`params:set`, so the library's offset follows; the number param clamps it to the baseline's range). A baseline change itself still zeroes the offset, as the library intends. This covers every way the state is set: the LFO page, PARAMS, scene recalls, cleanup. Scenes rely on it: they set the recalled `lfo_offset_<n>` before `lfo_<n>`, so without the wrapper the state switch at a transition's end would zero it.
- Destination indices are stored in PSETs and scenes (`strata_lfo<n>_dest`), so the 68 built-in destinations never move. Registered destinations (`S.registry.lfo_destinations`) go after all of them, by registration and then voice 1-7, so a later registration only appends. The list is built at init (`add_lfo_params`), never at include time.
- `LFO_PPQN` (48) and the send dedupe bound the message rate. The ceiling is the library's 10 Hz: anything faster belongs in the engine.

## Owns

`lib/lfos.lua` (`S.lib.lfos`):
- `S.lfos`, `S.selected_lfo`, `S.lfo_last_raw`, `S.LFO_DESTINATIONS`;
- `lfo_destination_id`, `restore_lfo_destination`, `apply_lfo`, the phase estimate (`lfo_phase_estimate`), `wrap_param_action`, `add_lfo_params`;
- `LFO_DEFAULT_PERIOD` as `S.lib.lfos.LFO_DEFAULT_PERIOD`, for the scene defaults, and `LFO_OFFSET_RANGE` (`{-100, 100}`, the library's offset range for every baseline) as `S.lib.lfos.LFO_OFFSET_RANGE`, for scene validation;
- cleanup step 120: the LFOs stopped, their destinations restored.

Elsewhere:
- The LFO page is `lib/pages/lfo.lua` (`docs/notes/lua/pages/lfo.md`), the arc's LFO rings `lib/arc/lfo.lua` (`docs/notes/lua/arc-pages.md`).
- `forget_arc_lfo_period_ticks` is in `lib/arc/core.lua`.
- The grid has no LFO controls.

Three LFOs (`NUM_LFOS`), built on norns' `lua/lib/lfo.lua` (`local LFO = require "lfo"`), stored in `S.lfos[n]`. They are not the per-voice drift (`drift_update`, `docs/notes/lua/mutation.md`).

## Construction

`add_lfo_params()`, called from `init` after the FX group (the "lfos" `S.registry.params` record):
- `LFO:add{shape = "sine", min = -1, max = 1, depth = LFO_DEFAULT_DEPTH (0.25, since 3.1), mode = "free", period = LFO_DEFAULT_PERIOD (4), baseline = "center", action = function(scaled, raw) apply_lfo(n, scaled, raw) end}`;
- then `S.lfos[n]:add_params(tostring(n), nil, "LFO " .. n)`;
- then `lfo_depth_<n>`'s `default` and `value` are rounded to a whole 25: the library computes depth × 100, a float in Lua 5.3 that its formatter would show as `25.0%`. The scene migration default for `lfo_depth_<n>` stays 0 (`lib/scenes.lua`), so files without LFO depths keep silent LFOs.

The library owns the params:
- `lfo_<n>` (state, option off/on), `lfo_shape_<n>`, `lfo_depth_<n>` (a **number 0-100, percent**), `lfo_phase_<n>`, `lfo_offset_<n>`, `lfo_mode_<n>` (clocked/free), `lfo_clocked_<n>` (rate option), `lfo_free_<n>` (0.1-300 s), `lfo_reset_<n>`, ...;
- `lfo_*` ids are reserved for it.
- It starts an LFO from its state param's action. That is off by default, so `init` starts nothing.
- It hides the other params while the LFO is off.

## PARAMS layout

- The library adds its own group per LFO: `lfo_group_<n>`, "LFO n", 15 params.
- So Strata's destinations get their own group first: `strata_lfos` ("lfo destinations", `NUM_LFOS` params `strata_lfo<n>_dest`).

## Destinations

`S.LFO_DESTINATIONS` is the ordered `strata_lfo<n>_dest` option list of `{label, resolve}`:
- `none`, `density`, `drift`, `filt freq`, `filt res`, `filt mix`, `dly time`, `dly fdbk`, `dly mix`, `rev mix`, `rev size`, `rev damp`;
- then per voice (`VOICE_LFO_DESTINATIONS`): `v<i> main` (`main_param_id(i)`, resolved on every step so it follows the voice's source), `v<i> size`, `dens`, `pitch`, `spread`, `pos`, `rate`, `scan`.
- 12 + 8 per voice = 68 entries (`BUILT_IN_LFO_DESTINATIONS`).
- then, built at init by `add_lfo_params` (`lfo_destination_labels`), the registered ones: for each `S.register_lfo_destination(label, suffix)` in registration order, `v1 <label>` ... `v7 <label>`, modulating `v<i>_<suffix>` (a control param). A label that repeats a built-in or earlier label is an error. Keep `v7 <label>` within the LFO page's right column (3.2's: `hist`, `vfilt`, `dsend`, `rsend`). 3.2's registration order is the include order: the history module before the voice-mix module.
- `lfo_destination_id(n)` returns the resolved id or nil.

## Modulating around the stored value

With min -1, max 1 and a center baseline, the library hands the action `scaled` in -depth..depth:
- depth = percent / 100;
- the library's `lfo_offset_<n>` param adds `(max - min) × offset / 100` to it (kept across on/off, see Must not break).

Other library settings the user can change in PARAMS, `lfo_min_<n>`, `lfo_max_<n>` and `lfo_baseline_<n>` (`docs/user/params.md` tells users to keep the defaults):
- a `min` baseline gives `scaled` in -1..-1 + 2 × depth (below the stored value, up to 50 % depth);
- a `max` baseline gives 1 - depth..1 (the library's `scaled_min = max * (1 - depth)`: above it, half as wide);
- other `lfo_min_<n>`/`lfo_max_<n>` values scale the swing.

`apply_lfo(n, scaled, raw)`:
- stores `S.lfo_last_raw[n] = raw` and resolves the destination;
- records `S.lfo_last_dest[n]` and `S.lfo_scaled[n] = scaled`;
- sends `with_lfo_offsets(id, params:get(id))` through `send_engine_value`: clamp(stored + (sum of `S.lfo_scaled` of every LFO whose `S.lfo_last_dest` is id) × 0.5 × (maxval - minval)) over `param_range(id)`.
- LFOs on one destination add up. `params:set` is never called for a destination.

## Send dedupe

- `apply_lfo` skips the send when the new value differs from `S.engine_param_values[id]` (the last value sent to that destination by any path) by less than `LFO_SEND_THRESHOLD` (1/1000) of the destination's range.
- So a slow LFO sends only when it has moved.
- Restores and param-action sends are never skipped.

## Restores

`restore_lfo_destination(n)`:
- clears `S.lfo_last_dest[n]`/`S.lfo_scaled[n]`;
- `send_param_to_engine(old id, params:get(old id))`: the stored value plus any other LFO's offset on it. Always sent.

Called from:
- the `strata_lfo<n>_dest` action (destination changed);
- wrappers installed with `wrap_param_action(id, before, after)` around the library's `lfo_<n>` action (state off; its `before`/`after` also keep the offset) and `lfo_depth_<n>` action (depth 0).
- When a `main` destination re-resolves to a different param (the voice's source changed), `apply_lfo` restores the old id once, then modulates the new one.

## Dot phase estimate

The library's running phase is internal (`get("phase")` is the phase offset setting), so Strata estimates it:
- `lfo_phase_estimate(n)` = (`lfo_phase_base[n]` + (`util.time()` - `lfo_phase_time[n]`) / period in seconds + phase offset) % 1.
- Clocked periods in seconds are beats × `clock.get_beat_sec()`.
- `note_lfo_reset(n)` sets the base to `LFO_RESET_PHASES[reset_target]` (floor 0.75, ceiling 0.25, mid: falling 0.5, mid: rising 0, as `LFO:reset_phase`) when the state turns on or `lfo_reset_<n>` fires.
- Wrappers on `lfo_mode_<n>`, `lfo_clocked_<n>` and `lfo_free_<n>` call `rebase_lfo_phase(n)` before the library changes the period, which keeps the phase like the library's `change_period`.
- Tempo changes are not tracked: the estimate drifts until the next reset.

## Rate ceiling and message rate

- The library's ceiling: free periods down to 0.1 s (10 Hz), clocked rates down to "1/16" (a period of 1/4 beat; clocked periods are the rate × 4 beats).
- The library calls the action on every step while depth > 0.
- So each LFO is set to `LFO_PPQN` (48) steps per beat with `S.lfos[n]:set("ppqn", LFO_PPQN)` right after `LFO:add`.
  - The library's default is 96.
  - `set("ppqn")` before `start` is what the sprocket is built from, and its phase counter advances 1/ppqn per step, so the phase maths are unchanged.
- Result: at most 96 sends/s per LFO at 120 BPM, 240 at 300 BPM (one engine message, or one per running voice for master density), fewer with the dedupe.

## Scenes

- `SCENE_GLOBAL_PARAMS` holds per LFO `lfo_shape_<n>`, `lfo_mode_<n>`, `lfo_clocked_<n>` (default 13, the library's index for a period of 4), `lfo_free_<n>`, `lfo_depth_<n>` and `lfo_offset_<n>` (continuous), `strata_lfo<n>_dest`, then `lfo_<n>` last, so an LFO starts with its settings in place.
- The offset (#103, format 3) crossfades in whole percents like the depth. Its entry's `range` (`LFO_OFFSET_RANGE`) is what `validate_scene` accepts; a recalled offset outside the current baseline's range (a scene saved with another baseline) is clamped by the param. Its state switch at the end keeps it (see Must not break).
- Scenes without them migrate to the defaults (LFOs off, offsets 0).

## Cleanup

Per LFO (step 120): `S.lfos[n]:stop()`, `params:set("lfo_<n>", 1)` and `restore_lfo_destination(n)`.

## Must not break

- LFOs modulate around the stored value and never `params:set` their destination. `apply_lfo` sends `with_lfo_offsets(id, params:get(id))` through `send_engine_value`.
- Strata restores a destination explicitly (the library stops calling the action when an LFO is off or its depth is 0): on a destination change, state off and depth 0. Restores are always sent, never deduped.
- The library owns every `lfo_*` param id and sizes its own group. Never pass a separator to `add_params` or wrap its params in a Strata group (norns groups cannot nest).
- Every resolved destination is a control param, and every destination label fits the LFO page's right column (49 px).
- `S.lfo_last_dest`/`S.lfo_scaled` are declared in `lib/engine_sync.lua`, included before `lib/lfos.lua`, because param actions read them.
- The offset survives on/off (#103): the library's `lfo_<n>` action re-bangs `lfo_baseline_<n>`, whose `change_offset` sets `lfo_offset_<n>` to 0, so the `lfo_<n>` wrapper's `before` saves the offset and its `after` sets it back when it changed (`params:set`, so the library's offset follows; the number param clamps it to the baseline's range). A baseline change itself still zeroes the offset, as the library intends. This covers every way the state is set: the LFO page, PARAMS, scene recalls, cleanup. So anything that turns an LFO on or off (a page, a scene, cleanup) uses a plain `params:set("lfo_<n>", ...)`. Scenes rely on it: they set the recalled `lfo_offset_<n>` before `lfo_<n>`, so without the wrapper the state switch at a transition's end would zero it.
- Destination indices are stored in PSETs and scenes (`strata_lfo<n>_dest`), so the 68 built-in destinations never move. Registered destinations (`S.registry.lfo_destinations`) go after all of them, in registration order: a per-voice record by voice 1-7, a global one (`{label, param_id, global = true}`, 3.4's 0a) as one destination, so a later registration only appends. The list is built at init (`add_lfo_params`), never at include time.
- The LFOs' scene fields are `S.lib.lfos.SCENE_FIELDS`, which `lib/scenes.lua` appends to `S.SCENE_GLOBAL_PARAMS` after its built-in globals, the records themselves: a change to an LFO's scene fields is made here, never in `lib/scenes.lua`. Their ids, order and defaults are what scenes.data holds, so a change needs a scene migration. `S.lib.lfos.transition_stops(n, scene_data)` is what a fade asks of an LFO (#408).
- A state action that runs (a change of state, or a bang of `lfo_<n>`) resets the library's phase: the `lfo_<n>` action ends with `lfo_bang`, which bangs `lfo_reset_<n>` and calls `reset_phase()` (#251). A PSET load or scene recall that leaves the state as it is runs no action (norns' option param bangs only on a change), so it resets nothing: running LFOs keep their phases (#416). The dot follows through the `lfo_reset_<n>` wrapper's `sync_lfo_phase`; never make the dot stay put on a repeated on, it would disagree with the LFO.
- The dot takes the library's own phase (`sync_lfo_phase`, from `phase_counter`) after every library action that moves it, never a phase of Strata's: after a reset (each target where `LFO:reset_phase` puts it, mid: rising included) and after a mode change, whose action sets the mode before the period, so `change_period` reads the old period in the new mode's unit and the phase jumps by the beat length (#409). A rate change (`lfo_clocked_<n>`, `lfo_free_<n>`) keeps the library's phase, so the dot rebases before it.
- The LFO page's randomize (#557) sets `lfo_shape_<n>`, `lfo_free_<n>` and `lfo_clocked_<n>`, so their wrappers call `note_param_edit` after the library's action (an edit of a held param ends the randomize undo). A new randomized LFO param needs the same chain.
- `LFO_PPQN` (48) and the send dedupe bound the message rate. The ceiling is the library's 10 Hz: anything faster belongs in the engine.
- The dedupe measures along the destination's warp (`destination_position`: an exponential range in octaves, #406) and without the step rounding `unmap` does first, so a linear destination's threshold is exactly 1/1000 of its range and a stepped one (a 0.01-step mix) still moves by 1/1000. It unmaps with a step-0 copy of the spec, never the param's own spec, which it never changes.
- `apply_lfo` never raises (#517): norns' lattice runs every LFO's step, so one error would stop all three for the session. It runs the step (`step_lfo`) through the frame's `S.lib.ui_frame.contained_call`, which prints `strata: LFO <n> step failed:` with the traceback, once per distinct message per LFO (a good step forgets it).
- `lfo_min_<n>` never rises above `lfo_max_<n>` (#528): the library's random shape calls `math.random(min × 100, max × 100)`, which raises on norns' Lua 5.3 inside the lattice when the interval is empty. Each bound's wrapper moves the other with it before the library's action (min set above max raises max to it; max set below min lowers min), never itself, so a pair loaded one value at a time (a PSET, min before max) lands as stored.

## Owns

`lib/lfos.lua` (`S.lib.lfos`):
- `S.lfos`, `S.selected_lfo`, `S.lfo_last_raw`, `S.LFO_DESTINATIONS`;
- `lfo_destination_id`, `restore_lfo_destination`, `apply_lfo` (its step `step_lfo`, `destination_position` with its `unstepped_specs` and the per-LFO `step_errors` are local), the phase estimate (`lfo_phase_estimate`; `library_phase`, `sync_lfo_phase` and `rebase_lfo_phase` are local), `wrap_param_action`, `add_lfo_params`;
- `LFO_DEFAULT_PERIOD` as `S.lib.lfos.LFO_DEFAULT_PERIOD` and `LFO_OFFSET_RANGE` (`{-100, 100}`, the library's offset range for every baseline) as `S.lib.lfos.LFO_OFFSET_RANGE`, the free period's scene default and the offset's scene range;
- the LFOs' scene fields, `S.lib.lfos.SCENE_FIELDS`, and `S.lib.lfos.transition_stops(n, scene_data)` (Scenes, below);
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
- then, built at init by `add_lfo_params` (`lfo_destination_labels`), the registered ones, in registration order: for each `S.register_lfo_destination(label, suffix)`, `v1 <label>` ... `v7 <label>`, modulating `v<i>_<suffix>` (a control param); for each global record (`{label, param_id, global = true}`, `S.register_lfo_global_destination`, 3.4's 0a), one destination `<label>` modulating `param_id`. A label that repeats a built-in or earlier label is an error, naming the register function its record came from (`register_lfo_destination` or `register_lfo_global_destination`). Keep `v7 <label>` within the LFO page's right column (3.2's: `hist`, `vfilt`, `dsend`, `rsend`). 3.2's registration order is the include order: the history module before the voice-mix module.
- So with 3.2's four the list has 96 entries: 69-75 `v1 hist` ... `v7 hist`, 76-82 `vfilt`, 83-89 `dsend`, 90-96 `rsend`. The LFO page's ALT+E3 makes each registration's seven one group, from its `v1 <label>` (#511, `docs/notes/lua/pages/lfo.md`).
- `lfo_destination_id(n)` returns the resolved id or nil.

## Modulating around the stored value

With min -1, max 1 and a center baseline, the library hands the action `scaled` in -depth..depth:
- depth = percent / 100;
- the library's `lfo_offset_<n>` param adds `(max - min) × offset / 100` to it (kept across on/off, see Must not break).

Other library settings the user can change in PARAMS, `lfo_min_<n>`, `lfo_max_<n>` and `lfo_baseline_<n>` (`docs/user/params.md` tells users to keep the defaults):
- a `min` baseline gives `scaled` in -1..-1 + 2 × depth (below the stored value, up to 50 % depth);
- a `max` baseline gives 1 - depth..1 (the library's `scaled_min = max * (1 - depth)`: above it, half as wide);
- other `lfo_min_<n>`/`lfo_max_<n>` values scale the swing; min stays at or below max (see Must not break).

`apply_lfo(n, scaled, raw)` runs `step_lfo(n, scaled, raw)` under `xpcall` (see Must not break), which:
- stores `S.lfo_last_raw[n] = raw` and resolves the destination;
- records `S.lfo_last_dest[n]` and `S.lfo_scaled[n] = scaled`;
- sends `with_lfo_offsets(id, params:get(id))` through `send_engine_value`: clamp(stored + (sum of `S.lfo_scaled` of every LFO whose `S.lfo_last_dest` is id) × 0.5 × (maxval - minval)) over `param_range(id)`.
- LFOs on one destination add up. `params:set` is never called for a destination.

## Send dedupe

- `apply_lfo` skips the send when the new value's position along the destination's range differs from that of `S.engine_param_values[id]` (the last value sent to that destination by any path) by less than `LFO_SEND_THRESHOLD` (1/1000).
- The position is `destination_position(id, value)`: `unmap` on a copy of the destination's controlspec with step 0 (`unmap` rounds to the step first), made with `spec:copy()` the first time a spec is used and kept in `unstepped_specs`, keyed weakly by the spec (a param given a new spec gets a new copy; a destination's range never changes in place). A linear range's position moves by the value's change over the range, so 1/1000 of the range, as in 3.0; an exponential one's in octaves, so 1/1000 of the range's octaves: 7.97 cents on a voice's freq (20-2000 Hz), where a linear threshold was 1.98 Hz, about 68 cents at 50 Hz (#406).
- So a slow LFO sends only when it has moved, and moves evenly in octaves on a frequency.
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

The library's running phase moves on its lattice's steps (`get("phase")` is the phase offset setting), so Strata estimates it between the moments it takes it from the library:
- `lfo_phase_estimate(n)` = (`lfo_phase_base[n]` + (`util.time()` - `lfo_phase_time[n]`) / period in seconds + phase offset) % 1.
- Clocked periods in seconds are beats × `clock.get_beat_sec()`.
- `library_phase(n)` is the library's phase before the offset, as its `process_lfo` computes it from `phase_counter` (in beats, 1/ppqn a step): `phase_counter / period` clocked, `phase_counter × clock.get_beat_sec() / period` free, % 1.
- `sync_lfo_phase(n)` sets the base to `library_phase(n)` at `util.time()`: at init, after `lfo_reset_<n>` (the state turning on bangs it too) and after the library's `lfo_mode_<n>` action (#409). `LFO:reset_phase` puts floor at 0.75, ceiling at 0.25 and mid: falling at 0.5 of the cycle; mid: rising sets `phase_counter` to beat length / period itself, so a free LFO restarts at (beat length / period)² (1/64 for 4 s at 120 BPM) and a clocked one at 0.
- Wrappers on `lfo_clocked_<n>` and `lfo_free_<n>` call `rebase_lfo_phase(n)` (base = the estimate now) before the library changes the period, which keeps the phase like the library's `change_period` (within 1/ppqn of a step).
- At 120 BPM, a free 4 s LFO 0.5 s after a floor reset is at 0.875; switched to clocked (rate 4, 16 beats) the library is at 0.75390625, and back to free 1 s later at 0.9375: the dot is too.
- Tempo changes are not tracked: the estimate drifts until the next reset or mode change.
- The stub has no lattice: its `phase_counter` moves only through `reset_phase` and `set("period")`, so a test that changes the mode of a running LFO adds the lattice's beats itself (`run_lfo` in `test/unit/lfos_test.lua`).

## Rate ceiling and message rate

- The library's ceiling: free periods down to 0.1 s (10 Hz), clocked rates down to "1/16" (a period of 1/4 beat; clocked periods are the rate × 4 beats).
- The library calls the action on every step while depth > 0.
- So each LFO is set to `LFO_PPQN` (48) steps per beat with `S.lfos[n]:set("ppqn", LFO_PPQN)` right after `LFO:add`.
  - The library's default is 96.
  - `set("ppqn")` before `start` is what the sprocket is built from, and its phase counter advances 1/ppqn per step, so the phase maths are unchanged.
- Result: at most 96 sends/s per LFO at 120 BPM, 240 at 300 BPM (one engine message, or one per running voice for master density), fewer with the dedupe.

## Scenes

- `S.lib.lfos.SCENE_FIELDS`, which `lib/scenes.lua` appends to `SCENE_GLOBAL_PARAMS` after its built-in globals, holds per LFO `lfo_shape_<n>`, `lfo_mode_<n>`, `lfo_clocked_<n>` (default 13, the library's index for a period of 4), `lfo_free_<n>`, `lfo_depth_<n>` and `lfo_offset_<n>` (continuous, `lfo = n`; the depth's `stop_target` 0), `strata_lfo<n>_dest`, then `lfo_<n>` last, so an LFO starts with its settings in place. Each record is `{id, continuous, default, lfo?, stop_target?, range?}`.
- `S.lib.lfos.transition_stops(n, scene_data)`: true when LFO n runs now (`lfo_<n>` on) and is off in the scene. A fade to such a scene fades the LFO's `stop_target` fields there and holds its other continuous fields (#408, `docs/notes/lua/scenes.md`).
- The offset (#103, format 3) crossfades in whole percents like the depth. Its entry's `range` (`LFO_OFFSET_RANGE`) is what `validate_scene` accepts; a recalled offset outside the current baseline's range (a scene saved with another baseline) is clamped by the param. Its state switch at the end keeps it (see Must not break).
- Scenes without them migrate to the defaults (LFOs off, offsets 0).

## Cleanup

Per LFO (step 120): `S.lfos[n]:stop()`, `params:set("lfo_<n>", 1)` and `restore_lfo_destination(n)`.

-- lib/lfos.lua
-- The three global LFOs (S.lfos), built on norns' lib/lfo.lua: their
-- destinations (S.LFO_DESTINATIONS: the built-in ones, then, from init, the
-- registered ones, S.registry.lfo_destinations), the action that modulates a
-- destination's engine value (apply_lfo), restoring it, the LFO page dot's
-- phase estimate (S.lfo_last_raw, lfo_phase_estimate) and the LFO params
-- (add_lfo_params, which lib/params_setup.lua's lfos record calls).
-- S.selected_lfo is the LFO the LFO page and arc ring 4 work on. The
-- functions that were global stay global;
-- LFO_DEFAULT_PERIOD, LFO_OFFSET_RANGE, SCENE_FIELDS (the LFOs' scene
-- fields, which lib/scenes.lua appends to S.SCENE_GLOBAL_PARAMS),
-- transition_stops (whether a fade stops an LFO) and BUILT_IN_DESTINATIONS
-- (the LFO page's groups) are fields of this module's table (S.lib.lfos).
-- Registers the LFOs' cleanup step.

return function(S)
  local M = {}
  local LFO = require "lfo"
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_LFOS = S.constants.NUM_LFOS

  -- Global LFOs, built on norns' lib/lfo.lua. Each LFO runs from -1 to 1
  -- around a center baseline, so the library applies depth and its action
  -- gets a scaled value in -depth..depth. apply_lfo sends the destination's
  -- stored value plus scaled * half its range to the engine through
  -- send_param_to_engine; the param itself is never written. The library
  -- stops calling the action when an LFO is turned off or its depth is 0, so
  -- Strata re-sends the stored value then, and when the destination changes.
  -- (S.lfo_last_dest and S.lfo_scaled are declared with send_param_to_engine,
  -- in lib/engine_sync.lua.)
  S.lfos = {}
  S.selected_lfo = 1     -- LFO page and arc ring 4
  S.lfo_last_raw = {}    -- per LFO: last raw shape value (0..1), for the LFO page dot
  local LFO_DEFAULT_PERIOD = 4  -- seconds (free mode)
  -- LFOs start at a quarter of their depth, so turning one on is audible
  -- (scenes keep the depth they store; lib/scenes.lua's migration default
  -- for a file without one stays 0)
  local LFO_DEFAULT_DEPTH = 0.25
  -- The library's lfo_offset_<n> range in percent, for every baseline (from
  -- center narrows it to -50..50): what a scene's offset may hold
  local LFO_OFFSET_RANGE = {-100, 100}
  -- The library's lfo_<n> state options: 1 off, 2 on
  local LFO_STATE = {off = 1, on = 2}

  -- The LFOs' scene fields, which lib/scenes.lua appends to
  -- S.SCENE_GLOBAL_PARAMS after its built-in globals (the same records, in
  -- this order). Per LFO: the library's shape, mode, clocked rate, free
  -- period, depth (percent) and offset (percent), Strata's destination,
  -- then the state, so an LFO starts with its settings in place. Depth,
  -- free period and offset crossfade (lfo = n: the LFO they belong to),
  -- except toward a scene that stops the running LFO (M.transition_stops):
  -- its depth fades to stop_target (0) and the others hold, the end setting
  -- the scene's values with the state (#408). The state switch re-bangs the
  -- library's baseline, which zeroes the offset: the lfo_<n> wrapper below
  -- puts the recalled one back (#103). range (optional) is the {min, max}
  -- validate_scene allows: the offset's is the library's, -100..100 for
  -- every baseline (the param clamps a recalled value to its current
  -- baseline's range). default is what a scene without the field loads
  local SCENE_FIELDS = {}
  for n = 1, NUM_LFOS do
    table.insert(SCENE_FIELDS, {id = "lfo_shape_" .. n, continuous = false, default = 1})    -- sine
    table.insert(SCENE_FIELDS, {id = "lfo_mode_" .. n, continuous = false, default = 2})     -- free
    table.insert(SCENE_FIELDS, {id = "lfo_clocked_" .. n, continuous = false, default = 13}) -- "4" (the library's index for a period of 4)
    table.insert(SCENE_FIELDS, {id = "lfo_free_" .. n, continuous = true, lfo = n, default = LFO_DEFAULT_PERIOD})
    table.insert(SCENE_FIELDS, {id = "lfo_depth_" .. n, continuous = true, lfo = n, stop_target = 0, default = 0})
    table.insert(SCENE_FIELDS, {id = "lfo_offset_" .. n, continuous = true, lfo = n, default = 0,
      range = LFO_OFFSET_RANGE})
    table.insert(SCENE_FIELDS, {id = "strata_lfo" .. n .. "_dest", continuous = false, default = 1}) -- none
    table.insert(SCENE_FIELDS, {id = "lfo_" .. n, continuous = false, default = 1})          -- off
  end

  -- Whether a smooth transition to scene_data stops LFO n: it runs now and
  -- is off in the scene (lib/scenes.lua's scene_transition_targets)
  function M.transition_stops(n, scene_data)
    return params:get("lfo_" .. n) == LFO_STATE.on and scene_data["lfo_" .. n] == LFO_STATE.off
  end

  -- Library steps per beat (its default is 96): the action, and so an engine
  -- message, runs on every step, so this bounds the message rate (96/s per LFO
  -- at 120 BPM) while a 10 Hz LFO still gets several steps per cycle
  local LFO_PPQN = 48
  -- An LFO step is not sent when the destination's engine value would move by
  -- less than this fraction of its range since the last value sent to it,
  -- measured along the range's warp (destination_position): an exponential
  -- range (a frequency) in octaves, so a slow LFO glides evenly at its low
  -- end too (#406)
  local LFO_SEND_THRESHOLD = 1 / 1000

  -- LFO destinations in strata_lfo<n>_dest option order: {label, resolve},
  -- where resolve returns the param id to modulate (nil for none). A voice's
  -- "main" resolves on every LFO step, so it follows the voice's source.
  local function fixed_destination(label, param_id)
    return {label = label, resolve = function() return param_id end}
  end

  S.LFO_DESTINATIONS = {
    {label = "none", resolve = function() return nil end},
    fixed_destination("density", "master_density"),
    fixed_destination("drift", "drift_amount"),
    fixed_destination("filt freq", "filter_freq"),
    fixed_destination("filt res", "filter_res"),
    fixed_destination("filt mix", "filter_mix"),
    fixed_destination("dly time", "delay_time"),
    fixed_destination("dly fdbk", "delay_feedback"),
    fixed_destination("dly mix", "delay_mix"),
    fixed_destination("rev mix", "reverb_mix"),
    fixed_destination("rev size", "reverb_size"),
    fixed_destination("rev damp", "reverb_damp")
  }

  -- per voice, after "v<i> main": {label suffix, param id suffix}
  local VOICE_LFO_DESTINATIONS = {
    {"size", "grain_size"}, {"dens", "grain_density"}, {"pitch", "grain_pitch"}, {"spread", "grain_spread"},
    {"pos", "buf_pos"}, {"rate", "buf_rate"}, {"scan", "buf_scan"}
  }

  for i = 1, NUM_VOICES do
    table.insert(S.LFO_DESTINATIONS, {label = "v" .. i .. " main", resolve = function() return main_param_id(i) end})
    for _, entry in ipairs(VOICE_LFO_DESTINATIONS) do
      table.insert(S.LFO_DESTINATIONS, fixed_destination("v" .. i .. " " .. entry[1], "v" .. i .. "_" .. entry[2]))
    end
  end

  -- The built-in destinations end here. Their indices are stored in PSETs
  -- and scenes (strata_lfo<n>_dest), so they never move: the registered
  -- destinations (S.registry.lfo_destinations) follow them, by registration
  -- and then voice, so a later registration only appends
  local BUILT_IN_LFO_DESTINATIONS = #S.LFO_DESTINATIONS

  -- At init (add_lfo_params): the registered destinations after the
  -- built-in ones, and the option labels of the whole list. A per-voice
  -- record ({label, suffix}) adds v1 <label> ... v7 <label>; a global one
  -- ({label, param_id, global = true}) adds one destination, <label>
  local function lfo_destination_labels()
    for index = #S.LFO_DESTINATIONS, BUILT_IN_LFO_DESTINATIONS + 1, -1 do S.LFO_DESTINATIONS[index] = nil end
    local labels = {}
    for index, destination in ipairs(S.LFO_DESTINATIONS) do labels[index] = destination.label end
    local taken = {}
    for _, label in ipairs(labels) do taken[label] = true end
    local function add(label, param_id)
      if taken[label] then error("register_lfo_destination: the label " .. label .. " is taken", 0) end
      taken[label] = true
      table.insert(S.LFO_DESTINATIONS, fixed_destination(label, param_id))
      table.insert(labels, label)
    end
    for _, entry in ipairs(S.registry.lfo_destinations) do
      if entry.global then
        add(entry.label, entry.param_id)
      else
        for i = 1, NUM_VOICES do add("v" .. i .. " " .. entry.label, "v" .. i .. "_" .. entry.suffix) end
      end
    end
    return labels
  end

  -- The param id LFO n modulates now, or nil
  function lfo_destination_id(n)
    return S.LFO_DESTINATIONS[params:get("strata_lfo" .. n .. "_dest")].resolve()
  end

  -- LFO n stops modulating its destination: the engine gets the stored value
  -- back (plus any other LFO's offset on it). Always sends.
  function restore_lfo_destination(n)
    local param_id = S.lfo_last_dest[n]
    if not param_id then return end
    S.lfo_last_dest[n] = nil
    S.lfo_scaled[n] = nil
    send_param_to_engine(param_id, params:get(param_id))
  end

  -- A value's position (0-1) along a destination's range, as its
  -- controlspec's warp places it (an exponential range in octaves), without
  -- the rounding to the param's step that unmap does first: a move finer
  -- than the step must count (a 0.01-step mix still sends every 1/1000).
  -- So it unmaps with a copy of the spec whose step is 0, made once per
  -- spec (keyed weakly by the spec itself, so a param given a new spec gets
  -- a new copy); the param's own spec is never changed. A destination's
  -- range never changes in place
  local unstepped_specs = setmetatable({}, {__mode = "k"})
  local function destination_position(param_id, value)
    local spec = params:lookup_param(param_id).controlspec
    local unstepped = unstepped_specs[spec]
    if not unstepped then
      unstepped = spec:copy()
      unstepped.step = 0
      unstepped_specs[spec] = unstepped
    end
    return unstepped:unmap(value)
  end

  -- One step of LFO n (the library passes scaled and raw)
  local function step_lfo(n, scaled, raw)
    S.lfo_last_raw[n] = raw
    local param_id = lfo_destination_id(n)
    -- a "main" destination re-resolves to another param when the voice's
    -- source changes: give the old one back first
    if param_id ~= S.lfo_last_dest[n] then restore_lfo_destination(n) end
    if not param_id then return end
    S.lfo_last_dest[n] = param_id
    S.lfo_scaled[n] = scaled
    local value = S.lib.engine_sync.with_lfo_offsets(param_id, params:get(param_id))
    -- skip steps too small to matter (a slow LFO moves very little per step)
    local last_sent = S.engine_param_values[param_id]
    if last_sent ~= nil then
      local moved = math.abs(destination_position(param_id, value) - destination_position(param_id, last_sent))
      if moved < LFO_SEND_THRESHOLD then return end
    end
    S.lib.engine_sync.send_engine_value(param_id, value)
  end

  -- LFO n's action: its step, protected. norns' lattice runs every LFO's
  -- step, so an error raised in one would stop them all for the session
  -- (#517): it is printed with its traceback instead, once per distinct
  -- message per LFO (a good step forgets it), through the frame's
  -- contained_call (lib/ui/frame.lua)
  local step_errors = {}  -- per LFO: the error message it last printed
  function apply_lfo(n, scaled, raw)
    S.lib.ui_frame.contained_call(step_errors, n, "LFO " .. n .. " step", step_lfo, n, scaled, raw)
  end

  -- LFO page dot: the library's running phase moves on its lattice's steps
  -- (get("phase") is the phase offset setting), so Strata estimates it from
  -- the time since the phase was last taken and the period.
  -- lfo_phase_base[n] is the phase (before the offset) at time
  -- lfo_phase_time[n]. A reset and a mode change take it from the library
  -- (sync_lfo_phase); a period change rebases it so the dot keeps its place,
  -- as the library keeps its phase.
  local lfo_phase_base = {}
  local lfo_phase_time = {}

  -- The library's phase now (before the offset), from its phase counter (in
  -- beats), as its process_lfo computes it: phase_counter / period when
  -- clocked, phase_counter x beat length / period when free
  local function library_phase(n)
    local lfo = S.lfos[n]
    local phase = lfo.phase_counter / lfo:get("period")
    if lfo:get("mode") ~= "clocked" then phase = phase * clock.get_beat_sec() end
    return phase % 1
  end

  -- After the library moved its phase: the dot goes on from there. A reset
  -- lands on the reset target (mid: rising lands at (beat length / period)^2
  -- of a free cycle, the library's own arithmetic); a mode change scales the
  -- phase by the beat length, since the library's mode action sets the mode
  -- before the period and change_period reads the old period in the new
  -- mode's unit (#409)
  local function sync_lfo_phase(n)
    lfo_phase_base[n] = library_phase(n)
    lfo_phase_time[n] = util.time()
  end

  local function lfo_period_seconds(n)
    local period = S.lfos[n]:get("period")
    if S.lfos[n]:get("mode") == "clocked" then
      return period * clock.get_beat_sec()  -- clocked periods are in beats
    end
    return period
  end

  local function lfo_running_phase(n)
    return (lfo_phase_base[n] + (util.time() - lfo_phase_time[n]) / lfo_period_seconds(n)) % 1
  end

  local function rebase_lfo_phase(n)
    lfo_phase_base[n] = lfo_running_phase(n)
    lfo_phase_time[n] = util.time()
  end

  -- Estimated position (0..1) in LFO n's cycle, phase offset included
  function lfo_phase_estimate(n)
    return (lfo_running_phase(n) + S.lfos[n]:get("phase")) % 1
  end

  -- Run Strata's code before and/or after a library param's own action
  local function wrap_param_action(param_id, before, after)
    local library_action = params:lookup_param(param_id).action
    params:set_action(param_id, function(x)
      if before then before(x) end
      library_action(x)
      if after then after(x) end
    end)
  end

  -- PARAMS layout: norns groups cannot nest, and the library builds its own
  -- group per LFO, so the three destinations get a group of their own
  -- (strata_lfos) ahead of the library's groups lfo_group_1..3 ("LFO 1".."LFO 3")
  function add_lfo_params()
    local destination_labels = lfo_destination_labels()
    params:add_group("strata_lfos", "lfo destinations", NUM_LFOS)
    for n = 1, NUM_LFOS do
      params:add{
        type = "option",
        id = "strata_lfo" .. n .. "_dest",
        name = "LFO " .. n .. " dest",
        options = destination_labels,
        default = 1,
        action = function()
          restore_lfo_destination(n)
        end
      }
    end

    for n = 1, NUM_LFOS do
      S.lfos[n] = LFO:add{
        shape = "sine", min = -1, max = 1, depth = LFO_DEFAULT_DEPTH, mode = "free", period = LFO_DEFAULT_PERIOD,
        baseline = "center",
        action = function(scaled, raw) apply_lfo(n, scaled, raw) end
      }
      S.lfos[n]:set("ppqn", LFO_PPQN)  -- before start: the sprocket is built from it
      -- the library's params lfo_<n>, lfo_shape_<n>, lfo_depth_<n> (0-100 %), ...
      S.lfos[n]:add_params(tostring(n), nil, "LFO " .. n)
      -- the library starts lfo_depth_<n> at depth * 100, a float in Lua 5.3
      -- that its formatter shows as "25.0%": make the default and value whole
      local depth_param = params:lookup_param("lfo_depth_" .. n)
      depth_param.default = math.floor(depth_param.default + 0.5)
      depth_param.value = depth_param.default
      sync_lfo_phase(n)
      -- the library's state action re-bangs the baseline, whose
      -- change_offset sets lfo_offset_<n> to 0 (#103): keep the offset across
      -- on/off (a real baseline change still zeroes it)
      local offset_id = "lfo_offset_" .. n
      local offset_before_state
      wrap_param_action("lfo_" .. n, function()
        offset_before_state = params:get(offset_id)
      end, function(state)
        if params:get(offset_id) ~= offset_before_state then params:set(offset_id, offset_before_state) end
        if state == 1 then
          restore_lfo_destination(n)
          S.lfo_last_raw[n] = nil
        end
        -- the dot restarts through the lfo_reset_<n> wrapper: the library's state action ends with lfo_bang (#251)
      end)
      wrap_param_action("lfo_depth_" .. n, nil, function(depth)
        if depth == 0 then restore_lfo_destination(n) end
      end)
      wrap_param_action("lfo_reset_" .. n, nil, function() sync_lfo_phase(n) end)
      for _, prefix in ipairs({"lfo_clocked_", "lfo_free_"}) do
        wrap_param_action(prefix .. n, function() rebase_lfo_phase(n) end,
          function() note_param_edit(prefix .. n) end)  -- an edit ends a randomize undo (#557)
      end
      wrap_param_action("lfo_shape_" .. n, nil, function() note_param_edit("lfo_shape_" .. n) end)
      -- a mode change moves the library's phase (sync_lfo_phase), and arc
      -- ring 4's carried ticks were for the other mode's period param
      wrap_param_action("lfo_mode_" .. n, nil, function()
        sync_lfo_phase(n)
        if n == S.selected_lfo then forget_arc_lfo_period_ticks() end
      end)
      -- norns' library raises inside its lattice on a random step whose min
      -- is above its max (#528): the bound set takes the other with it, so
      -- min never passes max, and a pair set one value at a time (a PSET)
      -- lands as stored in either order
      wrap_param_action("lfo_min_" .. n, function(low)
        if low > params:get("lfo_max_" .. n) then params:set("lfo_max_" .. n, low) end
      end)
      wrap_param_action("lfo_max_" .. n, function(high)
        if high < params:get("lfo_min_" .. n) then params:set("lfo_min_" .. n, high) end
      end)
    end
  end

  -- Stop the LFOs (through their state params, like the library's menu) and
  -- give their destinations back their stored values
  -- (a start that failed before init added the params built no LFOs)
  S.register_cleanup(S.constants.CLEANUP_ORDER.lfos, function()
    for n = 1, NUM_LFOS do
      if S.lfos[n] then
        S.lfos[n]:stop()
        params:set("lfo_" .. n, 1)
        restore_lfo_destination(n)
      end
    end
  end)

  M.LFO_DEFAULT_PERIOD = LFO_DEFAULT_PERIOD
  M.LFO_OFFSET_RANGE = LFO_OFFSET_RANGE
  M.SCENE_FIELDS = SCENE_FIELDS
  M.BUILT_IN_DESTINATIONS = BUILT_IN_LFO_DESTINATIONS  -- the LFO page's last voice group ends here
  return M
end

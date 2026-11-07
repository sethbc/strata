-- lib/lfos.lua
-- The three global LFOs (S.lfos), built on norns' lib/lfo.lua: their
-- destinations (S.LFO_DESTINATIONS), the action that modulates a
-- destination's engine value (apply_lfo), restoring it, the LFO page dot's
-- phase estimate (S.lfo_last_raw, lfo_phase_estimate) and the LFO params
-- (add_lfo_params, which lib/params_setup.lua's lfos record calls).
-- S.selected_lfo is the LFO the LFO page and arc ring 4 work on. The
-- functions that were global stay global;
-- LFO_DEFAULT_PERIOD is a field of this module's table (S.lib.lfos) for the
-- scene defaults in lib/scenes.lua. Registers the LFOs' cleanup step.

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
  -- Library steps per beat (its default is 96): the action, and so an engine
  -- message, runs on every step, so this bounds the message rate (96/s per LFO
  -- at 120 BPM) while a 10 Hz LFO still gets several steps per cycle
  local LFO_PPQN = 48
  -- An LFO step is not sent when the destination's engine value would move by
  -- less than this fraction of its range since the last value sent to it
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

  local LFO_DESTINATION_LABELS = {}
  for index, destination in ipairs(S.LFO_DESTINATIONS) do
    LFO_DESTINATION_LABELS[index] = destination.label
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

  -- LFO n's action (the library passes scaled and raw)
  function apply_lfo(n, scaled, raw)
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
      local minval, maxval = param_range(param_id)
      if math.abs(value - last_sent) < (maxval - minval) * LFO_SEND_THRESHOLD then return end
    end
    S.lib.engine_sync.send_engine_value(param_id, value)
  end

  -- LFO page dot: the library's running phase is internal (get("phase") is
  -- the phase offset setting), so Strata estimates it from the time since the
  -- LFO's last reset and its period. lfo_phase_base[n] is the phase (before the
  -- offset) at time lfo_phase_time[n]; a period change rebases it so the dot
  -- keeps its place, as the library keeps its phase.
  local lfo_phase_base = {}
  local lfo_phase_time = {}
  -- the phase LFO:reset_phase restarts the cycle at, per reset target
  local LFO_RESET_PHASES = {floor = 0.75, ceiling = 0.25, ["mid: rising"] = 0, ["mid: falling"] = 0.5}

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

  local function note_lfo_reset(n)
    lfo_phase_base[n] = LFO_RESET_PHASES[S.lfos[n]:get("reset_target")] or 0
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
    params:add_group("strata_lfos", "lfo destinations", NUM_LFOS)
    for n = 1, NUM_LFOS do
      params:add{
        type = "option",
        id = "strata_lfo" .. n .. "_dest",
        name = "LFO " .. n .. " dest",
        options = LFO_DESTINATION_LABELS,
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
      note_lfo_reset(n)
      wrap_param_action("lfo_" .. n, nil, function(state)
        if state == 1 then
          restore_lfo_destination(n)
          S.lfo_last_raw[n] = nil
        else
          note_lfo_reset(n)  -- LFO:start resets the phase
        end
      end)
      wrap_param_action("lfo_depth_" .. n, nil, function(depth)
        if depth == 0 then restore_lfo_destination(n) end
      end)
      wrap_param_action("lfo_reset_" .. n, nil, function() note_lfo_reset(n) end)
      for _, prefix in ipairs({"lfo_mode_", "lfo_clocked_", "lfo_free_"}) do
        wrap_param_action(prefix .. n, function() rebase_lfo_phase(n) end)
      end
      -- arc ring 4's carried ticks were for the other mode's period param
      wrap_param_action("lfo_mode_" .. n, nil, function()
        if n == S.selected_lfo then forget_arc_lfo_period_ticks() end
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
  return M
end

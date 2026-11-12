-- lib/scatter.lua
-- Scatter (3.4, design §6): slow, smooth random modulation that the
-- engine's one scatter node gives every unlocked voice, independently per
-- voice and per enabled destination (grain pitch, position, size, the
-- voice filter's cutoff and the level), at depth x half the destination's
-- range. Lua owns its eight params (the group strata_scatter, which
-- lib/params_setup.lua's scatter record adds through add_params) and sends
-- the whole state as one setScatter from each param's sender, every lock
-- change (S.register_lock_change) and a silent PSET read; no message per
-- step. Every param is a scene field (the depth and rate crossfade, the
-- toggles switch at a fade's end). S.lib.scatter holds add_params,
-- affects(voice) and SCATTER (the tunables). No clock, metro or poll.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- The params (design §6): on, depth (percent) and rate, then one toggle
  -- per engine destination in bit order (bit d of setScatter's destination
  -- mask is engine destination d: pitch, position, size, cutoff, amp),
  -- each with its default
  local SCATTER = {
    param_count = 8,
    depth = {min = 0, max = 100, default = 10},
    rate = {min = 0.01, max = 1, default = 0.1},
    destinations = {
      {id = "scatter_pitch", name = "pitch", default = 1},
      {id = "scatter_pos", name = "position", default = 1},
      {id = "scatter_size", name = "size", default = 0},
      {id = "scatter_cutoff", name = "cutoff", default = 0},
      {id = "scatter_amp", name = "amp", default = 0},
    },
  }
  M.SCATTER = SCATTER

  local function is_on() return params:get("scatter") == 1 end

  -- The destination mask: bit d set while destination d's toggle is on
  local function destination_mask()
    local mask, bit_value = 0, 1
    for _, destination in ipairs(SCATTER.destinations) do
      if params:get(destination.id) == 1 then mask = mask + bit_value end
      bit_value = bit_value * 2
    end
    return mask
  end

  -- The voice mask: bit v - 1 set for every unlocked voice (a locked voice
  -- is left alone, as by the drift and mutation)
  local function voice_mask()
    local mask, bit_value = 0, 1
    for voice_idx = 1, NUM_VOICES do
      if not S.frozen[voice_idx] then mask = mask + bit_value end
      bit_value = bit_value * 2
    end
    return mask
  end

  -- The whole state as one message: the depth as 0-1 (0 while off, which
  -- releases the engine's node), the rate and both masks. It reads the
  -- stored values: no scatter param is an LFO destination, a macro target
  -- or a matrix destination, so what is stored is what the engine plays
  local function send()
    local depth = is_on() and params:get("scatter_depth") / 100 or 0
    engine.setScatter(depth, params:get("scatter_rate"), destination_mask(), voice_mask())
  end

  -- Whether scatter moves voice_idx now: on, above depth 0, a destination
  -- enabled and the voice unlocked
  function M.affects(voice_idx)
    if type(voice_idx) ~= "number" or voice_idx % 1 ~= 0 or voice_idx < 1 or voice_idx > NUM_VOICES then
      return false
    end
    return is_on() and params:get("scatter_depth") > 0 and destination_mask() > 0 and not S.frozen[voice_idx]
  end

  local function percent(param) return string.format("%d %%", math.floor(param:get() + 0.5)) end
  local function hertz(param) return string.format("%.2f Hz", param:get()) end

  -- The group strata_scatter (the menu record "scatter" of
  -- lib/params_setup.lua adds it). Each action sends through its sender
  -- (send_param_to_engine, never engine.* from a control param's action);
  -- the depth's and the rate's call note_param_edit (MOD's randomize draws
  -- them)
  function M.add_params()
    params:add_group("strata_scatter", "scatter", SCATTER.param_count)
    params:add{type = "binary", behavior = "toggle", id = "scatter", name = "scatter", default = 0,
      action = function(x) send_param_to_engine("scatter", x) end}
    params:add{type = "control", id = "scatter_depth", name = "depth",
      controlspec = controlspec.new(SCATTER.depth.min, SCATTER.depth.max, "lin", 1, SCATTER.depth.default, "%",
        1 / (SCATTER.depth.max - SCATTER.depth.min)),
      formatter = percent,
      action = function(x)
        note_param_edit("scatter_depth")
        send_param_to_engine("scatter_depth", x)
      end}
    params:add{type = "control", id = "scatter_rate", name = "rate",
      controlspec = controlspec.new(SCATTER.rate.min, SCATTER.rate.max, "exp", 0, SCATTER.rate.default, "Hz"),
      formatter = hertz,
      action = function(x)
        note_param_edit("scatter_rate")
        send_param_to_engine("scatter_rate", x)
      end}
    for _, destination in ipairs(SCATTER.destinations) do
      params:add{type = "binary", behavior = "toggle", id = destination.id, name = destination.name,
        default = destination.default, action = function(x) send_param_to_engine(destination.id, x) end}
    end
  end

  S.engine_senders.scatter = send
  S.engine_senders.scatter_depth = send
  S.engine_senders.scatter_rate = send
  for _, destination in ipairs(SCATTER.destinations) do S.engine_senders[destination.id] = send end

  -- A lock change (toggle_lock, a recall's lock states) changes the voice mask
  S.register_lock_change(function() send() end)

  -- A silent PSET read sets the params without their actions: the engine
  -- gets the loaded state once (a read with actions has sent it already)
  S.register_pset_hook({name = "scatter", read = function(path_base, number, pset_path, silent)
    if silent then send() end
  end})

  -- Scenes store all eight: the depth and the rate crossfade, the on/off
  -- and the destination toggles switch at a fade's end
  S.register_scene_field({id = "scatter", default = 0, discrete = true})
  S.register_scene_field({id = "scatter_depth", default = SCATTER.depth.default})
  S.register_scene_field({id = "scatter_rate", default = SCATTER.rate.default})
  for _, destination in ipairs(SCATTER.destinations) do
    S.register_scene_field({id = destination.id, default = destination.default, discrete = true})
  end

  return M
end

-- lib/io/jf.lua
-- Just Friends as a note target over the ii bus (3.6 design 6.3,
-- S.lib.io_jf). A routed voice's notes go to Just Friends as one
-- play_note(pitch volts, level volts): JF allocates its own six voices and
-- steals the oldest, so a note off sends nothing. Command names and argument
-- order are crow's descriptor's (docs/design/3.6-facts/crow-ii.md section 2,
-- Just Friends). The ii bus module (S.lib.io_ii) does the sending, and only
-- while Strata leads the bus; where it is absent the device does nothing.
-- Its params are PSET-only.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  local JF = {
    device = "jf",
    volts = {min = -5, max = 5},
    level = {min = 0, max = 10, default = 5},  -- volts, peak to peak
    mode_synthesis = 1,
    mode_off = 0,
    param_count = NUM_VOICES + 1,
    level_id = "jf_level",
  }
  M.JF = JF

  local function route_id(voice) return "v" .. voice .. "_out_jf" end

  local function valid_voice(voice)
    return type(voice) == "number" and voice >= 1 and voice <= NUM_VOICES and voice == math.floor(voice)
  end

  -- The params exist only once the ii module has added them
  local function params_added()
    return params.lookup ~= nil and params.lookup[JF.level_id] ~= nil
  end

  local function bus() return S.lib.io_ii end

  local function leads()
    local ii = bus()
    return ii ~= nil and ii.leads() == true
  end

  local function routed(voice)
    if not valid_voice(voice) or not params_added() then return false end
    return params:get(route_id(voice)) == 1 and leads()
  end

  -- Called by the ii module's add_params (a group of the devices' summed
  -- param_count): the seven routes, then the level
  function M.add_params()
    for voice = 1, NUM_VOICES do
      params:add{type = "binary", behavior = "toggle", id = route_id(voice), name = "jf out v" .. voice,
        default = 0,
        action = function()
          if S.lib.io_targets then S.lib.io_targets.route_changed(voice) end
        end}
    end
    params:add{type = "control", id = JF.level_id, name = "jf level",
      controlspec = controlspec.new(JF.level.min, JF.level.max, "lin", 0, JF.level.default, "V")}
  end

  S.register_ii_device({
    name = JF.device,
    ports = false,  -- play_note's first argument is a pitch, not a channel (#717)
    param_count = JF.param_count,
    add_params = M.add_params,
    -- Just Friends must be told to leave its default mode before it takes notes
    ready = function()
      if bus() then bus().send(JF.device, "mode", JF.mode_synthesis) end
    end,
    release = function()
      if bus() then bus().send_direct(JF.device, "mode", JF.mode_off) end
    end,
  })

  S.register_note_target({
    name = JF.device,
    routed = routed,
    note_on = function(voice, _, pitch, velocity)
      if not routed(voice) or type(pitch) ~= "number" or type(velocity) ~= "number" then return end
      local volts = math.max(JF.volts.min, math.min(JF.volts.max, S.lib.io_targets.volts(pitch)))
      bus().send(JF.device, "play_note", volts, velocity * params:get(JF.level_id))
    end,
    note_off = function() end,
    stop_all = function() end,
    rows = function(voice)
      if not params_added() or not valid_voice(voice) then return {} end
      return {
        {label = "jf", kind = "param", param_id = route_id(voice), binary = {[0] = "off", [1] = "on"}},
        {label = "jf level", kind = "param", param_id = JF.level_id, format = "%.1f V"},
      }
    end,
  })

  return M
end

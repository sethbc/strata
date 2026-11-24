-- lib/io/wsyn.lua
-- W/ synth over the ii bus (3.6 design §6.3, S.lib.io_wsyn): an ii device
-- (eight params: each voice's toggle and the level) and a note target. A
-- note is one wsyn.play_note(volts, velocity * level); W/ allocates its own
-- four voices (AR mode) and ends its own notes, so a note off sends
-- nothing. Command names and argument order are crow's descriptor's
-- (docs/design/3.6-facts/crow-ii.md §2, W/). Everything goes through
-- S.lib.io_ii, which sends only while Strata leads the bus; where that
-- module is absent nothing here sends, routes or reads a param.
-- Unverified on the device until the 4.0 hardware check.

return function(S)
  local M = {}

  local NUM_VOICES = S.constants.NUM_VOICES

  local WSYN = {
    device = "wsyn",
    volts_limit = 5,
    voices = 4,
    level = {min = 0, max = 10, default = 5},
    param_count = NUM_VOICES + 1,
    -- IO's mark on a route set while Strata does not lead the bus (#937)
    idle_mark = "[idle]",
  }
  M.WSYN = WSYN

  local function out_id(voice) return "v" .. voice .. "_out_wsyn" end

  local function bus() return S.lib.io_ii end

  local function leading()
    local ii = bus()
    return ii ~= nil and ii.leads() and true or false
  end

  -- true once the device's params were added (the group is the ii bus
  -- module's to add)
  local function has_params()
    return params.lookup.wsyn_level ~= nil
  end

  local function valid_voice(voice)
    return type(voice) == "number" and voice % 1 == 0 and voice >= 1 and voice <= NUM_VOICES
  end

  function M.add_params()
    for voice = 1, NUM_VOICES do
      params:add{type = "binary", behavior = "toggle", id = out_id(voice), name = "v" .. voice .. " w/ syn",
        default = 0, action = function() S.lib.io_targets.route_changed(voice) end}
    end
    params:add{type = "control", id = "wsyn_level", name = "w/ syn level",
      controlspec = controlspec.new(WSYN.level.min, WSYN.level.max, "lin", 0, WSYN.level.default, "V")}
  end

  S.register_ii_device({
    name = WSYN.device,
    ports = false,  -- play_note's first argument is a pitch, not a voice (#717)
    param_count = WSYN.param_count,
    add_params = M.add_params,
    ready = function()
      local ii = bus()
      if not ii then return end
      ii.send(WSYN.device, "ar_mode", 1)
      ii.send(WSYN.device, "voices", WSYN.voices)
    end,
  })

  local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

  S.register_note_target({
    name = WSYN.device,
    routed = function(voice)
      if not valid_voice(voice) or not has_params() then return false end
      return params:get(out_id(voice)) == 1 and leading()
    end,
    note_on = function(voice, _, pitch, velocity)
      if not valid_voice(voice) or not has_params() or not leading() then return end
      if type(pitch) ~= "number" or type(velocity) ~= "number" then return end
      local volts = clamp(S.lib.io_targets.volts(pitch), -WSYN.volts_limit, WSYN.volts_limit)
      bus().send(WSYN.device, "play_note", volts, velocity * params:get("wsyn_level"))
    end,
    note_off = function() end,
    stop_all = function() end,
    rows = function(voice)
      if not valid_voice(voice) or not has_params() then return {} end
      return {
        {label = "w/ syn", kind = "param", param_id = out_id(voice), binary = {[0] = "off", [1] = "on"},
          mark = function()
            if params:get(out_id(voice)) == 1 and not leading() then return WSYN.idle_mark end
            return nil
          end},
        {label = "w/ level", kind = "param", param_id = "wsyn_level", format = "%.1f V"},
      }
    end,
  })

  return M
end

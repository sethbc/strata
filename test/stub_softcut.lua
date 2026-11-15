-- stub_softcut.lua
-- Stand-in for norns' lua/core/softcut.lua: the global `softcut` holds
-- every function of the module's public list (SC.* in softcut.lua) and
-- records each call as {name, arg1, arg2, ...} in context.softcut.calls;
-- a name the real module lacks raises, so a typo fails a test.
-- context.softcut.value(name, ...) returns the argument after the leading
-- ones given, from the last call of that name whose leading arguments
-- match (softcut.rate(1, 0.5): value("rate", 1) == 0.5), nil before any.
-- softcut.reset() clears the calls and the phase callback, as the real reset
-- clears the voices and that callback. event_phase, event_position and
-- event_render keep their callback: context.softcut.fire(name, ...) calls
-- it (and raises when none is set). defaults() and params() raise "not
-- modeled".
-- softcut.VOICE_COUNT is 6 and BUFFER_SIZE 16777216 / 48000. The audio
-- level functions (audio.level_eng_cut, level_cut, ...) live in
-- norns_stubs.lua's audio table and record context.audio.levels.

local FUNCTIONS = {
  "level", "pan", "level_input_cut", "level_cut_cut", "play", "rate", "loop_start", "loop_end", "loop",
  "fade_time", "rec_level", "pre_level", "rec", "rec_offset", "position", "buffer", "voice_sync",
  "pre_filter_fc", "pre_filter_fc_mod", "pre_filter_rq", "pre_filter_lp", "pre_filter_hp",
  "pre_filter_bp", "pre_filter_br", "pre_filter_dry",
  "filter_fc", "filter_fc_mod", "filter_rq", "filter_lp", "filter_hp", "filter_bp", "filter_br", "filter_dry",
  "post_filter_fc", "post_filter_rq", "post_filter_lp", "post_filter_hp", "post_filter_bp",
  "post_filter_br", "post_filter_dry",
  "level_slew_time", "pan_slew_time", "recpre_slew_time", "rate_slew_time",
  "phase_quant", "phase_offset", "poll_start_phase", "poll_stop_phase", "enable",
  "buffer_clear", "buffer_clear_channel", "buffer_clear_region", "buffer_clear_region_channel",
  "buffer_copy_mono", "buffer_copy_stereo", "buffer_read_mono", "buffer_read_stereo",
  "buffer_write_mono", "buffer_write_stereo", "render_buffer",
  "query_position",
}

return function()
  local helpers = { calls = {} }
  local softcut = { VOICE_COUNT = 6, BUFFER_SIZE = 16777216 / 48000 }

  for _, name in ipairs(FUNCTIONS) do
    softcut[name] = function(...)
      local call = { name }
      for index = 1, select("#", ...) do call[index + 1] = (select(index, ...)) end
      table.insert(helpers.calls, call)
    end
  end

  -- the callbacks a script registers (softcut.lua :372, :385, :395), kept
  -- for context.softcut.fire(name, ...)
  helpers.callbacks = {}
  for _, name in ipairs({ "event_phase", "event_position", "event_render" }) do
    softcut[name] = function(callback)
      table.insert(helpers.calls, { name, callback })
      helpers.callbacks[name] = callback
    end
  end

  function helpers.fire(name, ...)
    local callback = helpers.callbacks[name]
    if not callback then error("softcut stub: no callback is set with softcut." .. tostring(name), 2) end
    return callback(...)
  end

  -- SC.defaults and SC.params (softcut.lua :417, :479) set a script's voices
  -- and add its params; the stub models neither
  for _, name in ipairs({ "defaults", "params" }) do
    softcut[name] = function() error("softcut." .. name .. " is not modeled by the softcut stub", 2) end
  end

  -- SC.reset (softcut.lua :405) calls _norns.cut_reset and clears the phase callback
  function softcut.reset()
    for index = #helpers.calls, 1, -1 do helpers.calls[index] = nil end
    helpers.callbacks.event_phase = nil
  end

  setmetatable(softcut, { __index = function(_, name)
    error("softcut." .. tostring(name) .. " is not a function of norns' softcut module", 2)
  end })

  function helpers.value(name, ...)
    local leading = select("#", ...)
    for index = #helpers.calls, 1, -1 do
      local call = helpers.calls[index]
      if call[1] == name then
        local matches = true
        for position = 1, leading do
          if call[position + 1] ~= (select(position, ...)) then matches = false; break end
        end
        if matches then return call[leading + 2] end
      end
    end
    return nil
  end

  helpers.softcut = softcut
  return helpers
end

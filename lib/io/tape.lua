-- lib/io/tape.lua
-- The tape loop (3.6 design §12, S.lib.io_tape): softcut's voices 1 and 2
-- loop norns' engine output as one stereo tape, with feedback, a worn
-- (low-passed) repeat and a speed. Every softcut call, its order and its
-- value come from docs/design/3.6-facts/checks.md §8 (softcut's write path,
-- from its C++ source): the cutoff tops out at 12000 Hz, the write gains
-- 1.2, pre_filter_fc_mod must precede pre_filter_fc, and the ADC and tape
-- levels go into softcut at 0 while the loop is on. Off by default: with
-- the tape off nothing here reaches softcut or the mixer.
-- Sets no engine command and no rig setting; its params are PSET-only.

return function(S)
  local M = {}

  local TAPE = {
    voices = {1, 2},
    fade_seconds = 0.02,
    rate_slew_seconds = 0.2,
    cutoff_open = 12000,   -- softcut clamps the cutoff there
    cutoff_worn = 800,
    filter_rq = 1.414,     -- the default damping of 4 would dull every pass
    write_gain = 1.2,      -- softcut's write path gains this; the feedback param is divided by it
    length = {min = 0.25, max = 60, default = 4},
    rate = {min = -2, max = 2, default = 1},
    feedback = {default = 0.5},
    wear = {default = 0.2},
    level = {default = 0.7},
    param_count = 7,
    -- the four params a macro can move (one list: their senders, macro targets and the
    -- LFO sender test's skip list), each with its macro label
    macro_targets = {"tapeloop_level", "tapeloop_rate", "tapeloop_feedback", "tapeloop_wear"},
    macro_labels = {tapeloop_level = "tape level", tapeloop_rate = "tape speed", tapeloop_feedback = "tape fb",
      tapeloop_wear = "tape wear"},
  }
  M.TAPE = TAPE

  local engaged = false

  local function each_voice(fn)
    for _, voice in ipairs(TAPE.voices) do fn(voice) end
  end

  -- The value a modulated param has now: what the engine path last held
  -- (stored value plus the macros' and LFOs' offsets) or the stored value
  local function current(id)
    return engine_param_value(id)
  end

  local function cutoff_for(wear)
    return TAPE.cutoff_open * (TAPE.cutoff_worn / TAPE.cutoff_open) ^ wear
  end

  local function send_level(value) each_voice(function(v) softcut.level(v, value) end) end
  local function send_rate(value) each_voice(function(v) softcut.rate(v, value) end) end
  local function send_feedback(value)
    each_voice(function(v) softcut.level_cut_cut(v, v, value / TAPE.write_gain) end)
  end
  local function send_wear(value)
    each_voice(function(v) softcut.pre_filter_fc(v, cutoff_for(value)) end)
  end

  -- The tape on (checks.md §8's order, verbatim), then the mixer: the loop
  -- holds Strata's output and nothing else
  local function start()
    if engaged then return end
    engaged = true
    local length = params:get("tapeloop_length")
    local rate, level = current("tapeloop_rate"), current("tapeloop_level")
    local feedback, wear = current("tapeloop_feedback"), current("tapeloop_wear")
    local recording = params:get("tapeloop_rec") == 1
    each_voice(function(v)
      softcut.buffer(v, v)
      softcut.pan(v, v == 1 and -1 or 1)
      softcut.loop(v, 1)
      softcut.loop_start(v, 0)
      softcut.loop_end(v, length)
      softcut.fade_time(v, TAPE.fade_seconds)
      softcut.position(v, 0)
      softcut.rate_slew_time(v, TAPE.rate_slew_seconds)
      softcut.rate(v, rate)
      softcut.level(v, level)
      softcut.level_input_cut(v, v, 1)
      softcut.pre_level(v, 0)
      softcut.level_cut_cut(v, v, feedback / TAPE.write_gain)
      softcut.rec_level(v, recording and 1 or 0)
      softcut.pre_filter_fc_mod(v, 0)
      softcut.pre_filter_fc(v, cutoff_for(wear))
      softcut.pre_filter_rq(v, TAPE.filter_rq)
      softcut.pre_filter_lp(v, 1)
      softcut.pre_filter_dry(v, 0)
      softcut.post_filter_dry(v, 1)
      softcut.rec(v, 1)
      softcut.play(v, 1)
      softcut.enable(v, 1)
    end)
    audio.level_eng_cut(1)
    audio.level_adc_cut(0)
    audio.level_tape_cut(0)
  end

  -- The tape off, and cleanup's step: both voices disabled, the mixer's
  -- three cut levels put back from norns' own params. Nothing when the
  -- tape was never on
  function M.stop()
    if not engaged then return end
    engaged = false
    each_voice(function(v) softcut.enable(v, 0) end)
    audio.level_eng_cut(util.dbamp(params:get("cut_input_eng")))
    audio.level_adc_cut(util.dbamp(params:get("cut_input_adc")))
    audio.level_tape_cut(util.dbamp(params:get("cut_input_tape")))
  end

  function M.is_on() return engaged end

  local function percent(param) return string.format("%d %%", math.floor(param:get() * 100 + 0.5)) end

  -- The group strata_tape (the menu record "tape" of lib/params_setup.lua
  -- adds it): seven params, PSET-only. The four a macro can move send
  -- through send_param_to_engine (their S.engine_senders entries below);
  -- the others call softcut from their own action, only while the tape is on
  function M.add_params()
    params:add_group("strata_tape", "tape", TAPE.param_count)
    params:add{type = "binary", behavior = "toggle", id = "tapeloop", name = "tape loop", default = 0,
      action = function(x)
        if x == 1 then start() else M.stop() end
      end}
    params:add{type = "binary", behavior = "toggle", id = "tapeloop_rec", name = "tape record", default = 1,
      action = function(x)
        if engaged then each_voice(function(v) softcut.rec_level(v, x == 1 and 1 or 0) end) end
      end}
    params:add{type = "control", id = "tapeloop_length", name = "tape length",
      controlspec = controlspec.new(TAPE.length.min, TAPE.length.max, "exp", 0, TAPE.length.default, "s"),
      action = function(x)
        if engaged then each_voice(function(v) softcut.loop_end(v, x) end) end
      end}
    params:add{type = "control", id = "tapeloop_rate", name = "tape speed",
      controlspec = controlspec.new(TAPE.rate.min, TAPE.rate.max, "lin", 0, TAPE.rate.default, "x"),
      action = function(x) send_param_to_engine("tapeloop_rate", x) end}
    params:add{type = "control", id = "tapeloop_feedback", name = "tape feedback",
      controlspec = controlspec.new(0, 1, "lin", 0, TAPE.feedback.default, "%"), formatter = percent,
      action = function(x) send_param_to_engine("tapeloop_feedback", x) end}
    params:add{type = "control", id = "tapeloop_wear", name = "tape wear",
      controlspec = controlspec.new(0, 1, "lin", 0, TAPE.wear.default, "%"), formatter = percent,
      action = function(x) send_param_to_engine("tapeloop_wear", x) end}
    params:add{type = "control", id = "tapeloop_level", name = "tape level",
      controlspec = controlspec.new(0, 1, "lin", 0, TAPE.level.default, "%"), formatter = percent,
      action = function(x) send_param_to_engine("tapeloop_level", x) end}
  end

  -- These senders call softcut and no engine command; each does nothing
  -- while the tape is off
  local function while_on(send) return function(value) if engaged then send(value) end end end
  local SENDERS = {tapeloop_level = send_level, tapeloop_rate = send_rate, tapeloop_feedback = send_feedback,
    tapeloop_wear = send_wear}
  for _, id in ipairs(TAPE.macro_targets) do
    S.engine_senders[id] = while_on(SENDERS[id])
    S.register_macro_target(id, TAPE.macro_labels[id])
  end

  -- IO's tape section: the seven params, no status
  S.register_io_section({
    name = "tape",
    title = "tape",
    rows = function()
      return {
        {label = "tape", kind = "param", param_id = "tapeloop", binary = {[0] = "off", [1] = "on"}},
        {label = "record", kind = "param", param_id = "tapeloop_rec", binary = {[0] = "off", [1] = "on"}},
        {label = "length", kind = "param", param_id = "tapeloop_length", format = "%.2f s"},
        {label = "speed", kind = "param", param_id = "tapeloop_rate", format = "%.2fx"},
        {label = "feedback", kind = "param", param_id = "tapeloop_feedback", format = "%.2f"},
        {label = "wear", kind = "param", param_id = "tapeloop_wear", format = "%.2f"},
        {label = "level", kind = "param", param_id = "tapeloop_level", format = "%.2f"},
      }
    end,
    layout_states = {
      {name = "tape off", setup = function() params:set("tapeloop", 0) end},
      {name = "tape on", setup = function() params:set("tapeloop", 1) end},
    },
  })

  -- init's start step: a tape already on (a restored param) is started;
  -- with the default, nothing
  S.register_start(S.constants.START_ORDER.io_tape, function()
    if params.lookup.tapeloop and params:get("tapeloop") == 1 then start() end
  end)

  S.register_cleanup(S.constants.CLEANUP_ORDER.io_tape, function()
    M.stop()
  end)

  return M
end

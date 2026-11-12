-- lib/voice_mix.lua
-- Each voice's own filter and effect sends, and the effects' bypass. A
-- registered voice-param record (S.register_voice_params), voice_mix:
-- v<i>_filter_type, _filter_freq, _filter_res and _filter_mix (the voice
-- filter after its grains; mix 0, the default, leaves it out) and
-- v<i>_delay_send and _reverb_send (0-1, default 1: 3.1's chain). They are
-- grain params, scene fields (the type switches at a transition's end), a
-- VOICE section "filter & sends" and LFO destinations (the cutoff and both
-- sends). Two fx params (S.register_fx_params), delay_bypass and
-- reverb_bypass, free and re-create the effect's engine node
-- (engine.setBypass); PSETs store them, scenes never do. MAIN's
-- randomize, mutation and the fader pages never touch any of them; VOICE's
-- ALT+K2 on its section draws all but the filter's mix (the record's
-- randomize, #557). 3.4 adds v<i>_mute and v<i>_solo (binary, default 0):
-- silenced(voice) is the answer, sent to the engine as the stage's voiceMute
-- (a scene stores the mute, never the solo). See docs/notes/lua/voice-mix.md.

return function(S)
  local M = {}

  -- The voice params: key, engine grain param, and the LFO labels
  M.VOICE_MIX = {
    section = "filter & sends",   -- VOICE's last section, after mix
    filter_types = {"lowpass", "highpass", "bandpass"},
    keys = {"filter_type", "filter_freq", "filter_res", "filter_mix", "delay_send", "reverb_send", "mute", "solo"},
    lfo = {{label = "vfilt", key = "filter_freq"}, {label = "dsend", key = "delay_send"},
      {label = "rsend", key = "reverb_send"},
      {label = "amp", key = "amp"}},
  }

  -- The bypass params, by effect: the param id and engine.setBypass's
  -- effect number (0 delay, 1 reverb)
  M.BYPASS = {
    delay = {param_id = "delay_bypass", name = "delay bypass", engine_effect = 0},
    reverb = {param_id = "reverb_bypass", name = "reverb bypass", engine_effect = 1},
  }
  M.BYPASS_ORDER = {"delay", "reverb"}

  -- Whether an effect ("delay", "reverb") is bypassed; the filter never is
  function M.bypassed(effect)
    local bypass = M.BYPASS[effect]
    return bypass ~= nil and params:get(bypass.param_id) == 1
  end

  -- Whether a voice is silenced: muted, or some voice is soloed and it is
  -- not. False for anything that is not a voice 1..NUM_VOICES
  function M.silenced(voice)
    local count = S.constants.NUM_VOICES
    if type(voice) ~= "number" or voice < 1 or voice > count or voice % 1 ~= 0 then return false end
    local function held(index, key)
      local voice_state = S.voices[index]
      return voice_state ~= nil and voice_state.extras ~= nil and voice_state.extras[key] == 1
    end
    if held(voice, "mute") then return true end
    if held(voice, "solo") then return false end
    for index = 1, count do
      if held(index, "solo") then return true end
    end
    return false
  end

  -- Whether a voice is soloed: its solo is on and it is not muted, so it is
  -- not silenced. False for anything that is not a voice 1..NUM_VOICES
  function M.soloed(voice)
    if type(voice) ~= "number" or voice < 1 or voice > S.constants.NUM_VOICES or voice % 1 ~= 0 then return false end
    local voice_state = S.voices[voice]
    local extras = voice_state and voice_state.extras
    return extras ~= nil and extras.solo == 1 and not M.silenced(voice)
  end

  -- What each voice's engine last got as voiceMute (1 or 0): a running
  -- voice is sent only when its answer changes. A voice's sync sets it
  local sent_mute = {}

  local function mute_value(voice_idx) return M.silenced(voice_idx) and 1 or 0 end

  -- Every running voice whose answer changed gets it; a stopped voice gets
  -- its answer with its next start's sync
  local function send_changed_mutes()
    for voice_idx = 1, S.constants.NUM_VOICES do
      if S.voices[voice_idx].active then
        local value = mute_value(voice_idx)
        if (sent_mute[voice_idx] or 0) ~= value then
          sent_mute[voice_idx] = value
          engine.setGrainParam(voice_idx - 1, "voiceMute", value)
        end
      end
    end
  end

  -- The sends are 0-1 values shown as a percent (display only)
  local function send_percent(param) return string.format("%d %%", math.floor(param:get() * 100 + 0.5)) end

  -- The params' specs (a params:add table without an id), by key
  local function voice_mix_param(key)
    if key == "mute" or key == "solo" then
      return {type = "binary", name = key, behavior = "toggle", default = 0,
        action = function()
          if update_voice_list then update_voice_list() end  -- MAIN's list marks it
          request_redraw()
          grid_redraw()  -- the grids light a silenced voice
        end}
    elseif key == "filter_type" then
      return {type = "option", name = "filter type", options = M.VOICE_MIX.filter_types, default = 1}
    elseif key == "filter_freq" then
      return {type = "control", name = "filter freq", controlspec = controlspec.new(20, 20000, "exp", 0, 5000, "Hz")}
    elseif key == "filter_res" then
      return {type = "control", name = "filter res", controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5)}
    elseif key == "filter_mix" then
      return {type = "control", name = "filter mix", controlspec = controlspec.new(0, 1, "lin", 0.01, 0)}
    elseif key == "delay_send" then
      return {type = "control", name = "delay send", controlspec = controlspec.new(0, 1, "lin", 0.01, 1),
        formatter = send_percent}
    end
    return {type = "control", name = "reverb send", controlspec = controlspec.new(0, 1, "lin", 0.01, 1),
      formatter = send_percent}
  end

  -- VOICE's layout tests and page renders: each source, the cursor on the
  -- section's first and last row, at the values that draw widest
  local function layout_state(voice_idx, source_name, source_option, edge)
    return {
      name = string.format("v%d %s filter & sends %s", voice_idx, source_name, edge),
      setup = function()
        local prefix = "v" .. voice_idx .. "_"
        S.selected_voice = voice_idx
        params:set(prefix .. "source", source_option)
        params:set(prefix .. "filter_type", #M.VOICE_MIX.filter_types)
        params:set(prefix .. "filter_freq", 20000)
        local key = edge == "first" and M.VOICE_MIX.keys[1] or M.VOICE_MIX.keys[#M.VOICE_MIX.keys]
        S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(prefix .. key))
      end,
    }
  end
  local layout_states = {}
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, source in ipairs({{"synth", S.constants.SOURCE_SYNTH}, {"buf 1", S.constants.SOURCE_SYNTH + 1},
      {"input", S.constants.SOURCE_INPUT}}) do
      for _, edge in ipairs({"first", "last"}) do
        table.insert(layout_states, layout_state(voice_idx, source[1], source[2], edge))
      end
    end
  end

  local record
  record = {
    name = "voice_mix",
    count = #M.VOICE_MIX.keys,
    add = function(voice_idx)
      for _, key in ipairs(M.VOICE_MIX.keys) do
        S.lib.params_setup.add_voice_extra(voice_idx, record, key, voice_mix_param(key))
      end
      -- mute and solo send the effective mute (not a grain key: that sends
      -- a stored value as it is) to the voices whose answer changed
      for _, key in ipairs({"mute", "solo"}) do
        S.engine_senders["v" .. voice_idx .. "_" .. key] = send_changed_mutes
      end
    end,
    -- the voice sync (the voice may not be marked running yet): the
    -- effective mute
    sync = function(voice_idx)
      sent_mute[voice_idx] = mute_value(voice_idx)
      engine.setGrainParam(voice_idx - 1, "voiceMute", sent_mute[voice_idx])
    end,
    grain_keys = {
      filter_type = {name = "filterType", value = function(option) return option - 1 end},
      filter_freq = "filterFreq",
      filter_res = "filterRes",
      filter_mix = "filterMix",
      delay_send = "delaySend",
      reverb_send = "reverbSend",
    },
    scene_defaults = {filter_type = 1, filter_freq = 5000, filter_res = 0.5, filter_mix = 0, delay_send = 1,
      reverb_send = 1, mute = 0},
    discrete = {filter_type = {1, #M.VOICE_MIX.filter_types}, mute = {0, 1}},
    voice_rows = {section = M.VOICE_MIX.section, rows = M.VOICE_MIX.keys},
    layout_states = layout_states,
    fader = false,
    -- VOICE's ALT+K2 on this section (#557): the type a uniform option, the
    -- cutoff 100-8000 Hz even in octaves (2 ^ uniform(log2 100, log2 8000)),
    -- the res below self-oscillation and the sends moderate. The filter's
    -- mix is kept: 0 would leave the filter out
    randomize = {
      filter_type = function() return math.random(#M.VOICE_MIX.filter_types) end,
      filter_freq = function() return 100 * (8000 / 100) ^ math.random() end,
      filter_res = function() return math.random() * 0.7 end,
      delay_send = function() return math.random() * 0.6 end,
      reverb_send = function() return math.random() * 0.6 end,
    },
  }
  S.register_voice_params(record)
  for _, destination in ipairs(M.VOICE_MIX.lfo) do
    S.register_lfo_destination(destination.label, destination.key)
  end

  -- The bypass params, at the end of the fx group. Each sends
  -- engine.setBypass through its engine sender; neither touches the mix
  -- (the FX page's K3 toggles them, lib/pages/fx.lua)
  S.register_fx_params({
    name = "bypass",
    count = #M.BYPASS_ORDER,
    add = function()
      for _, effect in ipairs(M.BYPASS_ORDER) do
        local bypass = M.BYPASS[effect]
        params:add{
          type = "binary",
          id = bypass.param_id,
          name = bypass.name,
          behavior = "toggle",
          default = 0,
          action = function(x) send_param_to_engine(bypass.param_id, x) end,
        }
        S.engine_senders[bypass.param_id] = function(value) engine.setBypass(bypass.engine_effect, value) end
      end
    end,
  })

  return M
end

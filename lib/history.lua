-- lib/history.lua
-- Input history: v<i>_history, how far back (seconds) an input voice's
-- grains read in the input ring, 0 to the tier's history
-- (S.performance.history_seconds: 16 s standard, 60 s high). A registered
-- voice param (S.register_voice_params): the engine's history grain param,
-- a scene field that crossfades, a VOICE row in an input voice's own
-- section and an LFO destination. MAIN's randomize, mutation and the fader
-- pages never touch it; VOICE's ALT+K2 on its section draws it (the
-- record's randomize, #557). And (3.8, package 1d) v<i>_input_channel,
-- which of the input's channels an input voice reads: stereo, left or
-- right, the engine's handler-only inputChannel grain param, a discrete
-- scene key and a VOICE row after history. See docs/notes/lua/history.md.

return function(S)
  local M = {}

  -- The record's names: the param key (v<i>_history), its engine grain
  -- param, its LFO label ("v<i> hist") and VOICE section
  M.HISTORY = {key = "history", engine_name = "history", lfo_label = "hist", section = "input", before = "grain",
    -- 3.8: the input channel's param key, its options (sent as index - 1)
    -- and its engine grain param
    channel_key = "input_channel", channels = {"stereo", "left", "right"}, channel_engine_name = "inputChannel"}

  -- The history range's top for the tier the engine runs (seconds)
  function M.max_seconds()
    return S.performance.history_seconds
  end

  -- Whether voice voice_idx reads the live input (history and the channel
  -- are for it only; a voice source has neither)
  function M.uses_input(voice_idx)
    return S.voices[voice_idx] ~= nil and voice_uses_input(voice_idx)
  end

  -- VOICE's layout tests and page renders: every voice on the input, its
  -- cursor on the history row at the range's top
  local layout_states = {}
  for voice_idx = 1, S.constants.NUM_VOICES do
    table.insert(layout_states, {
      name = string.format("v%d input history", voice_idx),
      setup = function()
        local param_id = "v" .. voice_idx .. "_" .. M.HISTORY.key
        S.selected_voice = voice_idx
        params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_INPUT)
        params:set(param_id, M.max_seconds())
        S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(param_id))
      end,
    })
    -- 3.8: the cursor on the channel row, at its widest option
    table.insert(layout_states, {
      name = string.format("v%d input channel", voice_idx),
      setup = function()
        local param_id = "v" .. voice_idx .. "_" .. M.HISTORY.channel_key
        S.selected_voice = voice_idx
        params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_INPUT)
        params:set(param_id, 1)
        S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(param_id))
      end,
    })
  end

  local record
  record = {
    name = "history",
    count = 2,
    -- Read at init, after the performance setting has filled S.performance,
    -- so the range is the running tier's: a value saved on a longer tier
    -- (a PSET or scene) clamps to it when set. Then the input channel
    add = function(voice_idx)
      S.lib.params_setup.add_voice_param(voice_idx, record, M.HISTORY.key, {
        type = "control",
        name = "history",
        controlspec = controlspec.new(0, M.max_seconds(), "lin", 0, 0, "s"),
      })
      S.lib.params_setup.add_voice_param(voice_idx, record, M.HISTORY.channel_key, {
        type = "option",
        name = "input channel",
        options = M.HISTORY.channels,
        default = 1,
      })
    end,
    grain_keys = {
      [M.HISTORY.key] = M.HISTORY.engine_name,
      [M.HISTORY.channel_key] = {name = M.HISTORY.channel_engine_name, value = function(x) return x - 1 end, carry = false},
    },
    scene_defaults = {[M.HISTORY.key] = 0, [M.HISTORY.channel_key] = 1},
    discrete = {[M.HISTORY.channel_key] = {1, #M.HISTORY.channels}},
    voice_rows = {
      section = M.HISTORY.section,
      rows = {M.HISTORY.key, M.HISTORY.channel_key},
      before = M.HISTORY.before,
      when = function(voice_idx) return M.uses_input(voice_idx) end,
    },
    layout_states = layout_states,
    fader = false,
    -- VOICE's ALT+K2 on the input section (#557): uniform from 0 to the
    -- param's top, the tier's history when the params were added
    randomize = {
      [M.HISTORY.key] = function(voice_idx)
        return math.random() * params:lookup_param("v" .. voice_idx .. "_" .. M.HISTORY.key).controlspec.maxval
      end,
    },
  }
  S.register_voice_params(record)
  S.register_lfo_destination(M.HISTORY.lfo_label, M.HISTORY.key)

  return M
end

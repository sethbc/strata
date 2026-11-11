-- lib/history.lua
-- Input history: v<i>_history, how far back (seconds) an input voice's
-- grains read in the input ring, 0 to the tier's history
-- (S.performance.history_seconds: 16 s standard, 60 s high). A registered
-- voice param (S.register_voice_params): the engine's history grain param,
-- a scene field that crossfades, a VOICE row in an input voice's own
-- section and an LFO destination. MAIN's randomize, mutation and the fader
-- pages never touch it; VOICE's ALT+K2 on its section draws it (the
-- record's randomize, #557). See docs/notes/lua/history.md.

return function(S)
  local M = {}

  -- The record's names: the param key (v<i>_history), its engine grain
  -- param, its LFO label ("v<i> hist") and VOICE section
  M.HISTORY = {key = "history", engine_name = "history", lfo_label = "hist", section = "input", before = "grain"}

  -- The history range's top for the tier the engine runs (seconds)
  function M.max_seconds()
    return S.performance.history_seconds
  end

  -- Whether voice voice_idx reads the live input (history is for it only)
  function M.uses_input(voice_idx)
    local voice = S.voices[voice_idx]
    return voice ~= nil and voice.source == S.constants.SOURCE_INPUT
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
  end

  local record
  record = {
    name = "history",
    count = 1,
    -- Read at init, after the performance setting has filled S.performance,
    -- so the range is the running tier's: a value saved on a longer tier
    -- (a PSET or scene) clamps to it when set
    add = function(voice_idx)
      S.lib.params_setup.add_voice_extra(voice_idx, record, M.HISTORY.key, {
        type = "control",
        name = "history",
        controlspec = controlspec.new(0, M.max_seconds(), "lin", 0, 0, "s"),
      })
    end,
    grain_keys = {[M.HISTORY.key] = M.HISTORY.engine_name},
    scene_defaults = {[M.HISTORY.key] = 0},
    voice_rows = {
      section = M.HISTORY.section,
      rows = {M.HISTORY.key},
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

-- lib/freeze.lua
-- Freeze: v<i>_freeze holds what a voice's grains read (its ring, the last
-- 4 s of the input, or a buffer's scan), and v<i>_freeze_mode picks hold or,
-- on the high tier only, spectral. A registered voice param
-- (S.register_voice_params): the engine's freeze and freezeMode grain
-- params, two discrete scene fields, rows in VOICE's mix section, keys on
-- the grid layouts and [F] on MAIN's status row. A source switch unfreezes
-- (a source_change hook). Randomize, mutation and the fader pages never
-- touch either. Not the lock: that is toggle_lock and its own state. See
-- docs/notes/lua/freeze.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- The record's names: the param keys (v<i>_freeze, v<i>_freeze_mode), their
  -- engine grain params and VOICE section, and the modes (high offers both,
  -- standard the first only)
  M.FREEZE = {
    key = "freeze", mode_key = "freeze_mode", engine_name = "freeze", mode_engine_name = "freezeMode",
    section = "mix", modes = {"hold", "spectral"},
  }

  local function valid_voice(voice_idx)
    return type(voice_idx) == "number" and voice_idx >= 1 and voice_idx <= NUM_VOICES and voice_idx % 1 == 0
  end

  local function param_id(voice_idx, key)
    return "v" .. voice_idx .. "_" .. key
  end

  -- Whether the tier the engine runs offers the spectral mode
  function M.spectral_offered()
    return S.performance.tier == "high"
  end

  -- The mode options for the running tier: a PSET or scene saved on high
  -- (spectral, 2) clamps to hold on standard when set
  function M.mode_options()
    if M.spectral_offered() then return M.FREEZE.modes end
    return {M.FREEZE.modes[1]}
  end

  -- Whether voice voice_idx is frozen (false for any other value)
  function M.is_frozen(voice_idx)
    if not valid_voice(voice_idx) then return false end
    local extras = S.voices[voice_idx].extras
    return extras ~= nil and extras[M.FREEZE.key] == 1
  end

  -- Freeze or unfreeze voice voice_idx (ignored for any other value)
  function M.toggle(voice_idx)
    if not valid_voice(voice_idx) then return end
    params:set(param_id(voice_idx, M.FREEZE.key), M.is_frozen(voice_idx) and 0 or 1)
  end

  -- VOICE's layout tests and page renders: every voice frozen, its cursor
  -- on the freeze row
  local layout_states = {}
  for voice_idx = 1, NUM_VOICES do
    table.insert(layout_states, {
      name = string.format("v%d frozen", voice_idx),
      setup = function()
        local id = param_id(voice_idx, M.FREEZE.key)
        S.selected_voice = voice_idx
        params:set(id, 1)
        S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(id))
      end,
    })
  end

  local record
  record = {
    name = "freeze",
    count = 2,
    -- Read at init, after the performance setting has filled S.performance,
    -- so the mode's options are the running tier's
    add = function(voice_idx)
      S.lib.params_setup.add_voice_extra(voice_idx, record, M.FREEZE.key, {
        type = "binary",
        name = "freeze",
        behavior = "toggle",
        default = 0,
        -- MAIN's [F] (the param actions request a redraw) and the grid's keys
        action = function() grid_redraw() end,
      })
      S.lib.params_setup.add_voice_extra(voice_idx, record, M.FREEZE.mode_key, {
        type = "option",
        name = "freeze mode",
        options = M.mode_options(),
        default = 1,
      })
    end,
    grain_keys = {
      [M.FREEZE.key] = M.FREEZE.engine_name,
      [M.FREEZE.mode_key] = {name = M.FREEZE.mode_engine_name, value = function(option) return option - 1 end},
    },
    scene_defaults = {[M.FREEZE.key] = 0, [M.FREEZE.mode_key] = 1},
    discrete = {[M.FREEZE.key] = {0, 1}, [M.FREEZE.mode_key] = {1, #M.FREEZE.modes}},
    voice_rows = {
      section = M.FREEZE.section,
      rows = {M.FREEZE.key, M.FREEZE.mode_key},
      when = function(_, key) return key ~= M.FREEZE.mode_key or M.spectral_offered() end,
    },
    layout_states = layout_states,
    fader = false,
  }
  S.register_voice_params(record)

  -- A source switch unfreezes: the frozen ring, input copy or scan belongs
  -- to the old source. (A scene recall sets the scene's freeze itself, after
  -- the source, and runs no hooks)
  S.register_source_change(function(voice_idx)
    if M.is_frozen(voice_idx) then params:set(param_id(voice_idx, M.FREEZE.key), 0) end
  end)

  return M
end

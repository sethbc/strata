-- lib/grain.lua
-- The grain's controls (3.8, design §4.1, §4.2, §4.4, §4.5): per voice the
-- window's shape and skew (v<i>_grain_shape, v<i>_grain_skew: the
-- engine's window bank, picked per grain), the grains' probability
-- (v<i>_grain_prob), the cloud mode and its overlap (v<i>_grain_cloud,
-- v<i>_grain_overlap: constant overlap as the size moves) and the pan
-- wander (v<i>_pan_wander, the grain synth's panSpread). One registered
-- voice-param record (S.register_voice_params), "grain_controls" ("grain"
-- is the built-in record's name): six grain params a start sends before
-- voiceOn, scene keys (the cloud discrete), VOICE rows in the grain
-- section (the overlap in the density's row while the cloud is overlap:
-- voice_rows.swaps), and the shape and skew as LFO, matrix and macro
-- destinations. It draws nothing and has no fader group: shape and skew
-- sit in the built-in grain record's (ruling 31). Master density reaches
-- the overlap by Lua (ruling 35): grainOverlap goes out times it. See
-- docs/notes/lua/grain.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- The record's names, ranges and defaults (the task's, verbatim)
  M.GRAIN = {
    name = "grain_controls",
    section = "grain",
    keys = {"grain_shape", "grain_skew", "grain_prob", "grain_cloud", "grain_overlap", "pan_wander"},
    -- VOICE's rows, after the built-in grain record's (the overlap swaps in
    -- for the density instead)
    rows = {"grain_shape", "grain_skew", "grain_prob", "grain_cloud", "pan_wander"},
    clouds = {"density", "overlap"},
    cloud_index = {density = 1, overlap = 2},
    percent = 100,
    -- the default shape is the table GrainBuf's own Hann stands in for:
    -- 0.57 x 7 rounds to shape 4 (the engine's windowHannShape)
    shape = {min = 0, max = 1, step = 0.01, default = 0.57},
    skew = {min = -1, max = 1, step = 0.01, default = 0},
    prob_default = 100,
    overlap = {min = 0.25, max = 16, default = 2},
    wander_default = 50,
    lfo = {{label = "shape", key = "grain_shape"}, {label = "skew", key = "grain_skew"}},
  }
  local GRAIN = M.GRAIN

  -- Whether voice voice_idx's cloud is the overlap (false before init)
  function M.overlap(voice_idx)
    local voice = type(voice_idx) == "number" and S.voices[voice_idx]
    if not voice then return false end
    return voice.values.grain_cloud == GRAIN.cloud_index.overlap
  end

  local function percent_of(x) return x / GRAIN.percent end

  -- The params' texts: the shape and skew to two places, the percentages
  -- whole, the overlap a factor
  M.FORMATS = {grain_shape = "%.2f", grain_skew = "%.2f", grain_prob = "%.0f %%", grain_overlap = "%.2f x",
    pan_wander = "%.0f %%"}
  function M.text(key, value) return string.format(M.FORMATS[key], value) end
  local function formatter(key) return function(param) return M.text(key, param:get()) end end
  local function add_param(...) S.lib.params_setup.add_voice_param(...) end

  -- VOICE's layout tests and page renders: each voice with every new row
  -- at the low end of its range, then at the high end, the cursor on each
  -- row in turn (the overlap's row in overlap mode)
  local layout_states = {}
  local ENDS = {
    {name = "low", grain_shape = GRAIN.shape.min, grain_skew = GRAIN.skew.min, grain_prob = 0,
      grain_overlap = GRAIN.overlap.min, pan_wander = 0},
    {name = "high", grain_shape = GRAIN.shape.max, grain_skew = GRAIN.skew.max, grain_prob = GRAIN.percent,
      grain_overlap = GRAIN.overlap.max, pan_wander = GRAIN.percent},
  }
  for voice_idx = 1, NUM_VOICES do
    for _, ends in ipairs(ENDS) do
      for _, cursor_key in ipairs(GRAIN.keys) do
        table.insert(layout_states, {
          name = string.format("v%d grain %s at %s", voice_idx, cursor_key, ends.name),
          setup = function()
            local prefix = "v" .. voice_idx .. "_"
            S.selected_voice = voice_idx
            for key, value in pairs(ends) do
              if key ~= "name" then params:set(prefix .. key, value) end
            end
            params:set(prefix .. "grain_cloud", GRAIN.cloud_index.overlap)
            S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(prefix .. cursor_key))
          end,
        })
      end
    end
  end

  local record
  record = {
    name = GRAIN.name,
    count = #GRAIN.keys,
    add = function(voice_idx)
      add_param(voice_idx, record, "grain_shape", {type = "control", name = "grain shape",
        controlspec = controlspec.new(GRAIN.shape.min, GRAIN.shape.max, "lin", GRAIN.shape.step, GRAIN.shape.default),
        formatter = formatter("grain_shape")})
      add_param(voice_idx, record, "grain_skew", {type = "control", name = "grain skew",
        controlspec = controlspec.new(GRAIN.skew.min, GRAIN.skew.max, "lin", GRAIN.skew.step, GRAIN.skew.default),
        formatter = formatter("grain_skew")})
      add_param(voice_idx, record, "grain_prob", {type = "control", name = "grain prob",
        controlspec = controlspec.new(0, GRAIN.percent, "lin", 1, GRAIN.prob_default, "%"),
        formatter = formatter("grain_prob")})
      -- the switch resends the rate the engine now plays, with master
      -- density on it (the master density's sender sends only the mode's)
      add_param(voice_idx, record, "grain_cloud", {type = "option", name = "grain cloud",
        options = GRAIN.clouds, default = GRAIN.cloud_index.density,
        action = function()
          if not S.voices[voice_idx].active then return end
          local id = "v" .. voice_idx .. "_" .. (M.overlap(voice_idx) and "grain_overlap" or "grain_density")
          send_param_to_engine(id, params:get(id))
        end})
      add_param(voice_idx, record, "grain_overlap", {type = "control", name = "grain overlap",
        controlspec = controlspec.new(GRAIN.overlap.min, GRAIN.overlap.max, "exp", 0, GRAIN.overlap.default, "x"),
        formatter = formatter("grain_overlap")})
      add_param(voice_idx, record, "pan_wander", {type = "control", name = "pan wander",
        controlspec = controlspec.new(0, GRAIN.percent, "lin", 1, GRAIN.wander_default, "%"),
        formatter = formatter("pan_wander")})
    end,
    grain_keys = {
      grain_shape = "windowShape",
      grain_skew = "windowSkew",
      grain_prob = {name = "grainProb", value = percent_of},
      grain_cloud = {name = "overlapOn", value = function(x) return x - 1 end, carry = false},
      grain_overlap = {name = "grainOverlap", value = function(x) return x * engine_param_value("master_density") end},
      pan_wander = {name = "panSpread", value = percent_of},
    },
    send_order = GRAIN.keys,
    scene_defaults = {
      grain_shape = GRAIN.shape.default, grain_skew = GRAIN.skew.default, grain_prob = GRAIN.prob_default,
      grain_cloud = GRAIN.cloud_index.density, grain_overlap = GRAIN.overlap.default, pan_wander = GRAIN.wander_default,
    },
    discrete = {grain_cloud = {GRAIN.cloud_index.density, GRAIN.cloud_index.overlap}},
    scene_ranges = {
      grain_shape = {GRAIN.shape.min, GRAIN.shape.max}, grain_skew = {GRAIN.skew.min, GRAIN.skew.max},
      grain_prob = {0, GRAIN.percent}, grain_overlap = {GRAIN.overlap.min, GRAIN.overlap.max},
      pan_wander = {0, GRAIN.percent},
    },
    voice_rows = {
      section = GRAIN.section,
      rows = GRAIN.rows,
      -- ruling 36: in overlap mode the density's row shows the overlap
      swaps = {grain_density = function(voice_idx) if M.overlap(voice_idx) then return "grain_overlap" end end},
    },
    layout_states = layout_states,
    fader = false,
  }
  S.register_voice_params(record)
  for _, destination in ipairs(GRAIN.lfo) do S.register_lfo_destination(destination.label, destination.key) end

  return M
end

-- lib/voices.lua
-- The voices: their definitions (S.voices, built fresh by each script load),
-- which voices are locked (S.locked), the master density, the selected voice,
-- and the global helpers that test a voice's grain source. strata.lua runs
-- `S.lib.voices = include("lib/voices")(S)`; the constructor sets its S
-- fields itself, and its table (S.lib.voices) holds is_synth_key(voice_idx,
-- key). A voice is {name, active, source, param_order, values}: values holds
-- every value of the voice by key, its param id without "v<i>_".

return function(S)
  local M = {}

  local NUM_VOICES = S.constants.NUM_VOICES
  local SOURCE_SYNTH = S.constants.SOURCE_SYNTH
  local SOURCE_INPUT = S.constants.SOURCE_INPUT
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS

  -- State
  S.voices = {
    {
      name = "resonator",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "rq", "noise", "mod1", "mod2", "amp", "pan"},  -- display / grid order of params
      -- every value of the voice, by key (its param id without v<i>_): the
      -- synth params (param_order's keys), the grain and buffer params and
      -- crossmod; lib/params_setup.lua adds each registered record's
      values = {
        freq = 100,
        amp = 0.3,
        pan = 0,
        rq = 0.1,
        noise = 0.5,
        mod1 = 0.1,
        mod2 = 0.15,
        grain_size = 0.1,
        grain_density = 20,
        grain_pitch = 1,
        grain_spread = 0.5,
        grain_env = 1,  -- GRAIN_ENV_OPTIONS index
        grain_mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0,
        mod_source_1 = 0, mod_amp_amt_1 = 0, mod_freq_amt_1 = 0,  -- a source: 0 = none, 1-7 = voice number
        mod_source_2 = 0, mod_amp_amt_2 = 0, mod_freq_amt_2 = 0,
        mod_source_3 = 0, mod_amp_amt_3 = 0, mod_freq_amt_3 = 0,
        mod_speed = 10
      }
    },
    {
      name = "fm",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "ratio", "index", "modFreq", "amp", "pan"},  -- display / grid order of params
      -- every value of the voice, by key (its param id without v<i>_): the
      -- synth params (param_order's keys), the grain and buffer params and
      -- crossmod; lib/params_setup.lua adds each registered record's
      values = {
        freq = 80,
        amp = 0.25,
        pan = 0,
        ratio = 1.5,
        index = 2,
        modFreq = 0.05,
        grain_size = 0.15,
        grain_density = 15,
        grain_pitch = 1,
        grain_spread = 0.3,
        grain_env = 1,  -- GRAIN_ENV_OPTIONS index
        grain_mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0,
        mod_source_1 = 0, mod_amp_amt_1 = 0, mod_freq_amt_1 = 0,  -- a source: 0 = none, 1-7 = voice number
        mod_source_2 = 0, mod_amp_amt_2 = 0, mod_freq_amt_2 = 0,
        mod_source_3 = 0, mod_amp_amt_3 = 0, mod_freq_amt_3 = 0,
        mod_speed = 10
      }
    },
    {
      name = "folder",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "fold", "mod", "amp", "pan"},  -- display / grid order of params
      -- every value of the voice, by key (its param id without v<i>_): the
      -- synth params (param_order's keys), the grain and buffer params and
      -- crossmod; lib/params_setup.lua adds each registered record's
      values = {
        freq = 60,
        amp = 0.3,
        pan = 0,
        fold = 1,
        mod = 0.2,
        grain_size = 0.08,
        grain_density = 25,
        grain_pitch = 1,
        grain_spread = 0.4,
        grain_env = 1,  -- GRAIN_ENV_OPTIONS index
        grain_mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0,
        mod_source_1 = 0, mod_amp_amt_1 = 0, mod_freq_amt_1 = 0,  -- a source: 0 = none, 1-7 = voice number
        mod_source_2 = 0, mod_amp_amt_2 = 0, mod_freq_amt_2 = 0,
        mod_source_3 = 0, mod_amp_amt_3 = 0, mod_freq_amt_3 = 0,
        mod_speed = 10
      }
    },
    {
      name = "sub",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "drift", "amp"},  -- display / grid order of params
      -- every value of the voice, by key (its param id without v<i>_): the
      -- synth params (param_order's keys), the grain and buffer params and
      -- crossmod; lib/params_setup.lua adds each registered record's
      values = {
        freq = 40,
        amp = 0.4,
        drift = 0.02,
        grain_size = 0.2,
        grain_density = 10,
        grain_pitch = 1,
        grain_spread = 0.2,
        grain_env = 1,  -- GRAIN_ENV_OPTIONS index
        grain_mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0,
        mod_source_1 = 0, mod_amp_amt_1 = 0, mod_freq_amt_1 = 0,  -- a source: 0 = none, 1-7 = voice number
        mod_source_2 = 0, mod_amp_amt_2 = 0, mod_freq_amt_2 = 0,
        mod_source_3 = 0, mod_amp_amt_3 = 0, mod_freq_amt_3 = 0,
        mod_speed = 10
      }
    },
    {
      name = "pulse",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "width", "cutoff", "res", "amp", "pan"},  -- display / grid order of params
      -- every value of the voice, by key (its param id without v<i>_): the
      -- synth params (param_order's keys), the grain and buffer params and
      -- crossmod; lib/params_setup.lua adds each registered record's
      values = {
        freq = 120,
        amp = 0.3,
        pan = 0,
        width = 0.5,
        cutoff = 2000,
        res = 0.8,  -- rises with resonance: 0.8 is the filter's rq 0.3, 3.2's default 0.3 (#314)
        grain_size = 0.12,
        grain_density = 18,
        grain_pitch = 1,
        grain_spread = 0.35,
        grain_env = 1,  -- GRAIN_ENV_OPTIONS index
        grain_mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0,
        mod_source_1 = 0, mod_amp_amt_1 = 0, mod_freq_amt_1 = 0,  -- a source: 0 = none, 1-7 = voice number
        mod_source_2 = 0, mod_amp_amt_2 = 0, mod_freq_amt_2 = 0,
        mod_source_3 = 0, mod_amp_amt_3 = 0, mod_freq_amt_3 = 0,
        mod_speed = 10
      }
    },
    {
      name = "karplus",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "decay", "damping", "excite", "amp", "pan"},  -- display / grid order of params
      -- every value of the voice, by key (its param id without v<i>_): the
      -- synth params (param_order's keys), the grain and buffer params and
      -- crossmod; lib/params_setup.lua adds each registered record's
      values = {
        freq = 200,
        amp = 0.35,
        pan = 0,
        decay = 4,
        damping = 0.5,
        excite = 0.3,
        grain_size = 0.08,
        grain_density = 22,
        grain_pitch = 1,
        grain_spread = 0.25,
        grain_env = 1,  -- GRAIN_ENV_OPTIONS index
        grain_mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0,
        mod_source_1 = 0, mod_amp_amt_1 = 0, mod_freq_amt_1 = 0,  -- a source: 0 = none, 1-7 = voice number
        mod_source_2 = 0, mod_amp_amt_2 = 0, mod_freq_amt_2 = 0,
        mod_source_3 = 0, mod_amp_amt_3 = 0, mod_freq_amt_3 = 0,
        mod_speed = 10
      }
    },
    {
      name = "ring",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "ratio", "mod", "brightness", "amp", "pan"},  -- display / grid order of params
      -- every value of the voice, by key (its param id without v<i>_): the
      -- synth params (param_order's keys), the grain and buffer params and
      -- crossmod; lib/params_setup.lua adds each registered record's
      values = {
        freq = 300,
        amp = 0.25,
        pan = 0,
        ratio = 1.618,
        mod = 0.2,
        brightness = 0.5,
        grain_size = 0.1,
        grain_density = 20,
        grain_pitch = 1,
        grain_spread = 0.4,
        grain_env = 1,  -- GRAIN_ENV_OPTIONS index
        grain_mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0,
        mod_source_1 = 0, mod_amp_amt_1 = 0, mod_freq_amt_1 = 0,  -- a source: 0 = none, 1-7 = voice number
        mod_source_2 = 0, mod_amp_amt_2 = 0, mod_freq_amt_2 = 0,
        mod_source_3 = 0, mod_amp_amt_3 = 0, mod_freq_amt_3 = 0,
        mod_speed = 10
      }
    }
  }

  -- A voice's grain source: its synth, a buffer slot, or the live input
  function voice_uses_synth(voice_idx)
    return S.voices[voice_idx].source == SOURCE_SYNTH
  end

  function voice_uses_buffer(voice_idx)
    local source = S.voices[voice_idx].source
    return source > SOURCE_SYNTH and source < SOURCE_INPUT
  end

  function voice_source_label(voice_idx)
    return SOURCE_OPTIONS[S.voices[voice_idx].source]
  end

  -- The buffer slot (1..NUM_BUFFERS) a buffer-sourced voice reads, or nil for
  -- the synth and input sources
  function voice_buffer_slot(voice_idx)
    if not voice_uses_buffer(voice_idx) then return nil end
    return S.voices[voice_idx].source - SOURCE_SYNTH
  end

  S.selected_voice = 1
  S.locked = {}
  for i = 1, NUM_VOICES do
    S.locked[i] = false
  end

  -- Whether key is one of voice voice_idx's synth params (its param_order;
  -- false for a number that is no voice). A synth-key test goes through
  -- it, never values[key] ~= nil: a voice's values hold every key of its
  -- params, the grain, crossmod and registered ones too
  function M.is_synth_key(voice_idx, key)
    local voice = type(voice_idx) == "number" and S.voices[voice_idx]
    if not voice then return false end
    for _, synth_key in ipairs(voice.param_order) do
      if synth_key == key then return true end
    end
    return false
  end

  -- The built-in per-voice params (the groundwork before 3.8, rulings 10
  -- to 15): three S.register_voice_params records, registered here, the
  -- first module that can, so they come first in the menu, the sends, the
  -- scene keys and the faders. Their adds run at init, through
  -- S.lib.params_setup.add_voice_param; get_param_spec, fader_page_count,
  -- voice_level_fader_keys and sync_voice_values_to_engine are globals of
  -- later modules, called only then
  do
    local NUM_MOD_SLOTS = S.constants.NUM_MOD_SLOTS
    local GRAIN_ENV_OPTIONS = S.constants.GRAIN_ENV_OPTIONS
    local GRAIN_MODE_OPTIONS = S.constants.GRAIN_MODE_OPTIONS
    local function add_param(...) S.lib.params_setup.add_voice_param(...) end
    local function option_index(x) return x - 1 end
    local function uses_synth(voice_idx) return voice_uses_synth(voice_idx) end
    local function uses_buffer(voice_idx) return voice_uses_buffer(voice_idx) end
    local function uses_input(voice_idx) return not voice_uses_synth(voice_idx) and not voice_uses_buffer(voice_idx) end
    -- a voice's synth keys but those listed in `except`
    local function synth_keys_but(except)
      return function(voice_idx)
        local keys = {}
        for _, key in ipairs(S.voices[voice_idx].param_order) do
          if not except[key] then keys[#keys + 1] = key end
        end
        return keys
      end
    end

    -- Synthesis params whose step is finer than the default string's 0.01
    -- show three decimals, so every encoder detent changes the text (#386)
    local SYNTH_FORMATS = {
      drift = function(param) return string.format("%.3f", param:get()) end,
      ratio = function(param) return string.format("%.3f", param:get()) end,
    }

    -- The voice's own synth params (its param_order), under the voice's
    -- heading: a control each with its get_param_spec spec and the voices
    -- table's default, sent with setVoiceParam under its own name. MAIN's
    -- randomize draws all but amp (uniform in the normalized range), the
    -- mutations move all but amp and pan, and the faders show them all, on
    -- a synth source only. A filtered key's own delta (the PARAMS menu's
    -- E3) is a turn (turn_on_own_delta, #318; this record's keys only)
    local synth_record
    synth_record = {
      name = "synth",
      count = function(voice_idx) return #S.voices[voice_idx].param_order end,
      separator = false,
      add = function(voice_idx)
        local voice = S.voices[voice_idx]
        for _, key in ipairs(voice.param_order) do
          local spec = get_param_spec(key)
          spec.default = voice.values[key]  -- the voices table holds each voice's defaults
          add_param(voice_idx, synth_record, key, {type = "control", name = key, controlspec = spec,
            formatter = SYNTH_FORMATS[key]})
          S.lib.params_setup.turn_on_own_delta(key, "v" .. voice_idx .. "_" .. key)
        end
      end,
      voice_keys = function(voice_idx)
        local keys = {}
        for _, key in ipairs(S.voices[voice_idx].param_order) do keys[key] = key end
        return keys
      end,
      fader = {{keys = function(voice_idx) return S.voices[voice_idx].param_order end, when = uses_synth}},
      main_randomize = {{keys = synth_keys_but({amp = true}), when = uses_synth,
        draw = function(_, _, param_id) return params:lookup_param(param_id).controlspec:map(math.random()) end}},
      mutate = {{keys = synth_keys_but({amp = true, pan = true}), when = uses_synth, warped = true}},
    }

    -- The source (an option: always sent, so the engine knows it before
    -- the voice starts; it is a voice field, no value) and the nine grain
    -- and buffer params, under "granular", sent with setGrainParam in their
    -- fixed order. The envelope and mode are option indexes (discrete,
    -- sent as index - 1, no start value). MAIN's randomize draws the buffer
    -- params on a buffer source, then grain size and pitch; the mutations
    -- move the buffer params on a buffer source, then grain size, pitch
    -- and spread. The faders: a buffer source's buffer params, level and
    -- pan, then the six grain params, then an input source's level and pan
    local BUFFER_DRAWS = {
      buf_pos = function() return math.random() end,
      buf_rate = function() return 2 ^ (math.random() * 2 - 1) end,  -- 0.5-2, even in octaves
      buf_scan = function() return math.random() - 0.5 end,          -- a gentle scan
    }
    local GRAIN_DRAWS = {
      grain_size = function() return math.random() * 0.3 + 0.05 end,
      grain_pitch = function() return math.random() * 2 + 0.5 end,
    }
    local function drawn_by(draws) return function(_, key) return draws[key]() end end
    local function buffer_and_level_keys(voice_idx)
      local keys = {"buf_pos", "buf_rate", "buf_scan"}
      for _, key in ipairs(voice_level_fader_keys(voice_idx)) do keys[#keys + 1] = key end
      return keys
    end
    local grain_record
    grain_record = {
      name = "grain",
      count = 10,
      separator = "granular",
      add = function(voice_idx)
        local voice = S.voices[voice_idx]
        local values = voice.values
        params:add{
          type = "option",
          id = "v" .. voice_idx .. "_source",
          name = "source",
          options = SOURCE_OPTIONS,
          default = voice.source,
          action = function(x)
            S.voices[voice_idx].source = x
            S.lib.engine_sync.send_grain_source(voice_idx)
            -- the registered hooks (S.registry.source_change), before the
            -- sync, so it sends what they set (freeze cleared, never the old
            -- freeze first); a scene recall sets every value itself, so they
            -- never run during one
            if not S.scene_recall_in_progress then
              for _, hook in ipairs(S.registry.source_change) do hook(voice_idx, x) end
            end
            -- a scene recall syncs once, after it has set every param
            if S.voices[voice_idx].active and not S.scene_recall_in_progress then
              sync_voice_values_to_engine(voice_idx)
            end
            -- the grid fader list follows the source (buffer or synth params)
            if S.grid_voice_select == voice_idx then
              S.param_page = util.clamp(S.param_page, 1, fader_page_count(voice_idx))
            end
            grid_redraw()
          end
        }
        -- step 0: the drift moves in steps far smaller than 0.01
        add_param(voice_idx, grain_record, "buf_pos", {type = "control", name = "buffer position",
          controlspec = controlspec.new(0, 1, "lin", 0, values.buf_pos),
          action = function(x) if not S.drift_writing then S.buf_pos_base[voice_idx] = x end end})
        -- step 0 (#679): the own note of a MIDI or sequenced note plays the
        -- exact rate, as its chord's extra notes do; a turn's size is the
        -- quantum (0.01 of the range), never the step
        add_param(voice_idx, grain_record, "buf_rate", {type = "control", name = "buffer rate",
          controlspec = controlspec.new(0.25, 4, "exp", 0, values.buf_rate)})
        add_param(voice_idx, grain_record, "buf_scan", {type = "control", name = "buffer scan",
          controlspec = controlspec.new(-2, 2, "lin", 0.01, values.buf_scan)})
        add_param(voice_idx, grain_record, "grain_size", {type = "control", name = "grain size",
          controlspec = controlspec.new(0.01, 0.5, "lin", 0.01, values.grain_size, "s")})
        add_param(voice_idx, grain_record, "grain_density", {type = "control", name = "grain density",
          controlspec = controlspec.new(1, 100, "lin", 1, values.grain_density, "/s")})
        -- step 0: the drift moves in steps far smaller than 0.01
        add_param(voice_idx, grain_record, "grain_pitch", {type = "control", name = "grain pitch",
          controlspec = controlspec.new(0.25, 4, "lin", 0, values.grain_pitch, "x"),
          action = function(x) if not S.drift_writing then S.grain_pitch_base[voice_idx] = x end end})
        add_param(voice_idx, grain_record, "grain_spread", {type = "control", name = "position spread",
          controlspec = controlspec.new(0, 1, "lin", 0.01, values.grain_spread)})
        add_param(voice_idx, grain_record, "grain_env", {type = "option", name = "grain envelope",
          options = GRAIN_ENV_OPTIONS, default = values.grain_env})
        add_param(voice_idx, grain_record, "grain_mode", {type = "option", name = "grain mode",
          options = GRAIN_MODE_OPTIONS, default = values.grain_mode})
      end,
      grain_keys = {
        grain_size = "grainSize",
        grain_density = {name = "grainDensity", value = function(x) return x * engine_param_value("master_density") end},
        grain_pitch = "pitchShift",
        grain_spread = "posSpread",
        grain_env = {name = "envShape", value = option_index, carry = false},
        grain_mode = {name = "grainMode", value = option_index, carry = false},
        buf_pos = "bufPos",
        buf_rate = "bufRate",
        buf_scan = "bufScan",
      },
      send_order = {"grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_env", "grain_mode",
        "buf_pos", "buf_rate", "buf_scan"},
      discrete = {grain_env = {1, #GRAIN_ENV_OPTIONS}, grain_mode = {1, #GRAIN_MODE_OPTIONS}},
      fader = {
        {keys = buffer_and_level_keys, when = uses_buffer},
        {keys = {"grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_env", "grain_mode"}},
        {keys = function(voice_idx) return voice_level_fader_keys(voice_idx) end, when = uses_input},
      },
      main_randomize = {
        {keys = {"buf_pos", "buf_rate", "buf_scan"}, when = uses_buffer, draw = drawn_by(BUFFER_DRAWS)},
        {keys = {"grain_size", "grain_pitch"}, draw = drawn_by(GRAIN_DRAWS)},
      },
      mutate = {
        {keys = {"buf_pos", "buf_rate", "buf_scan"}, when = uses_buffer, warped = true},
        {keys = {"grain_size"}, chance = 0.5, scale = 0.2, warped = false},
        {keys = {"grain_pitch"}, chance = 0.3, scale = 1.0, warped = false},
        {keys = {"grain_spread"}, chance = 0.2, scale = 0.3, warped = false},
      },
    }

    -- Cross-modulation: per slot (1..NUM_MOD_SLOTS) its source (a number,
    -- 0 = none, 1-7 a voice; discrete), amp mod and freq mod, in that order
    -- (the ids, names and menu order saved PSETs hold), then the speed, all
    -- sent after voiceOn with their own commands and no start value. The
    -- faders show the nine slot values
    local function mod_source_text(param)
      if param:get() == 0 then return "none" end
      return "voice " .. param:get()
    end
    local crossmod_keys, crossmod_order, crossmod_discrete, crossmod_faders = {}, {}, {}, {}
    for slot = 1, NUM_MOD_SLOTS do
      local source, amp, freq = "mod_source_" .. slot, "mod_amp_amt_" .. slot, "mod_freq_amt_" .. slot
      crossmod_keys[source] = {carry = false, send = function(voice_idx, x)
        engine.setModSource(voice_idx - 1, slot, S.lib.engine_sync.engine_mod_source(x))
      end}
      crossmod_keys[amp] = {carry = false, send = function(voice_idx, x) engine.setModAmpAmt(voice_idx - 1, slot, x) end}
      crossmod_keys[freq] = {carry = false, send = function(voice_idx, x) engine.setModFreqAmt(voice_idx - 1, slot, x) end}
      crossmod_discrete[source] = {0, NUM_VOICES}
      for _, key in ipairs({source, amp, freq}) do
        crossmod_order[#crossmod_order + 1] = key
        crossmod_faders[#crossmod_faders + 1] = key
      end
    end
    crossmod_keys.mod_speed = {carry = false, send = function(voice_idx, x) engine.setModSpeed(voice_idx - 1, x) end}
    crossmod_order[#crossmod_order + 1] = "mod_speed"
    local crossmod_record
    crossmod_record = {
      name = "crossmod",
      count = 3 * NUM_MOD_SLOTS + 1,
      separator = "cross-modulation",
      add = function(voice_idx)
        local values = S.voices[voice_idx].values
        for slot = 1, NUM_MOD_SLOTS do
          add_param(voice_idx, crossmod_record, "mod_source_" .. slot, {type = "number", name = "mod source " .. slot,
            min = 0, max = NUM_VOICES, default = values["mod_source_" .. slot], formatter = mod_source_text})
          add_param(voice_idx, crossmod_record, "mod_amp_amt_" .. slot, {type = "control", name = "amp mod " .. slot,
            controlspec = controlspec.new(-2, 2, "lin", 0.01, values["mod_amp_amt_" .. slot])})
          add_param(voice_idx, crossmod_record, "mod_freq_amt_" .. slot, {type = "control", name = "freq mod " .. slot,
            controlspec = controlspec.new(-2, 2, "lin", 0.01, values["mod_freq_amt_" .. slot])})
        end
        -- one speed for every slot
        add_param(voice_idx, crossmod_record, "mod_speed", {type = "control", name = "mod speed",
          controlspec = controlspec.new(0.1, 50, "exp", 0.1, values.mod_speed, "Hz")})
      end,
      voice_keys = crossmod_keys,
      send_order = crossmod_order,
      discrete = crossmod_discrete,
      fader = {{keys = crossmod_faders}},
    }

    S.register_voice_params(synth_record)
    S.register_voice_params(grain_record)
    S.register_voice_params(crossmod_record)
  end

  return M
end

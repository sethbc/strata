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

  return M
end

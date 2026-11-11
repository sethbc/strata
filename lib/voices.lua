-- lib/voices.lua
-- The voices: their definitions (S.voices, built fresh by each script load),
-- which voices are locked (S.frozen), the master density, the selected voice,
-- and the global helpers that test a voice's grain source. strata.lua runs
-- `S.lib.voices = include("lib/voices")(S)`; the constructor sets its S
-- fields itself, and its table (S.lib.voices) has no fields.

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
      params = {
        freq = 100,
        amp = 0.3,
        pan = 0,
        rq = 0.1,
        noise = 0.5,
        mod1 = 0.1,
        mod2 = 0.15
      },
      grain = {
        size = 0.1,
        density = 20,
        pitch = 1,
        spread = 0.5,
        env = 1,  -- GRAIN_ENV_OPTIONS index
        mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0
      },
      crossmod = {
        slot1 = {source = 0, amp_amt = 0, freq_amt = 0},  -- 0 = none, 1-7 = voice number
        slot2 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot3 = {source = 0, amp_amt = 0, freq_amt = 0},
        speed = 10
      }
    },
    {
      name = "fm",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "ratio", "index", "modFreq", "amp", "pan"},  -- display / grid order of params
      params = {
        freq = 80,
        amp = 0.25,
        pan = 0,
        ratio = 1.5,
        index = 2,
        modFreq = 0.05
      },
      grain = {
        size = 0.15,
        density = 15,
        pitch = 1,
        spread = 0.3,
        env = 1,  -- GRAIN_ENV_OPTIONS index
        mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0
      },
      crossmod = {
        slot1 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot2 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot3 = {source = 0, amp_amt = 0, freq_amt = 0},
        speed = 10
      }
    },
    {
      name = "folder",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "fold", "mod", "amp", "pan"},  -- display / grid order of params
      params = {
        freq = 60,
        amp = 0.3,
        pan = 0,
        fold = 1,
        mod = 0.2
      },
      grain = {
        size = 0.08,
        density = 25,
        pitch = 1,
        spread = 0.4,
        env = 1,  -- GRAIN_ENV_OPTIONS index
        mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0
      },
      crossmod = {
        slot1 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot2 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot3 = {source = 0, amp_amt = 0, freq_amt = 0},
        speed = 10
      }
    },
    {
      name = "sub",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "drift", "amp"},  -- display / grid order of params
      params = {
        freq = 40,
        amp = 0.4,
        drift = 0.02
      },
      grain = {
        size = 0.2,
        density = 10,
        pitch = 1,
        spread = 0.2,
        env = 1,  -- GRAIN_ENV_OPTIONS index
        mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0
      },
      crossmod = {
        slot1 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot2 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot3 = {source = 0, amp_amt = 0, freq_amt = 0},
        speed = 10
      }
    },
    {
      name = "pulse",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "width", "cutoff", "res", "amp", "pan"},  -- display / grid order of params
      params = {
        freq = 120,
        amp = 0.3,
        pan = 0,
        width = 0.5,
        cutoff = 2000,
        res = 0.3
      },
      grain = {
        size = 0.12,
        density = 18,
        pitch = 1,
        spread = 0.35,
        env = 1,  -- GRAIN_ENV_OPTIONS index
        mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0
      },
      crossmod = {
        slot1 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot2 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot3 = {source = 0, amp_amt = 0, freq_amt = 0},
        speed = 10
      }
    },
    {
      name = "karplus",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "decay", "damping", "excite", "amp", "pan"},  -- display / grid order of params
      params = {
        freq = 200,
        amp = 0.35,
        pan = 0,
        decay = 4,
        damping = 0.5,
        excite = 0.3
      },
      grain = {
        size = 0.08,
        density = 22,
        pitch = 1,
        spread = 0.25,
        env = 1,  -- GRAIN_ENV_OPTIONS index
        mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0
      },
      crossmod = {
        slot1 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot2 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot3 = {source = 0, amp_amt = 0, freq_amt = 0},
        speed = 10
      }
    },
    {
      name = "ring",
      active = false,
      source = SOURCE_SYNTH,  -- SOURCE_OPTIONS index
      param_order = {"freq", "ratio", "mod", "brightness", "amp", "pan"},  -- display / grid order of params
      params = {
        freq = 300,
        amp = 0.25,
        pan = 0,
        ratio = 1.618,
        mod = 0.2,
        brightness = 0.5
      },
      grain = {
        size = 0.1,
        density = 20,
        pitch = 1,
        spread = 0.4,
        env = 1,  -- GRAIN_ENV_OPTIONS index
        mode = 1,  -- GRAIN_MODE_OPTIONS index
        buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
        buf_rate = 1,
        buf_scan = 0
      },
      crossmod = {
        slot1 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot2 = {source = 0, amp_amt = 0, freq_amt = 0},
        slot3 = {source = 0, amp_amt = 0, freq_amt = 0},
        speed = 10
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
  S.frozen = {}
  for i = 1, NUM_VOICES do
    S.frozen[i] = false
  end

  return M
end

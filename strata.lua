-- strata.lua
-- ambient granular layers
--
-- E1: page (MAIN FX LFO BUFFER SETUP)
-- MAIN: E2 select voice, E3 main param,
--       K2 randomize, K3 start/freeze
-- FX: E2 select row, E3 adjust,
--     K3 filter bypass/on

engine.name = "Strata"

local UI = require "ui"

-- Constants
local NUM_VOICES = 7
local NUM_SCENES = 8
local PATTERN_LENGTH = 16
local SCENE_DATA_VERSION = 2  -- Scene file format version (written into scenes.data)
local NUM_MOD_SLOTS = 3       -- Cross-modulation slots per voice
local NUM_UI_PAGES = 5        -- Screen pages, selected with E1
local MAX_STEP_LEVEL = 15     -- Pattern step levels are 0 (off) to 15; level / 15 = retrigger velocity
local NUM_BUFFERS = 8         -- Sample buffer slots (engine numBuffers)
local BUFFER_SECONDS = 16     -- Length of each buffer slot (engine bufferSeconds)
local BUFFER_DATA_VERSION = 1 -- Buffer paths file format version (written into buffers.data)

-- Grain envelope shapes (v<i>_grain_env option order). Option n is sent to
-- the engine as envShape n - 1: 0 = GrainIn's built-in Hann, 1-4 = the
-- engine's envelope buffers
local GRAIN_ENV_OPTIONS = {"hann", "sine", "perc", "linen", "trap"}

-- Grain modes (v<i>_grain_mode option order), sent as grainMode n - 1:
-- 0 = continuous (grain density grains per second), 1 = triggered (one grain
-- per retrigger: pattern steps and MIDI notes)
local GRAIN_MODE_OPTIONS = {"continuous", "triggered"}

-- Grain sources (v<i>_source option order): the voice's own synth, buffer
-- slots 1..NUM_BUFFERS, then the live input. Option n is sent to the engine
-- as setGrainSource n - 1 (0 = synth, 1-8 = buffer slot, 9 = input).
local SOURCE_SYNTH = 1
local SOURCE_INPUT = NUM_BUFFERS + 2
local SOURCE_OPTIONS = {"synth"}
for slot = 1, NUM_BUFFERS do
  SOURCE_OPTIONS[slot + 1] = "buf " .. slot
end
SOURCE_OPTIONS[SOURCE_INPUT] = "input"

-- Convert a Lua mod source (0 = none, 1..NUM_VOICES = voice number) to the
-- engine's 0-indexed form (-1 = none, 0..NUM_VOICES-1 = voice index)
local function engine_mod_source(source)
  if source == 0 then return -1 end
  return source - 1
end

-- State
local voices = {
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
  return voices[voice_idx].source == SOURCE_SYNTH
end

function voice_uses_buffer(voice_idx)
  local source = voices[voice_idx].source
  return source > SOURCE_SYNTH and source < SOURCE_INPUT
end

function voice_source_label(voice_idx)
  return SOURCE_OPTIONS[voices[voice_idx].source]
end

-- The buffer slot (1..NUM_BUFFERS) a buffer-sourced voice reads, or nil for
-- the synth and input sources
function voice_buffer_slot(voice_idx)
  if not voice_uses_buffer(voice_idx) then return nil end
  return voices[voice_idx].source - SOURCE_SYNTH
end

local selected_voice = 1
local UI_PAGES = {"MAIN", "FX", "LFO", "BUFFER", "SETUP"}
local ui_page = 1  -- index into UI_PAGES
local E1_TICKS_PER_PAGE = 4  -- E1 encoder sensitivity (norns.enc.sens)
local master_density = 1.0
local frozen = {}
for i = 1, NUM_VOICES do
  frozen[i] = false
end

-- UI
local voice_list

-- LFOs for parameter modulation
local lfo_metro
local LFO_PITCH_STEP = 0.004       -- width of each random grain pitch step (+/-0.002 per tick)
local LFO_PITCH_REVERSION = 0.01   -- fraction of the offset from the base pitch removed per tick
local grain_pitch_base = {}        -- last non-LFO grain pitch per voice (the walk's centre)
local LFO_BUF_POS_STEP = 0.002     -- width of each random buffer position step (+/-0.001 per tick)
local LFO_BUF_POS_REVERSION = 0.01 -- fraction of the offset from the base position removed per tick
local buf_pos_base = {}            -- last non-LFO buffer position per voice
local lfo_writing = false          -- true while lfo_update sets params
for i = 1, NUM_VOICES do
  grain_pitch_base[i] = voices[i].grain.pitch
  buf_pos_base[i] = voices[i].grain.buf_pos
end

-- Mutation system
local mutation_metro

-- Scene system
local scenes = {}
local current_scene = 0  -- 0 = no scene loaded
local scene_sequencer_position = 1
local scene_sequencer_enabled = false
local scene_sequencer_clock = nil
local scene_transition_active = false
local scene_transition_clock = nil  -- Track transition clock for cancellation

-- Arc device (the arc vport from arc.connect)
local arc_device = nil
local arc_connected = false

-- Grid devices (support multiple grids)
local MAX_GRID_PORTS = 4
local grids = {}

-- Pattern sequencer
local patterns = {}
local pattern_position = 1
local pattern_playing = false
local pattern_clock = nil

-- Grid UI state
local grid_page = 1  -- 1=patterns, 2=parameters, 3=scenes, 4=buffers/fx (256 only)
local param_page = 1
local grid_voice_select = 1

-- Initialize patterns for each voice
for i = 1, NUM_VOICES do
  patterns[i] = {}
  for step = 1, PATTERN_LENGTH do
    patterns[i][step] = 0  -- 0=off, 1-15=velocity/brightness
  end
end

-- Initialize scenes
local function empty_scene(scene_num)
  return {
    name = "scene " .. scene_num,
    populated = false,
    data = {}
  }
end

for i = 1, NUM_SCENES do
  scenes[i] = empty_scene(i)
end

-- Sample buffers. The engine holds the audio; Lua tracks what each slot
-- holds for the screen and scenes. path is the loaded file, or the scratch
-- take the engine writes when a recording completes (or stops early).
local buffers = {}
for slot = 1, NUM_BUFFERS do
  buffers[slot] = {name = "empty", loaded = false, recording = false, seconds = 0, path = nil}
end
local buffer_record_clocks = {}  -- per slot: clock that ends the recording state
local buffer_state_poll = nil
local BUFFER_STATE_STRIDE = 100  -- bufferState value = slot index * 100 + valid seconds (engine bufferStateStride)
local buffer_audio_dir = _path.audio .. "strata/"
local buffer_scratch_dir = buffer_audio_dir .. "scratch/"  -- engine scratchDir

local function valid_buffer_slot(slot)
  return slot >= 1 and slot <= NUM_BUFFERS
end

-- Buffer state is shown on the BUFFER page and the 256 grid's page 4
local function buffer_display_changed()
  redraw()
  grid_redraw()
end

local function cancel_buffer_recording_timer(slot)
  if buffer_record_clocks[slot] then
    clock.cancel(buffer_record_clocks[slot])
    buffer_record_clocks[slot] = nil
  end
end

-- The engine writes each completed (or early-stopped) take here,
-- overwriting the slot's previous take
function scratch_take_path(slot)
  return buffer_scratch_dir .. "buf" .. slot .. ".wav"
end

-- A take is in the slot (the recording completed or was stopped early)
local function finish_buffer_take(slot)
  local buffer = buffers[slot]
  buffer.recording = false
  buffer.loaded = true
  buffer.name = "take " .. slot
  buffer.path = scratch_take_path(slot)
end

-- A usable sound file path: not empty, not norns' "-" (no file chosen) and
-- not a directory (the file param's starting folder)
local function is_sound_file_path(path)
  return type(path) == "string" and path ~= "" and path ~= "-" and path:sub(-1) ~= "/"
end

function load_buffer(slot, path)
  if not valid_buffer_slot(slot) or not is_sound_file_path(path) then return end
  -- loading cancels a recording in progress in the engine
  cancel_buffer_recording_timer(slot)
  engine.loadBuffer(slot - 1, path)
  local buffer = buffers[slot]
  -- a scratch take restored on start keeps its take name
  buffer.name = path == scratch_take_path(slot) and ("take " .. slot) or path:match("[^/]*$")
  buffer.loaded = true
  buffer.recording = false
  buffer.path = path
  buffer_display_changed()
end

-- Record the live input into a slot for record_duration seconds, or, if the
-- slot is already recording, stop early and keep what was captured
function record_buffer(slot)
  if not valid_buffer_slot(slot) then return end
  local buffer = buffers[slot]
  cancel_buffer_recording_timer(slot)
  if buffer.recording then
    engine.stopRecord(slot - 1)
    finish_buffer_take(slot)
  else
    local duration = params:get("record_duration")
    engine.recordBuffer(slot - 1, duration, params:get("record_level"))
    buffer.recording = true
    buffer.seconds = 0  -- the engine reports 0 s until the take completes
    buffer_record_clocks[slot] = clock.run(function()
      clock.sleep(duration)
      buffer_record_clocks[slot] = nil
      finish_buffer_take(slot)
      buffer_display_changed()
    end)
  end
  buffer_display_changed()
end

function clear_buffer(slot)
  if not valid_buffer_slot(slot) then return end
  cancel_buffer_recording_timer(slot)
  engine.clearBuffer(slot - 1)
  local buffer = buffers[slot]
  buffer.name = "empty"
  buffer.loaded = false
  buffer.recording = false
  buffer.seconds = 0
  buffer.path = nil
  buffer_display_changed()
end

-- Timestamped stereo WAV in audio/strata/, so it shows in the file browser
function buffer_save_path(slot)
  return buffer_audio_dir .. os.date("%Y%m%d-%H%M%S") .. "-buf" .. slot .. ".wav"
end

function save_buffer(slot)
  if not valid_buffer_slot(slot) then return end
  -- seconds comes from the engine's poll: a load that failed leaves
  -- loaded set but no audio, and a recording reads 0 s until it completes
  if buffers[slot].seconds <= 0 then
    print("buffer " .. slot .. " is empty, nothing to save")
    return
  end
  util.make_dir(buffer_audio_dir)
  local path = buffer_save_path(slot)
  engine.saveBuffer(slot - 1, path)
  print("buffer " .. slot .. " saved to " .. path)
end

-- bufferState poll: one slot per message, slot index * 100 + seconds
local function buffer_state_changed(value)
  local slot_index = math.floor(value / BUFFER_STATE_STRIDE)
  local slot = slot_index + 1
  if not valid_buffer_slot(slot) then return end
  local seconds = value - slot_index * BUFFER_STATE_STRIDE
  -- the periodic poll repeats unchanged values: redraw only on a change
  if buffers[slot].seconds == seconds then return end
  buffers[slot].seconds = seconds
  redraw()  -- the BUFFER page shows the seconds
  if grid_page == 4 then grid_redraw() end
end

-- Effects chain (filter -> delay -> reverb -> master). Each filter or delay
-- param sends its whole command, so the engine always gets the current
-- values of the others.
local function send_filter_to_engine()
  engine.setFilter(params:get("filter_freq"), params:get("filter_res"), params:get("filter_type") - 1, params:get("filter_mix"))
end

local function send_delay_to_engine()
  engine.setDelay(params:get("delay_time"), params:get("delay_feedback"), params:get("delay_mix"))
end

-- Last non-zero filter mix (set by the filter_mix action): FX page K3
-- restores it after a bypass
local fx_filter_last_mix = 1

-- The filter and delay params are faders on the 256 grid's FX page
local function fx_fader_changed()
  if grid_page == 4 then grid_redraw() end
end

function init()
  -- Set up params
  params:add_separator("strata")
  
  -- Master controls
  params:add{
    type = "control",
    id = "master_density",
    name = "master density",
    controlspec = controlspec.new(0.1, 2.0, "lin", 0.01, 1.0),
    action = function(x)
      master_density = x
      update_all_grain_density()
    end
  }
  
  -- Sequencer tempo: drives norns' global clock (clock_tempo), which the
  -- pattern clock follows via clock.sync so external clock sources still work
  params:add{
    type = "number",
    id = "tempo",
    name = "tempo",
    min = 40,
    max = 300,
    default = util.clamp(util.round(params:get("clock_tempo")), 40, 300),
    action = function(x)
      params:set("clock_tempo", x)
    end
  }

  -- Probability-based mutations
  params:add_separator("strata_mutations")

  params:add{
    type = "binary",
    id = "mutation_enabled",
    name = "mutations enabled",
    behavior = "toggle",
    default = 0,
    action = function(x)
      if x == 1 then
        mutation_metro:start()
      else
        mutation_metro:stop()
      end
    end
  }

  params:add{
    type = "control",
    id = "mutation_rate",
    name = "mutation rate",
    controlspec = controlspec.new(0.5, 10, "lin", 0.1, 2, "s"),
    action = function(x)
      mutation_metro.time = x
    end
  }

  params:add{
    type = "control",
    id = "mutation_probability",
    name = "mutation probability",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0.15),
    action = function(x)
      -- Probability value used in gentle_mutate()
    end
  }

  params:add{
    type = "control",
    id = "mutation_amount",
    name = "mutation amount",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0.25),
    action = function(x)
      -- Amount value used in gentle_mutate()
    end
  }

  -- Scene system
  params:add_separator("strata_scenes")

  params:add{
    type = "binary",
    id = "scene_sequencer_enabled",
    name = "scene sequencer",
    behavior = "toggle",
    default = 0,
    action = function(x)
      if x == 1 then
        scene_sequencer_start()
      else
        scene_sequencer_stop()
      end
    end
  }

  params:add{
    type = "control",
    id = "scene_transition_time",
    name = "transition time",
    controlspec = controlspec.new(0, 30, "lin", 0.5, 2, "s"),
    action = function(x)
      -- Transition time used in scene recall
    end
  }

  params:add{
    type = "control",
    id = "scene_duration",
    name = "scene duration",
    controlspec = controlspec.new(4, 120, "lin", 1, 16, "s"),
    action = function(x)
      -- Time before advancing to next scene
    end
  }

  params:add{
    type = "number",
    id = "scene_sequence_length",
    name = "sequence length",
    min = 1,
    max = NUM_SCENES,
    default = 4,
    action = function(x)
      -- How many scenes to cycle through
    end
  }

  params:add{
    type = "trigger",
    id = "save_scenes",
    name = "save scenes to disk",
    action = function()
      save_scenes_to_disk()
    end
  }

  params:add{
    type = "trigger",
    id = "load_scenes",
    name = "load scenes from disk",
    action = function()
      load_scenes_from_disk()
    end
  }

  -- Effects chain: filter, delay, reverb and tape drift in one group. The
  -- group size must match the params below exactly.
  params:add_group("strata_fx", "fx", 11)

  params:add{
    type = "option",
    id = "filter_type",
    name = "filter type",
    options = {"lowpass", "highpass", "bandpass"},
    default = 1,
    action = function()
      send_filter_to_engine()
    end
  }

  params:add{
    type = "control",
    id = "filter_freq",
    name = "filter freq",
    controlspec = controlspec.new(20, 20000, "exp", 0, 5000, "Hz"),
    action = function()
      send_filter_to_engine()
      fx_fader_changed()
    end
  }

  params:add{
    type = "control",
    id = "filter_res",
    name = "filter res",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5),
    action = function()
      send_filter_to_engine()
      fx_fader_changed()
    end
  }

  params:add{
    type = "control",
    id = "filter_mix",
    name = "filter mix",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0),  -- 0 = bypass
    action = function(x)
      -- FX page K3 brings back the last non-zero mix, however it was set
      if x > 0 then fx_filter_last_mix = x end
      send_filter_to_engine()
    end
  }

  params:add{
    type = "control",
    id = "delay_time",
    name = "delay time",
    controlspec = controlspec.new(0.01, 2, "exp", 0.001, 0.375, "s"),
    action = function()
      send_delay_to_engine()
      fx_fader_changed()
    end
  }

  params:add{
    type = "control",
    id = "delay_feedback",
    name = "delay feedback",
    controlspec = controlspec.new(0, 0.95, "lin", 0.01, 0.4),
    action = function()
      send_delay_to_engine()
      fx_fader_changed()
    end
  }

  params:add{
    type = "control",
    id = "delay_mix",
    name = "delay mix",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0),
    action = function()
      send_delay_to_engine()
      fx_fader_changed()
    end
  }

  params:add{
    type = "control",
    id = "reverb_mix",
    name = "reverb mix",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0.3),
    action = function(x)
      engine.setReverb(x, params:get("reverb_size"), params:get("reverb_damp"))
    end
  }

  params:add{
    type = "control",
    id = "reverb_size",
    name = "reverb size",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0.8),
    action = function(x)
      engine.setReverb(params:get("reverb_mix"), x, params:get("reverb_damp"))
    end
  }

  params:add{
    type = "control",
    id = "reverb_damp",
    name = "reverb damping",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5),
    action = function(x)
      engine.setReverb(params:get("reverb_mix"), params:get("reverb_size"), x)
    end
  }

  params:add{
    type = "control",
    id = "drift_amount",
    name = "tape drift",
    controlspec = controlspec.new(0, 0.1, "lin", 0.001, 0.01),
    action = function(x)
      engine.setMasterDrift(x)
    end
  }

  -- Sample buffers: recording settings, then file/record/clear/save per
  -- slot. The group size must match the params below exactly.
  params:add_group("strata_buffers", "buffers", 2 + NUM_BUFFERS * 4)

  params:add{
    type = "control",
    id = "record_duration",
    name = "record duration",
    controlspec = controlspec.new(0.5, BUFFER_SECONDS, "lin", 0.5, 8, "s")
  }

  params:add{
    type = "control",
    id = "record_level",
    name = "record level",
    controlspec = controlspec.new(0, 2, "lin", 0.01, 1)
  }

  for slot = 1, NUM_BUFFERS do
    params:add_file("buf" .. slot .. "_file", "buffer " .. slot .. " file", _path.audio)
    params:set_action("buf" .. slot .. "_file", function(path) load_buffer(slot, path) end)
    params:add_trigger("buf" .. slot .. "_record", "buffer " .. slot .. " record")
    params:set_action("buf" .. slot .. "_record", function() record_buffer(slot) end)
    params:add_trigger("buf" .. slot .. "_clear", "buffer " .. slot .. " clear")
    params:set_action("buf" .. slot .. "_clear", function() clear_buffer(slot) end)
    params:add_trigger("buf" .. slot .. "_save", "buffer " .. slot .. " save")
    params:set_action("buf" .. slot .. "_save", function() save_buffer(slot) end)
  end

  -- Add params for each voice
  for i = 1, NUM_VOICES do
    add_voice_params(i)
  end
  
  -- UI setup
  update_voice_list()
  -- E1 only selects the page: without acceleration, and 4 ticks per page,
  -- a fast turn steps through pages instead of jumping to SETUP
  norns.enc.accel(1, false)
  norns.enc.sens(1, E1_TICKS_PER_PAGE)
  
  -- Start LFO system
  lfo_metro = metro.init()
  lfo_metro.time = 0.1
  lfo_metro.event = lfo_update
  lfo_metro:start()

  -- Initialize mutation system
  mutation_metro = metro.init()
  mutation_metro.time = params:get("mutation_rate")
  mutation_metro.event = gentle_mutate
  -- Don't start automatically - controlled by mutation_enabled param

  -- Valid seconds per buffer slot, from the engine
  buffer_state_poll = poll.set("bufferState", buffer_state_changed)
  if buffer_state_poll then
    buffer_state_poll:start()
  else
    print("bufferState poll not found")
  end

  -- Connect arc
  arc_init()

  -- Connect grids
  grid_init()

  -- Load saved scenes from disk
  load_scenes_from_disk()

  -- Reload the buffers remembered on exit (after the scenes, which may use them)
  load_buffers_from_disk()

  -- Start with first two voices (delayed)
  clock.run(function()
    toggle_voice(1)
    clock.sleep(0.5)
    toggle_voice(2)
  end)

  redraw()
end

function add_voice_params(voice_idx)
  local v = voices[voice_idx]
  params:add_separator("voice " .. voice_idx .. ": " .. v.name)
  
  -- Voice params (in param_order so the menu order is stable)
  for _, key in ipairs(v.param_order) do
    local spec = get_param_spec(key)
    spec.default = v.params[key]  -- the voices table holds each voice's defaults
    params:add{
      type = "control",
      id = "v" .. voice_idx .. "_" .. key,
      name = key,
      controlspec = spec,
      action = function(x)
        voices[voice_idx].params[key] = x
        if voices[voice_idx].active then
          engine.setVoiceParam(voice_idx - 1, key, x)
        end
      end
    }
  end
  
  -- Grain params
  params:add_separator("voice " .. voice_idx .. " granular")

  -- Source: always sent, so the engine knows it before the voice starts
  -- (a stopped voice only records it; voiceOn then builds the right synths)
  params:add{
    type = "option",
    id = "v" .. voice_idx .. "_source",
    name = "source",
    options = SOURCE_OPTIONS,
    default = v.source,
    action = function(x)
      voices[voice_idx].source = x
      engine.setGrainSource(voice_idx - 1, x - 1)
      if voices[voice_idx].active then
        sync_voice_values_to_engine(voice_idx)
      end
      -- the grid fader list follows the source (buffer or synth params)
      if grid_voice_select == voice_idx then
        param_page = util.clamp(param_page, 1, fader_page_count(voice_idx))
      end
      redraw()
      grid_redraw()
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_buf_pos",
    name = "buffer position",
    -- step 0: the LFO drift moves in steps far smaller than 0.01
    controlspec = controlspec.new(0, 1, "lin", 0, v.grain.buf_pos),
    action = function(x)
      voices[voice_idx].grain.buf_pos = x
      if not lfo_writing then
        buf_pos_base[voice_idx] = x
      end
      if voices[voice_idx].active then
        engine.setGrainParam(voice_idx - 1, "bufPos", x)
      end
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_buf_rate",
    name = "buffer rate",
    controlspec = controlspec.new(0.25, 4, "exp", 0.01, v.grain.buf_rate),
    action = function(x)
      voices[voice_idx].grain.buf_rate = x
      if voices[voice_idx].active then
        engine.setGrainParam(voice_idx - 1, "bufRate", x)
      end
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_buf_scan",
    name = "buffer scan",
    controlspec = controlspec.new(-2, 2, "lin", 0.01, v.grain.buf_scan),
    action = function(x)
      voices[voice_idx].grain.buf_scan = x
      if voices[voice_idx].active then
        engine.setGrainParam(voice_idx - 1, "bufScan", x)
      end
    end
  }
  
  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_grain_size",
    name = "grain size",
    controlspec = controlspec.new(0.01, 0.5, "lin", 0.01, v.grain.size),
    action = function(x)
      voices[voice_idx].grain.size = x
      if voices[voice_idx].active then
        engine.setGrainParam(voice_idx - 1, "grainSize", x)
      end
    end
  }
  
  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_grain_density",
    name = "grain density",
    controlspec = controlspec.new(1, 100, "lin", 1, v.grain.density),
    action = function(x)
      voices[voice_idx].grain.density = x
      if voices[voice_idx].active then
        engine.setGrainParam(voice_idx - 1, "grainDensity", x * master_density)
      end
    end
  }
  
  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_grain_pitch",
    name = "grain pitch",
    -- step 0: the LFO drift moves in steps far smaller than 0.01
    controlspec = controlspec.new(0.25, 4, "lin", 0, v.grain.pitch),
    action = function(x)
      voices[voice_idx].grain.pitch = x
      if not lfo_writing then
        grain_pitch_base[voice_idx] = x
      end
      if voices[voice_idx].active then
        engine.setGrainParam(voice_idx - 1, "pitchShift", x)
      end
    end
  }
  
  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_grain_spread",
    name = "position spread",
    controlspec = controlspec.new(0, 1, "lin", 0.01, v.grain.spread),
    action = function(x)
      voices[voice_idx].grain.spread = x
      if voices[voice_idx].active then
        engine.setGrainParam(voice_idx - 1, "posSpread", x)
      end
    end
  }

  params:add{
    type = "option",
    id = "v" .. voice_idx .. "_grain_env",
    name = "grain envelope",
    options = GRAIN_ENV_OPTIONS,
    default = v.grain.env,
    action = function(x)
      voices[voice_idx].grain.env = x
      if voices[voice_idx].active then
        engine.setGrainParam(voice_idx - 1, "envShape", x - 1)
      end
    end
  }

  params:add{
    type = "option",
    id = "v" .. voice_idx .. "_grain_mode",
    name = "grain mode",
    options = GRAIN_MODE_OPTIONS,
    default = v.grain.mode,
    action = function(x)
      voices[voice_idx].grain.mode = x
      if voices[voice_idx].active then
        engine.setGrainParam(voice_idx - 1, "grainMode", x - 1)
      end
    end
  }

  -- Cross-modulation params (3 slots)
  params:add_separator("voice " .. voice_idx .. " cross-modulation")

  -- Slot 1
  params:add{
    type = "number",
    id = "v" .. voice_idx .. "_mod_source_1",
    name = "mod source 1",
    min = 0,
    max = NUM_VOICES,
    default = v.crossmod.slot1.source,
    formatter = function(param)
      if param:get() == 0 then
        return "none"
      else
        return "voice " .. param:get()
      end
    end,
    action = function(x)
      voices[voice_idx].crossmod.slot1.source = x
      if voices[voice_idx].active then
        engine.setModSource(voice_idx - 1, 1, engine_mod_source(x))
      end
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_mod_amp_amt_1",
    name = "amp mod 1",
    controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot1.amp_amt),
    action = function(x)
      voices[voice_idx].crossmod.slot1.amp_amt = x
      if voices[voice_idx].active then
        engine.setModAmpAmt(voice_idx - 1, 1, x)
      end
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_mod_freq_amt_1",
    name = "freq mod 1",
    controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot1.freq_amt),
    action = function(x)
      voices[voice_idx].crossmod.slot1.freq_amt = x
      if voices[voice_idx].active then
        engine.setModFreqAmt(voice_idx - 1, 1, x)
      end
    end
  }

  -- Slot 2
  params:add{
    type = "number",
    id = "v" .. voice_idx .. "_mod_source_2",
    name = "mod source 2",
    min = 0,
    max = NUM_VOICES,
    default = v.crossmod.slot2.source,
    formatter = function(param)
      if param:get() == 0 then
        return "none"
      else
        return "voice " .. param:get()
      end
    end,
    action = function(x)
      voices[voice_idx].crossmod.slot2.source = x
      if voices[voice_idx].active then
        engine.setModSource(voice_idx - 1, 2, engine_mod_source(x))
      end
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_mod_amp_amt_2",
    name = "amp mod 2",
    controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot2.amp_amt),
    action = function(x)
      voices[voice_idx].crossmod.slot2.amp_amt = x
      if voices[voice_idx].active then
        engine.setModAmpAmt(voice_idx - 1, 2, x)
      end
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_mod_freq_amt_2",
    name = "freq mod 2",
    controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot2.freq_amt),
    action = function(x)
      voices[voice_idx].crossmod.slot2.freq_amt = x
      if voices[voice_idx].active then
        engine.setModFreqAmt(voice_idx - 1, 2, x)
      end
    end
  }

  -- Slot 3
  params:add{
    type = "number",
    id = "v" .. voice_idx .. "_mod_source_3",
    name = "mod source 3",
    min = 0,
    max = NUM_VOICES,
    default = v.crossmod.slot3.source,
    formatter = function(param)
      if param:get() == 0 then
        return "none"
      else
        return "voice " .. param:get()
      end
    end,
    action = function(x)
      voices[voice_idx].crossmod.slot3.source = x
      if voices[voice_idx].active then
        engine.setModSource(voice_idx - 1, 3, engine_mod_source(x))
      end
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_mod_amp_amt_3",
    name = "amp mod 3",
    controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot3.amp_amt),
    action = function(x)
      voices[voice_idx].crossmod.slot3.amp_amt = x
      if voices[voice_idx].active then
        engine.setModAmpAmt(voice_idx - 1, 3, x)
      end
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_mod_freq_amt_3",
    name = "freq mod 3",
    controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot3.freq_amt),
    action = function(x)
      voices[voice_idx].crossmod.slot3.freq_amt = x
      if voices[voice_idx].active then
        engine.setModFreqAmt(voice_idx - 1, 3, x)
      end
    end
  }

  -- Global mod speed (shared across all slots)
  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_mod_speed",
    name = "mod speed",
    controlspec = controlspec.new(0.1, 50, "exp", 0.1, v.crossmod.speed),
    action = function(x)
      voices[voice_idx].crossmod.speed = x
      if voices[voice_idx].active then
        engine.setModSpeed(voice_idx - 1, x)
      end
    end
  }
end

function get_param_spec(param_name)
  local specs = {
    freq = controlspec.new(20, 2000, "exp", 1, 100, "Hz"),
    amp = controlspec.new(0, 1, "lin", 0.01, 0.3),
    pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    rq = controlspec.new(0.01, 1, "lin", 0.01, 0.1),
    noise = controlspec.new(0, 1, "lin", 0.01, 0.5),
    mod1 = controlspec.new(0.01, 1, "lin", 0.01, 0.1),
    mod2 = controlspec.new(0.01, 1, "lin", 0.01, 0.15),
    ratio = controlspec.new(0.5, 8, "lin", 0.001, 1.5),  -- fine step: Ring defaults to 1.618
    index = controlspec.new(0, 10, "lin", 0.1, 2),
    modFreq = controlspec.new(0.01, 1, "lin", 0.01, 0.05),
    fold = controlspec.new(0.1, 5, "lin", 0.1, 1),
    mod = controlspec.new(0.01, 2, "lin", 0.01, 0.2),
    drift = controlspec.new(0.001, 0.1, "lin", 0.001, 0.02),
    width = controlspec.new(0.05, 0.95, "lin", 0.01, 0.5),
    cutoff = controlspec.new(100, 8000, "exp", 10, 2000, "Hz"),
    res = controlspec.new(0.1, 1, "lin", 0.01, 0.3),
    decay = controlspec.new(0.5, 10, "lin", 0.1, 4),
    damping = controlspec.new(0.1, 0.9, "lin", 0.01, 0.5),
    excite = controlspec.new(0.1, 2, "lin", 0.01, 0.3),
    brightness = controlspec.new(0, 1, "lin", 0.01, 0.5)
  }
  return specs[param_name] or controlspec.new(0, 1, "lin", 0.01, 0.5)
end

function toggle_voice(voice_idx)
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  local voice = voices[voice_idx]
  
  if voice.active then
    engine.voiceOff(voice_idx - 1)
    voice.active = false
  else
    engine.voiceOn(
      voice_idx - 1,
      voice.params.freq,
      voice.params.amp,
      voice.params.pan or 0,
      voice.grain.size,
      voice.grain.density * master_density,
      voice.grain.pitch
    )
    sync_voice_to_engine(voice_idx)
    voice.active = true
  end
  
  update_voice_list()
  redraw()
  grid_redraw()
end

function toggle_freeze(voice_idx)
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  frozen[voice_idx] = not frozen[voice_idx]
  update_voice_list()
  grid_redraw()
end

-- Push the complete Lua-side state of a voice to its freshly started engine
-- synths. voiceOn only carries the initial freq/amp/pan and grain values, and
-- param actions only reach the engine while a voice is active, so without this
-- edits made while a voice was off (and scene recalls) would be lost. The
-- source goes first (the engine ignores it when unchanged).
function sync_voice_to_engine(voice_idx)
  engine.setGrainSource(voice_idx - 1, voices[voice_idx].source - 1)
  sync_voice_values_to_engine(voice_idx)
end

-- Everything sync_voice_to_engine sends after the source: synthesis, grain
-- (including the buffer params) and crossmod values
function sync_voice_values_to_engine(voice_idx)
  local voice = voices[voice_idx]
  local engine_voice = voice_idx - 1

  for key, value in pairs(voice.params) do
    engine.setVoiceParam(engine_voice, key, value)
  end

  engine.setGrainParam(engine_voice, "grainSize", voice.grain.size)
  engine.setGrainParam(engine_voice, "grainDensity", voice.grain.density * master_density)
  engine.setGrainParam(engine_voice, "pitchShift", voice.grain.pitch)
  engine.setGrainParam(engine_voice, "posSpread", voice.grain.spread)
  engine.setGrainParam(engine_voice, "envShape", voice.grain.env - 1)
  engine.setGrainParam(engine_voice, "grainMode", voice.grain.mode - 1)
  engine.setGrainParam(engine_voice, "bufPos", voice.grain.buf_pos)
  engine.setGrainParam(engine_voice, "bufRate", voice.grain.buf_rate)
  engine.setGrainParam(engine_voice, "bufScan", voice.grain.buf_scan)

  for slot = 1, NUM_MOD_SLOTS do
    local slot_state = voice.crossmod["slot" .. slot]
    engine.setModSource(engine_voice, slot, engine_mod_source(slot_state.source))
    engine.setModAmpAmt(engine_voice, slot, slot_state.amp_amt)
    engine.setModFreqAmt(engine_voice, slot, slot_state.freq_amt)
  end

  engine.setModSpeed(engine_voice, voice.crossmod.speed)
end

function randomize_voice(voice_idx)
  if frozen[voice_idx] then return end
  
  local voice = voices[voice_idx]
  local prefix = "v" .. voice_idx .. "_"

  if voice_uses_synth(voice_idx) then
    -- Randomize synth params
    for key, _ in pairs(voice.params) do
      if key ~= "amp" then -- Don't randomize amplitude
        local spec = get_param_spec(key)
        local new_val = math.random() * (spec.maxval - spec.minval) + spec.minval
        params:set(prefix .. key, new_val)
      end
    end
  elseif voice_uses_buffer(voice_idx) then
    -- Buffer source: the synth is not playing, so randomize the buffer
    -- params instead (rate 0.5-2, even in octaves; gentle scan)
    params:set(prefix .. "buf_pos", math.random())
    params:set(prefix .. "buf_rate", 2 ^ (math.random() * 2 - 1))
    params:set(prefix .. "buf_scan", math.random() - 0.5)
  end
  -- (input source: neither synth nor buffer params do anything; only the
  -- grain params below are randomized)
  
  -- Randomize some grain params
  params:set("v" .. voice_idx .. "_grain_size", math.random() * 0.3 + 0.05)
  params:set("v" .. voice_idx .. "_grain_pitch", math.random() * 2 + 0.5)
  
  redraw()
  grid_redraw()
end

function update_all_grain_density()
  for i = 1, NUM_VOICES do
    if voices[i].active then
      engine.setGrainParam(i - 1, "grainDensity", voices[i].grain.density * master_density)
    end
  end
end

function lfo_update()
  -- Slow grain pitch drift for active, non-frozen voices: a small random
  -- step plus a pull back toward the last user/scene/mutation-set pitch, so
  -- the walk stays a subtle detune instead of wandering to the rails
  for i = 1, NUM_VOICES do
    if voices[i].active and not frozen[i] then
      local current = voices[i].grain.pitch
      local delta = (math.random() - 0.5) * LFO_PITCH_STEP
        - (current - grain_pitch_base[i]) * LFO_PITCH_REVERSION
      lfo_writing = true
      params:set("v" .. i .. "_grain_pitch", util.clamp(current + delta, 0.25, 4))
      lfo_writing = false

      -- Buffer sources also drift their position the same way
      if voice_uses_buffer(i) then
        local position = voices[i].grain.buf_pos
        local position_delta = (math.random() - 0.5) * LFO_BUF_POS_STEP
          - (position - buf_pos_base[i]) * LFO_BUF_POS_REVERSION
        lfo_writing = true
        params:set("v" .. i .. "_buf_pos", util.clamp(position + position_delta, 0, 1))
        lfo_writing = false
      end
    end
  end

  -- Grain pitch is shown on the parameter fader page; this runs 10x/s, so
  -- only redraw when a grid is actually showing that page
  if next(grids) ~= nil and grid_page == 2 then
    grid_redraw()
  end

  -- lfo_update is the script's 10 Hz tick: also drop keys held into the menu
  forget_keys_held_through_menu()
end

-- voices[i].grain keys gentle_mutate changes for buffer-sourced voices
local BUFFER_MUTATION_KEYS = {"buf_pos", "buf_rate", "buf_scan"}

function gentle_mutate()
  -- Probability-based parameter mutations
  local probability = params:get("mutation_probability")
  local amount = params:get("mutation_amount")

  for i = 1, NUM_VOICES do
    -- Only mutate active, non-frozen voices
    if voices[i].active and not frozen[i] then
      local v = voices[i]

      if voice_uses_synth(i) then
        -- Iterate through synthesis parameters
        for key, current_val in pairs(v.params) do
          -- Skip amplitude and pan to preserve stability
          if key ~= "amp" and key ~= "pan" then
            -- Check if this parameter should mutate
            if math.random() < probability then
              local spec = get_param_spec(key)
              local range = spec.maxval - spec.minval

              -- Generate mutation delta based on amount
              -- Using gaussian-like distribution by averaging random values
              local delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount * range

              -- Apply mutation with clamping
              local new_val = util.clamp(current_val + delta, spec.minval, spec.maxval)
              params:set("v" .. i .. "_" .. key, new_val)
            end
          end
        end
      elseif voice_uses_buffer(i) then
        -- Buffer sources mutate their buffer params instead of the (silent)
        -- synthesis params. Input sources mutate only the grain params
        -- below. The source itself never mutates.
        for _, key in ipairs(BUFFER_MUTATION_KEYS) do
          if math.random() < probability then
            local param_id = "v" .. i .. "_" .. key
            local spec = params:lookup_param(param_id).controlspec
            -- delta across the normalized range, so exp buf_rate moves evenly
            local delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount
            params:set(param_id, spec:map(util.clamp(spec:unmap(v.grain[key]) + delta, 0, 1)))
          end
        end
      end

      -- Occasionally mutate granular parameters (lower probability). The
      -- discrete ones (DISCRETE_GRAIN_KEYS: envelope shape, grain mode) never mutate.
      if math.random() < probability * 0.5 then
        local grain_size = v.grain.size
        local size_delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount * 0.2
        params:set("v" .. i .. "_grain_size", util.clamp(grain_size + size_delta, 0.01, 0.5))
      end

      if math.random() < probability * 0.3 then
        local grain_pitch = v.grain.pitch
        local pitch_delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount * 1.0
        params:set("v" .. i .. "_grain_pitch", util.clamp(grain_pitch + pitch_delta, 0.25, 4))
      end

      if math.random() < probability * 0.2 then
        local grain_spread = v.grain.spread
        local spread_delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount * 0.3
        params:set("v" .. i .. "_grain_spread", util.clamp(grain_spread + spread_delta, 0, 1))
      end
    end
  end

  -- Mutated values are shown by the 256 grid's parameter faders
  grid_redraw()
end

-- Scene management functions

-- Global params stored in every scene, in recall order. Continuous ones are
-- crossfaded by smooth transitions; the others switch when the fade ends.
-- default is the param's default, which migrate_scene gives scenes written
-- before the param existed (tempo's param default follows clock_tempo; every
-- scene file has always stored tempo).
local SCENE_GLOBAL_PARAMS = {
  {id = "master_density", continuous = true, default = 1.0},
  {id = "tempo", continuous = false, default = 120},
  {id = "mutation_enabled", continuous = false, default = 0},
  {id = "mutation_rate", continuous = false, default = 2},
  {id = "mutation_probability", continuous = false, default = 0.15},
  {id = "mutation_amount", continuous = false, default = 0.25},
  {id = "filter_type", continuous = false, default = 1},
  {id = "filter_freq", continuous = true, default = 5000},
  {id = "filter_res", continuous = true, default = 0.5},
  {id = "filter_mix", continuous = true, default = 0},
  {id = "delay_time", continuous = true, default = 0.375},
  {id = "delay_feedback", continuous = true, default = 0.4},
  {id = "delay_mix", continuous = true, default = 0},
  {id = "reverb_mix", continuous = true, default = 0.3},
  {id = "reverb_size", continuous = true, default = 0.8},
  {id = "reverb_damp", continuous = true, default = 0.5},
  {id = "drift_amount", continuous = true, default = 0.01}
}

-- Per-voice scene fields added after format 1, filled by migrate_scene in
-- scenes that lack them: {path = keys inside data.voices[i], default = value}.
-- A field is only filled when its parent table exists (a scene missing the
-- parent is left for validate_scene to reject). Each default must equal the
-- param's default.
local VOICE_SCENE_DEFAULTS = {
  {path = {"grain", "env"}, default = 1},  -- hann
  {path = {"grain", "mode"}, default = 1},  -- continuous
  {path = {"source"}, default = SOURCE_SYNTH},
  {path = {"grain", "buf_pos"}, default = 0},
  {path = {"grain", "buf_rate"}, default = 1},
  {path = {"grain", "buf_scan"}, default = 0}
}

-- Top-level scene blocks added after format 1 (such as LFO or MIDI
-- settings): {key = field of scene data, default = value}
local SCENE_BLOCK_DEFAULTS = {}

-- voices[i].grain keys -> param id suffixes
local GRAIN_PARAM_IDS = {
  size = "grain_size",
  density = "grain_density",
  pitch = "grain_pitch",
  spread = "grain_spread",
  env = "grain_env",
  mode = "grain_mode",
  buf_pos = "buf_pos",
  buf_rate = "buf_rate",
  buf_scan = "buf_scan"
}

-- voices[i].grain keys holding an option index rather than a continuous
-- value, mapped to their option count: smooth transitions switch them at the
-- end instead of crossfading, mutation never touches them, and scenes must
-- store integers from 1 to the option count
local DISCRETE_GRAIN_KEYS = {
  env = #GRAIN_ENV_OPTIONS,
  mode = #GRAIN_MODE_OPTIONS
}

local SCENE_TRANSITION_STEPS = 20

local function is_number(value)
  return type(value) == "number" and value == value  -- rejects NaN
end

local function is_integer_between(value, min, max)
  return is_number(value) and value == math.floor(value) and value >= min and value <= max
end

-- Copy a scene default so filled scenes never share tables
local function copy_scene_default(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, inner in pairs(value) do copy[key] = copy_scene_default(inner) end
  return copy
end

-- Set target[path] to default unless it is already present
local function fill_scene_default(target, path, default)
  for depth = 1, #path - 1 do
    target = target[path[depth]]
    if type(target) ~= "table" then return end
  end
  if target[path[#path]] == nil then
    target[path[#path]] = copy_scene_default(default)
  end
end

-- Bring a loaded scene up to the current format by filling every field it
-- lacks with its default: globals (SCENE_GLOBAL_PARAMS), top-level blocks
-- (SCENE_BLOCK_DEFAULTS) and per-voice fields (VOICE_SCENE_DEFAULTS).
-- Filling only adds what is missing, so it runs for every file version;
-- from_version is there for changes that must convert a particular format.
-- Malformed scenes are left alone for validate_scene to reject.
function migrate_scene(scene, from_version)
  if type(scene) ~= "table" or scene.populated ~= true or type(scene.data) ~= "table" then return end
  local data = scene.data

  for _, global in ipairs(SCENE_GLOBAL_PARAMS) do
    fill_scene_default(data, {global.id}, global.default)
  end

  for _, block in ipairs(SCENE_BLOCK_DEFAULTS) do
    fill_scene_default(data, {block.key}, block.default)
  end

  if type(data.voices) ~= "table" then return end
  for i = 1, NUM_VOICES do
    if type(data.voices[i]) == "table" then
      for _, field in ipairs(VOICE_SCENE_DEFAULTS) do
        fill_scene_default(data.voices[i], field.path, field.default)
      end
    end
  end
end

function capture_scene(scene_num)
  if scene_num < 1 or scene_num > NUM_SCENES then return end

  local scene_data = {
    voices = {},
    frozen = {},
    patterns = {}
  }

  for _, global in ipairs(SCENE_GLOBAL_PARAMS) do
    scene_data[global.id] = params:get(global.id)
  end

  -- Capture voice states
  for i = 1, NUM_VOICES do
    scene_data.voices[i] = {
      active = voices[i].active,
      source = voices[i].source,  -- the buffer's contents are not captured
      params = {},
      grain = {},
      crossmod = {}
    }

    -- Copy all parameters
    for key, value in pairs(voices[i].params) do
      scene_data.voices[i].params[key] = value
    end
    for key, value in pairs(voices[i].grain) do
      scene_data.voices[i].grain[key] = value
    end
    -- Copy crossmod structure (including nested slots)
    scene_data.voices[i].crossmod = {speed = voices[i].crossmod.speed}
    for slot = 1, NUM_MOD_SLOTS do
      local slot_state = voices[i].crossmod["slot" .. slot]
      scene_data.voices[i].crossmod["slot" .. slot] = {
        source = slot_state.source,
        amp_amt = slot_state.amp_amt,
        freq_amt = slot_state.freq_amt
      }
    end

    scene_data.frozen[i] = frozen[i]
  end

  -- Capture patterns
  for i = 1, NUM_VOICES do
    scene_data.patterns[i] = {}
    for step = 1, PATTERN_LENGTH do
      scene_data.patterns[i][step] = patterns[i][step]
    end
  end

  scenes[scene_num].data = scene_data
  scenes[scene_num].populated = true
  print("captured scene " .. scene_num)
end

function cancel_scene_transition()
  if scene_transition_clock then
    clock.cancel(scene_transition_clock)
    scene_transition_clock = nil
  end
  scene_transition_active = false
end

-- Snapshot {id, start, target} for every continuous param a smooth
-- transition crossfades. Start values are read once, before the fade, so
-- the fade moves linearly from start to target over the whole transition.
-- Grain sources, mod sources, discrete grain params (envelope shape, grain
-- mode), freeze and active states switch at the end instead.
function scene_transition_targets(scene_data)
  local targets = {}
  local function add_target(param_id, target_value)
    table.insert(targets, {id = param_id, start = params:get(param_id), target = target_value})
  end

  for _, global in ipairs(SCENE_GLOBAL_PARAMS) do
    if global.continuous then
      add_target(global.id, scene_data[global.id])
    end
  end

  for i = 1, NUM_VOICES do
    local voice_data = scene_data.voices[i]
    local prefix = "v" .. i .. "_"
    for key, target_value in pairs(voice_data.params) do
      add_target(prefix .. key, target_value)
    end
    for key, target_value in pairs(voice_data.grain) do
      if not DISCRETE_GRAIN_KEYS[key] then
        add_target(prefix .. GRAIN_PARAM_IDS[key], target_value)
      end
    end
    for slot = 1, NUM_MOD_SLOTS do
      local slot_data = voice_data.crossmod["slot" .. slot]
      add_target(prefix .. "mod_amp_amt_" .. slot, slot_data.amp_amt)
      add_target(prefix .. "mod_freq_amt_" .. slot, slot_data.freq_amt)
    end
    add_target(prefix .. "mod_speed", voice_data.crossmod.speed)
  end

  return targets
end

function recall_scene(scene_num, transition_time)
  if scene_num < 1 or scene_num > NUM_SCENES then return end
  if not scenes[scene_num].populated then
    print("scene " .. scene_num .. " is empty")
    return
  end

  -- Validate scene data before recalling
  if not validate_scene(scenes[scene_num]) then
    print("error: scene " .. scene_num .. " has invalid data")
    return
  end

  transition_time = transition_time or 0

  -- Any new recall supersedes a transition that is still running
  cancel_scene_transition()

  if transition_time > 0 then
    local targets = scene_transition_targets(scenes[scene_num].data)

    scene_transition_active = true
    scene_transition_clock = clock.run(function()
      local step_time = transition_time / SCENE_TRANSITION_STEPS

      for step = 1, SCENE_TRANSITION_STEPS do
        local mix = step / SCENE_TRANSITION_STEPS
        for _, target in ipairs(targets) do
          params:set(target.id, util.linlin(0, 1, target.start, target.target, mix))
        end
        grid_redraw()  -- keep the parameter faders moving with the fade
        clock.sleep(step_time)
      end

      -- Final state: exact values plus the non-continuous params
      scene_transition_clock = nil
      scene_transition_active = false
      recall_scene_instant(scene_num)
    end)
  else
    -- Instant recall
    recall_scene_instant(scene_num)
  end

  current_scene = scene_num
  redraw()
end

-- Apply a scene immediately. The scene must have passed validate_scene.
function recall_scene_instant(scene_num)
  local scene_data = scenes[scene_num].data

  -- Restore global parameters
  for _, global in ipairs(SCENE_GLOBAL_PARAMS) do
    params:set(global.id, scene_data[global.id])
  end

  -- Restore voice states
  for i = 1, NUM_VOICES do
    local voice_data = scene_data.voices[i]
    local prefix = "v" .. i .. "_"

    params:set(prefix .. "source", voice_data.source)

    for key, value in pairs(voice_data.params) do
      params:set(prefix .. key, value)
    end

    for key, value in pairs(voice_data.grain) do
      params:set(prefix .. GRAIN_PARAM_IDS[key], value)
    end

    -- Restore crossmod slots
    for slot = 1, NUM_MOD_SLOTS do
      local slot_data = voice_data.crossmod["slot" .. slot]
      params:set(prefix .. "mod_source_" .. slot, slot_data.source)
      params:set(prefix .. "mod_amp_amt_" .. slot, slot_data.amp_amt)
      params:set(prefix .. "mod_freq_amt_" .. slot, slot_data.freq_amt)
    end
    params:set(prefix .. "mod_speed", voice_data.crossmod.speed)

    frozen[i] = scene_data.frozen[i]

    -- Start/stop voices last: toggle_voice syncs the restored state
    if voice_data.active ~= voices[i].active then
      toggle_voice(i)
    end
  end

  -- Restore patterns
  for i = 1, NUM_VOICES do
    for step = 1, PATTERN_LENGTH do
      patterns[i][step] = scene_data.patterns[i][step]
    end
  end

  update_voice_list()
  grid_redraw()
end

function scene_sequencer_start()
  if scene_sequencer_clock then
    clock.cancel(scene_sequencer_clock)
  end

  scene_sequencer_enabled = true
  scene_sequencer_position = 1

  scene_sequencer_clock = clock.run(function()
    while scene_sequencer_enabled do
      local seq_length = params:get("scene_sequence_length")

      -- Clamp position to valid range (prevents wraparound bugs)
      scene_sequencer_position = util.clamp(scene_sequencer_position, 1, seq_length)

      -- Recall next scene in sequence (skip empty scenes)
      if scenes[scene_sequencer_position].populated then
        recall_scene(scene_sequencer_position, params:get("scene_transition_time"))
      else
        print("skipping empty scene " .. scene_sequencer_position)
      end

      -- Wait for scene duration
      clock.sleep(params:get("scene_duration"))

      -- Advance to next scene with proper wraparound
      scene_sequencer_position = scene_sequencer_position + 1
      if scene_sequencer_position > seq_length then
        scene_sequencer_position = 1
      end

      redraw()
      grid_redraw()
    end
  end)
end

function scene_sequencer_stop()
  scene_sequencer_enabled = false
  if scene_sequencer_clock then
    clock.cancel(scene_sequencer_clock)
    scene_sequencer_clock = nil
  end
  redraw()
  grid_redraw()
end

-- Scene disk persistence
local scene_data_dir = _path.data .. "strata/"
local scene_data_file = scene_data_dir .. "scenes.data"
-- Set when a scenes file could not be loaded and could not be moved aside:
-- cleanup() must then not overwrite it with the (empty) in-memory scenes
local scene_autosave_blocked = false

function save_scenes_to_disk()
  -- Ensure data directory exists
  if util.file_exists(scene_data_dir) == false then
    util.make_dir(scene_data_dir)
  end

  -- Save scenes table to disk, tagged with the format version
  tab.save({version = SCENE_DATA_VERSION, scenes = scenes}, scene_data_file)
  print("scenes saved to " .. scene_data_file)
end

-- A data file that failed to load must survive the save in cleanup():
-- move it to <file>.bak. Returns false if that failed, and the caller then
-- blocks its auto-save.
local function move_aside_unloadable_file(data_file, label)
  local backup_file = data_file .. ".bak"
  local moved, move_error = os.rename(data_file, backup_file)
  if moved then
    print("unloadable " .. label .. " file kept as " .. backup_file)
    return true
  end
  print("could not move unloadable " .. label .. " file (" .. tostring(move_error) ..
    "); " .. label .. " will not be auto-saved on exit")
  return false
end

local function preserve_unloadable_scene_file()
  if not move_aside_unloadable_file(scene_data_file, "scenes") then
    scene_autosave_blocked = true
  end
end

-- Load scenes from disk. On any problem the current scenes (empty at
-- startup) are kept, a message is printed and the file is preserved; a bad
-- file never stops init.
function load_scenes_from_disk()
  if not util.file_exists(scene_data_file) then
    print("no saved scenes file found")
    return
  end

  -- tab.load runs the file as Lua without protection
  local ok, loaded, load_error = pcall(tab.load, scene_data_file)
  if not ok then
    print("error: scenes file could not be read (" .. tostring(loaded) .. "), keeping current scenes")
    preserve_unloadable_scene_file()
    return
  end
  if type(loaded) ~= "table" then
    print("error loading scenes file: " .. tostring(load_error))
    preserve_unloadable_scene_file()
    return
  end

  local scene_table, file_version
  if loaded.version ~= nil then
    -- Version 1 files are migrated; newer (or invalid) versions are rejected
    if not is_integer_between(loaded.version, 1, SCENE_DATA_VERSION) then
      print("error: scenes file has version " .. tostring(loaded.version) ..
        ", expected 1 to " .. SCENE_DATA_VERSION)
      preserve_unloadable_scene_file()
      return
    end
    file_version = loaded.version
    scene_table = loaded.scenes
  else
    -- Files written before 2.1 hold the bare scenes array (format version 1)
    file_version = 1
    scene_table = loaded
  end

  -- Fill fields added since the file's format, then validate the result
  if type(scene_table) == "table" then
    for i = 1, NUM_SCENES do
      migrate_scene(scene_table[i], file_version)
    end
  end

  if not validate_scene_data(scene_table) then
    print("error: scene file corrupted or incompatible version")
    preserve_unloadable_scene_file()
    return
  end

  -- Make sure every slot exists, filling gaps with empty scenes
  local loaded_scenes = {}
  for i = 1, NUM_SCENES do
    loaded_scenes[i] = scene_table[i] or empty_scene(i)
  end
  scenes = loaded_scenes
  scene_autosave_blocked = false
  if file_version < SCENE_DATA_VERSION then
    print("migrated scenes file from version " .. file_version)
  end
  print("scenes loaded from " .. scene_data_file)

  -- Update grid display if grids are connected
  grid_redraw()
end

-- Buffer disk persistence: buffers.data remembers, per slot, the loaded file
-- or the scratch take, so buffer-sourced voices and scenes are not silent
-- after a restart. It holds only paths; the audio stays in its own files.
local buffer_data_file = scene_data_dir .. "buffers.data"
-- Set when a buffers file could not be loaded and could not be moved aside
local buffer_autosave_blocked = false
local buffers_restored = 0  -- slots reloaded by the last load_buffers_from_disk (SETUP page)

function save_buffers_to_disk()
  if util.file_exists(scene_data_dir) == false then
    util.make_dir(scene_data_dir)
  end
  local paths = {}
  for slot = 1, NUM_BUFFERS do
    paths[slot] = buffers[slot].path or ""
  end
  tab.save({version = BUFFER_DATA_VERSION, paths = paths}, buffer_data_file)
  print("buffer paths saved to " .. buffer_data_file)
end

local function preserve_unloadable_buffer_file()
  if not move_aside_unloadable_file(buffer_data_file, "buffers") then
    buffer_autosave_blocked = true
  end
end

-- Reload each remembered path that still exists through load_buffer. A
-- missing or damaged file loads nothing and never stops init.
function load_buffers_from_disk()
  buffers_restored = 0
  if not util.file_exists(buffer_data_file) then
    print("no saved buffers file found")
    return
  end

  -- tab.load runs the file as Lua without protection
  local ok, loaded, load_error = pcall(tab.load, buffer_data_file)
  if not ok then
    print("error: buffers file could not be read (" .. tostring(loaded) .. ")")
    preserve_unloadable_buffer_file()
    return
  end
  if type(loaded) ~= "table" then
    print("error loading buffers file: " .. tostring(load_error))
    preserve_unloadable_buffer_file()
    return
  end
  if loaded.version ~= BUFFER_DATA_VERSION or type(loaded.paths) ~= "table" then
    print("error: buffers file has version " .. tostring(loaded.version) ..
      " or no path list, expected version " .. BUFFER_DATA_VERSION)
    preserve_unloadable_buffer_file()
    return
  end

  for slot = 1, NUM_BUFFERS do
    local path = loaded.paths[slot]
    if is_sound_file_path(path) then
      -- the file may have been deleted, or a take never written
      if util.file_exists(path) then
        load_buffer(slot, path)
        buffers_restored = buffers_restored + 1
      else
        print("buffer " .. slot .. ": " .. path .. " not found, not restored")
      end
    end
  end
  buffer_autosave_blocked = false
  print(buffers_restored .. " buffers restored from " .. buffer_data_file)
end

-- Check that one scene slot holds everything recall_scene_instant reads
function validate_scene(scene)
  if type(scene) ~= "table" then return false end
  if type(scene.populated) ~= "boolean" then return false end
  if not scene.populated then return true end

  local data = scene.data
  if type(data) ~= "table" then return false end

  for _, global in ipairs(SCENE_GLOBAL_PARAMS) do
    if not is_number(data[global.id]) then return false end
  end

  if type(data.voices) ~= "table" or #data.voices ~= NUM_VOICES then return false end
  if type(data.frozen) ~= "table" then return false end
  if type(data.patterns) ~= "table" then return false end

  for i = 1, NUM_VOICES do
    local voice_data = data.voices[i]
    if type(voice_data) ~= "table" then return false end
    if type(voice_data.active) ~= "boolean" then return false end
    if not is_integer_between(voice_data.source, 1, #SOURCE_OPTIONS) then return false end
    if type(voice_data.params) ~= "table" then return false end
    if type(voice_data.grain) ~= "table" then return false end
    if type(voice_data.crossmod) ~= "table" then return false end

    for key, value in pairs(voice_data.params) do
      if voices[i].params[key] == nil or not is_number(value) then return false end
    end
    for key, value in pairs(voice_data.grain) do
      if GRAIN_PARAM_IDS[key] == nil or not is_number(value) then return false end
      if DISCRETE_GRAIN_KEYS[key] and not is_integer_between(value, 1, DISCRETE_GRAIN_KEYS[key]) then
        return false
      end
    end
    for slot = 1, NUM_MOD_SLOTS do
      local slot_data = voice_data.crossmod["slot" .. slot]
      if type(slot_data) ~= "table" then return false end
      if not is_integer_between(slot_data.source, 0, NUM_VOICES) then return false end
      if not is_number(slot_data.amp_amt) or not is_number(slot_data.freq_amt) then return false end
    end
    if not is_number(voice_data.crossmod.speed) then return false end

    if type(data.frozen[i]) ~= "boolean" then return false end

    local pattern = data.patterns[i]
    if type(pattern) ~= "table" then return false end
    for step = 1, PATTERN_LENGTH do
      if not is_integer_between(pattern[step], 0, MAX_STEP_LEVEL) then return false end
    end
  end

  return true
end

-- Validate a whole scenes table (as loaded from disk). Missing slots are
-- allowed; load_scenes_from_disk fills them with empty scenes.
function validate_scene_data(scene_table)
  if type(scene_table) ~= "table" then return false end

  for i = 1, NUM_SCENES do
    if scene_table[i] ~= nil and not validate_scene(scene_table[i]) then
      return false
    end
  end

  return true
end

function update_voice_list()
  local items = {}
  for i = 1, NUM_VOICES do
    local status = voices[i].active and "●" or "○"
    local freeze = frozen[i] and " [F]" or ""
    items[i] = status .. " " .. voices[i].name .. freeze
  end
  voice_list = UI.ScrollingList.new(0, 10, 1, items)
  voice_list.num_visible = 4  -- rows at y 15-48, clear of the hint row at y 62
  voice_list.num_above_selected = 1
  voice_list.active = true
  voice_list.index = selected_voice
end

-- The synthesis param E3 and arc ring 2 adjust on MAIN, per voice type:
-- param id suffix, screen label, screen value format, and arc delta scale
local MAIN_PARAMS = {
  resonator = {key = "freq", label = "freq", format = "%.0f Hz", arc_scale = 1},
  fm = {key = "index", label = "index", format = "%.1f", arc_scale = 0.1},
  folder = {key = "fold", label = "fold", format = "%.1f", arc_scale = 0.1},
  sub = {key = "drift", label = "drift", format = "%.3f", arc_scale = 0.01},
  pulse = {key = "width", label = "width", format = "%.2f", arc_scale = 0.01},
  karplus = {key = "decay", label = "decay", format = "%.1f s", arc_scale = 0.1},
  ring = {key = "ratio", label = "ratio", format = "%.2f", arc_scale = 0.01}
}

-- A buffer-sourced voice shows and adjusts its buffer position instead; an
-- input-sourced voice its grain size (its synth and buffer params do nothing)
local BUFFER_MAIN_PARAM = {key = "buf_pos", label = "pos", format = "%.2f", arc_scale = 0.1}
local INPUT_MAIN_PARAM = {key = "grain_size", label = "size", format = "%.2f s", arc_scale = 0.01}

function main_param_entry(voice_idx)
  if voice_uses_synth(voice_idx) then
    return MAIN_PARAMS[voices[voice_idx].name]
  elseif voice_uses_buffer(voice_idx) then
    return BUFFER_MAIN_PARAM
  end
  return INPUT_MAIN_PARAM
end

function main_param_id(voice_idx)
  return "v" .. voice_idx .. "_" .. main_param_entry(voice_idx).key
end

function main_param_label(voice_idx)
  return main_param_entry(voice_idx).label
end

-- Screen pages. E1 selects the page; E2, E3, K2 and K3 go to the page's
-- handlers in PAGE_ENC / PAGE_KEY, and redraw() draws the shared header,
-- then the page's PAGE_DRAW function, which ends with its hint row.

local HINT_ROW_Y = 62

function draw_header()
  screen.level(15)
  screen.move(0, 8)
  screen.text(UI_PAGES[ui_page])

  -- Master density (after the page title; "BUFFER" ends near x=36)
  screen.move(40, 8)
  screen.level(4)
  screen.text("dens:" .. string.format("%.2f", master_density))

  -- Mutation indicator (between density and scene)
  if params:get("mutation_enabled") == 1 then
    screen.move(98, 8)
    screen.level(6)
    screen.text("[M]")
  end

  -- Scene indicator (right-aligned to the screen edge)
  if current_scene > 0 then
    screen.move(127, 8)
    screen.level(scene_sequencer_enabled and 10 or 6)
    screen.text_right("S" .. current_scene)
  end
end

function draw_hints(text)
  screen.level(4)
  screen.move(0, HINT_ROW_Y)
  screen.text(text)
end

function redraw_main()
  -- Voice list (left column, 0-60px)
  voice_list:redraw()

  -- Right column divider
  screen.level(1)
  screen.move(62, 10)
  screen.line(62, 52)
  screen.stroke()

  -- Selected voice info (right column, 65-128px)
  local v = voices[selected_voice]
  screen.level(15)
  screen.move(65, 18)
  screen.text(string.upper(v.name))

  -- Status indicators
  screen.level(4)
  screen.move(65, 26)
  local status = v.active and "ON" or "OFF"
  screen.text(status)
  if frozen[selected_voice] then
    screen.move(127, 26)
    screen.level(8)
    screen.text_right("[FREEZE]")
  end

  -- Modulation sources display
  local mod_sources = {}
  if v.crossmod.slot1.source > 0 then table.insert(mod_sources, "V" .. v.crossmod.slot1.source) end
  if v.crossmod.slot2.source > 0 then table.insert(mod_sources, "V" .. v.crossmod.slot2.source) end
  if v.crossmod.slot3.source > 0 then table.insert(mod_sources, "V" .. v.crossmod.slot3.source) end

  if #mod_sources > 0 then
    screen.level(4)
    screen.move(65, 32)
    screen.text("mod:" .. table.concat(mod_sources, " "))
  end

  -- Main parameter
  screen.level(frozen[selected_voice] and 3 or 10)
  screen.move(65, 42)
  screen.text(main_param_label(selected_voice))
  if GRAIN_MODE_OPTIONS[v.grain.mode] == "triggered" then
    screen.move(127, 42)
    screen.level(8)
    screen.text_right("[TRIG]")
    screen.level(frozen[selected_voice] and 3 or 10)
  end
  screen.move(65, 50)
  screen.text(string.format(main_param_entry(selected_voice).format, params:get(main_param_id(selected_voice))))

  draw_hints("K2:rand K3:" .. (v.active and "freeze" or "start"))
end

function redraw_setup()
  -- Connected grids (count, then sizes in port order)
  local grid_count = 0
  local grid_sizes = {}
  for port = 1, MAX_GRID_PORTS do
    local grid_port = grids[port]
    if grid_port and grid_port.device then
      grid_count = grid_count + 1
      table.insert(grid_sizes, grid_port.cols .. "x" .. grid_port.rows)
    end
  end

  local scenes_saved = 0
  for scene_num = 1, NUM_SCENES do
    if scenes[scene_num].populated then scenes_saved = scenes_saved + 1 end
  end

  -- rows 6 px apart (like the BUFFER page), leaving y 54 above the hints
  screen.level(10)
  screen.move(0, 18)
  screen.text("grid: " .. grid_count .. " connected")
  screen.level(4)
  screen.move(0, 24)
  screen.text(table.concat(grid_sizes, " "))
  screen.level(10)
  screen.move(0, 30)
  screen.text("arc: " .. (arc_connected and "connected" or "none"))
  screen.move(0, 36)
  screen.text("scenes: " .. scenes_saved .. "/" .. NUM_SCENES .. " saved")
  screen.move(0, 42)
  screen.text("buffers: " .. buffers_restored .. " restored")
  screen.move(0, 48)
  screen.text("midi: -")  -- MIDI device and channel mode arrive with MIDI input

  draw_hints("K3:save scenes")
end

-- FX page: a scrolling list of the effects params. E2 selects a row, E3
-- adjusts it; format is a string.format pattern, or nil to show the param's
-- own string (the filter type's name).
local FX_ROWS = {
  {label = "density", param_id = "master_density", format = "%.2f"},
  {label = "tape drift", param_id = "drift_amount", format = "%.3f"},
  {label = "filter type", param_id = "filter_type"},
  {label = "filter freq", param_id = "filter_freq", format = "%.0f Hz"},
  {label = "filter res", param_id = "filter_res", format = "%.2f"},
  {label = "filter mix", param_id = "filter_mix", format = "%.2f"},
  {label = "delay time", param_id = "delay_time", format = "%.3f s"},
  {label = "delay fdbk", param_id = "delay_feedback", format = "%.2f"},
  {label = "delay mix", param_id = "delay_mix", format = "%.2f"},
  {label = "reverb mix", param_id = "reverb_mix", format = "%.2f"},
  {label = "reverb size", param_id = "reverb_size", format = "%.2f"},
  {label = "reverb damp", param_id = "reverb_damp", format = "%.2f"}
}
local FX_VISIBLE_ROWS = 5      -- rows at y 18-50, clear of the hint row at y 62
local FX_FIRST_ROW_Y = 18
local FX_ROW_SPACING = 8
local fx_row = 1               -- selected FX_ROWS index

function redraw_fx()
  -- Keep one row above the selection in view, like the MAIN voice list
  local first_visible = util.clamp(fx_row - 1, 1, #FX_ROWS - FX_VISIBLE_ROWS + 1)
  for offset = 0, FX_VISIBLE_ROWS - 1 do
    local row_index = first_visible + offset
    local row = FX_ROWS[row_index]
    local y = FX_FIRST_ROW_Y + offset * FX_ROW_SPACING
    local value = row.format and string.format(row.format, params:get(row.param_id))
      or params:string(row.param_id)
    screen.level(row_index == fx_row and 15 or 4)
    screen.move(0, y)
    screen.text(row.label)
    screen.move(127, y)
    screen.text_right(value)
  end

  draw_hints("K3:filter " .. (params:get("filter_mix") > 0 and "bypass" or "on"))
end

local function fx_enc(n, d)
  if n == 2 then
    fx_row = util.clamp(fx_row + d, 1, #FX_ROWS)
  elseif n == 3 then
    params:delta(FX_ROWS[fx_row].param_id, d)
  end
end

-- K3 on FX: bypass the filter (mix 0), or bring back its last non-zero mix
local function fx_key(n)
  if n == 3 then
    params:set("filter_mix", params:get("filter_mix") > 0 and 0 or fx_filter_last_mix)
  end
end

-- Pages whose controls are not built yet: draw an empty hint row and ignore
-- encoders and keys
local function redraw_placeholder() draw_hints("") end
local function ignore_page_input() end

-- E2 on MAIN and BUFFER: step the shared selected voice
local function select_voice_by(d)
  selected_voice = util.clamp(selected_voice + d, 1, NUM_VOICES)
  update_voice_list()
end

local function main_enc(n, d)
  if n == 2 then
    select_voice_by(d)
  elseif n == 3 then
    params:delta(main_param_id(selected_voice), d)
  end
end

-- K3 on MAIN (and the arc button): start the selected voice, or freeze it
local function start_or_freeze_selected_voice()
  if not voices[selected_voice].active then
    toggle_voice(selected_voice)
  else
    toggle_freeze(selected_voice)
  end
end

local function main_key(n)
  if n == 2 then
    randomize_voice(selected_voice)
  elseif n == 3 then
    start_or_freeze_selected_voice()
  end
end

local function setup_key(n)
  if n == 3 then
    save_scenes_to_disk()
  end
end

-- Per key: the page it was pressed on, while it is held (nil when up).
-- key() sends a release only to the page the key went down on.
local key_press_page = {}

-- BUFFER page: the selected voice and its source on the left, the eight
-- buffer slots on the right (slot, name or "empty", seconds or REC)
local BUFFER_ROW_FIRST_Y = 14
local BUFFER_ROW_SPACING = 6   -- eight rows at y 14-56, clear of the hint row at y 62
local BUFFER_SLOT_X = 65
local BUFFER_NAME_X = 71
local BUFFER_NAME_MAX_WIDTH = 31  -- the name ends before the widest seconds ("16.0s" from x 103)

-- Cut text, a whole UTF-8 character at a time, until it fits max_width px
local function fit_text(text, max_width)
  while text ~= "" and screen.text_extents(text) > max_width do
    text = text:gsub("[^\128-\191][\128-\191]*$", "")
  end
  return text
end

-- A buffer's name for the screen: the file name without its extension
local function buffer_display_name(slot)
  local name = buffers[slot].name:gsub("%.[^.]*$", "")
  if name == "" then name = buffers[slot].name end
  return fit_text(name, BUFFER_NAME_MAX_WIDTH)
end

function redraw_buffer()
  local v = voices[selected_voice]
  local voice_slot = voice_buffer_slot(selected_voice)

  -- Left column (0-60px): voice, source, recording settings
  screen.level(15)
  screen.move(0, 18)
  screen.text(string.upper(v.name))
  screen.level(10)
  screen.move(0, 26)
  screen.text("src: " .. voice_source_label(selected_voice))
  screen.level(4)
  screen.move(0, 42)
  screen.text("dur: " .. string.format("%.1f", params:get("record_duration")) .. "s")
  screen.move(0, 50)
  screen.text("lvl: " .. string.format("%.2f", params:get("record_level")))

  screen.level(1)
  screen.move(62, 10)
  screen.line(62, 56)
  screen.stroke()

  -- Right column (65-127px): one row per buffer slot. The voice's buffer is
  -- brightest, loaded (or recording) slots mid, empty slots dim.
  for slot = 1, NUM_BUFFERS do
    local buffer = buffers[slot]
    local y = BUFFER_ROW_FIRST_Y + (slot - 1) * BUFFER_ROW_SPACING
    local level = 2
    if slot == voice_slot then
      level = 15
    elseif buffer.loaded or buffer.recording then
      level = 8
    end
    screen.level(level)
    screen.move(BUFFER_SLOT_X, y)
    screen.text(tostring(slot))
    screen.move(BUFFER_NAME_X, y)
    screen.text(buffer_display_name(slot))
    screen.move(127, y)
    screen.text_right(buffer.recording and "REC" or string.format("%.1fs", buffer.seconds))
  end

  if voice_slot then
    draw_hints("K2:load K3:" .. (buffers[voice_slot].recording and "stop" or "rec") .. " K2+3:save")
  else
    -- K2 and K3 need a buffer source; E3 picks one
    draw_hints("K2:- K3:- E3:source")
  end
end

local function buffer_enc(n, d)
  if n == 2 then
    select_voice_by(d)
  elseif n == 3 then
    params:delta("v" .. selected_voice .. "_source", d)
  end
end

-- K3 while K2 is held saved the buffer: K2's release then opens nothing
local buffer_saved_during_k2 = false

-- K3 (press) records into the voice's buffer, or stops early; with K2 held
-- it saves the buffer instead. K2 acts on release (buffer_key_release).
-- Both do nothing when the voice's source is not a buffer.
local function buffer_key(n)
  if n == 2 then
    buffer_saved_during_k2 = false
  elseif n == 3 then
    local slot = voice_buffer_slot(selected_voice)
    if not slot then return end
    if key_press_page[2] == ui_page then
      save_buffer(slot)
      buffer_saved_during_k2 = true
    else
      record_buffer(slot)
    end
  end
end

-- K2 released: open the file selector for the voice's buffer, unless K3
-- saved while K2 was down
local function buffer_key_release(n)
  if n ~= 2 then return end
  if buffer_saved_during_k2 then
    buffer_saved_during_k2 = false
    return
  end
  local slot = voice_buffer_slot(selected_voice)
  if not slot then return end
  fileselect.enter(_path.audio, function(path)
    if path ~= "cancel" then
      params:set("buf" .. slot .. "_file", path)
    end
    redraw()
  end)
end

-- Indexed like UI_PAGES: MAIN, FX, LFO, BUFFER, SETUP. PAGE_KEY gets key
-- presses, PAGE_KEY_RELEASE releases (only BUFFER uses them).
local PAGE_DRAW = {redraw_main, redraw_fx, redraw_placeholder, redraw_buffer, redraw_setup}
local PAGE_ENC = {main_enc, fx_enc, ignore_page_input, buffer_enc, ignore_page_input}
local PAGE_KEY = {main_key, fx_key, ignore_page_input, buffer_key, setup_key}
local PAGE_KEY_RELEASE = {ignore_page_input, ignore_page_input, ignore_page_input, buffer_key_release, ignore_page_input}

-- Encoders
function enc(n, d)
  if n == 1 then
    ui_page = util.clamp(ui_page + d, 1, NUM_UI_PAGES)
  else
    PAGE_ENC[ui_page](n, d)
  end
  arc_redraw()
  redraw()
end

-- The norns menu (K1, or PARAMS and its file selector) takes every key
-- while it is open, so a key released there never reaches key() and would
-- stay "held" (on BUFFER, every later K3 would save instead of record).
-- Called on every 10 Hz lfo_metro tick (end of lfo_update): while the menu is open, forget
-- every held key and the BUFFER page's K2 gesture.
function forget_keys_held_through_menu()
  if not norns.menu.status() then return end
  for n in pairs(key_press_page) do
    key_press_page[n] = nil
  end
  buffer_saved_during_k2 = false
end

-- Keys. Presses go to the page's PAGE_KEY handler. A release goes to
-- PAGE_KEY_RELEASE only if the key went down on the page still showing, so a
-- key held across a page change does nothing when it comes up.
function key(n, z)
  if z == 1 then
    key_press_page[n] = ui_page
    PAGE_KEY[ui_page](n)
  else
    local press_page = key_press_page[n]
    key_press_page[n] = nil
    if press_page == ui_page then
      PAGE_KEY_RELEASE[ui_page](n)
    end
  end
  redraw()
end

-- Redraw
function redraw()
  screen.clear()
  draw_header()
  PAGE_DRAW[ui_page]()
  screen.update()
end

-- Arc functions

-- Arc pages follow the screen page: ARC_PAGE_DELTA[ui_page] handles ring
-- turns and ARC_PAGE_REDRAW[ui_page] draws the rings between arc_redraw's
-- clear and refresh.

local function arc_main_delta(n, delta)
  if n == 1 then
    -- Ring 1: Master density
    params:delta("master_density", delta / 20)
  elseif n == 2 then
    -- Ring 2: Selected voice's main parameter
    local scale = main_param_entry(selected_voice).arc_scale
    params:delta(main_param_id(selected_voice), delta * scale)
  elseif n == 3 then
    -- Ring 3: Grain size
    params:delta("v" .. selected_voice .. "_grain_size", delta / 100)
  elseif n == 4 then
    -- Ring 4: Grain density
    params:delta("v" .. selected_voice .. "_grain_density", delta / 10)
  end
end

local function arc_main_redraw(arc_port)
  -- Ring 1: Master density (0.1 to 2.0)
  local density_pos = util.linlin(0.1, 2.0, 0, 64, master_density)
  arc_port:segment(1, 0, density_pos / 64 * math.pi * 2, 15)

  -- Ring 2: Selected voice's main parameter, across its controlspec range
  local v = voices[selected_voice]
  local param_id = main_param_id(selected_voice)
  local param_min, param_max = param_range(param_id)
  local param_pos = util.linlin(param_min, param_max, 0, 64, params:get(param_id))
  arc_port:segment(2, 0, param_pos / 64 * math.pi * 2, v.active and 15 or 4)

  -- Ring 3: Grain size (0.01 to 0.5)
  local grain_size_pos = util.linlin(0.01, 0.5, 0, 64, v.grain.size)
  arc_port:segment(3, 0, grain_size_pos / 64 * math.pi * 2, v.active and 12 or 3)

  -- Ring 4: Grain density (1 to 100)
  local grain_density_pos = util.linlin(1, 100, 0, 64, v.grain.density)
  arc_port:segment(4, 0, grain_density_pos / 64 * math.pi * 2, v.active and 12 or 3)
end

-- FX page rings: the param each ring adjusts and its delta scale
local ARC_FX_RINGS = {
  {param_id = "filter_freq", scale = 1 / 4},
  {param_id = "filter_res", scale = 1 / 100},
  {param_id = "delay_time", scale = 1 / 200},
  {param_id = "delay_mix", scale = 1 / 100}
}

local function arc_fx_delta(n, delta)
  local ring = ARC_FX_RINGS[n]
  if ring then
    params:delta(ring.param_id, delta * ring.scale)
  end
end

-- Each ring shows its param across its controlspec (following the warp,
-- so exp params such as filter freq and delay time sweep evenly)
local function arc_fx_redraw(arc_port)
  for n, ring in ipairs(ARC_FX_RINGS) do
    arc_port:segment(n, 0, param_fraction(ring.param_id) * math.pi * 2, 12)
  end
end

-- BUFFER page rings: the selected voice's buffer position and rate, then
-- the recording duration and level. Param id suffixes after "v<i>_" for
-- the voice rings.
local ARC_BUFFER_RINGS = {
  {voice_key = "buf_pos", scale = 1 / 200},
  {voice_key = "buf_rate", scale = 1 / 100},
  {param_id = "record_duration", scale = 1 / 20},
  {param_id = "record_level", scale = 1 / 100}
}

local function arc_buffer_ring_param(ring)
  return ring.param_id or ("v" .. selected_voice .. "_" .. ring.voice_key)
end

-- Rings 1-2 adjust the voice's buffer params whatever its source (they are
-- ready when it switches to a buffer)
local function arc_buffer_delta(n, delta)
  local ring = ARC_BUFFER_RINGS[n]
  if ring then
    params:delta(arc_buffer_ring_param(ring), delta * ring.scale)
  end
end

-- Rings 1-2 are bright for a buffer-sourced voice and dim otherwise (the
-- buffer params do nothing then); the recording rings are always lit
local function arc_buffer_redraw(arc_port)
  local uses_buffer = voice_uses_buffer(selected_voice)
  for n, ring in ipairs(ARC_BUFFER_RINGS) do
    local level = 12
    if ring.voice_key then
      level = uses_buffer and 15 or 4
    end
    arc_port:segment(n, 0, param_fraction(arc_buffer_ring_param(ring)) * math.pi * 2, level)
  end
end

local function arc_ignore_delta() end
local function arc_draw_nothing() end  -- rings stay off

-- Indexed like UI_PAGES; LFO rings arrive with that page
local ARC_PAGE_DELTA = {arc_main_delta, arc_fx_delta, arc_ignore_delta, arc_buffer_delta, arc_ignore_delta}
local ARC_PAGE_REDRAW = {arc_main_redraw, arc_fx_redraw, arc_draw_nothing, arc_buffer_redraw, arc_draw_nothing}

-- Arc handlers live on the vport only (as for grids): norns fires both
-- device.delta/key and vports[port].delta/key, so setting them on the device
-- as well would run every turn twice.
local function attach_arc(port)
  arc_device = arc.connect(port)
  arc_device.delta = arc_delta
  arc_device.key = arc_key
  arc_connected = arc_device.device ~= nil
end

function arc_init()
  attach_arc(1)
  if arc_connected then
    arc_redraw()
  end
end

function arc.add(device)
  attach_arc(device.port or 1)
  arc_redraw()
  redraw()  -- SETUP shows the arc state
  print("arc connected")
end

function arc.remove(device)
  arc_connected = false
  redraw()
  print("arc disconnected")
end

function arc_delta(n, delta)
  ARC_PAGE_DELTA[ui_page](n, delta)
  arc_redraw()
  redraw()
end

function arc_key(n, s)
  -- Button press (2025 arc): same as K3 on MAIN, nothing on other pages
  if s == 1 and UI_PAGES[ui_page] == "MAIN" then
    start_or_freeze_selected_voice()
    redraw()
  end
end

function arc_redraw()
  if arc_device == nil or arc_device.device == nil then return end

  arc_device:all(0)
  ARC_PAGE_REDRAW[ui_page](arc_device)
  arc_device:refresh()
end

-- Grid functions
local GRID_FADER_ROWS = 4     -- 256-grid parameter page: one fader per row 9-12
local GRID_FADER_WIDTH = 16   -- fader columns
local GRID_FADER_FIRST_ROW = 9
local GRID_PARAM_PAGE_ROW = 13
-- 256-grid BUFFER / FX page (page 4): record (row 1) and clear (row 2)
-- per buffer slot, one FX fader per row 3-7, one source row per voice 9-15
local GRID_BUFFER_RECORD_ROW = 1
local GRID_BUFFER_CLEAR_ROW = 2
local GRID_FX_FADER_IDS = {"filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix"}
local GRID_FX_FIRST_ROW = 3
local GRID_SOURCE_FIRST_ROW = 9  -- voice v's row is 8 + v; column = source option (1 synth, 2-9 buffers, 10 input)

-- Pick a grid's layout by its exact size. 16x16 must be matched exactly or
-- an 8x16 grid (rows == 16) would be treated as a 256.
local function grid_layout(grid_port)
  local cols, rows = grid_port.cols, grid_port.rows
  if cols == 16 and rows == 16 then
    return "256"
  elseif cols == 16 and rows == 8 then
    return "128h"
  elseif cols == 8 and rows == 16 then
    return "128v"
  elseif cols == 8 and rows == 8 then
    return "64"
  end
  return nil
end

-- Store a grid port's vport and route its key events to grid_key. Handlers
-- live on the vport only: norns fires both device.key and vports[port].key,
-- so also setting them on the device would run grid_key twice per press.
local function attach_grid(port)
  local grid_port = grid.connect(port)
  grids[port] = grid_port
  grid_port.key = function(x, y, z)
    grid_key(port, x, y, z)
  end
  return grid_port
end

function grid_init()
  -- Connect up to 4 grids
  for port = 1, MAX_GRID_PORTS do
    if grid.connect(port).device then
      local grid_port = attach_grid(port)
      print("grid " .. port .. " connected: " .. grid_port.cols .. "x" .. grid_port.rows)
    end
  end
  grid_redraw()
end

-- Hot-plug. norns passes the raw device here; store its port's vport (as
-- grid_init does) rather than the device, which has no .device field.
function grid.add(device)
  local port = device.port
  if not port then return end  -- device not assigned to a grid port
  local grid_port = attach_grid(port)
  print("grid " .. port .. " connected: " .. grid_port.cols .. "x" .. grid_port.rows)
  grid_redraw()
  redraw()  -- SETUP lists the connected grids
end

function grid.remove(device)
  local port = device.port
  if not port then return end
  if grids[port] then
    grids[port].key = nil
    grids[port] = nil
  end
  redraw()
  print("grid " .. port .. " disconnected")
end

function grid_key(port, x, y, z)
  if z == 0 then return end  -- Only respond to key presses

  local grid_port = grids[port]
  if not grid_port then return end

  local layout = grid_layout(grid_port)
  if layout == "256" then
    grid_key_256(x, y, z)
  elseif layout == "128h" then
    grid_key_128h(x, y, z)
  elseif layout == "128v" then
    grid_key_128v(x, y, z)
  elseif layout == "64" then
    grid_key_64(x, y, z)
  end

  grid_redraw()
  redraw()
end

-- 16x16 grid layout
function grid_key_256(x, y, z)
  -- Handle page navigation first (always accessible from row 8)
  if y == 8 and x >= 13 and x <= 16 then
    -- Page selection (always accessible)
    grid_page = x - 12
    return
  end

  if grid_page == 3 then
    -- Scene page
    if y == 1 and x <= NUM_SCENES then
      -- Row 1: Scene recall (instant)
      recall_scene(x, 0)
    elseif y == 2 and x <= NUM_SCENES then
      -- Row 2: Scene recall (with transition)
      recall_scene(x, params:get("scene_transition_time"))
    elseif y == 3 and x <= NUM_SCENES then
      -- Row 3: Scene save
      capture_scene(x)
    elseif y == 5 then
      -- Row 5: Scene sequencer controls
      if x == 1 then
        -- Toggle sequencer
        local enabled = params:get("scene_sequencer_enabled")
        params:set("scene_sequencer_enabled", enabled == 1 and 0 or 1)
      elseif x >= 3 and x <= 2 + NUM_SCENES then
        -- Set sequence length
        params:set("scene_sequence_length", x - 2)
      end
    end
  elseif grid_page == 4 then
    -- BUFFER / FX page: buffer rows 1-2, FX faders on rows 3-7, voice
    -- sources on rows 9-15; rows 8 and 16 work as on page 1
    local fx_param_id = GRID_FX_FADER_IDS[y - GRID_FX_FIRST_ROW + 1]
    local source_voice = y - GRID_SOURCE_FIRST_ROW + 1
    if y == GRID_BUFFER_RECORD_ROW then
      -- record into buffer x, or stop its recording early
      if x <= NUM_BUFFERS then record_buffer(x) end
    elseif y == GRID_BUFFER_CLEAR_ROW then
      if x <= NUM_BUFFERS then clear_buffer(x) end
    elseif fx_param_id then
      set_param_from_column(fx_param_id, x)
    elseif source_voice >= 1 and source_voice <= NUM_VOICES then
      if x <= #SOURCE_OPTIONS then
        params:set("v" .. source_voice .. "_source", x)
      end
    elseif y == 8 then
      grid_key_256_transport(x)
    elseif y == 16 then
      grid_key_256_freeze(x)
    end
  elseif y >= 1 and y <= NUM_VOICES then
    -- Rows 1-NUM_VOICES: Pattern triggers for each voice
    toggle_pattern_step(y, x)
  elseif y == 8 then
    grid_key_256_transport(x)
  elseif y >= GRID_FADER_FIRST_ROW and y < GRID_FADER_FIRST_ROW + GRID_FADER_ROWS then
    -- Rows 9-12 (parameter page): one fader per row for the selected voice
    if grid_page == 2 then
      local fader_index = (param_page - 1) * GRID_FADER_ROWS + (y - GRID_FADER_FIRST_ROW + 1)
      set_fader_param(grid_voice_select, fader_index, x)
    end
  elseif y == GRID_PARAM_PAGE_ROW then
    -- Row 13 (parameter page): choose which group of four faders is shown
    if grid_page == 2 and x <= fader_page_count(grid_voice_select) then
      param_page = x
    end
  elseif y == 14 then
    -- Row 14: Voice selection for parameters (columns 1-7), voice
    -- on/off (columns 9-15)
    if x <= NUM_VOICES then
      select_grid_voice(x)
    elseif x >= 9 and x <= 8 + NUM_VOICES then
      toggle_voice(x - 8)
    end
  elseif y == 15 then
    -- Row 15: Pattern operations
    if x <= NUM_VOICES then
      -- Clear pattern for voice
      clear_pattern(x)
    elseif x >= 9 and x <= 8 + NUM_VOICES then
      -- Randomize pattern for voice
      randomize_pattern(x - 8)
    end
  elseif y == 16 then
    grid_key_256_freeze(x)
  end
end

-- 256 row 8: pattern controls (page selection is handled by grid_key_256)
function grid_key_256_transport(x)
  if x <= 4 then
    -- Play/stop
    pattern_toggle()
  elseif x >= 5 and x <= 8 then
    -- Tempo controls
    if x == 5 then params:delta("tempo", -10) end
    if x == 6 then params:delta("tempo", -1) end
    if x == 7 then params:delta("tempo", 1) end
    if x == 8 then params:delta("tempo", 10) end
  end
end

-- 256 row 16: global functions
function grid_key_256_freeze(x)
  if x <= NUM_VOICES then
    -- Freeze voice
    toggle_freeze(x)
  elseif x >= 9 and x <= 16 then
    -- Copy/paste patterns
    -- (Future expansion)
  end
end

-- 16x8 grid layout (128 buttons horizontal)
function grid_key_128h(x, y, z)
  if grid_page == 3 then
    -- Scene page
    if y == 1 and x <= NUM_SCENES then
      -- Row 1: Scene recall (instant)
      recall_scene(x, 0)
    elseif y == 2 and x <= NUM_SCENES then
      -- Row 2: Scene recall (with transition)
      recall_scene(x, params:get("scene_transition_time"))
    elseif y == 3 and x <= NUM_SCENES then
      -- Row 3: Scene save
      capture_scene(x)
    elseif y == 5 and x == 1 then
      -- Toggle scene sequencer
      local enabled = params:get("scene_sequencer_enabled")
      params:set("scene_sequencer_enabled", enabled == 1 and 0 or 1)
    elseif y == 4 and x <= NUM_SCENES then
      -- Row 4: Set sequence length
      params:set("scene_sequence_length", x)
    end
  elseif y >= 1 and y <= NUM_VOICES then
    -- Rows 1-7: Pattern triggers
    toggle_pattern_step(y, x)
  end

  -- Row 8: Always accessible (multi-function)
  if y == 8 then
    if x <= 4 then
      pattern_toggle()
    elseif x == 5 then
      grid_page = 1  -- Patterns
    elseif x == 6 then
      grid_page = 2  -- Parameters
    elseif x == 7 then
      grid_page = 3  -- Scenes
    elseif x >= 9 and x <= 8 + NUM_VOICES then
      -- Voice toggle
      toggle_voice(x - 8)
    elseif x == 16 then
      -- Voice selection for parameters
      select_grid_voice(grid_voice_select % NUM_VOICES + 1)
    end
  end
end

-- 8x16 grid layout (128 buttons vertical)
function grid_key_128v(x, y, z)
  if x >= 1 and x <= NUM_VOICES then
    -- Columns 1-7: Pattern triggers
    if y <= PATTERN_LENGTH then
      toggle_pattern_step(x, y)
    end
  elseif x == 8 then
    -- Column 8: Controls
    if y >= 1 and y <= NUM_VOICES then
      toggle_voice(y)
    elseif y == 9 then
      pattern_toggle()
    elseif y >= 10 and y <= 9 + NUM_VOICES then
      -- Voice selection for parameters
      select_grid_voice(y - 9)
    end
  end
end

-- 8x8 grid layout (64 buttons)
function grid_key_64(x, y, z)
  if y >= 1 and y <= NUM_VOICES then
    -- Rows 1-7: Pattern triggers (only steps 1-8 fit on this grid)
    toggle_pattern_step(y, x)
  elseif y == 8 then
    -- Row 8: Controls
    if x == 1 then
      pattern_toggle()
    elseif x >= 3 and x <= 7 then
      toggle_voice(x - 2)
    end
  end
end

function toggle_pattern_step(voice_idx, step)
  -- Bounds checking to prevent array expansion
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  if step < 1 or step > PATTERN_LENGTH then return end

  if patterns[voice_idx][step] == 0 then
    patterns[voice_idx][step] = 15  -- Full brightness
  else
    patterns[voice_idx][step] = 0
  end
end

function clear_pattern(voice_idx)
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  for step = 1, PATTERN_LENGTH do
    patterns[voice_idx][step] = 0
  end
end

function randomize_pattern(voice_idx)
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  for step = 1, PATTERN_LENGTH do
    if math.random() > 0.5 then
      patterns[voice_idx][step] = math.random(8, 15)
    else
      patterns[voice_idx][step] = 0
    end
  end
end

-- A buffer-sourced voice's first faders: its buffer params and its level
-- (the other synthesis params do nothing while the synth is off)
local BUFFER_FADER_KEYS = {"buf_pos", "buf_rate", "buf_scan", "amp"}
-- The six grain params (envelope shape and grain mode are option params,
-- shown as index faders)
local GRAIN_FADER_KEYS = {"grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_env", "grain_mode"}

local function append_fader_ids(ids, prefix, keys)
  for _, key in ipairs(keys) do
    table.insert(ids, prefix .. key)
  end
end

-- Ordered param IDs for the 256-grid fader page: the voice's synthesis
-- params (param_order), or BUFFER_FADER_KEYS for a buffer source, then the
-- grain params, then the nine crossmod slot values (source, amp mod, freq
-- mod for each slot). An input source has neither synth nor buffer params
-- that do anything: its faders start with the grain params, then its level.
function fader_param_ids(voice_idx)
  local prefix = "v" .. voice_idx .. "_"
  local ids = {}
  if voice_uses_synth(voice_idx) then
    append_fader_ids(ids, prefix, voices[voice_idx].param_order)
    append_fader_ids(ids, prefix, GRAIN_FADER_KEYS)
  elseif voice_uses_buffer(voice_idx) then
    append_fader_ids(ids, prefix, BUFFER_FADER_KEYS)
    append_fader_ids(ids, prefix, GRAIN_FADER_KEYS)
  else
    append_fader_ids(ids, prefix, GRAIN_FADER_KEYS)
    append_fader_ids(ids, prefix, {"amp"})
  end
  for slot = 1, NUM_MOD_SLOTS do
    table.insert(ids, prefix .. "mod_source_" .. slot)
    table.insert(ids, prefix .. "mod_amp_amt_" .. slot)
    table.insert(ids, prefix .. "mod_freq_amt_" .. slot)
  end
  return ids
end

function fader_page_count(voice_idx)
  return math.ceil(#fader_param_ids(voice_idx) / GRID_FADER_ROWS)
end

-- Range of a control param (controlspec), option param (option indices
-- 1..count) or number param (min/max)
function param_range(param_id)
  local param = params:lookup_param(param_id)
  if param.controlspec then
    return param.controlspec.minval, param.controlspec.maxval
  end
  if param.options then  -- option param (norns' param.t is a number, so test the field)
    return 1, param.count
  end
  return param.min, param.max
end

-- A param's current value as a fraction (0-1) of its range. Control params
-- follow their controlspec warp (exp for freq, cutoff, mod speed); number
-- params (mod sources) and option params (grain envelope) are linear.
function param_fraction(param_id)
  local spec = params:lookup_param(param_id).controlspec
  if spec then
    return spec:unmap(params:get(param_id))
  end
  local minval, maxval = param_range(param_id)
  return util.linlin(minval, maxval, 0, 1, params:get(param_id))
end

-- Grid column x (1-16) sets a param across its range. Control params follow
-- their controlspec warp; number params (mod sources) and option params
-- (grain envelope, as an option index) map linearly to integers.
function set_param_from_column(param_id, x)
  local spec = params:lookup_param(param_id).controlspec
  local value
  if spec then
    value = spec:map((x - 1) / (GRID_FADER_WIDTH - 1))
  else
    local minval, maxval = param_range(param_id)
    value = util.round(util.linlin(1, GRID_FADER_WIDTH, minval, maxval, x))
  end
  params:set(param_id, value)
end

-- Column x on one of the parameter page's faders
function set_fader_param(voice_idx, fader_index, x)
  local param_id = fader_param_ids(voice_idx)[fader_index]
  if not param_id then return end
  set_param_from_column(param_id, x)
end

-- Grid column (1-16) that shows a fader param's current value
function fader_position(param_id)
  return util.round(param_fraction(param_id) * (GRID_FADER_WIDTH - 1) + 1)
end

function select_grid_voice(voice_idx)
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  grid_voice_select = voice_idx
  param_page = util.clamp(param_page, 1, fader_page_count(voice_idx))
end

function pattern_toggle()
  if pattern_playing then
    pattern_clock_stop()
  else
    pattern_clock_start()
  end
end

function pattern_clock_start()
  if pattern_clock then
    clock.cancel(pattern_clock)
  end

  pattern_playing = true
  pattern_position = 1

  pattern_clock = clock.run(function()
    while pattern_playing do
      -- Trigger voices that have active steps
      for voice_idx = 1, NUM_VOICES do
        if patterns[voice_idx][pattern_position] > 0 then
          if voices[voice_idx].active then
            -- Voice is already running: accent it in place, at the step's
            -- level (1-15) as velocity. A step must never create new synth
            -- nodes (toggling would stack whole voice/grain/mod chains
            -- through their long release tails).
            engine.retrigger(voice_idx - 1, patterns[voice_idx][pattern_position] / MAX_STEP_LEVEL)
          else
            -- Voice is off - turn it on
            toggle_voice(voice_idx)
          end
        end
      end

      -- Show the step that just played, then advance
      grid_redraw()
      pattern_position = pattern_position % PATTERN_LENGTH + 1

      -- Wait for next step based on tempo
      clock.sync(1/4)  -- 16th notes
    end
  end)
end

function pattern_clock_stop()
  pattern_playing = false
  if pattern_clock then
    clock.cancel(pattern_clock)
    pattern_clock = nil
  end
  grid_redraw()
end

-- LED level for a pattern step: its stored level, or at the playhead 15 for
-- an active step and 4 for an empty one
function step_brightness(voice_idx, step)
  local level = patterns[voice_idx][step]
  if pattern_playing and step == pattern_position then
    return level > 0 and 15 or 4
  end
  return level
end

function grid_redraw()
  if next(grids) == nil then return end  -- no grids: nothing to do

  for _, grid_port in pairs(grids) do
    if grid_port.device then
      local layout = grid_layout(grid_port)

      grid_port:all(0)

      if layout == "256" then
        grid_redraw_256(grid_port)
      elseif layout == "128h" then
        grid_redraw_128h(grid_port)
      elseif layout == "128v" then
        grid_redraw_128v(grid_port)
      elseif layout == "64" then
        grid_redraw_64(grid_port)
      end

      grid_port:refresh()
    end
  end
end

function grid_redraw_256(grid_device)
  if grid_page == 3 then
    -- Scene page
    -- Row 1: Scene recall (instant)
    for i = 1, NUM_SCENES do
      local brightness = scenes[i].populated and 8 or 2
      if current_scene == i then brightness = 15 end
      grid_device:led(i, 1, brightness)
    end

    -- Row 2: Scene recall (with transition)
    for i = 1, NUM_SCENES do
      local brightness = scenes[i].populated and 6 or 2
      grid_device:led(i, 2, brightness)
    end

    -- Row 3: Scene save
    for i = 1, NUM_SCENES do
      grid_device:led(i, 3, 4)
    end

    -- Row 5: Scene sequencer controls
    if scene_sequencer_enabled then
      grid_device:led(1, 5, 15)  -- Sequencer on
      -- Show next scene in sequence
      if scene_sequencer_position >= 1 and scene_sequencer_position <= NUM_SCENES then
        grid_device:led(scene_sequencer_position, 1, 15)
      end
    else
      grid_device:led(1, 5, 4)  -- Sequencer off
    end

    -- Sequence length indicators
    local seq_length = params:get("scene_sequence_length")
    for i = 1, NUM_SCENES do
      grid_device:led(i + 2, 5, i <= seq_length and 8 or 2)
    end

    grid_redraw_256_page_row(grid_device)
  elseif grid_page == 4 then
    -- BUFFER / FX page: buffer rows 1-2, FX faders on rows 3-7, voice
    -- sources on rows 9-15, rows 8 and 16 as on page 1
    grid_redraw_256_buffers(grid_device)
    for index, param_id in ipairs(GRID_FX_FADER_IDS) do
      grid_redraw_fader_row(grid_device, GRID_FX_FIRST_ROW + index - 1, param_id)
    end
    grid_redraw_256_sources(grid_device)
    grid_redraw_256_transport(grid_device)
    grid_redraw_256_freeze(grid_device)
  else
    -- Patterns/parameters pages
    -- Draw patterns (rows 1-NUM_VOICES)
    for voice_idx = 1, NUM_VOICES do
      for step = 1, PATTERN_LENGTH do
        local brightness = step_brightness(voice_idx, step)
        grid_device:led(step, voice_idx, brightness)
      end
    end

    grid_redraw_256_transport(grid_device)

    -- Rows 9-13 (parameter page): faders and fader page selection
    if grid_page == 2 then
      grid_redraw_faders(grid_device)
    end

    -- Row 14: Voice status
    for i = 1, NUM_VOICES do
      grid_device:led(i, 14, i == grid_voice_select and 15 or 4)
      grid_device:led(i + 8, 14, voices[i].active and 12 or 2)
    end

    grid_redraw_256_freeze(grid_device)
  end
end

-- 256 page 4, rows 1-2: buffer state (15 recording, 8 loaded, 2 empty)
-- above each slot's clear key
function grid_redraw_256_buffers(grid_device)
  for slot = 1, NUM_BUFFERS do
    local buffer = buffers[slot]
    local level = 2
    if buffer.recording then
      level = 15
    elseif buffer.loaded then
      level = 8
    end
    grid_device:led(slot, GRID_BUFFER_RECORD_ROW, level)
    grid_device:led(slot, GRID_BUFFER_CLEAR_ROW, 4)
  end
end

-- 256 page 4, rows 9-15: each voice's source (selected 15, others 4, empty
-- buffers 2)
function grid_redraw_256_sources(grid_device)
  for voice_idx = 1, NUM_VOICES do
    local y = GRID_SOURCE_FIRST_ROW + voice_idx - 1
    for source = 1, #SOURCE_OPTIONS do
      local level = 4
      local slot = source - SOURCE_SYNTH
      if source == voices[voice_idx].source then
        level = 15
      elseif valid_buffer_slot(slot) and not (buffers[slot].loaded or buffers[slot].recording) then
        level = 2
      end
      grid_device:led(source, y, level)
    end
  end
end

-- 256 row 8, columns 13-16: page indicators
function grid_redraw_256_page_row(grid_device)
  for i = 1, 4 do
    grid_device:led(12 + i, 8, i == grid_page and 15 or 2)
  end
end

-- 256 row 8: pattern controls, tempo and page indicators
function grid_redraw_256_transport(grid_device)
  if pattern_playing then
    grid_device:led(1, 8, 15)
    grid_device:led(2, 8, 15)
  else
    grid_device:led(1, 8, 4)
    grid_device:led(2, 8, 4)
  end

  -- Tempo indicators
  grid_device:led(5, 8, 2)
  grid_device:led(6, 8, 2)
  grid_device:led(7, 8, 2)
  grid_device:led(8, 8, 2)

  grid_redraw_256_page_row(grid_device)
end

-- 256 row 16: freeze status
function grid_redraw_256_freeze(grid_device)
  for i = 1, NUM_VOICES do
    grid_device:led(i, 16, frozen[i] and 12 or 2)
  end
end

-- One fader on row y: a bar (brightness 8) up to the param's current value,
-- with the value's own column at 15
function grid_redraw_fader_row(grid_device, y, param_id)
  local position = fader_position(param_id)
  for x = 1, position - 1 do
    grid_device:led(x, y, 8)
  end
  grid_device:led(position, y, 15)
end

-- Fader rows 9-12 for the selected voice's fader page. Row 13 shows the
-- fader pages, selected at 15.
function grid_redraw_faders(grid_device)
  local ids = fader_param_ids(grid_voice_select)
  for row = 1, GRID_FADER_ROWS do
    local param_id = ids[(param_page - 1) * GRID_FADER_ROWS + row]
    if param_id then
      grid_redraw_fader_row(grid_device, GRID_FADER_FIRST_ROW + row - 1, param_id)
    end
  end
  for page = 1, fader_page_count(grid_voice_select) do
    grid_device:led(page, GRID_PARAM_PAGE_ROW, page == param_page and 15 or 4)
  end
end

function grid_redraw_128h(grid_device)
  if grid_page == 3 then
    -- Scene page (simplified for 128h layout)
    -- Row 1: Scene recall (instant)
    for i = 1, NUM_SCENES do
      local brightness = scenes[i].populated and 8 or 2
      if current_scene == i then brightness = 15 end
      grid_device:led(i, 1, brightness)
    end

    -- Row 2: Scene recall (with transition)
    for i = 1, NUM_SCENES do
      local brightness = scenes[i].populated and 6 or 2
      grid_device:led(i, 2, brightness)
    end

    -- Row 3: Scene save
    for i = 1, NUM_SCENES do
      grid_device:led(i, 3, 4)
    end

    -- Row 5: Scene sequencer controls
    if scene_sequencer_enabled then
      grid_device:led(1, 5, 15)  -- Sequencer on
    else
      grid_device:led(1, 5, 4)  -- Sequencer off
    end

    -- Sequence length indicators (simplified)
    local seq_length = params:get("scene_sequence_length")
    for i = 1, NUM_SCENES do
      grid_device:led(i, 4, i <= seq_length and 8 or 2)
    end
  else
    -- Pattern/parameter pages
    -- Draw patterns (rows 1-NUM_VOICES)
    for voice_idx = 1, NUM_VOICES do
      for step = 1, PATTERN_LENGTH do
        local brightness = step_brightness(voice_idx, step)
        grid_device:led(step, voice_idx, brightness)
      end
    end
  end

  -- Row 8: Controls (always visible)
  if pattern_playing then
    grid_device:led(1, 8, 15)
    grid_device:led(2, 8, 15)
  else
    grid_device:led(1, 8, 4)
    grid_device:led(2, 8, 4)
  end

  -- Page indicators (3 pages now)
  grid_device:led(5, 8, grid_page == 1 and 15 or 4)
  grid_device:led(6, 8, grid_page == 2 and 15 or 4)
  grid_device:led(7, 8, grid_page == 3 and 15 or 4)

  -- Voice status
  for i = 1, NUM_VOICES do
    grid_device:led(i + 8, 8, voices[i].active and 12 or 2)
  end

  -- Voice selection indicator
  grid_device:led(16, 8, 8)
end

function grid_redraw_128v(grid_device)
  -- Draw patterns (columns 1-NUM_VOICES)
  for voice_idx = 1, NUM_VOICES do
    for step = 1, PATTERN_LENGTH do
      local brightness = step_brightness(voice_idx, step)
      grid_device:led(voice_idx, step, brightness)
    end
  end

  -- Column 8: Controls
  for i = 1, NUM_VOICES do
    grid_device:led(8, i, voices[i].active and 12 or 4)
  end
  grid_device:led(8, 9, pattern_playing and 15 or 4)

  -- Voice selection
  for i = 1, NUM_VOICES do
    grid_device:led(8, 9 + i, (i == grid_voice_select) and 15 or 2)
  end
end

function grid_redraw_64(grid_device)
  -- Draw patterns (rows 1-7). Only the first 8 steps of each 16-step
  -- pattern fit; the sequencer still plays all PATTERN_LENGTH steps.
  local visible_steps = math.min(PATTERN_LENGTH, grid_device.cols)
  for voice_idx = 1, NUM_VOICES do
    for step = 1, visible_steps do
      local brightness = step_brightness(voice_idx, step)
      grid_device:led(step, voice_idx, brightness)
    end
  end

  -- Row 8: Controls
  grid_device:led(1, 8, pattern_playing and 15 or 4)
  for i = 1, 5 do
    grid_device:led(i + 2, 8, voices[i].active and 12 or 4)
  end
end

function cleanup()
  -- Save scenes to disk before exiting, unless that would overwrite a scenes
  -- file that failed to load and could not be moved aside
  if scene_autosave_blocked then
    print("scenes not auto-saved: " .. scene_data_file .. " could not be loaded")
  else
    save_scenes_to_disk()
  end

  -- Remember each buffer's file or scratch take for the next start
  if buffer_autosave_blocked then
    print("buffer paths not auto-saved: " .. buffer_data_file .. " could not be loaded")
  else
    save_buffers_to_disk()
  end

  -- Stop metros and clocks
  if lfo_metro then lfo_metro:stop() end

  -- Sync mutation metro state with param
  if mutation_metro then
    mutation_metro:stop()
    -- Ensure param matches actual state
    params:set("mutation_enabled", 0)
  end

  pattern_clock_stop()

  -- Stop the scene sequencer through its param so param and state agree
  params:set("scene_sequencer_enabled", 0)
  scene_sequencer_stop()

  -- Cancel any active transition clock
  cancel_scene_transition()

  -- Stop the buffer poll and recording timers (the engine finishes or
  -- frees any recording itself)
  if buffer_state_poll then buffer_state_poll:stop() end
  for slot = 1, NUM_BUFFERS do
    cancel_buffer_recording_timer(slot)
  end

  -- Turn off all voices
  for i = 1, NUM_VOICES do
    if voices[i].active then
      engine.voiceOff(i - 1)
    end
  end

  -- Leave connected controllers dark
  for _, grid_port in pairs(grids) do
    grid_port:all(0)
    grid_port:refresh()
  end
  if arc_device then
    arc_device:all(0)
    arc_device:refresh()
  end
end

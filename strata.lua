-- strata.lua
-- ambient granular layers
--
-- E1: master density
-- E2: select voice/param
-- E3: adjust value
-- K2: randomize voice
-- K3: freeze/unfreeze

engine.name = "Strata"

local MusicUtil = require "musicutil"
local UI = require "ui"

-- State
local voices = {
  {
    name = "resonator",
    active = false,
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
      spread = 0.5
    }
  },
  {
    name = "fm",
    active = false,
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
      spread = 0.3
    }
  },
  {
    name = "folder",
    active = false,
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
      spread = 0.4
    }
  },
  {
    name = "sub",
    active = false,
    params = {
      freq = 40,
      amp = 0.4,
      drift = 0.02
    },
    grain = {
      size = 0.2,
      density = 10,
      pitch = 1,
      spread = 0.2
    }
  }
}

local selected_voice = 1
local selected_param = 1
local master_density = 1.0
local frozen = {false, false, false, false}

-- UI
local voice_list
local param_names = {}

-- LFOs for parameter modulation
local lfo_metro

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
  
  params:add{
    type = "control",
    id = "drift_amount",
    name = "tape drift",
    controlspec = controlspec.new(0, 0.1, "lin", 0.001, 0.01),
    action = function(x)
      engine.setMasterDrift(x)
    end
  }
  
  -- Reverb
  params:add_separator("reverb")
  params:add{
    type = "control",
    id = "reverb_mix",
    name = "mix",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0.3),
    action = function(x)
      engine.setReverb(x, params:get("reverb_size"), params:get("reverb_damp"))
    end
  }
  
  params:add{
    type = "control",
    id = "reverb_size",
    name = "size",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0.8),
    action = function(x)
      engine.setReverb(params:get("reverb_mix"), x, params:get("reverb_damp"))
    end
  }
  
  params:add{
    type = "control",
    id = "reverb_damp",
    name = "damping",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5),
    action = function(x)
      engine.setReverb(params:get("reverb_mix"), params:get("reverb_size"), x)
    end
  }
  
  -- Add params for each voice
  for i = 1, #voices do
    add_voice_params(i)
  end
  
  -- UI setup
  voice_list = UI.List.new(0, 0, 1, {})
  update_voice_list()
  
  -- Start LFO system
  lfo_metro = metro.init()
  lfo_metro.time = 0.1
  lfo_metro.event = lfo_update
  lfo_metro:start()
  
  -- Start with first two voices
  toggle_voice(1)
  clock.sleep(0.5)
  toggle_voice(2)
  
  redraw()
end

function add_voice_params(voice_idx)
  local v = voices[voice_idx]
  params:add_separator("voice " .. voice_idx .. ": " .. v.name)
  
  -- Voice params
  for key, value in pairs(v.params) do
    local spec = get_param_spec(key)
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
    controlspec = controlspec.new(0.25, 4, "lin", 0.01, v.grain.pitch),
    action = function(x)
      voices[voice_idx].grain.pitch = x
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
    ratio = controlspec.new(0.5, 8, "lin", 0.1, 1.5),
    index = controlspec.new(0, 10, "lin", 0.1, 2),
    modFreq = controlspec.new(0.01, 1, "lin", 0.01, 0.05),
    fold = controlspec.new(0.1, 5, "lin", 0.1, 1),
    mod = controlspec.new(0.01, 2, "lin", 0.01, 0.2),
    drift = controlspec.new(0.001, 0.1, "lin", 0.001, 0.02)
  }
  return specs[param_name] or controlspec.new(0, 1, "lin", 0.01, 0.5)
end

function toggle_voice(voice_idx)
  local v = voices[voice_idx]
  
  if v.active then
    engine.voiceOff(voice_idx - 1)
    v.active = false
  else
    engine.voiceOn(
      voice_idx - 1,
      v.params.freq,
      v.params.amp,
      v.params.pan or 0,
      v.grain.size,
      v.grain.density * master_density,
      v.grain.pitch
    )
    v.active = true
  end
  
  update_voice_list()
  redraw()
end

function randomize_voice(voice_idx)
  if frozen[voice_idx] then return end
  
  local v = voices[voice_idx]
  
  -- Randomize synth params
  for key, _ in pairs(v.params) do
    if key ~= "amp" then -- Don't randomize amplitude
      local spec = get_param_spec(key)
      local new_val = math.random() * (spec.maxval - spec.minval) + spec.minval
      params:set("v" .. voice_idx .. "_" .. key, new_val)
    end
  end
  
  -- Randomize some grain params
  params:set("v" .. voice_idx .. "_grain_size", math.random() * 0.3 + 0.05)
  params:set("v" .. voice_idx .. "_grain_pitch", math.random() * 2 + 0.5)
  
  redraw()
end

function update_all_grain_density()
  for i = 1, #voices do
    if voices[i].active then
      engine.setGrainParam(i - 1, "grainDensity", voices[i].grain.density * master_density)
    end
  end
end

function lfo_update()
  -- Slow parameter modulation for active, non-frozen voices
  for i = 1, #voices do
    if voices[i].active and not frozen[i] then
      -- Add subtle modulation here if desired
      -- For example, slowly drift grain parameters
      local drift = (math.random() - 0.5) * 0.02
      local current = params:get("v" .. i .. "_grain_pitch")
      params:set("v" .. i .. "_grain_pitch", util.clamp(current + drift, 0.25, 4))
    end
  end
end

function update_voice_list()
  local items = {}
  for i = 1, #voices do
    local status = voices[i].active and "●" or "○"
    local freeze = frozen[i] and " [F]" or ""
    items[i] = status .. " " .. voices[i].name .. freeze
  end
  voice_list:set_items(items)
  voice_list.index = selected_voice
end

-- Encoders
function enc(n, d)
  if n == 1 then
    params:delta("master_density", d)
  elseif n == 2 then
    selected_voice = util.clamp(selected_voice + d, 1, #voices)
    update_voice_list()
  elseif n == 3 then
    -- Adjust selected voice's main parameter
    local v = voices[selected_voice]
    if v.name == "resonator" then
      params:delta("v" .. selected_voice .. "_freq", d)
    elseif v.name == "fm" then
      params:delta("v" .. selected_voice .. "_index", d)
    elseif v.name == "folder" then
      params:delta("v" .. selected_voice .. "_fold", d)
    elseif v.name == "sub" then
      params:delta("v" .. selected_voice .. "_drift", d)
    end
  end
  redraw()
end

-- Keys
function key(n, z)
  if z == 1 then
    if n == 2 then
      randomize_voice(selected_voice)
    elseif n == 3 then
      if not voices[selected_voice].active then
        toggle_voice(selected_voice)
      else
        frozen[selected_voice] = not frozen[selected_voice]
        update_voice_list()
      end
    end
  end
  redraw()
end

-- Redraw
function redraw()
  screen.clear()
  
  -- Title
  screen.level(15)
  screen.move(0, 8)
  screen.text("STRATA")
  
  screen.move(90, 8)
  screen.level(4)
  screen.text("density: " .. string.format("%.2f", master_density))
  
  -- Voice list
  voice_list:redraw()
  
  -- Selected voice info
  local v = voices[selected_voice]
  screen.move(0, 55)
  screen.level(frozen[selected_voice] and 3 or 8)
  if v.name == "resonator" then
    screen.text("freq: " .. string.format("%.0f", v.params.freq))
  elseif v.name == "fm" then
    screen.text("index: " .. string.format("%.1f", v.params.index))
  elseif v.name == "folder" then
    screen.text("fold: " .. string.format("%.1f", v.params.fold))
  elseif v.name == "sub" then
    screen.text("drift: " .. string.format("%.3f", v.params.drift))
  end
  
  screen.move(0, 64)
  screen.level(4)
  screen.text("K2:rand K3:" .. (v.active and "freeze" or "start"))
  
  screen.update()
end

function cleanup()
  lfo_metro:stop()
  for i = 1, #voices do
    if voices[i].active then
      engine.voiceOff(i - 1)
    end
  end
end

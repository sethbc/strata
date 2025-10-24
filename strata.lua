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
    },
    crossmod = {
      source = 0,  -- 0 = none, 1-4 = voice number
      amp_amt = 0,
      freq_amt = 0,
      speed = 10
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
    },
    crossmod = {
      source = 0,
      amp_amt = 0,
      freq_amt = 0,
      speed = 10
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
    },
    crossmod = {
      source = 0,
      amp_amt = 0,
      freq_amt = 0,
      speed = 10
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
    },
    crossmod = {
      source = 0,
      amp_amt = 0,
      freq_amt = 0,
      speed = 10
    }
  },
  {
    name = "pulse",
    active = false,
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
      spread = 0.35
    },
    crossmod = {
      source = 0,
      amp_amt = 0,
      freq_amt = 0,
      speed = 10
    }
  },
  {
    name = "karplus",
    active = false,
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
      spread = 0.25
    },
    crossmod = {
      source = 0,
      amp_amt = 0,
      freq_amt = 0,
      speed = 10
    }
  },
  {
    name = "ring",
    active = false,
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
      spread = 0.4
    },
    crossmod = {
      source = 0,
      amp_amt = 0,
      freq_amt = 0,
      speed = 10
    }
  }
}

local selected_voice = 1
local selected_param = 1
local master_density = 1.0
local frozen = {false, false, false, false, false, false, false}

-- UI
local voice_list
local param_names = {}

-- LFOs for parameter modulation
local lfo_metro

-- Arc device
local a = nil
local arc_connected = false

-- Grid devices (support multiple grids)
local grids = {}
local grid_dirty = true

-- Pattern sequencer
local patterns = {}
local pattern_length = 16
local pattern_position = 1
local pattern_playing = false
local pattern_clock = nil
local tempo = 120

-- Grid UI state
local grid_page = 1  -- 1=patterns, 2=parameters
local param_page = 1
local grid_voice_select = 1

-- Initialize patterns for each voice
for i = 1, 7 do
  patterns[i] = {}
  for step = 1, 16 do
    patterns[i][step] = 0  -- 0=off, 1-15=velocity/brightness
  end
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
  
  params:add{
    type = "control",
    id = "drift_amount",
    name = "tape drift",
    controlspec = controlspec.new(0, 0.1, "lin", 0.001, 0.01),
    action = function(x)
      engine.setMasterDrift(x)
    end
  }

  params:add{
    type = "number",
    id = "tempo",
    name = "tempo",
    min = 40,
    max = 300,
    default = 120,
    action = function(x)
      tempo = x
    end
  }
  
  -- Reverb
  params:add_separator("strata_reverb")
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
  update_voice_list()
  
  -- Start LFO system
  lfo_metro = metro.init()
  lfo_metro.time = 0.1
  lfo_metro.event = lfo_update
  lfo_metro:start()

  -- Connect arc
  arc_init()

  -- Connect grids
  grid_init()

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

  -- Cross-modulation params
  params:add_separator("voice " .. voice_idx .. " cross-modulation")

  params:add{
    type = "number",
    id = "v" .. voice_idx .. "_mod_source",
    name = "mod source",
    min = 0,
    max = 7,
    default = v.crossmod.source,
    formatter = function(param)
      if param:get() == 0 then
        return "none"
      else
        return "voice " .. param:get()
      end
    end,
    action = function(x)
      voices[voice_idx].crossmod.source = x
      if voices[voice_idx].active then
        -- Convert to SC indexing: 0=none becomes -1, 1-7 become 0-6
        local sc_source = x == 0 and -1 or (x - 1)
        engine.setModSource(voice_idx - 1, sc_source)
      end
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_mod_amp_amt",
    name = "amp mod amount",
    controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.amp_amt),
    action = function(x)
      voices[voice_idx].crossmod.amp_amt = x
      if voices[voice_idx].active then
        engine.setModAmpAmt(voice_idx - 1, x)
      end
    end
  }

  params:add{
    type = "control",
    id = "v" .. voice_idx .. "_mod_freq_amt",
    name = "freq mod amount",
    controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.freq_amt),
    action = function(x)
      voices[voice_idx].crossmod.freq_amt = x
      if voices[voice_idx].active then
        engine.setModFreqAmt(voice_idx - 1, x)
      end
    end
  }

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
    ratio = controlspec.new(0.5, 8, "lin", 0.1, 1.5),
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
  voice_list = UI.ScrollingList.new(0, 10, 1, items)
  voice_list.num_visible = 5
  voice_list.num_above_selected = 1
  voice_list.active = true
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
    elseif v.name == "pulse" then
      params:delta("v" .. selected_voice .. "_width", d)
    elseif v.name == "karplus" then
      params:delta("v" .. selected_voice .. "_decay", d)
    elseif v.name == "ring" then
      params:delta("v" .. selected_voice .. "_ratio", d)
    end
  end
  arc_redraw()
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

  -- Master density (top right)
  screen.move(70, 8)
  screen.level(4)
  screen.text("dens:" .. string.format("%.2f", master_density))

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
    screen.move(90, 26)
    screen.level(8)
    screen.text("[FREEZE]")
  end

  -- Main parameter
  screen.level(frozen[selected_voice] and 3 or 10)
  screen.move(65, 36)
  if v.name == "resonator" then
    screen.text("freq")
    screen.move(65, 44)
    screen.text(string.format("%.0f Hz", v.params.freq))
  elseif v.name == "fm" then
    screen.text("index")
    screen.move(65, 44)
    screen.text(string.format("%.1f", v.params.index))
  elseif v.name == "folder" then
    screen.text("fold")
    screen.move(65, 44)
    screen.text(string.format("%.1f", v.params.fold))
  elseif v.name == "sub" then
    screen.text("drift")
    screen.move(65, 44)
    screen.text(string.format("%.3f", v.params.drift))
  elseif v.name == "pulse" then
    screen.text("width")
    screen.move(65, 44)
    screen.text(string.format("%.2f", v.params.width))
  elseif v.name == "karplus" then
    screen.text("decay")
    screen.move(65, 44)
    screen.text(string.format("%.1f s", v.params.decay))
  elseif v.name == "ring" then
    screen.text("ratio")
    screen.move(65, 44)
    screen.text(string.format("%.2f", v.params.ratio))
  end

  -- Key hints (bottom)
  screen.move(0, 64)
  screen.level(4)
  screen.text("K2:rand K3:" .. (v.active and "freeze" or "start"))

  screen.update()
end

-- Arc functions
function arc_init()
  a = arc.connect()
  a.delta = arc_delta
  a.key = arc_key
  arc_redraw()
end

function arc.add()
  arc_connected = true
  arc_init()
  print("arc connected")
end

function arc.remove()
  arc_connected = false
  a = nil
  print("arc disconnected")
end

function arc_delta(n, delta)
  if n == 1 then
    -- Encoder 1: Master density
    params:delta("master_density", delta / 20)
  elseif n == 2 then
    -- Encoder 2: Selected voice's main parameter
    local v = voices[selected_voice]
    if v.name == "resonator" then
      params:delta("v" .. selected_voice .. "_freq", delta)
    elseif v.name == "fm" then
      params:delta("v" .. selected_voice .. "_index", delta / 10)
    elseif v.name == "folder" then
      params:delta("v" .. selected_voice .. "_fold", delta / 10)
    elseif v.name == "sub" then
      params:delta("v" .. selected_voice .. "_drift", delta / 100)
    elseif v.name == "pulse" then
      params:delta("v" .. selected_voice .. "_width", delta / 100)
    elseif v.name == "karplus" then
      params:delta("v" .. selected_voice .. "_decay", delta / 10)
    elseif v.name == "ring" then
      params:delta("v" .. selected_voice .. "_ratio", delta / 100)
    end
  elseif n == 3 then
    -- Encoder 3: Grain size
    params:delta("v" .. selected_voice .. "_grain_size", delta / 100)
  elseif n == 4 then
    -- Encoder 4: Grain density
    params:delta("v" .. selected_voice .. "_grain_density", delta / 10)
  end
  arc_redraw()
  redraw()
end

function arc_key(n, s)
  -- Button press (2025 arc) - same as K3
  if s == 1 then
    if not voices[selected_voice].active then
      toggle_voice(selected_voice)
    else
      frozen[selected_voice] = not frozen[selected_voice]
      update_voice_list()
    end
    redraw()
  end
end

function arc_redraw()
  if a == nil then return end

  a:all(0)

  -- Ring 1: Master density (0.1 to 2.0)
  local density_pos = util.linlin(0.1, 2.0, 0, 64, master_density)
  a:segment(1, 0, density_pos / 64 * math.pi * 2, 15)

  -- Ring 2: Selected voice's main parameter
  local v = voices[selected_voice]
  local param_val = 0
  local param_min = 0
  local param_max = 1

  if v.name == "resonator" then
    param_val = v.params.freq
    param_min = 20
    param_max = 2000
  elseif v.name == "fm" then
    param_val = v.params.index
    param_min = 0
    param_max = 10
  elseif v.name == "folder" then
    param_val = v.params.fold
    param_min = 0.1
    param_max = 5
  elseif v.name == "sub" then
    param_val = v.params.drift
    param_min = 0.001
    param_max = 0.1
  elseif v.name == "pulse" then
    param_val = v.params.width
    param_min = 0.05
    param_max = 0.95
  elseif v.name == "karplus" then
    param_val = v.params.decay
    param_min = 0.5
    param_max = 10
  elseif v.name == "ring" then
    param_val = v.params.ratio
    param_min = 0.5
    param_max = 8
  end

  local param_pos = util.linlin(param_min, param_max, 0, 64, param_val)
  a:segment(2, 0, param_pos / 64 * math.pi * 2, v.active and 15 or 4)

  -- Ring 3: Grain size (0.01 to 0.5)
  local grain_size_pos = util.linlin(0.01, 0.5, 0, 64, v.grain.size)
  a:segment(3, 0, grain_size_pos / 64 * math.pi * 2, v.active and 12 or 3)

  -- Ring 4: Grain density (1 to 100)
  local grain_density_pos = util.linlin(1, 100, 0, 64, v.grain.density)
  a:segment(4, 0, grain_density_pos / 64 * math.pi * 2, v.active and 12 or 3)

  a:refresh()
end

-- Grid functions
function grid_init()
  -- Connect up to 4 grids
  for i = 1, 4 do
    local g = grid.connect(i)
    if g.device then
      grids[i] = g
      grids[i].key = function(x, y, z)
        grid_key(i, x, y, z)
      end
      print("grid " .. i .. " connected: " .. g.cols .. "x" .. g.rows)
    end
  end
  grid_redraw()
end

function grid.add(g)
  local port = g.port or 1
  grids[port] = g
  grids[port].key = function(x, y, z)
    grid_key(port, x, y, z)
  end
  print("grid " .. port .. " connected: " .. g.cols .. "x" .. g.rows)
  grid_redraw()
end

function grid.remove(g)
  local port = g.port or 1
  grids[port] = nil
  print("grid " .. port .. " disconnected")
end

function grid_key(grid_id, x, y, z)
  if z == 0 then return end  -- Only respond to key presses

  local g = grids[grid_id]
  if not g then return end

  local cols = g.cols
  local rows = g.rows

  -- Determine grid layout based on size
  if rows >= 16 then
    -- 16x16 grid (256 buttons) - full layout
    grid_key_256(x, y, z)
  elseif cols == 16 and rows == 8 then
    -- 16x8 grid (128 buttons horizontal)
    grid_key_128h(x, y, z)
  elseif cols == 8 and rows == 16 then
    -- 8x16 grid (128 buttons vertical)
    grid_key_128v(x, y, z)
  elseif cols == 8 and rows == 8 then
    -- 8x8 grid (64 buttons)
    grid_key_64(x, y, z)
  end

  grid_redraw()
  redraw()
end

-- 16x16 grid layout
function grid_key_256(x, y, z)
  if y >= 1 and y <= 7 then
    -- Rows 1-7: Pattern triggers for each voice
    toggle_pattern_step(y, x)
  elseif y == 8 then
    -- Row 8: Pattern controls
    if x <= 4 then
      -- Play/stop
      pattern_toggle()
    elseif x >= 5 and x <= 8 then
      -- Tempo controls
      if x == 5 then params:delta("tempo", -10) end
      if x == 6 then params:delta("tempo", -1) end
      if x == 7 then params:delta("tempo", 1) end
      if x == 8 then params:delta("tempo", 10) end
    elseif x >= 13 and x <= 16 then
      -- Page selection
      grid_page = x - 12
    end
  elseif y >= 9 and y <= 12 then
    -- Rows 9-12: Parameter manipulation
    if grid_page == 2 then
      manipulate_parameter(grid_voice_select, (y - 9) * 16 + x, z)
    end
  elseif y == 13 then
    -- Row 13: Parameter page
    param_page = util.clamp(x, 1, 4)
  elseif y == 14 then
    -- Row 14: Voice selection for parameters
    if x <= 7 then
      grid_voice_select = x
    elseif x >= 9 and x <= 15 then
      -- Toggle voice on/off
      local voice_idx = x - 8
      if voice_idx <= 7 then
        toggle_voice(voice_idx)
      end
    end
  elseif y == 15 then
    -- Row 15: Pattern operations
    if x <= 7 then
      -- Clear pattern for voice
      clear_pattern(x)
    elseif x >= 9 and x <= 15 then
      -- Randomize pattern for voice
      local voice_idx = x - 8
      if voice_idx <= 7 then
        randomize_pattern(voice_idx)
      end
    end
  elseif y == 16 then
    -- Row 16: Global functions
    if x <= 7 then
      -- Freeze voice
      if x <= 7 then
        frozen[x] = not frozen[x]
        update_voice_list()
      end
    elseif x >= 9 and x <= 16 then
      -- Copy/paste patterns
      -- (Future expansion)
    end
  end
end

-- 16x8 grid layout (128 buttons horizontal)
function grid_key_128h(x, y, z)
  if y >= 1 and y <= 7 then
    -- Rows 1-7: Pattern triggers
    toggle_pattern_step(y, x)
  elseif y == 8 then
    -- Row 8: Multi-function
    if x <= 4 then
      pattern_toggle()
    elseif x == 5 then
      grid_page = 1  -- Patterns
    elseif x == 6 then
      grid_page = 2  -- Parameters
    elseif x >= 9 and x <= 15 then
      -- Voice toggle
      local voice_idx = x - 8
      if voice_idx <= 7 then
        toggle_voice(voice_idx)
      end
    elseif x == 16 then
      -- Voice selection for parameters
      grid_voice_select = grid_voice_select % 7 + 1
    end
  end
end

-- 8x16 grid layout (128 buttons vertical)
function grid_key_128v(x, y, z)
  if x >= 1 and x <= 7 then
    -- Columns 1-7: Pattern triggers
    if y <= 16 then
      toggle_pattern_step(x, y)
    end
  elseif x == 8 then
    -- Column 8: Controls
    if y >= 1 and y <= 7 then
      toggle_voice(y)
    elseif y == 9 then
      pattern_toggle()
    elseif y >= 11 and y <= 16 then
      -- Voice selection for parameters
      grid_voice_select = util.clamp(y - 10, 1, 7)
    end
  end
end

-- 8x8 grid layout (64 buttons)
function grid_key_64(x, y, z)
  if y >= 1 and y <= 7 then
    -- Rows 1-7: Pattern triggers (8 steps)
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
  if patterns[voice_idx][step] == 0 then
    patterns[voice_idx][step] = 15  -- Full brightness
  else
    patterns[voice_idx][step] = 0
  end
end

function clear_pattern(voice_idx)
  for step = 1, 16 do
    patterns[voice_idx][step] = 0
  end
end

function randomize_pattern(voice_idx)
  for step = 1, 16 do
    if math.random() > 0.5 then
      patterns[voice_idx][step] = math.random(8, 15)
    else
      patterns[voice_idx][step] = 0
    end
  end
end

function manipulate_parameter(voice_idx, param_id, z)
  -- Map grid positions to voice parameters
  local param_map = {
    -- Main synthesis params
    {id = "freq", name = "frequency"},
    {id = "amp", name = "amplitude"},
    {id = "pan", name = "pan"},
    -- Voice-specific params (indices 4+)
  }

  local v = voices[voice_idx]
  if param_id <= 3 then
    local param_key = param_map[param_id].id
    if v.params[param_key] then
      -- Toggle or adjust parameter
      local param_full_id = "v" .. voice_idx .. "_" .. param_key
      if params:lookup_param(param_full_id) then
        -- Simple toggle for now - could be more sophisticated
        local current = params:get(param_full_id)
        local spec = params:lookup_param(param_full_id).controlspec
        if spec then
          local new_val = util.linlin(0, 1, spec.minval, spec.maxval, math.random())
          params:set(param_full_id, new_val)
        end
      end
    end
  end
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
      for voice_idx = 1, 7 do
        if patterns[voice_idx][pattern_position] > 0 then
          -- Trigger voice if not already active
          if not voices[voice_idx].active then
            toggle_voice(voice_idx)
          end
          -- Could add velocity/accent control here
        end
      end

      -- Advance pattern position
      pattern_position = pattern_position % pattern_length + 1

      grid_dirty = true
      grid_redraw()

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
  grid_dirty = true
  grid_redraw()
end

function grid_redraw()
  for grid_id, g in pairs(grids) do
    if g and g.device then
      local cols = g.cols
      local rows = g.rows

      g:all(0)

      if rows >= 16 then
        grid_redraw_256(g)
      elseif cols == 16 and rows == 8 then
        grid_redraw_128h(g)
      elseif cols == 8 and rows == 16 then
        grid_redraw_128v(g)
      elseif cols == 8 and rows == 8 then
        grid_redraw_64(g)
      end

      g:refresh()
    end
  end
end

function grid_redraw_256(g)
  -- Draw patterns (rows 1-7)
  for voice_idx = 1, 7 do
    for step = 1, 16 do
      local brightness = patterns[voice_idx][step]
      -- Highlight current step
      if pattern_playing and step == pattern_position then
        brightness = math.max(brightness, 4)
        if brightness > 0 then brightness = 15 end
      end
      g:led(step, voice_idx, brightness)
    end
  end

  -- Row 8: Pattern controls
  if pattern_playing then
    g:led(1, 8, 15)
    g:led(2, 8, 15)
  else
    g:led(1, 8, 4)
    g:led(2, 8, 4)
  end

  -- Tempo indicators
  g:led(5, 8, 2)
  g:led(6, 8, 2)
  g:led(7, 8, 2)
  g:led(8, 8, 2)

  -- Page indicators
  for i = 1, 4 do
    g:led(12 + i, 8, i == grid_page and 15 or 2)
  end

  -- Row 14: Voice status
  for i = 1, 7 do
    g:led(i, 14, i == grid_voice_select and 15 or 4)
    g:led(i + 8, 14, voices[i].active and 12 or 2)
  end

  -- Row 16: Freeze status
  for i = 1, 7 do
    g:led(i, 16, frozen[i] and 12 or 2)
  end
end

function grid_redraw_128h(g)
  -- Draw patterns (rows 1-7)
  for voice_idx = 1, 7 do
    for step = 1, 16 do
      local brightness = patterns[voice_idx][step]
      if pattern_playing and step == pattern_position then
        brightness = math.max(brightness, 4)
        if brightness > 0 then brightness = 15 end
      end
      g:led(step, voice_idx, brightness)
    end
  end

  -- Row 8: Controls
  if pattern_playing then
    g:led(1, 8, 15)
    g:led(2, 8, 15)
  else
    g:led(1, 8, 4)
    g:led(2, 8, 4)
  end

  -- Page indicators
  g:led(5, 8, grid_page == 1 and 15 or 4)
  g:led(6, 8, grid_page == 2 and 15 or 4)

  -- Voice status
  for i = 1, 7 do
    g:led(i + 8, 8, voices[i].active and 12 or 2)
  end

  -- Voice selection indicator
  g:led(16, 8, 8)
end

function grid_redraw_128v(g)
  -- Draw patterns (columns 1-7)
  for voice_idx = 1, 7 do
    for step = 1, 16 do
      local brightness = patterns[voice_idx][step]
      if pattern_playing and step == pattern_position then
        brightness = math.max(brightness, 4)
        if brightness > 0 then brightness = 15 end
      end
      g:led(voice_idx, step, brightness)
    end
  end

  -- Column 8: Controls
  for i = 1, 7 do
    g:led(8, i, voices[i].active and 12 or 4)
  end
  g:led(8, 9, pattern_playing and 15 or 4)

  -- Voice selection
  for i = 1, 6 do
    g:led(8, 10 + i, (i == grid_voice_select) and 15 or 2)
  end
end

function grid_redraw_64(g)
  -- Draw patterns (rows 1-7, 8 steps only)
  for voice_idx = 1, 7 do
    for step = 1, 8 do
      local brightness = patterns[voice_idx][step]
      if pattern_playing and step == pattern_position and step <= 8 then
        brightness = math.max(brightness, 4)
        if brightness > 0 then brightness = 15 end
      end
      g:led(step, voice_idx, brightness)
    end
  end

  -- Row 8: Controls
  g:led(1, 8, pattern_playing and 15 or 4)
  for i = 1, 5 do
    if i <= 5 then
      g:led(i + 2, 8, voices[i].active and 12 or 4)
    end
  end
end

function cleanup()
  lfo_metro:stop()
  pattern_clock_stop()
  for i = 1, #voices do
    if voices[i].active then
      engine.voiceOff(i - 1)
    end
  end
end

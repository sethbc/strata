-- test/run.lua
-- Off-device test harness for strata. Run from the repo root:
--   lua test/run.lua      (or)      luajit test/run.lua
-- Exits non-zero if any test fails.

local test_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "test"
local repo_root = test_dir .. "/.."
package.path = test_dir .. "/?.lua;" .. package.path

local stubs = require("norns_stubs")
local sync_check = require("sync_check")
local real_print = print

local SC_PATH = repo_root .. "/lib/Engine_Strata.sc"
local LUA_PATH = repo_root .. "/strata.lua"
local signatures = stubs.parse_engine_signatures(SC_PATH)
local engine_polls = stubs.parse_engine_polls(SC_PATH)

local data_root = os.tmpname()
os.remove(data_root)
os.execute("mkdir -p '" .. data_root .. "'")
data_root = data_root .. "/"

local tests = {}
local function test(name, func) table.insert(tests, { name = name, func = func }) end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function fail(message, level) error(message, (level or 1) + 1) end

local function assert_true(value, message)
  if not value then fail(message or "expected true", 2) end
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    fail(string.format("%s: expected %s, got %s", message or "values differ", tostring(expected), tostring(actual)), 2)
  end
end

local function assert_near(actual, expected, tolerance, message)
  if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-9) then
    fail(string.format("%s: expected %s, got %s", message or "values differ", tostring(expected), tostring(actual)), 2)
  end
end

-- Load strata.lua into fresh stubs and run init().
local function load_strata(options)
  options = options or {}
  local data_dir = data_root .. (options.data_subdir or tostring(math.random(1, 1e9))) .. "/"
  local context = stubs.install { signatures = signatures, engine_polls = engine_polls, data_dir = data_dir, quiet = true }
  context.data_dir = data_dir
  context.audio_dir = data_dir .. "audio/"
  if options.before_load then options.before_load(context) end
  local chunk = assert(loadfile(LUA_PATH))
  chunk()
  if options.before_init then options.before_init(context) end
  init()
  return context
end

-- Find a script-local variable by searching the upvalues of global functions.
local function find_upvalue(name)
  for _, value in pairs(_G) do
    if type(value) == "function" then
      local index = 1
      while true do
        local upvalue_name, upvalue_value = debug.getupvalue(value, index)
        if not upvalue_name then break end
        if upvalue_name == name then
          return upvalue_value, function(new_value) debug.setupvalue(value, index, new_value) end
        end
        index = index + 1
      end
    end
  end
  error("script local '" .. name .. "' not found")
end

local function local_value(name) return (find_upvalue(name)) end

-- Deep copy of plain data tables
local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, inner in pairs(value) do copy[key] = deep_copy(inner) end
  return copy
end

-- Compare a voice's live state with a captured scene voice, allowing for
-- each param's controlspec quantization
local function assert_voice_matches(voice_idx, voice, captured)
  local prefix = "voice " .. voice_idx .. " "
  for key, value in pairs(captured.params) do
    local spec = params:lookup_param("v" .. voice_idx .. "_" .. key).controlspec
    assert_near(voice.params[key], value, spec.step + 1e-6, prefix .. key)
  end
  for key, value in pairs(captured.grain) do
    assert_near(voice.grain[key], value, 0.011, prefix .. "grain " .. key)
  end
  for slot = 1, 3 do
    local live, saved = voice.crossmod["slot" .. slot], captured.crossmod["slot" .. slot]
    assert_equal(live.source, saved.source, prefix .. "slot " .. slot .. " source")
    assert_near(live.amp_amt, saved.amp_amt, 0.011, prefix .. "slot " .. slot .. " amp")
    assert_near(live.freq_amt, saved.freq_amt, 0.011, prefix .. "slot " .. slot .. " freq")
  end
  assert_near(voice.crossmod.speed, captured.crossmod.speed, 0.11, prefix .. "mod speed")
  assert_equal(voice.active, captured.active, prefix .. "active")
end

-- Put every voice into a distinctive, non-default state through params
local function scramble_state(seed)
  math.randomseed(seed)
  for voice_idx = 1, 7 do
    randomize_voice(voice_idx)
    params:set("v" .. voice_idx .. "_grain_spread", math.random())
    params:set("v" .. voice_idx .. "_grain_density", math.random(1, 100))
    params:set("v" .. voice_idx .. "_grain_env", math.random(1, 5))
    for slot = 1, 3 do
      params:set("v" .. voice_idx .. "_mod_source_" .. slot, math.random(0, 7))
      params:set("v" .. voice_idx .. "_mod_amp_amt_" .. slot, math.random() * 4 - 2)
      params:set("v" .. voice_idx .. "_mod_freq_amt_" .. slot, math.random() * 4 - 2)
    end
    params:set("v" .. voice_idx .. "_mod_speed", math.random() * 40 + 0.5)
  end
end

---------------------------------------------------------------------------
-- tests
---------------------------------------------------------------------------

test("strata.lua loads and init() runs", function()
  local context = load_strata()
  assert_true(#context.engine_calls > 0, "init should talk to the engine")
end)

test("Lua engine calls and SC addCommand signatures are in sync (T3)", function()
  local ok, problems, summary = sync_check.run(repo_root)
  assert_true(ok, summary .. "\n" .. table.concat(problems, "\n"))
  -- the scanner itself: nested calls, strings and comments
  local calls = sync_check.lua_calls('engine.foo(a, f(b, c), "x,y)", {1, 2}) -- engine.bar(1)\nengine.baz()')
  assert_equal(#calls, 2, "comment ignored")
  assert_equal(calls[1].arg_count, 4, "nested commas ignored")
  assert_equal(calls[2].arg_count, 0, "empty call")
end)

test("every voice param has a menu param, ordered by param_order", function()
  load_strata()
  local voices = local_value("voices")
  for voice_idx = 1, 7 do
    local voice = voices[voice_idx]
    local listed = {}
    for _, key in ipairs(voice.param_order) do
      listed[key] = true
      local param = params:lookup_param("v" .. voice_idx .. "_" .. key)
      assert_near(param.controlspec.default, voice.params[key], 1e-9,
        "voice " .. voice_idx .. " " .. key .. " default comes from the voices table")
    end
    for key in pairs(voice.params) do
      assert_true(listed[key], "voice " .. voice_idx .. " param_order lists " .. key)
    end
  end
end)

-- index engine calls for one voice by command and key
local function engine_state_for_voice(calls, engine_voice)
  local state = { voice = {}, grain = {}, source = {}, amp_amt = {}, freq_amt = {} }
  for _, call in ipairs(calls) do
    local args = call.args
    if args[1] == engine_voice then
      if call.name == "setVoiceParam" then state.voice[args[2]] = args[3]
      elseif call.name == "setGrainParam" then state.grain[args[2]] = args[3]
      elseif call.name == "setModSource" then state.source[args[2]] = args[3]
      elseif call.name == "setModAmpAmt" then state.amp_amt[args[2]] = args[3]
      elseif call.name == "setModFreqAmt" then state.freq_amt[args[2]] = args[3]
      elseif call.name == "setModSpeed" then state.speed = args[2]
      elseif call.name == "voiceOn" then state.voice_on = args end
    end
  end
  return state
end

test("starting a voice sends its complete state to the engine (C1, C2)", function()
  local context = load_strata()
  context.clock.advance()
  local voices = local_value("voices")
  -- turn everything off, then edit every voice while it is off
  for voice_idx = 1, 7 do
    if voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  scramble_state(42)
  params:set("master_density", 1.5)
  context.clear_engine_calls()
  assert_equal(#context.engine_calls, 0, "edits to stopped voices are not sent")

  for voice_idx = 1, 7 do
    context.clear_engine_calls()
    toggle_voice(voice_idx)
    local voice = voices[voice_idx]
    local sent = engine_state_for_voice(context.engine_calls, voice_idx - 1)
    assert_true(sent.voice_on ~= nil, "voiceOn sent for voice " .. voice_idx)
    assert_equal(sent.voice_on[2], voice.params.freq, "voiceOn freq (number) for voice " .. voice_idx)
    for key, value in pairs(voice.params) do
      assert_equal(sent.voice[key], value, "voice " .. voice_idx .. " setVoiceParam " .. key)
    end
    assert_equal(sent.grain.grainSize, voice.grain.size, "voice " .. voice_idx .. " grainSize")
    assert_near(sent.grain.grainDensity, voice.grain.density * 1.5, 1e-9, "voice " .. voice_idx .. " grainDensity")
    assert_equal(sent.grain.pitchShift, voice.grain.pitch, "voice " .. voice_idx .. " pitchShift")
    assert_equal(sent.grain.posSpread, voice.grain.spread, "voice " .. voice_idx .. " posSpread")
    assert_equal(sent.grain.envShape, voice.grain.env - 1, "voice " .. voice_idx .. " envShape")
    for slot = 1, 3 do
      local slot_state = voice.crossmod["slot" .. slot]
      local expected_source = slot_state.source == 0 and -1 or slot_state.source - 1
      assert_equal(sent.source[slot], expected_source, "voice " .. voice_idx .. " slot " .. slot .. " source")
      assert_equal(sent.amp_amt[slot], slot_state.amp_amt, "voice " .. voice_idx .. " slot " .. slot .. " amp")
      assert_equal(sent.freq_amt[slot], slot_state.freq_amt, "voice " .. voice_idx .. " slot " .. slot .. " freq")
    end
    assert_equal(sent.speed, voice.crossmod.speed, "voice " .. voice_idx .. " mod speed")
  end
end)

test("grain envelope option reaches the engine and is synced on start", function()
  local context = load_strata(); context.clock.advance()
  params:set("v1_grain_env", 3)
  local calls = context.calls_named("setGrainParam"); local last = calls[#calls]
  assert_equal(last.args[2], "envShape"); assert_equal(last.args[3], 2)
  toggle_voice(3); params:set("v3_grain_env", 5); toggle_voice(3)       -- on, edit, off
  context.clear_engine_calls(); toggle_voice(3)                          -- on again: synced
  local sent = engine_state_for_voice(context.engine_calls, 2)
  assert_equal(sent.grain.envShape, 4)
  capture_scene(1); params:set("v1_grain_env", 1)
  recall_scene(1, 2); context.clock.advance()
  assert_equal(params:get("v1_grain_env"), 1, "transition does not interpolate env")
  recall_scene(1, 0); assert_equal(params:get("v1_grain_env"), 3)
  -- an option param floors fractional values, so check the fade list directly
  for _, target in ipairs(scene_transition_targets(local_value("scenes")[1].data)) do
    assert_true(not target.id:find("_grain_env$"), target.id .. " is not crossfaded")
  end
end)

test("grain envelope param: options, default, scenes, never mutated or randomized", function()
  local context = load_strata(); context.clock.advance()
  for voice_idx = 1, 7 do
    local param = params:lookup_param("v" .. voice_idx .. "_grain_env")
    assert_equal(param.t, params.tOPTION, "voice " .. voice_idx .. " grain_env is an option")
    assert_equal(param.count, 5, "five envelope shapes")
    assert_equal(params:get("v" .. voice_idx .. "_grain_env"), 1, "default hann")
    assert_equal(local_value("voices")[voice_idx].grain.env, 1, "voices table holds the index")
  end
  local names = {}
  for index = 1, 5 do params:set("v1_grain_env", index); names[index] = params:string("v1_grain_env") end
  assert_equal(table.concat(names, ","), "hann,sine,perc,linen,trap")
  -- every per-voice scene default equals its param default
  local found_env = false
  for _, field in ipairs(local_value("VOICE_SCENE_DEFAULTS")) do
    if field.path[1] == "grain" and field.path[2] == "env" then found_env = true end
    if field.path[1] == "grain" then
      local suffix = local_value("GRAIN_PARAM_IDS")[field.path[2]]
      for voice_idx = 1, 7 do
        local param = params:lookup_param("v" .. voice_idx .. "_" .. suffix)
        local param_default = param.controlspec and param.controlspec.default or param.default
        assert_equal(field.default, param_default, "voice " .. voice_idx .. " " .. suffix .. " scene default")
      end
    end
  end
  assert_true(found_env, "grain.env has a scene default")
  -- scenes written before grain envelopes migrate to hann
  params:set("v2_grain_env", 4)
  capture_scene(3)
  local scene = local_value("scenes")[3]
  for voice_idx = 1, 7 do scene.data.voices[voice_idx].grain.env = nil end
  migrate_scene(scene, 2)
  assert_equal(scene.data.voices[2].grain.env, 1, "missing env migrates to hann")
  assert_true(validate_scene(scene), "migrated scene validates")
  scene.data.voices[2].grain.env = 2.5
  assert_true(not validate_scene(scene), "a fractional envelope index is rejected")
  scene.data.voices[2].grain.env = 0
  assert_true(not validate_scene(scene), "envelope index 0 is rejected")
  scene.data.voices[2].grain.env = 1
  -- mutation and randomize leave the envelope alone
  for voice_idx = 1, 7 do
    if not local_value("voices")[voice_idx].active then toggle_voice(voice_idx) end
    params:set("v" .. voice_idx .. "_grain_env", 4)
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(5)
  for _ = 1, 50 do gentle_mutate() end
  for voice_idx = 1, 7 do randomize_voice(voice_idx) end
  for voice_idx = 1, 7 do
    assert_equal(params:get("v" .. voice_idx .. "_grain_env"), 4, "voice " .. voice_idx .. " envelope unchanged")
  end
end)

test("pattern steps retrigger running voices and never stack synths (C3)", function()
  local context = load_strata()
  context.clock.advance()  -- voices 1 and 2 running
  local voices = local_value("voices")
  assert_true(voices[1].active and not voices[3].active, "voice 1 on, voice 3 off")
  for step = 1, 16 do toggle_pattern_step(1, step) end
  toggle_pattern_step(3, 1)
  context.clear_engine_calls()

  pattern_toggle()  -- plays step 1 immediately
  for _ = 1, 31 do context.clock.advance() end  -- 31 more 16ths: two full bars
  pattern_toggle()

  local retriggers = context.calls_named("retrigger")
  local voice_on_calls = context.calls_named("voiceOn")
  local voice1_retriggers, voice3_retriggers = 0, 0
  for _, call in ipairs(retriggers) do
    if call.args[1] == 0 then voice1_retriggers = voice1_retriggers + 1 end
    if call.args[1] == 2 then voice3_retriggers = voice3_retriggers + 1 end
  end
  assert_equal(voice1_retriggers, 32, "voice 1 retriggered on each of 32 steps")
  assert_equal(#voice_on_calls, 1, "only the stopped voice was started")
  assert_equal(voice_on_calls[1].args[1], 2, "voice 3 started by its first step")
  assert_equal(voice3_retriggers, 1, "voice 3 retriggered on its second pass")
  assert_equal(#context.calls_named("voiceOff"), 0, "no voice was stopped")
  for _, entry in ipairs(context.clock.sleep_log) do
    assert_true(entry.mode ~= "sleep" or entry.amount ~= 0.01, "no 10 ms retrigger gap")
  end
end)

test("grain pitch LFO drifts subtly around the user-set pitch (C4)", function()
  local context = load_strata()
  local lfo_metro = context.metro.all[1]
  assert_true(lfo_metro.running and lfo_metro.event == lfo_update, "lfo metro running")
  params:set("v1_grain_pitch", 1.5)
  math.randomseed(3)
  local max_offset = 0
  for _ = 1, 20000 do
    lfo_metro.event()
    max_offset = math.max(max_offset, math.abs(params:get("v1_grain_pitch") - 1.5))
  end
  assert_true(max_offset > 0.001, "pitch actually drifts (" .. max_offset .. ")")
  assert_true(max_offset < 0.06, "drift stays within a few percent (" .. max_offset .. ")")
  -- a new user value becomes the new centre
  params:set("v1_grain_pitch", 0.5)
  for _ = 1, 2000 do lfo_metro.event() end
  assert_near(params:get("v1_grain_pitch"), 0.5, 0.06, "walk re-centres on the new value")
  -- frozen voices do not drift
  toggle_freeze(1)
  local frozen_pitch = params:get("v1_grain_pitch")
  for _ = 1, 100 do lfo_metro.event() end
  assert_equal(params:get("v1_grain_pitch"), frozen_pitch, "frozen voice pitch unchanged")
end)

test("tempo param drives clock_tempo and grid tempo buttons (I1)", function()
  local context = load_strata({ before_init = function() params:set("clock_tempo", 97) end })
  assert_equal(params:get("tempo"), 97, "tempo initialised from clock_tempo")
  params:set("tempo", 133)
  assert_equal(params:get("clock_tempo"), 133, "tempo param sets clock_tempo")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 13, 8, 1)  -- page 1
  context.grid.press(1, 8, 8, 1)   -- +10 BPM
  context.grid.press(1, 5, 8, 1)   -- -10 BPM
  context.grid.press(1, 7, 8, 1)   -- +1 BPM
  assert_equal(params:get("clock_tempo"), 134, "grid tempo buttons reach clock_tempo")
end)

test("256-grid parameter page faders set values and show them (I8)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  local press = function(x, y) context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0) end
  press(14, 8)  -- grid page 2 (parameters)
  press(2, 14)  -- select voice 2 (fm)
  local ids = fader_param_ids(2)
  assert_equal(ids[1], "v2_freq", "first fader is freq")
  assert_equal(#ids, 6 + 5 + 9, "fm has 20 faders")
  assert_equal(fader_page_count(2), 5, "fm has 5 fader pages")
  assert_equal(ids[11], "v2_grain_env", "grain envelope follows the other grain faders")
  assert_equal(fader_page_count(1), 6, "resonator has 6 fader pages")
  assert_equal(fader_page_count(4), 5, "sub has 5 fader pages")

  press(16, 9)  -- page 1 row 1 full right -> freq max
  assert_near(params:get("v2_freq"), 2000, 1, "column 16 sets max")
  press(1, 10)  -- row 2 (ratio) far left -> min
  assert_near(params:get("v2_ratio"), 0.5, 1e-6, "column 1 sets min")
  press(8, 11)  -- row 3 (index) column 8 -> linlin(1, 16, 0, 10, 8)
  assert_near(params:get("v2_index"), 70 / 15, 0.1, "column 8 sets the proportional value")
  -- LEDs: bar at 8 up to the value, value column at 15
  assert_equal(device:get_led(8, 11), 15, "value column bright")
  assert_equal(device:get_led(7, 11), 8, "bar below the value")
  assert_equal(device:get_led(9, 11), 0, "nothing above the value")
  assert_equal(device:get_led(16, 9), 15, "freq at max")
  assert_equal(device:get_led(1, 13), 15, "row 13 shows page 1 selected")

  -- exponential params follow their warp: freq (20-2000 Hz exp)
  press(1, 14)  -- select voice 1 (resonator)
  press(8, 9)   -- freq fader, column 8
  assert_near(params:get("v1_freq"), 20 * (2000 / 20) ^ (7 / 15), 1.0, "column 8 on an exp fader")
  assert_equal(device:get_led(8, 9), 15, "exp fader shows its value at column 8")
  press(4, 14)  -- select voice 4 (sub), freq 40 Hz
  assert_near(params:get("v4_freq"), 40, 1e-9, "sub freq default")
  local sub_column = fader_position("v4_freq")
  assert_true(sub_column > 1, "40 Hz shows above column 1 (got " .. sub_column .. ")")
  assert_equal(device:get_led(sub_column, 9), 15, "sub freq LED at its column")
  press(2, 14)  -- back to voice 2 (fm)
  assert_equal(device:get_led(5, 13), 4, "row 13 shows page 5 available")
  assert_equal(device:get_led(6, 13), 0, "no page 6")

  press(3, 13)  -- page 3: faders 9-12 = grain_pitch, grain_spread, grain_env, source 1
  assert_equal(device:get_led(3, 13), 15, "page 3 selected")
  -- grain envelope is an option param: an index fader over its 5 options
  press(16, 11)
  assert_equal(params:get("v2_grain_env"), 5, "envelope fader column 16 -> last option")
  assert_equal(device:get_led(16, 11), 15, "envelope fader shows the last option at column 16")
  press(1, 11)
  assert_equal(params:get("v2_grain_env"), 1, "envelope fader column 1 -> first option")
  press(9, 11)
  assert_equal(params:get("v2_grain_env"), 3, "envelope column 9 -> round(linlin(1,16,1,5,9))")
  assert_equal(fader_position("v2_grain_env"), 9, "option 3 of 5 shows at the middle column")
  assert_equal(device:get_led(9, 11), 15, "envelope fader LED at its option")
  press(16, 12)  -- mod source 1 -> 7 (number param, rounded)
  assert_equal(params:get("v2_mod_source_1"), 7, "mod source fader rounds to an integer")
  press(9, 12)
  assert_equal(params:get("v2_mod_source_1"), 4, "mod source column 9 -> round(linlin(1,16,0,7,9))")
  press(4, 13)  -- page 4: first fader is amp mod 1
  press(1, 9)   -- amp mod 1 -> -2
  assert_near(params:get("v2_mod_amp_amt_1"), -2, 1e-6, "amp mod fader min")
  press(16, 8)  -- grid page 4: rows 9-13 dark
  for y = 9, 13 do
    for x = 1, 16 do assert_equal(device:get_led(x, y), 0, "parameter rows dark on page 4") end
  end
end)

local GRID_SIZES = {
  { name = "256", cols = 16, rows = 16 },
  { name = "128h", cols = 16, rows = 8 },
  { name = "128v", cols = 8, rows = 16 },
  { name = "64", cols = 8, rows = 8 },
}

test("every grid key on every layout and page runs without error", function()
  for _, size in ipairs(GRID_SIZES) do
    local context = load_strata()
    local device = context.grid.plug(1, size.cols, size.rows)
    -- 256 has four pages selected from row 8; other layouts are swept once
    local pages = size.name == "256" and { 1, 2, 3, 4 } or { 1 }
    for _, page in ipairs(pages) do
      for y = 1, size.rows do
        for x = 1, size.cols do
          if size.name == "256" then context.grid.press(1, 12 + page, 8, 1) end
          context.grid.press(1, x, y, 1)
          context.grid.press(1, x, y, 0)
          context.clock.advance()
        end
      end
    end
    assert_true(device.refresh_count > 0, size.name .. " grid was redrawn")
  end
end)

test("grid_redraw draws every layout (I2) and a hot-plugged grid (I3)", function()
  for _, size in ipairs(GRID_SIZES) do
    local context = load_strata()
    local device = context.grid.plug(2, size.cols, size.rows)
    local refreshes = device.refresh_count
    grid_redraw()
    assert_equal(device.refresh_count, refreshes + 1, size.name .. " redraw reaches a hot-plugged grid")
    -- voice 1 is running after init: its status LED must be lit on every layout
    local lit = false
    for x = 1, size.cols do
      for y = 1, size.rows do
        if device:get_led(x, y) >= 12 then lit = true end
      end
    end
    assert_true(lit, size.name .. " layout drew something")
  end
end)

test("scene capture -> change -> recall restores every voice", function()
  local context = load_strata()
  context.clock.advance()  -- let init start voice 2
  scramble_state(11)
  toggle_voice(3)
  toggle_freeze(1)
  toggle_pattern_step(4, 5)
  params:set("reverb_mix", 0.71)
  capture_scene(2)
  local scenes = local_value("scenes")
  local captured = deep_copy(scenes[2].data)
  assert_true(validate_scene_data(scenes), "a captured scene validates")

  scramble_state(99)
  toggle_voice(3)   -- off again
  toggle_voice(6)   -- on
  toggle_freeze(1)
  toggle_pattern_step(4, 5)
  params:set("reverb_mix", 0.1)

  context.clear_engine_calls()
  recall_scene(2, 0)
  local voices = local_value("voices")
  local frozen = local_value("frozen")
  local patterns = local_value("patterns")
  for voice_idx = 1, 7 do
    assert_voice_matches(voice_idx, voices[voice_idx], captured.voices[voice_idx])
    assert_equal(frozen[voice_idx], captured.frozen[voice_idx], "voice " .. voice_idx .. " frozen")
    for step = 1, 16 do
      assert_equal(patterns[voice_idx][step], captured.patterns[voice_idx][step], "pattern " .. voice_idx .. "/" .. step)
    end
  end
  assert_near(params:get("reverb_mix"), 0.71, 1e-9, "reverb mix")
  -- voice 3 was restarted by the recall: the engine got its recalled state
  local started = false
  for _, call in ipairs(context.calls_named("voiceOn")) do
    if call.args[1] == 2 then started = true end
  end
  assert_true(started, "recall started voice 3")
  for _, call in ipairs(context.calls_named("setModSource")) do
    if call.args[1] == 2 then
      local source = captured.voices[3].crossmod["slot" .. call.args[2]].source
      assert_equal(call.args[3], source == 0 and -1 or source - 1, "voice 3 mod source sent after recall")
    end
  end
end)

test("validate_scene_data rejects malformed scenes and accepts captured ones", function()
  load_strata()
  capture_scene(1)
  local scenes = local_value("scenes")
  local good = deep_copy(scenes)
  assert_true(validate_scene_data(good), "captured scenes are valid")

  local function rejects(mutator, message)
    local candidate = deep_copy(good)
    mutator(candidate[1].data, candidate)
    assert_true(not validate_scene_data(candidate), "should reject: " .. message)
  end
  rejects(function(data) data.frozen = nil end, "missing frozen")
  rejects(function(data) data.frozen[3] = nil end, "frozen entry missing")
  rejects(function(data) data.patterns[2][16] = nil end, "short pattern")
  rejects(function(data) data.patterns[7] = nil end, "missing pattern row")
  rejects(function(data) data.patterns[1][1] = "x" end, "non-numeric step")
  rejects(function(data) data.master_density = "loud" end, "non-numeric master_density")
  rejects(function(data) data.tempo = nil end, "missing tempo")
  rejects(function(data) data.reverb_damp = {} end, "non-numeric reverb_damp")
  rejects(function(data) data.voices[7] = nil end, "missing voice")
  rejects(function(data) data.voices[2].crossmod.slot2 = nil end, "missing crossmod slot")
  rejects(function(data) data.voices[2].crossmod.slot1.source = 9 end, "out-of-range mod source")
  rejects(function(data) data.voices[1].params.bogus = 1 end, "unknown voice param")
  rejects(function(data) data.voices[1].grain.size = "big" end, "non-numeric grain param")
  rejects(function(data, all) all[1].populated = "yes" end, "non-boolean populated")
  assert_true(not validate_scene_data("nope"), "should reject a non-table")
  assert_true(not validate_scene_data({ [3] = 7 }), "should reject a non-table slot")
end)

test("scene files: round trip, version check, missing slots, erroring file", function()
  local context = load_strata({ data_subdir = "roundtrip" })
  context.clock.advance()
  scramble_state(5)
  capture_scene(4)
  save_scenes_to_disk()
  local saved = deep_copy(local_value("scenes")[4].data)

  -- reload into a fresh script: auto-load in init restores the scene
  context = load_strata({ data_subdir = "roundtrip" })
  local scenes = local_value("scenes")
  assert_true(scenes[4].populated, "scene 4 reloaded from disk")
  assert_near(scenes[4].data.voices[1].params.freq, saved.voices[1].params.freq, 1e-9, "scene 4 data")
  for slot = 1, 8 do assert_true(scenes[slot] ~= nil, "slot " .. slot .. " exists") end
  local file_path = context.data_dir .. "strata/scenes.data"

  -- a file that raises an error when run must not break init
  local file = assert(io.open(file_path, "w"))
  file:write('error("corrupt scenes file")')
  file:close()
  context = load_strata({ data_subdir = "roundtrip" })
  scenes = local_value("scenes")
  for slot = 1, 8 do assert_true(scenes[slot] and scenes[slot].populated == false, "empty slot " .. slot) end
  load_scenes_from_disk()  -- the manual trigger survives it too

  -- wrong version is rejected
  file = assert(io.open(file_path, "w"))
  file:write("return { version = 99, scenes = {} }")
  file:close()
  context = load_strata({ data_subdir = "roundtrip" })
  local found = false
  for _, line in ipairs(context.printed) do
    if line:find("version 99") then found = true end
  end
  assert_true(found, "version mismatch reported")

  -- a pre-2.1 bare array with only some slots loads, missing slots filled
  local legacy = { [1] = { name = "scene 1", populated = false, data = {} } }
  legacy[2] = { name = "scene 2", populated = true, data = saved }
  context.tab.save(legacy, file_path)
  context = load_strata({ data_subdir = "roundtrip" })
  scenes = local_value("scenes")
  assert_true(scenes[2].populated, "legacy scene 2 loaded")
  for slot = 3, 8 do assert_true(scenes[slot] and scenes[slot].populated == false, "filled slot " .. slot) end
  recall_scene(2, 0)
  grid_redraw()
end)

test("a scenes file that fails to load survives cleanup (fix round 1)", function()
  local bad_files = {
    { name = "wrong version", content = "return { version = 99, scenes = {} }" },
    { name = "raises on load", content = 'error("corrupt scenes file")' },
  }
  -- a versioned file with one bad slot (validate_scene_data rejects it whole)
  local context = load_strata({ data_subdir = "survive_source" })
  capture_scene(1)
  capture_scene(2)
  local scenes = deep_copy(local_value("scenes"))
  scenes[2].data.frozen = nil
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  local bad_slot_path = context.data_dir .. "bad_slot.data"
  context.tab.save({ version = 1, scenes = scenes }, bad_slot_path)
  local bad_slot_file = assert(io.open(bad_slot_path, "r"))
  table.insert(bad_files, { name = "one bad slot", content = bad_slot_file:read("*a") })
  bad_slot_file:close()

  for index, bad in ipairs(bad_files) do
    local subdir = "survive_" .. index
    local data_dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. data_dir .. "'")
    local file = assert(io.open(data_dir .. "scenes.data", "w"))
    file:write(bad.content)
    file:close()

    context = load_strata({ data_subdir = subdir })  -- init's load fails
    for slot = 1, 8 do
      assert_true(local_value("scenes")[slot].populated == false, bad.name .. ": scenes empty after failed load")
    end
    capture_scene(3)  -- new work after the failed load
    cleanup()
    local backup = io.open(data_dir .. "scenes.data.bak", "r")
    assert_true(backup ~= nil, bad.name .. ": original kept as scenes.data.bak")
    assert_equal(backup:read("*a"), bad.content, bad.name .. ": backup content unchanged")
    backup:close()
    -- the new save is a valid file again
    context = load_strata({ data_subdir = subdir })
    assert_true(local_value("scenes")[3].populated, bad.name .. ": new work saved on exit")
  end

  -- if the file cannot be moved aside, cleanup must not overwrite it
  local data_dir = data_root .. "survive_blocked/strata/"
  os.execute("mkdir -p '" .. data_dir .. "scenes.data.bak/occupied'")  -- rename target is a non-empty dir
  local file = assert(io.open(data_dir .. "scenes.data", "w"))
  file:write(bad_files[1].content)
  file:close()
  load_strata({ data_subdir = "survive_blocked" })
  cleanup()
  file = assert(io.open(data_dir .. "scenes.data", "r"))
  assert_equal(file:read("*a"), bad_files[1].content, "unmovable bad file not overwritten by cleanup")
  file:close()
end)

test("scene transitions crossfade linearly from snapshotted start values (I6)", function()
  local context = load_strata()
  params:set("v1_freq", 1000)
  params:set("reverb_mix", 0.8)
  params:set("v2_mod_source_1", 3)
  capture_scene(1)
  params:set("v1_freq", 200)
  params:set("reverb_mix", 0.0)
  params:set("v2_mod_source_1", 0)

  recall_scene(1, 20)  -- 20 s over 20 steps; the first step runs immediately
  for step = 1, 19 do
    local mix = step / 20
    assert_near(params:get("v1_freq"), 200 + 800 * mix, 1.0, "freq at step " .. step)
    assert_near(params:get("reverb_mix"), 0.8 * mix, 0.0051, "reverb mix at step " .. step)
    assert_equal(params:get("v2_mod_source_1"), 0, "mod source switches only at the end")
    context.clock.advance()
  end
  assert_near(params:get("v1_freq"), 1000, 1.0, "freq at the end")
  context.clock.advance()
  assert_equal(params:get("v2_mod_source_1"), 3, "mod source set when the fade ends")
  assert_equal(local_value("scene_transition_active"), false, "transition finished")

  -- a second recall cancels a running transition and clears the flag
  params:set("v1_freq", 300)
  recall_scene(1, 10)
  assert_equal(local_value("scene_transition_active"), true, "transition running")
  recall_scene(1, 0)
  assert_equal(local_value("scene_transition_active"), false, "cancelled transition clears the flag")
  assert_equal(local_value("scene_transition_clock"), nil, "cancelled transition clock cleared")
  assert_near(params:get("v1_freq"), 1000, 1.0, "instant recall wins")
  context.clock.advance()
  assert_near(params:get("v1_freq"), 1000, 1.0, "cancelled transition no longer writes")
end)

-- Approximate advance of norns' default font (04B_03 at size 8): capitals
-- about 6 px, brackets/colon/period about 4 px, everything else 5 px
local function text_width(text)
  local width = 0
  for char in text:gmatch(".") do
    if char:match("%u") then
      width = width + 6
    elseif char:match("[%[%]%.:]") then
      width = width + 4
    else
      width = width + 5
    end
  end
  return width
end

local function text_span(entry)
  local width = text_width(entry.text)
  if entry.align == "right" then return entry.x - width, entry.x end
  return entry.x, entry.x + width
end

local PAGE_TITLES = { "MAIN", "FX", "LFO", "BUFFER", "SETUP" }
local HINT_ROW_Y = 62
local TEXT_HEIGHT = 6   -- 04B_03 glyph height plus one row of spacing

local function show_page(page)
  enc(1, page - local_value("ui_page"))
  redraw()
end

-- Check the drawn screen: everything inside 128x64, no two strings overlap on
-- a row, the page title at 0,8 with dens: at least 4 px after it, and a hint
-- row at y 62.
local function assert_screen_layout(context, where)
  local rows = {}
  for _, entry in ipairs(context.screen.texts) do
    local left, right = text_span(entry)
    assert_true(left >= 0 and right <= 128 and entry.y <= 64,
      string.format("'%s' at %d,%d leaves the screen (%s)", entry.text, entry.x, entry.y, where))
    rows[entry.y] = rows[entry.y] or {}
    for _, other in ipairs(rows[entry.y]) do
      assert_true(right <= other.left or left >= other.right,
        string.format("'%s' overlaps '%s' on row %d (%s)", entry.text, other.text, entry.y, where))
    end
    table.insert(rows[entry.y], { left = left, right = right, text = entry.text })
  end
  local title = PAGE_TITLES[local_value("ui_page")]
  local title_right, density_left, hint_found
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == title and entry.x == 0 and entry.y == 8 then title_right = select(2, text_span(entry)) end
    if entry.text:find("^dens:") then density_left = entry.x end
    if entry.x == 0 and entry.y == HINT_ROW_Y then hint_found = true end
  end
  assert_true(title_right, "page title " .. title .. " drawn at 0,8 (" .. where .. ")")
  assert_true(density_left and density_left - title_right >= 4,
    "dens: starts at least 4 px after " .. title .. " (" .. where .. ")")
  assert_true(hint_found, "hint row at y " .. HINT_ROW_Y .. " (" .. where .. ")")
end

test("every page's header, hints and text stay apart and inside 128x64 (M7)", function()
  local context = load_strata()
  params:set("mutation_enabled", 1)
  params:set("master_density", 2.0)
  capture_scene(8)
  recall_scene(8, 0)
  -- the widest SETUP page: four grids of every size and an arc
  context.grid.plug(1, 16, 16)
  context.grid.plug(2, 16, 8)
  context.grid.plug(3, 8, 16)
  context.grid.plug(4, 8, 8)
  context.arc.plug(1)
  local voices = local_value("voices")
  local _, set_selected = find_upvalue("selected_voice")
  for voice_idx = 1, 7 do
    set_selected(voice_idx)
    if not voices[voice_idx].active then toggle_voice(voice_idx) end
    if not local_value("frozen")[voice_idx] then toggle_freeze(voice_idx) end
    for page = 1, #PAGE_TITLES do
      show_page(page)
      assert_screen_layout(context, PAGE_TITLES[page] .. ", voice " .. voice_idx)
    end
  end
  -- UI.ScrollingList draws row i at y + 5 + (i - 1) * 11; its last row must
  -- end above the hint row (the stub list draws nothing, so check geometry)
  local voice_list = local_value("voice_list")
  local last_row_y = voice_list.y + 5 + (voice_list.num_visible - 1) * 11
  assert_true(last_row_y <= HINT_ROW_Y - TEXT_HEIGHT,
    "voice list's last row (y " .. last_row_y .. ") clears the hint row")
end)

test("E1 selects pages; MAIN keeps its encoder and key mappings", function()
  local context = load_strata(); context.clock.advance()
  assert_equal(local_value("ui_page"), 1)
  local density = params:get("master_density")
  enc(1, 1); assert_equal(local_value("ui_page"), 2)
  assert_equal(params:get("master_density"), density, "E1 no longer changes density")
  enc(1, 10); assert_equal(local_value("ui_page"), 5)
  enc(1, -10); assert_equal(local_value("ui_page"), 1)
  enc(2, 1); assert_equal(local_value("selected_voice"), 2)
  local before = params:get(main_param_id(2)); enc(3, 1)
  assert_true(params:get(main_param_id(2)) ~= before, "E3 moves the main param on MAIN")
  key(3, 1); assert_true(local_value("frozen")[2], "K3 freezes a running voice on MAIN")
end)

test("E1 steps one page per detent: no acceleration, 4 ticks per page", function()
  local context = load_strata()
  local encoders = context.encoders
  assert_equal(encoders.accel[1], false, "E1 acceleration off")
  assert_equal(encoders.sens[1], 4, "E1 needs 4 ticks per page")
  assert_equal(encoders.accel[2], true, "E2 keeps norns' default acceleration")
  assert_equal(encoders.accel[3], true, "E3 keeps norns' default acceleration")
  -- a fast turn (1 ms between ticks) of 4 ticks moves exactly one page
  for _ = 1, 4 do encoders.deliver(1, 1, 0.001) end
  assert_equal(local_value("ui_page"), 2, "fast E1 turn does not skip pages")
  for _ = 1, 3 do encoders.deliver(1, 1, 0.001) end
  assert_equal(local_value("ui_page"), 2, "three ticks are not yet a page")
  encoders.deliver(1, 1, 0.001)
  assert_equal(local_value("ui_page"), 3, "the fourth tick is")
  for _ = 1, 8 do encoders.deliver(1, -1, 0.001) end
  assert_equal(local_value("ui_page"), 1, "eight ticks back return two pages")
end)

test("every page draws within 128x64 with a header and hint row", function()
  local context = load_strata(); context.clock.advance()
  for page = 1, 5 do
    enc(1, page - local_value("ui_page")); redraw()
    local texts = context.screen.texts
    assert_equal(texts[1].text, ({"MAIN","FX","LFO","BUFFER","SETUP"})[page], "page title")
    for _, entry in ipairs(texts) do
      local left, right = text_span(entry)
      assert_true(left >= 0 and right <= 128 and entry.y <= 64, "text inside screen on page " .. page)
    end
  end
end)

test("arc rings follow the page; MAIN mapping unchanged", function()
  local context = load_strata(); context.clock.advance()
  local device = context.arc.plug(1)
  context.arc.turn(1, 1, 20); assert_true(params:get("master_density") > 1.0, "ring 1 density on MAIN")
  enc(1, 4); arc_redraw()
  assert_equal(next(device.segments), nil, "SETUP page draws no rings")
end)

test("main_param_id and main_param_label name each voice's E3 and arc ring 2 param", function()
  local context = load_strata()
  local device = context.arc.plug(1)
  local expected = { resonator = "freq", fm = "index", folder = "fold", sub = "drift",
    pulse = "width", karplus = "decay", ring = "ratio" }
  local voices = local_value("voices")
  local _, set_selected = find_upvalue("selected_voice")
  for voice_idx = 1, 7 do
    local key_name = expected[voices[voice_idx].name]
    local param_id = "v" .. voice_idx .. "_" .. key_name
    assert_equal(main_param_id(voice_idx), param_id, "main param id of voice " .. voice_idx)
    assert_equal(main_param_label(voice_idx), key_name, "main param label of voice " .. voice_idx)
    -- arc ring 2 adjusts it and shows it across its controlspec range
    set_selected(voice_idx)
    local min_value, max_value = param_range(param_id)
    params:set(param_id, min_value)
    context.arc.turn(1, 2, 100)  -- enough for one step of sub's fine-scaled drift
    local value = params:get(param_id)
    assert_true(value > min_value, "arc ring 2 raises " .. param_id)
    local expected_end = util.linlin(min_value, max_value, 0, 64, value) / 64 * math.pi * 2
    assert_near(device.segments[2].to, expected_end, 1e-9, "ring 2 shows " .. param_id)
    -- MAIN shows the label and value in the right column
    redraw()
    local label_found = false
    for _, entry in ipairs(context.screen.texts) do
      if entry.x == 65 and entry.y == 42 and entry.text == key_name then label_found = true end
    end
    assert_true(label_found, "MAIN shows the " .. key_name .. " label")
  end
end)

test("every encoder, key and arc control is safe on every page; arc button only acts on MAIN", function()
  local context = load_strata(); context.clock.advance()
  context.arc.plug(1)
  context.grid.plug(1, 16, 16)
  for page = 1, #PAGE_TITLES do
    show_page(page)
    for _, n in ipairs({ 2, 3 }) do
      enc(n, 1); enc(n, -1)
      assert_equal(local_value("ui_page"), page, "E" .. n .. " stays on " .. PAGE_TITLES[page])
    end
    for n = 1, 3 do key(n, 1); key(n, 0) end
    for ring = 1, 4 do context.arc.turn(1, ring, 5); context.arc.turn(1, ring, -5) end
    arc_redraw()
    if page ~= 1 then
      local frozen = deep_copy(local_value("frozen"))
      local active = {}
      for voice_idx, voice in ipairs(local_value("voices")) do active[voice_idx] = voice.active end
      context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
      for voice_idx, voice in ipairs(local_value("voices")) do
        assert_equal(voice.active, active[voice_idx], "arc button leaves voices alone on " .. PAGE_TITLES[page])
        assert_equal(local_value("frozen")[voice_idx], frozen[voice_idx], "arc button leaves freeze alone on " .. PAGE_TITLES[page])
      end
    end
  end
  -- SETUP: arc rings do nothing
  show_page(5)
  local density = params:get("master_density")
  context.arc.turn(1, 1, 40)
  assert_equal(params:get("master_density"), density, "arc ring 1 does not change density on SETUP")
end)

test("SETUP page shows grids, arc and scenes; K3 saves scenes to disk", function()
  local context = load_strata()
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  show_page(5)
  assert_true(screen_has("grid: 0 connected"), "no grids")
  assert_true(screen_has("arc: none"), "no arc")
  assert_true(screen_has("scenes: 0/8 saved"), "no scenes")
  context.grid.plug(1, 16, 16)
  context.grid.plug(3, 8, 8)
  context.arc.plug(1)
  capture_scene(3)
  redraw()
  assert_true(screen_has("grid: 2 connected"), "two grids")
  assert_true(screen_has("16x16 8x8"), "grid sizes in port order")
  assert_true(screen_has("arc: connected"), "arc connected")
  assert_true(screen_has("scenes: 1/8 saved"), "one scene")
  context.arc.unplug(1)
  context.grid.unplug(3)
  assert_true(screen_has("arc: none"), "unplugging the arc redraws SETUP")
  assert_true(screen_has("grid: 1 connected"), "unplugging a grid redraws SETUP")

  local scene_file = context.data_dir .. "strata/scenes.data"
  assert_true(not util.file_exists(scene_file), "no scenes file yet")
  key(3, 1)
  assert_true(util.file_exists(scene_file), "K3 on SETUP saves scenes")
end)

test("grid LEDs follow non-grid state changes (I9) and the played step (M7)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  -- row 14, columns 9-15 show voice on/off; row 16 shows freeze
  toggle_voice(5)
  assert_equal(device:get_led(13, 14), 12, "voice 5 on lights row 14")
  toggle_voice(5)
  assert_equal(device:get_led(13, 14), 2, "voice 5 off dims row 14")
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(1)
  key(3, 1)  -- voice 1 is active: K3 freezes it
  assert_equal(device:get_led(1, 16), 12, "K3 freeze lights row 16")
  context.arc.plug(1)
  context.arc.push(1, 1, 1)
  assert_equal(device:get_led(1, 16), 2, "arc button unfreeze dims row 16")

  -- the highlighted step is the one that just played
  toggle_pattern_step(1, 1)
  pattern_toggle()
  assert_equal(device:get_led(1, 1), 15, "step 1 highlighted while it plays")
  assert_equal(device:get_led(2, 1), 0, "step 2 not highlighted")
  assert_equal(device:get_led(1, 2), 4, "empty step under the playhead shows dim")
  pattern_toggle()

  -- page 2 faders follow mutations
  context.grid.press(1, 14, 8, 1)  -- grid page 2 (parameters)
  context.grid.press(1, 1, 14, 1)  -- voice 1
  params:set("v1_freq", 20)        -- changes the param without a grid redraw
  params:set("mutation_probability", 1)
  params:set("mutation_amount", 1)
  -- gentle_mutate visits params with pairs(), so which random draw lands on
  -- freq varies between processes; a negative draw clamps freq back to the
  -- minimum. Mutate until it moves (each try has about an even chance).
  local freq_column = 1
  for _ = 1, 40 do
    gentle_mutate()
    freq_column = fader_position("v1_freq")
    if freq_column > 1 then break end
  end
  assert_true(freq_column > 1, "mutation moved freq off the minimum")
  assert_equal(device:get_led(freq_column, 9), 15, "freq fader LED follows the mutation")

  -- grid_redraw with no grids is a no-op
  context.grid.unplug(1)
  assert_equal(next(local_value("grids")), nil, "unplug clears the grids table")
  grid_redraw()
end)

test("hot-plugged grid and arc fire handlers once per event (I3)", function()
  local context = load_strata()
  context.grid.plug(3, 16, 16)
  local calls = 0
  local real_grid_key = grid_key
  grid_key = function(...) calls = calls + 1; return real_grid_key(...) end
  context.grid.press(3, 1, 1, 1)
  assert_equal(calls, 1, "grid_key runs once per press")
  context.grid.unplug(3)
  context.grid.plug(3, 16, 16)
  context.grid.press(3, 1, 2, 1)
  assert_equal(calls, 2, "replugged grid still runs grid_key once per press")
  grid_key = real_grid_key

  context.arc.plug(1)
  local before = params:get("master_density")
  context.arc.turn(1, 1, 20)  -- one delta of 20 -> +1 quantum step
  local one_step = params:get("master_density") - before
  context.arc.unplug(1)
  context.arc.plug(1)
  before = params:get("master_density")
  context.arc.turn(1, 1, 20)
  assert_near(params:get("master_density") - before, one_step, 1e-9, "replugged arc handles a turn once")
end)

test("cleanup stops everything and darkens controllers (M9)", function()
  local context = load_strata()
  local grid_device = context.grid.plug(1, 16, 16)
  local arc_hardware = context.arc.plug(1)
  context.clock.advance()  -- finish init's voice start-up coroutine
  capture_scene(1)
  params:set("scene_sequencer_enabled", 1)
  params:set("mutation_enabled", 1)
  pattern_toggle()
  recall_scene(1, 5)
  context.clear_engine_calls()
  cleanup()
  assert_equal(params:get("scene_sequencer_enabled"), 0, "scene sequencer param reset")
  assert_equal(params:get("mutation_enabled"), 0, "mutation param reset")
  assert_equal(context.clock.pending_count(), 0, "no clocks left running")
  for _, timer in ipairs(context.metro.all) do assert_true(not timer.running, "metro stopped") end
  local lit = 0
  for x = 1, 16 do for y = 1, 16 do lit = lit + grid_device:get_led(x, y) end end
  assert_equal(lit, 0, "grid LEDs cleared")
  assert_true(next(arc_hardware.segments) == nil, "arc rings cleared")
  local voices_off = #context.calls_named("voiceOff")
  assert_true(voices_off >= 1, "running voices turned off")
  assert_true(util.file_exists(context.data_dir .. "strata/scenes.data"), "scenes saved on cleanup")
end)

---------------------------------------------------------------------------
-- effects chain, FX page, scene format 2
---------------------------------------------------------------------------

local FX_PARAM_IDS = { "filter_type", "filter_freq", "filter_res", "filter_mix",
  "delay_time", "delay_feedback", "delay_mix", "reverb_mix", "reverb_size", "reverb_damp", "drift_amount" }

test("fx params drive setFilter/setDelay and live in scenes", function()
  local context = load_strata(); context.clear_engine_calls()
  params:set("filter_type", 3); params:set("filter_freq", 1200); params:set("filter_mix", 1)
  local call = context.calls_named("setFilter"); call = call[#call]
  assert_near(call.args[1], 1200, 1); assert_equal(call.args[3], 2); assert_equal(call.args[4], 1)
  params:set("delay_time", 0.5); params:set("delay_feedback", 0.6); params:set("delay_mix", 0.3)
  call = context.calls_named("setDelay"); call = call[#call]
  assert_near(call.args[1], 0.5, 1e-6); assert_near(call.args[2], 0.6, 1e-6); assert_near(call.args[3], 0.3, 1e-6)
  capture_scene(1); params:set("filter_freq", 300); params:set("delay_mix", 0)
  recall_scene(1, 0)
  assert_near(params:get("filter_freq"), 1200, 1); assert_near(params:get("delay_mix"), 0.3, 1e-6)
end)

test("fx params: defaults, one exactly sized strata_fx group, scene defaults match", function()
  load_strata()
  local expected_defaults = { filter_type = 1, filter_freq = 5000, filter_res = 0.5, filter_mix = 0,
    delay_time = 0.375, delay_feedback = 0.4, delay_mix = 0 }
  for param_id, default in pairs(expected_defaults) do
    assert_near(params:get(param_id), default, 1e-9, param_id .. " default")
  end
  assert_equal(params:lookup_param("filter_type").count, 3, "lowpass, highpass, bandpass")
  assert_equal(params:string("filter_type"), "lowpass")
  -- the group holds exactly the FX params, in order
  local group_index
  for index, param in ipairs(params.params) do
    if param.id == "strata_fx" then group_index = index end
  end
  assert_true(group_index, "strata_fx group exists")
  assert_equal(params.params[group_index].t, params.tGROUP)
  assert_equal(params.params[group_index].n, #FX_PARAM_IDS, "group size")
  for offset, param_id in ipairs(FX_PARAM_IDS) do
    assert_equal(params.params[group_index + offset].id, param_id, "group entry " .. offset)
  end
  assert_true(not params.lookup["strata_reverb"], "the reverb separator is replaced by the group")
  -- every scene global carries its param's default (tempo follows clock_tempo)
  local in_scene = {}
  for _, global in ipairs(local_value("SCENE_GLOBAL_PARAMS")) do
    in_scene[global.id] = global
    assert_true(type(global.default) == "number", global.id .. " has a default")
    if global.id ~= "tempo" then
      local param = params:lookup_param(global.id)
      local param_default = param.controlspec and param.controlspec.default or param.default
      assert_near(global.default, param_default, 1e-9, global.id .. " scene default")
    end
  end
  for _, param_id in ipairs(FX_PARAM_IDS) do
    assert_true(in_scene[param_id], param_id .. " is a scene global")
    assert_equal(in_scene[param_id].continuous, param_id ~= "filter_type", param_id .. " continuity")
  end
end)

test("v1 scene file migrates to v2 with fx defaults", function()
  local context = load_strata({ data_subdir = "v1" })
  capture_scene(2)
  local scenes = local_value("scenes")
  for _, param_id in ipairs(FX_PARAM_IDS) do
    if param_id:find("^filter_") or param_id:find("^delay_") then
      scenes[2].data[param_id] = nil   -- as a v1 file lacks them
    end
  end
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  tab.save(scenes, context.data_dir .. "strata/scenes.data")  -- v1 wrote the bare array
  params:set("filter_freq", 300); params:set("delay_mix", 0.5)
  load_scenes_from_disk()
  assert_true(local_value("scenes")[2].populated)
  recall_scene(2, 0)                                           -- must not error on nil
  assert_near(params:get("filter_freq"), 5000, 1); assert_equal(params:get("delay_mix"), 0)
  assert_true(table.concat(context.printed, "\n"):find("migrated scenes file from version 1"),
    "migration message printed")
  -- a versioned version-1 file migrates too, and the next save writes version 2
  tab.save({ version = 1, scenes = scenes }, context.data_dir .. "strata/scenes.data")
  context = load_strata({ data_subdir = "v1" })
  assert_true(local_value("scenes")[2].populated, "versioned v1 file loads")
  save_scenes_to_disk()
  local saved = dofile(context.data_dir .. "strata/scenes.data")
  assert_equal(saved.version, 2, "scenes are saved as version 2")
  assert_near(saved.scenes[2].data.filter_freq, 5000, 1, "migrated default saved")
end)

test("migrate_scene fills table-driven voice defaults and tolerates malformed data", function()
  load_strata()
  capture_scene(1)
  local scene = deep_copy(local_value("scenes")[1])
  local voice_defaults = local_value("VOICE_SCENE_DEFAULTS")
  -- later formats add per-voice fields through VOICE_SCENE_DEFAULTS
  table.insert(voice_defaults, { path = { "test_block", "field" }, default = 7 })
  table.insert(voice_defaults, { path = { "grain", "test_field" }, default = 3 })
  migrate_scene(scene, 1)
  table.remove(voice_defaults); table.remove(voice_defaults)
  for voice_idx = 1, 7 do
    assert_equal(scene.data.voices[voice_idx].grain.test_field, 3, "nested voice default filled")
    assert_equal(scene.data.voices[voice_idx].test_block, nil, "missing parent tables are not invented")
  end
  scene.data.reverb_mix = nil
  migrate_scene(scene, 1)
  assert_near(scene.data.reverb_mix, 0.3, 1e-9, "missing global filled from its default")
  scene.data.reverb_mix = 0.9
  migrate_scene(scene, 1)
  assert_near(scene.data.reverb_mix, 0.9, 1e-9, "present values are kept")
  -- malformed scenes are left for validate_scene to reject
  for _, bad in ipairs({ "x", {}, { populated = true }, { populated = true, data = { voices = "v" } },
      { populated = true, data = { voices = { "a", 3 } } }, { populated = false } }) do
    migrate_scene(bad, 1)
  end
end)

test("FX page: E2 selects a row, E3 adjusts it, K3 bypasses the filter", function()
  local context = load_strata(); enc(1, 1)
  params:set("filter_mix", 0.8); key(3, 1); assert_equal(params:get("filter_mix"), 0)
  key(3, 1); assert_near(params:get("filter_mix"), 0.8, 1e-6)
  enc(2, 3); local before = params:get("filter_freq"); enc(3, 2)
  assert_true(params:get("filter_freq") > before, "row 4 is filter freq")
  -- K3 from a bypassed default turns the filter fully on
  context = load_strata(); enc(1, 1)
  key(3, 1); assert_equal(params:get("filter_mix"), 1, "first K3 turns the filter on")
  local function hint_text()
    for _, entry in ipairs(context.screen.texts) do
      if entry.y == 62 then return entry.text end
    end
  end
  redraw(); assert_equal(hint_text(), "K3:filter bypass")
  key(3, 1); redraw(); assert_equal(hint_text(), "K3:filter on")
end)

test("FX page K3 restores the last non-zero filter mix however it was set", function()
  load_strata(); enc(1, 1)
  enc(2, 5)                                    -- row 6: filter mix
  enc(3, 50); assert_near(params:get("filter_mix"), 0.5, 1e-6, "E3 sets the mix to 0.5")
  enc(3, -50); assert_equal(params:get("filter_mix"), 0, "E3 brings it to 0")
  key(3, 1); assert_near(params:get("filter_mix"), 0.5, 1e-6, "K3 restores the mix E3 last set")
  params:set("filter_mix", 0.3); params:set("filter_mix", 0)  -- PARAMS menu, scene recall, ...
  key(3, 1); assert_near(params:get("filter_mix"), 0.3, 1e-6, "K3 restores a mix set through params")
end)

test("FX page rows stay apart and inside 128x64 at every row and value", function()
  local context = load_strata()
  params:set("mutation_enabled", 1)
  capture_scene(8); recall_scene(8, 0)
  show_page(2)
  local rows = local_value("FX_ROWS")
  assert_equal(#rows, 12, "density, drift, 4 filter, 3 delay, 3 reverb rows")
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  for _, extreme in ipairs({ "max", "min" }) do
    for _, row in ipairs(rows) do
      local min_value, max_value = param_range(row.param_id)
      if row.param_id == "filter_type" then min_value, max_value = 2, 3 end  -- highpass, bandpass
      params:set(row.param_id, extreme == "max" and max_value or min_value)
    end
    enc(2, -100)
    for row = 1, #rows do
      assert_equal(local_value("fx_row"), row, "E2 steps one row")
      redraw()
      assert_screen_layout(context, "FX row " .. row .. ", " .. extreme)
      assert_true(screen_has(rows[row].label), "selected row " .. rows[row].label .. " is visible")
      enc(2, 1)
    end
    assert_equal(local_value("fx_row"), #rows, "E2 stops at the last row")
  end
end)

test("arc FX page: rings adjust filter freq/res, delay time/mix and show them", function()
  local context = load_strata()
  local device = context.arc.plug(1)
  show_page(2)
  local density = params:get("master_density")
  for ring, param_id in ipairs({ "filter_freq", "filter_res", "delay_time", "delay_mix" }) do
    local before = params:get(param_id)
    context.arc.turn(1, ring, 100)
    assert_true(params:get(param_id) > before, "ring " .. ring .. " raises " .. param_id)
    local spec = params:lookup_param(param_id).controlspec
    assert_near(device.segments[ring].to, spec:unmap(params:get(param_id)) * math.pi * 2, 1e-9,
      "ring " .. ring .. " shows " .. param_id)
  end
  assert_equal(params:get("master_density"), density, "density is not on the FX rings")
end)

test("grid page 4 shows FX faders in rows 3-7 and keeps row 8/16", function()
  local context = load_strata(); context.clock.advance()
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 16, 8, 1)              -- page 4
  context.grid.press(1, 16, 3, 1); assert_near(params:get("filter_freq"), 20000, 1)
  context.grid.press(1, 1, 7, 1); assert_equal(params:get("delay_mix"), 0)
  assert_equal(device:get_led(16, 3), 15, "filter freq fader at max")
  context.grid.press(1, 8, 4, 1)               -- filter res, column 8
  assert_near(params:get("filter_res"), 7 / 15, 0.01, "column 8 sets the proportional value")
  assert_equal(device:get_led(7, 4), 8, "bar below the value")
  assert_equal(device:get_led(9, 4), 0, "nothing above the value")
  local patterns = local_value("patterns")
  assert_equal(patterns[3][16], 0, "FX fader presses do not toggle pattern steps")
  for x = 1, 16 do
    for _, y in ipairs({ 1, 2, 9, 10, 11, 12, 13, 14, 15 }) do
      assert_equal(device:get_led(x, y), 0, "row " .. y .. " dark on page 4")
    end
  end
  context.grid.press(1, 1, 8, 1); assert_true(local_value("pattern_playing"), "row 8 play on page 4")
  context.grid.press(1, 1, 16, 1); assert_true(local_value("frozen")[1], "row 16 freeze on page 4")
  assert_equal(device:get_led(1, 16), 12, "row 16 shows freeze on page 4")
  assert_equal(device:get_led(16, 8), 15, "row 8 shows page 4 selected")
  -- FX changes made elsewhere move the faders
  params:set("delay_mix", 1)
  assert_equal(device:get_led(16, 7), 15, "delay mix fader follows a param change")
end)

---------------------------------------------------------------------------
-- harness: stubs for the norns APIs used by later features
---------------------------------------------------------------------------

test("stub params support option, group, trigger, binary, file and set_action", function()
  load_strata()
  params:add_option("stub_opt", "opt", {"a", "b", "c"}, 2)
  assert_equal(params:get("stub_opt"), 2); assert_equal(params:string("stub_opt"), "b")
  assert_equal(params:lookup_param("stub_opt").count, 3)
  local fired
  params:set_action("stub_opt", function(v) fired = v end)
  params:set("stub_opt", 3); assert_equal(fired, 3)
  fired = nil
  params:set("stub_opt", 9); assert_equal(fired, nil, "option clamps to its count, unchanged value is silent")
  params:set("stub_opt", 1.7); assert_equal(params:get("stub_opt"), 1, "option index is floored")
  params:add_file("stub_file", "file", ""); params:set("stub_file", "/tmp/x.wav")
  assert_equal(params:get("stub_file"), "/tmp/x.wav")
  assert_equal(params:string("stub_file"), "x.wav", "file params display the file name")
  params:add_trigger("stub_trig", "trig"); params:add_binary("stub_bin", "bin", "toggle", 0)
  local triggered = 0
  params:set_action("stub_trig", function() triggered = triggered + 1 end)
  params:set("stub_trig", 1); params:set("stub_trig", 1)
  assert_equal(triggered, 2, "triggers fire on every set")
  params:set("stub_bin", 5); assert_equal(params:get("stub_bin"), 1, "toggle binary stores 0/1")
  params:add_group("stub_group", "group", 2); params:hide("stub_opt"); params:show("stub_opt")
  assert_true(params:visible("stub_opt"), "shown param is visible")
  params:hide("stub_file"); assert_true(not params:visible("stub_file"), "hidden param is not visible")
  params:add_text("stub_text", "text", ""); params:set("stub_text", "hello")
  assert_equal(params:string("stub_text"), "hello")
end)

test("stub params store norns' numeric type constants in param.t", function()
  load_strata()
  -- lua/core/paramset.lua: ParamSet.tSEPARATOR = 0 ... tBINARY = 9
  local expected_codes = { tSEPARATOR = 0, tNUMBER = 1, tOPTION = 2, tCONTROL = 3, tFILE = 4, tTAPER = 5,
    tTRIGGER = 6, tGROUP = 7, tTEXT = 8, tBINARY = 9 }
  for name, code in pairs(expected_codes) do assert_equal(params[name], code, "params." .. name) end
  params:add_separator("stub_sep", "sep"); params:add_number("stub_num", "num", 0, 4, 1)
  params:add_option("stub_opt", "opt", {"a", "b"}, 1)
  params:add_control("stub_ctl", "ctl", controlspec.new(0, 1, "lin", 0, 0))
  params:add_file("stub_file", "file", ""); params:add_trigger("stub_trig", "trig")
  params:add_text("stub_text", "text", ""); params:add_binary("stub_bin", "bin", "toggle", 0)
  params:add_group("stub_group", "group", 1)
  local expected_types = { stub_sep = params.tSEPARATOR, stub_num = params.tNUMBER, stub_opt = params.tOPTION,
    stub_ctl = params.tCONTROL, stub_file = params.tFILE, stub_trig = params.tTRIGGER, stub_text = params.tTEXT,
    stub_bin = params.tBINARY, stub_group = params.tGROUP }
  for param_id, code in pairs(expected_types) do
    assert_equal(params:lookup_param(param_id).t, code, param_id .. " type code")
  end
end)

test("strata.lua never compares a param type with a string", function()
  local file = assert(io.open(LUA_PATH, "r")); local source = file:read("*a"); file:close()
  assert_true(not source:find('%.t%s*[=~]=%s*"'), "param.t is numeric on norns; compare with params.tX")
end)

test("stub lfo mirrors lib/lfo params and calls the action with scaled and raw", function()
  local context = load_strata()
  local LFO = require("lfo")
  local got
  local instance = LFO:add{ shape = "sine", min = -1, max = 1, depth = 0.5, mode = "free", period = 1,
    baseline = "center", action = function(scaled, raw) got = { scaled, raw } end }
  instance:add_params("stubtest", nil, "stub")
  -- the library's params, types and ranges (lua/lib/lfo.lua add_params)
  assert_equal(params:lookup_param("lfo_group_stubtest").n, 15, "group holds the library's 15 params")
  local expected_types = {
    lfo_stubtest = "option", lfo_shape_stubtest = "option", lfo_depth_stubtest = "number",
    lfo_phase_stubtest = "number", lfo_offset_stubtest = "number", lfo_scaled_stubtest = "text",
    lfo_raw_stubtest = "text", lfo_min_stubtest = "control", lfo_max_stubtest = "control",
    lfo_baseline_stubtest = "option", lfo_mode_stubtest = "option", lfo_clocked_stubtest = "option",
    lfo_free_stubtest = "control", lfo_reset_stubtest = "trigger", lfo_reset_target_stubtest = "option",
  }
  for param_id, param_type in pairs(expected_types) do
    assert_equal(params:lookup_param(param_id).t, params["t" .. param_type:upper()], param_id .. " type")
  end
  local depth_param = params:lookup_param("lfo_depth_stubtest")
  assert_equal(depth_param.min, 0); assert_equal(depth_param.max, 100)
  assert_equal(params:get("lfo_depth_stubtest"), 50, "depth is a percentage")
  assert_equal(params:lookup_param("lfo_shape_stubtest").count, 6)
  assert_equal(params:string("lfo_mode_stubtest"), "free")
  assert_equal(params:string("lfo_baseline_stubtest"), "from center")
  local free_spec = params:lookup_param("lfo_free_stubtest").controlspec
  assert_equal(free_spec.minval, 0.1); assert_equal(free_spec.maxval, 300)
  assert_near(params:get("lfo_free_stubtest"), 1, 1e-9, "free period")
  assert_equal(params:string("lfo_stubtest"), "off")
  assert_equal(instance:get("enabled"), 0)

  context.lfo.tick(instance, 1.0)
  assert_equal(got, nil, "disabled LFO never fires")
  params:set("lfo_stubtest", 2)
  assert_equal(instance:get("enabled"), 1, "state on enables the LFO")
  context.lfo.tick(instance, 1.0); assert_near(got[1], 0.5, 1e-9); assert_near(got[2], 1.0, 1e-9)
  context.lfo.tick(instance, 0.0); assert_near(got[1], -0.5, 1e-9, "center baseline is symmetric")
  assert_equal(params:get("lfo_scaled_stubtest"), -0.5, "scaled value is shown in the text param")
  params:set("lfo_depth_stubtest", 25)
  context.lfo.tick(instance, 1.0); assert_near(got[1], 0.25, 1e-9, "depth 25% scales to +-0.25")
  params:set("lfo_depth_stubtest", 0); got = nil
  context.lfo.tick(instance, 1.0); assert_equal(got, nil, "depth 0 never fires")
  params:set("lfo_depth_stubtest", 50); params:set("lfo_stubtest", 1); got = nil
  context.lfo.tick(instance, 1.0); assert_equal(got, nil, "state off stops the LFO")
  assert_equal(instance:get("enabled"), 0)
end)

test("stub midi delivers note_on, cc and pitchbend messages", function()
  local context = load_strata()
  local vport = midi.connect(1)
  local seen = {}
  vport.event = function(data) table.insert(seen, midi.to_msg(data)) end
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  context.midi.send(1, { type = "cc", cc = 1, val = 64, ch = 1 })
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 1 })
  context.midi.send(1, { type = "note_on", note = 61, vel = 0, ch = 2 })
  assert_equal(seen[1].type, "note_on"); assert_equal(seen[1].note, 60); assert_equal(seen[1].ch, 3)
  assert_equal(seen[1].vel, 100)
  assert_equal(seen[2].type, "cc"); assert_equal(seen[2].cc, 1); assert_equal(seen[2].val, 64)
  assert_equal(seen[3].type, "pitchbend"); assert_equal(seen[3].val, 8192 + 4096)
  assert_equal(seen[4].type, "note_off", "velocity 0 note_on is a note_off, as in norns")
  assert_true(vport.device ~= nil and vport.name ~= "none", "sending plugs a device into the port")
  local added, removed
  midi.add = function(device) added = device end
  midi.remove = function(device) removed = device end
  local device = context.midi.plug(2, "keys")
  assert_equal(added, device); assert_equal(midi.connect(2).name, "keys")
  assert_equal(midi.devices[device.id], device)
  context.midi.unplug(2)
  assert_equal(removed, device); assert_equal(midi.connect(2).device, nil)
end)

test("stub fileselect, musicutil, polls and audio path", function()
  local context = load_strata()
  local picked
  fileselect.enter(_path.audio, function(path) picked = path end, "audio")
  assert_equal(fileselect.last.folder, _path.audio); assert_equal(fileselect.last.filter, "audio")
  fileselect.last.callback("/x.wav"); assert_equal(picked, "/x.wav")
  assert_equal(_path.audio, context.audio_dir)
  assert_true(util.file_exists(_path.audio), "audio dir exists")
  local file = assert(io.open(_path.audio .. "a.wav", "w")); file:write("x"); file:close()
  local listing = util.scandir(_path.audio)
  assert_equal(#listing, 1); assert_equal(listing[1], "a.wav")
  assert_equal(util.os_capture("echo '  hi  '"), "hi")
  local musicutil = require("musicutil")
  assert_near(musicutil.note_num_to_freq(69), 440, 1e-9); assert_near(musicutil.note_num_to_freq(57), 220, 1e-9)
  local values = {}
  local amp_poll = poll.set("amp_in_l", function(value) table.insert(values, value) end)
  assert_true(amp_poll ~= nil, "system polls exist")
  assert_equal(poll.set("no_such_poll", function() end), nil, "unknown polls return nil, as in norns")
  amp_poll:start()
  context.polls.fire("amp_in_l", 0.25)
  amp_poll:stop()
  context.polls.fire("amp_in_l", 0.5)
  assert_equal(#values, 1, "stopped polls do not fire"); assert_equal(values[1], 0.25)
end)

---------------------------------------------------------------------------
-- runner
---------------------------------------------------------------------------

local failures = 0
for _, entry in ipairs(tests) do
  local ok, err = xpcall(entry.func, debug.traceback)
  print = real_print
  if ok then
    real_print("ok   " .. entry.name)
  else
    failures = failures + 1
    real_print("FAIL " .. entry.name .. "\n     " .. tostring(err):gsub("\n", "\n     "))
  end
end

os.execute("rm -rf '" .. data_root .. "'")

real_print(string.format("\n%d tests, %d failures", #tests, failures))
os.exit(failures == 0 and 0 or 1)

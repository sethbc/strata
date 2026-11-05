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
local engine_spec = stubs.parse_engine_spec(SC_PATH)

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
  local context = stubs.install { signatures = signatures, engine_polls = engine_polls, engine_spec = engine_spec, data_dir = data_dir, quiet = true }
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
  assert_equal(voice.source, captured.source, prefix .. "source")
  assert_equal(voice.active, captured.active, prefix .. "active")
end

-- Put every voice into a distinctive, non-default state through params
local function scramble_state(seed)
  math.randomseed(seed)
  for voice_idx = 1, 7 do
    -- source first: randomize_voice then picks buffer or synth params
    params:set("v" .. voice_idx .. "_source", math.random(1, 10))
    randomize_voice(voice_idx)
    params:set("v" .. voice_idx .. "_buf_pos", math.random())
    params:set("v" .. voice_idx .. "_buf_rate", 0.25 + math.random() * 3.75)
    params:set("v" .. voice_idx .. "_buf_scan", math.random() * 4 - 2)
    params:set("v" .. voice_idx .. "_grain_spread", math.random())
    params:set("v" .. voice_idx .. "_grain_density", math.random(1, 100))
    params:set("v" .. voice_idx .. "_grain_env", math.random(1, 5))
    params:set("v" .. voice_idx .. "_grain_mode", math.random(1, 2))
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

-- Expects engine.<name>(...) to be rejected by the engine stub with an error
-- containing `expected_text`
local function assert_engine_rejects(expected_text, name, ...)
  local ok, message = pcall(engine[name], ...)
  assert_true(not ok, "engine." .. name .. " should be rejected (" .. expected_text .. ")")
  assert_true(tostring(message):find(expected_text, 1, true) ~= nil,
    "engine." .. name .. " error mentions " .. expected_text .. ": " .. tostring(message))
end

test("the engine stub reads its limits and controls from the engine source (#24)", function()
  load_strata()
  local spec = stubs.parse_engine_spec(SC_PATH)
  assert_equal(spec.num_voices, local_value("NUM_VOICES"), "numVoices")
  assert_equal(spec.num_buffers, local_value("NUM_BUFFERS"), "numBuffers")
  assert_equal(spec.input_source, local_value("NUM_BUFFERS") + 1, "inputSource")
  assert_equal(spec.mod_slots, local_value("NUM_MOD_SLOTS"), "modBus1..N on every voice SynthDef")
  assert_equal(#spec.voice_synthdefs, spec.num_voices, "one voice SynthDef per voice")
  assert_equal(spec.voice_synthdefs[1], "strataResonator", "voice 0 SynthDef")
  assert_equal(spec.voice_synthdefs[7], "strataRing", "voice 6 SynthDef")
  assert_true(spec.synthdef_controls.strataFM.ratio, "strataFM controls parsed")
  assert_true(spec.synthdef_controls.strataGrainBuf.bufPos, "strataGrainBuf controls parsed")
  assert_true(spec.grain_params.envShape, "setGrainParam's own envShape is accepted")
  assert_true(spec.grain_params.bufPos and spec.grain_params.grainSize, "grain SynthDef controls are accepted")
  -- each enumerated control is 0..options - 1 of its Lua option param
  assert_equal(spec.enumerations.grainMode[1], 0, "grainMode from 0")
  assert_equal(spec.enumerations.grainMode[2], #local_value("GRAIN_MODE_OPTIONS") - 1, "grainMode to triggered")
  assert_equal(spec.enumerations.envShape[1], 0, "envShape from Hann")
  assert_equal(spec.enumerations.envShape[2], #local_value("GRAIN_ENV_OPTIONS") - 1, "envShape to the last envelope buffer")
  assert_equal(spec.enumerations.filterType[1], 0, "filterType from lowpass")
  assert_equal(spec.enumerations.filterType[2], 2, "filterType to bandpass")
  -- a control added to a grain SynthDef is picked up without stub changes
  local file = assert(io.open(SC_PATH, "r")); local source = file:read("*a"); file:close()
  local extended, count = source:gsub("SynthDef%(\\strataGrain, {%s*arg ", "%0newGrainControl=0, ")
  assert_equal(count, 1, "test patch applies")
  assert_true(stubs.engine_spec_from_source(extended).grain_params.newGrainControl, "new grain control accepted")
end)

test("the engine stub rejects out-of-range engine arguments (#24)", function()
  load_strata()
  -- voices are 0..numVoices-1
  assert_engine_rejects("voice", "voiceOff", 7)
  assert_engine_rejects("voice", "voiceOff", -1)
  assert_engine_rejects("voice", "voiceOn", 7, 100, 0.3, 0, 0.1, 20, 1)
  assert_engine_rejects("voice", "retrigger", 7, 1)
  assert_engine_rejects("voice", "setVoiceParam", 7, "amp", 0.3)
  assert_engine_rejects("voice", "setGrainParam", 7, "grainSize", 0.1)
  assert_engine_rejects("voice", "setModSpeed", 7, 1)
  engine.voiceOff(0); engine.voiceOff(6)
  -- slots are 0..numBuffers-1
  for _, command in ipairs({"clearBuffer", "stopRecord"}) do
    assert_engine_rejects("slot", command, 8)
    assert_engine_rejects("slot", command, -1)
  end
  assert_engine_rejects("slot", "loadBuffer", 8, "/tmp/x.wav")
  assert_engine_rejects("slot", "saveBuffer", 8, "/tmp/x.wav")
  assert_engine_rejects("slot", "recordBuffer", 8, 4, 1)
  engine.clearBuffer(0); engine.clearBuffer(7)
  -- sources are 0 (synth), 1..numBuffers, numBuffers + 1 (input)
  assert_engine_rejects("source", "setGrainSource", 0, 10)
  assert_engine_rejects("source", "setGrainSource", 0, -1)
  engine.setGrainSource(0, 0); engine.setGrainSource(0, 9)
  -- mod slots are 1..3, mod sources -1 (none) or a voice
  for _, command in ipairs({"setModAmpAmt", "setModFreqAmt"}) do
    assert_engine_rejects("mod slot", command, 0, 0, 0.5)
    assert_engine_rejects("mod slot", command, 0, 4, 0.5)
    assert_engine_rejects("voice", command, 7, 1, 0.5)
  end
  assert_engine_rejects("mod slot", "setModSource", 0, 4, 1)
  assert_engine_rejects("mod source", "setModSource", 0, 1, 7)
  assert_engine_rejects("mod source", "setModSource", 0, 1, -2)
  engine.setModSource(0, 1, -1); engine.setModSource(0, 3, 6)
  -- filter type 0..2
  assert_engine_rejects("filterType", "setFilter", 5000, 0.5, 3, 0)
  assert_engine_rejects("filterType", "setFilter", 5000, 0.5, -1, 0)
  engine.setFilter(5000, 0.5, 2, 0)
  -- enumerated grain params: whole numbers in range
  assert_engine_rejects("grainMode", "setGrainParam", 0, "grainMode", 2)
  assert_engine_rejects("grainMode", "setGrainParam", 0, "grainMode", 0.5)
  assert_engine_rejects("envShape", "setGrainParam", 0, "envShape", 5)
  assert_engine_rejects("envShape", "setGrainParam", 0, "envShape", -1)
  engine.setGrainParam(0, "grainMode", 1); engine.setGrainParam(0, "envShape", 4)
end)

test("the engine stub rejects param names the SynthDefs do not have (#24)", function()
  load_strata()
  local spec = stubs.parse_engine_spec(SC_PATH)
  -- ratio is a strataFM control (voice 1), not one of strataResonator (voice 0)
  assert_engine_rejects("ratio", "setVoiceParam", 0, "ratio", 1.5)
  engine.setVoiceParam(1, "ratio", 1.5)
  assert_engine_rejects("nonsense", "setVoiceParam", 0, "nonsense", 1)
  for engine_voice = 0, spec.num_voices - 1 do engine.setVoiceParam(engine_voice, "bend", 1) end
  -- grain params: either grain SynthDef's controls (kept for a source switch) plus envShape
  assert_engine_rejects("ratio", "setGrainParam", 0, "ratio", 1)
  assert_engine_rejects("grainsize", "setGrainParam", 0, "grainsize", 0.1)
  engine.setGrainParam(0, "bufPos", 0.5); engine.setGrainParam(0, "grainSize", 0.1)
  engine.setGrainParam(0, "envShape", 0)
end)

test("CLAUDE.md command table lists exactly the engine's commands", function()
  local file = assert(io.open(repo_root .. "/CLAUDE.md", "r")); local doc = file:read("*a"); file:close()
  -- table rows: | `engine.<name>(<args>)` | `"<signature>"` | purpose |
  local rows = {}
  for line in doc:gmatch("[^\n]+") do
    local name, args, signature = line:match('^| `engine%.(%w+)%((.-)%)` | `"(%a*)"` |')
    if name then
      assert_true(rows[name] == nil, "CLAUDE.md documents engine." .. name .. " twice")
      local arg_count = 0
      if args:match("%S") then arg_count = select(2, args:gsub(",", ",")) + 1 end
      rows[name] = { signature = signature, arg_count = arg_count }
    end
  end
  for name, signature in pairs(signatures) do
    local row = rows[name]
    assert_true(row ~= nil, "CLAUDE.md command table documents engine." .. name)
    assert_equal(row.signature, signature, "CLAUDE.md signature of engine." .. name)
    assert_equal(row.arg_count, #signature, "CLAUDE.md argument count of engine." .. name)
  end
  for name in pairs(rows) do
    assert_true(signatures[name] ~= nil, "CLAUDE.md command table lists engine." .. name .. ", which the engine does not have")
  end
  -- no engine command mentioned anywhere in CLAUDE.md or README.md is gone
  for _, doc_name in ipairs({"CLAUDE.md", "README.md"}) do
    file = assert(io.open(repo_root .. "/" .. doc_name, "r")); local text = file:read("*a"); file:close()
    for name in text:gmatch("engine%.(%w+)%(") do
      assert_true(signatures[name] ~= nil, doc_name .. " mentions engine." .. name .. ", which the engine does not have")
    end
  end
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
  params:set("master_density", 1.5)
  context.clear_engine_calls()
  scramble_state(42)
  for _, call in ipairs(context.engine_calls) do
    -- the source is always sent (the engine only records it for a stopped voice)
    assert_equal(call.name, "setGrainSource", "edits to stopped voices are not sent")
  end

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
    assert_equal(sent.grain.grainMode, voice.grain.mode - 1, "voice " .. voice_idx .. " grainMode")
    assert_equal(sent.grain.bufPos, voice.grain.buf_pos, "voice " .. voice_idx .. " bufPos")
    assert_equal(sent.grain.bufRate, voice.grain.buf_rate, "voice " .. voice_idx .. " bufRate")
    assert_equal(sent.grain.bufScan, voice.grain.buf_scan, "voice " .. voice_idx .. " bufScan")
    -- the source goes first after voiceOn, before any other voice state
    assert_equal(context.engine_calls[1].name, "voiceOn", "voice " .. voice_idx .. " voiceOn first")
    assert_equal(context.engine_calls[2].name, "setGrainSource", "voice " .. voice_idx .. " source synced first")
    assert_equal(context.engine_calls[2].args[2], voice.source - 1, "voice " .. voice_idx .. " source")
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

test("voiceOn's grain density is the voice's density times master density as the engine has them", function()
  local context = load_strata(); context.clock.advance()
  local voices = local_value("voices")
  if voices[5].active then toggle_voice(5) end
  params:set("v5_grain_density", 20); params:set("master_density", 1.5)
  -- as LFOs on both params would have left them
  local sent_values = local_value("engine_param_values")
  sent_values.master_density = 0.5; sent_values.v5_grain_density = 30
  context.clear_engine_calls(); toggle_voice(5)
  assert_near(context.calls_named("voiceOn")[1].args[6], 15, 1e-9, "voiceOn grainDensity")
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

test("pattern steps retrigger with velocity from the step level", function()
  local context = load_strata(); context.clock.advance()
  local patterns = local_value("patterns"); patterns[1][1] = 15; patterns[1][2] = 6
  context.clear_engine_calls(); pattern_toggle(); context.clock.advance(); pattern_toggle()
  local calls = context.calls_named("retrigger")
  assert_equal(#calls, 2, "one retrigger per active step")
  assert_equal(calls[1].args[1], 0); assert_near(calls[1].args[2], 1.0, 1e-9)
  assert_equal(calls[2].args[1], 0); assert_near(calls[2].args[2], 6 / 15, 1e-9)
end)

test("grain mode option is sent, synced and never mutated", function()
  local context = load_strata(); context.clock.advance()
  params:set("v1_grain_mode", 2)
  local calls = context.calls_named("setGrainParam"); assert_equal(calls[#calls].args[2], "grainMode"); assert_equal(calls[#calls].args[3], 1)
  params:set("mutation_probability", 1); params:set("mutation_amount", 1); gentle_mutate()
  assert_equal(params:get("v1_grain_mode"), 2)
end)

test("grain mode param: options, default, sync, scenes, never mutated, randomized or crossfaded", function()
  local context = load_strata(); context.clock.advance()
  local voices = local_value("voices")
  for voice_idx = 1, 7 do
    local param = params:lookup_param("v" .. voice_idx .. "_grain_mode")
    assert_equal(param.t, params.tOPTION, "voice " .. voice_idx .. " grain_mode is an option")
    assert_equal(param.count, 2, "two grain modes")
    assert_equal(params:get("v" .. voice_idx .. "_grain_mode"), 1, "default continuous")
    assert_equal(voices[voice_idx].grain.mode, 1, "voices table holds the index")
  end
  params:set("v1_grain_mode", 1); assert_equal(params:string("v1_grain_mode"), "continuous")
  params:set("v1_grain_mode", 2); assert_equal(params:string("v1_grain_mode"), "triggered")
  -- edited while off, sent when the voice starts
  assert_true(not voices[3].active, "voice 3 starts off")
  context.clear_engine_calls(); params:set("v3_grain_mode", 2)
  assert_equal(#context.calls_named("setGrainParam"), 0, "a stopped voice's mode is not sent")
  toggle_voice(3)
  assert_equal(engine_state_for_voice(context.engine_calls, 2).grain.grainMode, 1, "start syncs grainMode")
  -- scenes: default, capture/recall, switched at the end of a transition
  local found_mode = false
  for _, field in ipairs(local_value("VOICE_SCENE_DEFAULTS")) do
    if field.path[1] == "grain" and field.path[2] == "mode" then
      found_mode = true
      assert_equal(field.default, params:lookup_param("v1_grain_mode").default, "scene default = param default")
    end
  end
  assert_true(found_mode, "grain.mode has a scene default")
  capture_scene(1); params:set("v1_grain_mode", 1)
  for _, target in ipairs(scene_transition_targets(local_value("scenes")[1].data)) do
    assert_true(not target.id:find("_grain_mode$"), target.id .. " is not crossfaded")
  end
  recall_scene(1, 0); assert_equal(params:get("v1_grain_mode"), 2, "scene recall restores the mode")
  local scene = local_value("scenes")[1]
  for voice_idx = 1, 7 do scene.data.voices[voice_idx].grain.mode = nil end
  migrate_scene(scene, 2)
  assert_equal(scene.data.voices[1].grain.mode, 1, "missing mode migrates to continuous")
  assert_true(validate_scene(scene), "migrated scene validates")
  scene.data.voices[1].grain.mode = 3
  assert_true(not validate_scene(scene), "a mode index past the options is rejected")
  scene.data.voices[1].grain.mode = 1.5
  assert_true(not validate_scene(scene), "a fractional mode index is rejected")
  -- mutation and randomize leave the mode alone
  for voice_idx = 1, 7 do
    if not voices[voice_idx].active then toggle_voice(voice_idx) end
    params:set("v" .. voice_idx .. "_grain_mode", 2)
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(9)
  for _ = 1, 50 do gentle_mutate() end
  for voice_idx = 1, 7 do randomize_voice(voice_idx) end
  for voice_idx = 1, 7 do
    assert_equal(params:get("v" .. voice_idx .. "_grain_mode"), 2, "voice " .. voice_idx .. " mode unchanged")
  end
end)

test("MAIN shows [TRIG] for a voice in triggered grain mode", function()
  local context = load_strata(); context.clock.advance()
  local function trig_drawn()
    redraw()
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == "[TRIG]" then return entry end
    end
  end
  assert_true(not trig_drawn(), "no indicator in continuous mode")
  params:set("v1_grain_mode", 2)
  local entry = trig_drawn()
  assert_true(entry, "indicator in triggered mode")
  assert_equal(entry.y, 42, "on the main parameter label row")
end)

test("grain pitch drift wanders subtly around the user-set pitch (C4)", function()
  local context = load_strata()
  local drift_metro = context.metro.all[1]
  assert_true(drift_metro.running and drift_metro.event == drift_update, "drift metro running")
  params:set("v1_grain_pitch", 1.5)
  math.randomseed(3)
  local max_offset = 0
  for _ = 1, 20000 do
    drift_metro.event()
    max_offset = math.max(max_offset, math.abs(params:get("v1_grain_pitch") - 1.5))
  end
  assert_true(max_offset > 0.001, "pitch actually drifts (" .. max_offset .. ")")
  assert_true(max_offset < 0.06, "drift stays within a few percent (" .. max_offset .. ")")
  -- a new user value becomes the new centre
  params:set("v1_grain_pitch", 0.5)
  for _ = 1, 2000 do drift_metro.event() end
  assert_near(params:get("v1_grain_pitch"), 0.5, 0.06, "walk re-centres on the new value")
  -- frozen voices do not drift
  toggle_freeze(1)
  local frozen_pitch = params:get("v1_grain_pitch")
  for _ = 1, 100 do drift_metro.event() end
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

test("tempo param follows a clock_tempo change made elsewhere (#15)", function()
  local context = load_strata({ before_init = function() params:set("clock_tempo", 97) end })
  -- PARAMETERS > CLOCK > tempo: a plain params:set on the system param
  params:set("clock_tempo", 150)
  assert_equal(params:get("tempo"), 150, "tempo param follows clock_tempo")
  -- a scene captures the tempo that is playing
  capture_scene(1)
  assert_equal(local_value("scenes")[1].data.tempo, 150, "scene captured the external tempo")
  -- grid +1 / -1 step from the external tempo, not from a stale value
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 13, 8, 1)
  context.grid.press(1, 7, 8, 1)
  assert_equal(params:get("clock_tempo"), 151, "grid +1 steps from the external tempo")
  params:set("clock_tempo", 200)
  context.grid.press(1, 6, 8, 1)
  assert_equal(params:get("clock_tempo"), 199, "grid -1 steps from the external tempo")
  -- recall applies the scene's tempo to the clock
  params:set("clock_tempo", 80)
  recall_scene(1)
  assert_equal(params:get("clock_tempo"), 150, "recall sets clock_tempo")
  assert_equal(params:get("tempo"), 150, "recall sets the tempo param")
  -- out-of-range clock tempo clamps the param, not the clock
  params:set("clock_tempo", 20)
  assert_equal(params:get("tempo"), 40, "tempo param clamps to its range")
  assert_equal(params:get("clock_tempo"), 20, "clock_tempo is left alone")
  assert_true(clock.tempo_change_handler ~= nil, "handler installed")
  cleanup()
  assert_equal(clock.tempo_change_handler, nil, "cleanup restores the previous handler")
end)

test("256-grid parameter page faders set values and show them (I8)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  local press = function(x, y) context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0) end
  press(14, 8)  -- grid page 2 (parameters)
  press(2, 14)  -- select voice 2 (fm)
  local ids = fader_param_ids(2)
  assert_equal(ids[1], "v2_freq", "first fader is freq")
  assert_equal(#ids, 6 + 6 + 9, "fm has 21 faders")
  assert_equal(fader_page_count(2), 6, "fm has 6 fader pages")
  assert_equal(ids[11], "v2_grain_env", "grain envelope follows the other grain faders")
  assert_equal(ids[12], "v2_grain_mode", "grain mode follows the envelope")
  assert_equal(fader_page_count(1), 6, "resonator has 6 fader pages")
  assert_equal(fader_page_count(3), 5, "folder has 5 fader pages")
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
  assert_equal(device:get_led(6, 13), 4, "row 13 shows page 6 available")
  assert_equal(device:get_led(7, 13), 0, "no page 7")

  press(3, 13)  -- page 3: faders 9-12 = grain_pitch, grain_spread, grain_env, grain_mode
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
  -- grain mode: two options, columns 1-8 continuous, 9-16 triggered
  press(16, 12)
  assert_equal(params:get("v2_grain_mode"), 2, "mode fader column 16 -> triggered")
  press(8, 12)
  assert_equal(params:get("v2_grain_mode"), 1, "mode fader column 8 -> continuous")
  press(9, 12)
  assert_equal(params:get("v2_grain_mode"), 2, "mode fader column 9 -> triggered")
  assert_equal(device:get_led(16, 12), 15, "triggered shows at column 16")
  press(4, 13)  -- page 4: faders 13-16 = source 1, amp mod 1, freq mod 1, source 2
  press(16, 9)  -- mod source 1 -> 7 (number param, rounded)
  assert_equal(params:get("v2_mod_source_1"), 7, "mod source fader rounds to an integer")
  press(9, 9)
  assert_equal(params:get("v2_mod_source_1"), 4, "mod source column 9 -> round(linlin(1,16,0,7,9))")
  press(1, 10)  -- amp mod 1 -> -2
  assert_near(params:get("v2_mod_amp_amt_1"), -2, 1e-6, "amp mod fader min")
  press(16, 8)  -- grid page 4: rows 9-13 hold voice sources, not parameter faders
  for y = 9, 13 do
    local source = params:get("v" .. (y - 8) .. "_source")
    for x = 1, 16 do
      local level = device:get_led(x, y)
      if x > 10 then
        assert_equal(level, 0, "no fader past the source columns on page 4")
      elseif x == source then
        assert_equal(level, 15, "source rows on page 4")
      else
        assert_true(level == 4 or level == 2, "source rows, not fader bars, on page 4")
      end
    end
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

test("the startup clock leaves a voice 2 started within 0.5 s running", function()
  local context = load_strata()
  local voices = local_value("voices")
  assert_true(not voices[2].active, "voice 2 starts stopped")
  toggle_voice(2)  -- a MIDI note or grid press starts it before the startup sleep ends
  context.clock.advance()
  assert_true(voices[2].active, "voice 2 is still running after the startup clock")
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

test("a smooth scene transition holds filter_type until the fade ends", function()
  local context = load_strata()
  -- the filter freq fades, so setFilter goes out on every step
  params:set("filter_type", 3); params:set("filter_freq", 8000)
  capture_scene(1)
  params:set("filter_type", 1); params:set("filter_freq", 200)
  local function last_filter_type()
    local calls = context.calls_named("setFilter")
    return calls[#calls].args[3]
  end

  recall_scene(1, 20)  -- 20 steps; the first runs immediately, the switch after the last
  for step = 1, 20 do
    assert_equal(params:get("filter_type"), 1, "filter_type at step " .. step)
    assert_equal(last_filter_type(), 0, "engine filter type at step " .. step)
    context.clock.advance()
  end
  assert_equal(local_value("scene_transition_active"), false, "transition finished")
  assert_equal(params:get("filter_type"), 3, "filter_type lands on the target")
  assert_equal(last_filter_type(), 2, "engine filter type lands on the target")
  assert_near(params:get("filter_freq"), 8000, 1.0, "the filter freq faded to its target")
end)

-- Two scenes for the sequencer: scene 2 starts voice 3 in triggered grain
-- mode (both switch only when a transition ends), scene 1 has it stopped
local function capture_sequencer_scenes()
  local voices = local_value("voices")
  if voices[3].active then toggle_voice(3) end
  params:set("v3_grain_mode", 1); capture_scene(1)
  toggle_voice(3); params:set("v3_grain_mode", 2); capture_scene(2)
  toggle_voice(3); params:set("v3_grain_mode", 1)
  params:set("scene_sequence_length", 2)
  return voices
end

-- Run the scene sequencer time-ordered with a 1 ms scheduling delay per
-- wake-up (so the fade's 20 sleeps fall behind one long sleep, as on norns).
-- Returns the list of recalls (it keeps growing while the test runs the
-- clocks on; the next load_strata defines recall_scene afresh): scene,
-- util.time() and whether a transition was still running (the recall
-- would cancel it)
local function run_scene_sequencer(context, transition, duration, seconds)
  local recalls = {}
  local real_recall = recall_scene
  recall_scene = function(scene_num, transition_time)
    table.insert(recalls, { scene = scene_num, time = util.time(),
      interrupts = local_value("scene_transition_active") })
    return real_recall(scene_num, transition_time)
  end
  params:set("scene_transition_time", transition); params:set("scene_duration", duration)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(seconds, 0.001)
  return recalls
end

for _, case in ipairs({ { transition = 20, duration = 16 }, { transition = 16, duration = 16 } }) do
  test(string.format("the scene sequencer lets a %d s transition finish with a %d s scene duration",
    case.transition, case.duration), function()
    local context = load_strata(); context.clock.advance()
    local voices = capture_sequencer_scenes()
    local period = math.max(case.transition, case.duration)
    local recalls = run_scene_sequencer(context, case.transition, case.duration, period + 1)
    assert_equal(#recalls, 2, "scene 2 recalled once scene 1's transition ended")
    assert_equal(recalls[2].scene, 2, "the sequencer moved on to scene 2")
    assert_true(not recalls[2].interrupts, "scene 1's transition was not cut short")
    assert_true(recalls[2].time >= case.transition, "scene 2 recalled after scene 1's transition")
    assert_true(recalls[2].time < period + 0.1, "the sequencer moved on as soon as it ended")
    assert_true(not voices[3].active, "voice 3 waits for the end of scene 2's transition")
    context.clock.run_for(period, 0.001)                   -- scene 2's transition ends
    assert_true(voices[3].active, "voice 3 started at the end of scene 2's transition")
    assert_equal(params:get("v3_grain_mode"), 2, "grain mode switched at the end of the transition")
    assert_equal(#recalls, 3, "then the sequencer moved on to scene 1")
    context.clock.run_for(period, 0.001)                   -- back to scene 1, which ends too
    assert_true(not voices[3].active, "scene 1 stopped voice 3 again")
    for index, recall in ipairs(recalls) do
      assert_true(not recall.interrupts, "recall " .. index .. " cut no transition short")
    end
    assert_equal(params:get("v3_grain_mode"), 1, "scene 1's grain mode")
  end)
end

test("the scene sequencer holds a scene for its duration when the transition is shorter", function()
  local context = load_strata(); context.clock.advance()
  local voices = capture_sequencer_scenes()
  local recalls = run_scene_sequencer(context, 10, 16, 43)
  assert_equal(#recalls, 3, "a recall every 16 s")
  assert_near(recalls[2].time, 16, 0.01, "scene 2 after the scene duration")
  assert_near(recalls[3].time, 32, 0.02, "scene 1 after another scene duration")
  assert_true(not voices[3].active, "scene 1's transition has ended")
end)

test("the scene sequencer moves on when a transition never finishes", function()
  local context = load_strata(); context.clock.advance()
  capture_sequencer_scenes()
  local overrun = local_value("SCENE_TRANSITION").overrun_seconds
  assert_true(type(overrun) == "number" and overrun > 0, "SCENE_TRANSITION.overrun_seconds")
  local recalls = run_scene_sequencer(context, 4, 4, 1)          -- scene 1's 4 s transition is running
  assert_true(local_value("scene_transition_active"), "scene 1's transition is running")
  clock.cancel(local_value("scene_transition_clock"))            -- its clock is lost: the flag stays set
  context.clock.run_for(4 + overrun + 0.5, 0.001)
  assert_equal(#recalls, 2, "the sequencer moved on")
  assert_equal(recalls[2].scene, 2, "to scene 2")
  assert_near(recalls[2].time, 4 + overrun, 0.05, "after the transition time plus the overrun margin")
  assert_true(not recalls[2].interrupts, "the stuck transition was cleared first")
  assert_true(table.concat(context.printed, "\n"):find("scene transition overran", 1, true), "reported")
  context.clock.run_for(4.5, 0.001)
  assert_true(local_value("voices")[3].active, "scene 2's transition ended normally")
end)

test("the scene sequencer waits for a manual transition it did not start, within a bound", function()
  local context = load_strata(); context.clock.advance()
  local voices = capture_sequencer_scenes()
  local overrun = local_value("SCENE_TRANSITION").overrun_seconds
  local recalls = run_scene_sequencer(context, 0, 4, 1)           -- instant recalls every 4 s
  recall_scene(2, 25)                                              -- a manual 25 s transition
  context.clock.run_for(24, 0.001)
  assert_equal(#recalls, 2, "the sequencer waits for the manual transition")
  context.clock.run_for(1.5, 0.001)
  assert_true(voices[3].active, "the manual transition ended and applied scene 2")
  assert_equal(#recalls, 3, "then the sequencer moved on")
  assert_true(not recalls[3].interrupts, "without cutting it short")
  -- a stuck manual transition is cancelled after the longest transition time
  recall_scene(2, 25)
  clock.cancel(local_value("scene_transition_clock"))
  context.clock.run_for(30 + overrun + 4.5, 0.001)
  assert_equal(#recalls, 5, "the sequencer moved on after the bound")
  local _, longest = param_range("scene_transition_time")
  -- timed from the sequencer's wake-up 4 s after its last recall
  assert_near(recalls[5].time, recalls[3].time + 4 + longest + overrun, 0.05,
    "after the longest transition time plus the margin")
  assert_true(not recalls[5].interrupts, "the stuck transition was cleared first")
end)

test("an error inside a scene transition's fade clears the transition flag", function()
  local context = load_strata(); context.clock.advance()
  params:set("v1_freq", 1000); capture_scene(1); params:set("v1_freq", 200)
  params:set_action("v1_freq", function() error("fade failed") end)
  local ok, message = pcall(recall_scene, 1, 4)                  -- the first step runs at once
  assert_true(not ok and tostring(message):find("fade failed", 1, true), "the error is raised")
  assert_equal(local_value("scene_transition_active"), false, "flag cleared")
  assert_equal(local_value("scene_transition_clock"), nil, "clock cleared")
  -- an error in a later step
  params:set_action("v1_freq", function() end)
  recall_scene(1, 4)
  params:set_action("v1_freq", function() error("fade failed") end)
  ok, message = pcall(context.clock.advance)
  assert_true(not ok and tostring(message):find("fade failed", 1, true), "the later error is raised")
  assert_equal(local_value("scene_transition_active"), false, "flag cleared after a later step")
  assert_equal(local_value("scene_transition_clock"), nil, "clock cleared after a later step")
end)

test("a manual recall still interrupts a transition the scene sequencer started", function()
  local context = load_strata(); context.clock.advance()
  local voices = capture_sequencer_scenes()
  local recalls = run_scene_sequencer(context, 20, 16, 25)       -- scene 2's transition is running
  assert_equal(recalls[#recalls].scene, 2, "the sequencer recalled scene 2")
  assert_true(local_value("scene_transition_active"), "scene 2's transition is running")
  recall_scene(2, 0)                                             -- a manual instant recall
  assert_true(not local_value("scene_transition_active"), "the manual recall cancelled the transition")
  assert_true(voices[3].active, "and applied scene 2 at once")
  context.clock.run_for(16, 0.001)                               -- the sequencer keeps going
  assert_equal(local_value("current_scene"), 1, "the sequencer moved on to scene 1")
end)

test("scene recall: one full sync per voice whose source changed, after its params", function()
  -- every engine call since the script loaded, for each running voice, must
  -- leave the engine with the voice's Lua state
  local function assert_engine_has_lua_state(context, where)
    local voices = local_value("voices")
    local master = params:get("master_density")
    for voice_idx = 1, 7 do
      local voice = voices[voice_idx]
      if voice.active then
        local label = where .. ": voice " .. voice_idx .. " "
        local sent = engine_state_for_voice(context.engine_calls, voice_idx - 1)
        for key, value in pairs(voice.params) do
          assert_near(sent.voice[key], value, 1e-9, label .. key)
        end
        assert_near(sent.grain.grainSize, voice.grain.size, 1e-9, label .. "grainSize")
        assert_near(sent.grain.grainDensity, voice.grain.density * master, 1e-9, label .. "grainDensity")
        assert_near(sent.grain.pitchShift, voice.grain.pitch, 1e-9, label .. "pitchShift")
        assert_near(sent.grain.posSpread, voice.grain.spread, 1e-9, label .. "posSpread")
        assert_equal(sent.grain.envShape, voice.grain.env - 1, label .. "envShape")
        assert_equal(sent.grain.grainMode, voice.grain.mode - 1, label .. "grainMode")
        assert_near(sent.grain.bufPos, voice.grain.buf_pos, 1e-9, label .. "bufPos")
        assert_near(sent.grain.bufRate, voice.grain.buf_rate, 1e-9, label .. "bufRate")
        assert_near(sent.grain.bufScan, voice.grain.buf_scan, 1e-9, label .. "bufScan")
        for slot = 1, 3 do
          local slot_state = voice.crossmod["slot" .. slot]
          assert_equal(sent.source[slot], slot_state.source == 0 and -1 or slot_state.source - 1, label .. "mod source " .. slot)
          assert_near(sent.amp_amt[slot], slot_state.amp_amt, 1e-9, label .. "amp mod " .. slot)
          assert_near(sent.freq_amt[slot], slot_state.freq_amt, 1e-9, label .. "freq mod " .. slot)
        end
        assert_near(sent.speed, voice.crossmod.speed, 1e-9, label .. "mod speed")
        local grain_sources = {}
        for _, call in ipairs(context.calls_named("setGrainSource")) do
          if call.args[1] == voice_idx - 1 then table.insert(grain_sources, call.args[2]) end
        end
        assert_equal(grain_sources[#grain_sources], voice.source - 1, label .. "grain source")
      end
    end
  end
  -- a full sync (sync_voice_values_to_engine) ends with the voice's bend.
  -- MIDI pitchbend also sends setVoiceParam "bend", so this test must not
  -- send any pitchbend, or it would count as a sync
  local function full_syncs(context, first_call, engine_voice)
    local count, last_sync, last_call = 0, nil, nil
    for index = first_call, #context.engine_calls do
      local call = context.engine_calls[index]
      if call.args[1] == engine_voice then
        last_call = index
        if call.name == "setVoiceParam" and call.args[2] == "bend" then
          count = count + 1; last_sync = index
        end
      end
    end
    return count, last_sync, last_call
  end

  for _, transition_time in ipairs({ 0, 4 }) do
    local where = transition_time == 0 and "instant recall" or "smooth transition"
    local context = load_strata(); context.clock.advance()
    local voices = local_value("voices")
    for voice_idx = 1, 7 do
      if voices[voice_idx].active ~= (voice_idx <= 3) then toggle_voice(voice_idx) end
    end
    scramble_state(11)
    params:set("v1_source", 1); params:set("v2_source", 3)
    capture_scene(1)                     -- voices 1-3 running, v1 synth, v2 buf 2
    scramble_state(23)
    params:set("v1_source", 4)           -- v1's source differs from the scene's
    params:set("v2_source", 3)           -- v2's is the scene's
    toggle_voice(3); toggle_voice(4)     -- the recall starts voice 3 and stops voice 4

    local first_call = #context.engine_calls + 1
    recall_scene(1, transition_time)
    for _ = 1, 25 do context.clock.advance() end
    assert_equal(local_value("scene_transition_active"), false, where .. " finished")

    local syncs, last_sync, last_call = full_syncs(context, first_call, 0)
    assert_equal(syncs, 1, where .. ": voice 1 (source changed) gets one full sync")
    assert_equal(last_sync, last_call, where .. ": voice 1's full sync comes after its recalled params")
    assert_equal((full_syncs(context, first_call, 1)), 0, where .. ": voice 2 (same source) gets no full sync")
    assert_equal((full_syncs(context, first_call, 2)), 1, where .. ": voice 3 (started) gets toggle_voice's sync only")
    assert_equal((full_syncs(context, first_call, 3)), 0, where .. ": voice 4 (stopped) gets none")
    assert_equal(local_value("scene_recall_in_progress"), false, where .. ": flag cleared")
    assert_engine_has_lua_state(context, where)
  end
end)

test("an error during a scene recall clears scene_recall_in_progress and is raised", function()
  local context = load_strata(); context.clock.advance()   -- voices 1 and 2 running
  local function voice1_full_syncs()
    local bends = 0
    for _, call in ipairs(context.calls_named("setVoiceParam")) do
      if call.args[1] == 0 and call.args[2] == "bend" then bends = bends + 1 end
    end
    return bends
  end
  -- the scene has voice 1 on buffer 2; voice 2's mod speed action fails
  -- after voice 1's source has switched
  params:set("v1_source", 3); params:set("v2_mod_speed", 3); capture_scene(1)
  params:set("v1_source", 1); params:set("v2_mod_speed", 7)
  params:set_action("v2_mod_speed", function() error("mod speed action failed") end)
  context.clear_engine_calls()
  local ok, recall_error = pcall(recall_scene, 1, 0)
  assert_true(not ok, "the error reaches the caller")
  assert_true(tostring(recall_error):find("mod speed action failed", 1, true), "the original error: " .. tostring(recall_error))
  assert_equal(local_value("scene_recall_in_progress"), false, "flag cleared after the error")
  assert_equal(local_value("voices")[1].source, 3, "voice 1's source switched before the error")
  assert_equal(voice1_full_syncs(), 1, "the switched running voice still gets its end-of-recall sync")
  -- the source action syncs a running voice again
  context.clear_engine_calls(); params:set("v1_source", 1)
  assert_equal(voice1_full_syncs(), 1, "a later source switch sends its full sync")
end)

local text_width = stubs.text_width

local function text_span(entry)
  local width = text_width(entry.text)
  if entry.align == "right" then return entry.x - width, entry.x end
  if entry.align == "center" then return entry.x - width / 2, entry.x + width / 2 end
  return entry.x, entry.x + width
end

local PAGE_TITLES = { "MAIN", "FX", "LFO", "BUFFER", "SETUP" }
local HINT_ROW_Y = 62
local TEXT_HEIGHT = 6   -- 04B_03 glyph height plus one row of spacing
-- MAIN: the voice list ends at x 60, left of the divider at 62; the selected
-- voice's details start at x 65
local MAIN_LIST_RIGHT = 60
local MAIN_DETAILS_LEFT = 65

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
    -- between the header and the hint row, MAIN text stays in its column
    if local_value("ui_page") == 1 and entry.y > 8 and entry.y < HINT_ROW_Y then
      assert_true(right <= MAIN_LIST_RIGHT or left >= MAIN_DETAILS_LEFT,
        string.format("'%s' at %d,%d crosses the MAIN divider (%s)", entry.text, entry.x, entry.y, where))
    end
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

test("stub text_width counts UTF-8 characters, not bytes", function()
  assert_equal(text_width("\226\151\143"), text_width("o"), "a three-byte glyph is one character")
  assert_equal(text_width("\226\151\139 ab"), 4 * text_width("o"), "glyph, space and two letters")
end)

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
    params:set("v" .. voice_idx .. "_grain_mode", 2)  -- MAIN shows [TRIG]
    for page = 1, #PAGE_TITLES do
      show_page(page)
      assert_screen_layout(context, PAGE_TITLES[page] .. ", voice " .. voice_idx)
    end
  end
  -- UI.ScrollingList draws row i at y + 5 + (i - 1) * 11; its last row must
  -- end above the hint row
  local voice_list = local_value("voice_list")
  local last_row_y = voice_list.y + 5 + (voice_list.num_visible - 1) * 11
  assert_true(last_row_y <= HINT_ROW_Y - TEXT_HEIGHT,
    "voice list's last row (y " .. last_row_y .. ") clears the hint row")
end)

test("MAIN voice list fits its column for every voice, state and selection (#23)", function()
  local context = load_strata(); context.clock.advance()
  local voices = local_value("voices")
  local frozen = local_value("frozen")
  local _, set_selected = find_upvalue("selected_voice")
  local states = { { active = false, frozen = false }, { active = false, frozen = true },
    { active = true, frozen = false }, { active = true, frozen = true } }
  local entries_by_state = {}
  for state_idx, state in ipairs(states) do
    for voice_idx = 1, 7 do
      if voices[voice_idx].active ~= state.active then toggle_voice(voice_idx) end
      if (frozen[voice_idx] or false) ~= state.frozen then toggle_freeze(voice_idx) end
    end
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      update_voice_list()
      show_page(1)
      local where = string.format("MAIN, voice %d, active %s, frozen %s", voice_idx,
        tostring(state.active), tostring(state.frozen))
      assert_screen_layout(context, where)
      -- the list draws its four rows; the selected voice's entry is bright
      local voice_list = local_value("voice_list")
      local rows_drawn, selected_entry = 0, nil
      for _, entry in ipairs(context.screen.texts) do
        local row = (entry.y - voice_list.y - 5) / 11
        if entry.x == voice_list.x and row >= 0 and row < voice_list.num_visible and row % 1 == 0 then
          rows_drawn = rows_drawn + 1
          if entry.level == 15 then selected_entry = entry.text end
        end
      end
      assert_equal(rows_drawn, voice_list.num_visible, "list rows drawn (" .. where .. ")")
      assert_equal(selected_entry, voice_list.entries[voice_idx], "selected entry bright (" .. where .. ")")
    end
    entries_by_state[state_idx] = local_value("voice_list").entries
  end
  for voice_idx = 1, 7 do
    local stopped, stopped_frozen = entries_by_state[1][voice_idx], entries_by_state[2][voice_idx]
    local running, running_frozen = entries_by_state[3][voice_idx], entries_by_state[4][voice_idx]
    assert_true(stopped ~= running, "running and stopped entries differ: " .. stopped)
    assert_true(not stopped:find("[F]", 1, true) and not running:find("[F]", 1, true), "[F] only when frozen")
    assert_true(stopped_frozen:find("[F]", 1, true) and running_frozen:find("[F]", 1, true),
      "frozen entries show [F]: " .. running_frozen)
    -- every entry is plain ASCII, so its width does not depend on how the
    -- norns font draws other glyphs
    for _, entry in ipairs({ stopped, stopped_frozen, running, running_frozen }) do
      assert_true(not entry:find("[\128-\255]"), "ASCII entry: " .. entry)
    end
  end
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
  -- rings drawn (with at least one segment) on each page: SETUP none
  local expected_rings = { 4, 4, 4, 4, 0 }
  for page = 1, #PAGE_TITLES do
    show_page(page); arc_redraw()
    local drawn = 0
    for ring in pairs(device.segments) do
      assert_true(ring >= 1 and ring <= 4, "ring " .. tostring(ring) .. " exists (" .. PAGE_TITLES[page] .. ")")
      drawn = drawn + 1
    end
    assert_equal(drawn, expected_rings[page], PAGE_TITLES[page] .. " rings drawn")
  end
end)

test("every arc ring lights all 64 LEDs at its maximum, about half at half, none at its minimum", function()
  local context = load_strata(); context.clock.advance()
  local device = context.arc.plug(1)
  local function set_fraction(param_id, fraction)
    local spec = params:lookup_param(param_id).controlspec
    if spec then
      params:set(param_id, spec:map(fraction))
    else
      local minval, maxval = param_range(param_id)
      params:set(param_id, util.linlin(0, 1, minval, maxval, fraction))
    end
  end
  local function lit(ring)
    local count = 0
    for _, level in ipairs(device.segments[ring].leds) do
      if level > 0 then count = count + 1 end
    end
    return count
  end
  local function check(page, ring_params, where)
    show_page(page)
    for ring, param_id in pairs(ring_params) do
      local label = where .. " ring " .. ring .. " (" .. param_id .. ")"
      set_fraction(param_id, 1); arc_redraw()
      assert_equal(lit(ring), 64, label .. " at maximum")
      set_fraction(param_id, 0.5); arc_redraw()
      assert_true(math.abs(lit(ring) - 32) <= 1, label .. " at half lights about 32, got " .. lit(ring))
      set_fraction(param_id, 0); arc_redraw()
      assert_equal(lit(ring), 0, label .. " at minimum")
    end
  end
  local voice = local_value("selected_voice")
  check(1, { "master_density", main_param_id(voice),
             "v" .. voice .. "_grain_size", "v" .. voice .. "_grain_density" }, "MAIN")
  check(2, { "filter_freq", "filter_res", "delay_time", "delay_mix" }, "FX")
  local lfo = {}
  for n = 1, local_value("NUM_LFOS") do lfo[n] = "lfo_depth_" .. n end
  lfo[4] = "lfo_free_" .. local_value("selected_lfo")
  check(3, lfo, "LFO")
  check(4, { "v" .. voice .. "_buf_pos", "v" .. voice .. "_buf_rate", "record_duration", "record_level" }, "BUFFER")
end)

test("MAIN rings 1, 3 and 4 are drawn from the param spec, like the other rings", function()
  local context = load_strata(); context.clock.advance()
  local device = context.arc.plug(1)
  show_page(1)
  local voice = local_value("selected_voice")
  local function lit(ring)
    local count = 0
    for _, level in ipairs(device.segments[ring].leds) do
      if level > 0 then count = count + 1 end
    end
    return count
  end
  local rings = { [1] = "master_density", [3] = "v" .. voice .. "_grain_size", [4] = "v" .. voice .. "_grain_density" }
  for ring, param_id in pairs(rings) do
    local param = params:lookup_param(param_id)
    -- a different range: a ring with its own hardcoded range would not follow
    param.controlspec = controlspec.new(0, 10, "lin", 0.01, 5)
    for _, value in ipairs({0, 2.5, 5, 7.5, 10}) do
      params:set(param_id, value); arc_redraw()
      local expected = param_fraction(param_id) >= 1 and 64 or math.floor(param_fraction(param_id) * 64 + 0.5)
      assert_true(math.abs(lit(ring) - expected) <= 1,
        param_id .. " = " .. value .. " lights " .. expected .. " LEDs, got " .. lit(ring))
    end
  end
end)

test("Strata follows one arc: any port, the first one plugged, removal of that one disconnects", function()
  local function screen_has(context, text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  local function setup_text(context)
    local page = local_value("ui_page")
    show_page(5); redraw()
    local result = screen_has(context, "arc: connected") and "connected" or (screen_has(context, "arc: none") and "none" or "?")
    show_page(page)
    return result
  end
  -- the only arc is on port 2
  local context = load_strata(); context.clock.advance()
  context.arc.plug(2)
  assert_equal(setup_text(context), "connected", "arc on port 2 connects")
  local density = params:lookup_param("master_density")
  local before = density.raw
  context.arc.turn(2, 1, 20)
  assert_near(density.raw - before, 20 / 512, 1e-9, "arc on port 2 works")
  context.arc.unplug(2)
  assert_equal(setup_text(context), "none", "removing it disconnects")

  -- already plugged at start: found on its port
  context = load_strata(); context.clock.advance()
  context.arc.plug(3)
  context.arc.unplug(3)
  context.arc.vports[4].device = {port = 4, segments = {}, all = function() end, refresh = function() end, segment = function() end, led = function() end}
  arc_init()
  assert_true(context.arc.vports[4].delta ~= nil, "init attaches the vport holding a device")

  -- port 2 first, then port 1: Strata stays on 2
  context = load_strata(); context.clock.advance()
  density = params:lookup_param("master_density")
  context.arc.plug(2)
  context.arc.plug(1)
  assert_equal(context.arc.vports[1].delta, nil, "a second arc gets no handler")
  context.arc.unplug(1)
  assert_equal(setup_text(context), "connected", "removing the other arc keeps Strata's")
  before = density.raw
  context.arc.turn(2, 1, 20)
  assert_near(density.raw - before, 20 / 512, 1e-9, "still handled on port 2")
  context.arc.unplug(2)
  assert_equal(setup_text(context), "none", "removing Strata's arc disconnects")

  -- port 1 first, then 2
  context = load_strata(); context.clock.advance()
  context.arc.plug(1)
  context.arc.plug(2)
  assert_equal(context.arc.vports[2].delta, nil, "no handler on the second arc")
  context.arc.unplug(2)
  assert_equal(setup_text(context), "connected", "removing another port's arc keeps Strata's arc")
  context.arc.unplug(1)
  assert_equal(setup_text(context), "none", "removing Strata's arc disconnects it")
end)

test("every continuous arc ring sweeps its param's range in 512 ticks, following the warp", function()
  local context = load_strata(); context.clock.advance()
  context.arc.plug(1)
  local _, set_selected = find_upvalue("selected_voice")
  local function sweep(page, ring, param_id, where)
    show_page(page)
    local spec = params:lookup_param(param_id).controlspec
    -- the param's step quantizes the value; step-0 params land within float error
    local tolerance = spec.step + 1e-6 * (spec.maxval - spec.minval)
    params:set(param_id, spec.minval)
    for _ = 1, 256 do context.arc.turn(1, ring, 1) end
    assert_near(params:get(param_id), spec:map(0.5), tolerance, where .. ": 256 ticks reach the warp's midpoint")
    for _ = 1, 256 do context.arc.turn(1, ring, 1) end
    assert_near(params:get(param_id), spec.maxval, tolerance, where .. ": 512 ticks reach the maximum")
    for _ = 1, 512 do context.arc.turn(1, ring, -1) end
    assert_near(params:get(param_id), spec.minval, tolerance, where .. ": 512 back reach the minimum")
  end
  assert_equal(local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, 512, "half of the arc's 1024 ticks per turn")
  -- MAIN: density, every voice's main param, grain size and density
  sweep(1, 1, "master_density", "MAIN ring 1")
  for voice_idx = 1, 7 do
    set_selected(voice_idx)
    sweep(1, 2, main_param_id(voice_idx), "MAIN ring 2, voice " .. voice_idx)
    sweep(1, 3, "v" .. voice_idx .. "_grain_size", "MAIN ring 3, voice " .. voice_idx)
    sweep(1, 4, "v" .. voice_idx .. "_grain_density", "MAIN ring 4, voice " .. voice_idx)
  end
  set_selected(1)
  params:set("v1_source", 3); sweep(1, 2, "v1_buf_pos", "MAIN ring 2, buffer source")
  params:set("v1_source", 10); sweep(1, 2, "v1_grain_size", "MAIN ring 2, input source")
  params:set("v1_source", 1)
  for ring, param_id in ipairs({ "filter_freq", "filter_res", "delay_time", "delay_mix" }) do
    sweep(2, ring, param_id, "FX ring " .. ring)
  end
  for ring, param_id in ipairs({ "v1_buf_pos", "v1_buf_rate", "record_duration", "record_level" }) do
    sweep(4, ring, param_id, "BUFFER ring " .. ring)
  end
  -- LFO ring 4 in free mode (the selected LFO's period); its depth rings and
  -- clocked rate keep their whole steps (the arc LFO page test)
  sweep(3, 4, "lfo_free_1", "LFO ring 4, free period")
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
    -- arc ring 2 adjusts it and shows it across its controlspec range,
    -- following the warp (param_fraction, as the FX and BUFFER rings)
    set_selected(voice_idx)
    local min_value, max_value = param_range(param_id)
    params:set(param_id, min_value)
    context.arc.turn(1, 2, 100)  -- enough for one step of sub's fine-scaled drift
    local value = params:get(param_id)
    assert_true(value > min_value, "arc ring 2 raises " .. param_id)
    assert_near(device.segments[2].to, param_fraction(param_id) * math.pi * 2, 1e-9, "ring 2 shows " .. param_id)
    -- MAIN shows the label and value in the right column
    redraw()
    local label_found = false
    for _, entry in ipairs(context.screen.texts) do
      if entry.x == 65 and entry.y == 42 and entry.text == key_name then label_found = true end
    end
    assert_true(label_found, "MAIN shows the " .. key_name .. " label")
  end
  -- an exp main param: the resonator's freq at the sweep's midpoint (200 Hz
  -- on 20-2000) is drawn at half a turn, not at its linear 9 %
  set_selected(1)
  params:set("v1_freq", 20)
  for _ = 1, 256 do context.arc.turn(1, 2, 1) end
  assert_near(params:get("v1_freq"), 200, 1e-6, "256 ticks reach the exp midpoint")
  assert_near(device.segments[2].to, math.pi, 1e-6, "ring 2 draws the exp midpoint at half a turn")
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

test("the arc button finds MAIN by its page index, not its title", function()
  local context = load_strata(); context.clock.advance()
  context.arc.plug(1); show_page(1)
  local pages = local_value("UI_PAGES")
  assert_equal(pages.MAIN_PAGE, 1, "MAIN_PAGE is MAIN's index")
  assert_equal(pages[pages.MAIN_PAGE], "MAIN")
  local _, set_selected = find_upvalue("selected_voice"); set_selected(3)
  local voices = local_value("voices")
  assert_true(not voices[3].active, "voice 3 starts stopped")
  local title = pages[1]
  pages[1] = "HOME"   -- a renamed title must not change what the button does
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  pages[1] = title
  assert_true(voices[3].active, "the button starts the selected voice on page 1")
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

  -- compared on the raw 0-1 position: the 0.01 step quantizes the value
  local density = params:lookup_param("master_density")
  context.arc.plug(1)
  local before = density.raw
  context.arc.turn(1, 1, 20)  -- one delta of 20 -> 20/512 of the range
  assert_near(density.raw - before, 20 / 512, 1e-9, "a turn is handled once")
  context.arc.unplug(1)
  context.arc.plug(1)
  before = density.raw
  context.arc.turn(1, 1, 20)
  assert_near(density.raw - before, 20 / 512, 1e-9, "replugged arc handles a turn once")
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
  local voices = local_value("voices")
  local expected_off = {}
  for voice_idx = 1, 7 do
    if voices[voice_idx].active then table.insert(expected_off, voice_idx - 1) end
  end
  assert_true(#expected_off >= 2 and expected_off[1] == 0, "voice 1 and others are running before cleanup")
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
  local voices_off = {}
  for _, call in ipairs(context.calls_named("voiceOff")) do table.insert(voices_off, call.args[1]) end
  assert_equal(table.concat(voices_off, ","), table.concat(expected_off, ","),
    "exactly the running voices are turned off, by 0-based engine index")
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
  local rows = local_value("FX_PAGE").rows
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

test("play/stop columns 1-4 on row 8 all light with the state (256 and 16x8)", function()
  for _, size in ipairs({ { 16, 16 }, { 16, 8 } }) do
    local context = load_strata()
    local device = context.grid.plug(1, size[1], size[2])
    for x = 1, 4 do
      assert_equal(device:get_led(x, 8), 4, size[2] .. " rows: play column " .. x .. " dim when stopped")
    end
    context.grid.press(1, 4, 8, 1)  -- column 4 starts the pattern
    assert_true(local_value("pattern_playing"), "column 4 plays")
    for x = 1, 4 do
      assert_equal(device:get_led(x, 8), 15, size[2] .. " rows: play column " .. x .. " lit while playing")
    end
    context.grid.press(1, 3, 8, 1)  -- column 3 stops it
    for x = 1, 4 do
      assert_equal(device:get_led(x, 8), 4, size[2] .. " rows: play column " .. x .. " dim after stop")
    end
  end
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
  -- rows 1-2 (buffers, columns 1-8) and 9-15 (sources, columns 1-10) are
  -- the buffer controls; the columns past them stay dark
  for x = 1, 16 do
    for _, y in ipairs({ 1, 2 }) do
      if x > 8 then assert_equal(device:get_led(x, y), 0, "row " .. y .. " column " .. x .. " dark on page 4") end
    end
    for y = 9, 15 do
      if x > 10 then assert_equal(device:get_led(x, y), 0, "row " .. y .. " column " .. x .. " dark on page 4") end
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

test("a scene transition redraws the grid once per step on grid page 4", function()
  local context = load_strata(); context.clock.advance()
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 16, 8, 1)              -- page 4: the FX faders
  local fx = { filter_freq = 1000, filter_res = 0.2, filter_mix = 0.6, delay_time = 0.8,
    delay_feedback = 0.7, delay_mix = 0.5 }
  for id, value in pairs(fx) do params:set(id, value) end
  capture_scene(1)
  for id, value in pairs(fx) do params:set(id, value / 2) end
  recall_scene(1, 4)                           -- step 1 runs now
  for step = 2, 20 do
    local refreshes = device.refresh_count
    context.clock.advance()
    assert_equal(device.refresh_count - refreshes, 1, "one grid redraw at step " .. step)
  end
  context.clock.advance()                      -- the end: the instant recall
  assert_near(params:get("filter_freq"), 1000, 1, "transition landed")
  -- outside a transition each FX change still moves the faders at once
  local refreshes = device.refresh_count
  params:set("delay_mix", 0.1)
  assert_equal(device.refresh_count - refreshes, 1, "an FX edit redraws the grid")
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

test("stub clock.run_for resumes sleeps and syncs in wake-time order and moves util.time", function()
  local context = load_strata(); context.clock.advance()
  params:set("clock_tempo", 120)                 -- 0.5 s per beat
  local events = {}
  local function log(name) table.insert(events, string.format("%s@%.3f", name, util.time())) end
  clock.run(function() while true do clock.sleep(0.3); log("short") end end)
  clock.run(function() clock.sleep(1); log("long") end)
  clock.run(function() for _ = 1, 3 do clock.sync(1/4); log("sync") end end)
  local cancelled = clock.run(function() clock.sleep(0.1); log("cancelled") end)
  clock.cancel(cancelled)
  context.clock.run_for(1)
  assert_equal(table.concat(events, " "),
    "sync@0.125 sync@0.250 short@0.300 sync@0.375 short@0.600 short@0.900 long@1.000",
    "wake-time order")
  assert_near(util.time(), 1, 1e-12, "util.time() ends at the start plus the run time")
  -- a scheduling delay on every wake-up: twenty short sleeps fall behind one long one
  events = {}
  clock.run(function() for _ = 1, 20 do clock.sleep(0.5) end; log("steps") end)
  clock.run(function() clock.sleep(10); log("once") end)
  local before = #events
  context.clock.run_for(11, 0.001)
  local order = {}
  for _, event in ipairs(events) do
    local name = event:match("^(%a+)@")
    if name == "steps" or name == "once" then table.insert(order, event) end
  end
  assert_equal(table.concat(order, " "), "once@11.001 steps@11.020", "latency accumulates per sleep")
  assert_true(#events > before, "the clocks ran")
end)

test("stub param type codes come from one table; an unknown type is an error", function()
  load_strata()
  local codes = stubs.PARAM_TYPE_CODES
  assert_true(type(codes) == "table", "the stub exports PARAM_TYPE_CODES")
  local count = 0
  for name, code in pairs(codes) do
    assert_equal(params["t" .. name:upper()], code, "params.t" .. name:upper() .. " from PARAM_TYPE_CODES")
    count = count + 1
  end
  local constants = 0
  for key in pairs(getmetatable(params)) do
    if type(key) == "string" and key:match("^t%u+$") then
      assert_true(codes[key:sub(2):lower()] ~= nil, "params." .. key .. " is in PARAM_TYPE_CODES")
      constants = constants + 1
    end
  end
  assert_equal(constants, count, "one params.tX constant per PARAM_TYPE_CODES entry")
  -- the codes are written down once: no literal tX = <n> outside the table
  local file = assert(io.open(test_dir .. "/norns_stubs.lua", "r")); local source = file:read("*a"); file:close()
  assert_true(not source:find("%f[%w_]t%u+%s*=%s*%d"), "no type code assigned outside PARAM_TYPE_CODES")
  for _, bad_type in ipairs({ "bogus", "taper" }) do
    local ok, message = pcall(function() params:add { id = "stub_" .. bad_type, type = bad_type } end)
    assert_true(not ok, "params:add with type " .. bad_type .. " raises an error")
    assert_true(tostring(message):find(bad_type, 1, true), "the error names the type " .. bad_type)
    assert_equal(params.lookup["stub_" .. bad_type], nil, "nothing registered for type " .. bad_type)
  end
  assert_true(not pcall(function() params:add { id = "stub_untyped" } end), "params:add without a type raises an error")
end)

-- The first place source compares a param type (x.t) with a string literal,
-- either way round and with either quote, or nil
local function param_type_string_comparison(source)
  local patterns = {
    "[%w_%]%)]%.t%s*[=~]=%s*[\"']",            -- p.t == "option"
    "[\"']%s*[=~]=%s*[%w_%.:%(%)%[%]]-%.t%f[^%w_]", -- "option" == p.t
  }
  for _, pattern in ipairs(patterns) do
    local start, finish = source:find(pattern)
    if start then return source:sub(start, finish) end
  end
  return nil
end

test("strata.lua never compares a param type with a string", function()
  -- the check catches both quotes and both orders, and nothing else
  local caught = { 'if p.t == "option" then', "if p.t == 'option' then", 'if param.t ~= "number" then',
    'if "option" == p.t then', "if 'control' ~= params:lookup_param(id).t then", 'x = ("trigger" == p.t)' }
  for _, line in ipairs(caught) do
    assert_true(param_type_string_comparison(line), "caught: " .. line)
  end
  local allowed = { "if p.t == params.tOPTION then", 'if p.text == "option" then', 'if "option" == p.text then',
    'if p.type == "option" then', 'local s = "a.t == b"', "if params.tOPTION == p.t then" }
  for _, line in ipairs(allowed) do
    assert_equal(param_type_string_comparison(line), nil, "allowed: " .. line)
  end
  local file = assert(io.open(LUA_PATH, "r")); local source = file:read("*a"); file:close()
  local found = param_type_string_comparison(source)
  assert_equal(found, nil, "param.t is numeric on norns; compare with params.tX")
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
  -- port 3: Strata listens to port 1 (midi_device) and re-attaches it on midi.add
  local vport = midi.connect(3)
  local seen = {}
  vport.event = function(data) table.insert(seen, midi.to_msg(data)) end
  context.midi.send(3, { type = "note_on", note = 60, vel = 100, ch = 3 })
  context.midi.send(3, { type = "cc", cc = 1, val = 64, ch = 1 })
  context.midi.send(3, { type = "pitchbend", val = 8192 + 4096, ch = 1 })
  context.midi.send(3, { type = "note_on", note = 61, vel = 0, ch = 2 })
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

test("MIDI notes set pitch per source, start or retrigger the voice with velocity", function()
  local context = load_strata(); context.clock.advance()
  context.midi.send(1, { type = "note_on", note = 69, vel = 127, ch = 3 })   -- voice 3, off
  assert_near(params:get("v3_freq"), 440, 0.01); assert_true(local_value("voices")[3].active)
  local rt = context.calls_named("retrigger"); assert_equal(rt[#rt].args[1], 2); assert_near(rt[#rt].args[2], 1, 1e-9)
  params:set("v1_source", 2)
  context.midi.send(1, { type = "note_on", note = 72, vel = 64, ch = 1 })
  assert_near(params:get("v1_buf_rate"), 2, 1e-6); rt = context.calls_named("retrigger"); assert_near(rt[#rt].args[2], 64 / 127, 1e-9)
  params:set("v2_source", 10); context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 2 })  -- input source: no error
  context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 9 })  -- no voice: ignored
  params:set("v1_source", 1); params:set("midi_channel_mode", 2)        -- omni -> selected voice (1, synth again)
  context.midi.send(1, { type = "note_on", note = 57, vel = 100, ch = 9 })
  assert_near(params:get("v1_freq"), 220, 0.01)
end)

test("MIDI note details: start order, exact pitch, clamping, ignored channels", function()
  local context = load_strata(); context.clock.advance()
  local voices = local_value("voices")
  -- a stopped voice is started (voiceOn) before the retrigger
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 61, vel = 100, ch = 4 })
  local names = {}
  for _, call in ipairs(context.engine_calls) do table.insert(names, call.name) end
  local voice_on_at, retrigger_at
  for index, name in ipairs(names) do
    if name == "voiceOn" then voice_on_at = voice_on_at or index end
    if name == "retrigger" then retrigger_at = index end
  end
  assert_true(voice_on_at and retrigger_at and voice_on_at < retrigger_at, "voiceOn, then retrigger")
  assert_true(voices[4].active, "note on starts voice 4")
  -- equal temperament is not rounded to whole hertz
  assert_near(params:get("v4_freq"), 13.75 * 2 ^ ((61 - 9) / 12), 0.01, "note 61 = 277.18 Hz")
  -- a running voice is only retriggered (no second voiceOn)
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 62, vel = 50, ch = 4 })
  assert_equal(#context.calls_named("voiceOn"), 0, "running voice: no voiceOn")
  assert_equal(#context.calls_named("retrigger"), 1, "running voice: one retrigger")
  -- pitch is clamped to the voice's range
  context.midi.send(1, { type = "note_on", note = 127, vel = 100, ch = 4 })
  assert_near(params:get("v4_freq"), select(2, param_range("v4_freq")), 1e-9, "high notes clamp to the freq maximum")
  context.midi.send(1, { type = "note_on", note = 0, vel = 100, ch = 4 })
  assert_near(params:get("v4_freq"), (param_range("v4_freq")), 1e-9, "low notes clamp to the freq minimum")
  params:set("v5_source", 3)
  context.midi.send(1, { type = "note_on", note = 120, vel = 100, ch = 5 })
  assert_near(params:get("v5_buf_rate"), 4, 1e-9, "buffer rate clamps to 4")
  context.midi.send(1, { type = "note_on", note = 0, vel = 100, ch = 5 })
  assert_near(params:get("v5_buf_rate"), 0.25, 1e-9, "buffer rate clamps to 0.25")
  -- an input-sourced voice takes no pitch but still starts and accents
  params:set("v6_source", 10)
  local freq_before, rate_before = params:get("v6_freq"), params:get("v6_buf_rate")
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 90, vel = 127, ch = 6 })
  assert_equal(params:get("v6_freq"), freq_before); assert_equal(params:get("v6_buf_rate"), rate_before)
  assert_true(voices[6].active and #context.calls_named("retrigger") == 1, "input voice started and accented")
  -- per voice: channels 8-16 address no voice; other message types are ignored
  context.clear_engine_calls()
  for channel = 8, 16 do context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = channel }) end
  context.midi.send(1, { type = "cc", cc = 1, val = 64, ch = 1 })
  context.midi.send(1, { type = "program_change", val = 3, ch = 1 })
  context.midi.send(1, { type = "clock" })
  assert_equal(#context.engine_calls, 0, "nothing reaches the engine")
end)

test("note off mode and pitchbend", function()
  local context = load_strata(); context.clock.advance()
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 }); assert_true(local_value("voices")[1].active)
  params:set("midi_note_off", 2); context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 })
  assert_true(not local_value("voices")[1].active)
  context.midi.send(1, { type = "pitchbend", val = 8192 + 8191, ch = 2 })
  local calls = context.calls_named("setVoiceParam"); local last = calls[#calls]
  assert_equal(last.args[2], "bend"); assert_near(last.args[3], 2 ^ (2 / 12), 1e-3)
end)

test("voice off mode: the voice stops when its last held note is released", function()
  local context = load_strata(); context.clock.advance()
  local voices = local_value("voices")
  params:set("midi_note_off", 2)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  context.midi.send(1, { type = "note_on", note = 64, vel = 100, ch = 3 })
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 3 })
  assert_true(voices[3].active, "another note is still held")
  context.midi.send(1, { type = "note_on", note = 64, vel = 0, ch = 3 })   -- velocity 0 = note off
  assert_true(not voices[3].active, "last note released: voice off")
  -- a note during the release starts the voice again through voiceOn (the
  -- engine re-gates the releasing synths)
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 67, vel = 90, ch = 3 })
  assert_true(voices[3].active); assert_equal(#context.calls_named("voiceOn"), 1)
  -- omni: a note off reaches the voice its note on started, even if the selection moved
  params:set("midi_channel_mode", 2)
  context.midi.send(1, { type = "note_on", note = 48, vel = 100, ch = 1 })   -- selected voice 1
  local _, set_selected = find_upvalue("selected_voice"); set_selected(5)
  context.midi.send(1, { type = "note_off", note = 48, vel = 0, ch = 1 })
  assert_true(not voices[1].active, "voice 1 stops on its note's release")
  assert_true(not voices[5].active, "the newly selected voice is untouched")
  -- ignore mode leaves voices running
  params:set("midi_note_off", 1)
  context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 1 })
  context.midi.send(1, { type = "note_off", note = 50, vel = 0, ch = 1 })
  assert_true(voices[5].active, "ignore: note off does nothing")
end)

test("a MIDI-held voice stopped another way: its note off changes nothing and leaves nothing held", function()
  local context = load_strata(); context.clock.advance()
  local voices = local_value("voices")
  local midi_state = local_value("midi_state")
  context.grid.plug(1, 16, 16)
  params:set("midi_note_off", 2)
  for voice_idx = 1, 7 do
    if voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  capture_scene(1)   -- every voice off
  local function assert_nothing_held(voice_idx, channel, note, where)
    assert_equal(next(midi_state.held[voice_idx]), nil, where .. ": no note held on voice " .. voice_idx)
    local channel_notes = midi_state.note_voice[channel]
    assert_equal(channel_notes and channel_notes[note], nil, where .. ": note " .. note .. " not mapped")
  end
  -- K3 (and the arc button) never stop a running voice: on a held voice K3
  -- freezes it, and the note off then stops it as voice off mode says
  local _, set_selected = find_upvalue("selected_voice"); set_selected(2)
  show_page(1)
  context.midi.send(1, { type = "note_on", note = 62, vel = 100, ch = 2 })
  key(3, 1); key(3, 0)
  assert_true(voices[2].active and local_value("frozen")[2], "K3 freezes the held voice, it does not stop it")
  context.midi.send(1, { type = "note_off", note = 62, vel = 0, ch = 2 })
  assert_true(not voices[2].active, "K3: the note off stops the frozen voice")
  assert_nothing_held(2, 2, 62, "K3")
  toggle_freeze(2)
  local stoppers = {
    { name = "grid voice toggle", voice = 4, stop = function() context.grid.press(1, 8 + 4, 14, 1) end },
    { name = "scene recall", voice = 6, stop = function() recall_scene(1, 0) end },
  }
  for _, stopper in ipairs(stoppers) do
    local voice_idx = stopper.voice
    context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = voice_idx })
    assert_true(voices[voice_idx].active, stopper.name .. ": the note started the voice")
    assert_true(midi_state.held[voice_idx][60], stopper.name .. ": note 60 held")
    stopper.stop()
    assert_true(not voices[voice_idx].active, stopper.name .. ": the voice stopped")
    context.clear_engine_calls()
    local frozen = deep_copy(local_value("frozen"))
    context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = voice_idx })
    assert_equal(#context.engine_calls, 0, stopper.name .. ": the note off sends nothing")
    for other = 1, 7 do
      assert_true(not voices[other].active, stopper.name .. ": voice " .. other .. " still off")
      assert_equal(local_value("frozen")[other], frozen[other], stopper.name .. ": voice " .. other .. " freeze unchanged")
    end
    assert_nothing_held(voice_idx, voice_idx, 60, stopper.name)
  end
end)

test("pitchbend: range, buffer voices, stopped voices, restarts and resets", function()
  local context = load_strata(); context.clock.advance()
  local function last_bend(engine_voice)
    local value
    for _, call in ipairs(context.calls_named("setVoiceParam")) do
      if call.args[1] == engine_voice and call.args[2] == "bend" then value = call.args[3] end
    end
    return value
  end
  context.midi.send(1, { type = "pitchbend", val = 0, ch = 1 })
  assert_near(last_bend(0), 2 ^ (-2 / 12), 1e-9, "full down = -2 semitones")
  context.midi.send(1, { type = "pitchbend", val = 8192, ch = 1 })
  assert_near(last_bend(0), 1, 1e-12, "centre = 1")
  -- a buffer-sourced voice gets the same voice-level bend (the engine passes it to strataGrainBuf)
  params:set("v2_source", 4)
  context.clear_engine_calls()
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 2 })
  assert_near(last_bend(1), 2 ^ (1 / 12), 1e-9, "buffer voice bend")
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    assert_true(call.args[2] ~= "bend", "bend is not a grain param")
  end
  -- bend is transient: not a param and not in scenes
  assert_equal(params.lookup["v2_bend"], nil, "no bend param")
  capture_scene(1)
  assert_equal(local_value("scenes")[1].data.voices[2].params.bend, nil, "scenes do not capture bend")
  -- a stopped voice remembers the wheel and gets it when it starts
  context.clear_engine_calls()
  context.midi.send(1, { type = "pitchbend", val = 8192 - 4096, ch = 4 })
  assert_equal(last_bend(3), nil, "stopped voice: nothing sent")
  toggle_voice(4)
  assert_near(last_bend(3), 2 ^ (-1 / 12), 1e-9, "starting the voice sends the held bend")
  -- changing the channel mode re-centres every bent voice
  context.clear_engine_calls()
  params:set("midi_channel_mode", 2)
  assert_near(last_bend(1), 1, 1e-12, "voice 2 re-centred"); assert_near(last_bend(3), 1, 1e-12, "voice 4 re-centred")
  assert_equal(last_bend(0), nil, "an unbent voice gets nothing")
end)

test("omni pitchbend follows the selection: the old voice re-centres, the new one takes the wheel", function()
  local context = load_strata(); context.clock.advance()
  local bend = local_value("midi_state").bend
  local function last_bend(engine_voice)
    local value
    for _, call in ipairs(context.calls_named("setVoiceParam")) do
      if call.args[1] == engine_voice and call.args[2] == "bend" then value = call.args[3] end
    end
    return value
  end
  local up = 2 ^ (1 / 12)
  params:set("midi_channel_mode", 2); show_page(1)
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 1 })   -- bends voice 1
  context.clear_engine_calls()
  enc(2, 1)   -- voice 2, wheel still up
  assert_near(last_bend(0), 1, 1e-12, "voice 1 re-centred"); assert_equal(bend[1], 1)
  assert_near(last_bend(1), up, 1e-9, "voice 2 takes the wheel"); assert_near(bend[2], up, 1e-9)
  -- a stopped voice keeps the wheel for its start
  context.clear_engine_calls()
  enc(2, 1)   -- voice 3 (stopped)
  assert_near(last_bend(1), 1, 1e-12, "voice 2 re-centred")
  assert_equal(last_bend(2), nil, "nothing sent to a stopped voice"); assert_near(bend[3], up, 1e-9)
  toggle_voice(3); assert_near(last_bend(2), up, 1e-9, "starting it sends the wheel")
  -- BUFFER page E2 is the same selection
  show_page(4); context.clear_engine_calls()
  enc(2, -1)
  assert_near(last_bend(2), 1, 1e-12, "voice 3 re-centred"); assert_near(last_bend(1), up, 1e-9, "voice 2 bent again")
  -- E2 against the end of the list changes nothing
  show_page(1); enc(2, -1)   -- voice 1
  context.clear_engine_calls(); enc(2, -1)
  assert_equal(#context.calls_named("setVoiceParam"), 0, "no selection change, no bend")
  -- wheel centred: moving the selection sends nothing
  context.midi.send(1, { type = "pitchbend", val = 8192, ch = 1 })
  context.clear_engine_calls(); enc(2, 1)
  assert_equal(#context.calls_named("setVoiceParam"), 0, "a centred wheel moves nothing")
  -- per voice: bends stay with their channels' voices
  params:set("midi_channel_mode", 1)
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 1 })
  context.clear_engine_calls(); enc(2, 1)
  assert_equal(#context.calls_named("setVoiceParam"), 0, "per voice mode: the selection does not move bends")
  assert_near(bend[1], up, 1e-9)
end)

test("MIDI device param, hot-plug and the SETUP page", function()
  local context = load_strata(); context.clock.advance()
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  assert_equal(params:get("midi_device"), 1); assert_equal(params:get("midi_channel_mode"), 1)
  assert_equal(params:get("midi_note_off"), 1)
  assert_equal(params:string("midi_channel_mode"), "per voice")
  show_page(5)
  assert_true(screen_has("midi 1: none"), "no device on port 1")
  assert_true(screen_has("ch: per voice"), "channel mode shown")
  context.midi.plug(1, "keys")
  assert_true(screen_has("midi 1: keys"), "plugging a device redraws SETUP")
  -- E2 selects the port; events on the old port no longer reach Strata
  enc(2, 1); assert_equal(params:get("midi_device"), 2)
  assert_true(screen_has("midi 2: none"))
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_equal(#context.engine_calls, 0, "port 1 is no longer listened to")
  context.midi.send(2, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_true(#context.calls_named("retrigger") == 1, "port 2 is")
  -- E3 sets the channel mode
  enc(3, 1); assert_equal(params:get("midi_channel_mode"), 2)
  assert_true(screen_has("ch: omni to selected"))
  -- unplugging the selected port's device shows none at once
  context.midi.unplug(2)
  assert_true(screen_has("midi 2: none"), "unplugging redraws SETUP without the device")
  -- a long device name is cut to fit the screen
  context.midi.plug(2, "Very Long Manufacturer Name USB MIDI Interface Port 1")
  local midi_line
  for _, entry in ipairs(context.screen.texts) do
    if entry.text:find("^midi 2: ") then midi_line = entry.text end
  end
  assert_true(midi_line and #midi_line < #"midi 2: Very Long Manufacturer Name USB MIDI Interface Port 1", "name shortened")
  assert_screen_layout(context, "SETUP with a long MIDI device name")
  assert_true(params:get("midi_device") <= 4 and select(2, param_range("midi_device")) == 4, "ports 1-4")
  -- a re-plug reattaches: the vport still delivers to Strata
  context.clear_engine_calls()
  context.midi.send(2, { type = "note_on", note = 62, vel = 100, ch = 1 })
  assert_equal(#context.calls_named("retrigger"), 1, "re-plugged device plays")
  cleanup()
  assert_equal(midi.connect(2).event, nil, "cleanup detaches the MIDI handler")
end)

test("stub fileselect, musicutil, polls and audio path", function()
  local context = load_strata()
  local picked
  assert_equal(rawget(_G, "fileselect"), nil, "fileselect is a module, not a global")
  local fileselect = require("fileselect")
  assert_equal(fileselect, context.fileselect)
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
-- audio sources and buffers
---------------------------------------------------------------------------

test("source switching syncs through setGrainSource and swaps the main param", function()
  local context = load_strata(); context.clock.advance()
  context.clear_engine_calls(); params:set("v1_source", 4)      -- buf 3
  local calls = context.calls_named("setGrainSource")
  assert_equal(#calls, 1, "one setGrainSource per switch")
  assert_equal(calls[1].args[1], 0); assert_equal(calls[1].args[2], 3)
  assert_equal(main_param_id(1), "v1_buf_pos"); assert_equal(main_param_label(1), "pos")
  params:set("v1_source", 10); calls = context.calls_named("setGrainSource"); assert_equal(calls[#calls].args[2], 9)
  assert_equal(main_param_id(1), "v1_grain_size", "input source shows grain size (controller ruling: its buffer params are dead too)")
  params:set("v1_source", 1); assert_equal(main_param_id(1), "v1_freq")
  -- a stopped voice's source is sent at once (R11) and nothing else is
  context.clear_engine_calls(); params:set("v3_source", 5)
  assert_equal(#context.engine_calls, 1, "stopped voice: only the source is sent")
  assert_equal(context.engine_calls[1].name, "setGrainSource")
  assert_equal(context.engine_calls[1].args[1], 2); assert_equal(context.engine_calls[1].args[2], 4)
  toggle_voice(3); params:set("v3_source", 2); toggle_voice(3)          -- on, edit, off
  context.clear_engine_calls(); toggle_voice(3)                          -- on again: synced
  local sent = engine_state_for_voice(context.engine_calls, 2)
  assert_equal(context.calls_named("setGrainSource")[1].args[2], 1, "started voice sends its source")
  assert_equal(sent.grain.bufPos, 0); assert_equal(sent.grain.bufRate, 1); assert_equal(sent.grain.bufScan, 0)
  -- a running voice's switch resends the rest of its state after the source
  context.clear_engine_calls(); params:set("v3_source", 10)
  assert_equal(context.engine_calls[1].name, "setGrainSource")
  assert_equal(#context.calls_named("setGrainSource"), 1, "no second setGrainSource")
  assert_true(#context.calls_named("setVoiceParam") > 0, "running voice: voice state resent")
  assert_equal(engine_state_for_voice(context.engine_calls, 2).grain.bufPos, 0, "grain state resent")
  assert_equal(#context.calls_named("voiceOn"), 0, "switching creates no voice")
end)

test("source and buffer params: options, defaults, voices table, labels", function()
  load_strata()
  local voices = local_value("voices")
  local names = {}
  for index = 1, 10 do params:set("v1_source", index); names[index] = params:string("v1_source") end
  assert_equal(table.concat(names, ","), "synth,buf 1,buf 2,buf 3,buf 4,buf 5,buf 6,buf 7,buf 8,input")
  params:set("v1_source", 1)
  local expected = { buf_pos = 0, buf_rate = 1, buf_scan = 0 }
  for voice_idx = 1, 7 do
    local prefix = "v" .. voice_idx .. "_"
    local source = params:lookup_param(prefix .. "source")
    assert_equal(source.t, params.tOPTION, "source is an option")
    assert_equal(source.count, 10, "synth, eight buffers, input")
    assert_equal(params:get(prefix .. "source"), 1, "default synth")
    assert_equal(voices[voice_idx].source, 1, "voices table holds the source index")
    for key, default in pairs(expected) do
      assert_near(params:get(prefix .. key), default, 1e-9, prefix .. key .. " default")
      assert_near(voices[voice_idx].grain[key], default, 1e-9, "voices[" .. voice_idx .. "].grain." .. key)
      assert_equal(local_value("GRAIN_PARAM_IDS")[key], key, key .. " in GRAIN_PARAM_IDS")
    end
  end
  assert_equal(param_range("v1_buf_pos"), 0); assert_equal(select(2, param_range("v1_buf_pos")), 1)
  assert_equal(param_range("v1_buf_rate"), 0.25); assert_equal(select(2, param_range("v1_buf_rate")), 4)
  assert_equal(param_range("v1_buf_scan"), -2); assert_equal(select(2, param_range("v1_buf_scan")), 2)
  assert_equal(params:lookup_param("v1_buf_rate").controlspec.warp_name, "exp", "buf rate is exponential")
  params:set("v2_buf_rate", 2); assert_near(voices[2].grain.buf_rate, 2, 1e-9)
  params:set("v2_buf_scan", -1); assert_near(voices[2].grain.buf_scan, -1, 1e-9)
  params:set("v2_buf_pos", 0.123); assert_near(voices[2].grain.buf_pos, 0.123, 1e-9, "buf_pos is not quantized")
  assert_true(not voice_uses_buffer(2), "synth source is not a buffer")
  assert_equal(voice_source_label(2), "synth")
  params:set("v2_source", 9); assert_true(voice_uses_buffer(2)); assert_equal(voice_source_label(2), "buf 8")
  params:set("v2_source", 10); assert_true(not voice_uses_buffer(2), "input is not a buffer")
  assert_equal(voice_source_label(2), "input")
  -- every per-voice scene default equals its param default
  local found = {}
  for _, field in ipairs(local_value("VOICE_SCENE_DEFAULTS")) do
    local suffix = field.path[1] == "grain" and local_value("GRAIN_PARAM_IDS")[field.path[2]] or field.path[1]
    found[suffix] = true
    local param = params:lookup_param("v1_" .. suffix)
    local param_default = param.controlspec and param.controlspec.default or param.default
    assert_equal(field.default, param_default, suffix .. " scene default")
  end
  for _, suffix in ipairs({ "source", "buf_pos", "buf_rate", "buf_scan" }) do
    assert_true(found[suffix], suffix .. " has a scene default")
  end
end)

test("buffer-sourced voices: E3, arc ring 2 and MAIN use buf_pos", function()
  local context = load_strata(); context.clock.advance()
  local device = context.arc.plug(1)
  params:set("v1_source", 3)
  params:set("v1_buf_pos", 0.5)
  local freq = params:get("v1_freq")
  enc(3, 2)
  assert_near(params:get("v1_buf_pos"), 0.52, 1e-6, "E3 moves buf_pos")
  assert_equal(params:get("v1_freq"), freq, "E3 leaves the synth freq alone")
  context.arc.turn(1, 2, 10)
  assert_true(params:get("v1_buf_pos") > 0.52, "arc ring 2 moves buf_pos")
  assert_equal(params:get("v1_freq"), freq, "arc ring 2 leaves the synth freq alone")
  assert_near(device.segments[2].to, params:get("v1_buf_pos") * math.pi * 2, 1e-9, "ring 2 shows buf_pos")
  redraw()
  local label, value
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 65 and entry.y == 42 then label = entry.text end
    if entry.x == 65 and entry.y == 50 then value = entry.text end
  end
  assert_equal(label, "pos", "MAIN label")
  assert_equal(value, string.format("%.2f", params:get("v1_buf_pos")), "MAIN value")
end)

test("randomize and mutate touch buffer params, never source", function()
  local context = load_strata(); context.clock.advance()
  params:set("v1_source", 2); local freq = params:get("v1_freq")
  local synth_before = deep_copy(local_value("voices")[1].params)
  math.randomseed(7); randomize_voice(1)
  assert_equal(params:get("v1_freq"), freq, "synth params untouched for a buffer voice")
  assert_true(params:get("v1_buf_rate") ~= 1 or params:get("v1_buf_pos") ~= 0, "buffer params randomized")
  for _ = 1, 20 do
    randomize_voice(1)
    assert_true(params:get("v1_buf_rate") >= 0.5 - 1e-9 and params:get("v1_buf_rate") <= 2 + 1e-9, "rate 0.5-2")
    assert_true(math.abs(params:get("v1_buf_scan")) <= 0.5 + 1e-9, "scan -0.5..0.5")
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  local pos_before = params:get("v1_buf_pos")
  gentle_mutate()
  assert_equal(params:get("v1_source"), 2)
  assert_true(params:get("v1_buf_pos") ~= pos_before, "mutation moves buf_pos")
  for key, value in pairs(synth_before) do
    assert_equal(local_value("voices")[1].params[key], value, "mutation leaves synth " .. key .. " alone")
  end
  -- synth-sourced voices keep mutating synth params, never the source
  params:set("v1_source", 1); local mutated = false
  for _ = 1, 5 do gentle_mutate(); if params:get("v1_freq") ~= freq then mutated = true end end
  assert_true(mutated, "synth source mutates synth params again")
  for _ = 1, 20 do randomize_voice(1); gentle_mutate() end
  assert_equal(params:get("v1_source"), 1, "source never randomized or mutated")
  -- freeze covers buffer params
  params:set("v1_source", 5); toggle_freeze(1)
  local frozen_state = deep_copy(local_value("voices")[1].grain)
  randomize_voice(1); gentle_mutate(); for _ = 1, 10 do drift_update() end
  for key, value in pairs(frozen_state) do
    assert_equal(local_value("voices")[1].grain[key], value, "frozen buffer voice keeps " .. key)
  end
end)

test("randomize and mutation work in normalized space for exponential params", function()
  local context = load_strata(); context.clock.advance()   -- voice 1 (synth source) running
  local spec = params:lookup_param("v1_freq").controlspec
  assert_true(spec.minval == 20 and spec.maxval == 2000 and spec.warp_name == "exp",
    "voice 1 freq is the 20-2000 Hz exponential spec this test covers")
  local midpoint = math.sqrt(spec.minval * spec.maxval)
  math.randomseed(11)
  local below, draws = 0, 2000
  for _ = 1, draws do
    randomize_voice(1)
    if params:get("v1_freq") < midpoint then below = below + 1 end
  end
  local share = below / draws
  assert_true(share > 0.35 and share < 0.65,
    "freq randomize (20-2000 Hz exp) lands below the geometric midpoint about half the time (" .. share .. ")")
  -- a mutation step moves freq by at most amount in normalized distance
  params:set("mutation_probability", 1); params:set("mutation_amount", 0.25)
  local max_step = 0
  for _ = 1, 300 do
    params:set("v1_freq", spec:map(math.random()))
    local before = spec:unmap(params:get("v1_freq"))
    gentle_mutate()
    max_step = math.max(max_step, math.abs(spec:unmap(params:get("v1_freq")) - before))
  end
  assert_true(max_step <= 0.25 + 1e-6, "normalized mutation step within amount (" .. max_step .. ")")
  assert_true(max_step > 0.05, "mutation actually moves freq (" .. max_step .. ")")
end)

test("gentle_mutate skips every grain key in DISCRETE_GRAIN_KEYS", function()
  local context = load_strata(); context.clock.advance()   -- voice 1 running
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  params:set("v1_grain_env", 3); params:set("v1_grain_mode", 2)
  math.randomseed(13)
  for _ = 1, 50 do gentle_mutate() end
  assert_equal(params:get("v1_grain_env"), 3, "envelope shape never mutates")
  assert_equal(params:get("v1_grain_mode"), 2, "grain mode never mutates")
  -- the guard is the table: any grain key marked discrete is left alone
  local discrete = local_value("DISCRETE_GRAIN_KEYS")
  for _, key in ipairs({ "size", "pitch", "spread", "buf_pos", "buf_rate", "buf_scan" }) do discrete[key] = 1 end
  for _, source in ipairs({ 1, 2, 10 }) do   -- synth, buffer, input
    params:set("v1_source", source)
    local before = deep_copy(local_value("voices")[1].grain)
    for _ = 1, 20 do gentle_mutate() end
    for key, value in pairs(before) do
      assert_equal(local_value("voices")[1].grain[key], value, "source " .. source .. ": grain " .. key .. " skipped")
    end
  end
end)

test("buffer position drifts subtly and reverts to the user-set position", function()
  local context = load_strata(); context.clock.advance()   -- voice 1 running
  assert_true(local_value("voices")[1].active, "voice 1 on")
  params:set("v1_source", 2); params:set("v1_buf_pos", 0.4)
  local synth_freq = params:get("v1_freq")
  math.randomseed(3)
  local max_offset = 0
  for _ = 1, 3000 do
    drift_update()
    max_offset = math.max(max_offset, math.abs(params:get("v1_buf_pos") - 0.4))
  end
  assert_true(max_offset > 0, "buf_pos drifts")
  assert_true(max_offset < 0.05, "drift stays subtle (max " .. max_offset .. ")")
  assert_equal(params:get("v1_freq"), synth_freq, "drift leaves synth params alone")
  params:set("v1_buf_pos", 0.8)
  for _ = 1, 3000 do drift_update() end
  assert_true(math.abs(params:get("v1_buf_pos") - 0.8) < 0.05, "a new user position becomes the centre")
  -- a synth-sourced voice's position does not drift
  params:set("v1_source", 1); local pos = params:get("v1_buf_pos")
  for _ = 1, 100 do drift_update() end
  assert_equal(params:get("v1_buf_pos"), pos, "synth source: no position drift")
end)

test("mean_reverting_step: one random step plus a pull toward the base, used by both drifts", function()
  local context = load_strata(); context.clock.advance()   -- voice 1 running
  math.randomseed(5); local random = math.random()
  math.randomseed(5)
  assert_near(mean_reverting_step(1.2, 1.0, 0.004, 0.01), 1.2 + (random - 0.5) * 0.004 - 0.2 * 0.01, 1e-12,
    "current + (random - 0.5) * step - (current - base) * reversion")
  -- drift_update's grain pitch and buffer position steps are exactly that
  params:set("v1_source", 2); params:set("v1_grain_pitch", 1.5); params:set("v1_buf_pos", 0.4)
  for _ = 1, 50 do drift_update() end
  local pitch, position = params:get("v1_grain_pitch"), params:get("v1_buf_pos")
  math.randomseed(9); local pitch_random = math.random(); local position_random = math.random()
  math.randomseed(9); drift_update()
  assert_near(params:get("v1_grain_pitch"), pitch + (pitch_random - 0.5) * 0.004 - (pitch - 1.5) * 0.01, 1e-12,
    "grain pitch drift step")
  assert_near(params:get("v1_buf_pos"), position + (position_random - 0.5) * 0.002 - (position - 0.4) * 0.01, 1e-12,
    "buffer position drift step")
end)

test("transition skips discrete voice fields; scenes keep source and buffer params", function()
  local context = load_strata(); context.clock.advance()
  params:set("v2_source", 3); params:set("v2_buf_pos", 0.7); capture_scene(1)
  assert_equal(local_value("scenes")[1].data.voices[2].source, 3, "source captured")
  params:set("v2_source", 1); params:set("v2_buf_pos", 0.1)
  recall_scene(1, 4); context.clock.advance()
  assert_equal(params:get("v2_source"), 1, "source only changes at the end of a transition")
  assert_true(params:get("v2_buf_pos") > 0.1, "buf_pos interpolates")
  for _, target in ipairs(scene_transition_targets(local_value("scenes")[1].data)) do
    assert_true(not target.id:find("_source$"), target.id .. " is not crossfaded")
  end
  for _ = 1, 25 do context.clock.advance() end
  assert_equal(params:get("v2_source"), 3); assert_near(params:get("v2_buf_pos"), 0.7, 1e-6)
  -- validation and migration of the source field
  local scene = deep_copy(local_value("scenes")[1])
  assert_true(validate_scene(scene), "captured scene validates")
  for _, bad in ipairs({ 0, 11, 2.5, "buf 1" }) do
    scene.data.voices[2].source = bad
    assert_true(not validate_scene(scene), "source " .. tostring(bad) .. " rejected")
  end
  for voice_idx = 1, 7 do
    scene.data.voices[voice_idx].source = nil
    for _, key in ipairs({ "buf_pos", "buf_rate", "buf_scan" }) do scene.data.voices[voice_idx].grain[key] = nil end
  end
  migrate_scene(scene, 1)
  assert_equal(scene.data.voices[2].source, 1, "missing source migrates to synth")
  assert_equal(scene.data.voices[2].grain.buf_rate, 1, "missing buf_rate migrates to 1")
  assert_equal(scene.data.voices[2].grain.buf_pos, 0, "missing buf_pos migrates to 0")
  assert_true(validate_scene(scene), "migrated scene validates")
end)

test("buffer faders replace synth faders for a buffer-sourced voice", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  local press = function(x, y) context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0) end
  press(14, 8); press(1, 14)            -- grid page 2, voice 1 (resonator: 6 fader pages)
  press(6, 13); assert_equal(local_value("param_page"), 6)
  params:set("v1_source", 2)
  local ids = fader_param_ids(1)
  assert_equal(ids[1], "v1_buf_pos"); assert_equal(ids[2], "v1_buf_rate")
  assert_equal(ids[3], "v1_buf_scan"); assert_equal(ids[4], "v1_amp")
  assert_equal(ids[5], "v1_grain_size", "grain faders follow")
  assert_equal(#ids, 4 + 6 + 9); assert_equal(fader_page_count(1), 5)
  assert_equal(local_value("param_page"), 5, "fader page clamped when the source shrinks the list")
  press(1, 13); press(16, 10)           -- page 1, row 2 = buf_rate max
  assert_near(params:get("v1_buf_rate"), 4, 1e-6, "buf_rate fader")
  assert_equal(device:get_led(16, 10), 15)
  params:set("v1_source", 1)
  assert_equal(fader_param_ids(1)[1], "v1_freq", "synth faders return")
end)

test("buffer group params: exact group, triggers and defaults", function()
  load_strata()
  local expected = { "record_duration", "record_level" }
  for slot = 1, 8 do
    for _, suffix in ipairs({ "file", "record", "clear", "save" }) do
      table.insert(expected, "buf" .. slot .. "_" .. suffix)
    end
  end
  local group_index
  for index, param in ipairs(params.params) do
    if param.id == "strata_buffers" then group_index = index end
  end
  assert_true(group_index, "strata_buffers group exists")
  assert_equal(params.params[group_index].n, #expected, "group size")
  for offset, param_id in ipairs(expected) do
    assert_equal(params.params[group_index + offset].id, param_id, "group entry " .. offset)
  end
  assert_near(params:get("record_duration"), 8, 1e-9); assert_near(params:get("record_level"), 1, 1e-9)
  assert_equal(param_range("record_duration"), 0.5); assert_equal(select(2, param_range("record_duration")), 16)
  assert_equal(select(2, param_range("record_level")), 2)
  assert_equal(params:lookup_param("buf1_file").t, params.tFILE)
  assert_equal(params:lookup_param("buf1_record").t, params.tTRIGGER)
  local buffers = local_value("buffers")
  assert_equal(#buffers, 8)
  for slot = 1, 8 do
    assert_equal(buffers[slot].name, "empty"); assert_equal(buffers[slot].loaded, false)
    assert_equal(buffers[slot].recording, false); assert_equal(buffers[slot].seconds, 0)
    assert_equal(buffers[slot].path, nil)
  end
end)

test("buffer triggers call the engine and track recording state", function()
  local context = load_strata()
  params:set("record_duration", 2); params:set("buf3_record", 1)
  local call = context.calls_named("recordBuffer")[1]
  assert_equal(call.args[1], 2); assert_near(call.args[2], 2, 1e-9); assert_near(call.args[3], 1, 1e-9)
  assert_true(local_value("buffers")[3].recording)
  context.clock.advance(); assert_true(local_value("buffers")[3].recording, "finishing until the engine reports")
  context.polls.fire("bufferState", 202)  -- the engine reports the take
  assert_true(not local_value("buffers")[3].recording)
  assert_equal(local_value("buffers")[3].name, "take 3"); assert_true(local_value("buffers")[3].loaded)
  assert_equal(local_value("buffers")[3].path, _path.audio .. "strata/scratch/buf3.wav", "scratch take path")
  params:set("buf3_file", "/tmp/a.wav"); assert_equal(context.calls_named("loadBuffer")[1].args[2], "/tmp/a.wav")
  assert_equal(context.calls_named("loadBuffer")[1].args[1], 2)
  assert_equal(local_value("buffers")[3].name, "a.wav"); assert_equal(local_value("buffers")[3].path, "/tmp/a.wav")
  params:set("buf3_clear", 1); assert_equal(context.calls_named("clearBuffer")[1].args[1], 2)
  assert_equal(local_value("buffers")[3].name, "empty"); assert_true(not local_value("buffers")[3].loaded)
  context.polls.fire("bufferState", 201.5); assert_near(local_value("buffers")[3].seconds, 1.5, 1e-9)
  context.polls.fire("bufferState", 716); assert_near(local_value("buffers")[8].seconds, 16, 1e-9)
  context.polls.fire("bufferState", 0); assert_near(local_value("buffers")[1].seconds, 0, 1e-9)
  context.polls.fire("bufferState", 950); context.polls.fire("bufferState", -1)  -- out of range: ignored
  -- an empty path or norns' "-" (no file chosen) loads nothing
  context.clear_engine_calls()
  params:set("buf4_file", ""); params:set("buf4_file", "-"); params:set("buf4_file", _path.audio)
  assert_equal(#context.calls_named("loadBuffer"), 0, "no load without a file")
end)

test("recording again stops early; clear and load cancel the timer", function()
  local context = load_strata(); context.clock.advance()   -- finish init's start-up coroutine
  local buffers = local_value("buffers")
  params:set("record_duration", 4)
  record_buffer(2); assert_true(buffers[2].recording)
  context.clear_engine_calls()
  record_buffer(2)
  assert_equal(#context.calls_named("stopRecord"), 1, "second press stops the recording")
  assert_equal(context.calls_named("stopRecord")[1].args[1], 1)
  assert_equal(#context.calls_named("recordBuffer"), 0, "and does not start a new one")
  context.polls.fire("bufferState", 101)  -- the engine reports what was captured
  assert_true(not buffers[2].recording); assert_true(buffers[2].loaded); assert_equal(buffers[2].name, "take 2")
  local pending = context.clock.pending_count()
  record_buffer(2); assert_equal(context.clock.pending_count(), pending + 1, "new recording timer")
  clear_buffer(2)
  assert_true(not buffers[2].recording, "clear ends the recording state")
  assert_equal(context.clock.pending_count(), pending, "clear cancels the timer")
  record_buffer(2); load_buffer(2, "/tmp/b.wav")
  assert_true(not buffers[2].recording, "load ends the recording state")
  assert_equal(context.clock.pending_count(), pending, "load cancels the timer")
  -- out-of-range slots are ignored
  context.clear_engine_calls()
  record_buffer(0); record_buffer(9); clear_buffer(9); load_buffer(0, "/tmp/c.wav"); save_buffer(9)
  assert_equal(#context.engine_calls, 0, "invalid slots send nothing")
  -- cleanup stops the poll and any recording timer
  record_buffer(5)
  cleanup()
  assert_equal(context.clock.pending_count(), 0, "no recording timer left")
  assert_true(not context.polls.polls.bufferState.running, "bufferState poll stopped")
end)

test("a take or a load is confirmed by the engine's bufferState report", function()
  local context = load_strata(); context.clock.advance()
  local buffers = local_value("buffers")
  local function hint()
    for _, entry in ipairs(context.screen.texts) do
      if entry.x == 0 and entry.y == HINT_ROW_Y then return entry.text end
    end
  end
  -- a take that ran its full duration
  params:set("record_duration", 2)
  record_buffer(3)
  context.clock.advance()                       -- the recording timer ends
  assert_true(buffers[3].recording, "finishing: still shown as recording")
  assert_true(not buffers[3].loaded, "not loaded before the engine reports it")
  assert_equal(buffers[3].name, "empty", "no take name yet")
  params:set("v1_source", 4); show_page(4)      -- voice 1 reads buf 3
  assert_equal(hint(), "K2:load K3:... K2+3:save", "BUFFER hint while finishing")
  context.clear_engine_calls(); record_buffer(3)
  assert_equal(#context.engine_calls, 0, "a press while finishing sends nothing (no new take, no stop)")
  assert_true(buffers[3].recording, "and changes nothing")
  context.polls.fire("bufferState", 200)        -- a periodic 0 s sent before the take completed
  assert_true(buffers[3].recording and not buffers[3].loaded, "0 s inside the settle time is not the outcome")
  context.polls.fire("bufferState", 202)        -- the engine reports the take
  assert_true(not buffers[3].recording, "finished"); assert_true(buffers[3].loaded, "loaded")
  assert_equal(buffers[3].name, "take 3"); assert_equal(buffers[3].path, scratch_take_path(3))
  show_page(4)
  assert_equal(hint(), "K2:load K3:rec K2+3:save", "hint back to rec")

  -- stopped within the start-up window: the engine captured nothing
  record_buffer(4); record_buffer(4)
  assert_equal(#context.calls_named("stopRecord"), 1, "the stop is sent")
  assert_true(buffers[4].recording and not buffers[4].loaded, "finishing after the stop")
  context.set_time(5)                           -- past the settle time
  context.polls.fire("bufferState", 300)
  assert_true(not buffers[4].recording, "settled"); assert_true(not buffers[4].loaded, "nothing captured: empty")
  assert_equal(buffers[4].name, "empty"); assert_equal(buffers[4].path, nil)
  context.clear_engine_calls(); record_buffer(4)
  assert_equal(#context.calls_named("recordBuffer"), 1, "an empty slot records again")

  -- a file load shows its name at once; 0 s after the settle time clears loaded
  load_buffer(5, "/tmp/unreadable.wav")
  assert_true(buffers[5].loaded, "optimistic load"); assert_equal(buffers[5].name, "unreadable.wav")
  context.polls.fire("bufferState", 400)
  assert_true(buffers[5].loaded, "0 s inside the settle time keeps the load")
  context.set_time(10); context.polls.fire("bufferState", 400)
  assert_true(not buffers[5].loaded, "the engine has no audio: not loaded")
  assert_equal(buffers[5].name, "unreadable.wav", "the name stays")
  load_buffer(6, "/tmp/fine.wav"); context.polls.fire("bufferState", 503.5)
  assert_true(buffers[6].loaded, "audio reported: loaded"); assert_near(buffers[6].seconds, 3.5, 1e-9)
end)

test("a take settled empty adopts audio the engine reports later; a clear wins", function()
  local context = load_strata(); context.clock.advance()
  local buffers = local_value("buffers")
  params:set("record_duration", 2)
  record_buffer(3); context.clock.advance()     -- the timer ends; the engine is slow
  context.set_time(5); context.polls.fire("bufferState", 200)
  assert_equal(buffers[3].name, "empty", "a periodic 0 after the settle time empties the slot")
  context.polls.fire("bufferState", 202)        -- the take completes late
  assert_true(buffers[3].loaded, "the late take is adopted"); assert_equal(buffers[3].name, "take 3")
  assert_equal(buffers[3].path, scratch_take_path(3), "with the scratch take path")
  context.polls.fire("bufferState", 202); context.polls.fire("bufferState", 203)
  assert_equal(buffers[3].name, "take 3", "later reports leave it a take")
  -- a slot cleared after an empty take is not brought back by a report
  record_buffer(4); record_buffer(4)
  context.set_time(10); context.polls.fire("bufferState", 300)
  assert_equal(buffers[4].name, "empty")
  clear_buffer(4); context.polls.fire("bufferState", 302)
  assert_true(not buffers[4].loaded, "clear wins"); assert_equal(buffers[4].path, nil)
  -- nor is a slot whose last event was a load or a new recording
  record_buffer(5); record_buffer(5)
  context.set_time(15); context.polls.fire("bufferState", 400)
  record_buffer(5); context.polls.fire("bufferState", 401)
  assert_true(buffers[5].recording, "a new recording is not adopted as the old take")
  assert_true(not buffers[5].finishing)
end)

test("a load settled empty adopts audio the engine reports later; restores count; a clear wins", function()
  local context = load_strata(); context.clock.advance()
  local buffers = local_value("buffers")
  -- a slow read: the engine keeps reporting 0 s past the settle time
  load_buffer(2, "/tmp/slow.wav")
  context.set_time(2); context.polls.fire("bufferState", 100)
  assert_true(not buffers[2].loaded, "settled empty")
  context.polls.fire("bufferState", 116)        -- the read completes
  assert_true(buffers[2].loaded, "the late load is adopted")
  assert_equal(buffers[2].name, "slow.wav", "it keeps the file name")
  assert_equal(buffers[2].path, "/tmp/slow.wav")
  -- a restored slot read late counts once
  load_buffer(3, "/tmp/restored.wav"); buffers[3].restoring = true   -- as load_buffers_from_disk does
  context.set_time(4); context.polls.fire("bufferState", 200)
  assert_equal(local_value("buffers_restored"), 0, "not counted while empty")
  context.polls.fire("bufferState", 208); context.polls.fire("bufferState", 208)
  assert_true(buffers[3].loaded); assert_equal(local_value("buffers_restored"), 1, "counted once when adopted")
  -- a clear, or a new load, in between wins
  load_buffer(4, "/tmp/gone.wav")
  context.set_time(6); context.polls.fire("bufferState", 300)
  clear_buffer(4); context.polls.fire("bufferState", 305)
  assert_true(not buffers[4].loaded, "clear wins"); assert_equal(buffers[4].name, "empty")
  load_buffer(5, "/tmp/first.wav")
  context.set_time(8); context.polls.fire("bufferState", 400)
  load_buffer(5, "/tmp/second.wav"); context.set_time(10); context.polls.fire("bufferState", 400)
  assert_true(not buffers[5].loaded, "the second load settled empty too")
  assert_equal(buffers[5].name, "second.wav", "a new load replaces the old one")
end)

test("a finishing take settles from the last known seconds when no report comes", function()
  local context = load_strata(); context.clock.advance()
  local buffers = local_value("buffers")
  -- BUFFER_SETTLE is an upvalue of the local finish_buffer_take, which the
  -- global record_buffer holds
  local finish_buffer_take = local_value("finish_buffer_take")
  local buffer_settle
  for index = 1, math.huge do
    local name, value = debug.getupvalue(finish_buffer_take, index)
    if not name then break end
    if name == "BUFFER_SETTLE" then buffer_settle = value end
  end
  assert_true(buffer_settle ~= nil, "BUFFER_SETTLE reached through finish_buffer_take")
  local fallback_seconds = buffer_settle.fallback_seconds
  params:set("record_duration", 2)
  record_buffer(3); context.clock.advance()     -- the timer ends: finishing, no report ever
  assert_true(buffers[3].finishing, "finishing")
  local log = context.clock.sleep_log
  assert_equal(log[#log].amount, fallback_seconds, "the fallback waits fallback_seconds after the take ends")
  context.clock.advance()                       -- the fallback runs
  assert_true(not buffers[3].finishing and not buffers[3].recording, "settled")
  assert_equal(buffers[3].name, "empty", "no seconds known: empty")
  context.clear_engine_calls(); record_buffer(3)
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records again")
  -- a stopped take gets the fallback too, and settles as a take when the
  -- slot's seconds are known
  record_buffer(3)
  assert_true(buffers[3].finishing)
  buffers[3].seconds = 1.5                      -- as an earlier report left it
  context.clock.advance()
  assert_true(buffers[3].loaded, "known seconds: loaded"); assert_equal(buffers[3].name, "take 3")
  -- a report, a load, a clear or cleanup cancels the fallback
  local pending = context.clock.pending_count()
  record_buffer(4); record_buffer(4)
  assert_equal(context.clock.pending_count(), pending + 1, "fallback pending")
  context.polls.fire("bufferState", 301)
  assert_equal(context.clock.pending_count(), pending, "a report settles it and cancels the fallback")
  record_buffer(5); record_buffer(5); load_buffer(5, "/tmp/x.wav")
  assert_equal(context.clock.pending_count(), pending, "load cancels the fallback")
  record_buffer(6); record_buffer(6); clear_buffer(6)
  assert_equal(context.clock.pending_count(), pending, "clear cancels the fallback")
  record_buffer(7); record_buffer(7)
  cleanup()
  assert_equal(context.clock.pending_count(), 0, "cleanup cancels the fallback")
end)

test("bufferState poll is found and started in init", function()
  local context = load_strata()
  local entry = context.polls.polls.bufferState
  assert_true(entry ~= nil, "the engine registers bufferState")
  assert_true(entry.running, "poll started"); assert_true(entry.callback ~= nil, "callback set")
end)

test("save_buffer writes a timestamped wav under audio/strata", function()
  local context = load_strata()
  load_buffer(6, "/tmp/x.wav")
  -- the engine has not reported any audio yet: nothing to save (a failed load
  -- leaves loaded = true, so the guard is the poll's seconds)
  save_buffer(6)
  assert_equal(#context.calls_named("saveBuffer"), 0, "loaded flag alone does not save")
  context.polls.fire("bufferState", 504)  -- slot index 5 (buffer 6) holds 4 s
  save_buffer(6)
  local call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[1], 5)
  local dir = _path.audio .. "strata/"
  assert_equal(call.args[2]:sub(1, #dir), dir, "saved under " .. dir)
  assert_true(call.args[2]:sub(#dir + 1):match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-buf6%.wav$"),
    "timestamped name: " .. call.args[2])
  assert_equal(buffer_save_path(6):sub(1, #dir), dir)
  assert_true(util.file_exists(dir), "directory created")
  assert_true(table.concat(context.printed, "\n"):find(call.args[2], 1, true), "path printed")
  -- an empty slot has nothing to save
  context.clear_engine_calls(); save_buffer(1)
  assert_equal(#context.calls_named("saveBuffer"), 0, "empty slot not saved")
  params:set("buf6_save", 1); assert_equal(#context.calls_named("saveBuffer"), 1, "save trigger")
end)

test("explicit save writes a timestamped file; cleanup/init persist buffer paths", function()
  local context = load_strata({ data_subdir = "buf" })
  context.polls.fire("bufferState", 104)  -- buffer 2 holds 4 s (save needs the engine's seconds)
  params:set("buf2_save", 1)
  local call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[1], 1); assert_true(call.args[2]:match("strata/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-buf2%.wav$"))
  params:set("buf1_file", context.audio_dir .. "one.wav"); io.open(context.audio_dir .. "one.wav", "w"):close()
  params:set("buf4_record", 1); context.clock.advance()
  context.polls.fire("bufferState", 304)  -- the engine reports the take
  assert_equal(local_value("buffers")[4].path, context.audio_dir .. "strata/scratch/buf4.wav")
  assert_equal(scratch_take_path(4), context.audio_dir .. "strata/scratch/buf4.wav")
  cleanup()
  local again = load_strata({ data_subdir = "buf" })
  local loads = again.calls_named("loadBuffer")
  assert_equal(loads[1].args[1], 0); assert_equal(loads[1].args[2], context.audio_dir .. "one.wav")
  assert_equal(#loads, 1, "scratch take not restored when its file is missing")
end)

test("buffers.data format, restored scratch takes and the SETUP count", function()
  local context = load_strata({ data_subdir = "buf_format" })
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  show_page(5)
  assert_true(screen_has("buffers: 0 restored"), "nothing restored without a file")
  local loaded_file = context.audio_dir .. "loop.wav"
  io.open(loaded_file, "w"):close()
  load_buffer(3, loaded_file)
  record_buffer(5); context.clock.advance()
  context.polls.fire("bufferState", 404)        -- the engine reports the take
  -- the engine wrote the take
  util.make_dir(context.audio_dir .. "strata/scratch/")
  io.open(scratch_take_path(5), "w"):close()
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.version, 1, "format version")
  for slot = 1, 8 do
    local expected = ({ [3] = loaded_file, [5] = scratch_take_path(5) })[slot] or ""
    assert_equal(saved.paths[slot], expected, "slot " .. slot .. " path")
  end

  context = load_strata({ data_subdir = "buf_format" })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 2, "both existing files restored")
  assert_equal(loads[1].args[1], 2); assert_equal(loads[1].args[2], loaded_file)
  assert_equal(loads[2].args[1], 4); assert_equal(loads[2].args[2], scratch_take_path(5))
  local buffers = local_value("buffers")
  assert_equal(buffers[3].name, "loop.wav"); assert_equal(buffers[3].path, loaded_file)
  assert_equal(buffers[5].name, "take 5", "a restored scratch take keeps its take name")
  assert_equal(buffers[5].path, scratch_take_path(5))
  assert_equal(params:get("buf3_file"), loaded_file, "a restored slot's file param shows its path (F2)")
  assert_equal(params:get("buf5_file"), scratch_take_path(5), "a restored take's file param shows the take")
  assert_equal(params:get("buf1_file"), _path.audio, "a slot with nothing restored stays at its starting folder")
  assert_equal(local_value("buffers_restored"), 0, "restored once the engine reports audio")
  context.polls.fire("bufferState", 202); context.polls.fire("bufferState", 404)
  assert_equal(local_value("buffers_restored"), 2)
  show_page(5)
  assert_true(screen_has("buffers: 2 restored"), "SETUP shows the restored count")
  -- a slot whose file has gone is skipped and reported, and stays empty
  os.remove(loaded_file)
  cleanup()
  context = load_strata({ data_subdir = "buf_format" })
  assert_equal(#context.calls_named("loadBuffer"), 1, "missing file not loaded")
  assert_equal(local_value("buffers")[3].name, "empty")
  assert_true(table.concat(context.printed, "\n"):find(loaded_file, 1, true), "missing file reported")
  assert_equal(local_value("buffers_restored"), 0, "nothing confirmed by the engine yet")
  context.polls.fire("bufferState", 403)        -- buffer 5's take
  assert_equal(local_value("buffers_restored"), 1)
end)

test("a buffer cleared before exit is saved empty and not restored", function()
  local context = load_strata({ data_subdir = "buf_cleared" })
  local kept_file, cleared_file = context.audio_dir .. "kept.wav", context.audio_dir .. "cleared.wav"
  io.open(kept_file, "w"):close(); io.open(cleared_file, "w"):close()
  load_buffer(2, kept_file); load_buffer(6, cleared_file)
  cleanup()
  context = load_strata({ data_subdir = "buf_cleared" })
  assert_equal(#context.calls_named("loadBuffer"), 2, "both files restored")
  clear_buffer(6)
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[6], "", "the cleared slot is saved as an empty path")
  assert_equal(saved.paths[2], kept_file, "the other slot keeps its file")
  context = load_strata({ data_subdir = "buf_cleared" })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "only the kept slot is restored")
  assert_equal(loads[1].args[1], 1); assert_equal(loads[1].args[2], kept_file)
  local buffers = local_value("buffers")
  assert_equal(buffers[6].name, "empty", "the cleared slot starts empty")
  assert_equal(buffers[6].path, nil, "the cleared slot has no path")
end)

test("restores count engine-confirmed slots; missing remembered files are kept across restarts", function()
  local subdir = "buf_missing"
  local context = load_strata({ data_subdir = subdir })
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  local present = context.audio_dir .. "here.wav"
  local unreadable = context.audio_dir .. "bad.wav"
  local away = context.audio_dir .. "drive/away.wav"   -- on a drive that is unmounted later
  util.make_dir(context.audio_dir .. "drive/")
  for _, path in ipairs({ present, unreadable, away }) do io.open(path, "w"):close() end
  load_buffer(1, present); load_buffer(2, unreadable); load_buffer(3, away)
  cleanup()
  os.remove(away)

  context = load_strata({ data_subdir = subdir })
  local buffers = local_value("buffers")
  assert_equal(#context.calls_named("loadBuffer"), 2, "the two files present are loaded")
  assert_equal(buffers[3].name, "empty", "the missing file's slot stays empty")
  assert_true(not buffers[3].loaded)
  assert_true(table.concat(context.printed, "\n"):find(away, 1, true), "the console names the missing file")
  assert_equal(local_value("buffers_restored"), 0, "nothing restored until the engine reports audio")
  show_page(5)
  assert_true(screen_has("buffers: 0 ok, 1 missing"), "SETUP shows the missing file")
  context.polls.fire("bufferState", 3)          -- buffer 1 holds 3 s
  context.polls.fire("bufferState", 3)          -- the periodic poll repeats it
  assert_equal(local_value("buffers_restored"), 1, "a confirmed slot counts once")
  context.set_time(5); context.polls.fire("bufferState", 100)   -- buffer 2: the engine could not read it
  assert_equal(local_value("buffers_restored"), 1, "a slot without audio does not count")
  assert_true(not buffers[2].loaded, "and is not loaded")
  show_page(5)
  assert_true(screen_has("buffers: 1 ok, 1 missing"), "SETUP count after the reports")
  assert_screen_layout(context, "SETUP with missing buffers")

  -- the missing path survives the next exit, so the sample comes back once
  -- its drive is mounted again
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[1], present); assert_equal(saved.paths[2], unreadable)
  assert_equal(saved.paths[3], away, "the missing file's path is kept")
  io.open(away, "w"):close()
  context = load_strata({ data_subdir = subdir })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 3, "the file is back: restored")
  assert_equal(loads[3].args[1], 2); assert_equal(loads[3].args[2], away)
  context.polls.fire("bufferState", 3); context.polls.fire("bufferState", 201)
  assert_equal(local_value("buffers_restored"), 2)
  show_page(5)
  assert_true(screen_has("buffers: 2 restored"), "no missing files: the plain count")
  -- a slot cleared after a missing restore forgets the path
  cleanup(); os.remove(away)
  context = load_strata({ data_subdir = subdir })
  clear_buffer(3)
  cleanup()
  saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[3], "", "cleared: the missing path is forgotten")

  -- an earlier blocked auto-save does not outlive the next load
  local _, set_blocked = find_upvalue("buffer_autosave_blocked")
  set_blocked(true)
  load_buffers_from_disk()
  assert_equal(local_value("buffer_autosave_blocked"), false, "reset at the top of load_buffers_from_disk")
  set_blocked(true)
  os.remove(context.data_dir .. "strata/buffers.data")
  load_buffers_from_disk()
  assert_equal(local_value("buffer_autosave_blocked"), false, "reset even when there is no file")
end)

test("a buffers file that fails to load does not stop init and survives cleanup", function()
  local bad_files = {
    { name = "wrong version", content = "return { version = 99, paths = {} }" },
    { name = "raises on load", content = 'error("corrupt buffers file")' },
    { name = "not a table", content = "return 42" },
    { name = "paths not a table", content = 'return { version = 1, paths = "x" }' },
  }
  for index, bad in ipairs(bad_files) do
    local subdir = "buf_survive_" .. index
    local data_dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. data_dir .. "'")
    local file = assert(io.open(data_dir .. "buffers.data", "w"))
    file:write(bad.content)
    file:close()

    local context = load_strata({ data_subdir = subdir })  -- init's load fails
    assert_equal(#context.calls_named("loadBuffer"), 0, bad.name .. ": nothing loaded")
    assert_equal(local_value("buffers_restored"), 0, bad.name .. ": nothing restored")
    local recorded = context.audio_dir .. "new.wav"
    io.open(recorded, "w"):close()
    load_buffer(2, recorded)  -- new work after the failed load
    cleanup()
    local backup = io.open(data_dir .. "buffers.data.bak", "r")
    assert_true(backup ~= nil, bad.name .. ": original kept as buffers.data.bak")
    assert_equal(backup:read("*a"), bad.content, bad.name .. ": backup content unchanged")
    backup:close()
    context = load_strata({ data_subdir = subdir })
    assert_equal(context.calls_named("loadBuffer")[1].args[2], recorded, bad.name .. ": new work saved on exit")
  end

  -- if the file cannot be moved aside, cleanup must not overwrite it
  local data_dir = data_root .. "buf_survive_blocked/strata/"
  os.execute("mkdir -p '" .. data_dir .. "buffers.data.bak/occupied'")  -- rename target is a non-empty dir
  local file = assert(io.open(data_dir .. "buffers.data", "w"))
  file:write(bad_files[1].content)
  file:close()
  load_strata({ data_subdir = "buf_survive_blocked" })
  cleanup()
  file = assert(io.open(data_dir .. "buffers.data", "r"))
  assert_equal(file:read("*a"), bad_files[1].content, "unmovable bad file not overwritten by cleanup")
  file:close()
end)

test("MAIN layout holds for buffer- and input-sourced voices", function()
  local context = load_strata(); context.clock.advance()
  local _, set_selected = find_upvalue("selected_voice")
  for _, source in ipairs({ 9, 10 }) do
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      params:set("v" .. voice_idx .. "_source", source)
      params:set("v" .. voice_idx .. "_buf_pos", 1)
      params:set("v" .. voice_idx .. "_grain_mode", 2)
      if not local_value("frozen")[voice_idx] then toggle_freeze(voice_idx) end
      show_page(1)
      assert_screen_layout(context, "MAIN, voice " .. voice_idx .. " source " .. source)
    end
  end
end)

---------------------------------------------------------------------------
-- BUFFER page, arc BUFFER page, grid page 4 buffer rows
---------------------------------------------------------------------------

-- Press and release a norns key
local function tap(n) key(n, 1); key(n, 0) end

-- The drawn strings on row y, left to right
local function texts_on_row(context, y)
  local row = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == y then table.insert(row, entry) end
  end
  table.sort(row, function(a, b) return select(1, text_span(a)) < select(1, text_span(b)) end)
  return row
end

local function hint_text(context)
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == HINT_ROW_Y then return entry.text end
  end
end

test("BUFFER page: E3 cycles source, K3 records into the voice's slot, K2 opens the file selector", function()
  local context = load_strata(); context.clock.advance(); enc(1, 3)
  assert_equal(PAGE_TITLES[local_value("ui_page")], "BUFFER")
  enc(3, 2); assert_equal(params:get("v1_source"), 3)
  key(3, 1); assert_equal(context.calls_named("recordBuffer")[1].args[1], 1)
  key(3, 0)
  -- adapted (R12): K2 acts on release, so the brief's key(2, 1) is a press and release
  tap(2); assert_true(context.fileselect.last ~= nil, "fileselect opened")
  assert_equal(context.fileselect.last.folder, _path.audio, "file selector starts in the audio folder")
  context.fileselect.last.callback("/tmp/b.wav"); assert_equal(params:get("buf2_file"), "/tmp/b.wav")
  params:set("v1_source", 1); context.clear_engine_calls(); context.fileselect.last = nil
  tap(3); tap(2)
  assert_equal(#context.calls_named("recordBuffer"), 0, "K3 does nothing for a synth voice")
  assert_equal(context.fileselect.last, nil, "K2 does nothing for a synth voice")
  redraw(); for _, entry in ipairs(context.screen.texts) do local l, r = text_span(entry); assert_true(r <= 128) end
  -- E2 selects the voice (shared with MAIN); a cancelled selection loads nothing
  enc(2, 3); assert_equal(local_value("selected_voice"), 4)
  params:set("v4_source", 7); tap(2); context.clear_engine_calls()
  context.fileselect.last.callback("cancel")
  assert_equal(#context.calls_named("loadBuffer"), 0, "cancel loads nothing")
  assert_equal(voice_buffer_slot(4), 6); assert_equal(voice_buffer_slot(1), nil)
  params:set("v1_source", 10); assert_equal(voice_buffer_slot(1), nil, "input has no buffer slot")
end)

test("the same file loads again after a record or clear, from the BUFFER page and PARAMS (F2)", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  params:set("v1_source", 2)  -- voice 1 reads buffer 1
  context.clear_engine_calls()
  local function loads() return #context.calls_named("loadBuffer") end
  tap(2); context.fileselect.last.callback("/tmp/foo.wav")
  assert_equal(loads(), 1, "the BUFFER page loads the picked file")
  assert_equal(params:get("buf1_file"), "/tmp/foo.wav", "and the file param shows it")
  clear_buffer(1)
  assert_equal(params:get("buf1_file"), _path.audio, "clear resets the file param to its starting folder")
  assert_equal(loads(), 1, "the reset is silent (loads nothing)")
  tap(2); context.fileselect.last.callback("/tmp/foo.wav")
  assert_equal(loads(), 2, "the same file loads again after a clear (BUFFER page)")
  record_buffer(1)
  assert_equal(params:get("buf1_file"), _path.audio, "a recording resets the file param")
  assert_equal(loads(), 2, "silently")
  params:set("buf1_file", "/tmp/foo.wav")
  assert_equal(loads(), 3, "the same file loads again after a recording (PARAMS)")
  assert_true(not local_value("buffers")[1].recording, "the load ended the recording")
  tap(2); context.fileselect.last.callback("/tmp/foo.wav")
  assert_equal(loads(), 4, "picking the loaded file again on the BUFFER page reloads it")
  assert_equal(context.calls_named("loadBuffer")[4].args[1], 0); assert_equal(context.calls_named("loadBuffer")[4].args[2], "/tmp/foo.wav")
end)

test("the BUFFER page caches each slot's cut name (M3)", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  local measured = 0
  local text_extents = screen.text_extents
  screen.text_extents = function(text) measured = measured + 1; return text_extents(text) end
  -- each load redraws the page (and measures the new name)
  for slot = 1, 8 do load_buffer(slot, "/tmp/a very long sample name number " .. slot .. ".wav") end
  assert_true(measured > 0, "a new name is measured")
  measured = 0
  redraw(); redraw()
  screen.text_extents = text_extents
  assert_equal(measured, 0, "later draws reuse the cut names")
  local names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_true(names[14] ~= nil and #names[14] < 20, "the cached name is the cut one")
  load_buffer(1, "/tmp/b.wav"); redraw()
  names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_equal(names[14], "b", "a new name is cut and shown")
  clear_buffer(1); redraw()
  names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_equal(names[14], "empty", "a cleared slot shows empty")
end)

test("BUFFER page: K2+K3 saves, K2 release then does not open the selector (R12)", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)  -- the engine reports buffer 3's audio
  context.clear_engine_calls(); context.fileselect.last = nil
  key(2, 1); tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K3 with K2 held saves")
  assert_equal(context.calls_named("saveBuffer")[1].args[1], 2, "the voice's buffer")
  assert_equal(#context.calls_named("recordBuffer"), 0, "and does not record")
  tap(3); assert_equal(#context.calls_named("saveBuffer"), 2, "each K3 while K2 is held saves")
  key(2, 0); assert_equal(context.fileselect.last, nil, "K2 release after a save opens nothing")
  -- the next plain K2 opens the selector again, and a plain K3 records
  tap(2); assert_true(context.fileselect.last ~= nil, "K2 alone opens the selector")
  tap(3); assert_equal(#context.calls_named("recordBuffer"), 1, "K3 alone records")
  tap(3); assert_equal(#context.calls_named("stopRecord"), 1, "K3 again stops early")
  context.polls.fire("bufferState", 205)  -- the engine reports the stopped take
  -- a K2 held across a page change is released elsewhere: no selector, and
  -- back on BUFFER K3 records
  context.fileselect.last = nil; context.clear_engine_calls()
  key(2, 1); show_page(1); key(2, 0); show_page(4)
  assert_equal(context.fileselect.last, nil, "K2 released on another page opens nothing")
  tap(3); assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records once K2 is up")
  assert_equal(#context.calls_named("saveBuffer"), 0)
end)

test("BUFFER page K2+K3 confirms the save in the hint row for 1.5 s", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)  -- buffer 3 holds 4 s
  context.set_time(100)
  key(2, 1); tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K2+K3 saves")
  assert_equal(hint_text(context), "saved buf 3", "the hint row confirms the save")
  assert_screen_layout(context, "BUFFER with the save confirmation")
  key(2, 0); assert_equal(hint_text(context), "saved buf 3", "K2's release leaves it")
  context.set_time(101.4); redraw()
  assert_equal(hint_text(context), "saved buf 3", "still shown before 1.5 s")
  context.set_time(101.5); redraw()
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save", "the normal hint after 1.5 s")
  -- an empty buffer: nothing saved, the hint says so
  context.polls.fire("bufferState", 200)  -- buffer 3 reports 0 s
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0)
  assert_equal(#context.calls_named("saveBuffer"), 0, "an empty buffer is not saved")
  assert_equal(hint_text(context), "buf 3 empty", "the hint says the buffer is empty")
  assert_screen_layout(context, "BUFFER with the empty-buffer flash")
  -- one clock redraws when the flash ends: it sleeps 1.5 s, clears the flash
  -- (even if it woke a little early) and redraws
  local page = local_value("BUFFER_PAGE")
  local flash_clock = page.flash_clock
  assert_true(flash_clock ~= nil, "the flash has a clock")
  local log = context.clock.sleep_log
  assert_equal(log[#log].id, flash_clock); assert_near(log[#log].amount, 1.5, 1e-9, "it sleeps 1.5 s")
  key(2, 1); tap(3); key(2, 0)   -- a second flash replaces the first one's clock
  assert_equal(context.clock.threads[flash_clock], nil, "the earlier clock is cancelled")
  flash_clock = page.flash_clock
  context.clock.resume_thread(flash_clock)
  assert_equal(context.clock.threads[flash_clock], nil, "the clock ends after one redraw")
  assert_equal(page.flash_clock, nil)
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save", "its redraw shows the normal hint")
  -- cleanup cancels a pending flash clock
  key(2, 1); tap(3); key(2, 0)
  flash_clock = page.flash_clock
  cleanup()
  assert_equal(context.clock.threads[flash_clock], nil, "cleanup cancels the flash clock")
  assert_equal(page.flash_clock, nil)
end)

test("BUFFER page K2+K3 on a recording or finishing buffer flashes busy and saves nothing", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  params:set("v1_source", 4)
  local buffers = local_value("buffers")
  tap(3); assert_true(buffers[3].recording, "K3 records into buffer 3")
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while recording")
  assert_equal(#context.calls_named("stopRecord"), 0, "K2+K3 does not stop the recording")
  assert_equal(hint_text(context), "buf 3 busy", "the hint says the buffer is busy")
  assert_screen_layout(context, "BUFFER with the busy flash while recording")
  -- stopped early: the take waits for the engine (finishing)
  tap(3); assert_true(buffers[3].finishing, "the stopped take is finishing")
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while finishing")
  assert_equal(hint_text(context), "buf 3 busy", "still busy while finishing")
  assert_screen_layout(context, "BUFFER with the busy flash while finishing")
  -- once the engine reports the take, K2+K3 saves it
  context.polls.fire("bufferState", 205)
  assert_true(not buffers[3].finishing, "the take settled")
  key(2, 1); tap(3); key(2, 0)
  assert_equal(#context.calls_named("saveBuffer"), 1, "the settled take saves")
  assert_equal(hint_text(context), "saved buf 3")
end)

test("a K2 released inside the norns menu is forgotten: K3 records again (fix round 1)", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  local drift_metro = local_value("drift_metro")
  context.clear_engine_calls(); context.fileselect.last = nil
  -- K2 down, then K1 opens the menu: the K2 release goes to the menu
  key(2, 1)
  context.menu.mode = true; drift_metro.event()   -- a 10 Hz tick while the menu is open
  context.menu.mode = false                       -- K1 again: back to the script
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save after K2 was released in the menu")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  assert_equal(context.fileselect.last, nil, "nothing opened the file selector")
  -- a save made with K2 held, then the menu: the next K2 tap opens the selector
  tap(3)  -- stop the recording
  context.polls.fire("bufferState", 202)  -- the engine reports the 2 s take
  key(2, 1); tap(3); assert_equal(#context.calls_named("saveBuffer"), 1, "K2+K3 still saves")
  context.menu.mode = true; drift_metro.event(); context.menu.mode = false
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the selector after the menu")
  -- ticks with the menu closed keep a held K2
  context.fileselect.last = nil; context.clear_engine_calls()
  key(2, 1); drift_metro.event(); tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K2 still held across a tick with the menu closed")
  key(2, 0); assert_equal(context.fileselect.last, nil)
  assert_equal(norns.menu.status(), false, "stub norns.menu.status mirrors _menu.mode")
end)

test("BUFFER K2's release forgets every held key as the file selector opens", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  params:set("v1_source", 4)
  local held_at_enter
  local stub_enter = context.fileselect.enter
  context.fileselect.enter = function(...)
    held_at_enter = {}
    for n, page in pairs(local_value("key_press_page")) do held_at_enter[n] = page end
    return stub_enter(...)
  end
  -- K3 goes down (it records), then K2 is pressed and released while K3 is
  -- still held: the selector opens and takes K3's release
  key(3, 1); key(2, 1); key(2, 0)
  assert_true(context.fileselect.last ~= nil, "K2's release opens the selector")
  assert_true(held_at_enter ~= nil and next(held_at_enter) == nil, "no key is held when the selector opens")
  assert_equal(next(local_value("key_press_page")), nil, "and none afterwards")
  assert_equal(local_value("buffer_saved_during_k2"), false, "the K2-save flag is clear")
end)

test("BUFFER K2 loads a file with no fileselect global: the script requires it (issue #10)", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  assert_equal(rawget(_G, "fileselect"), nil, "norns has no fileselect global")
  params:set("v1_source", 2)  -- voice 1 reads buffer 1
  context.clear_engine_calls()
  tap(2); assert_true(context.fileselect.last ~= nil, "K2's release opens the selector")
  context.fileselect.close("/tmp/picked.wav")
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "the chosen file loads")
  assert_equal(loads[1].args[1], 0); assert_equal(loads[1].args[2], "/tmp/picked.wav")
end)

test("Strata's page never draws over the open file selector; redraws draw the selector (issue #10)", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  params:set("v1_source", 2)
  local draws = 0  -- Strata's page draws (the stub's fileselect.redraw draws nothing)
  local update = screen.update
  screen.update = function() draws = draws + 1; return update() end
  local selector = context.fileselect
  -- opening it on K2's release: fs.enter's redraw() (from norns.menu.init)
  -- and key()'s redraw draw the selector, not the page
  key(2, 1); draws = 0
  key(2, 0); assert_true(selector.last ~= nil, "K2's release opens the selector")
  assert_equal(draws, 0, "the page does not draw over the selector as it opens")
  assert_equal(selector.redraws, 3, "menu.init's redraw, fs.enter's own and key()'s draw the selector")
  -- the norns menu opened and closed over it (K1 twice): set_mode(false)
  -- clears the screen and calls redraw(), which must show the selector again
  selector.redraws = 0
  _menu.set_mode(true); _menu.set_mode(false); redraw()
  assert_equal(selector.redraws, 1, "norns' redraw() as the menu closes draws the selector")
  assert_equal(draws, 0, "and not Strata's page")
  -- Strata's own redraws (a buffer report, page turns, a load) while it is open
  selector.redraws = 0
  context.polls.fire("bufferState", 305)
  enc(1, -1); enc(1, 1)
  load_buffer(5, "/tmp/other.wav")
  assert_equal(draws, 0, "the page does not draw over the selector while it is open")
  assert_true(selector.redraws > 0, "they draw the selector instead")
  -- cancelled: fs.exit's redraw() comes before the callback; then one redraw
  context.clear_engine_calls()
  context.fileselect.close()
  assert_equal(draws, 1, "a cancel redraws once")
  assert_equal(#context.calls_named("loadBuffer"), 0, "a cancel loads nothing")
  assert_equal(PAGE_TITLES[local_value("ui_page")], "BUFFER")
  redraw(); assert_equal(draws, 2, "the script draws again after a cancel")
  -- a chosen file: loads it, then one redraw
  tap(2); assert_equal(draws, 3, "only K2's press draws as the selector opens again")
  draws = 0
  context.fileselect.close("/tmp/chosen.wav")
  assert_equal(draws, 1, "a chosen file redraws once")
  assert_equal(#context.calls_named("loadBuffer"), 1, "and loads")
  redraw(); assert_equal(draws, 2, "the script draws again after a choice")
  screen.update = update
end)

test("opening the norns menu forgets held keys at once; cleanup restores _menu.set_mode", function()
  local stub_set_mode
  local context = load_strata({ before_init = function() stub_set_mode = _menu.set_mode end })
  context.clock.advance(); show_page(4)
  assert_true(_menu.set_mode ~= stub_set_mode, "init watches _menu.set_mode")
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)
  context.clear_engine_calls(); context.fileselect.last = nil
  -- K2 down, then K1 opens and closes the menu between two 10 Hz ticks
  key(2, 1)
  _menu.set_mode(true)
  assert_equal(norns.menu.status(), true, "the wrapped set_mode still opens the menu")
  assert_equal(local_value("key_press_page")[2], nil, "the held K2 is forgotten as the menu opens")
  _menu.set_mode(false)
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  -- a K2+K3 save, then the menu: the next K2 tap opens the selector
  tap(3)  -- stop the recording
  context.polls.fire("bufferState", 202)  -- the engine reports the 2 s take
  key(2, 1); tap(3); assert_equal(#context.calls_named("saveBuffer"), 1)
  _menu.set_mode(true); _menu.set_mode(false)
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the selector")
  -- closing the menu forgets nothing (only an opening does)
  key(2, 1); _menu.set_mode(false)
  assert_equal(local_value("key_press_page")[2], 4, "set_mode(false) keeps a held key")
  key(2, 0)
  -- cleanup gives norns its own set_mode back
  cleanup()
  assert_equal(_menu.set_mode, stub_set_mode, "cleanup restores set_mode")
  -- something that wrapped set_mode after Strata keeps its wrapper; Strata's goes inert
  stub_set_mode = nil
  context = load_strata({ before_init = function() stub_set_mode = _menu.set_mode end })
  local strata_set_mode = _menu.set_mode
  local mod_set_mode = function(mode) strata_set_mode(mode) end
  _menu.set_mode = mod_set_mode
  cleanup()
  assert_equal(_menu.set_mode, mod_set_mode, "a later wrapper is left in place")
  show_page(4); key(2, 1)
  _menu.set_mode(true)
  assert_equal(norns.menu.status(), true, "the inert wrapper still passes the call on")
  assert_equal(local_value("key_press_page")[2], 4, "and no longer touches the script's keys")
  _menu.set_mode(false)
end)

test("key releases reach only the BUFFER page; other pages act once per press", function()
  local context = load_strata(); context.clock.advance()
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(2)
  show_page(1)
  key(3, 1); assert_true(local_value("frozen")[2], "K3 press freezes on MAIN")
  key(3, 0); assert_true(local_value("frozen")[2], "K3 release does not unfreeze")
  show_page(2)
  local mix = params:get("filter_mix")
  key(3, 1); key(3, 0)
  assert_true(params:get("filter_mix") ~= mix, "FX K3 press bypasses once, the release does not undo it")
  show_page(5); context.clear_engine_calls()
  local saved = 0
  local real_save = save_scenes_to_disk
  save_scenes_to_disk = function() saved = saved + 1 end
  key(3, 1); key(3, 0)
  save_scenes_to_disk = real_save
  assert_equal(saved, 1, "SETUP K3 saves once per press")
end)

test("BUFFER page draws the voice, its source and eight buffer rows", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(6); params:set("v6_source", 3)   -- karplus on buf 2
  load_buffer(2, "/tmp/drone.wav"); context.polls.fire("bufferState", 116)
  load_buffer(5, "/tmp/x.wav"); context.polls.fire("bufferState", 402.5)
  params:set("record_duration", 2); record_buffer(7)
  redraw()
  local left_name, left_source
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == 18 then left_name = entry.text end
    if entry.x == 0 and entry.y == 26 then left_source = entry.text end
  end
  assert_equal(left_name, "KARPLUS"); assert_equal(left_source, "src: buf 2")
  local rows = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.x >= 65 then
      rows[entry.y] = rows[entry.y] or {}
      table.insert(rows[entry.y], entry)
    end
  end
  local row_ys = {}
  for y in pairs(rows) do table.insert(row_ys, y) end
  table.sort(row_ys)
  assert_equal(#row_ys, 8, "eight buffer rows")
  assert_true(row_ys[1] > 8 and row_ys[8] < HINT_ROW_Y - TEXT_HEIGHT + 1, "rows between header and hints")
  local function row_text(slot)
    local parts = {}
    for _, entry in ipairs(texts_on_row(context, row_ys[slot])) do
      if entry.x >= 65 then table.insert(parts, entry.text) end
    end
    return table.concat(parts, " ")
  end
  local function row_level(slot)
    local level
    for _, entry in ipairs(rows[row_ys[slot]]) do
      assert_true(level == nil or level == entry.level, "one level per row")
      level = entry.level
    end
    return level
  end
  assert_equal(row_text(1), "1 empty 0.0s"); assert_equal(row_level(1), 2, "empty buffer dim")
  assert_equal(row_text(2), "2 drone 16.0s"); assert_equal(row_level(2), 15, "the voice's buffer bright")
  assert_equal(row_text(5), "5 x 2.5s"); assert_equal(row_level(5), 8, "loaded buffer")
  assert_equal(row_text(7), "7 empty REC", "REC while recording"); assert_equal(row_level(7), 8)
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save")
  -- the voice's buffer recording: the hint says K3 stops
  record_buffer(2); redraw()
  assert_equal(hint_text(context), "K2:load K3:stop K2+3:save")
  -- not a buffer: the hint says K2 and K3 do nothing
  params:set("v6_source", 1); redraw()
  assert_equal(hint_text(context), "K2:- K3:- E3:source")
  params:set("v6_source", 10); redraw()
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == 26 then assert_equal(entry.text, "src: input") end
  end
end)

test("BUFFER page layout holds for every voice, source and buffer state", function()
  local context = load_strata(); context.clock.advance()
  params:set("mutation_enabled", 1); params:set("master_density", 2.0)
  capture_scene(8); recall_scene(8, 0)
  local _, set_selected = find_upvalue("selected_voice")
  local long_names = { "WWWWWWWWWWWWWWWWWWWW.wav", "a_very_long_field_recording_name.aiff", "MMMM", "x",
    "café_crème_très_longue.wav", "no_extension_but_long" }
  local function set_buffers(state)
    for slot = 1, 8 do
      if state == "empty" then clear_buffer(slot)
      elseif state == "loaded" then
        load_buffer(slot, "/tmp/" .. long_names[(slot - 1) % #long_names + 1])
        context.polls.fire("bufferState", (slot - 1) * 100 + 16)
      elseif state == "recording" then
        clear_buffer(slot); record_buffer(slot)
      end
    end
  end
  for _, state in ipairs({ "empty", "loaded", "recording" }) do
    set_buffers(state)
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      for source = 1, 10 do
        params:set("v" .. voice_idx .. "_source", source)
        show_page(4)
        assert_screen_layout(context, "BUFFER, " .. state .. ", voice " .. voice_idx .. " source " .. source)
      end
    end
  end
end)

test("bufferState poll redraws the screen and the grid's buffer page", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  local device = context.grid.plug(1, 16, 16); context.grid.press(1, 16, 8, 1)
  load_buffer(3, "/tmp/a.wav")
  local refreshes = device.refresh_count
  context.screen.texts = {}
  context.polls.fire("bufferState", 212.5)
  local found = false
  for _, entry in ipairs(context.screen.texts) do if entry.text == "12.5s" then found = true end end
  assert_true(found, "poll redraws the BUFFER page with the new seconds")
  assert_true(device.refresh_count > refreshes, "grid page 4 redrawn")
end)

test("bufferState poll ignores NaN, infinities and out-of-range slots", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  local buffers = local_value("buffers")
  context.polls.fire("bufferState", 304)   -- slot 4 holds 4 s
  local before = deep_copy(buffers)
  for _, value in ipairs({ 0 / 0, math.huge, -math.huge, -1, 800 }) do
    local ok, message = pcall(context.polls.fire, "bufferState", value)
    assert_true(ok, "poll value " .. tostring(value) .. " raises no error: " .. tostring(message))
    for slot = 1, 8 do
      assert_equal(buffers[slot].seconds, before[slot].seconds, "poll value " .. tostring(value) .. ", slot " .. slot .. " seconds")
    end
    assert_equal(rawget(buffers, 0), nil, "no slot 0 after " .. tostring(value))
    assert_equal(rawget(buffers, 9), nil, "no slot 9 after " .. tostring(value))
  end
  redraw(); assert_screen_layout(context, "BUFFER page after bad poll values")
end)

test("arc BUFFER page: buf_pos, buf_rate, record duration and level", function()
  local context = load_strata(); context.clock.advance(); show_page(4)
  local device = context.arc.plug(1)
  params:set("v1_source", 2)
  params:set("v1_buf_pos", 0.5); params:set("v1_buf_rate", 1)
  params:set("record_duration", 8); params:set("record_level", 1)
  context.arc.turn(1, 1, 20); assert_near(params:get("v1_buf_pos"), 0.5 + 20 / 512, 1e-6, "ring 1 buf_pos")
  context.arc.turn(1, 2, 100); assert_true(params:get("v1_buf_rate") > 1, "ring 2 buf_rate")
  context.arc.turn(1, 3, 100); assert_true(params:get("record_duration") > 8, "ring 3 record duration")
  context.arc.turn(1, 4, 100); assert_true(params:get("record_level") > 1, "ring 4 record level")
  local ids = { "v1_buf_pos", "v1_buf_rate", "record_duration", "record_level" }
  for ring, param_id in ipairs(ids) do
    assert_near(device.segments[ring].to, param_fraction(param_id) * math.pi * 2, 1e-9, "ring " .. ring .. " shows " .. param_id)
  end
  assert_equal(device.segments[1].level, 15, "buffer voice: ring 1 bright")
  assert_equal(device.segments[3].level, 12)
  -- a synth voice: rings 1-2 still set its buffer params, drawn dim
  params:set("v1_source", 1); local rate = params:get("v1_buf_rate")
  context.arc.turn(1, 2, 100); assert_true(params:get("v1_buf_rate") > rate, "ring 2 still adjusts buf_rate")
  assert_equal(device.segments[1].level, 4, "not buffer-sourced: ring 1 dim")
  assert_equal(device.segments[2].level, 4, "not buffer-sourced: ring 2 dim")
  assert_equal(device.segments[4].level, 12, "record rings stay lit")
  -- the selected voice follows E2
  enc(2, 1)
  local position = params:get("v2_buf_pos"); local voice1_position = params:get("v1_buf_pos")
  context.arc.turn(1, 1, 20)
  assert_true(params:get("v2_buf_pos") > position, "ring 1 follows the selected voice")
  assert_equal(params:get("v1_buf_pos"), voice1_position, "the previous voice's buf_pos is left alone")
end)

test("grid page 4 buffer rows record, clear and set sources with LED feedback", function()
  local context = load_strata(); context.clock.advance()
  local device = context.grid.plug(1, 16, 16); context.grid.press(1, 16, 8, 1)
  context.grid.press(1, 5, 1, 1); assert_equal(context.calls_named("recordBuffer")[1].args[1], 4)
  assert_equal(device:get_led(5, 1), 15)
  context.grid.press(1, 3, 10, 1); assert_equal(params:get("v2_source"), 3); assert_equal(device:get_led(3, 10), 15)
  context.grid.press(1, 10, 15, 1); assert_equal(params:get("v7_source"), 10)
  context.grid.press(1, 5, 2, 1); assert_equal(context.calls_named("clearBuffer")[1].args[1], 4)
end)

test("grid page 4 buffer LEDs: row 1 state, row 2, source rows, and non-grid changes", function()
  local context = load_strata(); context.clock.advance()
  local device = context.grid.plug(1, 16, 16); context.grid.press(1, 16, 8, 1)
  load_buffer(2, "/tmp/a.wav")              -- loaded, not from the grid
  params:set("record_duration", 2); params:set("buf6_record", 1)  -- recording, from params
  params:set("v1_source", 3)                -- voice 1 on buf 2
  for slot = 1, 8 do
    local expected = slot == 6 and 15 or (slot == 2 and 8 or 2)
    assert_equal(device:get_led(slot, 1), expected, "row 1 buffer " .. slot)
    assert_equal(device:get_led(slot, 2), 4, "row 2 clear " .. slot)
  end
  for voice_idx = 1, 7 do
    local y = 8 + voice_idx
    local source = params:get("v" .. voice_idx .. "_source")
    for x = 1, 10 do
      local expected
      if x == source then expected = 15
      elseif x >= 2 and x <= 9 and x - 1 ~= 2 and x - 1 ~= 6 then expected = 2
      else expected = 4 end
      assert_equal(device:get_led(x, y), expected, "voice " .. voice_idx .. " source col " .. x)
    end
    for x = 11, 16 do assert_equal(device:get_led(x, y), 0, "cols 11-16 dark") end
  end
  -- the selected source wins over "empty"
  params:set("v4_source", 9); assert_equal(device:get_led(9, 12), 15, "selected empty buffer lit 15")
  -- the recording completes: 15 -> 8
  context.clock.advance(); assert_equal(device:get_led(6, 1), 15, "a take waiting for the engine stays lit")
  context.polls.fire("bufferState", 503)  -- the engine reports the take
  assert_equal(device:get_led(6, 1), 8, "finished take shown as loaded")
  clear_buffer(2); assert_equal(device:get_led(2, 1), 2, "cleared buffer dim")
  -- a second row-1 press stops early; row 8 and 16 keep their meaning
  context.grid.press(1, 4, 1, 1); context.grid.press(1, 4, 1, 1)
  assert_equal(#context.calls_named("stopRecord"), 1, "second press stops the recording")
  context.grid.press(1, 3, 16, 1); assert_true(local_value("frozen")[3], "row 16 freezes on page 4")
  context.grid.press(1, 1, 8, 1); assert_true(local_value("pattern_playing"), "row 8 transport on page 4")
  -- the FX faders are still on rows 3-7
  context.grid.press(1, 16, 7, 1); assert_near(params:get("delay_mix"), 1, 1e-6, "row 7 delay mix")
  -- out-of-range columns do nothing
  context.clear_engine_calls()
  context.grid.press(1, 9, 1, 1); context.grid.press(1, 12, 2, 1); context.grid.press(1, 13, 11, 1)
  assert_equal(#context.engine_calls, 0, "columns past the buffers/sources send nothing")
  assert_equal(params:get("v3_source"), 1)
end)

test("input-sourced voices: main param, faders, randomize, mutate and drift use grain params", function()
  local context = load_strata(); context.clock.advance()   -- voice 1 running
  local device = context.arc.plug(1)
  params:set("v1_source", 10)
  assert_equal(main_param_id(1), "v1_grain_size"); assert_equal(main_param_label(1), "size")
  assert_equal(fader_param_ids(1)[1], "v1_grain_size", "first grid fader")
  for _, id in ipairs(fader_param_ids(1)) do
    assert_true(not id:find("_buf_"), id .. ": no buffer faders for input")
  end
  params:set("v1_grain_size", 0.2)
  enc(3, 2); assert_true(params:get("v1_grain_size") > 0.2, "E3 on MAIN moves grain size")
  local size = params:get("v1_grain_size")
  context.arc.turn(1, 2, 200); assert_true(params:get("v1_grain_size") > size, "arc ring 2 moves grain size")
  local param_min, param_max = param_range("v1_grain_size")
  assert_near(device.segments[2].to,
    util.linlin(param_min, param_max, 0, 64, params:get("v1_grain_size")) / 64 * math.pi * 2, 1e-9, "ring 2 shows grain size")
  redraw()
  local value
  for _, entry in ipairs(context.screen.texts) do if entry.x == 65 and entry.y == 50 then value = entry.text end end
  assert_equal(value, string.format("%.2f s", params:get("v1_grain_size")), "MAIN shows grain size")
  -- randomize, mutate and drift leave the synth and buffer params alone
  local synth_before = deep_copy(local_value("voices")[1].params)
  local buffer_before = {}
  for _, key in ipairs({ "buf_pos", "buf_rate", "buf_scan" }) do buffer_before[key] = params:get("v1_" .. key) end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(11)
  local grain_changed = false
  for _ = 1, 10 do
    local grain_before = params:get("v1_grain_size")
    randomize_voice(1); gentle_mutate(); for _ = 1, 10 do drift_update() end
    if params:get("v1_grain_size") ~= grain_before then grain_changed = true end
  end
  assert_true(grain_changed, "grain params still randomize and mutate")
  for key, val in pairs(synth_before) do
    assert_equal(local_value("voices")[1].params[key], val, "input voice keeps synth " .. key)
  end
  for key, val in pairs(buffer_before) do
    assert_equal(params:get("v1_" .. key), val, "input voice keeps " .. key)
  end
  -- buffer voices keep buf_pos
  params:set("v1_source", 2); assert_equal(main_param_id(1), "v1_buf_pos")
  assert_equal(fader_param_ids(1)[1], "v1_buf_pos")
end)

---------------------------------------------------------------------------
-- global LFOs, LFO page
---------------------------------------------------------------------------

-- lfo_depth_<n> is the library's percentage (0-100)
test("LFO modulates around the stored value without writing it, and restores on disable", function()
  local context = load_strata(); context.clock.advance()
  params:set("filter_freq", 1000); params:set("strata_lfo1_dest", 4)   -- filt freq
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.clear_engine_calls(); context.lfo.tick(local_value("lfos")[1], 1.0)   -- scaled = +0.5
  local call = context.calls_named("setFilter")[1]
  assert_near(call.args[1], 1000 + 0.5 * 0.5 * (20000 - 20), 1e-6)
  assert_near(params:get("filter_freq"), 1000, 1e-9, "param value untouched")
  context.clear_engine_calls(); params:set("lfo_1", 1)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000, 1e-6, "disable restores the stored value")
end)

test("main destination follows a voice's source and restores the old param", function()
  local context = load_strata(); context.clock.advance()
  params:set("strata_lfo2_dest", 13)   -- v1 main
  params:set("lfo_depth_2", 100); params:set("lfo_2", 2)
  context.lfo.tick(local_value("lfos")[2], 0.5)
  assert_equal(local_value("lfo_last_dest")[2], "v1_freq")
  params:set("v1_source", 2); context.clear_engine_calls(); context.lfo.tick(local_value("lfos")[2], 0.5)
  local voice_calls = context.calls_named("setVoiceParam")
  assert_equal(voice_calls[1].args[2], "freq"); assert_near(voice_calls[1].args[3], params:get("v1_freq"), 1e-9)
  assert_equal(local_value("lfo_last_dest")[2], "v1_buf_pos")
end)

test("LFO restores the stored value when its depth reaches 0 or its destination changes", function()
  local context = load_strata(); context.clock.advance()
  local lfos = local_value("lfos")
  params:set("delay_mix", 0.2); params:set("strata_lfo1_dest", 9)   -- dly mix
  params:set("lfo_depth_1", 40); params:set("lfo_1", 2)
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)     -- scaled +0.4
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2 + 0.4 * 0.5, 1e-9, "modulated mix")
  context.clear_engine_calls(); params:set("lfo_depth_1", 0)
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9, "depth 0 restores")
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)
  assert_equal(#context.engine_calls, 0, "a depth-0 LFO sends nothing")
  params:set("lfo_depth_1", 40); context.clear_engine_calls()
  context.lfo.tick(lfos[1], 0.0)                                    -- scaled -0.4: clamped at 0
  assert_near(context.calls_named("setDelay")[1].args[3], 0, 1e-9, "modulated value clamps to the range")
  context.clear_engine_calls(); params:set("strata_lfo1_dest", 10)  -- rev mix
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9, "destination change restores the old one")
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)
  assert_equal(#context.calls_named("setDelay"), 0, "old destination left alone")
  assert_near(context.calls_named("setReverb")[1].args[1], util.clamp(params:get("reverb_mix") + 0.2, 0, 1), 1e-9,
    "new destination modulated")
  context.clear_engine_calls(); params:set("strata_lfo1_dest", 1)   -- none
  context.lfo.tick(lfos[1], 1.0)
  assert_near(context.calls_named("setReverb")[1].args[1], params:get("reverb_mix"), 1e-9, "none restores")
  assert_equal(#context.calls_named("setReverb"), 1, "and then sends nothing")
end)

test("LFOs on params of one command, or on one param, do not undo each other", function()
  local context = load_strata(); context.clock.advance()
  local lfos = local_value("lfos")
  params:set("filter_freq", 1000); params:set("filter_res", 0.5)
  params:set("strata_lfo1_dest", 4); params:set("strata_lfo2_dest", 5)   -- filt freq, filt res
  for n = 1, 2 do params:set("lfo_depth_" .. n, 20); params:set("lfo_" .. n, 2) end
  context.lfo.tick(lfos[1], 1.0); context.clear_engine_calls(); context.lfo.tick(lfos[2], 1.0)
  local call = context.calls_named("setFilter")[1]
  assert_near(call.args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "LFO 2 keeps LFO 1's filter freq")
  assert_near(call.args[2], 0.5 + 0.2 * 0.5, 1e-6, "and adds its res")
  -- a user change to res is sent with the modulated freq
  context.clear_engine_calls(); params:set("filter_res", 0.3)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "freq stays modulated")
  -- two LFOs on one destination add up; disabling one leaves the other's offset
  params:set("strata_lfo2_dest", 4)
  context.lfo.tick(lfos[1], 1.0); context.clear_engine_calls(); context.lfo.tick(lfos[2], 1.0)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.4 * 0.5 * 19980, 1e-6, "offsets add")
  context.clear_engine_calls(); params:set("lfo_2", 1)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "LFO 1 still applies")
  -- master density modulation reaches every running voice's grain density
  params:set("strata_lfo1_dest", 2); params:set("master_density", 1)
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)       -- +0.2 * 0.5 * 1.9
  local voices = local_value("voices")
  for _, density_call in ipairs(context.calls_named("setGrainParam")) do
    local voice_idx = density_call.args[1] + 1
    assert_true(voices[voice_idx].active, "only running voices")
    assert_near(density_call.args[3], voices[voice_idx].grain.density * (1 + 0.19), 1e-6, "modulated density")
  end
  assert_true(#context.calls_named("setGrainParam") >= 1, "a running voice got its density")
  assert_near(params:get("master_density"), 1, 1e-9, "master density param untouched")
end)

test("LFO params: library groups, a destination group, labels and resolvers", function()
  load_strata()
  local destinations = local_value("LFO_DESTINATIONS")
  assert_equal(#destinations, 12 + 7 * 8, "12 globals, 8 per voice")
  local expected_ids = { [1] = nil, [2] = "master_density", [3] = "drift_amount", [4] = "filter_freq",
    [5] = "filter_res", [6] = "filter_mix", [7] = "delay_time", [8] = "delay_feedback", [9] = "delay_mix",
    [10] = "reverb_mix", [11] = "reverb_size", [12] = "reverb_damp", [13] = "v1_freq", [14] = "v1_grain_size",
    [15] = "v1_grain_density", [16] = "v1_grain_pitch", [17] = "v1_grain_spread", [18] = "v1_buf_pos",
    [19] = "v1_buf_rate", [20] = "v1_buf_scan", [21] = "v2_index", [68] = "v7_buf_scan" }
  for index = 1, #destinations do
    local resolved = destinations[index].resolve()
    if expected_ids[index] or index == 1 then
      assert_equal(resolved, expected_ids[index], "destination " .. index)
    end
    if resolved then assert_true(params:lookup_param(resolved).controlspec, resolved .. " is a control param") end
    assert_true(stubs.text_width(destinations[index].label) <= 49, destinations[index].label .. " fits its column")
  end
  assert_equal(destinations[13].label, "v1 main")
  local group = params:lookup_param("strata_lfos")
  assert_equal(group.t, params.tGROUP); assert_equal(group.n, 3, "destination group holds the three dests")
  for n = 1, 3 do
    local dest = params:lookup_param("strata_lfo" .. n .. "_dest")
    assert_equal(dest.count, #destinations); assert_equal(params:get("strata_lfo" .. n .. "_dest"), 1, "none")
    assert_equal(params:lookup_param("lfo_group_" .. n).n, 15, "the library's own group")
    assert_equal(params:string("lfo_" .. n), "off", "LFOs start off")
    assert_equal(params:get("lfo_depth_" .. n), 0)
    assert_equal(params:string("lfo_mode_" .. n), "free")
    assert_near(params:get("lfo_free_" .. n), 4, 1e-9, "4 s period")
    assert_equal(params:string("lfo_baseline_" .. n), "from center")
    local lfo = local_value("lfos")[n]
    assert_equal(lfo:get("min"), -1); assert_equal(lfo:get("max"), 1)
  end
end)

test("LFO page: E2 selects, E3 depth in percent, K3 enables, K2 cycles destination", function()
  local context = load_strata(); context.clock.advance()
  show_page(3)
  enc(2, 1); assert_equal(local_value("selected_lfo"), 2)
  enc(2, 5); assert_equal(local_value("selected_lfo"), 3, "clamped to 3 LFOs")
  enc(2, -1)
  enc(3, 7); assert_equal(params:get("lfo_depth_2"), 7, "E3 steps depth by percent")
  key(3, 1); key(3, 0); assert_equal(params:string("lfo_2"), "on")
  key(3, 1); key(3, 0); assert_equal(params:string("lfo_2"), "off")
  key(2, 1); key(2, 0); assert_equal(params:get("strata_lfo2_dest"), 2)
  params:set("strata_lfo2_dest", #local_value("LFO_DESTINATIONS"))
  key(2, 1); key(2, 0); assert_equal(params:get("strata_lfo2_dest"), 1, "K2 wraps to none")
  -- MAIN is untouched by LFO page input
  assert_equal(local_value("selected_voice"), 1)
end)

test("LFO page clock runs only while the page is shown", function()
  local context = load_strata(); context.clock.advance()
  local baseline = context.clock.pending_count()
  show_page(3)
  assert_equal(context.clock.pending_count(), baseline + 1, "page clock started")
  local sleeps = context.clock.sleep_log
  assert_near(sleeps[#sleeps].amount, 1 / 15, 1e-9, "15 fps")
  local redraws = 0
  local real_redraw = redraw
  redraw = function() redraws = redraws + 1; real_redraw() end
  context.clock.advance()
  redraw = real_redraw
  assert_equal(redraws, 1, "each frame redraws")
  show_page(3); assert_equal(context.clock.pending_count(), baseline + 1, "no second clock")
  show_page(4); assert_equal(context.clock.pending_count(), baseline, "leaving the page cancels it")
  show_page(2); show_page(3); show_page(1); assert_equal(context.clock.pending_count(), baseline)
  show_page(3); cleanup()
  assert_equal(context.clock.pending_count(), 0, "cleanup cancels it")
end)

-- The LFO page's waveform, dot and labels for LFO n
local function lfo_row_drawing(context, n)
  local top = 16 + (n - 1) * 15
  local row = { lines = {}, rects = {}, texts = {} }
  for _, line in ipairs(context.screen.lines) do
    if line.y1 >= top and line.y1 <= top + 10 then table.insert(row.lines, line) end
  end
  for _, rect in ipairs(context.screen.rects) do
    if rect.y >= top - 1 and rect.y <= top + 10 then table.insert(row.rects, rect) end
  end
  for _, entry in ipairs(context.screen.texts) do
    if entry.y > top and entry.y <= top + 11 then table.insert(row.texts, entry.text) end
  end
  return row
end

test("LFO page rows: waveform, dot from the last raw value and elapsed period, labels; cleanup stops LFOs", function()
  local context = load_strata(); context.clock.advance()
  local lfos = local_value("lfos")
  context.set_time(100)
  params:set("strata_lfo1_dest", 4); params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(lfos[1], 0.25)
  show_page(3)
  -- three rows, each labelled, and every string inside the screen
  for n = 1, 3 do
    local row = lfo_row_drawing(context, n)
    assert_true(table.concat(row.texts, " "):find("L" .. n, 1, true), "row " .. n .. " labelled L" .. n)
    assert_true(#row.lines >= 63, "row " .. n .. " draws its waveform")
  end
  for _, entry in ipairs(context.screen.texts) do
    local left, right = text_span(entry)
    assert_true(left >= 0 and right <= 128 and entry.y <= 64, "'" .. entry.text .. "' inside the screen")
  end
  -- every drawn shape stays inside its row, rows inside y 14-58
  for _, line in ipairs(context.screen.lines) do
    assert_true(line.y1 >= 14 and line.y2 <= 58 and line.y2 >= 14 and line.y1 <= 58, "line inside y 14-58")
    assert_true(line.x1 >= 12 and line.x2 <= 75, "waveform inside x 12-75")
  end
  local row = lfo_row_drawing(context, 1)
  assert_true(#row.lines >= 63, "64 px waveform ")
  assert_equal(#row.rects, 1, "one dot for a running LFO")
  -- reset to the floor (phase 0.75) at t 100, so at t 100 the dot is at 0.75
  local dot = row.rects[1]
  assert_near(dot.x + 1, 12 + 0.75 * 63, 0.51, "dot x from the phase since the reset")
  assert_near(dot.y + 1, 16 + 10 - 0.25 * 10, 0.51, "dot y from the last raw value")
  assert_true(table.concat(row.texts, " "):find("filt freq"), "destination label")
  assert_true(table.concat(row.texts, " "):find("on 50%%"), "state and depth")
  -- one second later at a 4 s period: a quarter cycle further, wrapped to 0
  context.set_time(101); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12, 0.51, "dot advanced and wrapped")
  -- a period change keeps the phase (like the library), then advances at the new rate
  params:set("lfo_free_1", 2)
  context.set_time(101.5); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.25 * 63, 0.51, "advances at the new period")
  -- the phase offset shifts the dot, the reset trigger restarts it
  params:set("lfo_phase_1", 50); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.75 * 63, 0.51, "phase offset")
  params:set("lfo_phase_1", 0); params:set("lfo_reset_1", 1); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.75 * 63, 0.51, "reset to the floor")
  -- stopped LFOs draw no dot
  assert_equal(#lfo_row_drawing(context, 2).rects, 0, "no dot for a stopped LFO")
  assert_true(table.concat(lfo_row_drawing(context, 2).texts, " "):find("off 0%%"), "stopped LFO shows off")
  -- every shape and every destination label keeps the page apart and inside the screen
  for shape = 1, 6 do
    for n = 1, 3 do params:set("lfo_shape_" .. n, shape) end
    for _, dest in ipairs({ 1, 3, 12, 17, 68 }) do
      params:set("strata_lfo2_dest", dest); params:set("lfo_depth_2", 100); redraw()
      assert_screen_layout(context, "LFO shape " .. shape .. ", dest " .. dest)
      for _, line in ipairs(context.screen.lines) do
        assert_true(line.y1 >= 14 and line.y2 <= 58 and line.y2 >= 14 and line.y1 <= 58, "shape " .. shape .. " inside rows")
      end
    end
  end
  -- cleanup turns a running LFO off
  params:set("lfo_3", 2); cleanup(); assert_equal(params:get("lfo_3"), 1, "cleanup stops LFO 3")
end)

test("arc LFO page: rings 1-3 depth, ring 4 period of the selected LFO", function()
  local context = load_strata(); context.clock.advance()
  local device = context.arc.plug(1)
  show_page(3)
  context.arc.turn(1, 1, 100); assert_equal(params:get("lfo_depth_1"), 10, "ring 1: 10 ticks per percent")
  context.arc.turn(1, 3, 55); assert_equal(params:get("lfo_depth_3"), 5, "whole percents only")
  context.arc.turn(1, 3, 5); assert_equal(params:get("lfo_depth_3"), 6, "remainder carried")
  assert_near(device.segments[1].to, 0.1 * math.pi * 2, 1e-9, "ring 1 shows depth")
  enc(2, 1)   -- LFO 2
  local period = params:get("lfo_free_2")
  context.arc.turn(1, 4, 100); assert_true(params:get("lfo_free_2") > period, "ring 4: free period")
  assert_equal(params:get("lfo_free_1"), 4, "only the selected LFO")
  assert_near(device.segments[4].to, param_fraction("lfo_free_2") * math.pi * 2, 1e-9, "ring 4 shows the period")
  params:set("lfo_mode_2", 1)   -- clocked
  local rate = params:get("lfo_clocked_2")
  context.arc.turn(1, 4, -40); assert_equal(params:get("lfo_clocked_2"), rate - 2, "ring 4: clocked rate, 20 ticks a step")
  assert_near(device.segments[4].to, param_fraction("lfo_clocked_2") * math.pi * 2, 1e-9)
end)

test("arc LFO ring 4 forgets its carried ticks when the selected LFO or its mode changes", function()
  local context = load_strata(); context.clock.advance()
  context.arc.plug(1); show_page(3)
  for n = 1, 3 do params:set("lfo_mode_" .. n, 1) end   -- clocked: 20 ticks a rate step
  local rate_1, rate_2 = params:get("lfo_clocked_1"), params:get("lfo_clocked_2")
  context.arc.turn(1, 4, 15); assert_equal(params:get("lfo_clocked_1"), rate_1, "15 ticks carried for LFO 1")
  enc(2, 1)   -- LFO 2
  context.arc.turn(1, 4, 5)
  assert_equal(params:get("lfo_clocked_2"), rate_2, "LFO 1's carried ticks do not step LFO 2")
  context.arc.turn(1, 4, 15); assert_equal(params:get("lfo_clocked_2"), rate_2 + 1, "20 of its own ticks do")
  -- away and back again also forgets them
  context.arc.turn(1, 4, 15); enc(2, -1); enc(2, 1)
  context.arc.turn(1, 4, 5); assert_equal(params:get("lfo_clocked_2"), rate_2 + 1, "reselecting forgets the carry")
  -- the selected LFO's mode changing forgets them
  context.arc.turn(1, 4, 10)   -- 15 carried
  params:set("lfo_mode_2", 2); params:set("lfo_mode_2", 1)
  context.arc.turn(1, 4, 5); assert_equal(params:get("lfo_clocked_2"), rate_2 + 1, "a mode change forgets the carry")
  -- another LFO's mode changing does not
  context.arc.turn(1, 4, 10)   -- 15 carried
  params:set("lfo_mode_3", 2)
  context.arc.turn(1, 4, 5); assert_equal(params:get("lfo_clocked_2"), rate_2 + 2, "LFO 3's mode leaves LFO 2's carry")
  -- the depth rings keep their own remainders
  context.arc.turn(1, 1, 5); enc(2, 1); context.arc.turn(1, 1, 5)
  assert_equal(params:get("lfo_depth_1"), 1, "ring 1's carry survives a selection change")
end)

test("scenes capture and recall the LFOs; old files load with LFOs off", function()
  local context = load_strata({ data_subdir = "lfo_scenes" }); context.clock.advance()
  params:set("lfo_shape_1", 2); params:set("lfo_mode_1", 1); params:set("lfo_clocked_1", 5)
  params:set("lfo_free_2", 9); params:set("lfo_depth_2", 60); params:set("strata_lfo2_dest", 14)
  params:set("lfo_2", 2)
  capture_scene(1)
  local data = local_value("scenes")[1].data
  assert_equal(data.lfo_shape_1, 2); assert_equal(data.lfo_mode_1, 1); assert_equal(data.lfo_clocked_1, 5)
  assert_near(data.lfo_free_2, 9, 1e-9); assert_equal(data.lfo_depth_2, 60)
  assert_equal(data.strata_lfo2_dest, 14); assert_equal(data.lfo_2, 2)
  params:set("lfo_2", 1); params:set("lfo_depth_2", 0); params:set("strata_lfo2_dest", 1); params:set("lfo_shape_1", 1)
  recall_scene(1, 0)
  assert_equal(params:string("lfo_2"), "on"); assert_equal(params:get("lfo_depth_2"), 60)
  assert_equal(params:get("strata_lfo2_dest"), 14); assert_equal(params:string("lfo_shape_1"), "tri")
  assert_equal(local_value("lfos")[2]:get("enabled"), 1, "recalled LFO runs")
  -- smooth transitions fade depth and free period, switch the rest at the end
  local continuous = {}
  for _, global in ipairs(local_value("SCENE_GLOBAL_PARAMS")) do continuous[global.id] = global.continuous end
  for n = 1, 3 do
    assert_equal(continuous["lfo_depth_" .. n], true); assert_equal(continuous["lfo_free_" .. n], true)
    for _, id in ipairs({ "lfo_" .. n, "lfo_shape_" .. n, "lfo_mode_" .. n, "lfo_clocked_" .. n, "strata_lfo" .. n .. "_dest" }) do
      assert_equal(continuous[id], false, id .. " switches")
    end
  end
  -- invalid option values are rejected
  local bad = deep_copy(local_value("scenes")[1]); bad.data.strata_lfo2_dest = 0.5
  assert_true(not validate_scene(bad), "fractional destination rejected")
  bad.data.strata_lfo2_dest = #local_value("LFO_DESTINATIONS") + 1
  assert_true(not validate_scene(bad), "out-of-range destination rejected")
  -- a scene saved before the LFOs existed recalls them as off with defaults
  local old = deep_copy(local_value("scenes")[1])
  for key in pairs(old.data) do
    if key:find("^lfo_") or key:find("^strata_lfo") then old.data[key] = nil end
  end
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  tab.save({ version = 2, scenes = { old } }, context.data_dir .. "strata/scenes.data")
  load_scenes_from_disk()
  assert_true(local_value("scenes")[1].populated, "pre-LFO scene file loads")
  recall_scene(1, 0)
  assert_equal(params:string("lfo_2"), "off"); assert_equal(params:get("lfo_depth_2"), 0)
  assert_equal(params:get("strata_lfo2_dest"), 1); assert_equal(params:string("lfo_mode_1"), "free")
end)

test("param actions under a running LFO send the modulated value (drift, edits)", function()
  local context = load_strata(); context.clock.advance()
  local lfos = local_value("lfos")
  params:set("v1_source", 2)                                     -- buf 1: the drift moves buf_pos
  params:set("v1_buf_pos", 0.4); params:set("strata_lfo1_dest", 18)  -- v1 pos
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(lfos[1], 1.0)                                 -- scaled +0.5: +0.25 of the range
  math.randomseed(5)
  context.clear_engine_calls(); drift_update()
  local sent
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "bufPos" then sent = call.args[3] end
  end
  assert_true(params:get("v1_buf_pos") ~= 0.4, "the drift moved the stored position")
  assert_near(sent, params:get("v1_buf_pos") + 0.25, 1e-9, "drift sends the position with the LFO offset")
  -- a user edit of a modulated FX param keeps the offset too
  params:set("filter_freq", 1000); params:set("strata_lfo2_dest", 4)
  params:set("lfo_depth_2", 20); params:set("lfo_2", 2); context.lfo.tick(lfos[2], 1.0)
  context.clear_engine_calls(); params:set("filter_freq", 2000)
  assert_near(context.calls_named("setFilter")[1].args[1], 2000 + 0.2 * 0.5 * 19980, 1e-6, "edit keeps the offset")
  -- unmodulated params still send exactly their value
  context.clear_engine_calls(); params:set("filter_res", 0.3)
  assert_near(context.calls_named("setFilter")[1].args[2], 0.3, 1e-9)
end)

test("LFO steps run at 48 ppqn and skip sends below 1/1000 of the range; restores always send", function()
  local context = load_strata(); context.clock.advance()
  local lfos = local_value("lfos")
  for n = 1, 3 do assert_equal(lfos[n]:get("ppqn"), 48, "LFO " .. n .. " ppqn") end
  params:set("filter_mix", 0.5); params:set("strata_lfo1_dest", 6)  -- filt mix (0-1)
  params:set("lfo_free_1", 300); params:set("lfo_depth_1", 100); params:set("lfo_1", 2)
  -- ten seconds of a 300 s sine at 120 BPM: 96 steps a second, from the floor
  local steps = 10 * 96
  context.clear_engine_calls()
  for step = 1, steps do
    context.lfo.tick(lfos[1], (math.sin(2 * math.pi * (0.75 + step / (300 * 96))) + 1) / 2)
  end
  local calls = context.calls_named("setFilter")
  assert_true(#calls >= 5 and #calls <= 15, "a slow LFO sends rarely (" .. #calls .. " of " .. steps .. " steps)")
  for index = 2, #calls do
    assert_true(math.abs(calls[index].args[4] - calls[index - 1].args[4]) >= 0.001 - 1e-12, "each send moves >= 1/1000")
  end
  -- a step below the threshold is skipped, but turning the LFO off restores at once
  local last_sent = calls[#calls].args[4]
  context.clear_engine_calls()
  -- (mix 0.5 at depth 100: the sent mix equals the raw value)
  context.lfo.tick(lfos[1], last_sent + 0.0004)
  assert_equal(#context.calls_named("setFilter"), 0, "tiny step skipped")
  params:set("lfo_1", 1)
  calls = context.calls_named("setFilter")
  assert_equal(#calls, 1, "restore sends"); assert_near(calls[1].args[4], 0.5, 1e-9, "stored mix restored")
  assert_true(last_sent ~= 0.5, "the restore was a change")
  -- a restore sends even when the engine already has the stored value
  params:set("lfo_1", 2); context.lfo.tick(lfos[1], 0.5)        -- scaled 0: value 0.5
  context.clear_engine_calls(); params:set("lfo_depth_1", 0)
  assert_equal(#context.calls_named("setFilter"), 1, "depth 0 restore sends")
  -- a fast LFO sends on every step
  params:set("lfo_depth_1", 100); context.clear_engine_calls()
  for step = 1, 20 do context.lfo.tick(lfos[1], step % 2) end
  assert_equal(#context.calls_named("setFilter"), 20, "large steps all sent")
end)

test("cleanup stops the LFOs and restores their destinations", function()
  local context = load_strata(); context.clock.advance()
  params:set("filter_freq", 800); params:set("strata_lfo1_dest", 4)
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(local_value("lfos")[1], 1.0)
  context.clear_engine_calls(); cleanup()
  assert_equal(params:get("lfo_1"), 1); assert_equal(local_value("lfos")[1]:get("enabled"), 0)
  assert_near(context.calls_named("setFilter")[1].args[1], 800, 1e-6, "destination restored")
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

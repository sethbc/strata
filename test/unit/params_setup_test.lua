-- test/unit/params_setup_test.lua
-- The PARAMS menu: voice, grain, FX, source and buffer params, and the
-- tempo param (lib/params_setup.lua)
-- Run alone: lua test/run.lua params_setup

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local engine_state_for_voice, FX_PARAM_IDS = h.engine_state_for_voice, h.FX_PARAM_IDS

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

test("grain envelope param: options, default, scenes, never mutated or randomized", function()
  local context = load_strata(); finish_startup(context)
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

test("grain mode param: options, default, sync, scenes, never mutated, randomized or crossfaded", function()
  local context = load_strata(); finish_startup(context)
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

test("tempo param drives clock_tempo and grid tempo buttons (I1)", function()
  local context = load_strata({ before_init = function() params:set("clock_tempo", 97) end })
  assert_equal(params:get("tempo"), 97, "tempo initialized from clock_tempo")
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
  assert_true(clock.tempo_change_handler ~= nil, "handler installed")
  cleanup()
  assert_equal(clock.tempo_change_handler, nil, "cleanup restores the previous handler")
end)

test("the tempo param has clock_tempo's range: a 30 BPM scene recalls at 30 (#48)", function()
  local context = load_strata({ before_init = function() params:set("clock_tempo", 30) end })
  local clock_min, clock_max = param_range("clock_tempo")
  local tempo_min, tempo_max = param_range("tempo")
  assert_equal(tempo_min, clock_min, "tempo minimum is clock_tempo's")
  assert_equal(tempo_max, clock_max, "tempo maximum is clock_tempo's")
  assert_equal(params:get("tempo"), 30, "tempo initialized from a 30 BPM clock")
  capture_scene(1)
  assert_equal(local_value("scenes")[1].data.tempo, 30, "the scene captured 30 BPM")
  params:set("tempo", 100)
  recall_scene(1)
  assert_equal(params:get("clock_tempo"), 30, "recall sets the clock to 30 BPM")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 13, 8, 1)  -- page 1
  context.grid.press(1, 7, 8, 1)   -- +1 BPM
  assert_equal(params:get("clock_tempo"), 31, "grid +1 steps from 30 BPM")
  params:set("clock_tempo", clock_min)
  assert_equal(params:get("tempo"), clock_min, "the param follows the clock down to its minimum")
  context.grid.press(1, 6, 8, 1)   -- -1 BPM
  assert_equal(params:get("tempo"), clock_min, "grid -1 at the minimum keeps the tempo param there")
  assert_equal(params:get("clock_tempo"), clock_min, "and the clock")
  -- an external source's tempo reaches the handler unclamped
  clock.tempo_change_handler(clock_max + 100)
  assert_equal(params:get("tempo"), clock_max, "the param clamps to the clock's maximum")
end)

test("the tempo handler is installed once and cleanup restores only its own (#48)", function()
  local previous_calls, previous_bpm = 0, nil
  local function previous_handler(bpm) previous_calls = previous_calls + 1; previous_bpm = bpm end
  load_strata({ before_init = function() clock.tempo_change_handler = previous_handler end })
  local strata_handler = clock.tempo_change_handler
  assert_true(strata_handler ~= previous_handler, "the script's handler is installed")
  install_tempo_change_handler()                               -- installed again (init run twice)
  assert_equal(clock.tempo_change_handler, strata_handler, "a second install changes nothing")
  params:set("clock_tempo", 90)
  assert_equal(params:get("tempo"), 90, "the param follows the clock")
  assert_equal(previous_calls, 1, "the previous handler is still called, once per change")
  assert_equal(previous_bpm, 90, "with the bpm")
  cleanup()
  assert_equal(clock.tempo_change_handler, previous_handler, "cleanup restores the handler found at init")
  -- a handler installed after the script's (another library's) is left alone
  load_strata()
  local later_handler = function() end
  clock.tempo_change_handler = later_handler
  cleanup()
  assert_equal(clock.tempo_change_handler, later_handler, "cleanup keeps a handler installed after the script's")
end)

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
  -- then the registered fx params (lib/voice_mix.lua's two bypass params)
  assert_equal(params.params[group_index].n, #FX_PARAM_IDS + 2, "group size")
  for offset, param_id in ipairs(FX_PARAM_IDS) do
    assert_equal(params.params[group_index + offset].id, param_id, "group entry " .. offset)
  end
  assert_true(not params.lookup["strata_reverb"], "the reverb separator is replaced by the group")
  -- every scene global carries its param's default (tempo follows clock_tempo)
  local in_scene = {}
  for _, global in ipairs(local_value("SCENE_GLOBAL_PARAMS")) do
    in_scene[global.id] = global
    assert_true(type(global.default) == "number", global.id .. " has a default")
    -- (old scene files without LFO depths keep silent LFOs: 0, not the 25% the params start at)
    if global.id ~= "tempo" and not global.id:find("^lfo_depth_") then
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


-- #315: each voice param's range, warp and step, held in one table
local VOICE_PARAM_SPECS = {
  freq = {20, 2000, "exp", 0}, amp = {0, 1, "lin", 0.01}, pan = {-1, 1, "lin", 0.01},
  rq = {0.01, 1, "lin", 0.01}, noise = {0, 1, "lin", 0.01}, mod1 = {0.01, 1, "lin", 0.01},
  mod2 = {0.01, 1, "lin", 0.01}, ratio = {0.5, 8, "lin", 0.001}, index = {0, 10, "lin", 0.1},
  modFreq = {0.01, 1, "lin", 0.01}, fold = {0.1, 5, "lin", 0.1}, mod = {0.01, 2, "lin", 0.01},
  drift = {0.001, 0.1, "lin", 0.001}, width = {0.05, 0.95, "lin", 0.01}, cutoff = {100, 8000, "exp", 10},
  res = {0.1, 1, "lin", 0.01}, decay = {0.5, 10, "lin", 0.1}, damping = {0.1, 0.9, "lin", 0.01},
  excite = {0.1, 2, "lin", 0.01}, brightness = {0, 1, "lin", 0.01},
}

test("every voice param has its own spec: range, warp and step", function()
  load_strata()
  local voices = local_value("voices")
  for voice_idx = 1, 7 do
    for _, key in ipairs(voices[voice_idx].param_order) do
      local want = VOICE_PARAM_SPECS[key]
      assert_true(want ~= nil, "the table holds " .. key)
      local spec = params:lookup_param("v" .. voice_idx .. "_" .. key).controlspec
      assert_near(spec.minval, want[1], 1e-9, key .. " minimum")
      assert_near(spec.maxval, want[2], 1e-9, key .. " maximum")
      assert_near(spec.step, want[4], 1e-9, key .. " step")
      local midpoint = spec:map(0.5)
      local linear_midpoint = (want[1] + want[2]) / 2
      assert_equal(math.abs(midpoint - linear_midpoint) > 0.02 * (want[2] - want[1]), want[3] == "exp", key .. " warp " .. want[3])
    end
  end
end)

test("a voice's params follow param_order between its heading and its granular separator", function()
  load_strata()
  local voices = local_value("voices")
  for voice_idx = 1, 7 do
    local prefix = "v" .. voice_idx .. "_"
    local first, last
    for index, param in ipairs(params.params) do
      if param.t == params.tSEPARATOR and param.name == "voice " .. voice_idx .. ": " .. voices[voice_idx].name then
        first = index
      end
      if param.t == params.tSEPARATOR and param.name == "voice " .. voice_idx .. " granular" then last = index end
    end
    assert_true(first and last and first < last, "voice " .. voice_idx .. " has its two separators")
    local positions = {}
    for _, key in ipairs(voices[voice_idx].param_order) do
      for index = first, last do
        if params.params[index].id == prefix .. key then positions[#positions + 1] = index end
      end
    end
    assert_equal(#positions, #voices[voice_idx].param_order, "voice " .. voice_idx .. " lists every key between them")
    for index = 2, #positions do
      assert_true(positions[index] > positions[index - 1], "voice " .. voice_idx .. " follows param_order")
    end
  end
end)

test("get_param_spec refuses a name it has no spec for", function()
  load_strata()
  assert_true(not pcall(get_param_spec, "nonexistent"), "an unknown name is an error")
  assert_true(pcall(get_param_spec, "rq"), "a known name is fine")
end)

test("get_param_spec makes at most one controlspec per call (#389)", function()
  load_strata()
  local made, calls, real_new = 0, 0, controlspec.new
  controlspec.new = function(...) made = made + 1; return real_new(...) end
  local ok, err = pcall(function()
    for key in pairs(VOICE_PARAM_SPECS) do get_param_spec(key); calls = calls + 1 end
  end)
  controlspec.new = real_new
  assert_true(ok, tostring(err))
  assert_true(made <= calls, "at most one spec per call: " .. made .. " for " .. calls)
  -- the returned spec is the caller's own: changing its default changes no later call's
  local first = get_param_spec("amp")
  first.default = 0.77
  assert_near(get_param_spec("amp").default, 0.3, 1e-9, "a changed default stays with that copy")
end)

test("PARAMS separators show names, not ids (#388)", function()
  load_strata()
  assert_equal(params:lookup_param("strata_mutations").name, "mutations")
  assert_equal(params:lookup_param("strata_scenes").name, "scenes")
end)

test("drift and ratio show every step; grain size, decay and the rates carry units (#386, #387)", function()
  load_strata()
  params:set("v4_drift", 0.021)
  assert_equal(params:string("v4_drift"), "0.021", "the Sub's drift shows three decimals")
  params:set("v4_drift", 0.022)
  assert_equal(params:string("v4_drift"), "0.022")
  params:set("drift_amount", 0.012)
  assert_equal(params:string("drift_amount"), "0.012", "tape drift shows three decimals")
  params:set("v1_grain_size", 0.1)
  assert_equal(params:string("v1_grain_size"):sub(-2), " s", "grain size is in seconds: " .. params:string("v1_grain_size"))
  assert_equal(params:string("v6_decay"):sub(-2), " s", "decay is in seconds")
  assert_equal(params:string("v1_mod_speed"):sub(-3), " Hz", "mod speed is in hertz")
  assert_equal(params:string("v6_excite"):sub(-3), " Hz", "excite is in hertz")
  assert_equal(params:string("v1_mod1"):sub(-3), " Hz", "mod1 is in hertz")
  assert_equal(params:string("v1_mod2"):sub(-3), " Hz", "mod2 is in hertz")
  assert_equal(params:string("v2_modFreq"):sub(-3), " Hz", "modFreq is in hertz")
end)

test("the tempo handler's previous handler is no global (#394)", function()
  load_strata({ before_init = function() clock.tempo_change_handler = function() end end })
  assert_true(rawget(_G, "previous_tempo_change_handler") == nil, "kept local to the module")
end)

-- lib/constants.lua's text with NUM_MOD_SLOTS set to slots
local function constants_with_mod_slots(slots)
  local file = assert(io.open(h.repo_root .. "/lib/constants.lua"))
  local source = file:read("*a")
  file:close()
  local patched, count = source:gsub("local NUM_MOD_SLOTS = 3", "local NUM_MOD_SLOTS = " .. slots)
  assert(count == 1, "lib/constants.lua sets NUM_MOD_SLOTS once")
  return patched
end

-- The ids of voice_idx's params after its cross-modulation separator, up to
-- its mod speed, in menu order
local function crossmod_menu(voice_idx)
  local ids, inside = {}, false
  for _, param in ipairs(params.params) do
    if param.t == params.tSEPARATOR and param.name == "voice " .. voice_idx .. " cross-modulation" then
      inside = true
    elseif inside then
      table.insert(ids, param.id)
      if param.id == "v" .. voice_idx .. "_mod_speed" then break end
    end
  end
  return ids
end

-- The cross-modulation params are one loop over NUM_MOD_SLOTS, as the
-- voice sync, the VOICE rows and the scenes are (#392)
test("the crossmod params follow NUM_MOD_SLOTS, as the voice sync does (#392)", function()
  local context = load_strata({ module_sources = { ["lib/constants"] = constants_with_mod_slots(2) } })
  finish_startup(context)
  assert_equal(table.concat(crossmod_menu(4), " "), "v4_mod_source_1 v4_mod_amp_amt_1 v4_mod_freq_amt_1 "
    .. "v4_mod_source_2 v4_mod_amp_amt_2 v4_mod_freq_amt_2 v4_mod_speed", "two slots in the menu")
  assert_equal(params.lookup["v4_mod_source_3"], nil, "no third slot")
  context.clear_engine_calls()
  toggle_voice(4)
  local slots = {}
  for _, call in ipairs(context.calls_named("setModSource")) do table.insert(slots, call.args[2]) end
  assert_equal(table.concat(slots, " "), "1 2", "a start sends the two slots")
  context.clear_engine_calls()
  params:set("v4_mod_amp_amt_2", 0.5); params:set("v4_mod_freq_amt_2", -0.5); params:set("v4_mod_source_2", 6)
  assert_equal(table.concat(context.calls_named("setModAmpAmt")[1].args, " "), "3 2 0.5", "slot 2's amp mod")
  assert_equal(table.concat(context.calls_named("setModFreqAmt")[1].args, " "), "3 2 -0.5", "slot 2's freq mod")
  assert_equal(table.concat(context.calls_named("setModSource")[1].args, " "), "3 2 5",
    "slot 2's source: voice 6 as engine voice 5")
end)

-- The three slots' params as the menu has always had them (saved PSETs and
-- the params tests hold them): ids, names, kinds, ranges, defaults, the
-- source's text and each one's engine call
test("each crossmod slot has its source, amp mod and freq mod params, sent to its slot (#392)", function()
  local context = load_strata(); finish_startup(context)
  assert_equal(table.concat(crossmod_menu(2), " "), "v2_mod_source_1 v2_mod_amp_amt_1 v2_mod_freq_amt_1 "
    .. "v2_mod_source_2 v2_mod_amp_amt_2 v2_mod_freq_amt_2 v2_mod_source_3 v2_mod_amp_amt_3 v2_mod_freq_amt_3 "
    .. "v2_mod_speed", "three slots, then the speed")
  local voices = local_value("voices")
  assert_true(voices[2].active, "voice 2 runs")
  for slot = 1, 3 do
    local source_id = "v2_mod_source_" .. slot
    local source = params:lookup_param(source_id)
    assert_equal(source.t, params.tNUMBER, source_id .. " is a number")
    assert_equal(source.name, "mod source " .. slot)
    assert_equal(source.min, 0, source_id .. " min"); assert_equal(source.max, 7, source_id .. " max")
    assert_equal(source.default, 0, source_id .. " default")
    assert_equal(params:string(source_id), "none", source_id .. " text at 0")
    for _, kind in ipairs({ { "amp", "amp mod " }, { "freq", "freq mod " } }) do
      local amount_id = "v2_mod_" .. kind[1] .. "_amt_" .. slot
      local amount = params:lookup_param(amount_id)
      assert_equal(amount.t, params.tCONTROL, amount_id .. " is a control")
      assert_equal(amount.name, kind[2] .. slot)
      local spec = amount.controlspec
      assert_equal(spec.minval, -2, amount_id .. " min"); assert_equal(spec.maxval, 2, amount_id .. " max")
      assert_equal(spec.warp_name, "lin", amount_id .. " warp")
      assert_equal(spec.step, 0.01, amount_id .. " step"); assert_equal(spec.default, 0, amount_id .. " default")
    end
    context.clear_engine_calls()
    params:set(source_id, 3)
    assert_equal(params:string(source_id), "voice 3", source_id .. " text at 3")
    params:set("v2_mod_amp_amt_" .. slot, 1.25); params:set("v2_mod_freq_amt_" .. slot, -0.75)
    assert_equal(table.concat(context.calls_named("setModSource")[1].args, " "), "1 " .. slot .. " 2")
    assert_equal(table.concat(context.calls_named("setModAmpAmt")[1].args, " "), "1 " .. slot .. " 1.25")
    assert_equal(table.concat(context.calls_named("setModFreqAmt")[1].args, " "), "1 " .. slot .. " -0.75")
    local slot_state = voices[2].crossmod["slot" .. slot]
    assert_equal(slot_state.source, 3); assert_equal(slot_state.amp_amt, 1.25); assert_equal(slot_state.freq_amt, -0.75)
  end
  -- a stopped voice's slot is stored, not sent
  assert_true(not voices[5].active, "voice 5 is stopped")
  context.clear_engine_calls()
  params:set("v5_mod_source_2", 4); params:set("v5_mod_amp_amt_2", 1); params:set("v5_mod_freq_amt_2", 1)
  assert_equal(#context.engine_calls, 0, "nothing sent for a stopped voice")
  assert_equal(voices[5].crossmod.slot2.source, 4); assert_equal(voices[5].crossmod.slot2.amp_amt, 1)
end)

test("a tempo change from an external clock redraws SEQ and the arc (#383)", function()
  local context = load_strata(); finish_startup(context)
  h.show_page("SEQ")
  local arc_device = context.arc.plug(1)
  params:set("tempo", 130)
  h.next_frame(context)
  assert_true(h.screen_shows(context, "130 bpm"), "SEQ shows the tempo")
  local refreshes = arc_device.refresh_count
  -- what norns' clock loop does for an external source: silent clock_tempo, then the handler
  params:set("clock_tempo", 100, true)
  clock.tempo_change_handler(100)
  h.next_frame(context)
  assert_true(h.screen_shows(context, "100 bpm"), "the next frame draws the new tempo")
  assert_true(arc_device.refresh_count > refreshes, "and the arc")
  -- a handler call that changes nothing asks for nothing
  local pages = local_value("S").constants.UI_PAGES
  pages.screen_dirty = false
  clock.tempo_change_handler(100)
  assert_true(not pages.screen_dirty, "an unchanged tempo requests no redraw")
end)

end

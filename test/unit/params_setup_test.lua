-- test/unit/params_setup_test.lua
-- The PARAMS menu: voice, grain, FX, source and buffer params, and the
-- tempo param (lib/params_setup.lua)
-- Run alone: lua test/run.lua params_setup

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local engine_state_for_voice, FX_PARAM_IDS = h.engine_state_for_voice, h.FX_PARAM_IDS

-- 3.8 (package 0d): every type's synth key is a menu param of every voice,
-- the voice's own type's in its param_order first, each default the type
-- record's
test("every voice param has a menu param, ordered by param_order", function()
  load_strata()
  local voices, types = local_value("voices"), local_value("S").lib.types
  for voice_idx = 1, 7 do
    local voice = voices[voice_idx]
    local record = types.of(voice_idx)
    local previous = 0
    for _, key in ipairs(voice.param_order) do
      local param = params:lookup_param("v" .. voice_idx .. "_" .. key)
      assert_near(param.controlspec.default, record.defaults[key], 1e-9,
        "voice " .. voice_idx .. " " .. key .. " default comes from its type's record")
      assert_true(params.lookup[param.id] > previous, "voice " .. voice_idx .. " " .. key .. " in param_order")
      previous = params.lookup[param.id]
    end
    for _, key in ipairs(types.keys()) do
      assert_true(params.lookup["v" .. voice_idx .. "_" .. key] ~= nil, "voice " .. voice_idx .. " has " .. key)
      assert_true(voice.values[key] ~= nil, "voice " .. voice_idx .. " holds " .. key)
    end
  end
end)

-- 3.8 1c (design §4.1, §4.4): the grain envelope is gone, no param and no
-- scene key; the cloud is the grain's option now: its options, default,
-- discrete scene key, the fill of a scene without it, its validation, and
-- no mutation or randomize moves it
test("grain_env is gone; the grain cloud param: options, default, scenes, never mutated or randomized", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, 7 do
    assert_equal(params.lookup["v" .. voice_idx .. "_grain_env"], nil, "voice " .. voice_idx .. " has no grain_env")
    assert_equal(S.voices[voice_idx].values.grain_env, nil, "and holds none")
    local param = params:lookup_param("v" .. voice_idx .. "_grain_cloud")
    assert_equal(param.t, params.tOPTION, "voice " .. voice_idx .. " grain_cloud is an option")
    assert_equal(param.count, 2, "two clouds")
    assert_equal(params:get("v" .. voice_idx .. "_grain_cloud"), 1, "default density")
    assert_equal(S.voices[voice_idx].values.grain_cloud, 1, "voices table holds the index")
  end
  local names = {}
  for index = 1, 2 do params:set("v1_grain_cloud", index); names[index] = params:string("v1_grain_cloud") end
  assert_equal(table.concat(names, ","), "density,overlap")
  params:set("v1_grain_cloud", 1)
  -- the scene key's default is its param's, and it is discrete
  for voice_idx = 1, 7 do
    local _, by_key = S.lib.params_setup.voice_scene_keys(voice_idx)
    assert_equal(by_key.grain_env, nil, "voice " .. voice_idx .. ": no grain_env scene key")
    assert_equal(by_key.grain_cloud.default, 1, "voice " .. voice_idx .. " grain_cloud scene default: density")
    assert_equal(table.concat(by_key.grain_cloud.range, ","), "1,2", "two clouds")
  end
  -- a scene without the cloud is filled with density
  params:set("v2_grain_cloud", 2)
  capture_scene(3)
  local scene = local_value("scenes")[3]
  for voice_idx = 1, 7 do scene.data.voices[voice_idx].values.grain_cloud = nil end
  fill_scene(scene)
  assert_equal(scene.data.voices[2].values.grain_cloud, 1, "a missing cloud fills to density")
  assert_true(validate_scene(scene), "the filled scene validates")
  scene.data.voices[2].values.grain_cloud = 1.5
  assert_true(not validate_scene(scene), "a fractional cloud index is rejected")
  scene.data.voices[2].values.grain_cloud = 0
  assert_true(not validate_scene(scene), "cloud index 0 is rejected")
  scene.data.voices[2].values.grain_cloud = 1
  -- mutation and randomize leave the cloud alone
  for voice_idx = 1, 7 do
    if not S.voices[voice_idx].active then toggle_voice(voice_idx) end
    params:set("v" .. voice_idx .. "_grain_cloud", 2)
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(5)
  for _ = 1, 50 do gentle_mutate() end
  for voice_idx = 1, 7 do randomize_voice(voice_idx) end
  for voice_idx = 1, 7 do
    assert_equal(params:get("v" .. voice_idx .. "_grain_cloud"), 2, "voice " .. voice_idx .. " cloud unchanged")
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
    assert_equal(voices[voice_idx].values.grain_mode, 1, "voices table holds the index")
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
  local _, by_key = local_value("S").lib.params_setup.voice_scene_keys(1)
  assert_equal(by_key.grain_mode.default, params:lookup_param("v1_grain_mode").default, "scene default = param default")
  assert_equal(table.concat(by_key.grain_mode.range, ","), "1,2", "two modes")
  capture_scene(1); params:set("v1_grain_mode", 1)
  for _, target in ipairs(scene_transition_targets(local_value("scenes")[1].data)) do
    assert_true(not target.id:find("_grain_mode$"), target.id .. " is not crossfaded")
  end
  recall_scene(1, 0); assert_equal(params:get("v1_grain_mode"), 2, "scene recall restores the mode")
  local scene = local_value("scenes")[1]
  for voice_idx = 1, 7 do scene.data.voices[voice_idx].values.grain_mode = nil end
  fill_scene(scene)
  assert_equal(scene.data.voices[1].values.grain_mode, 1, "missing mode migrates to continuous")
  assert_true(validate_scene(scene), "migrated scene validates")
  scene.data.voices[1].values.grain_mode = 3
  assert_true(not validate_scene(scene), "a mode index past the options is rejected")
  scene.data.voices[1].values.grain_mode = 1.5
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
  context.grid.press(1, 2, 16, 1)  -- T+ (row 16): +1 BPM
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
  context.grid.press(1, 2, 16, 1)  -- T+
  assert_equal(params:get("clock_tempo"), 151, "grid +1 steps from the external tempo")
  params:set("clock_tempo", 200)
  context.grid.press(1, 1, 16, 1)  -- T-
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
  context.grid.press(1, 2, 16, 1)  -- T+: +1 BPM
  assert_equal(params:get("clock_tempo"), 31, "grid +1 steps from 30 BPM")
  params:set("clock_tempo", clock_min)
  assert_equal(params:get("tempo"), clock_min, "the param follows the clock down to its minimum")
  context.grid.press(1, 1, 16, 1)  -- T-: -1 BPM
  assert_equal(params:get("tempo"), clock_min, "grid -1 at the minimum keeps the tempo param there")
  assert_equal(params:get("clock_tempo"), clock_min, "and the clock")
  -- an external source's tempo reaches the handler unclamped
  clock.tempo_change_handler(clock_max + 100)
  assert_equal(params:get("tempo"), clock_max, "the param clamps to the clock's maximum")
end)

-- #567: what is timed from the tempo right after a change. On the internal
-- clock the clock_tempo param sets the clock at once, while
-- clock.get_tempo() reads the old tempo until the clock has ticked twice.
-- On Link the param is a whole BPM that norns refreshes from the session
-- once a second, so a fractional session or a peer's change would be off:
-- beat_seconds_now (take lengths, sync delays) reads the clock there, as
-- under MIDI or crow. clock_tempo_now (the 256's flash) shows the tempo a
-- key set, the param, on the internal clock and Link
test("beat_seconds_now: the param only on the internal clock; clock_tempo_now: the param on internal and Link (#567)", function()
  local context = load_strata(); finish_startup(context)
  local params_setup = local_value("S").lib.params_setup
  for _, source in ipairs({2, 4}) do   -- midi, crow
    params:set("clock_source", source)
    clock.tempo = 90                    -- the external source's tempo; the param stays 120
    local name = params:string("clock_source")
    assert_equal(params_setup.clock_tempo_now(), 90, name .. ": the clock's tempo")
    assert_near(params_setup.beat_seconds_now(), 60 / 90, 1e-9, name .. ": the clock's beat")
  end
  params:set("clock_source", 3)   -- link
  clock.tempo = 123.45            -- the session's tempo; the whole param reads 120
  assert_equal(params:get("clock_tempo"), 120, "link: the param stays a whole 120")
  assert_equal(params_setup.clock_tempo_now(), 120, "link: the flash shows the param")
  assert_near(params_setup.beat_seconds_now(), 60 / 123.45, 1e-12, "link: a beat of the session's 123.45 BPM")
  params:set("clock_source", 1)   -- internal
  clock.tempo = 120
  params:set("clock_tempo", 60)
  assert_equal(clock.get_tempo(), 120, "the internal clock still reports 120")
  assert_equal(params_setup.clock_tempo_now(), 60, "internal: the param")
  assert_equal(params_setup.beat_seconds_now(), 1.0, "internal: a beat of 1 s at 60 BPM")
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
  -- then the registered fx params (lib/voice_mix.lua's two bypass params
  -- and its delay to reverb, lib/delay_sync.lua's sync, division and
  -- ping-pong, 3.8's lib/fx_hold.lua's delay freeze and clear and
  -- lib/shimmer.lua's interval and two amounts)
  assert_equal(params.params[group_index].n, #FX_PARAM_IDS + 2 + 1 + 3 + 2 + 3, "group size")
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

-- 3.8 (design §7.1): the returns are levels, and the reverb's starts at
-- 0.43 (3.7's 0.3 / 0.7) so a default start sounds as 3.7.0's
test("the reverb's level starts at 0.43 and is named reverb level", function()
  load_strata()
  assert_near(params:get("reverb_mix"), 0.43, 1e-9, "the reverb's level starts at 0.43")
  assert_near(params:lookup_param("reverb_mix").controlspec.default, 0.43, 1e-9, "its spec's default")
  assert_equal(params:lookup_param("reverb_mix").name, "reverb level", "the reverb's return is named its level")
  assert_equal(params:lookup_param("delay_mix").name, "delay level", "and the delay's")
  local global
  for _, entry in ipairs(local_value("SCENE_GLOBAL_PARAMS")) do if entry.id == "reverb_mix" then global = entry end end
  assert_near(global.default, 0.43, 1e-9, "its scene default")
end)

test("source and buffer params: options, defaults, voices table, labels", function()
  load_strata()
  local voices = local_value("voices")
  local names = {}
  -- (3.8, package 1d: the voices' output rings after the input)
  local C = local_value("S").constants
  for index = 1, #C.SOURCE_OPTIONS do params:set("v1_source", index); names[index] = params:string("v1_source") end
  local voice_names = {}
  for voice = 1, C.NUM_VOICES do voice_names[voice] = "voice " .. voice end
  assert_equal(table.concat(names, ","), "synth,buf 1,buf 2,buf 3,buf 4,buf 5,buf 6,buf 7,buf 8,input," .. table.concat(voice_names, ","))
  params:set("v1_source", 1)
  local expected = { buf_pos = 0, buf_rate = 1, buf_scan = 0 }
  for voice_idx = 1, 7 do
    local prefix = "v" .. voice_idx .. "_"
    local source = params:lookup_param(prefix .. "source")
    assert_equal(source.t, params.tOPTION, "source is an option")
    assert_equal(source.count, #C.SOURCE_OPTIONS, "synth, eight buffers, input, seven voices")
    assert_equal(params:get(prefix .. "source"), 1, "default synth")
    assert_equal(voices[voice_idx].source, 1, "voices table holds the source index")
    for key, default in pairs(expected) do
      assert_near(params:get(prefix .. key), default, 1e-9, prefix .. key .. " default")
      assert_near(voices[voice_idx].values[key], default, 1e-9, "voices[" .. voice_idx .. "].values." .. key)
    end
  end
  assert_equal(param_range("v1_buf_pos"), 0); assert_equal(select(2, param_range("v1_buf_pos")), 1)
  assert_equal(param_range("v1_buf_rate"), 0.25); assert_equal(select(2, param_range("v1_buf_rate")), 4)
  assert_equal(param_range("v1_buf_scan"), -2); assert_equal(select(2, param_range("v1_buf_scan")), 2)
  assert_equal(params:lookup_param("v1_buf_rate").controlspec.warp_name, "exp", "buf rate is exponential")
  params:set("v2_buf_rate", 2); assert_near(voices[2].values.buf_rate, 2, 1e-9)
  params:set("v2_buf_scan", -1); assert_near(voices[2].values.buf_scan, -1, 1e-9)
  params:set("v2_buf_pos", 0.123); assert_near(voices[2].values.buf_pos, 0.123, 1e-9, "buf_pos is not quantized")
  assert_true(not voice_uses_buffer(2), "synth source is not a buffer")
  assert_equal(voice_source_label(2), "synth")
  params:set("v2_source", 9); assert_true(voice_uses_buffer(2)); assert_equal(voice_source_label(2), "buf 8")
  params:set("v2_source", 10); assert_true(not voice_uses_buffer(2), "input is not a buffer")
  assert_equal(voice_source_label(2), "input")
  -- the buffer params are scene keys with their params' defaults
  local _, by_key = local_value("S").lib.params_setup.voice_scene_keys(1)
  for key, default in pairs(expected) do
    assert_true(by_key[key] ~= nil, key .. " is a scene key")
    assert_equal(by_key[key].default, default, key .. " scene default")
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
    local values = voices[2].values
    assert_equal(values["mod_source_" .. slot], 3); assert_equal(values["mod_amp_amt_" .. slot], 1.25)
    assert_equal(values["mod_freq_amt_" .. slot], -0.75)
  end
  -- a stopped voice's slot is stored, not sent
  assert_true(not voices[5].active, "voice 5 is stopped")
  context.clear_engine_calls()
  params:set("v5_mod_source_2", 4); params:set("v5_mod_amp_amt_2", 1); params:set("v5_mod_freq_amt_2", 1)
  assert_equal(#context.engine_calls, 0, "nothing sent for a stopped voice")
  assert_equal(voices[5].values.mod_source_2, 4); assert_equal(voices[5].values.mod_amp_amt_2, 1)
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


test("the 256 grid's tempo keys flash the tempo the clock runs, under an external source (#383)", function()
  local context = load_strata(); finish_startup(context)
  local flash = local_value("S").lib.ui_flash
  context.grid.plug(1, 16, 16)
  params:set("clock_source", 2)    -- midi: the clock's tempo is not ours to set
  clock.tempo = 100
  context.grid.press(1, 2, 16, 1)  -- T+ (row 16): +1 BPM
  assert_equal(flash.text("header"), "tempo 100", "the flash shows the running tempo, not the param")
  params:set("clock_source", 1)
  context.grid.press(1, 2, 16, 1)
  assert_equal(flash.text("header"), "tempo 122", "internal: the tempo it landed on (the clock reports it once it ticks)")
end)

-- 3.7 (design decision 21): no PSET format. A PSET is read as it is: a
-- line for an id that is no param (strata_pset_format, which 3.3 to 3.6
-- saved) is skipped by norns' read, and nothing is converted by it
test("a PSET has no strata_pset_format, and one that holds the line still loads", function()
  local context = load_strata({ data_subdir = "pset_no_format" }); finish_startup(context)
  local S = local_value("S")
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  assert_equal(params.lookup["strata_pset_format"], nil, "no format param")
  assert_equal(S.constants.PSET_FORMAT, nil, "no PSET_FORMAT")
  if not S.voices[5].active then toggle_voice(5) end
  local path = context.data_dir .. "now.pset"
  params:set("v5_res", 0.3)
  params:write(path, "now")
  local text = h.file_text(path)
  assert_true(not text:find("strata_pset_format", 1, true), "a PSET saved now has no format line")
  -- a PSET of 3.3 to 3.6 holds the line (2), one hand-edited may say 1:
  -- either reads as written, never mirrored
  for _, format in ipairs({ 2, 1 }) do
    local old_path = context.data_dir .. "format" .. format .. ".pset"
    h.write_text(old_path, text .. '"strata_pset_format": ' .. format .. "\n")
    params:set("v5_res", 0.6); params:set("reverb_mix", 0.9)
    params:read(old_path)
    assert_near(params:get("v5_res"), 0.3, 1e-9, "format line " .. format .. ": the res as written")
    assert_near(params:get("reverb_mix"), 0.43, 1e-9, "format line " .. format .. ": every other param as written")
  end
  for _, line in ipairs(context.printed) do
    assert_true(not line:find("mirrored", 1, true), "nothing is mirrored: " .. line)
  end
end)

-- #554: a PSET saved while a number param held a fraction (norns' PARAMS
-- menu turned a number param by d / 20 with K3 held, #534) loads it whole:
-- after the read the hook rounds every number param Strata's records added
-- (its own and the LFO library's, the registered voice params too), never
-- one of norns' system params
test("a PSET's fractional number params load whole (#554)", function()
  local context = load_strata({ data_subdir = "pset_whole_numbers" }); finish_startup(context)
  local S = local_value("S")
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  -- (a running voice: the next test)
  if S.voices[1].active then toggle_voice(1) end
  local path = context.data_dir .. "fractions.pset"
  params:write(path, "fractions")
  local text = h.file_text(path)
  for id, value in pairs({ v1_mod_source_1 = "0.05", scene_sequence_length = "4.05", v1_custom_interval_1 = "-2.6" }) do
    local count
    text, count = text:gsub('"' .. id .. '": [^\n]*\n', '"' .. id .. '": ' .. value .. '\n')
    assert_equal(count, 1, id .. " is in the PSET")
  end
  h.write_text(path, text)
  params:set("link_quantum", 4.5)  -- a system param (not saved in PSETs) holding a fraction
  params:read(path)
  assert_equal(params:get("v1_mod_source_1"), 0, "mod source 0.05 loads as 0")
  assert_equal(params:get("scene_sequence_length"), 4, "sequence length 4.05 loads as 4")
  assert_equal(params:get("v1_custom_interval_1"), -3, "custom interval -2.6 loads as -3")
  assert_equal(S.voices[1].values.mod_source_1, 0, "the voices table holds the whole source")
  assert_equal(params:get("link_quantum"), 4.5, "norns' own params are left alone")
  -- a silent read runs no action: the hook alone rounds them
  params:set("v1_mod_source_1", 2); params:set("scene_sequence_length", 2); params:set("v1_custom_interval_1", 5)
  params:read(path, true)
  assert_equal(params:get("v1_mod_source_1"), 0, "silent: mod source 0.05 loads as 0")
  assert_equal(params:get("scene_sequence_length"), 4, "silent: sequence length 4.05 loads as 4")
  assert_equal(params:get("v1_custom_interval_1"), -3, "silent: custom interval -2.6 loads as -3")
end)

-- #554: norns sets each PSET line through the param's own set, actions
-- included, before the read hook rounds: a number param whose action
-- reaches the engine rounds its value first, so a running voice never gets
-- a fraction (matron casts an "i" argument: 0.05 - 1 would be voice 1)
test("a PSET read while a voice runs sends its crossmod source and custom intervals only whole (#554)", function()
  local context = load_strata({ data_subdir = "pset_whole_sends" }); finish_startup(context)
  local S = local_value("S")
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  if not S.voices[1].active then toggle_voice(1) end
  params:set("v1_intervals", 5)  -- custom: the custom intervals reach the engine
  local path = context.data_dir .. "running.pset"
  params:write(path, "running")
  local text = h.file_text(path)
  for id, value in pairs({ v1_mod_source_1 = "0.05", v1_mod_source_2 = "2.6", v1_custom_interval_1 = "-2.6" }) do
    local count
    text, count = text:gsub('"' .. id .. '": [^\n]*\n', '"' .. id .. '": ' .. value .. '\n')
    assert_equal(count, 1, id .. " is in the PSET")
  end
  h.write_text(path, text)
  context.clear_engine_calls()
  params:read(path)
  local sources = {}
  for _, call in ipairs(context.calls_named("setModSource")) do
    if call.args[1] == 0 then sources[#sources + 1] = call.args[2] .. ":" .. call.args[3] end
  end
  assert_equal(table.concat(sources, " "), "1:-1 2:2", "slot 1 none, slot 2 voice 3 (SC 2), each sent once")
  local intervals = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "interval1" then intervals[#intervals + 1] = call.args[3] end
  end
  assert_true(#intervals > 0, "the custom interval reaches the engine")
  for _, value in ipairs(intervals) do assert_equal(value, -3, "interval1 is sent whole") end
  assert_equal(S.voices[1].values.mod_source_1, 0)
  assert_equal(S.voices[1].values.mod_source_2, 3)
  assert_equal(S.voices[1].values.custom_interval_1, -3)
  assert_equal(params:get("v1_mod_source_1"), 0, "and the params are whole once the read is done")
  assert_equal(params:get("v1_custom_interval_1"), -3)
end)

-- #628: a PSET saved before a param existed has no line for it, and the
-- param loads its default, never the session's value. without_lines turns a
-- PSET written now into one without the lines of the params MISSING names
-- (3.4's, which a 3.3 PSET lacked)
local MISSING = { "^gesture_%d+_quantize$", "^input_follow_gain$", "^macro_%d+$", "^matrix_%d+$", "^matrix_%d+_depth$",
  "^morph$", "^morph_a$", "^morph_b$", "^quantize_actions$", "^scatter", "^seq_", "^strata_gestures$", "^strata_input$",
  "^strata_lfo_%d+$", "^strata_macros$", "^strata_matrix$", "^strata_morph$", "^strata_scatter$", "^strata_seq$",
  "^v%d+_mute$", "^v%d+_solo$", "^v%d+_seq_" }

local function without_lines(text)
  local lines, dropped = {}, {}
  for line in text:gmatch("[^\n]*\n") do
    local id = line:match('^"(.-)"')
    local missing = false
    for index, pattern in ipairs(MISSING) do
      if id and id:match(pattern) then dropped[index], missing = true, true end
    end
    if not missing then lines[#lines + 1] = line end
  end
  for index, pattern in ipairs(MISSING) do assert_true(dropped[index], pattern .. " names a param of this session") end
  return table.concat(lines)
end

-- The reviewer's session: params the shorter PSET has no line for, away
-- from their defaults, with voices 1-4 running
local SESSION_3_4 = { v2_mute = 1, v3_solo = 1, scatter = 1, scatter_depth = 50, v1_seq_gate = 2, v1_seq_swing = 66,
  morph = 0.5, macro_1 = 0.7 }
local DEFAULTS_3_4 = { v2_mute = 0, v3_solo = 0, scatter = 0, scatter_depth = 10, v1_seq_gate = 1, v1_seq_swing = 50,
  morph = 0, macro_1 = 0 }

test("a PSET line that is missing still means the default (#628)", function()
  local context = load_strata({ data_subdir = "pset_missing_lines" }); finish_startup(context)
  local S = local_value("S")
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  for voice_idx = 1, 4 do
    if not S.voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  local new_path, old_path = context.data_dir .. "new.pset", context.data_dir .. "old.pset"
  params:write(new_path, "new")
  h.write_text(old_path, without_lines(h.file_text(new_path)))
  local function set_session() for id, value in pairs(SESSION_3_4) do params:set(id, value) end end
  set_session()
  assert_true(S.lib.voice_mix.silenced(1) and S.lib.voice_mix.silenced(2) and S.lib.voice_mix.silenced(4))
  context.clear_engine_calls()
  params:read(old_path)
  for id, value in pairs(DEFAULTS_3_4) do assert_near(params:get(id), value, 1e-9, id .. " back to its default") end
  for voice_idx = 1, 4 do assert_true(not S.lib.voice_mix.silenced(voice_idx), "voice " .. voice_idx .. " plays") end
  local muted = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "voiceMute" then muted[call.args[1] + 1] = call.args[3] end
  end
  for _, voice_idx in ipairs({ 1, 2, 4 }) do assert_equal(muted[voice_idx], 0, "voice " .. voice_idx .. " unmuted") end
  -- a silent read's defaults are set silently; then the per-voice params'
  -- hook (#951) sends the running voices what a read with actions does
  set_session()
  context.clear_engine_calls()
  local setup = S.lib.params_setup
  local real_migrate, sent_in_migrate = setup.migrate_read_pset, nil
  setup.migrate_read_pset = function(...)
    real_migrate(...)
    sent_in_migrate = #context.engine_calls
  end
  params:read(old_path, true)
  setup.migrate_read_pset = real_migrate
  for id, value in pairs(DEFAULTS_3_4) do assert_near(params:get(id), value, 1e-9, id .. " silently to its default") end
  assert_equal(sent_in_migrate, 0, "the defaults are set silently")
  muted = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "voiceMute" then muted[call.args[1] + 1] = call.args[3] end
  end
  for _, voice_idx in ipairs({ 1, 2, 4 }) do assert_equal(muted[voice_idx], 0, "silent: voice " .. voice_idx .. " unmuted") end
  -- a PSET saved now names every param: it loads as written, defaults left alone
  set_session()
  params:write(new_path, "new")
  for id, value in pairs(DEFAULTS_3_4) do params:set(id, value) end
  params:read(new_path)
  for id, value in pairs(SESSION_3_4) do assert_near(params:get(id), value, 1e-9, id .. " as the PSET saved it") end
end)

-- #951: a silent PSET read (params:read(n, true), a script's or a mod's)
-- runs no param action, and add_voice_param's action is the one writer of
-- S.voices[v].values: after the read, each voice param's stored value is
-- the one its action would have stored for the value the read left
test("a silent PSET read leaves no voice param's stored value behind (#951)", function()
  local context = load_strata({ data_subdir = "pset_silent_values" }); finish_startup(context)
  local S = local_value("S")
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "silent.pset"
  params:set("v1_env_loop", 2); params:set("v1_grain_size", 0.37)
  params:write(path, "silent")
  params:set("v1_env_loop", 1); params:set("v1_grain_size", 0.1)
  assert_equal(S.voices[1].values.env_loop, 1, "the session's loop is off before the read")
  params:read(path, true)
  assert_equal(params:get("v1_env_loop"), 2, "the read sets the loop param")
  assert_equal(S.voices[1].values.env_loop, 2, "and the voice stores it")
  assert_near(S.voices[1].values.grain_size, params:get("v1_grain_size"), 1e-9, "the grain size stored is the param's")
  assert_near(S.voices[1].values.grain_size, 0.37, 1e-9, "the PSET's grain size")
end)

-- #951 (the controller's rulings 1 and 2): one PSET read, silent or with
-- actions, from a session with voices 1-3 running. The PSET is the session
-- with change() applied; the read starts from the session (a read with
-- actions of its own PSET). Returns the voices' stored fields (values, type,
-- source), each per-voice param's value, and the engine calls of the read,
-- sorted, but scatter's one setScatter (its own hook sends it after a silent
-- read: lib/scatter.lua) and the scale's setScale and scaleNote (#965: sent
-- after every silent read, the controller's ruling), which are compared
-- instead as what the engine holds after the read (scale, per voice, from
-- every call since the load). The arp's random draw (an order of random)
-- is seeded the same before each read
local function read_once(name, silent, change)
  local context = load_strata({ data_subdir = "pset_silent_" .. name .. (silent and "_silent" or "_actions") })
  finish_startup(context)
  local S = local_value("S")
  util.make_dir(context.data_dir)
  for voice_idx = 1, 3 do
    if not S.voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  local session, path = context.data_dir .. "session.pset", context.data_dir .. "changed.pset"
  params:write(session, "session")
  change(S)
  params:write(path, "changed")
  params:read(session)
  local from = #context.engine_calls
  math.randomseed(951)
  params:read(path, silent)
  local result = { stored = {}, params = {}, calls = {}, scale = {} }
  for voice_idx = 1, 7 do
    local voice = S.voices[voice_idx]
    result.stored["v" .. voice_idx .. " type"] = voice.name
    result.stored["v" .. voice_idx .. " source"] = voice.source
    for key, value in pairs(voice.values) do
      result.stored["v" .. voice_idx .. " " .. key] = value
      result.params["v" .. voice_idx .. "_" .. key] = params:get("v" .. voice_idx .. "_" .. key)
    end
  end
  for index, call in ipairs(context.engine_calls) do
    local scale_note = call.name == "setGrainParam" and call.args[2] == "scaleNote"
    if scale_note then
      result.scale["scaleNote " .. call.args[1]] = string.format("%.9g", call.args[3])
    elseif call.name == "setScale" then
      result.scale.setScale = call.args[1] .. " " .. call.args[2]
    elseif call.name ~= "setScatter" and index > from then
      local parts = { call.name }
      for _, arg in ipairs(call.args) do
        parts[#parts + 1] = type(arg) == "number" and string.format("%.9g", arg) or tostring(arg)
      end
      result.calls[#result.calls + 1] = table.concat(parts, " ")
    end
  end
  table.sort(result.calls)
  return result, S
end

-- The two reads' results, field by field and call by call
local function assert_same_reads(silent, actions, what)
  for field, value in pairs(actions.stored) do
    if type(value) == "number" then
      assert_near(silent.stored[field], value, 1e-9, what .. ": " .. field .. " stored as a read with actions stores it")
    else
      assert_equal(silent.stored[field], value, what .. ": " .. field .. " stored as a read with actions stores it")
    end
  end
  local counts, differ = {}, {}
  for _, call in ipairs(actions.calls) do counts[call] = (counts[call] or 0) + 1 end
  for _, call in ipairs(silent.calls) do counts[call] = (counts[call] or 0) - 1 end
  for call, count in pairs(counts) do
    if count ~= 0 then differ[#differ + 1] = call .. " (" .. (count > 0 and "actions +" or "silent +") .. math.abs(count) .. ")" end
  end
  for key, value in pairs(actions.scale) do
    if silent.scale[key] ~= value then differ[#differ + 1] = key .. ": " .. tostring(silent.scale[key]) .. " after the silent read" end
  end
  table.sort(differ)
  assert_equal(table.concat(differ, "\n"), "", what .. ": the running voices are sent what a read with actions sends them")
end

test("a silent read of a PSET with another type and source ends where a read with actions ends (#951)", function()
  local function change(S)
    local folder = S.lib.types.list()[3]
    params:set("v1_type", folder.index)
    for index, key in ipairs(folder.param_order) do
      local param = params:lookup_param("v1_" .. key)
      params:set(param.id, param.controlspec:map((index % 4 + 1) / 5))
    end
    params:set("v2_source", S.constants.SOURCE_SYNTH + 2)
    params:set("v2_buf_rate", 1.5); params:set("v2_grain_size", 0.3)
    params:set("v3_env_loop", 2); params:set("v3_mute", 1); params:set("v3_grain_size", 0.2)
  end
  local actions = read_once("type", false, change)
  local silent, S = read_once("type", true, change)
  assert_equal(silent.stored["v1 type"], S.lib.types.list()[3].key, "voice 1 takes the PSET's type")
  assert_equal(silent.stored["v2 source"], S.constants.SOURCE_SYNTH + 2, "voice 2 the PSET's source")
  assert_true(#actions.calls > 0, "a read with actions sends the changes to the running voices")
  assert_same_reads(silent, actions, "another type and source")
end)

test("a quantized voice's freq is the PSET's after a silent read (#951)", function()
  local pset_freq
  local function change()
    params:set("v2_quantize", 1)
    params:set("v2_freq", 46.25)
    pset_freq = params:get("v2_freq")
  end
  local actions = read_once("freq", false, change)
  local silent = read_once("freq", true, change)
  assert_near(params:get("v2_freq"), pset_freq, 1e-9, "the PSET's freq, a scale tone")
  assert_near(silent.stored["v2 freq"], pset_freq, 1e-9, "stored, never the session's freq snapped over it")
  assert_equal(silent.stored["v2 quantize"], 1, "the voice quantizes")
  assert_same_reads(silent, actions, "a quantized freq")
end)

test("a silent read leaves the loop pair as the file has it (#951)", function()
  local function change(S)
    params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
    params:set("v1_loop_start", 0.6); params:set("v1_loop_length", 0.35)
    params:set("v2_source", S.constants.SOURCE_SYNTH + 1)
    params:set("v2_loop_length", 0.25)
  end
  local actions = read_once("loops", false, change)
  local silent = read_once("loops", true, change)
  assert_near(silent.stored["v1 loop_start"], 0.6, 1e-9, "voice 1's start as the file has it")
  assert_near(silent.stored["v1 loop_length"], 0.35, 1e-9, "and its length")
  assert_near(silent.params.v1_loop_length, 0.35, 1e-9, "the length param too")
  assert_near(silent.stored["v2 loop_length"], 0.25, 1e-9, "voice 2's length, its start left at 0")
  assert_same_reads(silent, actions, "the loop pair")
end)

-- The hook acts only on a silent read: a read with actions runs each
-- changed per-voice param's action once, and no other's
test("a read with actions runs no action twice (#951)", function()
  local context = load_strata({ data_subdir = "pset_silent_once" }); finish_startup(context)
  local S = local_value("S")
  util.make_dir(context.data_dir)
  if not S.voices[1].active then toggle_voice(1) end
  local session, path = context.data_dir .. "session.pset", context.data_dir .. "changed.pset"
  params:write(session, "session")
  local changed = { v1_type = 4, v1_source = 2, v1_env_loop = 2, v1_grain_size = 0.3, v2_mute = 1 }
  for id, value in pairs(changed) do params:set(id, value) end
  params:write(path, "changed")
  params:read(session)
  local runs = {}
  for _, param in ipairs(params.params) do
    local id = tostring(param.id)
    if id:match("^v%d+_") and param.action then
      local action = param.action
      param.action = function(...) runs[id] = (runs[id] or 0) + 1; return action(...) end
    end
  end
  params:read(path)
  for id in pairs(changed) do assert_equal(runs[id], 1, id .. "'s action runs once") end
  for id, count in pairs(runs) do
    assert_true(changed[id] ~= nil or count == 1, id .. " ran " .. count .. " times")
  end
end)

-- The hook returns at once at a read with actions: it reads and sets no
-- param (a set alone could not tell, since after such a read no stored
-- value differs). And it is the last PSET hook, after the tuning's, whose
-- silent re-set of each v<i>_freq it must replay
test("the voice params' PSET hook is the last and touches no param at a read with actions (#951)", function()
  local context = load_strata({ data_subdir = "pset_silent_guard" }); finish_startup(context)
  local S = local_value("S")
  util.make_dir(context.data_dir)
  local hooks, tuning_at = S.registry.pset_hooks, nil
  for index, hook in ipairs(hooks) do
    if hook.name == "tuning" then tuning_at = index end
  end
  assert_equal(hooks[#hooks].name, "voice_params", "the voice params' hook is the last PSET hook")
  assert_true(tuning_at ~= nil and tuning_at < #hooks, "after the tuning's")
  local hook = hooks[#hooks]
  local path = context.data_dir .. "guard.pset"
  params:write(path, "guard")
  params:set("v1_grain_size", 0.3)
  local own_read, touched = hook.read, nil
  hook.read = function(...)
    touched = 0
    params.get = function(self, ...) touched = touched + 1; return getmetatable(self).get(self, ...) end
    params.set = function(self, ...) touched = touched + 1; return getmetatable(self).set(self, ...) end
    local ran, failure = pcall(own_read, ...)
    params.get, params.set = nil, nil
    if not ran then error(failure, 0) end
  end
  params:read(path)
  hook.read = own_read
  assert_equal(touched, 0, "a read with actions: the hook gets and sets no param")
  assert_near(S.voices[1].values.grain_size, params:get("v1_grain_size"), 1e-9, "the read's own action stored it")
end)

-- #965 (decided 2026-11-23): after a silent PSET read the engine follows
-- every param, voice or not. The engine as calls leave it: per command and
-- its index arguments (a voice and a param name, an effect, a tone), the
-- last call's other arguments
local ENGINE_INDEX_ARGS = { setGrainParam = 2, setVoiceParam = 2, setBypass = 1, setTuningTone = 1, setModSource = 2,
  setModAmpAmt = 2, setModFreqAmt = 2, setModSpeed = 1, setGrainSource = 1, setVoiceType = 1, voiceOn = 1,
  voiceOff = 1 }
local function engine_holds(calls)
  local held = {}
  for _, call in ipairs(calls) do
    local key, rest = { call.name }, {}
    for index, arg in ipairs(call.args) do
      local text = type(arg) == "number" and string.format("%.9g", arg) or tostring(arg)
      if index <= (ENGINE_INDEX_ARGS[call.name] or 0) then key[#key + 1] = text else rest[#rest + 1] = text end
    end
    held[table.concat(key, " ")] = table.concat(rest, " ")
  end
  return held
end

-- One PSET read of the session with change() applied, silent or with
-- actions, from the session (voices 1 and 2 run, as at the default start):
-- what the engine holds after it, from every call since the script loaded
-- (held), and the read's own calls (read)
local function engine_read(name, silent, change)
  local context = load_strata({ data_subdir = "pset_engine_" .. name .. (silent and "_silent" or "_actions") })
  finish_startup(context)
  local S = local_value("S")
  util.make_dir(context.data_dir)
  local session, path = context.data_dir .. "session.pset", context.data_dir .. "changed.pset"
  params:write(session, "session")
  change(S)
  params:write(path, "changed")
  params:read(session)
  local from = #context.engine_calls
  params:read(path, silent)
  local read = {}
  for index = from + 1, #context.engine_calls do read[#read + 1] = context.engine_calls[index] end
  return { held = engine_holds(context.engine_calls), read = read }, S, context
end

-- The calls' names, sorted, joined with spaces
local function call_names(calls)
  local names = {}
  for _, call in ipairs(calls) do names[#names + 1] = call.name end
  table.sort(names)
  return table.concat(names, " ")
end

-- What the engine holds after both reads, command by command; leave: the
-- commands left out (scatter's setScatter: its own hook sends it after a
-- silent read, lib/scatter.lua)
local function assert_engine_holds_same(silent, actions, what, leave)
  local differ = {}
  for key, value in pairs(actions.held) do
    if not (leave and leave[key]) and silent.held[key] ~= value then
      differ[#differ + 1] = key .. ": " .. tostring(silent.held[key]) .. " after the silent read, " .. value .. " after the other"
    end
  end
  for key, value in pairs(silent.held) do
    if not (leave and leave[key]) and actions.held[key] == nil then differ[#differ + 1] = key .. ": only the silent read sent " .. value end
  end
  table.sort(differ)
  assert_equal(table.concat(differ, "\n"), "", what .. ": the engine holds what a read with actions leaves")
end

test("after a silent PSET read the engine holds what a read with actions leaves (#965)", function()
  local function change()
    params:set("filter_freq", 800); params:set("delay_feedback", 0.6); params:set("reverb_size", 0.5)
    params:set("shimmer_delay", 0.3); params:set("drift_amount", 0.05); params:set("scale", 3)
  end
  local actions = engine_read("all", false, change)
  local silent = engine_read("all", true, change)
  for _, command in ipairs({ "setFilter", "setDelay", "setReverb", "setShimmer", "setMasterDrift", "setScale" }) do
    assert_true(actions.held[command] ~= nil, "a read with actions sends " .. command)
  end
  assert_engine_holds_same(silent, actions, "the filter, the delay, the reverb, shimmer, the drift and the scale",
    { setScatter = true })
end)

-- The scale keeps no record of what the engine holds (the controller's
-- ruling on #965: one message is cheaper than a second record), so it is
-- sent after every silent read, with each running voice's scaleNote, as
-- scatter's hook sends its one setScatter
test("a silent read of a PSET equal to the state sends only scatter's setScatter and the scale's setScale (#965)", function()
  local context = load_strata({ data_subdir = "pset_engine_equal" }); finish_startup(context)
  local S = local_value("S")
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "equal.pset"
  -- sent values (the engine's record holds them) beside defaults never sent
  params:set("filter_freq", 800); params:set("reverb_size", 0.5); params:set("delay_bypass", 1)
  params:set("shimmer_delay", 0.3); params:set("scale", 3); params:set("master_density", 1.5)
  params:write(path, "equal")
  for voice_idx = 1, 7 do
    if S.voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(call_names(context.engine_calls), "setScale setScatter", "a silent read of the state as it is")
  -- a running voice also gets its scaleNote, as a root change sends it
  toggle_voice(2)
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(call_names(context.engine_calls), "setGrainParam setScale setScatter", "with voice 2 running")
  local note = context.engine_calls[#context.engine_calls]
  assert_equal(note.args[1] .. " " .. note.args[2], "1 scaleNote", "its scaleNote")
  assert_true(S.voices[2].active, "the voice still runs")
  -- a running chord voice's intervals, computed from the scale, once (fix
  -- round 1: S.lib.arp's send-if-changed is local to lib/arp.lua, so the
  -- scale's sends resend the list once a silent read, never twice)
  params:set("v2_intervals", S.lib.variation.VARIATION.set_index.chord)
  params:write(path, "equal")
  context.clear_engine_calls()
  params:read(path, true)
  local intervals = 0
  for _, call in ipairs(context.engine_calls) do
    if call.name == "setGrainParam" and tostring(call.args[2]):match("^interval") then intervals = intervals + 1 end
  end
  assert_equal(intervals, S.lib.variation.VARIATION.max_intervals + 1, "the chord's list once: each interval and the count")
end)

-- #987 (known, not this package's): turning delay sync off sends under
-- delay_time, so the record the hook compares keeps delay_sync at 1 and
-- the next silent read sends one setDelay it did not need (with the values
-- the engine has). #987's fix removes this allowance
test("a silent read of an equal PSET after delay sync was turned off sends one setDelay more (known #987)", function()
  local context = load_strata({ data_subdir = "pset_engine_sync_off" }); finish_startup(context)
  util.make_dir(context.data_dir)
  local S = local_value("S")
  local path = context.data_dir .. "equal.pset"
  for voice_idx = 1, 7 do
    if S.voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  params:set("delay_sync", 1); params:set("delay_sync", 0)
  params:write(path, "equal")
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(call_names(context.engine_calls), "setDelay setScale setScatter", "#987's one setDelay more")
  local delay
  for _, call in ipairs(context.engine_calls) do if call.name == "setDelay" then delay = call end end
  assert_near(delay.args[1], params:get("delay_time"), 1e-9, "with the time the delay plays")
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(call_names(context.engine_calls), "setScale setScatter", "once: the send records delay_sync")
end)

test("a silent read sends a command of several params once (#965)", function()
  local function change()
    params:set("filter_type", 2); params:set("filter_freq", 800); params:set("filter_res", 0.7)
    params:set("filter_mix", 0.6)
    params:set("delay_time", 0.5); params:set("delay_feedback", 0.6); params:set("delay_mix", 0.3)
    params:set("delay_pingpong", 0.4)
    params:set("reverb_mix", 0.2); params:set("reverb_size", 0.5); params:set("reverb_damp", 0.3)
    params:set("delay_to_reverb", 0.4)
    params:set("shimmer_interval", 2); params:set("shimmer_delay", 0.3); params:set("shimmer_reverb", 0.2)
  end
  local actions = engine_read("once", false, change)
  local silent = engine_read("once", true, change)
  local counts = {}
  for _, call in ipairs(silent.read) do counts[call.name] = (counts[call.name] or 0) + 1 end
  for _, command in ipairs({ "setFilter", "setDelay", "setReverb", "setShimmer" }) do
    assert_equal(counts[command], 1, command .. " is sent once")
    assert_equal(silent.held[command], actions.held[command], command .. " with every value the read changed")
  end
end)

-- #995 (fix round 2 of #965): the scale's and the root's actions snap every
-- quantized voice's stored freq ahead of the voices' lines; a silent read
-- does it in the engine params' hook. The probe: voice 2 quantized on C#4
-- (277.18 Hz) in a chromatic session, a PSET in C major whose v2_freq line
-- is that same freq (so the voice params' hook has nothing to set); a read
-- with actions ends on C4, and so must a silent one, in the param, the
-- stored value and what the engine holds
test("a silent read snaps a quantized voice to the PSET's scale, as a read with actions does (#995)", function()
  local function read(silent)
    local context = load_strata({ data_subdir = "pset_engine_scale_snap_" .. tostring(silent) })
    finish_startup(context)
    local S = local_value("S")
    util.make_dir(context.data_dir)
    local path = context.data_dir .. "major.pset"
    if not S.voices[2].active then toggle_voice(2) end
    params:set("v2_quantize", 1)
    params:set("v2_freq", 277.18)
    local session_freq = S.voices[2].values.freq
    local major
    for index, name in ipairs(params:lookup_param("scale").options) do if name == "Major" then major = index end end
    params:set("scale", major)
    params:write(path, "major")
    params:set("scale", 1)
    params:set("v2_freq", session_freq)
    assert_near(S.voices[2].values.freq, session_freq, 1e-9, "the session's voice 2 is back on C#4")
    local lines = {}
    for line in h.file_text(path):gmatch("[^\n]*\n") do
      if line:match('^"v2_freq"') then line = '"v2_freq": ' .. string.format("%.17g", session_freq) .. '\n' end
      lines[#lines + 1] = line
    end
    h.write_text(path, table.concat(lines))
    params:read(path, silent)
    local engine_freq
    for _, call in ipairs(context.engine_calls) do
      if call.name == "setVoiceParam" and call.args[1] == 1 and call.args[2] == "freq" then engine_freq = call.args[3] end
    end
    return params:get("v2_freq"), S.voices[2].values.freq, engine_freq, session_freq
  end
  local actions_param, actions_stored, actions_engine, session_freq = read(false)
  local silent_param, silent_stored, silent_engine = read(true)
  assert_true(math.abs(actions_param - session_freq) > 1, "a read with actions snaps C#4 off C major")
  assert_near(silent_param, actions_param, 1e-9, "the silent read's freq is a read with actions'")
  assert_near(silent_stored, actions_stored, 1e-9, "stored the same")
  assert_near(silent_engine, actions_engine, 1e-6, "and the engine holds the same freq")
end)

-- Fix round 1 of #965: a value waiting in the send budget (a macro's move,
-- morph or a gesture writes inside deferrable) for a param the PSET sets is
-- dropped by the read, as each action's send drops it in a read with
-- actions, so the flush never puts it back over the PSET's value
test("a value waiting in the budget for a param a silent read sets never flushes over the read (#965)", function()
  local function read(silent)
    local context = load_strata({ data_subdir = "pset_engine_waiting_" .. tostring(silent) })
    finish_startup(context)
    local S = local_value("S")
    local sync = S.lib.engine_sync
    util.make_dir(context.data_dir)
    local path = context.data_dir .. "filter.pset"
    params:set("filter_freq", 800); params:set("filter_res", 0.7)
    params:write(path, "filter")
    params:set("filter_freq", 5000); params:set("filter_res", 0.5)
    sync.count_sends(S.constants.ENGINE_BUDGET.messages_per_window)  -- the window is full
    sync.deferrable(function() send_param_to_engine("filter_res", 0.9) end)  -- as a macro's move
    assert_equal(sync.budget_state().pending, 1, "the move waits")
    params:read(path, silent)
    context.clock.run_for(0.3)
    local filters = context.calls_named("setFilter")
    return filters[#filters].args, sync, S
  end
  local actions = read(false)
  local silent, sync = read(true)
  assert_near(actions[2], 0.7, 1e-9, "after a read with actions the engine has the PSET's res")
  assert_near(silent[2], 0.7, 1e-9, "and after a silent read")
  assert_near(silent[1], 800, 1e-9, "with the PSET's freq")
  assert_near(sync.expected_value("filter_res"), 0.7, 1e-9, "the record is the PSET's res")
  assert_equal(sync.budget_state().pending, 0, "nothing waits")
end)

-- A bypassed effect, a frozen delay (lib/fx_hold.lua's hook, #883) and the
-- filter's restore mix keep their own rules: the sends go through each
-- param's own sender
test("a silent read that bypasses a frozen delay releases the freeze, then bypasses it (#965, #883)", function()
  local context = load_strata({ data_subdir = "pset_engine_bypass" }); finish_startup(context)
  local S = local_value("S")
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "bypassed.pset"
  params:set("delay_bypass", 1)
  params:write(path, "bypassed")
  params:set("delay_bypass", 0)
  params:set("delay_freeze", 1)
  assert_true(S.lib.fx_hold.frozen("delay"), "the delay is frozen before the read")
  context.clear_engine_calls()
  params:read(path, true)
  local delay_calls = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == "setDelayFreeze" or call.name == "setBypass" or call.name == "setDelay" then
      delay_calls[#delay_calls + 1] = call.name .. " " .. table.concat(call.args, " ")
    end
  end
  assert_equal(table.concat(delay_calls, ", "), "setDelayFreeze 0, setBypass 0 1",
    "the freeze released first, then the bypass, each once")
  assert_true(S.lib.voice_mix.bypassed("delay"), "bypassed")
  assert_true(not S.lib.fx_hold.frozen("delay"), "and not frozen")
  context.clear_engine_calls()
  params:set("delay_bypass", 0)
  assert_equal(call_names(context.engine_calls), "setBypass", "the lift sends the bypass alone, unfrozen")
end)

test("a silent read that raises the filter's mix makes it the restore mix, as a read with actions does (#965)", function()
  for _, silent in ipairs({ false, true }) do
    local what = silent and "silent" or "with actions"
    local context = load_strata({ data_subdir = "pset_engine_restore_" .. what:gsub(" ", "_") })
    finish_startup(context)
    local S = local_value("S")
    util.make_dir(context.data_dir)
    local path = context.data_dir .. "mix.pset"
    params:set("filter_mix", 0.7)
    params:write(path, "mix")
    params:set("filter_mix", 0.2)
    S.lib.params_setup.toggle_filter_mix()
    assert_near(S.fx_last_mix.filter, 0.2, 1e-9, what .. ": K3 kept 0.2 as the restore mix")
    params:read(path, silent)
    assert_near(params:get("filter_mix"), 0.7, 1e-9, what .. ": the PSET's mix")
    assert_near(S.fx_last_mix.filter, 0.7, 1e-9, what .. ": the read's rise is the restore mix")
    params:set("filter_mix", 0.5)
    assert_near(S.fx_last_mix.filter, 0.7, 1e-9, what .. ": a turn down from the read's mix keeps it")
  end
end)

-- The hook acts only on a silent read: a read with actions runs each
-- changed param's action once and sends each command its actions send
test("a read with actions runs no action twice, the FX and the scale's included (#965)", function()
  local context = load_strata({ data_subdir = "pset_engine_once" }); finish_startup(context)
  util.make_dir(context.data_dir)
  local session, path = context.data_dir .. "session.pset", context.data_dir .. "changed.pset"
  params:write(session, "session")
  local changed = { filter_freq = 800, delay_feedback = 0.6, reverb_size = 0.5, drift_amount = 0.05, scale = 3,
    delay_bypass = 1, shimmer_delay = 0.3 }
  for id, value in pairs(changed) do params:set(id, value) end
  params:write(path, "changed")
  params:read(session)
  local runs = {}
  for _, param in ipairs(params.params) do
    local id = param.id and tostring(param.id)
    if id and param.action then
      local action = param.action
      param.action = function(...) runs[id] = (runs[id] or 0) + 1; return action(...) end
    end
  end
  context.clear_engine_calls()
  params:read(path)
  for id in pairs(changed) do assert_equal(runs[id], 1, id .. "'s action runs once") end
  for id, count in pairs(runs) do assert_true(count == 1, id .. " ran " .. count .. " times") end
  assert_equal(call_names(context.engine_calls),
    "setBypass setDelay setFilter setMasterDrift setReverb setScale setShimmer",
    "each changed param's own send, once")
end)

-- 3.4's PSET hooks (S.register_pset_hook, design §0.1): the master record
-- installs norns' three PSET actions, which run every hook with the PSET's
-- path without .pset and the two-digit number norns passes (nil for a PSET
-- read or written by path); the read runs after migrate_read_pset
test("the PSET hooks run on write, read and delete with the path base and number", function()
  local log = {}
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    S.register_pset_hook({ name = "raises", write = function() error("boom") end, read = function() error("boom") end,
      delete = function() error("boom") end })
    S.register_pset_hook({ name = "probe",
      write = function(base, number) log[#log + 1] = "write " .. base .. " " .. tostring(number) end,
      read = function(base, number, path) log[#log + 1] = "read " .. base .. " " .. tostring(number) .. " " .. path end,
      delete = function(base, number) log[#log + 1] = "delete " .. base .. " " .. tostring(number) end })
    S.register_pset_hook({ name = "reads only", read = function() log[#log + 1] = "reads only" end })
  end })
  finish_startup(context)
  local S = local_value("S")
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  local real_migrate = S.lib.params_setup.migrate_read_pset
  S.lib.params_setup.migrate_read_pset = function(...) log[#log + 1] = "migrate"; return real_migrate(...) end
  local function take()
    local text = table.concat(log, "\n")
    for index in pairs(log) do log[index] = nil end
    return text
  end
  local function hook_failures()
    local count = 0
    for _, line in ipairs(context.printed) do
      if line:find("^pset hook raises: ") and line:find("boom", 1, true) then count = count + 1 end
    end
    return count
  end
  local base = context.data_dir .. "strata/strata-01"
  params:write(1, "a")
  assert_equal(take(), "write " .. base .. " 01", "a numbered write: its base and number")
  assert_equal(hook_failures(), 1, "a hook that raises prints pset hook <name>: and the next still runs")
  params:read(1)
  assert_equal(take(), table.concat({ "migrate", "read " .. base .. " 01 " .. base .. ".pset", "reads only" }, "\n"),
    "a numbered read: after the migration, with the PSET's path")
  assert_equal(hook_failures(), 2, "the read's failure prints too")
  local path = context.data_dir .. "y.pset"
  params:write(path)
  params:read(path)
  local by_path = context.data_dir .. "y"
  assert_equal(take(), table.concat({ "write " .. by_path .. " nil", "migrate", "read " .. by_path .. " nil " .. path,
    "reads only" }, "\n"), "a PSET written and read by path has no number")
  params:delete(base .. ".pset", "a", "01")
  assert_equal(take(), "delete " .. base .. " 01", "the PSET menu's delete names the number")
  assert_equal(io.open(base .. ".pset", "r"), nil, "and the file is gone")
  assert_equal(hook_failures(), 5, "every action prints its failing hook")
  h.claim_script_errors(context, 5, "pset hook raises: ", "boom")  -- each a script error to the harness
end)

test("the menu records for 3.4's groups follow lfos in order, each adding its module's group", function()
  local added, called = {}, {}
  load_strata({ before_init = function()
    local S = local_value("S")
    for _, record in ipairs(S.registry.params) do
      local add = record.add
      record.add = function()
        local before = #params.params
        add()
        added[record.name] = #params.params - before
      end
    end
  end })
  local S = local_value("S")
  local names = {}
  for _, record in ipairs(S.registry.params) do names[#names + 1] = record.name end
  local menu = table.concat(names, " ")
  -- (3.6's five records, between gestures and seq, have their own test)
  assert_true(menu:find("lfos macros morph scatter matrix input gestures rseq out midi crow out ii out nb tape seq buffers",
    1, true) ~= nil, "3.4's seven records follow lfos, then 3.7's rseq, with 3.6's five before seq: " .. menu)
  -- each a group and its params: the macros' sixteen, morph's six (the XY
  -- morph's three with the two-scene morph's three),
  -- scatter's eight, the matrix's 32, the input's one, the gestures' eight
  local groups = { macros = 1 + S.constants.NUM_MACROS, morph = 1 + 6, scatter = 1 + 8,
    matrix = 1 + 2 * S.constants.MATRIX_SLOTS, input = 1 + 1, gestures = 1 + 2 * S.constants.NUM_GESTURES }
  for _, name in ipairs({ "macros", "morph", "scatter", "matrix", "input", "gestures" }) do
    assert_equal(added[name], groups[name], name .. " adds its group")
  end
  assert_equal(added.seq, 1 + S.lib.sequencer.SEQ.group_params + S.lib.quantize.PARAM_COUNT, "seq adds strata_seq")
  -- each record calls its module's add_params, in menu order
  local modules = { macros = "macros", morph = "morph", scatter = "scatter", matrix = "matrix",
    input = "input_level", gestures = "gestures", seq = "sequencer" }
  load_strata({ before_init = function()
    local S2 = local_value("S")
    for record_name, module in pairs(modules) do
      local real = S2.lib[module].add_params
      S2.lib[module].add_params = function() called[#called + 1] = record_name; real() end
    end
  end })
  assert_equal(table.concat(called, " "), "macros morph scatter matrix input gestures seq", "each, in menu order")
end)

-- #679: step 0 keeps what the step used to give the other readers
test("buffer rate is exact (step 0) and its turns, display and range are as with step 0.01", function()
  load_strata()
  local spec = params:lookup_param("v1_buf_rate").controlspec
  assert_equal(spec.step, 0, "no step: a set keeps the exact rate")
  assert_equal(spec.quantum, 0.01, "a turn is still 0.01 of the raw range, not the step")
  assert_equal(spec.minval, 0.25); assert_equal(spec.maxval, 4)
  params:set("v1_buf_rate", 2 ^ (2 / 12))
  assert_near(params:get("v1_buf_rate"), 2 ^ (2 / 12), 1e-12, "exact")
  assert_equal((params:string("v1_buf_rate"):gsub("%s+$", "")), "1.12", "two decimals shown")
  params:set("v1_buf_rate", 0.2649)
  assert_equal((params:string("v1_buf_rate"):gsub("%s+$", "")), "0.26", "two decimals at a low rate")
  params:set("v1_buf_rate", 1)
  local raw = params:get_raw("v1_buf_rate")
  enc_param_delta(3, "v1_buf_rate", 1)
  assert_near(params:get_raw("v1_buf_rate") - raw, 0.01, 1e-9, "E3: 0.01 of the raw range")
  key(1, 1); raw = params:get_raw("v1_buf_rate"); enc_param_delta(3, "v1_buf_rate", 1)
  assert_near(params:get_raw("v1_buf_rate") - raw, 0.001, 1e-9, "ALT+E3: a tenth of it")
  key(1, 0)
  params:set("v1_buf_rate", 1)
  for _ = 1, 5 do enc_param_delta(3, "v1_buf_rate", 1) end
  for _ = 1, 5 do enc_param_delta(3, "v1_buf_rate", -1) end
  assert_equal(params:get("v1_buf_rate"), 1, "E3 up and down by the same clicks returns exactly 1")
  arc_sweep_param("v1_buf_rate", 3); arc_sweep_param("v1_buf_rate", -3)
  assert_near(params:get("v1_buf_rate"), 1, 1e-9, "an arc up and down returns to 1")
  local before = params:get("v1_buf_rate")
  arc_sweep_param("v1_buf_rate", 1)
  assert_true(params:get("v1_buf_rate") > before, "an arc tick raises it")
end)

-- 3.6 (design §0.1, §13): the five groups' records, each adding its group
-- only when its module is loaded
test("a 3.6 group record adds its group only for a loaded module", function()
  load_strata()
  local S = local_value("S")
  local names = {}
  for _, record in ipairs(S.registry.params) do names[#names + 1] = record.name end
  local menu = table.concat(names, "|")
  assert_true(menu:find("|gestures|rseq|out midi|crow|out ii|out nb|tape|seq|", 1, true) ~= nil,
    "the five records follow gestures and 3.7's rseq, in order: " .. menu)
  local function record_named(name)
    for _, record in ipairs(S.registry.params) do
      if record.name == name then return record end
    end
  end
  -- with its module absent, a record's add does nothing (the tape module is loaded here: take it out)
  local tape_module = S.lib.io_tape
  S.lib.io_tape = nil
  local before = #params.params
  -- the modules loaded in this tree are set aside, as on a branch without them
  local set_aside = { "io_midi_out", "io_crow", "io_ii", "io_nb" }
  local loaded = {}
  for _, name in ipairs(set_aside) do loaded[name], S.lib[name] = S.lib[name], nil end
  for _, name in ipairs({ "out midi", "crow", "out ii", "out nb", "tape" }) do record_named(name).add() end
  for _, name in ipairs(set_aside) do S.lib[name] = loaded[name] end
  assert_equal(#params.params, before, "no module, no params")
  S.lib.io_tape = tape_module
  -- with its module loaded, a record calls its add_params once
  local modules = { ["out midi"] = "io_midi_out", crow = "io_crow", ["out ii"] = "io_ii", ["out nb"] = "io_nb",
    tape = "io_tape" }
  for name, module in pairs(modules) do
    local ran = 0
    S.lib[module] = { add_params = function() ran = ran + 1 end }
    record_named(name).add()
    S.lib[module] = nil
    assert_equal(ran, 1, name .. " calls S.lib." .. module .. ".add_params")
  end
  -- and at init
  local calls = 0
  load_strata({ before_init = function()
    local_value("S").lib.io_tape = { add_params = function() calls = calls + 1 end }
  end })
  assert_equal(calls, 1, "S.lib.io_tape's add_params ran once, at init")
end)

-- #840: a scene key's synth flag is its record's synth_keys field, never
-- the record's name: the built-in synth record carries it, and a record of
-- another name with it marks its keys so; synth_keys is true, on a
-- scene_keys record, or absent
test("a voice scene key is marked synth by its record's synth_keys field, not by the record's name", function()
  load_strata({ before_init = function()
    local S0 = local_value("S")
    local function refused(fields)
      local record = { name = "probe_bad", count = 1, add = function() end }
      for key, value in pairs(fields) do record[key] = value end
      return not pcall(S0.register_voice_params, record)
    end
    assert_true(refused({ scene_keys = {}, synth_keys = 1 }) and refused({ scene_keys = {}, synth_keys = "yes" })
      and refused({ scene_keys = {}, synth_keys = false }), "synth_keys is true or absent")
    assert_true(refused({ synth_keys = true, scene_defaults = {} }), "and only on a scene_keys record")
    local probe
    probe = { name = "probe_marked", count = 1, synth_keys = true, scene_keys = { "probe_marked" },
      add = function(voice_idx)
        S0.lib.params_setup.add_voice_param(voice_idx, probe, "probe_marked",
          { type = "control", name = "probe marked", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
      end }
    S0.register_voice_params(probe)
  end })
  local S = local_value("S")
  local synth_record
  for _, record in ipairs(S.registry.voice_params) do
    if record.name == "synth" then synth_record = record end
  end
  assert_equal(synth_record.synth_keys, true, "the built-in synth record carries synth_keys")
  local _, by_key = S.lib.params_setup.voice_scene_keys(1)
  assert_equal(by_key.probe_marked.synth, true, "a record of another name with synth_keys marks its keys synth")
  for _, key in ipairs(S.voices[1].param_order) do
    assert_equal(by_key[key].synth, true, key .. ": the synth record's keys are marked")
  end
  assert_equal(by_key.grain_size.synth, nil, "a grain key is not")
end)

-- #842: read_defaulted names what the last read set to its default, so
-- each read starts it afresh: a PSET with its lines, read after one
-- without them, defaults nothing
test("read_defaulted holds only the last read's defaults (each read resets it)", function()
  local context = load_strata({ data_subdir = "read_changed_reset" }); finish_startup(context)
  local S = local_value("S")
  local setup = S.lib.params_setup
  util.make_dir(context.data_dir)
  local nineteen
  for _, entry in ipairs(S.lib.tuning.built_ins()) do
    if entry.name == "19 equal" then nineteen = entry end
  end
  S.lib.tuning.select(nineteen)
  local full = context.data_dir .. "full.pset"
  params:write(full, "full")
  local without = context.data_dir .. "without.pset"
  local lines = {}
  for line in h.file_text(full):gmatch("[^\n]*\n") do
    if not line:match('^"tuning_') then lines[#lines + 1] = line end
  end
  h.write_text(without, table.concat(lines))
  params:read(without)
  assert_true(setup.read_defaulted("tuning_tones"), "a PSET without the tuning's lines defaults tuning_tones")
  assert_true(setup.read_defaulted("tuning_name"), "and tuning_name")
  params:read(full)
  assert_true(not setup.read_defaulted("tuning_tones"), "the next read, with the lines, has defaulted nothing")
  assert_true(not setup.read_defaulted("tuning_name"), "tuning_name neither")
  assert_equal(params:get("tuning_name"), "19 equal", "the full PSET's tuning")
end)

-- A param as test/fixtures/3.7.0-params.lua records it (its header): id,
-- t and name; the default; a control's spec, an option's options, a
-- number's range, a group's size; the string a formatted param shows at
-- its default
local PARAM_FIXTURE_FIELDS = {"id", "t", "name", "default", "min", "max", "warp", "step", "quantum", "units",
  "options", "string", "n"}
local function string_at_default(param, default)
  local saved_raw, saved_value = param.raw, param.value
  if param.t == params.tCONTROL then param.raw = param.controlspec:unmap(default) else param.value = default end
  local text = params:string(param.id)
  param.raw, param.value = saved_raw, saved_value
  return text
end
local function fixture_record(param, audio_dir)
  local record = {id = param.id, t = param.t, name = param.name}
  if param.t == params.tCONTROL then
    local spec = param.controlspec
    record.default, record.min, record.max, record.warp = spec.default, spec.minval, spec.maxval, spec.warp_name
    record.step, record.quantum, record.units = spec.step, spec.quantum, spec.units
    if param.formatter and spec.default ~= nil then record.string = string_at_default(param, spec.default) end
  elseif param.t == params.tNUMBER then
    record.default, record.min, record.max = param.default, param.min, param.max
    if param.formatter then record.string = string_at_default(param, param.default) end
  elseif param.t == params.tOPTION then
    record.default, record.options = param.default, param.options
  elseif param.t == params.tBINARY then
    record.default = param.default
  elseif param.t == params.tFILE then
    record.default = param.path
    if record.default:sub(1, #audio_dir) == audio_dir then record.default = "@AUDIO@" .. record.default:sub(#audio_dir + 1) end
  elseif param.t == params.tTEXT then
    record.default = param.text
  elseif param.t == params.tGROUP then
    record.n = param.n
  end
  return record
end
local function field_text(value)
  if type(value) == "table" then
    local parts = {}
    for index, item in ipairs(value) do parts[index] = field_text(item) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  if type(value) == "number" then return string.format("%.17g", value) end
  return type(value) == "string" and string.format("%q", value) or tostring(value)
end

-- The differences from 3.7.0 the groundwork before 3.8 and 3.8 make on
-- purpose (their Global Constraints: every surviving param keeps its id,
-- default, spec and place but for the differences named here; the fixture
-- stays 3.7.0's). The package that makes a difference adds its entries in
-- the same commit, as registration lines: a block of its own inside the
-- list, opening `-- <id>: <what> (design §n)`, one entry a line, each why
-- beginning "<id>: ". An empty list leaves the comparison exactly as strict
-- as the fixture. An entry is one of:
--   {kind = "removed", id = <id>, why = <text>}: 3.7.0's param <id> is gone
--     (every fixture record with that id is left out of the comparison);
--   {kind = "added", id = <new id>, after = <id>, record = {t = <type code>,
--     name = <text>, ...}, why = <text>}: a new param directly after <id>
--     (a 3.7.0 id or an earlier added one; several after one id keep the
--     list's order); record holds t, name and any of PARAM_FIXTURE_FIELDS
--     but id, and the comparison checks the id, the place and those fields;
--   {kind = "default", id = <id>, default = <value>, string = <text>?,
--     why = <text>}: a changed default, and the string a formatted param
--     shows at it;
--   {kind = "name", id = <id>, name = <text>, why = <text>};
--   {kind = "range", id = <id>, min = <n>?, max = <n>?, why = <text>}: a
--     control's or number's bounds (an omitted one stays 3.7.0's);
--   {kind = "group_size", id = <group id>, add = <k>, why = <text>}: the
--     group keeps its place, k params more (several add entries for one
--     group sum: a group several packages grow is sized only so); or
--     n = <count> in place of add (2b's LFO groups alone; never beside add);
--   {kind = "options", id = <id>, options = {<text>, ...}, why = <text>}: the
--     option param keeps its place, with these options.
-- An id or after holding <v> (a voice's number) or <v0> (its engine index)
-- stands for one entry a voice (h.voice_entries). One id may carry entries
-- of several kinds, one of each (group_size's add excepted); removed stands
-- alone but beside added (a move). An entry naming an id the fixture lacks
-- (added aside), an added 3.7.0 id with no removed, an after no record has,
-- a kind that does not fit the param, another kind or no why raises.
-- An added record's t is norns' type code, named from the stubs' one
-- table of them (params is not loaded when this list is built, #839)
local T = h.stubs.PARAM_TYPE_CODES
local PARAM_FIXTURE_ALLOWED = {
  -- groundwork: MIDI note off is latch or release (the groundwork design §8)
  {kind = "options", id = "midi_note_off", options = {"latch", "release"},
    why = "groundwork: note off is latch or release (design section 8)"},
  -- 0b: the delay's line is a buffer, so its time reaches 5.4 s (design §0.2)
  {kind = "range", id = "delay_time", max = 5.4, why = "0b: the delay's line is a buffer, 5.4 s (design §0.2)"},
  -- 1a: plain sends (design §7.1): a dry level per voice, the returns are
  -- levels (the reverb's 0.43, 3.7's 0.3 / 0.7), the delay into the reverb
  {kind = "added", id = "v<v>_dry", after = "v<v>_filter_mix", why = "1a: each voice's dry level (design section 7.1)",
    record = {t = T.control, name = "dry", default = 1, min = 0, max = 1, warp = "lin", step = 0.01, quantum = 0.01, units = "",
      string = "100 %"}},
  {kind = "added", id = "delay_to_reverb", after = "reverb_bypass", why = "1a: the delay into the reverb (design section 7.1)",
    record = {t = T.control, name = "delay to reverb", default = 1, min = 0, max = 1, warp = "lin", step = 0.01, quantum = 0.01,
      units = "", string = "100 %"}},
  {kind = "group_size", id = "strata_fx", add = 1, why = "1a: delay_to_reverb joins the fx group"},
  {kind = "default", id = "reverb_mix", default = 0.43, why = "1a: the reverb's level starts at 0.3 / 0.7 (design section 7.1)"},
  {kind = "name", id = "delay_mix", name = "delay level", why = "1a: the delay's mix is its return's level"},
  {kind = "name", id = "reverb_mix", name = "reverb level", why = "1a: the reverb's mix is its return's level"},
  -- 1b: the delay's freeze and clear (design §7.2, §7.3)
  {kind = "added", id = "delay_freeze", after = "delay_pingpong", why = "1b: the delay's freeze (design section 7.3)",
    record = {t = T.binary, name = "delay freeze", default = 0}},
  {kind = "added", id = "delay_clear", after = "delay_freeze", why = "1b: the delay's clear (design section 7.2)",
    record = {t = T.trigger, name = "delay clear"}},
  {kind = "group_size", id = "strata_fx", add = 2, why = "1b: delay_freeze and delay_clear join the fx group"},
  -- 2a: shimmer's interval and two amounts (design §7.4)
  {kind = "added", id = "shimmer_interval", after = "delay_clear", why = "2a: shimmer's interval (design section 7.4)",
    record = {t = T.option, name = "shimmer interval", default = 3, options = {"oct down", "fifth", "octave", "oct+5th", "2 oct"}}},
  {kind = "added", id = "shimmer_delay", after = "shimmer_interval", why = "2a: shimmer in the delay (design section 7.4)",
    record = {t = T.control, name = "shimmer delay", default = 0, min = 0, max = 1, warp = "lin", step = 0.01, quantum = 0.01,
      units = "", string = "0 %"}},
  {kind = "added", id = "shimmer_reverb", after = "shimmer_delay", why = "2a: shimmer around the reverb (design section 7.4)",
    record = {t = T.control, name = "shimmer reverb", default = 0, min = 0, max = 1, warp = "lin", step = 0.01, quantum = 0.01,
      units = "", string = "0 %"}},
  {kind = "group_size", id = "strata_fx", add = 3, why = "2a: shimmer's three params join the fx group"},
  -- 1c: the grain envelope goes; the window's shape and skew, probability,
  -- the cloud and its overlap and the pan wander join each voice's extras
  -- (design §4.1, §4.2, §4.4, §4.5)
  {kind = "removed", id = "v<v>_grain_env", why = "1c: the five grain envelopes are gone (design §4.1)"},
  {kind = "added", id = "v<v>_grain_shape", after = "voice <v> extras", why = "1c: the window's shape (design §4.1)",
    record = {t = T.control, name = "grain shape", default = 0.57, min = 0, max = 1, warp = "lin", step = 0.01,
      quantum = 0.01, units = "", string = "0.57"}},
  {kind = "added", id = "v<v>_grain_skew", after = "v<v>_grain_shape", why = "1c: the window's skew (design §4.1)",
    record = {t = T.control, name = "grain skew", default = 0, min = -1, max = 1, warp = "lin", step = 0.01,
      quantum = 0.01, units = "", string = "0.00"}},
  {kind = "added", id = "v<v>_grain_prob", after = "v<v>_grain_skew", why = "1c: the grains' probability (design §4.2)",
    record = {t = T.control, name = "grain prob", default = 100, min = 0, max = 100, warp = "lin", step = 1,
      quantum = 0.01, units = "%", string = "100 %"}},
  {kind = "added", id = "v<v>_grain_cloud", after = "v<v>_grain_prob", why = "1c: the cloud mode (design §4.4)",
    record = {t = T.option, name = "grain cloud", default = 1, options = {"density", "overlap"}}},
  {kind = "added", id = "v<v>_grain_overlap", after = "v<v>_grain_cloud", why = "1c: the overlap cloud's overlap (design §4.4)",
    record = {t = T.control, name = "grain overlap", default = 2, min = 0.25, max = 16, warp = "exp", step = 0,
      quantum = 0.01, units = "x", string = "2.00 x"}},
  {kind = "added", id = "v<v>_pan_wander", after = "v<v>_grain_overlap", why = "1c: the pan wander (design §4.5)",
    record = {t = T.control, name = "pan wander", default = 50, min = 0, max = 100, warp = "lin", step = 1,
      quantum = 0.01, units = "%", string = "50 %"}},
  -- 1e: the tuning (design §6.3, §6.4): scale gains custom at its end, the
  -- custom scale's mask and the tuning's two text params join the scale's
  -- params, before every voice
  {kind = "options", id = "scale", why = "1e: custom, the scale held as a mask, appended (design section 6.3)",
    options = (function()
      local options = {}
      for _, record in ipairs(dofile(h.repo_root .. "/test/fixtures/3.7.0-params.lua")) do
        if record.id == "scale" then
          for index, name in ipairs(record.options) do options[index] = name end
        end
      end
      options[#options + 1] = "custom"
      return options
    end)()},
  {kind = "added", id = "scale_mask", after = "root", why = "1e: the custom scale's mask (design section 6.3)",
    record = {t = T.number, name = "scale mask", default = 4095, min = 1, max = 4095}},
  {kind = "added", id = "tuning_name", after = "scale_mask", why = "1e: the tuning's name (design section 6.4)",
    record = {t = T.text, name = "tuning", default = "12 equal"}},
  {kind = "added", id = "tuning_tones", after = "tuning_name", why = "1e: the tuning's tones (design section 6.4)",
    record = {t = T.text, name = "tuning tones", default = "1200 0 100 200 300 400 500 600 700 800 900 1000 1100"}},
  -- 1d: the voice sources join the source's options at their end (ruling
  -- P8), and an input voice's channel follows its history (design §5)
  {kind = "options", id = "v<v>_source", options = {"synth", "buf 1", "buf 2", "buf 3", "buf 4", "buf 5", "buf 6", "buf 7",
    "buf 8", "input", "voice 1", "voice 2", "voice 3", "voice 4", "voice 5", "voice 6", "voice 7"},
    why = "1d: a voice can grain another voice's output ring, or its own (design section 5)"},
  {kind = "added", id = "v<v>_input_channel", after = "v<v>_history", why = "1d: an input voice reads stereo, left or right (design section 5)",
    record = {t = T.option, name = "input channel", default = 1, options = {"stereo", "left", "right"}}},
  -- 2b: the arpeggiator (design §4.3)
  {kind = "added", id = "v<v>_arp", after = "v<v>_release", why = "2b: each voice's arpeggiator (design section 4.3)",
    record = {t = T.option, name = "arp", default = 1, options = {"off", "up", "down", "up-down", "shuffle"}}},
}
-- 2b: an LFO's destination is its home routing in the matrix (design §4);
-- its six LFOs' entries follow the list (an LFO is no voice token)
for n = 1, 6 do
  local why = "2b: LFO " .. n .. "'s destination is its home routing in the matrix (slot " .. (16 + n) .. ")"
  table.insert(PARAM_FIXTURE_ALLOWED, {kind = "removed", id = "strata_lfo" .. n .. "_dest", why = why})
  table.insert(PARAM_FIXTURE_ALLOWED, {kind = "removed", id = "strata_lfo" .. n .. "_dest_key", why = why})
  table.insert(PARAM_FIXTURE_ALLOWED, {kind = "group_size", id = "strata_lfo_" .. n, n = 12, why = why})
end

-- 0d: a voice's type and every type's synth keys on every voice (design
-- §2.2). Generated from S.lib.types once a build is loaded, so a type
-- package adds nothing here: per voice, v<i>_type after its heading, and
-- each synth key its default type lacks after the param this build has
-- before it, with its type, name and spec (its default the default
-- type's, else the first type's that has the key)
local function type_allowances(S)
  local types, entries = S.lib.types, {}
  for voice = 1, S.constants.NUM_VOICES do
    local own = types.record(types.default_key(voice))
    local why = "0d: voice " .. voice .. " has a type and every type's synth keys (design section 2.2)"
    local names = {}
    for index, record in ipairs(types.list()) do names[index] = record.name end
    local function before(id) return params.params[params.lookup[id] - 1].id end
    local id = "v" .. voice .. "_type"
    entries[#entries + 1] = {kind = "added", id = id, after = before(id), why = why,
      record = {t = params.tOPTION, name = "type", default = own.index, options = names}}
    for _, key in ipairs(types.keys()) do
      if own.defaults[key] == nil then
        local spec, default = types.spec(key), nil
        for _, record in ipairs(types.list()) do
          if default == nil then default = record.defaults[key] end
        end
        local format = types.format(key)
        id = "v" .. voice .. "_" .. key
        entries[#entries + 1] = {kind = "added", id = id, after = before(id), why = why,
          record = {t = params.tCONTROL, name = key, default = default, min = spec.minval, max = spec.maxval,
            warp = spec.warp_name, step = spec.step, quantum = spec.quantum, units = spec.units,
            string = format and string.format(format, default) or nil}}
      end
    end
  end
  return entries
end

-- PARAM_FIXTURE_ALLOWED with the allowances generated from a loaded build
local function build_allowances(S)
  local entries = {}
  for _, entry in ipairs(PARAM_FIXTURE_ALLOWED) do entries[#entries + 1] = entry end
  for _, entry in ipairs(type_allowances(S)) do entries[#entries + 1] = entry end
  return entries
end

-- The fixture's records as this build should have them: a copy of each,
-- the allowed differences applied. An added record carries `only`, the
-- set of fields its entry gives, and first_param_difference compares
-- those alone (its id and place always)
local PARAM_FIXTURE_KINDS = {removed = true, group_size = true, options = true, added = true, default = true,
  name = true, range = true}
local PARAM_FIXTURE_FIELD_SET = {}
for _, field in ipairs(PARAM_FIXTURE_FIELDS) do PARAM_FIXTURE_FIELD_SET[field] = true end
local function added_record(entry, where)
  local record = entry.record
  if type(record) ~= "table" or record.t == nil or type(record.name) ~= "string" then
    error(where .. ": an added record needs t and name", 3)
  end
  if type(entry.after) ~= "string" then error(where .. ": an added entry needs after", 3) end
  local copy, only = {id = entry.id}, {id = true}
  for field, value in pairs(record) do
    if field == "id" or not PARAM_FIXTURE_FIELD_SET[field] then
      error(where .. ": an added record has no field " .. tostring(field), 3)
    end
    copy[field], only[field] = value, true
  end
  copy.only = only
  return copy
end
local function allowed_records(fixture, allowed)
  local known = {}
  for _, record in ipairs(fixture) do known[record.id] = record end
  local kinds, removed, changes, sizes, added = {}, {}, {}, {}, {}
  for index, listed in ipairs(allowed) do
    -- an entry whose id or after holds <v> or <v0> stands for one a voice
    for _, entry in ipairs(h.voice_entries(listed, {"id", "after"})) do
      local where = "allowed difference " .. index .. " (" .. tostring(entry.id) .. ")"
      if type(entry.why) ~= "string" or entry.why == "" then error(where .. " says no why", 2) end
      local kind = entry.kind
      if not PARAM_FIXTURE_KINDS[kind] then error(where .. ": no kind " .. tostring(kind), 2) end
      local id = entry.id
      kinds[id] = kinds[id] or {}
      if kinds[id][kind] and not (kind == "group_size" and entry.add ~= nil) then
        error(where .. ": a second " .. kind .. " entry for the param", 2)
      end
      kinds[id][kind] = true
      local record = known[id]
      changes[id] = changes[id] or {}
      if kind == "added" then
        added[#added + 1] = {after = entry.after, record = added_record(entry, where), where = where}
      elseif not record then
        error(where .. ": 3.7.0 has no such param", 2)
      elseif kind == "removed" then
        removed[id] = true
      elseif kind == "group_size" then
        if record.t ~= params.tGROUP then error(where .. ": a group size for a param that is no group", 2) end
        local size = sizes[id] or {}
        sizes[id] = size
        if (entry.n == nil) == (entry.add == nil) then error(where .. ": a group size gives n or add", 2) end
        if entry.n ~= nil then size.n = entry.n else size.add = (size.add or 0) + entry.add end
        if size.n and size.add then error(where .. ": n beside add for one group", 2) end
      elseif kind == "options" then
        if record.t ~= params.tOPTION then error(where .. ": options for a param that is no option", 2) end
        changes[id].options = entry.options
      elseif kind == "default" then
        if record.t == params.tSEPARATOR or record.t == params.tGROUP then error(where .. ": no default to change", 2) end
        if entry.default == nil then error(where .. ": a default entry gives the default", 2) end
        changes[id].default = entry.default
        if entry.string ~= nil then changes[id].string = entry.string end
      elseif kind == "name" then
        if type(entry.name) ~= "string" then error(where .. ": a name entry gives the name", 2) end
        changes[id].name = entry.name
      elseif kind == "range" then
        if record.t ~= params.tCONTROL and record.t ~= params.tNUMBER then
          error(where .. ": a range for a param that is no control or number", 2)
        end
        if entry.min == nil and entry.max == nil then error(where .. ": a range gives min, max or both", 2) end
        if entry.min ~= nil then changes[id].min = entry.min end
        if entry.max ~= nil then changes[id].max = entry.max end
      end
    end
  end
  -- removed stands alone, but for added (a move); an added 3.7.0 id needs its removed
  for id, set in pairs(kinds) do
    for kind in pairs(set) do
      if set.removed and kind ~= "removed" and kind ~= "added" then
        error("allowed differences (" .. id .. "): removed beside " .. kind, 2)
      end
    end
    if set.added and known[id] and not set.removed then
      error("allowed differences (" .. id .. "): 3.7.0 has the param, and an added one needs its removed", 2)
    end
  end
  for id, size in pairs(sizes) do changes[id].n = size.n or (known[id].n + size.add) end
  -- the records in order: each record kept, then what is placed after it
  -- (in the list's order, each followed by what is placed after it)
  local followers, records, placed = {}, {}, {}
  for _, item in ipairs(added) do
    followers[item.after] = followers[item.after] or {}
    table.insert(followers[item.after], item)
  end
  local function place(id)
    for _, item in ipairs(followers[id] or {}) do
      placed[item] = true
      records[#records + 1] = item.record
      place(item.record.id)
    end
  end
  for _, record in ipairs(fixture) do
    if not removed[record.id] then
      local copy = {}
      for field, value in pairs(record) do copy[field] = value end
      for field, value in pairs(changes[record.id] or {}) do copy[field] = value end
      records[#records + 1] = copy
      place(record.id)
    end
  end
  for _, item in ipairs(added) do
    if not placed[item] then error(item.where .. ": no record " .. item.after .. " to follow", 2) end
  end
  return records
end

-- The first difference between the expected records and this build's, as
-- a line, or nil when every record and field agrees
local function first_param_difference(expected, actual)
  for index = 1, math.max(#expected, #actual) do
    local want, got = expected[index], actual[index]
    if want == nil or got == nil then
      return "param " .. index .. ": 3.7.0 had " .. tostring(want and want.id) .. ", this build "
        .. tostring(got and got.id)
    end
    for _, field in ipairs(PARAM_FIXTURE_FIELDS) do
      if (not want.only or want.only[field]) and field_text(got[field]) ~= field_text(want[field]) then
        return "param " .. index .. " (" .. want.id .. ")'s " .. field .. ": expected " .. field_text(want[field])
          .. ", got " .. field_text(got[field])
      end
    end
  end
  return nil
end

test("every param's id, type, name, default and spec is 3.7.0's, in order", function()
  math.randomseed(37)
  local first
  local context = load_strata({before_load = function() first = #params.params + 1 end})
  finish_startup(context)
  local fixture = dofile(h.repo_root .. "/test/fixtures/3.7.0-params.lua")
  local actual = {}
  for index = first, #params.params do actual[#actual + 1] = fixture_record(params.params[index], context.audio_dir) end
  local difference = first_param_difference(allowed_records(fixture, build_allowances(local_value("S"))), actual)
  if difference then h.fail(difference) end
end)

test("the fixture comparison honors each kind of allowed difference, and only those", function()
  local fixture = {
    {id = "head", t = params.tSEPARATOR, name = "head"},
    {id = "lfo", t = params.tGROUP, name = "lfo", n = 3},
    {id = "mode", t = params.tOPTION, name = "mode", default = 1, options = {"a", "b", "c"}},
    {id = "gone", t = params.tNUMBER, name = "gone", default = 0, min = 0, max = 4},
    {id = "kept", t = params.tNUMBER, name = "kept", default = 1, min = 0, max = 4},
  }
  local build = {
    {id = "head", t = params.tSEPARATOR, name = "head"},
    {id = "lfo", t = params.tGROUP, name = "lfo", n = 2},
    {id = "mode", t = params.tOPTION, name = "mode", default = 1, options = {"a", "b"}},
    {id = "kept", t = params.tNUMBER, name = "kept", default = 1, min = 0, max = 4},
  }
  local entries = {
    {kind = "removed", id = "gone", why = "a test"},
    {kind = "group_size", id = "lfo", n = 2, why = "a test"},
    {kind = "options", id = "mode", options = {"a", "b"}, why = "a test"},
  }
  assert_equal(first_param_difference(allowed_records(fixture, entries), build), nil, "every difference is allowed")
  assert_equal(#fixture, 5, "the fixture itself is left alone")
  assert_equal(fixture[2].n, 3, "its records too")
  -- an empty list is the plain comparison
  assert_equal(first_param_difference(allowed_records(fixture, {}), fixture), nil, "the fixture is itself")
  assert_true(first_param_difference(allowed_records(fixture, {}), build) ~= nil, "unlisted, the build differs")
  -- each difference with no entry still fails
  for left_out = 1, #entries do
    local others = {}
    for index, entry in ipairs(entries) do
      if index ~= left_out then others[#others + 1] = entry end
    end
    assert_true(first_param_difference(allowed_records(fixture, others), build) ~= nil,
      entries[left_out].kind .. " left out: the build differs")
  end
  -- an entry allows only what it says
  local wrong_size = {entries[1], {kind = "group_size", id = "lfo", n = 4, why = "a test"}, entries[3]}
  assert_true(first_param_difference(allowed_records(fixture, wrong_size), build) ~= nil, "another size fails")
  -- an entry naming no 3.7.0 param, of no kind, or without why raises
  assert_true(not pcall(allowed_records, fixture, {{kind = "removed", id = "never", why = "a test"}}), "no such id")
  assert_true(not pcall(allowed_records, fixture, {{kind = "renamed", id = "kept", why = "a test"}}), "no such kind")
  assert_true(not pcall(allowed_records, fixture, {{kind = "removed", id = "gone"}}), "no why")
  -- an entry's kind must fit its param's type, and one id has one entry
  assert_true(not pcall(allowed_records, fixture, {{kind = "group_size", id = "mode", n = 2, why = "a test"}}),
    "a group size on an option")
  assert_true(not pcall(allowed_records, fixture, {{kind = "options", id = "lfo", options = {"a"}, why = "a test"}}),
    "options on a group")
  assert_true(not pcall(allowed_records, fixture, {entries[3], {kind = "removed", id = "mode", why = "a test"}}),
    "removed beside another kind for one id")
  assert_true(not pcall(allowed_records, fixture, {entries[3], {kind = "options", id = "mode", options = {"a"}, why = "a test"}}),
    "two entries of one kind for one id")
end)

-- 3.8's package 0g: the kinds a later package names its difference with
-- (added, default, name, range, group_size's add form), each the only
-- difference between a small fixture and build, and their misuses
test("the fixture comparison honors added, default, name, range and a group's add, and only those", function()
  local NUM_VOICES = h.voice_count()
  local fixture = {
    {id = "head", t = params.tSEPARATOR, name = "head"},
    {id = "shift", t = params.tNUMBER, name = "shift", default = 0, min = 0, max = 2},
    {id = "fx", t = params.tGROUP, name = "fx", n = 2},
    {id = "level", t = params.tCONTROL, name = "level", default = 1, min = 0, max = 4, warp = "lin", step = 0,
      quantum = 0.01, units = "", string = "1 dB"},
    {id = "label", t = params.tNUMBER, name = "label", default = 0, min = 0, max = 1},
    {id = "span", t = params.tNUMBER, name = "span", default = 1, min = 0, max = 4},
    {id = "kept", t = params.tNUMBER, name = "kept", default = 1, min = 0, max = 4},
  }
  for voice = 1, NUM_VOICES do
    fixture[#fixture + 1] = {id = "v" .. voice .. "_y", t = params.tBINARY, name = "y", default = 0}
  end
  local build = {
    {id = "head", t = params.tSEPARATOR, name = "head"},
    {id = "fx", t = params.tGROUP, name = "fx", n = 4},
    {id = "level", t = params.tCONTROL, name = "level", default = 2, min = 0, max = 4, warp = "lin", step = 0,
      quantum = 0.01, units = "", string = "2 dB"},
    {id = "label", t = params.tNUMBER, name = "tag", default = 0, min = 0, max = 1},
    {id = "span", t = params.tNUMBER, name = "span", default = 1, min = 0, max = 8},
    {id = "shift", t = params.tNUMBER, name = "shift", default = 0, min = 0, max = 2},
    {id = "kept", t = params.tNUMBER, name = "kept", default = 1, min = 0, max = 4},
    -- the fields an added record leaves out are not compared
    {id = "new", t = params.tNUMBER, name = "new", default = 0, min = 0, max = 9},
    {id = "new2", t = params.tBINARY, name = "new2", default = 1},
  }
  for voice = 1, NUM_VOICES do
    build[#build + 1] = {id = "v" .. voice .. "_y", t = params.tBINARY, name = "y", default = 0}
    build[#build + 1] = {id = "v" .. voice .. "_x", t = params.tBINARY, name = "x", default = 0}
  end
  local entries = {
    {kind = "added", id = "new", after = "kept", record = {t = params.tNUMBER, name = "new", default = 0}, why = "a test"},
    {kind = "added", id = "new2", after = "kept", record = {t = params.tBINARY, name = "new2"}, why = "a test"},
    {kind = "default", id = "level", default = 2, string = "2 dB", why = "a test"},
    {kind = "name", id = "label", name = "tag", why = "a test"},
    {kind = "range", id = "span", max = 8, why = "a test"},
    {kind = "group_size", id = "fx", add = 1, why = "a test"},
    {kind = "group_size", id = "fx", add = 1, why = "another test"},
    {kind = "added", id = "v<v>_x", after = "v<v>_y", record = {t = params.tBINARY, name = "x"}, why = "a test"},
    -- a move: removed and added for one id
    {kind = "removed", id = "shift", why = "a test"},
    {kind = "added", id = "shift", after = "span", record = {t = params.tNUMBER, name = "shift", default = 0, min = 0,
      max = 2}, why = "a test"},
  }
  local function differs(allowed)
    local ok, records = pcall(allowed_records, fixture, allowed)
    return not ok or first_param_difference(records, build) ~= nil
  end
  assert_equal(first_param_difference(allowed_records(fixture, entries), build), nil, "every difference is allowed")
  assert_equal(fixture[4].default, 1, "the fixture itself is left alone")
  -- each entry left out fails: raises, or the build differs
  for left_out = 1, #entries do
    local others = {}
    for index, entry in ipairs(entries) do
      if index ~= left_out then others[#others + 1] = entry end
    end
    assert_true(differs(others), entries[left_out].kind .. " " .. entries[left_out].id .. " left out: the build differs")
  end
  -- an entry allows only what it says
  local function with(index, entry)
    local copy = {}
    for at, item in ipairs(entries) do copy[at] = at == index and entry or item end
    return copy
  end
  assert_true(differs(with(1, {kind = "added", id = "new", after = "kept", record = {t = params.tNUMBER, name = "new",
    default = 1}, why = "a test"})), "an added record's fields are compared")
  assert_true(differs(with(2, {kind = "added", id = "new2", after = "head", record = {t = params.tBINARY,
    name = "new2"}, why = "a test"})), "an added record's place is compared")
  assert_true(differs(with(3, {kind = "default", id = "level", default = 2, why = "a test"})),
    "a default without its string leaves the old string")
  assert_true(differs(with(5, {kind = "range", id = "span", min = 1, why = "a test"})), "a range sets only its bounds")
  -- a token entry stands for one entry a voice: a build without the last voice's param differs
  local last_x = table.remove(build)
  assert_equal(last_x.id, "v" .. NUM_VOICES .. "_x", "the build's last record")
  assert_true(differs(entries), "the token entry asks for every voice's param")
  build[#build + 1] = last_x
  -- several added after one id keep the list's order
  local swapped = with(1, entries[2])
  swapped[2] = entries[1]
  assert_true(differs(swapped), "two added after one id, swapped, differ")
  -- each misuse raises
  local function raises(allowed) return not pcall(allowed_records, fixture, allowed) end
  assert_true(raises(with(1, {kind = "added", id = "new", after = "nowhere", record = {t = params.tNUMBER,
    name = "new"}, why = "a test"})), "an after naming nothing")
  assert_true(raises(with(1, {kind = "added", id = "new", after = "kept", record = {name = "new"}, why = "a test"})),
    "an added record without t")
  assert_true(raises(with(1, {kind = "added", id = "new", after = "kept", record = {t = params.tNUMBER}, why = "a test"})),
    "an added record without a name")
  assert_true(raises(with(1, {kind = "added", id = "new", after = "kept", record = {t = params.tNUMBER, name = "new",
    hue = 1}, why = "a test"})), "an added record with a field the fixture has not")
  assert_true(raises({entries[5], {kind = "range", id = "span", min = 1, why = "a test"}}), "two range entries for one id")
  assert_true(raises({{kind = "group_size", id = "fx", n = 4, add = 2, why = "a test"}}), "n beside add")
  assert_true(raises({{kind = "group_size", id = "fx", n = 3, why = "a test"}, entries[6]}), "an n entry and an add entry")
  assert_true(raises({{kind = "added", id = "kept", after = "head", record = {t = params.tNUMBER, name = "kept"},
    why = "a test"}}), "added for a 3.7.0 id with no removed")
  assert_true(raises({{kind = "removed", id = "label", why = "a test"}, entries[4]}), "removed beside a name")
  assert_true(raises({{kind = "range", id = "level"}}), "no why")
  assert_true(raises({{kind = "range", id = "head", max = 2, why = "a test"}}), "a range for a separator")
  assert_true(raises({{kind = "name", id = "never", name = "x", why = "a test"}}), "a name for no 3.7.0 param")
  assert_true(raises({{kind = "default", id = "kept", why = "a test"}}), "a default entry with no default")
end)

-- The groundwork before 3.8 (ruling 5): a voice's scene keys, each with
-- its param's default
test("every voice_scene_keys default equals its param's default", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    local list, by_key = S.lib.params_setup.voice_scene_keys(voice)
    assert_true(#list > 0, "voice " .. voice .. " has scene keys")
    local seen = 0
    for _, entry in ipairs(list) do
      local id = "v" .. voice .. "_" .. entry.key
      assert_equal(by_key[entry.key], entry, id .. ": by_key holds the list's entry")
      local param = params:lookup_param(id)
      local default = param.controlspec and param.controlspec.default or param.default
      assert_equal(entry.default, default, id .. "'s scene default is its param's")
      if entry.range then
        assert_true(entry.range[1] <= default and default <= entry.range[2], id .. ": the default is in its range")
      end
      seen = seen + 1
    end
    local count = 0
    for _ in pairs(by_key) do count = count + 1 end
    assert_equal(count, seen, "voice " .. voice .. ": no key twice")
    assert_equal(by_key.solo, nil, "solo is no scene key")
    assert_equal(by_key.note_cap, nil, "note_cap is no scene key")
  end
  assert_true(not pcall(S.lib.params_setup.voice_scene_keys, 0), "no voice 0")
end)

-- The groundwork before 3.8 (package 2a, ruling 14): the grain mode goes
-- out through send_param_to_engine, as an option index - 1, and only while
-- the voice runs (3.8 1c: the envelope it went with is gone)
test("grain_mode sends grainMode x - 1, only while running", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active and not S.voices[3].active, "voice 1 runs, voice 3 is stopped")
  assert_true(S.engine_senders.v1_grain_mode ~= nil, "it has an engine sender")
  context.clear_engine_calls()
  params:set("v1_grain_mode", 2)
  local sent = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do sent[#sent + 1] = table.concat(call.args, " ") end
  assert_equal(table.concat(sent, ","), "0 grainMode 1", "once, as an index from 0")
  assert_equal(S.engine_param_values.v1_grain_mode, 2, "recorded as sent")
  context.clear_engine_calls()
  params:set("v3_grain_mode", 2)
  assert_equal(#context.calls_named("setGrainParam"), 0, "a stopped voice gets nothing")
  assert_equal(S.voices[3].values.grain_mode, 2, "but stores it")
end)

test("mod_source sends setModSource through engine_mod_source, only while running", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.engine_senders.v1_mod_source_2 ~= nil, "a mod source has an engine sender")
  context.clear_engine_calls()
  params:set("v1_mod_source_2", 5)
  params:set("v1_mod_source_2", 0)
  local sent = {}
  for _, call in ipairs(context.calls_named("setModSource")) do sent[#sent + 1] = table.concat(call.args, " ") end
  assert_equal(table.concat(sent, ","), "0 2 4,0 2 -1", "voice 5 as engine voice 4, none as -1")
  assert_equal(S.engine_param_values.v1_mod_source_2, 0, "recorded as sent")
  context.clear_engine_calls()
  params:set("v3_mod_source_1", 2)
  assert_equal(#context.calls_named("setModSource"), 0, "a stopped voice gets nothing")
  assert_equal(S.voices[3].values.mod_source_1, 2, "but stores it")
end)

-- #318, ruling 15: the synth record's add turns its filtered keys' own
-- delta into a turn; no other record's
test("the PARAMS menu's own delta turns freq but not expression's press target", function()
  load_strata()
  local S = local_value("S")
  assert_equal(type(S.lib.params_setup.turn_on_own_delta), "function", "exported")
  local turned = {}
  for _, key in ipairs({ "freq", "press_target" }) do
    local filter = S.registry.param_filters[key]
    S.registry.param_filters[key] = function(voice_idx, value, previous, turn)
      turned[key] = turn
      return filter(voice_idx, value, previous, turn)
    end
  end
  params:lookup_param("v1_freq"):delta(1)
  assert_equal(turned.freq, true, "freq's own delta is a turn")
  params:lookup_param("v1_press_target"):delta(1)
  assert_equal(turned.press_target, false, "press_target's is not")
end)

-- 3.8 (4d): the read hook's two halves, exported for the factory sets'
-- load, which defaults a set's missing lines as a PSET read does
test("record_param_ids lists Strata's record params in menu order; load_default is the read hook's", function()
  load_strata()
  local setup = local_value("S").lib.params_setup
  local ids = setup.record_param_ids()
  local position = {}
  for index, id in ipairs(ids) do position[id] = index end
  assert_true(position.master_density ~= nil and position.v1_freq ~= nil, "Strata's params are listed")
  assert_equal(position.clock_tempo, nil, "norns' own are not")
  assert_equal(position.output_level, nil)
  local last = 0
  for _, param in ipairs(params.params) do
    if param.id and position[param.id] then
      assert_true(position[param.id] > last, param.id .. " in menu order")
      last = position[param.id]
    end
  end
  assert_equal(#ids, last, "each once")
  ids[1] = "changed"
  assert_true(setup.record_param_ids()[1] ~= "changed", "a copy each call")
  local lookup = function(id) return params:lookup_param(id) end
  assert_equal(setup.load_default(lookup("v1_grain_size")), 0.1, "a control: its default")
  assert_equal(setup.load_default(lookup("v1_seq_length")), 16, "a number")
  assert_equal(setup.load_default(lookup("scale")), 1, "an option")
  assert_equal(setup.load_default(lookup("v1_quantize")), 0, "a binary that is no trigger")
  assert_equal(setup.load_default(lookup("tuning_name")), "12 equal", "a text param 1e gave a default")
  assert_equal(setup.load_default(lookup("delay_freeze")), nil, "a param saved nowhere: none")
  assert_equal(setup.load_default(lookup("delay_clear")), nil, "a trigger: none")
  assert_equal(setup.load_default(lookup("buf1_file")), nil, "a file param: none")
end)

end

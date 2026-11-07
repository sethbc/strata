-- test/unit/engine_sync_test.lua
-- Engine sync: starting a voice sends its full state, grain values, source
-- switches (lib/engine_sync.lua)
-- Run alone: lua test/run.lua engine_sync

return function(h)
local test, SC_PATH, assert_true, assert_equal = h.test, h.SC_PATH, h.assert_true, h.assert_equal
local assert_near, load_strata, local_value = h.assert_near, h.load_strata, h.local_value
local finish_startup, wake, scramble_state = h.finish_startup, h.wake, h.scramble_state
local engine_state_for_voice = h.engine_state_for_voice

test("starting a voice sends its complete state to the engine (C1, C2)", function()
  local context = load_strata()
  finish_startup(context)
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
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  if voices[5].active then toggle_voice(5) end
  params:set("v5_grain_density", 20); params:set("master_density", 1.5)
  -- as LFOs on both params would have left them
  local sent_values = local_value("engine_param_values")
  sent_values.master_density = 0.5; sent_values.v5_grain_density = 30
  context.clear_engine_calls(); toggle_voice(5)
  assert_near(context.calls_named("voiceOn")[1].args[6], 15, 1e-9, "voiceOn grainDensity")
end)

test("the largest grain overlap Lua can send fits the engine's maxGrains", function()
  load_strata()
  local file = assert(io.open(SC_PATH, "r")); local source = file:read("*a"); file:close()
  local max_grains = tonumber(source:match("var <maxGrains = (%d+);"))
  assert_true(max_grains ~= nil, "the engine declares var <maxGrains = <n>;")
  local master_max = params:lookup_param("master_density").controlspec.maxval
  for voice_idx = 1, 7 do
    local size_max = params:lookup_param("v" .. voice_idx .. "_grain_size").controlspec.maxval
    local density_max = params:lookup_param("v" .. voice_idx .. "_grain_density").controlspec.maxval
    -- a GrainIn/GrainBuf runs at most maxGrains - 1 grains and drops the rest
    assert_true(size_max * density_max * master_max <= max_grains - 1,
      string.format("voice %d: %.2f s x %d x %.1f = %.0f overlapping grains fit maxGrains %d",
        voice_idx, size_max, density_max, master_max, size_max * density_max * master_max, max_grains))
  end
end)

test("grain envelope option reaches the engine and is synced on start", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_grain_env", 3)
  local calls = context.calls_named("setGrainParam"); local last = calls[#calls]
  assert_equal(last.args[2], "envShape"); assert_equal(last.args[3], 2)
  toggle_voice(3); params:set("v3_grain_env", 5); toggle_voice(3)       -- on, edit, off
  context.clear_engine_calls(); toggle_voice(3)                          -- on again: synced
  local sent = engine_state_for_voice(context.engine_calls, 2)
  assert_equal(sent.grain.envShape, 4)
  capture_scene(1); params:set("v1_grain_env", 1)
  recall_scene(1, 2); wake(context, "scene_transition_clock")
  assert_equal(params:get("v1_grain_env"), 1, "transition does not interpolate env")
  recall_scene(1, 0); assert_equal(params:get("v1_grain_env"), 3)
  -- an option param floors fractional values, so check the fade list directly
  for _, target in ipairs(scene_transition_targets(local_value("scenes")[1].data)) do
    assert_true(not target.id:find("_grain_env$"), target.id .. " is not crossfaded")
  end
end)

test("grain mode option is sent, synced and never mutated", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_grain_mode", 2)
  local calls = context.calls_named("setGrainParam"); assert_equal(calls[#calls].args[2], "grainMode"); assert_equal(calls[#calls].args[3], 1)
  params:set("mutation_probability", 1); params:set("mutation_amount", 1); gentle_mutate()
  assert_equal(params:get("v1_grain_mode"), 2)
end)

test("source switching syncs through setGrainSource and swaps the main param", function()
  local context = load_strata(); finish_startup(context)
  context.clear_engine_calls(); params:set("v1_source", 4)      -- buf 3
  local calls = context.calls_named("setGrainSource")
  assert_equal(#calls, 1, "one setGrainSource per switch")
  assert_equal(calls[1].args[1], 0); assert_equal(calls[1].args[2], 3)
  assert_equal(main_param_id(1), "v1_buf_pos"); assert_equal(main_param_label(1), "pos")
  params:set("v1_source", 10); calls = context.calls_named("setGrainSource"); assert_equal(calls[#calls].args[2], 9)
  assert_equal(main_param_id(1), "v1_grain_size", "input source shows grain size (a 3.0 decision: its buffer params are dead too)")
  params:set("v1_source", 1); assert_equal(main_param_id(1), "v1_freq")
  -- a stopped voice's source is sent at once (so voiceOn builds the right synths) and nothing else is
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


test("toggle_lock locks and unlocks a voice", function()
  local context = load_strata()
  finish_startup(context)
  local frozen = local_value("frozen")
  local before = frozen[3] and true or false
  toggle_lock(3); assert_true(frozen[3] == not before)
  toggle_lock(3); assert_true(frozen[3] == before)
  toggle_lock(99); toggle_lock(0)  -- ignored
  assert_true(frozen[99] == nil and frozen[0] == nil, "out-of-range voices never grow the table")
  assert_true(toggle_freeze == nil, "toggle_freeze is gone")
end)

test("no Lua file says freeze for the lock feature", function()
  local banned = { "toggle_freeze", "%[FREEZE%]", "%[F%]", "_freeze%(", "start_or_freeze" }
  for _, source in ipairs(h.read_lua_sources()) do
    if not source.path:match("^test/") then
      local code = source.text:gsub("%-%-[^\n]*", "")
      for _, pattern in ipairs(banned) do
        assert_true(not code:find(pattern), source.path .. " still says " .. pattern)
      end
    end
  end
end)

test("each effect remembers its last non-zero mix", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  assert_equal(S.fx_last_mix.filter, 1); assert_equal(S.fx_last_mix.delay, 0.3)
  assert_equal(S.fx_last_mix.reverb, 0.3)
  params:set("delay_mix", 0.6); params:set("delay_mix", 0)
  assert_equal(S.fx_last_mix.delay, 0.6); assert_equal(S.fx_last_mix.reverb, 0.3)
  params:set("reverb_mix", 0.8); params:set("reverb_mix", 0)
  assert_equal(S.fx_last_mix.reverb, 0.8)
  params:set("filter_mix", 0.4); params:set("filter_mix", 0)
  assert_equal(S.fx_last_mix.filter, 0.4)
  assert_equal(S.fx_last_mix.delay, 0.6, "other effects keep theirs")
end)

end

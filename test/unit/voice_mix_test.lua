-- test/unit/voice_mix_test.lua
-- The voice filter and sends and the effects' bypass (lib/voice_mix.lua):
-- the params, their grain keys and the sync, the scene fields, the VOICE
-- section, the LFO destinations, the bypass params (PSETs, never scenes,
-- independent of the mixes) and what randomize, mutation and the faders
-- leave.
-- Run alone: lua test/run.lua voice_mix

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake

local KEYS = {"filter_type", "filter_freq", "filter_res", "filter_mix", "delay_send", "reverb_send"}
local ENGINE_NAMES = {filter_type = "filterType", filter_freq = "filterFreq", filter_res = "filterRes",
  filter_mix = "filterMix", delay_send = "delaySend", reverb_send = "reverbSend"}

-- The setGrainParam values sent since the calls were cleared for one
-- engine grain param, as {voice (engine index), value}
local function sent_grain(context, name)
  local sent = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == name then table.insert(sent, {voice = call.args[1], value = call.args[3]}) end
  end
  return sent
end

local function scene_holds(value, needle, seen)
  seen = seen or {}
  if type(value) ~= "table" or seen[value] then return false end
  seen[value] = true
  for key, entry in pairs(value) do
    if (type(key) == "string" and key:find(needle, 1, true)) or scene_holds(entry, needle, seen) then return true end
  end
  return false
end

test("voice filter and send params default to 3.0's chain and reach the engine", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.lib.voice_mix ~= nil, "S.lib.voice_mix is the module's table")
  local defaults = {filter_type = 1, filter_freq = 5000, filter_res = 0.5, filter_mix = 0, delay_send = 1,
    reverb_send = 1}
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, key in ipairs(KEYS) do
      local id = "v" .. voice_idx .. "_" .. key
      assert_near(params:get(id), defaults[key], 1e-9, id .. " default")
      assert_near(S.voices[voice_idx].extras[key], defaults[key], 1e-9, id .. " stored in extras")
    end
    assert_equal(params:string("v" .. voice_idx .. "_filter_type"), "lowpass")
    local low, high = param_range("v" .. voice_idx .. "_filter_freq")
    assert_equal(low, 20); assert_equal(high, 20000)
    assert_equal(params:lookup_param("v" .. voice_idx .. "_filter_freq").controlspec.warp_name, "exp",
      "the cutoff is exponential")
    for _, key in ipairs({"filter_res", "filter_mix", "delay_send", "reverb_send"}) do
      low, high = param_range("v" .. voice_idx .. "_" .. key)
      assert_equal(low, 0, key .. " from 0"); assert_equal(high, 1, key .. " to 1")
    end
  end
  -- a running voice gets each change as its grain param; the type as 0-2
  assert_true(S.voices[1].active and not S.voices[3].active, "voice 1 runs, voice 3 does not")
  for _, key in ipairs(KEYS) do
    context.clear_engine_calls()
    local value = key == "filter_type" and 3 or (key == "filter_freq" and 800 or 0.25)
    params:set("v1_" .. key, value)
    local sent = sent_grain(context, ENGINE_NAMES[key])
    assert_equal(#sent, 1, key .. ": one message")
    assert_equal(sent[1].voice, 0, key .. " to engine voice 0")
    assert_near(sent[1].value, key == "filter_type" and 2 or value, 1e-9, key .. " value sent")
  end
  -- a stopped voice stores it, and its start sends every value after the source
  context.clear_engine_calls()
  params:set("v3_filter_mix", 0.6); params:set("v3_reverb_send", 0.2); params:set("v3_filter_type", 2)
  assert_equal(#context.calls_named("setGrainParam"), 0, "a stopped voice gets no message")
  context.clear_engine_calls()
  toggle_voice(3)
  local source_at, found = nil, {}
  for index, call in ipairs(context.engine_calls) do
    if call.name == "setGrainSource" and call.args[1] == 2 then source_at = source_at or index end
    if call.name == "setGrainParam" and call.args[1] == 2 then
      for key, name in pairs(ENGINE_NAMES) do
        if call.args[2] == name then found[key] = {index = index, value = call.args[3]} end
      end
    end
  end
  for _, key in ipairs(KEYS) do
    assert_true(found[key] ~= nil and source_at < found[key].index, key .. " is sent after the source on start")
  end
  assert_near(found.filter_mix.value, 0.6, 1e-9); assert_near(found.reverb_send.value, 0.2, 1e-9)
  assert_equal(found.filter_type.value, 1, "highpass is engine type 1")
  assert_near(found.delay_send.value, 1, 1e-9, "an unchanged send is sent at 1")
end)

test("the voice filter cutoff and both sends are LFO destinations", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  local built_in = S.lib.lfos.BUILT_IN_DESTINATIONS
  local labels = {}
  for index = built_in + 1, #S.LFO_DESTINATIONS do labels[S.LFO_DESTINATIONS[index].label] = index end
  for voice_idx = 1, S.constants.NUM_VOICES do
    for label, key in pairs({vfilt = "filter_freq", dsend = "delay_send", rsend = "reverb_send"}) do
      local index = labels["v" .. voice_idx .. " " .. label]
      assert_true(index ~= nil and index > built_in, "v" .. voice_idx .. " " .. label .. " follows the built-ins")
      assert_equal(S.LFO_DESTINATIONS[index].resolve(), "v" .. voice_idx .. "_" .. key)
      assert_true(index > labels["v7 hist"], label .. " after history (registered first)")
    end
  end
  assert_equal(S.LFO_DESTINATIONS[built_in].label, "v7 scan", "the last built-in stays where it was")
  -- an LFO on v1's reverb send modulates the engine value, never the param
  params:set("v1_reverb_send", 0.5)
  local lfo = local_value("lfos")[1]
  params:set("strata_lfo1_dest", labels["v1 rsend"])
  params:set("lfo_depth_1", 100); params:set("lfo_1", 2)
  context.clear_engine_calls()
  context.lfo.tick(lfo, 1.0)
  local sent = sent_grain(context, "reverbSend")
  assert_true(#sent > 0 and sent[#sent].value > 0.5, "the LFO raises the send the engine gets")
  assert_near(params:get("v1_reverb_send"), 0.5, 1e-9, "the param keeps its value")
end)

test("voice filter and send fields round-trip through a scene; filter type switches at the end", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  params:set("v2_filter_type", 3); params:set("v2_filter_freq", 400); params:set("v2_filter_res", 0.9)
  params:set("v2_filter_mix", 1); params:set("v2_delay_send", 0); params:set("v2_reverb_send", 0.4)
  capture_scene(1)
  local extras = S.scenes[1].data.voices[2].extras
  assert_equal(extras.filter_type, 3, "the scene captures the type")
  assert_near(extras.filter_freq, 400, 1e-9); assert_near(extras.reverb_send, 0.4, 1e-9)
  assert_true(validate_scene(S.scenes[1]), "and validates")
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "voice_mix" then record = each end end
  assert_true(record.discrete.filter_type ~= nil and record.discrete.filter_type[1] == 1
    and record.discrete.filter_type[2] == 3, "the type is discrete, 1-3")
  for _, key in ipairs({"filter_freq", "filter_res", "filter_mix", "delay_send", "reverb_send"}) do
    assert_true(record.discrete[key] == nil, key .. " crossfades")
  end
  assert_equal(record.scene_defaults.filter_type, 1); assert_equal(record.scene_defaults.filter_freq, 5000)
  assert_equal(record.scene_defaults.filter_mix, 0); assert_equal(record.scene_defaults.delay_send, 1)
  -- back to the defaults, then a 4 s transition
  for _, key in ipairs(KEYS) do params:set("v2_" .. key, param_default("v2_" .. key)) end
  recall_scene(1, 4); wake(context, "scene_transition_clock")
  context.clock.run_for(2)
  assert_equal(params:get("v2_filter_type"), 1, "the type holds during the transition")
  local midway = params:get("v2_reverb_send")
  assert_true(midway < 1 and midway > 0.4, "the send crossfades (got " .. midway .. ")")
  context.clock.run_for(3)
  assert_equal(params:get("v2_filter_type"), 3, "and switches at the end")
  assert_near(params:get("v2_filter_freq"), 400, 1e-6); assert_near(params:get("v2_delay_send"), 0, 1e-9)
end)

test("the bypass params are stored in PSETs and never in scenes", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  for _, id in ipairs({"delay_bypass", "reverb_bypass"}) do
    local param = params:lookup_param(id)
    assert_true(param ~= nil and param.t == params.tBINARY, id .. " is a binary param")
    assert_equal(params:get(id), 0, id .. " is off by default")
  end
  -- in the fx group, after its own params
  local group_index, last_index
  for index, param in ipairs(params.params) do
    if param.id == "strata_fx" then group_index = index end
  end
  last_index = group_index + params:get("strata_fx")
  assert_equal(params.params[last_index - 1].id, "delay_bypass", "delay bypass in the fx group")
  assert_equal(params.params[last_index].id, "reverb_bypass", "reverb bypass last in the fx group")
  -- a PSET keeps them
  local pset_path = context.data_dir .. "bypass.pset"
  params:set("delay_bypass", 1)
  params:write(pset_path, "bypass")
  params:set("delay_bypass", 0); params:set("reverb_bypass", 1)
  context.clear_engine_calls()
  params:read(pset_path)
  assert_equal(params:get("delay_bypass"), 1, "a PSET restores the delay bypass")
  assert_equal(params:get("reverb_bypass"), 0, "and the reverb's")
  local calls = context.calls_named("setBypass")
  assert_true(#calls >= 2, "the PSET load reaches the engine")
  -- scenes never capture or recall them
  capture_scene(3)
  assert_true(not scene_holds(S.scenes[3].data, "bypass"), "the scene holds no bypass field")
  params:set("delay_bypass", 0)
  context.clear_engine_calls()
  recall_scene(3, 0)
  assert_equal(params:get("delay_bypass"), 0, "a recall leaves the bypass as it is")
  assert_equal(#context.calls_named("setBypass"), 0, "and sends no setBypass")
end)

test("a mix set to 0 never sets the bypass and a bypass never changes the mix", function()
  local context = load_strata()
  finish_startup(context)
  params:set("delay_mix", 0.5); params:set("reverb_mix", 0.4)
  context.clear_engine_calls()
  params:set("delay_mix", 0); params:set("reverb_mix", 0)
  assert_equal(params:get("delay_bypass"), 0, "a delay mix of 0 is not a bypass")
  assert_equal(params:get("reverb_bypass"), 0, "a reverb mix of 0 is not a bypass")
  assert_equal(#context.calls_named("setBypass"), 0, "and sends no setBypass")
  params:set("delay_mix", 0.5); params:set("reverb_mix", 0.4)
  context.clear_engine_calls()
  params:set("delay_bypass", 1)
  local calls = context.calls_named("setBypass")
  assert_equal(#calls, 1, "the delay bypass sends one setBypass")
  assert_equal(calls[1].args[1], 0, "effect 0 is the delay"); assert_equal(calls[1].args[2], 1, "bypassed")
  assert_near(params:get("delay_mix"), 0.5, 1e-9, "the delay keeps its mix")
  params:set("reverb_bypass", 1)
  calls = context.calls_named("setBypass")
  assert_equal(calls[#calls].args[1], 1, "effect 1 is the reverb"); assert_equal(calls[#calls].args[2], 1)
  assert_near(params:get("reverb_mix"), 0.4, 1e-9, "the reverb keeps its mix")
  assert_equal(#context.calls_named("setDelay") + #context.calls_named("setReverb"), 0, "no mix is sent")
  params:set("delay_bypass", 0)
  calls = context.calls_named("setBypass")
  assert_equal(calls[#calls].args[1], 0); assert_equal(calls[#calls].args[2], 0, "lifted")
  assert_near(params:get("delay_mix"), 0.5, 1e-9, "the mix is the same after the lift")
end)

test("the filter & sends section is on VOICE for every source", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, source in ipairs({S.constants.SOURCE_SYNTH, 2, S.constants.SOURCE_INPUT}) do
      params:set("v" .. voice_idx .. "_source", source)
      local rows, keys, label_at = voice_page_rows(voice_idx), {}, nil
      for index, row in ipairs(rows) do
        if row.section == "filter & sends" then
          if row.selectable == false then label_at = index else table.insert(keys, row.param_id) end
        end
      end
      assert_true(label_at ~= nil, "v" .. voice_idx .. " has the filter & sends section")
      local expected = {}
      for _, key in ipairs(KEYS) do table.insert(expected, "v" .. voice_idx .. "_" .. key) end
      assert_equal(table.concat(keys, " "), table.concat(expected, " "), "its rows, in order")
    end
  end
  -- the record's layout states draw (the VOICE layout tests run them too)
  h.show_page("VOICE")
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "voice_mix" then record = each end end
  assert_equal(#record.layout_states, S.constants.NUM_VOICES * 3 * 2, "each voice, source and section edge")
  for _, state in ipairs(record.layout_states) do
    state.setup(context)
    redraw()
    h.assert_screen_layout(context, "VOICE " .. state.name)
  end
end)

test("randomize, mutation and the fader pages leave the voice filter and sends alone", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    params:set("v" .. voice_idx .. "_filter_mix", 0.33); params:set("v" .. voice_idx .. "_delay_send", 0.66)
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(11)
  for voice_idx = 1, S.constants.NUM_VOICES do randomize_voice(voice_idx) end
  for _ = 1, 20 do gentle_mutate() end
  for _ = 1, 20 do drift_update() end
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_near(params:get("v" .. voice_idx .. "_filter_mix"), 0.33, 1e-9, "voice " .. voice_idx .. " filter mix")
    assert_near(params:get("v" .. voice_idx .. "_delay_send"), 0.66, 1e-9, "voice " .. voice_idx .. " delay send")
    for _, param_id in ipairs(fader_param_ids(voice_idx)) do
      assert_true(not param_id:find("filter", 1, true) and not param_id:find("send", 1, true),
        param_id .. " is not a voice filter or send")
    end
  end
  assert_equal(params:get("delay_bypass"), 0); assert_equal(params:get("reverb_bypass"), 0)
end)

end

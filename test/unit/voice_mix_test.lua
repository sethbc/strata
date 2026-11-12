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
  params:set("strata_lfo1_dest", labels["v1 rsend"])
  params:set("strata_lfo1_shape", 3); params:set("strata_lfo1_rate", 0.003)   -- a square at its top
  params:set("strata_lfo1_depth", 100); params:set("strata_lfo1", 1)
  context.clear_engine_calls()
  context.clock.advance_until(S.lfo_clock)
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
      for _, key in ipairs({"mute", "solo"}) do table.insert(expected, "v" .. voice_idx .. "_" .. key) end
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

-- #557: a press of ALT+K2 on VOICE's filter & sends section draws these
-- keys (the record's randomize): the type a uniform option, the cutoff
-- 100-8000 Hz even in octaves, the res below self-oscillation and the sends
-- moderate; the filter's mix is kept (0 would leave the filter out)
test("voice_mix's randomize draws the filter's type, cutoff and res and both sends, never its mix (#557)", function()
  local context = load_strata()
  finish_startup(context)
  local record
  for _, each in ipairs(local_value("S").registry.voice_params) do
    if each.name == "voice_mix" then record = each end
  end
  local keys = {}
  for key in pairs(record.randomize) do keys[#keys + 1] = key end
  table.sort(keys)
  assert_equal(table.concat(keys, ","), "delay_send,filter_freq,filter_res,filter_type,reverb_send",
    "the drawn keys: never filter_mix")
  math.randomseed(23)
  local types = {}
  for _ = 1, 200 do
    local option = record.randomize.filter_type(3)
    assert_true(option % 1 == 0 and option >= 1 and option <= 3, "filter_type draws an option index")
    types[option] = true
  end
  assert_true(types[1] and types[2] and types[3], "every filter type is drawn")
  local below_middle = 0
  local low, high = math.huge, -math.huge
  for _ = 1, 400 do
    local value = record.randomize.filter_freq(3)
    low, high = math.min(low, value), math.max(high, value)
    if value < math.sqrt(100 * 8000) then below_middle = below_middle + 1 end
  end
  assert_true(low >= 100 and high <= 8000 and low < 120 and high > 7000, "the cutoff spans 100-8000 Hz (" .. low .. "-" .. high .. ")")
  assert_true(below_middle > 160 and below_middle < 240, "even in octaves: half below 894 Hz (" .. below_middle .. " of 400)")
  for key, top in pairs({ filter_res = 0.7, delay_send = 0.6, reverb_send = 0.6 }) do
    low, high, below_middle = math.huge, -math.huge, 0
    for _ = 1, 400 do
      local value = record.randomize[key](3)
      low, high = math.min(low, value), math.max(high, value)
      if value < top / 2 then below_middle = below_middle + 1 end
    end
    assert_true(low >= 0 and high <= top and low < top * 0.05 and high > top * 0.95, key .. " spans 0-" .. top)
    assert_true(below_middle > 160 and below_middle < 240, key .. " is uniform (" .. below_middle .. " of 400 below the middle)")
  end
end)

test("the voice sends show in percent and send the same value (#387)", function()
  local context = load_strata(); finish_startup(context)
  for voice_idx = 1, 7 do
    for _, key in ipairs({"delay_send", "reverb_send"}) do
      local id = "v" .. voice_idx .. "_" .. key
      assert_equal(params:string(id), "100 %", id .. " at 1.0")
      params:set(id, 0.5)
      assert_equal(params:string(id), "50 %", id .. " at 0.5")
      assert_near(params:get(id), 0.5, 1e-9, "the stored value is unchanged")
      params:set(id, 1)
    end
  end
  if not local_value("voices")[1].active then toggle_voice(1) end
  context.clear_engine_calls()
  params:set("v1_delay_send", 0.25)
  local sent
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "delaySend" then sent = call.args[3] end
  end
  assert_near(sent, 0.25, 1e-9, "the engine still gets the 0-1 value")
end)

-- Mute and solo (3.4, #1j): the voices running are 1-4
local function run_voices_1_to_4(context)
  finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, 4 do
    if not S.voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  return S
end

local function mutes_sent(context)
  local by_voice = {}
  for _, entry in ipairs(sent_grain(context, "voiceMute")) do
    by_voice[entry.voice + 1] = entry.value
    by_voice.count = (by_voice.count or 0) + 1
  end
  return by_voice
end

test("a mute silences a voice without stopping it", function()
  local context = load_strata()
  local S = run_voices_1_to_4(context)
  context.clear_engine_calls()
  params:set("v3_mute", 1)
  local sent = mutes_sent(context)
  assert_equal(sent.count, 1, "one message")
  assert_equal(sent[3], 1, "voice 3 muted")
  assert_equal(#context.calls_named("voiceOff"), 0, "no voiceOff")
  assert_true(S.voices[3].active, "voice 3 still runs")
  assert_true(S.lib.voice_mix.silenced(3), "voice 3 is silenced")
  assert_true(not S.lib.voice_mix.silenced(1), "voice 1 is not")
  context.clear_engine_calls()
  params:set("v3_mute", 0)
  assert_equal(mutes_sent(context)[3], 0, "unmuting sends 0")
end)

test("silenced is safe for any argument", function()
  local context = load_strata(); finish_startup(context)
  local silenced = local_value("S").lib.voice_mix.silenced
  for _, bad in ipairs({0, 8, -1, 1.5, "x", false}) do assert_equal(silenced(bad), false, tostring(bad)) end
  assert_equal(silenced(nil), false)
end)

test("a second solo un-silences its voice and no other", function()
  local context = load_strata()
  local S = run_voices_1_to_4(context)
  params:set("v2_solo", 1)
  context.clear_engine_calls()
  params:set("v4_solo", 1)
  local second = mutes_sent(context)
  assert_equal(second[4], 0, "voiceMute 0 to voice 4")
  assert_equal(second.count, 1, "and to no other voice")
  assert_true(not S.lib.voice_mix.silenced(4) and S.lib.voice_mix.silenced(1))
end)

test("a solo silences every voice that is not soloed", function()
  local context = load_strata()
  local S = run_voices_1_to_4(context)
  params:set("v4_mute", 1)
  context.clear_engine_calls()
  params:set("v2_solo", 1)
  local sent = mutes_sent(context)
  assert_equal(sent[1], 1); assert_equal(sent[3], 1)
  assert_equal(sent[2], nil, "the soloed voice was not silenced")
  assert_equal(sent[4], nil, "voice 4 was muted already")
  assert_equal(sent.count, 2)
  context.clear_engine_calls()
  params:set("v4_solo", 1)  -- voice 4 is muted and soloed: still silenced
  assert_equal(mutes_sent(context).count, nil, "a muted voice stays silenced when soloed")
  assert_true(S.lib.voice_mix.silenced(4), "mute wins over solo")
  context.clear_engine_calls()
  params:set("v4_mute", 0)
  assert_equal(mutes_sent(context)[4], 0, "voice 4 plays")
  context.clear_engine_calls()
  params:set("v2_solo", 0); params:set("v4_solo", 0)
  local after = mutes_sent(context)
  assert_equal(after[1], 0); assert_equal(after[3], 0)
  for voice_idx = 1, 4 do assert_equal(S.lib.voice_mix.silenced(voice_idx), false) end
  params:set("v1_mute", 1)
  context.clear_engine_calls()
  params:set("v2_solo", 1); params:set("v2_solo", 0)
  assert_true(S.lib.voice_mix.silenced(1), "a voice muted before stays silenced")
  assert_equal(mutes_sent(context)[1], nil, "and was never sent 0")
  assert_equal(#context.calls_named("voiceOff"), 0)
end)

test("a stopped voice gets no mute message and its start syncs the effective mute", function()
  local context = load_strata()
  local S = run_voices_1_to_4(context)
  context.clear_engine_calls()
  params:set("v6_mute", 1); params:set("v5_solo", 1)
  for _, entry in ipairs(sent_grain(context, "voiceMute")) do
    assert_true(entry.voice + 1 <= 4, "no message to the stopped voices 5-7")
  end
  context.clear_engine_calls()
  toggle_voice(6)  -- muted
  local sent = mutes_sent(context)
  assert_equal(sent[6], 1, "voice 6 starts silenced")
  local voice_on_at, mute_at
  for index, call in ipairs(context.engine_calls) do
    if call.name == "voiceOn" and call.args[1] == 5 then voice_on_at = index end
    if call.name == "setGrainParam" and call.args[1] == 5 and call.args[2] == "voiceMute" then mute_at = index end
  end
  assert_true(mute_at < voice_on_at, "the mute is sent before voiceOn")
  context.clear_engine_calls()
  toggle_voice(5)  -- soloed
  assert_equal(mutes_sent(context)[5], 0, "the soloed voice starts audible")
  params:set("v5_solo", 0)
  assert_true(S.voices[6].active)
end)

test("scenes store mutes and never solos", function()
  local context = load_strata()
  local S = run_voices_1_to_4(context)
  params:set("v2_mute", 1); params:set("v3_solo", 1)
  capture_scene(1)
  assert_equal(S.scenes[1].data.voices[2].extras.mute, 1, "the mute is captured")
  assert_true(not scene_holds(S.scenes[1].data, "solo"), "no solo in the scene")
  assert_true(validate_scene(S.scenes[1]))
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "voice_mix" then record = each end end
  assert_equal(record.scene_defaults.mute, 0); assert_equal(record.scene_defaults.solo, nil)
  assert_true(record.discrete.mute ~= nil and record.discrete.solo == nil, "mute is discrete")
  params:set("v2_mute", 0); params:set("v3_solo", 0); params:set("v1_solo", 1)
  recall_scene(1, 0)
  assert_equal(params:get("v2_mute"), 1, "the recall mutes voice 2")
  assert_equal(params:get("v1_solo"), 1, "and leaves the solo")
  assert_equal(params:get("v3_solo"), 0)
  -- a scene saved before 3.4 has no mute: every voice plays
  local old = S.scenes[1].data.voices[2].extras
  old.mute = nil
  migrate_scene(S.scenes[1], local_value("SCENE_DATA_VERSION"))
  assert_equal(S.scenes[1].data.voices[2].extras.mute, 0, "the migration default is unmuted")
  assert_true(validate_scene(S.scenes[1]))
end)

test("a muted voice's steps still retrigger it", function()
  local context = load_strata()
  run_voices_1_to_4(context)
  params:set("v1_mute", 1)
  for step = 1, 4 do toggle_pattern_step(1, step) end
  context.clear_engine_calls()
  pattern_toggle()
  for _ = 1, 3 do wake(context, "pattern_clock") end
  pattern_toggle()
  local count = 0
  for _, call in ipairs(context.calls_named("retrigger")) do if call.args[1] == 0 then count = count + 1 end end
  assert_equal(count, 4, "voice 1 retriggers on every step")
  assert_equal(#context.calls_named("voiceOff"), 0)
end)

test("randomize, mutations and the fader pages never touch mute or solo", function()
  local context = load_strata()
  local S = run_voices_1_to_4(context)
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(5)
  for voice_idx = 1, 7 do randomize_voice(voice_idx) end
  for _ = 1, 20 do gentle_mutate() end
  for _ = 1, 20 do drift_update() end
  -- VOICE's section randomize draws exist, and none is mute or solo
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "voice_mix" then record = each end end
  assert_equal(record.randomize.mute, nil); assert_equal(record.randomize.solo, nil)
  for voice_idx = 1, 7 do
    assert_equal(params:get("v" .. voice_idx .. "_mute"), 0); assert_equal(params:get("v" .. voice_idx .. "_solo"), 0)
    for _, param_id in ipairs(fader_param_ids(voice_idx)) do
      assert_true(not param_id:find("_mute", 1, true) and not param_id:find("_solo", 1, true), param_id)
    end
  end
end)

test("soloed is true for a soloed voice that is not muted, and safe for any argument", function()
  local context = load_strata()
  local S = run_voices_1_to_4(context)
  local voice_mix = S.lib.voice_mix
  assert_equal(voice_mix.soloed(2), false)
  params:set("v2_solo", 1)
  assert_equal(voice_mix.soloed(2), true); assert_equal(voice_mix.soloed(1), false)
  params:set("v2_mute", 1)
  assert_equal(voice_mix.soloed(2), false, "muted is silenced, not soloed")
  for _, bad in ipairs({0, 8, -1, 1.5, "x", false}) do assert_equal(voice_mix.soloed(bad), false, tostring(bad)) end
  assert_equal(voice_mix.soloed(nil), false)
end)

test("a mute or solo redraws the grid", function()
  local context = load_strata()
  run_voices_1_to_4(context)
  local calls = 0
  local original = grid_redraw
  grid_redraw = function() calls = calls + 1 end
  params:set("v3_mute", 1)
  params:set("v2_solo", 1)
  grid_redraw = original
  assert_true(calls >= 2, "grid_redraw ran for each (" .. calls .. ")")
end)

end

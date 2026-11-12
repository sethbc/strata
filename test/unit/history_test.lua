-- test/unit/history_test.lua
-- Input history (lib/history.lua): v<i>_history, its range from the tier,
-- the history grain param, the scene field, the VOICE row on input voices,
-- the LFO destination, and what randomize, mutation and the faders leave.
-- Run alone: lua test/run.lua history

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake

-- The history values setGrainParam sent since the engine calls were
-- cleared, as {voice (engine index), value}
local function sent_history(context)
  local sent = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "history" then table.insert(sent, {voice = call.args[1], value = call.args[3]}) end
  end
  return sent
end

local function row_ids(voice_idx)
  local ids = {}
  for _, row in ipairs(voice_page_rows(voice_idx)) do
    table.insert(ids, row.param_id and (row.section .. ":" .. row.param_id) or row.section)
  end
  return table.concat(ids, " ")
end

test("v<i>_history ranges from 0 to the tier's history", function()
  load_strata()
  local S = local_value("S")
  assert_true(S.lib.history ~= nil, "S.lib.history is the module's table")
  for voice_idx = 1, S.constants.NUM_VOICES do
    local id = "v" .. voice_idx .. "_history"
    local low, high = param_range(id)
    assert_equal(low, 0, id .. " from 0")
    assert_equal(high, 16, id .. " to the standard tier's 16 s")
    assert_equal(param_default(id), 0, id .. " defaults to 0")
    assert_equal(params:lookup_param(id).controlspec.units, "s", id .. " in seconds")
    assert_equal(S.voices[voice_idx].extras.history, 0, "voice " .. voice_idx .. " stores it")
  end
end)

test("v<i>_history ranges 0 to 60 with a high active file", function()
  h.write_performance_active({tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60,
    reason = "high: setting"})
  load_strata()
  local S = local_value("S")
  assert_equal(S.performance.history_seconds, 60, "the active file's history")
  for voice_idx = 1, S.constants.NUM_VOICES do
    local low, high = param_range("v" .. voice_idx .. "_history")
    assert_equal(low, 0); assert_equal(high, 60, "v" .. voice_idx .. "_history to the high tier's 60 s")
  end
  params:set("v2_history", 45)
  assert_equal(params:get("v2_history"), 45, "45 s holds on high")
end)

test("history reaches the engine as the history grain param only while running", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active and not S.voices[3].active, "voice 1 runs, voice 3 does not")
  context.clear_engine_calls()
  params:set("v1_history", 4.5)
  local sent = sent_history(context)
  assert_equal(#sent, 1, "one message")
  assert_equal(sent[1].voice, 0, "to engine voice 0")
  assert_near(sent[1].value, 4.5, 1e-9, "the value in seconds")
  context.clear_engine_calls()
  params:set("v3_history", 2)
  assert_equal(#sent_history(context), 0, "a stopped voice gets no message")
  assert_near(S.voices[3].extras.history, 2, 1e-9, "but stores it")
  -- the sync sends it after the source when the voice starts
  context.clear_engine_calls()
  toggle_voice(3)
  local source_at, history_at
  for index, call in ipairs(context.engine_calls) do
    if call.name == "setGrainSource" and call.args[1] == 2 then source_at = source_at or index end
    if call.name == "setGrainParam" and call.args[1] == 2 and call.args[2] == "history" then
      history_at = index
      assert_near(call.args[3], 2, 1e-9, "the stored value")
    end
  end
  assert_true(source_at and history_at and source_at < history_at, "the start sends history after the source")
end)

test("history is a scene field with default 0 that crossfades", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  params:set("v2_source", S.constants.SOURCE_INPUT)
  params:set("v2_history", 8)
  capture_scene(1)
  assert_equal(S.scenes[1].data.voices[2].extras.history, 8, "the scene captures it")
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "history" then record = each end end
  assert_equal(record.scene_defaults.history, 0, "migration fills 0")
  assert_true(record.discrete == nil or record.discrete.history == nil, "not discrete")
  params:set("v2_history", 0)
  recall_scene(1, 4); wake(context, "scene_transition_clock")
  local midway = params:get("v2_history")
  assert_true(midway > 0 and midway < 8, "it crossfades (got " .. midway .. ")")
  context.clock.run_for(5)
  assert_near(params:get("v2_history"), 8, 1e-9, "and ends at the scene's value")
end)

test("a high-tier history recalled on standard plays at most 16 s", function()
  -- a scene saved on the high tier, with history 45 s
  h.write_performance_active({tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60,
    reason = "high: setting"})
  local context = load_strata({data_subdir = "history_high_scene"})
  finish_startup(context)
  local S = local_value("S")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  params:set("v1_history", 45)
  capture_scene(1)
  assert_equal(S.scenes[1].data.voices[1].extras.history, 45, "captured on high")
  save_scenes_to_disk()
  -- loaded on standard
  h.write_performance_active({tier = "standard", buffer_seconds = 16, max_grains = 128, history_seconds = 16,
    reason = "standard: setting"})
  context = load_strata({data_subdir = "history_high_scene"})
  finish_startup(context)
  S = local_value("S")
  assert_equal(S.performance.history_seconds, 16, "the standard tier")
  assert_equal(S.scenes[1].data.voices[1].extras.history, 45, "the scene still holds 45")
  assert_true(validate_scene(S.scenes[1]), "and validates")
  context.clear_engine_calls()
  recall_scene(1, 0)
  assert_equal(params:get("v1_history"), 16, "params:get gives the tier's 16")
  -- a transition toward it, and an LFO at full depth on it
  params:set("v1_history", 0)
  recall_scene(1, 2); wake(context, "scene_transition_clock")
  context.clock.run_for(3)
  assert_equal(params:get("v1_history"), 16)
  local dest
  for index, destination in ipairs(S.LFO_DESTINATIONS) do
    if destination.label == "v1 hist" then dest = index end
  end
  params:set("strata_lfo1_dest", dest)
  params:set("strata_lfo1_shape", 3); params:set("strata_lfo1_rate", 10)   -- a 10 Hz square: up, down, up
  params:set("strata_lfo1_depth", 100); params:set("strata_lfo1", 1)
  context.clock.run_for(0.25)
  -- a PSET value past the range
  params:set("v1_history", 45)
  assert_equal(params:get("v1_history"), 16, "a PSET value clamps too")
  local sent = sent_history(context)
  assert_true(#sent > 2, "history was sent (" .. #sent .. " times)")
  for _, each in ipairs(sent) do
    assert_true(each.value >= 0 and each.value <= 16, "every sent history is 0-16 (got " .. each.value .. ")")
  end
end)

test("only an input voice's VOICE rows show history", function()
  load_strata()
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    local prefix = "v" .. voice_idx
    for _, source in ipairs({S.constants.SOURCE_SYNTH, 2, S.constants.NUM_BUFFERS + 1}) do
      params:set(prefix .. "_source", source)
      assert_true(not row_ids(voice_idx):find("history", 1, true),
        prefix .. " on source " .. source .. " has no history row: " .. row_ids(voice_idx))
    end
    params:set(prefix .. "_source", S.constants.SOURCE_INPUT)
    local outline = row_ids(voice_idx)
    assert_true(outline:find("input input:" .. prefix .. "_history grain ", 1, true),
      prefix .. " on the input: an input section with history, before grain: " .. outline)
  end
end)

test("the history row lays out on VOICE", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  h.show_page("VOICE")
  for voice_idx = 1, S.constants.NUM_VOICES do
    S.selected_voice = voice_idx
    params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_INPUT)
    params:set("v" .. voice_idx .. "_history", 16)
    S.lib.pages_voice.sync_cursor()
    S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of("v" .. voice_idx .. "_history"))
    for _, alt in ipairs({0, 1}) do
      key(1, alt); redraw()
      assert_true(h.screen_shows(context, "history"), "v" .. voice_idx .. " shows the history row")
      h.assert_screen_layout(context, "VOICE v" .. voice_idx .. " on history" .. (alt == 1 and " with ALT" or ""))
    end
    key(1, 0)
  end
end)

test("history is an LFO destination after the built-ins", function()
  load_strata()
  local S = local_value("S")
  local built_in = S.lib.lfos.BUILT_IN_DESTINATIONS
  for voice_idx = 1, S.constants.NUM_VOICES do
    local destination = S.LFO_DESTINATIONS[built_in + voice_idx]
    assert_equal(destination.label, "v" .. voice_idx .. " hist", "right after the built-ins, by voice")
    assert_equal(destination.resolve(), "v" .. voice_idx .. "_history")
  end
  assert_equal(S.LFO_DESTINATIONS[built_in].label, "v7 scan", "the last built-in stays where it was")
end)

test("randomize, mutation and the fader pages leave history alone", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    params:set("v" .. voice_idx .. "_source", voice_idx % 2 == 0 and S.constants.SOURCE_INPUT or 1)
    params:set("v" .. voice_idx .. "_history", 3.25)
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(7)
  for voice_idx = 1, S.constants.NUM_VOICES do randomize_voice(voice_idx) end
  for _ = 1, 20 do gentle_mutate() end
  for _ = 1, 20 do drift_update() end
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_near(params:get("v" .. voice_idx .. "_history"), 3.25, 1e-9, "voice " .. voice_idx .. " untouched")
    for _, param_id in ipairs(fader_param_ids(voice_idx)) do
      assert_true(not param_id:find("history", 1, true), param_id .. " is not history")
    end
  end
end)

-- #557: a press of ALT+K2 on VOICE's input section draws history, uniform
-- from 0 to its spec's top (the tier's history)
test("history's randomize draws 0 to the tier's history, uniform (#557)", function()
  for _, tier in ipairs({ { name = "standard", seconds = 16 }, { name = "high", seconds = 60 } }) do
    h.write_performance_active({ tier = tier.name, buffer_seconds = tier.seconds, max_grains = 128,
      history_seconds = tier.seconds, reason = tier.name .. ": setting" })
    local context = load_strata()
    finish_startup(context)
    local record
    for _, each in ipairs(local_value("S").registry.voice_params) do
      if each.name == "history" then record = each end
    end
    local keys = {}
    for key in pairs(record.randomize) do keys[#keys + 1] = key end
    assert_equal(table.concat(keys, ","), "history", tier.name .. ": the drawn key")
    math.randomseed(19)
    local low, high, below_middle = math.huge, -math.huge, 0
    for _ = 1, 400 do
      local value = record.randomize.history(4)
      low, high = math.min(low, value), math.max(high, value)
      if value < tier.seconds / 2 then below_middle = below_middle + 1 end
    end
    assert_true(low >= 0 and high <= tier.seconds, tier.name .. ": within 0-" .. tier.seconds .. " s (" .. low .. "-" .. high .. ")")
    assert_true(low < tier.seconds * 0.05 and high > tier.seconds * 0.95, tier.name .. ": spans its range")
    assert_true(below_middle > 160 and below_middle < 240, tier.name .. ": uniform (" .. below_middle .. " of 400 below the middle)")
  end
end)

end

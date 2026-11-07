-- test/unit/loops_test.lua
-- Loop regions (lib/loops.lua): v<i>_loop_start and v<i>_loop_length, their
-- grain params, the clamps (start at most 0.999, length at most 1 - start),
-- the VOICE rows in a buffer voice's synth section, the scene fields, and
-- what randomize, mutation and the faders leave.
-- Run alone: lua test/run.lua loops

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake

-- The values setGrainParam sent for one grain param since the engine calls
-- were cleared, as {voice (engine index), value}
local function sent_values(context, name)
  local sent = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == name then table.insert(sent, {voice = call.args[1], value = call.args[3]}) end
  end
  return sent
end

local function last_sent(context, name, engine_voice)
  local value
  for _, each in ipairs(sent_values(context, name)) do
    if each.voice == engine_voice then value = each.value end
  end
  return value
end

local function row_ids(voice_idx)
  local ids = {}
  for _, row in ipairs(voice_page_rows(voice_idx)) do
    table.insert(ids, row.param_id and (row.section .. ":" .. row.param_id) or row.section)
  end
  return table.concat(ids, " ")
end

local function loop_of(voice_idx)
  return params:get("v" .. voice_idx .. "_loop_start"), params:get("v" .. voice_idx .. "_loop_length")
end

test("loop params default to the whole slot and reach the engine", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.lib.loops ~= nil, "S.lib.loops is the module's table")
  for voice_idx = 1, S.constants.NUM_VOICES do
    local start_id, length_id = "v" .. voice_idx .. "_loop_start", "v" .. voice_idx .. "_loop_length"
    local low, high = param_range(start_id)
    assert_equal(low, 0, start_id .. " from 0"); assert_equal(high, 1, start_id .. " to 1")
    assert_equal(param_default(start_id), 0, start_id .. " defaults to 0")
    low, high = param_range(length_id)
    assert_near(low, 0.001, 1e-12, length_id .. " from 0.001"); assert_equal(high, 1, length_id .. " to 1")
    assert_equal(param_default(length_id), 1, length_id .. " defaults to 1")
    assert_equal(S.voices[voice_idx].extras.loop_start, 0, "voice " .. voice_idx .. " stores the start")
    assert_equal(S.voices[voice_idx].extras.loop_length, 1, "voice " .. voice_idx .. " stores the length")
  end
  assert_true(S.voices[1].active and not S.voices[3].active, "voice 1 runs, voice 3 does not")
  context.clear_engine_calls()
  params:set("v1_loop_length", 0.5)
  params:set("v1_loop_start", 0.25)
  local starts, lengths = sent_values(context, "loopStart"), sent_values(context, "loopLength")
  assert_equal(#starts, 1, "one start message"); assert_equal(#lengths, 1, "one length message")
  assert_equal(starts[1].voice, 0, "to engine voice 0")
  assert_near(starts[1].value, 0.25, 1e-9); assert_near(lengths[1].value, 0.5, 1e-9)
  assert_equal(params:string("v1_loop_start"), "0.250", "shown with three decimals")
  context.clear_engine_calls()
  params:set("v3_loop_start", 0.5)
  assert_equal(#sent_values(context, "loopStart"), 0, "a stopped voice gets no message")
  assert_near(S.voices[3].extras.loop_start, 0.5, 1e-9, "but stores it")
  -- the sync sends them after the source when the voice starts
  context.clear_engine_calls()
  toggle_voice(3)
  local source_at, start_at, length_at
  for index, call in ipairs(context.engine_calls) do
    if call.name == "setGrainSource" and call.args[1] == 2 then source_at = source_at or index end
    if call.name == "setGrainParam" and call.args[1] == 2 then
      if call.args[2] == "loopStart" then start_at = index; assert_near(call.args[3], 0.5, 1e-9) end
      if call.args[2] == "loopLength" then length_at = index; assert_near(call.args[3], 0.5, 1e-9) end
    end
  end
  assert_true(source_at and start_at and length_at and source_at < start_at and source_at < length_at,
    "the start sends the loop after the source")
end)

test("loop start 1 clamps to 0.999 and the length to 0.001", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    params:set("v" .. voice_idx .. "_source", 2)
  end
  context.clear_engine_calls()
  params:set("v1_loop_start", 1)
  local start, length = loop_of(1)
  assert_near(start, 0.999, 1e-12, "the start stops at 0.999")
  assert_near(length, 0.001, 1e-9, "the length is cut to 1 - start")
  assert_near(S.voices[1].extras.loop_start, 0.999, 1e-12, "the stored start")
  assert_near(last_sent(context, "loopStart", 0), 0.999, 1e-12, "the engine gets 0.999")
  assert_near(last_sent(context, "loopLength", 0), 0.001, 1e-9, "and 0.001")
  for _, each in ipairs(sent_values(context, "loopStart")) do
    assert_true(each.value <= 0.999, "no start past 0.999 is sent (got " .. each.value .. ")")
  end
  -- the length cannot grow past the room left, by set, encoder or arc
  params:set("v1_loop_length", 1)
  assert_near(params:get("v1_loop_length"), 0.001, 1e-9, "a set past 1 - start stops there")
  h.show_page("VOICE")
  S.selected_voice = 1
  S.lib.pages_voice.sync_cursor()
  S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of("v1_loop_length"))
  enc(3, 20)
  assert_near(params:get("v1_loop_length"), 0.001, 1e-9, "E3 cannot lengthen it")
  for _, each in ipairs(sent_values(context, "loopLength")) do
    assert_true(each.value <= 0.001 + 1e-9, "no length past 1 - start is sent (got " .. each.value .. ")")
  end
  assert_equal(params:string("v1_loop_start"), "0.999")
  assert_equal(params:string("v1_loop_length"), "0.001")
  -- a start of 1 from a PSET clamps the same way
  params:set("v2_loop_length", 0.5)
  params:set("v2_loop_start", 1.5)
  start, length = loop_of(2)
  assert_near(start, 0.999, 1e-12); assert_near(length, 0.001, 1e-9)
end)

test("moving loop start past 1 - length clamps the length", function()
  local context = load_strata()
  finish_startup(context)
  params:set("v1_source", 3)
  params:set("v1_loop_length", 0.5)
  params:set("v1_loop_start", 0.3)
  local start, length = loop_of(1)
  assert_near(start, 0.3, 1e-9); assert_near(length, 0.5, 1e-9, "a length that fits is kept")
  context.clear_engine_calls()
  params:set("v1_loop_start", 0.7)
  start, length = loop_of(1)
  assert_near(length, 0.3, 1e-9, "the length is cut to 1 - start")
  assert_near(last_sent(context, "loopLength", 0), 0.3, 1e-9, "and the cut length is sent")
  params:set("v1_loop_start", 0.2)
  assert_near(params:get("v1_loop_length"), 0.3, 1e-9, "moving the start back keeps the cut length")
  params:set("v1_loop_length", 0.9)
  assert_near(params:get("v1_loop_length"), 0.8, 1e-9, "a longer length stops at 1 - start")
  -- every pair the engine got fits in the slot
  local S = local_value("S")
  assert_true(S.voices[1].extras.loop_start + S.voices[1].extras.loop_length <= 1 + 1e-9, "the stored pair fits")
end)

test("loop rows show in a buffer voice's section only", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    local prefix = "v" .. voice_idx
    for _, source in ipairs({S.constants.SOURCE_SYNTH, S.constants.SOURCE_INPUT}) do
      params:set(prefix .. "_source", source)
      assert_true(not row_ids(voice_idx):find("loop", 1, true),
        prefix .. " on source " .. source .. " has no loop rows: " .. row_ids(voice_idx))
    end
    for slot = 1, S.constants.NUM_BUFFERS do
      params:set(prefix .. "_source", S.constants.SOURCE_SYNTH + slot)
      local outline = row_ids(voice_idx)
      local expected = string.format("synth synth:%s_buf_pos synth:%s_buf_rate synth:%s_buf_scan "
        .. "synth:%s_loop_start synth:%s_loop_length grain ", prefix, prefix, prefix, prefix, prefix)
      assert_true(outline:find(expected, 1, true) == 1,
        prefix .. " on buffer " .. slot .. ": the loop rows end the synth section: " .. outline)
    end
  end
  -- they lay out on VOICE, at the slot's end
  h.show_page("VOICE")
  for voice_idx = 1, S.constants.NUM_VOICES do
    S.selected_voice = voice_idx
    params:set("v" .. voice_idx .. "_source", 2)
    params:set("v" .. voice_idx .. "_loop_start", 1)
    S.lib.pages_voice.sync_cursor()
    for _, loop_key in ipairs({"loop_start", "loop_length"}) do
      S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of("v" .. voice_idx .. "_" .. loop_key))
      for _, alt in ipairs({0, 1}) do
        key(1, alt); redraw()
        assert_true(h.screen_shows(context, (loop_key:gsub("_", " "))), "v" .. voice_idx .. " shows " .. loop_key)
        h.assert_screen_layout(context, "VOICE v" .. voice_idx .. " on " .. loop_key .. (alt == 1 and " with ALT" or ""))
      end
      key(1, 0)
    end
  end
end)

test("loops are continuous scene fields that crossfade", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  params:set("v2_source", 4)
  params:set("v2_loop_length", 0.5)
  params:set("v2_loop_start", 0.5)
  capture_scene(1)
  assert_near(S.scenes[1].data.voices[2].extras.loop_start, 0.5, 1e-9, "the scene captures the start")
  assert_near(S.scenes[1].data.voices[2].extras.loop_length, 0.5, 1e-9, "and the length")
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "loops" then record = each end end
  assert_equal(record.scene_defaults.loop_start, 0, "migration fills a start of 0")
  assert_equal(record.scene_defaults.loop_length, 1, "and a length of 1")
  assert_true(record.discrete == nil, "neither is discrete")
  params:set("v2_loop_start", 0)
  params:set("v2_loop_length", 1)
  capture_scene(2)

  -- (0, 1) -> (0.5, 0.5): both move, and end at the scene's values
  recall_scene(1, 4); wake(context, "scene_transition_clock")
  local start, length = loop_of(2)
  assert_true(start > 0 and start < 0.5, "the start crossfades (got " .. start .. ")")
  assert_true(length > 0.5 and length < 1, "the length crossfades (got " .. length .. ")")
  context.clock.run_for(5)
  start, length = loop_of(2)
  assert_near(start, 0.5, 1e-9, "the transition ends at the scene's start")
  assert_near(length, 0.5, 1e-9, "and length")

  -- (0.5, 0.5) -> (0, 1): the start falls as the length grows, and the clamp
  -- never leaves the length short of the scene's
  recall_scene(2, 4); wake(context, "scene_transition_clock")
  start, length = loop_of(2)
  assert_true(start > 0 and start < 0.5 and length > 0.5 and length < 1,
    "both crossfade back (got " .. start .. ", " .. length .. ")")
  context.clock.run_for(5)
  start, length = loop_of(2)
  assert_near(start, 0, 1e-9, "the transition back ends at the whole slot")
  assert_near(length, 1, 1e-9, "with the whole length")

  -- and instantly, both ways
  recall_scene(1, 0)
  start, length = loop_of(2)
  assert_near(start, 0.5, 1e-9); assert_near(length, 0.5, 1e-9)
  recall_scene(2, 0)
  start, length = loop_of(2)
  assert_near(start, 0, 1e-9, "an instant recall gives the scene's start")
  assert_near(length, 1, 1e-9, "and its whole length")

  -- a scene from before 3.2 (no loop fields) recalls the whole slot
  params:set("v2_loop_length", 0.25); params:set("v2_loop_start", 0.75)
  S.scenes[3] = h.deep_copy(S.scenes[1])
  for voice_idx = 1, S.constants.NUM_VOICES do
    S.scenes[3].data.voices[voice_idx].extras.loop_start = nil
    S.scenes[3].data.voices[voice_idx].extras.loop_length = nil
  end
  migrate_scene(S.scenes[3], 2)
  assert_true(validate_scene(S.scenes[3]), "the migrated scene validates")
  recall_scene(3, 0)
  start, length = loop_of(2)
  assert_near(start, 0, 1e-9, "migration gives a start of 0"); assert_near(length, 1, 1e-9, "and a length of 1")
end)

test("randomize, mutation and the fader pages leave loops alone", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    params:set("v" .. voice_idx .. "_source", voice_idx % 2 == 0 and S.constants.SOURCE_SYNTH or 2)
    params:set("v" .. voice_idx .. "_loop_length", 0.25)
    params:set("v" .. voice_idx .. "_loop_start", 0.5)
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(11)
  for voice_idx = 1, S.constants.NUM_VOICES do randomize_voice(voice_idx) end
  for _ = 1, 20 do gentle_mutate() end
  for _ = 1, 20 do drift_update() end
  for voice_idx = 1, S.constants.NUM_VOICES do
    local start, length = loop_of(voice_idx)
    assert_near(start, 0.5, 1e-9, "voice " .. voice_idx .. "'s start untouched")
    assert_near(length, 0.25, 1e-9, "voice " .. voice_idx .. "'s length untouched")
    for _, param_id in ipairs(fader_param_ids(voice_idx)) do
      assert_true(not param_id:find("loop", 1, true), param_id .. " is not a loop param")
    end
  end
end)

end

-- test/unit/freeze_test.lua
-- Freeze (lib/freeze.lua): v<i>_freeze and v<i>_freeze_mode, their grain
-- params, a source switch clearing freeze, the scene fields (discrete, and
-- a spectral mode recalled on standard), the VOICE rows, and what
-- randomize, mutation and the fader pages leave.
-- Run alone: lua test/run.lua freeze

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local HIGH = {tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60, reason = "high: setting"}

-- The freeze and freezeMode values setGrainParam sent since the engine
-- calls were cleared, as {index into engine_calls, voice, name, value}
local function sent_freeze(context)
  local sent = {}
  for index, call in ipairs(context.engine_calls) do
    if call.name == "setGrainParam" and (call.args[2] == "freeze" or call.args[2] == "freezeMode") then
      table.insert(sent, {index = index, voice = call.args[1], name = call.args[2], value = call.args[3]})
    end
  end
  return sent
end

local function first_call(context, name, voice)
  for index, call in ipairs(context.engine_calls) do
    if call.name == name and call.args[1] == voice then return index end
  end
end

local function row_ids(voice_idx)
  local ids = {}
  for _, row in ipairs(voice_page_rows(voice_idx)) do
    table.insert(ids, row.param_id and (row.section .. ":" .. row.param_id) or row.section)
  end
  return table.concat(ids, " ")
end

local function freeze_record(S)
  for _, record in ipairs(S.registry.voice_params) do
    if record.name == "freeze" then return record end
  end
end

test("freeze params are binary and mode has one option on standard", function()
  load_strata()
  local S = local_value("S")
  assert_true(S.lib.freeze ~= nil, "S.lib.freeze is the module's table")
  for voice_idx = 1, S.constants.NUM_VOICES do
    local freeze = params:lookup_param("v" .. voice_idx .. "_freeze")
    assert_equal(freeze.t, params.tBINARY, "v" .. voice_idx .. "_freeze is binary")
    assert_equal(freeze.behavior, "toggle", "a toggle")
    assert_equal(params:get("v" .. voice_idx .. "_freeze"), 0, "off by default")
    local mode = params:lookup_param("v" .. voice_idx .. "_freeze_mode")
    assert_equal(mode.t, params.tOPTION, "the mode is an option")
    assert_equal(table.concat(mode.options, ","), "hold", "standard offers hold only")
    assert_equal(params:get("v" .. voice_idx .. "_freeze_mode"), 1, "hold by default")
    assert_true(not S.lib.freeze.is_frozen(voice_idx), "voice " .. voice_idx .. " not frozen")
  end
  local record = freeze_record(S)
  assert_equal(record.count, 2, "two params per voice")
  assert_equal(record.scene_defaults.freeze, 0); assert_equal(record.scene_defaults.freeze_mode, 1)
  assert_true(record.discrete.freeze and record.discrete.freeze_mode, "both switch at a transition's end")
  assert_true(record.fader == false, "off the 256 fader pages")
  -- the high tier offers spectral
  h.write_performance_active(HIGH)
  load_strata()
  S = local_value("S")
  assert_equal(table.concat(params:lookup_param("v1_freeze_mode").options, ","), "hold,spectral", "high offers spectral")
  -- bounds-checked
  for _, bad in ipairs({0, 8, 1.5, "1"}) do
    assert_true(S.lib.freeze.is_frozen(bad) == false, "is_frozen(" .. tostring(bad) .. ") is false")
    S.lib.freeze.toggle(bad)
  end
end)

test("freeze reaches the engine and a source switch clears it", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  context.clear_engine_calls()
  params:set("v1_freeze", 1)
  local sent = sent_freeze(context)
  assert_equal(#sent, 1, "one message")
  assert_equal(sent[1].voice, 0); assert_equal(sent[1].name, "freeze"); assert_equal(sent[1].value, 1)
  assert_true(S.lib.freeze.is_frozen(1), "voice 1 is frozen")
  -- toggle
  context.clear_engine_calls()
  S.lib.freeze.toggle(1)
  assert_equal(params:get("v1_freeze"), 0, "toggle unfreezes")
  S.lib.freeze.toggle(1)
  assert_equal(params:get("v1_freeze"), 1, "and freezes again")
  -- a stopped voice stores it only
  context.clear_engine_calls()
  params:set("v3_freeze", 1)
  assert_equal(#sent_freeze(context), 0, "a stopped voice gets no message")
  assert_true(S.lib.freeze.is_frozen(3), "but stores it")
  params:set("v3_freeze", 0)
  -- the mode as an index - 1
  h.write_performance_active(HIGH)
  context = load_strata()
  finish_startup(context)
  context.clear_engine_calls()
  params:set("v1_freeze_mode", 2)
  sent = sent_freeze(context)
  assert_equal(#sent, 1); assert_equal(sent[1].name, "freezeMode"); assert_equal(sent[1].value, 1, "spectral is 1")
  -- a source switch clears it, after the source reached the engine
  params:set("v1_freeze", 1)
  context.clear_engine_calls()
  params:set("v1_source", 2)
  assert_equal(params:get("v1_freeze"), 0, "the switch unfroze voice 1")
  local source_at = first_call(context, "setGrainSource", 0)
  local last
  for _, each in ipairs(sent_freeze(context)) do
    if each.name == "freeze" and each.voice == 0 then last = each end
  end
  assert_true(source_at and last and last.index > source_at, "freeze 0 is sent after setGrainSource")
  assert_equal(last.value, 0, "and the last freeze sent is 0")
  -- a switch of a voice that is not frozen sends no freeze
  context.clear_engine_calls()
  params:set("v1_source", 3)
  for _, each in ipairs(sent_freeze(context)) do
    assert_true(each.name ~= "freeze" or each.value == 0, "an unfrozen voice is never frozen by a switch")
  end
end)

test("recalling a scene that changes source with freeze 1 ends frozen on the new source", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  params:set("v1_freeze", 1)
  capture_scene(1)
  assert_equal(S.scenes[1].data.voices[1].extras.freeze, 1, "the scene captures freeze")
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  assert_equal(params:get("v1_freeze"), 0, "the switch unfroze it")
  params:set("v1_freeze", 1)  -- frozen on the synth now
  context.clear_engine_calls()
  recall_scene(1, 0)
  assert_equal(params:get("v1_source"), S.constants.SOURCE_INPUT, "the scene's source")
  assert_equal(params:get("v1_freeze"), 1, "still frozen")
  local source_at = first_call(context, "setGrainSource", 0)
  local last
  for _, each in ipairs(sent_freeze(context)) do
    if each.name == "freeze" and each.voice == 0 then last = each end
  end
  assert_true(source_at and last and last.index > source_at and last.value == 1,
    "freeze 1 reaches the engine after the new source")
  -- a transition: freeze switches at its end, after the source
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  context.clear_engine_calls()
  recall_scene(1, 2); h.wake(context, "scene_transition_clock")
  assert_equal(params:get("v1_freeze"), 0, "not frozen during the transition")
  context.clock.run_for(3)
  assert_equal(params:get("v1_freeze"), 1, "frozen at its end")
  assert_equal(params:get("v1_source"), S.constants.SOURCE_INPUT)
end)

test("recalling a scene that changes source with freeze 0 leaves the voice unfrozen", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  params:set("v1_source", 2)
  capture_scene(1)
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  params:set("v1_freeze", 1)
  context.clear_engine_calls()
  recall_scene(1, 0)
  assert_equal(params:get("v1_source"), 2)
  assert_equal(params:get("v1_freeze"), 0, "unfrozen")
  local sent, freezes = sent_freeze(context), 0
  for _, each in ipairs(sent) do
    if each.name == "freeze" then
      freezes = freezes + 1
      assert_equal(each.value, 0, "no freeze 1 sent")
    end
  end
  assert_true(freezes > 0, "the engine was told freeze 0")
end)

test("spectral freeze mode recalled on standard freezes in hold", function()
  -- a scene saved on the high tier: voice 1 frozen in spectral mode
  h.write_performance_active(HIGH)
  local context = load_strata({data_subdir = "freeze_spectral_scene"})
  finish_startup(context)
  local S = local_value("S")
  params:set("v1_freeze_mode", 2)
  params:set("v1_freeze", 1)
  capture_scene(1)
  assert_equal(S.scenes[1].data.voices[1].extras.freeze_mode, 2, "captured as spectral")
  save_scenes_to_disk()
  -- loaded on standard
  h.write_performance_active({tier = "standard", buffer_seconds = 16, max_grains = 128, history_seconds = 16,
    reason = "standard: setting"})
  context = load_strata({data_subdir = "freeze_spectral_scene"})
  finish_startup(context)
  S = local_value("S")
  assert_true(validate_scene(S.scenes[1]), "the scene validates")
  context.clear_engine_calls()
  recall_scene(1, 0)
  assert_equal(params:get("v1_freeze_mode"), 1, "the mode clamps to hold")
  assert_equal(params:get("v1_freeze"), 1, "frozen")
  -- a PSET value past the options
  params:set("v1_freeze_mode", 2)
  assert_equal(params:get("v1_freeze_mode"), 1, "a PSET value clamps too")
  -- a voice started after the recall syncs hold as well
  params:set("v2_freeze_mode", 2); toggle_voice(3)
  local sent = sent_freeze(context)
  assert_true(#sent > 0, "freeze params were sent")
  for _, each in ipairs(sent) do
    if each.name == "freezeMode" then assert_equal(each.value, 0, "every freezeMode sent is hold (0)") end
  end
end)

test("VOICE's mix section has freeze, and freeze mode only on high", function()
  load_strata()
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    local prefix = "v" .. voice_idx
    for _, source in ipairs({S.constants.SOURCE_SYNTH, 2, S.constants.SOURCE_INPUT}) do
      params:set(prefix .. "_source", source)
      local outline = row_ids(voice_idx)
      assert_true(outline:find("mix:" .. prefix .. "_freeze", 1, true), prefix .. " has a freeze row in mix: " .. outline)
      assert_true(not outline:find("_freeze_mode", 1, true), prefix .. " has no mode row on standard: " .. outline)
    end
  end
  local freeze_row
  for _, row in ipairs(voice_page_rows(1)) do
    if row.param_id == "v1_freeze" then freeze_row = row end
  end
  assert_equal(freeze_row.kind, "binary", "a binary row")
  h.write_performance_active(HIGH)
  load_strata()
  local outline = row_ids(1)
  assert_true(outline:find("mix:v1_freeze mix:v1_freeze_mode", 1, true), "high adds the mode after freeze: " .. outline)
end)

test("the freeze rows lay out on VOICE", function()
  for _, tier in ipairs({"standard", "high"}) do
    if tier == "high" then h.write_performance_active(HIGH) end
    local context = load_strata()
    finish_startup(context)
    local S = local_value("S")
    h.show_page("VOICE")
    for voice_idx = 1, S.constants.NUM_VOICES do
      S.selected_voice = voice_idx
      params:set("v" .. voice_idx .. "_freeze", 1)
      S.lib.pages_voice.sync_cursor()
      local id = tier == "high" and "_freeze_mode" or "_freeze"
      S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of("v" .. voice_idx .. id))
      redraw()
      assert_true(h.screen_shows(context, "freeze"), "v" .. voice_idx .. " shows the freeze row")
      h.assert_screen_layout(context, "VOICE v" .. voice_idx .. " on freeze (" .. tier .. ")")
    end
  end
end)

test("randomize and mutation never touch freeze", function()
  h.write_performance_active(HIGH)
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    params:set("v" .. voice_idx .. "_freeze", voice_idx % 2)
    params:set("v" .. voice_idx .. "_freeze_mode", 2)
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(11)
  for voice_idx = 1, S.constants.NUM_VOICES do randomize_voice(voice_idx) end
  for _ = 1, 20 do gentle_mutate() end
  for _ = 1, 20 do drift_update() end
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice_idx .. "_freeze"), voice_idx % 2, "voice " .. voice_idx .. " freeze untouched")
    assert_equal(params:get("v" .. voice_idx .. "_freeze_mode"), 2, "voice " .. voice_idx .. " mode untouched")
    for _, param_id in ipairs(fader_param_ids(voice_idx)) do
      assert_true(not param_id:find("freeze", 1, true), param_id .. " is not a freeze param")
    end
  end
end)

end

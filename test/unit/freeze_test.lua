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
  -- no freeze 1 at all: the hook clears it before the voice's sync, so the
  -- engine never freezes the new source for a moment (synth -> input too)
  for _, from_to in ipairs({{2, 1}, {1, S.constants.SOURCE_INPUT}, {S.constants.SOURCE_INPUT, 3}}) do
    params:set("v1_source", from_to[1])
    params:set("v1_freeze", 1)
    context.clear_engine_calls()
    params:set("v1_source", from_to[2])
    local freezes = 0
    for _, each in ipairs(sent_freeze(context)) do
      if each.name == "freeze" then
        freezes = freezes + 1
        assert_equal(each.value, 0, "a switch " .. from_to[1] .. " -> " .. from_to[2] .. " never sends freeze 1")
      end
    end
    assert_true(freezes > 0, "the switch sends freeze 0")
    assert_true(first_call(context, "setGrainSource", 0) < sent_freeze(context)[1].index, "after the source")
  end
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
  assert_equal(S.scenes[1].data.voices[1].values.freeze, 1, "the scene captures freeze")
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
  assert_equal(S.scenes[1].data.voices[1].values.freeze_mode, 2, "captured as spectral")
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

-- #538: norns' Binary:set sends no MIDI-map CC (only ParamSet:delta does),
-- so a freeze the player sets from the script goes through set_binary_param
-- (lib/ui/params.lua) and a controller mapped to v<i>_freeze in PARAMS >
-- MAP follows. The map is as lua/core/pmap.lua's pmap.new makes it, echo on
local function map_freeze(context, voice_idx, cc)
  local controller = context.midi.plug(1)
  norns.pmap.data["v" .. voice_idx .. "_freeze"] = { dev = 1, ch = 1, cc = cc, in_lo = 0, in_hi = 127,
    out_lo = 0, out_hi = 1, echo = true, value = 0 }
  return function()
    local values = {}
    for _, message in ipairs(controller.sent) do
      if message[2] == cc then table.insert(values, message[3]) end
    end
    return table.concat(values, ",")
  end
end

test("a freeze toggle echoes v<i>_freeze to a MIDI-mapped controller (#538)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local echoes = map_freeze(context, 1, 30)
  S.lib.freeze.toggle(1)
  assert_equal(params:get("v1_freeze"), 1, "frozen")
  assert_equal(echoes(), "127", "the controller hears the freeze")
  S.lib.freeze.toggle(1)
  assert_equal(echoes(), "127,0", "and the unfreeze")
end)

test("a source switch's unfreeze echoes v<i>_freeze to a MIDI-mapped controller (#538)", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_freeze", 1)
  local echoes = map_freeze(context, 1, 31)
  params:set("v1_source", 2)
  assert_equal(params:get("v1_freeze"), 0, "the switch unfroze voice 1")
  assert_equal(echoes(), "0", "the controller hears the unfreeze")
end)

-- 3.4 (design §8.9): a freeze key's toggle waits for the beat or bar
-- quantize_actions names; toggle itself (VOICE's row, a CC) stays immediate
test("toggle_quantized waits for the bar; toggle flips at once", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function run_to_beat(beat)
    context.clock.run_for((beat - clock.get_beats()) * clock.get_beat_sec())
  end
  S.lib.freeze.toggle_quantized(3)
  assert_true(S.lib.freeze.is_frozen(3), "quantize off: at once")
  S.lib.freeze.toggle(3)

  params:set("quantize_actions", 3)  -- bar
  run_to_beat(1.5)
  S.lib.freeze.toggle_quantized(3)
  assert_true(not S.lib.freeze.is_frozen(3), "not before the bar")
  assert_equal(S.lib.ui_flash.text("header"), "v3 frz at bar", "the header says it waits")
  run_to_beat(3.98)
  assert_true(not S.lib.freeze.is_frozen(3), "beat 3.98: still not")
  run_to_beat(4.02)
  assert_true(S.lib.freeze.is_frozen(3), "the freeze flips at the bar")
  S.lib.freeze.toggle(3)
  assert_true(not S.lib.freeze.is_frozen(3), "toggle still flips at once under bar")

  for _, bad in ipairs({0, 8, 2.5, "3"}) do
    S.lib.freeze.toggle_quantized(bad)
  end
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_true(not S.lib.quantize.waiting("freeze" .. voice_idx), "a bad voice index schedules nothing")
  end
end)

-- A freeze key pressed again while its toggle waits takes the toggle back
-- (#625); another voice's waiting toggle stays
test("a second freeze key press while its toggle waits takes it back", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function run_to_beat(beat)
    context.clock.run_for((beat - clock.get_beats()) * clock.get_beat_sec())
  end
  params:set("quantize_actions", 3)  -- bar
  run_to_beat(1.5)
  S.lib.freeze.toggle_quantized(2)
  S.lib.freeze.toggle_quantized(4)
  assert_equal(S.lib.ui_flash.text("header"), "v4 frz at bar")
  S.lib.freeze.toggle_quantized(4)
  assert_true(not S.lib.quantize.waiting("freeze4"), "the second press takes voice 4's toggle back")
  assert_true(S.lib.quantize.waiting("freeze2"), "voice 2's still waits")
  assert_equal(S.lib.ui_flash.text("header"), nil, "the taken-back toggle's flash goes")
  run_to_beat(4.02)
  assert_true(S.lib.freeze.is_frozen(2), "voice 2 freezes at the bar")
  assert_true(not S.lib.freeze.is_frozen(4), "voice 4 does not")
  S.lib.freeze.toggle_quantized(4)
  assert_true(S.lib.quantize.waiting("freeze4"), "a third press waits again")
  run_to_beat(8.02)
  assert_true(S.lib.freeze.is_frozen(4), "and freezes at its bar")
end)

-- 3.9 (#864): the freeze key's machine, voice 3 with quantize_actions on
-- bar, every state entered at beat 1.5. A waiting key sets the value its
-- press asked for (the opposite of the freeze at the press), whatever
-- happened before the bar; a second key takes the waiting set back. Which
-- value waits is not readable from outside (it is the scheduled closure's),
-- so the table keeps what each press asked for on the context, and the bar
-- rows, and the check of every row that leaves a set waiting, run the bar
-- and assert what it sets
local KEY_VOICE = 3
local KEY_ID = "v" .. KEY_VOICE .. "_freeze"
local KEY_ACTION = "freeze" .. KEY_VOICE
local KEY_BAR = 4  -- quantize_actions' bar, in beats

local KEY_SOURCE_ID = "v" .. KEY_VOICE .. "_source"

-- The source a switch or a recall moves voice 3 to: the input, or the synth
-- from the input
local function key_other_source(S)
  if params:get(KEY_SOURCE_ID) == S.constants.SOURCE_INPUT then return S.constants.SOURCE_SYNTH end
  return S.constants.SOURCE_INPUT
end

local function key_state(S) return S.lib.freeze.is_frozen(KEY_VOICE) and "on" or "off" end

local function key_run_to_beat(context, beat)
  context.clock.run_for((beat - clock.get_beats()) * clock.get_beat_sec())
end

-- The bar after now, and a little past it
local function key_bar(context)
  key_run_to_beat(context, (math.floor(clock.get_beats() / KEY_BAR) + 1) * KEY_BAR + 0.02)
end

-- A press of voice 3's FZ key, keeping what it asked for: nothing if it took
-- a waiting set back, else the opposite of the freeze it found
local function key_press(context)
  local S = local_value("S")
  if S.lib.quantize.waiting(KEY_ACTION) then
    context.asked = nil
  else
    context.asked = S.lib.freeze.is_frozen(KEY_VOICE) and 0 or 1
  end
  S.lib.freeze.toggle_quantized(KEY_VOICE)
end

local function key_enter(frozen, press, then_set)
  return function(context)
    params:set("quantize_actions", 3)  -- bar
    key_run_to_beat(context, 1.5)
    params:set(KEY_ID, frozen)
    if press then key_press(context) end
    if then_set ~= nil then params:set(KEY_ID, then_set) end
  end
end

-- A row's check: the bar then leaves the voice as `expected`, nothing waiting
local function then_the_bar(expected)
  return function(context)
    key_bar(context)
    local S = local_value("S")
    assert_equal(key_state(S), expected, "after the bar")
    assert_true(not S.lib.quantize.waiting(KEY_ACTION), "nothing waits after the bar")
  end
end

h.transition_table({
  name = "freeze key",
  notes = {"docs/notes/lua/freeze.md", "freeze key"},
  states = {
    ["off"] = key_enter(0),
    ["on"] = key_enter(1),
    ["off, freeze waits"] = key_enter(0, true),
    ["off, unfreeze waits"] = key_enter(1, true, 0),
    ["on, freeze waits"] = key_enter(0, true, 1),
    ["on, unfreeze waits"] = key_enter(1, true),
  },
  events = {
    ["key"] = key_press,
    ["source switch"] = function() params:set(KEY_SOURCE_ID, key_other_source(local_value("S"))) end,
    ["hand set 0"] = function() params:set(KEY_ID, 0) end,
    ["hand set 1"] = function() params:set(KEY_ID, 1) end,
    -- a scene that holds the opposite of the voice's freeze on the other
    -- source: the recall sets the scene's source (no source change hook
    -- runs), then its freeze
    ["recall"] = function()
      local S = local_value("S")
      capture_scene(1)
      local scene_voice = S.scenes[1].data.voices[KEY_VOICE]
      scene_voice.source = key_other_source(S)
      scene_voice.values.freeze = S.lib.freeze.is_frozen(KEY_VOICE) and 0 or 1
      recall_scene(1, 0)
      assert_equal(params:get(KEY_SOURCE_ID), scene_voice.source, "the recall set the scene's source")
    end,
    ["the bar"] = key_bar,
  },
  state_of = function(context)
    local S = local_value("S")
    local state = key_state(S)
    if not S.lib.quantize.waiting(KEY_ACTION) then return state end
    if context.asked == 1 then return state .. ", freeze waits" end
    if context.asked == 0 then return state .. ", unfreeze waits" end
    return state .. ", a set waits that no press asked for"
  end,
  rows = {
    {"off", "key", "off, freeze waits", check = then_the_bar("on")},
    {"off", "source switch", "off"},
    {"off", "hand set 0", "off"},
    {"off", "hand set 1", "on"},
    {"off", "recall", "on"},
    {"off", "the bar", "off"},
    {"on", "key", "on, unfreeze waits", check = then_the_bar("off")},
    {"on", "source switch", "off"},
    {"on", "hand set 0", "off"},
    {"on", "hand set 1", "on"},
    {"on", "recall", "off"},
    {"on", "the bar", "on"},
    {"off, freeze waits", "key", "off", check = then_the_bar("off")},
    {"off, freeze waits", "source switch", "off, freeze waits", check = then_the_bar("on")},
    {"off, freeze waits", "hand set 0", "off, freeze waits", check = then_the_bar("on")},
    {"off, freeze waits", "hand set 1", "on, freeze waits", check = then_the_bar("on")},
    {"off, freeze waits", "recall", "on, freeze waits", check = then_the_bar("on")},
    {"off, freeze waits", "the bar", "on"},
    {"off, unfreeze waits", "key", "off", check = then_the_bar("off")},
    {"off, unfreeze waits", "source switch", "off, unfreeze waits", check = then_the_bar("off")},
    {"off, unfreeze waits", "hand set 0", "off, unfreeze waits", check = then_the_bar("off")},
    {"off, unfreeze waits", "hand set 1", "on, unfreeze waits", check = then_the_bar("off")},
    {"off, unfreeze waits", "recall", "on, unfreeze waits", check = then_the_bar("off")},
    {"off, unfreeze waits", "the bar", "off"},
    {"on, freeze waits", "key", "on", check = then_the_bar("on")},
    {"on, freeze waits", "source switch", "off, freeze waits", check = then_the_bar("on")},
    {"on, freeze waits", "hand set 0", "off, freeze waits", check = then_the_bar("on")},
    {"on, freeze waits", "hand set 1", "on, freeze waits", check = then_the_bar("on")},
    {"on, freeze waits", "recall", "off, freeze waits", check = then_the_bar("on")},
    {"on, freeze waits", "the bar", "on"},
    {"on, unfreeze waits", "key", "on", check = then_the_bar("on")},
    {"on, unfreeze waits", "source switch", "off, unfreeze waits", check = then_the_bar("off")},
    {"on, unfreeze waits", "hand set 0", "off, unfreeze waits", check = then_the_bar("off")},
    {"on, unfreeze waits", "hand set 1", "on, unfreeze waits", check = then_the_bar("off")},
    {"on, unfreeze waits", "recall", "off, unfreeze waits", check = then_the_bar("off")},
    {"on, unfreeze waits", "the bar", "off"},
  },
})

-- The issue's sequences (#864), as the player meets them
test("a waiting freeze key sets the value its press asked for, whatever happened before the bar (#864)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("quantize_actions", 3)  -- bar
  key_run_to_beat(context, 1.5)
  -- frozen, the key asks for an unfreeze, a source switch unfreezes now
  params:set(KEY_ID, 1)
  S.lib.freeze.toggle_quantized(KEY_VOICE)
  params:set("v" .. KEY_VOICE .. "_source", S.constants.SOURCE_INPUT)
  assert_true(not S.lib.freeze.is_frozen(KEY_VOICE), "the switch unfroze the voice")
  assert_true(S.lib.quantize.waiting(KEY_ACTION), "the key's set still waits")
  key_bar(context)
  assert_true(not S.lib.freeze.is_frozen(KEY_VOICE), "the bar leaves the new source unfrozen")
  -- unfrozen, the key asks for a freeze, a hand set freezes now
  S.lib.freeze.toggle_quantized(KEY_VOICE)
  params:set(KEY_ID, 1)
  key_bar(context)
  assert_true(S.lib.freeze.is_frozen(KEY_VOICE), "the bar keeps the voice frozen")
end)

test("a second freeze key takes the waiting set back (#864)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("quantize_actions", 3)  -- bar
  key_run_to_beat(context, 1.5)
  S.lib.freeze.toggle_quantized(KEY_VOICE)
  params:set(KEY_ID, 1)  -- frozen by hand while the freeze waits
  S.lib.freeze.toggle_quantized(KEY_VOICE)
  assert_true(not S.lib.quantize.waiting(KEY_ACTION), "the second key takes the waiting set back")
  assert_true(S.lib.freeze.is_frozen(KEY_VOICE), "and leaves the voice as it is")
  key_bar(context)
  assert_true(S.lib.freeze.is_frozen(KEY_VOICE), "the bar sets nothing")
end)

-- 3.5's freeze-change registry (design §0.1): the param's action runs the
-- hooks once the value is stored and sent, before its grid redraw
test("the freeze param runs the freeze-change hooks", function()
  local log, context = {}, nil
  context = load_strata({ before_init = function()
    local S = local_value("S")
    S.register_freeze_change(function(voice_idx, frozen)
      local sent = sent_freeze(context)
      local last = sent[#sent]
      log[#log + 1] = string.format("%d:%s stored %s sent %s", voice_idx, tostring(frozen),
        tostring(S.lib.freeze.is_frozen(voice_idx)), last and (last.voice .. "=" .. last.value) or "none")
    end)
  end })
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[2].active, "voice 2 runs")
  local real_grid_redraw = grid_redraw
  grid_redraw = function(...) log[#log + 1] = "grid"; return real_grid_redraw(...) end
  context.clear_engine_calls()
  params:set("v2_freeze", 1)
  params:set("v2_freeze", 0)
  grid_redraw = real_grid_redraw
  assert_equal(table.concat(log, ", "), "2:true stored true sent 1=1, grid, 2:false stored false sent 1=0, grid",
    "each change runs the hooks with the voice and its state, after the send, before the grid redraw")
end)

-- A freeze-change hook that raises is reported (once per distinct message)
-- and skipped: the other hooks and the grid redraw still run
test("a raising freeze-change hook is reported and skipped", function()
  local log = {}
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    S.register_freeze_change(function(voice_idx, frozen) error("freeze hook boom " .. tostring(frozen)) end)
    S.register_freeze_change(function(voice_idx, frozen) log[#log + 1] = voice_idx .. ":" .. tostring(frozen) end)
  end })
  finish_startup(context)
  local real_grid_redraw = grid_redraw
  grid_redraw = function(...) log[#log + 1] = "grid"; return real_grid_redraw(...) end
  local set, set_error = pcall(params.set, params, "v2_freeze", 1)
  assert_true(set, "the set completes: " .. tostring(set_error))
  assert_true(local_value("S").lib.freeze.is_frozen(2), "the voice is frozen")
  h.claim_script_errors(context, 1, "strata: freeze change hook failed: ", "freeze hook boom true")
  set, set_error = pcall(params.set, params, "v2_freeze", 0)
  grid_redraw = real_grid_redraw
  assert_true(set, "the unfreeze completes: " .. tostring(set_error))
  h.claim_script_errors(context, 1, "strata: freeze change hook failed: ", "freeze hook boom false")
  assert_equal(table.concat(log, ", "), "2:true, grid, 2:false, grid", "the good hook and the grid redraw still run")
end)

-- 3.8 (package 1d): a voice reading another voice's ring freezes as an
-- input voice does: on high its spectral mode reaches the engine
-- (freezeMode 1, then freeze 1), on standard the mode stays hold (freezeMode
-- 0); a switch to another voice's ring unfreezes it
test("a voice source freezes, and a switch unfreezes", function()
  local function freeze_spectral(tier)
    if tier then h.write_performance_active(tier) end
    local context = load_strata()
    finish_startup(context)
    local S = local_value("S")
    params:set("v1_source", S.constants.SOURCE_VOICE_FIRST + 1)
    context.clear_engine_calls()
    params:set("v1_freeze_mode", 2)
    params:set("v1_freeze", 1)
    local texts = {}
    for _, each in ipairs(sent_freeze(context)) do
      if each.voice == 0 then texts[#texts + 1] = each.name .. " " .. each.value end
    end
    return S, table.concat(texts, ", ")
  end
  local S, sent = freeze_spectral(HIGH)
  assert_equal(sent, "freezeMode 1, freeze 1", "on high: spectral, then the freeze")
  assert_true(S.lib.freeze.is_frozen(1), "the voice is frozen")
  params:set("v1_source", S.constants.SOURCE_VOICE_FIRST + 2)
  assert_equal(params:get("v1_freeze"), 0, "a switch to another voice's ring unfreezes")
  S, sent = freeze_spectral({tier = "standard", buffer_seconds = 16, max_grains = 128, history_seconds = 16,
    reason = "standard: setting"})
  assert_equal(params:get("v1_freeze_mode"), 1, "standard offers hold only")
  assert_true(not sent:find("freezeMode 1", 1, true), "standard never sends spectral (sent: " .. sent .. ")")
  assert_true(sent:find("freeze 1", 1, true) ~= nil, "standard freezes in hold (sent: " .. sent .. ")")
end)

-- #858: the engine gave up a hold whose copy was late eight times over
-- and unfroze the voice itself; its freezeEnded report (the voice's ended
-- holds, counted from 1, times NUM_VOICES plus the engine voice) sets
-- v<i>_freeze to 0 through set_binary_param, its action and hooks running,
-- with no freeze message to the engine (it has unfrozen already). A repeat
-- of a report (a value request resends the last) or an older one, a voice
-- not frozen and a bad value do nothing
test("the engine's ended hold sets v<i>_freeze to 0 and sends no unfreeze (#858)", function()
  local log, context = {}, nil
  context = load_strata({ before_init = function()
    local_value("S").register_freeze_change(function(voice_idx, frozen) log[#log + 1] = voice_idx .. ":" .. tostring(frozen) end)
  end })
  finish_startup(context)
  local S = local_value("S")
  local NUM_VOICES = S.constants.NUM_VOICES
  local function ended(voice_idx, count) context.polls.fire("freezeEnded", count * NUM_VOICES + voice_idx - 1) end
  assert_true(S.voices[2].active, "voice 2 runs")
  params:set("v2_source", S.constants.SOURCE_INPUT)
  params:set("v2_freeze", 1)
  local echoes = map_freeze(context, 2, 32)
  log = {}
  context.clear_engine_calls()
  ended(2, 1)
  assert_equal(params:get("v2_freeze"), 0, "the param follows the engine")
  assert_true(not S.lib.freeze.is_frozen(2), "MAIN's [F] reads the voice unfrozen")
  assert_equal(#sent_freeze(context), 0, "no freeze message reaches the engine")
  assert_equal(table.concat(log, ", "), "2:false", "the freeze-change hooks ran")
  assert_equal(echoes(), "0", "a mapped controller hears the unfreeze")
  assert_equal(S.engine_param_values.v2_freeze, 0, "the engine's value is recorded as 0")
  -- the next freeze reaches the engine again
  params:set("v2_freeze", 1)
  assert_equal(#sent_freeze(context), 1, "a freeze after it is sent")
  context.clear_engine_calls()
  ended(2, 1)
  ended(2, 0)
  assert_equal(params:get("v2_freeze"), 1, "a repeated or older report does nothing")
  ended(3, 1)
  assert_equal(params:get("v3_freeze"), 0, "a voice not frozen stays as it is")
  for _, value in ipairs({0 / 0, -1, math.huge, "x"}) do context.polls.fire("freezeEnded", value) end
  assert_equal(params:get("v2_freeze"), 1, "a bad value does nothing")
  ended(2, 2)
  assert_equal(params:get("v2_freeze"), 0, "the voice's next ended hold acts")
  assert_equal(#sent_freeze(context), 0, "and sends nothing either")
end)

-------------------------------------------------------------------------------
-- 3.9 (#908): the voice kind, a table. A voice is a synth, frozen synth,
-- buffer, input or voice source voice, stopped or running (read from the
-- script: its source, its freeze and whether it runs); each event is a
-- source set, a freeze set, a start or a stop, by hand or in a recall (an
-- instant recall of a scene captured now with the one field changed). Voice
-- 3 enters at 440 Hz (a running frozen synth voice takes its freeze
-- reference there, note 69), then its freq goes to 220 Hz (note 57), and a
-- running voice holds an own note and one extra note. The buffer states read
-- slot 1 and the voice source states voice 1's ring; "source buffer 2" and
-- "source voice 2" switch to slot 2 and voice 2's ring, so the same kind
-- again is a switch too. Each row's check asserts the freeze param, the
-- freeze reference, the extra notes held, the last scaleNote the event sent
-- (or none) and that a model of the engine's slots (test/notes_model.lua)
-- agrees with Lua's held notes
-------------------------------------------------------------------------------
local Model = require("notes_model")
local KIND_VOICE = 3
local KIND_PREFIX = "v" .. KIND_VOICE .. "_"
local KIND_FROZE_AT, KIND_NOW = 69, 57  -- 440 Hz and 220 Hz as notes
local KIND_RING = 60                     -- a buffer, input or voice source voice's scaleNote: root C + 60

local function kind_sources(S)
  local c = S.constants
  return {synth = c.SOURCE_SYNTH, buffer = c.SOURCE_SYNTH + 1, input = c.SOURCE_INPUT,
    ["voice source"] = c.SOURCE_VOICE_FIRST, ["buffer 2"] = c.SOURCE_SYNTH + 2, ["voice 2"] = c.SOURCE_VOICE_FIRST + 1}
end

local function kind_note(key, pitch)
  return {owner = "midi", key = key, pitch = pitch, velocity = 0.5, park = true, set_own = function() end}
end

local function kind_enter(kind, running)
  return function(context)
    local S = local_value("S")
    params:set(KIND_PREFIX .. "freq", 440)
    params:set(KIND_PREFIX .. "source", kind_sources(S)[kind == "frozen synth" and "synth" or kind])
    params:set(KIND_PREFIX .. "freeze", kind == "frozen synth" and 1 or 0)
    if running then toggle_voice(KIND_VOICE) end
    params:set(KIND_PREFIX .. "freq", 220)
    if running then
      assert_equal(S.lib.notes.play(KIND_VOICE, kind_note(1, 60)), 1, "the own note")
      assert_equal(S.lib.notes.play(KIND_VOICE, kind_note(2, 64)), 2, "an extra note")
    end
    context.set_time(util.time() + 0.1)
    context.kind_mark = #context.engine_calls
  end
end

local function kind_of(S)
  local kind = "input"
  if voice_uses_synth(KIND_VOICE) then
    kind = S.lib.freeze.is_frozen(KIND_VOICE) and "frozen synth" or "synth"
  elseif voice_uses_buffer(KIND_VOICE) then
    kind = "buffer"
  elseif voice_uses_voice(KIND_VOICE) then
    kind = "voice source"
  end
  return kind .. (S.voices[KIND_VOICE].active and ", running" or ", stopped")
end

-- A recall of a scene captured now, with change(scene's voice 3) applied
local function kind_recall(change)
  return function()
    local S = local_value("S")
    capture_scene(1)
    change(S.scenes[1].data.voices[KIND_VOICE], S)
    recall_scene(1, 0)
  end
end

local function kind_source(target, recall)
  if recall then
    return kind_recall(function(voice, S) voice.source = kind_sources(S)[target] end)
  end
  return function() params:set(KIND_PREFIX .. "source", kind_sources(local_value("S"))[target]) end
end

local function kind_freeze(value, recall)
  if recall then return kind_recall(function(voice) voice.values.freeze = value end) end
  return function() params:set(KIND_PREFIX .. "freeze", value) end
end

-- A start or a stop: by hand through the actions' run_voice (crow, ii,
-- OSC: on or off), which calls toggle_voice, K3's, only when the voice is
-- not already as asked; in a recall the scene's active entry
local function kind_run(running, recall)
  if recall then return kind_recall(function(voice) voice.active = running end) end
  return function()
    assert_true(local_value("S").lib.io_actions.run_voice(KIND_VOICE, running and 1 or 0), "run_voice took it")
  end
end

local function kind_extras(S)
  local extras = 0
  for _, used in ipairs(S.lib.notes.slots(KIND_VOICE)) do
    if used.slot > 1 and used.held then extras = extras + 1 end
  end
  return extras
end

-- The last scaleNote sent to voice 3 after call number `after` (nil: none)
local function kind_scale_sent(context, after)
  local sent
  for index = after + 1, #context.engine_calls do
    local call = context.engine_calls[index]
    if call.name == "setGrainParam" and call.args[1] == KIND_VOICE - 1 and call.args[2] == "scaleNote" then
      sent = call.args[3]
    end
  end
  return sent
end

local function kind_assert(context, freeze, reference, extras, scale, where)
  local S = local_value("S")
  where = where and (where .. ": ") or ""
  assert_equal(params:get(KIND_PREFIX .. "freeze"), freeze, where .. "the freeze param")
  assert_equal(kind_extras(S), extras, where .. "the extra notes held")
  -- a running voice: the scaleNote the engine holds (the last one sent,
  -- whenever: a recall's freq set resends it as a hand set does); a stopped
  -- voice: none sent by the event
  if scale then
    local held = kind_scale_sent(context, 0)
    assert_true(held ~= nil, where .. "a scaleNote was sent")
    h.assert_near(held, scale, 1e-9, where .. "the scaleNote the engine holds")
  else
    assert_equal(kind_scale_sent(context, context.kind_mark), nil, where .. "no scaleNote sent")
  end
  local found = S.lib.notes.freeze_reference(KIND_VOICE)
  if reference then
    assert_true(found ~= nil, where .. "a freeze reference")
    h.assert_near(found, reference, 1e-9, where .. "the freeze reference")
  else
    assert_equal(found, nil, where .. "no freeze reference")
  end
  local model = Model.new(S.constants, S.lib.notes.NOTES)
  model:feed(context.engine_calls)
  local problems = model:compare(S)
  assert_equal(table.concat(problems, "; "), "", where .. "the engine's slots agree with Lua's held notes")
end

-- A row's check: freeze (0 or 1), reference (a note or nil), extras (the
-- extra notes held), scale (the last scaleNote sent, or false: none)
local function kind_expect(freeze, reference, extras, scale, more)
  return function(context)
    kind_assert(context, freeze, reference, extras, scale)
    if more then more(context) end
  end
end

-- Ruling 58 (#690), driven on from a frozen synth voice a recall left a
-- frozen buffer voice: a recall back to its synth, the freeze kept, cuts
-- the extra note and takes a fresh reference
local function kind_and_back(context)
  context.kind_mark = #context.engine_calls
  kind_source("synth", true)()
  assert_equal(kind_of(local_value("S")), "frozen synth, running", "back on the synth, frozen")
  kind_assert(context, 1, KIND_NOW, 0, KIND_NOW, "and back")
end

local E = kind_expect
local SR, SS, FR, FS = "synth, running", "synth, stopped", "frozen synth, running", "frozen synth, stopped"
local BR, BS, IR, IS = "buffer, running", "buffer, stopped", "input, running", "input, stopped"
local VR, VS = "voice source, running", "voice source, stopped"

local kind_states, kind_events = {}, {}
for _, kind in ipairs({"synth", "frozen synth", "buffer", "input", "voice source"}) do
  kind_states[kind .. ", stopped"] = kind_enter(kind, false)
  kind_states[kind .. ", running"] = kind_enter(kind, true)
end
for _, how in ipairs({{", by hand", false}, {", in a recall", true}}) do
  for _, target in ipairs({"synth", "buffer 2", "input", "voice 2"}) do
    kind_events["source " .. target .. how[1]] = kind_source(target, how[2])
  end
  kind_events["freeze 1" .. how[1]] = kind_freeze(1, how[2])
  kind_events["freeze 0" .. how[1]] = kind_freeze(0, how[2])
  kind_events["start" .. how[1]] = kind_run(true, how[2])
  kind_events["stop" .. how[1]] = kind_run(false, how[2])
end

-- The engine calls to voice 3 named `names` (a set) since the mark; for
-- setGrainParam, only the grain param `param`
local function kind_calls(context, names, param)
  local count = 0
  for index = context.kind_mark + 1, #context.engine_calls do
    local call = context.engine_calls[index]
    if names[call.name] and call.args[1] == KIND_VOICE - 1 and (param == nil or call.args[2] == param) then
      count = count + 1
    end
  end
  return count
end

-- A start of a running voice and a stop of a stopped one change nothing:
-- by hand nothing at all is sent; in a recall the voice is neither started,
-- stopped nor switched and no note or freeze goes (a recall's freq set may
-- resend its value and scaleNote, as in every recall row)
local KIND_NO_RUN = {voiceOn = true, voiceOff = true, setGrainSource = true, noteOn = true, noteOff = true}
local function kind_nothing(recall)
  return function(context)
    if not recall then
      assert_equal(#context.engine_calls, context.kind_mark, "nothing sent")
      return
    end
    assert_equal(kind_calls(context, KIND_NO_RUN), 0, "no start, stop, switch or note")
    assert_equal(kind_calls(context, {setGrainParam = true}, "freeze"), 0, "no freeze sent")
  end
end

-- by hand and in a recall alike: {event suffix, ...}
local HAND, RECALL = ", by hand", ", in a recall"
local kind_rows = {}

-- A recall's source set runs no source change hook: the freeze it sends is
-- the end's sync's one, on a running voice whose source the scene changed
-- (none on a stopped voice, whose senders are gated, or for the same
-- source). The source hooks, run in a recall, would send more (#908's 5th
-- review finding)
local function recall_freezes(state, target)
  if not state:find(", running$") then return 0 end
  local same = (target == "synth" and state:find("synth, running$") ~= nil) or (target == "input" and state == "input, running")
  return same and 0 or 1
end

local function rows(state, how, list)
  for _, row in ipairs(list) do
    local check, target = row[3], row[1]:match("^source (.+)$")
    if how == RECALL and target then
      local wanted, own = recall_freezes(state, target), check
      check = function(context)
        local sent = kind_calls(context, {setGrainParam = true}, "freeze")
        own(context)
        assert_equal(sent, wanted, "the freeze sends the recall made")
      end
    end
    table.insert(kind_rows, {state, row[1] .. how, row[2], check = check, known = row.known})
  end
end

-- synth, running: an own note and an extra note held, unfrozen
for _, how in ipairs({HAND, RECALL}) do
  rows(SR, how, {
    {"source synth", SR, E(0, nil, 1, KIND_NOW)},
    {"source buffer 2", BR, E(0, nil, 1, KIND_RING)},
    {"source input", IR, E(0, nil, 1, KIND_RING)},
    {"source voice 2", VR, E(0, nil, 1, KIND_RING)},
    {"freeze 1", FR, E(1, KIND_NOW, 0, KIND_NOW)},
    {"freeze 0", SR, E(0, nil, 1, KIND_NOW)},
    {"stop", SS, E(0, nil, 0, false)},
    {"start", SR, E(0, nil, 1, KIND_NOW, kind_nothing(how == RECALL))},
  })
end
-- frozen synth, running: frozen at 440 Hz, its freq at 220 Hz since
rows(FR, HAND, {
  {"source synth", FR, E(1, KIND_FROZE_AT, 1, KIND_FROZE_AT)},
  {"source buffer 2", BR, E(0, nil, 1, KIND_RING)},
  {"source input", IR, E(0, nil, 1, KIND_RING)},
  {"source voice 2", VR, E(0, nil, 1, KIND_RING)},
})
rows(FR, RECALL, {
  {"source synth", FR, E(1, KIND_FROZE_AT, 1, KIND_FROZE_AT)},
  {"source buffer 2", BR, E(1, nil, 1, KIND_RING, kind_and_back)},
  {"source input", IR, E(1, nil, 1, KIND_RING)},
  {"source voice 2", VR, E(1, nil, 1, KIND_RING)},
})
for _, how in ipairs({HAND, RECALL}) do
  rows(FR, how, {
    {"freeze 1", FR, E(1, KIND_FROZE_AT, 1, KIND_FROZE_AT)},
    {"freeze 0", SR, E(0, nil, 1, KIND_NOW)},
    {"stop", FS, E(1, KIND_NOW, 0, false)},
    {"start", FR, E(1, KIND_FROZE_AT, 1, KIND_FROZE_AT, kind_nothing(how == RECALL))},
  })
end
-- buffer, input and voice source, running
for _, how in ipairs({HAND, RECALL}) do
  rows(BR, how, {
    {"source synth", SR, E(0, nil, 1, KIND_NOW)},
    {"source buffer 2", BR, E(0, nil, 1, KIND_RING)},
    {"source input", IR, E(0, nil, 1, KIND_RING)},
    {"source voice 2", VR, E(0, nil, 1, KIND_RING)},
    {"freeze 1", BR, E(1, nil, 1, KIND_RING)},
    {"freeze 0", BR, E(0, nil, 1, KIND_RING)},
    {"stop", BS, E(0, nil, 0, false)},
    {"start", BR, E(0, nil, 1, KIND_RING, kind_nothing(how == RECALL))},
  })
  rows(IR, how, {
    {"source synth", SR, E(0, nil, 1, KIND_NOW)},
    {"source buffer 2", BR, E(0, nil, 1, KIND_RING)},
    {"source input", IR, E(0, nil, 1, KIND_RING)},
    {"source voice 2", VR, E(0, nil, 1, KIND_RING)},
    {"freeze 1", IR, E(1, nil, 1, KIND_RING)},
    {"freeze 0", IR, E(0, nil, 1, KIND_RING)},
    {"stop", IS, E(0, nil, 0, false)},
    {"start", IR, E(0, nil, 1, KIND_RING, kind_nothing(how == RECALL))},
  })
  rows(VR, how, {
    {"source synth", SR, E(0, nil, 1, KIND_NOW)},
    {"source buffer 2", BR, E(0, nil, 1, KIND_RING)},
    {"source input", IR, E(0, nil, 1, KIND_RING)},
    {"source voice 2", VR, E(0, nil, 1, KIND_RING)},
    {"freeze 1", VR, E(1, nil, 1, KIND_RING)},
    {"freeze 0", VR, E(0, nil, 1, KIND_RING)},
    {"stop", VS, E(0, nil, 0, false)},
    {"start", VR, E(0, nil, 1, KIND_RING, kind_nothing(how == RECALL))},
  })
end
-- the stopped states: nothing held, nothing sent but a start's scaleNote
for _, how in ipairs({HAND, RECALL}) do
  rows(SS, how, {
    {"source synth", SS, E(0, nil, 0, false)},
    {"source buffer 2", BS, E(0, nil, 0, false)},
    {"source input", IS, E(0, nil, 0, false)},
    {"source voice 2", VS, E(0, nil, 0, false)},
    {"freeze 1", FS, E(1, KIND_NOW, 0, false)},
    {"freeze 0", SS, E(0, nil, 0, false)},
    {"start", SR, E(0, nil, 0, KIND_NOW)},
    {"stop", SS, E(0, nil, 0, false, kind_nothing(how == RECALL))},
  })
end
rows(FS, HAND, {
  {"source synth", FS, E(1, KIND_NOW, 0, false)},
  {"source buffer 2", BS, E(0, nil, 0, false)},
  {"source input", IS, E(0, nil, 0, false)},
  {"source voice 2", VS, E(0, nil, 0, false)},
})
rows(FS, RECALL, {
  {"source synth", FS, E(1, KIND_NOW, 0, false)},
  {"source buffer 2", BS, E(1, nil, 0, false)},
  {"source input", IS, E(1, nil, 0, false)},
  {"source voice 2", VS, E(1, nil, 0, false)},
})
for _, how in ipairs({HAND, RECALL}) do
  rows(FS, how, {
    {"freeze 1", FS, E(1, KIND_NOW, 0, false)},
    {"freeze 0", SS, E(0, nil, 0, false)},
    {"start", FR, E(1, KIND_NOW, 0, KIND_NOW)},
    {"stop", FS, E(1, KIND_NOW, 0, false, kind_nothing(how == RECALL))},
  })
  for _, kind in ipairs({{BS, BR}, {IS, IR}, {VS, VR}}) do
    rows(kind[1], how, {
      {"source synth", SS, E(0, nil, 0, false)},
      {"source buffer 2", BS, E(0, nil, 0, false)},
      {"source input", IS, E(0, nil, 0, false)},
      {"source voice 2", VS, E(0, nil, 0, false)},
      {"freeze 1", kind[1], E(1, nil, 0, false)},
      {"freeze 0", kind[1], E(0, nil, 0, false)},
      {"start", kind[2], E(0, nil, 0, KIND_RING)},
      {"stop", kind[1], E(0, nil, 0, false, kind_nothing(how == RECALL))},
    })
  end
end

h.transition_table({
  name = "voice kind",
  notes = {"docs/notes/lua/freeze.md", "voice kind"},
  states = kind_states,
  events = kind_events,
  state_of = function() return kind_of(local_value("S")) end,
  rows = kind_rows,
  impossible = {},
})


-- #1031: the freeze's own reader of whether a voice's quantized freeze set
-- waits (the grid core's blink and the voices page's FZ key read it)
test("S.lib.freeze.waiting says a voice's freeze set waits (#1031)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function run_to_beat(beat)
    context.clock.run_for((beat - clock.get_beats()) * clock.get_beat_sec())
  end
  assert_true(not S.lib.freeze.waiting(3), "nothing waits at first")
  S.lib.freeze.toggle_quantized(3)
  assert_true(not S.lib.freeze.waiting(3) and S.lib.freeze.is_frozen(3), "quantize off: at once, never waiting")
  S.lib.freeze.toggle(3)
  params:set("quantize_actions", 3)  -- bar
  run_to_beat(1.5)
  S.lib.freeze.toggle_quantized(3)
  assert_true(S.lib.freeze.waiting(3), "under quantize the set waits")
  assert_true(not S.lib.freeze.waiting(2), "another voice's does not")
  for _, bad in ipairs({0, 8, 2.5, "3", false}) do
    assert_equal(S.lib.freeze.waiting(bad), false, "out of range: " .. tostring(bad))
  end
  assert_equal(S.lib.freeze.waiting(nil), false, "nil")
  run_to_beat(4.02)
  assert_true(S.lib.freeze.is_frozen(3), "it landed")
  assert_true(not S.lib.freeze.waiting(3), "and waits no more")
  S.lib.freeze.toggle_quantized(3)
  assert_true(S.lib.freeze.waiting(3), "a press waits again")
  S.lib.freeze.toggle_quantized(3)
  assert_true(not S.lib.freeze.waiting(3), "a second press takes it back")
end)

-- #1031: the freeze's quantizer key (freeze<v>) is built in one place, so
-- its readers ask S.lib.freeze.waiting
test("only lib/freeze.lua builds the freeze's quantizer key", function()
  local listing = assert(io.popen("cd '" .. h.repo_root .. "' && git ls-files 'lib/*.lua' 'lib/**/*.lua' strata.lua"))
  local builders = {}
  for path in listing:lines() do
    local file = assert(io.open(h.repo_root .. "/" .. path))
    local text = file:read("*a"); file:close()
    if text:find('"freeze" ..', 1, true) or text:find("'freeze' ..", 1, true) then builders[#builders + 1] = path end
  end
  listing:close()
  assert_equal(table.concat(builders, ","), "lib/freeze.lua")
end)

end

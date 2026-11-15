-- test/unit/io_actions_test.lua
-- The shared actions (lib/io/actions.lua, S.lib.io_actions): what crow's
-- triggers, OSC's addresses and a Teletype's calls run.
-- Run alone: lua test/run.lua io_actions

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function started()
  local context = load_strata(); finish_startup(context)
  return context, local_value("S"), local_value("S").lib.io_actions
end

-- Run fn with print captured: the lines it printed
local function printed(fn)
  local lines, real = {}, print
  print = function(...) lines[#lines + 1] = table.concat({...}, " ") end
  local ok, failure = pcall(fn)
  print = real
  if not ok then error(failure, 0) end
  return lines
end

local function refused(fn, action)
  local result
  local lines = printed(function() result = fn() end)
  assert_equal(result, false, action .. " returns false")
  assert_equal(#lines, 1, action .. " prints one line")
  assert_true(lines[1]:find("^strata: " .. action .. " ignored: ") ~= nil, "the line names the action: " .. tostring(lines[1]))
end

test("recall_scene goes through the scheduler and ignores an empty or absent scene", function()
  local context, S, actions = started()
  capture_scene(3)
  local scheduled
  local real = S.lib.quantize.schedule
  S.lib.quantize.schedule = function(key, fn, label) scheduled = {key = key, label = label}; return real(key, fn, label) end
  assert_equal(actions.recall_scene(3), true)
  S.lib.quantize.schedule = real
  assert_equal(scheduled.key, "scene", "the quantizer's scene action")
  assert_equal(scheduled.label, "S3")
  assert_equal(S.current_scene, 3, "quantize off: it ran")
  S.lib.quantize.schedule = function() error("nothing is scheduled") end
  for _, n in ipairs({4, 0, 17, 2.5}) do refused(function() return actions.recall_scene(n) end, "recall_scene") end
  S.lib.quantize.schedule = real
end)

test("next_scene steps over empty scenes and wraps", function()
  local context, S, actions = started()
  refused(function() return actions.next_scene() end, "next_scene")
  capture_scene(2); capture_scene(9)
  S.current_scene = 2
  assert_equal(actions.next_scene(), true); assert_equal(S.current_scene, 9)
  assert_equal(actions.next_scene(), true); assert_equal(S.current_scene, 2)
end)

test("run_voice stops, starts and toggles, and 0 is the selected voice", function()
  local context, S, actions = started()
  assert_true(not S.voices[3].active)
  assert_equal(actions.run_voice(3, 1), true); assert_true(S.voices[3].active)
  context.clear_engine_calls()
  assert_equal(actions.run_voice(3, 1), true); assert_true(S.voices[3].active, "left running")
  assert_equal(#context.engine_calls, 0, "no engine call for a voice already as asked")
  assert_equal(actions.run_voice(3, 0), true); assert_true(not S.voices[3].active)
  S.selected_voice = 4
  assert_equal(actions.run_voice(0, 2), true); assert_true(S.voices[4].active, "0 toggles the selected voice")
  refused(function() return actions.run_voice(8, 1) end, "run_voice")
  refused(function() return actions.run_voice(3, 3) end, "run_voice")
  refused(function() return actions.run_voice(2.5, 1) end, "run_voice")
end)

test("retrigger accents a running voice and never starts a stopped one", function()
  local context, S, actions = started()
  assert_true(S.voices[2].active and not S.voices[4].active)
  context.clear_engine_calls()
  assert_equal(actions.retrigger(2, 0.5), true)
  assert_equal(#context.engine_calls, 1, "no other engine call")
  assert_equal(context.calls_named("retrigger")[1].args[1], 1)
  assert_equal(context.calls_named("retrigger")[1].args[2], 0.5)
  context.clear_engine_calls()
  actions.retrigger(2, 1.7)
  assert_equal(context.calls_named("retrigger")[1].args[2], 1, "velocity clamps")
  context.clear_engine_calls()
  local result
  local lines = printed(function() result = actions.retrigger(4, 1) end)
  assert_equal(result, false); assert_equal(#lines, 0, "no line for a stopped voice")
  assert_equal(#context.engine_calls, 0)
  refused(function() return actions.retrigger(9, 1) end, "retrigger")
  context.clear_engine_calls()
  refused(function() return actions.retrigger(2, "loud") end, "retrigger")
  refused(function() return actions.retrigger(2, 0 / 0) end, "retrigger")
  assert_equal(#context.engine_calls, 0, "a bad velocity sends nothing")
end)

test("retrigger on a running gated voice opens the voice's own gate length, not a step's (#639)", function()
  -- sequencer_test's #639 case, through the shared retrigger crow, OSC and Teletype call
  local context, S, actions = started()
  params:set("v1_seq_gate", 2)
  S.patterns[1][1] = 15
  S.lib.sequencer.set_step_attr(1, 1, "gate", 2)
  pattern_clock_start()
  pattern_clock_stop()
  if not S.voices[1].active then toggle_voice(1) end
  local function order()
    local list = {}
    for _, call in ipairs(context.engine_calls) do
      if call.args[1] == 0 and call.name == "retrigger" then list[#list + 1] = "retrigger" end
      if call.args[1] == 0 and call.name == "setGrainParam" and call.args[2] == "gateSeconds" then
        list[#list + 1] = string.format("gateSeconds %.4f", call.args[3])
      end
    end
    return table.concat(list, ", ")
  end
  context.clear_engine_calls()
  assert_equal(actions.retrigger(1, 1), true)
  assert_equal(order(), "gateSeconds 0.0625, retrigger", "the voice's own half step, then the accent")
  context.clear_engine_calls()
  actions.retrigger(1, 1)
  assert_equal(order(), "retrigger", "a second accent sends no gate length: it has not changed")
end)

test("freeze and mute set, clear and toggle their params", function()
  local context, S, actions = started()
  assert_equal(actions.freeze(2, 1), true); assert_equal(params:get("v2_freeze"), 1)
  assert_equal(actions.freeze(2, 2), true); assert_equal(params:get("v2_freeze"), 0)
  assert_equal(actions.mute(5, 2), true); assert_equal(params:get("v5_mute"), 1)
  assert_equal(actions.mute(5, 0), true); assert_equal(params:get("v5_mute"), 0)
  S.selected_voice = 6
  assert_equal(actions.mute(0, 1), true); assert_equal(params:get("v6_mute"), 1, "0 is the selected voice")
  refused(function() return actions.freeze(9, 1) end, "freeze")
  refused(function() return actions.mute(2, 3) end, "mute")
end)

test("macro sets a macro's param and clamps", function()
  local context, S, actions = started()
  assert_equal(actions.macro(4, 0.25), true); assert_equal(params:get("macro_4"), 0.25)
  assert_equal(actions.macro(4, 1.5), true); assert_equal(params:get("macro_4"), 1)
  refused(function() return actions.macro(17, 0.5) end, "macro")
  refused(function() return actions.macro(0, 0.5) end, "macro")
  params:set("macro_4", 0.6)
  refused(function() return actions.macro(4, "high") end, "macro")
  assert_equal(params:get("macro_4"), 0.6, "a bad value leaves the param")
end)

test("patterns stops, plays and toggles", function()
  local context, S, actions = started()
  assert_true(not S.pattern_playing)
  assert_equal(actions.patterns(1), true); assert_true(S.pattern_playing)
  assert_equal(actions.patterns(1), true); assert_true(S.pattern_playing, "stays")
  assert_equal(actions.patterns(2), true); assert_true(not S.pattern_playing)
  assert_equal(actions.patterns(0), true); assert_true(not S.pattern_playing, "stays stopped")
  refused(function() return actions.patterns(3) end, "patterns")
end)

test("record does what BUFFER's key does on the page's slot", function()
  local context, S, actions = started()
  S.buffer_page.slot = 3
  context.clear_engine_calls()
  assert_equal(actions.record(), true)
  assert_equal(#context.calls_named("recordBuffer"), 1)
  assert_equal(context.calls_named("recordBuffer")[1].args[1], 2, "slot 3 is engine slot 2")
  context.clear_engine_calls()
  assert_equal(actions.record(), true)
  assert_equal(#context.calls_named("stopRecord"), 1, "again stops it")
end)

end

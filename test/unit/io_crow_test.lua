-- test/unit/io_crow_test.lua
-- crow (lib/io/crow.lua, S.lib.io_crow): the only way Strata speaks to
-- crow. Every line is pinned in the form crow's documents give it
-- (docs/design/3.6-facts/crow-ii.md §1), written by S.lib.io_crow.number.
-- No device is used: the crow stub (test/stub_crow.lua) records each line.
-- Run alone: lua test/run.lua io_crow

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function started(options)
  local context = load_strata(options); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.io_crow
end

-- The group's params, in its order
local function crow_param_ids()
  local ids = {}
  for n = 1, 2 do
    for _, field in ipairs({"mode", "range", "action", "voice"}) do ids[#ids + 1] = "crow_in" .. n .. "_" .. field end
  end
  for n = 1, 4 do
    for _, field in ipairs({"source", "range", "div"}) do ids[#ids + 1] = "crow_out" .. n .. "_" .. field end
  end
  return ids
end

-- Every value a param takes: an option's indexes, a number's range
local function values_of(id)
  local param = params:lookup_param(id)
  local values = {}
  if param.t == params.tOPTION then
    for index = 1, #param.options do values[#values + 1] = index end
  else
    for value = param.min, param.max do values[#values + 1] = value end
  end
  return values
end

-- The index of an option by its text
local function option(id, text)
  for index, name in ipairs(params:lookup_param(id).options) do
    if name == text then return index end
  end
  error("no option " .. text .. " for " .. id)
end

local function count_lines(context, line)
  local count = 0
  for _, sent in ipairs(context.crow.sent) do
    if sent == line then count = count + 1 end
  end
  return count
end

local function any_line_with(context, text)
  for _, sent in ipairs(context.crow.sent) do
    if sent:find(text, 1, true) then return sent end
  end
  return nil
end

local function step(context) context.clock.run_for(1 / 48) end

local function crow_target(S)
  for _, record in ipairs(S.registry.note_targets) do
    if record.name == "crow" then return record end
  end
end

local function crow_section(S)
  for _, record in ipairs(S.registry.io_sections) do
    if record.name == "crow" then return record end
  end
end

local function section_row(S, label)
  for _, row in ipairs(crow_section(S).rows()) do
    if row.label == label then return row end
  end
end

test("with defaults, and with no crow, nothing is sent", function()
  -- crow-ii.md §1: norns' own add runs crow.reset(); nothing else is Strata's to send
  local context = started()
  context.crow.plug()
  context.clock.run_for(1)
  assert_equal(table.concat(context.crow.sent, "|"), "crow.reset()", "plugged after the start")
  cleanup()
  assert_equal(table.concat(context.crow.sent, "|"), "crow.reset()", "and through cleanup")

  context = started({before_load = function(c) c.crow.plug() end})
  context.clock.run_for(1)
  assert_equal(table.concat(context.crow.sent, "|"), "crow.reset()", "plugged before the start: norns' own reset")
  cleanup()
  assert_equal(table.concat(context.crow.sent, "|"), "crow.reset()", "and through cleanup")

  context = started()
  for _, id in ipairs(crow_param_ids()) do
    local values = values_of(id)
    params:set(id, values[#values])
  end
  context.clock.run_for(1)
  cleanup()
  assert_equal(#context.crow.sent, 0, "unplugged with every param set: nothing")
end)

test("no function is ever assigned through the proxy", function()
  -- crow-ii.md §1: each function assignment takes one of 45 event keys for the session
  local context = started()
  local function every_value()
    for _, id in ipairs(crow_param_ids()) do
      for _, value in ipairs(values_of(id)) do
        params:set(id, value)
        step(context)
      end
    end
  end
  context.crow.plug()
  every_value()
  context.crow.unplug()
  every_value()
  context.crow.plug()
  context.clock.run_for(1)
  assert_equal(context.crow.function_assignments, 0)
end)

test("an input's mode sends its handler and its documented mode call", function()
  -- crow-ii.md §1 Inputs: mode('stream', time), mode('change', threshold, hysteresis, direction), 'none'
  local context = started()
  context.crow.plug(); context.crow.clear()
  params:set("crow_in1_mode", option("crow_in1_mode", "cv"))
  local sent = context.crow.sent
  assert_equal(#sent, 2)
  -- crow calls a stream handler with a number (crow lib/lualink.c L_handle_stream: lua_pushnumber, then
  -- lua/input.lua:149 stream_handler), which tell writes as text (lib/lualink.c:158-175)
  assert_equal(sent[1], "input[1].stream = function(v) tell('strata_in', 1, v) end")
  assert_equal(sent[2], "input[1].mode('stream', 0.02)")
  context.crow.clear()
  params:set("crow_in2_mode", option("crow_in2_mode", "trigger"))
  assert_equal(#sent, 2)
  -- crow calls a change handler with a boolean (crow lua/input.lua:150, change(val ~= 0)), and tell
  -- raises on one (luaL_checkstring, lib/lualink.c:158-175): the handler sends 1 or 0, as crow's own
  -- default does (lua/input.lua:30, state and 1 or 0)
  assert_equal(sent[1], "input[2].change = function(s) tell('strata_change', 2, s and 1 or 0) end")
  assert_equal(sent[2], "input[2].mode('change', 1, 0.1, 'rising')")
  context.crow.clear()
  params:set("crow_in2_mode", option("crow_in2_mode", "off"))
  assert_equal(table.concat(sent, "|"), "input[2].mode('none')")
end)

test("a cv input is a modulation source over its range", function()
  -- crow-ii.md §1 Inputs: the stream callback gets the input's volts
  local context, S = started()
  context.crow.plug()
  assert_equal(#S.lib.mod_sources.list("crow"), 0, "an input that is off shows no source")
  params:set("crow_in1_mode", option("crow_in1_mode", "cv"))
  context.crow.fire("strata_in", 1, 2.5)
  assert_near(S.lib.mod_sources.fraction("crow1"), 0.75, 1e-9, "-5..5")
  params:set("crow_in1_range", option("crow_in1_range", "0..10"))
  assert_near(S.lib.mod_sources.fraction("crow1"), 0.25, 1e-9, "0..10")
  local record = S.lib.mod_sources.get("crow1")
  assert_equal(record.name, "CR1")
  assert_equal(record.section, "crow")
  local listed = S.lib.mod_sources.list("crow")
  assert_equal(#listed, 1, "MOD lists the cv input")
  assert_equal(listed[1].key, "crow1")
  local sections = table.concat(S.lib.mod_sources.sections(), " ")
  assert_true((" " .. sections .. " "):find(" crow ", 1, true) ~= nil, "MOD's sections: " .. sections)
  assert_equal(S.lib.mod_sources.fraction("crow2"), 0.5, "input 2 has had no value: no modulation")
end)

test("a trigger's rise runs its action", function()
  -- crow-ii.md §1 Inputs: change's state is 1 rising, 0 falling
  local context, S = started()
  context.crow.plug()
  params:set("crow_in1_mode", option("crow_in1_mode", "trigger"))
  params:set("crow_in1_voice", 2)
  assert_true(S.voices[2].active, "voice 2 runs")
  context.clear_engine_calls()
  context.crow.fire("strata_change", 1, 1)
  local calls = context.calls_named("retrigger")
  assert_equal(#calls, 1, "one accent")
  assert_equal(calls[1].args[1], 1); assert_equal(calls[1].args[2], 1)
  context.crow.fire("strata_change", 1, 0)
  assert_equal(#context.calls_named("retrigger"), 1, "a fall does nothing")

  capture_scene(1); capture_scene(3)
  S.current_scene = 1
  params:set("crow_in1_action", option("crow_in1_action", "next scene"))
  context.crow.fire("strata_change", 1, 1)
  assert_equal(S.current_scene, 3, "the next saved scene (quantize off: at once)")

  params:set("crow_in1_action", option("crow_in1_action", "freeze"))
  local frozen = params:get("v2_freeze")
  context.crow.fire("strata_change", 1, 1)
  assert_equal(params:get("v2_freeze"), 1 - frozen, "v2_freeze toggled")

  params:set("crow_in1_action", option("crow_in1_action", "record"))
  local recorded = 0
  local real_record = S.lib.io_actions.record
  S.lib.io_actions.record = function() recorded = recorded + 1; return true end
  context.crow.fire("strata_change", 1, 1)
  S.lib.io_actions.record = real_record
  assert_equal(recorded, 1, "record runs BUFFER's record")

  params:set("crow_in1_action", option("crow_in1_action", "patterns"))
  local playing = S.pattern_playing and true or false
  context.crow.fire("strata_change", 1, 1)
  assert_equal(S.pattern_playing and true or false, not playing, "the patterns toggled")
  context.crow.fire("strata_change", 1, 0)
  assert_equal(S.pattern_playing and true or false, not playing, "a fall does nothing")
end)

test("a followed source reaches its output in volts, only when it moved", function()
  -- crow-ii.md §1 Outputs: output[n].volts and output[n].slew
  local context, S = started()
  local lfo_value = 0
  S.lib.lfos.value = function(n) return n == 1 and lfo_value or 0 end
  context.crow.plug()
  params:set("crow_out2_range", option("crow_out2_range", "0..10"))
  context.crow.clear()
  params:set("crow_out2_source", option("crow_out2_source", "lfo1"))
  assert_equal(table.concat(context.crow.sent, "|"), "output[2].slew = 0.02", "setup's line")
  context.crow.clear()
  step(context)
  assert_equal(table.concat(context.crow.sent, "|"), "output[2].volts = 5", "fraction 0.5 of 0..10")
  context.crow.clear()
  lfo_value = 0.009  -- 5.045 V: moved by less than 1/200 of the range
  step(context)
  assert_equal(#context.crow.sent, 0, "moved by less than 0.05 V: nothing")
  params:set("crow_out2_range", option("crow_out2_range", "-5..5"))
  lfo_value = 0.5
  context.crow.clear()
  step(context)
  assert_equal(table.concat(context.crow.sent, "|"), "output[2].volts = 2.5", "fraction 0.75 of -5..5")
end)

test("followed values wait for the window and notes never do", function()
  local context, S, crow_io = started()
  context.crow.plug()
  context.clock.run_for(0.2)  -- a window after the plug's reset
  context.crow.clear()
  for index = 1, 30 do crow_io.send_now("line " .. index) end
  for key = 1, 5 do crow_io.send_value("k" .. key, "k" .. key .. " a") end
  assert_equal(#context.crow.sent, 32, "two of the five went")
  assert_equal(crow_io.budget_state().sent, 32)
  assert_equal(crow_io.budget_state().pending, 3, "three wait")
  crow_io.send_value("k4", "k4 b")
  assert_equal(crow_io.budget_state().pending, 3, "a waiting key's line is replaced")
  assert_equal(crow_io.send_now("now"), true)
  assert_equal(context.crow.sent[#context.crow.sent], "now", "send_now still sends at once")
  assert_true(crow_io.clocks().flush ~= nil, "the flush clock runs")
  context.clock.run_for(crow_io.CROW.window_seconds * 1.5)
  local sent = context.crow.sent
  assert_equal(table.concat({sent[34], sent[35], sent[36]}, "|"), "k3 a|k4 b|k5 a", "newest lines, first-waited order")
  assert_equal(#sent, 36)
  assert_equal(crow_io.budget_state().pending, 0)
  assert_equal(crow_io.clocks().flush, nil, "the flush clock has ended")
  context.crow.unplug()
  assert_equal(crow_io.send_now("gone"), false, "without a crow nothing goes")
end)

test("a voice's pitch and gate outputs follow its target notes", function()
  -- crow-ii.md §1 Outputs: output[n].volts, output[n].slew
  local context, S = started()
  context.crow.plug()
  params:set("crow_out1_range", option("crow_out1_range", "-5..5"))
  context.crow.clear()
  params:set("crow_out1_source", option("crow_out1_source", "v3 pitch"))
  assert_equal(table.concat(context.crow.sent, "|"), "output[1].slew = 0", "pitch has no slew")
  params:set("crow_out2_source", option("crow_out2_source", "v3 gate"))
  local target = crow_target(S)
  assert_true(target.routed(3), "voice 3 routed")
  assert_true(not target.routed(2), "voice 2 not")
  assert_equal(#target.rows(3), 0, "no rows of its own")
  context.crow.clear()
  target.note_on(3, "m1", 72, 0.5, {source = "midi"})
  assert_equal(table.concat(context.crow.sent, "|"), "output[1].volts = 1|output[2].volts = 5")
  context.crow.clear()
  target.note_on(3, "m2", 84, 0.5, {source = "midi"})
  assert_equal(table.concat(context.crow.sent, "|"), "output[1].volts = 2", "the newest, and no gate line")
  context.crow.clear()
  target.note_off(3, "m2")
  assert_equal(table.concat(context.crow.sent, "|"), "output[1].volts = 1", "back to the newest left")
  context.crow.clear()
  target.note_off(3, "m1")
  assert_equal(table.concat(context.crow.sent, "|"), "output[2].volts = 0", "the last ends: gate low")
  context.crow.clear()
  target.note_on(3, "m3", 140, 1, {source = "midi"})
  assert_equal(context.crow.sent[1], "output[1].volts = 5", "the range's end")
  -- a route param's action tells the targets core (lib/io/targets.lua, a double here) of each voice it moved
  local told = {}
  S.lib.io_targets = {route_changed = function(voice) told[#told + 1] = voice end}
  params:set("crow_out1_source", option("crow_out1_source", "v5 pitch"))
  S.lib.io_targets = nil
  assert_equal(table.concat(told, " "), "3 5", "the voice it left and the voice it joined")
end)

test("a clock output pulses once per division with one line a pulse", function()
  -- crow-ii.md §1 How norns' clock relates to crow: action = pulse, then output[n]() per pulse
  local context, S, crow_io = started()
  context.crow.plug()
  params:set("crow_out4_div", option("crow_out4_div", "1/4"))
  context.crow.clear()
  params:set("crow_out4_source", option("crow_out4_source", "clock"))
  assert_equal(table.concat(context.crow.sent, "|"), "output[4].action = pulse(0.01, 5)")
  local beat = clock.get_beat_sec()
  context.clock.run_for(beat * 0.1)  -- off the division's grid
  context.crow.clear()
  context.clock.run_for(beat)
  assert_equal(count_lines(context, "output[4]()"), 4, "four pulses a beat")
  assert_equal(#context.crow.sent, 4, "one line a pulse")
  local id = crow_io.clocks().outputs[4]
  assert_true(id ~= nil and clock.threads[id] ~= nil, "its clock runs")
  params:set("crow_out4_source", option("crow_out4_source", "off"))
  context.crow.clear()
  context.clock.run_for(beat * 2)
  assert_equal(count_lines(context, "output[4]()"), 0, "no more")
  assert_equal(crow_io.clocks().outputs[4], nil)
  assert_equal(clock.threads[id], nil, "its clock is gone")
end)

test("norns' own crow clock keeps its jacks", function()
  -- crow-ii.md §1 How norns' clock relates to crow: input 1 is norns' under clock source crow,
  -- and "crow out" drives its output
  local context, S = started()
  context.crow.plug()
  params:set("clock_source", 4)  -- crow
  context.crow.clear()
  for _, mode in ipairs({2, 3, 1, 2}) do params:set("crow_in1_mode", mode) end
  context.clock.run_for(0.5)
  assert_equal(any_line_with(context, "input[1]"), nil, "no line names input 1")
  local found = false
  for _, row in ipairs(crow_section(S).rows()) do
    if row.kind == "status" and row.text == "in 1  clock (norns)" then found = true end
  end
  assert_true(found, "the section shows in 1  clock (norns)")
  params:set("clock_crow_out", 3)  -- output 2
  context.crow.clear()
  for _, value in ipairs(values_of("crow_out2_source")) do
    params:set("crow_out2_source", value)
    step(context)
  end
  context.clock.run_for(1)
  assert_equal(any_line_with(context, "output[2]"), nil, "no line names output 2")
end)

test("a reconnect sends exactly the current settings' lines", function()
  -- crow-ii.md §1: the default add runs crow.reset(); a script that replaces add does it itself
  local context, S, crow_io = started()
  context.crow.plug()
  params:set("crow_in1_mode", option("crow_in1_mode", "cv"))
  params:set("crow_out2_source", option("crow_out2_source", "lfo1"))
  params:set("crow_out4_source", option("crow_out4_source", "clock"))
  context.crow.unplug()
  assert_equal(crow_io.clocks().outputs[4], nil, "no clock while crow is gone")
  context.crow.clear()
  context.crow.plug()
  local sent = context.crow.sent
  assert_equal(sent[1], "crow.reset()", "the reset first")
  local first = table.concat(sent, "|")
  assert_equal(#sent, 5, "reset, input 1's two lines, output 2's slew, output 4's action: " .. first)
  for _, line in ipairs({"input[1].mode('stream', 0.02)", "output[2].slew = 0.02", "output[4].action = pulse(0.01, 5)"}) do
    assert_equal(count_lines(context, line), 1, line .. " once")
  end
  local clock_id = crow_io.clocks().outputs[4]
  assert_true(clock_id ~= nil, "output 4's clock runs")
  context.crow.clear()
  norns.crow.add(1, "crow", "crow stub device")
  assert_equal(table.concat(sent, "|"), first, "a second add: the same lines")
  assert_equal(clock.threads[clock_id], nil, "the old clock is gone")
  assert_true(crow_io.clocks().outputs[4] ~= nil, "one clock for output 4")
  assert_equal(context.crow.function_assignments, 0)
end)

test("cleanup leaves the outputs at 0 V and the inputs off", function()
  -- crow-ii.md §1 Inputs and Outputs: output[n].volts = 0, input[n].mode('none')
  local context, S, crow_io = started()
  context.crow.plug()
  params:set("crow_in2_mode", option("crow_in2_mode", "cv"))
  params:set("crow_out4_source", option("crow_out4_source", "clock"))
  local clock_id = crow_io.clocks().outputs[4]
  cleanup()
  local sent = context.crow.sent
  local last = {}
  for index = #sent - 5, #sent do last[#last + 1] = sent[index] end
  assert_equal(table.concat(last, "|"), "output[1].volts = 0|output[2].volts = 0|output[3].volts = 0|"
    .. "output[4].volts = 0|input[1].mode('none')|input[2].mode('none')")
  assert_equal(clock.threads[clock_id], nil, "output 4's clock ended")
  assert_equal(crow_io.clocks().flush, nil)
  assert_equal(next(crow_io.clocks().outputs), nil, "no clock of the module runs")
  context.crow.unplug()
  context.crow.clear()
  context.crow.plug()
  assert_equal(#sent, 0, "a crow plugged in after cleanup gets no line")
end)

test("an output's source is kept by key when the source list grows", function()
  local context, S = started()
  params:set("crow_out1_source", option("crow_out1_source", "lfo2"))
  local before = params:get("crow_out1_source")
  local path = h.data_root .. "crow_source_by_key.pset"
  params:write(path)
  context = started({before_init = function()
    local script = local_value("S")
    script.register_mod_source({key = "a later source", name = "LATE", section = "later", range = {0, 1},
      value = function() return 0 end})
    local list = script.registry.mod_sources
    table.insert(list, 1, table.remove(list))  -- registered ahead of lfo2
  end})
  S = local_value("S")
  assert_equal(option("crow_out1_source", "lfo2"), before + 1, "lfo2's option moved")
  params:read(path)
  assert_equal(S.lib.io_keyed.key("crow_out1_source"), "lfo2", "still lfo2")
  assert_equal(params:string("crow_out1_source"), "lfo2", "and shown")
end)

test("a source key the list lacks reads as off on its jack, is kept, and sends nothing", function()
  local context, S = started()
  context.crow.plug(); context.crow.clear()
  params:set("crow_out3_source_key", "a later source")
  context.clock.run_for(0.5)
  assert_equal(#context.crow.sent, 0, "no line for a jack whose key resolves to off")
  assert_equal(S.lib.io_keyed.key("crow_out3_source"), "off")
  assert_equal(params:get("crow_out3_source_key"), "a later source", "the key kept")
  assert_equal(params:string("crow_out3_source"), "off")
end)

test("after cleanup nothing is sent, whoever asks", function()
  local context, S, crow_io = started()
  context.crow.plug()
  params:set("crow_out2_source", option("crow_out2_source", "v3 gate"))
  local target = crow_target(S)
  target.note_on(3, "m1", 60, 1, {source = "midi"})
  cleanup()
  context.crow.clear()
  assert_equal(crow_io.send_now("late"), false, "send_now")
  assert_equal(crow_io.send_value("late", "late"), false, "send_value")
  target.note_off(3, "m1")
  target.note_on(3, "m2", 60, 1, {source = "midi"})
  target.stop_all()
  assert_equal(#context.crow.sent, 0, "no line after cleanup")
end)

test("norns' clock moving on and off crow's jacks sends nothing for a jack left off", function()
  local context = started()
  context.crow.plug(); context.crow.clear()
  for _, setting in ipairs({{"clock_source", 4}, {"clock_source", 1}, {"clock_crow_out", 3}, {"clock_crow_out", 1}}) do
    params:set(setting[1], setting[2])
    context.clock.run_for(0.2)
  end
  assert_equal(#context.crow.sent, 0, "with defaults: no line")
  -- a jack Strata set up gets its lines again when norns gives it back
  params:set("crow_in1_mode", option("crow_in1_mode", "cv"))
  params:set("clock_source", 4)
  context.clock.run_for(0.2)
  context.crow.clear()
  params:set("clock_source", 1)
  context.clock.run_for(0.2)
  assert_equal(#context.crow.sent, 2, "input 1's two lines, nothing else")
  assert_equal(context.crow.sent[2], "input[1].mode('stream', 0.02)", "input 1's lines again")
end)

test("an output norns' clock owns routes no voice", function()
  local context, S = started()
  params:set("crow_out2_source", option("crow_out2_source", "v3 gate"))
  assert_true(crow_target(S).routed(3))
  params:set("clock_crow_out", 3)  -- output 2
  assert_true(not crow_target(S).routed(3), "norns' clock owns output 2")
end)

test("a cv input's action and voice send nothing; its mode and range send its lines", function()
  local context = started()
  context.crow.plug()
  params:set("crow_in1_mode", option("crow_in1_mode", "cv"))
  context.crow.clear()
  params:set("crow_in1_action", option("crow_in1_action", "freeze"))
  params:set("crow_in1_voice", 4)
  assert_equal(#context.crow.sent, 0, "action and voice")
  params:set("crow_in1_range", option("crow_in1_range", "0..5"))
  assert_equal(#context.crow.sent, 2, "the range")
end)

test("number writes at most four decimals and no trailing zeros", function()
  local _, _, crow_io = started()
  local number = crow_io.number
  assert_equal(number(3.25), "3.25")
  assert_equal(number(5), "5")
  assert_equal(number(0.02), "0.02")
  assert_equal(number(-1.5), "-1.5")
  assert_equal(number(1 / 3), "0.3333")
  assert_equal(number(-0.00001), "0")
  assert_equal(number(-0), "0")
  assert_equal(number(10), "10")
end)

test("the crow section shows presence, the jacks and an approximate mark", function()
  local context, S = started()
  local section = crow_section(S)
  assert_equal(section.status(), "[--]", "no crow")
  context.crow.plug()
  assert_equal(section.status(), nil, "with one")
  assert_equal(section_row(S, "in 1").kind, "detail")
  assert_equal(#section_row(S, "in 1").fields, 4, "mode, range, action, voice")
  assert_equal(#section_row(S, "out 4").fields, 3, "source, range, div")
  local fast, slow
  for index, destination in ipairs(S.LFO_DESTINATIONS) do
    if destination.fast and not fast then fast = index end
    if not destination.fast and not slow then slow = index end
  end
  params:set("strata_lfo1_dest", fast)
  params:set("strata_lfo2_dest", slow)
  assert_true(S.lib.lfos.is_engine_run(1), "LFO 1 runs in the engine")
  params:set("crow_out1_source", option("crow_out1_source", "lfo1"))
  params:set("crow_out2_source", option("crow_out2_source", "lfo2"))
  local text = section_row(S, "out 1").text()
  assert_equal(text:sub(-1), "~", "an engine-run LFO's output: " .. text)
  text = section_row(S, "out 2").text()
  assert_true(text:sub(-1) ~= "~", "a Lua-run LFO's: " .. text)
  assert_true(S.lib.pages_io.show_section("crow"), "the page shows the section")
end)

end

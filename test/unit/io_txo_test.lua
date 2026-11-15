-- test/unit/io_txo_test.lua
-- The TELEXo as a note target over the ii bus (lib/io/txo.lua,
-- S.lib.io_txo): one note at a time, the newest, in two modes: pitch (cv
-- and a trigger) and envelope (the level, the envelope's gate and a
-- trigger, the envelope's attack and decay set at setup). Commands are
-- the TELEX README's (docs/design/3.6-facts/crow-ii.md section 2,
-- TELEXo). S.lib.io_ii is a double here (the ii bus module is another
-- package's): leads, send, send_off, send_direct and add_params.
-- Run alone: lua test/run.lua io_txo

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local ENVELOPE = 2  -- the option index of "envelope" in v<i>_out_txo_cv

-- The double: send and send_off record only while leading (as the real
-- bus drops them otherwise), send_direct always
local function install_ii(state)
  local S = local_value("S")
  local function recorder(kind, only_leading)
    return function(...)
      if only_leading and not state.leading then return end
      state.calls[#state.calls + 1] = {kind, ...}
    end
  end
  S.lib.io_ii = {
    leads = function() return state.leading end,
    send = recorder("send", true), send_off = recorder("send_off", true), send_direct = recorder("send_direct"),
    add_params = function()
      local total = 0
      for _, device in ipairs(S.registry.ii_devices) do total = total + device.param_count end
      params:add_group("strata_out_ii", "out ii", total)
      for _, device in ipairs(S.registry.ii_devices) do
        if device.add_params then device.add_params() end
      end
    end,
  }
end

local function started(without_double)
  local state = {calls = {}, leading = true}
  local context = load_strata(without_double and {} or {before_init = function() install_ii(state) end})
  finish_startup(context)
  return context, local_value("S"), state
end

local function assert_calls(state, expected, what)
  local got = state.calls
  local function show(list)
    local lines = {}
    for _, call in ipairs(list) do
      local parts = {}
      for index, part in ipairs(call) do parts[index] = tostring(part) end
      lines[#lines + 1] = table.concat(parts, " ")
    end
    return table.concat(lines, "; ")
  end
  local same = #got == #expected
  for index = 1, same and #expected or 0 do
    for field = 1, math.max(#got[index], #expected[index]) do
      if got[index][field] ~= expected[index][field] then same = false end
    end
  end
  assert_true(same, (what or "calls") .. ": expected [" .. show(expected) .. "] got [" .. show(got) .. "]")
  state.calls = {}
end

local function target_of(S)
  for _, record in ipairs(S.registry.note_targets) do
    if record.name == "txo" then return record end
  end
end

local function device_of(S)
  for _, record in ipairs(S.registry.ii_devices) do
    if record.name == "txo" then return record end
  end
end

local function played(key, pitch)
  return {owner = "midi", key = key, pitch = pitch, velocity = 0.5, park = true, set_own = function() end}
end

local function setup_calls(output, attack, decay)
  return {{"send", "txo", "env_act", output, 1}, {"send", "txo", "env_att", output, attack},
    {"send", "txo", "env_dec", output, decay}}
end

local function row_named(S, label)
  for _, entry in ipairs(S.lib.pages_io.rows()) do
    if entry.label == label then return entry end
  end
end

test("with defaults nothing is sent", function()
  local _, S, state = started()
  local target = target_of(S)
  assert_true(target ~= nil, "the target is registered")
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_out_txo"), 0, "voice " .. voice .. " is off")
    assert_equal(params:string("v" .. voice .. "_out_txo_cv"), "pitch", "in pitch mode")
    assert_equal(target.routed(voice), false, "not routed")
  end
  S.lib.notes.play(1, played(7740, 64))
  S.lib.notes.release(1, "midi", 7740)
  assert_calls(state, {}, "a note on an unrouted voice")
  assert_equal(params:get("txo_attack"), 10); assert_equal(params:get("txo_decay"), 500)
end)

test("its params: sixteen, in the ii group, with the brief's ranges", function()
  local _, S = started()
  local device = device_of(S)
  assert_equal(device.param_count, 16)
  assert_true(device.ready ~= nil and device.release ~= nil, "ready and release")
  local out = params:lookup_param("v7_out_txo")
  assert_equal(out.min, 0); assert_equal(out.max, 32)
  assert_equal(params:lookup_param("v7_out_txo_cv").options[1], "pitch")
  assert_equal(params:lookup_param("v7_out_txo_cv").options[ENVELOPE], "envelope")
  assert_equal(params:lookup_param("txo_attack").min, 1); assert_equal(params:lookup_param("txo_attack").max, 10000)
  assert_equal(params:lookup_param("txo_decay").min, 1); assert_equal(params:lookup_param("txo_decay").max, 10000)
end)

test("pitch mode sends cv and a trigger; its end lowers the trigger", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_txo", 5)
  assert_equal(target.routed(1), true)
  state.calls = {}
  target.note_on(1, "s1", 48, 1)
  assert_calls(state, {{"send", "txo", "cv", 5, -1}, {"send", "txo", "tr", 5, 1}}, "the note")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "txo", "tr", 5, 0}}, "its end")
  target.note_on(1, "s1", 300, 1)
  assert_equal(state.calls[1][5], 10, "clamped to 10 V")
  state.calls = {}
  target.note_on(1, "s2", -300, 1)
  assert_equal(state.calls[1][5], -10, "clamped to -10 V")
end)

test("the newest note wins: its end gives the pitch to the newest left, the last end the trigger", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_txo", 5)
  target.note_on(1, "s1", 72, 1); target.note_on(1, "s2", 84, 1); state.calls = {}
  target.note_off(1, "s2")
  assert_calls(state, {{"send", "txo", "cv", 5, 1}}, "the pitch goes back, no trigger")
  target.note_off(1, "s2")
  assert_calls(state, {}, "an off twice")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "txo", "tr", 5, 0}}, "the last")
  target.note_off(1, "s1")
  assert_calls(state, {}, "never negative")
  target.note_on(1, "s1", 60, 1); target.note_on(1, "s1", 62, 1); state.calls = {}
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "txo", "tr", 5, 0}}, "an id played again replaced itself")
end)

test("envelope mode sends the level, the envelope's gate and a trigger; its end lowers both", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_txo", 5); params:set("v1_out_txo_cv", ENVELOPE)
  state.calls = {}
  target.note_on(1, "s1", 60, 0.5)
  assert_calls(state, {{"send", "txo", "cv", 5, 2.5}, {"send", "txo", "env", 5, 1}, {"send", "txo", "tr", 5, 1}}, "the note")
  target.note_on(1, "s2", 60, 1)
  assert_calls(state, {{"send", "txo", "cv", 5, 5}, {"send", "txo", "env", 5, 1}, {"send", "txo", "tr", 5, 1}}, "the next")
  target.note_off(1, "s2")
  assert_calls(state, {{"send", "txo", "cv", 5, 2.5}}, "the level of the newest left")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "txo", "tr", 5, 0}, {"send_off", "txo", "env", 5, 0}}, "its end")
end)

test("ready and a changed setting set the envelope up; release and a left output take it down", function()
  local _, S, state = started()
  local device = device_of(S)
  params:set("v1_out_txo", 5); params:set("v1_out_txo_cv", ENVELOPE)
  state.calls = {}
  device.ready()
  assert_calls(state, setup_calls(5, 10, 500), "ready")
  params:set("txo_decay", 800)
  assert_calls(state, setup_calls(5, 10, 800), "a new decay")
  params:set("txo_attack", 20)
  assert_calls(state, setup_calls(5, 20, 800), "a new attack")
  params:set("v1_out_txo", 6)
  local expected = {{"send", "txo", "env_act", 5, 0}}
  for _, call in ipairs(setup_calls(6, 20, 800)) do expected[#expected + 1] = call end
  assert_calls(state, expected, "a new output: the old one's envelope off, the new one set up")
  params:set("v1_out_txo_cv", 1)
  assert_calls(state, {{"send", "txo", "env_act", 6, 0}}, "back to pitch: the envelope off")
  params:set("v1_out_txo_cv", ENVELOPE)
  assert_calls(state, setup_calls(6, 20, 800), "and to envelope again")
  device.release()
  assert_calls(state, {{"send_direct", "txo", "env_act", 6, 0}}, "release")
end)

test("a pitch voice sends none of the envelope's setup", function()
  local _, S, state = started()
  params:set("v1_out_txo", 5)
  state.calls = {}
  device_of(S).ready()
  params:set("txo_decay", 800); params:set("v1_out_txo", 6)
  assert_calls(state, {}, "ready, a decay and an output in pitch mode")
  device_of(S).release()
  assert_calls(state, {}, "release")
end)

test("a setting changed while the bus is not led sends nothing, and ready sets everything up", function()
  local _, S, state = started()
  state.leading = false
  params:set("v2_out_txo", 9); params:set("v2_out_txo_cv", ENVELOPE); params:set("txo_attack", 30)
  assert_calls(state, {}, "not leading")
  state.leading = true
  device_of(S).ready()
  assert_calls(state, setup_calls(9, 30, 500), "ready")
end)

test("a route change, a voice stop and the bus leaving leave every trigger low", function()
  local _, S, state = started()
  local function low()
    local outputs = {}
    for _, call in ipairs(state.calls) do
      if call[1] == "send_off" and call[3] == "tr" then outputs[#outputs + 1] = call[4] end
    end
    return table.concat(outputs, ",")
  end
  params:set("v1_out_txo", 5); params:set("v2_out_txo", 6); params:set("v2_out_txo_cv", ENVELOPE)
  S.lib.notes.play(1, played(7740, 64)); S.lib.notes.play(2, played(7741, 64))
  state.calls = {}
  params:set("v1_out_txo", 7)
  assert_equal(low(), "5", "a route change: the output it was raised on")
  state.calls = {}
  toggle_voice(2)
  assert_equal(low(), "6", "a voice stop")
  S.lib.notes.play(1, played(7742, 64)); S.lib.notes.play(2, played(7743, 64))
  state.calls = {}
  S.lib.io_targets.end_target("txo")
  assert_equal(low(), "7,6", "the bus leaving ends every note of the target")
  S.lib.notes.play(1, played(7744, 64))
  state.calls = {}
  S.lib.io_targets.stop_all()
  assert_equal(low(), "7", "cleanup")
  state.calls = {}
  target_of(S).stop_all()
  assert_calls(state, {}, "a second stop_all")
end)

test("without the ii module the device does nothing and the page draws", function()
  local _, S = started(true)
  assert_true(S.lib.io_ii == nil, "no ii module in this test")
  local target = target_of(S)
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(target.routed(voice), false, "not routed")
    assert_equal(#target.rows(voice), 0, "no rows")
  end
  S.lib.pages_io.show_section("voice")
  h.show_page("IO")
  S.lib.notes.play(1, played(7740, 64))
  S.lib.notes.release(1, "midi", 7740)
  target.note_on(1, "s1", 60, 1); target.note_off(1, "s1"); target.stop_all()
  local device = device_of(S)
  device.ready(); device.release()
end)

test("IO's voice section: a detail row for the output and mode, and a row each for the times", function()
  local _, S = started()
  S.selected_voice = 3
  local detail = row_named(S, "txo")
  assert_equal(detail.kind, "detail")
  assert_equal(detail.shown, "off")
  assert_equal(detail.fields[1].param_id, "v3_out_txo")
  assert_equal(detail.fields[2].param_id, "v3_out_txo_cv")
  params:set("v3_out_txo", 3)
  assert_equal(row_named(S, "txo").shown, "out 3  pitch")
  params:set("v3_out_txo_cv", ENVELOPE)
  assert_equal(row_named(S, "txo").shown, "out 3  envelope")
  assert_equal(row_named(S, "txo attack").param_id, "txo_attack")
  assert_equal(row_named(S, "txo decay").param_id, "txo_decay")
  assert_equal(row_named(S, "txo attack").shown, "10 ms")
  assert_equal(row_named(S, "txo decay").shown, "500 ms")
end)

end

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
      state.attempts = (state.attempts or 0) + 1
      if state.fail_next then state.fail_next = nil; error("send failed", 0) end
      if state.fail_at and state.fail_at[state.attempts] then error("send failed #" .. state.attempts, 0) end
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
  -- without the double the real ii module is taken away before init, so
  -- the ii group adds nothing and the device's params never exist (ruling 6)
  local context = load_strata({before_init = function()
    if without_double then local_value("S").lib.io_ii = nil else install_ii(state) end
  end})
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

-- Ruling 10: an output is one line that plays one note at a time, whatever voices feed it
test("two voices on one output in pitch mode: the newest sounds, the trigger is the line's", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_txo", 5); params:set("v2_out_txo", 5)
  state.calls = {}
  target.note_on(1, "s1", 72, 1); target.note_on(2, "s1", 84, 1)
  assert_calls(state, {{"send", "txo", "cv", 5, 1}, {"send", "txo", "tr", 5, 1},
    {"send", "txo", "cv", 5, 2}, {"send", "txo", "tr", 5, 1}}, "both notes")
  target.note_off(2, "s1")
  assert_calls(state, {{"send", "txo", "cv", 5, 1}}, "the pitch falls back to the first voice's note, no trigger")
  target.note_on(2, "s2", 84, 1); state.calls = {}
  target.note_off(1, "s1")
  assert_calls(state, {}, "the older note (voice 1's) ends while voice 2's newer one sounds: the trigger stays high")
  target.note_off(2, "s2")
  assert_calls(state, {{"send_off", "txo", "tr", 5, 0}}, "low once, at the line's last note")
end)

test("two envelope voices on one output: its envelope goes off only when the last leaves", function()
  local _, S, state = started()
  local device = device_of(S)
  params:set("v1_out_txo", 5); params:set("v1_out_txo_cv", ENVELOPE)
  state.calls = {}
  params:set("v2_out_txo", 5); params:set("v2_out_txo_cv", ENVELOPE)
  state.calls = {}
  device.ready()
  assert_calls(state, setup_calls(5, 10, 500), "ready: the shared output once")
  params:set("v1_out_txo_cv", 1)
  assert_calls(state, {}, "one voice leaves envelope mode: the other still needs it")
  params:set("v2_out_txo_cv", 1)
  assert_calls(state, {{"send", "txo", "env_act", 5, 0}}, "the last leaves: off, exactly once")
  params:set("v1_out_txo_cv", ENVELOPE)
  assert_calls(state, setup_calls(5, 10, 500), "set up again")
  params:set("v1_out_txo", 6)
  local expected = {{"send", "txo", "env_act", 5, 0}}
  for _, call in ipairs(setup_calls(6, 10, 500)) do expected[#expected + 1] = call end
  assert_calls(state, expected, "the output left by the only envelope voice")
end)

test("a pitch voice and an envelope voice on one output: each note's cv is its own mode's", function()
  local _, S, state = started()
  local target, device = target_of(S), device_of(S)
  params:set("v1_out_txo", 5)
  params:set("v2_out_txo", 5); params:set("v2_out_txo_cv", ENVELOPE)
  state.calls = {}
  device.ready()
  assert_calls(state, setup_calls(5, 10, 500), "the envelope is active for the envelope voice")
  target.note_on(2, "s1", 60, 0.5)
  assert_calls(state, {{"send", "txo", "cv", 5, 2.5}, {"send", "txo", "env", 5, 1}, {"send", "txo", "tr", 5, 1}})
  target.note_on(1, "s1", 72, 1)
  assert_calls(state, {{"send", "txo", "cv", 5, 1}, {"send", "txo", "tr", 5, 1}}, "the pitch note: its pitch, no env")
  target.note_off(1, "s1")
  assert_calls(state, {{"send", "txo", "cv", 5, 2.5}}, "back to the envelope note's level")
  target.note_off(2, "s1")
  assert_calls(state, {{"send_off", "txo", "tr", 5, 0}, {"send_off", "txo", "env", 5, 0}}, "the last: both low")
  target.note_on(2, "s2", 60, 1); target.note_on(1, "s2", 72, 1); state.calls = {}
  target.note_off(1, "s2"); target.note_off(2, "s2")
  assert_calls(state, {{"send", "txo", "cv", 5, 5}, {"send_off", "txo", "tr", 5, 0}, {"send_off", "txo", "env", 5, 0}},
    "an envelope note that ended earlier leaves its gate to the last end, a pitch note")
end)

test("ready and release with a shared output send its lines once", function()
  local _, S, state = started()
  local device = device_of(S)
  for voice = 1, 2 do params:set("v" .. voice .. "_out_txo", 5); params:set("v" .. voice .. "_out_txo_cv", ENVELOPE) end
  params:set("v3_out_txo", 6); params:set("v3_out_txo_cv", ENVELOPE)
  state.calls = {}
  device.ready()
  local expected = setup_calls(5, 10, 500)
  for _, call in ipairs(setup_calls(6, 10, 500)) do expected[#expected + 1] = call end
  assert_calls(state, expected, "ready")
  device.release()
  assert_calls(state, {{"send_direct", "txo", "env_act", 5, 0}, {"send_direct", "txo", "env_act", 6, 0}}, "release")
end)

test("a note_on whose send raises leaves the line as it was", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_txo", 5)
  state.fail_next = true
  assert_true(not pcall(target.note_on, 1, "s1", 72, 1), "the error goes on to the core")
  target.note_off(1, "s1")
  assert_calls(state, {}, "an off for a note the line does not hold does nothing")
  target.note_on(1, "s1", 72, 1); state.calls = {}
  state.fail_next = true
  assert_true(not pcall(target.note_on, 1, "s2", 84, 1), "a second note, raising")
  assert_calls(state, {{"send", "txo", "cv", 5, 1}}, "the earlier note's cv is sent again")
  target.note_off(1, "s2")
  assert_calls(state, {}, "nothing for the failed note")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "txo", "tr", 5, 0}}, "the first note alone held the trigger")
end)

-- A note_on that raises partway puts the device back too, best effort
test("an envelope note whose tr raises on an empty output lowers the envelope gate it raised", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_txo", 5); params:set("v1_out_txo_cv", ENVELOPE)
  state.calls = {}; state.attempts = 0; state.fail_at = {[3] = true}
  assert_true(not pcall(target.note_on, 1, "s1", 60, 0.5))
  assert_calls(state, {{"send", "txo", "cv", 5, 2.5}, {"send", "txo", "env", 5, 1}, {"send_off", "txo", "env", 5, 0}},
    "the envelope gate is lowered")
  params:set("v1_out_txo_cv", 1)
  state.calls = {}
  target.note_on(1, "s2", 60, 1); target.note_off(1, "s2")
  assert_calls(state, {{"send", "txo", "cv", 5, 0}, {"send", "txo", "tr", 5, 1}, {"send_off", "txo", "tr", 5, 0}},
    "a later pitch note leaves no envelope gate to lower")
end)

test("an envelope note whose cv or env send raises repairs nothing that did not reach the device", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_txo", 5); params:set("v1_out_txo_cv", ENVELOPE)
  state.calls = {}; state.attempts = 0; state.fail_at = {[1] = true}
  assert_true(not pcall(target.note_on, 1, "s1", 60, 0.5))
  assert_calls(state, {}, "the cv raised: nothing reached the device, no env off")
  state.attempts = 0; state.fail_at = {[2] = true}
  assert_true(not pcall(target.note_on, 1, "s1", 60, 0.5))
  assert_calls(state, {{"send", "txo", "cv", 5, 2.5}}, "the env send raised: env 1 never went, so no env off")
  state.fail_at = nil
  target.note_on(1, "s2", 60, 1); target.note_off(1, "s2")
  assert_calls(state, {{"send", "txo", "cv", 5, 5}, {"send", "txo", "env", 5, 1}, {"send", "txo", "tr", 5, 1},
    {"send_off", "txo", "tr", 5, 0}, {"send_off", "txo", "env", 5, 0}}, "the line is clean after both")
end)

test("a pitch note whose tr raises on a sounding line sends the earlier note's cv again", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_txo", 5)
  target.note_on(1, "s1", 72, 1); state.calls = {}
  state.attempts = 0; state.fail_at = {[2] = true}
  assert_true(not pcall(target.note_on, 1, "s2", 84, 1))
  assert_calls(state, {{"send", "txo", "cv", 5, 2}, {"send", "txo", "cv", 5, 1}}, "put right")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "txo", "tr", 5, 0}}, "the line holds only the first note")
end)

test("a failed envelope note on a sounding pitch line puts back the cv and the gate", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_txo", 5)
  params:set("v2_out_txo", 5); params:set("v2_out_txo_cv", ENVELOPE)
  target.note_on(1, "s1", 72, 1); state.calls = {}
  state.attempts = 0; state.fail_at = {[3] = true}
  assert_true(not pcall(target.note_on, 2, "s1", 60, 1))
  assert_calls(state, {{"send", "txo", "cv", 5, 5}, {"send", "txo", "env", 5, 1}, {"send", "txo", "cv", 5, 1},
    {"send_off", "txo", "env", 5, 0}}, "the pitch note's cv again, the envelope gate lowered")
end)

test("a repair's own send raising is swallowed: the first error surfaces, the line is as before", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_txo", 5)
  target.note_on(1, "s1", 72, 1); state.calls = {}
  state.attempts = 0; state.fail_at = {[2] = true, [3] = true}
  local ok, message = pcall(target.note_on, 1, "s2", 84, 1)
  assert_true(not ok and tostring(message):find("#2", 1, true), "the first error: " .. tostring(message))
  state.calls = {}
  target.note_off(1, "s2")
  assert_calls(state, {}, "an off for the failed note does nothing")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "txo", "tr", 5, 0}}, "the first note alone")
end)

-- 3.6's target layout states: the target's own record carries them
test("the two TELEXo layout states are listed and each draws its look", function()
  local context, S = started()
  local states = S.registry.pages[S.constants.UI_PAGES.index.IO].layout_states
  local function state_named(name)
    for _, state in ipairs(states) do if state.name == name then return state end end
  end
  local on = state_named("voice: txo on an output")
  local open = state_named("voice: txo detail list open")
  assert_true(on ~= nil and open ~= nil, "both are listed")
  -- other targets' rows come ahead of the TELEXo's in the voice section
  local ahead = 0
  for _, entry in ipairs(S.lib.pages_io.rows()) do
    if entry.section == "voice" and entry.id == "txo" then break end
    if entry.section == "voice" and entry.selectable then ahead = ahead + 1 end
  end
  assert_true(ahead >= S.lib.pages_io.IO_PAGE.visible, "enough rows ahead to push the TELEXo's off screen")
  h.show_page("IO")
  on.setup(context); redraw()
  local cursor_row = S.lib.pages_io.rows()[S.io_cursor]
  assert_true(cursor_row.section == "voice" and cursor_row.id == "txo", "the cursor is on the TELEXo's row")
  assert_true(h.screen_shows(context, "out 3  envelope"), "the row's text")
  h.assert_screen_layout(context, "txo on an output")
  open.setup(context); redraw()
  assert_true(h.screen_shows(context, "output") and h.screen_shows(context, "mode"), "the detail list's fields")
  h.assert_screen_layout(context, "txo detail list open")
end)

test("each TELEXo layout state raises naming the row when the voice section lacks it", function()
  local context, S = started()
  target_of(S).rows = function() return {} end
  for _, name in ipairs({"voice: txo on an output", "voice: txo detail list open"}) do
    for _, state in ipairs(S.registry.pages[S.constants.UI_PAGES.index.IO].layout_states) do
      if state.name == name then
        h.show_page("IO")  -- a layout state runs with its page shown
        local ok, problem = pcall(state.setup, context)
        assert_true(not ok, name .. " raises")
        assert_true(tostring(problem):find("^txo layout: ") ~= nil and tostring(problem):find("row id txo", 1, true) ~= nil,
          name .. ": the message names the module and the row: " .. tostring(problem))
      end
    end
  end
end)

test("without the ii module the layout states are listed and do nothing", function()
  local context, S = started(true)
  local states = S.registry.pages[S.constants.UI_PAGES.index.IO].layout_states
  local found = 0
  for _, state in ipairs(states) do
    if state.name == "voice: txo on an output" or state.name == "voice: txo detail list open" then
      found = found + 1
      h.show_page("IO")
      state.setup(context); redraw()
    end
  end
  assert_equal(found, 2, "both listed")
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

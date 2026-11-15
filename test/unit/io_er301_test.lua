-- test/unit/io_er301_test.lua
-- The ER-301 as a note target over the ii bus (lib/io/er301.lua,
-- S.lib.io_er301): one note at a time, the newest. A port's cv, then its
-- trigger; the pitch returns to the newest left when one ends, the
-- trigger goes low when the last does (docs/design/3.6-facts/crow-ii.md
-- section 2, ER-301). S.lib.io_ii is a double here (the ii bus module is
-- another package's): the four functions the device uses, recording.
-- Run alone: lua test/run.lua io_er301

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- The double: send and send_off record only while leading (as the real
-- bus drops them otherwise), send_direct always; add_params does what the
-- real module's does
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
    if record.name == "er301" then return record end
  end
end

local function played(key, pitch)
  return {owner = "midi", key = key, pitch = pitch, velocity = 0.5, park = true, set_own = function() end}
end

local function lowered(state)
  local count = 0
  for _, call in ipairs(state.calls) do
    if call[1] == "send_off" and call[3] == "tr" then count = count + 1 end
  end
  return count
end

test("with defaults nothing is sent", function()
  local _, S, state = started()
  local target = target_of(S)
  assert_true(target ~= nil, "the target is registered")
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_out_er301"), 0, "voice " .. voice .. " is off")
    assert_equal(target.routed(voice), false, "not routed")
  end
  S.lib.notes.play(1, played(7740, 64))
  S.lib.notes.release(1, "midi", 7740)
  assert_calls(state, {}, "a note on an unrouted voice")
end)

test("its params: seven, port 0 to 100, in the ii group", function()
  local _, S = started()
  local device
  for _, record in ipairs(S.registry.ii_devices) do if record.name == "er301" then device = record end end
  assert_equal(device.param_count, 7)
  assert_true(device.ready == nil and device.release == nil, "no ready and no release")
  for voice = 1, S.constants.NUM_VOICES do
    local param = params:lookup_param("v" .. voice .. "_out_er301")
    assert_equal(param.min, 0); assert_equal(param.max, 100)
  end
  assert_equal(params:string("v1_out_er301"), "off")
  params:set("v1_out_er301", 12)
  assert_equal(params:string("v1_out_er301"), "port 12")
end)

test("a note sets the port's cv, then raises its trigger; the last note's end lowers it", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v3_out_er301", 12)
  assert_equal(target.routed(3), true)
  state.calls = {}
  target.note_on(3, "s1", 72, 1)
  assert_calls(state, {{"send", "er301", "cv", 12, 1}, {"send", "er301", "tr", 12, 1}}, "the first note")
  target.note_on(3, "s2", 84, 1)
  assert_calls(state, {{"send", "er301", "cv", 12, 2}, {"send", "er301", "tr", 12, 1}}, "the second note")
  target.note_off(3, "s2")
  assert_calls(state, {{"send", "er301", "cv", 12, 1}}, "the newest ends: the pitch goes back, no trigger")
  target.note_off(3, "s1")
  assert_calls(state, {{"send_off", "er301", "tr", 12, 0}}, "the last ends")
  target.note_on(3, "s1", 300, 1)
  assert_calls(state, {{"send", "er301", "cv", 12, 10}, {"send", "er301", "tr", 12, 1}}, "clamped to 10 V")
  target.note_on(3, "s2", -300, 1)
  assert_equal(state.calls[1][5], -10, "clamped to -10 V")
end)

test("an older note ending changes nothing, and a stray off never goes negative", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_er301", 5)
  state.calls = {}
  target.note_off(1, "s9")
  assert_calls(state, {}, "an off for a note that never started")
  target.note_on(1, "s1", 60, 1); target.note_on(1, "s2", 72, 1); state.calls = {}
  target.note_off(1, "s1")
  assert_calls(state, {}, "the older ends")
  target.note_off(1, "s1")
  assert_calls(state, {}, "twice")
  target.note_off(1, "s2")
  assert_calls(state, {{"send_off", "er301", "tr", 5, 0}}, "the last")
  target.note_off(1, "s2")
  assert_calls(state, {}, "an off after the last")
  target.note_on(1, "s3", 60, 1); state.calls = {}
  target.note_off(1, "s3")
  assert_calls(state, {{"send_off", "er301", "tr", 5, 0}}, "a fresh note after them starts clean")
end)

test("a note's id played again replaces it, never stacks", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_er301", 5)
  target.note_on(1, "s1", 60, 1); target.note_on(1, "s1", 62, 1); state.calls = {}
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "er301", "tr", 5, 0}}, "one off ends it")
end)

test("a route change, a voice stop and a stop of every note leave the trigger low", function()
  local _, S, state = started()
  params:set("v1_out_er301", 7)
  S.lib.notes.play(1, played(7740, 64)); S.lib.notes.play(1, played(7741, 67))
  state.calls = {}
  params:set("v1_out_er301", 8)  -- both notes end, on the port they started on
  assert_equal(lowered(state), 1, "a route change lowers the trigger once")
  assert_equal(state.calls[#state.calls][4], 7, "on the port it was raised on")
  S.lib.notes.play(1, played(7742, 64)); state.calls = {}
  toggle_voice(1)
  assert_equal(lowered(state), 1, "the voice's stop")
  assert_equal(state.calls[#state.calls][4], 8, "on port 8")
  S.lib.notes.play(1, played(7743, 64)); state.calls = {}
  S.lib.io_targets.stop_all()
  assert_equal(lowered(state), 1, "stop_all lowers it once")
  state.calls = {}
  target_of(S).stop_all()
  assert_calls(state, {}, "and a second stop_all sends nothing")
end)

test("a bus that is not led gets nothing, and the target keeps no note", function()
  local _, S, state = started()
  params:set("v2_out_er301", 3)
  target_of(S).note_on(2, "s1", 60, 1)
  state.leading = false
  state.calls = {}
  target_of(S).note_off(2, "s1")
  assert_calls(state, {}, "dropped while not leading")
  state.leading = true
  target_of(S).note_off(2, "s1")
  assert_calls(state, {}, "and no note is left")
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
end)

test("IO's voice section shows the er-301 row for the selected voice", function()
  local _, S = started()
  S.selected_voice = 4
  local function row()
    for _, entry in ipairs(S.lib.pages_io.rows()) do
      if entry.label == "er-301" then return entry end
    end
  end
  assert_equal(row().param_id, "v4_out_er301")
  assert_equal(row().shown, "off")
  params:set("v4_out_er301", 12)
  assert_equal(row().shown, "port 12")
end)

end

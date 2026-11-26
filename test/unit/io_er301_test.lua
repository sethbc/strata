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
  -- the ii group adds nothing and the device's params never exist (build ruling 6)
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

-- Build ruling 10: a port is one line that plays one note at a time, whatever voices feed it
test("two voices on one port share it: the trigger stays high until the line's last note ends", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_er301", 12); params:set("v2_out_er301", 12)
  state.calls = {}
  target.note_on(1, "s1", 72, 1)
  target.note_on(2, "s1", 84, 1)
  assert_calls(state, {{"send", "er301", "cv", 12, 1}, {"send", "er301", "tr", 12, 1},
    {"send", "er301", "cv", 12, 2}, {"send", "er301", "tr", 12, 1}}, "both notes")
  target.note_off(1, "s1")
  assert_calls(state, {}, "the older note (the first voice's only one) ends while the newer sounds: the trigger stays high")
  target.note_off(2, "s1")
  assert_calls(state, {{"send_off", "er301", "tr", 12, 0}}, "the trigger goes low once, at the line's last note")
  target.note_off(2, "s1")
  assert_calls(state, {}, "and never again")
end)

test("the pitch falls back across voices with no new trigger", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_er301", 12); params:set("v2_out_er301", 12)
  target.note_on(1, "s1", 72, 1); target.note_on(2, "s1", 84, 1); state.calls = {}
  target.note_off(2, "s1")
  assert_calls(state, {{"send", "er301", "cv", 12, 1}}, "the first voice's note again")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "er301", "tr", 12, 0}}, "its end")
end)

test("a note stays on the port it started on when its voice's port changes", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_er301", 12); params:set("v2_out_er301", 13)
  target.note_on(1, "s1", 72, 1); target.note_on(2, "s1", 72, 1); state.calls = {}
  params:set("v1_out_er301", 13)  -- v1's own note is not ended here: only the core ends notes
  target.note_on(1, "s2", 60, 1)
  assert_calls(state, {{"send", "er301", "cv", 13, 0}, {"send", "er301", "tr", 13, 1}}, "a new note: the new port")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "er301", "tr", 12, 0}}, "the old note lowers the port it raised")
end)

-- The core records a target for a note only when its note_on returned, so
-- a note_on that raised gets no off: it must leave the line as it was
test("a note_on whose send raises leaves the line as it was", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_er301", 12)
  state.fail_next = true
  assert_true(not pcall(target.note_on, 1, "s1", 72, 1), "the error goes on to the core")
  target.note_off(1, "s1")
  assert_calls(state, {}, "an off for the note the line does not hold does nothing")
  target.note_on(1, "s1", 72, 1); state.calls = {}
  state.fail_next = true
  assert_true(not pcall(target.note_on, 1, "s2", 84, 1), "a second note, raising")
  assert_calls(state, {{"send", "er301", "cv", 12, 1}}, "the earlier note's cv is sent again")
  target.note_off(1, "s2")
  assert_calls(state, {}, "nothing for the failed note")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "er301", "tr", 12, 0}}, "the first note alone holds the trigger, lowered once")
end)

-- A note_on that raises partway puts the device back too, best effort
test("a note_on whose tr raises on an empty port sends nothing more", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_er301", 12)
  state.calls = {}; state.attempts = 0; state.fail_at = {[2] = true}
  assert_true(not pcall(target.note_on, 1, "s1", 72, 1))
  assert_calls(state, {{"send", "er301", "cv", 12, 1}}, "the cv went, the trigger raised: no trigger off to send")
end)

test("a note_on whose tr raises on a sounding line sends the earlier note's cv again", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_er301", 12)
  target.note_on(1, "s1", 72, 1); state.calls = {}
  state.attempts = 0; state.fail_at = {[2] = true}
  assert_true(not pcall(target.note_on, 1, "s2", 84, 1))
  assert_calls(state, {{"send", "er301", "cv", 12, 2}, {"send", "er301", "cv", 12, 1}}, "put right")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "er301", "tr", 12, 0}}, "the line holds only the first note")
end)

test("a repair's own send raising is swallowed: the first error surfaces, the line is as before", function()
  local _, S, state = started()
  local target = target_of(S)
  params:set("v1_out_er301", 12)
  target.note_on(1, "s1", 72, 1); state.calls = {}
  state.attempts = 0; state.fail_at = {[2] = true, [3] = true}
  local ok, message = pcall(target.note_on, 1, "s2", 84, 1)
  assert_true(not ok and tostring(message):find("#2", 1, true), "the first error: " .. tostring(message))
  state.calls = {}
  target.note_off(1, "s2")
  assert_calls(state, {}, "an off for the failed note does nothing")
  target.note_off(1, "s1")
  assert_calls(state, {{"send_off", "er301", "tr", 12, 0}}, "the first note alone")
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


-- With the real ii module (not the double): a crow plugged in, Strata
-- leading the bus as the rig's row would set it
local function leading_real()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  context.crow.plug()
  assert_true(S.lib.io_rig.set("ii_bus", "strata"), "the rig takes ii_bus strata")
  assert_true(S.lib.io_ii.leads(), "Strata leads")
  return context, S
end

local function last_line(context, prefix)
  local last
  for _, line in ipairs(context.crow.sent) do
    if line:find(prefix, 1, true) == 1 then last = line end
  end
  return last
end

-- #1110: exercise the played-note owner, the preset read and the ii queue.
for _, silent in ipairs({false, true}) do
  for _, destination in ipairs({0, 2}) do
    test(("a %s PSET read moves a held ER-301 route from port 1 to %d"):format(
        silent and "silent" or "normal", destination), function()
      local context, S = leading_real()
      params:set("midi_note_off", 2) -- release
      params:set("v1_out_er301", destination)
      params:set("v2_out_er301", 3)
      local path = context.data_dir .. "er301-route.pset"
      params:write(path)
      params:set("v1_out_er301", 1)

      local function midi_note(channel, pitch, down)
        context.midi.send(1, {type = down and "note_on" or "note_off", ch = channel,
          note = pitch, vel = down and 100 or 0})
        context.clock.run_for(0.2)
      end
      local function gates()
        local sent = {}
        for _, line in ipairs(context.crow.sent) do
          if line:match("^ii%.er301%.tr") then sent[#sent + 1] = line end
        end
        context.crow.clear()
        return table.concat(sent, "|")
      end

      midi_note(1, 60, true)
      midi_note(2, 65, true)
      assert_equal(gates(), "ii.er301.tr(1, 1)|ii.er301.tr(3, 1)")
      params:read(path, silent)
      context.clock.run_for(0.2)
      assert_equal(gates(), "ii.er301.tr(1, 0)", "the old gate lowers at load")
      assert_true(next(S.lib.io_targets.sounding(1)) == nil, "the old target is released")
      assert_true(next(S.lib.io_targets.sounding(2)) ~= nil, "the other voice keeps its target")

      midi_note(1, 62, true)
      assert_equal(gates(), destination == 0 and "" or "ii.er301.tr(2, 1)", "the next note follows the route")
      params:read(path, silent)
      context.clock.run_for(0.2)
      midi_note(1, 60, false)
      assert_equal(gates(), "", "an unchanged read and the old key-up leave sounding notes alone")
      midi_note(1, 62, false)
      midi_note(2, 65, false)
      assert_equal(gates(), destination == 0 and "ii.er301.tr(3, 0)" or "ii.er301.tr(2, 0)|ii.er301.tr(3, 0)",
        "each sounding port lowers at its own key-up")
    end)
  end
end

test("a gate high when crow leaves is lowered when crow returns", function()
  -- crow-ii.md §2 (ER-301): tr(port, 1) raises the trigger, tr(port, 0) lowers it; a crow that
  -- leaves can send nothing, so the low is owed to the next lead (lib/io/ii.lua)
  local context, S = leading_real()
  params:set("v1_out_er301", 3)
  S.lib.notes.play(1, played(7750, 60))
  context.clock.run_for(0.2)
  assert_equal(last_line(context, "ii.er301.tr(3, "), "ii.er301.tr(3, 1)", "the trigger went high")
  context.crow.unplug()
  S.lib.notes.release(1, "midi", 7750)  -- the note ends while crow is away
  context.crow.clear()
  context.crow.plug()
  context.clock.run_for(0.2)
  assert_equal(context.crow.sent[1], "crow.reset()", "crow's reset first")
  assert_equal(last_line(context, "ii.er301.tr(3, "), "ii.er301.tr(3, 0)", "the trigger lowered on the return")
end)


test("two full-length steps on a port: the trigger's low goes out before the next step raises it", function()
  -- seq gate off (the default): a step's gate is the whole step, so the targets core ends it
  -- TARGETS.step_gap_seconds early and the SC.TR unit sees a low (crow-ii.md §2, ER-301)
  local context, S = started()
  params:set("v3_out_er301", 3)
  for voice = 1, S.constants.NUM_VOICES do
    for step = 1, S.constants.PATTERN_LENGTH do S.patterns[voice][step] = 0 end
  end
  S.patterns[3][1], S.patterns[3][2] = 15, 15
  local times = {}
  for _, kind in ipairs({"send", "send_off"}) do
    local real = S.lib.io_ii[kind]
    S.lib.io_ii[kind] = function(device, command, port, value)
      if command == "tr" then times[#times + 1] = {value = value, t = util.time()} end
      return real(device, command, port, value)
    end
  end
  pattern_clock_start()
  context.clock.run_for(0.2)  -- both steps have started (0.125 s each at 120 BPM)
  pattern_clock_stop()
  local shown = {}
  for _, entry in ipairs(times) do shown[#shown + 1] = string.format("tr %d at %.4f", entry.value, entry.t) end
  shown = table.concat(shown, "; ")
  assert_true(#times >= 3, "high, low, high: " .. shown)
  assert_equal(times[1].value, 1, shown); assert_equal(times[2].value, 0, shown); assert_equal(times[3].value, 1, shown)
  local gap = S.lib.io_targets.TARGETS.step_gap_seconds
  assert_true(times[3].t - times[2].t >= gap - 1 / 48 - 1e-6,
    "the low lasts at least the gap less one 48 Hz step: " .. shown)
end)


test("the ER-301 is routed only while Strata leads the bus, as Just Friends and W/ are", function()
  local _, S, state = started()
  params:set("v2_out_er301", 3)
  assert_equal(target_of(S).routed(2), true, "leading: routed")
  state.leading = false
  assert_equal(target_of(S).routed(2), false, "not leading: not routed, so the core records nothing on it")
  state.leading = true
  assert_equal(target_of(S).routed(2), true, "leading again")
end)


-- #937 (5c): a route set while Strata does not lead the ii bus (no crow, the
-- bus off or Teletype's) plays nothing; its row in IO's voice section says
-- so. The real ii module here, with the crow stub
test("an ii route is marked while Strata does not lead", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function row()
    for _, entry in ipairs(S.lib.pages_io.rows()) do
      if entry.section == "voice" and entry.param_id == "v1_out_er301" then return entry end
    end
  end
  assert_equal(local_value("S").lib.io_er301.ER301.idle_mark, "[idle]", "the mark")
  assert_equal(row().mark_shown, nil, "a route not set: no mark, whoever leads")
  params:set("v1_out_er301", 3)
  assert_equal(row().mark_shown, "[idle]", "set, with no crow")
  context.crow.plug()
  assert_equal(row().mark_shown, "[idle]", "set, the bus off")
  assert_true(S.lib.io_rig.set("ii_bus", "strata"), "Strata leads")
  assert_equal(row().mark_shown, nil, "Strata leads: no mark")
  assert_true(S.lib.io_rig.set("ii_bus", "teletype"), "Teletype leads")
  assert_equal(row().mark_shown, "[idle]", "Teletype leads: marked")
  h.show_page("IO"); S.lib.pages_io.go_to_row("er301", "voice", {param_id = "v1_out_er301"}); redraw()
  assert_true(h.screen_shows(context, "[idle]"), "on the screen")
  h.assert_screen_layout(context, "IO, an idle er301 route")
  params:set("v1_out_er301", 0)
  assert_equal(row().mark_shown, nil, "the route off: no mark")
end)

end

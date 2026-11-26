-- test/unit/io_osc_test.lua
-- OSC in and feedback (lib/io/osc.lua, S.lib.io_osc) and the TouchOSC layout
-- description (tools/touchosc/lib/layout.lua). Each comment cites
-- docs/design/3.6-facts/iii-osc-nb-softcut.md (the OSC fact file), section 2
-- (norns' osc.lua) or section 3 (TouchOSC), and checks.md sections 5 and 6.
-- No device or app is used. Run alone: lua test/run.lua io_osc

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local SENDER = {"10.0.0.7", 51000}

local function started()
  local context = load_strata(); finish_startup(context)
  return context, local_value("S")
end

local function printed(fn)
  local lines, real = {}, print
  print = function(...) lines[#lines + 1] = table.concat({...}, " ") end
  local ok, failure = pcall(fn)
  print = real
  if not ok then error(failure, 0) end
  return lines
end

local function clear(context)
  for key in pairs(context.osc.sent) do context.osc.sent[key] = nil end
end

-- The messages sent so far to a path
local function sent_path(context, path)
  local found = {}
  for _, message in ipairs(context.osc.sent) do
    if message.path == path then found[#found + 1] = message end
  end
  return found
end

-- Feedback on, a sender known, and the baseline taken
local function feeding()
  local context, S = started()
  S.lib.io_rig.set("osc_feedback", "on")
  context.osc.receive("/strata/hello", {}, SENDER)
  context.clock.run_for(0.5)
  clear(context)
  return context, S
end

test("with defaults nothing is sent and no clock runs", function()
  -- fact §2: norns sends nothing back by itself; Strata's feedback is off by default
  local context, S = started()
  assert_true(type(S.lib.io_osc) == "table", "the module is loaded")
  assert_equal(type(osc.event), "function", "osc.event is set by the start step")
  assert_equal(S.lib.io_rig.get("osc_feedback"), "off")
  params:set("macro_1", 0.4)
  context.osc.receive("/strata/hello", {}, SENDER)
  context.clock.run_for(1)
  assert_equal(#context.osc.sent, 0, "feedback off: nothing is sent, even after a hello")
  assert_equal(S.lib.io_osc.running(), false, "no feedback clock")
end)

test("each address does its action", function()
  -- the six addresses of design §10.1; norns passes (path, args, from) to osc.event (fact §2)
  local context, S = started()
  capture_scene(3)
  S.current_scene = 1
  context.osc.receive("/strata/scene", {3}, SENDER)
  assert_equal(S.current_scene, 3, "scene 3 recalled (quantize off: at once)")
  assert_true(not S.voices[3].active)
  context.osc.receive("/strata/voice/3/run", {1}, SENDER)
  assert_true(S.voices[3].active, "voice 3 started")
  context.osc.receive("/strata/voice/3/run", {2}, SENDER)
  assert_true(not S.voices[3].active, "toggled off")
  context.osc.receive("/strata/voice/3/run", {1}, SENDER)
  local calls = {}
  local real = engine.retrigger
  engine.retrigger = function(...) calls[#calls + 1] = {...}; return real(...) end
  context.osc.receive("/strata/voice/3/retrigger", {0.5}, SENDER)
  engine.retrigger = real
  assert_equal(#calls, 1); assert_equal(calls[1][1], 2); assert_equal(calls[1][2], 0.5)
  local playing = S.pattern_playing
  context.osc.receive("/strata/patterns", {2}, SENDER)
  assert_true(S.pattern_playing ~= playing, "the patterns toggled")
end)

test("a wrong address, argument or voice prints one line and does nothing", function()
  local context, S = started()
  capture_scene(3)
  S.current_scene = 1
  local cases = {
    {"/strata/nope", {1}}, {"/strata/voice/9/run", {1}}, {"/strata/voice/0/run", {1}}, {"/strata/scene", {}},
    {"/strata/scene", {"x"}}, {"/strata/voice/3/run", {}}, {"/strata/voice/3/run", {"on"}},
    {"/strata/voice/3/jump", {1}}, {"/strata/patterns", {"x"}}, {"/strata/watch", {}}, {"/strata/watch", {"nope_id"}},
    {"/strata/voice/3/retrigger", {"loud"}},
  }
  for _, case in ipairs(cases) do
    local lines = printed(function() context.osc.receive(case[1], case[2], SENDER) end)
    assert_equal(#lines, 1, case[1] .. " prints one line: " .. table.concat(lines, " | "))
  end
  assert_equal(S.current_scene, 1); assert_true(not S.voices[3].active)
  -- a path that is not Strata's (and not /param) is left alone, silently
  assert_equal(#printed(function() context.osc.receive("/remote/key", {1, 1}, SENDER) end), 0)
end)

test("norns' own /param handling is left alone", function()
  -- fact §2: osc.event runs first, then the built-in /param handler sets the real value
  local context = started()
  local runs = 0
  local param = params:lookup_param("macro_1")
  local real = param.action
  param.action = function(...) runs = runs + 1; if real then return real(...) end end
  context.osc.receive("/param/macro_1", {0.5}, SENDER)
  param.action = real
  assert_equal(params:get("macro_1"), 0.5)
  assert_equal(runs, 1, "the action ran once")
end)

test("feedback goes to the last sender's host at the rig's port", function()
  local context, S = feeding()
  params:set("macro_2", 0.3)
  context.clock.run_for(0.1)
  local sent = sent_path(context, "/param/macro_2")
  assert_equal(#sent, 1)
  assert_equal(sent[1].to[1], "10.0.0.7"); assert_equal(sent[1].to[2], 9000)
  assert_equal(sent[1].args[1], 0.3)
  S.lib.io_rig.set("osc_port", 8000)
  params:set("macro_2", 0.6)
  context.clock.run_for(0.1)
  sent = sent_path(context, "/param/macro_2")
  assert_equal(sent[#sent].to[2], 8000, "the next goes to the new port")
  context.osc.receive("/strata/watch", {"v1_freq"}, {"10.0.0.9", 40000})
  clear(context); params:set("macro_2", 0.1); context.clock.run_for(0.1)
  assert_equal(sent_path(context, "/param/macro_2")[1].to[1], "10.0.0.9", "the last sender's host")
end)

test("a value that just arrived is not sent back", function()
  local context = feeding()
  context.osc.receive("/param/macro_1", {0.5}, SENDER)
  context.clock.run_for(0.2)
  assert_equal(#sent_path(context, "/param/macro_1"), 0, "no echo within 0.25 s")
  params:set("macro_1", 0.9)  -- changed inside the window: still not sent in it
  context.clock.run_for(0.01)
  assert_equal(#sent_path(context, "/param/macro_1"), 0, "still inside 0.25 s")
  context.clock.run_for(0.3)
  assert_equal(#sent_path(context, "/param/macro_1"), 1, "a change after the window is sent")
  assert_equal(sent_path(context, "/param/macro_1")[1].args[1], 0.9)
end)

test("feedback sends at most 32 a tick, newest values, none lost", function()
  local context = feeding()
  for v = 1, local_value("S").constants.NUM_VOICES do
    context.osc.receive("/strata/watch", {"v" .. v .. "_freq"}, SENDER)
    context.osc.receive("/strata/watch", {"v" .. v .. "_pan"}, SENDER)
  end
  for m = 1, 16 do params:set("macro_" .. m, 0.2 + m / 100) end
  for v = 1, local_value("S").constants.NUM_VOICES do params:set("v" .. v .. "_amp", 0.3 + v / 100); params:set("v" .. v .. "_mute", 1) end
  params:set("v1_freq", 300); params:set("v1_freq", 310)
  for v = 2, local_value("S").constants.NUM_VOICES do params:set("v" .. v .. "_freq", 200 + v) end
  local changed = 16 + 3 * local_value("S").constants.NUM_VOICES  -- the macros; each voice's amp, mute and freq
  clear(context)
  -- the clock sleeps 1/15 s between ticks: the first tick falls inside this step
  context.clock.run_for(1 / 15 + 0.001)
  local first = #context.osc.sent
  assert_true(first >= 1 and first <= 32, "at most 32 in the first tick: " .. first)
  context.clock.run_for(0.5)
  assert_equal(#context.osc.sent, changed, "all of them arrive, none twice")
  local freq = sent_path(context, "/param/v1_freq")
  assert_equal(#freq, 1, "one changed twice sends once")
  -- the freq param's exponential spec stores 310 as 309.99999999999994: near, and not the first value, 300
  assert_near(freq[1].args[1], 310, 1e-6, "its newest value")
end)

test("forty watched params changing every tick: none starves, none past 32, each value current", function()
  local context, S = feeding()
  local ids = {}
  -- the changing ones: not the mutes (a binary flipping back before it is sent is rightly not sent)
  for _, id in ipairs(S.lib.io_osc.OSC.watch) do if not id:find("_mute$") then ids[#ids + 1] = id end end
  for _, extra in ipairs({"v1_freq", "v2_freq", "v3_freq", "v4_freq", "v5_freq", "v6_freq", "v7_freq",
      "v1_pan", "v2_pan", "v3_pan", "reverb_size", "delay_mix", "delay_time", "drift_amount", "filter_freq",
      "delay_feedback", "mutation_rate"}) do
    ids[#ids + 1] = extra
    context.osc.receive("/strata/watch", {extra}, SENDER)
  end
  assert_equal(#ids, 40)
  -- each message, stamped with the clock's time, and whether it carried the value current when it was sent
  local stamps, stale = {}, {}
  local real_send = osc.send
  osc.send = function(to, path, args)
    local id = path:match("^/param/(.+)$")
    if id then
      stamps[#stamps + 1] = {id = id, time = util.time()}
      if args[1] ~= params:get(id) then stale[#stale + 1] = id end
    end
    return real_send(to, path, args)
  end
  local changes = {}  -- round -> the clock time every param changed at
  for round = 1, 10 do
    for _, id in ipairs(ids) do
      params:set_raw(id, 0.05 + 0.09 * round)  -- never the same twice: a value back at the last sent is rightly not sent
    end
    changes[round] = util.time()
    context.clock.run_for(1 / 15)
  end
  context.clock.run_for(0.5)
  osc.send = real_send
  assert_equal(#stale, 0, "every message carries the value current when it is sent: " .. table.concat(stale, ","))
  local per_tick = {}
  for _, stamp in ipairs(stamps) do per_tick[stamp.time] = (per_tick[stamp.time] or 0) + 1 end
  for time, count in pairs(per_tick) do assert_true(count <= 32, count .. " sent at " .. time) end
  for round = 1, 10 do
    for _, id in ipairs(ids) do
      local served = false
      for _, stamp in ipairs(stamps) do
        if stamp.id == id and stamp.time > changes[round] and stamp.time <= changes[round] + 2 / 15 + 1e-6 then
          served = true
        end
      end
      if not served then local seen = {} for _, st in ipairs(stamps) do if st.id == id then seen[#seen + 1] = string.format("%.4f", st.time) end end error(id .. " round " .. round .. " at " .. string.format("%.4f", changes[round]) .. " sent at " .. table.concat(seen, ",")) end
    end
  end
end)

test("a sender cannot grow the arrival record with ids that are not watched", function()
  local context, S = started()
  for index = 1, 500 do context.osc.receive("/param/nothing_" .. index, {0.5}, SENDER) end
  assert_equal(S.lib.io_osc.tracked(), 0, "unwatched ids are not recorded")
  context.osc.receive("/param/macro_1", {0.5}, SENDER)
  assert_equal(S.lib.io_osc.tracked(), 1, "a watched id is")
end)

test("a handler that raises or a malformed sender never escapes osc.event, and /param still runs", function()
  local context, S = started()
  -- a malformed or missing from: no error, no line, the sender not taken
  for _, from in ipairs({false, "10.0.0.7", {}, {5}, {{}}}) do
    local lines = printed(function() context.osc.receive("/param/macro_1", {0.25}, from) end)
    assert_equal(#lines, 0, "no line for a malformed from")
    assert_equal(params:get("macro_1"), 0.25, "norns' handling ran")
    params:set("macro_1", 0)
  end
  osc.event("/strata/hello", {})  -- no from at all
  assert_equal(S.lib.io_osc.running(), false)
  -- a handler that raises: one line, nothing escapes, norns' /param handling runs after it
  local real_get = S.lib.io_rig.get
  S.lib.io_rig.get = function() error("probe failure") end
  local lines = printed(function() context.osc.receive("/param/macro_2", {0.6}, SENDER) end)
  S.lib.io_rig.get = real_get
  assert_equal(#lines, 1, "one line: " .. table.concat(lines, " | "))
  assert_true(lines[1]:find("osc event failed", 1, true) ~= nil and lines[1]:find("probe failure", 1, true) ~= nil,
    "it names the failure")
  assert_equal(params:get("macro_2"), 0.6, "the built-in /param handling still ran")
  -- an action that raises
  local real_recall = S.lib.io_actions.recall_scene
  S.lib.io_actions.recall_scene = function() error("action failure") end
  lines = printed(function() context.osc.receive("/strata/scene", {3}, SENDER) end)
  S.lib.io_actions.recall_scene = real_recall
  assert_equal(#lines, 1)
end)

test("an ordinary first edit gets no snapshot, then hello sends the existing control values", function()
  local context, S = started()
  S.lib.io_rig.set("osc_feedback", "on")
  S.lib.io_actions.run_voice(1, 1)
  params:set("v1_amp", 0.3)
  params:set("macro_2", 0.72)

  context.osc.receive("/param/macro_1", {0.4}, SENDER)
  context.clock.run_for(0.5)
  assert_equal(#context.osc.sent, 0)

  context.osc.receive("/strata/hello", {}, SENDER)
  context.clock.run_for(0.5)
  assert_equal(#context.osc.sent, 39)
  assert_equal(sent_path(context, "/strata/voice/1/running")[1].args[1], 1)
  assert_near(sent_path(context, "/param/v1_amp")[1].args[1], 0.3, 1e-6)
  assert_near(sent_path(context, "/param/macro_2")[1].args[1], 0.72, 1e-6)
end)

test("watch adds a param and hello sends everything watched", function()
  local context, S = feeding()
  context.osc.receive("/strata/watch", {"v1_freq"}, SENDER)
  params:set("v1_freq", 333)
  context.clock.run_for(0.1)
  assert_equal(#sent_path(context, "/param/v1_freq"), 1, "a watched param is sent on change")
  capture_scene(2); S.current_scene = 2
  clear(context)
  context.osc.receive("/strata/hello", {}, SENDER)
  context.clock.run_for(0.5)
  assert_equal(#sent_path(context, "/param/v1_freq"), 1)
  for _, id in ipairs(S.lib.io_osc.OSC.watch) do assert_equal(#sent_path(context, "/param/" .. id), 1, id) end
  assert_equal(#sent_path(context, "/strata/scene"), 1)
  for v = 1, S.constants.NUM_VOICES do assert_equal(#sent_path(context, "/strata/voice/" .. v .. "/running"), 1) end
  assert_equal(#sent_path(context, "/strata/patterns"), 1)
end)

test("the scene, a voice's running and the patterns are fed back when they change", function()
  local context, S = feeding()
  capture_scene(4)
  recall_scene_instant(4)
  context.clock.run_for(0.1)
  assert_equal(sent_path(context, "/strata/scene")[1].args[1], 4)
  local was = S.voices[3].active and 1 or 0
  toggle_voice(3)
  context.clock.run_for(0.1)
  assert_equal(sent_path(context, "/strata/voice/3/running")[1].args[1], 1 - was)
  assert_equal(#sent_path(context, "/strata/patterns"), 0, "not changed yet")
  S.lib.io_actions.patterns(1)
  context.clock.run_for(0.1)
  assert_equal(sent_path(context, "/strata/patterns")[1].args[1], 1)
  S.lib.io_actions.patterns(0)
  context.clock.run_for(0.1)
  assert_equal(sent_path(context, "/strata/patterns")[2].args[1], 0)
  clear(context); context.clock.run_for(0.5)
  assert_equal(#context.osc.sent, 0, "unchanged: nothing more")
end)

test("with feedback off, or before any sender, nothing is sent", function()
  local context, S = started()
  S.lib.io_rig.set("osc_feedback", "on")
  params:set("macro_3", 0.7)
  context.clock.run_for(1)
  assert_equal(#context.osc.sent, 0, "no sender yet")
  assert_equal(S.lib.io_osc.running(), false, "and no clock")
  context.osc.receive("/strata/hello", {}, SENDER)
  assert_equal(S.lib.io_osc.running(), true, "feedback on and a sender: the clock runs")
  S.lib.io_rig.set("osc_feedback", "off")
  assert_equal(S.lib.io_osc.running(), false, "turned off: the clock stops")
  clear(context); params:set("macro_3", 0.2); context.clock.run_for(1)
  assert_equal(#context.osc.sent, 0)
end)

test("the feedback clock stopped as its wake is posted: no clock error, and nothing more happens", function()
  -- #870: feedback turned off after matron posted the clock's resume and before Lua delivered
  -- it; the clock ends at that wake and sends nothing
  local context, S = feeding()
  local id = S.lib.io_osc.clock_id()
  assert_true(id ~= nil, "the feedback clock runs")
  params:set("macro_3", 0.7)  -- a change the next tick would send
  context.clock.advance_until(id, function() S.lib.io_rig.set("osc_feedback", "off") end)
  context.clock.run_for(0.5)
  assert_equal(#context.clock.take_errors(), 0, "no resume reached a canceled clock")
  assert_equal(#context.osc.sent, 0, "nothing sent at the wake or after")
  assert_equal(clock.threads[id], nil, "the clock ended at its wake")
  assert_equal(S.lib.io_osc.running(), false, "no clock")
end)

test("cleanup clears osc.event and stops the clock", function()
  local _, S = feeding()
  assert_true(S.lib.io_osc.running())
  cleanup()
  assert_equal(osc.event, nil)
  assert_equal(S.lib.io_osc.running(), false)
end)

test("IO's osc section shows the rig rows and the sender", function()
  local context, S = started()
  local record
  for _, section in ipairs(S.registry.io_sections) do if section.name == "osc" then record = section end end
  assert_true(record ~= nil, "an osc section is registered")
  local keys = {}
  for _, row in ipairs(record.rows()) do if row.kind == "rig" then keys[#keys + 1] = row.key end end
  assert_equal(table.concat(keys, ","), "osc_feedback,osc_port")
  assert_equal(record.status(), "no sender")
  context.osc.receive("/strata/hello", {}, SENDER)
  assert_equal(record.status(), "10.0.0.7")
  assert_equal(#record.layout_states, 2, "feedback off with no sender; on with a sender")
end)

test("a new sender is drawn on the next frame while IO shows the osc section", function()
  -- IO does not animate: the title's sender changes only by a redraw request
  local context, S = started()
  h.show_page("IO")
  S.lib.pages_io.show_section("osc")
  h.assert_drawn_on_next_frame(context, nil, "a new sender's hello", function()
    context.osc.receive("/strata/hello", {}, SENDER)
  end)
  assert_true(h.screen_shows(context, "10.0.0.7"), "the title shows the sender")
  h.assert_drawn_on_next_frame(context, nil, "another sender", function()
    context.osc.receive("/strata/hello", {}, {"10.0.0.8", 51000})
  end)
end)

test("every address in the layout description is a param or one of Strata's addresses", function()
  -- checks.md §5: the description is a Lua table the generator reads; design §10.1's table
  local _, S = started()
  local layout = dofile("tools/touchosc/lib/layout.lua")
  local known = {["/strata/scene"] = true, ["/strata/patterns"] = true, ["/strata/hello"] = true}
  for v = 1, S.constants.NUM_VOICES do known["/strata/voice/" .. v .. "/run"] = true; known["/strata/voice/" .. v .. "/retrigger"] = true end
  for _, id in ipairs(layout.params) do assert_true(params.lookup[id] ~= nil, id .. " is a param") end
  for _, path in ipairs(layout.addresses) do assert_true(known[path], path .. " is a Strata address") end
  local seen = {}
  for _, id in ipairs(layout.params) do seen[id] = true end
  assert_equal(#S.lib.io_osc.OSC.watch, #layout.params, "the watch list is the layout's params")
  for _, id in ipairs(S.lib.io_osc.OSC.watch) do assert_true(seen[id], id .. " is in the layout") end
  for _, name in ipairs({"tablet", "phone"}) do
    for _, page in ipairs(layout[name].pages) do
      for _, control in ipairs(page.controls) do
        assert_true((control.param ~= nil) ~= (control.address ~= nil), control.label .. " has one target")
        if control.param then assert_true(seen[control.param], control.param) end
        if control.address then assert_true(known[control.address], control.address) end
      end
    end
  end
end)

test("both layouts are committed", function()
  for _, name in ipairs({"strata-tablet", "strata-phone"}) do
    local file = io.open("extras/touchosc/" .. name .. ".tosc", "rb")
    assert_true(file ~= nil, name .. ".tosc exists")
    local size = file and file:seek("end") or 0
    if file then file:close() end
    assert_true(size > 0, name .. ".tosc is not empty")
  end
end)


-- The invariant `osc` (#935): the feedback clock runs exactly while
-- feedback is on and a sender is known. The test that breaks it reaches
-- the module's state through h.registered_invariant
test("the osc invariant holds as feedback and the sender come and go", function()
  local context, S = started()
  local invariant = h.registered_invariant("osc")
  assert_equal(invariant.check(), nil, "no feedback, no clock")
  S.lib.io_rig.set("osc_feedback", "on")
  assert_equal(invariant.check(), nil, "feedback on, no sender: no clock")
  context.osc.receive("/strata/hello", {}, SENDER)
  assert_equal(invariant.check(), nil, "a sender: the clock runs")
  S.lib.io_rig.set("osc_feedback", "off")
  assert_equal(invariant.check(), nil, "feedback off: the clock stopped")
  S.lib.io_rig.set("osc_feedback", "on")
  cleanup()
  assert_equal(invariant.check(), nil, "after cleanup: no sender, no clock")
end)

test("the osc invariant names a clock that runs without a sender, and a sender with no clock", function()
  local context, S = started()
  S.lib.io_rig.set("osc_feedback", "on")
  context.osc.receive("/strata/hello", {}, SENDER)
  h.allow_broken_invariants("the test breaks the osc invariant on purpose")
  local invariant = h.registered_invariant("osc")
  local state = invariant.upvalue("state")
  local sender = state.sender
  state.sender = nil
  assert_true(invariant.check() ~= nil, "a clock with no sender is reported")
  state.sender = sender
  S.lib.clocks.stop(state.clock)
  assert_true(invariant.check() ~= nil, "a stopped clock kept under feedback and a sender is reported")
  state.clock = nil
  assert_true(invariant.check() ~= nil, "no clock under feedback and a sender is reported")
end)

end

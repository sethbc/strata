-- test/unit/io_wsyn_test.lua
-- W/ synth (lib/io/wsyn.lua, S.lib.io_wsyn): an ii device and a note target.
-- Every command name and argument order is crow's descriptor's
-- (docs/design/3.6-facts/crow-ii.md §2, W/). S.lib.io_ii is a recording
-- double (plan-common.md, Doubles), since 2b's module is not on this branch.
-- Run alone: lua test/run.lua io_wsyn

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- A recording double with exactly the functions 2c to 2e use; `state.leading`
-- is the test's switch for the bus
local function ii_double(log, state)
  local function record(name)
    return function(...) log[#log + 1] = {name, ...}; return state.leading end
  end
  return {
    leads = function() return state.leading end,
    send = record("send"), send_off = record("send_off"), send_direct = record("send_direct"),
    add_params = function()
      local S = local_value("S")
      local count = 0
      for _, device in ipairs(S.registry.ii_devices) do count = count + device.param_count end
      params:add_group("strata_out_ii", "out ii", count)
      for _, device in ipairs(S.registry.ii_devices) do
        if device.add_params then device.add_params() end
      end
    end,
  }
end

local function started(leading)
  local log, state = {}, {leading = leading ~= false}
  local context = load_strata({before_init = function()
    local_value("S").lib.io_ii = ii_double(log, state)
  end})
  finish_startup(context)
  return context, local_value("S"), log, state
end

local function device_of(S)
  for _, record in ipairs(S.registry.ii_devices) do if record.name == "wsyn" then return record end end
end

local function target_of(S)
  for _, record in ipairs(S.registry.note_targets) do if record.name == "wsyn" then return record end end
end

test("with defaults nothing is sent", function()
  local context, S, log = started()
  context.clock.run_for(1)
  assert_equal(#log, 0, "no ii call")
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_out_wsyn"), 0, "v" .. voice .. " is off")
    assert_equal(target_of(S).routed(voice), false, "v" .. voice .. " is not routed")
  end
  assert_equal(params:get("wsyn_level"), 5)
end)

test("a note is one play_note in volts at the level", function()
  -- crow-ii.md §2, W/: wsyn.play_note(pitch, velocity); volts clamp to +-5
  local _, S, log = started()
  local target = target_of(S)
  params:set("v1_out_wsyn", 1)
  assert_equal(target.routed(1), true)
  target.note_on(1, "m7740", 48, 1)
  assert_equal(#log, 1, "one call")
  assert_equal(table.concat(log[1], ",", 1, 3), "send,wsyn,play_note")
  assert_near(log[1][4], -1, 1e-9); assert_near(log[1][5], 5, 1e-9)
  target.note_off(1, "m7740")
  assert_equal(#log, 1, "a note off sends nothing")
  params:set("wsyn_level", 8)
  target.note_on(1, "s1", 72, 0.5)
  assert_near(log[2][4], 1, 1e-9); assert_near(log[2][5], 4, 1e-9)
  target.note_on(1, "s2", 0, 1)
  assert_near(log[3][4], -5, 1e-9, "clamped low")
  target.note_on(1, "s3", 130, 1)
  assert_near(log[4][4], 5, 1e-9, "clamped high")
end)

test("a voice is routed only while the bus leads", function()
  local _, S, _, state = started()
  params:set("v2_out_wsyn", 1)
  assert_equal(target_of(S).routed(2), true)
  state.leading = false
  assert_equal(target_of(S).routed(2), false)
end)

test("ready sets AR mode and four voices, in that order", function()
  -- crow-ii.md §2, W/: wsyn.ar_mode(1), wsyn.voices(4); no release
  local _, S, log = started()
  local device = device_of(S)
  device.ready()
  assert_equal(#log, 2)
  assert_equal(table.concat(log[1], ","), "send,wsyn,ar_mode,1")
  assert_equal(table.concat(log[2], ","), "send,wsyn,voices,4")
  assert_equal(device.release, nil, "no release")
end)

test("the route's change ends the voice's target notes", function()
  local _, S = started()
  local calls = {}
  local real = S.lib.io_targets.route_changed
  S.lib.io_targets.route_changed = function(voice) calls[#calls + 1] = voice; return real(voice) end
  params:set("v3_out_wsyn", 1)
  assert_equal(calls[#calls], 3)
end)

test("its eight params are in the ii group and its rows show on the voice section", function()
  local _, S = started()
  assert_equal(device_of(S).param_count, 8)
  -- the group holds every registered device's params, W/ synth's eight among them
  local total = 0
  for _, device in ipairs(S.registry.ii_devices) do total = total + device.param_count end
  assert_equal(params:lookup_param("strata_out_ii").n, total, "the group: every device's params")
  local group = params.lookup.strata_out_ii
  local ids = {"wsyn_level"}
  for voice = 1, S.constants.NUM_VOICES do ids[#ids + 1] = "v" .. voice .. "_out_wsyn" end
  assert_equal(#ids, 8)
  for _, id in ipairs(ids) do
    local index = params.lookup[id]
    assert_true(index ~= nil and index > group and index <= group + total, id .. " is inside the ii group")
  end
  assert_equal(params:lookup_param("v1_out_wsyn").t, params.tBINARY)
  local rows = target_of(S).rows(1)
  assert_equal(#rows, 2)
  assert_equal(rows[1].label, "w/ syn"); assert_equal(rows[1].param_id, "v1_out_wsyn")
  assert_equal(rows[1].binary[0], "off"); assert_equal(rows[1].binary[1], "on")
  assert_equal(rows[2].label, "w/ level"); assert_equal(rows[2].param_id, "wsyn_level")
  local range = params:lookup_param("wsyn_level").controlspec
  assert_equal(range.minval, 0); assert_equal(range.maxval, 10)
end)

test("without the ii module the device does nothing and the page draws", function()
  -- the real ii module taken away before init: the ii group adds nothing,
  -- so the device's params never exist (build ruling 6)
  local context = load_strata({before_init = function() local_value("S").lib.io_ii = nil end})
  finish_startup(context)
  local S = local_value("S")
  assert_equal(S.lib.io_ii, nil, "no ii module on this load")
  local target = target_of(S)
  assert_equal(target.routed(1), false)
  assert_equal(#target.rows(1), 0, "no rows without its params")
  target.note_on(1, "s1", 60, 1); target.note_off(1, "s1")
  assert_equal(params.lookup.v1_out_wsyn, nil, "no param was added")
  S.lib.pages_io.show_section("voice")
  local ok, problem = pcall(redraw)
  assert_true(ok, tostring(problem))
end)

-- #937 (5c): a route set while Strata does not lead the ii bus (no crow, the
-- bus off or Teletype's) plays nothing; its row in IO's voice section says
-- so. The real ii module here, with the crow stub
test("an ii route is marked while Strata does not lead", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function row()
    for _, entry in ipairs(S.lib.pages_io.rows()) do
      if entry.section == "voice" and entry.param_id == "v1_out_wsyn" then return entry end
    end
  end
  assert_equal(local_value("S").lib.io_wsyn.WSYN.idle_mark, "[idle]", "the mark")
  assert_equal(row().mark_shown, nil, "a route not set: no mark, whoever leads")
  params:set("v1_out_wsyn", 1)
  assert_equal(row().mark_shown, "[idle]", "set, with no crow")
  context.crow.plug()
  assert_equal(row().mark_shown, "[idle]", "set, the bus off")
  assert_true(S.lib.io_rig.set("ii_bus", "strata"), "Strata leads")
  assert_equal(row().mark_shown, nil, "Strata leads: no mark")
  assert_true(S.lib.io_rig.set("ii_bus", "teletype"), "Teletype leads")
  assert_equal(row().mark_shown, "[idle]", "Teletype leads: marked")
  h.show_page("IO"); S.lib.pages_io.go_to_row("wsyn", "voice", {param_id = "v1_out_wsyn"}); redraw()
  assert_true(h.screen_shows(context, "[idle]"), "on the screen")
  h.assert_screen_layout(context, "IO, an idle wsyn route")
  params:set("v1_out_wsyn", 0)
  assert_equal(row().mark_shown, nil, "the route off: no mark")
end)

end

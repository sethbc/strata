-- test/unit/grid_core_test.lua
-- Grid core (lib/grid/core.lua): pages per port, held keys and holds, the
-- step-level gesture, the scene save hold and the shared key helpers
-- Run alone: lua test/run.lua grid_core

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, find_upvalue = h.load_strata, h.local_value, h.finish_startup, h.find_upvalue
local wake, wake_buffer_clock = h.wake, h.wake_buffer_clock

local function grid_core() return local_value("S").lib.grid_core end
local function tap(context, port, x, y)
  context.grid.press(port, x, y, 1); context.grid.press(port, x, y, 0)
end

test("a second key on a held step's row sets its level", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16); context.grid.press(1, 3, 2, 1)
  assert_equal(patterns[2][3], 15, "the held step toggles on at press")
  context.grid.press(1, 8, 2, 1)
  assert_equal(patterns[2][3], 8, "8 * 15 / 16 = 7.5 -> 8")
  assert_equal(patterns[2][8], 0, "the second key does not toggle")
  context.grid.press(1, 8, 2, 0); context.grid.press(1, 3, 2, 0)
  assert_equal(patterns[2][3], 8, "the releases change nothing")
  assert_true(not grid_core().consumed(1, 3, 2), "consumed is cleared after the release")
  -- with nothing held, a key toggles again
  context.grid.press(1, 8, 2, 1); context.grid.press(1, 8, 2, 0)
  assert_equal(patterns[2][8], 15, "a key pressed alone toggles at press")
  -- a held key of another voice does not set levels
  context.grid.press(1, 5, 1, 1); context.grid.press(1, 6, 2, 1)
  assert_equal(patterns[2][6], 15, "voice 2's key toggles while voice 1's step is held")
  assert_equal(patterns[1][5], 15, "voice 1's held step keeps its level")
end)

-- A voice has at most one held step on a port (#450): a second key of the
-- voice always sets a level. A step held after an earlier one's release is
-- the held step
test("the step held now gets the level, not one released before", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 3, 2, 1); context.grid.press(1, 3, 2, 0)
  context.clock.run_for(0.1)
  context.grid.press(1, 5, 2, 1); context.clock.run_for(0.1)
  context.grid.press(1, 12, 2, 1)
  assert_equal(patterns[2][5], 11, "round(12 * 15 / 16) = 11")
  assert_equal(patterns[2][3], 15, "the released step keeps its level")
  assert_equal(patterns[2][12], 0, "the level key does not toggle")
end)

test("a key that set a level is not a held step", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 2, 1, 1)
  context.grid.press(1, 4, 1, 1)   -- still held: sets step 2 to 4
  context.grid.press(1, 16, 1, 1)  -- step 2 again, not step 4
  assert_equal(patterns[1][2], 15, "the held step gets column 16's level")
  assert_equal(patterns[1][4], 0, "the held level key never toggles or takes a level")
  assert_equal(patterns[1][16], 0)
end)

test("on an 8-wide grid levels follow eight positions", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 8, 8); context.grid.press(1, 2, 1, 1)
  context.grid.press(1, 4, 1, 1); assert_equal(patterns[1][2], 8, "round(4 * 15 / 8) = 8")
  context.grid.press(1, 4, 1, 0)
  context.grid.press(1, 8, 1, 1); assert_equal(patterns[1][2], 15, "column 8 is the top")
  context.grid.press(1, 8, 1, 0)
  context.grid.press(1, 1, 1, 1); assert_equal(patterns[1][2], 2, "round(15 / 8) = 2")
  assert_equal(patterns[1][1] + patterns[1][4] + patterns[1][8], 0, "the level keys never toggled")
end)

test("on 128h levels follow sixteen columns", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 8); context.grid.press(1, 3, 4, 1)
  context.grid.press(1, 16, 4, 1)
  assert_equal(patterns[4][3], 15)
  assert_equal(patterns[4][16], 0)
end)

test("on 128v levels follow sixteen positions down the voice's column", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 8, 16); context.grid.press(1, 2, 3, 1)
  assert_equal(patterns[2][3], 15, "voice 2 step 3 toggles on")
  context.grid.press(1, 2, 8, 1)
  assert_equal(patterns[2][3], 8, "row 8 of 16 -> 8")
  assert_equal(patterns[2][8], 0)
end)

test("a held step on another grid does not set levels", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16); context.grid.plug(2, 16, 16)
  context.grid.press(1, 3, 2, 1)
  context.grid.press(2, 8, 2, 1)
  assert_equal(patterns[2][3], 15, "grid 1's held step keeps its level")
  assert_equal(patterns[2][8], 15, "grid 2's key toggles its step")
end)

test("level_for_position spreads the positions over the step levels", function()
  load_strata()
  local core = grid_core()
  assert_equal(core.level_for_position(16, 16), 15)
  assert_equal(core.level_for_position(1, 16), 1, "never below 1")
  assert_equal(core.level_for_position(8, 16), 8)
  assert_equal(core.level_for_position(1, 8), 2)
end)

test("a scene save needs a 0.5 s hold", function()
  local context = load_strata(); finish_startup(context)
  local scenes = local_value("scenes")
  local device = context.grid.plug(1, 16, 16); tap(context, 1, 15, 8)  -- page 3
  assert_equal(device:get_led(2, 3), 4, "save key idle")
  context.grid.press(1, 2, 3, 1)
  assert_equal(device:get_led(2, 3), 15, "a pending save lights at 15")
  context.clock.run_for(0.4)
  context.grid.press(1, 2, 3, 0)
  assert_true(not scenes[2].populated, "released early: nothing saved")
  assert_equal(device:get_led(2, 3), 4, "the release dims the key")
  context.grid.press(1, 2, 3, 1)
  context.clock.run_for(0.51)
  assert_true(scenes[2].populated, "held 0.5 s: saved")
  assert_equal(device:get_led(2, 3), 4, "no longer pending once saved")
  assert_equal(device:get_led(2, 1), 8, "row 1 shows the saved scene")
  context.grid.press(1, 2, 3, 0)
  -- the 128h's row 3 too
  local small = context.grid.plug(2, 16, 8); tap(context, 2, 7, 8)  -- page 3
  context.grid.press(2, 5, 3, 1)
  assert_equal(small:get_led(5, 3), 15)
  context.clock.run_for(0.51)
  assert_true(scenes[5].populated, "128h row 3 saves on a hold")
end)

test("removing a grid cancels its pending holds", function()
  local context = load_strata(); finish_startup(context)
  local scenes = local_value("scenes")
  context.grid.plug(1, 16, 16); tap(context, 1, 15, 8)
  context.grid.press(1, 2, 3, 1)
  context.grid.press(1, 4, 1, 1)   -- a held key with no hold
  assert_true(grid_core().hold_pending(1, 2, 3))
  grid_core().port_state(1).marker = true
  context.grid.unplug(1)
  context.clock.run_for(1)
  assert_true(not scenes[2].populated, "no save after the grid is removed")
  assert_equal(next(local_value("grid_held")[1] or {}), nil, "the port's held keys are forgotten")
  assert_true(not grid_core().hold_pending(1, 2, 3))
  assert_equal(grid_core().port_state(1).marker, nil, "the port's layout state is emptied")
  assert_equal(grid_core().page(1), 1, "a new grid on the port starts on page 1")
  -- a stray release after the removal changes nothing and errors nowhere
  grid_key(1, 2, 3, 0)
end)

test("existing_port_state reads a port's layout state without creating it", function()
  load_strata()
  assert_equal(grid_core().existing_port_state(3), nil, "no state on a port nothing wrote to")
  assert_equal(grid_core().existing_port_state(3), nil, "the read created none")
  local state = grid_core().port_state(3)
  assert_equal(grid_core().existing_port_state(3), state, "port_state's table once it exists")
end)

test("cleanup cancels pending holds", function()
  local context = load_strata(); finish_startup(context)
  local scenes = local_value("scenes")
  context.grid.plug(1, 16, 16); tap(context, 1, 15, 8)
  context.grid.press(1, 6, 3, 1)
  cleanup()
  context.clock.run_for(1)
  assert_true(not scenes[6].populated, "no save after cleanup")
  assert_equal(grid_core().held(1, 6, 3), nil, "held keys are forgotten")
end)

test("holds run once, release cancels them and consumed releases do nothing", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  context.grid.plug(1, 16, 16)
  local fired = 0
  context.grid.press(1, 9, 9, 1)
  assert_true(core.held(1, 9, 9) ~= nil, "a press is held")
  core.on_hold(1, 9, 9, 0.5, function() fired = fired + 1 end)
  context.clock.run_for(2)
  assert_equal(fired, 1, "the hold runs once")
  context.grid.press(1, 9, 9, 0)
  assert_equal(core.held(1, 9, 9), nil, "a release clears the key")
  context.grid.press(1, 9, 9, 1)
  core.on_hold(1, 9, 9, 0.5, function() fired = fired + 1 end)
  context.clock.run_for(0.2); context.grid.press(1, 9, 9, 0); context.clock.run_for(1)
  assert_equal(fired, 1, "a release cancels the hold")
  -- a consumed key's release never reaches the layout
  local releases = 0
  local layout = local_value("S").registry.grid_layouts["256"]
  local real_key = layout.key
  layout.key = function(port, x, y, z)
    if z == 0 then releases = releases + 1 end
    return real_key(port, x, y, z)
  end
  context.grid.press(1, 9, 9, 1); core.consume(1, 9, 9)
  assert_true(core.consumed(1, 9, 9))
  context.grid.press(1, 9, 9, 0)
  assert_equal(releases, 0, "the consumed release did nothing")
  assert_true(not core.consumed(1, 9, 9), "and is cleared")
  context.grid.press(1, 9, 9, 1); context.grid.press(1, 9, 9, 0)
  assert_equal(releases, 1, "other releases reach the layout")
  layout.key = real_key
end)

test("each grid keeps its own page", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  local patterns = local_value("patterns")
  local first = context.grid.plug(1, 16, 16)
  local second = context.grid.plug(2, 16, 16)
  tap(context, 1, 15, 8)
  assert_equal(core.page(1), 3); assert_equal(core.page(2), 1)
  tap(context, 2, 3, 1)
  assert_equal(patterns[1][3], 15, "a key on grid 2's row 1 toggles a step")
  assert_equal(first:get_led(15, 8), 15, "grid 1 shows page 3")
  assert_equal(second:get_led(13, 8), 15, "grid 2 shows page 1")
  assert_equal(second:get_led(15, 8), 2)
  assert_true(core.any_page(3) and core.any_page(1), "any_page sees both")
  assert_true(not core.any_page(2) and not core.any_page(4))
  context.grid.unplug(1)
  assert_true(not core.any_page(3), "a removed grid shows no page")
  core.set_page(2, 6); core.set_page(9, 2)
  assert_equal(core.page(2), 1, "out-of-range pages are ignored")
  assert_equal(core.page(9), 1, "out-of-range ports are ignored")
end)

test("a named, unsettled slot's source key is not shown as empty", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  load_buffer(2, "/tmp/slow.wav")
  context.set_time(util.time() + 1.1); context.polls.fire("bufferState", 1000)
  assert_equal(local_value("S").lib.buffers.status(2), "unsettled")
  assert_equal(core.source_level(1, 3), 4, "slot 2 (option 3) is named: not dimmed")
  assert_equal(core.source_level(1, 4), 2, "an empty slot (slot 3, option 4) is")
  assert_equal(core.record_level(2), 8, "its record key agrees: not empty")
  assert_equal(core.record_level(3), 2, "an empty slot's record key")
end)

test("source and slot helpers check bounds and give the 256's levels", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  core.source_key(2, 11); assert_equal(params:get("v2_source"), 1, "option 11 changes nothing")
  core.source_key(8, 2); core.source_key(0, 2)
  core.source_key(2, 3); assert_equal(params:get("v2_source"), 3, "option 3 is buffer 2")
  assert_equal(core.source_level(2, 3), 15, "selected")
  assert_equal(core.source_level(2, 1), 4, "other")
  assert_equal(core.source_level(2, 4), 2, "empty buffer")
  context.clear_engine_calls()
  core.record_key(9); core.record_key(0); core.clear_key(9)
  assert_equal(#context.engine_calls, 0, "out-of-range slots send nothing")
  assert_equal(core.record_level(1), 2, "empty slot")
  core.record_key(1); assert_equal(core.record_level(1), 15, "recording")
  load_buffer(2, "/tmp/a.wav"); assert_equal(core.record_level(2), 8, "holding audio")
  core.clear_key(2); assert_equal(context.calls_named("clearBuffer")[1].args[1], 1)
  assert_equal(core.CLEAR_LEVEL, 4)
end)

-- A key whose action redraws the grid too (scene_sequence_length's) still
-- paints each grid once per press (#161)
test("a sequence-length key repaints the grid once", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  -- each layout's scene page and the key that sets length 3
  local cases = {
    {cols = 16, rows = 16, page = 3, x = 5, y = 5},
    {cols = 16, rows = 8, page = 3, x = 3, y = 4},
    {cols = 8, rows = 16, page = 3, x = 4, y = 11},
  }
  for index, case in ipairs(cases) do
    local device = context.grid.plug(1, case.cols, case.rows)
    core.set_page(1, case.page)
    params:set("scene_sequence_length", 1)
    local before = device.refresh_count
    context.grid.press(1, case.x, case.y, 1)
    local name = case.cols .. "x" .. case.rows
    assert_equal(params:get("scene_sequence_length"), 3, name .. ": the key sets length 3")
    assert_equal(device.refresh_count - before, 1, name .. ": one repaint for the press")
    context.grid.press(1, case.x, case.y, 0)
    assert_equal(device.refresh_count - before, 2, name .. ": and one for the release")
    params:set("scene_sequence_length", 5)
    assert_equal(device.refresh_count - before, 3, name .. ": a change from PARAMS still repaints")
    context.grid.unplug(1)
  end
end)

-- An error in a layout's key handler still repaints and leaves later
-- redraws working (grid_key holds them only while it handles a key)
test("a key handler that fails still repaints, and later redraws work", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local layouts = local_value("S").registry.grid_layouts
  local layout = layouts["256"]
  local key = layout.key
  layout.key = function() grid_redraw(); error("broken key") end
  local before = device.refresh_count
  local ok, message = pcall(context.grid.press, 1, 1, 1, 1)
  layout.key = key
  assert_true(not ok and tostring(message):find("broken key", 1, true) ~= nil, "the error reaches the caller")
  assert_equal(device.refresh_count - before, 1, "the failed key still repaints once")
  grid_redraw()
  assert_equal(device.refresh_count - before, 2, "a redraw after it paints")
end)

test("an FX change redraws the grids only while one shows the FX faders", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  local wide = context.grid.plug(1, 16, 8)
  local tall = context.grid.plug(2, 8, 16)
  core.set_page(1, 4); core.set_page(2, 4)  -- their page 4: sources, freeze, slots (no FX)
  local function refreshes() return wide.refresh_count + tall.refresh_count end
  local before = refreshes()
  for _, id in ipairs({ "filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix" }) do
    params:delta(id, 1)
  end
  assert_equal(refreshes(), before, "a 16x8 and an 8x16 on page 4 show no FX: no redraw")
  local full = context.grid.plug(3, 16, 16)
  before = full.refresh_count
  params:delta("delay_mix", 1)
  assert_equal(full.refresh_count, before, "a 256 on page 1: no redraw")
  core.set_page(3, 4)
  params:delta("delay_mix", -1)
  assert_equal(full.refresh_count, before + 1, "a 256 on page 4 shows the faders: one redraw")
end)

test("a layout record says whether a position press selects the grid voice", function()
  local context = load_strata(); finish_startup(context)
  local layouts = local_value("S").registry.grid_layouts
  assert_equal(layouts["256"].selects_grid_voice, nil, "the 256's rows are one voice each")
  for _, name in ipairs({"128h", "128v", "64"}) do
    assert_equal(layouts[name].selects_grid_voice, true, name .. " selects the grid voice")
  end
  context.grid.plug(1, 16, 8)
  assert_equal(grid_core().layout_of(1), layouts["128h"], "a connected 128h's record")
  assert_equal(grid_core().layout_of(2), nil, "a port with no grid")
  context.grid.plug(3, 12, 12)
  assert_equal(grid_core().layout_of(3), nil, "a size with no layout")
  -- so a position press there selects no grid voice
  local S = local_value("S")
  S.buffers[1].seconds = 16
  params:set("v2_source", S.constants.SOURCE_SYNTH + 1)
  S.grid_voice_select = 6
  S.lib.positions.grid_key(3, 2, 5, 16, 1); S.lib.positions.grid_key(3, 2, 5, 16, 0)
  assert_equal(S.grid_voice_select, 6, "the grid voice is unchanged")
  -- the same press on the 128h (port 1) selects voice 2: the 12x12 ignored
  -- it for want of a layout
  S.lib.positions.grid_key(1, 2, 5, 16, 1); S.lib.positions.grid_key(1, 2, 5, 16, 0)
  assert_equal(S.grid_voice_select, 2, "a 128h's press selects the voice")
end)

test("a scene saved on a hold shows on the SCENES page on the next frame", function()
  local context = load_strata(); finish_startup(context)
  -- slot 2's box on the SCENES page (5x5, right of its number): its rect
  -- from the last draw
  local function slot_box(slot)
    local number
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == tostring(slot) and entry.y > 8 and entry.y < 46 then number = entry end
    end
    for _, rect in ipairs(context.screen.rects) do
      if number and rect.w == 5 and rect.h == 5 and rect.x > number.x and rect.y == number.y - 5 then return rect end
    end
  end
  h.show_page("SCENES")
  context.grid.plug(1, 16, 16); tap(context, 1, 15, 8)
  h.next_frame(context)
  assert_true(not slot_box(2).filled, "slot 2 starts empty")
  context.grid.press(1, 2, 3, 1)
  h.next_frame(context)
  local counter = h.count_screen_draws()
  context.clock.run_for(0.3)  -- under 0.5 s since the press, frames included
  assert_true(not local_value("scenes")[2].populated, "still pending")
  assert_equal(counter.screen, 0, "a pending hold draws nothing")
  context.clock.run_for(0.25)  -- the hold fires, then a frame
  counter.restore()
  assert_true(local_value("scenes")[2].populated, "held 0.5 s: saved")
  assert_equal(counter.screen, 1, "the save draws on a frame, once")
  assert_true(slot_box(2).filled, "slot 2's box is filled")
  assert_true(not slot_box(3).filled, "slot 3's is not")
  context.grid.press(1, 2, 3, 0)
end)

test("a third key sets only its own voice's held step", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 3, 1, 1)  -- voice 1 step 3
  context.grid.press(1, 6, 2, 1)  -- voice 2 step 6
  context.grid.press(1, 16, 1, 1)
  assert_equal(patterns[1][3], 15, "voice 1's held step gets column 16's level")
  context.grid.press(1, 16, 1, 0)
  context.grid.press(1, 1, 1, 1)
  assert_equal(patterns[1][3], 1, "voice 1's held step gets column 1's level")
  assert_equal(patterns[2][6], 15, "voice 2's held step keeps its level")
  assert_equal(patterns[1][16] + patterns[1][1], 0, "the level keys never toggled")
end)

test("step_key ignores voices, steps and positions out of range", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 3, 1, 1)  -- voice 1 step 3 held
  core.step_key(1, 5, 1, 1, 1.5, 5, 5, 16)
  core.step_key(1, 5, 1, 1, 1, 17, 5, 16)
  core.step_key(1, 5, 1, 1, 1, 0, 5, 16)
  core.step_key(1, 5, 1, 1, 1, 5, 17, 16)
  core.step_key(1, 5, 1, 1, 1, 5, 0, 16)
  core.step_key(1, 5, 1, 1, 8, 5, 5, 16)
  assert_equal(patterns[1][3], 15, "no out-of-range call set the held step's level")
  assert_equal(patterns[1][17], nil, "the pattern never grows")
  assert_equal(patterns[8], nil)
end)

test("hot-plugged grid and arc fire handlers once per event (I3)", function()
  local context = load_strata()
  context.grid.plug(3, 16, 16)
  local calls = 0
  local real_grid_key = grid_key
  grid_key = function(...) calls = calls + 1; return real_grid_key(...) end
  context.grid.press(3, 1, 1, 1)
  assert_equal(calls, 1, "grid_key runs once per press")
  context.grid.unplug(3)
  context.grid.plug(3, 16, 16)
  context.grid.press(3, 1, 2, 1)
  assert_equal(calls, 2, "replugged grid still runs grid_key once per press")
  grid_key = real_grid_key

  -- compared on the raw 0-1 position: the 0.01 step quantizes the value
  local density = params:lookup_param("master_density")
  context.arc.plug(1)
  local before = density.raw
  context.arc.turn(1, 1, 20)  -- one delta of 20 -> 20 ticks of the sweep
  assert_near(density.raw - before, 20 / local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, 1e-9, "a turn is handled once")
  context.arc.unplug(1)
  context.arc.plug(1)
  before = density.raw
  context.arc.turn(1, 1, 20)
  assert_near(density.raw - before, 20 / local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, 1e-9, "replugged arc handles a turn once")
end)

test("a grid can show page 5 and any_page(5) counts it", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  local core = grid_core()
  core.set_page(1, 5)
  assert_equal(core.page(1), 5)
  assert_true(core.any_page(5), "any_page counts page 5")
  assert_true(not core.any_page(4))
  core.set_page(1, 6)
  assert_equal(core.page(1), 5, "page 6 is ignored")
end)

-- #242: every whole-pattern change ends the voice's held step gesture, as
-- the 256's paste does (#114). On a 256 page 1, row 15 column v clears voice
-- v and column 8 + v randomizes it, once held 0.5 s (#443)
test("clear, randomize and a scene recall end a held step gesture, as a paste does", function()
  -- clear
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 3, 1, 1)  -- voice 1 step 3 held: on at 15
  context.grid.press(1, 1, 15, 1); context.clock.run_for(0.51); context.grid.press(1, 1, 15, 0)  -- clear voice 1
  context.grid.press(1, 9, 1, 1)
  assert_equal(patterns[1][3], 0, "clear: the held step takes no level in the cleared pattern")
  assert_equal(patterns[1][9], 15, "clear: the next step key toggles its own step")
  -- randomize
  context = load_strata(); finish_startup(context)
  patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 3, 1, 1)
  context.grid.press(1, 9, 15, 1); context.clock.run_for(0.51); context.grid.press(1, 9, 15, 0)  -- randomize voice 1
  local step_3, step_9 = patterns[1][3], patterns[1][9]
  context.grid.press(1, 9, 1, 1)
  assert_equal(patterns[1][3], step_3, "randomize: the held step keeps the level randomize gave it")
  assert_equal(patterns[1][9], step_9 == 0 and 15 or 0, "randomize: step 9 toggles from what randomize gave it")
  -- a scene recall
  context = load_strata(); finish_startup(context)
  patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  for step = 1, 16 do assert_equal(patterns[1][step], 0, "voice 1's pattern starts empty") end
  capture_scene(1)
  context.grid.press(1, 3, 1, 1)
  recall_scene(1, 0)
  context.grid.press(1, 9, 1, 1)
  assert_equal(patterns[1][3], 0, "recall: the held step takes no level in the recalled pattern")
  assert_equal(patterns[1][9], 15, "recall: the next step key toggles its own step")
end)

test("a scene saved on a grid hold flashes saved in the header", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  context.grid.plug(1, 16, 16); tap(context, 1, 15, 8)  -- page 3
  context.grid.press(1, 4, 3, 1)
  context.clock.run_for(0.3)
  context.grid.press(1, 4, 3, 0)
  assert_equal(S.lib.ui_flash.text("header"), nil, "a release at 0.3 s saves nothing")
  context.grid.press(1, 4, 3, 1)
  context.clock.run_for(0.6)
  assert_equal(S.lib.ui_flash.text("header"), "saved S4")
end)

-- SYSTEM > DEVICES moves a grid through update_devices() only, never
-- grid.add or grid.remove (#256)
test("a grid moved to another port in SYSTEM > DEVICES works once the menu closes", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 8)
  _menu.set_mode(true)
  context.grid.reassign(1, 2)
  _menu.set_mode(false)
  local grids = local_value("S").grids
  assert_equal(grids[1], nil, "port 1 is no longer attached")
  assert_equal(grids[2], grid.connect(2), "port 2 is attached")
  local before = patterns[1][1]
  tap(context, 2, 1, 1)
  assert_true(patterns[1][1] ~= before, "a step press on port 2 toggles voice 1 step 1")
  h.show_page("SETUP"); enc(2, 20); redraw()
  assert_true(h.screen_shows(context, "grid: 1 connected"), "SETUP counts the moved grid")
  -- another grid moved onto an attached port replaces its grid: the port
  -- starts over, as a grid plugged in does
  context.grid.plug(3, 16, 8)
  grid_core().set_page(2, 3)
  _menu.set_mode(true)
  context.grid.reassign(3, 2)
  _menu.set_mode(false)
  assert_equal(grids[3], nil, "port 3 is no longer attached")
  assert_equal(grid_core().page(2), 1, "port 2 starts on page 1 with the other grid")
end)

-- #441: one layout's error in a redraw spares the other grids and whoever
-- asked for the redraw (a voice toggle, the pattern clock, a source param)
test("a layout whose redraw fails spares the other grids and the caller, and prints once", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local wide = context.grid.plug(1, 16, 8)
  local full = context.grid.plug(2, 16, 16)
  local layout = S.registry.grid_layouts["128h"]
  local real_redraw = layout.redraw
  layout.redraw = function() error("broken redraw") end
  local lines = {}
  local real_print = print
  print = function(text) lines[#lines + 1] = tostring(text) end
  local ok, err = pcall(function()
    local wide_before, full_before = wide.refresh_count, full.refresh_count
    assert_true(pcall(grid_redraw), "grid_redraw returns")
    assert_equal(full.refresh_count - full_before, 1, "the 256 after it is repainted")
    assert_equal(wide.refresh_count - wide_before, 1, "the failing grid is still refreshed")
    assert_true(pcall(toggle_voice, 3), "toggle_voice does not raise")
    assert_true(S.voices[3].active, "voice 3 is on")
    assert_true(pcall(pattern_toggle), "pattern_toggle does not raise")
    assert_true(S.pattern_playing, "the pattern plays")
    context.clock.run_for(0.5)
    assert_true(S.pattern_playing, "its steps (each redraws) keep it playing")
    assert_true(pcall(params.set, params, "v1_source", 2), "a source change does not raise")
    full_before = full.refresh_count
    context.grid.press(2, 1, 16, 1); context.grid.press(2, 1, 16, 0)
    assert_equal(full.refresh_count - full_before, 2, "a key on the 256 repaints it")
    local failed = 0
    for _, line in ipairs(lines) do
      if line:find("strata: grid redraw failed: ", 1, true) == 1 then failed = failed + 1 end
    end
    assert_equal(failed, 1, "the same error prints once")
  end)
  print = real_print
  layout.redraw = real_redraw
  pattern_clock_stop()
  if not ok then error(err, 0) end
end)

-- #446: the sequencer's edits ask for no screen redraw; SEQ follows a grid
-- edit because grid_key (and row 15's hold) asks for one
test("SEQ draws a grid step press, a release and a 256's row 15 clear on the next frame", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  h.show_page("SEQ")
  context.grid.plug(1, 16, 16)
  h.next_frame(context)
  local counter = h.count_screen_draws()
  h.next_frame(context)
  assert_equal(counter.screen, 0, "an idle frame draws nothing")
  context.grid.press(1, 3, 1, 1)
  h.next_frame(context)
  assert_equal(patterns[1][3], 15, "the press toggled voice 1 step 3 on")
  assert_equal(counter.screen, 1, "the frame after the press draws once")
  context.grid.press(1, 3, 1, 0)
  h.next_frame(context)
  assert_equal(counter.screen, 2, "the frame after the release draws once")
  context.grid.press(1, 1, 15, 1)
  h.next_frame(context)
  assert_equal(counter.screen, 3, "the press of row 15's clear key draws (its LED)")
  context.clock.run_for(0.51)
  counter.restore()
  assert_equal(patterns[1][3], 0, "held half a second: voice 1's pattern is cleared")
  assert_equal(counter.screen, 4, "the clear draws on a frame, once")
  context.grid.press(1, 1, 15, 0)
end)

-- #447: the guards the notes describe, one test each
test("grid_key ignores a key outside the grid's size", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  for _, key in ipairs({{17, 1}, {0, 1}, {1, 17}, {1, 0}}) do
    grid_key(1, key[1], key[2], 1)
    assert_equal(grid_core().held(1, key[1], key[2]), nil, key[1] .. "," .. key[2] .. " is not held")
  end
  assert_equal(patterns[1][17], nil, "no step 17")
  assert_equal(next(local_value("grid_held")[1] or {}), nil, "no key is held on the port")
end)

test("a press with no release before it starts the key over", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  local patterns = local_value("patterns")
  local scenes = local_value("scenes")
  context.grid.plug(1, 16, 16); tap(context, 1, 15, 8)  -- page 3
  context.grid.press(1, 2, 3, 1)  -- scene 2's save hold
  core.set_page(1, 1)
  context.grid.press(1, 2, 3, 1)  -- again, no release seen: page 1's voice 3 step 2
  context.clock.run_for(1)
  assert_true(not scenes[2].populated, "the first press's hold was canceled")
  context.grid.press(1, 2, 3, 0)
  -- a consumed mark goes with the second press
  local releases = 0
  local layout = local_value("S").registry.grid_layouts["256"]
  local real_key = layout.key
  layout.key = function(port, x, y, z)
    if z == 0 then releases = releases + 1 end
    return real_key(port, x, y, z)
  end
  context.grid.press(1, 9, 9, 1); core.consume(1, 9, 9)
  context.grid.press(1, 9, 9, 1)
  context.grid.press(1, 9, 9, 0)
  layout.key = real_key
  assert_equal(releases, 1, "the release after the second press reaches the layout")
  -- a step entry goes with it: voice 1 step 3 held on page 1, pressed again
  -- on page 3 (a recall there), is no longer a held step on page 1
  context.grid.press(1, 3, 1, 1)
  assert_equal(patterns[1][3], 15, "voice 1 step 3 on")
  core.set_page(1, 3)
  context.grid.press(1, 3, 1, 1)
  core.set_page(1, 1)
  context.grid.press(1, 8, 1, 1)
  assert_equal(patterns[1][3], 15, "step 3 took no level")
  assert_equal(patterns[1][8], 15, "the key toggled its own step")
end)

test("a grid plugged into a port forgets the port's page, held keys and layout state", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  core.set_page(2, 3)
  core.port_state(2).marker = true
  local grid_held = local_value("grid_held")
  grid_held[2] = {[4] = {[4] = 1}}
  context.grid.plug(2, 16, 16)
  assert_equal(core.page(2), 1, "page 1")
  assert_equal(core.port_state(2).marker, nil, "no layout state")
  assert_equal(core.held(2, 4, 4), nil, "no held key")
end)

test("a grid moved in SYSTEM > DEVICES is repainted as the menu closes", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  _menu.set_mode(true)
  context.grid.reassign(1, 2)
  local before = device.refresh_count
  _menu.set_mode(false)
  assert_equal(device.refresh_count - before, 1, "repainted once on port 2")
  assert_true(device:get_led(13, 8) == 15, "it shows page 1")
end)

test("select_grid_voice refuses a voice outside 1-7", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  select_grid_voice(3)
  select_grid_voice(0); select_grid_voice(8)
  assert_equal(S.grid_voice_select, 3, "unchanged")
end)

test("a range just past 0 still has its zero column inside 2-15", function()
  load_strata()
  params:add_control("zz_low_zero", "low zero", controlspec.new(-0.01, 1, "lin", 0, 0))
  params:add_control("zz_high_zero", "high zero", controlspec.new(-1, 0.01, "lin", 0, 0))
  assert_equal(fader_zero_column("zz_low_zero"), 2, "column 2, never 1")
  assert_equal(fader_zero_column("zz_high_zero"), 15, "column 15, never 16")
end)

-- #452: the scene keys' levels, one rule for every layout with a scenes page
local function recall_levels(core, count)
  local levels = {}
  for slot = 1, count do levels[slot] = core.scene_recall_level(slot) end
  return table.concat(levels, " ")
end

-- #303: the recall levels of scenes 1-5 while the sequencer runs through the
-- clock: scenes 1-3 saved, slot 4 empty (the sequencer skips it, #513)
test("scene_recall_level: 8 saved, 2 empty, 10 the running sequencer's next slot, 15 the current scene (#303)", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  capture_scene(1); capture_scene(2); capture_scene(3)
  params:set("scene_sequence_length", 4)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  assert_equal(recall_levels(core, 5), "8 8 8 2 2", "stopped: saved scenes at 8, empty ones at 2")
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(1, 0.001)
  assert_equal(recall_levels(core, 5), "15 10 8 2 2", "1 s: scene 1 playing, scene 2 next at 10")
  context.clock.run_for(4, 0.001)
  assert_equal(recall_levels(core, 5), "8 15 10 2 2", "5 s: scene 2 playing, scene 3 next")
  context.clock.run_for(4, 0.001)
  assert_equal(recall_levels(core, 5), "10 8 15 2 2", "9 s: scene 3 playing, scene 1 next (past empty slot 4)")
  context.clock.run_for(4, 0.001)
  assert_equal(recall_levels(core, 5), "15 10 8 2 2", "13 s: scene 1 again, scene 2 next")
  context.clock.run_for(4, 0.001)
  assert_equal(recall_levels(core, 5), "8 15 10 2 2", "17 s: scene 2, scene 3 next")
  params:set("scene_sequencer_enabled", 0)
  assert_equal(recall_levels(core, 5), "8 15 8 2 2", "a stopped sequencer lights no next scene")
  for _, slot in ipairs({0, 9, 1.5}) do
    assert_equal(core.scene_recall_level(slot), 0, "slot " .. slot .. " is no scene")
    assert_equal(core.scene_fade_level(slot), 0)
  end
end)

-- #303: the first recall waits for the next scheduler tick; until then the
-- slot recalled first is at 10: the first that holds a scene, since an empty
-- slot is skipped (#513)
test("scene_recall_level from the sequencer's start: the slot it recalls first (#303)", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  capture_scene(1); capture_scene(2); capture_scene(3)
  params:set("scene_sequence_length", 3)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  assert_equal(local_value("S").current_scene, 0, "started: nothing recalled yet")
  assert_equal(recall_levels(core, 4), "10 8 8 2", "before the first recall: scene 1, recalled first, at 10")
  context.clock.run_for(1, 0.001)
  assert_equal(recall_levels(core, 4), "15 10 8 2", "scene 1 playing, scene 2 next")
  params:set("scene_sequencer_enabled", 0)
  context = load_strata(); finish_startup(context)
  core = grid_core()
  capture_scene(2); capture_scene(3)
  params:set("scene_sequence_length", 3)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  assert_equal(recall_levels(core, 4), "2 10 8 2", "slot 1 is empty: scene 2, recalled first, at 10 (#513)")
  context.clock.run_for(1, 0.001)
  assert_equal(recall_levels(core, 4), "2 15 10 2", "scene 2 playing, scene 3 next")
  params:set("scene_sequencer_enabled", 0)
end)

-- #254: a 2 s fade has 20 steps of 0.1 s; the first runs inside the recall
test("scene_recall_level blinks the scene a fade goes to; the fade keys are 6 saved, 2 empty (#254)", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  capture_scene(1); capture_scene(2)
  assert_equal(core.scene_fade_level(1), 6, "a saved scene's fade key")
  assert_equal(core.scene_fade_level(3), 2, "an empty one's")
  recall_scene(1, 0); recall_scene(2, 2)
  context.clock.run_for(0.1)                                    -- step 2
  assert_equal(core.scene_recall_level(2), 8, "step 2: the target at its saved level")
  context.clock.run_for(0.1)                                    -- step 3
  assert_equal(core.scene_recall_level(2), 15, "step 3: the target at 15")
end)

-- #254: the sequencer's fading target blinks between 15 and its saved 8;
-- the scene it recalls next stays at 10 (#303)
test("scene_recall_level: the sequencer's fading target blinks, the next scene steady at 10", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  capture_scene(1); capture_scene(2); capture_scene(3)
  params:set("scene_sequence_length", 3)
  params:set("scene_transition_time", 2); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(0.05)                                   -- the sequencer recalls scene 1: step 1
  local S = local_value("S")
  assert_equal(S.lib.scenes.fading_to(), 1, "the sequencer fades to scene 1")
  assert_equal(recall_levels(core, 2), "15 10", "step 1: the target at 15, scene 2 next at 10")
  context.clock.run_for(0.1)                                    -- step 2
  assert_equal(recall_levels(core, 2), "8 10", "step 2: the target at its saved 8, scene 2 still 10")
  context.clock.run_for(0.1)                                    -- step 3
  assert_equal(core.scene_recall_level(1), 15, "step 3: at 15 again")
  context.clock.run_for(2)                                      -- the fade lands
  assert_equal(S.lib.scenes.fading_to(), nil, "the fade landed")
  assert_equal(core.scene_recall_level(1), 15, "the landed scene is steady at 15")
  params:set("scene_sequencer_enabled", 0)
end)

test("scene_save_level: 15 while the key's save hold is pending, 4 otherwise", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  context.grid.plug(1, 16, 16); tap(context, 1, 15, 8)  -- page 3
  assert_equal(core.scene_save_level(1, 2, 3), 4, "idle")
  context.grid.press(1, 2, 3, 1)
  assert_equal(core.scene_save_level(1, 2, 3), 15, "pending")
  assert_equal(core.scene_save_level(2, 2, 3), 4, "another port's key is idle")
  context.grid.press(1, 2, 3, 0)
  assert_equal(core.scene_save_level(1, 2, 3), 4, "released")
end)

-- #526: the same state lights the same on every grid: the four layouts on
-- ports 1-4, voices 1 and 2 (from the start) and 3 running, voice 4
-- stopped, voice 3 locked, grid voice 2
test("every layout lights voice, play, lock, page and pick keys at the core's shared levels", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  local S = local_value("S")
  local full = context.grid.plug(1, 16, 16)
  local wide = context.grid.plug(2, 16, 8)
  local tall = context.grid.plug(3, 8, 16)
  local small = context.grid.plug(4, 8, 8)
  toggle_voice(3); toggle_lock(3); select_grid_voice(2)
  grid_redraw()
  local levels = core.LEVELS
  local function same(what, expected, leds)
    for name, level in pairs(leds) do assert_equal(level, expected, what .. " on the " .. name) end
  end
  same("a stopped voice's key", levels.voice_stopped,
    {["256"] = full:get_led(12, 14), ["128h"] = wide:get_led(12, 8), ["128v"] = tall:get_led(8, 4), ["64"] = small:get_led(5, 8)})
  same("a running voice's key", levels.voice_running,
    {["256"] = full:get_led(11, 14), ["128h"] = wide:get_led(11, 8), ["128v"] = tall:get_led(8, 3), ["64"] = small:get_led(4, 8)})
  same("a stopped play key", levels.stopped, {["256"] = full:get_led(1, 8), ["128h"] = wide:get_led(1, 8), ["128v"] = tall:get_led(8, 9)})
  same("an idle page key", levels.page_other, {["256"] = full:get_led(14, 8), ["128h"] = wide:get_led(6, 8)})
  same("the shown page's key", levels.page_shown, {["256"] = full:get_led(13, 8), ["128h"] = wide:get_led(5, 8)})
  same("the grid voice's pick key", levels.picked,
    {["256"] = full:get_led(2, 14), ["128v"] = tall:get_led(8, 11)})
  same("another voice's pick key", levels.unpicked,
    {["256"] = full:get_led(1, 14), ["128v"] = tall:get_led(8, 10)})
  same("a lock key", levels.locked, {["256"] = full:get_led(3, 16)})
  same("an unlocked key", levels.unlocked, {["256"] = full:get_led(1, 16)})
  -- the 16x8's and 8x16's pick and lock keys are on their faders pages
  core.set_page(2, 2); core.set_page(3, 2)
  grid_redraw()
  same("the grid voice's pick key", levels.picked, {["128h"] = wide:get_led(2, 6)})
  same("another voice's pick key", levels.unpicked, {["128h"] = wide:get_led(1, 6)})
  same("a lock key", levels.locked, {["128h"] = wide:get_led(3, 7), ["128v"] = tall:get_led(7, 12)})
  same("an unlocked key", levels.unlocked, {["128h"] = wide:get_led(1, 7), ["128v"] = tall:get_led(7, 10)})
  same("the shown fader page's key", levels.picked, {["128h"] = wide:get_led(1, 5), ["128v"] = tall:get_led(5, 1)})
  same("another fader page's key", levels.unpicked, {["128h"] = wide:get_led(2, 5), ["128v"] = tall:get_led(5, 2)})
  assert_equal(core.voice_level(3), levels.voice_running, "voice_level reads the voice")
  assert_equal(core.voice_level(4), levels.voice_stopped)
  assert_equal(core.lock_level(3), levels.locked, "lock_level reads the lock")
  assert_equal(core.lock_level(1), levels.unlocked)
  assert_equal(core.play_level(), levels.stopped, "play_level reads the patterns")
  assert_true(levels.voice_stopped ~= levels.voice_running and levels.page_other ~= levels.page_shown
    and levels.picked ~= levels.unpicked and levels.locked ~= levels.unlocked, "each pair is two levels")
  S.grid_voice_select = 1
end)

-- #324: the drift tick redraws a faders page only when a fader it shows
-- moved (a param set anywhere), never on every tick
test("the faders follow a param set off the grid within a tick, and idle ticks repaint nothing", function()
  local cases = {
    {cols = 16, rows = 16, before = {5, 9}, after = {1, 9}},   -- row 9, the first fader
    {cols = 16, rows = 8, before = {5, 1}, after = {1, 1}},    -- row 1
    {cols = 8, rows = 16, before = {1, 12}, after = {1, 16}},  -- column 1, upright
  }
  for _, case in ipairs(cases) do
    local name = case.cols .. "x" .. case.rows
    local context = load_strata(); finish_startup(context)
    local device = context.grid.plug(1, case.cols, case.rows)
    grid_core().set_page(1, 2)
    select_grid_voice(3)  -- stopped: nothing of it drifts
    grid_redraw()
    drift_update()  -- the first look
    assert_equal(device:get_led(case.before[1], case.before[2]), 15, name .. ": v3_freq's default")
    local spec = params:lookup_param("v3_freq").controlspec
    params:set("v3_freq", spec.minval)
    drift_update()
    assert_equal(device:get_led(case.after[1], case.after[2]), 15, name .. ": the tick moved the fader to the minimum")
    local before = device.refresh_count
    for _ = 1, 10 do drift_update() end
    assert_equal(device.refresh_count - before, 0, name .. ": ten idle ticks repaint nothing")
  end
end)

-- #451: a grid page outside the layouts is named (S.constants.GRID_PAGES),
-- never a bare number that a renumbered page would leave behind
test("no any_page call outside lib/grid/ names its page with a bare number", function()
  local found = {}
  for _, source in ipairs(h.read_lua_sources()) do
    if source.path:sub(1, #"lib/grid/") ~= "lib/grid/" then
      local line_number = 0
      for line in (source.text .. "\n"):gmatch("([^\n]*)\n") do
        line_number = line_number + 1
        local code = line:gsub("%-%-.*$", "")
        if code:find("any_page%(%s*%d") then found[#found + 1] = source.path .. ":" .. line_number end
      end
    end
  end
  assert_equal(table.concat(found, ", "), "", "bare page numbers")
end)

-- #468: norns' SLEEP runs only cleanup() before it shuts down, so a key in
-- those seconds must reach nothing of Strata's
test("after cleanup no grid, arc or MIDI handler of Strata's is left", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local device = context.grid.plug(1, 16, 16)
  context.arc.plug(1)
  context.midi.plug(1, "keys")
  local own = {grid_add = grid.add, grid_remove = grid.remove, arc_add = arc.add, arc_remove = arc.remove,
    midi_add = midi.add, midi_remove = midi.remove}
  local function lit(led_device)
    local sum = 0
    for x = 1, 16 do
      for y = 1, 16 do sum = sum + led_device:get_led(x, y) end
    end
    return sum
  end
  cleanup()
  assert_equal(lit(device), 0, "the grid is dark")
  context.clear_engine_calls()
  local before = device.refresh_count
  tap(context, 1, 12, 14)  -- voice 4's on/off key on page 1
  tap(context, 1, 3, 1)    -- a step
  assert_equal(lit(device), 0, "a press after cleanup lights nothing")
  assert_equal(device.refresh_count, before, "and repaints nothing")
  assert_equal(#context.engine_calls, 0, "and sends nothing")
  assert_true(not S.voices[4].active, "voice 4 stays off")
  assert_equal(S.grids[1].key, nil, "the vport's key handler is cleared")
  assert_equal(S.arc_device.delta, nil, "the arc's delta handler is cleared")
  assert_equal(S.arc_device.key, nil, "and its key handler")
  for name, fn in pairs(own) do
    local kind, event = name:match("^(%a+)_(%a+)$")
    assert_true(_G[kind][event] ~= fn, kind .. "." .. event .. " is no longer Strata's")
  end
  context.grid.plug(2, 16, 16)
  assert_equal(S.grids[2], nil, "a grid plugged after cleanup is not attached")
  assert_equal(midi.connect(1).event, nil, "the MIDI vport's handler is cleared")
  context.midi.plug(2, "pads")
  assert_equal(midi.connect(1).event, nil, "a MIDI device plugged after cleanup attaches nothing")
end)

-- #323: a monome 128 reports 16x8 until a script turns it; a port's
-- rotation setting calls norns' Grid:rotation and the port starts over
test("a port's rotation turns its 16x8 into the 8x16 layout on page 1 with no held keys, and back", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  local S = local_value("S")
  local device = context.grid.plug(1, 16, 8)
  assert_equal(device.rotation_value, 0, "attached at rotation 0")
  core.set_page(1, 3)
  context.grid.press(1, 4, 1, 1)
  core.port_state(1).marker = true
  assert_equal(core.set_rotation(1, 1), true, "set")
  assert_equal(core.rotation(1), 1)
  assert_equal(device.rotation_value, 1, "norns' Grid:rotation(1)")
  assert_equal(grid.connect(1).cols .. "x" .. grid.connect(1).rows, "8x16", "the vport reports 8x16")
  assert_equal(core.layout_of(1), S.registry.grid_layouts["128v"], "the 8x16 layout")
  assert_equal(core.page(1), 1, "on page 1")
  assert_equal(core.held(1, 4, 1), nil, "no held key")
  assert_equal(core.existing_port_state(1), nil, "no layout state")
  assert_equal(device:get_led(8, 8), S.lib.grid_layout_128v.LAYOUT.page_levels[1], "drawn as the 8x16 on page 1")
  context.grid.press(1, 4, 1, 0)  -- the stray release of the key held before
  local patterns = local_value("patterns")
  tap(context, 1, 2, 5)
  assert_equal(patterns[2][5], 15, "(2,5) is voice 2 step 5 now")
  assert_equal(core.set_rotation(1, 0), true)
  assert_equal(grid.connect(1).cols .. "x" .. grid.connect(1).rows, "16x8", "back to 16x8")
  assert_equal(core.layout_of(1), S.registry.grid_layouts["128h"])
  for _, bad in ipairs({{1, 4}, {1, -1}, {1, 1.5}, {0, 1}, {5, 1}, {1, "1"}}) do
    assert_equal(core.set_rotation(bad[1], bad[2]), false, "refused: " .. tostring(bad[1]) .. ", " .. tostring(bad[2]))
  end
  assert_equal(core.rotation(1), 0, "unchanged")
  assert_equal(device.rotation_value, 0)
end)

test("a port's rotation is kept in grids.data and applied at start and to a grid plugged in", function()
  local subdir = "grid_rotation_kept"
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local core = grid_core()
  assert_equal(core.rotation(2), 0, "0 with no file")
  assert_equal(core.set_rotation(2, 3), true)
  local value = local_value("S").lib.data_files.read(context.data_dir .. "strata/grids.data")
  assert_equal(type(value), "table", "grids.data holds the settings")
  -- the next start: a grid on port 2 before init, and one plugged later
  local early
  context = load_strata({ data_subdir = subdir, before_init = function(c) early = c.grid.plug(2, 16, 8) end })
  finish_startup(context)
  core = grid_core()
  assert_equal(core.rotation(2), 3, "read back")
  assert_equal(early.rotation_value, 3, "applied to the grid there at start")
  assert_equal(grid.connect(2).cols, 8, "which reports 8x16")
  assert_equal(core.layout_of(2), local_value("S").registry.grid_layouts["128v"])
  context.grid.unplug(2)
  local later = context.grid.plug(2, 16, 8)
  assert_equal(later.rotation_value, 3, "applied to a grid plugged in")
  local other = context.grid.plug(3, 16, 8)
  assert_equal(other.rotation_value, 0, "another port keeps its own")
end)

test("a grids.data that is not Strata's settings reads as rotation 0 and is never run", function()
  -- text, or a value written in tab.save's layout
  local cases = {
    "return {", "ran_grids_data = true return {}", {version = 9, rotation = {1, 1, 1, 1}},
    {version = 1, rotation = {7, "1", 1.5, -1}}, {version = 1, rotation = 2},
  }
  local function write_grids_data(case)
    return function(c)
      os.execute("mkdir -p '" .. c.data_dir .. "strata'")
      local text = type(case) == "string" and case or local_value("S").lib.data_files.encode(case)
      h.write_text(c.data_dir .. "strata/grids.data", text)
    end
  end
  for index, case in ipairs(cases) do
    local context = load_strata({ before_init = write_grids_data(case) })
    finish_startup(context)
    for port = 1, 4 do assert_equal(grid_core().rotation(port), 0, "case " .. index .. " port " .. port) end
  end
  assert_equal(rawget(_G, "ran_grids_data"), nil, "the file was never run")
  -- a version 1 file's valid entries are kept, the others read as 0
  local context = load_strata({ before_init = write_grids_data({version = 1, rotation = {3, 9, 1}}) })
  finish_startup(context)
  local core = grid_core()
  assert_equal(core.rotation(1) .. core.rotation(2) .. core.rotation(3) .. core.rotation(4), "3010")
end)

test("a rotation that cannot be written is not set", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  local device = context.grid.plug(1, 16, 8)
  local path = context.data_dir .. "strata/grids.data"
  os.execute("mkdir -p '" .. path .. ".part/inside'")  -- the .part is a folder: the write fails
  assert_equal(core.set_rotation(1, 1), false, "not set")
  assert_equal(core.rotation(1), 0, "the old value")
  assert_equal(device.rotation_value, 0, "the grid not turned")
end)

-- #323's comment: a rotation made outside Strata (maiden) changes the size
-- under an attached port with no add or remove; the port starts over
test("a grid whose size changes under its port starts on page 1 with no held keys", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  local device = context.grid.plug(1, 16, 8)
  core.set_page(1, 3)
  context.grid.press(1, 4, 1, 1)
  grid.connect(1):rotation(1)  -- not through Strata
  grid_redraw()
  assert_equal(core.page(1), 1, "page 1")
  assert_equal(core.held(1, 4, 1), nil, "no held key")
  assert_equal(device:get_led(8, 8), local_value("S").lib.grid_layout_128v.LAYOUT.page_levels[1], "the 8x16 drawn")
end)

test("a grid moved in SYSTEM > DEVICES cancels the old port's pending holds", function()
  local context = load_strata(); finish_startup(context)
  local scenes = local_value("scenes")
  context.grid.plug(1, 16, 16); tap(context, 1, 15, 8)  -- page 3
  context.grid.press(1, 2, 3, 1)
  assert_true(grid_core().hold_pending(1, 2, 3), "a scene save is pending on port 1")
  _menu.set_mode(true)
  context.grid.reassign(1, 2)
  _menu.set_mode(false)
  assert_true(not grid_core().hold_pending(1, 2, 3), "port 1's hold is canceled")
  context.clock.run_for(1)
  assert_true(not scenes[2].populated, "no scene saved")
end)

end

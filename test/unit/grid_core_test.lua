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

-- The brief's "two steps held" case cannot arise: a second key of the voice
-- always sets a level. The latest held step is the one still held after the
-- earlier one's release
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
  context.arc.turn(1, 1, 20)  -- one delta of 20 -> 20/512 of the range
  assert_near(density.raw - before, 20 / 512, 1e-9, "a turn is handled once")
  context.arc.unplug(1)
  context.arc.plug(1)
  before = density.raw
  context.arc.turn(1, 1, 20)
  assert_near(density.raw - before, 20 / 512, 1e-9, "replugged arc handles a turn once")
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
-- v and column 8 + v randomizes it
test("clear, randomize and a scene recall end a held step gesture, as a paste does", function()
  -- clear
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 3, 1, 1)  -- voice 1 step 3 held: on at 15
  tap(context, 1, 1, 15)          -- clear voice 1
  context.grid.press(1, 9, 1, 1)
  assert_equal(patterns[1][3], 0, "clear: the held step takes no level in the cleared pattern")
  assert_equal(patterns[1][9], 15, "clear: the next step key toggles its own step")
  -- randomize
  context = load_strata(); finish_startup(context)
  patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 3, 1, 1)
  tap(context, 1, 9, 15)          -- randomize voice 1
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

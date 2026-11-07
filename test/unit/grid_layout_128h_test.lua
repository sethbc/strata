-- test/unit/grid_layout_128h_test.lua
-- The 16x8 grid layout (lib/grid/layout_128h.lua)
-- Run alone: lua test/run.lua grid_layout_128h

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function tap(context, port, x, y)
  context.grid.press(port, x, y, 1); context.grid.press(port, x, y, 0)
end

local function grid_core() return local_value("S").lib.grid_core end

local function pattern_sum(patterns)
  local sum = 0
  for voice_idx = 1, #patterns do
    for step = 1, #patterns[voice_idx] do sum = sum + patterns[voice_idx][step] end
  end
  return sum
end

test("every 128h grid key on every page runs without error", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 8)
  for page_column = 5, 8 do
    for y = 1, 8 do
      for x = 1, 16 do
        tap(context, 1, page_column, 8)
        context.grid.press(1, x, y, 1)
        context.grid.press(1, x, y, 0)
        context.clock.advance()
      end
    end
  end
  assert_true(device.refresh_count > 0, "128h grid was redrawn")
end)

test("grid_redraw draws the 128h layout (I2), on a hot-plugged grid too (I3)", function()
  local context = load_strata()
  local device = context.grid.plug(2, 16, 8)
  local refreshes = device.refresh_count
  grid_redraw()
  assert_equal(device.refresh_count, refreshes + 1, "128h redraw reaches a hot-plugged grid")
  -- voice 1 is running after init: its status LED must be lit
  local lit = false
  for x = 1, 16 do
    for y = 1, 8 do
      if device:get_led(x, y) >= 12 then lit = true end
    end
  end
  assert_true(lit, "128h layout drew something")
end)

test("play/stop columns 1-4 on row 8 all light with the state (16x8)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 8)
  for x = 1, 4 do
    assert_equal(device:get_led(x, 8), 4, "8 rows: play column " .. x .. " dim when stopped")
  end
  context.grid.press(1, 4, 8, 1)  -- column 4 starts the pattern
  assert_true(local_value("pattern_playing"), "column 4 plays")
  for x = 1, 4 do
    assert_equal(device:get_led(x, 8), 15, "8 rows: play column " .. x .. " lit while playing")
  end
  context.grid.press(1, 3, 8, 1)  -- column 3 stops it
  for x = 1, 4 do
    assert_equal(device:get_led(x, 8), 4, "8 rows: play column " .. x .. " dim after stop")
  end
end)

test("128h row 8 columns 5-8 pick pages 1-4 and light the shown one", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 8)
  for page = 1, 4 do
    tap(context, 1, 4 + page, 8)
    assert_equal(grid_core().page(1), page, "column " .. (4 + page) .. " shows page " .. page)
    for column = 5, 8 do
      assert_equal(device:get_led(column, 8), column - 4 == page and 15 or 4,
        "page " .. page .. ": row 8 column " .. column)
    end
  end
end)

test("128h page 2: four faders, the page selector, voice select and lock", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  local frozen = local_value("frozen")
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 6, 8)  -- page 2
  local before = pattern_sum(patterns)

  -- rows 1-4: faders 1-4 of voice 1's fader page 1
  local ids = fader_param_ids(1)
  tap(context, 1, 16, 1)
  assert_equal(fader_position(ids[1]), 16, "column 16 sets fader 1 to its maximum")
  local _, max_value = param_range(ids[1])
  assert_near(params:get(ids[1]), max_value, 1e-6, "fader 1 at the maximum")
  assert_equal(device:get_led(16, 1), 15, "fader 1 shows its value at column 16")
  assert_equal(device:get_led(15, 1), 8, "the bar below the value")
  tap(context, 1, 1, 2)
  assert_equal(fader_position(ids[2]), 1, "column 1 sets fader 2 to its minimum")
  tap(context, 1, 8, 3)
  assert_equal(fader_position(ids[3]), 8, "column 8 on fader 3")
  assert_equal(device:get_led(8, 3), 15, "value column bright")
  assert_equal(device:get_led(7, 3), 8, "bar below the value")
  assert_equal(device:get_led(9, 3), 0, "nothing above the value")
  tap(context, 1, 5, 4)
  assert_equal(fader_position(ids[4]), 5, "row 4 is fader 4")
  assert_equal(pattern_sum(patterns), before, "rows 1-7 never toggle steps on page 2")

  -- row 5: the fader page selector, only up to fader_page_count
  local pages = fader_page_count(1)
  for x = 1, 16 do
    local expected = x == 1 and 15 or (x <= pages and 4 or 0)
    assert_equal(device:get_led(x, 5), expected, "row 5 column " .. x)
  end
  tap(context, 1, 3, 5)
  assert_equal(local_value("param_page"), 3, "row 5 column 3 picks fader page 3")
  assert_equal(device:get_led(3, 5), 15, "page 3 lit")
  assert_equal(device:get_led(1, 5), 4, "page 1 dim")
  tap(context, 1, 16, 2)
  assert_equal(fader_position(ids[10]), 16, "row 2 on fader page 3 is fader 10")
  tap(context, 1, pages + 1, 5)
  assert_equal(local_value("param_page"), 3, "a column past the last fader page does nothing")

  -- row 6, columns 1-7: voice select (selected 15, others 4)
  tap(context, 1, 2, 6)
  assert_equal(local_value("grid_voice_select"), 2, "row 6 column 2 selects voice 2")
  for x = 1, 16 do
    local expected = x == 2 and 15 or (x <= 7 and 4 or 0)
    assert_equal(device:get_led(x, 6), expected, "row 6 column " .. x)
  end
  local voice2_ids = fader_param_ids(2)
  local fader_index = (local_value("param_page") - 1) * 4 + 1
  tap(context, 1, 1, 1)
  assert_equal(fader_position(voice2_ids[fader_index]), 1, "the faders follow the selected voice")
  tap(context, 1, 8, 6)
  assert_equal(local_value("grid_voice_select"), 2, "row 6 column 8 does nothing")

  -- row 7, columns 1-7: lock (12 locked, 2 not)
  tap(context, 1, 3, 7)
  assert_true(frozen[3], "row 7 column 3 locks voice 3")
  for x = 1, 16 do
    local expected = x == 3 and 12 or (x <= 7 and 2 or 0)
    assert_equal(device:get_led(x, 7), expected, "row 7 column " .. x)
  end
  tap(context, 1, 3, 7)
  assert_true(not frozen[3], "a second press unlocks")
  tap(context, 1, 9, 7)
  for i = 1, 7 do assert_true(not frozen[i], "row 7 column 9 locks nothing") end
  assert_equal(pattern_sum(patterns), before, "no page 2 key toggled a step")
end)

test("128h column 16 of row 8 cycles the voice and page 2 shows it", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 16, 8)
  assert_equal(local_value("grid_voice_select"), 2, "column 16 selects the next voice")
  tap(context, 1, 6, 8)  -- page 2
  assert_equal(device:get_led(2, 6), 15, "page 2 shows voice 2 selected")
  assert_equal(device:get_led(1, 6), 4)
  local ids = fader_param_ids(2)
  assert_equal(device:get_led(fader_position(ids[1]), 1), 15, "row 1 shows voice 2's first fader")
  for _ = 1, 6 do tap(context, 1, 16, 8) end
  assert_equal(local_value("grid_voice_select"), 1, "the cycle wraps from voice 7 to voice 1")
  assert_equal(device:get_led(1, 6), 15, "page 2 follows the cycle")
end)

test("128h page 4 sets sources and records and clears slots", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 8, 8)  -- page 4
  assert_equal(grid_core().page(1), 4, "row 8 column 8 shows page 4")
  local before = pattern_sum(patterns)

  -- rows 1-7, columns 1-10: each voice's source
  tap(context, 1, 3, 2)
  assert_equal(params:get("v2_source"), 3, "row 2 column 3: voice 2 reads buf 2")
  tap(context, 1, 10, 7)
  assert_equal(params:get("v7_source"), 10, "row 7 column 10: voice 7 reads the input")
  assert_equal(pattern_sum(patterns), before, "source keys never toggle steps")

  -- rows 1-2, columns 13-16: record slots 1-4 and 5-8
  context.clear_engine_calls()
  tap(context, 1, 13, 1)
  assert_equal(context.calls_named("recordBuffer")[1].args[1], 0, "(13,1) records slot 1")
  tap(context, 1, 16, 2)
  assert_equal(context.calls_named("recordBuffer")[2].args[1], 7, "(16,2) records slot 8")
  assert_equal(device:get_led(13, 1), 15, "slot 1 recording")
  assert_equal(device:get_led(16, 2), 15, "slot 8 recording")

  -- rows 3-4, columns 13-16: clear slots 1-4 and 5-8
  tap(context, 1, 14, 3)
  assert_equal(context.calls_named("clearBuffer")[1].args[1], 1, "(14,3) clears slot 2")
  tap(context, 1, 15, 4)
  assert_equal(context.calls_named("clearBuffer")[2].args[1], 6, "(15,4) clears slot 7")

  -- columns 11-12 and rows 5-7 of columns 13-16 do nothing
  context.clear_engine_calls()
  for y = 1, 7 do
    for x = 11, 12 do tap(context, 1, x, y) end
  end
  for y = 5, 7 do
    for x = 13, 16 do tap(context, 1, x, y) end
  end
  assert_equal(#context.engine_calls, 0, "keys outside the source and slot blocks send nothing")
end)

test("128h page 4 LEDs come from source_level, record_level and CLEAR_LEVEL", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 8, 8)  -- page 4
  load_buffer(2, "/tmp/a.wav")                                    -- slot 2 holds audio
  params:set("record_duration", 2); params:set("buf6_record", 1)  -- slot 6 records
  params:set("v1_source", 3)                                      -- voice 1 on buf 2
  params:set("v4_source", 9)                                      -- voice 4 on an empty buf 8
  for voice_idx = 1, 7 do
    for x = 1, 10 do
      assert_equal(device:get_led(x, voice_idx), core.source_level(voice_idx, x),
        "voice " .. voice_idx .. " source column " .. x)
    end
    for x = 11, 12 do assert_equal(device:get_led(x, voice_idx), 0, "columns 11-12 dark") end
  end
  assert_equal(device:get_led(9, 4), 15, "the selected empty buffer lights 15")
  for slot = 1, 8 do
    local x = 12 + (slot - 1) % 4 + 1
    local record_row = slot <= 4 and 1 or 2
    assert_equal(device:get_led(x, record_row), core.record_level(slot), "record slot " .. slot)
    assert_equal(device:get_led(x, record_row + 2), core.CLEAR_LEVEL, "clear slot " .. slot)
  end
  assert_equal(device:get_led(14, 1), 8, "slot 2 holding audio")
  assert_equal(device:get_led(14, 2), 15, "slot 6 recording")
  assert_equal(device:get_led(13, 1), 2, "slot 1 empty")
  for y = 5, 7 do
    for x = 13, 16 do assert_equal(device:get_led(x, y), 0, "rows 5-7 of columns 13-16 dark") end
  end
  -- a change made elsewhere reaches the LEDs
  clear_buffer(2)
  assert_equal(device:get_led(14, 1), 2, "a cleared slot dims")
  -- row 8 keeps its meaning on page 4
  tap(context, 1, 1, 8)
  assert_true(local_value("pattern_playing"), "row 8 plays on page 4")
  assert_equal(device:get_led(8, 8), 15, "row 8 shows page 4")
end)

test("128h scene saves need a hold", function()
  local context = load_strata(); finish_startup(context)
  local scenes = local_value("scenes")
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 7, 8)  -- page 3
  assert_equal(device:get_led(4, 3), 4, "save key idle")
  context.grid.press(1, 4, 3, 1)
  assert_equal(device:get_led(4, 3), 15, "a pending save lights at 15")
  context.clock.run_for(0.4)
  context.grid.press(1, 4, 3, 0)
  assert_true(not scenes[4].populated, "released early: nothing saved")
  assert_equal(device:get_led(4, 3), 4, "the release dims the key")
  context.grid.press(1, 4, 3, 1)
  context.clock.run_for(0.51)
  assert_true(scenes[4].populated, "held 0.5 s: saved")
  assert_equal(device:get_led(4, 1), 8, "row 1 shows the saved scene")
  context.grid.press(1, 4, 3, 0)
end)

test("two 128h grids keep their own pages", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 8); context.grid.plug(2, 16, 8)
  tap(context, 1, 8, 8)  -- grid 1 on page 4, grid 2 on page 1
  tap(context, 2, 3, 2)
  assert_equal(patterns[2][3], 15, "grid 2's key toggles a step")
  assert_equal(params:get("v2_source"), 1, "and sets no source")
  tap(context, 1, 3, 2)
  assert_equal(params:get("v2_source"), 3, "grid 1's key sets the source")
  assert_equal(patterns[2][3], 15, "and toggles no step")
end)

end

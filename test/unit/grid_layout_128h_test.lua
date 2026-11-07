-- test/unit/grid_layout_128h_test.lua
-- The 16x8 grid layout (lib/grid/layout_128h.lua)
-- Run alone: lua test/run.lua grid_layout_128h

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value = h.load_strata, h.local_value

test("every 128h grid key runs without error", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 8)
  for y = 1, 8 do
    for x = 1, 16 do
      context.grid.press(1, x, y, 1)
      context.grid.press(1, x, y, 0)
      context.clock.advance()
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

end

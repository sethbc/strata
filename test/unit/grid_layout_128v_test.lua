-- test/unit/grid_layout_128v_test.lua
-- The 8x16 grid layout (lib/grid/layout_128v.lua)
-- Run alone: lua test/run.lua grid_layout_128v

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value = h.load_strata, h.local_value

test("every 128v grid key runs without error", function()
  local context = load_strata()
  local device = context.grid.plug(1, 8, 16)
  for y = 1, 16 do
    for x = 1, 8 do
      context.grid.press(1, x, y, 1)
      context.grid.press(1, x, y, 0)
      context.clock.advance()
    end
  end
  assert_true(device.refresh_count > 0, "128v grid was redrawn")
end)

test("grid_redraw draws the 128v layout (I2), on a hot-plugged grid too (I3)", function()
  local context = load_strata()
  local device = context.grid.plug(2, 8, 16)
  local refreshes = device.refresh_count
  grid_redraw()
  assert_equal(device.refresh_count, refreshes + 1, "128v redraw reaches a hot-plugged grid")
  -- voice 1 is running after init: its status LED must be lit
  local lit = false
  for x = 1, 8 do
    for y = 1, 16 do
      if device:get_led(x, y) >= 12 then lit = true end
    end
  end
  assert_true(lit, "128v layout drew something")
end)

end

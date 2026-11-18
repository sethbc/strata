-- test/unit/grid_layout_128h_test.lua
-- The 16x8 grid layout (lib/grid/layout_128h.lua, 3.8's arranger): one
-- pane on rows 1-7, row 8 its strip (play, fill, the page keys, the
-- voices). The pages are their own files' (grid_pages_*_test.lua)
-- Run alone: lua test/run.lua grid_layout_128h

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function tap(context, port, x, y)
  context.grid.press(port, x, y, 1); context.grid.press(port, x, y, 0)
end

-- Row 8: PL 1, FL 2, P1-P7 3-9, O1-O7 10-16
local STRIP = {row = 8, first_page = 3, first_voice = 10}

test("the 128h's pane and strip sit where its spec says", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local layout = S.registry.grid_layouts["128h"]
  context.grid.plug(1, 16, 8)
  assert_equal(S.lib.grid_core.layout_of(1), layout, "a 16x8 grid has the 128h layout")
  assert_equal(layout.panes, 1, "one pane")
  assert_equal(layout.pane_at(1, 1), 1, "rows 1-7 are the pane")
  assert_equal(layout.pane_at(16, 7), 1)
  assert_equal(layout.pane_at(1, 8), nil, "row 8 is its strip")
  assert_equal(layout.start_pages[1], S.constants.GRID_PAGES.patterns, "it starts on patterns")
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

test("two 128h grids keep their own pages", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.GRID_PAGES
  local probe = h.probe_grid_page(pages.fx)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 8); context.grid.plug(2, 16, 8)
  tap(context, 1, STRIP.first_page + pages.fx - 1, STRIP.row)  -- grid 1 on the probe, grid 2 on patterns
  tap(context, 2, 3, 2)
  assert_equal(patterns[2][3], 15, "grid 2's key toggles a step")
  assert_equal(#probe.presses, 0, "and reaches no probe")
  tap(context, 1, 3, 2)
  assert_equal(#probe.presses, 2, "grid 1's key reaches the probe (press and release)")
  assert_equal(patterns[2][3], 15, "and toggles no step")
end)

test("128h lights the sounding step between steps, as SEQ does (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local device = context.grid.plug(1, 16, 8)
  local function led(voice_idx, step) return device:get_led(step, voice_idx) end
  S.patterns[1][2] = 9
  grid_redraw()
  assert_equal(led(1, 2), 9, "stopped: the stored level")
  assert_equal(led(2, 1), 0, "stopped: no playhead")
  pattern_toggle()  -- step 1 plays at once
  grid_redraw()
  assert_equal(led(2, 1), 4, "just started: step 1 is the playhead")
  assert_equal(led(2, PATTERN_LENGTH), 0, "never the last step")
  h.wake(context, "pattern_clock")  -- step 2 plays; the position is now 3
  grid_redraw()  -- a redraw between steps (a key press)
  assert_equal(S.pattern_position, 3)
  assert_equal(led(1, 2), 15, "the sounding active step at 15")
  assert_equal(led(2, 2), 4, "the sounding empty step at 4")
  assert_equal(led(2, 3), 0, "not the next step")
  assert_equal(S.lib.sequencer.sounding_step(), 2, "the step SEQ draws")
  pattern_toggle()
  assert_equal(led(1, 2), 9, "stopped: the stored level again")
  assert_equal(led(2, 2), 0)
end)

test("a silenced voice's key lights at 6 on every layout", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 8)
  local function voice_x(voice_idx) return STRIP.first_voice + voice_idx - 1 end
  toggle_voice(3)
  assert_equal(device:get_led(voice_x(3), STRIP.row), 12, "voice 3 running: 12")
  params:set("v3_mute", 1)
  assert_equal(device:get_led(voice_x(3), STRIP.row), 6, "voice 3 muted: 6")
  params:set("v3_mute", 0); params:set("v4_solo", 1)
  assert_equal(device:get_led(voice_x(3), STRIP.row), 6, "silenced by voice 4's solo: 6")
  assert_equal(device:get_led(voice_x(4), STRIP.row), 2, "voice 4, soloed but stopped: 2")
end)

-- design §8.7: the step keys toggle on release
test("128h: a step key toggles on release", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 8)
  context.grid.press(1, 9, 2, 1)
  assert_equal(patterns[2][9], 0, "the press leaves voice 2's step 9")
  context.grid.press(1, 9, 2, 0)
  assert_equal(patterns[2][9], 15, "the release toggles it")
end)

end

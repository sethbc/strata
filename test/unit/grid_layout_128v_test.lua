-- test/unit/grid_layout_128v_test.lua
-- The 8x16 grid layout (lib/grid/layout_128v.lua, 3.8's arranger): one
-- pane turned, a line down each of columns 1-7, column 8 its strip (the
-- 128h's row 8, top to bottom). The pages are their own files'
-- Run alone: lua test/run.lua grid_layout_128v

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function tap(context, port, x, y)
  context.grid.press(port, x, y, 1); context.grid.press(port, x, y, 0)
end

-- Column 8, top to bottom: PL 1, FL 2, P1-P7 3-9, O1-O7 10-16
local STRIP = {column = 8, play = 1, fill = 2, first_page = 3, first_voice = 10}

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

test("128v column 8 is the strip, top to bottom, on every page", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.GRID_PAGES
  h.probe_grid_page(pages.fx)
  local device = context.grid.plug(1, 8, 16)
  local layout = S.registry.grid_layouts["128v"]
  assert_equal(layout.pane_at(1, 1), 1, "columns 1-7 are the pane")
  assert_equal(layout.pane_at(7, 16), 1)
  assert_equal(layout.pane_at(8, 5), nil, "column 8 is its strip")
  for _, page in ipairs({pages.patterns, pages.fx}) do
    S.lib.grid_core.set_page(1, page); grid_redraw()
    local was_active = S.voices[5].active
    tap(context, 1, STRIP.column, STRIP.first_voice + 4)
    assert_true(S.voices[5].active ~= was_active, "page " .. page .. ": O5 toggles voice 5")
    assert_equal(device:get_led(STRIP.column, STRIP.first_voice + 4), S.voices[5].active and 12 or 2,
      "the shared voice levels (#526)")
    tap(context, 1, STRIP.column, STRIP.play)
    assert_true(S.pattern_playing, "page " .. page .. ": PL plays")
    assert_equal(device:get_led(STRIP.column, STRIP.play), 15)
    tap(context, 1, STRIP.column, STRIP.play)
    assert_true(not S.pattern_playing, "and stops")
    context.grid.press(1, STRIP.column, STRIP.fill, 1)
    assert_true(S.lib.conditions.fill(), "page " .. page .. ": FL holds fill")
    context.grid.press(1, STRIP.column, STRIP.fill, 0)
  end
  tap(context, 1, STRIP.column, STRIP.first_page + pages.patterns - 1)
  assert_equal(S.lib.grid_core.page(1), pages.patterns, "P1 shows patterns")
  assert_equal(device:get_led(STRIP.column, STRIP.first_page + pages.patterns - 1), 15, "lit")
  assert_equal(device:get_led(STRIP.column, STRIP.first_page + pages.fx - 1), 2, "another page with a record: 2")
end)

test("128v patterns page: steps down each voice's column", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  h.probe_grid_page(S.constants.GRID_PAGES.fx)
  local device = context.grid.plug(1, 8, 16)
  local patterns = local_value("patterns")
  tap(context, 1, 3, 12)
  assert_equal(patterns[3][12], 15, "(3,12) toggles voice 3 step 12")
  assert_equal(device:get_led(3, 12), 15)
  context.grid.press(1, 3, 12, 1); context.grid.press(1, 3, 4, 1)
  local lo, hi = S.lib.loop_roll.loop(3)
  assert_equal(lo, 4, "with step 12 held, row 4 loops 4 to 12 (3.9's 5a)"); assert_equal(hi, 12)
  assert_equal(patterns[3][12], 15, "the held step keeps its level")
  assert_equal(patterns[3][4], 0, "the second key does not toggle")
  context.grid.press(1, 3, 4, 0); context.grid.press(1, 3, 12, 0)
  -- another page does not edit patterns
  S.lib.grid_core.set_page(1, S.constants.GRID_PAGES.fx)
  tap(context, 1, 6, 6)
  assert_equal(patterns[6][6], 0, "columns 1-7 edit steps on the patterns page only")
end)

test("128v lights the sounding step between steps, as SEQ does (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local device = context.grid.plug(1, 8, 16)
  local function led(voice_idx, step) return device:get_led(voice_idx, step) end
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
  local device = context.grid.plug(1, 8, 16)
  local voice_3 = STRIP.first_voice + 2
  toggle_voice(3)
  assert_equal(device:get_led(STRIP.column, voice_3), 12, "voice 3 running: 12")
  params:set("v3_mute", 1)
  assert_equal(device:get_led(STRIP.column, voice_3), 6, "voice 3 muted: 6")
  params:set("v3_mute", 0); params:set("v4_solo", 1)
  assert_equal(device:get_led(STRIP.column, voice_3), 6, "silenced by voice 4's solo: 6")
end)

-- design §8.7: the step keys toggle on release
test("128v: a step key toggles on release", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 8, 16)
  context.grid.press(1, 2, 9, 1)
  assert_equal(patterns[2][9], 0, "the press leaves voice 2's step 9")
  context.grid.press(1, 2, 9, 0)
  assert_equal(patterns[2][9], 15, "the release toggles it")
end)

end

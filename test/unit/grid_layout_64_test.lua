-- test/unit/grid_layout_64_test.lua
-- The 8x8 grid layout (lib/grid/layout_64.lua): one half of the patterns at
-- a time, row 8's play / half key and voice toggles
-- Run alone: lua test/run.lua grid_layout_64

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function grid_core() return local_value("S").lib.grid_core end
local function shown_half(port) return grid_core().port_state(port).half or 1 end
local function tap(context, port, x, y)
  context.grid.press(port, x, y, 1); context.grid.press(port, x, y, 0)
end
-- hold (1,8) past the half-toggle time, then let go
local function switch_half(context, port)
  context.grid.press(port, 1, 8, 1)
  context.clock.run_for(0.51)
  context.grid.press(port, 1, 8, 0)
end

test("every 64 grid key runs without error", function()
  local context = load_strata()
  local device = context.grid.plug(1, 8, 8)
  for half = 1, 2 do
    if shown_half(1) ~= half then switch_half(context, 1) end
    for y = 1, 8 do
      for x = 1, 8 do
        context.grid.press(1, x, y, 1)
        context.grid.press(1, x, y, 0)
        context.clock.advance()
      end
    end
  end
  assert_true(device.refresh_count > 0, "64 grid was redrawn")
end)

test("grid_redraw draws the 64 layout (I2), on a hot-plugged grid too (I3)", function()
  local context = load_strata()
  local device = context.grid.plug(2, 8, 8)
  local refreshes = device.refresh_count
  grid_redraw()
  assert_equal(device.refresh_count, refreshes + 1, "64 redraw reaches a hot-plugged grid")
  -- voice 1 is running after init: its status LED must be lit
  local lit = false
  for x = 1, 8 do
    for y = 1, 8 do
      if device:get_led(x, y) >= 12 then lit = true end
    end
  end
  assert_true(lit, "64 layout drew something")
end)

test("64 row 8 columns 2-8 toggle voices 1-7", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  local voices = local_value("voices")
  for voice_idx = 1, 7 do
    local was_active = voices[voice_idx].active
    tap(context, 1, voice_idx + 1, 8)
    assert_true(voices[voice_idx].active ~= was_active, "(" .. (voice_idx + 1) .. ",8) toggles voice " .. voice_idx)
    assert_equal(device:get_led(voice_idx + 1, 8), voices[voice_idx].active and 12 or 4, "voice " .. voice_idx .. " LED")
  end
  assert_true(voices[7].active, "voice 7 is reachable")
end)

test("64 column 1: a tap plays or stops on release, a 0.5 s hold switches the half", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  local patterns = local_value("patterns")
  assert_equal(shown_half(1), 1, "a grid starts on steps 1-8")
  context.grid.press(1, 1, 8, 1)
  assert_true(not local_value("pattern_playing"), "nothing happens at press")
  context.clock.run_for(0.1)
  context.grid.press(1, 1, 8, 0)
  assert_true(local_value("pattern_playing"), "a tap plays on release")
  assert_equal(shown_half(1), 1, "a tap does not switch the half")
  tap(context, 1, 1, 8)
  assert_true(not local_value("pattern_playing"), "a second tap stops")
  context.grid.press(1, 1, 8, 0)
  assert_true(not local_value("pattern_playing"), "a release with no press does nothing")
  -- a hold switches the half and its release does not play
  context.grid.press(1, 1, 8, 1)
  context.clock.run_for(0.51)
  assert_equal(grid_core().port_state(1).half, 2, "a 0.5 s hold shows steps 9-16")
  context.grid.press(1, 1, 8, 0)
  assert_true(not local_value("pattern_playing"), "the hold's release does not toggle play")
  -- half 2: column x is step 8 + x
  tap(context, 1, 3, 1)
  assert_equal(patterns[1][11], 15, "half 2: (3,1) toggles voice 1 step 11")
  assert_equal(patterns[1][3], 0, "step 3 untouched")
  assert_equal(device:get_led(3, 1), 15, "the LED shows step 11")
  -- the step-level gesture uses positions 1-8 of the shown half
  context.grid.press(1, 3, 2, 1); context.grid.press(1, 4, 2, 1)
  assert_equal(patterns[2][11], 8, "held step 11 takes round(4 * 15 / 8) = 8")
  assert_equal(patterns[2][12] + patterns[2][4], 0, "the level key does not toggle")
  context.grid.press(1, 4, 2, 0); context.grid.press(1, 3, 2, 0)
  context.grid.press(1, 5, 3, 1); context.grid.press(1, 8, 3, 1)
  assert_equal(patterns[3][13], 15, "column 8 is the top level")
  context.grid.press(1, 8, 3, 0); context.grid.press(1, 5, 3, 0)
  -- a hold switches back
  switch_half(context, 1)
  assert_equal(grid_core().port_state(1).half, 1, "a second hold shows steps 1-8")
  tap(context, 1, 3, 1)
  assert_equal(patterns[1][3], 15, "half 1: (3,1) toggles step 3")
  assert_equal(device:get_led(3, 1), 15)
  assert_equal(patterns[1][11], 15, "step 11 keeps playing, unseen")
end)

test("64 halves are per grid and a removed grid's hold switches nothing", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 8, 8); context.grid.plug(2, 8, 8)
  switch_half(context, 1)
  assert_equal(shown_half(1), 2)
  assert_equal(shown_half(2), 1, "the other grid keeps its own half")
  context.grid.press(2, 1, 8, 1)
  context.grid.unplug(2)
  context.clock.run_for(1)
  assert_true(not local_value("pattern_playing"), "no play from a removed grid")
  context.grid.plug(2, 8, 8)
  assert_equal(shown_half(2), 1, "a grid plugged back shows steps 1-8")
  assert_equal(shown_half(1), 2)
  -- cleanup during a hold: nothing fires
  context.grid.press(1, 1, 8, 1)
  cleanup()
  context.clock.run_for(1)
  assert_equal(shown_half(1), 1, "cleanup forgets the half and cancels the hold")
end)

test("64 lights the shown half's playhead and blinks column 1 when the other half plays", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  local S = local_value("S")
  assert_equal(device:get_led(1, 8), 4, "stopped: column 1 dim")
  toggle_pattern_step(2, 4)
  S.pattern_playing = true
  S.pattern_position = 4
  grid_redraw()
  assert_equal(device:get_led(1, 8), 15, "the shown half plays: column 1 at 15")
  assert_equal(device:get_led(4, 2), 15, "the playhead on an active step")
  assert_equal(device:get_led(4, 1), 4, "the playhead on an empty step")
  assert_equal(device:get_led(5, 1), 0, "no playhead past it")
  -- the other half plays: column 1 blinks 12 / 3 with the beat (four steps)
  local levels = {}
  for position = 9, 16 do
    S.pattern_position = position
    grid_redraw()
    levels[#levels + 1] = device:get_led(1, 8)
    for x = 1, 8 do
      assert_true(device:get_led(x, 1) ~= 4, "no playhead in the shown half at step " .. position)
    end
  end
  assert_equal(table.concat(levels, " "), "12 12 12 12 3 3 3 3", "column 1 blinks with the beat")
  -- half 2 shows steps 9-16: the playhead lights there, and half 1's steps blink
  S.pattern_playing = false
  switch_half(context, 1)
  S.pattern_playing = true
  S.pattern_position = 12
  grid_redraw()
  assert_equal(device:get_led(4, 1), 4, "half 2: step 12's playhead in column 4")
  assert_equal(device:get_led(1, 8), 15)
  S.pattern_position = 3
  grid_redraw()
  assert_equal(device:get_led(1, 8), 12, "half 1 plays: column 1 blinks (beat 1 lit)")
  S.pattern_position = 6
  grid_redraw()
  assert_equal(device:get_led(1, 8), 3, "beat 2 dim")
  S.pattern_playing = false
  grid_redraw()
  assert_equal(device:get_led(1, 8), 4)
  -- with the sequencer running for real
  pattern_toggle()
  context.clock.advance()
  assert_true(device:get_led(1, 8) == 15 or device:get_led(1, 8) == 12 or device:get_led(1, 8) == 3, "playing")
  pattern_toggle()
end)

end

-- test/unit/grid_layout_64_test.lua
-- The 8x8 grid layout (lib/grid/layout_64.lua, 3.8's arranger): the left
-- or the right half of one pane on rows 1-7, row 8 its small strip (NV,
-- the voices); NV held shows the chooser. The pages are their own files'
-- Run alone: lua test/run.lua grid_layout_64

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function grid_core() return local_value("S").lib.grid_core end
local function shown_half(port) return grid_core().half(port, 1) end
local function tap(context, port, x, y)
  context.grid.press(port, x, y, 1); context.grid.press(port, x, y, 0)
end
-- NV (1, 8) held into the chooser, the chooser key at column `page` and
-- row `row` pressed (row 1 the left half, 2 the right; 3 and 4 side 2's),
-- then NV let go
local function choose(context, port, page, row)
  context.grid.press(port, 1, 8, 1)
  context.clock.run_for(local_value("S").constants.GRID_HOLD.chooser_seconds + 0.01)
  tap(context, port, page, row)
  context.grid.press(port, 1, 8, 0)
end

-- What the real step editor (the SEQ page's, S.lib.pages_seq) has open,
-- as "voice step port", or nil (test/helpers.lua)
local shown_step_editor = h.shown_step_editor

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
  local layout = local_value("S").registry.grid_layouts["64"]
  assert_equal(layout.panes, 1, "one pane")
  assert_equal(layout.pane_at(8, 7), 1, "rows 1-7 are the pane")
  assert_equal(layout.pane_at(1, 8), nil, "row 8 is its strip")
end)

test("64 row 8 columns 2-8 toggle voices 1-7", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  local voices = local_value("voices")
  for voice_idx = 1, local_value("S").constants.NUM_VOICES do
    local was_active = voices[voice_idx].active
    tap(context, 1, voice_idx + 1, 8)
    assert_true(voices[voice_idx].active ~= was_active, "(" .. (voice_idx + 1) .. ",8) toggles voice " .. voice_idx)
    assert_equal(device:get_led(voice_idx + 1, 8), voices[voice_idx].active and 12 or 2,
      "voice " .. voice_idx .. " LED (the shared levels, #526)")
  end
  assert_true(voices[local_value("S").constants.NUM_VOICES].active, "the last voice is reachable")
end)

test("64 NV: a tap plays or stops on release, the chooser shows the right half", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  local patterns = local_value("patterns")
  local patterns_page = local_value("S").constants.GRID_PAGES.patterns
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
  -- the chooser picks the right half and its release does not play
  choose(context, 1, patterns_page, 2)
  assert_equal(shown_half(1), 2, "the chooser showed steps 9-16")
  assert_true(not local_value("pattern_playing"), "NV's release after the chooser does not toggle play")
  -- half 2: column x is step 8 + x
  tap(context, 1, 3, 1)
  assert_equal(patterns[1][11], 15, "half 2: (3,1) toggles voice 1 step 11")
  assert_equal(patterns[1][3], 0, "step 3 untouched")
  assert_equal(device:get_led(3, 1), 15, "the LED shows step 11")
  -- a second key loops to its own step of the shown half (3.9's 5a,
  -- re-based from 3.4's level gesture over positions 1-8)
  local loop_roll = local_value("S").lib.loop_roll
  context.grid.press(1, 3, 2, 1); context.grid.press(1, 4, 2, 1)
  local lo, hi = loop_roll.loop(2)
  assert_equal(lo, 11, "held step 11 loops"); assert_equal(hi, 12, "to step 12")
  assert_equal(patterns[2][11] + patterns[2][12] + patterns[2][4], 0, "neither key toggles")
  context.grid.press(1, 4, 2, 0); context.grid.press(1, 3, 2, 0)
  context.grid.press(1, 5, 3, 1); context.grid.press(1, 8, 3, 1)
  assert_equal(select(2, loop_roll.loop(3)), 16, "column 8 is step 16")
  context.grid.press(1, 8, 3, 0); context.grid.press(1, 5, 3, 0)
  -- back to the left half
  choose(context, 1, patterns_page, 1)
  assert_equal(shown_half(1), 1, "the chooser shows steps 1-8 again")
  tap(context, 1, 3, 1)
  assert_equal(patterns[1][3], 15, "half 1: (3,1) toggles step 3")
  assert_equal(device:get_led(3, 1), 15)
  assert_equal(patterns[1][11], 15, "step 11 keeps playing, unseen")
end)

test("64 halves and choosers are per grid and a removed grid's hold switches nothing", function()
  local context = load_strata(); finish_startup(context)
  local patterns_page = local_value("S").constants.GRID_PAGES.patterns
  local first = context.grid.plug(1, 8, 8); context.grid.plug(2, 8, 8)
  choose(context, 1, patterns_page, 2)
  assert_equal(shown_half(1), 2)
  assert_equal(shown_half(2), 1, "the other grid keeps its own half")
  -- one grid's chooser shows on it alone
  context.grid.press(2, 1, 8, 1)
  context.clock.run_for(0.51)
  grid_redraw()
  assert_equal(first:get_led(1, 2), 0, "grid 1 shows its patterns, not grid 2's chooser")
  context.grid.press(2, 1, 8, 0)
  -- a removed grid's held NV opens nothing and plays nothing
  context.grid.press(2, 1, 8, 1)
  context.grid.unplug(2)
  context.clock.run_for(1)
  assert_true(not local_value("pattern_playing"), "no play from a removed grid")
  context.grid.plug(2, 8, 8)
  assert_equal(shown_half(2), 1, "a grid plugged back shows steps 1-8")
  assert_equal(grid_core().existing_port_state(2), nil, "and no chooser")
  assert_equal(shown_half(1), 2)
  -- cleanup during a hold: nothing fires
  context.grid.press(1, 1, 8, 1)
  cleanup()
  context.clock.run_for(1)
  assert_equal(shown_half(1), 1, "cleanup forgets the half and cancels the hold")
end)

test("64 lights the sounding step between steps, in its own half (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local device = context.grid.plug(1, 8, 8)
  S.patterns[1][8] = 9
  pattern_toggle()  -- step 1 plays at once
  grid_redraw()
  assert_equal(device:get_led(1, 2), 4, "just started: step 1 is the playhead")
  for _ = 2, 8 do h.wake(context, "pattern_clock") end  -- steps 2-8 play; the position is now 9
  grid_redraw()  -- a redraw between steps (a key press)
  assert_equal(S.pattern_position, 9)
  assert_equal(device:get_led(8, 1), 15, "step 8 sounds: column 8 lit")
  -- half 2 shows steps 9-16: step 8 sounding is the other half
  S.lib.grid_core.set_half(1, 1, 2)
  grid_redraw()
  for x = 1, 8 do
    assert_true(device:get_led(x, 2) ~= 4, "half 2: no playhead while step 8 sounds (column " .. x .. ")")
  end
  h.wake(context, "pattern_clock")  -- step 9 plays
  assert_equal(device:get_led(1, 2), 4, "half 2: step 9 in column 1")
  pattern_toggle()
end)

test("64: the step views keep every key", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16
  for voice_idx = 1, 3 do params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_SYNTH + 1) end
  context.grid.plug(1, 8, 8)
  local calls = 0
  local positions = S.lib.positions
  local originals = {grid_key = positions.grid_key, strip_key = positions.strip_key}
  positions.grid_key = function(...) calls = calls + 1 end
  positions.strip_key = function(...) calls = calls + 1 end
  for half = 1, 2 do
    S.lib.grid_core.set_half(1, 1, half)
    for y = 1, 8 do
      for x = 1, 8 do
        if not (x == 1 and y == 8) then tap(context, 1, x, y) end
      end
    end
  end
  positions.grid_key, positions.strip_key = originals.grid_key, originals.strip_key
  assert_equal(calls, 0, "the step views never reach positions")
end)

test("switching halves ends a held step gesture", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  local patterns_page = local_value("S").constants.GRID_PAGES.patterns
  context.grid.plug(1, 8, 8)
  context.grid.press(1, 3, 1, 1)  -- half 1: voice 1 step 3 held
  assert_equal(patterns[1][3], 0, "step 3 toggles at its release, not its press")
  context.grid.press(1, 1, 8, 1); context.clock.run_for(0.35)
  assert_equal(shown_step_editor(), "1 3 1", "the held step opened the step editor")
  context.clock.run_for(0.25)
  assert_equal(shown_step_editor(), nil, "the chooser opening closed the editor")
  tap(context, 1, patterns_page, 2)
  context.grid.press(1, 1, 8, 0)
  assert_equal(shown_half(1), 2, "the chooser showed steps 9-16")
  tap(context, 1, 8, 1)
  assert_equal(patterns[1][16], 15, "column 8 now toggles step 16")
  assert_equal(patterns[1][3], 0, "the hidden held step takes no level")
  context.grid.press(1, 3, 1, 0)
  assert_equal(patterns[1][3] + patterns[1][11], 0, "and its release toggles nothing, in either half")
end)

test("end_port_step_gestures ignores a port that is not a grid port (nil and NaN raise nothing)", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  local S = local_value("S")
  context.grid.plug(1, 8, 8)
  context.grid.press(1, 3, 1, 1)  -- voice 1 step 3 held: on at 15
  local before = {}
  for key in pairs(S.grid_held) do before[#before + 1] = key end
  local core = grid_core()
  core.end_port_step_gestures(nil)
  core.end_port_step_gestures(0 / 0)
  for _, port in ipairs({0, 1.5, S.MAX_GRID_PORTS + 1, "1", -1}) do
    core.end_port_step_gestures(port)
  end
  local after = {}
  for key in pairs(S.grid_held) do after[#after + 1] = key end
  assert_equal(#after, #before, "no port entry made")
  context.grid.press(1, 4, 1, 1)
  assert_equal(select(2, S.lib.loop_roll.loop(1)), 4, "port 1's held step still meets its second key: a loop 3 to 4 (3.9's 5a)")
  assert_equal(patterns[1][3] + patterns[1][4], 0, "neither key toggles")
end)

-- 3.4 (design §8.7, §11): a held step opens the step editor on either
-- half, for the step of the half shown
test("a held step opens the step editor in the steps views", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local patterns = local_value("patterns")
  context.grid.plug(1, 8, 8)
  context.grid.press(1, 3, 2, 1); context.clock.run_for(0.35)
  assert_equal(shown_step_editor(), "2 3 1", "steps 1-8: voice 2's step 3")
  context.grid.press(1, 3, 2, 0)
  assert_equal(shown_step_editor(), nil, "the release closes it")
  assert_equal(patterns[2][3], 0, "and toggles nothing")
  S.lib.grid_core.set_half(1, 1, 2)
  context.grid.press(1, 3, 2, 1); context.clock.run_for(0.35)
  assert_equal(shown_step_editor(), "2 11 1", "steps 9-16: voice 2's step 11")
  assert_equal(S.lib.ui_modal.top(), S.lib.pages_seq.step_editor_owner, "the editor has the screen")
  -- the half switch ends the held step: the editor closes, nothing toggles
  S.lib.grid_core.set_half(1, 1, 1)
  assert_equal(shown_step_editor(), nil, "the editor closed with the half")
  assert_equal(S.lib.ui_modal.top(), nil)
  context.grid.press(1, 3, 2, 0)
  assert_equal(patterns[2][11], 0, "its release toggles nothing")
  -- a tap still toggles, on its release
  context.grid.press(1, 5, 4, 1)
  assert_equal(patterns[4][5], 0, "a press leaves voice 4's step 5")
  context.grid.press(1, 5, 4, 0)
  assert_equal(patterns[4][5], 15, "its release toggles it")
end)

-- (mute) design §8.14: a silenced running voice's key lights at 6
test("a silenced voice's key lights at 6 on every layout", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  toggle_voice(3)
  assert_equal(device:get_led(4, 8), 12, "voice 3 running: 12")
  params:set("v3_mute", 1)
  assert_equal(device:get_led(4, 8), 6, "voice 3 muted: 6")
  params:set("v3_mute", 0); params:set("v4_solo", 1)
  assert_equal(device:get_led(4, 8), 6, "silenced by voice 4's solo: 6")
end)

end

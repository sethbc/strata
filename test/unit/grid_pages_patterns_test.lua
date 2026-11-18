-- test/unit/grid_pages_patterns_test.lua
-- Grid page 1, patterns (lib/grid/pages/patterns.lua, design §10.3): a
-- line per voice, a key per step, on every arrangement (h.grid_pane)
-- Run alone: lua test/run.lua grid_pages_patterns

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local grid_pane, shown_step_editor = h.grid_pane, h.shown_step_editor

-- The pane's first and last shown column: a half shows eight
local function shown_columns(pane)
  local first, last
  for x = 1, 16 do
    if pane.shows(x, 1) then
      first = first or x
      last = x
    end
  end
  return first, last
end

local function each_arrangement(body)
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    local pane = grid_pane(context, arrangement)
    pane.show(S.constants.GRID_PAGES.patterns)
    body(context, S, pane, arrangement)
  end
end

test("the patterns page is registered at its index", function()
  load_strata()
  local S = local_value("S")
  local record = S.registry.grid_pages[S.constants.GRID_PAGES.patterns]
  assert_true(record ~= nil, "a record at page 1")
  assert_equal(record.name, "patterns")
  assert_equal(record.sides, nil, "one side")
  assert_equal(S.lib.grid_pages_patterns.record, record, "the module keeps its record")
end)

test("a step toggles at its release", function()
  each_arrangement(function(context, S, pane, arrangement)
    local first = shown_columns(pane)
    local step = first + 2
    pane.press(step, 4, 1)
    assert_equal(S.patterns[4][step], 0, arrangement .. ": a press leaves the step as it was")
    context.clock.run_for(0.2)
    pane.press(step, 4, 0)
    assert_equal(S.patterns[4][step], 15, arrangement .. ": its release within 0.3 s toggles it on")
    assert_equal(pane.led(step, 4), 15, arrangement .. ": and lights it")
    pane.tap(step, 4)
    assert_equal(S.patterns[4][step], 0, arrangement .. ": the next tap toggles it off")
    -- every voice's line
    for voice_idx = 1, S.constants.NUM_VOICES do
      pane.tap(first, voice_idx)
      assert_equal(S.patterns[voice_idx][first], 15, arrangement .. ": line " .. voice_idx .. " is voice " .. voice_idx)
    end
  end)
end)

test("a second key sets the held step's level over 16 positions, 8 on a half", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first, last = shown_columns(pane)
    local positions = last - first + 1
    S.patterns[2][first] = 15
    pane.press(first, 2, 1)
    pane.press(last, 2, 1)
    assert_equal(S.patterns[2][first], 15, arrangement .. ": the line's last shown key is the top level")
    pane.press(last, 2, 0)
    local middle = first + positions / 2 - 1
    pane.press(middle, 2, 1)
    local expected = S.lib.grid_core.level_for_position(positions / 2, positions)
    assert_equal(S.patterns[2][first], expected, arrangement .. ": key " .. (positions / 2) .. " of " .. positions)
    pane.press(middle, 2, 0)
    pane.press(first, 2, 0)
    assert_equal(S.patterns[2][first], expected, arrangement .. ": neither release toggles")
    assert_equal(S.patterns[2][last] + S.patterns[2][middle], 0, arrangement .. ": the level keys toggled nothing")
  end)
end)

test("a 0.3 s hold opens the step editor and its release closes it", function()
  each_arrangement(function(context, S, pane, arrangement)
    local first = shown_columns(pane)
    local step = first + 4
    pane.press(step, 3, 1)
    context.clock.run_for(0.25)
    assert_equal(shown_step_editor(), nil, arrangement .. ": not before 0.3 s")
    context.clock.run_for(0.1)
    assert_equal(shown_step_editor(), "3 " .. step .. " 1", arrangement .. ": voice 3's step, from port 1")
    pane.press(step, 3, 0)
    assert_equal(shown_step_editor(), nil, arrangement .. ": the release closes it")
    assert_equal(S.patterns[3][step], 0, arrangement .. ": and toggles nothing")
  end)
end)

test("the sounding step between steps (#113)", function()
  each_arrangement(function(context, S, pane, arrangement)
    local first = shown_columns(pane)
    local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
    S.patterns[1][first + 1] = 9
    grid_redraw()
    assert_equal(pane.led(first + 1, 1), 9, arrangement .. ": stopped, the stored level")
    if first ~= 1 then return end  -- the right half shows steps 9-16, past the first two
    assert_equal(pane.led(1, 2), 0, arrangement .. ": stopped, no playhead")
    pattern_toggle()
    grid_redraw()
    assert_equal(pane.led(1, 2), 4, arrangement .. ": just started, step 1 is the playhead")
    assert_equal(pane.led(PATTERN_LENGTH, 2), pane.shows(PATTERN_LENGTH, 2) and 0 or nil, arrangement .. ": never the last step")
    h.wake(context, "pattern_clock")
    grid_redraw()
    assert_equal(S.pattern_position, 3)
    assert_equal(pane.led(2, 1), 15, arrangement .. ": the sounding active step at 15")
    assert_equal(pane.led(2, 2), 4, arrangement .. ": the sounding empty step at 4")
    assert_equal(pane.led(3, 2), 0, arrangement .. ": not the next step")
    pattern_toggle()
    assert_equal(pane.led(2, 1), 9, arrangement .. ": stopped, the stored level again")
  end)
end)

test("both panes on patterns: steps held above and below are each their voice's held step, and a level key in one pane never sets a step held in the other for another voice", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.GRID_PAGES
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(pages.patterns); bottom.show(pages.patterns)
  top.press(3, 2, 1)     -- voice 2's held step 3, above
  bottom.press(5, 4, 1)  -- voice 4's held step 5, below
  bottom.press(16, 4, 1) -- voice 4's level key, below
  assert_equal(S.patterns[4][5], 15, "the level key sets its own voice's held step")
  assert_equal(S.patterns[2][3], 0, "and not the step held above for voice 2")
  bottom.press(16, 4, 0)
  top.press(8, 2, 1)     -- voice 2's level key, above
  assert_equal(S.patterns[2][3], 8, "voice 2's level key, above, sets voice 2's step")
  assert_equal(S.patterns[4][5], 15, "voice 4's below is left alone")
  top.press(8, 2, 0); top.press(3, 2, 0); bottom.press(5, 4, 0)
  assert_equal(S.patterns[2][3], 8, "neither release toggled")
  assert_equal(S.patterns[4][5], 15)
  -- a step of one voice in both panes: the second press is a level key
  bottom.press(2, 6, 1)
  top.press(12, 6, 1)
  assert_equal(S.patterns[6][2], 11, "a voice has one held step on a port: round(12 * 15 / 16) = 11")
  top.press(12, 6, 0); bottom.press(2, 6, 0)
end)

end

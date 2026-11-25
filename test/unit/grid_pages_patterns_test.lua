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
  assert_equal(record.sides, 2, "two sides: 3.9's lane side is side 2")
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

-- 3.9's loop (package 5a, design section 4, The loop): side 1's second key
-- of a line loops the voice between the two keys (the level gesture moved
-- to side 2's hits line). Re-based from 3.4's "a second key sets the held
-- step's level over 16 positions, 8 on a half"

-- Voice 1's clock's next tick, and the step it played
local function next_step(context, S)
  context.clock.advance_until(S.pattern_clocks[1])
  return S.lib.sequencer.sounding_step(1)
end

local function every_step_set(S, voice_idx)
  for step = 1, S.constants.PATTERN_LENGTH do S.lib.sequencer.set_level(voice_idx, step, 15) end
end

test("two keys of a line loop between them", function()
  each_arrangement(function(context, S, pane, arrangement)
    local first = shown_columns(pane)
    local lo, hi = first + 1, first + 4
    every_step_set(S, 1)
    pattern_clock_start()
    pane.press(hi, 1, 1)
    pane.press(lo, 1, 1)
    pane.press(lo, 1, 0)
    local got_lo, got_hi = S.lib.loop_roll.loop(1)
    assert_equal(got_lo, lo, arrangement .. ": the loop from the lower key")
    assert_equal(got_hi, hi, arrangement .. ": to the upper, the held key")
    local steps = {}
    for _ = 1, 5 do steps[#steps + 1] = next_step(context, S) end
    assert_equal(table.concat(steps, " "), table.concat({lo, lo + 1, lo + 2, hi, lo}, " "),
      arrangement .. ": the voice plays between them")
    pane.press(hi, 1, 0)
    assert_equal(S.lib.loop_roll.loop(1), nil, arrangement .. ": the held key's release ends it")
    assert_equal(next_step(context, S), 7, arrangement .. ": tick 7 plays the voice's own step 7")
    pattern_clock_stop()
  end)
end)

test("neither key toggles and no editor opens", function()
  each_arrangement(function(context, S, pane, arrangement)
    local first = shown_columns(pane)
    pane.press(first, 2, 1)
    pane.press(first + 3, 2, 1)
    context.clock.run_for(0.5)
    assert_equal(shown_step_editor(), nil, arrangement .. ": the second key stopped the held step's hold")
    pane.press(first + 3, 2, 0); pane.press(first, 2, 0)
    assert_equal(S.patterns[2][first] + S.patterns[2][first + 3], 0, arrangement .. ": neither release toggles")
    -- after the hold has fired a further key of the line does nothing
    pane.press(first + 1, 3, 1)
    context.clock.run_for(0.35)
    assert_equal(shown_step_editor(), "3 " .. (first + 1) .. " 1", arrangement .. ": the hold opened the editor")
    pane.press(first + 5, 3, 1)
    assert_equal(S.lib.loop_roll.loop(3), nil, arrangement .. ": a key after the hold makes no loop")
    pane.press(first + 5, 3, 0); pane.press(first + 1, 3, 0)
    assert_equal(S.patterns[3][first + 1] + S.patterns[3][first + 5], 0, arrangement .. ": and toggles nothing")
  end)
end)

test("a page change and an unplug end an unlatched loop at the next tick", function()
  for _, ending in ipairs({"page change", "unplug"}) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    local pane = grid_pane(context, "128h")
    pane.show(S.constants.GRID_PAGES.patterns)
    every_step_set(S, 1)
    pattern_clock_start()
    pane.press(5, 1, 1); pane.press(8, 1, 1); pane.press(8, 1, 0)
    assert_equal(next_step(context, S), 5, ending .. ": the loop plays")
    if ending == "unplug" then context.grid.unplug(1) else pane.show(S.constants.GRID_PAGES.voices) end
    assert_equal(next_step(context, S), 3, ending .. ": the next tick plays the voice's own step 3")
    assert_equal(S.lib.loop_roll.loop(1), nil, ending .. ": the loop has ended")
    pattern_clock_stop()
  end
end)

test("a variation switch leaves a loop, and its key's release still ends it", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = grid_pane(context, "128h")
  pane.show(S.constants.GRID_PAGES.patterns)
  every_step_set(S, 1)
  pattern_clock_start()
  pane.press(5, 1, 1); pane.press(8, 1, 1); pane.press(8, 1, 0)
  S.lib.pattern_letters.switch_now(1, "B")
  assert_equal(S.lib.pattern_letters.current(1), "B", "B plays")
  assert_equal(select(2, S.lib.loop_roll.loop(1)), 8, "the loop stays")
  assert_equal(next_step(context, S), 5, "and plays")
  pane.press(5, 1, 0)
  assert_equal(next_step(context, S), 3, "the key's release ends it: the voice's own step 3")
  pattern_clock_stop()
end)

-- The final review's I1: a pattern's replacement ends every step gesture
-- but a held loop's, which writes nothing, so a further key of the line
-- still moves the loop's other end and toggles nothing. `replace` runs one
-- replacement with the loop's keys down: a letter switch, a chain link, an
-- order's next letter at the bar
local function loop_end_after(replace)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local top = grid_pane(context, "256 top")
  top.show(S.constants.GRID_PAGES.patterns)
  top.press(2, 3, 1); top.press(6, 3, 1); top.press(6, 3, 0)
  local lo, hi = S.lib.loop_roll.loop(3)
  assert_equal(lo .. " " .. hi, "2 6", "the held step 2 and key 6 loop 2 to 6")
  replace(context, S)
  assert_equal(select(2, S.lib.loop_roll.loop(3)), 6, "the replacement leaves the loop")
  top.press(10, 3, 1)
  context.clock.run_for(0.35)
  top.press(10, 3, 0)
  lo, hi = S.lib.loop_roll.loop(3)
  assert_equal(tostring(lo) .. " " .. tostring(hi), "2 10", "a further key moves the loop's other end to 10")
  assert_equal(S.patterns[3][10], 0, "and toggles nothing")
  assert_equal(shown_step_editor(), nil, "nor opens the editor")
  top.press(12, 3, 1); top.press(12, 3, 0)
  assert_equal(select(2, S.lib.loop_roll.loop(3)), 12, "a key after that moves it again")
  top.press(2, 3, 0)
  assert_equal(S.lib.loop_roll.loop(3), nil, "the held key's release ends the loop")
  assert_equal(S.patterns[3][2], 0, "and toggles nothing")
  top.tap(9, 3)
  assert_equal(S.patterns[3][9], 15, "the next tap of the line is a step of its own again")
  return context, S
end

test("after a letter switch a further key moves a held loop's end and toggles nothing", function()
  loop_end_after(function(_, S)
    S.lib.pattern_letters.switch_now(3, "B")
    assert_equal(S.lib.pattern_letters.current(3), "B", "B plays")
  end)
end)

test("after a chain link a further key moves a held loop's end and toggles nothing", function()
  local replaced
  loop_end_after(function(_, S)
    local real = S.lib.sequencer.replace_pattern
    S.lib.sequencer.replace_pattern = function(voice_idx, ...)
      if voice_idx == 3 then replaced = true end
      return real(voice_idx, ...)
    end
    S.lib.sequencer.set_level(3, 4, 9)
    capture_scene(1)
    S.lib.sequencer.set_level(3, 4, 0)
    params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 1)
    pattern_clock_start()
    S.lib.sequencer.replace_pattern = real
    assert_true(replaced, "the start's link replaced voice 3's pattern")
    assert_equal(S.patterns[3][4], 9, "the link brought scene 1's step 4")
  end)
  pattern_clock_stop()
end)

test("after an order's next letter at the bar a further key moves a held loop's end and toggles nothing", function()
  loop_end_after(function(context, S)
    local letters = S.lib.pattern_letters
    letters.set_order(3, {"A", "B"})
    pattern_clock_start()
    context.clock.run_for(4 * 4 * 0.125 + 0.01)  -- past the second bar's start
    assert_equal(letters.current(3), "B", "the order switched to B at the bar")
  end)
  pattern_clock_stop()
end)

test("on a 64 both keys are in the half shown", function()
  for _, case in ipairs({{"64 left", 2, 5}, {"64 right", 10, 13}}) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    local pane = grid_pane(context, case[1])
    pane.show(S.constants.GRID_PAGES.patterns)
    local first, last = shown_columns(pane)
    assert_true(case[2] >= first and case[3] <= last, case[1] .. ": both keys shown")
    assert_true(not pane.shows(case[1] == "64 left" and 9 or 8, 1), case[1] .. ": the other half's keys are not")
    every_step_set(S, 1)
    pane.press(case[2], 1, 1); pane.press(case[3], 1, 1)
    pattern_clock_start()
    local steps = {S.lib.sequencer.sounding_step(1)}
    for _ = 1, 4 do steps[#steps + 1] = next_step(context, S) end
    assert_equal(table.concat(steps, " "), table.concat({case[2], case[2] + 1, case[2] + 2, case[3], case[2]}, " "),
      case[1] .. ": the loop of the half's keys")
    pattern_clock_stop()
  end
end)

test("while a loop is set the voice's set steps outside it light 2", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first, last = shown_columns(pane)
    every_step_set(S, 1)
    S.lib.sequencer.set_level(1, last, 0)
    pane.press(first + 2, 1, 1); pane.press(first + 4, 1, 1)
    grid_redraw()
    assert_equal(pane.led(first, 1), 2, arrangement .. ": a set step before the loop at 2")
    assert_equal(pane.led(first + 3, 1), 15, arrangement .. ": one inside at its level")
    assert_equal(pane.led(last, 1), 1, arrangement .. ": an empty step outside stays as it was (the picked voice's, 1)")
    assert_equal(pane.led(first, 2), 0, arrangement .. ": another voice's line is untouched")
    pane.press(first + 2, 1, 0)
    grid_redraw()
    assert_equal(pane.led(first, 1), 15, arrangement .. ": let go, its level again")
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
    -- the second step the pane shows: step 2, or step 10 on the right half
    local first, last = shown_columns(pane)
    local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
    local step = first + 1
    S.patterns[1][step] = 9
    grid_redraw()
    assert_equal(pane.led(step, 1), 9, arrangement .. ": stopped, the stored level")
    assert_equal(pane.led(first, 2), 0, arrangement .. ": stopped, no playhead")
    pattern_toggle()  -- step 1 plays at once
    grid_redraw()
    if first == 1 then
      assert_equal(pane.led(1, 2), 4, arrangement .. ": just started, step 1 is the playhead")
      assert_equal(pane.led(PATTERN_LENGTH, 2), pane.shows(PATTERN_LENGTH, 2) and 0 or nil,
        arrangement .. ": never the last step")
    else
      for x = first, last do
        assert_true(pane.led(x, 2) ~= 4, arrangement .. ": step 1 sounds on the other half: no playhead at " .. x)
      end
    end
    for _ = 2, step do h.wake(context, "pattern_clock") end  -- the pane's second step plays
    grid_redraw()  -- a redraw between steps
    assert_equal(S.pattern_position, step + 1)
    assert_equal(pane.led(step, 1), 15, arrangement .. ": the sounding active step at 15")
    assert_equal(pane.led(step, 2), 4, arrangement .. ": the sounding empty step at 4")
    assert_equal(pane.led(step + 1, 2), 0, arrangement .. ": not the next step")
    pattern_toggle()
    assert_equal(pane.led(step, 1), 9, arrangement .. ": stopped, the stored level again")
  end)
end)

-- Re-based by 3.9's loop (5a) from "... and a level key in one pane never
-- sets a step held in the other for another voice": side 1's second key loops
test("both panes on patterns: steps held above and below are each their voice's held step, and a second key in one pane never loops a step held in the other for another voice", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.GRID_PAGES
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(pages.patterns); bottom.show(pages.patterns)
  local loop_roll = S.lib.loop_roll
  top.press(3, 2, 1)     -- voice 2's held step 3, above
  bottom.press(5, 4, 1)  -- voice 4's held step 5, below
  bottom.press(16, 4, 1) -- voice 4's second key, below
  assert_equal(select(2, loop_roll.loop(4)), 16, "the second key loops its own voice's held step: 5 to 16")
  assert_equal(loop_roll.loop(2), nil, "and not the step held above for voice 2")
  bottom.press(16, 4, 0)
  top.press(8, 2, 1)     -- voice 2's second key, above
  assert_equal(select(2, loop_roll.loop(2)), 8, "voice 2's second key, above, loops voice 2: 3 to 8")
  assert_equal(select(2, loop_roll.loop(4)), 16, "voice 4's below is left alone")
  top.press(8, 2, 0); top.press(3, 2, 0); bottom.press(5, 4, 0)
  assert_equal(S.patterns[2][3] + S.patterns[4][5], 0, "neither release toggled")
  -- a step of one voice in both panes: the second press is its second key
  bottom.press(2, 6, 1)
  top.press(12, 6, 1)
  local lo, hi = loop_roll.loop(6)
  assert_equal(lo, 2, "a voice has one held step on a port: the loop from 2"); assert_equal(hi, 12, "to 12")
  top.press(12, 6, 0); bottom.press(2, 6, 0)
end)

-- The final review's M1: a held step pairs only with a second key from its
-- own view (the pane's page and side), so on a 256 with side 1 above and
-- side 2 below each pane's key of one voice is a step of its own
test("a side 1 key and a side 2 hits key of one voice make no gesture across the panes", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.GRID_PAGES
  local top, bottom = grid_pane(context, "256 top"), grid_pane(context, "256 bottom")
  top.show(pages.patterns); bottom.show(pages.patterns, 2)
  S.lib.grid_pages_patterns.pick(1, 3)
  local hits = 1
  -- side 1 held, side 2's hits key pressed
  top.press(2, 3, 1)
  bottom.press(9, hits, 1)
  assert_equal(S.lib.loop_roll.loop(3), nil, "side 2's key makes no loop of side 1's held step")
  bottom.press(9, hits, 0); top.press(2, 3, 0)
  assert_equal(S.patterns[3][9], 15, "the hits key toggles its own step")
  assert_equal(S.patterns[3][2], 15, "and side 1's key its own")
  -- side 2's hits key held, side 1 pressed
  bottom.press(4, hits, 1)
  top.press(12, 3, 1)
  assert_equal(S.patterns[3][4], 0, "side 1's key sets no level on side 2's held step")
  top.press(12, 3, 0); bottom.press(4, hits, 0)
  assert_equal(S.patterns[3][4], 15, "the hits key toggles its own step at its release")
  assert_equal(S.patterns[3][12], 15, "and side 1's key its own")
  assert_equal(S.lib.loop_roll.loop(3), nil, "no loop")
end)

-- fx2 (#1054 item 1): a held step's entry stores no copy of its view; the
-- core works the view out at the second key from each key's pane
test("a held step's entry keeps no view: the second key reads it from the keys' panes", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.GRID_PAGES
  local top = grid_pane(context, "256 top")
  top.show(pages.patterns)
  top.press(2, 3, 1)
  local name, step_keys, index = nil, nil, 1
  repeat
    name, step_keys = debug.getupvalue(S.lib.grid_core.step_key, index)
    index = index + 1
  until name == "step_keys" or name == nil
  local found = 0
  for _, columns in pairs(step_keys) do
    for _, rows in pairs(columns) do
      for _, entry in pairs(rows) do
        found = found + 1
        assert_equal(entry.view, nil, "no stored view")
      end
    end
  end
  assert_equal(found, 1, "the held step's entry")
  top.press(12, 3, 1)
  assert_equal(select(2, S.lib.loop_roll.loop(3)), 12, "its own view's second key still pairs: the loop to 12")
  top.press(12, 3, 0); top.press(2, 3, 0)
end)

-- 3.9's lane side (package 3b, design section 4) --------------------------

local PATTERNS_SIDE2 = 2
-- Side 2's lines and utility keys (pane x on line 7)
local LINE = {hits = 1, a = 2, b = 3, chance = 4, repeats = 5, gate = 6, utility = 7}
local KEY = {pulse = 1, move = 2, accent = 3, ln = 4, position = 5, pitch = 6, size = 7, cutoff = 8, b = 9,
  first_voice = 10}
local STRIP_LINE, PAGE_KEY_ONE, NV = 8, 3, 1

local function lane_side(S, pane, half)
  pane.show(S.constants.GRID_PAGES.patterns, PATTERNS_SIDE2, half)
end

-- The x of position p16 of 16 on a full pane, or of p16 / 2 of 8 on a half
-- (the same share of the keys shown)
local function at_share(pane, p16)
  local first, last = shown_columns(pane)
  if last - first + 1 == 16 then return p16 end
  return first - 1 + p16 / 2
end

local function mode_index(S, name)
  for index, mode in ipairs(S.lib.sequencer.SEQ.modes) do
    if mode == name then return index end
  end
  error("no mode " .. name)
end

local function lane_side_arrangement(body)
  each_arrangement(function(context, S, pane, arrangement)
    lane_side(S, pane)
    body(context, S, pane, arrangement)
  end)
end

-- The utility line's keys on a 64 sit on one half: show the half that has x
local function show_half_of(S, pane, arrangement, x)
  if arrangement:match("^64") then lane_side(S, pane, x <= 8 and 1 or 2) end
end

test("the lit page key flips to the lane side and back", function()
  each_arrangement(function(context, S, pane, arrangement)
    local core, page = S.lib.grid_core, S.constants.GRID_PAGES.patterns
    local first = shown_columns(pane)
    if arrangement:match("^64") then
      -- the 64 has no page keys: its chooser picks the side
      local half = core.half(pane.port, 1)
      pane.press(NV, STRIP_LINE, 1)
      context.clock.run_for(0.55)
      pane.tap(first, 2 + half)
      pane.press(NV, STRIP_LINE, 0)
      assert_equal(core.view(pane.port, 1), "1:" .. page .. ":2:" .. half, arrangement .. ": the chooser's side 2")
      pane.press(NV, STRIP_LINE, 1)
      context.clock.run_for(0.55)
      pane.tap(first, half)
      pane.press(NV, STRIP_LINE, 0)
      assert_equal(core.view(pane.port, 1), "1:" .. page .. ":1:" .. half, arrangement .. ": and side 1 again")
    else
      pane.tap(PAGE_KEY_ONE, STRIP_LINE)
      assert_equal(core.side(pane.port, pane.pane), 2, arrangement .. ": the lit key shows side 2")
      assert_equal(pane.led(PAGE_KEY_ONE, STRIP_LINE), S.constants.GRID_LEVELS.side_two, arrangement .. ": lit 10 there")
      pane.tap(PAGE_KEY_ONE, STRIP_LINE)
      assert_equal(core.side(pane.port, pane.pane), 1, arrangement .. ": and side 1 again")
    end
  end)
end)

test("a press on a line of side 1 picks its voice, on both panes of a 256, and the picked line's empty steps light 1", function()
  each_arrangement(function(_, S, pane, arrangement)
    local patterns = S.lib.grid_pages_patterns
    local first, last = shown_columns(pane)
    assert_equal(patterns.voice(pane.port), 1, arrangement .. ": voice 1 is picked at first")
    assert_equal(pane.led(first, 1), 1, arrangement .. ": the picked voice's empty step lights 1")
    assert_equal(pane.led(first, 2), 0, arrangement .. ": another voice's empty step is dark")
    pane.press(last, 4, 1)
    assert_equal(patterns.voice(pane.port), 4, arrangement .. ": a press on line 4 picks voice 4")
    pane.press(last, 4, 0)
    assert_equal(S.patterns[4][last], 15, arrangement .. ": and the key still toggles its step")
    assert_equal(pane.led(last, 4), 15, arrangement .. ": a set step lights its level")
    assert_equal(pane.led(first, 4), 1, arrangement .. ": the picked line's empty steps light 1")
    assert_equal(pane.led(first, 1), 0, arrangement .. ": voice 1's are dark again")
  end)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local top, bottom = grid_pane(context, "256 top"), grid_pane(context, "256 bottom")
  top.show(S.constants.GRID_PAGES.patterns)
  bottom.show(S.constants.GRID_PAGES.patterns, PATTERNS_SIDE2)
  top.tap(3, 5)
  assert_equal(S.lib.grid_pages_patterns.voice(1), 5, "the top pane's press picks for the port")
  assert_equal(bottom.led(KEY.first_voice + 4, LINE.utility), 15, "the bottom pane's side 2 shows voice 5")
  assert_equal(bottom.led(3, LINE.hits), 15, "and its hits")
  bottom.show(S.constants.GRID_PAGES.patterns)
  top.show(S.constants.GRID_PAGES.patterns, PATTERNS_SIDE2)
  bottom.tap(6, 2)
  assert_equal(S.lib.grid_pages_patterns.voice(1), 2, "the bottom pane's press picks too")
  assert_equal(top.led(KEY.first_voice + 1, LINE.utility), 15, "and the top pane's side 2 shows voice 2")
end)

test("side 2's hits line toggles and sets levels as side 1 did", function()
  lane_side_arrangement(function(context, S, pane, arrangement)
    S.lib.grid_pages_patterns.pick(pane.port, 3)
    local first, last = shown_columns(pane)
    local positions = last - first + 1
    local step = first + 2
    pane.press(step, LINE.hits, 1)
    context.clock.run_for(0.2)
    pane.press(step, LINE.hits, 0)
    assert_equal(S.patterns[3][step], 15, arrangement .. ": a tap toggles the picked voice's step on")
    assert_equal(pane.led(step, LINE.hits), 15, arrangement .. ": and lights it")
    pane.tap(step, LINE.hits)
    assert_equal(S.patterns[3][step], 0, arrangement .. ": and off")
    S.patterns[3][first] = 5
    pane.press(first, LINE.hits, 1)
    pane.press(last, LINE.hits, 1)
    assert_equal(S.patterns[3][first], 15, arrangement .. ": the last shown key is 15")
    pane.press(last, LINE.hits, 0)
    local middle = first + positions / 2 - 1
    pane.press(middle, LINE.hits, 1)
    assert_equal(S.patterns[3][first], 8, arrangement .. ": the half-way key sets 8")
    pane.press(middle, LINE.hits, 0)
    pane.press(first, LINE.hits, 0)
    assert_equal(S.patterns[3][first], 8, arrangement .. ": neither release toggles")
    assert_equal(S.patterns[3][last] + S.patterns[3][middle], 0, arrangement .. ": the level keys toggled nothing")
    -- the 0.3 s hold opens the step editor, as on side 1
    pane.press(step, LINE.hits, 1)
    context.clock.run_for(0.35)
    assert_equal(shown_step_editor(), "3 " .. step .. " 1", arrangement .. ": the picked voice's step editor")
    pane.press(step, LINE.hits, 0)
    assert_equal(shown_step_editor(), nil, arrangement .. ": closed at the release")
  end)
end)

test("in move the hits line's second key sets value A and the step lights at it", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    params:set("v1_seq_gate", mode_index(S, "move"))
    local first = shown_columns(pane)
    -- key 9 held, key 12 of 16 (on a half: its second key, key 6 of 8)
    local held = first + (arrangement:match("^64") and 1 or 8)
    S.lib.sequencer.set_level(1, held, 9)
    pane.press(held, LINE.hits, 1)
    pane.press(at_share(pane, 12), LINE.hits, 1)
    assert_equal(S.lib.sequencer.step_attr(1, held, "va"), 11, arrangement .. ": va is round(12 * 15 / 16) = 11")
    assert_equal(S.patterns[1][held], 9, arrangement .. ": its level unchanged")
    pane.press(at_share(pane, 12), LINE.hits, 0)
    pane.press(held, LINE.hits, 0)
    assert_equal(S.patterns[1][held], 9, arrangement .. ": the release toggles nothing")
    assert_equal(S.patterns[1][at_share(pane, 12)], 0, arrangement .. ": nor the second key")
    assert_equal(pane.led(held, LINE.hits), 11, arrangement .. ": the step lights at its value A")
  end)
end)

test("a value cell takes its level from a second key", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    local seq = S.lib.sequencer
    pane.press(first, LINE.a, 1)
    for _, case in ipairs({{12, 11}, {16, 15}, {8, 8}}) do
      pane.press(at_share(pane, case[1]), LINE.a, 1)
      assert_equal(seq.step_attr(1, first, "va"), case[2], arrangement .. ": key " .. case[1] .. " of 16 sets " .. case[2])
      pane.press(at_share(pane, case[1]), LINE.a, 0)
    end
    pane.press(first, LINE.a, 0)
    assert_equal(seq.step_attr(1, first, "va"), 8, arrangement .. ": the release taps nothing")
    assert_equal(seq.step_attr(1, at_share(pane, 12), "va"), nil, arrangement .. ": the second keys set no cell of their own")
    assert_equal(pane.led(first, LINE.a), 8, arrangement .. ": the cell lights its value")
    -- value B the same
    pane.press(first + 1, LINE.b, 1)
    pane.press(at_share(pane, 12), LINE.b, 1)
    pane.press(at_share(pane, 12), LINE.b, 0)
    pane.press(first + 1, LINE.b, 0)
    assert_equal(seq.step_attr(1, first + 1, "vb"), 11, arrangement .. ": value B's cell")
  end)
end)

test("a tap clears a set cell and gives an empty one the last value", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    local seq = S.lib.sequencer
    pane.tap(first, LINE.a)
    assert_equal(seq.step_attr(1, first, "va"), 15, arrangement .. ": before any value is set, a value lane's top")
    pane.tap(first, LINE.a)
    assert_equal(seq.step_attr(1, first, "va"), nil, arrangement .. ": a tap clears a set cell")
    pane.press(first + 1, LINE.a, 1)
    pane.press(at_share(pane, 8), LINE.a, 1)
    pane.press(at_share(pane, 8), LINE.a, 0)
    pane.press(first + 1, LINE.a, 0)
    pane.tap(first + 2, LINE.a)
    assert_equal(seq.step_attr(1, first + 2, "va"), 8, arrangement .. ": an empty cell takes the value last set on the lane")
    pane.tap(first, LINE.b)
    assert_equal(seq.step_attr(1, first, "vb"), 15, arrangement .. ": each lane its own last value")
    pane.tap(first, LINE.chance)
    assert_equal(seq.step_attr(1, first, "prob"), 53, arrangement .. ": chance's first value, 53 %")
    pane.tap(first, LINE.repeats)
    assert_equal(seq.step_attr(1, first, "ratchet"), 2, arrangement .. ": repeats' first value, 2")
    params:set("v1_seq_gate_length", 2)
    pane.tap(first, LINE.gate)
    assert_equal(seq.step_attr(1, first, "gate"), params:get("v1_seq_gate_length"),
      arrangement .. ": gate's first value, the voice's gate length (2)")
    -- the last value is the port's, whatever the voice
    S.lib.grid_pages_patterns.pick(pane.port, 2)
    pane.tap(first, LINE.a)
    assert_equal(seq.step_attr(2, first, "va"), 8, arrangement .. ": voice 2's empty cell takes the port's last value")
  end)
end)

test("chance, repeats and gate cells write prob, ratchet and gate", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    local seq = S.lib.sequencer
    for _, line in ipairs({LINE.chance, LINE.repeats, LINE.gate}) do
      pane.press(first, line, 1)
      pane.press(at_share(pane, 8), line, 1)
      pane.press(at_share(pane, 8), line, 0)
      pane.press(first, line, 0)
    end
    assert_equal(seq.step_attr(1, first, "prob"), 53, arrangement .. ": round(8 * 100 / 15) = 53")
    assert_equal(seq.step_attr(1, first, "ratchet"), 2, arrangement .. ": max(1, round(8 * 4 / 16)) = 2")
    local spec = params:lookup_param("v1_seq_gate_length").controlspec
    assert_true(math.abs(seq.step_attr(1, first, "gate") - spec:map(7 / 14)) < 1e-9,
      arrangement .. ": the eighth of fifteen steps on the gate's scale, saw " .. tostring(seq.step_attr(1, first, "gate")))
    assert_equal(pane.led(first, LINE.chance), 8, arrangement .. ": chance lights max(1, round(53 * 15 / 100)) = 8")
    assert_equal(pane.led(first, LINE.repeats), 8, arrangement .. ": 2 repeats light 8")
    assert_equal(pane.led(first, LINE.gate), 8, arrangement .. ": the gate lights its place, 8")
    -- the lights' other values
    seq.set_level(1, first + 1, 15)
    assert_equal(pane.led(first + 1, LINE.chance), 15, arrangement .. ": a set step with no prob lights 15")
    assert_equal(pane.led(first + 2, LINE.chance), 0, arrangement .. ": an empty one is dark")
    seq.set_step_attr(1, first + 1, "prob", 0)
    assert_equal(pane.led(first + 1, LINE.chance), 1, arrangement .. ": a chance of 0 lights 1")
    for ratchet, light in ipairs({4, 8, 11, 15}) do
      seq.set_step_attr(1, first + 1, "ratchet", ratchet)
      assert_equal(pane.led(first + 1, LINE.repeats), light, arrangement .. ": " .. ratchet .. " repeats light " .. light)
    end
    seq.set_step_attr(1, first + 1, "gate", spec.maxval)
    assert_equal(pane.led(first + 1, LINE.gate), 15, arrangement .. ": the longest gate lights 15")
    seq.set_step_attr(1, first + 1, "gate", spec.minval)
    assert_equal(pane.led(first + 1, LINE.gate), 1, arrangement .. ": the shortest 1")
  end)
end)

-- Arm LN where the pane shows it (a 64's left half), then show `half`
local function arm_ln(S, pane, arrangement, half)
  show_half_of(S, pane, arrangement, KEY.ln)
  pane.tap(KEY.ln, LINE.utility)
  if half then lane_side(S, pane, half) end
end

test("LN armed lights the lengths; the next lane key sets one and disarms; the same key again sets it back to following", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    local half = arrangement == "64 right" and 2 or nil
    local lanes = S.lib.lanes
    params:set("v1_seq_length", 12)
    show_half_of(S, pane, arrangement, KEY.ln)
    assert_equal(pane.led(KEY.ln, LINE.utility), 4, arrangement .. ": LN unarmed at 4")
    arm_ln(S, pane, arrangement)
    assert_equal(pane.led(KEY.ln, LINE.utility), 15, arrangement .. ": LN armed at 15")
    if half then lane_side(S, pane, half) end
    local first, last = shown_columns(pane)
    for x = first, last do
      local inside = x <= 12
      assert_equal(pane.led(x, LINE.hits), inside and 8 or 0, arrangement .. ": the hits up to the voice's length at 8, x " .. x)
      for line = LINE.a, LINE.gate do
        assert_equal(pane.led(x, line), inside and 3 or 0, arrangement .. ": a following lane at 3 up to the voice's, x " .. x)
      end
    end
    local x = first + 4
    pane.press(x, LINE.a, 1)
    assert_equal(lanes.length(1, "a"), x, arrangement .. ": the key sets lane A's length")
    pane.press(x, LINE.a, 0)
    assert_equal(S.lib.sequencer.step_attr(1, x, "va"), nil, arrangement .. ": and taps no cell")
    show_half_of(S, pane, arrangement, KEY.ln)
    assert_equal(pane.led(KEY.ln, LINE.utility), 4, arrangement .. ": and LN disarmed")
    arm_ln(S, pane, arrangement, half)
    assert_equal(pane.led(x, LINE.a), 8, arrangement .. ": a free lane at 8 up to its length")
    if x < last then assert_equal(pane.led(x + 1, LINE.a), 0, arrangement .. ": dark past it") end
    pane.tap(x, LINE.a)
    assert_equal(lanes.length(1, "a"), nil, arrangement .. ": the key at its length sets it back to following")
    -- LN again disarms
    arm_ln(S, pane, arrangement)
    pane.tap(KEY.ln, LINE.utility)
    assert_equal(pane.led(KEY.ln, LINE.utility), 4, arrangement .. ": LN tapped again disarms")
    if half then lane_side(S, pane, half) end
    pane.tap(x, LINE.chance)
    assert_equal(lanes.length(1, "chance"), nil, arrangement .. ": disarmed, a lane key is a cell again")
    assert_equal(S.lib.sequencer.step_attr(1, x, "prob"), 53, arrangement .. ": its tap gives the cell a value")
  end)
end)

test("LN on line 1 sets the voice's length", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    local half = arrangement == "64 right" and 2 or nil
    arm_ln(S, pane, arrangement, half)
    local first = shown_columns(pane)
    local x = first + 5
    pane.tap(x, LINE.hits)
    assert_equal(params:get("v1_seq_length"), x, arrangement .. ": the voice's length")
    assert_equal(S.patterns[1][x], 0, arrangement .. ": the key toggles nothing")
    show_half_of(S, pane, arrangement, KEY.ln)
    assert_equal(pane.led(KEY.ln, LINE.utility), 4, arrangement .. ": LN disarmed")
  end)
end)

test("LN stays armed across a 64's half change; a page or a side change disarms", function()
  for _, arrangement in ipairs({"64 left", "64 right"}) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    local pane = grid_pane(context, arrangement)
    lane_side(S, pane)
    arm_ln(S, pane, arrangement, 2)
    pane.tap(12, LINE.b)
    assert_equal(S.lib.lanes.length(1, "b"), 12, arrangement .. ": armed on the left half, set on the right")
    arm_ln(S, pane, arrangement)
    pane.show(S.constants.GRID_PAGES.voices)
    pane.show(S.constants.GRID_PAGES.patterns)
    lane_side(S, pane, 1)
    assert_equal(pane.led(KEY.ln, LINE.utility), 4, arrangement .. ": a page change disarmed it")
    pane.tap(KEY.ln, LINE.utility)
    pane.show(S.constants.GRID_PAGES.patterns, 1, 1)
    lane_side(S, pane, 1)
    assert_equal(pane.led(KEY.ln, LINE.utility), 4, arrangement .. ": a side change disarmed it")
  end
end)

test("the mode keys choose the mode; a gate voice lights pulse at 8", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    show_half_of(S, pane, arrangement, KEY.pulse)
    local seq = S.lib.sequencer
    local function lights() return pane.led(KEY.pulse, LINE.utility) .. " " .. pane.led(KEY.move, LINE.utility)
      .. " " .. pane.led(KEY.accent, LINE.utility) end
    assert_equal(lights(), "15 4 4", arrangement .. ": pulse, the default")
    seq.set_level(1, 2, 15)
    pane.tap(KEY.move, LINE.utility)
    assert_equal(seq.step_mode(1), "move", arrangement .. ": move")
    assert_true(seq.step_attr(1, 2, "va") ~= nil, arrangement .. ": chosen by hand: the set step has a value A")
    assert_equal(lights(), "4 15 4", arrangement)
    pane.tap(KEY.accent, LINE.utility)
    assert_equal(seq.step_mode(1), "accent", arrangement .. ": accent")
    assert_equal(lights(), "4 4 15", arrangement)
    pane.tap(KEY.pulse, LINE.utility)
    assert_equal(seq.step_mode(1), "pulse", arrangement .. ": pulse")
    params:set("v1_seq_gate", mode_index(S, "gate"))
    grid_redraw()
    assert_equal(lights(), "8 4 4", arrangement .. ": a gate voice lights pulse at 8")
  end)
end)

test("a tap sets target A, with B held target B, and B's lit key turns it off", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    show_half_of(S, pane, arrangement, KEY.position)
    local lanes = S.lib.lanes
    local function light(key) return pane.led(KEY[key], LINE.utility) end
    assert_equal(light("pitch"), 10, arrangement .. ": A auto on a synth voice: pitch at 10")
    assert_equal(light("position") + light("size") + light("cutoff"), 6, arrangement .. ": the others at 2")
    pane.tap(KEY.position, LINE.utility)
    assert_equal(lanes.target(1, "a"), "position", arrangement .. ": a tap sets A's")
    assert_equal(light("position"), 15, arrangement .. ": A's at 15")
    assert_equal(light("pitch"), 2, arrangement)
    if pane.shows(KEY.b, LINE.utility) then
      pane.press(KEY.b, LINE.utility, 1)
      pane.tap(KEY.size, LINE.utility)
      assert_equal(lanes.target(1, "b"), "size", arrangement .. ": with B held a tap sets B's")
      assert_equal(lanes.target(1, "a"), "position", arrangement .. ": A's left alone")
      assert_equal(light("size"), 8, arrangement .. ": B's at 8")
      pane.tap(KEY.size, LINE.utility)
      assert_equal(lanes.target(1, "b"), nil, arrangement .. ": B's lit key turns B off")
      assert_equal(params:get("v1_seq_move_b"), 1, arrangement .. ": off")
      pane.press(KEY.b, LINE.utility, 0)
      assert_equal(light("size"), 2, arrangement)
    end
  end)
end)

test("choosing cutoff opens a closed filter", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    show_half_of(S, pane, arrangement, KEY.cutoff)
    params:set("v1_filter_mix", 0)
    pane.tap(KEY.cutoff, LINE.utility)
    assert_equal(S.lib.lanes.target(1, "a"), "cutoff", arrangement)
    assert_equal(params:get("v1_filter_mix"), 1, arrangement .. ": the filter opened")
  end)
end)

test("a voice key picks, and the pick is lit", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    show_half_of(S, pane, arrangement, KEY.first_voice)
    local patterns = S.lib.grid_pages_patterns
    assert_equal(pane.led(KEY.first_voice, LINE.utility), 15, arrangement .. ": voice 1 picked")
    for voice_idx = 2, S.constants.NUM_VOICES do
      assert_equal(pane.led(KEY.first_voice + voice_idx - 1, LINE.utility), 4, arrangement .. ": voice " .. voice_idx)
    end
    S.patterns[4][16] = 6
    pane.tap(KEY.first_voice + 3, LINE.utility)
    assert_equal(patterns.voice(pane.port), 4, arrangement .. ": a tap picks voice 4")
    assert_equal(pane.led(KEY.first_voice + 3, LINE.utility), 15, arrangement .. ": lit 15")
    assert_equal(pane.led(KEY.first_voice, LINE.utility), 4, arrangement .. ": voice 1 at 4")
    assert_equal(pane.led(16, LINE.hits), 6, arrangement .. ": the hits line is voice 4's")
  end)
end)

test("each lane lights the cell it last read", function()
  lane_side_arrangement(function(context, S, pane, arrangement)
    local seq, PATTERN_LENGTH = S.lib.sequencer, S.constants.PATTERN_LENGTH
    for step = 1, PATTERN_LENGTH do
      seq.set_level(1, step, 15)
      seq.set_step_attr(1, step, "va", 6)
    end
    S.lib.lanes.set_length(1, "a", 5)
    pattern_toggle()
    for _ = 1, 6 do h.wake(context, "pattern_clock") end
    grid_redraw()
    assert_equal(seq.sounding_step(1), 7, "the hits at step 7")
    local function expect(x, line, level, what)
      if pane.shows(x, line) then assert_equal(pane.led(x, line), level, arrangement .. ": " .. what) end
    end
    expect(7, LINE.hits, 15, "the hits' step 7")
    expect(2, LINE.a, 15, "lane A of 5 read cell 2: 15, it holds a value")
    expect(1, LINE.a, 6, "its other cells at their value")
    expect(5, LINE.a, 6, "the last cell of its length")
    for x = 6, PATTERN_LENGTH do expect(x, LINE.a, 1, "past its length a cell that holds something at 1, x " .. x) end
    expect(7, LINE.b, 4, "following lane B read step 7, which holds nothing: 4")
    expect(8, LINE.b, 0, "its other cells dark")
    expect(7, LINE.chance, 15, "chance follows: step 7 is set and plays always")
    pattern_toggle()
  end)
end)

test("value B's line is dim where B names A's target", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    S.lib.sequencer.set_step_attr(1, first, "vb", 12)
    grid_redraw()
    assert_equal(pane.led(first, LINE.b), 12, arrangement .. ": B off: the cell at its value")
    S.lib.lanes.choose_target(1, "b", "pitch")
    grid_redraw()
    assert_equal(pane.led(first, LINE.b), 2, arrangement .. ": B names auto A's pitch: 2")
    S.lib.lanes.choose_target(1, "b", "size")
    grid_redraw()
    assert_equal(pane.led(first, LINE.b), 12, arrangement .. ": B its own target: its value")
  end)
end)

test("the 64 shows each half of side 2", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local left = grid_pane(context, "64 left")
  lane_side(S, left, 1)
  assert_equal(left.led(KEY.pulse, LINE.utility), 15, "the left half: the mode keys")
  assert_equal(left.led(KEY.ln, LINE.utility), 4, "LN")
  assert_equal(left.led(KEY.pitch, LINE.utility), 10, "the targets")
  assert_true(not left.shows(KEY.b, LINE.utility), "B is on the right half")
  local right = grid_pane(context, "64 right")
  lane_side(S, right, 2)
  assert_true(right.shows(KEY.b, LINE.utility), "the right half: B")
  assert_equal(right.led(KEY.first_voice, LINE.utility), 15, "and the voices: voice 1 picked")
  assert_equal(right.led(KEY.first_voice + 1, LINE.utility), 4)
  assert_true(not right.shows(KEY.ln, LINE.utility), "LN is on the left half")
end)

test("LN is disarmed after the 8x8's chooser goes to another page and back to side 2", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = grid_pane(context, "64 left")
  lane_side(S, pane, 1)
  pane.tap(KEY.ln, LINE.utility)
  local function chooser(page, row)
    pane.press(NV, STRIP_LINE, 1)
    context.clock.run_for(0.55)
    -- chooser key (page, row) is physical: the right half's pane x is 8 on
    pane.tap(page + (S.lib.grid_core.half(1, 1) == 2 and 8 or 0), row)
    pane.press(NV, STRIP_LINE, 0)
  end
  chooser(S.constants.GRID_PAGES.patterns, 4)  -- side 2's right half: a half change
  assert_true(S.lib.grid_pages_patterns.ln_armed(1, 1), "a half change by the chooser keeps LN armed")
  chooser(S.constants.GRID_PAGES.sources, 1)
  chooser(S.constants.GRID_PAGES.patterns, 3)
  assert_equal(S.lib.grid_core.view(1, 1), "1:" .. S.constants.GRID_PAGES.patterns .. ":2:1", "back on side 2")
  assert_equal(pane.led(KEY.ln, LINE.utility), 4, "LN is disarmed")
  pane.tap(5, LINE.a)
  assert_equal(S.lib.lanes.length(1, "a"), nil, "and a lane key is a cell again")
end)

test("a value written on an off step turns the step on", function()
  lane_side_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    local seq = S.lib.sequencer
    -- a value A cell's second key on step `first`, off
    pane.press(first, LINE.a, 1)
    pane.press(at_share(pane, 12), LINE.a, 1)
    pane.press(at_share(pane, 12), LINE.a, 0)
    pane.press(first, LINE.a, 0)
    assert_equal(seq.step_attr(1, first, "va"), 11, arrangement .. ": the value set")
    assert_equal(S.patterns[1][first], 15, arrangement .. ": and its step turned on at a tap's level")
    -- a value B cell's tap on an off step
    pane.tap(first + 1, LINE.b)
    assert_equal(seq.step_attr(1, first + 1, "vb"), 15, arrangement .. ": a tap gives value B")
    assert_equal(S.patterns[1][first + 1], 15, arrangement .. ": and turns its step on")
    -- a set step keeps its level
    seq.set_level(1, first + 2, 6)
    pane.tap(first + 2, LINE.a)
    assert_equal(S.patterns[1][first + 2], 6, arrangement .. ": a set step keeps its level")
    -- a free lane's cell is no step's: its step is left off
    S.lib.lanes.set_length(1, "b", 16)
    pane.tap(first + 3, LINE.b)
    assert_equal(seq.step_attr(1, first + 3, "vb"), 15, arrangement .. ": a free lane's cell takes its value")
    assert_equal(S.patterns[1][first + 3], 0, arrangement .. ": and its step stays off")
    -- in move, the hits line's second key on an off step
    params:set("v1_seq_gate", mode_index(S, "move"))
    local held = first + 4
    pane.press(held, LINE.hits, 1)
    pane.press(at_share(pane, 8), LINE.hits, 1)
    pane.press(at_share(pane, 8), LINE.hits, 0)
    pane.press(held, LINE.hits, 0)
    assert_equal(seq.step_attr(1, held, "va"), 8, arrangement .. ": move: value A set")
    assert_equal(S.patterns[1][held], 15, arrangement .. ": and the step turned on")
  end)
end)

test("on side 1 the picked line's empty steps past the voice's length stay dark", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first, last = shown_columns(pane)
    params:set("v1_seq_length", 12)
    S.lib.sequencer.set_level(1, 14, 9)
    grid_redraw()
    for x = first, last do
      local expected = (x == 14 and 1) or (x <= 12 and 1) or 0
      assert_equal(pane.led(x, 1), expected,
        arrangement .. ": step " .. x .. (x > 12 and " past the length" or "") .. (x == 14 and ", set, at 1" or ""))
    end
  end)
end)

test("side 1 lights a move voice's steps at their value A", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    local seq = S.lib.sequencer
    params:set("v2_seq_gate", mode_index(S, "move"))
    seq.set_level(2, first, 15)
    seq.set_step_attr(2, first, "va", 7)
    seq.set_level(2, first + 1, 15)
    seq.set_step_attr(2, first + 1, "va", nil)
    grid_redraw()
    assert_equal(pane.led(first, 2), 7, arrangement .. ": a step at its value A")
    assert_equal(pane.led(first + 1, 2), 4, arrangement .. ": a step with none at 4")
  end)
end)

test("the picked voice is what pane.state() holds", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = grid_pane(context, "128h")
  pane.show(S.constants.GRID_PAGES.patterns)
  local record = S.lib.grid_pages_patterns.record
  local press, seen = record.press, nil
  record.press = function(page_pane, ...)
    seen = page_pane
    return press(page_pane, ...)
  end
  pane.tap(2, 6)
  record.press = press
  assert_true(seen ~= nil, "the page's press got its pane")
  assert_equal(seen.state().voice, 6, "the press's pick is in pane.state()")
  assert_equal(S.lib.grid_pages_patterns.voice(1), 6)
  seen.state().voice = 3
  assert_equal(S.lib.grid_pages_patterns.voice(1), 3, "voice(port) reads pane.state()")
end)

-- The patterns LN machine: a 64 on port 1, its pane on patterns' side 2,
-- left half; armed by a tap of LN; the lane key is (5, 2), lane A
local function ln_enter(armed)
  return function(context)
    local S = local_value("S")
    local pane = grid_pane(context, "64 left")
    pane.show(S.constants.GRID_PAGES.patterns, PATTERNS_SIDE2, 1)
    if armed then pane.tap(KEY.ln, LINE.utility) end
  end
end
local function ln_armed() return local_value("S").lib.grid_pages_patterns.ln_armed(1, 1) end
-- back on side 2 the way a player comes back to it: side 1, then side 2
local function ln_back()
  local S = local_value("S")
  local core, page = S.lib.grid_core, S.constants.GRID_PAGES.patterns
  core.set_page(1, page, 1, 1); grid_redraw()
  core.set_page(1, page, 1, PATTERNS_SIDE2); core.set_half(1, 1, 1); grid_redraw()
end
local function ln_off_on_return()
  ln_back()
  assert_true(not ln_armed(), "back on side 2, LN is not armed")
end
-- the 8x8's chooser (NV held 0.5 s, a chooser key, NV let go) to a page and
-- side, left half
local function ln_chooser(context, page, side)
  local pane = grid_pane(context, "64 left")
  pane.press(NV, STRIP_LINE, 1)
  context.clock.run_for(0.55)
  pane.tap(page, side == PATTERNS_SIDE2 and 3 or 1)
  pane.press(NV, STRIP_LINE, 0)
end
local function ln_forgotten()
  assert_equal(local_value("S").lib.grid_core.existing_port_state(1), nil, "the port's state is forgotten")
end
h.transition_table({
  name = "patterns LN",
  notes = {"docs/notes/lua/grid/pages/patterns.md", "patterns LN"},
  states = {off = ln_enter(false), armed = ln_enter(true)},
  events = {
    ["LN tap"] = function(context) grid_pane(context, "64 left").tap(KEY.ln, LINE.utility) end,
    ["lane key"] = function(context) grid_pane(context, "64 left").tap(5, LINE.a) end,
    ["voice key"] = function(context)
      local right = grid_pane(context, "64 right")
      right.tap(KEY.first_voice + 2, LINE.utility)
      local_value("S").lib.grid_core.set_half(1, 1, 1); grid_redraw()
    end,
    ["side change"] = function()
      local S = local_value("S")
      S.lib.grid_core.set_page(1, S.constants.GRID_PAGES.patterns, 1, 1); grid_redraw()
    end,
    ["page change"] = function()
      local S = local_value("S")
      S.lib.grid_core.set_page(1, S.constants.GRID_PAGES.voices, 1, 1); grid_redraw()
    end,
    ["half change"] = function() local_value("S").lib.grid_core.set_half(1, 1, 2); grid_redraw() end,
    ["unplug"] = function(context) context.grid.unplug(1) end,
    ["chooser away and back"] = function(context)
      local S = local_value("S")
      ln_chooser(context, S.constants.GRID_PAGES.sources, 1)
      ln_chooser(context, S.constants.GRID_PAGES.patterns, PATTERNS_SIDE2)
    end,
  },
  state_of = function() return ln_armed() and "armed" or "off" end,
  rows = {
    {"off", "LN tap", "armed", check = function(context)
      local pane = grid_pane(context, "64 left")
      assert_equal(pane.led(KEY.ln, LINE.utility), 15, "LN lights 15")
      assert_equal(pane.led(1, LINE.hits), 8, "the hits line shows the voice's length at 8")
      assert_equal(pane.led(1, LINE.b), 3, "a following lane at 3")
    end},
    {"off", "lane key", "off", check = function()
      local S = local_value("S")
      assert_equal(S.lib.sequencer.step_attr(1, 5, "va"), 15, "the tap gives the cell a value")
      assert_equal(S.patterns[1][5], 15, "and turns its step on")
    end},
    {"off", "voice key", "off", check = function()
      assert_equal(local_value("S").lib.grid_pages_patterns.voice(1), 3, "voice 3 picked")
    end},
    {"off", "side change", "off"},
    {"off", "page change", "off"},
    {"off", "half change", "off"},
    {"off", "unplug", "off", check = ln_forgotten},
    {"off", "chooser away and back", "off"},
    {"armed", "LN tap", "off"},
    {"armed", "lane key", "off", check = function()
      local S = local_value("S")
      assert_equal(S.lib.lanes.length(1, "a"), 5, "lane A's length set")
      assert_equal(S.lib.sequencer.step_attr(1, 5, "va"), nil, "no cell tapped")
    end},
    {"armed", "voice key", "armed", check = function()
      assert_equal(local_value("S").lib.grid_pages_patterns.voice(1), 3, "voice 3 picked, LN still armed")
    end},
    {"armed", "side change", "off", check = ln_off_on_return},
    {"armed", "page change", "off", check = ln_off_on_return},
    {"armed", "half change", "armed", check = function(context)
      grid_pane(context, "64 right").tap(12, LINE.gate)
      assert_equal(local_value("S").lib.lanes.length(1, "gate"), 12, "a lane key of the other half sets its length")
    end},
    {"armed", "chooser away and back", "off", check = function()
      assert_equal(local_value("S").lib.grid_core.view(1, 1), "1:1:2:1", "back on side 2's left half")
    end},
    {"armed", "unplug", "off", check = function(context)
      ln_forgotten()
      context.grid.plug(1, 8, 8)
      ln_back()
      assert_true(not ln_armed(), "plugged back, LN is not armed")
    end},
  },
})

-- 3.9's step view (package 3c, design section 4) ---------------------------

-- A bar's lit keys light 10 (the brief's level)
local BAR_LIT = 10

-- The other pane of a 256 arrangement, or nil
local function other_256_pane(arrangement)
  if arrangement == "256 top" then return "256 bottom" end
  if arrangement == "256 bottom" then return "256 top" end
  return nil
end

-- The key that opens the view on the arrangement's pane, side 2 shown
-- there: on a 256 voice 1's step 3 on the other pane's side 1; elsewhere
-- side 2's hits line, its third key shown (voice 1, the picked one)
local function view_key(context, S, pane, arrangement)
  lane_side(S, pane)
  local other = other_256_pane(arrangement)
  local key = {pane = pane, x = shown_columns(pane) + 2, y = LINE.hits}
  if other then
    key.pane = grid_pane(context, other)
    key.pane.show(S.constants.GRID_PAGES.patterns)
    key.x, key.y = 3, 1
  end
  key.step = key.x
  function key.press(z) key.pane.press(key.x, key.y, z) end
  return key
end

-- Hold the view's key past the editor's hold: the view opens on the pane
local function hold_into_view(context, S, pane, arrangement)
  local key = view_key(context, S, pane, arrangement)
  key.press(1)
  context.clock.run_for(0.35)
  return key
end

-- A line's lights along the keys shown, as one string
local function bar(pane, line)
  local first, last = shown_columns(pane)
  local lights = {}
  for x = first, last do lights[#lights + 1] = tostring(pane.led(x, line)) end
  return table.concat(lights, " ")
end

-- The bar a value whose key is at_share(p16) shows: lit to it, dark beyond
-- (p16 0: dark)
local function lit_to(pane, p16)
  local first, last = shown_columns(pane)
  local to = p16 == 0 and first - 1 or at_share(pane, p16)
  local lights = {}
  for x = first, last do lights[#lights + 1] = tostring(x <= to and BAR_LIT or 0) end
  return table.concat(lights, " ")
end

-- The last lit key of a bar, or nil
local function last_lit(pane, line)
  local first, last = shown_columns(pane)
  local found
  for x = first, last do if pane.led(x, line) == BAR_LIT then found = x end end
  return found
end

local function k2() key(2, 1); key(2, 0) end

-- The core's still for the press now down at the harness pane's (x, y),
-- through the layout's own map (S.lib.grid_pane.physical), as the harness
-- finds its keys
local function key_still(S, pane, x, y)
  local core = S.lib.grid_core
  local px, py = S.lib.grid_pane.physical(core.layout_of(pane.port), pane.pane, x, y, core.half(pane.port, pane.pane))
  return core.still(pane.port, px, py)
end

test("a held step opens the editor, and the step view where the port shows side 2", function()
  lane_side_arrangement(function(context, S, pane, arrangement)
    local core, seq = S.lib.grid_core, S.lib.sequencer
    local key = view_key(context, S, pane, arrangement)
    seq.set_level(1, key.step, 8)
    seq.set_step_attr(1, key.step, "va", 8)
    key.press(1)
    context.clock.run_for(0.35)
    assert_equal(shown_step_editor(), "1 " .. key.step .. " 1", arrangement .. ": the editor opens for the step")
    local view = core.step_view(pane.port)
    assert_true(view ~= nil, arrangement .. ": and the step view")
    assert_equal(view.voice .. " " .. view.step .. " " .. view.pane, "1 " .. key.step .. " " .. pane.pane,
      arrangement .. ": for the step, on the pane showing side 2")
    assert_equal(bar(pane, LINE.hits), lit_to(pane, 8), arrangement .. ": line 1 its level, lit to key 8 at 10")
    assert_equal(bar(pane, LINE.a), lit_to(pane, 8), arrangement .. ": line 2 its value A")
    assert_equal(bar(pane, LINE.b), lit_to(pane, 0), arrangement .. ": line 3 dark with no value B")
    assert_equal(bar(pane, LINE.chance), lit_to(pane, 16), arrangement .. ": a set step with no chance plays always: 100")
    assert_equal(bar(pane, LINE.utility), lit_to(pane, 0), arrangement .. ": line 7 is dark")
    key.press(0)
    assert_equal(core.step_view(pane.port), nil, arrangement .. ": its release ends both")
    assert_equal(shown_step_editor(), nil, arrangement)
  end)
end)

test("with no side 2 shown the hold opens the editor alone and the pane stays the page", function()
  each_arrangement(function(context, S, pane, arrangement)
    local other = other_256_pane(arrangement)
    if other then grid_pane(context, other).show(S.constants.GRID_PAGES.patterns) end
    local first = shown_columns(pane)
    local before = bar(pane, 1)
    pane.press(first + 2, 1, 1)
    context.clock.run_for(0.35)
    assert_equal(shown_step_editor(), "1 " .. (first + 2) .. " 1", arrangement .. ": the editor opens")
    assert_equal(S.lib.grid_core.step_view(pane.port), nil, arrangement .. ": no step view")
    assert_equal(bar(pane, 1), before, arrangement .. ": the pane still shows side 1's steps")
    pane.press(first + 2, 1, 0)
  end)
end)

test("a bar key sets the step's value and the screen's row shows it", function()
  lane_side_arrangement(function(context, S, pane, arrangement)
    local seq = S.lib.sequencer
    local key = hold_into_view(context, S, pane, arrangement)
    pane.tap(at_share(pane, 8), LINE.chance)
    assert_equal(seq.step_attr(1, key.step, "prob"), 53, arrangement .. ": line 4 key 8: prob 53")
    context.screen.clear(); redraw()
    assert_true(h.screen_shows(context, "53%"), arrangement .. ": the step editor's prob row shows 53%")
    assert_equal(bar(pane, LINE.chance), lit_to(pane, 8), arrangement .. ": lit to key 8")
    pane.tap(at_share(pane, 8), LINE.hits)
    assert_equal(S.patterns[1][key.step], 8, arrangement .. ": line 1 key 8 sets the level 8")
    pane.tap(at_share(pane, 12), LINE.a)
    assert_equal(seq.step_attr(1, key.step, "va"), 11, arrangement .. ": line 2 key 12: value A 11")
    pane.tap(at_share(pane, 16), LINE.b)
    assert_equal(seq.step_attr(1, key.step, "vb"), 15, arrangement .. ": line 3 key 16: value B 15")
    pane.tap(at_share(pane, 8), LINE.repeats)
    assert_equal(seq.step_attr(1, key.step, "ratchet"), 2, arrangement .. ": line 5 key 8: 2 repeats")
    pane.tap(at_share(pane, 8), LINE.gate)
    local spec = params:lookup_param("v1_seq_gate_length").controlspec
    assert_true(math.abs(seq.step_attr(1, key.step, "gate") - spec:map(7 / 14)) < 1e-9,
      arrangement .. ": line 6 key 8: the eighth gate")
    assert_equal(bar(pane, LINE.gate), lit_to(pane, 8), arrangement .. ": lit to key 8")
    for x = 1, 16 do
      if pane.shows(x, LINE.utility) then pane.tap(x, LINE.utility) end
    end
    assert_equal(seq.step_mode(1), "pulse", arrangement .. ": line 7's keys do nothing")
    assert_equal(S.lib.grid_pages_patterns.voice(pane.port), 1, arrangement .. ": not even a voice pick")
    -- the screen's edits show on the bars at once, and the editor's step
    -- (ALT+E2) is the view's
    enc(3, -2)
    assert_equal(bar(pane, LINE.hits), lit_to(pane, 6), arrangement .. ": E3 on the editor's level shows at once")
    _G.key(1, 1); enc(2, 1); _G.key(1, 0)  -- the script's key (this test's `key` is the grid's)
    assert_equal(S.lib.grid_core.step_view(pane.port).step, key.step + 1, arrangement .. ": ALT+E2 moves the view's step")
    assert_equal(bar(pane, LINE.hits), lit_to(pane, 0), arrangement .. ": and the bars show it at once")
    key.press(0)
  end)
end)

test("the last key of a bar clears it", function()
  lane_side_arrangement(function(context, S, pane, arrangement)
    local seq = S.lib.sequencer
    local key = hold_into_view(context, S, pane, arrangement)
    for _, case in ipairs({{LINE.a, "va"}, {LINE.b, "vb"}, {LINE.chance, "prob"}, {LINE.repeats, "ratchet"},
        {LINE.gate, "gate"}}) do
      local line, attr = case[1], case[2]
      pane.tap(at_share(pane, 8), line)
      assert_true(seq.step_attr(1, key.step, attr) ~= nil, arrangement .. ": " .. attr .. " set")
      pane.tap(last_lit(pane, line), line)
      assert_equal(seq.step_attr(1, key.step, attr), nil, arrangement .. ": " .. attr .. "'s own last key clears it")
    end
    assert_equal(bar(pane, LINE.a), lit_to(pane, 0), arrangement .. ": value A dark once cleared")
    pane.tap(at_share(pane, 8), LINE.hits)
    pane.tap(last_lit(pane, LINE.hits), LINE.hits)
    assert_equal(S.patterns[1][key.step], 8, arrangement .. ": the level's own key sets it again, never clears")
    key.press(0)
  end)
end)

test("K2 closes the editor and the view with the key still down", function()
  lane_side_arrangement(function(context, S, pane, arrangement)
    local seq = S.lib.sequencer
    local key = hold_into_view(context, S, pane, arrangement)
    local bar_x = at_share(pane, 8)
    pane.press(bar_x, LINE.a, 1)  -- a bar key held across the view's end
    local bar_still = key_still(S, pane, bar_x, LINE.a)
    assert_true(bar_still(), arrangement .. ": the bar key's press is still down")
    k2()
    assert_equal(shown_step_editor(), nil, arrangement .. ": K2 closes the editor")
    assert_equal(S.lib.grid_core.step_view(pane.port), nil, arrangement .. ": and the view")
    -- a bar press makes no cell entry: the view's end shows in its still
    assert_true(not bar_still(), arrangement .. ": the view's end ended the held bar key's press (its still)")
    pane.press(bar_x, LINE.a, 0)
    assert_equal(seq.step_attr(1, bar_x, "va"), nil, arrangement .. ": the held bar key is spent: it taps nothing")
    key.press(0)
    assert_equal(seq.step_attr(1, key.step, "va"), 8, arrangement .. ": the bar key set value A before K2")
    assert_equal(S.patterns[1][key.step], 15, arrangement .. ": which turned the step on; the key's release toggled nothing")
    show_half_of(S, pane, arrangement, KEY.ln)
    assert_equal(pane.led(KEY.ln, LINE.utility), 4, arrangement .. ": the pane is the lane side again")
  end)
end)

test("the key's release closes both; the pane is the page again", function()
  lane_side_arrangement(function(context, S, pane, arrangement)
    local key = hold_into_view(context, S, pane, arrangement)
    assert_equal(bar(pane, LINE.utility), lit_to(pane, 0), arrangement .. ": the view's line 7 is dark")
    key.press(0)
    assert_equal(shown_step_editor(), nil, arrangement .. ": the release closes the editor")
    assert_equal(S.lib.grid_core.step_view(pane.port), nil, arrangement .. ": and the view")
    assert_equal(S.patterns[1][key.step], 0, arrangement .. ": and toggles nothing")
    show_half_of(S, pane, arrangement, KEY.ln)
    assert_equal(pane.led(KEY.ln, LINE.utility), 4, arrangement .. ": the pane is the lane side again")
  end)
end)

test("entering the view ends that pane's other held keys and leaves the opening key held", function()
  lane_side_arrangement(function(context, S, pane, arrangement)
    local seq = S.lib.sequencer
    local key = view_key(context, S, pane, arrangement)
    local cell = shown_columns(pane) + 5
    pane.press(cell, LINE.b, 1)  -- a held cell of the pane the view takes
    key.press(1)
    context.clock.run_for(0.35)
    assert_true(S.lib.grid_core.step_view(pane.port) ~= nil, arrangement .. ": the view opens")
    pane.press(cell, LINE.b, 0)
    assert_equal(seq.step_attr(1, cell, "vb"), nil, arrangement .. ": the held cell was ended: its release taps nothing")
    assert_equal(shown_step_editor(), "1 " .. key.step .. " 1", arrangement .. ": the opening key still holds the editor")
    pane.tap(at_share(pane, 8), LINE.a)
    assert_equal(seq.step_attr(1, key.step, "va"), 8, arrangement .. ": and the view")
    key.press(0)
    assert_equal(shown_step_editor(), nil, arrangement .. ": its release closes the editor")
    assert_equal(S.patterns[1][key.step], 15, arrangement .. ": value A turned it on; the release toggled nothing")
  end)
end)

test("a free lane's bar is dark and its keys set nothing", function()
  lane_side_arrangement(function(context, S, pane, arrangement)
    local seq = S.lib.sequencer
    local key = view_key(context, S, pane, arrangement)
    seq.set_step_attr(1, key.step, "prob", 53)
    S.lib.lanes.set_length(1, "chance", 5)
    key.press(1)
    context.clock.run_for(0.35)
    assert_equal(bar(pane, LINE.chance), lit_to(pane, 0), arrangement .. ": a free lane's line is dark")
    pane.tap(at_share(pane, 16), LINE.chance)
    assert_equal(seq.step_attr(1, key.step, "prob"), 53, arrangement .. ": and its keys set nothing")
    key.press(0)
  end)
end)

test("a lane cell held 0.3 s opens nothing", function()
  lane_side_arrangement(function(context, S, pane, arrangement)
    local first = shown_columns(pane)
    for line = LINE.a, LINE.gate do
      pane.press(first, line, 1)
      context.clock.run_for(0.35)
      assert_equal(shown_step_editor(), nil, arrangement .. ": line " .. line .. " opens no editor")
      assert_equal(S.lib.grid_core.step_view(pane.port), nil, arrangement .. ": and no view")
      pane.press(first, line, 0)
    end
  end)
end)

test("with side 2 on both panes of a 256 the view is the key's pane and the other stays the page", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local top, bottom = grid_pane(context, "256 top"), grid_pane(context, "256 bottom")
  top.show(S.constants.GRID_PAGES.patterns, PATTERNS_SIDE2)
  bottom.show(S.constants.GRID_PAGES.patterns, PATTERNS_SIDE2)
  top.press(3, LINE.hits, 1); context.clock.run_for(0.35)
  local view = S.lib.grid_core.step_view(1)
  assert_equal(view and view.pane, 1, "the view is the pane the key is on")
  assert_equal(top.led(KEY.ln, LINE.utility), 0, "the top pane is the view: line 7 dark")
  assert_equal(bottom.led(KEY.ln, LINE.utility), 4, "the bottom pane stays the lane side")
  bottom.tap(6, LINE.b)
  assert_equal(S.lib.sequencer.step_attr(1, 6, "vb"), 15, "and its cell keys still work: a tap gives cell 6 value B")
  assert_equal(S.lib.sequencer.step_attr(1, 3, "vb"), nil, "the view's step is untouched")
  bottom.show(S.constants.GRID_PAGES.voices)
  view = S.lib.grid_core.step_view(1)
  assert_equal(view and view.pane, 1, "the other pane's page change leaves the view where it is")
  top.press(3, LINE.hits, 0)
  assert_equal(S.lib.grid_core.step_view(1), nil, "the release ends it")
end)

test("LN armed before the view is still armed after it", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local top, bottom = grid_pane(context, "256 top"), grid_pane(context, "256 bottom")
  top.show(S.constants.GRID_PAGES.patterns)
  bottom.show(S.constants.GRID_PAGES.patterns, PATTERNS_SIDE2)
  bottom.tap(KEY.ln, LINE.utility)
  assert_equal(bottom.led(KEY.ln, LINE.utility), 15, "LN armed")
  top.press(5, 1, 1); context.clock.run_for(0.35)
  assert_true(S.lib.grid_core.step_view(1) ~= nil, "the view is open on the bottom pane")
  bottom.tap(8, LINE.chance)
  assert_equal(S.lib.sequencer.step_attr(1, 5, "prob"), 53, "the view's keys are the bars, not LN's")
  assert_equal(S.lib.lanes.length(1, "chance"), nil, "no length set while the view shows")
  top.press(5, 1, 0)
  assert_equal(bottom.led(KEY.ln, LINE.utility), 15, "the view is no page change: LN is still armed")
  bottom.tap(9, LINE.gate)
  assert_equal(S.lib.lanes.length(1, "gate"), 9, "and the next lane key sets a length")
end)

-- The step view's table (docs/notes/lua/grid/keys.md, ### step view), on a
-- 256 on port 1: the top pane shows patterns' side 1, where the key (5, 1)
-- is voice 1's step 5; the bottom pane shows side 2 in "closed" and "open"
-- (the view's pane), side 1 in the other two states. The bar key is (8, 4)
-- of the bottom pane: chance's key 8 in the view. Another key is (7, 3) of
-- the top pane, voice 3's step 7: its hold is a second open of the editor
local VIEW = {key_x = 5, key_y = 1, step = 5, bar_x = 8, bar_y = LINE.chance, other_x = 7, other_y = 3}
local function view_panes(context)
  return grid_pane(context, "256 top"), grid_pane(context, "256 bottom")
end
local function view_state()
  local S = local_value("S")
  local editor, view = S.lib.pages_seq.step_editor(), S.lib.grid_core.step_view(1)
  local shown = shown_step_editor()
  if view then
    if editor == nil or editor.port ~= 1 or view.pane ~= 2 or view.voice ~= editor.voice or view.step ~= editor.step then
      return "a view of " .. view.voice .. " " .. view.step .. " on pane " .. view.pane .. ", the editor " .. tostring(shown)
    end
    return "open"
  end
  if editor and editor.port == 1 then return "editor" end
  if editor then return "the editor of " .. shown end
  return S.lib.grid_core.any_page(S.constants.GRID_PAGES.patterns, PATTERNS_SIDE2) and "closed" or "closed, no side 2"
end
local function view_enter(bottom_side, hold)
  return function(context)
    local S = local_value("S")
    local top, bottom = view_panes(context)
    top.show(S.constants.GRID_PAGES.patterns)
    bottom.show(S.constants.GRID_PAGES.patterns, bottom_side)
    if hold then top.press(VIEW.key_x, VIEW.key_y, 1); context.clock.run_for(0.35) end
  end
end
local function set_page_of(pane_index, page, side)
  local S = local_value("S")
  S.lib.grid_core.set_page(1, S.constants.GRID_PAGES[page], pane_index, side)
end
local VIEW_EVENTS = {
  ["hold"] = function(context)
    local top = view_panes(context)
    top.press(VIEW.key_x, VIEW.key_y, 1); context.clock.run_for(0.35)
  end,
  ["release"] = function(context) context.grid.press(1, VIEW.key_x, VIEW.key_y, 0) end,
  ["K2"] = k2,
  ["key's pane page"] = function() set_page_of(1, "voices") end,
  ["view's pane page"] = function() set_page_of(2, "voices") end,
  ["view's pane side"] = function() set_page_of(2, "patterns", 3 - local_value("S").lib.grid_core.side(1, 2)) end,
  ["unplug"] = function(context) context.grid.unplug(1) end,
  ["replacement"] = function()
    local S = local_value("S")
    local steps = {}
    for step = 1, #S.patterns[1] do steps[step] = S.patterns[1][step] end
    S.lib.sequencer.replace_pattern(1, steps)
  end,
  -- the editor's euclid row's fill (E2 up from its level row, then E3):
  -- its own replacement (ruling 71)
  ["editor's replacement"] = function() enc(2, -2); enc(3, 4) end,
  ["bar key"] = function(context) local _, bottom = view_panes(context); bottom.tap(VIEW.bar_x, VIEW.bar_y) end,
  ["another key's hold"] = function(context)
    local top = view_panes(context)
    top.press(VIEW.other_x, VIEW.other_y, 1); context.clock.run_for(0.35)
  end,
  ["close all"] = function() local_value("S").lib.ui_modal.close_all() end,
}
-- The bottom pane draws the lane side again: LN lit 4 on its utility line
local function bottom_is_lane_side(context)
  local _, bottom = view_panes(context)
  assert_equal(bottom.led(KEY.ln, LINE.utility), 4, "the bottom pane is the lane side again")
end
local function bottom_is_view(context)
  local _, bottom = view_panes(context)
  assert_equal(bottom.led(KEY.ln, LINE.utility), 0, "the bottom pane is the step view: line 7 dark")
end
-- The key's release toggles nothing (it opened the editor)
local function key_toggles_nothing(context)
  context.grid.press(1, VIEW.key_x, VIEW.key_y, 0)
  assert_equal(local_value("S").patterns[1][VIEW.step], 0, "the key's release toggles nothing")
end
local function step_prob(prob)
  assert_equal(local_value("S").lib.sequencer.step_attr(1, VIEW.step, "prob"), prob, "step 5's prob")
end
local function voice_4_tapped()
  assert_equal(local_value("S").patterns[4][VIEW.bar_x], 15, "a side 1 tap: voice 4's step 8 on")
end
-- The editor is the step the key's hold opened (voice 1's step 5)
local function editor_of_key()
  assert_equal(shown_step_editor(), "1 " .. VIEW.step .. " 1", "the editor of the key's step")
end
-- The second open: voice 3's step 7 in the editor (and in the view where
-- there is one), and the first key's release closes nothing
local function editor_of_other(context)
  assert_equal(shown_step_editor(), "3 " .. VIEW.other_x .. " 1", "the other key's step in the editor")
  local view = local_value("S").lib.grid_core.step_view(1)
  if view then assert_equal(view.voice .. " " .. view.step, "3 " .. VIEW.other_x, "and in the view") end
  context.grid.press(1, VIEW.key_x, VIEW.key_y, 0)
  assert_equal(shown_step_editor(), "3 " .. VIEW.other_x .. " 1", "the first key's release closes nothing")
end
local NO_EDITOR_REPLACEMENT = "the editor's own replacement runs only from its open owner's rows and keys (run_replacement)"
h.transition_table({
  name = "step view",
  notes = {"docs/notes/lua/grid/keys.md", "step view"},
  states = {
    ["closed"] = view_enter(PATTERNS_SIDE2, false),
    ["closed, no side 2"] = view_enter(1, false),
    ["editor"] = view_enter(1, true),
    ["open"] = view_enter(PATTERNS_SIDE2, true),
  },
  events = VIEW_EVENTS,
  state_of = view_state,
  rows = {
    {"closed", "hold", "open", check = function(context)
      editor_of_key()
      bottom_is_view(context)
    end},
    {"closed", "another key's hold", "open", check = editor_of_other},
    {"closed", "close all", "closed"},
    {"closed", "release", "closed"},
    {"closed", "K2", "closed"},
    {"closed", "key's pane page", "closed"},
    {"closed", "view's pane page", "closed, no side 2"},
    {"closed", "view's pane side", "closed, no side 2"},
    {"closed", "unplug", "closed, no side 2"},
    {"closed", "replacement", "closed"},
    {"closed", "bar key", "closed", check = function()
      assert_equal(local_value("S").lib.sequencer.step_attr(1, VIEW.bar_x, "prob"), 53, "a chance cell's tap: cell 8 takes 53")
      step_prob(nil)
    end},
    {"closed, no side 2", "hold", "editor", check = editor_of_key},
    {"closed, no side 2", "another key's hold", "editor", check = editor_of_other},
    {"closed, no side 2", "close all", "closed, no side 2"},
    {"closed, no side 2", "release", "closed, no side 2"},
    {"closed, no side 2", "K2", "closed, no side 2"},
    {"closed, no side 2", "key's pane page", "closed, no side 2"},
    {"closed, no side 2", "view's pane page", "closed, no side 2"},
    {"closed, no side 2", "view's pane side", "closed"},
    {"closed, no side 2", "unplug", "closed, no side 2"},
    {"closed, no side 2", "replacement", "closed, no side 2"},
    {"closed, no side 2", "bar key", "closed, no side 2", check = voice_4_tapped},
    {"editor", "hold", "editor", check = key_toggles_nothing},
    {"editor", "another key's hold", "editor", check = editor_of_other},
    {"editor", "close all", "closed, no side 2", check = key_toggles_nothing},
    {"editor", "release", "closed, no side 2", check = function()
      assert_equal(local_value("S").patterns[1][VIEW.step], 0, "the release toggles nothing")
    end},
    {"editor", "K2", "closed, no side 2", check = key_toggles_nothing},
    {"editor", "key's pane page", "closed, no side 2", check = key_toggles_nothing},
    {"editor", "view's pane page", "editor"},
    {"editor", "view's pane side", "open", check = bottom_is_view},
    {"editor", "unplug", "closed, no side 2"},
    {"editor", "replacement", "closed, no side 2", check = key_toggles_nothing},
    {"editor", "editor's replacement", "editor"},
    {"editor", "bar key", "editor", check = function()
      step_prob(nil)
      voice_4_tapped()
    end},
    {"open", "hold", "open", check = function(context)
      bottom_is_view(context)
      key_toggles_nothing(context)
    end},
    {"open", "release", "closed", check = bottom_is_lane_side},
    {"open", "another key's hold", "open", check = function(context)
      bottom_is_view(context)
      editor_of_other(context)
    end},
    {"open", "close all", "closed", check = function(context)
      bottom_is_lane_side(context)
      key_toggles_nothing(context)
    end},
    {"open", "K2", "closed", check = function(context)
      bottom_is_lane_side(context)
      key_toggles_nothing(context)
    end},
    {"open", "key's pane page", "closed", check = function(context)
      bottom_is_lane_side(context)
      key_toggles_nothing(context)
    end},
    {"open", "view's pane page", "editor"},
    {"open", "view's pane side", "editor", check = function()
      set_page_of(2, "patterns", PATTERNS_SIDE2)
      assert_equal(view_state(), "open", "side 2 shown again: the view again, the editor still open")
    end},
    {"open", "unplug", "closed, no side 2"},
    {"open", "replacement", "closed", check = function(context)
      bottom_is_lane_side(context)
      key_toggles_nothing(context)
    end},
    {"open", "editor's replacement", "open", check = bottom_is_view},
    {"open", "bar key", "open", check = function(context)
      step_prob(53)
      context.screen.clear(); redraw()
      assert_true(h.screen_shows(context, "53%"), "the editor's prob row shows it")
    end},
  },
  impossible = {
    {"closed", "editor's replacement", NO_EDITOR_REPLACEMENT},
    {"closed, no side 2", "editor's replacement", NO_EDITOR_REPLACEMENT},
  },
})

end

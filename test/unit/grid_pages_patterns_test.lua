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

test("a second key sets the held step's level over 16 positions, 8 on a half", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first, last = shown_columns(pane)
    local positions = last - first + 1
    S.patterns[2][first] = 5
    pane.press(first, 2, 1)
    pane.press(last, 2, 1)
    assert_equal(S.patterns[2][first], 15, arrangement .. ": the line's last shown key is the top level, 15")
    pane.press(last, 2, 0)
    -- the half-way key: 8 of 16 (round(8 * 15 / 16) = 8), or 4 of 8 on a
    -- half (round(4 * 15 / 8) = round(7.5) = 8)
    local middle = first + positions / 2 - 1
    pane.press(middle, 2, 1)
    assert_equal(S.patterns[2][first], 8, arrangement .. ": the half-way key of " .. positions .. " sets 8")
    pane.press(middle, 2, 0)
    local quarter = first + positions / 4 - 1
    pane.press(quarter, 2, 1)
    -- 4 of 16 (round(3.75) = 4), or 2 of 8 (round(3.75) = 4)
    assert_equal(S.patterns[2][first], 4, arrangement .. ": the quarter key of " .. positions .. " sets 4")
    pane.press(quarter, 2, 0)
    pane.press(first, 2, 0)
    assert_equal(S.patterns[2][first], 4, arrangement .. ": neither release toggles")
    assert_equal(S.patterns[2][last] + S.patterns[2][middle] + S.patterns[2][quarter], 0,
      arrangement .. ": the level keys toggled nothing")
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

end

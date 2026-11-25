-- test/unit/pattern_letters_test.lua
-- The four patterns a voice (lib/pattern_letters.lua, 3.9 grid sequencer
-- package 4a, design section 3, Variations, and section 6): the letters A
-- to D, the switch that stores the playing pattern and loads another
-- through the whole-pattern door (S.lib.sequencer.whole, replace_whole),
-- and the scene block `variations`
-- Run alone: lua test/run.lua pattern_letters

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local shown_step_editor = h.shown_step_editor

local OWN_POSITION = 0.2

-- A fresh script after its start-up (voices 1 and 2 running), voice 1
-- reading buffer 1 (8 s) at position 0.2: its value A moves the position
local function setup()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = 8
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v1_buf_pos", OWN_POSITION)
  context.clear_engine_calls()
  return context, S
end

-- Voice 1's pattern A: steps 1, 5 and 9 set, step 5 at 50 % with a chord,
-- step 9 with value A 12, the chance lane at a length of 5
local function pattern_a(S)
  local seq = S.lib.sequencer
  seq.set_level(1, 1, 15); seq.set_level(1, 5, 9); seq.set_level(1, 9, 4)
  seq.set_step_attr(1, 5, "prob", 50); seq.set_step_attr(1, 5, "notes", {0, 3, 7})
  seq.set_step_attr(1, 9, "va", 12)
  S.lib.lanes.set_length(1, "chance", 5)
end

local function levels_of(S, voice_idx)
  local levels = {}
  for step = 1, S.constants.PATTERN_LENGTH do levels[step] = S.patterns[voice_idx][step] end
  return levels
end

-- Two values alike, tables by their contents (a table's own fields both ways)
local function same(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  for key, value in pairs(a) do
    if not same(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

local function assert_same(a, b, what)
  assert_true(same(a, b), what)
end

-- The values setGrainParam(voice - 1, name, ...) sent, in order
local function sent(context, voice_idx, name)
  local values = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == "setGrainParam" and call.args[1] == voice_idx - 1 and call.args[2] == name then
      values[#values + 1] = call.args[3]
    end
  end
  return values
end

test("the letters are A to D; a voice plays A, the only letter used", function()
  local _, S = setup()
  local letters = S.lib.pattern_letters
  assert_equal(table.concat(letters.LETTERS, " "), "A B C D", "the four letters")
  for voice_idx = 1, h.voice_count() do
    assert_equal(letters.current(voice_idx), "A", "voice " .. voice_idx .. " plays A")
    assert_true(letters.used(voice_idx, "A"), "voice " .. voice_idx .. ": the playing letter is used")
    for _, letter in ipairs({"B", "C", "D"}) do
      assert_true(not letters.used(voice_idx, letter), "voice " .. voice_idx .. ": " .. letter .. " is not")
    end
  end
  assert_equal(letters.current(0), nil, "no voice 0")
  assert_equal(letters.used(1, "E"), false, "no letter E")
end)

test("whole is a deep copy of the playing pattern: levels, steps and lane lengths", function()
  local _, S = setup()
  pattern_a(S)
  local whole = S.lib.sequencer.whole(1)
  assert_same(whole.levels, levels_of(S, 1), "its levels")
  assert_same(whole.steps, S.pattern_steps[1], "its steps' settings")
  assert_same(whole.lanes, {chance = 5}, "its lane lengths")
  assert_true(whole.levels ~= S.patterns[1] and whole.steps ~= S.pattern_steps[1], "copies, not the tables")
  assert_true(whole.steps[5].notes ~= S.pattern_steps[1][5].notes, "a chord copied too")
  whole.steps[5].notes[1] = 14; whole.levels[1] = 0
  assert_equal(S.pattern_steps[1][5].notes[1], 0, "a change of the copy leaves the pattern")
  assert_equal(S.patterns[1][1], 15)
  assert_equal(S.lib.sequencer.whole(0), nil, "no voice")
end)

test("replace_whole loads levels, steps and lane lengths and asks the gate rule", function()
  local context, S = setup()
  pattern_a(S)
  local whole = S.lib.sequencer.whole(1)
  S.lib.sequencer.replace_whole(2, whole)
  assert_same(levels_of(S, 2), whole.levels, "voice 2's levels")
  assert_same(S.pattern_steps[2], whole.steps, "its steps")
  assert_same(S.lib.lanes.lengths(2), {chance = 5}, "its lane lengths")
  assert_true(S.pattern_steps[2][5].notes ~= whole.steps[5].notes, "copied in, not shared")
  -- a pattern with no lane length makes every lane follow
  S.lib.sequencer.replace_whole(2, {levels = {}, steps = {}, lanes = {}})
  assert_same(S.lib.lanes.lengths(2), {}, "every lane follows")
  assert_equal(next(S.pattern_steps[2]), nil, "no step settings")
  assert_equal(S.patterns[2][1], 0, "no levels")
  -- the gate rule: a pulse voice playing gets its answer last
  S.lib.sequencer.replace_whole(2, whole)
  pattern_clock_start()
  context.clear_engine_calls()
  S.lib.sequencer.replace_whole(2, {levels = {}, steps = {}, lanes = {}})
  local gates = sent(context, 2, "seqGate")
  assert_true(#gates >= 1, "the rule sent")
  assert_equal(gates[#gates], 0, "and last 0: nothing to pulse")
  pattern_clock_stop()
end)

test("the first switch to a letter copies the playing pattern", function()
  local _, S = setup()
  local letters = S.lib.pattern_letters
  pattern_a(S)
  local before = S.lib.sequencer.whole(1)
  letters.switch_now(1, "B")
  assert_equal(letters.current(1), "B", "B plays")
  assert_same(S.lib.sequencer.whole(1), before, "the same levels, settings and lane lengths")
  assert_same(S.lib.lanes.lengths(1), {chance = 5}, "the 5-step lane")
  assert_true(letters.used(1, "A") and letters.used(1, "B"), "A and B used")
  assert_true(not letters.used(1, "C"), "C not")
  assert_equal(letters.current(2), "A", "another voice stays on A")
end)

test("a switch stores what was playing", function()
  local _, S = setup()
  local letters, seq = S.lib.pattern_letters, S.lib.sequencer
  pattern_a(S)
  local a = seq.whole(1)
  letters.switch_now(1, "B")
  seq.set_level(1, 16, 15); seq.set_step_attr(1, 16, "ratchet", 3); S.lib.lanes.set_length(1, "gate", 3)
  local b = seq.whole(1)
  letters.switch_now(1, "A")
  assert_equal(letters.current(1), "A")
  assert_same(seq.whole(1), a, "A is as it was")
  letters.switch_now(1, "B")
  assert_same(seq.whole(1), b, "back to B: the edit is there")
  assert_equal(seq.step_attr(1, 16, "ratchet"), 3, "its step setting")
  assert_equal(S.lib.lanes.length(1, "gate"), 3, "its lane length")
  -- a switch to the playing letter changes nothing
  letters.switch_now(1, "B")
  assert_same(seq.whole(1), b, "B again")
  -- a bad voice or letter does nothing
  letters.switch_now(1, "E"); letters.switch_now(0, "A"); letters.switch_now(1, nil)
  assert_equal(letters.current(1), "B", "still B")
end)

test("a cleared letter stays empty", function()
  local _, S = setup()
  local letters = S.lib.pattern_letters
  pattern_a(S)
  letters.switch_now(1, "B")
  clear_pattern(1)
  letters.switch_now(1, "A")
  assert_equal(S.patterns[1][1], 15, "A has its steps")
  letters.switch_now(1, "B")
  for step = 1, S.constants.PATTERN_LENGTH do
    assert_equal(S.patterns[1][step], 0, "B is empty, not a copy of A: step " .. step)
  end
  assert_true(letters.used(1, "B"), "and used")
end)

test("a switch ends the held values and closes the step editor", function()
  local context, S = setup()
  local letters, seq = S.lib.pattern_letters, S.lib.sequencer
  seq.set_level(1, 1, 15); seq.set_step_attr(1, 1, "va", 15)
  pattern_clock_start()
  assert_equal(seq.held_value(1, "position"), 15, "step 1's value held")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 5, 1, 1); context.clock.run_for(0.35)
  assert_true(shown_step_editor() ~= nil, "a held step opened the step editor")
  context.clear_engine_calls()
  letters.switch_now(1, "B")
  assert_equal(seq.held_value(1, "position"), nil, "the switch ended the value")
  assert_near(S.lib.engine_sync.engine_base_value("v1_buf_pos"), OWN_POSITION, 1e-12, "the voice's own position")
  assert_equal(shown_step_editor(), nil, "and closed the step editor")
  context.grid.press(1, 5, 1, 0)
  pattern_clock_stop()
end)

test("a switch asks the gate rule", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  assert_equal(S.lib.sequencer.step_mode(1), "pulse", "the default mode")
  pattern_a(S)
  letters.switch_now(1, "B")
  clear_pattern(1)
  letters.switch_now(1, "A")
  pattern_clock_start()
  context.clear_engine_calls()
  letters.switch_now(1, "B")
  local gates = sent(context, 1, "seqGate")
  assert_true(#gates >= 1, "the rule sent")
  assert_equal(gates[#gates], 0, "an empty used letter: seqGate 0 last")
  context.clear_engine_calls()
  letters.switch_now(1, "A")
  gates = sent(context, 1, "seqGate")
  assert_equal(gates[#gates], 1, "back on A's steps: 1")
  pattern_clock_stop()
end)

test("a scene keeps the used letters and the playing one", function()
  local _, S = setup()
  local letters, seq = S.lib.pattern_letters, S.lib.sequencer
  pattern_a(S)
  local a = seq.whole(1)
  letters.switch_now(1, "C")
  seq.set_level(1, 2, 15)
  local c = seq.whole(1)
  letters.switch_now(1, "B")
  clear_pattern(1)
  capture_scene(1)
  assert_true(validate_scene(S.scenes[1]), "it validates")
  local block = S.scenes[1].data.variations
  assert_equal(block[1].current, "B", "the playing letter")
  assert_true(block[1].slots.B == nil, "the playing letter is not in slots")
  assert_same(block[1].slots.A, a, "A stored")
  assert_same(block[1].slots.C, c, "C stored")
  assert_true(block[1].slots.D == nil, "D never used")
  assert_equal(block[1].order_on, false); assert_same(block[1].order, {}, "no order")
  assert_same(block[2], {current = "A", order = {}, order_on = false, slots = {}}, "voice 2 on A alone")
  -- change it all
  letters.switch_now(1, "D")
  seq.set_level(1, 7, 15)
  letters.switch_now(1, "A")
  recall_scene(1)
  assert_equal(letters.current(1), "B", "B plays again")
  assert_equal(S.patterns[1][1], 0, "B's (cleared) pattern")
  assert_true(not letters.used(1, "D"), "D was not used in the scene")
  letters.switch_now(1, "C")
  assert_same(seq.whole(1), c, "C as the scene held it")
  letters.switch_now(1, "A")
  assert_same(seq.whole(1), a, "A as the scene held it")
  seq.set_level(1, 3, 15)
  assert_equal(S.scenes[1].data.variations[1].slots.A.levels[3], 0, "an edit after the recall leaves the scene")
end)

test("an old scene fills with letter A alone", function()
  local _, S = setup()
  local letters = S.lib.pattern_letters
  pattern_a(S)
  capture_scene(1)
  S.scenes[1].data.variations = nil
  fill_scene(S.scenes[1])
  assert_true(validate_scene(S.scenes[1]), "filled, it validates")
  letters.switch_now(1, "C")
  recall_scene(1)
  assert_equal(letters.current(1), "A", "letter A")
  for voice_idx = 1, h.voice_count() do
    for _, letter in ipairs({"B", "C", "D"}) do
      assert_true(not letters.used(voice_idx, letter), "voice " .. voice_idx .. ": " .. letter .. " unused")
    end
  end
  assert_equal(S.patterns[1][1], 15, "the scene's own pattern plays")
end)

test("the block refuses a slot with a level of 16 or an unknown step key", function()
  local _, S = setup()
  local letters = S.lib.pattern_letters
  pattern_a(S)
  letters.switch_now(1, "B")
  capture_scene(1)
  assert_true(validate_scene(S.scenes[1]), "a captured scene validates")
  local block = S.scenes[1].data.variations
  local slot = block[1].slots.A
  local function refused(change, undo, what)
    change()
    assert_true(not validate_scene(S.scenes[1]), "refused: " .. what)
    undo()
    assert_true(validate_scene(S.scenes[1]), "restored: " .. what)
  end
  refused(function() slot.levels[1] = 16 end, function() slot.levels[1] = 15 end, "a level of 16")
  refused(function() slot.levels[2] = 1.5 end, function() slot.levels[2] = 0 end, "a level of 1.5")
  refused(function() slot.levels[17] = 1 end, function() slot.levels[17] = nil end, "a 17th level")
  refused(function() slot.steps[5].color = 1 end, function() slot.steps[5].color = nil end, "an unknown step key")
  refused(function() slot.steps[5].prob = 101 end, function() slot.steps[5].prob = 50 end, "a chance of 101")
  refused(function() slot.steps[17] = {prob = 1} end, function() slot.steps[17] = nil end, "a step 17")
  refused(function() slot.lanes.chance = 17 end, function() slot.lanes.chance = 5 end, "a lane of 17")
  refused(function() slot.lanes.pitch = 4 end, function() slot.lanes.pitch = nil end, "an unknown lane")
  refused(function() slot.extra = {} end, function() slot.extra = nil end, "an unknown pattern key")
  refused(function() block[1].slots.B = slot end, function() block[1].slots.B = nil end, "the playing letter in slots")
  refused(function() block[1].slots.E = slot end, function() block[1].slots.E = nil end, "a letter E")
  refused(function() block[1].current = "E" end, function() block[1].current = "B" end, "a current E")
  refused(function() block[1].order = {"A", "E"} end, function() block[1].order = {} end, "an order with E")
  refused(function() block[1].order = {"A", "A", "A", "A", "A", "A", "A", "A", "A"} end,
    function() block[1].order = {} end, "an order of nine")
  refused(function() block[1].order = {[2] = "A"} end, function() block[1].order = {} end, "an order with a hole")
  refused(function() block[1].order_on = 1 end, function() block[1].order_on = false end, "order_on not a boolean")
  refused(function() block[1].slots.A = nil; block[1].slots.C = "x" end,
    function() block[1].slots.C = nil; block[1].slots.A = slot end, "a slot not a table")
  local past, last = h.voice_count() + 1, h.voice_count()
  refused(function() block[past] = block[2] end, function() block[past] = nil end, "a voice past the last")
  local last_voice = block[last]
  refused(function() block[last] = nil end, function() block[last] = last_voice end, "a voice missing")
  refused(function() block[1].shape = 1 end, function() block[1].shape = nil end, "an unknown voice key")
end)

-- 4b: switching on the bar, and the order -----------------------------------

-- A bar at 120 BPM (four beats), in seconds
local BAR_SECONDS = 2.0
-- Each letter's step 1 level: voice 1's A, B and C hold step 1 alone at
-- its own level, so a hit's level says which letter played it
local LEVEL = {A = 15, B = 7, C = 3}

-- Voice 1's letters A, B and C used, each its step 1 at its level, A playing
local function three_letters(S)
  local letters, seq = S.lib.pattern_letters, S.lib.sequencer
  seq.set_level(1, 1, LEVEL.A)
  for _, letter in ipairs({"B", "C"}) do
    letters.switch_now(1, letter)
    seq.set_level(1, 1, LEVEL[letter])
  end
  letters.switch_now(1, "A")
end

-- The levels of voice 1's step 1 hits, in order: a step output (the
-- registry stays open) that hears every hit
local function step_one_levels(S)
  local heard = {}
  S.register_step_output({name = "letter probe", play = function(event)
    if event.voice == 1 and event.first and event.step == 1 then heard[#heard + 1] = event.level end
  end})
  return heard
end

test("a tap waits for the bar; the letter plays from the bar's first step", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  local heard = step_one_levels(S)
  pattern_clock_start()
  context.clock.run_for(0.5)
  letters.switch(1, "B")
  assert_equal(letters.waiting(1), "B", "B waits")
  assert_equal(letters.current(1), "A", "A plays on")
  context.clock.run_for(BAR_SECONDS - 0.5 - 0.01)
  assert_equal(letters.current(1), "A", "still A just before the bar")
  context.clock.run_for(0.02)
  assert_equal(letters.current(1), "B", "B from the bar")
  assert_equal(letters.waiting(1), nil, "nothing waits")
  assert_equal(table.concat(heard, " "), "15 7", "bar 1's step 1 was A's, bar 2's B's")
  pattern_clock_stop()
end)

test("a bar's switch repaints the grid once, with the bar's step", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  pattern_clock_start()
  context.clock.run_for(0.5)
  letters.switch(1, "B")
  context.clock.run_for(BAR_SECONDS - 0.5 - 0.01)
  local count, real_grid_redraw = 0, grid_redraw
  grid_redraw = function(...) count = count + 1; return real_grid_redraw(...) end
  context.clock.run_for(0.02)
  grid_redraw = real_grid_redraw
  assert_equal(letters.current(1), "B", "B from the bar")
  assert_equal(count, 1, "one repaint for the bar's step, the switch's included")
  pattern_clock_stop()
end)

test("a second tap on the waiting letter switches at once", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  pattern_clock_start()
  context.clock.run_for(0.5)
  letters.switch(1, "C")
  letters.switch(1, "B")
  assert_equal(letters.waiting(1), "B", "another letter replaces the one waiting")
  letters.switch(1, "B")
  assert_equal(letters.current(1), "B", "B at once")
  assert_equal(letters.waiting(1), nil, "nothing waits")
  assert_equal(S.patterns[1][1], LEVEL.B, "B's pattern")
  letters.switch(1, "C")
  letters.switch(1, "B")
  assert_equal(letters.waiting(1), nil, "the playing letter cancels the wait")
  context.clock.run_for(BAR_SECONDS)
  assert_equal(letters.current(1), "B", "B plays on past the bar")
  pattern_clock_stop()
end)

test("with the patterns stopped a tap switches at once", function()
  local _, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  letters.switch(1, "C")
  assert_equal(letters.current(1), "C", "C at once")
  assert_equal(letters.waiting(1), nil, "nothing waits")
  assert_equal(S.patterns[1][1], LEVEL.C, "C's pattern")
  letters.switch(0, "A"); letters.switch(1, "E")
  assert_equal(letters.current(1), "C", "a bad voice or letter does nothing")
  assert_equal(letters.waiting(0), nil)
end)

test("an order A A B A plays four bars from the patterns' start and starts again", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  letters.switch(1, "B")  -- B plays, so A at the first bar is the order's own
  local heard = step_one_levels(S)
  letters.set_order(1, {"A", "A", "B", "A"})
  local order, on = letters.order(1)
  assert_equal(table.concat(order, " "), "A A B A", "the order")
  assert_equal(on, true, "set_order turns it on")
  assert_equal(letters.current(1), "B", "nothing switches before a bar")
  pattern_clock_start()
  assert_equal(letters.current(1), "A", "bar 1 is A: the start's own bar")
  context.clock.run_for(6 * BAR_SECONDS + 0.01)
  assert_equal(table.concat(heard, " "), "15 15 7 15 15 15 7", "A A B A, then A A B")
  pattern_clock_stop()
  -- a start again takes the first entry, wherever the order was
  context.clock.run_for(BAR_SECONDS)
  heard[#heard + 1] = 0
  pattern_clock_start()
  context.clock.run_for(2 * BAR_SECONDS + 0.01)
  assert_equal(table.concat(heard, " "), "15 15 7 15 15 15 7 0 15 15 7", "from its first entry")
  pattern_clock_stop()
  -- a bad order is refused, and leaves the order as it was
  letters.set_order(1, {"A", "E"}); letters.set_order(1, {"A", "A", "A", "A", "A", "A", "A", "A", "A"})
  letters.set_order(1, "A"); letters.set_order(0, {"A"})
  order = letters.order(1)
  assert_equal(table.concat(order, " "), "A A B A", "refused")
  order[1] = "D"
  assert_equal(letters.order(1)[1], "A", "order gives a copy")
end)

test("an order of one letter never replaces the pattern", function()
  local context, S = setup()
  local letters, seq = S.lib.pattern_letters, S.lib.sequencer
  three_letters(S)
  local replaced, replace_pattern = 0, seq.replace_pattern
  seq.replace_pattern = function(...)
    replaced = replaced + 1
    return replace_pattern(...)
  end
  letters.set_order(1, {"A"})
  pattern_clock_start()
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 5, 1, 1); context.clock.run_for(0.35)
  assert_true(shown_step_editor() ~= nil, "a held step opened the step editor")
  context.clock.run_for(2 * BAR_SECONDS)
  assert_equal(replaced, 0, "no replace_pattern at a bar")
  assert_true(shown_step_editor() ~= nil, "the step editor stays open")
  assert_equal(letters.current(1), "A")
  context.grid.press(1, 5, 1, 0)
  pattern_clock_stop()
  seq.replace_pattern = replace_pattern
end)

test("turning an order on clears a waiting letter", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  local heard = step_one_levels(S)
  letters.set_order(1, {"C"})
  letters.set_order_on(1, false)
  local _, on = letters.order(1)
  assert_equal(on, false, "set_order_on off")
  pattern_clock_start()
  context.clock.run_for(0.5)
  letters.switch(1, "B")
  assert_equal(letters.waiting(1), "B", "B waits")
  letters.set_order_on(1, true)
  assert_equal(letters.waiting(1), nil, "the order cleared it")
  context.clock.run_for(BAR_SECONDS)
  assert_equal(letters.current(1), "C", "the bar takes the order's first entry")
  assert_equal(table.concat(heard, " "), "15 3", "A, then C")
  pattern_clock_stop()
end)

test("a switch by hand turns the order off", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  letters.set_order(1, {"B"})
  pattern_clock_start()
  assert_equal(letters.current(1), "B", "the order's first bar")
  context.clock.run_for(0.5)
  letters.switch(1, "C")
  local order, on = letters.order(1)
  assert_equal(on, false, "the order is off")
  assert_equal(table.concat(order, " "), "B", "and kept")
  assert_equal(letters.waiting(1), "C", "C waits")
  context.clock.run_for(2 * BAR_SECONDS)
  assert_equal(letters.current(1), "C", "C from the bar, and on: the order walks no more")
  -- a tap of the playing letter turns it off too
  letters.set_order_on(1, true)
  letters.switch(1, "C")
  _, on = letters.order(1)
  assert_equal(on, false, "a tap of the playing letter")
  -- an empty order cannot be on
  letters.set_order(1, {})
  order, on = letters.order(1)
  assert_equal(#order, 0, "no order")
  assert_equal(on, false, "an empty order is off")
  letters.set_order_on(1, true)
  _, on = letters.order(1)
  assert_equal(on, false, "and is never turned on")
  pattern_clock_stop()
end)

test("a chain link wins over a waiting letter on the same bar", function()
  local context, S = setup()
  local letters, seq = S.lib.pattern_letters, S.lib.sequencer
  three_letters(S)
  capture_scene(1)
  local heard = step_one_levels(S)
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 1)
  params:set("seq_chain_bars", 1)
  pattern_clock_start()
  context.clock.run_for(0.5)
  seq.set_level(1, 1, 9)  -- A edited: the scene's own A has 15
  letters.switch(1, "B")
  assert_equal(letters.waiting(1), "B", "B waits")
  context.clock.run_for(BAR_SECONDS - 0.5 + 0.01)
  assert_equal(letters.waiting(1), nil, "the link cleared the wait")
  assert_equal(letters.current(1), "A", "the scene's letter")
  assert_equal(table.concat(heard, " "), "15 15", "the scene's A played at the bar, not B nor the edit")
  pattern_clock_stop()
end)

test("a recall clears a wait, before or after the bar's hook", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  capture_scene(1)
  pattern_clock_start()
  context.clock.run_for(0.5)
  letters.switch(1, "B")
  recall_scene(1)
  assert_equal(letters.waiting(1), nil, "the recall cleared the wait")
  context.clock.run_for(BAR_SECONDS)
  assert_equal(letters.current(1), "A", "A plays on past the bar")
  pattern_clock_stop()
  -- after the hook: a recall from a later bar hook, on the bar the wait
  -- switched on, wins too (review round 1)
  local recall_at_bar = false
  S.lib.sequencer.on_bar(function(first)
    if recall_at_bar and not first then
      recall_at_bar = false
      recall_scene(1)
    end
  end)
  local heard = step_one_levels(S)
  pattern_clock_start()
  context.clock.run_for(0.5)
  letters.switch(1, "B")
  recall_at_bar = true
  context.clock.run_for(BAR_SECONDS - 0.5 + 0.01)
  assert_equal(recall_at_bar, false, "the later hook recalled at the bar")
  assert_equal(letters.waiting(1), nil, "nothing waits")
  assert_equal(letters.current(1), "A", "the scene's letter, not B")
  assert_equal(table.concat(heard, " "), "15 15", "the scene's A played the bar's first step")
  pattern_clock_stop()
end)

test("an order the block gives with no letter is off", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  capture_scene(1)
  S.scenes[1].data.variations[1].order_on = true  -- a file's: no order, on
  assert_true(validate_scene(S.scenes[1]), "it validates")
  recall_scene(1)
  local order, on = letters.order(1)
  assert_equal(#order, 0, "no order")
  assert_equal(on, false, "read as off")
  pattern_clock_start()
  context.clock.run_for(0.5)
  letters.switch(1, "B")
  assert_equal(letters.waiting(1), "B", "so a letter can wait")
  pattern_clock_stop()
end)

test("set_order refuses an order with a hole", function()
  local _, S = setup()
  local letters = S.lib.pattern_letters
  letters.set_order(1, {"A", "B"})
  local holed = {"A", "B", "C"}
  holed[2] = nil
  letters.set_order(1, holed)
  local order = letters.order(1)
  assert_equal(table.concat(order, " "), "A B", "refused: the order is as it was")
  letters.set_order(1, {"A", x = "B"})
  assert_equal(table.concat(letters.order(1), " "), "A B", "a key that is no index is refused")
end)

test("a tap with the patterns stopped repaints the grid once", function()
  local _, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  local count, real_grid_redraw = 0, grid_redraw
  grid_redraw = function(...) count = count + 1; return real_grid_redraw(...) end
  letters.switch(1, "B")
  grid_redraw = real_grid_redraw
  assert_equal(letters.current(1), "B")
  assert_equal(count, 1, "one repaint")
end)

-- Review round 1 (the controller's ruling): a late wake that skips bars
-- moves the order on by the bars that passed, wrapping, and switches once,
-- to the letter it lands on. Voice 1's resume mid bar 1 (at 0.625 s) is
-- delivered 6 s late: three bars (at beats 4, 8 and 12) pass at once
local function late_order(order)
  local context, S = setup()
  local letters, seq = S.lib.pattern_letters, S.lib.sequencer
  three_letters(S)
  letters.switch_now(1, "D")  -- D used: a copy of A
  letters.switch_now(1, "A")
  letters.set_order(1, order)
  pattern_clock_start()
  assert_equal(letters.current(1), order[1], "bar 1: the first entry")
  context.clock.run_for(0.5)
  local wholes, replace_whole = {}, seq.replace_whole
  seq.replace_whole = function(voice_idx, pattern)
    if voice_idx == 1 then wholes[#wholes + 1] = pattern.levels[1] end
    return replace_whole(voice_idx, pattern)
  end
  context.clock.advance_until(S.pattern_clocks[1], function() context.set_time(util.time() + 3 * BAR_SECONDS) end)
  context.clock.run_for(0.01)
  seq.replace_whole = replace_whole
  local landed = letters.current(1)
  pattern_clock_stop()
  return landed, wholes
end

test("a late wake past three bars moves an order on three entries and switches once", function()
  local landed, wholes = late_order({"A", "B"})
  assert_equal(landed, "B", "A B: one past where it was")
  assert_equal(#wholes, 1, "one switch")
  landed, wholes = late_order({"A", "B", "C"})
  assert_equal(landed, "A", "A B C: three on, back on A")
  assert_equal(#wholes, 0, "no switch, none of the letters between loaded")
  landed, wholes = late_order({"A", "B", "C", "D"})
  assert_equal(landed, "D", "A B C D: on D")
  assert_equal(table.concat(wholes, " "), "15", "one switch, to D (a copy of A), none to B or C")
end)

-- #1051's review round 1: a chain link clears every order's place, so the
-- bars a late wake skipped before the link never move the linked scene's
-- order. Scenes 1-4 each hold voice 1's order A B C, on; the chain links
-- them a bar each. `run` moves the clocks on; the letter voice 1 plays then
local function chained_order(run)
  local context, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  letters.set_order(1, {"A", "B", "C"})
  for slot = 1, 4 do capture_scene(slot) end
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 4)
  params:set("seq_chain_bars", 1)
  pattern_clock_start()
  context.clock.run_for(0.5)
  run(context, S)
  local playing = letters.current(1)
  pattern_clock_stop()
  return playing
end

test("a late wake past three chain links plays the linked order's first entry, as on time", function()
  assert_equal(chained_order(function(context) context.clock.run_for(3 * BAR_SECONDS) end), "A",
    "on time: each link's bar plays its order's entry 1")
  assert_equal(chained_order(function(context, S)
    context.clock.advance_until(S.pattern_clocks[1], function() context.set_time(util.time() + 3 * BAR_SECONDS) end)
    context.clock.run_for(0.01)
  end), "A", "late: the bars before the link never move the linked order")
end)

test("a stop clears a wait", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  three_letters(S)
  pattern_clock_start()
  context.clock.run_for(0.5)
  letters.switch(1, "B")
  pattern_clock_stop()
  assert_equal(letters.waiting(1), nil, "nothing waits")
  assert_equal(letters.current(1), "A", "A")
  pattern_clock_start()
  assert_equal(letters.current(1), "A", "a start finds no wait")
  context.clock.run_for(BAR_SECONDS)
  assert_equal(letters.current(1), "A", "nor a bar")
  pattern_clock_stop()
end)

test("the pattern letters invariant fails on a letter waiting while the patterns are stopped", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  local invariant = h.registered_invariant("pattern letters")
  three_letters(S)
  pattern_clock_start()
  context.clock.run_for(0.5)
  letters.switch(1, "B")
  assert_equal(invariant.check(), nil, "it holds: B waits while they play")
  S.pattern_playing = false  -- as though a stop had left the wait
  h.allow_broken_invariants("the test breaks the pattern letters invariant on purpose")
  assert_true((invariant.check() or ""):find("voice 1", 1, true) ~= nil, "a wait while stopped")
  S.pattern_playing = true
  pattern_clock_stop()
  assert_equal(invariant.check(), nil, "the stop cleared it")
end)

-- The machine `pattern letters` (docs/notes/lua/pattern-letters.md): voice
-- 1's letters A, B and C used (step 1 at 15, 7 and 3), A playing, scene 1
-- captured then (its order none, off), then the order B C set and turned
-- off, then A's step 16 set (the scene's A lacks it). A state is the
-- patterns stopped or playing (started, then half a second), the order
-- turned on (after the start: A plays, its first entry not yet taken) and
-- a letter waiting (C, switched to while they play)
local function letters_state(playing, waiting, order_on)
  return function(context)
    local S = local_value("S")
    local letters, seq = S.lib.pattern_letters, S.lib.sequencer
    three_letters(S)
    capture_scene(1)
    letters.set_order(1, {"B", "C"})
    letters.set_order_on(1, false)
    seq.set_level(1, 16, 15)
    if playing then
      pattern_clock_start()
      context.clock.run_for(0.5)
    end
    if order_on then letters.set_order_on(1, true) end
    if waiting then letters.switch(1, "C") end
    context.letters = letters
  end
end

local function letters_state_of()
  local S = local_value("S")
  local letters = S.lib.pattern_letters
  local _, on = letters.order(1)
  if not S.pattern_playing then return on and "stopped/order" or "stopped" end
  if letters.waiting(1) then return "playing/waiting" end
  return on and "playing/order" or "playing"
end

-- A row's check: voice 1 plays letter (step 1 holds its level), and the
-- letter waiting
local function plays(letter, waiting)
  return function()
    local S = local_value("S")
    assert_equal(S.lib.pattern_letters.current(1), letter, "voice 1 plays " .. letter)
    assert_equal(S.patterns[1][1], LEVEL[letter], letter .. "'s pattern")
    assert_equal(S.lib.pattern_letters.waiting(1), waiting, "waiting: " .. tostring(waiting))
  end
end

-- The scene's own A plays (its step 16 off), and its order, none, is off
local function scene_plays()
  local S = local_value("S")
  plays("A")()
  assert_equal(S.patterns[1][16], 0, "the scene's A")
  local order, on = S.lib.pattern_letters.order(1)
  assert_equal(#order, 0, "the scene's order")
  assert_equal(on, false)
end

local function order_is(text, on_wanted)
  return function()
    local order, on = local_value("S").lib.pattern_letters.order(1)
    assert_equal(table.concat(order, " "), text, "the order")
    assert_equal(on, on_wanted, "on")
  end
end

local function both(first, second)
  return function() first(); second() end
end

local NO_WAIT = "no letter waits: a tap while the patterns are stopped switches at once, and a stop clears a wait"
  .. " (switch, end_waits)"
local ORDER_WAIT = "no letter waits while an order is on: turning one on clears a wait, and a tap turns it off"
  .. " (switch, set_order, set_order_on)"
-- The chain switched on while the patterns are stopped links nothing
-- (chain.next_beat stays nil: chain_switched); the live pattern, its step
-- 16 set, plays on
local function no_link(letter)
  return function()
    plays(letter)()
    local S = local_value("S")
    assert_equal(S.patterns[1][16], 15, "the live pattern, not the scene's")
    assert_equal(S.lib.sequencer.chain_place(), nil, "the chain has linked nothing")
  end
end

h.transition_table({
  name = "pattern letters",
  notes = {"docs/notes/lua/pattern-letters.md", "pattern letters"},
  states = {
    stopped = letters_state(false, false, false),
    ["stopped/order"] = letters_state(false, false, true),
    playing = letters_state(true, false, false),
    ["playing/waiting"] = letters_state(true, true, false),
    ["playing/order"] = letters_state(true, false, true),
  },
  events = {
    ["tap playing"] = function(context) context.letters.switch(1, context.letters.current(1)) end,
    ["tap another"] = function(context) context.letters.switch(1, "B") end,
    ["tap waiting"] = function(context) context.letters.switch(1, "C") end,
    ["a bar"] = function(context) context.clock.run_for(BAR_SECONDS - 0.5 + 0.01) end,
    stop = function() pattern_clock_stop() end,
    start = function() pattern_clock_start() end,
    set_order = function(context) context.letters.set_order(1, {"C", "B"}) end,
    ["order on"] = function(context) context.letters.set_order_on(1, true) end,
    ["order off"] = function(context) context.letters.set_order_on(1, false) end,
    ["chain link"] = function(context)
      params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 1); params:set("seq_chain_bars", 1)
      params:set("seq_chain", 1)
      context.clock.run_for(BAR_SECONDS - 0.5 + 0.01)
    end,
    recall = function() recall_scene(1) end,
  },
  state_of = letters_state_of,
  rows = {
    {"stopped", "tap playing", "stopped", check = plays("A")},
    {"stopped", "tap another", "stopped", check = plays("B")},
    {"stopped", "a bar", "stopped", check = plays("A")},
    {"stopped", "stop", "stopped", check = plays("A")},
    {"stopped", "start", "playing", check = plays("A")},
    {"stopped", "set_order", "stopped/order", check = both(plays("A"), order_is("C B", true))},
    {"stopped", "order on", "stopped/order", check = both(plays("A"), order_is("B C", true))},
    {"stopped", "order off", "stopped", check = plays("A")},
    {"stopped", "recall", "stopped", check = scene_plays},
    {"stopped", "chain link", "stopped", check = no_link("A")},
    {"stopped/order", "tap playing", "stopped", check = both(plays("A"), order_is("B C", false))},
    {"stopped/order", "tap another", "stopped", check = both(plays("B"), order_is("B C", false))},
    {"stopped/order", "a bar", "stopped/order", check = plays("A")},
    {"stopped/order", "stop", "stopped/order", check = plays("A")},
    {"stopped/order", "start", "playing/order", check = plays("B")},
    {"stopped/order", "set_order", "stopped/order", check = both(plays("A"), order_is("C B", true))},
    {"stopped/order", "order on", "stopped/order", check = plays("A")},
    {"stopped/order", "order off", "stopped", check = both(plays("A"), order_is("B C", false))},
    {"stopped/order", "recall", "stopped", check = scene_plays},
    {"stopped/order", "chain link", "stopped/order", check = both(no_link("A"), order_is("B C", true))},
    {"playing", "tap playing", "playing", check = plays("A")},
    {"playing", "tap another", "playing/waiting", check = plays("A", "B")},
    {"playing", "a bar", "playing", check = plays("A")},
    {"playing", "stop", "stopped", check = plays("A")},
    {"playing", "start", "playing", check = plays("A")},
    {"playing", "set_order", "playing/order", check = both(plays("A"), order_is("C B", true))},
    {"playing", "order on", "playing/order", check = plays("A")},
    {"playing", "order off", "playing", check = plays("A")},
    {"playing", "chain link", "playing", check = scene_plays},
    {"playing", "recall", "playing", check = scene_plays},
    {"playing/waiting", "tap playing", "playing", check = plays("A")},
    {"playing/waiting", "tap another", "playing/waiting", check = plays("A", "B")},
    {"playing/waiting", "tap waiting", "playing", check = plays("C")},
    {"playing/waiting", "a bar", "playing", check = plays("C")},
    {"playing/waiting", "stop", "stopped", check = plays("A")},
    {"playing/waiting", "start", "playing", check = plays("C")},
    {"playing/waiting", "set_order", "playing/order", check = both(plays("A"), order_is("C B", true))},
    {"playing/waiting", "order on", "playing/order", check = both(plays("A"), order_is("B C", true))},
    {"playing/waiting", "order off", "playing/waiting", check = plays("A", "C")},
    {"playing/waiting", "chain link", "playing", check = scene_plays},
    {"playing/waiting", "recall", "playing", check = scene_plays},
    {"playing/order", "tap playing", "playing", check = both(plays("A"), order_is("B C", false))},
    {"playing/order", "tap another", "playing/waiting", check = both(plays("A", "B"), order_is("B C", false))},
    {"playing/order", "a bar", "playing/order", check = plays("B")},
    {"playing/order", "stop", "stopped/order", check = plays("A")},
    {"playing/order", "start", "playing/order", check = plays("B")},
    {"playing/order", "set_order", "playing/order", check = both(plays("A"), order_is("C B", true))},
    {"playing/order", "order on", "playing/order", check = plays("A")},
    {"playing/order", "order off", "playing", check = plays("A")},
    {"playing/order", "chain link", "playing", check = scene_plays},
    {"playing/order", "recall", "playing", check = scene_plays},
  },
  impossible = {
    {"stopped", "tap waiting", NO_WAIT},
    {"stopped/order", "tap waiting", NO_WAIT},
    {"playing", "tap waiting", "no letter waits in this state: only a tap of another letter while the patterns play"
      .. " makes one wait (switch)"},
    {"playing/order", "tap waiting", ORDER_WAIT},
  },
})

end

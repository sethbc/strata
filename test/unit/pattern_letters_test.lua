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
  refused(function() block[8] = block[2] end, function() block[8] = nil end, "an eighth voice")
  local voice_7 = block[h.voice_count()]
  refused(function() block[h.voice_count()] = nil end, function() block[h.voice_count()] = voice_7 end,
    "a voice missing")
  refused(function() block[1].shape = 1 end, function() block[1].shape = nil end, "an unknown voice key")
end)

end

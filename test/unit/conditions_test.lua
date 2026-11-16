-- test/unit/conditions_test.lua
-- Trig conditions' state and test (lib/conditions.lua, 3.7 design §5.1 and
-- §5.2): each voice's pass count and last conditioned outcome, the 78
-- conditions, the neighbor and fill (the latch and its holders)
-- Run alone: lua test/run.lua conditions

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function conditions()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  return S.lib.conditions, S, context
end

test("there are 78 conditions, in the row's order", function()
  local c = conditions()
  assert_equal(#c.values, 78, "78 values")
  assert_equal(c.values[1], "1:2"); assert_equal(c.values[2], "!1:2"); assert_equal(c.values[3], "2:2")
  assert_equal(c.values[5], "1:3"); assert_equal(c.values[70], "!8:8")
  assert_equal(c.values[71], "first"); assert_equal(c.values[78], "!fill")
  assert_equal(c.CONDITIONS.max_b, 8)
  for _, value in ipairs(c.values) do assert_true(c.valid(value), value .. " is valid") end
  for _, value in ipairs({"1:1", "9:9", "3:2", "0:2", "!9:9", "last", "", 2, {}, true}) do
    assert_true(not c.valid(value), tostring(value) .. " is not valid")
  end
  assert_true(not c.valid(nil), "nil is no condition")
end)

-- The passes in 1..n on which voice's cond holds
local function holding(c, voice, cond, n)
  local passes = {}
  c.start(voice)
  for pass = 1, n do
    assert_equal(c.pass(voice), pass, "pass " .. pass)
    if c.test(voice, cond) then passes[#passes + 1] = pass end
    c.next_pass(voice)
  end
  return table.concat(passes, " ")
end

test("A:B holds on the A-th of every B passes, and !A:B on the others", function()
  local c = conditions()
  assert_equal(holding(c, 1, "1:2", 6), "1 3 5")
  assert_equal(holding(c, 1, "2:2", 6), "2 4 6")
  assert_equal(holding(c, 1, "3:4", 8), "3 7")
  assert_equal(holding(c, 1, "!1:2", 6), "2 4 6")
  assert_equal(holding(c, 1, "!3:4", 8), "1 2 4 5 6 8")
  assert_equal(holding(c, 2, "8:8", 16), "8 16")
  assert_equal(holding(c, 1, nil, 2), "1 2", "no condition plays")
  assert_equal(holding(c, 1, "nonsense", 2), "1 2", "an unknown string plays")
end)

test("first, pre and nei read the pass and the last outcomes", function()
  local c = conditions()
  c.start(2); c.start(3)
  assert_equal(c.pass(2), 1)
  assert_true(c.test(2, "first"), "pass 1: first"); assert_true(not c.test(2, "!first"))
  assert_equal(c.outcome(2), nil, "no outcome before any")
  assert_true(not c.test(2, "pre"), "before any outcome pre is false"); assert_true(c.test(2, "!pre"))
  c.record(2, true)
  assert_equal(c.outcome(2), true)
  assert_true(c.test(2, "pre"), "pre after a played step"); assert_true(not c.test(2, "!pre"))
  assert_true(c.test(3, "nei"), "voice 3's neighbor is voice 2"); assert_true(not c.test(3, "!nei"))
  c.record(2, false)
  assert_true(not c.test(2, "pre")); assert_true(c.test(2, "!pre"))
  assert_true(not c.test(3, "nei")); assert_true(c.test(3, "!nei"))
  c.next_pass(2)
  assert_true(not c.test(2, "first"), "pass 2: not first"); assert_true(c.test(2, "!first"))
  assert_equal(c.outcome(2), false, "a pass keeps the outcome")
  assert_equal(c.neighbor(1), 7, "voice 1's neighbor is voice 7")
  assert_equal(c.neighbor(5), 4)
  c.start(7); c.start(1)
  c.record(7, true)
  assert_true(c.test(1, "nei"), "voice 1's nei reads voice 7")
  c.start(7)
  assert_equal(c.outcome(7), nil, "a start forgets the outcome"); assert_equal(c.pass(7), 1)
  assert_true(not c.test(1, "nei"))
end)

test("fill is the latch or any holder", function()
  local c = conditions()
  assert_true(not c.fill(), "off at the start")
  assert_true(c.test(1, "!fill")); assert_true(not c.test(1, "fill"))
  params:set("seq_fill", 1)
  assert_true(c.fill(), "the latch"); assert_true(c.test(1, "fill"))
  params:set("seq_fill", 0)
  c.hold_fill("grid:1", true)
  assert_true(c.fill(), "a holder")
  c.hold_fill("grid:2", true)
  c.hold_fill("grid:1", false)
  assert_true(c.fill(), "two holders, one released: still on")
  c.release_holder("grid:2")
  assert_true(not c.fill(), "none left")
  c.hold_fill("grid:1", true); params:set("seq_fill", 1); c.hold_fill("grid:1", false)
  assert_true(c.fill(), "a release leaves the latch")
  params:set("seq_fill", 0)
  local holds = true
  c.hold_fill("grid:3", true, function() return holds end)
  assert_true(c.fill(), "a holder that still holds")
  holds = false
  assert_true(not c.fill(), "a holder whose check fails no longer holds")
  holds = true
  assert_true(not c.fill(), "and is gone")
end)

test("seq_fill is never saved and starts off", function()
  local c, S = conditions()
  local param = params:lookup_param("seq_fill")
  assert_equal(param.save, false, "set_save(false)")
  assert_equal(params:get("seq_fill"), 0)
  assert_true(not c.fill())
  assert_true(S.lib.conditions == c)
end)

test("a voice out of range reads as pass 1 with no outcome and changes nothing", function()
  local c = conditions()
  assert_equal(c.pass(0), 1); assert_equal(c.pass(8), 1)
  c.record(9, true); c.next_pass(9); c.start(0)
  assert_equal(c.outcome(9), nil)
  assert_true(c.test(9, "1:2"), "a pass 1")
end)
end

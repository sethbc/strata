-- test/unit/chance_test.lua
-- The picker (lib/chance.lua, 3.7 design §0.5 and §5.4): the next of an
-- ordered list of slots by three chances (next, previous, random), one
-- draw, a repeat for what is left
-- Run alone: lua test/run.lua chance

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value = h.load_strata, h.local_value

local function picker()
  load_strata()
  return local_value("S").lib.chance
end

-- A random function that returns each of values in turn, and counts its calls
local function draws(...)
  local values, calls = { ... }, 0
  local function random()
    calls = calls + 1
    assert_true(calls <= #values, "no more than " .. #values .. " draws")
    return values[calls]
  end
  return random, function() return calls end
end

local function raises() error("a draw was made") end

test("100, 0, 0 plays in order with no draw", function()
  local chance = picker()
  local slot, move = chance.pick(2, { 1, 2, 3 }, { 100, 0, 0 }, raises)
  assert_equal(slot, 3, "the next slot")
  assert_equal(move, "next")
  slot, move = chance.pick(3, { 1, 2, 3 }, { 100, 0, 0 }, raises)
  assert_equal(slot, 1, "next past the last is the first")
  assert_equal(move, "next")
  slot, move = chance.pick(9, { 1, 2, 3 }, { 100, 0, 0 }, raises)
  assert_equal(slot, 1, "a current not in slots counts as before the first")
  assert_equal(move, "next")
  slot, move = chance.pick(5, { 5 }, { 100, 0, 0 }, raises)
  assert_equal(slot, 5, "one slot at 100, 0, 0: the slot again, by next (ruling 36)")
  assert_equal(move, "next")
  -- the slots are an ordered list of slot numbers, not 1..n
  slot = chance.pick(7, { 2, 7, 11 }, { 100, 0, 0 }, raises)
  assert_equal(slot, 11, "the slot after 7 in the list")
end)

test("each move is picked by one draw", function()
  local chance = picker()
  local slots, chances = { 1, 2, 3, 4 }, { 50, 30, 10 }
  local random, calls = draws(0.49)
  local slot, move = chance.pick(2, slots, chances, random)
  assert_equal(slot, 3); assert_equal(move, "next", "a draw below next")
  assert_equal(calls(), 1, "one draw")
  random, calls = draws(0.5)
  slot, move = chance.pick(2, slots, chances, random)
  assert_equal(slot, 1); assert_equal(move, "previous", "a draw below next + previous")
  assert_equal(calls(), 1)
  random, calls = draws(0.85, 0)
  slot, move = chance.pick(2, slots, chances, random)
  assert_equal(slot, 1, "a draw of 0 among the others: the first other slot")
  assert_equal(move, "random", "a draw below the sum")
  assert_equal(calls(), 2, "random draws once more")
  random = draws(0.85, 0.99)
  slot = chance.pick(2, slots, chances, random)
  assert_equal(slot, 4, "a draw near 1 among the others: the last")
  random = draws(0.85, 1)
  slot = chance.pick(2, slots, chances, random)
  assert_equal(slot, 4, "a draw of 1 stays inside the others")
  random, calls = draws(0.95)
  slot, move = chance.pick(2, slots, chances, random)
  assert_equal(slot, 2); assert_equal(move, "repeat", "a draw past the sum")
  assert_equal(calls(), 1)
  -- previous before the first is the last
  slot, move = chance.pick(1, slots, { 0, 100, 0 }, raises)
  assert_equal(slot, 4); assert_equal(move, "previous")
  slot = chance.pick(9, slots, { 0, 100, 0 }, raises)
  assert_equal(slot, 4, "a current not in slots: previous is the last")
  -- the default random is math.random
  slot, move = chance.pick(2, slots, { 0, 0, 0 })
  assert_equal(slot, 2); assert_equal(move, "repeat", "all three 0: a repeat")
end)

test("chances past 100 are scaled, and one slot can only repeat", function()
  local chance = picker()
  local slot, move = chance.pick(2, { 1, 2, 3 }, { 100, 100, 0 }, draws(0.49))
  assert_equal(slot, 3); assert_equal(move, "next", "200 scaled to 100: next below 50")
  slot, move = chance.pick(2, { 1, 2, 3 }, { 100, 100, 0 }, draws(0.51))
  assert_equal(slot, 1); assert_equal(move, "previous", "previous from 50")
  slot, move = chance.pick(2, { 1, 2, 3 }, { -50, 0, 0 }, draws(0.1))
  assert_equal(slot, 2); assert_equal(move, "repeat", "a chance below 0 counts as 0")
  slot, move = chance.pick(2, { 1, 2, 3 }, { 0 / 0, 0, 0 }, draws(0.1))
  assert_equal(move, "repeat", "a chance that is not a number counts as 0")
  for _, chances in ipairs({ { 0, 0, 100 }, { 30, 30, 40 }, { 0, 0, 0 } }) do
    slot = chance.pick(5, { 5 }, chances, draws(0.9, 0.5))
    assert_equal(slot, 5, "one slot: " .. table.concat(chances, ", "))
  end
  slot, move = chance.pick(5, { 5 }, { 0, 0, 100 }, draws(0.5))
  assert_equal(move, "repeat", "a random move with no other slot is a repeat")
  slot, move = chance.pick(2, {}, { 100, 0, 0 }, raises)
  assert_equal(slot, nil, "no slots: nil")
  assert_equal(move, nil)
end)

end

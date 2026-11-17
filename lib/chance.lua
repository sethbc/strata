-- lib/chance.lua
-- The picker (3.7, design §0.5 and §5.4; S.lib.chance): one pure function,
-- pick, the next of an ordered list of slots by three chances (next,
-- previous, random). Its one caller is the stepper, S.lib.scenes.next_slot,
-- under the scene sequencer, the pattern chain and the next-scene action.
-- It reads and keeps no state, sends nothing and never yields.

return function(S)
  local M = {}

  -- percent: what the three chances sum to at most (a larger sum is scaled
  -- down to it); moves: the names pick returns, in the draw's order
  local CHANCE = {percent = 100, moves = {"next", "previous", "random", "repeat"}}
  M.CHANCE = CHANCE

  -- A chance as pick counts it: a number above 0, else 0 (NaN included)
  local function counted(value)
    if type(value) ~= "number" or value ~= value or value <= 0 then return 0 end
    return value
  end

  -- current's index in slots, 0 when it is not there (before the first)
  local function position(slots, current)
    for index, slot in ipairs(slots) do
      if slot == current then return index end
    end
    return 0
  end

  -- The slot random picks: one more draw among the slots other than
  -- current, or nil when there is none
  local function other_slot(slots, current, random)
    local others = {}
    for _, slot in ipairs(slots) do
      if slot ~= current then others[#others + 1] = slot end
    end
    if #others == 0 then return nil end
    local index = math.floor(random() * #others) + 1
    return others[math.max(1, math.min(index, #others))]
  end

  -- The next slot and the move's name ("next", "previous", "random" or
  -- "repeat"). slots: an ordered list of slot numbers (next_slot hands it
  -- the playable ones); chances: {next, previous, random} in
  -- percent, each below 0 counted as 0, a sum above 100 scaled to 100;
  -- random: a function returning 0 to 1 (math.random by default). One draw
  -- r = random() * 100 picks next below next, previous below next +
  -- previous, random below the three's sum, else a repeat; none is made
  -- when one chance holds all 100 (or all are 0). Next past the last slot
  -- is the first, previous before the first the last; a current not in
  -- slots counts as before the first. Random draws once more among the
  -- other slots (with none, a repeat). An empty slots returns nil
  function M.pick(current, slots, chances, random)
    if type(slots) ~= "table" or #slots == 0 then return nil end
    random = random or math.random
    chances = type(chances) == "table" and chances or {}
    local next_chance, previous_chance, random_chance = counted(chances[1]), counted(chances[2]), counted(chances[3])
    local sum = next_chance + previous_chance + random_chance
    if sum > CHANCE.percent then
      local scale = CHANCE.percent / sum
      next_chance, previous_chance, random_chance = next_chance * scale, previous_chance * scale, random_chance * scale
      sum = CHANCE.percent
    end
    local move
    if next_chance >= CHANCE.percent then
      move = "next"
    elseif previous_chance >= CHANCE.percent then
      move = "previous"
    elseif random_chance >= CHANCE.percent then
      move = "random"
    elseif sum <= 0 then
      move = "repeat"
    else
      local r = random() * CHANCE.percent
      if r < next_chance then
        move = "next"
      elseif r < next_chance + previous_chance then
        move = "previous"
      elseif r < sum then
        move = "random"
      else
        move = "repeat"
      end
    end
    local index = position(slots, current)
    if move == "next" then return slots[index % #slots + 1], move end
    if move == "previous" then
      if index <= 1 then return slots[#slots], move end
      return slots[index - 1], move
    end
    if move == "random" then
      local slot = other_slot(slots, current, random)
      if slot ~= nil then return slot, move end
    end
    return current, "repeat"
  end

  return M
end

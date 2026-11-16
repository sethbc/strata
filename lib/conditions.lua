-- lib/conditions.lua
-- Trig conditions (3.7, design §5.1 and §5.2; S.lib.conditions): each
-- voice's pass count and the outcome of its last conditioned step, the test
-- of a step's condition (one of the 78 strings of M.values), the neighbor
-- rule, and fill: the latch (the seq_fill param, lib/sequencer.lua's) or
-- any holder (a grid key, "grid:<port>"). The sequencer asks it in
-- begin_voice_step, before the probability draw. Nothing here is stored:
-- the passes, the outcomes and the holders live only while Strata runs.
-- It sends nothing and never yields. See docs/notes/lua/conditions.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local CONDITIONS = S.constants.CONDITIONS
  M.CONDITIONS = CONDITIONS

  -- The 78 values in the edit row's order: for B from 2 to max_b, for A
  -- from 1 to B, "A:B" then "!A:B"; then the named ones. TESTS[value] is
  -- {kind, a, b, negated}
  local values, TESTS = {}, {}
  for b = 2, CONDITIONS.max_b do
    for a = 1, b do
      local value = a .. ":" .. b
      values[#values + 1], TESTS[value] = value, {kind = "every", a = a, b = b, negated = false}
      values[#values + 1], TESTS["!" .. value] = "!" .. value, {kind = "every", a = a, b = b, negated = true}
    end
  end
  for _, name in ipairs(CONDITIONS.names) do
    local negated = name:sub(1, 1) == "!"
    values[#values + 1], TESTS[name] = name, {kind = negated and name:sub(2) or name, negated = negated}
  end
  M.values = values

  -- Whether value is one of the 78
  function M.valid(value)
    return type(value) == "string" and TESTS[value] ~= nil
  end

  local function valid_voice(voice)
    return type(voice) == "number" and voice == math.floor(voice) and voice >= 1 and voice <= NUM_VOICES
  end

  -- Per voice: the pass (1 from a start) and the last conditioned outcome
  -- (true played, false not, nil before any)
  local passes, outcomes = {}, {}

  -- The voice's position starts (a pattern start, a restart, a division
  -- reset): pass 1, no outcome
  function M.start(voice)
    if not valid_voice(voice) then return end
    passes[voice], outcomes[voice] = 1, nil
  end

  -- The voice's pass ended
  function M.next_pass(voice)
    if not valid_voice(voice) then return end
    passes[voice] = (passes[voice] or 1) + 1
  end

  function M.pass(voice)
    return valid_voice(voice) and passes[voice] or 1
  end

  -- A conditioned step's outcome: whether it played
  function M.record(voice, played)
    if not valid_voice(voice) then return end
    outcomes[voice] = played and true or false
  end

  function M.outcome(voice)
    if not valid_voice(voice) then return nil end
    return outcomes[voice]
  end

  -- The voice above: voice - 1, and the last voice for voice 1
  function M.neighbor(voice)
    return voice <= 1 and NUM_VOICES or voice - 1
  end

  -- Fill's holders: [holder] = true, or a function that says whether it
  -- still holds (a grid key: false once its grid is gone or shows another
  -- page), asked whenever fill is read
  local holders = {}

  local function fill_changed()
    grid_redraw()
    request_redraw()
  end

  -- holder holds fill (on) or lets it go; still: an optional function,
  -- true while the hold stands (a hold it denies ends there)
  function M.hold_fill(holder, on, still)
    if holder == nil then return end
    if not on then return M.release_holder(holder) end
    local was = M.fill()
    holders[holder] = type(still) == "function" and still or true
    if not was then fill_changed() end
  end

  -- holder's hold ends, whatever it was; the latch stays
  function M.release_holder(holder)
    if holder == nil or holders[holder] == nil then return end
    holders[holder] = nil
    if not M.fill() then fill_changed() end
  end

  -- Whether any holder still holds (a read drops nothing: it may run in a
  -- page's draw)
  local function held()
    for _, still in pairs(holders) do
      if still == true or still() then return true end
    end
    return false
  end

  -- Each LFO step (48 Hz, never inside a draw): a holder whose check now
  -- denies it is dropped, and the grids and the screen redraw (an
  -- unplugged grid's hold ends with no key event of its own)
  S.lib.lfos.on_step(function()
    local dropped = false
    for holder, still in pairs(holders) do
      if still ~= true and not still() then
        holders[holder] = nil
        dropped = true
      end
    end
    if dropped then fill_changed() end
  end)

  -- Fill is on: the latch (seq_fill 1) or any holder
  function M.fill()
    local latched = params.lookup["seq_fill"] ~= nil and params:get("seq_fill") == 1
    return held() or latched
  end

  -- Whether a step with condition cond plays now on voice: nil or an
  -- unknown string plays; A:B on the A-th of every B passes
  function M.test(voice, cond)
    local spec = cond ~= nil and TESTS[cond]
    if not spec then return true end
    local holds
    if spec.kind == "every" then
      holds = (M.pass(voice) - 1) % spec.b == spec.a - 1
    elseif spec.kind == "first" then
      holds = M.pass(voice) == 1
    elseif spec.kind == "pre" then
      holds = M.outcome(voice) == true
    elseif spec.kind == "nei" then
      holds = valid_voice(voice) and M.outcome(M.neighbor(voice)) == true
    else
      holds = M.fill()
    end
    if spec.negated then return not holds end
    return holds
  end

  for voice = 1, NUM_VOICES do M.start(voice) end

  return M
end

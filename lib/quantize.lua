-- lib/quantize.lua
-- The quantized-action scheduler (3.4, design §8.9), S.lib.quantize: a user
-- action that may wait for the next beat or bar (a scene recall, a freeze
-- toggle, a bookmark recall or position jump, the pattern start) goes
-- through schedule(key, fn, label). In Wave 0 there is no quantize param:
-- every action runs at once, nothing waits and add_params adds nothing
-- (PARAM_COUNT 0). Package 1f adds the quantize_actions param (the fifth
-- of the strata_seq group, which lib/sequencer.lua's add_params sizes with
-- PARAM_COUNT and fills by calling add_params), the waits, the header
-- flash and the cleanup step (CLEANUP_ORDER.quantize).

return function(S)
  local M = {}

  -- The scheduler's own tunables (1f adds the modes and their beats)
  local QUANTIZE = {param_count = 0}
  M.QUANTIZE = QUANTIZE
  M.PARAM_COUNT = QUANTIZE.param_count  -- the params add_params adds

  -- Run fn now, or (from 1f) at the next beat or bar, replacing a waiting
  -- action of the same key; label names it in the header's flash. Returns
  -- whether fn ran at once (always, in Wave 0)
  function M.schedule(key, fn, label)
    if type(key) ~= "string" or key == "" then error("quantize.schedule: a key is a string", 2) end
    if type(fn) ~= "function" then error("quantize.schedule: an action is a function", 2) end
    fn()
    return true
  end

  -- Whether an action of this key waits (never, in Wave 0)
  function M.waiting(key)
    return false
  end

  -- The scheduler's params, PARAM_COUNT of them (none in Wave 0)
  function M.add_params()
  end

  return M
end

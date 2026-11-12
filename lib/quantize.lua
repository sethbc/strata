-- lib/quantize.lua
-- The quantized-action scheduler (3.4, design §8.9), S.lib.quantize: a user
-- action that may wait for the next beat or bar (a scene recall, a freeze
-- toggle, a bookmark recall or position jump, the pattern start) goes
-- through schedule(key, fn, label). The quantize_actions param (off, beat,
-- bar) says how long: off runs fn at once, beat and bar wait on a clock for
-- the next beat or bar (clock.sync), a new action of the same key replacing
-- the waiting one, and the header flashes "<label> at <beat|bar>" while it
-- waits. The param is the fifth of the strata_seq group, which
-- lib/sequencer.lua's add_params sizes with PARAM_COUNT and fills by
-- calling add_params (lib/params_setup.lua's "seq" record adds the group
-- with this param alone while the sequencer has none). Registers the
-- cleanup step CLEANUP_ORDER.quantize and the "quantize" invariant.

return function(S)
  local M = {}

  -- The scheduler's own tunables: its one param, the modes in option order
  -- and the beats a mode waits for (clock.sync's quantum)
  local QUANTIZE = {param_count = 1, param_id = "quantize_actions", modes = {"off", "beat", "bar"},
    beats = {beat = 1, bar = 4}}
  M.QUANTIZE = QUANTIZE
  M.PARAM_COUNT = QUANTIZE.param_count  -- the params add_params adds

  -- The waiting actions, by key: {clock = the coroutine that waits, flash =
  -- the header text it shows, or nil, token = its number}. Tests read the
  -- clocks here
  M.actions = {}
  local last_token = 0  -- each waiting action's own number, never reused

  -- The mode the param names ("off" before the params exist)
  local function mode()
    if not params.lookup[QUANTIZE.param_id] then return "off" end
    return QUANTIZE.modes[params:get(QUANTIZE.param_id)] or "off"
  end

  -- End an action's header flash if it still shows
  local function end_flash(action)
    if action.flash and S.lib.ui_flash.text("header") == action.flash then S.lib.ui_flash.start("header", nil) end
  end

  -- Drop the action of this key that waits, if one does: its clock is
  -- canceled and, unless keep_flash, its flash ends
  local function cancel(key, keep_flash)
    local action = M.actions[key]
    if not action then return end
    M.actions[key] = nil
    clock.cancel(action.clock)
    if not keep_flash then end_flash(action) end
  end

  -- Run fn now (quantize_actions off) or at the next beat or bar, replacing
  -- a waiting action of the same key; while it waits, label shows in the
  -- header as "<label> at beat" or "<label> at bar" (for at most the beat
  -- or bar, ending when fn runs). Returns whether fn ran at once and, for an
  -- action that waits, its token (waiting(key, token) tells whether that
  -- one still waits). A waiting fn that raises prints "strata: quantized
  -- <key> failed: <error>"
  function M.schedule(key, fn, label)
    if type(key) ~= "string" or key == "" then error("quantize.schedule: a key is a string", 2) end
    if type(fn) ~= "function" then error("quantize.schedule: an action is a function", 2) end
    cancel(key)
    local waits = mode()
    if waits == "off" then
      fn()
      return true
    end
    local beats = QUANTIZE.beats[waits]
    last_token = last_token + 1
    local action = {flash = label and (tostring(label) .. " at " .. waits) or nil, token = last_token}
    action.clock = clock.run(function()
      clock.sync(beats)
      if M.actions[key] == action then M.actions[key] = nil end
      end_flash(action)
      local ran, failure = xpcall(fn, with_traceback)
      if not ran then print("strata: quantized " .. key .. " failed: " .. tostring(failure)) end
    end)
    M.actions[key] = action
    if action.flash then S.lib.ui_flash.start("header", action.flash, beats * clock.get_beat_sec()) end
    return false, action.token
  end

  -- Whether an action of this key waits; with a token, whether the one
  -- that waits is the action schedule gave that token
  function M.waiting(key, token)
    local action = M.actions[key]
    return action ~= nil and (token == nil or action.token == token)
  end

  -- The scheduler's params, PARAM_COUNT of them: quantize_actions
  function M.add_params()
    params:add_option(QUANTIZE.param_id, "quantize actions", QUANTIZE.modes, 1)
  end

  -- An action waits exactly while its clock runs
  S.register_invariant("quantize", function()
    for key, action in pairs(M.actions) do
      if type(action.clock) ~= "number" then return key .. " waits with no clock" end
      if clock.threads and clock.threads[action.clock] == nil then
        return key .. " waits on clock " .. action.clock .. ", which no longer runs"
      end
    end
  end)

  -- Cleanup cancels every waiting action (the flashes' own step ends the
  -- header's flash)
  S.register_cleanup(S.constants.CLEANUP_ORDER.quantize, function()
    for key in pairs(M.actions) do cancel(key, true) end
  end)

  return M
end

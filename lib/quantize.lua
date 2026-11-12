-- lib/quantize.lua
-- The quantized-action scheduler (3.4, design §8.9), S.lib.quantize: a user
-- action that may wait for the next beat or bar (a scene recall, a freeze
-- toggle, a bookmark recall or position jump, the pattern start) goes
-- through schedule(key, fn, label). The quantize_actions param (off, beat,
-- bar) says how long: off runs fn at once, beat and bar wait on a clock for
-- the next beat or bar (clock.sync), a new action of the same key replacing
-- the waiting one (cancel(key) drops one: a toggle pressed again), and the
-- header flashes "<label> at <beat|bar>" while it waits. The param is the
-- fifth of the strata_seq group, which lib/sequencer.lua's add_params sizes
-- with PARAM_COUNT and fills by calling add_params. Registers the cleanup
-- step CLEANUP_ORDER.quantize and the "quantize" invariant.

return function(S)
  local M = {}

  -- The scheduler's own tunables: its one param, the modes in option order,
  -- the beats a mode waits for (clock.sync's quantum), how near its beat a
  -- clock's resume may be posted (a tick's jitter, as the sequencer's
  -- SEQ.wake_tolerance), matron's FLT_EPSILON, with which its scheduler
  -- finds a sync's beat (clock_scheduler_next_clock_beat), and the seconds
  -- a waiting action's flash is started for: no time ends it, only the
  -- action's run or drop (end_flash), however long it waits (#631)
  local QUANTIZE = {param_count = 1, param_id = "quantize_actions", modes = {"off", "beat", "bar"},
    beats = {beat = 1, bar = 4}, wake_tolerance = 1 / 32, flt_epsilon = 2 ^ -23, flash_seconds = math.huge}
  M.QUANTIZE = QUANTIZE
  M.PARAM_COUNT = QUANTIZE.param_count  -- the params add_params adds

  -- The waiting actions, by key: {clock = the coroutine that waits, flash =
  -- the header text it shows, or nil, token = its number, sync_beat = the
  -- beat it synced at, landing = the beat its sync lands on}. Tests read
  -- the clocks here
  M.actions = {}
  -- The clocks of dropped actions whose resume matron may have posted,
  -- [id] = true: each ends at that resume, doing nothing (#626)
  M.retired = {}
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

  -- Whether matron may have posted the resume of a waiting action's clock
  -- and norns not delivered it yet: its sync's beat is near or passed, or
  -- the beat is below the one it synced at (a reset or a new clock source
  -- has moved its sync since)
  local function resume_may_be_posted(action)
    local now = clock.get_beats()
    return now < action.sync_beat or action.landing - now <= QUANTIZE.wake_tolerance
  end

  -- Drop the action of this key that waits, if one does, and, unless
  -- keep_flash, end its flash. Its clock is never canceled while its resume
  -- may be posted: norns would deliver that resume to a coroutine it no
  -- longer has (clock.resume raises, maiden prints the error, #626). Such a
  -- clock is retired (M.retired) and ends at that resume, doing nothing;
  -- any other is canceled at once. Returns whether one waited
  local function cancel(key, keep_flash)
    local action = M.actions[key]
    if not action then return false end
    M.actions[key] = nil
    if resume_may_be_posted(action) then
      M.retired[action.clock] = true
    else
      clock.cancel(action.clock)
    end
    if not keep_flash then end_flash(action) end
    return true
  end

  -- Drop the action of this key that waits (its flash ends with it), and
  -- say whether one did: a toggle pressed again while its action waits
  -- takes it back (lib/freeze.lua, the play key), and any start or stop of
  -- the patterns drops a waiting start (#625)
  function M.cancel(key)
    if type(key) ~= "string" then return false end
    return cancel(key)
  end

  -- Run fn now (quantize_actions off) or at the next beat or bar, replacing
  -- a waiting action of the same key; while it waits, label shows in the
  -- header as "<label> at beat" or "<label> at bar" (for as long as it
  -- waits, ending when fn runs or the action is dropped, #631; another
  -- flash can take its place). Returns whether fn ran at once and, for an
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
    -- the clock's first wait is this sync, so matron counts it from now
    local now = clock.get_beats()
    local action = {flash = label and (tostring(label) .. " at " .. waits) or nil, token = last_token,
      sync_beat = now, landing = math.ceil((now + QUANTIZE.flt_epsilon) / beats) * beats}
    action.clock = clock.run(function()
      clock.sync(beats)
      if M.actions[key] ~= action then
        M.retired[action.clock] = nil  -- dropped meanwhile (cancel): it ends here
        return
      end
      M.actions[key] = nil
      end_flash(action)
      local ran, failure = xpcall(fn, with_traceback)
      if not ran then print("strata: quantized " .. key .. " failed: " .. tostring(failure)) end
    end)
    M.actions[key] = action
    if action.flash then S.lib.ui_flash.start("header", action.flash, QUANTIZE.flash_seconds) end
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

  -- An action waits exactly while its clock runs, and a retired clock runs
  -- until its resume (it is forgotten then)
  S.register_invariant("quantize", function()
    for key, action in pairs(M.actions) do
      if type(action.clock) ~= "number" then return key .. " waits with no clock" end
      if clock.threads and clock.threads[action.clock] == nil then
        return key .. " waits on clock " .. action.clock .. ", which no longer runs"
      end
      if M.retired[action.clock] then return key .. " waits on clock " .. action.clock .. ", which was retired" end
    end
    for id in pairs(M.retired) do
      if clock.threads and clock.threads[id] == nil then return "retired clock " .. id .. " has gone but is kept" end
    end
  end)

  -- Cleanup cancels every waiting action's clock and every retired one
  -- (norns cancels every coroutine right after cleanup anyway); the flashes'
  -- own step ends the header's flash
  S.register_cleanup(S.constants.CLEANUP_ORDER.quantize, function()
    for key, action in pairs(M.actions) do
      M.actions[key] = nil
      clock.cancel(action.clock)
    end
    for id in pairs(M.retired) do
      M.retired[id] = nil
      clock.cancel(id)
    end
  end)

  return M
end

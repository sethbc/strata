-- lib/clocks.lua
-- The clock helper (3.9 design section 3, #870), S.lib.clocks: #626's rule
-- held once. norns delivers every resume matron has posted, and one whose
-- coroutine was canceled meanwhile makes clock.resume raise (maiden prints
-- `bad argument #1 to 'resume'`). So a clock run here (run(fn): fn(handle)
-- runs in it, every wait through handle.sleep or handle.sync) is stopped
-- with stop(handle), which cancels it only while its wait's end is farther
-- off than a margin, and otherwise retires it: its wait returns false at
-- its wake and its body returns, doing nothing more. cancel(handle) ends
-- one at once, whatever its wait (a cleanup step's, when norns ends every
-- clock anyway). Registers the "clocks" invariant and the cleanup step
-- CLEANUP_ORDER.clocks, the last of all, which cancels what is still
-- retired

return function(S)
  local M = {}

  -- sleep_margin: seconds before a sleep's wake its resume may be posted;
  -- sync_tolerance: beats before a sync's landing it may be (a tick's
  -- jitter); sync_epsilon: matron's FLT_EPSILON, with which it finds a
  -- sync's landing
  local CLOCKS = S.constants.CLOCKS

  -- The stopped clocks whose resume may be posted, [id] = handle: each ends
  -- at that resume, and is forgotten then (or canceled by cancel or cleanup)
  M.retired = {}

  -- The beat a sync of `beats` and `offset` from beat `from` lands on, as
  -- matron's clock_scheduler_next_clock_beat finds it
  local function next_beat(from, beats, offset)
    local beat = math.ceil((from + CLOCKS.sync_epsilon) / beats) * beats + offset
    while beat < from + CLOCKS.sync_epsilon do beat = beat + beats end
    return math.max(beat, 0)
  end

  -- Whether matron may have posted the resume of a handle's wait and norns
  -- not delivered it yet: a sleep within sleep_margin of its wake or past
  -- it; a sync within sync_tolerance of its landing or past it, or whose
  -- beat is below the one it synced at (a reset or a new clock source has
  -- moved it since), or whose landing is not known
  local function resume_may_be_posted(handle)
    if handle.waiting == "sleep" then return util.time() >= handle.wake - CLOCKS.sleep_margin end
    local now = clock.get_beats()
    return handle.landing == nil or now < handle.sync_beat or handle.landing - now <= CLOCKS.sync_tolerance
  end

  -- After a wait: false (and the handle forgotten) once it was stopped
  local function resumed(handle)
    handle.waiting = nil
    if not handle.stopped then return true end
    if handle.id then M.retired[handle.id] = nil end
    return false
  end

  -- Start a clock running fn(handle) and return its handle: handle.id is
  -- the clock's id once run has returned (clock.run resumes fn before it
  -- returns, so the id is not known in fn before its first wait). Every
  -- wait in fn is `if not handle.sleep(seconds) then return end` (or
  -- handle.sync(beat, offset)): each waits as clock.sleep or clock.sync
  -- does and returns false, at once or at its wake, once the handle was
  -- stopped
  function M.run(fn)
    if type(fn) ~= "function" then error("clocks.run: a clock's body is a function", 2) end
    local handle = {stopped = false, ended = false}
    function handle.sleep(seconds)
      if handle.stopped then return false end
      handle.waiting, handle.from_beat = "sleep", nil
      handle.wake = util.time() + (type(seconds) == "number" and math.max(seconds, 0) or 0)
      clock.sleep(seconds)
      return resumed(handle)
    end
    function handle.sync(beats, offset)
      if handle.stopped then return false end
      local now = clock.get_beats()
      -- matron counts a sync from the beat of the coroutine's last, when its
      -- last wait was one (the beat it resumed with stands for it)
      local from = handle.from_beat or now
      handle.waiting, handle.sync_beat = "sync", now
      handle.landing = nil
      if type(beats) == "number" and beats > 0 then
        handle.landing = next_beat(from, beats, type(offset) == "number" and offset or 0)
      end
      local woke = clock.sync(beats, offset)
      handle.from_beat = type(woke) == "number" and woke or handle.landing
      return resumed(handle)
    end
    handle.id = clock.run(function()
      fn(handle)
      handle.ended, handle.waiting = true, nil
      if handle.id then M.retired[handle.id] = nil end
    end)
    return handle
  end

  -- End a handle's clock (nil, a stopped or an ended one: nothing), never
  -- raising: canceled at once while its wait's end is farther off than the
  -- margin, else retired (M.retired), to end at its wake. A clock stopped
  -- from its own body (it runs now) is neither: its next wait returns false
  function M.stop(handle)
    if type(handle) ~= "table" or handle.stopped or handle.ended then return end
    handle.stopped = true
    if handle.waiting == nil or type(handle.id) ~= "number" then return end
    if resume_may_be_posted(handle) then
      M.retired[handle.id] = handle
    else
      clock.cancel(handle.id)
    end
  end

  -- End a handle's clock at once, whatever its wait (nil or an ended one:
  -- nothing): for a cleanup step, when norns ends every clock anyway and
  -- the cleanup-order test looks for the cancel
  function M.cancel(handle)
    if type(handle) ~= "table" then return end
    handle.stopped = true
    if type(handle.id) ~= "number" then return end
    M.retired[handle.id] = nil
    if not handle.ended then clock.cancel(handle.id) end
  end

  -- Whether a handle's clock runs: started, never stopped, its body not
  -- ended and its coroutine not dead
  function M.alive(handle)
    if type(handle) ~= "table" or handle.stopped ~= false or handle.ended then return false end
    if type(handle.id) ~= "number" or not clock.threads then return true end
    local thread = clock.threads[handle.id]
    return type(thread) == "thread" and coroutine.status(thread) ~= "dead"
  end

  -- A retired clock is a stopped one that still waits for its wake: its
  -- coroutine is pending until then, and it is forgotten when it ends
  S.register_invariant("clocks", function()
    for id, handle in pairs(M.retired) do
      if handle.id ~= id or not handle.stopped then return "retired clock " .. tostring(id) .. " is not a stopped handle's" end
      local thread = clock.threads and clock.threads[id]
      if clock.threads and (type(thread) ~= "thread" or coroutine.status(thread) == "dead") then
        return "retired clock " .. id .. " has gone but is kept"
      end
    end
  end)

  -- Cleanup, the last step (the grids' own step ends their hold clocks
  -- late): cancel every retired clock still waiting
  S.register_cleanup(S.constants.CLEANUP_ORDER.clocks, function()
    for id in pairs(M.retired) do
      M.retired[id] = nil
      clock.cancel(id)
    end
  end)

  return M
end

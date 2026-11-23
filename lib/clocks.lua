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

  -- The clocks stopped while their body waited outside its handle (a bare
  -- clock.sleep or clock.sync, a mistake), [id] = handle: kept until cancel
  -- or cleanup, so the invariant still names one that ran on and ended
  -- before the harness checks it (#954)
  M.bare = {}

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

  -- Whether a stopped handle may wait on: false (and the handle forgotten,
  -- if it was retired) once it was stopped
  local function may_go_on(handle)
    if not handle.stopped then return true end
    if handle.id then M.retired[handle.id] = nil end
    return false
  end

  -- After a wait: whether the body goes on (false once it was stopped)
  local function resumed(handle)
    handle.waiting = nil
    return may_go_on(handle)
  end

  -- The beat matron counts a repeated sync's next landing from, once a
  -- sync of `beats` and `offset` (asked at handle.sync_beat, its landing
  -- handle.landing) resumed with the beat `woke`, its tick's. Matron's
  -- stored landing normally lies within a tick below woke (a tick posts a
  -- sync once the beat is past it), on the sync's grid, k * beats +
  -- offset, when it is the helper's landing or a reschedule's (a new clock
  -- source: the next landing after the new beat) of a coroutine that had
  -- waited before, and 0 after a reset. So the grid point at most
  -- sync_tolerance below woke, where it is no later than the landing or
  -- the landing was ahead when asked (a reschedule forward, #953's
  -- comment); 0 for a beat gone back to within the tolerance of 0 (a
  -- reset); else the lower of the landing and woke. Where it can be a
  -- period later than matron's: docs/notes/lua/clocks.md
  local function counted_from(handle, woke, beats, offset)
    local landing = handle.landing
    if type(woke) ~= "number" then return landing end
    if not landing then return woke end
    if woke < handle.sync_beat and woke <= CLOCKS.sync_tolerance then return 0 end
    local grid = math.floor((woke - offset) / beats) * beats + offset
    if woke - grid <= CLOCKS.sync_tolerance and (grid <= landing or landing > handle.sync_beat) then return grid end
    return math.min(landing, woke)
  end

  -- Whether a started handle's coroutine has gone: clock.threads[id] is
  -- no live coroutine (canceled outside the helper, or dead), so no wake
  -- is to come (#962)
  local function gone(handle)
    if type(handle.id) ~= "number" or not clock.threads then return false end
    local thread = clock.threads[handle.id]
    return type(thread) ~= "thread" or coroutine.status(thread) == "dead"
  end

  -- Whether a handle's body waits outside its handle: it has started (its
  -- id known) and its coroutine (clock.threads[id], as lua/core/clock.lua
  -- keeps it) is suspended though the handle waits on nothing. One that
  -- runs is not ("running", or "normal" while a coroutine it resumed
  -- runs), nor a dead one or one gone from clock.threads (a body that
  -- raised, which the helper cancels as it raises, #956), #954
  local function waits_bare(handle)
    if type(handle.id) ~= "number" or not clock.threads then return false end
    local thread = clock.threads[handle.id]
    return type(thread) == "thread" and coroutine.status(thread) == "suspended"
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
      if not may_go_on(handle) then return false end
      handle.waiting, handle.from_beat = "sleep", nil
      handle.wake = util.time() + (type(seconds) == "number" and math.max(seconds, 0) or 0)
      clock.sleep(seconds)
      return resumed(handle)
    end
    function handle.sync(beats, offset)
      if not may_go_on(handle) then return false end
      local now = clock.get_beats()
      -- matron counts a sync from the landing of the coroutine's last, when
      -- its last wait was one (clock_scheduler.cc)
      local from = handle.from_beat or now
      handle.waiting, handle.sync_beat = "sync", now
      handle.landing = nil
      local grid_offset = type(offset) == "number" and offset or 0
      if type(beats) == "number" and beats > 0 then
        handle.landing = next_beat(from, beats, grid_offset)
      end
      local woke = clock.sync(beats, offset)
      -- the landing matron stored, worked out from the beat it resumed
      -- with (a tick after the landing: matron's tick posts the beat it
      -- reads, #870's review), after a reset or a new clock source too
      handle.from_beat = counted_from(handle, woke, beats, grid_offset)
      return resumed(handle)
    end
    handle.id = clock.run(function()
      local ok, err = pcall(fn, handle)
      handle.ended, handle.waiting = true, nil
      if handle.id then M.retired[handle.id] = nil end
      if not ok then
        -- #956: clock.resume raises without canceling a body that raised,
        -- leaving its coroutine in clock.threads and its scheduler slot
        -- claimed until cleanup. Cancel it here, from inside its own run:
        -- clock.cancel only clears its slot (no wait is scheduled while it
        -- runs) and its clock.threads entry (clock.resume holds the
        -- coroutine), then raise the body's error as it was raised, for
        -- clock.resume to report as before. A body that raised before its
        -- first wait (no id yet) had no slot: clock.run raises it
        if type(handle.id) == "number" then clock.cancel(handle.id) end
        error(err, 0)
      end
    end)
    return handle
  end

  -- End a handle's clock (nil, a stopped or an ended one: nothing), never
  -- raising: canceled at once while its wait's end is farther off than the
  -- margin, else retired (M.retired), to end at its wake. One whose
  -- coroutine has gone (gone) is neither: no wake is to come. A clock stopped
  -- from its own body's run (from a coroutine it resumed, too) is neither:
  -- its next wait returns false (one whose body raised is ended). One whose
  -- body waits outside its handle (a bare clock.sleep or clock.sync, a
  -- mistake) is retired, its wait's end not known, and kept in M.bare,
  -- which the invariant names
  function M.stop(handle)
    if type(handle) ~= "table" or handle.stopped or handle.ended then return end
    handle.stopped = true
    if gone(handle) then return end
    if handle.waiting == nil then
      if not waits_bare(handle) then return end
      M.bare[handle.id] = handle
      M.retired[handle.id] = handle
    elseif resume_may_be_posted(handle) then
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
    M.retired[handle.id], M.bare[handle.id] = nil, nil
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
  -- coroutine is pending until then, and it is forgotten when it ends; none
  -- was stopped while its body waited outside its handle, since the last
  -- cancel or cleanup (M.bare), whether or not it ran on since
  S.register_invariant("clocks", function()
    for id in pairs(M.bare) do
      return "clock " .. tostring(id) .. " was stopped while its body waited outside its handle (a bare clock.sleep or clock.sync)"
    end
    for id, handle in pairs(M.retired) do
      if handle.id ~= id or not handle.stopped then return "retired clock " .. tostring(id) .. " is not a stopped handle's" end
      local thread = clock.threads and clock.threads[id]
      if clock.threads and (type(thread) ~= "thread" or coroutine.status(thread) == "dead") then
        return "retired clock " .. id .. " has gone but is kept"
      end
    end
  end)

  -- Cleanup, the last step (the grids' own step ends their hold clocks
  -- late): cancel every retired clock still waiting, and forget the bare
  -- stops
  S.register_cleanup(S.constants.CLEANUP_ORDER.clocks, function()
    for id in pairs(M.bare) do M.bare[id] = nil end
    for id in pairs(M.retired) do
      M.retired[id] = nil
      clock.cancel(id)
    end
  end)

  return M
end

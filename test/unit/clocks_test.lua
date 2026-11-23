-- test/unit/clocks_test.lua
-- The clock helper (lib/clocks.lua, S.lib.clocks, 3.9 design section 3,
-- #870): a clock run through it is stopped without ever being canceled
-- while its resume may be posted (#626): near its wake it is retired and
-- ends at that wake, its body told by a false wait; far from it, it is
-- canceled at once. cancel ends one at once whatever its wait (a cleanup
-- step's), the helper's own cleanup step cancels what is still retired,
-- and its invariant wants every retired clock still waiting
-- Run alone: lua test/run.lua clocks

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value = h.load_strata, h.local_value

-- A script loaded, its S and the helper
local function loaded()
  local context = load_strata()
  local S = local_value("S")
  return context, S, S.lib.clocks
end

-- A clock that sleeps `seconds` (or syncs on `beats`, with `sync`) again
-- and again, counting in counts.runs each wait that returned true and in
-- counts.ended its body's end
local function repeating(clocks, counts, wait, amount)
  return clocks.run(function(handle)
    while handle[wait](amount) do counts.runs = counts.runs + 1 end
    counts.ended = counts.ended + 1
  end)
end

-- The clock errors the scheduler recorded, claimed: none is expected
local function assert_no_clock_error(context, what)
  local errors = context.clock.take_errors()
  assert_equal(#errors, 0, what .. ": no resume reaches a canceled clock" .. (errors[1] and (": " .. errors[1]) or ""))
end

-- The "clocks" invariant (S.registry.invariants), called as the harness calls it
local function clocks_invariant(S)
  for _, record in ipairs(S.registry.invariants) do
    if record.name == "clocks" then return record.fn end
  end
end

-- Run the clocks until the beat timeline reads `beat` (120 BPM)
local function run_to_beat(context, beat)
  context.clock.run_for((beat - clock.get_beats()) * clock.get_beat_sec())
  assert_near(clock.get_beats(), beat, 1e-6, "the clock reached beat " .. beat)
end

test("a stop inside the margin retires: no clock error at the wake and the body does not run again", function()
  local context, S, clocks = loaded()
  local counts = {runs = 0, ended = 0}
  local handle = repeating(clocks, counts, "sleep", 1)
  assert_equal(type(handle.id), "number", "run returns the handle with its clock's id")
  assert_true(clocks.alive(handle), "the clock runs")
  -- the stop falls after the scheduler posted the wake and before Lua delivers it
  context.clock.advance_until(handle.id, function()
    clocks.stop(handle)
    assert_true(clock.threads[handle.id] ~= nil, "retired, not canceled: its resume is posted")
    assert_equal(clocks.retired[handle.id], handle, "the helper keeps it until its wake")
    assert_true(not clocks.alive(handle), "a stopped clock is not alive")
  end)
  assert_no_clock_error(context, "a sleep stopped at its wake")
  assert_equal(counts.runs, 0, "the wait returned false: the body did not run again")
  assert_equal(counts.ended, 1, "and ended")
  assert_equal(clock.threads[handle.id], nil, "its coroutine has ended")
  assert_equal(clocks.retired[handle.id], nil, "and the helper forgot it")
  -- within the margin of the wake, before the scheduler posted it: retired too
  local early = repeating(clocks, counts, "sleep", 1)
  context.clock.run_for(1 - S.constants.CLOCKS.sleep_margin / 2)
  clocks.stop(early)
  assert_equal(clocks.retired[early.id], early, "half the margin before its wake: retired")
  context.clock.run_for(0.1)
  assert_no_clock_error(context, "a sleep stopped inside the margin")
  assert_equal(clock.threads[early.id], nil, "it ended at its wake")
  assert_equal(counts.runs, 0, "doing nothing")
  -- a sync stopped as its beat's resume is posted
  local synced = repeating(clocks, counts, "sync", 1)
  context.clock.advance_until(synced.id, function() clocks.stop(synced) end)
  assert_no_clock_error(context, "a sync stopped at its beat")
  assert_equal(counts.runs, 0, "the sync returned false")
  assert_equal(clock.threads[synced.id], nil, "it ended at its beat")
  -- a sync that has woken once counts its next beat as matron does, from the last
  local counted = repeating(clocks, counts, "sync", 1)
  context.clock.advance_until(counted.id)
  assert_equal(counts.runs, 1, "the first beat ran")
  context.clock.advance_until(counted.id, function() clocks.stop(counted) end)
  assert_no_clock_error(context, "a repeating sync stopped at its second beat")
  assert_equal(counts.runs, 1, "and nothing more")
  assert_equal(counts.ended, 4, "every body ended")
end)

test("a stop far from the wake cancels at once", function()
  local context, S, clocks = loaded()
  local counts = {runs = 0, ended = 0}
  local slept = repeating(clocks, counts, "sleep", 10)
  context.clock.run_for(1)
  clocks.stop(slept)
  assert_equal(clock.threads[slept.id], nil, "a sleep 9 s from its wake is canceled at once")
  assert_equal(clocks.retired[slept.id], nil, "and not kept")
  run_to_beat(context, clock.get_beats() + 0.2)
  local synced = repeating(clocks, counts, "sync", 4)
  run_to_beat(context, clock.get_beats() + 1)
  clocks.stop(synced)
  assert_equal(clock.threads[synced.id], nil, "a sync beats from its landing is canceled at once")
  context.clock.run_for(20)
  assert_no_clock_error(context, "far stops")
  assert_equal(counts.runs, 0, "neither body ran again")
  assert_equal(counts.ended, 0, "nor reached its end")
  assert_true(not clocks.alive(slept) and not clocks.alive(synced), "neither is alive")
end)

test("a sync whose beat went backwards retires", function()
  local context, S, clocks = loaded()
  local counts = {runs = 0, ended = 0}
  run_to_beat(context, 1.5)
  local handle = repeating(clocks, counts, "sync", 4)
  run_to_beat(context, 2)
  -- a transport start's reset: the beat is 0 and the sync fires at the next tick
  context.clock.transport_reset()
  clocks.stop(handle)
  assert_true(clock.threads[handle.id] ~= nil, "below the beat it synced at, it is retired, not canceled")
  context.clock.advance()
  assert_no_clock_error(context, "a sync stopped after a reset")
  assert_equal(counts.runs, 0, "it ended at the reset's resume, doing nothing")
  assert_equal(clock.threads[handle.id], nil, "its coroutine has ended")
  -- after a reset a repeating sync counts from the reset's beat, as matron does
  local counted = repeating(clocks, counts, "sync", 1)
  run_to_beat(context, clock.get_beats() + 0.5)
  context.clock.transport_reset()
  context.clock.advance_until(counted.id)
  assert_equal(counts.runs, 1, "the reset woke it")
  context.clock.advance_until(counted.id, function() clocks.stop(counted) end)
  assert_no_clock_error(context, "a sync stopped at the beat after a reset")
  assert_equal(counts.runs, 1, "and it did nothing more")
end)

test("stop is safe on nil and on a stopped handle", function()
  local context, S, clocks = loaded()
  local counts = {runs = 0, ended = 0}
  clocks.stop(nil); clocks.cancel(nil)
  clocks.stop({}); clocks.cancel({})
  assert_equal(clocks.alive(nil), false, "nil is no clock")
  local handle = repeating(clocks, counts, "sleep", 10)
  clocks.stop(handle)
  clocks.stop(handle)
  clocks.cancel(handle)
  assert_equal(clock.threads[handle.id], nil, "stopped once")
  -- a clock that ends on its own: a stop after does nothing
  local once = clocks.run(function(own) own.sleep(0.5) end)
  context.clock.run_for(0.6)
  assert_equal(clock.threads[once.id], nil, "it ended at its wake")
  assert_true(not clocks.alive(once), "an ended clock is not alive")
  clocks.stop(once); clocks.cancel(once)
  assert_equal(clocks.retired[once.id], nil, "nothing kept")
  -- a body that stops its own clock: its next wait returns false at once
  local waits = {}
  local own = clocks.run(function(self_handle)
    clocks.stop(self_handle)
    table.insert(waits, self_handle.sleep(1))
    table.insert(waits, self_handle.sync(1))
  end)
  assert_equal(table.concat({tostring(waits[1]), tostring(waits[2])}, ","), "false,false", "both waits return false")
  assert_equal(clock.threads[own.id], nil, "and the clock has ended")
  context.clock.run_for(2)
  assert_no_clock_error(context, "stops on stopped, ended and running clocks")
  assert_equal(counts.runs, 0)
end)

test("cancel ends a clock at once, inside the margin too", function()
  local context, S, clocks = loaded()
  local counts = {runs = 0, ended = 0}
  local handle = repeating(clocks, counts, "sleep", 1)
  context.clock.run_for(1 - S.constants.CLOCKS.sleep_margin / 2)
  clocks.cancel(handle)
  assert_equal(clock.threads[handle.id], nil, "canceled inside the margin")
  assert_true(not clocks.alive(handle), "not alive")
  -- a retired one: cancel ends it and the helper forgets it
  local retired = repeating(clocks, counts, "sleep", 1)
  context.clock.run_for(1 - S.constants.CLOCKS.sleep_margin / 2)
  clocks.stop(retired)
  assert_equal(clocks.retired[retired.id], retired, "retired")
  clocks.cancel(retired)
  assert_equal(clock.threads[retired.id], nil, "canceled")
  assert_equal(clocks.retired[retired.id], nil, "and forgotten")
  context.clock.run_for(1)
  assert_no_clock_error(context, "cancels before the scheduler posted the wakes")
  assert_equal(counts.runs + counts.ended, 0, "neither body ran again")
end)

test("cleanup leaves no clock of the helper", function()
  local context, S, clocks = loaded()
  local counts = {runs = 0, ended = 0}
  local synced = repeating(clocks, counts, "sync", 4)
  run_to_beat(context, 4 - S.constants.CLOCKS.sync_tolerance / 2)
  clocks.stop(synced)
  local retired = repeating(clocks, counts, "sleep", S.constants.CLOCKS.sleep_margin / 2)
  clocks.stop(retired)
  assert_true(clocks.retired[retired.id] ~= nil and clocks.retired[synced.id] ~= nil, "both retired")
  local orders = {}
  for _, order in pairs(S.constants.CLEANUP_ORDER) do table.insert(orders, order) end
  table.sort(orders)
  assert_equal(orders[#orders], S.constants.CLEANUP_ORDER.clocks, "the helper's step is the last")
  cleanup()
  assert_equal(clock.threads[retired.id], nil, "the retired sleep is canceled")
  assert_equal(clock.threads[synced.id], nil, "the retired sync is canceled")
  assert_equal(next(clocks.retired), nil, "nothing is kept")
end)

test("the invariant fails for a retired handle whose coroutine is dead and still kept", function()
  local context, S, clocks = loaded()
  local invariant = clocks_invariant(S)
  assert_true(invariant ~= nil, "the clocks invariant is registered")
  local counts = {runs = 0, ended = 0}
  local handle = repeating(clocks, counts, "sleep", 1)
  assert_equal(invariant(), nil, "a running clock")
  context.clock.run_for(1 - S.constants.CLOCKS.sleep_margin / 2)
  clocks.stop(handle)
  assert_equal(invariant(), nil, "a retired clock that waits for its wake")
  clock.cancel(handle.id)  -- its coroutine gone under the helper
  local problem = invariant()
  assert_true(problem ~= nil and problem:find(tostring(handle.id), 1, true) ~= nil,
    "a retired clock gone but kept: " .. tostring(problem))
  clocks.cancel(handle)
  assert_equal(invariant(), nil, "forgotten")
end)

end

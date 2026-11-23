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

-- Run the clocks one scheduler step with the time at `beat` (later than
-- every pending wake-up): each resume is posted with that beat, as matron's
-- tick posts the beat it reads, a tick after a sync's landing on a device
-- (the stub's advance_until and run_for resume a sync with its landing)
local function deliver_at_beat(context, beat)
  context.set_time(util.time() + (beat - clock.get_beats()) * clock.get_beat_sec())
  context.clock.advance()
end

-- Review of 0b, finding 1: matron counts a sync from the landing of the
-- coroutine's last (clock_scheduler.cc's schedule_sync), not from the beat
-- its tick posted the resume with; with an offset just under a period the
-- two land a period apart
test("a repeated sync resumed a tick after its landing counts its next landing from that landing, as matron does", function()
  local context, S, clocks = loaded()
  local counts = {runs = 0, ended = 0}
  local offset = 0.9995  -- each landing just under a whole beat: 2.9995, 3.9995
  run_to_beat(context, 1.5)
  local handle = clocks.run(function(own)
    while own.sync(1, offset) do counts.runs = counts.runs + 1 end
    counts.ended = counts.ended + 1
  end)
  local tick_beats = h.stubs.MATRON_TICK_SECONDS / clock.get_beat_sec()
  deliver_at_beat(context, 2.9995 + tick_beats)  -- past 3: the next whole beat
  assert_equal(counts.runs, 1, "the first landing ran")
  context.clock.advance_until(handle.id, function()
    -- delivered at its tick: up to a tick after the landing
    assert_near(clock.get_beats(), 3.9995 + tick_beats / 2, tick_beats / 2 + 1e-6,
      "matron's next landing is a beat on, from 2.9995")
    clocks.stop(handle)
    assert_true(clock.threads[handle.id] ~= nil, "at its landing it is retired, not canceled")
  end)
  assert_no_clock_error(context, "a repeated sync stopped at a landing after a late resume")
  assert_equal(counts.runs, 1, "and its body did not run again")
  assert_equal(counts.ended, 1, "it ended")
end)

-- Review of 0b, finding 3: a body that waits on a bare clock.sleep or
-- clock.sync is not told of a stop; a stop then retires it (it cannot know
-- the wait's end) and the invariant names the mistake
test("a stop while the body waits outside its handle retires it and the invariant names it", function()
  local context, S, clocks = loaded()
  local invariant = clocks_invariant(S)
  local handle = clocks.run(function(own)
    clock.sleep(10)  -- the mistake: a wait the handle does not see
    own.sleep(1)
  end)
  clocks.stop(handle)
  assert_true(clock.threads[handle.id] ~= nil, "not canceled: its wait's end is not known")
  assert_equal(clocks.retired[handle.id], handle, "retired")
  local problem = invariant()
  assert_true(problem ~= nil and problem:find("outside its handle", 1, true) ~= nil,
    "the invariant names a wait outside the handle: " .. tostring(problem))
  clocks.cancel(handle)
  assert_equal(invariant(), nil, "canceled and forgotten")
  -- a body that stops its own clock after a wait (its id known) is not that
  -- mistake: its next wait returns false at once
  local waits = {}
  local own = clocks.run(function(self_handle)
    self_handle.sleep(0.5)
    clocks.stop(self_handle)
    table.insert(waits, self_handle.sleep(1))
  end)
  context.clock.run_for(0.6)
  assert_equal(tostring(waits[1]), "false", "its next wait returns false")
  assert_equal(clocks.retired[own.id], nil, "nothing retired")
  assert_equal(clock.threads[own.id], nil, "it ended")
  assert_equal(invariant(), nil, "the invariant holds")
  assert_no_clock_error(context, "stops outside and inside a body")
end)

-- Review of 0b, finding 6: a new clock source moves the beat on while a
-- sync waits (context.clock.set_beat, matron's reschedule: the next landing
-- after the new beat). The sync's landing is then the one it had or one
-- already passed, so a stop retires near it or past it and cancels far
-- from it, raising nothing
test("a sync whose beat jumped forward retires near or past its landing and is canceled far from it", function()
  local context, S, clocks = loaded()
  local counts = {runs = 0, ended = 0}
  run_to_beat(context, 0.5)
  local near = repeating(clocks, counts, "sync", 4)
  context.clock.set_beat(3.99)
  clocks.stop(near)
  assert_equal(clocks.retired[near.id], near, "jumped to just before its landing: retired")
  local past = repeating(clocks, counts, "sync", 4)
  context.clock.set_beat(6)
  clocks.stop(past)
  assert_equal(clocks.retired[past.id], past, "jumped past its landing (rescheduled to 8): retired")
  local far = repeating(clocks, counts, "sync", 4)
  context.clock.set_beat(6.5)
  clocks.stop(far)
  assert_equal(clock.threads[far.id], nil, "1.5 beats from its landing: canceled at once")
  run_to_beat(context, 8.1)
  assert_no_clock_error(context, "stops after forward jumps")
  assert_equal(counts.runs, 0, "no body ran again")
  assert_equal(next(clocks.retired), nil, "the retired ones ended at their landings")
end)

-- Review of 0b, finding 5: the helper's margins are the ones the zones
-- editor, the macros' learn and the quantized actions use
test("the helper's margins are the zones editor's, the macros' and the quantized actions'", function()
  local context, S, clocks = loaded()
  local CLOCKS = S.constants.CLOCKS
  assert_equal(CLOCKS.sleep_margin, S.lib.ui_zones.ZONES_EDITOR.learn_wake_margin, "a sleep's margin")
  assert_equal(CLOCKS.sleep_margin, S.lib.macros.MACROS.learn_wake_margin, "the macros' learn margin too")
  assert_equal(CLOCKS.sync_tolerance, S.lib.quantize.QUANTIZE.wake_tolerance, "a sync's tolerance")
  assert_equal(CLOCKS.sync_epsilon, S.lib.quantize.QUANTIZE.flt_epsilon, "matron's FLT_EPSILON")
end)

end

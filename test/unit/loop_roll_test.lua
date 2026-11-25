-- test/unit/loop_roll_test.lua
-- The loop (lib/loop_roll.lua, 3.9 grid sequencer package 5a, design
-- section 4, The loop, calls 10, 15 and 21): a voice plays its hits from
-- between two steps, in its own direction, while its own position runs on
-- under the loop; the loop is held by its key's own answer to "still
-- held?" or by its latch, and is never stored. The machine `loop`
-- Run alone: lua test/run.lua loop_roll

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- A fresh script after its start-up (voices 1 and 2 running), voice 1 in
-- accent with every step set at 15
local function setup()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for step = 1, S.constants.PATTERN_LENGTH do S.lib.sequencer.set_level(1, step, 15) end
  context.clear_engine_calls()
  return context, S
end

-- A key's answer to "still held?" that the test lets go of: still() and
-- release()
local function key()
  local held = true
  return function() return held end, function() held = false end
end

-- Voice 1's clock's next tick
local function tick(context, S) context.clock.advance_until(S.pattern_clocks[1]) end

-- The steps voice 1 plays at its next n ticks
local function played(context, S, n)
  local steps = {}
  for _ = 1, n do
    tick(context, S)
    steps[#steps + 1] = tostring(S.lib.sequencer.sounding_step(1))
  end
  return table.concat(steps, " ")
end

local function option_index(param_id, name)
  for index, option in ipairs(params:lookup_param(param_id).options) do
    if option == name then return index end
  end
  error("no option " .. name .. " of " .. param_id)
end

-- Voice 1's retriggers sent since the calls were cleared
local function retriggers(context)
  local count = 0
  for _, call in ipairs(context.calls_named("retrigger")) do
    if call.args[1] == 0 then count = count + 1 end
  end
  return count
end

test("set_loop orders its keys and cuts them to the voice's length; loop reads it", function()
  local _, S = setup()
  local loop_roll = S.lib.loop_roll
  local still = key()
  assert_equal(loop_roll.loop(1), nil, "no loop at first")
  loop_roll.set_loop(1, 8, 5, still)
  local lo, hi = loop_roll.loop(1)
  assert_equal(lo, 5, "ordered: lo"); assert_equal(hi, 8, "ordered: hi")
  assert_true(not loop_roll.latched(1) and not loop_roll.armed(1), "held, not latched, no latch armed")
  params:set("v2_seq_length", 6)
  loop_roll.set_loop(2, 4, 12, still)
  lo, hi = loop_roll.loop(2)
  assert_equal(lo, 4, "voice 2 from 4"); assert_equal(hi, 6, "cut to its length, 6")
  params:set("v3_seq_length", 8)
  loop_roll.set_loop(3, 9, 12, still)
  assert_equal(loop_roll.loop(3), nil, "a loop wholly past the length is none")
  for _, bad in ipairs({{0, 4}, {4, 17}, {2.5, 4}, {"3", 4}}) do
    loop_roll.set_loop(4, bad[1], bad[2], still)
    assert_equal(loop_roll.loop(4), nil, "refuses " .. tostring(bad[1]) .. ", " .. tostring(bad[2]))
  end
  loop_roll.set_loop(4, 2, 3, "held")
  assert_equal(loop_roll.loop(4), nil, "still is a function")
  loop_roll.set_loop(h.voice_count() + 1, 2, 3, still)
  assert_equal(loop_roll.loop(h.voice_count() + 1), nil, "no voice past the last")
  loop_roll.end_loop(1)
  assert_equal(loop_roll.loop(1), nil, "end_loop ends it")
end)

test("held_by is true only for the still the voice's live loop carries", function()
  local _, S = setup()
  local loop_roll = S.lib.loop_roll
  local still, release = key()
  local other = key()
  assert_true(not loop_roll.held_by(1, still), "no loop: false")
  loop_roll.set_loop(1, 3, 6, still)
  assert_true(loop_roll.held_by(1, still), "the loop's own still")
  assert_true(not loop_roll.held_by(1, other), "never another's")
  assert_true(not loop_roll.held_by(2, still), "nor another voice's loop")
  release()
  assert_true(not loop_roll.held_by(1, still), "a dead loop carries nothing")
  loop_roll.set_loop(1, 3, 6, other)
  loop_roll.press_latch(1)
  assert_true(loop_roll.held_by(1, other), "a latched loop still carries its key's still")
  assert_true(not loop_roll.held_by(0, other) and not loop_roll.held_by("1", other), "a bad voice is false")
end)

test("two keys of a line loop between them", function()
  local context, S = setup()
  S.lib.loop_roll.set_loop(1, 5, 8, (key()))
  pattern_clock_start()
  assert_equal(S.lib.sequencer.sounding_step(1), 5, "the start's step is the loop's first")
  assert_equal(played(context, S, 6), "6 7 8 5 6 7", "5 6 7 8 5 6 ...")
  pattern_clock_stop()
end)

test("the loop takes the voice's direction", function()
  for _, case in ipairs({{"reverse", "8 7 6 5 8 7"}, {"ping-pong", "5 6 7 8 7 6 5 6"}}) do
    local context, S = setup()
    params:set("v1_seq_direction", option_index("v1_seq_direction", case[1]))
    S.lib.loop_roll.set_loop(1, 5, 8, (key()))
    pattern_clock_start()
    local first = tostring(S.lib.sequencer.sounding_step(1))
    local count = select(2, case[2]:gsub(" ", ""))
    assert_equal(first .. " " .. played(context, S, count), case[2], case[1])
    pattern_clock_stop()
  end
end)

test("a random voice's loop draws inside it", function()
  local context, S = setup()
  params:set("v1_seq_direction", option_index("v1_seq_direction", "random"))
  S.lib.loop_roll.set_loop(1, 9, 11, (key()))
  pattern_clock_start()
  local seen = {}
  for _ = 1, 40 do
    local step = S.lib.sequencer.sounding_step(1)
    assert_true(step >= 9 and step <= 11, "step " .. step .. " inside 9 to 11")
    seen[step] = true
    tick(context, S)
  end
  assert_true(seen[9] and seen[10] and seen[11], "each of the three drawn")
  pattern_clock_stop()
end)

test("let go, the voice is where it would have been", function()
  local context, S = setup()
  local still, release = key()
  pattern_clock_start()
  assert_equal(played(context, S, 3), "2 3 4", "ticks 2 to 4 play the voice's own steps")
  S.lib.loop_roll.set_loop(1, 2, 3, still)
  assert_equal(played(context, S, 6), "2 3 2 3 2 3", "ticks 5 to 10 loop")
  release()
  assert_equal(played(context, S, 2), "11 12", "let go: tick 11 plays step 11")
  assert_equal(S.lib.loop_roll.loop(1), nil, "and the loop has ended")
  pattern_clock_stop()
end)

test("a skipped tick moves the loop's own step", function()
  local context, S = setup()
  local still, release = key()
  S.lib.loop_roll.set_loop(1, 5, 8, still)
  pattern_clock_start()
  local late = S.lib.sequencer.SEQ.division_beats[params:get("v1_seq_division")] * S.lib.params_setup.beat_seconds_now()
  context.clock.advance_until(S.pattern_clocks[1], function() context.set_time(util.time() + late) end)
  assert_equal(S.lib.sequencer.sounding_step(1), 7, "tick 2 skipped (the loop's 6), tick 3 plays the loop's 7")
  -- the harness wakes the clock once more at the late time, taking no tick
  -- (as without a loop): run to the next tick's time
  local function next_tick()
    local at = util.time()
    repeat tick(context, S) until util.time() > at + 1e-9
    return S.lib.sequencer.sounding_step(1)
  end
  assert_equal(next_tick(), 8, "and the loop goes on from there: 8 at tick 4")
  release()
  assert_equal(next_tick(), 5, "let go after the late wake, tick 5 plays the voice's own step 5")
  pattern_clock_stop()
end)

test("conditions count the voice's own passes under a loop", function()
  local context, S = setup()
  S.lib.sequencer.set_step_attr(1, 5, "cond", "1:2")
  S.lib.loop_roll.set_loop(1, 5, 8, (key()))
  pattern_clock_start()
  local plays_at = {}
  local function note(at)
    if S.lib.sequencer.sounding_step(1) == 5 and retriggers(context) > 0 then plays_at[#plays_at + 1] = at end
    context.clear_engine_calls()
  end
  note(1)
  for at = 2, 32 do
    tick(context, S)
    if at == 16 then assert_equal(S.lib.conditions.pass(1), 1, "16 ticks: still the voice's first pass") end
    if at == 17 then assert_equal(S.lib.conditions.pass(1), 2, "tick 17: its second") end
    note(at)
  end
  assert_equal(table.concat(plays_at, " "), "1 5 9 13", "step 5's 1:2 plays all through pass 1 and never in pass 2")
  pattern_clock_stop()
end)

test("a following lane reads the step played, a free lane its own cell", function()
  local context, S = setup()
  local lanes = S.lib.lanes
  lanes.set_length(1, "chance", 3)
  S.lib.loop_roll.set_loop(1, 5, 8, (key()))
  pattern_clock_start()
  local following, free = {}, {}
  for at = 1, 6 do
    if at > 1 then tick(context, S) end
    following[#following + 1] = tostring(lanes.sounding(1, "a"))
    free[#free + 1] = tostring(lanes.sounding(1, "chance"))
  end
  assert_equal(table.concat(following, " "), "5 6 7 8 5 6", "lane A follows the loop's steps")
  assert_equal(table.concat(free, " "), "1 2 3 1 2 3", "the 3-cell chance lane its own cells")
  pattern_clock_stop()
end)

test("an armed latch keeps the next loop; a press on a latched loop ends it", function()
  local context, S = setup()
  local loop_roll = S.lib.loop_roll
  local still, release = key()
  loop_roll.press_latch(1)
  assert_true(loop_roll.armed(1), "armed with no loop")
  loop_roll.press_latch(1)
  assert_true(not loop_roll.armed(1), "a second press disarms")
  loop_roll.press_latch(1)
  loop_roll.set_loop(1, 5, 8, still)
  assert_true(loop_roll.latched(1), "the next loop is latched at once")
  assert_true(not loop_roll.armed(1), "and the latch is no longer armed")
  release()
  pattern_clock_start()
  assert_equal(tostring(S.lib.sequencer.sounding_step(1)) .. " " .. played(context, S, 4), "5 6 7 8 5",
    "its key let go, the loop plays on")
  loop_roll.press_latch(1)
  assert_equal(loop_roll.loop(1), nil, "a press on a latched loop ends it")
  assert_true(not loop_roll.latched(1) and not loop_roll.armed(1), "and the latch with it")
  assert_equal(played(context, S, 1), "6", "the voice's own step 6 at tick 6")
  pattern_clock_stop()
end)

test("a held loop latched by a press outlasts its key", function()
  local context, S = setup()
  local loop_roll = S.lib.loop_roll
  local still, release = key()
  loop_roll.set_loop(1, 3, 4, still)
  loop_roll.press_latch(1)
  assert_true(loop_roll.latched(1), "latched")
  release()
  pattern_clock_start()
  assert_equal(tostring(S.lib.sequencer.sounding_step(1)) .. " " .. played(context, S, 3), "3 4 3 4", "it outlasts its key")
  -- a new loop over a latched one is latched too: the latch holds the voice's loop
  local still_2, release_2 = key()
  loop_roll.set_loop(1, 9, 10, still_2)
  release_2()
  assert_true(loop_roll.latched(1), "a new loop over a latched one stays latched")
  assert_equal(played(context, S, 2), "9 10", "and plays")
  pattern_clock_stop()
end)

test("a pulse voice looped over empty steps is silent", function()
  local context, S = setup()
  for step = 9, 12 do S.lib.sequencer.set_level(1, step, 0) end
  params:set("v1_seq_gate", option_index("v1_seq_gate", "pulse"))
  S.lib.loop_roll.set_loop(1, 9, 12, (key()))
  local function gates()
    local sent = {}
    for _, call in ipairs(context.engine_calls) do
      if call.name == "setGrainParam" and call.args[1] == 0 and call.args[2] == "seqGate" then sent[#sent + 1] = call.args[3] end
    end
    return sent
  end
  pattern_clock_start()
  local at_start = gates()
  assert_equal(at_start[#at_start], 1, "the start sends seqGate 1: the rule counts the steps inside the length")
  context.clear_engine_calls()
  for _ = 1, 8 do tick(context, S) end
  assert_equal(retriggers(context), 0, "no retrigger")
  for _, value in ipairs(gates()) do assert_true(value ~= 0, "no seqGate 0 after the start: the gate stays 1") end
  pattern_clock_stop()
end)

test("a length cut below the loop ends it; one inside it cuts it", function()
  local context, S = setup()
  local loop_roll = S.lib.loop_roll
  loop_roll.set_loop(1, 5, 10, (key()))
  pattern_clock_start()
  params:set("v1_seq_length", 7)
  local lo, hi = loop_roll.loop(1)
  assert_equal(lo, 5, "cut inside: lo stays"); assert_equal(hi, 7, "hi cut to 7")
  assert_equal(played(context, S, 4), "6 7 5 6", "the cut loop plays")
  params:set("v1_seq_length", 16)
  assert_equal(select(2, loop_roll.loop(1)), 7, "a longer length gives nothing back")
  params:set("v1_seq_length", 4)
  assert_equal(loop_roll.loop(1), nil, "below lo it ends")
  pattern_clock_stop()
  -- a latched loop alike
  loop_roll.set_loop(2, 3, 6, (key())); loop_roll.press_latch(2)
  params:set("v2_seq_length", 2)
  assert_equal(loop_roll.loop(2), nil, "a latched loop ends too")
  assert_true(not loop_roll.latched(2), "and its latch")
end)

test("a chain link leaves a loop, cut to the length the link brings", function()
  local _, S = setup()
  params:set("v1_seq_length", 6)
  capture_scene(1)
  params:set("v1_seq_length", 16)
  S.lib.loop_roll.set_loop(1, 5, 10, (key()))
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 1)
  pattern_clock_start()
  assert_equal(params:get("v1_seq_length"), 6, "the start's link brought length 6")
  local lo, hi = S.lib.loop_roll.loop(1)
  assert_equal(lo, 5, "the loop stays"); assert_equal(hi, 6, "cut to 6")
  pattern_clock_stop()
end)

test("replace_pattern and replace_whole leave a loop; a stop of the patterns keeps it", function()
  local context, S = setup()
  local loop_roll = S.lib.loop_roll
  loop_roll.set_loop(1, 5, 8, (key()))
  pattern_clock_start()
  S.lib.sequencer.replace_pattern(1, {15, 15, 15, 15, 15, 15, 15, 15})
  S.lib.sequencer.replace_whole(1, S.lib.sequencer.whole(1))
  assert_equal(select(2, loop_roll.loop(1)), 8, "the loop stays")
  pattern_clock_stop()
  assert_equal(select(2, loop_roll.loop(1)), 8, "a stop keeps it")
  pattern_clock_start()
  assert_equal(S.lib.sequencer.sounding_step(1), 5, "a start plays it from its first step")
  assert_equal(played(context, S, 1), "6", "and on")
  pattern_clock_stop()
end)

test("a loop is never a param, a scene field or a PSET field", function()
  local _, S = setup()
  local params_before = #params.params
  capture_scene(1)
  S.lib.loop_roll.set_loop(1, 5, 8, (key()))
  S.lib.loop_roll.press_latch(1)
  capture_scene(2)
  local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  assert_true(same(S.scenes[1].data, S.scenes[2].data), "a scene captured with a latched loop holds what one without it holds")
  assert_equal(#params.params, params_before, "a loop adds no param")
  recall_scene(1)
  assert_true(S.lib.loop_roll.latched(1), "and a recall leaves the loop")
end)

test("the loop invariant fails on a loop past the voice's length", function()
  local _, S = setup()
  local invariant = h.registered_invariant("loop")
  S.lib.loop_roll.set_loop(1, 5, 8, (key()))
  assert_equal(invariant.check(), nil, "it holds")
  S.voices[1].values.seq_length = 6  -- as though a length were set without its action
  h.allow_broken_invariants("the test breaks the loop invariant on purpose")
  assert_true((invariant.check() or ""):find("voice 1", 1, true) ~= nil, "a loop past the length")
  S.voices[1].values.seq_length = 16
  S.lib.loop_roll.end_loop(1)
  S.lib.loop_roll.press_latch(1)
  assert_equal(invariant.check(), nil, "an armed latch with no loop holds")
end)

-- The machine `loop` (docs/notes/lua/loop-roll.md): voice 1, every step
-- set, the patterns playing (one tick: step 1 played), its line on a 128's
-- patterns page, side 1. held: key 5 held and key 8 pressed (and let go),
-- the loop 5 to 8 by key 5's press; armed: press_latch with no loop;
-- latched: held, then press_latch, key 5 still down
local machine = {pane = nil}

local function loop_state(kind)
  return function(context)
    local S = local_value("S")
    for step = 1, S.constants.PATTERN_LENGTH do S.lib.sequencer.set_level(1, step, 15) end
    machine.pane = h.grid_pane(context, "128h")
    machine.pane.show(S.constants.GRID_PAGES.patterns)
    pattern_clock_start()
    if kind == "held" or kind == "latched" then
      machine.pane.press(5, 1, 1); machine.pane.press(8, 1, 1); machine.pane.press(8, 1, 0)
    end
    if kind == "armed" or kind == "latched" then S.lib.loop_roll.press_latch(1) end
  end
end

-- The row's check: the loop's ends (nil for none)
local function loop_is(lo, hi)
  return function()
    local got_lo, got_hi = local_value("S").lib.loop_roll.loop(1)
    assert_equal(got_lo, lo, "the loop from " .. tostring(lo)); assert_equal(got_hi, hi, "to " .. tostring(hi))
  end
end

-- The row's check: voice 1's next tick plays step
local function next_plays(step)
  return function(context)
    local S = local_value("S")
    tick(context, S)
    assert_equal(S.lib.sequencer.sounding_step(1), step, "the next tick plays step " .. step)
  end
end

local function both(a, b) return function(context) a(context); b(context) end end

h.transition_table({
  name = "loop",
  notes = {"docs/notes/lua/loop-roll.md", "loop"},
  states = {
    none = loop_state("none"),
    held = loop_state("held"),
    armed = loop_state("armed"),
    latched = loop_state("latched"),
  },
  events = {
    ["second key"] = function()
      local pane = machine.pane
      if not local_value("S").lib.grid_core.held(1, 5, 1) then pane.press(5, 1, 1) end
      pane.press(12, 1, 1); pane.press(12, 1, 0)
    end,
    ["first key's release"] = function() machine.pane.press(5, 1, 0) end,
    ["page change"] = function() machine.pane.show(local_value("S").constants.GRID_PAGES.voices) end,
    ["unplug"] = function(context) context.grid.unplug(1) end,
    ["press_latch"] = function() local_value("S").lib.loop_roll.press_latch(1) end,
    ["length cut inside"] = function() params:set("v1_seq_length", 6) end,
    ["length cut below"] = function() params:set("v1_seq_length", 4) end,
    ["replacement"] = function()
      local levels = {}
      for step = 1, 16 do levels[step] = 15 end
      local_value("S").lib.sequencer.replace_pattern(1, levels)
    end,
    ["stop"] = function() pattern_clock_stop() end,
  },
  state_of = function()
    local loop_roll = local_value("S").lib.loop_roll
    if loop_roll.latched(1) then return "latched" end
    if loop_roll.loop(1) then return "held" end
    if loop_roll.armed(1) then return "armed" end
    return "none"
  end,
  rows = {
    {"none", "second key", "held", check = loop_is(5, 12)},
    {"none", "first key's release", "none", check = next_plays(2)},
    {"none", "page change", "none"},
    {"none", "unplug", "none"},
    {"none", "press_latch", "armed"},
    {"none", "length cut inside", "none"},
    {"none", "length cut below", "none"},
    {"none", "replacement", "none"},
    {"none", "stop", "none"},
    {"held", "second key", "held", check = loop_is(5, 12)},
    {"held", "first key's release", "none", check = next_plays(2)},
    {"held", "page change", "none", check = next_plays(2)},
    {"held", "unplug", "none", check = next_plays(2)},
    {"held", "press_latch", "latched", check = loop_is(5, 8)},
    {"held", "length cut inside", "held", check = both(loop_is(5, 6), next_plays(5))},
    {"held", "length cut below", "none", check = next_plays(2)},
    {"held", "replacement", "held", check = both(loop_is(5, 8), next_plays(5))},
    {"held", "stop", "held", check = loop_is(5, 8)},
    {"armed", "second key", "latched", check = loop_is(5, 12)},
    {"armed", "first key's release", "armed"},
    {"armed", "page change", "armed"},
    {"armed", "unplug", "armed"},
    {"armed", "press_latch", "none"},
    {"armed", "length cut inside", "armed"},
    {"armed", "length cut below", "armed"},
    {"armed", "replacement", "armed"},
    {"armed", "stop", "armed"},
    {"latched", "second key", "latched", check = loop_is(5, 12)},
    {"latched", "first key's release", "latched", check = next_plays(5)},
    {"latched", "page change", "latched", check = next_plays(5)},
    {"latched", "unplug", "latched", check = next_plays(5)},
    {"latched", "press_latch", "none", check = next_plays(2)},
    {"latched", "length cut inside", "latched", check = loop_is(5, 6)},
    {"latched", "length cut below", "none", check = next_plays(2)},
    {"latched", "replacement", "latched", check = loop_is(5, 8)},
    {"latched", "stop", "latched", check = loop_is(5, 8)},
  },
})

-- 5b: the roll ------------------------------------------------------------

-- A 1/16 step at the stub clock's 120 BPM, in seconds
local STEP_SECONDS = 0.125
-- matron's tick, which a wake may land up to one of late (the stub's)
local TICK_SECONDS = 0.0015

-- The times (from now) of voice 1's retriggers over the next `seconds`,
-- the clocks run a scheduler step at a time; those already sent since the
-- calls were cleared count at 0
local function retrigger_times(context, seconds)
  local start, times, seen = util.time(), {}, 0
  local function catch()
    local count = retriggers(context)
    while seen < count do
      seen = seen + 1
      times[#times + 1] = util.time() - start
    end
  end
  catch()
  for _ = 1, 100000 do
    if util.time() - start >= seconds - 1e-9 then break end
    context.clock.advance()
    if util.time() - start >= seconds - 1e-9 then break end
    catch()
  end
  return times
end

-- The gaps between successive times
local function gaps(times)
  local list = {}
  for index = 2, #times do list[#list + 1] = times[index] - times[index - 1] end
  return list
end

local function assert_gaps(times, seconds, what)
  assert_true(#times >= 3, what .. ": at least three hits, saw " .. #times)
  for index, gap in ipairs(gaps(times)) do
    assert_true(math.abs(gap - seconds) <= TICK_SECONDS,
      what .. ": gap " .. index .. " is " .. gap .. " s, not " .. seconds)
  end
end

-- A step output that logs every hit's event of voice 1 (the registry stays open)
local function hit_log(S)
  local log = {}
  S.register_step_output({name = "roll probe", play = function(event)
    if event.voice == 1 then log[#log + 1] = event end
  end})
  return log
end

-- The events in log the voice's own steps played (not a roll's)
local function own_hits(log)
  local list = {}
  for _, event in ipairs(log) do
    if not event.rolled then list[#list + 1] = event end
  end
  return list
end

-- A test page in the fx page's place whose keys 1 to 4 of lines 1 and 2
-- roll voice 1 at their rate, held by the key's own still (as 5c's perform
-- side will), on a 128 showing it
local function roll_keys(context, S)
  local index = S.constants.GRID_PAGES.fx
  local probe = h.probe_grid_page(index)
  probe.press = function(pane, x, y, z)
    if z == 1 and y <= 2 and x <= 4 then S.lib.loop_roll.roll(1, x, pane.still(x, y)) end
  end
  local pane = h.grid_pane(context, "128h")
  pane.show(index)
  return pane
end

test("a roll replays the last hit at its rate", function()
  local context, S = setup()
  pattern_clock_start()
  context.clear_engine_calls()
  assert_equal(S.lib.sequencer.step_seconds(1), STEP_SECONDS, "a 1/16 step at 120 BPM")
  S.lib.loop_roll.roll(1, 4, (key()))
  assert_equal(S.lib.loop_roll.rolling(1), 4, "rolling at 4")
  assert_equal(retriggers(context), 1, "its first hit at once")
  assert_gaps(retrigger_times(context, 0.2), STEP_SECONDS / 4, "rate 4: a retrigger every 31.25 ms")
  for rate = 1, 3 do
    context.clear_engine_calls()
    S.lib.loop_roll.roll(1, rate, (key()))
    assert_gaps(retrigger_times(context, 3 * STEP_SECONDS / rate + 0.001), STEP_SECONDS / rate, "rate " .. rate)
  end
  pattern_clock_stop()
end)

test("a roll is never faster than 20 ms", function()
  local context, S = setup()
  params:set("v1_seq_division", 1)  -- 1/32: 62.5 ms, a quarter of it 15.6 ms
  pattern_clock_start()
  context.clear_engine_calls()
  S.lib.loop_roll.roll(1, 4, (key()))
  assert_gaps(retrigger_times(context, 0.1), S.lib.sequencer.SEQ.min_ratchet_seconds, "20 ms apart")
  pattern_clock_stop()
end)

test("a roll's refusals: a bad voice, rate or still, and the patterns stopped", function()
  local _, S = setup()
  local loop_roll = S.lib.loop_roll
  loop_roll.roll(1, 2, (key()))
  assert_equal(loop_roll.rolling(1), nil, "the patterns stopped: nothing")
  pattern_clock_start()
  for _, bad in ipairs({{0, 2}, {h.voice_count() + 1, 2}, {1, 0}, {1, 5}, {1, 1.5}, {1, "2"}}) do
    loop_roll.roll(bad[1], bad[2], (key()))
    assert_equal(loop_roll.rolling(1), nil, "refuses voice " .. tostring(bad[1]) .. ", rate " .. tostring(bad[2]))
  end
  loop_roll.roll(1, 2, "held")
  assert_equal(loop_roll.rolling(1), nil, "still is a function")
  loop_roll.roll(1, 2, (key()))
  assert_equal(loop_roll.rolling(1), 2, "a good one rolls")
  loop_roll.end_roll(1)
  assert_equal(loop_roll.rolling(1), nil, "end_roll ends it")
  assert_equal(loop_roll.rolling(0), nil, "no voice 0")
  pattern_clock_stop()
end)

test("the voice's own steps are silent under a roll and its position moves on", function()
  local context, S = setup()
  local log = hit_log(S)
  local still, release = key()
  pattern_clock_start()
  S.lib.loop_roll.roll(1, 2, still)
  assert_equal(played(context, S, 3), "2 3 4", "the voice's position takes steps 2 to 4")
  assert_equal(#own_hits(log), 1, "and plays none of them: only step 1's own hit")
  release()
  assert_equal(played(context, S, 1), "5", "let go, the next step is the one the pattern reached")
  local own = own_hits(log)
  assert_equal(#own, 2, "and it plays")
  assert_equal(own[2].step, 5, "step 5")
  pattern_clock_stop()
end)

test("a roll stops a ratcheted step's later hits", function()
  local context, S = setup()
  S.lib.sequencer.set_step_attr(1, 1, "ratchet", 4)
  local log = hit_log(S)
  pattern_clock_start()
  assert_equal(#own_hits(log), 1, "step 1's first hit")
  S.lib.loop_roll.roll(1, 1, (key()))
  context.clock.run_for(STEP_SECONDS - 0.01)
  assert_equal(#own_hits(log), 1, "its three later hits are not played under the roll")
  pattern_clock_stop()
end)

test("a rolled hit in move swells at the hit's level and sets the held values again", function()
  local context, S = setup()
  S.buffers[1].seconds = 8
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v1_buf_pos", 0.2)
  for step = 2, S.constants.PATTERN_LENGTH do S.lib.sequencer.set_level(1, step, 0) end
  S.lib.sequencer.set_level(1, 1, 9)
  S.lib.sequencer.set_step_attr(1, 1, "va", 12)
  params:set("v1_seq_gate", option_index("v1_seq_gate", "move"))
  local log = hit_log(S)
  local function positions()
    local sent = {}
    for _, call in ipairs(context.calls_named("setGrainParam")) do
      if call.args[1] == 0 and call.args[2] == "bufPos" then sent[#sent + 1] = call.args[3] end
    end
    return sent
  end
  context.clear_engine_calls()
  pattern_clock_start()
  local own_retrigger = context.calls_named("retrigger")[1]
  assert_equal(own_retrigger.args[2], 0, "the move hit itself: no swell")
  local moved = positions()
  assert_true(#moved >= 1, "the move hit set its position")
  local value = moved[#moved]
  assert_true(math.abs(value - 0.2) > 0.01, "a position of its own: " .. value)
  assert_equal(S.lib.sequencer.held_value(1, "position"), 12, "held")
  context.clear_engine_calls()
  S.lib.loop_roll.roll(1, 2, (key()))
  local rolled = context.calls_named("retrigger")
  assert_equal(#rolled, 1, "one rolled hit at once")
  h.assert_near(rolled[1].args[2], 9 / 15, 1e-9, "at the hit's level, 9: a swell")
  local again = positions()
  assert_equal(#again, 1, "the held value set again")
  h.assert_near(again[1], value, 1e-9, "to the value it holds")
  h.assert_near(log[#log].velocity, 9 / 15, 1e-9, "the outputs hear the level too")
  assert_true(log[#log].rolled == true and log[#log].first == false, "a rolled hit, not a step's first")
  assert_equal(S.lib.sequencer.held_value(1, "position"), 12, "still held")
  pattern_clock_stop()
end)

test("a roll tells the targets each hit", function()
  local context, S = setup()
  local calls = {}
  S.register_note_target({name = "roll target", routed = function(voice) return voice == 1 end,
    note_on = function(voice, id, pitch, velocity) calls[#calls + 1] = {"on", voice, id, velocity} end,
    note_off = function(voice, id) calls[#calls + 1] = {"off", voice, id} end,
    stop_all = function() end})
  S.lib.sequencer.set_level(1, 1, 6)
  pattern_clock_start()
  local function ons()
    local n = 0
    for _, call in ipairs(calls) do if call[1] == "on" then n = n + 1 end end
    return n
  end
  assert_equal(ons(), 1, "step 1's own note")
  calls = {}
  S.lib.loop_roll.roll(1, 4, (key()))
  context.clock.run_for(STEP_SECONDS - 0.005)
  assert_equal(ons(), 4, "a note on at each of four rolled hits")
  for _, call in ipairs(calls) do
    if call[1] == "on" then h.assert_near(call[4], 6 / 15, 1e-9, "at the hit's level") end
  end
  pattern_clock_stop()
end)

test("a rolled hit's gate is its interval times the voice's gate length in steps", function()
  local context, S = setup()
  params:set("v1_seq_gate_length", 2)
  S.lib.sequencer.set_step_attr(1, 1, "gate", 8)  -- the step's own gate is not the roll's
  local log = hit_log(S)
  pattern_clock_start()  -- a pulse voice with steps: gated
  context.clear_engine_calls()
  S.lib.loop_roll.roll(1, 4, (key()))
  local gates = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == "setGrainParam" and call.args[1] == 0 and call.args[2] == "gateSeconds" then gates[#gates + 1] = call.args[3] end
    if call.name == "retrigger" then break end
  end
  assert_equal(#gates, 1, "a gate length before the rolled hit")
  h.assert_near(gates[1], 2 * STEP_SECONDS / 4, 1e-9, "2 steps of 31.25 ms")
  h.assert_near(log[#log].gate_beats, 2 / 4 / 4, 1e-9, "the outputs' gate in beats")
  pattern_clock_stop()
end)

test("a roll before any hit plays nothing", function()
  local context, S = setup()
  for step = 1, S.constants.PATTERN_LENGTH do S.lib.sequencer.set_level(1, step, 0) end
  pattern_clock_start()
  assert_equal(S.lib.sequencer.replay_hit(1), false, "no hit since the patterns started")
  context.clear_engine_calls()
  S.lib.loop_roll.roll(1, 4, (key()))
  assert_equal(S.lib.loop_roll.rolling(1), 4, "it rolls")
  S.lib.sequencer.set_level(1, 3, 15)
  context.clock.run_for(4 * STEP_SECONDS)
  assert_equal(retriggers(context), 0, "and plays nothing: no hit to replay, and the voice's own steps are silent")
  pattern_clock_stop()
end)

test("of two roll keys the last pressed rolls, and the first's release changes nothing", function()
  local context, S = setup()
  local first, release_first = key()
  pattern_clock_start()
  S.lib.loop_roll.roll(1, 1, first)
  S.lib.loop_roll.roll(1, 3, (key()))
  assert_equal(S.lib.loop_roll.rolling(1), 3, "the last pressed rolls")
  release_first()
  context.clear_engine_calls()
  assert_equal(S.lib.loop_roll.rolling(1), 3, "the first's release changes nothing")
  assert_gaps(retrigger_times(context, 4 * STEP_SECONDS / 3 + 0.001), STEP_SECONDS / 3, "rate 3 goes on")
  pattern_clock_stop()
end)

test("a page change and an unplug end a roll at its next hit", function()
  for _, case in ipairs({"page change", "unplug"}) do
    local context, S = setup()
    local pane = roll_keys(context, S)
    pattern_clock_start()
    pane.press(2, 1, 1)
    assert_equal(S.lib.loop_roll.rolling(1), 2, case .. ": key 2 rolls at 2")
    if case == "page change" then pane.show(S.constants.GRID_PAGES.patterns) else context.grid.unplug(1) end
    assert_equal(S.lib.loop_roll.rolling(1), nil, case .. ": no longer rolling")
    context.clear_engine_calls()
    context.clock.run_for(STEP_SECONDS / 2 - 0.005)
    assert_equal(retriggers(context), 0, case .. ": its next hit plays nothing")
    assert_equal(played(context, S, 1), "2", case .. ": the voice plays its own step 2")
    assert_equal(retriggers(context), 1, case .. ": and only that")
    pattern_clock_stop()
  end
end)

test("a letter's switch under an order leaves a held roll", function()
  local context, S = setup()
  local letters = S.lib.pattern_letters
  letters.switch_now(1, "B")
  S.lib.sequencer.set_level(1, 1, 7)
  letters.switch_now(1, "A")
  letters.set_order(1, {"A", "B"})
  pattern_clock_start()
  S.lib.loop_roll.roll(1, 2, (key()))
  context.clock.run_for(4 * 4 * STEP_SECONDS + 0.01)  -- past the second bar's start
  assert_equal(letters.current(1), "B", "the order switched to B at the bar")
  assert_equal(S.lib.loop_roll.rolling(1), 2, "the roll is held")
  context.clear_engine_calls()
  assert_gaps(retrigger_times(context, 4 * STEP_SECONDS / 2 + 0.001), STEP_SECONDS / 2, "and rolls on")
  pattern_clock_stop()
end)

test("a start ends a roll, by hand and a followed transport start alike, and the voice plays its own steps", function()
  for _, case in ipairs({"by hand", "transport"}) do
    local context, S = setup()
    if case == "transport" then params:set("clock_source", 2) end  -- midi: the patterns follow its transport
    local log = hit_log(S)
    pattern_clock_start()
    S.lib.loop_roll.roll(1, 4, (key()))
    if case == "transport" then clock.transport.start() else pattern_clock_start() end
    assert_equal(S.lib.loop_roll.rolling(1), nil, case .. ": the start ended the roll")
    local before = #log
    context.clock.run_for(2 * STEP_SECONDS + 0.005)
    local own, rolled = 0, 0
    for index = before + 1, #log do
      if log[index].rolled then rolled = rolled + 1 else own = own + 1 end
    end
    assert_equal(rolled, 0, case .. ": no rolled hit after the start")
    assert_equal(own, 2, case .. ": the voice's own steps 2 and 3 play")
    pattern_clock_stop()
  end
end)

test("a late wake plays one rolled hit and keeps the roll's grid", function()
  local context, S = setup()
  pattern_clock_start()
  context.clear_engine_calls()
  local start = util.time()
  S.lib.loop_roll.roll(1, 4, (key()))
  assert_equal(retriggers(context), 1, "the first hit at once")
  -- the roll's wake (31.25 ms on) comes 100 ms on, past two more of its
  -- hits: the norns busy until then, one scheduler step delivers every
  -- clock overdue (the LFO clock's too)
  context.set_time(start + 0.1)
  context.clock.advance()
  assert_equal(retriggers(context), 2, "one hit at the late wake, never a burst")
  context.clear_engine_calls()
  local late = util.time() - start
  local times = retrigger_times(context, 0.05)
  assert_true(times[1] ~= nil and math.abs(late + times[1] - 0.125) <= TICK_SECONDS,
    "the next hit at 125 ms, on the roll's grid, not 31.25 ms after the late one: " .. tostring(times[1]))
  pattern_clock_stop()
end)

test("an error in a rolled hit stops the patterns and is raised again", function()
  local context, S = setup()
  pattern_clock_start()
  S.lib.loop_roll.roll(1, 4, (key()))
  local real_retrigger = S.lib.engine_sync.retrigger
  S.lib.engine_sync.retrigger = function() error("rolled hit failed") end
  context.clock.run_for(0.04)
  S.lib.engine_sync.retrigger = real_retrigger
  local errors = context.clock.take_errors()
  assert_equal(#errors, 1, "one clock error")
  assert_true(errors[1]:find("rolled hit failed", 1, true) ~= nil, "the hit's error, raised again: " .. tostring(errors[1]))
  assert_equal(S.pattern_playing, false, "the patterns stopped")
  assert_equal(S.lib.loop_roll.rolling(1), nil, "and the roll ended")
end)

test("the roll invariant fails on a roll clock no rolling voice owns", function()
  local _, S = setup()
  local invariant = h.registered_invariant("roll")
  pattern_clock_start()
  local real_stop = S.lib.clocks.stop
  S.lib.clocks.stop = function() end  -- end_roll's stop of the clock dropped
  S.lib.loop_roll.roll(1, 2, (key()))
  S.lib.loop_roll.end_roll(1)
  S.lib.clocks.stop = real_stop
  h.allow_broken_invariants("the test leaves a roll clock running on purpose")
  assert_true((invariant.check() or ""):find("voice 1", 1, true) ~= nil, "a roll clock runs with no roll")
  pattern_clock_stop()
end)

test("a stop and cleanup end a roll", function()
  local context, S = setup()
  pattern_clock_start()
  S.lib.loop_roll.roll(1, 4, (key()))
  pattern_clock_stop()
  assert_equal(S.lib.loop_roll.rolling(1), nil, "a stop ends it")
  context.clear_engine_calls()
  context.clock.run_for(STEP_SECONDS)
  assert_equal(retriggers(context), 0, "no hit after the stop, and no clock error at its wake")
  pattern_clock_start()
  S.lib.loop_roll.roll(1, 4, (key()))
  context.clock.run_for(0.01)
  cleanup()
  assert_equal(S.lib.loop_roll.rolling(1), nil, "cleanup ends it")
  context.clear_engine_calls()
  context.clock.run_for(STEP_SECONDS)
  assert_equal(retriggers(context), 0, "no hit after cleanup")
end)

test("a roll repaints the grid no more than once a beat", function()
  local counts = {}
  for _, rolls in ipairs({false, true}) do
    local context, S = setup()
    pattern_clock_start()
    if rolls then S.lib.loop_roll.roll(1, 4, (key())) end
    local count, real_grid_redraw = 0, grid_redraw
    grid_redraw = function(...) count = count + 1; return real_grid_redraw(...) end
    context.clock.run_for(8 * STEP_SECONDS - 0.005)
    grid_redraw = real_grid_redraw
    counts[#counts + 1] = count
    pattern_clock_stop()
  end
  assert_equal(counts[2], counts[1], "a roll adds no repaint to the steps' own")
  assert_true(counts[2] <= 8, "one a 16th at most: " .. counts[2])
end)

test("the roll invariant fails on a roll with the patterns stopped", function()
  local _, S = setup()
  local invariant = h.registered_invariant("roll")
  pattern_clock_start()
  S.lib.loop_roll.roll(1, 2, (key()))
  assert_equal(invariant.check(), nil, "it holds")
  h.allow_broken_invariants("the test breaks the roll invariant on purpose")
  S.pattern_playing = false  -- as though the patterns stopped without their stop
  assert_true((invariant.check() or ""):find("voice 1", 1, true) ~= nil, "a roll with the patterns stopped")
  S.pattern_playing = true
  pattern_clock_stop()
  assert_equal(invariant.check(), nil, "the stop ended it")
end)

-- The machine `roll` (docs/notes/lua/loop-roll.md): voice 1, every step
-- set, the patterns playing (step 1 played), a 128 showing roll_keys'
-- test page (keys 1 to 4 of lines 1 and 2 roll voice 1 at their rate, held
-- by the key's still). rolling: key 1 then key 3 of line 1 pressed, so the
-- roll is key 3's at rate 3, key 1 still down; roll_machine.before: the
-- hits logged when the state was entered
local roll_machine = {pane = nil, log = nil, before = 0}

local function roll_state(kind)
  return function(context)
    local S = local_value("S")
    for step = 1, S.constants.PATTERN_LENGTH do S.lib.sequencer.set_level(1, step, 15) end
    roll_machine.log = hit_log(S)
    roll_machine.pane = roll_keys(context, S)
    pattern_clock_start()
    if kind == "rolling" then roll_machine.pane.press(1, 1, 1); roll_machine.pane.press(3, 1, 1) end
    roll_machine.before = #roll_machine.log
  end
end

-- The row's check: rolling at rate, its first hit at once (one rolled
-- hit since the state was entered)
local function rolls_at(rate)
  return function()
    local S = local_value("S")
    assert_equal(S.lib.loop_roll.rolling(1), rate, "rolling at " .. rate)
    local log = roll_machine.log
    assert_equal(#log, roll_machine.before + 1, "one hit since the state")
    assert_true(log[#log].rolled == true and math.abs(log[#log].beat - clock.get_beats()) < 1e-9, "its first hit at once")
  end
end

-- The row's check: still rolling at rate
local function still_rolls(rate)
  return function() assert_equal(local_value("S").lib.loop_roll.rolling(1), rate, "rolling at " .. rate) end
end

-- The row's check: the roll's next hit (within its interval) plays nothing
local function next_hit_silent(context)
  local log = roll_machine.log
  local before = #log
  context.clock.run_for(0.06)
  for index = before + 1, #log do assert_true(not log[index].rolled, "no rolled hit after the end") end
end

-- The row's check: the voice's next tick plays its own step 2
local function own_step_plays(context)
  local S = local_value("S")
  if S.lib.sequencer.sounding_step(1) ~= 2 then tick(context, S) end
  local own = own_hits(roll_machine.log)
  assert_equal(own[#own].step, 2, "the voice's own step 2 plays")
end

local function silent_then_own(context)
  next_hit_silent(context)
  own_step_plays(context)
end

-- The row's check: the voice's tick took step 2 and played nothing of its own
local function own_step_silent()
  local S = local_value("S")
  assert_equal(S.lib.sequencer.sounding_step(1), 2, "the position took step 2")
  assert_equal(#own_hits(roll_machine.log), 1, "only step 1's own hit")
end

h.transition_table({
  name = "roll",
  notes = {"docs/notes/lua/loop-roll.md", "roll"},
  states = {
    off = roll_state("off"),
    rolling = roll_state("rolling"),
  },
  events = {
    ["a rate set"] = function() roll_machine.pane.press(2, 2, 1) end,
    ["another rate"] = function() roll_machine.pane.press(4, 1, 1) end,
    ["the key's release"] = function() roll_machine.pane.press(3, 1, 0) end,
    ["an earlier key's release"] = function() roll_machine.pane.press(1, 1, 0) end,
    ["a page change"] = function() roll_machine.pane.show(local_value("S").constants.GRID_PAGES.patterns) end,
    ["an unplug"] = function(context) context.grid.unplug(1) end,
    ["a stop"] = function() pattern_clock_stop() end,
    ["a replacement"] = function()
      local levels = {}
      for step = 1, local_value("S").constants.PATTERN_LENGTH do levels[step] = 15 end
      local_value("S").lib.sequencer.replace_pattern(1, levels)
    end,
    ["a hit that would have played"] = function(context) tick(context, local_value("S")) end,
  },
  state_of = function() return local_value("S").lib.loop_roll.rolling(1) and "rolling" or "off" end,
  rows = {
    {"off", "a rate set", "rolling", check = rolls_at(2)},
    {"off", "another rate", "rolling", check = rolls_at(4)},
    {"off", "the key's release", "off"},
    {"off", "an earlier key's release", "off"},
    {"off", "a page change", "off"},
    {"off", "an unplug", "off"},
    {"off", "a stop", "off"},
    {"off", "a replacement", "off"},
    {"off", "a hit that would have played", "off", check = own_step_plays},
    {"rolling", "a rate set", "rolling", check = rolls_at(2)},
    {"rolling", "another rate", "rolling", check = rolls_at(4)},
    {"rolling", "the key's release", "off", check = silent_then_own},
    {"rolling", "an earlier key's release", "rolling", check = still_rolls(3)},
    {"rolling", "a page change", "off", check = silent_then_own},
    {"rolling", "an unplug", "off", check = silent_then_own},
    {"rolling", "a stop", "off", check = next_hit_silent},
    {"rolling", "a replacement", "rolling", check = still_rolls(3)},
    {"rolling", "a hit that would have played", "rolling", check = own_step_silent},
  },
})

end

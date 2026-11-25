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

end

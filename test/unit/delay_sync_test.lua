-- test/unit/delay_sync_test.lua
-- The delay on the beat (lib/delay_sync.lua, S.lib.delay_sync, 3.7 design
-- §6): the three params in strata_fx (delay_sync, delay_division,
-- delay_pingpong), the time the delay's one sender takes from M.time(),
-- the halving of a division longer than DELAY.max_seconds, the step hook's
-- resend on a tempo move, the scene fields and a recall's one setDelay
-- Run alone: lua test/run.lua delay_sync

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- DIVISIONS.names' indices the tests use
local DIVISION = {eighth_dotted = 7, quarter = 9, half = 11, bar = 12}

local function loaded()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.delay_sync
end

-- Run the clocks until the LFO clock (the delay's step hook runs in it) has
-- stepped count times (default 1)
local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

local function delay_calls(context) return context.calls_named("setDelay") end

-- Run body, then put the clock's tempo back at the stubs' 120 BPM whether
-- body passed or a failed assertion raised (the error is raised again), so
-- a test that sets an external clock's tempo never leaves it behind
local function restoring_tempo(body)
  local ran, problem = pcall(body)
  clock.tempo = 120
  if not ran then error(problem, 0) end
end

local function last_delay(context)
  local calls = delay_calls(context)
  return calls[#calls] and calls[#calls].args
end

local function assert_delay(args, time, feedback, mix, pingpong, where)
  assert_true(args ~= nil, where .. ": a setDelay")
  assert_equal(#args, 4, where .. ": four values")
  assert_near(args[1], time, 1e-4, where .. ": time")
  assert_near(args[2], feedback, 1e-6, where .. ": feedback")
  assert_near(args[3], mix, 1e-6, where .. ": mix")
  assert_near(args[4], pingpong, 1e-6, where .. ": ping-pong")
end

test("with sync off the delay plays delay_time, and setDelay's fourth value is the ping-pong amount", function()
  local context = loaded()
  assert_equal(params:get("delay_sync"), 0, "sync is off at its default")
  assert_equal(params:get("delay_division"), DIVISION.eighth_dotted, "the division defaults to 1/8D")
  assert_equal(params:string("delay_division"), "1/8D")
  assert_near(params:get("delay_pingpong"), 0, 1e-9, "ping-pong is off at its default")
  context.clear_engine_calls()
  params:set("delay_feedback", 0.5); params:set("delay_feedback", 0.4)
  assert_delay(last_delay(context), 0.375, 0.4, 0, 0, "the defaults")
  params:set("delay_pingpong", 0.5)
  assert_delay(last_delay(context), 0.375, 0.4, 0, 0.5, "ping-pong at 0.5")
end)

test("sync plays the division at the tempo", function()
  local context, _, delay_sync = loaded()
  params:set("clock_tempo", 120)
  context.clear_engine_calls()
  params:set("delay_sync", 1)
  assert_delay(last_delay(context), 0.375, 0.4, 0, 0, "120 BPM, 1/8D")
  assert_equal(delay_sync.label(), "1/8D")
  params:set("delay_division", DIVISION.quarter)
  assert_near(last_delay(context)[1], 0.5, 1e-9, "120 BPM, 1/4")
  params:set("delay_division", DIVISION.bar)
  assert_near(last_delay(context)[1], 2.0, 1e-9, "120 BPM, 1 bar")
  assert_equal(delay_sync.label(), "1 bar")
  params:set("delay_division", DIVISION.quarter)
  params:set("clock_tempo", 90)
  assert_near(delay_sync.time(), 0.6667, 1e-4, "90 BPM, 1/4")
  lfo_step(context)
  assert_near(last_delay(context)[1], 0.6667, 1e-4, "and the engine gets it")
  local playing = delay_sync.playing()
  assert_equal(playing.division, DIVISION.quarter, "playing: the division")
  assert_equal(playing.halvings, 0, "playing: not halved")
  params:set("delay_sync", 0)
  assert_equal(delay_sync.playing(), nil, "playing is nil with sync off")
  assert_near(last_delay(context)[1], 0.375, 1e-9, "sync off plays delay_time again")
end)

test("a division that does not fit is halved until it does", function()
  local _, _, delay_sync = loaded()
  params:set("delay_sync", 1); params:set("delay_division", DIVISION.bar)
  -- 3.8: the line holds 5.4 s (design §0.2), so 1 bar at 60 BPM fits
  params:set("clock_tempo", 60)
  assert_near(delay_sync.time(), 4.0, 1e-9, "60 BPM, 1 bar (4 s): not halved")
  assert_equal(delay_sync.playing().halvings, 0, "not halved")
  assert_equal(delay_sync.label(), "1 bar")
  params:set("clock_tempo", 30)
  assert_near(delay_sync.time(), 4.0, 1e-9, "30 BPM, 1 bar (8 s): 4 s")
  assert_equal(delay_sync.playing().halvings, 1, "halved once")
  assert_equal(delay_sync.label(), "1 bar>1/2")
  params:set("clock_tempo", 20)
  assert_near(delay_sync.time(), 3.0, 1e-9, "20 BPM, 1 bar (12 s): 3 s")
  assert_equal(delay_sync.playing().halvings, 2, "halved twice")
  assert_equal(delay_sync.label(), "1 bar>1/4")
  -- the boundary: 44.5 BPM's bar (5.393 s) fits, 44.4 BPM's (5.405 s) does not
  params:set("clock_tempo", 44.5)
  assert_near(delay_sync.time(), 4 * 60 / 44.5, 1e-9, "44.5 BPM, 1 bar (5.393 s): not halved")
  assert_equal(delay_sync.playing().halvings, 0, "not halved")
  assert_equal(delay_sync.label(), "1 bar")
  params:set("clock_tempo", 44.4)
  assert_near(delay_sync.time(), 2 * 60 / 44.4, 1e-9, "44.4 BPM, 1 bar (5.405 s): halved once")
  assert_equal(delay_sync.playing().halvings, 1, "halved once")
  assert_equal(delay_sync.label(), "1 bar>1/2")
  -- the tempo's ends (Review Focus 3): 1 bar at 10 BPM (24 s) halves three
  -- times to half a beat; 1/32 at 300 BPM is 0.025 s, above the 0.01 floor
  params:set("clock_tempo", 10)
  assert_near(delay_sync.time(), 3.0, 1e-9, "10 BPM, 1 bar (24 s): 3 s")
  assert_equal(delay_sync.playing().halvings, 3, "halved three times")
  assert_equal(delay_sync.label(), "1 bar>1/8")
  params:set("delay_division", 1)  -- 1/32
  params:set("clock_tempo", 300)
  assert_near(delay_sync.time(), 0.025, 1e-9, "300 BPM, 1/32: 0.025 s")
  assert_equal(delay_sync.playing().halvings, 0, "not halved")
  assert_equal(delay_sync.label(), "1/32")
  -- a halved length a division has names it; one none has, the seconds
  params:set("delay_division", 8)  -- 1/4T, 2/3 of a beat
  params:set("clock_tempo", 5)     -- 8 s: halved once, 4 s, 1/3 of a beat
  assert_equal(delay_sync.playing().halvings, 1, "1/4T at 5 BPM is halved once")
  assert_equal(delay_sync.label(), "1/4T>1/8T")
  params:set("delay_division", 10) -- 1/4D: 18 s at 5 BPM, halved twice: 4.5 s, 3/8 of a beat
  assert_equal(delay_sync.playing().halvings, 2)
  assert_equal(delay_sync.label(), "1/4D>1/16D")
  params:set("clock_tempo", 3)     -- 30 s: halved three times, 3.75 s, 3/16 of a beat
  assert_equal(delay_sync.playing().halvings, 3)
  assert_equal(delay_sync.label(), "1/4D>3.75 s")
end)

test("a tempo change resends the time within a step, and a move under 0.5% sends nothing", function()
  local context, _, delay_sync = loaded()
  params:set("clock_tempo", 120); params:set("delay_sync", 1)
  lfo_step(context)
  context.clear_engine_calls()
  lfo_step(context, 3)
  assert_equal(#delay_calls(context), 0, "a steady tempo sends nothing")
  params:set("clock_tempo", 100)
  assert_equal(#delay_calls(context), 0, "the tempo's action sends nothing itself")
  lfo_step(context)
  assert_equal(#delay_calls(context), 1, "the next step sends the new time")
  assert_near(last_delay(context)[1], 0.45, 1e-9, "100 BPM, 1/8D")
  params:set("clock_tempo", 250)
  lfo_step(context)
  context.clear_engine_calls()
  params:set("clock_tempo", 251)   -- 0.4% shorter
  lfo_step(context, 3)
  assert_equal(#delay_calls(context), 0, "a move under 0.5% sends nothing")
  params:set("clock_tempo", 252)   -- 0.8% from the time last sent
  lfo_step(context)
  assert_equal(#delay_calls(context), 1, "a move past 0.5% of the time last sent sends")
  assert_near(last_delay(context)[1], delay_sync.time(), 1e-9)
  -- with sync off the tempo moves nothing
  params:set("delay_sync", 0)
  context.clear_engine_calls()
  params:set("clock_tempo", 80)
  lfo_step(context, 2)
  assert_equal(#delay_calls(context), 0, "unsynced, a tempo change sends nothing")
end)

test("a synced delay ignores delay_time and its modulation, and plays them again when sync is off", function()
  local context, S = loaded()
  params:set("clock_tempo", 120); params:set("delay_division", DIVISION.quarter); params:set("delay_sync", 1)
  context.clear_engine_calls()
  params:set("delay_time", 1.2)
  S.lib.engine_sync.set_extra_offset("test", "delay_time", 0.3)
  send_param_to_engine("delay_time", params:get("delay_time"))
  lfo_step(context, 3)
  for index, call in ipairs(delay_calls(context)) do
    assert_near(call.args[1], 0.5, 1e-9, "send " .. index .. " plays the division")
  end
  S.lib.engine_sync.set_extra_offset("test", "delay_time", nil)
  send_param_to_engine("delay_time", params:get("delay_time"))
  context.clear_engine_calls()
  params:set("delay_sync", 0)
  assert_near(last_delay(context)[1], 1.2, 1e-9, "sync off: delay_time again")
end)

test("the three params are scene fields: sync and division switch at a fade's end, ping-pong crossfades", function()
  local context, S = loaded()
  local fields = {}
  for _, field in ipairs(S.registry.scene_fields) do fields[field.id] = field end
  assert_true(fields.delay_sync and fields.delay_sync.discrete, "delay_sync switches")
  assert_equal(fields.delay_sync.default, 0)
  assert_true(fields.delay_division and fields.delay_division.discrete, "delay_division switches")
  assert_equal(fields.delay_division.default, DIVISION.eighth_dotted)
  assert_true(fields.delay_pingpong and not fields.delay_pingpong.discrete, "delay_pingpong crossfades")
  assert_equal(fields.delay_pingpong.default, 0)
  params:set("delay_sync", 1); params:set("delay_division", DIVISION.bar); params:set("delay_pingpong", 1)
  capture_scene(1)
  assert_equal(S.scenes[1].data.delay_sync, 1); assert_equal(S.scenes[1].data.delay_division, DIVISION.bar)
  assert_near(S.scenes[1].data.delay_pingpong, 1, 1e-9)
  params:set("delay_sync", 0); params:set("delay_division", DIVISION.quarter); params:set("delay_pingpong", 0)
  capture_scene(2)
  recall_scene(1, 0)
  assert_equal(params:get("delay_sync"), 1); assert_equal(params:get("delay_division"), DIVISION.bar)
  recall_scene(2, 2)
  context.clock.run_for(1)
  local pingpong = params:get("delay_pingpong")
  assert_true(pingpong > 0 and pingpong < 1, "ping-pong fades: " .. pingpong)
  assert_equal(params:get("delay_sync"), 1, "sync holds until the end")
  assert_equal(params:get("delay_division"), DIVISION.bar, "the division holds until the end")
  context.clock.run_for(1.5)
  assert_equal(params:get("delay_sync"), 0); assert_equal(params:get("delay_division"), DIVISION.quarter)
  assert_near(params:get("delay_pingpong"), 0, 1e-9)
  -- a scene without the three fields (saved before them) loads with their defaults
  local older = h.deep_copy(S.scenes[1])
  older.data.delay_sync, older.data.delay_division, older.data.delay_pingpong = nil, nil, nil
  S.scenes[3] = older
  fill_scene(S.scenes[3])
  assert_equal(older.data.delay_sync, 0, "filled: sync off")
  assert_equal(older.data.delay_division, DIVISION.eighth_dotted, "filled: 1/8D")
  assert_equal(older.data.delay_pingpong, 0, "filled: no ping-pong")
  assert_true(validate_scene(S.scenes[3]), "and valid")
  -- a scene outside the params' ranges is refused
  S.scenes[4] = h.deep_copy(S.scenes[1]); S.scenes[4].data.delay_division = 13
  assert_equal(validate_scene(S.scenes[4]), false, "a division past the twelfth is refused")
  S.scenes[4] = h.deep_copy(S.scenes[1]); S.scenes[4].data.delay_pingpong = 1.5
  assert_equal(validate_scene(S.scenes[4]), false, "a ping-pong above 1 is refused")
end)

test("the first setDelay after an instant recall carries the scene's values together", function()
  local context = loaded()
  params:set("clock_tempo", 120)
  params:set("delay_sync", 1); params:set("delay_division", DIVISION.quarter); params:set("delay_time", 1.2)
  params:set("delay_feedback", 0.6); params:set("delay_mix", 0.3); params:set("delay_pingpong", 0.7)
  capture_scene(1)
  params:set("delay_sync", 0); params:set("delay_division", DIVISION.bar); params:set("delay_time", 0.2)
  params:set("delay_feedback", 0.1); params:set("delay_mix", 0.9); params:set("delay_pingpong", 0)
  lfo_step(context)
  context.clear_engine_calls()
  recall_scene(1, 0)
  assert_equal(#delay_calls(context), 1, "the recall sends one, once its entries are applied")
  assert_delay(last_delay(context), 0.5, 0.6, 0.3, 0.7, "the scene's values together")
  lfo_step(context, 3)
  assert_equal(#delay_calls(context), 1, "and nothing after it")
  -- and back to a scene with sync off: its delay_time, not the division
  params:set("delay_sync", 0); params:set("delay_time", 0.8); capture_scene(2)
  recall_scene(1, 0); lfo_step(context)
  context.clear_engine_calls()
  recall_scene(2, 0)
  assert_equal(#delay_calls(context), 1)
  assert_delay(last_delay(context), 0.8, 0.6, 0.3, 0.7, "the unsynced scene's time")
end)

-- 1d's review: a recall's sends are never deferred (docs/notes/lua/engine-sync.md)
test("an instant recall that changes only the feedback or the mix sends one setDelay at once, never deferred", function()
  local context, S = loaded()
  params:set("delay_feedback", 0.6); capture_scene(1)
  params:set("delay_feedback", 0.4); params:set("delay_mix", 0.5); capture_scene(2)
  params:set("delay_feedback", 0.4); params:set("delay_mix", 0)
  lfo_step(context)
  context.clear_engine_calls()
  recall_scene(1, 0)
  assert_equal(#delay_calls(context), 1, "the feedback: one setDelay, before any step")
  assert_delay(last_delay(context), 0.375, 0.6, 0, 0, "the new feedback")
  assert_equal(S.lib.engine_sync.budget_state().pending, 0, "nothing waits")
  context.clear_engine_calls()
  recall_scene(2, 0)
  assert_equal(#delay_calls(context), 1, "the mix (and feedback): one setDelay, before any step")
  assert_delay(last_delay(context), 0.375, 0.4, 0.5, 0, "the new values")
  lfo_step(context, 2)
  assert_equal(#delay_calls(context), 1, "no second send follows")
end)

test("a fade sends the scene's whole delay at its landing", function()
  local context, S = loaded()
  params:set("clock_tempo", 120)
  params:set("delay_sync", 1); params:set("delay_division", DIVISION.quarter)
  params:set("delay_feedback", 0.6); params:set("delay_mix", 0.3); params:set("delay_pingpong", 0.7)
  capture_scene(1)
  params:set("delay_sync", 0); params:set("delay_division", DIVISION.bar); params:set("delay_time", 0.2)
  params:set("delay_feedback", 0.1); params:set("delay_mix", 0.9); params:set("delay_pingpong", 0)
  lfo_step(context)
  -- what the engine has as each apply_entries ends (this hook runs after the
  -- delay's, registered at include): the landing's is the last
  local seen = {}
  S.register_scene_applied({ name = "test landing", fn = function()
    local calls = delay_calls(context)
    table.insert(seen, { count = #calls, last = last_delay(context) })
  end })
  context.clear_engine_calls()
  recall_scene(1, 1)
  context.clock.run_for(1.5, 0.001)
  assert_equal(local_value("current_scene"), 1, "the fade landed")
  assert_equal(#seen, 1, "one apply: the landing")
  assert_delay(seen[1].last, 0.5, 0.6, 0.3, 0.7, "the landing's send carries the whole scene")
  for index, call in ipairs(delay_calls(context)) do
    if index > seen[1].count then
      assert_delay(call.args, 0.5, 0.6, 0.3, 0.7, "every send after the landing")
    end
  end
end)

test("a morph crossing that carries only delay_sync sends one setDelay with the values in place", function()
  local context, S = loaded()
  params:set("clock_tempo", 120)
  params:set("delay_feedback", 0.6); params:set("delay_mix", 0.3); params:set("delay_pingpong", 0.7)
  lfo_step(context)
  context.clear_engine_calls()
  -- morph's discrete writes (lib/morph.lua's write_position), inside its deferrable
  S.lib.engine_sync.deferrable(function()
    S.lib.scenes.apply_entries({ { kind = "discrete", id = "delay_sync", value = 1 } }, { only = "discrete" })
  end)
  assert_equal(#delay_calls(context), 1, "one setDelay")
  assert_delay(last_delay(context), 0.375, 0.6, 0.3, 0.7, "1/8D at 120 BPM with the other values as they are")
  lfo_step(context, 2)
  assert_equal(#delay_calls(context), 1, "no second send follows")
end)

-- #741: a synced delay at 120 BPM, 1/8D (0.375 s) under LFO 1, a sine at
-- 5 Hz and depth 100, on delay_time: through its home routing, or (route)
-- through matrix routing 1 at depth 100 with the LFO homeless. With
-- probes, 12 round-robin keys are marked every step, standing in for other
-- sends (lfos_test's probe_key: an engine sender that sends nothing, so
-- each takes a slot; they fill the round robin, so they stay out of the
-- tests that time a send to the step). Returns the count of probe sends
local function synced_under_lfo(context, S, route, probing)
  params:set("clock_tempo", 120); params:set("delay_sync", 1)
  lfo_step(context)
  if route then
    assert_true(S.lib.matrix.set_home(1, ""), "LFO 1 has no home")
    assert_true(S.lib.matrix.set_routing(1, "lfo1", "delay_time"), "routing 1: L1 to delay_time")
    params:set("matrix_1_depth", 100)
  else
    assert_true(S.lib.matrix.set_home(1, "delay_time"), "LFO 1's home is delay_time")
  end
  params:set("strata_lfo1_shape", 1); params:set("strata_lfo1_rate", 5)
  params:set("strata_lfo1_depth", 100); params:set("strata_lfo1", 1)
  local probes = {count = 0}
  local senders = S.engine_senders
  S.lib.lfos.on_step(function()
    for k = 1, probing and 12 or 0 do
      local key = "probe " .. k
      if senders[key] == nil then senders[key] = function() end end
      S.lib.lfos.mark_due(key, function()
        probes.count = probes.count + 1
        S.lib.engine_sync.send_engine_value(key, 0)
      end)
    end
  end)
  lfo_step(context, 2)
  context.clear_engine_calls()
  probes.count = 0
  return probes
end

for _, case in ipairs({{"a 5 Hz LFO on delay_time", false}, {"a routing from a 5 Hz LFO", true}}) do
  test("a synced delay under " .. case[1] .. " sends no setDelay and takes no slot (#741)", function()
    local context, S = loaded()
    local probes = synced_under_lfo(context, S, case[2], true)
    local low, high = math.huge, -math.huge
    for _ = 1, 48 do
      lfo_step(context)
      local offset = S.lib.matrix.offset("delay_time")
      low, high = math.min(low, offset), math.max(high, offset)
    end
    assert_true(high - low > 0.1, "the matrix moves delay_time's offset")
    assert_equal(#delay_calls(context), 0, "no setDelay in 48 steps")
    assert_equal(probes.count, 12 * 48, "every probe runs every step: delay_time takes no slot")
  end)
end

-- An external clock's tempo wavers: a synced time that moves by less than
-- DELAY.threshold of itself is one the step hook does not resend, so the
-- modulation sends it neither
test("a synced, modulated delay on an external clock wavering under 0.5% sends no setDelay (#741)", function()
  restoring_tempo(function()
    local context, S = loaded()
    synced_under_lfo(context, S)
    params:set("clock_source", 2)  -- midi: the tempo is clock.get_tempo()'s
    clock.tempo = 120
    lfo_step(context, 2)
    context.clear_engine_calls()
    local wavers = {120.2, 119.8, 120.4, 119.7, 120.1, 119.9}
    for step = 1, 48 do
      clock.tempo = wavers[(step - 1) % #wavers + 1]
      lfo_step(context)
    end
    assert_equal(#delay_calls(context), 0, "no setDelay in 48 steps")
    clock.tempo = 126  -- 5%: the step hook resends
    lfo_step(context)
    assert_true(#delay_calls(context) >= 1, "a tempo move past 0.5% sends")
    assert_near(last_delay(context)[1], 0.75 * 60 / 126, 1e-9, "the new time")
  end)
end)

test("a feedback edit under a synced, modulated delay sends one setDelay with the synced time (#741)", function()
  local context, S = loaded()
  synced_under_lfo(context, S)
  lfo_step(context, 5)
  params:set("delay_feedback", 0.5)
  assert_equal(#delay_calls(context), 1, "one setDelay")
  assert_delay(last_delay(context), 0.375, 0.5, engine_param_value("delay_mix"), 0, "the edit")
  lfo_step(context, 10)
  assert_equal(#delay_calls(context), 1, "and none after it")
end)

test("sync off under modulation sends the modulated time at once (#741)", function()
  local context, S = loaded()
  synced_under_lfo(context, S)
  lfo_step(context, 7)
  params:set("delay_sync", 0)
  assert_equal(#delay_calls(context), 1, "one setDelay")
  assert_near(last_delay(context)[1], S.lib.engine_sync.with_lfo_offsets("delay_time", params:get("delay_time")),
    1e-9, "the time as modulated now")
  local first = last_delay(context)[1]
  lfo_step(context, 3)
  assert_true(#delay_calls(context) > 1, "the next steps send the moving time")
  assert_true(math.abs(last_delay(context)[1] - first) > 1e-6, "and it moves")
end)

test("a tempo move under a synced, modulated delay still resends within a step (#741)", function()
  local context, S = loaded()
  synced_under_lfo(context, S)
  lfo_step(context, 3)
  assert_equal(#delay_calls(context), 0, "nothing while the tempo holds")
  params:set("clock_tempo", 100)
  lfo_step(context)
  -- the step hook's resend alone: the matrix skips delay_time while the
  -- delay is synced at a finite time (#768)
  assert_equal(#delay_calls(context), 1, "the next step sends the new time once")
  assert_near(last_delay(context)[1], 0.45, 1e-9, "100 BPM, 1/8D")
  lfo_step(context, 5)
  assert_equal(#delay_calls(context), 1, "and nothing after it")
  -- a tempo ramp: one setDelay each step it moves the time
  for step, tempo in ipairs({96, 92, 88, 84, 80, 76}) do
    context.clear_engine_calls()
    params:set("clock_tempo", tempo)
    lfo_step(context)
    assert_equal(#delay_calls(context), 1, "ramp step " .. step .. ": one setDelay")
    assert_near(last_delay(context)[1], 0.75 * 60 / tempo, 1e-9, "ramp step " .. step .. ": " .. tempo .. " BPM")
  end
end)

-- #762: the same delay (120 BPM, 1/8D, 0.375 s), synced unless `unsynced`,
-- under LFO 1 (a sine at 5 Hz, depth 100) homed on macro 1, whose row 1
-- targets delay_time and row 2 reverb_mix, both over their whole range.
-- The macro stays at `stored` (default 0: the sine's lower half clamps to
-- it, so the extras are cleared once a cycle and worked out again)
local function under_macro_lfo(context, S, stored, unsynced)
  params:set("clock_tempo", 120); params:set("delay_sync", unsynced and 0 or 1)
  assert_true(S.lib.macros.set_target(1, 1, "delay_time", 0, 1), "macro 1's row 1: delay_time")
  assert_true(S.lib.macros.set_target(1, 2, "reverb_mix", 0, 1), "macro 1's row 2: reverb_mix")
  params:set("macro_1", stored or 0)
  lfo_step(context, 2)
  assert_true(S.lib.matrix.set_home(1, "macro_1"), "LFO 1's home is macro 1")
  params:set("strata_lfo1_shape", 1); params:set("strata_lfo1_rate", 5)
  params:set("strata_lfo1_depth", 100); params:set("strata_lfo1", 1)
  lfo_step(context, 2)
  context.clear_engine_calls()
end

for _, stored in ipairs({0, 0.5}) do
  test("a synced delay under an LFO on a macro at " .. stored .. " that targets delay_time sends no setDelay (#762)",
    function()
      local context, S = loaded()
      under_macro_lfo(context, S, stored)
      local low, high = math.huge, -math.huge
      for _ = 1, 48 do
        lfo_step(context)
        local mix = engine_param_value("reverb_mix")
        low, high = math.min(low, mix), math.max(high, mix)
      end
      assert_equal(#delay_calls(context), 0, "no setDelay in 48 steps")
      assert_true(high - low > 0.1, "the macro's other target still moves")
      assert_true(#context.calls_named("setReverb") > 0, "and is sent")
    end)
end

test("a feedback edit under a synced delay and a macro's LFO sends one setDelay with the synced time (#762)", function()
  local context, S = loaded()
  under_macro_lfo(context, S)
  lfo_step(context, 5)
  context.clear_engine_calls()
  params:set("delay_feedback", 0.5)
  assert_equal(#delay_calls(context), 1, "one setDelay")
  assert_delay(last_delay(context), 0.375, 0.5, engine_param_value("delay_mix"), 0, "the edit")
  lfo_step(context, 10)
  assert_equal(#delay_calls(context), 1, "and none after it")
end)

test("sync off under a macro's LFO sends the modulated time at once (#762)", function()
  local context, S = loaded()
  under_macro_lfo(context, S, 0.5)
  lfo_step(context, 7)
  context.clear_engine_calls()
  params:set("delay_sync", 0)
  assert_equal(#delay_calls(context), 1, "one setDelay")
  local modulated = engine_param_value("delay_time")
  assert_true(math.abs(modulated - params:get("delay_time")) > 1e-6, "the macro's LFO moves delay_time")
  assert_near(last_delay(context)[1], modulated, 1e-9, "the time as modulated now")
  local first = last_delay(context)[1]
  lfo_step(context, 3)
  assert_true(#delay_calls(context) > 1, "the next steps send the moving time")
  assert_true(math.abs(last_delay(context)[1] - first) > 1e-6, "and it moves")
end)

test("unsynced, a macro's LFO still sends delay_time every step (#762)", function()
  local context, S = loaded()
  under_macro_lfo(context, S, 0.5, true)
  lfo_step(context, 12)
  local calls = delay_calls(context)
  assert_equal(#calls, 12, "one setDelay a step")
  assert_true(math.abs(calls[1].args[1] - calls[#calls].args[1]) > 1e-6, "carrying the moving time")
end)

-- #768: the review's probe. While synced the modulation's sends were
-- skipped, so the delivered delay_time is stale; a tempo that then gives no
-- length plays the param as modulated now, never that stale value
test("a synced delay whose tempo gives no length plays delay_time as modulated now, not a stale value (#768)", function()
  restoring_tempo(function()
    local context, S = loaded()
    under_macro_lfo(context, S, 0.5, true)  -- unsynced: the LFO's delay_time is delivered every step
    lfo_step(context, 7)
    params:set("delay_sync", 1)
    lfo_step(context, 2)
    params:set("strata_lfo1", 0)  -- the LFO off: the macro's extra on delay_time clears, unsent while synced
    lfo_step(context, 3)
    local expected = S.lib.engine_sync.with_lfo_offsets("delay_time", params:get("delay_time"))
    assert_true(math.abs(engine_param_value("delay_time") - expected) > 1e-3,
      "the delivered delay_time is stale: " .. engine_param_value("delay_time") .. " for " .. expected)
    context.clear_engine_calls()
    params:set("clock_source", 2)  -- midi: the tempo is clock.get_tempo()'s
    clock.tempo = 0
    lfo_step(context, 2)
    assert_true(#delay_calls(context) >= 1, "the time is sent")
    assert_near(last_delay(context)[1], expected, 1e-9, "delay_time with its offsets as they are now")
    assert_near(S.lib.delay_sync.time(), expected, 1e-9, "and M.time() says so")
  end)
end)

-- #770: a synced delay at a tempo with no length plays delay_time with its
-- offsets, which the modulation sends (time_unheard is false there); the
-- step hook's resend must not add a second setDelay in the same step.
-- Steps the LFO clock eight times from a MIDI clock's tempo of 0 (the step
-- it gives no length included), each step's setDelay count at most one;
-- returns the counts
local function steps_at_no_length(context, S)
  params:set("clock_source", 2)  -- midi: the tempo is clock.get_tempo()'s
  clock.tempo = 0
  local counts = {}
  for step = 1, 8 do
    local before = #delay_calls(context)
    lfo_step(context)
    counts[step] = #delay_calls(context) - before
  end
  local shown = table.concat(counts, " ")
  for step, count in ipairs(counts) do
    assert_true(count <= 1, "step " .. step .. ": at most one setDelay (" .. shown .. ")")
  end
  assert_true(#delay_calls(context) >= 1, "the time is sent (" .. shown .. ")")
  local expected = S.lib.engine_sync.with_lfo_offsets("delay_time", params:get("delay_time"))
  assert_near(S.lib.delay_sync.time(), expected, 1e-9, "M.time(): delay_time with its offsets")
  return counts
end

test("a synced delay at a tempo with no length under an LFO on delay_time sends one setDelay a step (#770)", function()
  restoring_tempo(function()
    local context, S = loaded()
    synced_under_lfo(context, S)
    local counts = steps_at_no_length(context, S)
    assert_equal(counts[#counts], 1, "the last step sends")
    assert_near(last_delay(context)[1], S.lib.delay_sync.time(), 1e-9, "the param's time with its offset")
    assert_true(math.abs(last_delay(context)[1] - params:get("delay_time")) > 1e-6, "the offset is in it")
    -- back to a tempo with a length: its division once, then nothing
    context.clear_engine_calls()
    clock.tempo = 120
    lfo_step(context)
    assert_equal(#delay_calls(context), 1, "120 BPM: one setDelay")
    assert_near(last_delay(context)[1], 0.375, 1e-9, "120 BPM, 1/8D")
    lfo_step(context, 5)
    assert_equal(#delay_calls(context), 1, "and nothing after it")
  end)
end)

test("a synced delay at a tempo with no length under a macro's LFO on delay_time sends one setDelay a step (#770)",
  function()
    restoring_tempo(function()
      local context, S = loaded()
      under_macro_lfo(context, S, 0.5)
      steps_at_no_length(context, S)
      assert_near(last_delay(context)[1], S.lib.delay_sync.time(), 1e-9, "the param's time with its offsets")
      assert_true(math.abs(last_delay(context)[1] - params:get("delay_time")) > 1e-6, "the macro's offset is in it")
    end)
  end)

test("a synced delay sends once as the tempo stops giving a length and once as it gives one again (#770)", function()
  restoring_tempo(function()
    local context = loaded()
    params:set("clock_tempo", 120); params:set("delay_sync", 1)
    params:set("delay_time", 0.6)
    params:set("clock_source", 2)  -- midi: the tempo is clock.get_tempo()'s
    clock.tempo = 120
    lfo_step(context, 2)
    assert_near(last_delay(context)[1], 0.375, 1e-9, "synced at 120 BPM: 1/8D")
    context.clear_engine_calls()
    clock.tempo = 0
    lfo_step(context, 6)
    assert_equal(#delay_calls(context), 1, "tempo 0: one setDelay")
    assert_near(last_delay(context)[1], 0.6, 1e-9, "tempo 0: delay_time")
    context.clear_engine_calls()
    clock.tempo = 120
    lfo_step(context, 6)
    assert_equal(#delay_calls(context), 1, "back to 120 BPM: one setDelay")
    assert_near(last_delay(context)[1], 0.375, 1e-9, "back to 120 BPM: 1/8D")
  end)
end)

test("DELAY.max_seconds equals the engine's limit on setDelay's time", function()
  local _, _, delay_sync = loaded()
  local limit = h.engine_spec.argument_limits.setDelay[1]
  assert_equal(limit.name, "time")
  assert_near(delay_sync.DELAY.max_seconds, limit.high, 1e-9, "the stub's limit, read from \\strataDelay")
  assert_near(delay_sync.DELAY.max_seconds, 5.4, 1e-9)
  local low, high = param_range("delay_time")
  assert_near(high, delay_sync.DELAY.max_seconds, 1e-9, "delay_time reaches it")
  assert_near(low, 0.01, 1e-9)
  assert_near(params:get("delay_time"), 0.375, 1e-9, "delay_time's default stays")
end)

-- The invariant's line for name ("<name>: <message>"), or nil while it holds
local function broken_line(name)
  for _, line in ipairs(h.check_invariants()) do
    if line:sub(1, #name + 2) == name .. ": " then return line end
  end
end

test("the delay sync invariant names a held send outside a recall's apply", function()
  local context, S, delay_sync = loaded()
  lfo_step(context)
  assert_equal(broken_line("delay sync"), nil, "it holds at rest")
  h.allow_broken_invariants("the test holds a send outside an apply on purpose")
  delay_sync.hold()
  assert_true(broken_line("delay sync") ~= nil, "a held send with no apply running is reported")
  assert_true(not S.scene_recall_in_progress, "no apply runs")
end)

test("the delay sync invariant names an unsynced time the engine was never sent, and leaves a synced one to the step",
  function()
    local context, S = loaded()
    params:set("delay_time", 0.6)
    lfo_step(context)
    assert_equal(broken_line("delay sync"), nil, "unsynced, sent: it holds")
    -- synced, the tempo moves with no event the module sees: legal until the
    -- next step, so the invariant does not check it
    params:set("delay_sync", 1)
    params:set("clock_tempo", 100)
    assert_equal(broken_line("delay sync"), nil, "a synced time that waits for its step is legal")
    lfo_step(context)
    params:set("delay_sync", 0)
    h.allow_broken_invariants("the test moves the engine's delay_time without its send on purpose")
    S.engine_param_values.delay_time = 0.9
    assert_true(broken_line("delay sync") ~= nil, "a free time that differs from the time last sent is reported")
  end)

---------------------------------------------------------------------------
-- The table `synced delay` (3.9, #911; docs/notes/lua/delay-sync.md). Every
-- state is entered on a MIDI clock at 120 BPM (the no-length one at 0),
-- delay_time 0.6 s (the free and no-length time), 1/8D (0.375 s at 120);
-- a held state inside a real apply_entries, suspended in a coroutine after
-- its delay_feedback entry's action (0.6) held the send. Each event fires
-- its change and then one LFO step; each row's check asserts the setDelay
-- sends from the event on (their count and the time each carries) and, from
-- a held state, the one setDelay the apply's end flushes
---------------------------------------------------------------------------

local TABLE = {time = 0.6, division = 0.375, moved = 0.45, tempo = 120, moved_tempo = 100,
  apply_feedback = 0.6, edit_feedback = 0.5, scene_feedback = 0.7}

local function table_enter(sync, tempo, holding)
  return function(context)
    local S = local_value("S")
    params:set("clock_source", 2)  -- midi: the tempo is clock.get_tempo()'s (a fresh clock each load)
    clock.tempo = TABLE.tempo
    params:set("delay_time", TABLE.time)
    params:set("delay_sync", sync)
    lfo_step(context)
    clock.tempo = tempo
    lfo_step(context)
    if holding then
      -- a real apply, suspended after its delay_feedback entry's action
      local param = params:lookup_param("delay_feedback")
      local action = param.action
      local suspend = true
      param.action = function(x)
        action(x)
        if suspend then
          suspend = false
          if coroutine.yield() == "fail" then error("test: the apply fails", 0) end
        end
      end
      context.apply = coroutine.create(function()
        S.lib.scenes.apply_entries({{kind = "continuous", id = "delay_feedback", value = TABLE.apply_feedback}})
      end)
      local resumed, problem = coroutine.resume(context.apply)
      assert_true(resumed, "the apply starts: " .. tostring(problem))
      assert_equal(coroutine.status(context.apply), "suspended", "the apply waits inside its entry")
      assert_true(S.scene_recall_in_progress, "inside the apply")
    end
    context.clear_engine_calls()
  end
end

-- End the suspended apply (fail: its entry's action raises as it resumes);
-- returns what resume returned
local function end_apply(context, fail)
  local resumed, problem = coroutine.resume(context.apply, fail and "fail" or nil)
  assert_equal(coroutine.status(context.apply), "dead", "the apply has ended")
  return resumed, problem
end

-- Turn LFO 1 on, homed on delay_time (a sine at 5 Hz, depth 100)
local function modulate_time()
  local S = local_value("S")
  assert_true(S.lib.matrix.set_home(1, "delay_time"), "LFO 1's home is delay_time")
  params:set("strata_lfo1_shape", 1); params:set("strata_lfo1_rate", 5)
  params:set("strata_lfo1_depth", 100); params:set("strata_lfo1", 1)
end

local function modulated_time()
  return local_value("S").lib.engine_sync.with_lfo_offsets("delay_time", params:get("delay_time"))
end

-- The setDelay sends since the state was entered: count of them, each
-- carrying time (a number, or a function giving it after the event)
local function assert_sends(context, count, time, feedback, where)
  local calls = delay_calls(context)
  assert_equal(#calls, count, where .. ": setDelay sends")
  local expected = type(time) == "function" and time() or time
  for index, call in ipairs(calls) do
    assert_near(call.args[1], expected, 1e-6, where .. ": send " .. index .. "'s time")
    if feedback then assert_near(call.args[2], feedback, 1e-6, where .. ": send " .. index .. "'s feedback") end
  end
end

-- A row's check from an unheld state: count sends of time (feedback
-- optional) after the event and its step
local function sends(count, time, feedback)
  return function(context) assert_sends(context, count, time, feedback, "after the event") end
end

-- A row's check from a held state: no send while the apply runs, then its
-- end (or its failure) flushes one setDelay of time and feedback; a state
-- held still after the event ends its apply here
local function held_then(time, feedback)
  return function(context)
    local S = local_value("S")
    assert_sends(context, 0, time, nil, "while the apply runs")
    if coroutine.status(context.apply) == "suspended" then
      context.clear_engine_calls()
      assert_true(end_apply(context), "the apply ends")
    end
    assert_true(not S.lib.delay_sync.held(), "nothing held after the apply")
    assert_sends(context, 1, time, feedback, "the apply's end")
  end
end

-- A row's check of the apply's end or failure: the one setDelay it flushed
-- (of time and feedback), and nothing held
local function ended(time, feedback)
  return function(context)
    assert_true(not local_value("S").lib.delay_sync.held(), "nothing held after the apply")
    assert_sends(context, 1, time, feedback, "the apply's end")
  end
end

local function table_tempo(tempo)
  return function(context)
    clock.tempo = tempo
    lfo_step(context)
  end
end

h.transition_table({
  name = "synced delay",
  notes = {"docs/notes/lua/delay-sync.md", "synced delay"},
  states = {
    ["free"] = table_enter(0, TABLE.tempo),
    ["division"] = table_enter(1, TABLE.tempo),
    ["synced, no length"] = table_enter(1, 0),
    ["free, held"] = table_enter(0, TABLE.tempo, true),
    ["division, held"] = table_enter(1, TABLE.tempo, true),
    ["synced, no length, held"] = table_enter(1, 0, true),
  },
  events = {
    ["tempo move"] = table_tempo(TABLE.moved_tempo),
    ["modulation of the time"] = function(context) modulate_time(); lfo_step(context) end,
    ["feedback edit"] = function(context) params:set("delay_feedback", TABLE.edit_feedback); lfo_step(context) end,
    ["sync toggle"] = function(context) params:set("delay_sync", 1 - params:get("delay_sync")); lfo_step(context) end,
    -- an instant recall of a scene of the delay as it is but its feedback
    -- (from a held state, an apply inside the running one)
    ["recall"] = function(context)
      local S = local_value("S")
      capture_scene(1)
      S.scenes[1].data.delay_feedback = TABLE.scene_feedback
      recall_scene(1, 0)
      lfo_step(context)
    end,
    ["tempo to 0"] = table_tempo(0),
    ["tempo back"] = table_tempo(TABLE.tempo),
    ["apply ends"] = function(context)
      local resumed, problem = end_apply(context)
      assert_true(resumed, "the apply ends: " .. tostring(problem))
    end,
    -- the apply's entry raises: apply_entries puts the flag back, runs the
    -- scene-applied hooks, then raises the error again
    ["apply fails"] = function(context)
      local resumed, problem = end_apply(context, true)
      assert_true(not resumed, "the apply raised")
      assert_true(tostring(problem):find("test: the apply fails", 1, true) ~= nil, "its error: " .. tostring(problem))
    end,
  },
  state_of = function()
    local delay_sync = local_value("S").lib.delay_sync
    local mode = "free"
    if params:get("delay_sync") == 1 then mode = delay_sync.playing() and "division" or "synced, no length" end
    return delay_sync.held() and mode .. ", held" or mode
  end,
  rows = {
    {"free", "tempo move", "free", check = sends(0)},
    {"free", "modulation of the time", "free", check = sends(1, modulated_time)},
    {"free", "feedback edit", "free", check = sends(1, TABLE.time, TABLE.edit_feedback)},
    {"free", "sync toggle", "division", check = sends(1, TABLE.division)},
    {"free", "recall", "free", check = sends(1, TABLE.time, TABLE.scene_feedback)},
    {"free", "tempo to 0", "free", check = sends(0)},
    {"division", "tempo move", "division", check = sends(1, TABLE.moved)},
    {"division", "modulation of the time", "division", check = sends(0)},
    {"division", "feedback edit", "division", check = sends(1, TABLE.division, TABLE.edit_feedback)},
    {"division", "sync toggle", "free", check = sends(1, TABLE.time)},
    {"division", "recall", "division", check = sends(1, TABLE.division, TABLE.scene_feedback)},
    {"division", "tempo to 0", "synced, no length", check = sends(1, TABLE.time)},
    {"synced, no length", "modulation of the time", "synced, no length", check = sends(1, modulated_time)},
    {"synced, no length", "feedback edit", "synced, no length", check = sends(1, TABLE.time, TABLE.edit_feedback)},
    {"synced, no length", "sync toggle", "free", check = sends(1, TABLE.time)},
    {"synced, no length", "recall", "synced, no length", check = sends(1, TABLE.time, TABLE.scene_feedback)},
    {"synced, no length", "tempo back", "division", check = sends(1, TABLE.division)},
    {"free, held", "tempo move", "free, held", check = held_then(TABLE.time, TABLE.apply_feedback)},
    {"free, held", "modulation of the time", "free, held", check = held_then(modulated_time)},
    {"free, held", "feedback edit", "free, held", check = held_then(TABLE.time, TABLE.edit_feedback)},
    {"free, held", "sync toggle", "division, held", check = held_then(TABLE.division)},
    {"free, held", "recall", "free, held", check = held_then(TABLE.time, TABLE.scene_feedback)},
    {"free, held", "tempo to 0", "free, held", check = held_then(TABLE.time)},
    {"free, held", "apply ends", "free", check = ended(TABLE.time, TABLE.apply_feedback)},
    {"free, held", "apply fails", "free", check = ended(TABLE.time, TABLE.apply_feedback)},
    {"division, held", "tempo move", "division, held", check = held_then(TABLE.moved, TABLE.apply_feedback)},
    {"division, held", "modulation of the time", "division, held", check = held_then(TABLE.division)},
    {"division, held", "feedback edit", "division, held", check = held_then(TABLE.division, TABLE.edit_feedback)},
    {"division, held", "sync toggle", "free, held", check = held_then(TABLE.time)},
    {"division, held", "recall", "division, held", check = held_then(TABLE.division, TABLE.scene_feedback)},
    {"division, held", "tempo to 0", "synced, no length, held", check = held_then(TABLE.time)},
    {"division, held", "apply ends", "division", check = ended(TABLE.division, TABLE.apply_feedback)},
    {"division, held", "apply fails", "division", check = ended(TABLE.division, TABLE.apply_feedback)},
    {"synced, no length, held", "modulation of the time", "synced, no length, held", check = held_then(modulated_time)},
    {"synced, no length, held", "feedback edit", "synced, no length, held",
      check = held_then(TABLE.time, TABLE.edit_feedback)},
    {"synced, no length, held", "sync toggle", "free, held", check = held_then(TABLE.time)},
    {"synced, no length, held", "recall", "synced, no length, held", check = held_then(TABLE.time, TABLE.scene_feedback)},
    {"synced, no length, held", "tempo back", "division, held", check = held_then(TABLE.division)},
    {"synced, no length, held", "apply ends", "synced, no length", check = ended(TABLE.time, TABLE.apply_feedback)},
    {"synced, no length, held", "apply fails", "synced, no length", check = ended(TABLE.time, TABLE.apply_feedback)},
  },
  impossible = {
    {"free", "tempo back", "the free state is entered at 120 BPM: `tempo back` leaves a tempo of 0"},
    {"division", "tempo back", "the division state is at 120 BPM: `tempo back` leaves a tempo of 0"},
    {"free, held", "tempo back", "the free state is entered at 120 BPM: `tempo back` leaves a tempo of 0"},
    {"division, held", "tempo back", "the division state is at 120 BPM: `tempo back` leaves a tempo of 0"},
    {"synced, no length", "tempo move", "a tempo of 0 moves only by giving a length again (`tempo back`)"},
    {"synced, no length", "tempo to 0", "the tempo is 0 already"},
    {"synced, no length, held", "tempo move", "a tempo of 0 moves only by giving a length again (`tempo back`)"},
    {"synced, no length, held", "tempo to 0", "the tempo is 0 already"},
    {"free", "apply ends", "no apply runs: a held send exists only inside one"},
    {"free", "apply fails", "no apply runs: a held send exists only inside one"},
    {"division", "apply ends", "no apply runs: a held send exists only inside one"},
    {"division", "apply fails", "no apply runs: a held send exists only inside one"},
    {"synced, no length", "apply ends", "no apply runs: a held send exists only inside one"},
    {"synced, no length", "apply fails", "no apply runs: a held send exists only inside one"},
  },
})

end

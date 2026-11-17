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
  params:set("clock_tempo", 60)
  assert_near(delay_sync.time(), 2.0, 1e-9, "60 BPM, 1 bar (4 s): 2 s")
  assert_equal(delay_sync.playing().halvings, 1, "halved once")
  assert_equal(delay_sync.label(), "1 bar>1/2")
  params:set("clock_tempo", 30)
  assert_near(delay_sync.time(), 2.0, 1e-9, "30 BPM, 1 bar (8 s): 2 s")
  assert_equal(delay_sync.playing().halvings, 2, "halved twice")
  assert_equal(delay_sync.label(), "1 bar>1/4")
  params:set("clock_tempo", 88.9)
  assert_near(delay_sync.time(), 4 * 60 / 88.9, 1e-9, "88.9 BPM, 1 bar (2.6997 s): not halved")
  assert_equal(delay_sync.playing().halvings, 0, "not halved")
  assert_equal(delay_sync.label(), "1 bar")
  -- the tempo's ends (Review Focus 3): 1 bar at 20 BPM (12 s) halves three
  -- times to half a beat; 1/32 at 300 BPM is 0.025 s, above the 0.01 floor
  params:set("clock_tempo", 20)
  assert_near(delay_sync.time(), 1.5, 1e-9, "20 BPM, 1 bar (12 s): 1.5 s")
  assert_equal(delay_sync.playing().halvings, 3, "halved three times")
  assert_equal(delay_sync.label(), "1 bar>1/8")
  params:set("delay_division", 1)  -- 1/32
  params:set("clock_tempo", 300)
  assert_near(delay_sync.time(), 0.025, 1e-9, "300 BPM, 1/32: 0.025 s")
  assert_equal(delay_sync.playing().halvings, 0, "not halved")
  assert_equal(delay_sync.label(), "1/32")
  -- a halved length a division has names it; one none has, the seconds
  params:set("delay_division", 8)  -- 1/4T, 2/3 of a beat
  params:set("clock_tempo", 10)    -- 4 s: halved once, 2 s, 1/3 of a beat
  assert_equal(delay_sync.playing().halvings, 1, "1/4T at 10 BPM is halved once")
  assert_equal(delay_sync.label(), "1/4T>1/8T")
  params:set("delay_division", 10) -- 1/4D: 9 s at 10 BPM, halved twice: 2.25 s, 3/8 of a beat
  assert_equal(delay_sync.label(), "1/4D>1/16D")
  params:set("clock_tempo", 5)     -- 18 s: halved three times, 2.25 s, 3/16 of a beat
  assert_equal(delay_sync.playing().halvings, 3)
  assert_equal(delay_sync.label(), "1/4D>2.25 s")
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
  -- the step hook's resend and the matrix's (which sees the time move
  -- first) may both go in this step: each carries the new time
  local sent = #delay_calls(context)
  assert_true(sent >= 1, "the next step sends the new time")
  for index, call in ipairs(delay_calls(context)) do
    assert_near(call.args[1], 0.45, 1e-9, "send " .. index .. ": 100 BPM, 1/8D")
  end
  lfo_step(context, 5)
  assert_equal(#delay_calls(context), sent, "and nothing after it")
end)

test("DELAY.max_seconds equals the engine's limit on setDelay's time", function()
  local _, _, delay_sync = loaded()
  local limit = h.engine_spec.argument_limits.setDelay[1]
  assert_equal(limit.name, "time")
  assert_near(delay_sync.DELAY.max_seconds, limit.high, 1e-9, "the stub's limit, read from \\strataDelay")
  assert_near(delay_sync.DELAY.max_seconds, 2.7, 1e-9)
  local low, high = param_range("delay_time")
  assert_near(high, delay_sync.DELAY.max_seconds, 1e-9, "delay_time reaches it")
  assert_near(low, 0.01, 1e-9)
  assert_near(params:get("delay_time"), 0.375, 1e-9, "delay_time's default stays")
end)

end

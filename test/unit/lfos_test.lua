-- test/unit/lfos_test.lua
-- The six LFOs (lib/lfos.lua): shapes, phases, LFO-to-LFO modulation, the
-- 48 Hz clock and its round robin of sends, Lua-run LFOs modulating around
-- the stored value, engine-run LFOs on the five fast destinations, the
-- destination list, the 3.3 PSET import and scene migration, the sources,
-- offset_for and m_for, and cleanup
-- Run alone: lua test/run.lua lfos

return function(h)
local test, stubs, assert_true, assert_equal = h.test, h.stubs, h.assert_true, h.assert_equal
local assert_near, load_strata, local_value = h.assert_near, h.load_strata, h.local_value
local finish_startup, deep_copy = h.finish_startup, h.deep_copy

-- LFO n's param ids: strata_lfo<n> (on/off), strata_lfo<n>_<field>
local function lfo_id(n, field) return "strata_lfo" .. n .. (field and ("_" .. field) or "") end

local function option_index(param_id, name)
  for index, option in ipairs(params:lookup_param(param_id).options) do
    if option == name then return index end
  end
  error("no option " .. name .. " in " .. param_id)
end

local function destination_index(label)
  for index, destination in ipairs(local_value("LFO_DESTINATIONS")) do
    if destination.label == label then return index end
  end
  error("no LFO destination " .. label)
end

-- Run the clocks until the LFO clock has stepped `count` times (default 1)
local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

-- LFO n on `label` with a square shape held at its top (value +1) or bottom
-- (value -1): the slowest rate moves the phase 6.3e-5 a step
local function hold_lfo(n, label, depth, low)
  params:set(lfo_id(n, "dest"), destination_index(label))
  params:set(lfo_id(n, "shape"), option_index(lfo_id(n, "shape"), "square"))
  params:set(lfo_id(n, "rate"), 0.003)
  params:set(lfo_id(n, "phase"), low and 50 or 0)
  params:set(lfo_id(n, "depth"), depth)
  params:set(lfo_id(n), 1)
end

-- The calls named `name` whose first argument is `first`
local function calls_with(context, name, first)
  local found = {}
  for _, call in ipairs(context.calls_named(name)) do
    if call.args[1] == first then table.insert(found, call) end
  end
  return found
end

test("the eight shapes", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  -- u(phase), read as the value 2u - 1 one step after the LFO starts at that phase
  local cases = { { "sine", 25, 1 }, { "sine", 75, 0 }, { "tri", 25, 0.5 }, { "tri", 50, 1 }, { "square", 25, 1 },
    { "square", 75, 0 }, { "up", 30, 0.3 }, { "down", 30, 0.7 } }
  for _, case in ipairs(cases) do
    params:set(lfo_id(1), 0)
    params:set(lfo_id(1, "shape"), option_index(lfo_id(1, "shape"), case[1]))
    params:set(lfo_id(1, "rate"), 0.003); params:set(lfo_id(1, "phase"), case[2])
    params:set(lfo_id(1), 1); lfo_step(context)
    assert_near(lfos.value(1), 2 * case[3] - 1, 1e-3, case[1] .. " at " .. case[2] .. "%")
  end
  params:set(lfo_id(1), 0)
  assert_equal(lfos.value(1), 0, "an LFO that is off reads 0")
  -- the random shapes, sampled after every step (S.lib.lfos.on_step), cut
  -- into cycles where the phase wraps
  local function cycles_of(shape, rate, seconds)
    local samples = {}
    params:set(lfo_id(2, "shape"), option_index(lfo_id(2, "shape"), shape))
    params:set(lfo_id(2, "rate"), rate); params:set(lfo_id(2, "phase"), 0)
    params:set(lfo_id(2), 1)
    lfos.on_step(function()
      if params:get(lfo_id(2)) == 1 then table.insert(samples, { phase = lfos.phase(2), u = (lfos.value(2) + 1) / 2 }) end
    end)
    context.clock.run_for(seconds)
    params:set(lfo_id(2), 0)
    local cycles, current = {}, {}
    for index, sample in ipairs(samples) do
      if index > 1 and sample.phase < samples[index - 1].phase then
        table.insert(cycles, current); current = {}
      end
      table.insert(current, sample)
    end
    return cycles
  end
  math.randomseed(7)
  local held = cycles_of("s&h", 4, 3)
  assert_true(#held >= 10, "s&h: " .. #held .. " cycles")
  local changes = 0
  for index = 2, #held do
    for _, sample in ipairs(held[index]) do
      assert_equal(sample.u, held[index][1].u, "s&h holds one value through a cycle")
    end
    if held[index][1].u ~= held[index - 1][1].u then changes = changes + 1 end
  end
  assert_true(changes >= #held - 2, "s&h draws a new value at the wrap")
  math.randomseed(8)
  local smooth = cycles_of("smooth", 3, 4)
  for index = 2, #smooth - 1 do
    local cycle = smooth[index]
    local first, last = cycle[1], cycle[#cycle]
    local slope = (last.u - first.u) / (last.phase - first.phase)
    for _, sample in ipairs(cycle) do
      assert_near(sample.u, first.u + slope * (sample.phase - first.phase), 1e-9, "smooth is linear in a cycle")
    end
    -- it starts where the cycle before it ended: the last draw
    local before = smooth[index - 1]
    local before_slope = (before[#before].u - before[1].u) / (before[#before].phase - before[1].phase)
    assert_near(before[1].u + before_slope * (1 - before[1].phase), first.u - slope * first.phase, 1e-9,
      "smooth goes on from the value the cycle before ended on")
  end
  math.randomseed(9)
  local drunk = cycles_of("drunk", 10, 21)
  assert_true(#drunk >= 200, "drunk: " .. #drunk .. " cycles")
  for _, cycle in ipairs(drunk) do
    local low, high = math.huge, -math.huge
    for _, sample in ipairs(cycle) do
      assert_true(sample.u >= 0 and sample.u <= 1, "drunk stays inside 0..1 (" .. sample.u .. ")")
      low, high = math.min(low, sample.u), math.max(high, sample.u)
    end
    assert_true(high - low <= 0.2 + 1e-9, "drunk steps at most 0.2 a cycle (" .. (high - low) .. ")")
  end
end)

test("a Lua-run LFO sends the stored value plus m times half the range", function()
  local context = load_strata(); finish_startup(context)
  params:set("reverb_mix", 0.3)
  params:set(lfo_id(1, "dest"), destination_index("rev mix"))
  params:set(lfo_id(1, "rate"), 0.003); params:set(lfo_id(1, "phase"), 25)   -- sine at its top
  assert_equal(params:get(lfo_id(1, "depth")), 25, "the default depth")
  params:set(lfo_id(1), 1)
  context.clear_engine_calls(); lfo_step(context)
  local calls = context.calls_named("setReverb")
  assert_equal(#calls, 1, "one send")
  assert_near(calls[1].args[1], 0.425, 1e-6, "m = 0.25: 0.3 + 0.25 x 0.5")
  params:set(lfo_id(1, "offset"), 10)
  context.clear_engine_calls(); lfo_step(context)
  assert_near(context.calls_named("setReverb")[1].args[1], 0.525, 1e-6, "offset 10: m = 0.25 + 0.2")
  assert_near(params:get("reverb_mix"), 0.3, 1e-9, "the param keeps its value")
  assert_equal(local_value("lfo_last_dest")[1], "reverb_mix")
end)

test("a free LFO's phase follows the time and a clocked one's the beats", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  params:set(lfo_id(1, "rate"), 0.25); params:set(lfo_id(1), 1)
  context.clock.run_for(1)
  assert_near(lfos.phase(1), 0.25, 0.001, "a quarter of a 4 s cycle after 1 s")
  params:set(lfo_id(2, "mode"), option_index(lfo_id(2, "mode"), "clocked"))
  params:set(lfo_id(2, "division"), option_index(lfo_id(2, "division"), "4"))   -- a 16-beat period
  params:set(lfo_id(2), 1)
  local beats = clock.get_beats()
  local target = math.ceil(beats / 16) * 16 + 4   -- beat 4 of a cycle
  context.set_time(util.time() + (target - beats) * clock.get_beat_sec())
  assert_near(lfos.phase(2), 0.25, 1e-6, "at beat 4 of 16")
  params:set(lfo_id(2, "phase"), 50)
  assert_near(lfos.phase(2), 0.75, 1e-6, "the phase param shifts it")
end)

test("rate and depth modulation read lower-numbered LFOs only", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  assert_equal(table.concat(params:lookup_param(lfo_id(1, "rate_mod")).options, " "), "none", "LFO 1 has no source")
  assert_equal(table.concat(params:lookup_param(lfo_id(3, "rate_mod")).options, " "), "none L1 L2")
  assert_equal(table.concat(params:lookup_param(lfo_id(6, "depth_mod")).options, " "), "none L1 L2 L3 L4 L5")
  hold_lfo(1, "none", 25)                               -- LFO 1's value +1
  params:set(lfo_id(2, "rate"), 1)
  params:set(lfo_id(2, "rate_mod"), option_index(lfo_id(2, "rate_mod"), "L1"))
  params:set(lfo_id(2, "rate_mod_amt"), 100)
  params:set(lfo_id(2), 1)
  lfo_step(context)
  assert_near(lfos.value(1), 1, 1e-9)
  assert_near(lfos.effective_rate(2), 4, 1e-9, "value 1 at +100 %: two octaves up")
  params:set(lfo_id(1, "phase"), 50); lfo_step(context)    -- value -1
  assert_near(lfos.effective_rate(2), 0.25, 1e-9, "value -1: two octaves down")
  params:set(lfo_id(2, "rate_mod_amt"), -50); lfo_step(context)
  assert_near(lfos.effective_rate(2), 2, 1e-9, "-50 % of -1: one octave up")
  params:set(lfo_id(2, "rate_mod"), 1)
  params:set(lfo_id(2, "depth"), 50)
  params:set(lfo_id(2, "depth_mod"), option_index(lfo_id(2, "depth_mod"), "L1"))
  params:set(lfo_id(2, "depth_mod_amt"), 100)
  params:set(lfo_id(1, "phase"), 0); lfo_step(context)
  assert_near(lfos.effective_depth(2), 100, 1e-9, "value 1: depth doubled")
  params:set(lfo_id(1, "phase"), 50); lfo_step(context)
  assert_near(lfos.effective_depth(2), 0, 1e-9, "value -1: depth 0")
  params:set(lfo_id(2, "depth"), 0); params:set(lfo_id(1, "phase"), 0); lfo_step(context)
  assert_near(lfos.effective_depth(2), 0, 1e-9, "depth 0 stays 0")
  params:set(lfo_id(2, "depth"), 50)
  params:set(lfo_id(1), 0); lfo_step(context)
  assert_near(lfos.effective_depth(2), 50, 1e-9, "a source that is off contributes 0")
end)

test("at most 12 sends a step, round robin, and every due key within two steps", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local lfos = S.lib.lfos
  params:set("delay_time", 1); params:set("delay_mix", 0.5)   -- the swing stays inside every range
  local labels = { "rev mix", "rev size", "rev damp", "dly time", "dly fdbk", "dly mix" }
  for n, label in ipairs(labels) do
    params:set(lfo_id(n, "dest"), destination_index(label))
    params:set(lfo_id(n, "shape"), option_index(lfo_id(n, "shape"), "up"))
    params:set(lfo_id(n, "rate"), 10); params:set(lfo_id(n, "depth"), 40)
    params:set(lfo_id(n), 1)
  end
  local sent = {}
  local real_send = S.lib.engine_sync.send_engine_value
  S.lib.engine_sync.send_engine_value = function(param_id, value)
    if S.deferrable_write then table.insert(sent, param_id) end   -- the clock's sends, not another clock's
    return real_send(param_id, value)
  end
  lfos.on_step(function()
    for k = 1, 14 do
      lfos.mark_due("probe " .. k, function() table.insert(sent, "probe " .. k) end)
    end
  end)
  local steps = {}
  local ok, problem = pcall(function()
    for _ = 1, 6 do
      sent = {}
      lfo_step(context)
      table.insert(steps, sent)
    end
  end)
  S.lib.engine_sync.send_engine_value = real_send
  if not ok then error(problem, 0) end
  local keys = { "probe 1", "probe 2", "probe 3", "probe 4", "probe 5", "probe 6", "probe 7", "probe 8", "probe 9",
    "probe 10", "probe 11", "probe 12", "probe 13", "probe 14", "reverb_mix", "reverb_size", "reverb_damp",
    "delay_time", "delay_feedback", "delay_mix" }
  for index, step_sent in ipairs(steps) do
    assert_equal(#step_sent, 12, "step " .. index .. " sends 12")
  end
  for index = 1, #steps - 1 do
    local seen = {}
    for _, key in ipairs(steps[index]) do seen[key] = true end
    for _, key in ipairs(steps[index + 1]) do seen[key] = true end
    for _, key in ipairs(keys) do assert_true(seen[key], key .. " sent in steps " .. index .. "-" .. (index + 1)) end
  end
end)

test("a Lua-run LFO above 10 Hz plays at 10 Hz", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  params:set(lfo_id(1, "dest"), destination_index("rev mix"))
  params:set(lfo_id(1, "rate"), 20); params:set(lfo_id(1), 1)
  lfo_step(context)
  assert_near(lfos.effective_rate(1), 10, 1e-9, "20 Hz in Lua plays at 10")
  local start = lfos.phase(1)
  context.clock.run_for(0.05)
  assert_near((lfos.phase(1) - start) % 1, 0.5, 1e-6, "half a cycle in 50 ms")
  assert_true(lfos.capped(1), "the page marks it")
  params:set(lfo_id(1, "rate"), 8); lfo_step(context)
  assert_true(not lfos.capped(1), "8 Hz is not capped")
  assert_near(lfos.effective_rate(1), 8, 1e-9)
  -- in the engine it keeps its rate
  params:set(lfo_id(1, "rate"), 20)
  context.clear_engine_calls()
  params:set(lfo_id(1, "dest"), destination_index("v3 pitch"))
  local call = context.calls_named("setFastLfo")[1]
  assert_near(call.args[5], 20, 1e-9, "an engine LFO runs at 20 Hz")
  assert_true(not lfos.capped(1), "and is not capped")
end)

test("an LFO on a fast destination runs in the engine", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  params:set(lfo_id(1, "dest"), destination_index("v3 pitch"))
  params:set(lfo_id(1, "rate"), 0.25)
  assert_true(lfos.is_engine_run(1), "v3 pitch runs in the engine")
  context.clear_engine_calls()
  params:set(lfo_id(1), 1)
  local names = {}
  for _, call in ipairs(context.engine_calls) do table.insert(names, call.name) end
  assert_equal(table.concat(names, " "), "setFastLfo syncFastLfo", "turned on: set up, then synced")
  local set = context.engine_calls[1].args
  assert_equal(set[1], 0); assert_equal(set[2], 2); assert_equal(set[3], 0); assert_equal(set[4], 0)
  assert_near(set[5], 0.25, 1e-9, "rate"); assert_near(set[6], 0.25, 1e-9, "depth"); assert_near(set[7], 0, 1e-9, "offset")
  assert_equal(context.engine_calls[2].args[1], 0)
  assert_near(context.engine_calls[2].args[2], lfos.phase(1), 1e-6, "synced to Lua's phase")
  context.clear_engine_calls()
  lfo_step(context, 48)
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    assert_true(call.args[2] ~= "pitchShift", "the engine moves the pitch, Lua sends none")
  end
  assert_equal(#context.calls_named("setFastLfo"), 0, "an engine LFO sends nothing per step")
  assert_equal(local_value("lfo_last_dest")[1], nil, "no Lua offset")
  context.clear_engine_calls()
  params:set(lfo_id(1, "dest"), destination_index("v3 size"))
  assert_equal(#context.calls_named("setFastLfo"), 1, "another fast destination: one setFastLfo")
  assert_equal(context.calls_named("setFastLfo")[1].args[3], 2, "size")
  assert_equal(#context.calls_named("stopFastLfo"), 0, "no stop")
  context.clear_engine_calls()
  params:set("reverb_mix", 0.3)
  params:set(lfo_id(1, "dest"), destination_index("rev mix"))
  assert_equal(#calls_with(context, "stopFastLfo", 0), 1, "a Lua destination stops the engine LFO")
  assert_true(not lfos.is_engine_run(1))
  lfo_step(context)
  assert_equal(#context.calls_named("setReverb"), 1, "and Lua's sends begin")
  context.clear_engine_calls()
  params:set(lfo_id(1), 0)
  local restores = context.calls_named("setReverb")
  assert_equal(#restores, 1, "off: the stored value sent once")
  assert_near(restores[1].args[1], 0.3, 1e-9)
  lfo_step(context, 3)
  assert_equal(#context.calls_named("setReverb"), 1, "and nothing after")
  -- every fast destination, the voice's amp and filter cutoff included
  for label, destination in pairs({ ["v1 pitch"] = 0, ["v2 pos"] = 1, ["v4 size"] = 2, ["v5 vfilt"] = 3, ["v7 amp"] = 4 }) do
    context.clear_engine_calls()
    params:set(lfo_id(2, "dest"), destination_index(label)); params:set(lfo_id(2), 1)
    local call = context.calls_named("setFastLfo")[1]
    assert_equal(call.args[2], tonumber(label:match("^v(%d)")) - 1, label .. ": its voice")
    assert_equal(call.args[3], destination, label .. ": its destination")
    params:set(lfo_id(2), 0)
  end
  -- depth 0 stops it, as it restores a Lua destination
  params:set(lfo_id(1, "dest"), destination_index("v3 pitch")); params:set(lfo_id(1), 1)
  context.clear_engine_calls()
  params:set(lfo_id(1, "depth"), 0); lfo_step(context)
  assert_equal(#calls_with(context, "stopFastLfo", 0), 1, "depth 0 stops the engine LFO")
  context.clear_engine_calls()
  params:set(lfo_id(1, "depth"), 30); lfo_step(context)
  assert_equal(#context.calls_named("setFastLfo"), 1, "a depth again starts it")
  assert_near(context.calls_named("setFastLfo")[1].args[6], 0.3, 1e-9)
  -- a shape change replaces the node: setFastLfo with the shape, then a sync
  context.clear_engine_calls()
  params:set(lfo_id(1, "shape"), option_index(lfo_id(1, "shape"), "drunk"))
  local after = {}
  for _, call in ipairs(context.engine_calls) do table.insert(after, call.name) end
  assert_equal(table.concat(after, " "), "setFastLfo syncFastLfo")
  assert_equal(context.engine_calls[1].args[4], 7, "drunk is engine shape 7")
end)

test("an engine LFO's modulated rate is resent past 0.5 % and its depth past 1/1000", function()
  local context = load_strata(); finish_startup(context)
  -- LFO 1 rises slowly from -1 (up, 0.003 Hz): 1.25e-4 a step
  params:set(lfo_id(1, "shape"), option_index(lfo_id(1, "shape"), "up"))
  params:set(lfo_id(1, "rate"), 0.003); params:set(lfo_id(1), 1)
  params:set(lfo_id(2, "dest"), destination_index("v2 pitch"))
  params:set(lfo_id(2, "rate"), 1)
  params:set(lfo_id(2, "rate_mod"), option_index(lfo_id(2, "rate_mod"), "L1"))
  params:set(lfo_id(2, "rate_mod_amt"), 100)
  params:set(lfo_id(2), 1)
  lfo_step(context)
  local first = context.calls_named("setFastLfo")
  local last_rate = first[#first].args[5]
  assert_near(last_rate, 0.25, 0.01, "LFO 1 near -1: two octaves down")
  context.clear_engine_calls()
  lfo_step(context, 200)
  local rates = context.calls_named("setFastLfo")
  assert_true(#rates >= 4, "the rate is resent as it moves (" .. #rates .. " times)")
  for _, call in ipairs(rates) do
    local moved = math.abs(call.args[5] / last_rate - 1)
    assert_true(moved > 0.005 and moved < 0.0055, "each resend moved the rate 0.5 % (" .. moved .. ")")
    last_rate = call.args[5]
  end
  params:set(lfo_id(2, "rate_mod"), 1)
  params:set(lfo_id(2, "depth"), 50)
  params:set(lfo_id(2, "depth_mod"), option_index(lfo_id(2, "depth_mod"), "L1"))
  params:set(lfo_id(2, "depth_mod_amt"), 100)
  lfo_step(context)
  local depth_calls = context.calls_named("setFastLfo")
  local last_depth = depth_calls[#depth_calls].args[6]
  context.clear_engine_calls()
  lfo_step(context, 100)
  local depths = context.calls_named("setFastLfo")
  assert_true(#depths >= 4, "the depth is resent as it moves (" .. #depths .. " times)")
  for _, call in ipairs(depths) do
    local moved = math.abs(call.args[6] - last_depth)
    assert_true(moved > 0.001 and moved < 0.0011, "each resend moved the depth 1/1000 (" .. moved .. ")")
    last_depth = call.args[6]
  end
end)

test("a clocked engine LFO resyncs once a bar and at once when the beat count falls", function()
  local context = load_strata(); finish_startup(context)
  -- half a beat into a bar
  local beats = clock.get_beats()
  context.set_time(util.time() + (math.ceil(beats / 4) * 4 + 0.5 - beats) * clock.get_beat_sec())
  params:set(lfo_id(1, "mode"), option_index(lfo_id(1, "mode"), "clocked"))
  params:set(lfo_id(1, "division"), option_index(lfo_id(1, "division"), "1"))
  params:set(lfo_id(1, "dest"), destination_index("v3 pitch"))
  context.clear_engine_calls()
  params:set(lfo_id(1), 1)
  assert_equal(#calls_with(context, "syncFastLfo", 0), 1, "the start's sync")
  context.clear_engine_calls()
  context.clock.run_for(8 * clock.get_beat_sec())
  assert_equal(#calls_with(context, "syncFastLfo", 0), 2, "two bars, two syncs")
  -- the transport starts again: the beat count falls
  local real_beats = clock.get_beats
  local offset = clock.get_beats() - 0.25
  clock.get_beats = function() return real_beats() - offset end
  local ok, problem = pcall(function()
    context.clear_engine_calls(); lfo_step(context)
    local syncs = calls_with(context, "syncFastLfo", 0)
    assert_equal(#syncs, 1, "one sync at once")
    assert_near(syncs[1].args[2], local_value("S").lib.lfos.phase(1), 1e-6, "at the new phase")
    context.clear_engine_calls(); lfo_step(context, 5)
    assert_equal(#calls_with(context, "syncFastLfo", 0), 0, "then none until the next bar")
  end)
  clock.get_beats = real_beats
  if not ok then error(problem, 0) end
  -- a free engine LFO is never resynced
  params:set(lfo_id(2, "dest"), destination_index("v4 size")); params:set(lfo_id(2), 1)
  context.clear_engine_calls()
  context.clock.run_for(8 * clock.get_beat_sec())
  assert_equal(#calls_with(context, "syncFastLfo", 1), 0, "a free LFO: none after its start")
end)

test("a tempo change resends a clocked engine LFO's rate", function()
  local context = load_strata(); finish_startup(context)
  params:set(lfo_id(1, "mode"), option_index(lfo_id(1, "mode"), "clocked"))
  params:set(lfo_id(1, "division"), option_index(lfo_id(1, "division"), "1"))   -- 4 beats
  params:set(lfo_id(1, "dest"), destination_index("v3 pitch"))
  context.clear_engine_calls()
  params:set(lfo_id(1), 1)
  assert_near(context.calls_named("setFastLfo")[1].args[5], 0.5, 1e-9, "4 beats at 120 BPM: 0.5 Hz")
  context.clear_engine_calls()
  params:set("clock_tempo", 60)
  lfo_step(context)
  local calls = context.calls_named("setFastLfo")
  assert_equal(#calls, 1, "resent within one step")
  assert_near(calls[1].args[5], 0.25, 1e-9, "at 60 BPM: 0.25 Hz")
end)

-- Review Focus 1: a tempo change reaches every clocked engine LFO in the
-- step that sees it, whatever waits in the round robin
test("a tempo change resends every clocked engine LFO's rate in its step, ahead of a full round robin", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  for n, label in ipairs({ "v3 pitch", "v4 size", "v5 vfilt" }) do
    params:set(lfo_id(n, "mode"), option_index(lfo_id(n, "mode"), "clocked"))
    params:set(lfo_id(n, "division"), option_index(lfo_id(n, "division"), "1"))
    params:set(lfo_id(n, "dest"), destination_index(label)); params:set(lfo_id(n), 1)
  end
  -- 12 keys due every step: the round robin is full
  lfos.on_step(function()
    for k = 1, 12 do lfos.mark_due("probe " .. k, function() end) end
  end)
  lfo_step(context, 3)
  context.clear_engine_calls()
  params:set("clock_tempo", 60)
  lfo_step(context)
  for n = 1, 3 do
    local calls = calls_with(context, "setFastLfo", n - 1)
    assert_equal(#calls, 1, "LFO " .. n .. "'s new rate goes out in the step")
    assert_near(calls[1].args[5], 0.25, 1e-9, "LFO " .. n .. " at 60 BPM: 0.25 Hz")
  end
end)

test("the destination list keeps its indices", function()
  load_strata({ before_init = function()
    local_value("S").register_lfo_global_destination("probe", "delay_time")
  end })
  local destinations = local_value("LFO_DESTINATIONS")
  local expected = { [1] = "none", [2] = "density", [68] = "v7 scan", [69] = "v1 hist", [76] = "v1 vfilt",
    [83] = "v1 dsend", [90] = "v1 rsend", [97] = "v1 amp", [103] = "v7 amp", [104] = "macro 1", [119] = "macro 16",
    [120] = "probe" }
  for index, label in pairs(expected) do assert_equal(destinations[index].label, label, "destination " .. index) end
  assert_equal(#destinations, 120)
  assert_equal(destinations[97].resolve(), "v1_amp")
  assert_equal(destinations[120].resolve(), "delay_time")
  assert_equal(params:lookup_param(lfo_id(6, "dest")).count, 120, "every LFO offers them")
  -- every destination is a control param whose label (with ~ when it
  -- runs in the engine) fits the page's right column
  for index, destination in ipairs(destinations) do
    local resolved = destination.resolve()
    if resolved then assert_true(params:lookup_param(resolved).controlspec, resolved .. " is a control param") end
    local label = destination.label .. (destination.fast and "~" or "")
    assert_true(stubs.text_width(label) <= 49, label .. " fits its column")
  end
end)

test("a global destination's param is a control param, checked once every param exists", function()
  local ok, problem = pcall(load_strata, { before_init = function()
    local_value("S").register_lfo_global_destination("probe glob", "filter_type")
  end })
  assert_true(not ok, "an option param is refused")
  assert_true(tostring(problem):find("probe glob", 1, true), "the error names the label: " .. tostring(problem))
  load_strata()
end)

test("a global destination whose label is taken names its own register function", function()
  for _, case in ipairs({ { label = "rev mix", why = "a built-in label" }, { label = "v3 hist", why = "a per-voice label" } }) do
    local ok, problem = pcall(load_strata, { before_init = function()
      local_value("S").register_lfo_global_destination(case.label, "delay_time")
    end })
    assert_true(not ok, case.why .. " is refused")
    assert_true(tostring(problem):find("register_lfo_global_destination: the label " .. case.label .. " is taken", 1, true),
      case.why .. ": the error names register_lfo_global_destination: " .. tostring(problem))
  end
  local ok, problem = pcall(load_strata, { before_init = function()
    local_value("S").register_lfo_destination("main", "grain_size")
  end })
  assert_true(not ok and tostring(problem):find("register_lfo_destination: the label v1 main is taken", 1, true),
    "a per-voice label: register_lfo_destination: " .. tostring(problem))
  load_strata()
end)

test("a 3.3 PSET's LFO lines are imported once", function()
  local context = load_strata(); finish_startup(context)
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "old.pset"
  h.write_text(path, table.concat({ '"strata_lfo1_dest": 10', '"lfo_1": 2', '"lfo_shape_1": 4', '"lfo_mode_1": 2',
    '"lfo_free_1": 2', '"lfo_depth_1": 40', '"lfo_offset_1": -10', '"lfo_phase_1": 30',
    '"lfo_2": 1', '"lfo_shape_2": 5', '"lfo_mode_2": 1', '"lfo_clocked_2": 9', '"lfo_free_2": 8', '"lfo_depth_2": 60',
    '"lfo_3": 2', '"lfo_shape_3": 4', '"lfo_mode_3": 1', '"lfo_clocked_3": 13', "" }, "\n"))
  context.printed = {}
  params:read(path)
  assert_equal(params:get(lfo_id(1)), 1, "on")
  assert_equal(params:string(lfo_id(1, "shape")), "s&h", "random becomes s&h")
  assert_equal(params:string(lfo_id(1, "mode")), "free")
  assert_near(params:get(lfo_id(1, "rate")), 1, 1e-9, "1 / 2 s, doubled for random")
  assert_equal(params:get(lfo_id(1, "depth")), 40)
  assert_equal(params:get(lfo_id(1, "offset")), -10)
  assert_equal(params:get(lfo_id(1, "phase")), 30)
  assert_equal(params:get(lfo_id(1, "dest")), 10, "the destination as the PSET loaded it")
  assert_equal(params:get(lfo_id(2)), 0, "off")
  assert_equal(params:string(lfo_id(2, "shape")), "up")
  assert_equal(params:string(lfo_id(2, "mode")), "clocked")
  assert_equal(params:string(lfo_id(2, "division")), "1", "the same division")
  assert_near(params:get(lfo_id(2, "rate")), 0.125, 1e-9, "1 / 8 s")
  assert_equal(params:get(lfo_id(2, "depth")), 60)
  assert_equal(params:string(lfo_id(3, "division")), "2", "a clocked random LFO: half the period")
  local imported = 0
  for _, line in ipairs(context.printed) do
    if line == "imported 3.3 LFO settings" then imported = imported + 1 end
  end
  assert_equal(imported, 1, "printed once")
  -- a 3.4 PSET is left as it loads
  params:write(path)
  params:set(lfo_id(1, "depth"), 70)
  context.printed = {}
  local text = h.file_text(path) .. '"lfo_shape_1": 1\n'
  h.write_text(path, text)
  params:read(path)
  assert_equal(params:get(lfo_id(1, "depth")), 40, "the PSET's own depth")
  assert_equal(params:string(lfo_id(1, "shape")), "s&h", "and its own shape")
  for _, line in ipairs(context.printed) do assert_true(line ~= "imported 3.3 LFO settings", "nothing imported") end
end)

-- A 3.3 PSET holds three LFOs and no inputs: what it cannot hold goes to its
-- default, so the PSET plays as it did in 3.3; a silent read stays silent
test("a 3.3 PSET sets every LFO param it cannot hold to its default, and a silent read runs no action", function()
  local context = load_strata(); finish_startup(context)
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "old.pset"
  h.write_text(path, table.concat({ '"strata_lfo1_dest": ' .. destination_index("v3 pitch"), '"lfo_1": 2',
    '"lfo_shape_1": 1', '"lfo_mode_1": 2', '"lfo_free_1": 4', '"lfo_depth_1": 40', '"lfo_offset_1": 0',
    '"lfo_phase_1": 0', '"lfo_2": 1', '"lfo_shape_2": 2', '"lfo_3": 1', '"lfo_shape_3": 3', "" }, "\n"))
  -- the session's own settings the PSET cannot hold
  for n = 4, 6 do
    params:set(lfo_id(n, "dest"), destination_index("rev mix")); params:set(lfo_id(n, "shape"), 8)
    params:set(lfo_id(n, "depth"), 70); params:set(lfo_id(n, "rate"), 3); params:set(lfo_id(n, "phase"), 40)
    params:set(lfo_id(n, "mode"), 2); params:set(lfo_id(n), 1)
  end
  for n = 2, 3 do
    params:set(lfo_id(n, "rate_mod"), 2); params:set(lfo_id(n, "rate_mod_amt"), 30)
    params:set(lfo_id(n, "depth_mod"), 2); params:set(lfo_id(n, "depth_mod_amt"), -30)
  end
  params:read(path)
  for n = 4, 6 do
    for _, field in ipairs({ "dest", "shape", "mode", "rate", "division", "depth", "offset", "phase", "rate_mod",
      "rate_mod_amt", "depth_mod", "depth_mod_amt" }) do
      assert_near(params:get(lfo_id(n, field)), param_default(lfo_id(n, field)), 1e-9, "LFO " .. n .. " " .. field)
    end
    assert_equal(params:get(lfo_id(n)), 0, "LFO " .. n .. " off")
  end
  for n = 1, 3 do
    for _, field in ipairs({ "rate_mod", "rate_mod_amt", "depth_mod", "depth_mod_amt" }) do
      assert_near(params:get(lfo_id(n, field)), param_default(lfo_id(n, field)), 1e-9, "LFO " .. n .. " " .. field)
    end
  end
  assert_equal(params:get(lfo_id(1)), 1, "LFO 1 imported on")
  -- a silent read sets the params and runs no action: no engine LFO starts
  params:set(lfo_id(1), 0)
  params:set(lfo_id(2, "rate_mod"), 2)
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(params:get(lfo_id(1)), 1, "imported on, silently")
  assert_equal(params:get(lfo_id(2, "rate_mod")), 1, "its default, silently")
  assert_equal(#context.calls_named("setFastLfo") + #context.calls_named("syncFastLfo"), 0,
    "a silent read starts no engine LFO")
  -- a read that is not silent starts it
  params:set(lfo_id(1), 0)
  context.clear_engine_calls()
  params:read(path)
  assert_equal(#context.calls_named("setFastLfo"), 1, "a plain read runs the on action")
  -- a running Lua LFO a silent read turns off lets its destination go at
  -- the next step (its action, which restores at once, did not run)
  params:set("reverb_mix", 0.3)
  params:set(lfo_id(4, "dest"), destination_index("rev mix")); params:set(lfo_id(4), 1)
  params:set(lfo_id(4, "shape"), option_index(lfo_id(4, "shape"), "square")); params:set(lfo_id(4, "rate"), 0.003)
  lfo_step(context)
  assert_equal(local_value("lfo_last_dest")[4], "reverb_mix", "LFO 4 holds rev mix")
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(params:get(lfo_id(4)), 0, "off, silently")
  assert_equal(#context.calls_named("setReverb"), 0, "nothing sent by the silent read")
  lfo_step(context)
  local restores = context.calls_named("setReverb")
  assert_equal(#restores, 1, "the next step restores rev mix")
  assert_near(restores[1].args[1], 0.3, 1e-9, "to its stored value")
  assert_equal(local_value("lfo_last_dest")[4], nil, "and LFO 4 holds nothing")
end)

-- A silent PSET read sets params without their actions: what an action
-- would have done at once (a depth-0 restore, an engine LFO's stop) the
-- next step does, once
test("a silent PSET read that sets an on LFO's depth to 0 lets its destination go at the next step, once", function()
  local context = load_strata(); finish_startup(context)
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "depth0.pset"
  params:set("reverb_mix", 0.3)
  hold_lfo(1, "rev mix", 0)                       -- on, at depth 0: the PSET holds that
  params:write(path)
  params:set(lfo_id(1, "depth"), 40)
  lfo_step(context)
  assert_equal(local_value("lfo_last_dest")[1], "reverb_mix", "LFO 1 holds rev mix")
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(params:get(lfo_id(1, "depth")), 0, "depth 0, silently")
  assert_equal(params:get(lfo_id(1)), 1, "still on")
  assert_equal(#context.calls_named("setReverb"), 0, "nothing sent by the silent read")
  lfo_step(context)
  local restores = context.calls_named("setReverb")
  assert_equal(#restores, 1, "the next step restores rev mix")
  assert_near(restores[1].args[1], 0.3, 1e-9, "to its stored value")
  assert_equal(local_value("lfo_last_dest")[1], nil, "LFO 1 holds nothing")
  context.clear_engine_calls()
  lfo_step(context, 5)
  assert_equal(#context.calls_named("setReverb"), 0, "and nothing is sent in the steps after it")
end)

test("a silent PSET read that turns an engine-run LFO off stops it at the next step, once", function()
  local context = load_strata(); finish_startup(context)
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "off.pset"
  params:set(lfo_id(2, "dest"), destination_index("v3 pitch"))   -- off: the PSET holds that
  params:write(path)
  params:set(lfo_id(2), 1)
  assert_equal(#context.calls_named("setFastLfo"), 1, "on: the engine LFO starts")
  lfo_step(context)
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(params:get(lfo_id(2)), 0, "off, silently")
  assert_equal(#context.calls_named("stopFastLfo"), 0, "nothing sent by the silent read")
  lfo_step(context)
  local stops = context.calls_named("stopFastLfo")
  assert_equal(#stops, 1, "the next step stops it")
  assert_equal(stops[1].args[1], 1, "LFO 2")
  context.clear_engine_calls()
  lfo_step(context, 5)
  assert_equal(#context.calls_named("stopFastLfo") + #context.calls_named("setFastLfo"), 0, "once")
end)

test("a format 5 scene's LFO fields migrate, and LFOs 4-6 default to off", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  capture_scene(1)
  local scene = deep_copy(S.scenes[1])
  for key in pairs(deep_copy(scene.data)) do
    if key:find("^strata_lfo") then scene.data[key] = nil end
  end
  -- 3.3's fields: LFO 1 on, random free; LFO 2 off, clocked; LFO 3 has no depth
  local old = { lfo_shape_1 = 4, lfo_mode_1 = 2, lfo_clocked_1 = 13, lfo_free_1 = 4, lfo_depth_1 = 40, lfo_offset_1 = 20,
    strata_lfo1_dest = 10, lfo_1 = 2,
    lfo_shape_2 = 6, lfo_mode_2 = 1, lfo_clocked_2 = 11, lfo_free_2 = 0.5, lfo_depth_2 = 0, lfo_offset_2 = -5,
    strata_lfo2_dest = 3, lfo_2 = 1,
    lfo_shape_3 = 1, lfo_mode_3 = 2, lfo_clocked_3 = 13, lfo_free_3 = 4, lfo_offset_3 = 0, strata_lfo3_dest = 1, lfo_3 = 1 }
  for key, value in pairs(old) do scene.data[key] = value end
  migrate_scene(scene, 5)
  local data = scene.data
  local expected = {
    [1] = { shape = 6, mode = 1, division = 11, rate = 0.5, depth = 40, offset = 20, phase = 0, dest = 10, state = 1 },
    [2] = { shape = 5, mode = 2, division = 11, rate = 2, depth = 0, offset = -5, phase = 0, dest = 3, state = 0 },
    [3] = { shape = 1, mode = 1, division = 13, rate = 0.25, depth = 0, offset = 0, phase = 0, dest = 1, state = 0 },
  }
  for n = 4, 6 do
    expected[n] = { shape = 1, mode = 1, division = 13, rate = 0.25, depth = 25, offset = 0, phase = 0, dest = 1, state = 0 }
  end
  for n, fields in ipairs(expected) do
    for field, value in pairs(fields) do
      local id = field == "state" and lfo_id(n) or lfo_id(n, field)
      assert_near(data[id], value, 1e-9, "LFO " .. n .. " " .. field)
    end
    for _, field in ipairs({ "rate_mod", "depth_mod" }) do assert_equal(data[lfo_id(n, field)], 1, field .. " none") end
    for _, field in ipairs({ "rate_mod_amt", "depth_mod_amt" }) do assert_equal(data[lfo_id(n, field)], 0, field .. " 0") end
  end
  for key in pairs(data) do assert_true(not key:find("^lfo_"), "the library's field " .. key .. " is dropped") end
  assert_true(validate_scene(scene), "the migrated scene validates")
  -- a second migration changes nothing
  local once = deep_copy(scene)
  migrate_scene(scene, 5)
  for key, value in pairs(once.data) do
    if type(value) ~= "table" then assert_equal(scene.data[key], value, key .. " unchanged") end
  end
  -- recalled, it plays as 3.3 did
  S.scenes[2] = scene
  recall_scene_instant(2)
  assert_equal(params:get(lfo_id(1)), 1, "LFO 1 runs")
  assert_near(params:get(lfo_id(1, "rate")), 0.5, 1e-9)
  for n = 4, 6 do assert_equal(params:get(lfo_id(n)), 0, "LFO " .. n .. " off") end
end)

test("the six LFOs register as sources lfo1..lfo6 with their shape value", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local sources = S.lib.mod_sources.list("lfos")
  assert_equal(#sources, 6, "six sources in the lfos section")
  for n, record in ipairs(sources) do
    assert_equal(record.key, "lfo" .. n); assert_equal(record.name, "L" .. n)
    assert_equal(record.range[1], -1); assert_equal(record.range[2], 1)
    assert_equal(record.value(), 0, "0 while off")
  end
  hold_lfo(1, "rev mix", 25, true)
  lfo_step(context)
  assert_near(S.lib.mod_sources.get("lfo1").value(), -1, 1e-9, "the shape value, before the depth")
  assert_equal(S.lib.mod_sources.get("lfo1").describe(), "rev mix 25%")
  params:set(lfo_id(2, "dest"), destination_index("v3 pitch"))
  params:set(lfo_id(2, "depth_mod"), option_index(lfo_id(2, "depth_mod"), "L1"))
  assert_equal(S.lib.mod_sources.get("lfo2").describe(), "v3 pitch~ 25% <L1", "engine-run and modulated")
  params:set(lfo_id(3, "rate_mod"), option_index(lfo_id(3, "rate_mod"), "L2"))
  params:set(lfo_id(3, "depth_mod"), option_index(lfo_id(3, "depth_mod"), "L1"))
  assert_equal(S.lib.mod_sources.get("lfo3").describe(), "none 25% <L2<L1", "both inputs")
  -- the row: E3 the depth, K3 the LFO page with that LFO selected
  local row = S.lib.mod_sources.get("lfo4").row
  row.enc(3)
  assert_equal(params:get(lfo_id(4, "depth")), 28)
  row.press()
  assert_equal(S.ui_page, S.constants.UI_PAGES.index.LFO, "K3 shows the LFO page")
  assert_equal(S.selected_lfo, 4, "with LFO 4 selected")
  assert_equal(row.hints(false), "K3:lfo E3:depth")
end)

test("offset_for and m_for", function()
  load_strata()
  local lfos = local_value("S").lib.lfos
  assert_near(lfos.offset_for("reverb_mix", 0.5), 0.25, 1e-12)
  assert_near(lfos.offset_for("delay_time", -1), -0.995, 1e-12, "half of 0.01-2 s")
  assert_near(lfos.m_for("v1_grain_pitch", 1, 1.9375), 0.5, 1e-12)
  assert_near(lfos.m_for("v2_buf_pos", 0.2, 0.45), 0.5, 1e-12)
  assert_near(lfos.m_for("v3_grain_size", 0.1, 0.0755), -0.1, 1e-12)
  assert_near(lfos.m_for("v1_filter_freq", 1000, 31620), 1, 1e-3)
  assert_near(lfos.m_for("v1_amp", 0.5, 0.75), 0.5, 1e-12)
  assert_equal(lfos.m_for("v1_amp", 0, 0.5), 0, "0 when the base is 0")
  local voice, destination = lfos.fast_destination("v4_filter_freq")
  assert_equal(voice, 4); assert_equal(destination, 3)
  assert_equal(lfos.fast_destination("filter_freq"), nil, "the master filter is not a fast destination")
  assert_equal(lfos.fast_destination("v1_freq"), nil)
  assert_equal(lfos.FAST_DESTINATIONS.amp, 4)
end)

test("a Lua-run LFO restores the stored value when turned off, at depth 0 and on a destination change", function()
  local context = load_strata(); finish_startup(context)
  params:set("delay_mix", 0.2)
  hold_lfo(1, "dly mix", 40)
  context.clear_engine_calls(); lfo_step(context)
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2 + 0.4 * 0.5, 1e-9, "modulated mix")
  context.clear_engine_calls(); params:set(lfo_id(1, "depth"), 0)
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9, "depth 0 restores")
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(#context.engine_calls, 0, "a depth-0 LFO sends nothing")
  params:set(lfo_id(1, "depth"), 60); params:set(lfo_id(1, "phase"), 50)   -- value -1
  context.clear_engine_calls(); lfo_step(context)
  assert_near(context.calls_named("setDelay")[1].args[3], 0, 1e-9, "the modulated value clamps to the range")
  context.clear_engine_calls(); params:set(lfo_id(1, "dest"), destination_index("rev mix"))
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9, "a destination change restores the old one")
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(#context.calls_named("setDelay"), 0, "the old destination is left alone")
  assert_near(context.calls_named("setReverb")[1].args[1], util.clamp(params:get("reverb_mix") - 0.3, 0, 1), 1e-9,
    "the new one is modulated")
  context.clear_engine_calls(); params:set(lfo_id(1, "dest"), 1)   -- none
  assert_near(context.calls_named("setReverb")[1].args[1], params:get("reverb_mix"), 1e-9, "none restores")
  lfo_step(context, 3)
  assert_equal(#context.calls_named("setReverb"), 1, "and then sends nothing")
  hold_lfo(1, "dly mix", 40); lfo_step(context)
  context.clear_engine_calls(); params:set(lfo_id(1), 0)
  assert_equal(#context.calls_named("setDelay"), 1, "off restores")
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9)
end)

test("a full-depth LFO clamps its destination to both ends of the range (#50)", function()
  local context = load_strata(); finish_startup(context)
  params:set("delay_feedback", 0.95)              -- dly fdbk, 0-0.95
  hold_lfo(1, "dly fdbk", 100, true)              -- value -1: 0.475 sent
  lfo_step(context)
  params:set(lfo_id(1, "phase"), 0)               -- value +1: 0.95 + 0.475
  context.clear_engine_calls(); lfo_step(context)
  assert_near(context.calls_named("setDelay")[1].args[2], 0.95, 1e-9, "clamped at the top of the range")
  params:set("delay_feedback", 0); params:set(lfo_id(1, "phase"), 50)   -- value -1: 0 - 0.475
  context.clear_engine_calls(); lfo_step(context)
  local calls = context.calls_named("setDelay")
  assert_near(calls[#calls].args[2], 0, 1e-9, "clamped at the bottom of the range")
  assert_near(params:get("delay_feedback"), 0, 1e-9, "param value untouched")
end)

test("a restore is sent even when the engine already holds the stored value", function()
  for _, ending in ipairs({ "off", "depth 0" }) do
    local context = load_strata(); finish_startup(context)
    params:set("filter_mix", 0.5)
    -- value +1 at depth 50 with an offset of -25: m = 0.5 - 0.5 = 0, so the
    -- engine keeps the stored 0.5 while the LFO holds the destination
    hold_lfo(1, "filt mix", 50); params:set(lfo_id(1, "offset"), -25)
    context.clear_engine_calls(); lfo_step(context, 3)
    assert_equal(#context.calls_named("setFilter"), 0, "nothing moved, nothing sent")
    assert_equal(local_value("lfo_last_dest")[1], "filter_mix", "the LFO holds the destination")
    context.clear_engine_calls()
    if ending == "off" then params:set(lfo_id(1), 0) else params:set(lfo_id(1, "depth"), 0) end
    local calls = context.calls_named("setFilter")
    assert_equal(#calls, 1, ending .. ": the restore sends")
    assert_near(calls[1].args[4], 0.5, 1e-9, ending .. ": the stored value")
  end
end)

-- The on/off param's bang (a PSET or scene that sets it on again) restarts
-- the phase, in Lua and in the engine (#251)
test("setting a running LFO on again restarts its phase, and an engine LFO's with it (#251)", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  params:set(lfo_id(1, "rate"), 0.25); params:set(lfo_id(1, "phase"), 10); params:set(lfo_id(1), 1)
  params:set(lfo_id(2, "dest"), destination_index("v3 pitch"))
  params:set(lfo_id(2, "rate"), 0.25); params:set(lfo_id(2), 1)
  context.clock.run_for(1)
  assert_near(lfos.phase(1), 0.35, 1e-6, "the phase has moved")
  params:lookup_param(lfo_id(1)):bang()
  assert_near(lfos.phase(1), 0.1, 1e-9, "a bang restarts it at the phase param")
  context.clear_engine_calls()
  params:lookup_param(lfo_id(2)):bang()
  local syncs = calls_with(context, "syncFastLfo", 1)
  assert_equal(#syncs, 1, "the engine LFO is synced to the restart")
  assert_near(syncs[1].args[2], 0, 1e-9, "at its start")
  assert_equal(#context.calls_named("setFastLfo"), 0, "its node is kept")
end)

test("main destination follows a voice's source and restores the old param", function()
  local context = load_strata(); finish_startup(context)
  hold_lfo(2, "v1 main", 100)
  lfo_step(context)
  assert_equal(local_value("lfo_last_dest")[2], "v1_freq")
  assert_true(not local_value("S").lib.lfos.is_engine_run(2), "v<i> main runs in Lua")
  params:set("v1_source", 2); context.clear_engine_calls(); lfo_step(context)
  local voice_calls = context.calls_named("setVoiceParam")
  assert_equal(voice_calls[1].args[2], "freq"); assert_near(voice_calls[1].args[3], params:get("v1_freq"), 1e-9)
  assert_equal(local_value("lfo_last_dest")[2], "v1_buf_pos", "a buffer voice's position, still in Lua")
end)

test("LFOs on params of one command, or on one param, do not undo each other", function()
  local context = load_strata(); finish_startup(context)
  params:set("filter_freq", 1000); params:set("filter_res", 0.5)
  hold_lfo(1, "filt freq", 20); hold_lfo(2, "filt res", 20)
  context.clear_engine_calls(); lfo_step(context)
  local calls = context.calls_named("setFilter")
  assert_near(calls[#calls].args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "LFO 2 keeps LFO 1's filter freq")
  assert_near(calls[#calls].args[2], 0.5 + 0.2 * 0.5, 1e-6, "and adds its res")
  context.clear_engine_calls(); params:set("filter_res", 0.3)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "a res edit keeps the freq")
  -- two LFOs on one destination add up; turning one off leaves the other's offset
  params:set(lfo_id(2, "dest"), destination_index("filt freq"))
  context.clear_engine_calls(); lfo_step(context)
  calls = context.calls_named("setFilter")
  assert_near(calls[#calls].args[1], 1000 + 0.4 * 0.5 * 19980, 1e-6, "offsets add")
  context.clear_engine_calls(); params:set(lfo_id(2), 0)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "LFO 1 still applies")
  -- master density reaches every running voice's grain density
  params:set(lfo_id(1, "dest"), destination_index("density")); params:set("master_density", 1)
  context.clear_engine_calls(); lfo_step(context)
  local voices = local_value("voices")
  for _, density_call in ipairs(context.calls_named("setGrainParam")) do
    local voice_idx = density_call.args[1] + 1
    assert_true(voices[voice_idx].active, "only running voices")
    assert_near(density_call.args[3], voices[voice_idx].grain.density * (1 + 0.19), 1e-6, "modulated density")
  end
  assert_true(#context.calls_named("setGrainParam") >= 1, "a running voice got its density")
  assert_near(params:get("master_density"), 1, 1e-9, "master density param untouched")
end)

-- sync_voice_values_to_engine sends the stored density, so the modulated
-- value sent before the restart must be forgotten (#50)
test("a restarted voice's grain density scales from its stored value until the next LFO step (#50)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  params:set("v1_grain_density", 20); params:set("master_density", 1)
  hold_lfo(1, "v1 dens", 50)
  lfo_step(context)
  assert_equal(voices[1].grain.density, 20, "the stored density is untouched")
  toggle_voice(1); toggle_voice(1)
  context.clear_engine_calls()
  params:set("master_density", 1.5)
  local density_calls = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "grainDensity" then table.insert(density_calls, call) end
  end
  assert_equal(#density_calls, 1, "master density resends voice 1's grain density")
  assert_near(density_calls[1].args[3], 20 * 1.5, 1e-6, "from the stored density, not the modulated one")
end)

test("param actions under a running LFO send the modulated value (drift, edits)", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_source", 2)
  params:set("v1_buf_pos", 0.4)
  hold_lfo(1, "v1 main", 50)                  -- a buffer voice's main is its position, in Lua
  lfo_step(context)
  math.randomseed(5)
  context.clear_engine_calls(); drift_update()
  local sent
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "bufPos" then sent = call.args[3] end
  end
  assert_true(params:get("v1_buf_pos") ~= 0.4, "the drift moved the stored position")
  assert_near(sent, params:get("v1_buf_pos") + 0.25, 1e-9, "drift sends the position with the LFO offset")
  params:set("filter_freq", 1000); hold_lfo(2, "filt freq", 20); lfo_step(context)
  context.clear_engine_calls(); params:set("filter_freq", 2000)
  assert_near(context.calls_named("setFilter")[1].args[1], 2000 + 0.2 * 0.5 * 19980, 1e-6, "an edit keeps the offset")
  context.clear_engine_calls(); params:set("filter_res", 0.3)
  assert_near(context.calls_named("setFilter")[1].args[2], 0.3, 1e-9, "an unmodulated param sends its value")
end)

test("LFO steps skip sends below 1/1000 of the range; restores always send", function()
  local context = load_strata(); finish_startup(context)
  params:set("filter_mix", 0.5); params:set(lfo_id(1, "dest"), destination_index("filt mix"))
  params:set(lfo_id(1, "rate"), 1 / 300); params:set(lfo_id(1, "phase"), 75)   -- a 300 s sine from its trough
  params:set(lfo_id(1, "depth"), 100); params:set(lfo_id(1), 1)
  context.clear_engine_calls()
  context.clock.run_for(10)
  local calls = context.calls_named("setFilter")
  assert_true(#calls >= 5 and #calls <= 15, "a slow LFO sends rarely (" .. #calls .. " sends)")
  for index = 2, #calls do
    assert_true(math.abs(calls[index].args[4] - calls[index - 1].args[4]) >= 0.001 - 1e-12, "each send moves >= 1/1000")
  end
  context.clear_engine_calls(); params:set(lfo_id(1), 0)
  calls = context.calls_named("setFilter")
  assert_equal(#calls, 1, "the restore sends"); assert_near(calls[1].args[4], 0.5, 1e-9, "the stored mix")
  -- a fast LFO sends on every step
  params:set(lfo_id(1, "shape"), option_index(lfo_id(1, "shape"), "up"))
  params:set(lfo_id(1, "rate"), 10); params:set(lfo_id(1), 1)
  context.clear_engine_calls(); lfo_step(context, 20)
  assert_equal(#context.calls_named("setFilter"), 20, "large steps all sent")
end)

-- The threshold is measured on the destination's warp: on an exponential
-- range (v1_freq, 20-2000 Hz) a slow LFO sends steps even in octaves (#406)
test("a slow LFO on an exponential destination sends steps of at most 10.8 cents (#406)", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_freq", 60); params:set(lfo_id(1, "dest"), destination_index("v1 main"))
  params:set(lfo_id(1, "rate"), 1 / 16); params:set(lfo_id(1, "phase"), 75)
  params:set(lfo_id(1, "depth"), 1); params:set(lfo_id(1), 1)
  context.clear_engine_calls()
  context.clock.run_for(16)
  local sent = {}
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 0 and call.args[2] == "freq" then table.insert(sent, call.args[3]) end
  end
  -- 60 Hz +/- 9.9 Hz: 1/1000 of the range's 6.64 octaves is 7.97 cents, and
  -- one 1/48 s step moves at most 2.8 cents (9.9 Hz x 2 pi / 16 / 48 at 50.1 Hz)
  assert_true(#sent >= 100, "the glide is sent in small steps (" .. #sent .. " sends)")
  local largest = 0
  for index = 2, #sent do
    local cents = math.abs(1200 * math.log(sent[index] / sent[index - 1]) / math.log(2))
    assert_true(cents >= 7.97, "send " .. index .. " moves at least 1/1000 of the octaves (" .. cents .. ")")
    largest = math.max(largest, cents)
  end
  assert_true(largest <= 10.8, "the largest step is " .. largest .. " cents")
end)

test("an LFO step never changes its destination's controlspec (#406)", function()
  local context = load_strata(); finish_startup(context)
  local spec = params:lookup_param("filter_mix").controlspec
  assert_near(spec.step, 0.01, 1e-12, "filter mix steps by 0.01")
  params:set("filter_mix", 0.5)
  params:set(lfo_id(1, "dest"), destination_index("filt mix"))
  params:set(lfo_id(1, "shape"), option_index(lfo_id(1, "shape"), "up"))
  params:set(lfo_id(1, "rate"), 10); params:set(lfo_id(1, "depth"), 100); params:set(lfo_id(1), 1)
  spec.unmap = function() error("unmap boom") end
  local ok, problem = pcall(function()
    context.clear_engine_calls(); lfo_step(context, 3)
    assert_near(spec.step, 0.01, 1e-12, "the live spec keeps its step")
    assert_equal(#context.calls_named("setFilter"), 3, "and every step that moved far enough was sent")
  end)
  spec.unmap = nil
  if not ok then error(problem, 0) end
end)

-- One LFO's failing step leaves the others and the clock running (#517)
test("an error inside an LFO step is printed once and the LFOs keep stepping (#517)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local index = destination_index("filt freq")
  local destination = S.LFO_DESTINATIONS[index]
  local real_resolve = destination.resolve
  local failure = "lfo step boom"
  destination.resolve = function() if failure then error(failure) end return real_resolve() end
  local ok, problem = pcall(function()
    hold_lfo(1, "filt freq", 50); hold_lfo(2, "rev mix", 50)
    context.printed = {}
    context.clear_engine_calls(); lfo_step(context, 5)
    local count, traced = 0, false
    for _, line in ipairs(context.printed) do
      if line:find("strata: LFO 1 step failed: ", 1, true) == 1 then
        count = count + 1
        traced = traced or line:find("stack traceback", 1, true) ~= nil
      end
    end
    assert_equal(count, 1, "the same error on every step prints once")
    assert_true(traced, "with its traceback")
    assert_true(#context.calls_named("setReverb") >= 1, "LFO 2 keeps stepping")
    failure = nil
    context.clear_engine_calls(); lfo_step(context)
    assert_true(#context.calls_named("setFilter") >= 1, "the next good step of LFO 1 sends")
    local function reports()
      local printed = 0
      for _, line in ipairs(context.printed) do
        if line:find("strata: LFO 1 step failed: ", 1, true) == 1 then printed = printed + 1 end
      end
      return printed
    end
    failure = "lfo step boom"
    lfo_step(context, 2)
    assert_equal(reports(), 2, "the same error after a good step prints again, once")
    failure = "another lfo boom"
    lfo_step(context)
    assert_equal(reports(), 3, "a different message prints at once")
  end)
  destination.resolve = real_resolve
  if not ok then error(problem, 0) end
  h.claim_script_errors(context, 3, "strata: LFO 1 step failed: ", "another lfo boom")
end)

-- norns frees the engine before cleanup() (#461): the step stops the clock;
-- an engine LFO's node is gone with the engine, so nothing stops it
test("cleanup stops the clock and sends no stopFastLfo", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.lfo_clock ~= nil, "the clock runs from the start step")
  params:set("filter_freq", 800); hold_lfo(1, "filt freq", 50)
  params:set(lfo_id(2, "dest"), destination_index("v3 pitch")); params:set(lfo_id(2), 1)
  lfo_step(context)
  context.clear_engine_calls(); cleanup()
  assert_equal(S.lfo_clock, nil, "the clock is canceled")
  assert_equal(#context.calls_named("stopFastLfo"), 0, "no stopFastLfo: the engine is gone by then")
  assert_equal(context.clock.pending_count(), 0, "no clock left")
  context.clear_engine_calls()
  context.clock.run_for(1)
  assert_equal(#context.calls_named("setFastLfo") + #context.calls_named("setFilter"), 0, "nothing steps after cleanup")
end)

-- #316: every control param with a sender reaches the engine only through
-- send_param_to_engine, so an LFO's offset is on what it sends
test("every control param with a sender sends its LFO-offset value; one without a sender never calls the engine", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, 7 do
    if not local_value("voices")[voice_idx].active then toggle_voice(voice_idx) end
  end
  local function signature(calls)
    local parts = {}
    for _, call in ipairs(calls) do
      local args = {}
      for index, value in ipairs(call.args) do
        args[index] = type(value) == "number" and string.format("%.9g", value) or tostring(value)
      end
      parts[#parts + 1] = call.name .. "(" .. table.concat(args, ",") .. ")"
    end
    return parts
  end
  local function contains_all(got, expected)
    local present = {}
    for _, text in ipairs(got) do present[text] = true end
    for _, text in ipairs(expected) do
      if not present[text] then return false, text end
    end
    return true
  end
  local function other_value(param)
    local spec = param.controlspec
    local value = spec:map(0.35)
    if math.abs(value - params:get(param.id)) < 1e-9 then value = spec:map(0.65) end
    return value
  end
  local checked = 0
  for _, param in ipairs(params.params) do
    -- a macro's sender takes an LFO's value for its targets' round robin
    -- sends (lib/macros.lua, macros_test.lua), never an engine call
    if param.t == params.tCONTROL and param.id:sub(1, 6) ~= "strata" and not param.id:match("^macro_%d+$") then
      local sender = S.engine_senders[param.id]
      local value = other_value(param)
      if sender then
        S.lfo_last_dest[1], S.lfo_scaled[1] = param.id, 0.2
        context.clear_engine_calls()
        params:set(param.id, value)
        local got = signature(context.engine_calls)
        local minval, maxval = param_range(param.id)
        local stored = params:get(param.id)
        S.lfo_last_dest[1], S.lfo_scaled[1] = nil, nil
        context.clear_engine_calls()
        sender(math.max(minval, math.min(maxval, stored + 0.2 * 0.5 * (maxval - minval))))
        local expected = signature(context.engine_calls)
        local found, missing = contains_all(got, expected)
        assert_true(#expected > 0 and found, param.id .. " sends the LFO-offset value, never the plain one: " .. tostring(missing)
          .. " is not among " .. table.concat(got, ";"))
        checked = checked + 1
      else
        context.clear_engine_calls()
        params:set(param.id, value)
        assert_equal(#context.engine_calls, 0, param.id .. " has no sender and makes no engine call")
      end
    end
  end
  assert_true(checked > 200, "many control params have senders: " .. checked)
  S.lfo_last_dest[1], S.lfo_scaled[1] = nil, nil
end)

-- AGENTS.md: a control param's action never calls the engine; an engine
-- LFO's control params reach it at the next step
test("an engine-run LFO's rate, depth, offset, phase and amounts call no engine command in their sets", function()
  local context = load_strata(); finish_startup(context)
  params:set(lfo_id(2, "dest"), destination_index("v3 pitch")); params:set(lfo_id(2), 1)
  params:set(lfo_id(2, "rate_mod"), 2); params:set(lfo_id(2, "depth_mod"), 2)
  lfo_step(context)
  local edits = { { "rate", 2, "rate", 2 }, { "depth", 60, "depth", 0.6 }, { "offset", 20, "offset", 0.4 },
    { "phase", 30 }, { "rate_mod_amt", 40 }, { "depth_mod_amt", -40 } }
  for _, edit in ipairs(edits) do
    context.clear_engine_calls()
    params:set(lfo_id(2, edit[1]), edit[2])
    assert_equal(#context.engine_calls, 0, edit[1] .. ": no engine command inside the set")
    lfo_step(context)
    local calls = context.calls_named("setFastLfo")
    if edit[1] == "phase" then
      local syncs = calls_with(context, "syncFastLfo", 1)
      assert_equal(#syncs, 1, "phase: the next step syncs")
      assert_near(syncs[1].args[2], local_value("S").lib.lfos.phase(2), 1e-6, "to the new phase")
    else
      assert_equal(#calls, 1, edit[1] .. ": the next step sends it")
    end
    if edit[3] == "rate" then assert_near(calls[1].args[5], edit[4], 1e-9, "the new rate") end
    if edit[3] == "depth" then assert_near(calls[1].args[6], edit[4], 1e-9, "the new depth") end
    if edit[3] == "offset" then assert_near(calls[1].args[7], edit[4], 1e-9, "the new offset") end
  end
end)

test("an edit of the LFO shape, rate, division or phase ends the randomize undo (#557)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for _, id in ipairs({ lfo_id(1, "shape"), lfo_id(1, "rate"), lfo_id(1, "division"), lfo_id(1, "phase") }) do
    local function other(value) return math.abs(value - 2) < 0.01 and 3 or 2 end   -- (an exp rate maps 2 near 2)
    local function spec()
      return { page = S.constants.UI_PAGES.index.LFO, section = "lfo", draws = {
        { id = id, draw = function() return other(params:get(id)) end } } }
    end
    S.lib.mutation.randomize(spec())
    assert_true(S.undo ~= nil, id .. ": an undo is held")
    params:set(id, other(params:get(id)))
    assert_equal(S.undo, nil, id .. ": an edit ends the undo")
    local before = params:get(id)
    S.lib.mutation.randomize(spec())
    assert_true(params:get(id) ~= before, id .. ": the randomize sets it")
    S.lib.mutation.undo()
    assert_near(params:get(id), before, 1e-9, id .. ": the undo restores it")
  end
end)

-- 3.4 (0b, then 1b): the LFOs' scene fields live in lib/lfos.lua
test("the LFO scene fields: per LFO in recall order, the state last, with the ranges validate_scene checks", function()
  load_strata()
  local S = local_value("S")
  local fields = S.lib.lfos.SCENE_FIELDS
  local per_lfo = { "shape", "mode", "division", "rate", "depth", "offset", "phase", "rate_mod", "rate_mod_amt",
    "depth_mod", "depth_mod_amt", "dest" }
  assert_equal(#fields, 6 * (#per_lfo + 1), "13 fields per LFO")
  local continuous = { rate = true, depth = true, offset = true }
  local ranges = { rate = { 0.003, 50 }, depth = { 0, 100 }, offset = { -100, 100 }, phase = { 0, 100 },
    rate_mod_amt = { -100, 100 }, depth_mod_amt = { -100, 100 } }
  for n = 1, 6 do
    for index, field in ipairs(per_lfo) do
      local record = fields[(n - 1) * 13 + index]
      assert_equal(record.id, lfo_id(n, field), "LFO " .. n .. " field " .. index)
      assert_equal(record.continuous, continuous[field] == true, record.id .. " continuous")
      assert_equal(record.lfo, continuous[field] and n or nil, record.id .. " belongs to its LFO")
      assert_equal(record.stop_target, field == "depth" and 0 or nil, record.id .. " stop target")
      assert_equal(record.default, param_default(record.id), record.id .. "'s default is its param's")
      assert_equal(record.range and record.range[1], ranges[field] and ranges[field][1], record.id .. " range min")
      assert_equal(record.range and record.range[2], ranges[field] and ranges[field][2], record.id .. " range max")
    end
    local state = fields[n * 13]
    assert_equal(state.id, lfo_id(n), "the state last")
    assert_equal(state.continuous, false); assert_equal(state.default, 0)
    assert_equal(state.range[1], 0); assert_equal(state.range[2], 1)
  end
  for index, field in ipairs(fields) do
    assert_true(rawequal(S.SCENE_GLOBAL_PARAMS[17 + index], field), "global " .. (17 + index) .. " is the LFO field itself")
  end
  -- a field outside its range fails the scene
  capture_scene(1)
  local scene = deep_copy(S.scenes[1])
  assert_true(validate_scene(scene))
  for id, bad in pairs({ [lfo_id(4, "rate")] = 60, [lfo_id(2, "phase")] = -1, [lfo_id(6)] = 2,
    [lfo_id(3, "depth_mod")] = 4, [lfo_id(1, "rate_mod")] = 2 }) do
    local broken = deep_copy(scene)
    broken.data[id] = bad
    assert_true(not validate_scene(broken), id .. " = " .. bad .. " is refused")
  end
end)

test("the LFO clock invariant holds from the start step to cleanup", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local check
  for _, record in ipairs(S.registry.invariants) do
    if record.name == "lfo clock" then check = record.fn end
  end
  assert_true(check ~= nil, "registered")
  assert_equal(check(), nil, "it holds while the clock runs")
  local clock_id = S.lfo_clock
  S.lfo_clock = nil
  assert_true(check() ~= nil, "a lost clock breaks it")
  S.lfo_clock = clock_id
  -- a clock canceled (or ended) behind the module's back, its id still kept
  clock.cancel(clock_id)
  local broken = check()
  assert_true(broken ~= nil and tostring(broken):find("not running", 1, true) ~= nil,
    "a canceled clock whose id is still in S.lfo_clock breaks it: " .. tostring(broken))
  -- the module's own stop leaves a state it accepts
  S.lib.lfos.stop_clock()
  assert_equal(S.lfo_clock, nil, "stop_clock forgets the clock")
  assert_equal(check(), nil, "stopped by the module: it holds")
  cleanup()
  assert_equal(check(), nil, "it holds after cleanup")
end)

test("a Lua-run LFO is compared with the value waiting in the send budget, not the delivered one (#591)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local budget = S.constants.ENGINE_BUDGET
  hold_lfo(1, "rev mix", 25)
  lfo_step(context, 2)
  local high = S.engine_param_values.reverb_mix
  params:set(lfo_id(1, "phase"), 50); lfo_step(context, 2)
  local low = S.engine_param_values.reverb_mix
  assert_true(math.abs(high - low) > 0.05, "the square's two values are far apart")
  -- a fresh window, so the fill and the two steps below stay inside one
  context.set_time((math.floor(util.time() / budget.window_seconds) + 1) * budget.window_seconds + 0.001)
  -- fill the window's budget with counted sends of another param
  for _ = 1, budget.messages_per_window do S.lib.engine_sync.send_engine_value("reverb_size", 0.5) end
  context.clear_engine_calls()
  params:set(lfo_id(1, "phase"), 0); lfo_step(context)
  assert_equal(S.lib.engine_sync.budget_state().pending, 1, "the high value waits")
  params:set(lfo_id(1, "phase"), 50); lfo_step(context)   -- back to the delivered value
  context.clock.run_for(budget.window_seconds * 2)
  for _, call in ipairs(context.calls_named("setReverb")) do
    assert_true(math.abs(call.args[1] - high) > 0.01, "the engine never gets the stale high value (" .. call.args[1] .. ")")
  end
  assert_near(S.engine_param_values.reverb_mix, low, 1e-9, "the engine ends on the value the LFO wants")
end)

end

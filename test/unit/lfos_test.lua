-- test/unit/lfos_test.lua
-- The six LFOs (lib/lfos.lua): shapes, phases, LFO-to-LFO modulation, the
-- 48 Hz clock and its round robin of sends, Lua-run LFOs modulating around
-- the stored value, engine-run LFOs on the five fast destinations, the
-- destination list, silent PSET reads, the sources,
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


-- LFO n's home routing (the matrix's slot 16 + n, the groundwork before
-- 3.8) aimed at entry index of the destination list (1: none), and the
-- entry it is aimed at now
local function aim_index(n, index)
  local S = local_value("S")
  assert_true(S.lib.matrix.set_home(n, S.lib.lfos.destination_id(index)), "LFO " .. n .. " aimed")
end
local function home_index(n) return local_value("S").lib.lfos.destination_index(n) end
-- The param id LFO n's home resolves to now (nil: none)
local function resolved(n) return local_value("S").lib.lfos.destination(n).resolve() end

-- LFO n's home routing aimed at the destination labeled `label`
local function aim(n, label) aim_index(n, destination_index(label)) end

-- Run the clocks until the LFO clock has stepped `count` times (default 1)
local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

-- LFO n on `label` with a square shape held at its top (value +1) or bottom
-- (value -1): the slowest rate moves the phase 6.3e-5 a step
local function hold_lfo(n, label, depth, low)
  aim(n, label)
  params:set(lfo_id(n, "shape"), option_index(lfo_id(n, "shape"), "square"))
  params:set(lfo_id(n, "rate"), 0.003)
  params:set(lfo_id(n, "phase"), low and 50 or 0)
  params:set(lfo_id(n, "depth"), depth)
  params:set(lfo_id(n), 1)
end

-- A round-robin key standing in for a real send: it has an engine sender
-- (that sends nothing), so it reaches the engine and takes a slot (a key
-- with no sender takes none, #646)
local function probe_key(k)
  local key = "probe " .. k
  local senders = local_value("S").engine_senders
  if senders[key] == nil then senders[key] = function() end end
  return key
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
  aim(1, "rev mix")
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
  assert_near(local_value("S").lib.matrix.offset("reverb_mix"), 0.225, 1e-6, "the matrix sums its home: 0.45 x 0.5")
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
    aim(n, label)
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
      local key = probe_key(k)
      lfos.mark_due(key, function() table.insert(sent, key) end)
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

-- #644: a due key that reaches no engine (a stopped voice's param:
-- S.lib.engine_sync.reaches_engine) still runs in its turn, so its value
-- is recorded, but takes none of the step's 12 slots

-- Fourteen voice-gated params of voice v (their senders send only while it runs)
local function voice_send_ids(v)
  local ids = {}
  for _, key in ipairs({ "grain_size", "grain_density", "grain_pitch", "grain_spread", "buf_pos", "buf_rate", "buf_scan",
    "mod_amp_amt_1", "mod_amp_amt_2", "mod_amp_amt_3", "mod_freq_amt_1", "mod_freq_amt_2", "mod_freq_amt_3",
    "mod_speed" }) do
    ids[#ids + 1] = "v" .. v .. "_" .. key
  end
  return ids
end

-- Voice 1 running, voice 2 stopped
local function one_running_one_stopped(S)
  if not S.voices[1].active then toggle_voice(1) end
  if S.voices[2].active then toggle_voice(2) end
end

test("a stopped voice's due sends take none of a step's 12; a running voice's stay capped at 12 (#644)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local lfos = S.lib.lfos
  one_running_one_stopped(S)
  local ran = { [1] = 0, [2] = 0 }
  local function mark(id, v)
    lfos.mark_due(id, function()
      ran[v] = ran[v] + 1
      S.lib.engine_sync.send_engine_value(id, params:get(id))
    end)
  end
  local stopped, running = voice_send_ids(2), voice_send_ids(1)
  for k = 1, 12 do mark(stopped[k], 2) end   -- first in the round robin
  for k = 1, 13 do mark(running[k], 1) end
  context.clear_engine_calls()
  lfo_step(context)
  assert_equal(ran[2], 12, "every stopped voice's send ran in its turn")
  assert_equal(ran[1], 12, "and the running voice's took all 12 slots")
  lfo_step(context)
  assert_equal(ran[1], 13, "its 13th went in the next step, as before")
  assert_equal(ran[2], 12, "nothing ran twice")
  for _, call in ipairs(context.engine_calls) do
    assert_true(call.args[1] ~= 1, "nothing reached stopped voice 2: " .. call.name)
  end
  assert_equal(S.lib.engine_sync.expected_value(stopped[1]), params:get(stopped[1]), "its values are recorded")
end)

test("an LFO on a stopped voice leaves the running voice its 12; the voice's start, then its next step (#644)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local lfos, sync = S.lib.lfos, S.lib.engine_sync
  one_running_one_stopped(S)
  params:set("v2_grain_density", 20)
  -- LFO 1 rising at 1 Hz on voice 2's density, at depth 20: due every step
  aim(1, "v2 dens")
  params:set(lfo_id(1, "shape"), option_index(lfo_id(1, "shape"), "up"))
  params:set(lfo_id(1, "rate"), 1); params:set(lfo_id(1, "depth"), 20)
  params:set(lfo_id(1), 1)
  -- after the LFO's key, 12 of running voice 1's sends due every step
  local running, ran = voice_send_ids(1), 0
  lfos.on_step(function()
    for k = 1, 12 do
      local id = running[k]
      lfos.mark_due(id, function() ran = ran + 1; sync.send_engine_value(id, params:get(id)) end)
    end
  end)
  context.clear_engine_calls()
  for step = 1, 3 do
    ran = 0
    lfo_step(context)
    assert_equal(ran, 12, "step " .. step .. ": the running voice's 12 all go")
    -- 20 + value x 0.2 x half of 1-100
    assert_near(sync.expected_value("v2_grain_density"), 20 + 9.9 * lfos.value(1), 1e-9,
      "step " .. step .. ": the stopped voice's LFO value is recorded")
  end
  local function densities() return calls_with(context, "setGrainParam", 1) end
  assert_equal(#densities(), 0, "nothing reached the stopped voice")
  -- the start sends the density with the home's offset at the last step
  -- (the matrix's extra offset: the groundwork before 3.8, ruling 18); the
  -- next step the value the LFO has moved to, once
  toggle_voice(2)
  local sent = {}
  for _, call in ipairs(densities()) do
    if call.args[2] == "grainDensity" then sent[#sent + 1] = call.args[3] end
  end
  local master = params:get("master_density")
  assert_equal(#sent, 1, "the start sends one density")
  assert_near(sent[1], (20 + 9.9 * lfos.value(1)) * master, 1e-9, "the modulated one")
  lfo_step(context)
  sent = {}
  for _, call in ipairs(densities()) do
    if call.args[2] == "grainDensity" then sent[#sent + 1] = call.args[3] end
  end
  assert_equal(#sent, 2, "the next step sends one more")
  assert_near(sent[2], (20 + 9.9 * lfos.value(1)) * master, 1e-9, "the value the LFO has now")
  params:set(lfo_id(1), 0)
end)

test("a Lua-run LFO above 10 Hz plays at 10 Hz", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  aim(1, "rev mix")
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
  aim(1, "v3 pitch")
  local call = context.calls_named("setFastLfo")[1]
  assert_near(call.args[5], 20, 1e-9, "an engine LFO runs at 20 Hz")
  assert_true(not lfos.capped(1), "and is not capped")
end)

test("an LFO on a fast destination runs in the engine", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  aim(1, "v3 pitch")
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
  assert_equal(local_value("S").lib.matrix.offset("v3_grain_pitch"), 0, "no offset from the matrix")
  context.clear_engine_calls()
  aim(1, "v3 size")
  assert_equal(#context.calls_named("setFastLfo"), 1, "another fast destination: one setFastLfo")
  assert_equal(context.calls_named("setFastLfo")[1].args[3], 2, "size")
  assert_equal(#context.calls_named("stopFastLfo"), 0, "no stop")
  context.clear_engine_calls()
  params:set("reverb_mix", 0.3)
  aim(1, "rev mix")
  assert_equal(#calls_with(context, "stopFastLfo", 0), 1, "a Lua destination stops the engine LFO")
  assert_true(not lfos.is_engine_run(1))
  lfo_step(context)
  assert_equal(#context.calls_named("setReverb"), 1, "and Lua's sends begin")
  context.clear_engine_calls()
  params:set(lfo_id(1), 0)
  lfo_step(context)   -- the matrix's next step gives a Lua destination back (ruling 17)
  local restores = context.calls_named("setReverb")
  assert_equal(#restores, 1, "off: the stored value sent once")
  assert_near(restores[1].args[1], 0.3, 1e-9)
  lfo_step(context, 3)
  assert_equal(#context.calls_named("setReverb"), 1, "and nothing after")
  -- every fast destination, the voice's amp and filter cutoff included
  for label, destination in pairs({ ["v1 pitch"] = 0, ["v2 pos"] = 1, ["v4 size"] = 2, ["v5 vfilt"] = 3, ["v7 amp"] = 4 }) do
    context.clear_engine_calls()
    aim(2, label); params:set(lfo_id(2), 1)
    local call = context.calls_named("setFastLfo")[1]
    assert_equal(call.args[2], tonumber(label:match("^v(%d)")) - 1, label .. ": its voice")
    assert_equal(call.args[3], destination, label .. ": its destination")
    params:set(lfo_id(2), 0)
  end
  -- depth 0 stops it, as it restores a Lua destination
  aim(1, "v3 pitch"); params:set(lfo_id(1), 1)
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
  aim(2, "v2 pitch")
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
  aim(1, "v3 pitch")
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
  aim(2, "v4 size"); params:set(lfo_id(2), 1)
  context.clear_engine_calls()
  context.clock.run_for(8 * clock.get_beat_sec())
  assert_equal(#calls_with(context, "syncFastLfo", 1), 0, "a free LFO: none after its start")
end)

test("a tempo change resends a clocked engine LFO's rate", function()
  local context = load_strata(); finish_startup(context)
  params:set(lfo_id(1, "mode"), option_index(lfo_id(1, "mode"), "clocked"))
  params:set(lfo_id(1, "division"), option_index(lfo_id(1, "division"), "1"))   -- 4 beats
  aim(1, "v3 pitch")
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

-- A tempo change reaches every clocked engine LFO in the
-- step that sees it, whatever waits in the round robin
test("a tempo change resends every clocked engine LFO's rate in its step, ahead of a full round robin", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  for n, label in ipairs({ "v3 pitch", "v4 size", "v5 vfilt" }) do
    params:set(lfo_id(n, "mode"), option_index(lfo_id(n, "mode"), "clocked"))
    params:set(lfo_id(n, "division"), option_index(lfo_id(n, "division"), "1"))
    aim(n, label); params:set(lfo_id(n), 1)
  end
  -- 12 keys due every step: the round robin is full
  lfos.on_step(function()
    for k = 1, 12 do lfos.mark_due(probe_key(k), function() end) end
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

-- #633: a deferrable source (a macro, morph, gesture playback, a fade)
-- moving an engine LFO's control params sends through the round robin and
-- the send budget; a hand edit still goes at the next step, uncapped
test("engine LFOs a macro moves at 30 Hz stay inside the round robin's 12 a step and the budget's count (#633)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local lfos, macros = S.lib.lfos, S.lib.macros
  S.drift_metro:stop()  -- the drift's own sends are never deferred
  for n = 1, 6 do
    aim(n, "v" .. n .. " pitch"); params:set(lfo_id(n), 1)
    assert_true(macros.set_target(1, n, lfo_id(n, "depth"), 0, 1), "macro 1 row " .. n .. " on LFO " .. n .. "'s depth")
  end
  lfo_step(context)
  -- 12 keys due every step: the round robin is full
  local probes = 0
  lfos.on_step(function()
    for k = 1, 12 do lfos.mark_due(probe_key(k), function() probes = probes + 1 end) end
  end)
  -- every engine LFO call, and whether the budget counted it (made by an
  -- engine sender, which only send_engine_value's delivery runs)
  local inside, lfo_calls = 0, {}
  for id, sender in pairs(S.engine_senders) do
    S.engine_senders[id] = function(value)
      inside = inside + 1
      local ok, problem = pcall(sender, value)
      inside = inside - 1
      if not ok then error(problem, 0) end
    end
  end
  for _, command in ipairs({ "setFastLfo", "syncFastLfo" }) do
    local real = engine[command]
    engine[command] = function(...)
      table.insert(lfo_calls, { what = command, lfo = (...), counted = inside > 0, depth = select(6, ...) })
      return real(...)
    end
  end
  local busiest, moved_at = 0, -math.huge
  local ok, problem = pcall(function()
    for step = 1, 48 do
      if util.time() - moved_at >= 1 / 30 then   -- the macro moves at 30 Hz: every depth with it
        params:set("macro_1", step % 2 == 0 and 0.2 or 0.8)
        moved_at = util.time()
      end
      local before
      context.clock.advance_until(S.lfo_clock, function() before = { calls = #lfo_calls, probes = probes } end)
      busiest = math.max(busiest, #lfo_calls - before.calls + probes - before.probes)
    end
    lfo_step(context, 6)  -- what the moves left due goes out
  end)
  -- a deferrable phase edit (a morph's crossing, gesture playback): its sync alone
  local phase_from = #lfo_calls
  if ok then
    ok, problem = pcall(function()
      S.lib.engine_sync.deferrable(function() params:set(lfo_id(4, "phase"), 30) end)
      lfo_step(context, 2)
    end)
  end
  rawset(engine, "setFastLfo", nil); rawset(engine, "syncFastLfo", nil)
  if not ok then error(problem, 0) end
  local phase_calls = {}
  for index = phase_from + 1, #lfo_calls do
    if lfo_calls[index].lfo == 3 then table.insert(phase_calls, lfo_calls[index].what) end
  end
  assert_equal(table.concat(phase_calls, " "), "syncFastLfo", "the deferrable phase edit: one sync, no setFastLfo")
  assert_true(#lfo_calls > 0, "the moves reach the engine LFOs")
  assert_true(busiest <= 12, "a step sends at most 12, the LFOs' with the round robin's: " .. busiest)
  for index, call in ipairs(lfo_calls) do
    assert_true(call.counted, call.what .. " " .. index .. " (LFO " .. call.lfo .. ") counts against the send budget")
  end
  for n = 1, 6 do
    local last
    for _, call in ipairs(lfo_calls) do
      if call.what == "setFastLfo" and call.lfo == n - 1 then last = call end
    end
    assert_near(last.depth, params:get(lfo_id(n, "depth")) / 100, 1e-9, "LFO " .. n .. " ends on the macro's last depth")
  end
  -- a hand edit goes in the next step, however full the round robin is
  context.clear_engine_calls()
  params:set(lfo_id(3, "depth"), 55)
  lfo_step(context)
  local calls = calls_with(context, "setFastLfo", 2)
  assert_equal(#calls, 1, "the hand edit goes in the next step")
  assert_near(calls[1].args[6], 0.55, 1e-9, "with its depth")
end)

-- 3.7 (decision 24): the list by voice, each destination stored by its key
local GLOBAL_LABELS = { "density", "drift", "filt freq", "filt res", "filt mix", "dly time", "dly fdbk", "dly mix",
  "rev mix", "rev size", "rev damp" }
local VOICE_SUFFIXES = { "main", "size", "dens", "pitch", "spread", "pos", "rate", "scan", "hist", "vfilt", "dsend",
  "rsend", "amp" }

test("the destinations are none, the globals, each voice's together, then the macros", function()
  load_strata()
  local S = local_value("S")
  local destinations = local_value("LFO_DESTINATIONS")
  local expected = { "none" }
  for _, label in ipairs(GLOBAL_LABELS) do expected[#expected + 1] = label end
  for voice_idx = 1, 7 do
    for _, suffix in ipairs(VOICE_SUFFIXES) do expected[#expected + 1] = "v" .. voice_idx .. " " .. suffix end
  end
  for m = 1, 16 do expected[#expected + 1] = "macro " .. m end
  local labels = {}
  for index, destination in ipairs(destinations) do labels[index] = destination.label end
  assert_equal(table.concat(labels, ","), table.concat(expected, ","), "the whole list, in order")
  assert_equal(#destinations, 119, "1 + 11 + 7 x 13 + 16: today's destinations, each once")
  -- an LFO's destination is its home routing (the groundwork before 3.8):
  -- entry index's home id is its key ("" for none), and back
  assert_equal(params.lookup[lfo_id(6, "dest")], nil, "no destination param")
  for index, destination in ipairs(destinations) do
    local id = S.lib.lfos.destination_id(index)
    assert_equal(id, index == 1 and "" or destination.key, destination.label .. "'s home id")
    aim_index(6, index)
    assert_equal(home_index(6), index, destination.label .. " back from the home")
  end
  -- each entry's key: none, the param it moves, v<i>_main for a voice's main
  local keys = {}
  for index, destination in ipairs(destinations) do
    keys[index] = destination.key
    -- (none and a voice's main entry: below)
    if destination.key ~= "none" and not destination.label:match(" main$") then
      assert_equal(destination.key, destination.resolve(), destination.label .. "'s key is the param it moves")
    end
  end
  assert_equal(keys[1], "none"); assert_equal(keys[2], "master_density")
  assert_equal(destinations[13].key, "v1_main"); assert_equal(destinations[22].key, "v1_filter_freq")
  -- the groups ALT+E3 jumps by: indices into the list
  local groups = {}
  for _, group in ipairs(S.lib.lfos.destination_groups()) do
    groups[#groups + 1] = group.name .. " " .. group.first .. "-" .. group.last
  end
  assert_equal(table.concat(groups, ", "), "global 2-12, voice 1 13-25, voice 2 26-38, voice 3 39-51, "
    .. "voice 4 52-64, voice 5 65-77, voice 6 78-90, voice 7 91-103, macros 104-119")
  -- every destination of voice 3 lies between voice 2's last and voice 4's first
  for index, destination in ipairs(destinations) do
    if destination.label:match("^v3 ") then assert_true(index >= 39 and index <= 51, destination.label .. " in voice 3") end
  end
  -- every destination is a control param whose label (with ~ when it
  -- runs in the engine) fits the page's right column
  for _, destination in ipairs(destinations) do
    local resolved = destination.resolve()
    if resolved then assert_true(params:lookup_param(resolved).controlspec, resolved .. " is a control param") end
    local label = destination.label .. (destination.fast and "~" or "")
    assert_true(stubs.text_width(label) <= 49, label .. " fits its column")
  end
end)

-- A PSET of the script as it is, its lines matching `drop` removed and
-- `lines` added (a hand-made older or foreign PSET)
local function pset_with(context, name, drop, lines)
  local path = context.data_dir .. name .. ".pset"
  util.make_dir(context.data_dir)
  params:write(path)
  local file = io.open(path, "r")
  local text = file:read("*a")
  file:close()
  local kept = {}
  for line in text:gmatch("[^\n]+") do
    if not (drop and line:find(drop)) then kept[#kept + 1] = line end
  end
  for _, line in ipairs(lines or {}) do kept[#kept + 1] = line end
  file = io.open(path, "w")
  file:write(table.concat(kept, "\n") .. "\n")
  file:close()
  return path
end

local function read_text(path)
  local file = io.open(path, "r")
  local text = file:read("*a")
  file:close()
  return text
end

-- The groundwork before 3.8: the key is LFO 2's home routing's, slot 18 of
-- the matrix, in the PSET's matrix side file and the scene's matrix block
test("a destination is stored by key in a PSET and in a scene", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "keyed.pset"
  aim(2, "v3 vfilt")
  assert_equal(S.lib.matrix.home(2), "v3_filter_freq", "the home holds the key")
  params:write(path)
  local text = read_text(path)
  assert_true(not text:find('"strata_lfo2_dest', 1, true), "the PSET has no destination line")
  local side = S.lib.data_files.read(context.data_dir .. "keyed.matrix.data")
  assert_equal(side.version, 2, "the matrix side file, version 2")
  assert_equal(side.matrix[18].source, "lfo2"); assert_equal(side.matrix[18].dest, "v3_filter_freq", "slot 18")
  aim_index(2, 1)
  params:read(path)
  assert_equal(home_index(2), destination_index("v3 vfilt"), "the PSET loads back to it")
  assert_equal(resolved(2), "v3_filter_freq")
  -- the scene's matrix block holds the key, and a recall puts it back
  capture_scene(1)
  local data = local_value("scenes")[1].data
  assert_equal(data.matrix[18].dest, "v3_filter_freq", "the scene's matrix block holds the key")
  assert_equal(data.strata_lfo2_dest_key, nil, "no block of its own")
  assert_equal(data.strata_lfo2_dest, nil, "and no index")
  aim_index(2, 1)
  recall_scene(1, 0)
  assert_equal(home_index(2), destination_index("v3 vfilt"), "the scene recalls it")
  assert_equal(resolved(2), "v3_filter_freq")
end)

-- The groundwork before 3.8 (ruling 19): a home this build has no
-- destination for is kept, reads as none, does not play, and is named on
-- the console at each file load and once a session for a scene
test("a key the build does not know reads as none", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function lines_naming(text)
    local lines = 0
    for _, line in ipairs(context.printed) do
      if line:find(text, 1, true) then lines = lines + 1 end
    end
    return lines
  end
  -- a PSET whose matrix side file holds a key this build lacks
  aim(2, "v3 pitch")
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "unknown.pset"
  params:write(path)
  assert_true(S.lib.data_files.write(context.data_dir .. "unknown.matrix.data",
    { version = 2, matrix = { [18] = { source = "lfo2", dest = "v3_wobble" } } }))
  aim(2, "rev mix")
  context.printed = {}
  params:read(path)
  assert_equal(home_index(2), 1, "none")
  assert_equal(S.lib.matrix.home(2), "v3_wobble", "the key is kept")
  assert_equal(resolved(2), nil, "and plays nothing")
  assert_equal(lines_naming("v3_wobble"), 1, "one console line names the key")
  params:read(path)
  assert_equal(lines_naming("v3_wobble"), 2, "and one at each file load")
  -- a scene whose key this build lacks
  aim(2, "v3 pitch")
  capture_scene(1)
  local scene = local_value("scenes")[1]
  scene.data.matrix[18] = { source = "lfo2", dest = "v9_nothing" }
  assert_true(validate_scene(scene), "a key is any string: the scene stays valid")
  context.printed = {}
  recall_scene(1, 0)
  assert_equal(home_index(2), 1, "none")
  assert_equal(S.lib.matrix.home(2), "v9_nothing", "kept")
  assert_equal(lines_naming("v9_nothing"), 1, "one console line names the key")
  recall_scene(1, 0)
  assert_equal(lines_naming("v9_nothing"), 1, "once a session")
  for _, bad in ipairs({ 14, true }) do
    local broken = deep_copy(scene)
    broken.data.matrix[18] = { source = "lfo2", dest = bad }
    assert_true(not validate_scene(broken), tostring(bad) .. " is no key")
  end
end)

test("a destination registered after init's list joins its voice's group", function()
  load_strata({ before_init = function()
    local S = local_value("S")
    S.register_lfo_destination("probe", "freq")
    S.register_lfo_global_destination("gprobe", "mutation_amount")
  end })
  local S = local_value("S")
  local destinations = local_value("LFO_DESTINATIONS")
  for voice_idx = 1, 7 do
    local amp, probe = destination_index("v" .. voice_idx .. " amp"), destination_index("v" .. voice_idx .. " probe")
    assert_equal(probe, amp + 1, "v" .. voice_idx .. " probe follows the voice's other registered ones")
    assert_equal(destinations[probe].group, "voice " .. voice_idx)
    assert_equal(destinations[probe].key, "v" .. voice_idx .. "_freq")
    if voice_idx < 7 then assert_equal(destinations[probe + 1].label, "v" .. (voice_idx + 1) .. " main") end
  end
  local gprobe = destination_index("gprobe")
  assert_equal(gprobe, destination_index("rev damp") + 1, "a registered global joins the globals")
  assert_equal(destinations[gprobe].group, "global")
  assert_equal(destinations[#destinations].label, "macro 16", "the macros still end the list")
  local groups = {}
  for _, group in ipairs(S.lib.lfos.destination_groups()) do groups[#groups + 1] = group.name .. " " .. group.first .. "-" .. group.last end
  assert_equal(table.concat(groups, ", "), "global 2-13, voice 1 14-27, voice 2 28-41, voice 3 42-55, "
    .. "voice 4 56-69, voice 5 70-83, voice 6 84-97, voice 7 98-111, macros 112-127")
  -- a key is stored, so two destinations never share one
  local ok, problem = pcall(load_strata, { before_init = function()
    local_value("S").register_lfo_destination("again", "grain_size")
  end })
  assert_true(not ok and tostring(problem):find("register_lfo_destination: v1 again's param v1_grain_size is already "
    .. "a destination", 1, true), "a second destination of one param is refused: " .. tostring(problem))
  load_strata()
end)

-- The engine calls 3.6 (main at de4949e6, the destination set by its index)
-- made for each destination: LFO 1 a square held at its top, rate 0.003 Hz,
-- depth 50 %, turned on and stepped three times (numbers to 4 places);
-- setDelay's fourth value, 3.7's ping-pong at its default 0, appended
local SOUND_BEFORE_3_7 = {
  v3_filter_freq = "setFastLfo 0.0000 2.0000 3.0000 2.0000 0.0030 0.5000 0.0000; syncFastLfo 0.0000 0.0000",
  v1_grain_pitch = "setFastLfo 0.0000 0.0000 0.0000 2.0000 0.0030 0.5000 0.0000; syncFastLfo 0.0000 0.0000",
  v5_buf_pos = "setFastLfo 0.0000 4.0000 1.0000 2.0000 0.0030 0.5000 0.0000; syncFastLfo 0.0000 0.0000",
  v6_grain_size = "setFastLfo 0.0000 5.0000 2.0000 2.0000 0.0030 0.5000 0.0000; syncFastLfo 0.0000 0.0000",
  v7_amp = "setFastLfo 0.0000 6.0000 4.0000 2.0000 0.0030 0.5000 0.0000; syncFastLfo 0.0000 0.0000",
  reverb_mix = "setReverb 0.5500 0.8000 0.5000",
  delay_feedback = "setDelay 0.3750 0.6375 0.0000 0.0000",
  v1_main = "setVoiceParam 0.0000 freq 555.0000",
  v2_history = "setGrainParam 1.0000 history 4.0000",
  v1_reverb_send = "setGrainParam 0.0000 reverbSend 1.0000",
}

test("an LFO's sound is unchanged: the same destination gives the same engine calls", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("reverb_mix", 0.3); params:set("delay_feedback", 0.4); params:set("v1_freq", 60)
  local keys = {}
  for key in pairs(SOUND_BEFORE_3_7) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    S.lib.matrix.set_home(1, key)
    params:set(lfo_id(1, "shape"), 3)
    params:set(lfo_id(1, "rate"), 0.003)
    params:set(lfo_id(1, "phase"), 0)
    params:set(lfo_id(1, "depth"), 50)
    context.clear_engine_calls()
    params:set(lfo_id(1), 1)
    lfo_step(context, 3)
    local lines = {}
    for _, call in ipairs(context.engine_calls) do
      local args = {}
      for index, arg in ipairs(call.args) do
        args[index] = type(arg) == "number" and string.format("%.4f", arg) or tostring(arg)
      end
      lines[#lines + 1] = call.name .. " " .. table.concat(args, " ")
    end
    assert_equal(table.concat(lines, "; "), SOUND_BEFORE_3_7[key], key .. ": the calls 3.6 made")
    params:set(lfo_id(1), 0)
    lfo_step(context)  -- a Lua destination is given back at the matrix's next step (ruling 17)
  end
  -- a voice's main follows its source; a macro is a direct destination
  S.lib.matrix.set_home(3, "v1_main")
  assert_equal(resolved(3), "v1_freq", "a synth voice's main is its freq")
  assert_equal(S.lib.lfos.destination(3).label, "v1 main", "destination(n) is the entry, as before")
  S.lib.matrix.set_home(4, "macro_1")
  assert_equal(resolved(4), "macro_1")
end)

-- 0e's re-review: while a scene applies an LFO's settings none of them
-- reaches the engine; the next step sends the LFO once with all of them in
-- place. `current` and `scene` set LFO 2's settings (the scene's are
-- captured into scene 1), then an instant recall and one step: every
-- engine call of LFO 2 in that window is checked
local function recall_window(context, current, scene)
  local S = local_value("S")
  params:set(lfo_id(2), 0)
  scene(); params:set(lfo_id(2), 1); capture_scene(1)
  params:set(lfo_id(2), 0)
  current(); params:set(lfo_id(2), 1); lfo_step(context)
  context.clear_engine_calls()
  recall_scene(1, 0)
  lfo_step(context)
  local sets, others = {}, {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == "setFastLfo" and call.args[1] == 1 then
      sets[#sets + 1] = call
    elseif (call.name == "stopFastLfo" or call.name == "syncFastLfo") and call.args[1] == 1 then
      others[#others + 1] = call
    end
  end
  return sets, others, S.lib.lfos
end

local function lfo_settings(dest_label, shape, rate, depth, mode, division)
  return function()
    aim(2, dest_label)
    params:set(lfo_id(2, "shape"), option_index(lfo_id(2, "shape"), shape))
    params:set(lfo_id(2, "mode"), option_index(lfo_id(2, "mode"), mode or "free"))
    params:set(lfo_id(2, "division"), option_index(lfo_id(2, "division"), division or "4"))
    params:set(lfo_id(2, "rate"), rate)
    params:set(lfo_id(2, "depth"), depth)
  end
end

-- The one send the window may hold: the scene's voice, destination, shape,
-- rate (what the LFO plays at its mode now) and depth together
local function assert_one_send(sets, lfos, voice, destination, shape, what)
  assert_equal(#sets, 1, what .. ": one setFastLfo, with everything in place")
  local args = sets[1].args
  assert_equal(args[2], voice - 1, what .. ": the scene's voice")
  assert_equal(args[3], destination, what .. ": the scene's destination")
  assert_equal(args[4], option_index(lfo_id(2, "shape"), shape) - 1, what .. ": the scene's shape")
  assert_near(args[5], lfos.effective_rate(2), 1e-9, what .. ": the scene's rate")
  assert_near(args[6], lfos.effective_depth(2) / 100, 1e-9, what .. ": the scene's depth")
end

test("an instant recall whose shape differs sends the LFO once, with the scene's settings", function()
  local context = load_strata(); finish_startup(context)
  local sets, _, lfos = recall_window(context, lfo_settings("v3 pitch", "sine", 1, 25),
    lfo_settings("v5 pitch", "tri", 5, 60))
  assert_one_send(sets, lfos, 5, 0, "tri", "shape")
  assert_near(sets[1].args[5], 5, 1e-9, "5 Hz"); assert_near(sets[1].args[6], 0.6, 1e-9, "60 %")
end)

test("an instant recall whose mode differs sends the LFO once, with the scene's settings", function()
  local context = load_strata(); finish_startup(context)
  local sets, _, lfos = recall_window(context, lfo_settings("v3 pitch", "sine", 1, 25),
    lfo_settings("v5 pitch", "sine", 1, 60, "clocked", "1"))
  assert_one_send(sets, lfos, 5, 0, "sine", "mode")
  assert_true(lfos.is_clocked(2), "clocked")
end)

test("an instant recall whose division differs sends the LFO once, with the scene's settings", function()
  local context = load_strata(); finish_startup(context)
  local sets, _, lfos = recall_window(context, lfo_settings("v3 pitch", "sine", 1, 25, "clocked", "4"),
    lfo_settings("v3 pitch", "sine", 1, 60, "clocked", "1/4"))
  assert_one_send(sets, lfos, 3, 0, "sine", "division")
end)

-- 0e's review, round 3: every engine call of the LFOs (setFastLfo,
-- stopFastLfo, syncFastLfo) and of a Lua destination's command, in order,
-- in two windows: the recall itself, and the next LFO step
local WINDOW_CALLS = { setFastLfo = true, stopFastLfo = true, syncFastLfo = true, setReverb = true }

local function window_calls(context)
  local calls = {}
  for _, call in ipairs(context.engine_calls) do
    if WINDOW_CALLS[call.name] then calls[#calls + 1] = call end
  end
  return calls
end

local function names_of(calls)
  local names = {}
  for index, call in ipairs(calls) do
    names[index] = call.name .. (call.name == "setReverb" and "" or " " .. tostring(call.args[1]))
  end
  return table.concat(names, ", ")
end

-- current and scene set LFO 2's settings and state (on: whether it runs);
-- scene 1 is captured from scene; returns the calls at the recall and at
-- the next step
local function recall_windows(context, current, current_on, scene, scene_on)
  params:set(lfo_id(2), 0)
  scene(); params:set(lfo_id(2), scene_on and 1 or 0); capture_scene(1)
  params:set(lfo_id(2), 0)
  current(); params:set(lfo_id(2), current_on and 1 or 0); lfo_step(context)
  context.clear_engine_calls()
  recall_scene(1, 0)
  local at_recall = window_calls(context)
  context.clear_engine_calls()
  lfo_step(context)
  return at_recall, window_calls(context)
end

-- setFastLfo's seven arguments, each asserted
local function assert_fast_lfo(call, voice, destination, shape, rate, depth, offset, what)
  assert_equal(call.name, "setFastLfo", what)
  assert_equal(call.args[1], 1, what .. ": LFO 2")
  assert_equal(call.args[2], voice - 1, what .. ": voice")
  assert_equal(call.args[3], destination, what .. ": destination")
  assert_equal(call.args[4], option_index(lfo_id(2, "shape"), shape) - 1, what .. ": shape")
  assert_near(call.args[5], rate, 1e-9, what .. ": rate")
  assert_near(call.args[6], depth, 1e-9, what .. ": depth")
  assert_near(call.args[7], offset, 1e-9, what .. ": offset")
end

-- the settings above plus an offset
local function with_offset(settings, offset)
  return function()
    settings()
    params:set(lfo_id(2, "offset"), offset)
  end
end

test("a recall that changes every LFO setting sends nothing at once, then one setFastLfo and its sync", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  local at_recall, at_step = recall_windows(context,
    with_offset(lfo_settings("v3 pitch", "sine", 1, 25), 0), true,
    with_offset(lfo_settings("v6 size", "drunk", 7, 80, "clocked", "1"), 30), true)
  assert_equal(names_of(at_recall), "", "nothing reaches the engine at the recall")
  assert_equal(names_of(at_step), "setFastLfo 1, syncFastLfo 1", "the next step: one send and its sync")
  -- clocked at division 1 (a period of 4 beats) at 120 BPM: 0.5 Hz
  assert_fast_lfo(at_step[1], 6, 2, "drunk", 0.5, 0.8, 0.6, "the scene's settings")
  assert_near(at_step[2].args[2], lfos.phase(2), 1e-3, "synced to the LFO's phase")
end)

test("a recall that turns an LFO on sends it once at the recall, with the scene's settings", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  local at_recall, at_step = recall_windows(context,
    with_offset(lfo_settings("v3 pitch", "sine", 1, 25), 0), false,
    with_offset(lfo_settings("v5 pitch", "tri", 5, 60), -20), true)
  assert_equal(names_of(at_recall), "setFastLfo 1, syncFastLfo 1", "turned on at the recall: one send and its sync")
  assert_fast_lfo(at_recall[1], 5, 0, "tri", 5, 0.6, -0.4, "the scene's settings")
  assert_near(at_recall[2].args[2], 0, 1e-9, "a free LFO starts at its phase param, 0")
  assert_true(lfos.is_on(2), "it runs")
  assert_equal(names_of(at_step), "", "and nothing at the next step")
end)

test("a recall that turns an LFO off sends its stop alone", function()
  local context = load_strata(); finish_startup(context)
  local at_recall, at_step = recall_windows(context,
    with_offset(lfo_settings("v3 pitch", "sine", 1, 25), 0), true,
    with_offset(lfo_settings("v5 pitch", "tri", 5, 60), 30), false)
  assert_equal(names_of(at_recall), "stopFastLfo 1", "the stop alone, at the recall")
  assert_equal(names_of(at_step), "", "and nothing at the next step")
end)

test("a recall from an engine destination to a Lua one stops the node at the step, then the Lua sends", function()
  local context = load_strata(); finish_startup(context)
  params:set("reverb_mix", 0.3)
  local held = function(label, depth)
    return function()
      lfo_settings(label, "square", 0.003, depth)()
      params:set(lfo_id(2, "phase"), 0)
    end
  end
  local at_recall, at_step = recall_windows(context, held("v3 pitch", 25), true, held("rev mix", 60), true)
  assert_equal(names_of(at_recall), "", "nothing at the recall")
  assert_equal(names_of(at_step), "stopFastLfo 1, setReverb", "the stop, then rev mix moves")
  -- a square held at its top: 0.3 + 0.6 x half the range (0.5)
  assert_near(at_step[2].args[1], 0.6, 1e-9, "rev mix at the scene's depth")
  assert_near(at_step[2].args[2], params:get("reverb_size"), 1e-9, "with the stored size")
  assert_near(at_step[2].args[3], params:get("reverb_damp"), 1e-9, "and damping")
end)

test("an instant recall from a Lua destination to an engine one gives the old back and starts the new once", function()
  local context = load_strata(); finish_startup(context)
  params:set("reverb_mix", 0.3)
  local sets, _, lfos = recall_window(context, lfo_settings("rev mix", "sine", 1, 25),
    lfo_settings("v5 pitch", "tri", 5, 60))
  assert_one_send(sets, lfos, 5, 0, "tri", "Lua to engine")
  local reverbs = context.calls_named("setReverb")
  assert_true(#reverbs >= 1, "rev mix given back")
  assert_near(reverbs[#reverbs].args[1], 0.3, 1e-9, "to its stored value")
end)

test("a plain turn of the shape, mode or division reaches the engine at once", function()
  local context = load_strata(); finish_startup(context)
  lfo_settings("v3 pitch", "sine", 1, 25)(); params:set(lfo_id(2), 1); lfo_step(context)
  for field, value in pairs({ shape = option_index(lfo_id(2, "shape"), "tri"),
    mode = option_index(lfo_id(2, "mode"), "clocked"), division = option_index(lfo_id(2, "division"), "1") }) do
    context.clear_engine_calls()
    params:set(lfo_id(2, field), value)
    assert_equal(#calls_with(context, "setFastLfo", 1), 1, field .. ": sent at once, outside a recall")
  end
end)

-- 0e's review: the destination is a scene block (since the groundwork
-- before 3.8 the matrix's, its home routing), which applies before the
-- LFO's settings, and the next step brings it in with every setting in
-- place
test("an instant recall's first send carries the scene's destination with its rate and depth", function()
  local context = load_strata(); finish_startup(context)
  local function setup(dest_label, rate, depth)
    aim(2, dest_label)
    params:set(lfo_id(2, "rate"), rate)
    params:set(lfo_id(2, "depth"), depth)
    params:set(lfo_id(2), 1)
  end
  -- an engine destination
  setup("v5 pitch", 5, 60); capture_scene(1)
  setup("v3 pitch", 1, 25); lfo_step(context)
  context.clear_engine_calls()
  recall_scene(1, 0)
  lfo_step(context)
  local sets = calls_with(context, "setFastLfo", 1)
  assert_true(#sets >= 1, "the recall moves the engine LFO")
  for index, call in ipairs(sets) do
    assert_equal(call.args[2], 4, "send " .. index .. ": voice 5")
    assert_near(call.args[5], 5, 1e-9, "send " .. index .. ": the scene's rate")
    assert_near(call.args[6], 0.6, 1e-9, "send " .. index .. ": the scene's depth")
  end
  assert_equal(resolved(2), "v5_grain_pitch")
  -- a Lua destination: the old one is given back, the new one first moves
  -- with the scene's depth (a square held at its top: + 0.6 x half range)
  params:set("reverb_mix", 0.3); params:set("delay_mix", 0.2)
  params:set(lfo_id(2), 0)
  hold_lfo(2, "dly mix", 60); capture_scene(2)
  hold_lfo(2, "rev mix", 25); lfo_step(context)
  context.clear_engine_calls()
  recall_scene(2, 0)
  lfo_step(context)
  local reverbs, delays = context.calls_named("setReverb"), context.calls_named("setDelay")
  assert_true(#reverbs >= 1, "rev mix is given back")
  assert_near(reverbs[#reverbs].args[1], 0.3, 1e-9, "to its stored value")
  assert_true(#delays >= 1, "dly mix moves")
  assert_near(delays[1].args[3], 0.2 + 0.6 * 0.5, 1e-9, "its first send at the scene's depth")
  -- from an engine destination to a Lua one: the step stops the engine LFO
  hold_lfo(2, "v3 pitch", 25); lfo_step(context)
  context.clear_engine_calls()
  recall_scene(2, 0)
  lfo_step(context)
  assert_equal(#calls_with(context, "stopFastLfo", 1), 1, "the engine LFO stops")
  assert_true(#context.calls_named("setDelay") >= 1, "and dly mix moves")
  -- a fade ramps the depth through 0 and switches the destination at its
  -- midpoint (the matrix's rule for a home routing, the groundwork before
  -- 3.8; 3.7 switched it at the end)
  hold_lfo(2, "rev mix", 25); lfo_step(context)
  recall_scene(2, 1)
  context.clock.run_for(0.4)
  assert_equal(resolved(2), "reverb_mix", "before the midpoint: the old destination")
  context.clock.run_for(0.2)
  assert_equal(resolved(2), "delay_mix", "past it: the scene's")
  context.clock.run_for(1)
  assert_equal(resolved(2), "delay_mix", "at its end: the scene's")
end)

-- #729: the list on main before a registered global named its group (3.7's
-- package 0e, by voice), each entry "label|key|group" in order: the keys
-- PSETs and scenes store, so every one still names the same destination
local DESTINATIONS_BEFORE_729 = {
  "none|none|none", "density|master_density|global", "drift|drift_amount|global", "filt freq|filter_freq|global",
  "filt res|filter_res|global", "filt mix|filter_mix|global", "dly time|delay_time|global",
  "dly fdbk|delay_feedback|global", "dly mix|delay_mix|global", "rev mix|reverb_mix|global",
  "rev size|reverb_size|global", "rev damp|reverb_damp|global", "v1 main|v1_main|voice 1",
  "v1 size|v1_grain_size|voice 1", "v1 dens|v1_grain_density|voice 1", "v1 pitch|v1_grain_pitch|voice 1",
  "v1 spread|v1_grain_spread|voice 1", "v1 pos|v1_buf_pos|voice 1", "v1 rate|v1_buf_rate|voice 1",
  "v1 scan|v1_buf_scan|voice 1", "v1 hist|v1_history|voice 1", "v1 vfilt|v1_filter_freq|voice 1",
  "v1 dsend|v1_delay_send|voice 1", "v1 rsend|v1_reverb_send|voice 1", "v1 amp|v1_amp|voice 1",
  "v2 main|v2_main|voice 2", "v2 size|v2_grain_size|voice 2", "v2 dens|v2_grain_density|voice 2",
  "v2 pitch|v2_grain_pitch|voice 2", "v2 spread|v2_grain_spread|voice 2", "v2 pos|v2_buf_pos|voice 2",
  "v2 rate|v2_buf_rate|voice 2", "v2 scan|v2_buf_scan|voice 2", "v2 hist|v2_history|voice 2",
  "v2 vfilt|v2_filter_freq|voice 2", "v2 dsend|v2_delay_send|voice 2", "v2 rsend|v2_reverb_send|voice 2",
  "v2 amp|v2_amp|voice 2", "v3 main|v3_main|voice 3", "v3 size|v3_grain_size|voice 3",
  "v3 dens|v3_grain_density|voice 3", "v3 pitch|v3_grain_pitch|voice 3", "v3 spread|v3_grain_spread|voice 3",
  "v3 pos|v3_buf_pos|voice 3", "v3 rate|v3_buf_rate|voice 3", "v3 scan|v3_buf_scan|voice 3",
  "v3 hist|v3_history|voice 3", "v3 vfilt|v3_filter_freq|voice 3", "v3 dsend|v3_delay_send|voice 3",
  "v3 rsend|v3_reverb_send|voice 3", "v3 amp|v3_amp|voice 3", "v4 main|v4_main|voice 4",
  "v4 size|v4_grain_size|voice 4", "v4 dens|v4_grain_density|voice 4", "v4 pitch|v4_grain_pitch|voice 4",
  "v4 spread|v4_grain_spread|voice 4", "v4 pos|v4_buf_pos|voice 4", "v4 rate|v4_buf_rate|voice 4",
  "v4 scan|v4_buf_scan|voice 4", "v4 hist|v4_history|voice 4", "v4 vfilt|v4_filter_freq|voice 4",
  "v4 dsend|v4_delay_send|voice 4", "v4 rsend|v4_reverb_send|voice 4", "v4 amp|v4_amp|voice 4",
  "v5 main|v5_main|voice 5", "v5 size|v5_grain_size|voice 5", "v5 dens|v5_grain_density|voice 5",
  "v5 pitch|v5_grain_pitch|voice 5", "v5 spread|v5_grain_spread|voice 5", "v5 pos|v5_buf_pos|voice 5",
  "v5 rate|v5_buf_rate|voice 5", "v5 scan|v5_buf_scan|voice 5", "v5 hist|v5_history|voice 5",
  "v5 vfilt|v5_filter_freq|voice 5", "v5 dsend|v5_delay_send|voice 5", "v5 rsend|v5_reverb_send|voice 5",
  "v5 amp|v5_amp|voice 5", "v6 main|v6_main|voice 6", "v6 size|v6_grain_size|voice 6",
  "v6 dens|v6_grain_density|voice 6", "v6 pitch|v6_grain_pitch|voice 6", "v6 spread|v6_grain_spread|voice 6",
  "v6 pos|v6_buf_pos|voice 6", "v6 rate|v6_buf_rate|voice 6", "v6 scan|v6_buf_scan|voice 6",
  "v6 hist|v6_history|voice 6", "v6 vfilt|v6_filter_freq|voice 6", "v6 dsend|v6_delay_send|voice 6",
  "v6 rsend|v6_reverb_send|voice 6", "v6 amp|v6_amp|voice 6", "v7 main|v7_main|voice 7",
  "v7 size|v7_grain_size|voice 7", "v7 dens|v7_grain_density|voice 7", "v7 pitch|v7_grain_pitch|voice 7",
  "v7 spread|v7_grain_spread|voice 7", "v7 pos|v7_buf_pos|voice 7", "v7 rate|v7_buf_rate|voice 7",
  "v7 scan|v7_buf_scan|voice 7", "v7 hist|v7_history|voice 7", "v7 vfilt|v7_filter_freq|voice 7",
  "v7 dsend|v7_delay_send|voice 7", "v7 rsend|v7_reverb_send|voice 7", "v7 amp|v7_amp|voice 7",
  "macro 1|macro_1|macros", "macro 2|macro_2|macros", "macro 3|macro_3|macros", "macro 4|macro_4|macros",
  "macro 5|macro_5|macros", "macro 6|macro_6|macros", "macro 7|macro_7|macros", "macro 8|macro_8|macros",
  "macro 9|macro_9|macros", "macro 10|macro_10|macros", "macro 11|macro_11|macros", "macro 12|macro_12|macros",
  "macro 13|macro_13|macros", "macro 14|macro_14|macros", "macro 15|macro_15|macros", "macro 16|macro_16|macros"
}

test("a registered global destination's group is its registration's; the list is unchanged (#729)", function()
  load_strata()
  local listed = {}
  for index, destination in ipairs(local_value("LFO_DESTINATIONS")) do
    listed[index] = destination.label .. "|" .. destination.key .. "|" .. destination.group
  end
  assert_equal(table.concat(listed, "\n"), table.concat(DESTINATIONS_BEFORE_729, "\n"),
    "every destination in its place, with its key and group")
  -- the group comes from the registration, never from the param's name
  load_strata({ before_init = function()
    local S = local_value("S")
    S.register_lfo_global_destination("probe mac", "mutation_amount", "macros")
    S.register_lfo_global_destination("probe glob", "mutation_probability", "global")
  end })
  local S = local_value("S")
  local destinations = local_value("LFO_DESTINATIONS")
  assert_equal(destinations[destination_index("probe mac")].group, "macros", "a global registered in the macros' group")
  assert_equal(destinations[destination_index("probe glob")].group, "global")
  assert_equal(destination_index("probe glob"), destination_index("rev damp") + 1, "it joins the globals")
  local groups = S.lib.lfos.destination_groups()
  local macros = groups[#groups]
  assert_equal(macros.name, "macros", "the macros still end the list")
  assert_true(destination_index("probe mac") >= macros.first and destination_index("probe mac") <= macros.last,
    "probe mac lies in the macros' group")
  assert_equal(macros.last - macros.first + 1, 17, "the 16 macros and the probe")
  load_strata()
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
  assert_true(local_value("S").lib.matrix.offset("reverb_mix") ~= 0, "LFO 1's home holds rev mix")
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(params:get(lfo_id(1, "depth")), 0, "depth 0, silently")
  assert_equal(params:get(lfo_id(1)), 1, "still on")
  assert_equal(#context.calls_named("setReverb"), 0, "nothing sent by the silent read")
  lfo_step(context)
  local restores = context.calls_named("setReverb")
  assert_equal(#restores, 1, "the next step restores rev mix")
  assert_near(restores[1].args[1], 0.3, 1e-9, "to its stored value")
  assert_equal(local_value("S").lib.matrix.offset("reverb_mix"), 0, "LFO 1's home holds nothing")
  context.clear_engine_calls()
  lfo_step(context, 5)
  assert_equal(#context.calls_named("setReverb"), 0, "and nothing is sent in the steps after it")
end)

test("a silent PSET read that turns an engine-run LFO off stops it at the next step, once", function()
  local context = load_strata(); finish_startup(context)
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "off.pset"
  aim(2, "v3 pitch")   -- off: the PSET holds that
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

-- #634: a silent read reaches a running engine LFO's offset and phase too
test("a silent PSET read reaches a running engine LFO's offset and phase at the next step, once (#634)", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "offset.pset"
  aim(2, "v3 pitch")
  params:set(lfo_id(2, "offset"), 30); params:set(lfo_id(2, "phase"), 40)
  params:set(lfo_id(2), 1)
  params:write(path)
  params:set(lfo_id(2, "offset"), -10); params:set(lfo_id(2, "phase"), 0)
  lfo_step(context)
  assert_near(calls_with(context, "setFastLfo", 1)[#calls_with(context, "setFastLfo", 1)].args[7], -0.2, 1e-9,
    "the engine plays offset -10 %")
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(params:get(lfo_id(2, "offset")), 30, "offset 30 %, silently")
  assert_equal(params:get(lfo_id(2, "phase")), 40, "phase 40 %, silently")
  assert_equal(#context.calls_named("setFastLfo") + #context.calls_named("syncFastLfo"), 0, "nothing sent by the silent read")
  lfo_step(context)
  local sets = calls_with(context, "setFastLfo", 1)
  assert_equal(#sets, 1, "the next step sends the new offset")
  assert_near(sets[1].args[7], 0.6, 1e-9, "2 x 30 / 100 half ranges")
  local syncs = calls_with(context, "syncFastLfo", 1)
  assert_equal(#syncs, 1, "and syncs the new phase")
  assert_near(syncs[1].args[2], lfos.phase(2), 1e-6, "to the phase with the PSET's 40 %")
  context.clear_engine_calls()
  lfo_step(context, 5)
  assert_equal(#calls_with(context, "setFastLfo", 1) + #calls_with(context, "syncFastLfo", 1), 0, "once")
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
  aim(2, "v3 pitch")
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
  assert_near(lfos.offset_for("delay_time", -1), -1.345, 1e-12, "half of 0.01-2.7 s")
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

-- The groundwork before 3.8 (ruling 17): the matrix gives a Lua home back
-- at its next step, through the round robin, once
test("a Lua-run LFO restores the stored value when turned off, at depth 0 and on a destination change", function()
  local context = load_strata(); finish_startup(context)
  params:set("delay_mix", 0.2)
  hold_lfo(1, "dly mix", 40)
  context.clear_engine_calls(); lfo_step(context)
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2 + 0.4 * 0.5, 1e-9, "modulated mix")
  context.clear_engine_calls(); params:set(lfo_id(1, "depth"), 0)
  assert_equal(#context.calls_named("setDelay"), 0, "depth 0: nothing at once")
  lfo_step(context)
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9, "depth 0 restores at the next step")
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(#context.engine_calls, 0, "a depth-0 LFO sends nothing")
  params:set(lfo_id(1, "depth"), 60); params:set(lfo_id(1, "phase"), 50)   -- value -1
  context.clear_engine_calls(); lfo_step(context)
  assert_near(context.calls_named("setDelay")[1].args[3], 0, 1e-9, "the modulated value clamps to the range")
  context.clear_engine_calls(); aim(1, "rev mix")
  assert_equal(#context.calls_named("setDelay"), 0, "a destination change: nothing at once")
  lfo_step(context)
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9, "the next step restores the old one")
  assert_near(context.calls_named("setReverb")[1].args[1], util.clamp(params:get("reverb_mix") - 0.3, 0, 1), 1e-9,
    "and modulates the new one")
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(#context.calls_named("setDelay"), 0, "the old destination is left alone")
  context.clear_engine_calls(); aim_index(1, 1)   -- none
  lfo_step(context)
  assert_near(context.calls_named("setReverb")[1].args[1], params:get("reverb_mix"), 1e-9, "none restores")
  lfo_step(context, 3)
  assert_equal(#context.calls_named("setReverb"), 1, "and then sends nothing")
  hold_lfo(1, "dly mix", 40); lfo_step(context)
  context.clear_engine_calls(); params:set(lfo_id(1), 0)
  lfo_step(context)
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

-- The groundwork before 3.8: a home whose m is exactly 0 adds nothing to the
-- matrix's sum, so its end has nothing to give back (the engine already
-- has the stored value)
test("a home at m 0 holds no offset, and its end sends nothing", function()
  for _, ending in ipairs({ "off", "depth 0" }) do
    local context = load_strata(); finish_startup(context)
    params:set("filter_mix", 0.5)
    -- value +1 at depth 50 with an offset of -25: m = 0.5 - 0.5 = 0, so the
    -- engine keeps the stored 0.5
    hold_lfo(1, "filt mix", 50); params:set(lfo_id(1, "offset"), -25)
    context.clear_engine_calls(); lfo_step(context, 3)
    assert_equal(#context.calls_named("setFilter"), 0, "nothing moved, nothing sent")
    assert_equal(local_value("S").lib.matrix.offset("filter_mix"), 0, "the matrix holds no offset")
    context.clear_engine_calls()
    if ending == "off" then params:set(lfo_id(1), 0) else params:set(lfo_id(1, "depth"), 0) end
    lfo_step(context, 3)
    assert_equal(#context.calls_named("setFilter"), 0, ending .. ": nothing to give back")
    assert_near(local_value("S").engine_param_values.filter_mix or params:get("filter_mix"), 0.5, 1e-9,
      ending .. ": the engine has the stored value")
  end
end)

-- The on/off param's bang (a PSET or scene that sets it on again) restarts
-- the phase, in Lua and in the engine (#251)
test("setting a running LFO on again restarts its phase, and an engine LFO's with it (#251)", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("S").lib.lfos
  params:set(lfo_id(1, "rate"), 0.25); params:set(lfo_id(1, "phase"), 10); params:set(lfo_id(1), 1)
  aim(2, "v3 pitch")
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

-- The groundwork before 3.8 (ruling 16): a buffer voice's main is its
-- position, a fast param the matrix sends as setFastOffset
test("main destination follows a voice's source and restores the old param", function()
  local context = load_strata(); finish_startup(context)
  local matrix = local_value("S").lib.matrix
  hold_lfo(2, "v1 main", 100)
  lfo_step(context)
  assert_true(matrix.offset("v1_freq") ~= 0, "a synth voice's main: its freq")
  assert_true(not local_value("S").lib.lfos.is_engine_run(2), "v<i> main is never the LFO's engine node")
  params:set("v1_source", 2); context.clear_engine_calls(); lfo_step(context)
  local voice_calls = context.calls_named("setVoiceParam")
  assert_equal(voice_calls[#voice_calls].args[2], "freq")
  assert_near(voice_calls[#voice_calls].args[3], params:get("v1_freq"), 1e-9, "the freq given back")
  assert_equal(matrix.offset("v1_freq"), 0)
  local fast = calls_with(context, "setFastOffset", 0)
  assert_true(#fast >= 1 and fast[#fast].args[3] == 1, "a buffer voice's position, on the fast channel")
  assert_near(fast[#fast].args[4], 1, 1e-9, "m 1")
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
  aim(2, "filt freq")
  context.clear_engine_calls(); lfo_step(context)
  calls = context.calls_named("setFilter")
  assert_near(calls[#calls].args[1], 1000 + 0.4 * 0.5 * 19980, 1e-6, "offsets add")
  context.clear_engine_calls(); params:set(lfo_id(2), 0); lfo_step(context)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "LFO 1 still applies")
  -- master density reaches every running voice's grain density
  aim(1, "density"); params:set("master_density", 1)
  context.clear_engine_calls(); lfo_step(context)
  local voices = local_value("voices")
  for _, density_call in ipairs(context.calls_named("setGrainParam")) do
    local voice_idx = density_call.args[1] + 1
    assert_true(voices[voice_idx].active, "only running voices")
    assert_near(density_call.args[3], voices[voice_idx].values.grain_density * (1 + 0.19), 1e-6, "modulated density")
  end
  assert_true(#context.calls_named("setGrainParam") >= 1, "a running voice got its density")
  assert_near(params:get("master_density"), 1, 1e-9, "master density param untouched")
end)

-- A start carries the extra offsets held on the voice's params, an LFO's
-- home among them since the groundwork before 3.8 (ruling 18; 3.7 sent
-- the stored density until the next LFO step, #50): the master density's
-- resend scales the modulated density, the one the engine plays
test("a restarted voice's grain density scales from its modulated value (#50)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  params:set("v1_grain_density", 20); params:set("master_density", 1)
  hold_lfo(1, "v1 dens", 50)
  lfo_step(context)
  assert_equal(voices[1].values.grain_density, 20, "the stored density is untouched")
  toggle_voice(1); toggle_voice(1)
  context.clear_engine_calls()
  params:set("master_density", 1.5)
  local density_calls = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "grainDensity" then table.insert(density_calls, call) end
  end
  assert_equal(#density_calls, 1, "master density resends voice 1's grain density")
  assert_near(density_calls[1].args[3], (20 + 0.5 * 49.5) * 1.5, 1e-6, "from the modulated density")
end)

test("param actions under a running LFO send the modulated value (drift, edits)", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_source", 2)
  params:set("v1_buf_pos", 0.4)
  hold_lfo(1, "v1 main", 50)                  -- a buffer voice's main is its position, on the fast path
  lfo_step(context)
  math.randomseed(5)
  context.clear_engine_calls(); drift_update()
  local sent
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "bufPos" then sent = call.args[3] end
  end
  assert_true(params:get("v1_buf_pos") ~= 0.4, "the drift moved the stored position")
  assert_near(sent, params:get("v1_buf_pos"), 1e-9, "drift sends the stored position")
  assert_near(local_value("S").lib.matrix.offset("v1_buf_pos"), 0.5, 1e-9,
    "the LFO's offset stays on its fast channel (ruling 16)")
  params:set("filter_freq", 1000); hold_lfo(2, "filt freq", 20); lfo_step(context)
  context.clear_engine_calls(); params:set("filter_freq", 2000)
  assert_near(context.calls_named("setFilter")[1].args[1], 2000 + 0.2 * 0.5 * 19980, 1e-6, "an edit keeps the offset")
  context.clear_engine_calls(); params:set("filter_res", 0.3)
  assert_near(context.calls_named("setFilter")[1].args[2], 0.3, 1e-9, "an unmodulated param sends its value")
end)

test("LFO steps skip sends below 1/1000 of the range; a restore sends once", function()
  local context = load_strata(); finish_startup(context)
  params:set("filter_mix", 0.5); aim(1, "filt mix")
  params:set(lfo_id(1, "rate"), 1 / 300); params:set(lfo_id(1, "phase"), 75)   -- a 300 s sine from its trough
  params:set(lfo_id(1, "depth"), 100); params:set(lfo_id(1), 1)
  context.clear_engine_calls()
  context.clock.run_for(10)
  local calls = context.calls_named("setFilter")
  assert_true(#calls >= 5 and #calls <= 15, "a slow LFO sends rarely (" .. #calls .. " sends)")
  for index = 2, #calls do
    assert_true(math.abs(calls[index].args[4] - calls[index - 1].args[4]) >= 0.001 - 1e-12, "each send moves >= 1/1000")
  end
  context.clear_engine_calls(); params:set(lfo_id(1), 0); lfo_step(context)
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
  params:set("v1_freq", 60); aim(1, "v1 main")
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
  aim(1, "filt mix")
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

-- One LFO's failing step leaves the others and the clock running (#517);
-- a Lua home's destination is resolved in the matrix's read of it since
-- the groundwork before 3.8, which contains it the same way
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
      if line:find("strata: matrix home 1 failed: ", 1, true) == 1 then
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
        if line:find("strata: matrix home 1 failed: ", 1, true) == 1 then printed = printed + 1 end
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
  h.claim_script_errors(context, 3, "strata: matrix home 1 failed: ", "another lfo boom")
end)

-- norns frees the engine before cleanup() (#461): the step stops the clock;
-- an engine LFO's node is gone with the engine, so nothing stops it
test("cleanup stops the clock and sends no stopFastLfo", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.lfo_clock ~= nil, "the clock runs from the start step")
  params:set("filter_freq", 800); hold_lfo(1, "filt freq", 50)
  aim(2, "v3 pitch"); params:set(lfo_id(2), 1)
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
  -- the tape's four macro targets: their senders reach softcut, not the
  -- engine (lib/io/tape.lua); test/unit/io_tape_test.lua checks that they
  -- send the offset value
  local softcut_senders = {}
  for _, id in ipairs(S.lib.io_tape.TAPE.macro_targets) do softcut_senders[id] = true end
  local checked = 0
  for _, param in ipairs(params.params) do
    -- a macro's sender takes an LFO's value for its targets' round robin
    -- sends (lib/macros.lua, macros_test.lua), never an engine call
    if param.t == params.tCONTROL and param.id:sub(1, 6) ~= "strata" and not param.id:match("^macro_%d+$")
        and not softcut_senders[param.id] then
      local sender = S.engine_senders[param.id]
      local value = other_value(param)
      if sender then
        local minval, maxval = param_range(param.id)
        S.lib.engine_sync.set_extra_offset("test", param.id, 0.2 * 0.5 * (maxval - minval))
        context.clear_engine_calls()
        params:set(param.id, value)
        local got = signature(context.engine_calls)
        local stored = params:get(param.id)
        S.lib.engine_sync.set_extra_offset("test", param.id, nil)
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
end)

-- AGENTS.md: a control param's action never calls the engine; an engine
-- LFO's control params reach it at the next step
test("an engine-run LFO's rate, depth, offset, phase and amounts call no engine command in their sets", function()
  local context = load_strata(); finish_startup(context)
  aim(2, "v3 pitch"); params:set(lfo_id(2), 1)
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
  -- the destination is a scene block of its key (3.7), not a field
  local per_lfo = { "shape", "mode", "division", "rate", "depth", "offset", "phase", "rate_mod", "rate_mod_amt",
    "depth_mod", "depth_mod_amt" }
  assert_equal(#fields, 6 * (#per_lfo + 1), "12 fields per LFO")
  local continuous = { rate = true, depth = true, offset = true }
  local ranges = { rate = { 0.003, 50 }, depth = { 0, 100 }, offset = { -100, 100 }, phase = { 0, 100 },
    rate_mod_amt = { -100, 100 }, depth_mod_amt = { -100, 100 } }
  for n = 1, 6 do
    for index, field in ipairs(per_lfo) do
      local record = fields[(n - 1) * 12 + index]
      assert_equal(record.id, lfo_id(n, field), "LFO " .. n .. " field " .. index)
      assert_equal(record.continuous, continuous[field] == true, record.id .. " continuous")
      assert_equal(record.lfo, continuous[field] and n or nil, record.id .. " belongs to its LFO")
      assert_equal(record.stop_target, field == "depth" and 0 or nil, record.id .. " stop target")
      assert_equal(record.default, param_default(record.id), record.id .. "'s default is its param's")
      assert_equal(record.range and record.range[1], ranges[field] and ranges[field][1], record.id .. " range min")
      assert_equal(record.range and record.range[2], ranges[field] and ranges[field][2], record.id .. " range max")
    end
    local state = fields[n * 12]
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

---------------------------------------------------------------------------
-- The home routing (the groundwork before 3.8, design §4): an LFO's
-- destination is the matrix's slot 16 + n
---------------------------------------------------------------------------

test("the rate ceiling follows the home routing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local lfos, matrix = S.lib.lfos, S.lib.matrix
  params:set(lfo_id(1, "rate"), 30)
  aim(1, "v1 pitch")
  params:set(lfo_id(1), 1)
  lfo_step(context)
  assert_near(lfos.effective_rate(1), 30, 1e-9, "the engine plays it: 30 Hz")
  assert_true(not lfos.capped(1))
  assert_true(matrix.edit_home(1, "filter_mix"))
  lfo_step(context)
  assert_near(lfos.effective_rate(1), 10, 1e-9, "in Lua: 10 Hz")
  assert_true(lfos.capped(1), "and capped")
  assert_true(matrix.edit_home(1, ""))
  lfo_step(context)
  assert_near(lfos.effective_rate(1), 10, 1e-9, "none: 10 Hz")
end)

test("a 3.7 PSET's destination lines read as nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local path = context.data_dir .. "strata-09.pset"
  params:write(path)
  os.remove(context.data_dir .. "strata-09.matrix.data")   -- 3.7 wrote no homes
  local file = assert(io.open(path, "a"))
  file:write('"strata_lfo1_dest": 14\n"strata_lfo1_dest_key": v3_grain_pitch\n')
  file:close()
  S.lib.matrix.set_home(1, "reverb_mix")
  local ok, problem = pcall(function() params:read(path) end)
  assert_true(ok, "the read raises nothing: " .. tostring(problem))
  assert_equal(S.lib.matrix.home(1), "", "LFO 1 is aimed at nothing")
  assert_equal(params.lookup[lfo_id(1, "dest")], nil, "there is no destination param")
  assert_equal(params.lookup[lfo_id(1, "dest_key")], nil, "nor its key")
end)

test("an LFO turned off gives its Lua destination back at the next step, once", function()
  for _, ending in ipairs({ "off", "depth 0", "another destination" }) do
    local context = load_strata(); finish_startup(context)
    params:set("reverb_mix", 0.3)
    hold_lfo(1, "rev mix", 40)
    context.clear_engine_calls(); lfo_step(context)
    assert_near(context.calls_named("setReverb")[1].args[1], 0.5, 1e-9, ending .. ": modulated, 0.3 + 0.4 x 0.5")
    context.clear_engine_calls()
    if ending == "off" then
      params:set(lfo_id(1), 0)
    elseif ending == "depth 0" then
      params:set(lfo_id(1, "depth"), 0)
    else
      aim(1, "dly mix")
    end
    assert_equal(#context.calls_named("setReverb"), 0, ending .. ": nothing at once")
    lfo_step(context)
    local calls = context.calls_named("setReverb")
    assert_equal(#calls, 1, ending .. ": the next step gives it back")
    assert_near(calls[1].args[1], 0.3, 1e-9, ending .. ": the stored value")
    lfo_step(context, 3)
    assert_equal(#context.calls_named("setReverb"), 1, ending .. ": once")
  end
end)

test("a voice start carries a Lua home's offset", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  one_running_one_stopped(S)
  params:set("master_density", 1)
  params:set("v2_grain_density", 20)
  hold_lfo(1, "v2 dens", 20)                 -- +0.2 half ranges of 1-100: +9.9
  lfo_step(context, 2)
  context.clear_engine_calls()
  toggle_voice(2)
  local sent = {}
  for _, call in ipairs(calls_with(context, "setGrainParam", 1)) do
    if call.args[2] == "grainDensity" then sent[#sent + 1] = call.args[3] end
  end
  assert_equal(#sent, 1, "the start sends one density")
  assert_near(sent[1], 29.9, 1e-9, "with the home's offset")
  lfo_step(context, 2)
  local after = 0
  for _, call in ipairs(calls_with(context, "setGrainParam", 1)) do
    if call.args[2] == "grainDensity" then after = after + 1 end
  end
  assert_equal(after, 1, "and the steps after it send nothing more")
  assert_true(S.voices[2].active)
end)

end

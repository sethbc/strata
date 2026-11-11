-- test/unit/lfos_test.lua
-- The global LFOs: modulation around the stored value, restores,
-- destinations, params, steps and cleanup (lib/lfos.lua)
-- Run alone: lua test/run.lua lfos

return function(h)
local test, stubs, assert_true, assert_equal = h.test, h.stubs, h.assert_true, h.assert_equal
local assert_near, load_strata, local_value = h.assert_near, h.load_strata, h.local_value
local finish_startup = h.finish_startup

-- lfo_depth_<n> is the library's percentage (0-100)
test("LFO modulates around the stored value without writing it, and restores on disable", function()
  local context = load_strata(); finish_startup(context)
  params:set("filter_freq", 1000); params:set("strata_lfo1_dest", 4)   -- filt freq
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.clear_engine_calls(); context.lfo.tick(local_value("lfos")[1], 1.0)   -- scaled = +0.5
  local call = context.calls_named("setFilter")[1]
  assert_near(call.args[1], 1000 + 0.5 * 0.5 * (20000 - 20), 1e-6)
  assert_near(params:get("filter_freq"), 1000, 1e-9, "param value untouched")
  context.clear_engine_calls(); params:set("lfo_1", 1)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000, 1e-6, "disable restores the stored value")
end)

test("main destination follows a voice's source and restores the old param", function()
  local context = load_strata(); finish_startup(context)
  params:set("strata_lfo2_dest", 13)   -- v1 main
  params:set("lfo_depth_2", 100); params:set("lfo_2", 2)
  context.lfo.tick(local_value("lfos")[2], 0.5)
  assert_equal(local_value("lfo_last_dest")[2], "v1_freq")
  params:set("v1_source", 2); context.clear_engine_calls(); context.lfo.tick(local_value("lfos")[2], 0.5)
  local voice_calls = context.calls_named("setVoiceParam")
  assert_equal(voice_calls[1].args[2], "freq"); assert_near(voice_calls[1].args[3], params:get("v1_freq"), 1e-9)
  assert_equal(local_value("lfo_last_dest")[2], "v1_buf_pos")
end)

test("LFO restores the stored value when its depth reaches 0 or its destination changes", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  params:set("delay_mix", 0.2); params:set("strata_lfo1_dest", 9)   -- dly mix
  params:set("lfo_depth_1", 40); params:set("lfo_1", 2)
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)     -- scaled +0.4
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2 + 0.4 * 0.5, 1e-9, "modulated mix")
  context.clear_engine_calls(); params:set("lfo_depth_1", 0)
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9, "depth 0 restores")
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)
  assert_equal(#context.engine_calls, 0, "a depth-0 LFO sends nothing")
  params:set("lfo_depth_1", 40); context.clear_engine_calls()
  context.lfo.tick(lfos[1], 0.0)                                    -- scaled -0.4: clamped at 0
  assert_near(context.calls_named("setDelay")[1].args[3], 0, 1e-9, "modulated value clamps to the range")
  context.clear_engine_calls(); params:set("strata_lfo1_dest", 10)  -- rev mix
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9, "destination change restores the old one")
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)
  assert_equal(#context.calls_named("setDelay"), 0, "old destination left alone")
  assert_near(context.calls_named("setReverb")[1].args[1], util.clamp(params:get("reverb_mix") + 0.2, 0, 1), 1e-9,
    "new destination modulated")
  context.clear_engine_calls(); params:set("strata_lfo1_dest", 1)   -- none
  context.lfo.tick(lfos[1], 1.0)
  assert_near(context.calls_named("setReverb")[1].args[1], params:get("reverb_mix"), 1e-9, "none restores")
  assert_equal(#context.calls_named("setReverb"), 1, "and then sends nothing")
end)

test("a full-depth LFO clamps its destination to both ends of the range (#50)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  params:set("strata_lfo1_dest", 8)   -- dly fdbk, 0-0.95
  params:set("lfo_depth_1", 100); params:set("lfo_1", 2)
  -- each tick moves the sent value well past the send threshold
  params:set("delay_feedback", 0.95); context.lfo.tick(lfo, 0.0)    -- scaled -1: 0.475 sent
  context.clear_engine_calls(); context.lfo.tick(lfo, 1.0)          -- scaled +1: 0.95 + 0.475
  assert_near(context.calls_named("setDelay")[1].args[2], 0.95, 1e-9, "clamped at the top of the range")
  params:set("delay_feedback", 0)                                   -- 0 + 0.475 sent
  context.clear_engine_calls(); context.lfo.tick(lfo, 0.0)          -- scaled -1: 0 - 0.475
  assert_near(context.calls_named("setDelay")[1].args[2], 0, 1e-9, "clamped at the bottom of the range")
  assert_near(params:get("delay_feedback"), 0, 1e-9, "param value untouched")
end)

-- sync_voice_values_to_engine sends the stored density, so the modulated
-- value sent before the restart must be forgotten: master density scales
-- what the engine has
test("a restarted voice's grain density scales from its stored value until the next LFO step (#50)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  assert_true(voices[1].active, "voice 1 is running")
  params:set("v1_grain_density", 20); params:set("master_density", 1)
  params:set("strata_lfo1_dest", 15)   -- v1 dens
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(local_value("lfos")[1], 1.0)   -- scaled +0.5: the engine gets a modulated density
  assert_equal(voices[1].grain.density, 20, "the stored density is untouched")
  toggle_voice(1); toggle_voice(1)                -- restart: the sync sends the stored density
  context.clear_engine_calls()
  params:set("master_density", 1.5)               -- before the LFO's next step
  local density_calls = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "grainDensity" then table.insert(density_calls, call) end
  end
  assert_equal(#density_calls, 1, "master density resends voice 1's grain density")
  assert_near(density_calls[1].args[3], 20 * 1.5, 1e-6, "from the stored density, not the modulated one")
end)

test("LFOs on params of one command, or on one param, do not undo each other", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  params:set("filter_freq", 1000); params:set("filter_res", 0.5)
  params:set("strata_lfo1_dest", 4); params:set("strata_lfo2_dest", 5)   -- filt freq, filt res
  for n = 1, 2 do params:set("lfo_depth_" .. n, 20); params:set("lfo_" .. n, 2) end
  context.lfo.tick(lfos[1], 1.0); context.clear_engine_calls(); context.lfo.tick(lfos[2], 1.0)
  local call = context.calls_named("setFilter")[1]
  assert_near(call.args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "LFO 2 keeps LFO 1's filter freq")
  assert_near(call.args[2], 0.5 + 0.2 * 0.5, 1e-6, "and adds its res")
  -- a user change to res is sent with the modulated freq
  context.clear_engine_calls(); params:set("filter_res", 0.3)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "freq stays modulated")
  -- two LFOs on one destination add up; disabling one leaves the other's offset
  params:set("strata_lfo2_dest", 4)
  context.lfo.tick(lfos[1], 1.0); context.clear_engine_calls(); context.lfo.tick(lfos[2], 1.0)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.4 * 0.5 * 19980, 1e-6, "offsets add")
  context.clear_engine_calls(); params:set("lfo_2", 1)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "LFO 1 still applies")
  -- master density modulation reaches every running voice's grain density
  params:set("strata_lfo1_dest", 2); params:set("master_density", 1)
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)       -- +0.2 * 0.5 * 1.9
  local voices = local_value("voices")
  for _, density_call in ipairs(context.calls_named("setGrainParam")) do
    local voice_idx = density_call.args[1] + 1
    assert_true(voices[voice_idx].active, "only running voices")
    assert_near(density_call.args[3], voices[voice_idx].grain.density * (1 + 0.19), 1e-6, "modulated density")
  end
  assert_true(#context.calls_named("setGrainParam") >= 1, "a running voice got its density")
  assert_near(params:get("master_density"), 1, 1e-9, "master density param untouched")
end)

test("LFO params: library groups, a destination group, labels and resolvers", function()
  load_strata()
  local destinations = local_value("LFO_DESTINATIONS")
  local S = local_value("S")
  assert_equal(S.lib.lfos.BUILT_IN_DESTINATIONS, 12 + 7 * 8, "12 globals, 8 per voice")
  assert_equal(#destinations, 12 + 7 * 8 + 7 * #S.registry.lfo_destinations, "then 7 per registered destination")
  local expected_ids = { [1] = nil, [2] = "master_density", [3] = "drift_amount", [4] = "filter_freq",
    [5] = "filter_res", [6] = "filter_mix", [7] = "delay_time", [8] = "delay_feedback", [9] = "delay_mix",
    [10] = "reverb_mix", [11] = "reverb_size", [12] = "reverb_damp", [13] = "v1_freq", [14] = "v1_grain_size",
    [15] = "v1_grain_density", [16] = "v1_grain_pitch", [17] = "v1_grain_spread", [18] = "v1_buf_pos",
    [19] = "v1_buf_rate", [20] = "v1_buf_scan", [21] = "v2_index", [68] = "v7_buf_scan" }
  for index = 1, #destinations do
    local resolved = destinations[index].resolve()
    if expected_ids[index] or index == 1 then
      assert_equal(resolved, expected_ids[index], "destination " .. index)
    end
    if resolved then assert_true(params:lookup_param(resolved).controlspec, resolved .. " is a control param") end
    assert_true(stubs.text_width(destinations[index].label) <= 49, destinations[index].label .. " fits its column")
  end
  assert_equal(destinations[13].label, "v1 main")
  local group = params:lookup_param("strata_lfos")
  assert_equal(group.t, params.tGROUP); assert_equal(group.n, 3, "destination group holds the three dests")
  for n = 1, 3 do
    local dest = params:lookup_param("strata_lfo" .. n .. "_dest")
    assert_equal(dest.count, #destinations); assert_equal(params:get("strata_lfo" .. n .. "_dest"), 1, "none")
    assert_equal(params:lookup_param("lfo_group_" .. n).n, 15, "the library's own group")
    assert_equal(params:string("lfo_" .. n), "off", "LFOs start off")
    assert_equal(params:get("lfo_depth_" .. n), 25, "LFOs start at 25% depth")
    assert_equal(params:string("lfo_mode_" .. n), "free")
    assert_near(params:get("lfo_free_" .. n), 4, 1e-9, "4 s period")
    assert_equal(params:string("lfo_baseline_" .. n), "from center")
    local lfo = local_value("lfos")[n]
    assert_equal(lfo:get("min"), -1); assert_equal(lfo:get("max"), 1)
  end
end)

test("param actions under a running LFO send the modulated value (drift, edits)", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  params:set("v1_source", 2)                                     -- buf 1: the drift moves buf_pos
  params:set("v1_buf_pos", 0.4); params:set("strata_lfo1_dest", 18)  -- v1 pos
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(lfos[1], 1.0)                                 -- scaled +0.5: +0.25 of the range
  math.randomseed(5)
  context.clear_engine_calls(); drift_update()
  local sent
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "bufPos" then sent = call.args[3] end
  end
  assert_true(params:get("v1_buf_pos") ~= 0.4, "the drift moved the stored position")
  assert_near(sent, params:get("v1_buf_pos") + 0.25, 1e-9, "drift sends the position with the LFO offset")
  -- a user edit of a modulated FX param keeps the offset too
  params:set("filter_freq", 1000); params:set("strata_lfo2_dest", 4)
  params:set("lfo_depth_2", 20); params:set("lfo_2", 2); context.lfo.tick(lfos[2], 1.0)
  context.clear_engine_calls(); params:set("filter_freq", 2000)
  assert_near(context.calls_named("setFilter")[1].args[1], 2000 + 0.2 * 0.5 * 19980, 1e-6, "edit keeps the offset")
  -- unmodulated params still send exactly their value
  context.clear_engine_calls(); params:set("filter_res", 0.3)
  assert_near(context.calls_named("setFilter")[1].args[2], 0.3, 1e-9)
end)

test("LFO steps run at 48 ppqn and skip sends below 1/1000 of the range; restores always send", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  for n = 1, 3 do assert_equal(lfos[n]:get("ppqn"), 48, "LFO " .. n .. " ppqn") end
  params:set("filter_mix", 0.5); params:set("strata_lfo1_dest", 6)  -- filt mix (0-1)
  params:set("lfo_free_1", 300); params:set("lfo_depth_1", 100); params:set("lfo_1", 2)
  -- ten seconds of a 300 s sine at 120 BPM: 96 steps a second, from the floor
  local steps = 10 * 96
  context.clear_engine_calls()
  for step = 1, steps do
    context.lfo.tick(lfos[1], (math.sin(2 * math.pi * (0.75 + step / (300 * 96))) + 1) / 2)
  end
  local calls = context.calls_named("setFilter")
  assert_true(#calls >= 5 and #calls <= 15, "a slow LFO sends rarely (" .. #calls .. " of " .. steps .. " steps)")
  for index = 2, #calls do
    assert_true(math.abs(calls[index].args[4] - calls[index - 1].args[4]) >= 0.001 - 1e-12, "each send moves >= 1/1000")
  end
  -- a step below the threshold is skipped, but turning the LFO off restores at once
  local last_sent = calls[#calls].args[4]
  context.clear_engine_calls()
  -- (mix 0.5 at depth 100: the sent mix equals the raw value)
  context.lfo.tick(lfos[1], last_sent + 0.0004)
  assert_equal(#context.calls_named("setFilter"), 0, "tiny step skipped")
  params:set("lfo_1", 1)
  calls = context.calls_named("setFilter")
  assert_equal(#calls, 1, "restore sends"); assert_near(calls[1].args[4], 0.5, 1e-9, "stored mix restored")
  assert_true(last_sent ~= 0.5, "the restore was a change")
  -- a restore sends even when the engine already has the stored value
  params:set("lfo_1", 2); context.lfo.tick(lfos[1], 0.5)        -- scaled 0: value 0.5
  context.clear_engine_calls(); params:set("lfo_depth_1", 0)
  assert_equal(#context.calls_named("setFilter"), 1, "depth 0 restore sends")
  -- a fast LFO sends on every step
  params:set("lfo_depth_1", 100); context.clear_engine_calls()
  for step = 1, 20 do context.lfo.tick(lfos[1], step % 2) end
  assert_equal(#context.calls_named("setFilter"), 20, "large steps all sent")
end)

-- The threshold is measured on the destination's warp: on an exponential
-- range (v1_freq, 20-2000 Hz) a slow LFO sends steps even in octaves, not
-- even in hertz (#406)
test("a slow LFO on an exponential destination sends steps of at most 10.4 cents (#406)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  params:set("v1_freq", 60); params:set("strata_lfo1_dest", 13)   -- v1 main: the Resonator's freq
  params:set("lfo_free_1", 8); params:set("lfo_depth_1", 1); params:set("lfo_1", 2)
  context.clear_engine_calls()
  -- one 8 s cycle at 120 BPM (768 steps of 48 a beat) from the floor:
  -- 60 Hz +/- 0.01 x 0.5 x 1980 Hz, so 50.1 to 69.9 Hz
  for step = 1, 768 do
    context.lfo.tick(lfo, (math.sin(2 * math.pi * (0.75 + step / 768)) + 1) / 2)
  end
  local sent = {}
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 0 and call.args[2] == "freq" then table.insert(sent, call.args[3]) end
  end
  -- 1/1000 of the range's log2(100) = 6.64 octaves is 7.97 cents, and one
  -- step moves at most 2.37 cents (9.9 Hz x 2 pi / 768, at 58.4 Hz), so a
  -- send moves 7.97 to 10.34 cents (with a linear threshold: 2 Hz, 68 cents)
  assert_true(#sent >= 100, "the glide is sent in small steps (" .. #sent .. " sends)")
  local largest = 0
  for index = 2, #sent do
    local cents = math.abs(1200 * math.log(sent[index] / sent[index - 1]) / math.log(2))
    assert_true(cents >= 7.97, "send " .. index .. " moves at least 1/1000 of the octaves (" .. cents .. ")")
    largest = math.max(largest, cents)
  end
  assert_true(largest <= 10.4, "the largest step is " .. largest .. " cents")
end)

-- The threshold measures with a step-0 copy of the destination's
-- controlspec: the param's own spec is never changed, even for the length
-- of a call that raises
test("an LFO step never changes its destination's controlspec, even when unmap raises (#406)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  local spec = params:lookup_param("filter_mix").controlspec
  assert_near(spec.step, 0.01, 1e-12, "filter mix steps by 0.01")
  params:set("filter_mix", 0.5); params:set("strata_lfo1_dest", 6)   -- filt mix
  params:set("lfo_depth_1", 100); params:set("lfo_1", 2)
  spec.unmap = function() error("unmap boom") end   -- the live spec's own unmap raises
  context.printed = {}
  local ok, problem = pcall(function()
    context.clear_engine_calls()
    for step = 1, 3 do context.lfo.tick(lfo, step % 2) end
    assert_near(spec.step, 0.01, 1e-12, "the live spec keeps its step")
    assert_equal(#context.calls_named("setFilter"), 3, "and every step that moved far enough was sent")
  end)
  spec.unmap = nil
  if not ok then error(problem, 0) end
end)

-- norns' Lua 5.3 math.random raises on an empty interval, inside the
-- lattice, when a random LFO's min is above its max: Strata keeps min at or
-- below max, whichever of the two is set (#528)
test("the stub's random step raises when min is above max, as the library does (#528)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  params:set("lfo_shape_1", 4); params:set("lfo_1", 2)   -- random
  lfo:set("min", 0.5); lfo:set("max", 0.2)                 -- past Strata's params
  local stepped, step_error = pcall(context.lfo.tick, lfo, 1.0)
  assert_true(not stepped, "the step raises")
  assert_true(tostring(step_error):find("interval is empty", 1, true), tostring(step_error))
end)

test("lfo min never rises above lfo max, so a random LFO keeps stepping (#528)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  params:set("strata_lfo1_dest", 4); params:set("lfo_shape_1", 4); params:set("lfo_1", 2)   -- random
  params:set("lfo_min_1", 0.5)
  assert_near(params:get("lfo_max_1"), 1, 1e-9, "a min below max leaves max alone")
  params:set("lfo_max_1", 0.2)
  assert_near(params:get("lfo_min_1"), 0.2, 1e-9, "max set below min takes min down with it")
  assert_near(lfo:get("min"), 0.2, 1e-9); assert_near(lfo:get("max"), 0.2, 1e-9, "and so does the library")
  params:set("lfo_min_1", 0.8)
  assert_near(params:get("lfo_max_1"), 0.8, 1e-9, "min set above max takes max up with it")
  assert_near(lfo:get("min"), 0.8, 1e-9); assert_near(lfo:get("max"), 0.8, 1e-9)
  params:set("lfo_max_1", 0.9); params:set("lfo_min_1", -0.4)
  for _, raw in ipairs({1.0, 0.0, 1.0}) do context.lfo.tick(lfo, raw) end   -- each half cycle draws a value
  assert_near(lfo:get("min"), -0.4, 1e-9); assert_near(lfo:get("max"), 0.9, 1e-9, "a valid pair stays as set")
  -- the bound set moves the other, never itself, so a pair loaded one value
  -- at a time (a PSET) lands as stored, in either order
  params:set("lfo_min_1", 0.6); params:set("lfo_max_1", 0.7)
  params:set("lfo_min_1", 0.8); params:set("lfo_max_1", 0.9)
  assert_near(params:get("lfo_min_1"), 0.8, 1e-9); assert_near(params:get("lfo_max_1"), 0.9, 1e-9, "min first")
  params:set("lfo_max_1", -0.3); params:set("lfo_min_1", -0.5)
  assert_near(params:get("lfo_min_1"), -0.5, 1e-9); assert_near(params:get("lfo_max_1"), -0.3, 1e-9, "max first")
end)

-- norns' lattice runs every LFO: an error raised in one LFO's action would
-- stop them all for the session (#517)
test("an error inside an LFO step is printed once and the LFO keeps stepping (#517)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local lfo = local_value("lfos")[1]
  params:set("filter_freq", 1000); params:set("strata_lfo1_dest", 4)   -- filt freq
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  local real_send = S.lib.engine_sync.send_engine_value
  local failure = "lfo step boom"
  S.lib.engine_sync.send_engine_value = function(...)
    if failure then error(failure) end
    return real_send(...)
  end
  local function reports()
    local count, traced = 0, false
    for _, line in ipairs(context.printed) do
      if line:find("strata: LFO 1 step failed: ", 1, true) == 1 then
        count = count + 1
        traced = traced or line:find("stack traceback", 1, true) ~= nil
      end
    end
    return count, traced
  end
  context.printed = {}
  local ok, problem = pcall(function()
    for step = 1, 5 do context.lfo.tick(lfo, step % 2) end   -- each step moves far enough to send
    local count, traced = reports()
    assert_equal(count, 1, "the same error on every step prints once")
    assert_true(traced, "with its traceback")
    failure = nil
    context.clear_engine_calls(); context.lfo.tick(lfo, 1.0)
    assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.5 * 0.5 * 19980, 1e-6, "the next good step sends")
    failure = "lfo step boom"
    context.lfo.tick(lfo, 0.0)
    assert_equal(reports(), 2, "the error after a good step prints again")
    failure = "another lfo boom"
    context.lfo.tick(lfo, 0.0)   -- (the failed step sent nothing: the engine still has raw 1.0's value)
    assert_equal(reports(), 3, "a different message prints at once")
  end)
  S.lib.engine_sync.send_engine_value = real_send
  if not ok then error(problem, 0) end
  h.claim_script_errors(context, 3, "strata: LFO 1 step failed: ", "another lfo boom")  -- the three it caused (#473)
end)

-- The dot's estimate against the library's phase. The stub has no lattice:
-- run_lfo moves the time and adds what the lattice would to phase_counter
-- (1/ppqn per step, ppqn steps a beat: one per beat)
local function run_lfo(context, lfo, seconds)
  context.set_time(util.time() + seconds)
  lfo.phase_counter = lfo.phase_counter + seconds / clock.get_beat_sec()
end

test("a clocked LFO's dot runs at its period in beats, through a clocked rate change (#415)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  assert_near(clock.get_beat_sec(), 0.5, 1e-12, "120 BPM")
  context.set_time(100)
  params:set("lfo_mode_1", 1)   -- clocked at rate "4": a 16-beat period, 8 s
  assert_near(lfo:get("period"), 16, 1e-12)
  params:set("lfo_1", 2)        -- reset to the floor
  assert_near(lfo_phase_estimate(1), 0.75, 1e-9, "the floor")
  run_lfo(context, lfo, 1)      -- 2 beats of 16
  assert_near(lfo_phase_estimate(1), 0.875, 1e-9, "1 s is an eighth of the 8 s cycle")
  params:set("lfo_clocked_1", 12)   -- rate "3": a 12-beat period, 6 s
  assert_near(lfo_phase_estimate(1), 0.875, 1e-9, "a rate change keeps the dot's place")
  run_lfo(context, lfo, 1)
  assert_near(lfo_phase_estimate(1), 0.875 + 1 / 6 - 1, 1e-9, "then it runs at the new period")
  -- the library's change_period keeps its phase within 1/ppqn of a step
  assert_near(lfo_phase_estimate(1), (lfo.phase_counter / lfo:get("period")) % 1, 0.002, "where the library is")
end)

-- the library's lfo_mode action sets the mode, then the period, which its
-- change_period scales in the new mode's unit: the phase jumps, and the dot
-- jumps with it (#409)
test("a mode switch at 120 BPM moves the dot to the library's phase, both ways (#409)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  context.set_time(100)
  params:set("lfo_1", 2)        -- free, 4 s: the floor, phase_counter 6 beats
  run_lfo(context, lfo, 0.5)    -- phase_counter 7: 7 x 0.5 / 4
  assert_near(lfo_phase_estimate(1), 0.875, 1e-9, "free: the dot and the library agree")
  params:set("lfo_mode_1", 1)   -- clocked: ((7 + 1/48) / 4 x 16 - 1/48) / 16
  assert_near(lfo_phase_estimate(1), 0.75390625, 1e-9, "to clocked: the dot is where the library is")
  run_lfo(context, lfo, 1)      -- 2 of 16 beats
  assert_near(lfo_phase_estimate(1), 0.87890625, 1e-9, "and runs with it")
  params:set("lfo_mode_1", 2)   -- free: ((30.0625 + 1/48) x 0.5 / 16 x 4 / 0.5 - 1/48) x 0.5 / 4
  assert_near(lfo_phase_estimate(1), 0.9375, 1e-9, "back to free: the library's phase again")
  run_lfo(context, lfo, 1)
  assert_near(lfo_phase_estimate(1), 0.1875, 1e-9, "a quarter of the 4 s cycle on")
end)

-- LFO:reset_phase's targets: floor 3/4, ceiling 1/4, mid: falling 1/2 of a
-- cycle; mid: rising sets phase_counter to (beat length / period) itself,
-- so a free LFO restarts at (beat length / period)^2 of its cycle and a
-- clocked one at 0
test("each reset target starts the dot where the library restarts (#415)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  context.set_time(100)
  params:set("lfo_1", 2)   -- free, 4 s, at 120 BPM
  local free_phases = {0.75, 0.25, 1 / 64, 0.5}   -- floor, ceiling, mid: rising, mid: falling
  for target, phase in ipairs(free_phases) do
    run_lfo(context, lfo, 0.3)
    params:set("lfo_reset_target_1", target); params:set("lfo_reset_1", 1)
    assert_near(lfo_phase_estimate(1), phase, 1e-9, "free: " .. params:string("lfo_reset_target_1"))
  end
  params:set("lfo_mode_1", 1)   -- clocked, 16 beats
  local clocked_phases = {0.75, 0.25, 0, 0.5}
  for target, phase in ipairs(clocked_phases) do
    run_lfo(context, lfo, 0.3)
    params:set("lfo_reset_target_1", target); params:set("lfo_reset_1", 1)
    assert_near(lfo_phase_estimate(1), phase, 1e-9, "clocked: " .. params:string("lfo_reset_target_1"))
  end
end)

test("turning an LFO off forgets its last raw value (#415)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  params:set("strata_lfo1_dest", 4); params:set("lfo_1", 2)
  context.lfo.tick(lfo, 0.25)
  assert_near(local_value("lfo_last_raw")[1], 0.25, 1e-9, "a step keeps its raw value")
  params:set("lfo_1", 1)
  assert_equal(local_value("lfo_last_raw")[1], nil, "off forgets it")
  params:set("lfo_1", 2)
  assert_equal(local_value("lfo_last_raw")[1], nil, "so on again has no dot until its first step")
end)

test("cleanup stops the LFOs and restores their destinations", function()
  local context = load_strata(); finish_startup(context)
  params:set("filter_freq", 800); params:set("strata_lfo1_dest", 4)
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(local_value("lfos")[1], 1.0)
  context.clear_engine_calls(); cleanup()
  assert_equal(params:get("lfo_1"), 1); assert_equal(local_value("lfos")[1]:get("enabled"), 0)
  assert_near(context.calls_named("setFilter")[1].args[1], 800, 1e-6, "destination restored")
end)

-- the library's on/off action re-bangs the baseline, whose change_offset
-- zeroes the offset (#103): Strata keeps it across on/off, wherever the
-- state is set, while a real baseline change still zeroes it
test("an LFO keeps its offset when turned on or off, and a baseline change zeroes it (#103)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[2]
  params:set("lfo_offset_2", 15)
  params:set("lfo_2", 2)
  assert_equal(params:get("lfo_offset_2"), 15, "on through PARAMS keeps the offset")
  assert_near(lfo:get("offset"), 0.15, 1e-9, "and so does the library")
  params:set("lfo_2", 1)
  assert_equal(params:get("lfo_offset_2"), 15, "off through PARAMS keeps it")
  params:set("lfo_offset_2", -20); params:set("lfo_2", 2)
  assert_equal(params:get("lfo_offset_2"), -20, "a negative offset too")
  params:set("lfo_baseline_2", 1)   -- from min
  assert_equal(params:get("lfo_offset_2"), 0, "a baseline change zeroes it, as the library intends")
  params:set("lfo_offset_2", 30); params:set("lfo_baseline_2", 2)
  assert_equal(params:get("lfo_offset_2"), 0, "back to center zeroes it again")
  params:set("lfo_offset_2", 10); params:set("lfo_2", 1)
  assert_equal(params:get("lfo_offset_2"), 10, "and on/off keeps the new one")
end)

test("setting a running LFO's state on again restarts its phase and the dot, as the library does (#251)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  params:set("lfo_1", 2)
  local fresh = lfo_phase_estimate(1)
  local fresh_counter = lfo.phase_counter
  context.clock.run_for(0.3)
  assert_true(math.abs(lfo_phase_estimate(1) - fresh) > 0.01, "the dot has moved since the start")
  local resets = lfo.reset_count
  params:lookup_param("lfo_1"):bang()  -- the library's state action ends with lfo_bang, which bangs lfo_reset_1
  assert_equal(lfo.reset_count, resets + 1, "the library reset its phase")
  assert_near(lfo.phase_counter, fresh_counter, 1e-9, "to the reset target's phase")
  assert_near(lfo_phase_estimate(1), fresh, 1e-9, "and the dot restarted with it")
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
  -- every call the sender makes is among the calls the edit made (an action may add its own other calls)
  local function contains_all(got, expected)
    local present = {}
    for _, text in ipairs(got) do present[text] = true end
    for _, text in ipairs(expected) do
      if not present[text] then return false, text end
    end
    return true
  end
  -- a value of the param other than its current one
  local function other_value(param)
    local spec = param.controlspec
    local value = spec:map(0.35)
    if math.abs(value - params:get(param.id)) < 1e-9 then value = spec:map(0.65) end
    return value
  end
  local checked = 0
  for _, param in ipairs(params.params) do
    if param.t == params.tCONTROL and param.id:sub(1, 5) ~= "lfo_" and param.id:sub(1, 6) ~= "strata" then
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

end

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

end

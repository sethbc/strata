-- test/unit/scenes_test.lua
-- Scenes: capture, recall, transitions, the scene sequencer, migration,
-- validation and scenes.data (lib/scenes.lua)
-- Run alone: lua test/run.lua scenes

return function(h)
local test, data_root, assert_true, assert_equal = h.test, h.data_root, h.assert_true, h.assert_equal
local assert_near, load_strata, local_value = h.assert_near, h.load_strata, h.local_value
local next_frame, finish_startup, wake, deep_copy = h.next_frame, h.finish_startup, h.wake, h.deep_copy
local tabutil_text, assert_voice_matches = h.tabutil_text, h.assert_voice_matches
local scramble_state, engine_state_for_voice = h.scramble_state, h.engine_state_for_voice
local show_page, count_screen_draws, screen_shows = h.show_page, h.count_screen_draws, h.screen_shows
local assert_drawn_on_next_frame, FX_PARAM_IDS = h.assert_drawn_on_next_frame, h.FX_PARAM_IDS

test("scene capture -> change -> recall restores every voice", function()
  local context = load_strata()
  finish_startup(context)  -- let init start voice 2
  scramble_state(11)
  toggle_voice(3)
  toggle_lock(1)
  toggle_pattern_step(4, 5)
  params:set("reverb_mix", 0.71)
  capture_scene(2)
  local scenes = local_value("scenes")
  local captured = deep_copy(scenes[2].data)
  assert_true(validate_scene_data(scenes), "a captured scene validates")

  scramble_state(99)
  toggle_voice(3)   -- off again
  toggle_voice(6)   -- on
  toggle_lock(1)
  toggle_pattern_step(4, 5)
  params:set("reverb_mix", 0.1)

  context.clear_engine_calls()
  recall_scene(2, 0)
  local voices = local_value("voices")
  local frozen = local_value("frozen")
  local patterns = local_value("patterns")
  for voice_idx = 1, 7 do
    assert_voice_matches(voice_idx, voices[voice_idx], captured.voices[voice_idx])
    assert_equal(frozen[voice_idx], captured.frozen[voice_idx], "voice " .. voice_idx .. " frozen")
    for step = 1, 16 do
      assert_equal(patterns[voice_idx][step], captured.patterns[voice_idx][step], "pattern " .. voice_idx .. "/" .. step)
    end
  end
  assert_near(params:get("reverb_mix"), 0.71, 1e-9, "reverb mix")
  -- voice 3 was restarted by the recall: the engine got its recalled state
  local started = false
  for _, call in ipairs(context.calls_named("voiceOn")) do
    if call.args[1] == 2 then started = true end
  end
  assert_true(started, "recall started voice 3")
  for _, call in ipairs(context.calls_named("setModSource")) do
    if call.args[1] == 2 then
      local source = captured.voices[3].crossmod["slot" .. call.args[2]].source
      assert_equal(call.args[3], source == 0 and -1 or source - 1, "voice 3 mod source sent after recall")
    end
  end
end)

test("validate_scene_data rejects malformed scenes and accepts captured ones", function()
  load_strata()
  capture_scene(1)
  local scenes = local_value("scenes")
  local good = deep_copy(scenes)
  assert_true(validate_scene_data(good), "captured scenes are valid")

  local function rejects(mutator, message)
    local candidate = deep_copy(good)
    mutator(candidate[1].data, candidate)
    assert_true(not validate_scene_data(candidate), "should reject: " .. message)
  end
  rejects(function(data) data.frozen = nil end, "missing frozen")
  rejects(function(data) data.frozen[3] = nil end, "frozen entry missing")
  rejects(function(data) data.patterns[2][16] = nil end, "short pattern")
  rejects(function(data) data.patterns[7] = nil end, "missing pattern row")
  rejects(function(data) data.patterns[1][1] = "x" end, "non-numeric step")
  -- a step is a whole level 0..MAX_STEP_LEVEL
  rejects(function(data) data.patterns[1][1] = local_value("MAX_STEP_LEVEL") + 1 end, "step level past MAX_STEP_LEVEL")
  rejects(function(data) data.patterns[1][1] = 2.5 end, "fractional step level")
  rejects(function(data) data.patterns[1][1] = -1 end, "negative step level")
  rejects(function(data) data.master_density = "loud" end, "non-numeric master_density")
  rejects(function(data) data.tempo = nil end, "missing tempo")
  rejects(function(data) data.reverb_damp = {} end, "non-numeric reverb_damp")
  rejects(function(data) data.voices[7] = nil end, "missing voice")
  rejects(function(data) data.voices[2].crossmod.slot2 = nil end, "missing crossmod slot")
  rejects(function(data) data.voices[2].crossmod.slot1.source = 9 end, "out-of-range mod source")
  -- recall would send engine.setModSpeed with nil
  rejects(function(data) data.voices[4].crossmod.speed = nil end, "missing mod speed")
  rejects(function(data) data.voices[4].crossmod.speed = "fast" end, "non-numeric mod speed")
  rejects(function(data) data.voices[1].params.bogus = 1 end, "unknown voice param")
  rejects(function(data) data.voices[1].grain.size = "big" end, "non-numeric grain param")
  rejects(function(data, all) all[1].populated = "yes" end, "non-boolean populated")
  assert_true(not validate_scene_data("nope"), "should reject a non-table")
  assert_true(not validate_scene_data({ [3] = 7 }), "should reject a non-table slot")
end)

test("scene files: round trip, version check, missing slots, erroring file", function()
  local context = load_strata({ data_subdir = "roundtrip" })
  finish_startup(context)
  scramble_state(5)
  capture_scene(4)
  save_scenes_to_disk()
  local saved = deep_copy(local_value("scenes")[4].data)

  -- reload into a fresh script: auto-load in init restores the scene
  context = load_strata({ data_subdir = "roundtrip" })
  local scenes = local_value("scenes")
  assert_true(scenes[4].populated, "scene 4 reloaded from disk")
  assert_near(scenes[4].data.voices[1].params.freq, saved.voices[1].params.freq, 1e-9, "scene 4 data")
  for slot = 1, 8 do assert_true(scenes[slot] ~= nil, "slot " .. slot .. " exists") end
  local file_path = context.data_dir .. "strata/scenes.data"

  -- a file that raises an error when run must not break init
  local file = assert(io.open(file_path, "w"))
  file:write('error("corrupt scenes file")')
  file:close()
  context = load_strata({ data_subdir = "roundtrip" })
  scenes = local_value("scenes")
  for slot = 1, 8 do assert_true(scenes[slot] and scenes[slot].populated == false, "empty slot " .. slot) end
  load_scenes_from_disk()  -- the manual trigger survives it too

  -- wrong version is rejected
  file = assert(io.open(file_path, "w"))
  file:write(tabutil_text({ version = 99, scenes = {} }))
  file:close()
  context = load_strata({ data_subdir = "roundtrip" })
  local found = false
  for _, line in ipairs(context.printed) do
    if line:find("version 99") then found = true end
  end
  assert_true(found, "version mismatch reported")

  -- a pre-2.1 bare array with only some slots loads, missing slots filled
  local legacy = { [1] = { name = "scene 1", populated = false, data = {} } }
  legacy[2] = { name = "scene 2", populated = true, data = saved }
  context.tab.save(legacy, file_path)
  context = load_strata({ data_subdir = "roundtrip" })
  scenes = local_value("scenes")
  assert_true(scenes[2].populated, "legacy scene 2 loaded")
  for slot = 3, 8 do assert_true(scenes[slot] and scenes[slot].populated == false, "filled slot " .. slot) end
  recall_scene(2, 0)
  grid_redraw()
end)

test("a scenes file that fails to load survives cleanup (fix round 1)", function()
  local bad_files = {
    { name = "wrong version", content = tabutil_text({ version = 99, scenes = {} }) },
    { name = "raises on load", content = 'error("corrupt scenes file")' },
  }
  -- a versioned file with one bad slot (validate_scene_data rejects it whole)
  local context = load_strata({ data_subdir = "survive_source" })
  capture_scene(1)
  capture_scene(2)
  local scenes = deep_copy(local_value("scenes"))
  scenes[2].data.frozen = nil
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  local bad_slot_path = context.data_dir .. "bad_slot.data"
  context.tab.save({ version = 1, scenes = scenes }, bad_slot_path)
  local bad_slot_file = assert(io.open(bad_slot_path, "r"))
  table.insert(bad_files, { name = "one bad slot", content = bad_slot_file:read("*a") })
  bad_slot_file:close()

  for index, bad in ipairs(bad_files) do
    local subdir = "survive_" .. index
    local data_dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. data_dir .. "'")
    local file = assert(io.open(data_dir .. "scenes.data", "w"))
    file:write(bad.content)
    file:close()

    context = load_strata({ data_subdir = subdir })  -- init's load fails
    for slot = 1, 8 do
      assert_true(local_value("scenes")[slot].populated == false, bad.name .. ": scenes empty after failed load")
    end
    capture_scene(3)  -- new work after the failed load
    cleanup()
    local backup = io.open(data_dir .. "scenes.data.bak", "r")
    assert_true(backup ~= nil, bad.name .. ": original kept as scenes.data.bak")
    assert_equal(backup:read("*a"), bad.content, bad.name .. ": backup content unchanged")
    backup:close()
    -- the new save is a valid file again
    context = load_strata({ data_subdir = subdir })
    assert_true(local_value("scenes")[3].populated, bad.name .. ": new work saved on exit")
  end

  -- if the file cannot be moved aside, cleanup must not overwrite it
  local data_dir = data_root .. "survive_blocked/strata/"
  os.execute("mkdir -p '" .. data_dir .. "scenes.data.bak/occupied'")  -- rename target is a non-empty dir
  local file = assert(io.open(data_dir .. "scenes.data", "w"))
  file:write(bad_files[1].content)
  file:close()
  load_strata({ data_subdir = "survive_blocked" })
  cleanup()
  file = assert(io.open(data_dir .. "scenes.data", "r"))
  assert_equal(file:read("*a"), bad_files[1].content, "unmovable bad file not overwritten by cleanup")
  file:close()
end)

-- #72: a start that failed before init loaded scenes.data must not let
-- cleanup overwrite it with the empty in-memory scenes
test("cleanup leaves scenes.data alone when init never loaded it (#72)", function()
  local sentinel = "-- scenes saved by an earlier session\nreturn {}\n"
  local started
  local function write_sentinel(context)
    started = context
    os.execute("mkdir -p '" .. context.data_dir .. "strata/'")
    local file = assert(io.open(context.data_dir .. "strata/scenes.data", "w"))
    file:write(sentinel)
    file:close()
  end
  local function scenes_file_text()
    local file = assert(io.open(started.data_dir .. "strata/scenes.data", "r"))
    local text = file:read("*a")
    file:close()
    return text
  end

  local before_loads, count = h.patched_script("%-%- Load saved scenes from disk",
    'error("simulated init failure before the loads")')
  assert_equal(count, 1, "init's scenes load found")
  before_loads.before_load = write_sentinel
  local failed_starts = {
    { name = "init never ran", options = { before_load = write_sentinel,
      before_init = function() error("simulated failure before init") end } },
    { name = "init failed before the loads", options = before_loads },
  }
  for _, start in ipairs(failed_starts) do
    local ok, load_error = pcall(load_strata, start.options)
    assert_true(not ok and tostring(load_error):find("simulated", 1, true), start.name .. ": the start failed")
    local cleaned, cleanup_error = pcall(cleanup)
    assert_equal(scenes_file_text(), sentinel, start.name .. ": scenes.data unchanged by cleanup")
    assert_true(cleaned, start.name .. ": cleanup runs after a failed start: " .. tostring(cleanup_error))
  end

  -- a start that loaded the file still saves on exit
  load_strata({ before_load = write_sentinel })
  capture_scene(2)
  cleanup()
  assert_true(scenes_file_text() ~= sentinel, "after a full start cleanup saves the scenes")
  load_strata({ data_subdir = started.data_dir:match("([^/]+)/$") })
  assert_true(local_value("scenes")[2].populated, "the captured scene was saved")
end)

test("scene transitions crossfade linearly from snapshotted start values (I6)", function()
  local context = load_strata(); finish_startup(context)  -- finish init's start-up coroutine
  params:set("v1_freq", 1000)
  params:set("reverb_mix", 0.8)
  params:set("v2_mod_source_1", 3)
  capture_scene(1)
  params:set("v1_freq", 200)
  params:set("reverb_mix", 0.0)
  params:set("v2_mod_source_1", 0)

  recall_scene(1, 20)  -- 20 s over 20 steps; the first step runs immediately
  for step = 1, 19 do
    local mix = step / 20
    assert_near(params:get("v1_freq"), 200 + 800 * mix, 1.0, "freq at step " .. step)
    assert_near(params:get("reverb_mix"), 0.8 * mix, 0.0051, "reverb mix at step " .. step)
    assert_equal(params:get("v2_mod_source_1"), 0, "mod source switches only at the end")
    wake(context, "scene_transition_clock")
  end
  assert_near(params:get("v1_freq"), 1000, 1.0, "freq at the end")
  wake(context, "scene_transition_clock")
  assert_equal(params:get("v2_mod_source_1"), 3, "mod source set when the fade ends")
  assert_equal(local_value("scene_transition_active"), false, "transition finished")

  -- a second recall cancels a running transition and clears the flag
  params:set("v1_freq", 300)
  recall_scene(1, 10)
  assert_equal(local_value("scene_transition_active"), true, "transition running")
  recall_scene(1, 0)
  assert_equal(local_value("scene_transition_active"), false, "canceled transition clears the flag")
  assert_equal(local_value("scene_transition_clock"), nil, "canceled transition clock cleared")
  assert_near(params:get("v1_freq"), 1000, 1.0, "instant recall wins")
  context.clock.run_for(1)  -- longer than a step of the canceled 10 s fade
  assert_near(params:get("v1_freq"), 1000, 1.0, "canceled transition no longer writes")
end)

test("a smooth scene transition holds filter_type until the fade ends", function()
  local context = load_strata(); finish_startup(context)  -- finish init's start-up coroutine
  -- the filter freq fades, so setFilter goes out on every step
  params:set("filter_type", 3); params:set("filter_freq", 8000)
  capture_scene(1)
  params:set("filter_type", 1); params:set("filter_freq", 200)
  local function last_filter_type()
    local calls = context.calls_named("setFilter")
    return calls[#calls].args[3]
  end

  recall_scene(1, 20)  -- 20 steps; the first runs immediately, the switch after the last
  for step = 1, 20 do
    assert_equal(params:get("filter_type"), 1, "filter_type at step " .. step)
    assert_equal(last_filter_type(), 0, "engine filter type at step " .. step)
    wake(context, "scene_transition_clock")
  end
  assert_equal(local_value("scene_transition_active"), false, "transition finished")
  assert_equal(params:get("filter_type"), 3, "filter_type lands on the target")
  assert_equal(last_filter_type(), 2, "engine filter type lands on the target")
  assert_near(params:get("filter_freq"), 8000, 1.0, "the filter freq faded to its target")
end)

test("a smooth transition fades LFO depths in whole percents and ends on the scene's exact depth", function()
  local context = load_strata()
  params:set("lfo_depth_1", 75); params:set("lfo_depth_2", 37.5)   -- a file may hold any number
  capture_scene(1)
  params:set("lfo_depth_1", 0); params:set("lfo_depth_2", 100)

  recall_scene(1, 20)  -- 20 steps; the first runs immediately
  for step = 1, 20 do
    local mix = step / 20
    for n, fade in ipairs({ { from = 0, to = 75 }, { from = 100, to = 37.5 } }) do
      local depth = params:get("lfo_depth_" .. n)
      assert_equal(depth, math.floor(depth), "LFO " .. n .. " depth is a whole percent at step " .. step)
      assert_near(depth, fade.from + (fade.to - fade.from) * mix, 0.5, "LFO " .. n .. " depth at step " .. step)
    end
    wake(context, "scene_transition_clock")
  end
  assert_equal(local_value("scene_transition_active"), false, "transition finished")
  assert_equal(params:get("lfo_depth_1"), 75, "LFO 1 ends on the scene's depth")
  assert_equal(params:get("lfo_depth_2"), 37.5, "LFO 2 ends on the scene's exact depth")
end)

-- Loading scenes replaces every slot: a transition that is running must not
-- apply the slot's new data (or fail on a slot that is now empty) when it ends
for _, slot_on_disk in ipairs({ "empty", "other" }) do
  test("loading scenes from disk during a transition (its slot on disk: " .. slot_on_disk .. ")", function()
    local context = load_strata(); finish_startup(context)
    local voices = local_value("voices")
    if slot_on_disk == "other" then
      params:set("v1_freq", 500); toggle_voice(3); capture_scene(1); toggle_voice(3)
    end
    save_scenes_to_disk()
    params:set("v1_freq", 1000); params:set("v4_grain_mode", 2); capture_scene(1)
    params:set("v1_freq", 200); params:set("v4_grain_mode", 1)

    recall_scene(1, 4)
    context.clock.run_for(1, 0.001)
    local faded = params:get("v1_freq")
    assert_true(faded > 200 and faded < 1000, "the fade is under way")
    load_scenes_from_disk()
    assert_equal(local_value("scenes")[1].populated, slot_on_disk == "other", "slot 1 loaded from disk")
    local ran, run_error = pcall(context.clock.run_for, 5, 0.001)
    assert_true(ran, "the transition's end raised no error: " .. tostring(run_error))
    assert_equal(local_value("scene_transition_active"), false, "no transition left running")
    assert_equal(params:get("v1_freq"), faded, "the canceled fade applied nothing more")
    assert_equal(params:get("v4_grain_mode"), 1, "nor the old scene's discrete state")
    assert_true(not voices[3].active, "nor the new slot's voices")
  end)
end

test("capturing the scene a transition fades to keeps the fade's target (#48)", function()
  local context = load_strata(); finish_startup(context)
  params:set("filter_freq", 8000); params:set("v4_grain_mode", 2); capture_scene(2)
  params:set("filter_freq", 200); params:set("v4_grain_mode", 1)
  recall_scene(2, 10)
  context.clock.run_for(5, 0.001)
  local halfway = params:get("filter_freq")
  assert_true(halfway > 200 and halfway < 8000, "the fade is under way")
  capture_scene(2)                                    -- the half-faded state, into scene 2
  assert_equal(local_value("scenes")[2].data.filter_freq, halfway, "scene 2 holds the half-faded state")
  context.clock.run_for(6, 0.001)
  assert_equal(local_value("scene_transition_active"), false, "the transition ended")
  assert_near(params:get("filter_freq"), 8000, 1.0, "it ended on the scene it was recalled with")
  assert_equal(params:get("v4_grain_mode"), 2, "with that scene's discrete state")
end)

-- Two scenes for the sequencer: scene 2 starts voice 3 in triggered grain
-- mode (both switch only when a transition ends), scene 1 has it stopped
local function capture_sequencer_scenes()
  local voices = local_value("voices")
  if voices[3].active then toggle_voice(3) end
  params:set("v3_grain_mode", 1); capture_scene(1)
  toggle_voice(3); params:set("v3_grain_mode", 2); capture_scene(2)
  toggle_voice(3); params:set("v3_grain_mode", 1)
  params:set("scene_sequence_length", 2)
  return voices
end

-- Run the scene sequencer time-ordered with a scheduling delay per wake-up
-- (`latency`, 1 ms unless given: the fade's 20 sleeps fall behind one long
-- sleep, as on norns).
-- Returns the list of recalls (it keeps growing while the test runs the
-- clocks on; the next load_strata defines recall_scene afresh): scene,
-- seconds since the sequencer started and whether a transition was still
-- running (the recall would cancel it)
local function run_scene_sequencer(context, transition, duration, seconds, latency)
  local recalls = {}
  local real_recall = recall_scene
  local start = util.time()
  recall_scene = function(scene_num, transition_time)
    table.insert(recalls, { scene = scene_num, time = util.time() - start,
      interrupts = local_value("scene_transition_active") })
    return real_recall(scene_num, transition_time)
  end
  params:set("scene_transition_time", transition); params:set("scene_duration", duration)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(seconds, latency or 0.001)
  return recalls
end

for _, case in ipairs({ { transition = 20, duration = 16 }, { transition = 16, duration = 16 } }) do
  test(string.format("the scene sequencer lets a %d s transition finish with a %d s scene duration",
    case.transition, case.duration), function()
    local context = load_strata(); finish_startup(context)
    local voices = capture_sequencer_scenes()
    local period = math.max(case.transition, case.duration)
    local recalls = run_scene_sequencer(context, case.transition, case.duration, period + 1)
    assert_equal(#recalls, 2, "scene 2 recalled once scene 1's transition ended")
    assert_equal(recalls[2].scene, 2, "the sequencer moved on to scene 2")
    assert_true(not recalls[2].interrupts, "scene 1's transition was not cut short")
    assert_true(recalls[2].time >= case.transition, "scene 2 recalled after scene 1's transition")
    assert_true(recalls[2].time < period + 0.1, "the sequencer moved on as soon as it ended")
    assert_true(not voices[3].active, "voice 3 waits for the end of scene 2's transition")
    context.clock.run_for(period, 0.001)                   -- scene 2's transition ends
    assert_true(voices[3].active, "voice 3 started at the end of scene 2's transition")
    assert_equal(params:get("v3_grain_mode"), 2, "grain mode switched at the end of the transition")
    assert_equal(#recalls, 3, "then the sequencer moved on to scene 1")
    context.clock.run_for(period, 0.001)                   -- back to scene 1, which ends too
    assert_true(not voices[3].active, "scene 1 stopped voice 3 again")
    for index, recall in ipairs(recalls) do
      assert_true(not recall.interrupts, "recall " .. index .. " cut no transition short")
    end
    assert_equal(params:get("v3_grain_mode"), 1, "scene 1's grain mode")
  end)
end

-- Under load every wake-up runs late: a fade's 21 wake-ups add 60 ms each,
-- so it ends well over a second after its transition time. It is still
-- progressing, so the sequencer must wait for it, not cancel it
test("the scene sequencer lets a 16 s transition finish when every wake-up runs 60 ms late (#48)", function()
  local context = load_strata(); finish_startup(context)
  local voices = capture_sequencer_scenes()
  local latency = 0.06
  local recalls = run_scene_sequencer(context, 16, 16, 18, latency)
  assert_equal(#recalls, 2, "scene 2 recalled once scene 1's transition ended")
  assert_true(recalls[2].time > 16 + local_value("SCENE_TRANSITION").overrun_seconds,
    "scene 1's transition ran past the overrun margin")
  assert_true(not recalls[2].interrupts, "scene 1's transition was not cut short")
  context.clock.run_for(18, latency)
  assert_true(voices[3].active, "voice 3 started at the end of scene 2's transition")
  assert_equal(params:get("v3_grain_mode"), 2, "scene 2's grain mode")
  assert_true(not table.concat(context.printed, "\n"):find("overran", 1, true), "no transition reported as overrun")
end)

test("the scene sequencer holds a scene for its duration when the transition is shorter", function()
  local context = load_strata(); finish_startup(context)
  local voices = capture_sequencer_scenes()
  local recalls = run_scene_sequencer(context, 10, 16, 43)
  assert_equal(#recalls, 3, "a recall every 16 s")
  assert_near(recalls[2].time, 16, 0.01, "scene 2 after the scene duration")
  assert_near(recalls[3].time, 32, 0.02, "scene 1 after another scene duration")
  assert_true(not voices[3].active, "scene 1's transition has ended")
end)

-- A transition is stuck once its next step is SCENE_TRANSITION.overrun_seconds
-- late (SCENE_TRANSITION.next_step_due: util.time() when it is due)
test("the scene sequencer moves on when a transition never finishes", function()
  local context = load_strata(); finish_startup(context)
  capture_sequencer_scenes()
  local overrun = local_value("SCENE_TRANSITION").overrun_seconds
  assert_true(type(overrun) == "number" and overrun > 0, "SCENE_TRANSITION.overrun_seconds")
  -- stuck early on: the sequencer moves on as soon as the scene's hold ends
  local recalls = run_scene_sequencer(context, 4, 4, 1)          -- scene 1's 4 s transition is running
  assert_true(local_value("scene_transition_active"), "scene 1's transition is running")
  clock.cancel(local_value("scene_transition_clock"))            -- its clock is lost: the flag stays set
  context.clock.run_for(3.5, 0.001)
  assert_equal(#recalls, 2, "the sequencer moved on")
  assert_equal(recalls[2].scene, 2, "to scene 2")
  assert_near(recalls[2].time, 4, 0.05, "when the scene's hold ended")
  assert_true(not recalls[2].interrupts, "the stuck transition was cleared first")
  assert_true(table.concat(context.printed, "\n"):find("scene transition overran", 1, true), "reported")
  context.clock.run_for(4.5, 0.001)
  assert_true(local_value("voices")[3].active, "scene 2's transition ended normally")

  -- stuck just before its end: the sequencer waits until its next step is overrun_seconds late
  context = load_strata(); finish_startup(context)
  capture_sequencer_scenes()
  recalls = run_scene_sequencer(context, 4, 4, 3.9)              -- scene 1's last step has run
  local started = util.time() - 3.9                              -- recall times count from here
  local due = local_value("SCENE_TRANSITION").next_step_due - started
  assert_true(due > 4, "the transition's end is due after the scene's hold")
  clock.cancel(local_value("scene_transition_clock"))
  context.clock.run_for(overrun + 0.5, 0.001)
  assert_equal(#recalls, 2, "the sequencer moved on")
  assert_near(recalls[2].time, due + overrun, 0.05, "once the transition's end was overrun_seconds late")
  assert_true(not recalls[2].interrupts, "the stuck transition was cleared first")
end)

test("the scene sequencer waits for a manual transition it did not start, within a bound", function()
  local context = load_strata(); finish_startup(context)
  local voices = capture_sequencer_scenes()
  local overrun = local_value("SCENE_TRANSITION").overrun_seconds
  local recalls = run_scene_sequencer(context, 0, 4, 1)           -- instant recalls every 4 s
  recall_scene(2, 25)                                              -- a manual 25 s transition
  context.clock.run_for(24, 0.001)
  assert_equal(#recalls, 2, "the sequencer waits for the manual transition")
  context.clock.run_for(1.5, 0.001)
  assert_true(voices[3].active, "the manual transition ended and applied scene 2")
  assert_equal(#recalls, 3, "then the sequencer moved on")
  assert_true(not recalls[3].interrupts, "without cutting it short")
  -- a manual transition that gets stuck is canceled once its next step is overrun_seconds late
  recall_scene(2, 25)
  local started = util.time() - recalls[#recalls].time           -- recall times count from here
  context.clock.run_for(10, 0.001)                                 -- the sequencer is waiting for it
  assert_equal(#recalls, 4, "the sequencer waits for the second manual transition")
  local due = local_value("SCENE_TRANSITION").next_step_due - started
  clock.cancel(local_value("scene_transition_clock"))
  context.clock.run_for(overrun + 2, 0.001)
  assert_equal(#recalls, 5, "the sequencer moved on after the bound")
  assert_near(recalls[5].time, due + overrun, 0.05, "once its next step was overrun_seconds late")
  assert_true(not recalls[5].interrupts, "the stuck transition was cleared first")
end)

-- A sequenced recall that fails validation starts no transition: a manual
-- transition still running is not the sequencer's, and is not cut short
test("a sequenced scene that fails validation leaves a manual transition running (#48)", function()
  local context = load_strata(); finish_startup(context)
  local voices = capture_sequencer_scenes()
  local_value("scenes")[1].data.patterns = nil                    -- scene 1 no longer validates
  recall_scene(2, 25)                                              -- a manual 25 s transition
  local recalls = run_scene_sequencer(context, 2, 4, 24)           -- scene 1 (invalid), held 4 s
  assert_equal(recalls[1].scene, 1, "the sequencer tried scene 1")
  assert_true(table.concat(context.printed, "\n"):find("scene 1 has invalid data", 1, true), "reported invalid")
  assert_equal(#recalls, 1, "the sequencer waits for the manual transition")
  assert_true(local_value("scene_transition_active"), "the manual transition is still running")
  context.clock.run_for(1.5, 0.001)
  assert_true(voices[3].active, "the manual transition ended and applied scene 2")
  assert_equal(#recalls, 2, "then the sequencer moved on")
  assert_true(not recalls[2].interrupts, "without cutting it short")
  assert_true(not table.concat(context.printed, "\n"):find("overran", 1, true), "nothing reported as overrun")
end)

test("an error inside a scene transition's fade clears the transition flag", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_freq", 1000); capture_scene(1); params:set("v1_freq", 200)
  params:set_action("v1_freq", function() error("fade failed") end)
  local ok, message = pcall(recall_scene, 1, 4)                  -- the first step runs at once
  assert_true(not ok and tostring(message):find("fade failed", 1, true), "the error is raised")
  -- with the traceback of where the param action failed (maiden shows it)
  local traceback = tostring(message):match("stack traceback:.*")
  assert_true(traceback and traceback:find("_test%.lua:%d+"), "the raised error keeps its traceback: " .. tostring(message))
  assert_equal(local_value("scene_transition_active"), false, "flag cleared")
  assert_equal(local_value("scene_transition_clock"), nil, "clock cleared")
  -- an error in a later step
  params:set_action("v1_freq", function() end)
  recall_scene(1, 4)
  params:set_action("v1_freq", function() error("fade failed") end)
  wake(context, "scene_transition_clock")                                        -- the scheduler reports the error
  local errors = context.clock.take_errors()
  assert_true(#errors == 1 and errors[1]:find("fade failed", 1, true), "the later error is raised")
  traceback = errors[1]:match("stack traceback:.*")
  assert_true(traceback and traceback:find("_test%.lua:%d+"), "a later step's error keeps its traceback")
  assert_equal(local_value("scene_transition_active"), false, "flag cleared after a later step")
  assert_equal(local_value("scene_transition_clock"), nil, "clock cleared after a later step")
end)

-- An error in a sequenced recall (here the first step of its fade, which
-- runs inside the sequencer's own clock) is reported and the sequencer
-- keeps going: the recall has already cleared its transition state
test("an error in a sequenced recall is reported and the scene sequencer keeps going", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_freq", 1000); capture_scene(1)
  params:set("v1_freq", 400); capture_scene(2)
  params:set("v1_freq", 200); params:set("scene_sequence_length", 2)
  local freq_param = params:lookup_param("v1_freq")
  local real_action, failures = freq_param.action, 1
  freq_param.action = function(value)
    if failures > 0 then failures = failures - 1; error("fade failed") end
    return real_action(value)
  end
  local ran, run_error = pcall(run_scene_sequencer, context, 2, 4, 1)  -- scene 1's first step fails
  assert_true(ran, "the error did not escape the sequencer: " .. tostring(run_error))
  local printed = table.concat(context.printed, "\n")
  assert_true(printed:find("fade failed", 1, true), "the error is printed")
  assert_true(printed:find("stack traceback:", 1, true), "with its traceback")
  assert_equal(params:get("scene_sequencer_enabled"), 1, "the sequencer param stays on")
  assert_true(context.clock.threads[local_value("scene_sequencer_clock")] ~= nil, "its clock is still running")
  assert_true(not local_value("scene_transition_active"), "no transition left flagged")
  ran, run_error = pcall(context.clock.run_for, 6, 0.001)
  assert_true(ran, "the sequencer runs on: " .. tostring(run_error))
  assert_equal(local_value("current_scene"), 2, "it recalled scene 2 after scene 1's duration")
  assert_near(params:get("v1_freq"), 400, 1.0, "and scene 2's transition ended")
end)

test("a failing instant sequenced recall is reported and the scene sequencer holds the scene, then goes on (#50)", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_freq", 1000); capture_scene(1)
  params:set("v1_freq", 400); capture_scene(2)
  params:set("v1_freq", 200); params:set("scene_sequence_length", 2)
  local freq_param = params:lookup_param("v1_freq")
  local real_action, failures = freq_param.action, 1
  freq_param.action = function(value)
    if failures > 0 then failures = failures - 1; error("recall failed") end
    return real_action(value)
  end
  local ran, recalls = pcall(run_scene_sequencer, context, 0, 4, 1)  -- scene 1's instant recall fails
  assert_true(ran, "the error did not escape the sequencer: " .. tostring(recalls))
  assert_equal(#recalls, 1, "one recall so far")
  local printed = table.concat(context.printed, "\n")
  assert_true(printed:find("scene sequencer: scene 1 failed", 1, true), "the failure is printed")
  assert_true(printed:find("recall failed", 1, true) and printed:find("stack traceback:", 1, true),
    "with the error and its traceback")
  assert_equal(params:get("scene_sequencer_enabled"), 1, "the sequencer param stays on")
  assert_true(context.clock.threads[local_value("scene_sequencer_clock")] ~= nil, "its clock is still running")
  assert_true(not local_value("scene_recall_in_progress"), "no recall left flagged")
  assert_true(not local_value("scene_transition_active"), "no transition left flagged")
  local run_error
  ran, run_error = pcall(context.clock.run_for, 4, 0.001)
  assert_true(ran, "the sequencer runs on: " .. tostring(run_error))
  assert_equal(#recalls, 2, "it recalled once more")
  assert_equal(recalls[2].scene, 2, "scene 2")
  assert_near(recalls[2].time, 4, 0.01, "after holding the failed scene for its duration")
  assert_equal(local_value("current_scene"), 2, "scene 2 recalled")
  assert_near(params:get("v1_freq"), 400, 1.0, "and applied at once")
end)

test("a manual recall still interrupts a transition the scene sequencer started", function()
  local context = load_strata(); finish_startup(context)
  local voices = capture_sequencer_scenes()
  local recalls = run_scene_sequencer(context, 20, 16, 25)       -- scene 2's transition is running
  assert_equal(recalls[#recalls].scene, 2, "the sequencer recalled scene 2")
  assert_true(local_value("scene_transition_active"), "scene 2's transition is running")
  recall_scene(2, 0)                                             -- a manual instant recall
  assert_true(not local_value("scene_transition_active"), "the manual recall canceled the transition")
  assert_true(voices[3].active, "and applied scene 2 at once")
  context.clock.run_for(16, 0.001)                               -- the sequencer keeps going
  assert_equal(local_value("current_scene"), 1, "the sequencer moved on to scene 1")
end)

test("shortening the sequence while the sequencer waits wraps to scene 1", function()
  local context = load_strata(); finish_startup(context)
  for scene = 1, 4 do capture_scene(scene) end
  params:set("scene_sequence_length", 4)
  local recalls = run_scene_sequencer(context, 0, 4, 9)          -- scene 3 is playing
  assert_equal(recalls[#recalls].scene, 3, "the sequencer reached scene 3")
  params:set("scene_sequence_length", 2)                         -- scene 3 is now past the end
  context.clock.run_for(4, 0.001)
  assert_equal(recalls[#recalls].scene, 1, "the sequencer wrapped to scene 1")
  context.clock.run_for(8, 0.001)
  assert_equal(recalls[#recalls - 1].scene, 2, "then played scene 2")
  assert_equal(recalls[#recalls].scene, 1, "and wrapped again")
end)

test("restarting the scene sequencer leaves one sequencer clock running", function()
  local context = load_strata(); finish_startup(context)
  capture_sequencer_scenes()
  local recalls = run_scene_sequencer(context, 0, 4, 1)          -- scene 1 at 0 s
  local first_clock = local_value("scene_sequencer_clock")
  scene_sequencer_start()                                        -- restart at 1 s: scene 1 again
  assert_true(context.clock.threads[first_clock] == nil, "the first sequencer clock was canceled")
  context.clock.run_for(8.5, 0.001)
  assert_equal(#recalls, 4, "one recall every 4 s from the restart")
  assert_near(recalls[3].time, 5, 0.01, "scene 2 4 s after the restart")
  assert_near(recalls[4].time, 9, 0.01, "scene 1 4 s later")
  assert_equal(recalls[3].scene, 2); assert_equal(recalls[4].scene, 1)
end)

test("stopping and restarting the scene sequencer while it waits for a transition leaves one clock (#50)", function()
  local context = load_strata(); finish_startup(context)
  capture_sequencer_scenes()
  local recalls = run_scene_sequencer(context, 0, 4, 1)           -- instant recalls every 4 s
  recall_scene(2, 25)                                              -- a manual 25 s transition
  context.clock.run_for(4, 0.001)                                  -- the sequencer waits for it
  assert_equal(#recalls, 2, "the sequencer is waiting inside wait_for_scene_transition")
  local waiting_clock = local_value("scene_sequencer_clock")
  params:set("scene_sequencer_enabled", 0)
  assert_true(context.clock.threads[waiting_clock] == nil, "stopping cancels the waiting clock")
  context.clock.run_for(1, 0.001)
  assert_equal(#recalls, 2, "a stopped sequencer recalls nothing")
  params:set("scene_sequencer_enabled", 1)                         -- restart at 6 s: scene 1 again
  context.clock.run_for(8.5, 0.001)
  assert_equal(#recalls, 5, "one recall every 4 s from the restart, from one clock")
  for index, expected in ipairs({ { scene = 1, time = 6 }, { scene = 2, time = 10 }, { scene = 1, time = 14 } }) do
    local recall = recalls[2 + index]
    assert_equal(recall.scene, expected.scene, "recall " .. (2 + index) .. " scene")
    assert_near(recall.time, expected.time, 0.01, "recall " .. (2 + index) .. " time")
  end
  assert_true(not table.concat(context.printed, "\n"):find("overran", 1, true), "the old wait never resumed")
end)

-- A PSET load (norns' params:read, from the PARAMS menu) sets params in file
-- order. scene_sequencer_enabled comes before the transition time, FX, LFO
-- and voice params, so a sequencer started inside the read would recall
-- scene 1 with the old transition time and then have the PSET overwrite it
test("a PSET read that turns the scene sequencer on starts it once the read has finished", function()
  local context = load_strata(); finish_startup(context)
  params:set("reverb_mix", 0.9); params:set("v1_freq", 1000); capture_scene(1)
  -- the PSET: the sequencer on, a 4 s transition and other values
  params:set("reverb_mix", 0.2); params:set("v1_freq", 300)
  params:set("scene_transition_time", 4); params:set("scene_duration", 30)
  params:set("scene_sequencer_enabled", 1, true)                 -- saved on, not started
  local pset_path = context.data_dir .. "strata-01.pset"
  params:write(pset_path)
  params:set("scene_sequencer_enabled", 0, true)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("reverb_mix", 0.5); params:set("v1_freq", 500)

  local recalls = {}
  local real_recall = recall_scene
  recall_scene = function(scene_num, transition_time)
    table.insert(recalls, { scene = scene_num, transition = transition_time, reverb = params:get("reverb_mix") })
    return real_recall(scene_num, transition_time)
  end
  params:read(pset_path)
  assert_equal(#recalls, 0, "no scene recalled while the PSET was being read")
  assert_equal(params:get("scene_sequencer_enabled"), 1, "the PSET turned the sequencer on")
  context.clock.run_for(5, 0.001)
  assert_equal(#recalls, 1, "the sequencer recalled scene 1 after the read")
  assert_equal(recalls[1].scene, 1, "scene 1")
  assert_equal(recalls[1].transition, 4, "with the PSET's transition time")
  assert_near(recalls[1].reverb, 0.2, 1e-9, "fading from the PSET's values")
  assert_near(params:get("reverb_mix"), 0.9, 1e-9, "scene 1's reverb after the transition")
  assert_near(params:get("v1_freq"), 1000, 1.0, "scene 1's voice 1 freq after the transition")
end)

test("scene recall: one full sync per voice whose source changed, after its params", function()
  -- every engine call since the script loaded, for each running voice, must
  -- leave the engine with the voice's Lua state
  local function assert_engine_has_lua_state(context, where)
    local voices = local_value("voices")
    local master = params:get("master_density")
    for voice_idx = 1, 7 do
      local voice = voices[voice_idx]
      if voice.active then
        local label = where .. ": voice " .. voice_idx .. " "
        local sent = engine_state_for_voice(context.engine_calls, voice_idx - 1)
        for key, value in pairs(voice.params) do
          assert_near(sent.voice[key], value, 1e-9, label .. key)
        end
        assert_near(sent.grain.grainSize, voice.grain.size, 1e-9, label .. "grainSize")
        assert_near(sent.grain.grainDensity, voice.grain.density * master, 1e-9, label .. "grainDensity")
        assert_near(sent.grain.pitchShift, voice.grain.pitch, 1e-9, label .. "pitchShift")
        assert_near(sent.grain.posSpread, voice.grain.spread, 1e-9, label .. "posSpread")
        assert_equal(sent.grain.envShape, voice.grain.env - 1, label .. "envShape")
        assert_equal(sent.grain.grainMode, voice.grain.mode - 1, label .. "grainMode")
        assert_near(sent.grain.bufPos, voice.grain.buf_pos, 1e-9, label .. "bufPos")
        assert_near(sent.grain.bufRate, voice.grain.buf_rate, 1e-9, label .. "bufRate")
        assert_near(sent.grain.bufScan, voice.grain.buf_scan, 1e-9, label .. "bufScan")
        for slot = 1, 3 do
          local slot_state = voice.crossmod["slot" .. slot]
          assert_equal(sent.source[slot], slot_state.source == 0 and -1 or slot_state.source - 1, label .. "mod source " .. slot)
          assert_near(sent.amp_amt[slot], slot_state.amp_amt, 1e-9, label .. "amp mod " .. slot)
          assert_near(sent.freq_amt[slot], slot_state.freq_amt, 1e-9, label .. "freq mod " .. slot)
        end
        assert_near(sent.speed, voice.crossmod.speed, 1e-9, label .. "mod speed")
        local grain_sources = {}
        for _, call in ipairs(context.calls_named("setGrainSource")) do
          if call.args[1] == voice_idx - 1 then table.insert(grain_sources, call.args[2]) end
        end
        assert_equal(grain_sources[#grain_sources], voice.source - 1, label .. "grain source")
      end
    end
  end
  -- a full sync (sync_voice_values_to_engine) ends with the voice's bend.
  -- MIDI pitchbend also sends setVoiceParam "bend", so this test must not
  -- send any pitchbend, or it would count as a sync
  -- (then the registered records' grain keys, which a sync sends last)
  local function full_syncs(context, first_call, engine_voice)
    local count, last_sync, last_call = 0, nil, nil
    local registered = {}
    for _, record in ipairs(local_value("S").registry.voice_params) do
      for _, grain_key in pairs(record.grain_keys or {}) do
        registered[type(grain_key) == "table" and grain_key.name or grain_key] = true
      end
      -- and what a record's sync sends after them (lib/variation.lua's)
      if record.name == "variation" then
        for index = 1, local_value("S").lib.variation.VARIATION.max_intervals do registered["interval" .. index] = true end
        registered.intervalCount, registered.scaleNote = true, true
      end
    end
    for index = first_call, #context.engine_calls do
      local call = context.engine_calls[index]
      if call.args[1] == engine_voice then
        if call.name == "setVoiceParam" and call.args[2] == "bend" then
          count = count + 1; last_sync = index
        elseif call.name == "setGrainParam" and registered[call.args[2]] and last_sync and last_sync == last_call then
          last_sync = index
        end
        last_call = index
      end
    end
    return count, last_sync, last_call
  end

  for _, transition_time in ipairs({ 0, 4 }) do
    local where = transition_time == 0 and "instant recall" or "smooth transition"
    local context = load_strata(); finish_startup(context)
    local voices = local_value("voices")
    for voice_idx = 1, 7 do
      if voices[voice_idx].active ~= (voice_idx <= 3) then toggle_voice(voice_idx) end
    end
    scramble_state(11)
    params:set("v1_source", 1); params:set("v2_source", 3)
    capture_scene(1)                     -- voices 1-3 running, v1 synth, v2 buf 2
    scramble_state(23)
    params:set("v1_source", 4)           -- v1's source differs from the scene's
    params:set("v2_source", 3)           -- v2's is the scene's
    toggle_voice(3); toggle_voice(4)     -- the recall starts voice 3 and stops voice 4

    local first_call = #context.engine_calls + 1
    recall_scene(1, transition_time)
    context.clock.run_for(transition_time + 1)
    assert_equal(local_value("scene_transition_active"), false, where .. " finished")

    local syncs, last_sync, last_call = full_syncs(context, first_call, 0)
    assert_equal(syncs, 1, where .. ": voice 1 (source changed) gets one full sync")
    assert_equal(last_sync, last_call, where .. ": voice 1's full sync comes after its recalled params")
    assert_equal((full_syncs(context, first_call, 1)), 0, where .. ": voice 2 (same source) gets no full sync")
    assert_equal((full_syncs(context, first_call, 2)), 1, where .. ": voice 3 (started) gets toggle_voice's sync only")
    assert_equal((full_syncs(context, first_call, 3)), 0, where .. ": voice 4 (stopped) gets none")
    assert_equal(local_value("scene_recall_in_progress"), false, where .. ": flag cleared")
    assert_engine_has_lua_state(context, where)
  end
end)

test("a scene recall stops a voice before switching its source (#46)", function()
  -- scenes A = voice 1 on/synth, B = off/input, C = on/buffer 1, recalled
  -- A -> B -> A -> C: only C's switch may reach a running voice. A switch
  -- sent before B's voiceOff would build an input grain synth only to
  -- release it at once, and leave the engine more synths than its bound
  for _, transition_time in ipairs({ 0, 4 }) do
    local where = transition_time == 0 and "instant recalls" or "smooth transitions"
    local context = load_strata(); finish_startup(context)   -- voices 1 and 2 running
    params:set("v1_source", 1); capture_scene(1)
    toggle_voice(1); params:set("v1_source", 10); params:set("v1_amp", 0.123); capture_scene(2)
    toggle_voice(1); params:set("v1_source", 2); params:set("v1_amp", 0.3); capture_scene(3)
    recall_scene(1, 0)
    context.clear_engine_calls()
    local scene_b_calls = {}
    for _, scene in ipairs({ 2, 1, 3 }) do
      local first_call = #context.engine_calls + 1
      recall_scene(scene, transition_time)
      context.clock.run_for(transition_time + 1)
      if scene == 2 then
        for index = first_call, #context.engine_calls do
          local call = context.engine_calls[index]
          if call.args[1] == 0 then table.insert(scene_b_calls, call.name) end
        end
      end
    end
    -- replay voice 1's calls on a model of the engine (running, on its synth)
    local running, source, replacements, order = true, 0, 0, {}
    for _, call in ipairs(context.engine_calls) do
      if call.args[1] == 0 then
        if call.name == "voiceOn" then running = true; table.insert(order, "on")
        elseif call.name == "voiceOff" then running = false; table.insert(order, "off")
        elseif call.name == "setGrainSource" and call.args[2] ~= source then
          if running then replacements = replacements + 1 end
          source = call.args[2]
          table.insert(order, "source " .. source)
        end
      end
    end
    assert_equal(table.concat(order, ", "), "off, source 9, source 0, on, source 1",
      where .. ": B stops voice 1 before its source switch, A switches it before starting it")
    assert_equal(replacements, 1, where .. ": only C's switch replaces a running voice's grain synth")
    -- an instant B stops voice 1 before setting its params (B's amp), so its
    -- release tail keeps A's values (a smooth one fades them in first)
    if transition_time == 0 then
      assert_equal(table.concat(scene_b_calls, ", "), "voiceOff, setGrainSource",
        where .. ": B sends voice 1 only its stop and its source")
    end
    assert_equal(local_value("voices")[1].active, true, where .. ": voice 1 ends running")
    assert_equal(local_value("voices")[1].source, 2, where .. ": on buffer 1")
  end
end)

test("an error during a scene recall clears scene_recall_in_progress and is raised", function()
  local context = load_strata(); finish_startup(context)   -- voices 1 and 2 running
  local function voice1_full_syncs()
    local bends = 0
    for _, call in ipairs(context.calls_named("setVoiceParam")) do
      if call.args[1] == 0 and call.args[2] == "bend" then bends = bends + 1 end
    end
    return bends
  end
  -- the scene has voice 1 on buffer 2; voice 2's mod speed action fails
  -- after voice 1's source has switched
  params:set("v1_source", 3); params:set("v2_mod_speed", 3); capture_scene(1)
  params:set("v1_source", 1); params:set("v2_mod_speed", 7)
  params:set_action("v2_mod_speed", function() error("mod speed action failed") end)
  context.clear_engine_calls()
  local ok, recall_error = pcall(recall_scene, 1, 0)
  assert_true(not ok, "the error reaches the caller")
  assert_true(tostring(recall_error):find("mod speed action failed", 1, true), "the original error: " .. tostring(recall_error))
  local traceback = tostring(recall_error):match("stack traceback:.*")
  assert_true(traceback and traceback:find("_test%.lua:%d+"), "the raised error keeps its traceback")
  assert_equal(local_value("scene_recall_in_progress"), false, "flag cleared after the error")
  assert_equal(local_value("voices")[1].source, 3, "voice 1's source switched before the error")
  assert_equal(voice1_full_syncs(), 1, "the switched running voice still gets its end-of-recall sync")
  -- the source action syncs a running voice again
  context.clear_engine_calls(); params:set("v1_source", 1)
  assert_equal(voice1_full_syncs(), 1, "a later source switch sends its full sync")
end)

test("a smooth scene transition reaches the screen and arc on every step and at its end (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  show_page("MAIN")
  -- the scene: voice 1 frozen at 100 Hz; now it plays 1000 Hz, unfrozen
  toggle_lock(1); capture_scene(1); toggle_lock(1)
  params:set("v1_freq", 1000)
  assert_drawn_on_next_frame(context, arc_hardware, "transition start (step 1)", function()
    recall_scene(1, 2)
  end)
  -- each step runs 0.1 s after the last and a frame comes every 1/15 s, so
  -- the frame after a step always comes before the next step (frames that
  -- run before a step find nothing to draw)
  local steps = 1
  while local_value("scene_transition_clock") do
    steps = steps + 1
    local where = "transition step " .. steps
    local counter = count_screen_draws()
    local arc_refreshes = arc_hardware.refresh_count
    wake(context, "scene_transition_clock")
    local drawn_before_frame = counter.screen
    local arc_before_frame = arc_hardware.refresh_count - arc_refreshes
    next_frame(context)
    counter.restore()
    assert_equal(drawn_before_frame, 0, where .. ": the screen waits for the frame")
    assert_equal(arc_before_frame, 0, where .. ": the arc waits for the frame")
    assert_equal(counter.screen, 1, where .. ": the next frame draws the screen once")
    assert_equal(arc_hardware.refresh_count - arc_refreshes, 1, where .. ": and the arc once")
  end
  assert_equal(steps, local_value("SCENE_TRANSITION").steps + 1, "every step, then the end")
  assert_true(screen_shows(context, "100 Hz"), "the end shows the scene's freq")
  -- its lock (the MAIN page's own lock mark is tested in pages_main_test.lua)
  assert_true(local_value("frozen")[1], "and its lock")
end)

test("v1 scene file migrates to v2 with fx defaults", function()
  local context = load_strata({ data_subdir = "v1" })
  capture_scene(2)
  local scenes = local_value("scenes")
  for _, param_id in ipairs(FX_PARAM_IDS) do
    if param_id:find("^filter_") or param_id:find("^delay_") then
      scenes[2].data[param_id] = nil   -- as a v1 file lacks them
    end
  end
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  tab.save(scenes, context.data_dir .. "strata/scenes.data")  -- v1 wrote the bare array
  params:set("filter_freq", 300); params:set("delay_mix", 0.5)
  load_scenes_from_disk()
  assert_true(local_value("scenes")[2].populated)
  recall_scene(2, 0)                                           -- must not error on nil
  assert_near(params:get("filter_freq"), 5000, 1); assert_equal(params:get("delay_mix"), 0)
  assert_true(table.concat(context.printed, "\n"):find("migrated scenes file from version 1"),
    "migration message printed")
  -- a versioned version-1 file migrates too, and the next save writes the current version
  tab.save({ version = 1, scenes = scenes }, context.data_dir .. "strata/scenes.data")
  context = load_strata({ data_subdir = "v1" })
  assert_true(local_value("scenes")[2].populated, "versioned v1 file loads")
  save_scenes_to_disk()
  local saved = context.tab.load(context.data_dir .. "strata/scenes.data")
  assert_equal(saved.version, 3, "scenes are saved as version 3")
  assert_near(saved.scenes[2].data.filter_freq, 5000, 1, "migrated default saved")
end)

test("migrate_scene fills table-driven voice defaults and tolerates malformed data", function()
  load_strata()
  capture_scene(1)
  local scene = deep_copy(local_value("scenes")[1])
  local voice_defaults = local_value("VOICE_SCENE_DEFAULTS")
  -- later formats add per-voice fields through VOICE_SCENE_DEFAULTS
  table.insert(voice_defaults, { path = { "test_block", "field" }, default = 7 })
  table.insert(voice_defaults, { path = { "grain", "test_field" }, default = 3 })
  migrate_scene(scene, 1)
  table.remove(voice_defaults); table.remove(voice_defaults)
  for voice_idx = 1, 7 do
    assert_equal(scene.data.voices[voice_idx].grain.test_field, 3, "nested voice default filled")
    assert_equal(scene.data.voices[voice_idx].test_block, nil, "missing parent tables are not invented")
  end
  scene.data.reverb_mix = nil
  migrate_scene(scene, 1)
  assert_near(scene.data.reverb_mix, 0.3, 1e-9, "missing global filled from its default")
  scene.data.reverb_mix = 0.9
  migrate_scene(scene, 1)
  assert_near(scene.data.reverb_mix, 0.9, 1e-9, "present values are kept")
  -- malformed scenes are left for validate_scene to reject
  for _, bad in ipairs({ "x", {}, { populated = true }, { populated = true, data = { voices = "v" } },
      { populated = true, data = { voices = { "a", 3 } } }, { populated = false } }) do
    migrate_scene(bad, 1)
  end
end)

test("transition skips discrete voice fields; scenes keep source and buffer params", function()
  local context = load_strata(); finish_startup(context)
  params:set("v2_source", 3); params:set("v2_buf_pos", 0.7); capture_scene(1)
  assert_equal(local_value("scenes")[1].data.voices[2].source, 3, "source captured")
  params:set("v2_source", 1); params:set("v2_buf_pos", 0.1)
  recall_scene(1, 4); wake(context, "scene_transition_clock")
  assert_equal(params:get("v2_source"), 1, "source only changes at the end of a transition")
  assert_true(params:get("v2_buf_pos") > 0.1, "buf_pos interpolates")
  for _, target in ipairs(scene_transition_targets(local_value("scenes")[1].data)) do
    assert_true(not target.id:find("_source$"), target.id .. " is not crossfaded")
  end
  context.clock.run_for(5)   -- past the 4 s transition
  assert_equal(params:get("v2_source"), 3); assert_near(params:get("v2_buf_pos"), 0.7, 1e-6)
  -- validation and migration of the source field
  local scene = deep_copy(local_value("scenes")[1])
  assert_true(validate_scene(scene), "captured scene validates")
  for _, bad in ipairs({ 0, 11, 2.5, "buf 1" }) do
    scene.data.voices[2].source = bad
    assert_true(not validate_scene(scene), "source " .. tostring(bad) .. " rejected")
  end
  for voice_idx = 1, 7 do
    scene.data.voices[voice_idx].source = nil
    for _, key in ipairs({ "buf_pos", "buf_rate", "buf_scan" }) do scene.data.voices[voice_idx].grain[key] = nil end
  end
  migrate_scene(scene, 1)
  assert_equal(scene.data.voices[2].source, 1, "missing source migrates to synth")
  assert_equal(scene.data.voices[2].grain.buf_rate, 1, "missing buf_rate migrates to 1")
  assert_equal(scene.data.voices[2].grain.buf_pos, 0, "missing buf_pos migrates to 0")
  assert_true(validate_scene(scene), "migrated scene validates")
end)

test("scenes capture and recall the LFOs; old files load with LFOs off", function()
  local context = load_strata({ data_subdir = "lfo_scenes" }); finish_startup(context)
  params:set("lfo_shape_1", 2); params:set("lfo_mode_1", 1); params:set("lfo_clocked_1", 5)
  params:set("lfo_free_2", 9); params:set("lfo_depth_2", 60); params:set("strata_lfo2_dest", 14)
  params:set("lfo_2", 2)
  capture_scene(1)
  local data = local_value("scenes")[1].data
  assert_equal(data.lfo_shape_1, 2); assert_equal(data.lfo_mode_1, 1); assert_equal(data.lfo_clocked_1, 5)
  assert_near(data.lfo_free_2, 9, 1e-9); assert_equal(data.lfo_depth_2, 60)
  assert_equal(data.strata_lfo2_dest, 14); assert_equal(data.lfo_2, 2)
  params:set("lfo_2", 1); params:set("lfo_depth_2", 0); params:set("strata_lfo2_dest", 1); params:set("lfo_shape_1", 1)
  recall_scene(1, 0)
  assert_equal(params:string("lfo_2"), "on"); assert_equal(params:get("lfo_depth_2"), 60)
  assert_equal(params:get("strata_lfo2_dest"), 14); assert_equal(params:string("lfo_shape_1"), "tri")
  assert_equal(local_value("lfos")[2]:get("enabled"), 1, "recalled LFO runs")
  -- smooth transitions fade depth and free period, switch the rest at the end
  local continuous = {}
  for _, global in ipairs(local_value("SCENE_GLOBAL_PARAMS")) do continuous[global.id] = global.continuous end
  for n = 1, 3 do
    assert_equal(continuous["lfo_depth_" .. n], true); assert_equal(continuous["lfo_free_" .. n], true)
    for _, id in ipairs({ "lfo_" .. n, "lfo_shape_" .. n, "lfo_mode_" .. n, "lfo_clocked_" .. n, "strata_lfo" .. n .. "_dest" }) do
      assert_equal(continuous[id], false, id .. " switches")
    end
  end
  -- invalid option values are rejected
  local bad = deep_copy(local_value("scenes")[1]); bad.data.strata_lfo2_dest = 0.5
  assert_true(not validate_scene(bad), "fractional destination rejected")
  bad.data.strata_lfo2_dest = #local_value("LFO_DESTINATIONS") + 1
  assert_true(not validate_scene(bad), "out-of-range destination rejected")
  -- a scene saved before the LFOs existed recalls them as off with defaults
  local old = deep_copy(local_value("scenes")[1])
  for key in pairs(old.data) do
    if key:find("^lfo_") or key:find("^strata_lfo") then old.data[key] = nil end
  end
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  tab.save({ version = 2, scenes = { old } }, context.data_dir .. "strata/scenes.data")
  load_scenes_from_disk()
  assert_true(local_value("scenes")[1].populated, "pre-LFO scene file loads")
  recall_scene(1, 0)
  assert_equal(params:string("lfo_2"), "off"); assert_equal(params:get("lfo_depth_2"), 0)
  assert_equal(params:get("strata_lfo2_dest"), 1); assert_equal(params:string("lfo_mode_1"), "free")
end)

end

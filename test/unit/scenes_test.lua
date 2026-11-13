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
  -- every backup name is taken (by a folder): the file cannot be moved aside
  os.execute("mkdir -p '" .. data_dir .. "scenes.data.bak'")
  for number = 2, 9 do os.execute("mkdir -p '" .. data_dir .. "scenes.data.bak." .. number .. "'") end
  local file = assert(io.open(data_dir .. "scenes.data", "w"))
  file:write(bad_files[1].content)
  file:close()
  load_strata({ data_subdir = "survive_blocked" })
  cleanup()
  file = assert(io.open(data_dir .. "scenes.data", "r"))
  assert_equal(file:read("*a"), bad_files[1].content, "unmovable bad file not overwritten by cleanup")
  file:close()
end)

-- The reader reads inf, -inf and nan as numbers (lib/data_files.lua, #464),
-- and tab.load read 1e999 as inf: validation refuses any of them as it
-- refuses any invalid value, so the file is kept as scenes.data.bak
test("a scenes.data value that is not a finite number is refused as an invalid value (#464)", function()
  local context = load_strata({ data_subdir = "nonfinite_source" })
  capture_scene(1)
  local scenes = deep_copy(local_value("scenes"))
  local cases = {
    { name = "a finite value", value = 200, loads = true },
    { name = "inf", value = math.huge }, { name = "-inf", value = -math.huge }, { name = "nan", value = 0 / 0 },
    { name = "1e999", value = 54321.25, text = "1e999" },
  }
  for index, case in ipairs(cases) do
    scenes[1].data.voices[1].params.freq = case.value
    local subdir = "nonfinite_" .. index
    local dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. dir .. "'")
    local text = tabutil_text({ version = 4, scenes = scenes })
    if case.text then text = text:gsub("54321%.25", case.text) end
    local file = assert(io.open(dir .. "scenes.data", "w")); file:write(text); file:close()
    load_strata({ data_subdir = subdir })
    local populated = local_value("scenes")[1].populated
    if case.loads then
      assert_true(populated, case.name .. " loads (the file is otherwise valid)")
    else
      assert_true(not populated, case.name .. ": the scene is refused")
      assert_true(util.file_exists(dir .. "scenes.data.bak"), case.name .. ": the file is kept as scenes.data.bak")
    end
  end
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
  params:set("strata_lfo1_depth", 75); params:set("strata_lfo2_depth", 37)
  capture_scene(1)
  params:set("strata_lfo1_depth", 0); params:set("strata_lfo2_depth", 100)

  recall_scene(1, 20)  -- 20 steps; the first runs immediately
  for step = 1, 20 do
    local mix = step / 20
    for n, fade in ipairs({ { from = 0, to = 75 }, { from = 100, to = 37 } }) do
      local depth = params:get("strata_lfo" .. n .. "_depth")
      assert_equal(depth, math.floor(depth), "LFO " .. n .. " depth is a whole percent at step " .. step)
      assert_near(depth, fade.from + (fade.to - fade.from) * mix, 0.5, "LFO " .. n .. " depth at step " .. step)
    end
    wake(context, "scene_transition_clock")
  end
  assert_equal(local_value("scene_transition_active"), false, "transition finished")
  assert_equal(params:get("strata_lfo1_depth"), 75, "LFO 1 ends on the scene's depth")
  assert_equal(params:get("strata_lfo2_depth"), 37, "LFO 2 ends on the scene's exact depth")
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

-- Scenes 1-3 hold voice 1 at 1000, 400 and 700 Hz and it now plays 200 Hz,
-- so every step of a fade between them sets v1_freq
local function capture_freq_scenes()
  for scene, freq in ipairs({ 1000, 400, 700 }) do
    params:set("v1_freq", freq); capture_scene(scene)
  end
  params:set("v1_freq", 200)
end

-- The running fade's next step raises, in the transition's clock
local function fail_next_fade_step(context)
  params:set_action("v1_freq", function() error("fade failed") end)
  wake(context, "scene_transition_clock")
  local errors = context.clock.take_errors()
  assert_true(#errors == 1 and errors[1]:find("fade failed", 1, true), "the step's error is raised")
  params:set_action("v1_freq", function() end)
end

test("a fade whose step fails leaves the previous scene current", function()
  local context = load_strata(); finish_startup(context)
  capture_freq_scenes()
  recall_scene(2, 0); recall_scene(1, 4)
  assert_equal(local_value("current_scene"), 1, "the fading target is current from its first step")
  fail_next_fade_step(context)
  assert_equal(local_value("current_scene"), 2, "the previous scene is current again")
  local transition = local_value("SCENE_TRANSITION")
  assert_equal(transition.target, nil, "no target once the fade is over")
  assert_equal(transition.previous, nil, "no previous once the fade is over")
  next_frame(context)
  assert_true(screen_shows(context, "S2"), "the header shows the previous scene")

  -- the fade's end fails: the filter type switches only there
  context = load_strata(); finish_startup(context)
  params:set("filter_type", 3); capture_freq_scenes(); params:set("filter_type", 1); capture_scene(2)
  recall_scene(2, 0); recall_scene(1, 2)
  next_frame(context)
  local failed, after_failure = false, {}
  params:set_action("filter_type", function() failed = true; error("landing failed") end)
  local real_grid_redraw = grid_redraw
  grid_redraw = function()
    if failed then table.insert(after_failure, local_value("current_scene")) end
    return real_grid_redraw()
  end
  local ran, run_error = pcall(context.clock.run_for, 2.5, 0.001)
  grid_redraw = real_grid_redraw
  assert_true(ran, "the clocks ran: " .. tostring(run_error))
  local errors = context.clock.take_errors()
  assert_true(#errors == 1 and errors[1]:find("landing failed", 1, true), "the end's error is raised")
  assert_equal(local_value("current_scene"), 2, "a fade whose end fails leaves the previous scene current")
  assert_equal(#after_failure, 1, "one grid redraw after the failure")
  for index, scene in ipairs(after_failure) do
    assert_equal(scene, 2, "grid redraw " .. index .. " after the failure shows the previous scene")
  end
  next_frame(context)
  assert_true(screen_shows(context, "S2"), "and the header shows it")
end)

test("a canceled fade leaves the previous scene current", function()
  local context = load_strata(); finish_startup(context)
  capture_freq_scenes()
  recall_scene(2, 0); recall_scene(1, 4)
  assert_equal(local_value("current_scene"), 1, "the fading target is current at once")
  cancel_scene_transition()
  assert_equal(local_value("current_scene"), 2, "a canceled fade puts the previous scene back")
  assert_equal(local_value("SCENE_TRANSITION").target, nil, "no target once canceled")

  -- the scene sequencer cancels a fade that overran
  context = load_strata(); finish_startup(context)
  capture_sequencer_scenes()
  recall_scene(2, 0)
  local recalls = run_scene_sequencer(context, 4, 4, 1)          -- scene 1's 4 s fade is running
  assert_equal(local_value("current_scene"), 1, "the sequencer's fading target is current")
  local current_at_next_recall
  local sequencer_recall = recall_scene
  recall_scene = function(scene_num, transition_time)
    current_at_next_recall = local_value("current_scene")
    return sequencer_recall(scene_num, transition_time)
  end
  clock.cancel(local_value("scene_transition_clock"))            -- its clock is lost: it overruns
  context.clock.run_for(3.5, 0.001)
  assert_equal(#recalls, 2, "the sequencer canceled the overrun fade and moved on")
  assert_equal(current_at_next_recall, 2, "the overrun fade left scene 2 current")

  -- a scenes file loaded during a fade
  context = load_strata(); finish_startup(context)
  capture_freq_scenes(); save_scenes_to_disk()
  recall_scene(2, 0); recall_scene(1, 4)
  context.clock.run_for(1, 0.001)
  load_scenes_from_disk()
  assert_equal(local_value("current_scene"), 2, "the load's cancel puts the previous scene back")
  assert_equal(local_value("SCENE_TRANSITION").target, nil, "no target after the load")
end)

test("a fade superseded by a fade that fails goes back to the last scene that landed", function()
  local context = load_strata(); finish_startup(context)
  capture_freq_scenes()
  recall_scene(1, 0); recall_scene(2, 4); recall_scene(3, 4)
  local transition = local_value("SCENE_TRANSITION")
  assert_equal(local_value("current_scene"), 3, "the newest fade's target is current")
  assert_equal(transition.target, 3, "the fade goes to scene 3")
  assert_equal(transition.previous, 1, "from scene 1, the last that landed")
  fail_next_fade_step(context)
  assert_equal(local_value("current_scene"), 1, "the last scene that landed is current again")
  -- an instant recall superseding a fade makes its own scene current
  recall_scene(2, 4); recall_scene(3, 0)
  assert_equal(local_value("current_scene"), 3, "the instant recall's scene is current")
  assert_equal(transition.target, nil, "no fade is running")
  -- an instant recall superseding a fade that fails: the last scene that landed
  recall_scene(1, 0); recall_scene(2, 4)
  params:set_action("v1_freq", function() error("recall failed") end)
  local ok, message = pcall(recall_scene, 3, 0)
  params:set_action("v1_freq", function() end)
  assert_true(not ok and tostring(message):find("recall failed", 1, true), "the recall's error is raised")
  assert_equal(local_value("current_scene"), 1, "the last scene that landed is current")
  assert_equal(transition.target, nil, "no target")
  assert_equal(transition.previous, nil, "no previous")
  assert_equal(local_value("scene_transition_active"), false, "no fade is running")
end)

test("a fade's landing keeps its target current while it applies it", function()
  local context = load_strata(); finish_startup(context)
  capture_sequencer_scenes()                     -- scene 2 starts voice 3, scene 1 stops it
  recall_scene(1, 0); recall_scene(2, 2)
  for _ = 1, local_value("SCENE_TRANSITION").steps - 1 do
    wake(context, "scene_transition_clock")      -- every step; the end is next
  end
  local seen = {}
  local real_grid_redraw = grid_redraw
  grid_redraw = function()
    table.insert(seen, local_value("current_scene"))
    return real_grid_redraw()
  end
  local landed, landing_error = pcall(wake, context, "scene_transition_clock")
  grid_redraw = real_grid_redraw
  assert_true(landed, "the landing ran: " .. tostring(landing_error))
  assert_true(local_value("voices")[3].active, "the landing started voice 3")
  assert_true(#seen >= 2, "the landing redrew the grid mid-way and at its end")
  for index, scene in ipairs(seen) do
    assert_equal(scene, 2, "grid redraw " .. index .. " during the landing shows the target")
  end
  assert_equal(local_value("current_scene"), 2, "the target is current")
end)

test("a fade that lands makes its target current", function()
  local context = load_strata(); finish_startup(context)
  capture_freq_scenes()
  recall_scene(2, 0); recall_scene(1, 2)
  context.clock.run_for(2.5, 0.001)
  assert_equal(local_value("current_scene"), 1, "the landed fade's target is current")
  assert_equal(local_value("SCENE_TRANSITION").target, nil, "no target once it landed")
  assert_equal(local_value("scene_transition_active"), false, "the fade is over")
end)

-- #254: a 2 s fade has 20 steps of 0.1 s; the first runs inside the recall
test("the fading target blinks once per step and is steady when it lands", function()
  local context = load_strata(); finish_startup(context)
  local scenes = local_value("S").lib.scenes
  capture_freq_scenes()
  recall_scene(1, 0)
  -- while step 1 sets its params (a param action can redraw the grid) no
  -- step has been applied yet: the target is lit from the recall
  local freq_param = params:lookup_param("v1_freq")
  local real_action, seen = freq_param.action, nil
  freq_param.action = function(value)
    if seen == nil then
      seen = {step = local_value("SCENE_TRANSITION").step, target = scenes.fading_to(),
        shows = scenes.shows_current(2)}
    end
    return real_action(value)
  end
  recall_scene(2, 2)
  freq_param.action = real_action
  assert_true(seen, "step 1 set v1_freq")
  assert_equal(seen.target, 2, "inside step 1 the fade goes to scene 2")
  assert_equal(seen.step, nil, "before step 1 is applied there is no step")
  assert_equal(seen.shows, true, "the target is lit before step 1 is applied")
  assert_equal(scenes.fading_to(), 2, "the fade goes to scene 2")
  assert_equal(local_value("SCENE_TRANSITION").step, 1, "the recall applied step 1")
  assert_equal(scenes.shows_current(2), true, "step 1: the target shows")
  assert_equal(scenes.shows_current(1), false, "the previous scene is not current")
  context.clock.run_for(0.1)
  assert_equal(local_value("SCENE_TRANSITION").step, 2, "one step per 0.1 s")
  assert_equal(scenes.shows_current(2), false, "step 2: the target is dark")
  context.clock.run_for(0.1)
  assert_equal(scenes.shows_current(2), true, "step 3: the target shows again")
  context.clock.run_for(2.5)
  assert_equal(scenes.fading_to(), nil, "the fade landed")
  assert_equal(local_value("SCENE_TRANSITION").step, nil, "no step once it landed")
  assert_equal(scenes.shows_current(2), true, "the landed scene is steady")
end)

-- The final review's item 2: a fade back to the current scene changes no
-- current scene, but its end still changes the blink phase
test("a fade back to the current scene that ends at a dark step redraws the steady mark", function()
  local context = load_strata(); finish_startup(context)
  local scenes = local_value("S").lib.scenes
  local UI_PAGES = local_value("UI_PAGES")
  capture_freq_scenes()
  local grid_redraws = 0
  local real_grid_redraw = grid_redraw
  grid_redraw = function() grid_redraws = grid_redraws + 1; return real_grid_redraw() end
  local ok, err = pcall(function()
    for _, how in ipairs({ "canceled", "failed" }) do
      recall_scene(2, 0); params:set("v1_freq", 200)  -- a tweak after the recall: the fade moves v1_freq back
      assert_equal(local_value("current_scene"), 2, how .. ": scene 2 is current")
      recall_scene(2, 2); context.clock.run_for(0.1)
      assert_equal(local_value("SCENE_TRANSITION").step, 2, how .. ": step 2")
      assert_equal(scenes.shows_current(2), false, how .. ": step 2 shows the mark dark")
      grid_redraws = 0
      UI_PAGES.screen_dirty = false
      if how == "canceled" then
        cancel_scene_transition()
      else
        fail_next_fade_step(context)
      end
      assert_equal(local_value("current_scene"), 2, how .. ": scene 2 is still current")
      assert_equal(scenes.shows_current(2), true, how .. ": the mark is steady again")
      assert_true(grid_redraws >= 1, how .. ": the grid is redrawn")
      assert_true(UI_PAGES.screen_dirty, how .. ": the screen is asked to redraw")
    end
  end)
  grid_redraw = real_grid_redraw
  if not ok then error(err, 0) end
end)

test("a superseded fade's target stops blinking at once", function()
  local context = load_strata(); finish_startup(context)
  local scenes = local_value("S").lib.scenes
  capture_freq_scenes()
  recall_scene(2, 2); context.clock.run_for(0.1)                 -- step 2: the target is dark
  recall_scene(3, 0)
  assert_equal(scenes.fading_to(), nil, "an instant recall ends the fade")
  assert_equal(local_value("SCENE_TRANSITION").step, nil, "no step")
  assert_equal(scenes.shows_current(3), true, "the instant recall's scene shows")
  assert_equal(scenes.shows_current(2), false, "the abandoned target does not")
  recall_scene(2, 2); context.clock.run_for(0.1)
  cancel_scene_transition()
  assert_equal(scenes.fading_to(), nil, "a cancel ends the fade")
  assert_equal(local_value("SCENE_TRANSITION").step, nil, "no step")
  assert_equal(scenes.shows_current(3), true, "the previous scene shows steady")
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
  local claimed = context.take_script_errors()  -- the printed failure this test raises (#473)
  assert_equal(#claimed, 1, "one failure printed")
  assert_true(claimed[1]:find("scene sequencer: scene 1 failed: ", 1, true) == 1 and claimed[1]:find("fade failed", 1, true),
    "scene 1's fade error: " .. claimed[1])
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
  local claimed = context.take_script_errors()  -- the printed failure this test raises (#473)
  assert_equal(#claimed, 1, "one failure printed")
  assert_true(claimed[1]:find("scene sequencer: scene 1 failed: ", 1, true) == 1 and claimed[1]:find("recall failed", 1, true),
    "scene 1's recall error: " .. claimed[1])
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

-- #303: the grids' scene pages light this slot at 10 while the sequencer runs
test("S.lib.scenes.sequencer_next_slot is the slot the running scene sequencer recalls next (#303)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for scene = 1, 3 do capture_scene(scene) end                    -- slot 4 stays empty
  params:set("scene_sequence_length", 4)
  assert_equal(S.lib.scenes.sequencer_next_slot(), nil, "nil while the sequencer is off")
  local recalls = run_scene_sequencer(context, 0, 4, 1)          -- scene 1 at 0 s, held 4 s
  -- at 1, 5, 9, 13 and 17 s: the slot it holds and the next (empty slot 4 is skipped, #513)
  local expected = { { 1, 2 }, { 2, 3 }, { 3, 1 }, { 1, 2 }, { 2, 3 } }
  for index, slots in ipairs(expected) do
    if index > 1 then context.clock.run_for(4, 0.001) end
    local at = (index * 4 - 3) .. " s: "
    assert_equal(S.scene_sequencer_position, slots[1], at .. "the sequencer is on slot " .. slots[1])
    assert_equal(S.lib.scenes.sequencer_next_slot(), slots[2], at .. "it recalls slot " .. slots[2] .. " next")
  end
  assert_equal(#recalls, 5, "scenes 1, 2, 3, 1 and 2 recalled; empty slot 4 skipped")
  assert_equal(recalls[4].scene, 1, "after scene 3 the sequencer went past slot 4 to scene 1")
  params:set("scene_sequence_length", 2)                          -- shortened during scene 2's hold
  assert_equal(S.lib.scenes.sequencer_next_slot(), 1, "the length as it is now: slot 1 next")
  context.clock.run_for(4, 0.001)
  assert_equal(recalls[#recalls].scene, 1, "and the sequencer recalls scene 1 next")
  params:set("scene_sequence_length", 1)                          -- one scene: it recalls itself
  assert_equal(S.lib.scenes.sequencer_next_slot(), 1, "a sequence of one slot recalls it again")
  params:set("scene_sequencer_enabled", 0)
  assert_equal(S.lib.scenes.sequencer_next_slot(), nil, "nil once the sequencer stops")
end)

-- #303: the sequencer's first recall waits for the next scheduler tick
-- (scene_sequencer_start), and the slot it recalls next until then is its
-- position, not the one after it
test("until the scene sequencer recalls its position, sequencer_next_slot is that position (#303)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for scene = 1, 3 do capture_scene(scene) end
  params:set("scene_sequence_length", 3)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  assert_equal(S.current_scene, 0, "started: nothing recalled yet")
  assert_equal(S.lib.scenes.sequencer_next_slot(), 1, "slot 1 is the one it recalls next")
  context.clock.run_for(0.01, 0.001)
  assert_equal(S.current_scene, 1, "the first recall")
  assert_equal(S.lib.scenes.sequencer_next_slot(), 2, "then slot 2")
  context.clock.run_for(4.5, 0.001)
  assert_equal(S.current_scene, 2, "scene 2 playing")
  scene_sequencer_start()                                         -- a restart begins at slot 1
  assert_equal(S.lib.scenes.sequencer_next_slot(), 1, "restarted: slot 1 is recalled next")
  context.clock.run_for(0.01, 0.001)
  assert_equal(S.current_scene, 1)
  assert_equal(S.lib.scenes.sequencer_next_slot(), 2, "then slot 2 again")
  params:set("scene_sequencer_enabled", 0)
  assert_equal(S.lib.scenes.sequencer_next_slot(), nil, "nil once stopped")
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
      -- and what a record's sync sends after them (lib/positions.lua's bookmarks)
      if record.name == "bookmarks" then registered.scrubRate, registered.scanHold = true, true end
      -- (lib/voice_mix.lua's: the effective mute)
      if record.name == "voice_mix" then registered.voiceMute = true end
      -- (lib/variation.lua's)
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
        elseif ((call.name == "setGrainParam" and registered[call.args[2]])
            -- (lib/notes.lua's sync: the envelope times)
            or (call.name == "setVoiceParam" and (call.args[2] == "attackTime" or call.args[2] == "releaseTime")))
          and last_sync and last_sync == last_call then
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
  assert_equal(saved.version, 6, "scenes are saved as version 6")
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
  params:set("strata_lfo1_shape", 2); params:set("strata_lfo1_mode", 2); params:set("strata_lfo1_division", 5)
  params:set("strata_lfo2_rate", 9); params:set("strata_lfo2_depth", 60); params:set("strata_lfo2_dest", 14)
  params:set("strata_lfo2_phase", 30); params:set("strata_lfo2_rate_mod", 2); params:set("strata_lfo2_depth_mod_amt", -40)
  params:set("strata_lfo2", 1)
  capture_scene(1)
  local data = local_value("scenes")[1].data
  assert_equal(data.strata_lfo1_shape, 2); assert_equal(data.strata_lfo1_mode, 2); assert_equal(data.strata_lfo1_division, 5)
  assert_near(data.strata_lfo2_rate, 9, 1e-6); assert_equal(data.strata_lfo2_depth, 60)
  assert_equal(data.strata_lfo2_dest, 14); assert_equal(data.strata_lfo2, 1)
  assert_equal(data.strata_lfo2_phase, 30); assert_equal(data.strata_lfo2_rate_mod, 2)
  assert_equal(data.strata_lfo2_depth_mod_amt, -40)
  params:set("strata_lfo2", 0); params:set("strata_lfo2_depth", 0); params:set("strata_lfo2_dest", 1)
  params:set("strata_lfo1_shape", 1); params:set("strata_lfo2_phase", 0); params:set("strata_lfo2_rate_mod", 1)
  recall_scene(1, 0)
  assert_equal(params:get("strata_lfo2"), 1); assert_equal(params:get("strata_lfo2_depth"), 60)
  assert_equal(params:get("strata_lfo2_dest"), 14); assert_equal(params:string("strata_lfo1_shape"), "tri")
  assert_equal(params:get("strata_lfo2_phase"), 30); assert_equal(params:string("strata_lfo2_rate_mod"), "L1")
  assert_true(local_value("S").lib.lfos.is_on(2), "the recalled LFO runs")
  -- smooth transitions fade rate, depth and offset, switch the rest at the end
  local continuous = {}
  for _, global in ipairs(local_value("SCENE_GLOBAL_PARAMS")) do continuous[global.id] = global.continuous end
  for n = 1, local_value("NUM_LFOS") do
    for _, field in ipairs({ "rate", "depth", "offset" }) do
      assert_equal(continuous["strata_lfo" .. n .. "_" .. field], true, field .. " crossfades")
    end
    for _, field in ipairs({ "shape", "mode", "division", "phase", "rate_mod", "rate_mod_amt", "depth_mod",
      "depth_mod_amt", "dest" }) do
      assert_equal(continuous["strata_lfo" .. n .. "_" .. field], false, field .. " switches")
    end
    assert_equal(continuous["strata_lfo" .. n], false, "the state switches")
  end
  -- invalid option values are rejected
  local bad = deep_copy(local_value("scenes")[1]); bad.data.strata_lfo2_dest = 0.5
  assert_true(not validate_scene(bad), "fractional destination rejected")
  bad.data.strata_lfo2_dest = #local_value("LFO_DESTINATIONS") + 1
  assert_true(not validate_scene(bad), "out-of-range destination rejected")
  -- a scene saved before the LFOs existed recalls them as off with defaults
  -- (a depth of 0 on LFOs 1-3, as 3.3 loaded it)
  local old = deep_copy(local_value("scenes")[1])
  for key in pairs(old.data) do
    if key:find("^strata_lfo") then old.data[key] = nil end
  end
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  tab.save({ version = 2, scenes = { old } }, context.data_dir .. "strata/scenes.data")
  load_scenes_from_disk()
  assert_true(local_value("scenes")[1].populated, "pre-LFO scene file loads")
  recall_scene(1, 0)
  assert_equal(params:get("strata_lfo2"), 0); assert_equal(params:get("strata_lfo2_depth"), 0)
  assert_equal(params:get("strata_lfo2_dest"), 1); assert_equal(params:string("strata_lfo1_mode"), "free")
  assert_equal(params:get("strata_lfo5"), 0); assert_equal(params:get("strata_lfo5_depth"), 25, "LFOs 4-6 at their defaults")
end)

-- #103: scenes store each LFO's offset. It sits before the state in
-- SCENE_GLOBAL_PARAMS, so the state switch at a transition's end runs after
-- the offset is set, and keeps it
test("scenes store the LFO offsets; the LFO on/off switch at a transition's end keeps them (#103)", function()
  local context = load_strata(); finish_startup(context)
  local globals, position = {}, {}
  for index, global in ipairs(local_value("SCENE_GLOBAL_PARAMS")) do
    globals[global.id] = global; position[global.id] = index
  end
  for n = 1, local_value("NUM_LFOS") do
    local offset = globals["strata_lfo" .. n .. "_offset"]
    assert_true(offset ~= nil, "LFO " .. n .. "'s offset is a scene global")
    assert_equal(offset.continuous, true, "LFO " .. n .. "'s offset crossfades")
    assert_equal(offset.default, 0, "LFO " .. n .. "'s offset migrates to 0")
    assert_true(position["strata_lfo" .. n .. "_offset"] < position["strata_lfo" .. n], "set before the state")
  end

  -- LFO 1 on with +30 %, LFO 2 off with -20 %
  params:set("strata_lfo1", 1); params:set("strata_lfo1_offset", 30)
  params:set("strata_lfo2_offset", -20)
  capture_scene(1)
  local data = local_value("scenes")[1].data
  assert_equal(data.strata_lfo1_offset, 30, "LFO 1's offset captured")
  assert_equal(data.strata_lfo2_offset, -20, "LFO 2's offset captured")
  assert_equal(data.strata_lfo3_offset, 0, "LFO 3's offset captured")
  -- the other way round: LFO 1 off, LFO 2 on
  params:set("strata_lfo1", 0); params:set("strata_lfo1_offset", -10)
  params:set("strata_lfo2", 1); params:set("strata_lfo2_offset", 40)

  recall_scene(1, 20)  -- 20 steps; the first runs immediately, the switch after the last
  for step = 1, 20 do
    local mix = step / 20
    -- LFO 2 stops at the end: its offset holds until then (#408)
    for n, fade in ipairs({ { from = -10, to = 30 }, { from = 40, to = 40 } }) do
      local offset = params:get("strata_lfo" .. n .. "_offset")
      assert_equal(offset, math.floor(offset), "LFO " .. n .. " offset is a whole percent at step " .. step)
      assert_near(offset, fade.from + (fade.to - fade.from) * mix, 0.5, "LFO " .. n .. " offset at step " .. step)
    end
    assert_equal(params:get("strata_lfo1"), 0, "LFO 1 switches only at the end (step " .. step .. ")")
    assert_equal(params:get("strata_lfo2"), 1, "LFO 2 switches only at the end (step " .. step .. ")")
    wake(context, "scene_transition_clock")
  end
  assert_equal(local_value("scene_transition_active"), false, "transition finished")
  assert_equal(params:get("strata_lfo1"), 1, "LFO 1 turned on at the end")
  assert_equal(params:get("strata_lfo2"), 0, "LFO 2 turned off at the end")
  assert_equal(params:get("strata_lfo1_offset"), 30, "turning LFO 1 on kept the recalled offset")
  assert_equal(params:get("strata_lfo2_offset"), -20, "turning LFO 2 off kept the recalled offset")

  -- an instant recall that switches the LFOs keeps the offsets too
  params:set("strata_lfo1", 0); params:set("strata_lfo1_offset", 5)
  params:set("strata_lfo2", 1); params:set("strata_lfo2_offset", 5)
  recall_scene(1, 0)
  assert_equal(params:get("strata_lfo1"), 1); assert_equal(params:get("strata_lfo2"), 0)
  assert_equal(params:get("strata_lfo1_offset"), 30, "instant recall: LFO 1's offset")
  assert_equal(params:get("strata_lfo2_offset"), -20, "instant recall: LFO 2's offset")
end)

test("LFO offsets in scenes: save and load, migration of older scenes, validation (#103)", function()
  local context = load_strata({ data_subdir = "lfo_offsets" }); finish_startup(context)
  params:set("strata_lfo3", 1); params:set("strata_lfo3_offset", -35); params:set("strata_lfo1_offset", 12)
  capture_scene(2)
  save_scenes_to_disk()
  local saved = context.tab.load(context.data_dir .. "strata/scenes.data")
  assert_equal(saved.scenes[2].data.strata_lfo3_offset, -35, "the offset is saved")

  -- a fresh script loads it and recalls it
  context = load_strata({ data_subdir = "lfo_offsets" }); finish_startup(context)
  assert_equal(local_value("scenes")[2].data.strata_lfo3_offset, -35, "the offset is loaded")
  params:set("strata_lfo1_offset", -40)
  recall_scene(2, 0)
  assert_equal(params:get("strata_lfo3"), 1)
  assert_equal(params:get("strata_lfo3_offset"), -35, "LFO 3's offset recalled after a reload")
  assert_equal(params:get("strata_lfo1_offset"), 12, "LFO 1's offset recalled after a reload")

  -- scenes saved without offsets (version 2, and version 3 before #103) load with offsets 0
  local old = deep_copy(local_value("scenes")[2])
  for n = 1, 3 do old.data["strata_lfo" .. n .. "_offset"] = nil end
  for _, version in ipairs({ 2, 3 }) do
    tab.save({ version = version, scenes = { [2] = deep_copy(old) } }, context.data_dir .. "strata/scenes.data")
    load_scenes_from_disk()
    local loaded = local_value("scenes")[2]
    assert_true(loaded.populated, "a version " .. version .. " scene without offsets loads")
    for n = 1, 3 do
      assert_equal(loaded.data["strata_lfo" .. n .. "_offset"], 0, "version " .. version .. ": offset " .. n .. " migrates to 0")
    end
    params:set("strata_lfo3_offset", 25)
    recall_scene(2, 0)
    assert_equal(params:get("strata_lfo3_offset"), 0, "version " .. version .. ": the migrated offset is recalled")
  end

  -- validation covers the offset's range (-100..100, every baseline's)
  capture_scene(1)
  local scene = deep_copy(local_value("scenes")[1])
  for _, good in ipairs({ -100, -50, 0, 12.5, 100 }) do
    scene.data.strata_lfo2_offset = good
    assert_true(validate_scene(scene), "offset " .. good .. " accepted")
  end
  for _, bad in ipairs({ 101, -100.5, 150, 0 / 0, "20%", {} }) do
    scene.data.strata_lfo2_offset = bad
    assert_true(not validate_scene(scene), "offset " .. tostring(bad) .. " rejected")
  end
  scene.data.strata_lfo2_offset = nil
  assert_true(not validate_scene(scene), "a missing offset is rejected (migration fills it)")
  -- a file with a bad offset is not loaded
  scene.data.strata_lfo2_offset = 250
  tab.save({ version = 3, scenes = { scene } }, context.data_dir .. "strata/scenes.data")
  local captured_offset = local_value("scenes")[1].data.strata_lfo2_offset
  load_scenes_from_disk()
  assert_equal(local_value("scenes")[1].data.strata_lfo2_offset, captured_offset, "the bad file is not loaded")
  assert_true(local_value("scenes")[2].populated, "the current scenes stay")
  assert_true(table.concat(context.printed, "\n"):find("scene file corrupted", 1, true), "the bad file is reported")
end)

test("scenes save as version 6 and a version 4 file loads unchanged but for the pulse res, mirrored (#314)", function()
  local context = load_strata(); finish_startup(context)
  scramble_state(5)
  capture_scene(2)
  local original = deep_copy(local_value("scenes")[2].data)
  save_scenes_to_disk()
  local path = context.data_dir .. "strata/scenes.data"
  local saved = context.tab.load(path)
  assert_equal(saved.version, 6, "scenes are saved as version 6")
  saved.version = 4
  context = load_strata({ data_subdir = "v4" })
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  context.tab.save(saved, context.data_dir .. "strata/scenes.data")
  load_scenes_from_disk()
  local loaded = local_value("scenes")[2]
  assert_true(loaded.populated, "the version 4 scene loads")
  -- a version 4 scene holds the pulse filter's rq as its res: mirrored, 1.1 - res
  local pulse = 5
  assert_equal(local_value("voices")[pulse].name, "pulse")
  original.voices[pulse].params.res = 1.1 - original.voices[pulse].params.res
  -- the whole scene is otherwise unchanged (numbers to the file's precision)
  local function assert_same(expected, actual, where)
    if type(expected) == "number" then
      assert_near(actual, expected, 1e-6, where)
    elseif type(expected) == "table" then
      assert_equal(type(actual), "table", where)
      for key, value in pairs(expected) do assert_same(value, actual[key], where .. "." .. tostring(key)) end
      for key in pairs(actual) do assert_true(expected[key] ~= nil, where .. "." .. tostring(key) .. " is new") end
    else
      assert_equal(actual, expected, where)
    end
  end
  assert_same(original, loaded.data, "scene")
end)

-- #314: from format 5 the Pulse voice's res rises with resonance (the
-- engine plays rq = 1.1 - res); a scene of format 1 to 4 holds the filter's
-- rq itself, so its res is mirrored once, as the file loads, and sounds the
-- same: 3.2's default 0.3 (rq 0.3) loads as 0.8, the new default
test("a scene saved before format 5 loads the pulse voice's res mirrored, once (#314)", function()
  local context = load_strata({ data_subdir = "pulse_res_scenes" }); finish_startup(context)
  local S = local_value("S")
  local pulse = 5
  assert_equal(S.voices[pulse].name, "pulse")
  assert_near(params:get("v5_res"), 0.8, 1e-9, "the default plays rq 0.3, as 3.2's 0.3 did")
  params:set("v5_res", 0.3)
  if not S.voices[pulse].active then toggle_voice(pulse) end  -- the scene plays the pulse voice
  capture_scene(1)
  local scene = deep_copy(S.scenes[1])
  local dir = context.data_dir .. "strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  local cases = {
    { name = "format 4", file = { version = 4, scenes = { deep_copy(scene) } }, expected = 0.8 },
    { name = "format 1", file = { version = 1, scenes = { deep_copy(scene) } }, expected = 0.8 },
    { name = "the bare array before 2.1", file = { deep_copy(scene) }, expected = 0.8 },
    { name = "format 5", file = { version = 5, scenes = { deep_copy(scene) } }, expected = 0.3 },
  }
  for _, case in ipairs(cases) do
    tab.save(case.file, dir .. "scenes.data")
    assert_equal(load_scenes_from_disk(), "loaded", case.name .. " loads")
    assert_near(S.scenes[1].data.voices[pulse].params.res, case.expected, 1e-9, case.name .. ": the pulse res")
    for i = 1, S.constants.NUM_VOICES do
      if i ~= pulse then
        assert_equal(S.scenes[1].data.voices[i].params.res, nil, case.name .. ": voice " .. i .. " gains no res")
      end
    end
  end
  -- a format 4 file recalls the mirrored value, saves as 5 (keeping the old
  -- file as scenes.data.v4) and is never mirrored again
  tab.save({ version = 4, scenes = { deep_copy(scene) } }, dir .. "scenes.data")
  load_scenes_from_disk()
  params:set("v5_res", 0.5)
  context.clear_engine_calls()
  recall_scene(1, 0)
  assert_near(params:get("v5_res"), 0.8, 1e-9, "the recall sets the mirrored value")
  local sent
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == pulse - 1 and call.args[2] == "res" then sent = call.args[3] end
  end
  assert_true(sent ~= nil and math.abs(sent - 0.8) < 1e-6, "the engine plays res 0.8 (sent: " .. tostring(sent) .. ")")
  assert_true(save_scenes_to_disk(), "the migrated file saves")
  assert_equal(S.lib.data_files.read(dir .. "scenes.data").version, 6, "as format 6")
  assert_true(util.file_exists(dir .. "scenes.data.v4"), "the format 4 file is kept as scenes.data.v4")
  load_scenes_from_disk()
  assert_near(S.scenes[1].data.voices[pulse].params.res, 0.8, 1e-9, "a format 5 file read back is not mirrored again")
end)

-- 3.2's number params could hold a fraction (norns' PARAMS menu turned one
-- by d / 20 with K3 held; Number:set never rounds, #534), so a 3.2 scene
-- could too. validate_scene wants a crossmod source and a discrete extra
-- whole, and one fraction set the whole file aside at the first 3.3 start.
-- A scene older than format 5 has those numbers rounded first, as a PSET's
-- number params are (#554); a format 5 file is still checked as it is
test("a 3.2 scene's fractional numbers round as it loads; the file is not set aside", function()
  local context = load_strata({ data_subdir = "fraction_source" }); finish_startup(context)
  for slot = 1, local_value("S").constants.NUM_SCENES do capture_scene(slot) end
  local scenes = deep_copy(local_value("scenes"))
  scenes[3].data.voices[1].crossmod.slot1.source = 0.05   -- voice 0.05: none
  scenes[3].data.voices[2].crossmod.slot2.source = 3.6    -- voice 4
  scenes[5].data.voices[1].extras.intervals = 2.4         -- a discrete extra: set 2
  for _, case in ipairs({ { version = 4, loads = true }, { version = 5, loads = false } }) do
    local subdir = "fraction_v" .. case.version
    local dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. dir .. "'")
    local file = assert(io.open(dir .. "scenes.data", "w"))
    file:write(tabutil_text({ version = case.version, scenes = scenes })); file:close()
    load_strata({ data_subdir = subdir })
    local loaded = local_value("scenes")
    if case.loads then
      for slot = 1, local_value("S").constants.NUM_SCENES do
        assert_true(loaded[slot].populated, "format 4: scene " .. slot .. " loads")
      end
      assert_equal(loaded[3].data.voices[1].crossmod.slot1.source, 0, "0.05 rounds to 0 (none)")
      assert_equal(loaded[3].data.voices[2].crossmod.slot2.source, 4, "3.6 rounds to 4")
      assert_equal(loaded[5].data.voices[1].extras.intervals, 2, "2.4 rounds to 2")
      assert_true(not util.file_exists(dir .. "scenes.data.bak"), "format 4: the file is not set aside")
    else
      assert_true(not loaded[3].populated, "format 5: a fraction is refused, as 3.3 never saves one")
      assert_true(util.file_exists(dir .. "scenes.data.bak"), "format 5: the file is kept as scenes.data.bak")
    end
  end
end)

-- An older-format scenes.data is kept as scenes.data.v<n> before the first
-- save over it (#467), at the first free of nine names. With all nine
-- taken, copies of that format are kept already: the save writes anyway
-- (and says why) rather than refusing every save, the exit's included
test("a full set of format copies never blocks a scene save", function()
  local context = load_strata({ data_subdir = "full_copies_source" }); finish_startup(context)
  capture_scene(1)
  local text = h.tabutil_text({ version = 4, scenes = deep_copy(local_value("scenes")) })
  local dir = data_root .. "full_copies/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  h.write_text(dir .. "scenes.data", text)
  local copies = {}
  for number = 1, 9 do
    copies[number] = dir .. "scenes.data.v4" .. (number > 1 and ("." .. number) or "")
    h.write_text(copies[number], "copy " .. number)
  end
  context = load_strata({ data_subdir = "full_copies" }); finish_startup(context)
  local S = local_value("S")
  assert_true(S.scenes[1].populated, "the format 4 file loads")
  capture_scene(2)
  assert_true(save_scenes_to_disk(), "the save goes ahead")
  assert_equal(S.lib.data_files.read(dir .. "scenes.data").version, 6, "scenes.data is written, as format 6")
  assert_true(S.lib.data_files.read(dir .. "scenes.data").scenes[2].populated, "with this session's scenes")
  for number = 1, 9 do
    assert_equal(h.file_text(copies[number]), "copy " .. number, "copy " .. number .. " is kept as it was")
  end
  assert_true(table.concat(context.printed, "\n"):find("every .v4 copy name is taken", 1, true),
    "the console says why no copy was kept: " .. table.concat(context.printed, " | "))
end)

test("S.lib.scenes.save captures and flashes; capture_scene stays silent", function()
  load_strata()
  local S = local_value("S")
  assert_true(S.lib.scenes.save(3), "slot 3 saves")
  assert_true(S.scenes[3].populated, "captured")
  assert_equal(S.lib.ui_flash.text("header"), "saved S3")
  assert_true(not S.lib.scenes.save(0), "slot 0 is refused")
  assert_true(not S.lib.scenes.save(17), "slot 17 is refused")
  load_strata()
  S = local_value("S")
  capture_scene(3)
  assert_equal(S.lib.ui_flash.text("header"), nil, "capture_scene says nothing")
end)

-- scenes.data on disk (#301)

local file_text, write_text, watch_writes = h.file_text, h.write_text, h.watch_writes

local function printed_count(context, text)
  local count = 0
  for _, line in ipairs(context.printed) do
    if line:find(text, 1, true) then count = count + 1 end
  end
  return count
end

test("a saved scene is on disk before the script exits; an exit with nothing new writes nothing (#327)", function()
  local context = load_strata({ data_subdir = "scene_on_disk" }); finish_startup(context)
  local S = local_value("S")
  local path = context.data_dir .. "strata/scenes.data"
  assert_true(not util.file_exists(path), "no scenes file yet")
  scramble_state(3)
  S.lib.scenes.save(2)
  assert_equal(S.lib.ui_flash.text("header"), "saved S2")
  assert_true(util.file_exists(path), "written by the save, not by the exit")
  local freq = S.scenes[2].data.voices[1].params.freq
  -- the same scene saved again: nothing is written
  local restore, opened = watch_writes("scenes.data")
  S.lib.scenes.save(2)
  restore()
  assert_equal(S.lib.ui_flash.text("header"), "saved S2", "an unchanged file holds the scene")
  assert_equal(#opened, 0, "the same scene saved again opens nothing for writing")
  -- no cleanup: a crash, a power cut, maiden's ;restart
  context = load_strata({ data_subdir = "scene_on_disk" })
  S = local_value("S")
  assert_true(S.scenes[2].populated, "the scene survived without a clean exit")
  assert_near(S.scenes[2].data.voices[1].params.freq, freq, 1e-6)
  -- an exit with nothing new: nothing is written
  restore, opened = watch_writes("scenes.data")
  cleanup()
  restore()
  for _, name in ipairs(opened) do
    assert_true(not name:find("scenes.data", 1, true), "an unchanged scenes.data is not rewritten: " .. name)
  end
end)

test("a scenes write that fails keeps the old file and says so; the next save that works clears it (#301)", function()
  local context = load_strata({ data_subdir = "scene_write_fails" }); finish_startup(context)
  local S = local_value("S")
  local path = context.data_dir .. "strata/scenes.data"
  S.lib.scenes.save(1)
  local good = file_text(path)
  assert_true(good ~= nil and S.lib.data_files.decode(good).scenes[1].populated, "scene 1 is on disk")
  -- the card fills: every write to scenes.data (or a file beside it) stops at 2000 bytes
  local restore = watch_writes("scenes.data", { at = "write", after = 2000 })
  params:set("v1_freq", 333)
  S.lib.scenes.save(2)
  assert_equal(S.lib.ui_flash.text("header"), "S2 not on disk", "the header says the scene is in memory only")
  assert_equal(file_text(path), good, "the file is byte for byte the last good one")
  assert_equal(printed_count(context, "scenes saved to"), 1, "a failed write never says saved")
  assert_equal(printed_count(context, "error: scenes not saved to " .. path), 1, "the console says why")
  assert_true(S.scene_file.unsaved, "a scene of this session is not on disk")
  assert_equal(S.scene_file.problem, "not saved")
  assert_true(S.scenes[2].populated, "the scene is kept in memory")
  -- the exit tries again and fails the same way: the file stays
  cleanup()
  assert_equal(file_text(path), good, "a failed exit save keeps the file too")
  restore()
  -- room again: the next save writes both scenes and clears the problem
  context = load_strata({ data_subdir = "scene_write_fails" })
  S = local_value("S")
  S.lib.scenes.save(3)
  restore = watch_writes("scenes.data", { at = "write", after = 2000 })
  S.lib.scenes.save(4)
  restore()
  assert_equal(S.scene_file.problem, "not saved")
  S.lib.scenes.save(5)
  assert_equal(S.lib.ui_flash.text("header"), "saved S5")
  assert_equal(S.scene_file.problem, nil, "a write that works clears the problem")
  assert_equal(S.scene_file.unsaved, false)
  local saved = S.lib.data_files.read(path)
  assert_true(saved.scenes[4].populated and saved.scenes[5].populated, "the unsaved scene went with the next save")
end)

test("a load asks for a second request only while a scene saved in this session is not on disk (#328)", function()
  local context = load_strata({ data_subdir = "scene_load_confirm" }); finish_startup(context)
  local S = local_value("S")
  S.lib.scenes.save(1)
  assert_equal(S.lib.scenes.request_load(), "loaded", "the file holds every saved scene: the load runs at once")
  local restore = watch_writes("scenes.data", { at = "write", after = 0 })
  S.lib.scenes.save(2)
  restore()
  assert_equal(S.lib.scenes.request_load(), "confirm", "a scene not on disk: the first request only asks")
  assert_true(S.scenes[2].populated, "and leaves the scene")
  context.set_time(util.time() + 1.5)
  assert_equal(S.lib.scenes.request_load(), "loaded", "a second request within 2 s loads")
  assert_true(not S.scenes[2].populated, "the file's scenes replace the unsaved one")
  assert_equal(S.scene_file.unsaved, false, "memory holds the file's scenes")
  assert_equal(S.lib.scenes.request_load(), "loaded", "and the next request loads at once")
  -- the request lapses after 2 s
  restore = watch_writes("scenes.data", { at = "write", after = 0 })
  S.lib.scenes.save(2)
  restore()
  assert_equal(S.lib.scenes.request_load(), "confirm")
  context.set_time(util.time() + 2.5)
  assert_equal(S.lib.scenes.request_load(), "confirm", "a request after 2 s asks again")
  assert_true(S.scenes[2].populated)
  -- the PARAMS trigger: the first says so on the console and leaves the scene, the second loads
  context.set_time(util.time() + 2.5)
  params:set("load_scenes", 1)
  assert_true(S.scenes[2].populated, "PARAMS: the first trigger leaves the scene")
  assert_equal(printed_count(context, "trigger again within 2 s"), 1, "and says why")
  params:set("load_scenes", 1)
  assert_true(not S.scenes[2].populated, "PARAMS: the second trigger loads")
  -- no file: "missing"; an unreadable file: "unreadable", the scenes kept
  S.lib.scenes.save(3)
  os.remove(context.data_dir .. "strata/scenes.data")
  assert_equal(S.lib.scenes.request_load(), "missing")
  assert_true(S.scenes[3].populated, "no file: the scenes stay")
  write_text(context.data_dir .. "strata/scenes.data", "return {")
  assert_equal(S.lib.scenes.request_load(), "unreadable")
  assert_true(S.scenes[3].populated, "an unreadable file: the scenes stay")
end)

test("two unloadable scenes files leave two backups, each with its own bytes (#466)", function()
  local dir = data_root .. "scene_two_backups/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  local newer = tabutil_text({ version = 99, scenes = {} })
  write_text(dir .. "scenes.data", newer)
  local context = load_strata({ data_subdir = "scene_two_backups" })
  local S = local_value("S")
  assert_equal(S.scene_file.problem, "unreadable")
  assert_equal(S.scene_file.backup, dir .. "scenes.data.bak", "the name it was kept under")
  cleanup()
  write_text(dir .. "scenes.data", "return {")
  context = load_strata({ data_subdir = "scene_two_backups" })
  S = local_value("S")
  assert_equal(file_text(dir .. "scenes.data.bak"), newer, "the first backup is still the first file")
  assert_equal(file_text(dir .. "scenes.data.bak.2"), "return {", "the second file has its own backup")
  assert_equal(S.scene_file.backup, dir .. "scenes.data.bak.2")
  assert_true(table.concat(context.printed, "\n"):find("kept as " .. dir .. "scenes.data.bak.2", 1, true) ~= nil,
    "the console names the backup")
end)

test("an older format's scenes.data is kept as scenes.data.v<n> when it is first replaced (#467)", function()
  local context = load_strata({ data_subdir = "scene_old_source" })
  capture_scene(1)
  local scenes = deep_copy(local_value("scenes"))
  local dir = data_root .. "scene_old/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  -- a version 3 file is a version 4 one under the older number (4 changed no field)
  context.tab.save({ version = 3, scenes = scenes }, dir .. "scenes.data")
  local original = file_text(dir .. "scenes.data")
  context = load_strata({ data_subdir = "scene_old" })
  assert_true(local_value("scenes")[1].populated)
  assert_true(not util.file_exists(dir .. "scenes.data.v3"), "nothing is copied until the file is replaced")
  -- a save whose write fails after the copy, then one that works: one copy, said once
  os.execute("mkdir -p '" .. dir .. "scenes.data.part/inside'")
  local_value("S").lib.scenes.save(2)
  assert_equal(file_text(dir .. "scenes.data"), original, "the failed write left the older file")
  os.remove(dir .. "scenes.data.part/inside"); os.remove(dir .. "scenes.data.part")
  cleanup()
  assert_equal(printed_count(context, "kept as " .. dir .. "scenes.data.v3"), 1,
    "the copy is named once, when it is made")
  assert_equal(file_text(dir .. "scenes.data.v3"), original, "the older file's bytes are kept")
  assert_equal(local_value("S").lib.data_files.read(dir .. "scenes.data").version, 6, "the file is this format now")
  load_strata({ data_subdir = "scene_old" }); local_value("S").lib.scenes.save(2); cleanup()
  assert_true(not util.file_exists(dir .. "scenes.data.v3.2"), "no second copy")
  assert_equal(file_text(dir .. "scenes.data.v3"), original)
end)

test("an unreadable scenes.data is named on the hint row at start (#463)", function()
  local dir = data_root .. "scene_start_flash/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  write_text(dir .. "scenes.data", "return {")
  local context = load_strata({ data_subdir = "scene_start_flash" })
  local S = local_value("S")
  assert_equal(S.lib.ui_flash.text("hints"), "scenes unreadable (SETUP)", "on whatever page comes up")
  next_frame(context)
  -- (cut to the row by the stub's widths, which are wider than norns' font)
  assert_true(tostring(h.hint_text(context)):find("^scenes unreadable") ~= nil, "drawn on the hint row")
  context.clock.run_for(3.9)
  assert_equal(S.lib.ui_flash.text("hints"), "scenes unreadable (SETUP)", "for 4 s")
  context.clock.run_for(0.2)
  assert_equal(S.lib.ui_flash.text("hints"), nil)
  -- a file that reads says nothing
  load_strata()
  assert_equal(local_value("S").lib.ui_flash.text("hints"), nil, "no file: no flash")
end)

test("a load from disk keeps the current scene only when that slot's data is unchanged (#518)", function()
  local context = load_strata({ data_subdir = "scene_load_current" }); finish_startup(context)
  local S = local_value("S")
  scramble_state(4)
  capture_scene(3)
  recall_scene(3, 0)
  assert_equal(S.current_scene, 3)
  save_scenes_to_disk()
  load_scenes_from_disk()
  assert_equal(S.current_scene, 3, "the file holds the same scene 3: it stays current")
  -- slot 3 in memory differs from the file's
  params:set("v1_freq", 333)
  capture_scene(3)
  load_scenes_from_disk()
  assert_equal(S.current_scene, 0, "scene 3 is now the file's, not what was recalled: no scene is current")
  next_frame(context)
  assert_true(not screen_shows(context, "S3"), "the header marks no scene")
  -- before the change it did
  recall_scene(3, 0); next_frame(context)
  assert_true(screen_shows(context, "S3"), "the header marks scene 3 while it is current")
end)

-- #538: norns' Binary:set sends no MIDI-map CC (only ParamSet:delta does), so
-- a recall sets a binary param through set_binary_param (lib/ui/params.lua):
-- a controller mapped to it in PARAMS > MAP follows. The maps are as
-- lua/core/pmap.lua's pmap.new makes them, with echo on
test("a recall and a fade's end echo a mapped binary param to its controller (#538)", function()
  local context = load_strata(); finish_startup(context)
  local controller = context.midi.plug(1)
  local cc_of = { v1_quantize = 21, mutation_enabled = 22 }
  for param_id, cc in pairs(cc_of) do
    norns.pmap.data[param_id] = { dev = 1, ch = 1, cc = cc, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
      echo = true, value = 0 }
  end
  local function echoes(cc)
    local values = {}
    for _, message in ipairs(controller.sent) do
      if message[2] == cc then table.insert(values, message[3]) end
    end
    return values
  end
  params:set("v1_quantize", 1); params:set("mutation_enabled", 1)
  capture_scene(1)
  params:set("v1_quantize", 0); params:set("mutation_enabled", 0)
  assert_equal(#controller.sent, 0, "params:set alone echoes nothing, as norns' Binary:set")
  recall_scene(1, 0)
  for param_id, cc in pairs(cc_of) do
    assert_equal(params:get(param_id), 1, param_id .. " recalled")
    assert_equal(table.concat(echoes(cc), ","), "127", "an instant recall echoes " .. param_id .. " once")
    assert_equal(norns.pmap.data[param_id].value, 127, "its map keeps the value, as norns' does")
  end
  params:set("v1_quantize", 0); params:set("mutation_enabled", 0)
  controller.sent = {}
  recall_scene(1, 2)
  context.clock.run_for(1.5, 0.001)
  assert_equal(#echoes(21) + #echoes(22), 0, "a fade switches them only at its end")
  context.clock.run_for(1, 0.001)
  assert_equal(local_value("scene_transition_active"), false, "the fade landed")
  for param_id, cc in pairs(cc_of) do
    assert_equal(table.concat(echoes(cc), ","), "127", "the fade's end echoes " .. param_id .. " once")
  end
  params:set("mutation_enabled", 0)
end)

-- #513: the scene sequencer skips an empty slot at once, so the scene after
-- it follows the last scene's hold; a sequence with no scene in it holds
-- each empty slot for the scene duration (its clock never spins)
test("the scene sequencer skips an empty slot at once (#513)", function()
  local context = load_strata(); finish_startup(context)
  capture_scene(1); capture_scene(3)                              -- slot 2 empty
  params:set("scene_sequence_length", 3)
  local recalls = run_scene_sequencer(context, 0, 4, 9)
  local scenes, times = {}, {}
  for index, recall in ipairs(recalls) do scenes[index] = recall.scene; times[index] = recall.time end
  assert_equal(table.concat(scenes, " "), "1 3 1", "scene 3 follows scene 1, then scene 1 again")
  assert_near(times[2], 4, 0.01, "scene 3 after scene 1's 4 s hold, not after another 4 s on slot 2")
  assert_near(times[3], 8, 0.01, "scene 1 after scene 3's hold")
  params:set("scene_sequencer_enabled", 0)
  -- an empty first slot: the sequencer starts on the first scene that holds one
  context = load_strata(); finish_startup(context)
  capture_scene(2); capture_scene(3)
  params:set("scene_sequence_length", 3)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  local S = local_value("S")
  assert_equal(S.lib.scenes.sequencer_next_slot(), 2, "before its first recall it recalls slot 2 next")
  context.clock.run_for(0.01, 0.001)
  assert_equal(S.current_scene, 2, "it recalled scene 2 at once")
  assert_equal(S.lib.scenes.sequencer_next_slot(), 3, "then scene 3")
  context.clock.run_for(4, 0.001)
  assert_equal(S.current_scene, 3)
  assert_equal(S.lib.scenes.sequencer_next_slot(), 2, "after scene 3: scene 2, past empty slot 1")
  params:set("scene_sequencer_enabled", 0)
  -- no scene in the sequence: each slot is held for the duration
  context = load_strata(); finish_startup(context)
  params:set("scene_sequence_length", 3)
  recalls = run_scene_sequencer(context, 0, 4, 9)
  S = local_value("S")
  assert_equal(#recalls, 0, "nothing to recall")
  assert_equal(S.scene_sequencer_position, 3, "one slot every 4 s: slot 3 at 9 s")
  assert_equal(S.lib.scenes.sequencer_next_slot(), 1, "then slot 1")
  params:set("scene_sequencer_enabled", 0)
end)

-- #329: an error in a pass of the sequencer's loop outside its recall (which
-- reports it and goes on) stops the sequencer through its param, so the
-- screen, the grids and the state agree, and is raised again for maiden
test("an error in the scene sequencer's advance stops it through its param (#329)", function()
  local context = load_strata(); finish_startup(context)
  capture_scene(1); capture_scene(2)
  params:set("scene_sequence_length", 2)
  local S = local_value("S")
  local real_grid_redraw, raised = grid_redraw, false
  grid_redraw = function(...)
    if not raised and S.scene_sequencer_position == 2 then raised = true; error("grid redraw failed") end
    return real_grid_redraw(...)
  end
  local recalls = run_scene_sequencer(context, 0, 4, 5)           -- the advance at 4 s raises
  grid_redraw = real_grid_redraw
  local errors = context.clock.take_errors()
  assert_equal(params:get("scene_sequencer_enabled"), 0, "the param shows the sequencer off")
  assert_equal(S.scene_sequencer_enabled, false, "and it is off")
  assert_equal(S.scene_sequencer_clock, nil, "its clock id is forgotten")
  assert_equal(#errors, 1, "one clock error")
  assert_true(errors[1]:find("grid redraw failed", 1, true), "the advance's error")
  assert_true(errors[1]:find("stack traceback:", 1, true), "with its traceback")
  assert_equal(S.lib.scenes.sequencer_next_slot(), nil, "no next scene is lit")
  context.clock.run_for(10, 0.001)
  assert_equal(#recalls, 1, "nothing is recalled after the stop")
  params:set("scene_sequencer_enabled", 1)                        -- one switch starts it again
  context.clock.run_for(0.01, 0.001)
  assert_equal(#recalls, 2, "from scene 1")
  assert_equal(recalls[2].scene, 1)
  params:set("scene_sequencer_enabled", 0)
end)

-- #329 with #538: the error stop sets the binary scene_sequencer_enabled
-- through set_binary_param, so a controller mapped to it in PARAMS > MAP
-- (the map as lua/core/pmap.lua's pmap.new makes it, echo on) goes dark too
test("the scene sequencer's error stop echoes the off to a mapped controller (#329)", function()
  local context = load_strata(); finish_startup(context)
  capture_scene(1); capture_scene(2)
  params:set("scene_sequence_length", 2)
  local controller = context.midi.plug(1)
  norns.pmap.data["scene_sequencer_enabled"] = { dev = 1, ch = 1, cc = 23, in_lo = 0, in_hi = 127,
    out_lo = 0, out_hi = 1, echo = true, value = 127 }
  local S = local_value("S")
  local real_grid_redraw, raised = grid_redraw, false
  grid_redraw = function(...)
    if not raised and S.scene_sequencer_position == 2 then raised = true; error("grid redraw failed") end
    return real_grid_redraw(...)
  end
  run_scene_sequencer(context, 0, 4, 5)                           -- the advance at 4 s raises
  grid_redraw = real_grid_redraw
  assert_equal(#context.clock.take_errors(), 1, "the error is raised again")
  assert_equal(params:get("scene_sequencer_enabled"), 0, "the param shows the sequencer off")
  local echoes = {}
  for _, message in ipairs(controller.sent) do
    if message[2] == 23 then table.insert(echoes, message[3]) end
  end
  assert_equal(table.concat(echoes, ","), "0", "the mapped controller gets one CC: off")
  assert_equal(norns.pmap.data["scene_sequencer_enabled"].value, 0, "its map keeps the value, as norns' does")
end)

-- #408: a fade to a scene that stops a running LFO fades its depth out,
-- never toward the scene's depth (a setting the scene never plays), and
-- leaves its period and offset; the end sets the scene's exact values with
-- the state
test("a fade that stops an LFO fades its depth out and holds its period and offset (#408)", function()
  local context = load_strata(); finish_startup(context)
  params:set("strata_lfo1_depth", 80); params:set("strata_lfo1_rate", 1 / 30); params:set("strata_lfo1_offset", -40)
  params:set("strata_lfo1", 0)                                    -- off in the scene
  capture_scene(1)
  params:set("strata_lfo1_depth", 10); params:set("strata_lfo1_rate", 0.25); params:set("strata_lfo1_offset", 20)
  params:set("strata_lfo1", 1)                                    -- on now
  local rate = params:get("strata_lfo1_rate")
  recall_scene(1, 20)                                             -- 20 steps of 1 s
  local previous = 10
  for step = 1, 20 do
    local depth = params:get("strata_lfo1_depth")
    assert_true(depth <= previous, "step " .. step .. ": the depth never rises (" .. previous .. " -> " .. depth .. ")")
    assert_equal(depth, math.floor(depth), "step " .. step .. ": a whole percent")
    assert_near(depth, 10 * (1 - step / 20), 0.5, "step " .. step .. ": the depth fades toward 0")
    assert_equal(params:get("strata_lfo1_rate"), rate, "step " .. step .. ": the rate holds")
    assert_equal(params:get("strata_lfo1_offset"), 20, "step " .. step .. ": the offset holds")
    assert_equal(params:get("strata_lfo1"), 1, "step " .. step .. ": the LFO runs until the end")
    previous = depth
    wake(context, "scene_transition_clock")
  end
  assert_equal(local_value("scene_transition_active"), false, "the fade landed")
  assert_equal(params:get("strata_lfo1"), 0, "the LFO stops at the end")
  assert_equal(params:get("strata_lfo1_depth"), 80, "with the scene's depth")
  assert_near(params:get("strata_lfo1_rate"), 1 / 30, 1e-6, "the scene's rate")
  assert_equal(params:get("strata_lfo1_offset"), -40, "and the scene's offset")
end)

-- #411: what the review's mutations of lib/scenes.lua survived
test("recall_scene and capture_scene ignore a scene number outside 1..NUM_SCENES (#411)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  capture_scene(1)
  for _, scene_num in ipairs({ 0, S.constants.NUM_SCENES + 1 }) do
    local recalled, recall_error = pcall(recall_scene, scene_num, 0)
    assert_true(recalled, "recall_scene(" .. scene_num .. ") raises nothing: " .. tostring(recall_error))
    local captured, capture_error = pcall(capture_scene, scene_num)
    assert_true(captured, "capture_scene(" .. scene_num .. ") raises nothing: " .. tostring(capture_error))
    assert_equal(S.scenes[scene_num], nil, "and adds no slot " .. scene_num)
  end
  assert_equal(S.current_scene, 0, "no scene was recalled")
  assert_equal(#S.scenes, S.constants.NUM_SCENES, "still eight slots")
end)

test("validate_scene rejects a non-boolean active, an unknown grain key and crossmod amounts that are not numbers (#411)", function()
  load_strata()
  capture_scene(1)
  local good = deep_copy(local_value("scenes")[1])
  assert_true(validate_scene(good), "the captured scene validates")
  local function rejects(mutator, message)
    local candidate = deep_copy(good)
    mutator(candidate.data)
    assert_true(not validate_scene(candidate), "should reject: " .. message)
  end
  rejects(function(data) data.voices[3].active = 1 end, "an active flag that is not a boolean")
  rejects(function(data) data.voices[3].active = nil end, "a missing active flag")
  rejects(function(data) data.voices[2].grain.future_key = 0.5 end, "a grain key from a later version")
  rejects(function(data) data.voices[5].crossmod.slot2.amp_amt = nil end, "a missing amp amount")
  rejects(function(data) data.voices[5].crossmod.slot3.amp_amt = "deep" end, "an amp amount that is not a number")
  rejects(function(data) data.voices[6].crossmod.slot1.freq_amt = nil end, "a missing freq amount")
  rejects(function(data) data.voices[6].crossmod.slot2.freq_amt = 0 / 0 end, "a freq amount that is NaN")
end)

test("a fade holds tempo and the mutation settings until its end (#411)", function()
  local context = load_strata(); finish_startup(context)
  local ids = { "tempo", "mutation_enabled", "mutation_rate", "mutation_probability", "mutation_amount" }
  params:set("tempo", 90); params:set("mutation_enabled", 1); params:set("mutation_rate", 8)
  params:set("mutation_probability", 0.6); params:set("mutation_amount", 0.75)
  capture_scene(1)
  local saved = {}
  for _, id in ipairs(ids) do saved[id] = params:get(id) end
  params:set("tempo", 150); params:set("mutation_enabled", 0); params:set("mutation_rate", 1)
  params:set("mutation_probability", 0.05); params:set("mutation_amount", 0.1)
  local before = {}
  for _, id in ipairs(ids) do before[id] = params:get(id) end
  recall_scene(1, 20)
  for step = 1, 20 do
    for _, id in ipairs(ids) do
      assert_equal(params:get(id), before[id], id .. " holds at step " .. step)
    end
    wake(context, "scene_transition_clock")
  end
  assert_equal(local_value("scene_transition_active"), false, "the fade landed")
  for _, id in ipairs(ids) do assert_equal(params:get(id), saved[id], id .. " switches at the end") end
  params:set("mutation_enabled", 0)
end)

test("a registered discrete binary or number scene field holds a whole value in its range (#411)", function()
  load_strata({ before_init = function()
    local S = local_value("S")
    S.register_fx_params({ name = "probe fields", count = 2, add = function()
      params:add_binary("probe_flag", "probe flag", "toggle", 0)
      params:add_number("probe_count", "probe count", 1, 4, 2)
    end })
    S.register_scene_field({ id = "probe_flag", default = 0, discrete = true })
    S.register_scene_field({ id = "probe_count", default = 2, discrete = true })
  end })
  capture_scene(1)
  local good = deep_copy(local_value("scenes")[1])
  assert_true(validate_scene(good), "the captured scene validates")
  for _, case in ipairs({ { id = "probe_flag", value = 0.5 }, { id = "probe_flag", value = 2 },
    { id = "probe_flag", value = -1 }, { id = "probe_count", value = 2.5 }, { id = "probe_count", value = 0 },
    { id = "probe_count", value = 5 } }) do
    local candidate = deep_copy(good)
    candidate.data[case.id] = case.value
    assert_true(not validate_scene(candidate), "should reject " .. case.id .. " = " .. case.value)
  end
  local candidate = deep_copy(good)
  candidate.data.probe_flag, candidate.data.probe_count = 1, 4
  assert_true(validate_scene(candidate), "whole values in range validate")
end)

test("a recall that changes only the locks updates MAIN's voice list (#411)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  toggle_lock(4)
  capture_scene(1)
  toggle_lock(4)
  assert_true(not S.voice_list.entries[4]:find("[L]", 1, true), "voice 4 shows unlocked")
  recall_scene(1, 0)
  assert_true(S.frozen[4], "the recall locked voice 4")
  assert_true(S.voice_list.entries[4]:find("[L]", 1, true), "and MAIN's list marks it [L]")
end)

test("a restarted scene sequencer recalls scene 1 first (#411)", function()
  local context = load_strata(); finish_startup(context)
  for scene = 1, 3 do capture_scene(scene) end
  params:set("scene_sequence_length", 3)
  local recalls = run_scene_sequencer(context, 0, 4, 5)           -- scene 1, then scene 2 at 4 s
  assert_equal(recalls[#recalls].scene, 2, "the sequencer is on scene 2")
  params:set("scene_sequencer_enabled", 0)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(0.01, 0.001)
  assert_equal(recalls[#recalls].scene, 1, "a restart begins at scene 1")
  params:set("scene_sequencer_enabled", 0)
end)

-- SCENES marks the slot the sequencer is on with ">"; with no scene in the
-- sequence nothing is recalled, so only the advance's redraw moves it
test("the scene sequencer's advance redraws the screen (#411)", function()
  local context = load_strata(); finish_startup(context)
  show_page("SCENES")
  params:set("scene_sequence_length", 3)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  local function mark_y()
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == ">" then return entry.y end
    end
  end
  context.clock.run_for(1, 0.001)
  local first = mark_y()
  assert_true(first ~= nil, "SCENES marks slot 1")
  context.clock.run_for(4, 0.001)
  assert_equal(local_value("scene_sequencer_position"), 2, "the sequencer moved to slot 2")
  assert_true(mark_y() ~= nil and mark_y() > first, "and the screen moved the mark down to it")
  params:set("scene_sequencer_enabled", 0)
end)

test("a good load after a blocked one lets the scenes save again (#411)", function()
  local data_dir = data_root .. "unblocked/strata/"
  -- every backup name is taken (by a folder): the bad file cannot be moved aside
  os.execute("mkdir -p '" .. data_dir .. "scenes.data.bak'")
  for number = 2, 9 do os.execute("mkdir -p '" .. data_dir .. "scenes.data.bak." .. number .. "'") end
  local file = assert(io.open(data_dir .. "scenes.data", "w"))
  file:write(tabutil_text({ version = 99, scenes = {} }))
  file:close()
  load_strata({ data_subdir = "unblocked" })
  local S = local_value("S")
  assert_equal(S.scene_autosave_blocked, true, "the bad file blocks the autosave")
  -- a good file takes its place (written from outside), and is loaded
  assert_true(S.lib.data_files.write(data_dir .. "scenes.data",
    { version = S.constants.SCENE_DATA_VERSION, scenes = S.scenes }), "a good file written")
  assert_equal(load_scenes_from_disk(), "loaded")
  assert_equal(S.scene_autosave_blocked, false, "the good load unblocks the autosave")
  capture_scene(4)
  cleanup()
  load_strata({ data_subdir = "unblocked" })
  assert_true(local_value("scenes")[4].populated, "the exit saved scene 4")
end)

-- #531: a recall and every fade step set a voice's registered fields in
-- sorted key order (pairs' order changes from run to run and between Lua
-- 5.3 and LuaJIT), so a recall sets and sends them the same way every time
test("a recall and a fade set a voice's registered fields in sorted key order (#531)", function()
  local keys = { "probe_h", "probe_c", "probe_f", "probe_a", "probe_g", "probe_d", "probe_b", "probe_e" }
  local order = {}
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    local defaults = {}
    for _, key in ipairs(keys) do defaults[key] = 0 end
    local record = { name = "probe order", count = #keys, scene_defaults = defaults, fader = false }
    function record.add(voice_idx)
      for _, key in ipairs(keys) do
        S.lib.params_setup.add_voice_extra(voice_idx, record, key, { type = "control", name = key,
          controlspec = controlspec.new(0, 1, "lin", 0, 0),
          action = function() if voice_idx == 1 then table.insert(order, key) end end })
      end
    end
    S.register_voice_params(record)
  end })
  finish_startup(context)
  for _, key in ipairs(keys) do params:set("v1_" .. key, 0.5) end
  capture_scene(1)
  for _, key in ipairs(keys) do params:set("v1_" .. key, 0) end
  local sorted = {}
  for _, key in ipairs(keys) do sorted[#sorted + 1] = key end
  table.sort(sorted)
  order = {}
  recall_scene(1, 0)
  assert_equal(table.concat(order, " "), table.concat(sorted, " "), "an instant recall sets them in key order")
  for _, key in ipairs(keys) do params:set("v1_" .. key, 0) end
  order = {}
  recall_scene(1, 2)                                              -- the first step runs at once
  assert_equal(table.concat(order, " "), table.concat(sorted, " "), "a fade step sets them in key order")
  context.clock.run_for(3, 0.001)
end)

---------------------------------------------------------------------------
-- 3.4 (0b): recall through scene_entries and apply_entries, scene blocks,
-- migrations, revisions and slot names
---------------------------------------------------------------------------

-- The merged recall_scene_instant (lib/scenes.lua at 3.3.2), from its flag
-- to its pattern restore, copied verbatim, with the two local helpers it
-- calls (set_scene_param, sorted_keys). Its clear_undo, current scene and
-- redraws send nothing to the engine and are left out
local function reference_recall(S, scene_data)
  local NUM_VOICES, NUM_MOD_SLOTS = S.constants.NUM_VOICES, S.constants.NUM_MOD_SLOTS
  local GRAIN_PARAM_IDS = S.constants.GRAIN_PARAM_IDS
  local function set_scene_param(param_id, value)
    if params:lookup_param(param_id).t == params.tBINARY then
      set_binary_param(param_id, value)
    else
      params:set(param_id, value)
    end
  end
  local function sorted_keys(entries)
    local keys = {}
    for key in pairs(entries) do table.insert(keys, key) end
    table.sort(keys)
    return keys
  end

  local source_changed = {}
  S.scene_recall_in_progress = true
  -- the flag must not outlive an error in a param action: clear it, then
  -- raise the error again, with its traceback
  local recalled, recall_error = xpcall(function()
    -- Restore global parameters
    for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
      set_scene_param(global.id, scene_data[global.id])
    end

    -- Restore voice states
    for i = 1, NUM_VOICES do
      local voice_data = scene_data.voices[i]
      local prefix = "v" .. i .. "_"

      -- A voice the scene stops is stopped first, so the engine only records
      -- its source switch instead of building a grain synth to release at
      -- once, and its release tail keeps the outgoing scene's values
      if S.voices[i].active and not voice_data.active then toggle_voice(i) end

      local previous_source = S.voices[i].source
      set_scene_param(prefix .. "source", voice_data.source)
      source_changed[i] = S.voices[i].source ~= previous_source

      for key, value in pairs(voice_data.params) do
        set_scene_param(prefix .. key, value)
      end

      for key, value in pairs(voice_data.grain) do
        set_scene_param(prefix .. GRAIN_PARAM_IDS[key], value)
      end

      -- Restore crossmod slots
      for slot = 1, NUM_MOD_SLOTS do
        local slot_data = voice_data.crossmod["slot" .. slot]
        set_scene_param(prefix .. "mod_source_" .. slot, slot_data.source)
        set_scene_param(prefix .. "mod_amp_amt_" .. slot, slot_data.amp_amt)
        set_scene_param(prefix .. "mod_freq_amt_" .. slot, slot_data.freq_amt)
      end
      set_scene_param(prefix .. "mod_speed", voice_data.crossmod.speed)

      -- The registered voice params, after the source (a discrete one,
      -- such as freeze, only now: a transition crossfades the others), in
      -- key order (#531)
      for _, key in ipairs(sorted_keys(voice_data.extras)) do
        set_scene_param(prefix .. key, voice_data.extras[key])
      end

      -- 3.4 (0b) adds the lock hooks to a recall: a lock that changes runs
      -- them (scatter's voice mask, lib/scatter.lua, sends setScatter)
      local was_locked = S.frozen[i]
      S.frozen[i] = scene_data.frozen[i]
      if (not was_locked) ~= (not S.frozen[i]) then
        for _, hook in ipairs(S.registry.lock_change) do hook(i, S.frozen[i]) end
      end

      -- Start voices last: toggle_voice syncs the restored state
      if voice_data.active and not S.voices[i].active then
        toggle_voice(i)
        source_changed[i] = false
      end
    end
  end, with_traceback)
  S.scene_recall_in_progress = false

  -- even after an error: a running voice whose source switched gets its sync
  -- (of whatever was applied), so the engine never lags the Lua state
  for i = 1, NUM_VOICES do
    if source_changed[i] and S.voices[i].active then
      sync_voice_values_to_engine(i)
    end
  end
  if not recalled then error(recall_error, 0) end

  -- Restore patterns
  for i = 1, NUM_VOICES do
    S.lib.sequencer.replace_pattern(i, scene_data.patterns[i])
  end
end

-- The merged scene_transition_targets (lib/scenes.lua at 3.3.2), copied
-- verbatim, with the local helpers it calls (LFO_STATE,
-- registered_voice_scene_keys, sorted_keys)
local function reference_targets(S, scene_data)
  local NUM_VOICES, NUM_MOD_SLOTS = S.constants.NUM_VOICES, S.constants.NUM_MOD_SLOTS
  local GRAIN_PARAM_IDS, DISCRETE_GRAIN_KEYS = S.constants.GRAIN_PARAM_IDS, S.constants.DISCRETE_GRAIN_KEYS
  local LFO_STATE = {off = 0, on = 1}
  local function registered_voice_scene_keys()
    local keys = {}
    for _, record in ipairs(S.registry.voice_params) do
      for key, default in pairs(record.scene_defaults or {}) do
        keys[key] = {default = default, range = record.discrete and record.discrete[key],
          limits = record.scene_ranges and record.scene_ranges[key]}
      end
    end
    return keys
  end
  local function sorted_keys(entries)
    local keys = {}
    for key in pairs(entries) do table.insert(keys, key) end
    table.sort(keys)
    return keys
  end

  local targets = {}
  local function add_target(param_id, target_value)
    -- number params (the LFO depths) step in whole numbers: the fade rounds
    -- to them (the end applies the scene's exact value)
    local step = params:lookup_param(param_id).t == params.tNUMBER and 1 or nil
    table.insert(targets, {id = param_id, start = params:get(param_id), target = target_value, step = step})
  end

  -- an LFO the fade stops (running now, off in the scene) fades its depth
  -- out, never toward the scene's (a setting the scene never plays), and
  -- keeps its period and offset: the end sets the scene's values with the
  -- state (#408)
  local function stops(n)
    return params:get("strata_lfo" .. n) == LFO_STATE.on and scene_data["strata_lfo" .. n] == LFO_STATE.off
  end
  for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
    if global.continuous then
      if not (global.lfo and stops(global.lfo)) then
        add_target(global.id, scene_data[global.id])
      elseif global.stop_target ~= nil then
        add_target(global.id, global.stop_target)
      end
    end
  end

  local extra_keys = registered_voice_scene_keys()
  for i = 1, NUM_VOICES do
    local voice_data = scene_data.voices[i]
    local prefix = "v" .. i .. "_"
    for key, target_value in pairs(voice_data.params) do
      add_target(prefix .. key, target_value)
    end
    for key, target_value in pairs(voice_data.grain) do
      if not DISCRETE_GRAIN_KEYS[key] then
        add_target(prefix .. GRAIN_PARAM_IDS[key], target_value)
      end
    end
    for slot = 1, NUM_MOD_SLOTS do
      local slot_data = voice_data.crossmod["slot" .. slot]
      add_target(prefix .. "mod_amp_amt_" .. slot, slot_data.amp_amt)
      add_target(prefix .. "mod_freq_amt_" .. slot, slot_data.freq_amt)
    end
    add_target(prefix .. "mod_speed", voice_data.crossmod.speed)
    -- the registered voice params that crossfade (discrete ones switch at the end)
    for _, key in ipairs(sorted_keys(voice_data.extras)) do
      if not extra_keys[key].range then add_target(prefix .. key, voice_data.extras[key]) end
    end
  end

  return targets
end

-- Raise unless actual and expected hold the same plain data (functions
-- count as equal to functions: two loads never share one)
local function assert_same(actual, expected, where)
  if type(actual) == "function" and type(expected) == "function" then return end
  if type(actual) ~= "table" or type(expected) ~= "table" then
    if actual ~= expected then
      error(string.format("%s: expected %s, got %s", where, tostring(expected), tostring(actual)), 2)
    end
    return
  end
  for key, value in pairs(expected) do assert_same(actual[key], value, where .. "." .. tostring(key)) end
  for key in pairs(actual) do
    if expected[key] == nil then error(where .. "." .. tostring(key) .. ": unexpected " .. tostring(actual[key]), 2) end
  end
end

-- Every value param's value, by id
local function param_values()
  local values = {}
  for _, param in ipairs(params.params) do
    local kind = param.t
    if param.id and (kind == params.tCONTROL or kind == params.tNUMBER or kind == params.tOPTION
        or kind == params.tBINARY) then
      values[param.id] = params:get(param.id)
    end
  end
  return values
end

-- Voice states for the equivalence test: combination c (0-23) of running
-- now x running in the scene x the scene's source (synth, buffer 2, input)
-- x the source now (the scene's, or another kind)
local RECALL_SOURCES = { 1, 3, 10 }
local function recall_combination(c)
  local kind = math.floor(c / 4) % 3
  local same = math.floor(c / 12) % 2 == 0
  return { now_active = c % 2 == 1, scene_active = math.floor(c / 2) % 2 == 1,
    scene_source = RECALL_SOURCES[kind + 1], now_source = RECALL_SOURCES[(same and kind or (kind + 1) % 3) + 1] }
end

-- A fresh load set up for run `run` of the equivalence test: scene 1
-- captured from one state, then another state; returns the context, S and
-- the captured scene data
local function prepare_recall_run(run)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function set_active(voice, active)
    if S.voices[voice].active ~= active then toggle_voice(voice) end
  end
  scramble_state(100 + run)
  params:set("reverb_mix", 0.62); params:set("filter_type", 2); params:set("strata_lfo1", 0)
  for voice = 1, 7 do
    local plan = recall_combination(((run - 1) * 7 + voice - 1) % 24)
    params:set("v" .. voice .. "_source", plan.scene_source)
    set_active(voice, plan.scene_active)
    if voice % 2 == 1 then toggle_lock(voice) end
    toggle_pattern_step(voice, voice)
  end
  capture_scene(1)
  scramble_state(200 + run)
  params:set("reverb_mix", 0.15); params:set("filter_type", 1); params:set("strata_lfo1", 1)
  for voice = 1, 7 do
    local plan = recall_combination(((run - 1) * 7 + voice - 1) % 24)
    params:set("v" .. voice .. "_source", plan.now_source)
    set_active(voice, plan.now_active)
    if voice <= 2 then toggle_lock(voice) end
    toggle_pattern_step(voice, 16 - voice)
  end
  context.clear_engine_calls()
  return context, S, S.scenes[1].data
end

test("apply_entries of scene_entries sends what today's recall sends, for every voice state and source", function()
  for run = 1, 4 do
    -- three loads from equal starting states, each recalling run 1's scene
    -- data (one table, so pairs walks it in one order)
    local outcomes, scene_data = {}, nil
    for _, way in ipairs({ "reference", "entries", "instant" }) do
      local context, S, captured = prepare_recall_run(run)
      if scene_data then
        assert_same(captured, scene_data, "run " .. run .. ": " .. way .. "'s load captured the same scene")
      else
        scene_data = captured
      end
      if way == "reference" then
        reference_recall(S, scene_data)
      elseif way == "entries" then
        S.lib.scenes.apply_entries(S.lib.scenes.scene_entries(scene_data))
      else
        recall_scene_instant(1, scene_data)
      end
      outcomes[way] = { calls = deep_copy(context.engine_calls), params = param_values(),
        voices = deep_copy(S.voices), frozen = deep_copy(S.frozen), patterns = deep_copy(S.patterns),
        in_progress = S.scene_recall_in_progress }
    end
    local reference = outcomes.reference
    assert_true(#reference.calls > 50, "run " .. run .. ": the recall sends (" .. #reference.calls .. " calls)")
    for _, way in ipairs({ "entries", "instant" }) do
      local outcome, where = outcomes[way], "run " .. run .. " (" .. way .. ")"
      assert_equal(#outcome.calls, #reference.calls, where .. ": as many engine calls")
      for index, call in ipairs(reference.calls) do
        assert_same(outcome.calls[index], call, where .. ": engine call " .. index .. " (" .. call.name .. ")")
      end
      assert_same(outcome.params, reference.params, where .. ": params")
      assert_same(outcome.voices, reference.voices, where .. ": S.voices")
      assert_same(outcome.frozen, reference.frozen, where .. ": S.frozen")
      assert_same(outcome.patterns, reference.patterns, where .. ": S.patterns")
      assert_equal(outcome.in_progress, false, where .. ": the recall flag is cleared")
    end
  end
end)

test("scene_transition_targets lists the same targets as before the rewrite", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  scramble_state(31)
  params:set("reverb_mix", 0.7)
  params:set("strata_lfo1_depth", 80); params:set("strata_lfo1_rate", 1 / 30); params:set("strata_lfo1_offset", -40)
  params:set("strata_lfo1", 0)                                    -- LFO 1 off in the scene
  params:set("strata_lfo2_depth", 60); params:set("strata_lfo2", 1)   -- LFO 2 on in both
  capture_scene(1)
  scramble_state(32)
  params:set("reverb_mix", 0.2)
  params:set("strata_lfo1_depth", 10); params:set("strata_lfo1_rate", 0.25); params:set("strata_lfo1_offset", 20)
  params:set("strata_lfo1", 1)                                    -- on now: the fade stops it
  params:set("strata_lfo2_depth", 20)
  local scene_data = S.scenes[1].data
  local expected = reference_targets(S, scene_data)
  local targets = scene_transition_targets(scene_data)
  assert_equal(#targets, #expected, "as many targets")
  for index, target in ipairs(expected) do
    local where = "target " .. index .. " (" .. target.id .. ")"
    assert_equal(targets[index].id, target.id, where .. ": id")
    assert_equal(targets[index].start, target.start, where .. ": start")
    assert_equal(targets[index].target, target.target, where .. ": target")
    assert_equal(targets[index].step, target.step, where .. ": step")
  end
  local by_id = {}
  for _, target in ipairs(targets) do by_id[target.id] = target end
  assert_near(by_id.reverb_mix.target, 0.7, 1e-9, "reverb mix fades to the scene's")
  assert_equal(by_id.strata_lfo1_depth.target, 0, "the stopped LFO's depth fades to 0")
  assert_equal(by_id.strata_lfo1_rate, nil, "and its rate holds")
  assert_equal(by_id.strata_lfo1_offset, nil, "and its offset holds")
  assert_equal(by_id.strata_lfo2_depth.target, 60, "a running LFO the scene keeps fades to the scene's depth")
  assert_equal(by_id.filter_type, nil, "a discrete global is no target")
end)

test("apply_entries with only = discrete sets no continuous param", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  scramble_state(41)
  params:set("reverb_mix", 0.7); params:set("filter_type", 3); params:set("tempo", 96)
  toggle_lock(4); toggle_voice(5)                                 -- voice 5 runs in the scene
  capture_scene(1)
  scramble_state(42)
  params:set("reverb_mix", 0.2); params:set("filter_type", 1); params:set("tempo", 130)
  toggle_lock(4); toggle_voice(5)
  local scene_data = S.scenes[1].data
  local entries = S.lib.scenes.scene_entries(scene_data)
  local before = param_values()
  S.lib.scenes.apply_entries(entries, { only = "discrete" })
  local continuous = 0
  for _, entry in ipairs(entries) do
    if entry.kind == "continuous" and before[entry.id] ~= entry.value then
      continuous = continuous + 1
      assert_equal(params:get(entry.id), before[entry.id], entry.id .. " (continuous) is not set")
    end
  end
  assert_true(continuous > 50, "the scene's continuous values differ from now's (" .. continuous .. ")")
  assert_equal(params:get("filter_type"), 3, "a discrete global is set")
  assert_equal(params:get("tempo"), 96, "tempo too")
  assert_true(S.frozen[4], "a lock is set")
  assert_true(S.voices[5].active, "a voice the scene runs is started")
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "reverb mix stays")
  -- only = continuous: the continuous values, and no discrete one
  params:set("filter_type", 1); toggle_lock(4); toggle_voice(5)
  S.lib.scenes.apply_entries(entries, { only = "continuous" })
  assert_near(params:get("reverb_mix"), 0.7, 1e-9, "only = continuous sets reverb mix")
  assert_equal(params:get("filter_type"), 1, "and no discrete global")
  assert_true(not S.frozen[4], "no lock")
  assert_true(not S.voices[5].active, "and starts no voice")
end)

-- A scene block record, registered before init (the registry closes there)
local function add_scene_block(S, record)
  S.register_scene_block(record)
end

test("a registered block is captured, migrated, validated and applied first", function()
  local order, applied = {}, {}
  local level = 7
  local data_subdir = "scene_block"
  local function register_block()
    local S = local_value("S")
    add_scene_block(S, { key = "tb", default = function() return {} end,
      capture = function() return { level = level } end,
      validate = function(value) return type(value) == "table" end,
      apply = function(value) table.insert(order, "apply"); table.insert(applied, value) end, discrete = true })
  end
  local context = load_strata({ data_subdir = data_subdir, before_init = register_block }); finish_startup(context)
  local S = local_value("S")
  capture_scene(1)
  assert_same(S.scenes[1].data.tb, { level = 7 }, "capture stores the block's capture under its key")
  local invalid = deep_copy(S.scenes[1])
  invalid.data.tb = 3
  assert_true(not validate_scene(invalid), "a block that fails its validate fails the scene")
  assert_true(validate_scene(S.scenes[1]), "the captured scene validates")
  -- a recall applies the block before the first global (master_density;
  -- norns runs its action only when the value changes)
  params:set("master_density", 0.5)
  local density_action = params:lookup_param("master_density").action
  params:set_action("master_density", function(x) table.insert(order, "master_density"); density_action(x) end)
  recall_scene(1, 0)
  assert_equal(order[1], "apply", "the block is applied first")
  assert_equal(order[2], "master_density", "then the first global")
  assert_same(applied[1], { level = 7 }, "with the scene's value")
  -- a scene written without the block gets the default on load
  S.scenes[2] = deep_copy(S.scenes[1]); S.scenes[2].data.tb = nil
  assert_true(save_scenes_to_disk(), "saved")
  assert_equal(load_scenes_from_disk(), "loaded")
  assert_same(local_value("S").scenes[2].data.tb, {}, "a scene without the block gets its default")
  assert_same(local_value("S").scenes[1].data.tb, { level = 7 }, "a scene with it keeps its value")
end)

test("a block's through_zero ramps its ids through 0 and switches once at the midpoint", function()
  local asked, switches = {}, {}
  local context = load_strata({ before_init = function()
    add_scene_block(local_value("S"), { key = "tz", default = function() return 0 end,
      capture = function() return 5 end, validate = function(value) return type(value) == "number" end,
      apply = function() end, discrete = true,
      through_zero = function(from_value, to_value)
        table.insert(asked, { from_value, to_value })
        return { { id = "reverb_mix", switch = function() table.insert(switches, params:get("reverb_mix")) end } }
      end })
  end })
  finish_startup(context)
  local S = local_value("S")
  params:set("reverb_mix", 0.8); capture_scene(1)
  S.scenes[1].data.tz = 9                                         -- the scene's value differs from the capture's
  params:set("reverb_mix", 0.4)
  recall_scene(1, 2)                                              -- 20 steps of 0.1 s; step 1 runs at once
  assert_equal(#asked, 1, "through_zero is asked once, at the start")
  assert_equal(asked[1][1], 5, "with the block's capture now")
  assert_equal(asked[1][2], 9, "and the scene's value")
  local expected = { [5] = 0.2, [9] = 0.4 * (1 - 2 * 0.45), [10] = 0, [11] = 0.8 * (2 * 0.55 - 1), [15] = 0.4 }
  for step = 1, 20 do
    if expected[step] then
      assert_near(params:get("reverb_mix"), expected[step], 1e-6, "step " .. step)
    end
    assert_equal(#switches, step >= 10 and 1 or 0, "step " .. step .. ": the switch runs once, at f = 0.5")
    if step < 20 then wake(context, "scene_transition_clock") end
  end
  assert_equal(switches[1], 0, "the switch runs once the id is at 0")
  wake(context, "scene_transition_clock")                         -- the end
  assert_equal(S.scene_transition_active, false, "the fade landed")
  assert_near(params:get("reverb_mix"), 0.8, 1e-9, "the end sets the scene's value")
  assert_equal(#switches, 1, "the switch ran once")
  -- an instant recall ignores through_zero
  params:set("reverb_mix", 0.4)
  recall_scene(1, 0)
  assert_equal(#asked, 1, "an instant recall asks nothing")
  assert_equal(#switches, 1, "and switches nothing")
  assert_near(params:get("reverb_mix"), 0.8, 1e-9, "it sets the scene's value")
end)

test("registered migrations run by before_version, then registration, before the defaults fill", function()
  local ran = {}
  load_strata({ before_init = function()
    local S = local_value("S")
    for _, record in ipairs({ { name = "m6a", before_version = 6 }, { name = "m5", before_version = 5 },
      { name = "m6b", before_version = 6 }, { name = "m3", before_version = 3 } }) do
      record.migrate = function(scene)
        table.insert(ran, record.name .. (scene.data.reverb_size == nil and " unfilled" or " filled"))
      end
      S.register_scene_migration(record)
    end
  end })
  local S = local_value("S")
  capture_scene(1)
  local scene = deep_copy(S.scenes[1]); scene.data.reverb_size = nil
  migrate_scene(scene, 4)
  assert_equal(table.concat(ran, ", "), "m5 unfilled, m6a unfilled, m6b unfilled",
    "a format 4 scene: the migrations above 4, by before_version then registration, before the fill")
  assert_near(scene.data.reverb_size, 0.8, 1e-9, "then the defaults fill")
  ran = {}
  scene = deep_copy(S.scenes[1])
  migrate_scene(scene, 5)
  assert_equal(table.concat(ran, ", "), "m6a filled, m6b filled", "a format 5 scene: those before 6")
  ran = {}
  migrate_scene(deep_copy(S.scenes[2]), 1)
  assert_equal(#ran, 0, "an empty slot is not migrated")
end)

test("a registered continuous field outside its param's range fails validation", function()
  load_strata({ before_init = function()
    local S = local_value("S")
    S.register_fx_params({ name = "probe range", count = 2, add = function()
      params:add_control("probe_level", "probe level", controlspec.new(0, 1, "lin", 0, 0.5))
      params:add_number("probe_steps", "probe steps", 1, 4, 2)
    end })
    S.register_scene_field({ id = "probe_level", default = 0.5 })
    S.register_scene_field({ id = "probe_steps", default = 2 })
  end })
  capture_scene(1)
  local good = deep_copy(local_value("scenes")[1])
  assert_true(validate_scene(good), "the captured scene validates")
  for _, case in ipairs({ { id = "probe_level", value = 1.5, valid = false }, { id = "probe_level", value = -0.1, valid = false },
    { id = "probe_level", value = 1, valid = true }, { id = "probe_level", value = 0, valid = true },
    { id = "probe_steps", value = 4.5, valid = false }, { id = "probe_steps", value = 0.5, valid = false },
    { id = "probe_steps", value = 2.5, valid = true } }) do
    local candidate = deep_copy(good)
    candidate.data[case.id] = case.value
    assert_equal(validate_scene(candidate), case.valid, case.id .. " = " .. case.value)
  end
end)

test("a field's set function replaces params:set in a recall, a transition step and apply_entries", function()
  local sets, actions = {}, 0
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    S.register_fx_params({ name = "probe set", count = 1, add = function()
      params:add_control("probe_level", "probe level", controlspec.new(0, 1, "lin", 0, 0.5))
      params:set_action("probe_level", function() actions = actions + 1 end)
    end })
    S.register_scene_field({ id = "probe_level", default = 0.5,
      set = function(value) table.insert(sets, value) end })
  end })
  finish_startup(context)
  local S = local_value("S")
  params:set("probe_level", 0.8); capture_scene(1); params:set("probe_level", 0.2)
  actions = 0
  recall_scene(1, 0)
  assert_equal(#sets, 1, "an instant recall calls the field's set once")
  assert_near(sets[1], 0.8, 1e-9, "with the scene's value")
  assert_equal(actions, 0, "and never params:set")
  assert_near(params:get("probe_level"), 0.2, 1e-9, "the param is as it was")
  sets = {}
  recall_scene(1, 2)                                              -- step 1 runs at once
  assert_equal(#sets, 1, "a fade step calls the field's set")
  assert_near(sets[1], 0.2 + (0.8 - 0.2) / 20, 1e-9, "with the step's value")
  context.clock.run_for(3, 0.001)
  assert_equal(#sets, 21, "every step, then the end")
  assert_near(sets[21], 0.8, 1e-9, "the end sets the scene's value")
  assert_equal(actions, 0, "never params:set")
  sets = {}
  S.lib.scenes.apply_entries(S.lib.scenes.scene_entries(S.scenes[1].data))
  assert_equal(#sets, 1, "apply_entries calls it once")
  assert_near(sets[1], 0.8, 1e-9, "with the scene's value")
  assert_equal(actions, 0, "never params:set")
end)

-- 3.3 (format 5 and older) named every slot "scene <i>"; from format 6 a
-- name is the player's, so only an older file's own default loads empty
test("an old default slot name loads empty, from a file older than format 6", function()
  local context = load_strata({ data_subdir = "scene_names" })
  local S = local_value("S")
  for slot = 1, S.constants.NUM_SCENES do
    assert_equal(S.scenes[slot].name, "", "slot " .. slot .. " starts with an empty name")
  end
  capture_scene(3); capture_scene(4); capture_scene(5)
  local eight = {}
  for slot = 1, 8 do eight[slot] = deep_copy(S.scenes[slot]) end
  eight[3].name, eight[4].name, eight[5].name = "scene 3", "dusk", "scene 3"
  eight[6].name = "scene 6"                                       -- an empty slot as 3.3 wrote it
  eight[7].name = nil                                             -- a slot written with no name at all
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  assert_true(S.lib.data_files.write(context.data_dir .. "strata/scenes.data", { version = 5, scenes = eight }),
    "a format 5 file written")
  context = load_strata({ data_subdir = "scene_names" })
  S = local_value("S")
  assert_true(S.scenes[3].populated, "the file loaded")
  assert_equal(S.scenes[3].name, "", "slot 3's old default name loads empty")
  assert_equal(S.scenes[4].name, "dusk", "a name of the player's stays")
  assert_equal(S.scenes[5].name, "scene 3", "another slot's default is a name of the player's")
  assert_equal(S.scenes[6].name, "", "an empty slot's old default loads empty")
  assert_equal(S.scenes[7].name, "", "a slot with no name loads named empty")
  assert_equal(S.scenes[8].name, "", "an empty slot is named empty")
  -- a format 6 file holds the player's names: "scene 3" in slot 3 stays
  S.lib.scenes.set_name(3, "scene 3")
  assert_true(save_scenes_to_disk(), "saved as format 6")
  load_strata({ data_subdir = "scene_names" })
  S = local_value("S")
  assert_equal(S.scenes[3].name, "scene 3", "a current file's name stays, whatever it reads")
end)

test("16 slots; a format 5 file loads into slots 1-8 and leaves 9-16 empty", function()
  local context = load_strata({ data_subdir = "format5_sixteen" })
  local S = local_value("S")
  assert_equal(S.constants.NUM_SCENES, 16, "sixteen slots")
  assert_equal(#S.scenes, 16, "S.scenes holds them")
  assert_equal(S.constants.SCENE_DATA_VERSION, 6, "the file format is 6")
  capture_scene(1); capture_scene(8)
  local eight = {}
  for slot = 1, 8 do eight[slot] = deep_copy(S.scenes[slot]) end
  eight[8].name = "dusk"
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  assert_true(S.lib.data_files.write(context.data_dir .. "strata/scenes.data", { version = 5, scenes = eight }),
    "a format 5 file of eight slots written")
  load_strata({ data_subdir = "format5_sixteen" })
  S = local_value("S")
  assert_equal(#S.scenes, 16, "sixteen slots after the load")
  assert_true(S.scenes[1].populated and S.scenes[8].populated, "slots 1 and 8 hold the file's scenes")
  assert_equal(S.scenes[8].name, "dusk", "with their names")
  for slot = 9, 16 do
    assert_true(S.scenes[slot].populated == false, "slot " .. slot .. " is empty")
    assert_equal(S.scenes[slot].name, "", "slot " .. slot .. " has no name")
  end
  assert_equal(S.scene_file.version, 5, "the file is known as format 5")
  capture_scene(12)
  assert_true(save_scenes_to_disk(), "saved")
  local written = S.lib.data_files.read(context.data_dir .. "strata/scenes.data")
  assert_equal(written.version, 6, "the save writes format 6")
  assert_true(written.scenes[12].populated, "with slot 12")
  assert_true(S.lib.data_files.read(context.data_dir .. "strata/scenes.data.v5") ~= nil,
    "and keeps the format 5 file as scenes.data.v5")
end)

test("validate_scene checks the name", function()
  load_strata()
  local S = local_value("S")
  capture_scene(1)
  local good = deep_copy(S.scenes[1])
  for _, case in ipairs({
    { name = string.rep("a", 13), valid = false, what = "13 characters" },
    { name = "dusk\tfall", valid = false, what = "a tab" },
    { name = "a\1", valid = false, what = "a control character" },
    { name = "caf\195\169", valid = false, what = "a letter outside ASCII" },
    { name = 5, valid = false, what = "a number" },
    { name = nil, valid = false, what = "no name" },
    { name = "", valid = true, what = "an empty name" },
    { name = "dusk", valid = true, what = "dusk" },
    { name = "~ 12 chars! ", valid = true, what = "twelve printable characters" },
  }) do
    local candidate = deep_copy(good)
    candidate.name = case.name
    assert_equal(validate_scene(candidate), case.valid, "a populated slot: " .. case.what)
    local empty = { name = case.name, populated = false, data = {} }
    assert_equal(validate_scene(empty), case.valid, "an empty slot: " .. case.what)
  end
end)

test("a capture keeps the slot's name, and set_name cuts to 12 characters", function()
  local context = load_strata({ data_subdir = "scene_set_name" })
  local S = local_value("S")
  local scenes = S.lib.scenes
  assert_true(scenes.set_name(2, "dusk"), "set_name names a slot")
  capture_scene(2)
  assert_equal(scenes.name(2), "dusk", "a capture keeps the slot's name")
  assert_true(S.scenes[2].populated, "and captures")
  local before = scenes.revision(2)
  scenes.set_name(2, "abcdefghijklmnop")
  assert_equal(scenes.name(2), "abcdefghijkl", "cut to 12 characters")
  assert_true(scenes.revision(2) > before, "a name raises the slot's revision")
  scenes.set_name(3, "a\tb\1c\195\169d")
  assert_equal(scenes.name(3), "abcd", "printable ASCII only")
  assert_true(validate_scene(S.scenes[3]), "so the slot validates")
  assert_equal(scenes.set_name(0, "x"), false, "slot 0 is no slot")
  assert_equal(scenes.set_name(S.constants.NUM_SCENES + 1, "x"), false, "nor is slot 17")
  assert_equal(scenes.set_name(4, 7), false, "a name is a string")
  assert_equal(scenes.name(4), "", "and slot 4 keeps its name")
  -- a name is written at once, as a save is
  load_strata({ data_subdir = "scene_set_name" })
  assert_equal(local_value("S").lib.scenes.name(2), "abcdefghijkl", "the name is on disk")
  assert_equal(local_value("S").lib.scenes.name(3), "abcd", "an empty slot's name too")
  assert_true(context ~= nil, "loaded")
end)

test("bank_of and name", function()
  load_strata()
  local scenes = local_value("S").lib.scenes
  assert_equal(scenes.bank_of(1), 1, "slot 1 is bank 1")
  assert_equal(scenes.bank_of(8), 1, "slot 8 is bank 1")
  assert_equal(scenes.bank_of(9), 2, "slot 9 is bank 2")
  assert_equal(scenes.bank_of(16), 2, "slot 16 is bank 2")
  assert_equal(scenes.bank_of(0), nil, "slot 0 is in no bank")
  assert_equal(scenes.bank_of(17), nil, "nor is slot 17")
  assert_equal(scenes.bank_of(2.5), nil, "nor a fraction")
  assert_equal(scenes.name(3), "", "a slot starts with no name")
  scenes.set_name(3, "dusk")
  assert_equal(scenes.name(3), "dusk", "name(3) after set_name(3, \"dusk\")")
  assert_equal(scenes.name(17), "", "a number that is no slot has no name")
end)

-- design §9.3: names show in flashes (S3 dusk)
test("label is S<n> with the slot's name when it has one", function()
  load_strata()
  local scenes = local_value("S").lib.scenes
  assert_equal(scenes.label(3), "S3", "a slot with no name: S3")
  scenes.set_name(3, "dusk")
  assert_equal(scenes.label(3), "S3 dusk", "a named slot: S3 dusk")
  scenes.set_name(16, "nightfall in rain")
  assert_equal(scenes.label(16), "S16 nightfall in", "the name as stored, cut to 12")
  assert_equal(scenes.label(17), "S17", "a slot out of range: S and the number")
  assert_equal(scenes.label(0), "S0", "slot 0 too")
  assert_equal(scenes.label(2.5), "S2.5", "and a fraction, never an error")
end)

test("the save and empty-slot flashes name the slot", function()
  local context = load_strata({ data_subdir = "scene_label_flashes" }); finish_startup(context)
  local S = local_value("S")
  S.lib.scenes.set_name(3, "dusk")
  recall_scene(3, 0)
  assert_equal(S.lib.ui_flash.text("header"), "S3 dusk empty", "an empty named slot's recall")
  S.lib.ui_flash.start("header", nil)
  recall_scene(4, 0)
  assert_equal(S.lib.ui_flash.text("header"), "S4 empty", "an empty slot with no name")
  S.lib.scenes.save(3)
  assert_equal(S.lib.ui_flash.text("header"), "saved S3 dusk", "a named slot's save")
  S.lib.scenes.save(5)
  assert_equal(S.lib.ui_flash.text("header"), "saved S5", "a slot with no name")
  S.scene_autosave_blocked = true
  S.lib.scenes.save(3)
  assert_equal(S.lib.ui_flash.text("header"), "S3 dusk not on disk", "a save that could not be written")
  S.scene_autosave_blocked = false
end)

test("the scene sequencer runs over up to 16 scenes", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("scene_sequence_length", 20)
  assert_equal(params:get("scene_sequence_length"), 16, "the length goes up to 16")
  capture_scene(9); capture_scene(16)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(1, 0.001)
  assert_equal(S.current_scene, 9, "the empty slots 1-8 are skipped: scene 9 first")
  assert_equal(S.lib.scenes.sequencer_next_slot(), 16, "scene 16 is next")
  context.clock.run_for(4, 0.001)
  assert_equal(S.current_scene, 16, "then scene 16")
  context.clock.run_for(4, 0.001)
  assert_equal(S.current_scene, 9, "then back to scene 9")
  params:set("scene_sequencer_enabled", 0)
end)

test("revision rises on a capture and on a load", function()
  local context = load_strata({ data_subdir = "scene_revisions" })
  local S = local_value("S")
  local scenes = S.lib.scenes
  for slot = 1, S.constants.NUM_SCENES do assert_equal(scenes.revision(slot), 0, "slot " .. slot .. " starts at 0") end
  capture_scene(1)
  local first = scenes.revision(1)
  assert_true(first > 0, "a capture raises its slot's revision")
  capture_scene(1)
  assert_true(scenes.revision(1) > first, "each capture does")
  assert_equal(scenes.revision(2), 0, "another slot's stays")
  assert_equal(scenes.revision(S.constants.NUM_SCENES + 1), 0, "a slot outside 1..NUM_SCENES is 0")
  capture_scene(S.constants.NUM_SCENES + 1)
  assert_equal(scenes.revision(S.constants.NUM_SCENES + 1), 0, "and a capture there changes nothing")
  local before = {}
  for slot = 1, S.constants.NUM_SCENES do before[slot] = scenes.revision(slot) end
  assert_equal(load_scenes_from_disk(), "missing")
  for slot = 1, S.constants.NUM_SCENES do
    assert_equal(scenes.revision(slot), before[slot], "slot " .. slot .. ": a load that finds no file changes nothing")
  end
  assert_true(save_scenes_to_disk(), "saved")
  assert_equal(load_scenes_from_disk(), "loaded")
  for slot = 1, S.constants.NUM_SCENES do
    assert_true(scenes.revision(slot) > before[slot], "slot " .. slot .. ": a load raises its revision")
  end
end)

test("a recall's lock states run the lock hooks for the voices whose lock changed", function()
  local calls = {}
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    S.register_lock_change(function(voice_idx, locked)
      table.insert(calls, voice_idx .. (locked and " locked" or " unlocked")
        .. (local_value("S").frozen[voice_idx] == locked and "" or " (before the state)"))
    end)
  end })
  finish_startup(context)
  toggle_lock(2); toggle_lock(5); capture_scene(1)                -- the scene locks 2 and 5
  toggle_lock(2); toggle_lock(3)                                  -- now 3 and 5
  calls = {}
  recall_scene(1, 0)
  assert_equal(table.concat(calls, ", "), "2 locked, 3 unlocked", "an instant recall: the voices whose lock changed")
  toggle_lock(2); toggle_lock(3)
  calls = {}
  recall_scene(1, 2)
  assert_equal(#calls, 0, "a fade sets no lock before its end")
  context.clock.run_for(3, 0.001)
  assert_equal(table.concat(calls, ", "), "2 locked, 3 unlocked", "its end runs them")
end)

-- 0b's review findings
test("apply_entries refuses an unknown only value", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("reverb_mix", 0.7); params:set("filter_type", 3); toggle_lock(4)
  capture_scene(1)
  params:set("reverb_mix", 0.2); params:set("filter_type", 1); toggle_lock(4)
  local entries = S.lib.scenes.scene_entries(S.scenes[1].data)
  context.clear_engine_calls()
  for _, only in ipairs({ "block", "discret" }) do
    local ok, problem = pcall(S.lib.scenes.apply_entries, entries, { only = only })
    assert_true(not ok, "only = " .. only .. " raises")
    assert_true(tostring(problem):find(only, 1, true) ~= nil, "the error names the value: " .. tostring(problem))
  end
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "no continuous value is applied")
  assert_equal(params:get("filter_type"), 1, "no discrete one")
  assert_true(not S.frozen[4], "no lock")
  assert_equal(#context.engine_calls, 0, "nothing reaches the engine")
  assert_equal(S.scene_recall_in_progress, false, "the recall flag is never left set")
end)

test("per-voice param entries carry their voice and global ones do not", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  capture_scene(1)
  local globals = {}
  for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do globals[global.id] = true end
  local per_voice, global_count = {}, 0
  for _, entry in ipairs(S.lib.scenes.scene_entries(S.scenes[1].data)) do
    if entry.id and globals[entry.id] then
      global_count = global_count + 1
      assert_equal(entry.voice, nil, entry.id .. " (global) has no voice")
    elseif entry.id then
      local voice = tonumber(entry.id:match("^v(%d)_"))
      assert_equal(entry.voice, voice, entry.id .. " carries its voice")
      per_voice[voice] = (per_voice[voice] or 0) + 1
    end
  end
  assert_equal(global_count, #S.SCENE_GLOBAL_PARAMS, "every global is listed")
  for voice = 1, 7 do assert_true((per_voice[voice] or 0) > 10, "voice " .. voice .. "'s params are listed") end
end)

test("a global entry whose id starts with v1_ is not treated as voice 1's", function()
  local running_at_set = {}
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    S.register_fx_params({ name = "probe v1 global", count = 1, add = function()
      params:add_control("v1_probe", "v1 probe", controlspec.new(0, 1, "lin", 0, 0))
      params:set_action("v1_probe", function() table.insert(running_at_set, local_value("S").voices[1].active) end)
    end })
  end })
  finish_startup(context)                                         -- voices 1 and 2 running
  local S = local_value("S")
  toggle_voice(1)                                                 -- voice 1 stopped
  -- voice 1's active entry, then a global entry: voice 1 starts after its
  -- own last entry, before the global is set
  S.lib.scenes.apply_entries({
    { kind = "discrete", key = "active", voice = 1, value = true },
    { kind = "continuous", id = "v1_probe", value = 0.6 },
  })
  assert_equal(#running_at_set, 1, "the global is set")
  assert_equal(running_at_set[1], true, "voice 1 was started before it: the global is not voice 1's entry")
  assert_true(S.voices[1].active, "voice 1 runs")
end)

test("a block's apply cannot change the saved scene", function()
  local received = {}
  local context = load_strata({ before_init = function()
    add_scene_block(local_value("S"), { key = "tb", default = function() return {} end,
      capture = function() return { level = 7, inner = { depth = 3 } } end,
      validate = function(value) return type(value) == "table" end,
      apply = function(value)
        table.insert(received, value.level)
        value.level, value.added, value.inner.depth = 99, true, 0
      end, discrete = true })
  end })
  finish_startup(context)
  local S = local_value("S")
  capture_scene(1)
  recall_scene(1, 0)
  assert_equal(received[1], 7, "apply gets the scene's value")
  assert_same(S.scenes[1].data.tb, { level = 7, inner = { depth = 3 } }, "an instant recall leaves the slot's data as it was")
  recall_scene(1, 2)
  context.clock.run_for(3, 0.001)
  assert_equal(#received, 2, "a fade's end applies it too")
  assert_equal(received[2], 7, "with the scene's value")
  assert_same(S.scenes[1].data.tb, { level = 7, inner = { depth = 3 } }, "and leaves the slot's data as it was")
end)

-- #584: morph tells a recall that came after a move by this count, even a
-- second recall of the scene already current
test("takeovers counts every recall and every transition started", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local scenes = S.lib.scenes
  local count = scenes.takeovers()
  assert_equal(count, 0, "none at load")
  capture_scene(2)
  assert_equal(scenes.takeovers(), count, "a capture takes nothing over")
  recall_scene(2, 0)
  assert_equal(scenes.takeovers(), count + 1, "an instant recall counts")
  recall_scene(2, 0)
  assert_equal(scenes.takeovers(), count + 2, "a second recall of the current scene too")
  recall_scene(2, 2)
  assert_equal(scenes.takeovers(), count + 3, "a transition counts at its start")
  context.clock.run_for(2.5)
  assert_true(not S.scene_transition_active, "the transition landed")
  assert_equal(scenes.takeovers(), count + 3, "its landing is no second takeover")
  recall_scene(5, 0)
  assert_equal(scenes.takeovers(), count + 3, "an empty slot's recall takes nothing over")
  capture_scene(6); S.scenes[6].data.tempo = "fast"
  recall_scene(6, 0)
  assert_equal(scenes.takeovers(), count + 3, "nor an invalid scene's")
end)

end

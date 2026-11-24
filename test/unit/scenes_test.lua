-- test/unit/scenes_test.lua
-- Scenes: capture, recall, transitions, the scene sequencer, the fill,
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
  local locked = local_value("locked")
  local patterns = local_value("patterns")
  for voice_idx = 1, local_value("S").constants.NUM_VOICES do
    assert_voice_matches(voice_idx, voices[voice_idx], captured.voices[voice_idx])
    assert_equal(locked[voice_idx], captured.locked[voice_idx], "voice " .. voice_idx .. " locked")
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
      local source = captured.voices[3].values["mod_source_" .. call.args[2]]
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
  rejects(function(data) data.voices[2].values = nil end, "missing values")
  rejects(function(data) data.voices[2].values.mod_source_2 = nil end, "missing mod source")
  rejects(function(data) data.voices[2].values.mod_source_1 = 9 end, "out-of-range mod source")
  rejects(function(data) data.voices[2].values.mod_source_1 = 2.5 end, "fractional mod source")
  -- recall would send engine.setModSpeed with nil
  rejects(function(data) data.voices[4].values.mod_speed = nil end, "missing mod speed")
  rejects(function(data) data.voices[4].values.mod_speed = "fast" end, "non-numeric mod speed")
  rejects(function(data) data.voices[1].values.bogus = 1 end, "unknown voice param")
  rejects(function(data) data.voices[1].values.grain_size = "big" end, "non-numeric grain param")
  rejects(function(data, all) all[1].populated = "yes" end, "non-boolean populated")
  assert_true(not validate_scene_data("nope"), "should reject a non-table")
  assert_true(not validate_scene_data({ [3] = 7 }), "should reject a non-table slot")
end)

-- The groundwork before 3.8 (design §1): the lock is a scene's field locked
test("a captured scene stores the lock as locked", function()
  load_strata()
  toggle_lock(3)
  capture_scene(1)
  local S = local_value("S")
  assert_equal(S.scenes[1].data.locked[3], true, "voice 3's lock is captured")
  assert_equal(S.scenes[1].data.locked[1], false, "an unlocked voice is false")
  assert_equal(S.scenes[1].data.frozen, nil, "no field frozen")
end)

test("a scene without locked is refused", function()
  load_strata()
  capture_scene(1)
  local S = local_value("S")
  local good = deep_copy(S.scenes[1])
  assert_true(validate_scene(good), "a captured scene is valid")
  local missing = deep_copy(good); missing.data.locked = nil
  assert_true(not validate_scene(missing), "no locked")
  local short = deep_copy(good); short.data.locked[3] = nil
  assert_true(not validate_scene(short), "a voice's lock missing")
  local old = deep_copy(good); old.data.frozen = old.data.locked; old.data.locked = nil
  assert_true(not validate_scene(old), "a scene holding only frozen")
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
  assert_near(scenes[4].data.voices[1].values.freq, saved.voices[1].values.freq, 1e-9, "scene 4 data")
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

  -- a file with only some slots loads, missing slots filled
  local some = { [1] = { name = "", populated = false, data = {} } }
  some[2] = { name = "", populated = true, data = saved }
  context.tab.save({ version = local_value("SCENE_DATA_VERSION"), scenes = some }, file_path)
  context = load_strata({ data_subdir = "roundtrip" })
  scenes = local_value("scenes")
  assert_true(scenes[2].populated, "scene 2 loaded")
  assert_equal(#scenes, local_value("NUM_SCENES"), "every slot exists")
  for slot = 3, local_value("NUM_SCENES") do
    assert_true(scenes[slot] and scenes[slot].populated == false, "filled slot " .. slot)
    assert_equal(scenes[slot].name, "", "filled slot " .. slot .. " has no name")
  end
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
  scenes[2].data.locked = nil
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  local bad_slot_path = context.data_dir .. "bad_slot.data"
  context.tab.save({ version = local_value("SCENE_DATA_VERSION"), scenes = scenes }, bad_slot_path)
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
    scenes[1].data.voices[1].values.freq = case.value
    local subdir = "nonfinite_" .. index
    local dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. dir .. "'")
    local text = tabutil_text({ version = local_value("SCENE_DATA_VERSION"), scenes = scenes })
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

test("release_voice lets go of a voice only while a fade runs", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("v2_grain_size", 0.1); params:set("v3_grain_size", 0.1); capture_scene(1)
  params:set("v2_grain_size", 0.4); params:set("v3_grain_size", 0.4); capture_scene(2)
  recall_scene(1, 0)
  assert_equal(S.lib.scenes.release_voice(2), false, "no fade: nothing to let go of")
  assert_equal(S.SCENE_TRANSITION.released, nil, "no released set without a fade")
  recall_scene(2, 2)
  assert_equal(S.lib.scenes.release_voice(0), false, "no voice 0")
  assert_equal(S.lib.scenes.release_voice(2), true, "voice 2 let go")
  local held = params:get("v2_grain_size")
  context.clock.run_for(3)
  assert_equal(params:get("v2_grain_size"), held, "no step or the landing moved voice 2")
  assert_near(params:get("v3_grain_size"), 0.4, 1e-9, "voice 3 landed on scene 2")
  assert_equal(S.SCENE_TRANSITION.released, nil, "the set ends with the fade")
  assert_equal(S.current_scene, 2, "scene 2 current")
end)

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

-- The fade's stop goes straight to the clock helper (#962 fixed there): a
-- fade whose clock was lost past its next wake (its wake may look posted)
-- is canceled and superseded without a retired or bare clock left behind
test("a fade whose clock has gone stops through the clock helper with no broken invariant (#962)", function()
  for _, way in ipairs({ "canceled", "superseded" }) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    capture_freq_scenes()
    recall_scene(1, 0); recall_scene(2, 4)
    local id = local_value("scene_transition_clock")
    assert_true(type(id) == "number", way .. ": the fade's clock runs")
    clock.cancel(id)                                               -- its clock is lost
    context.clock.run_for(0.5, 0.001)                              -- past the wake it waited for
    if way == "canceled" then cancel_scene_transition() else recall_scene(3, 0) end
    assert_equal(S.scene_transition_active, false, way .. ": the fade has ended")
    assert_equal(S.lib.clocks.retired[id], nil, way .. ": the gone clock is not retired")
    assert_equal(S.lib.clocks.bare[id], nil, way .. ": nor marked bare")
    assert_equal(table.concat(h.check_invariants(), "; "), "", way .. ": every invariant holds")
  end
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

-- 3.9 (#867): a hand edit during a fade is a hand edit: the loop length's
-- filter (lib/loops.lua) stands down only while a recall's apply or a fade
-- step sets the pair (S.lib.scenes.setting()), never for the whole fade.
-- The hand set is voice 2's start 0.5, then its length 1
local function fade_scenes()
  params:set("reverb_mix", 0.6); capture_scene(2)
  params:set("reverb_mix", 0.2); capture_scene(1)
  recall_scene(1, 0)
end

local function assert_cut_length(what)
  assert_near(params:get("v2_loop_start"), 0.5, 1e-9, what .. ": the start set by hand")
  assert_near(params:get("v2_loop_length"), 0.5, 1e-9, what .. ": the length cut to 1 - start")
end

-- 3.9 (#948; 1d began it with the hand edit's and the cancel's rows, 2c
-- completes it): the table of the scene fade. Scene 1 (current) holds
-- reverb 0.2 and voice 2's pan -0.5, scene 2 reverb 0.6, pan 0.5 and
-- matrix routing 1 from LFO 1 to the delay mix (scene 1's and 3's have
-- none: a fade from 1 to 2 ramps the routing's depth through 0 and
-- switches the routing at its midpoint), scene 3 reverb 0.9 and pan 0.8.
-- A fade takes 4 s, 20 steps of 0.2 s; before the midpoint is step 9 of
-- the fade to scene 2, after it step 12
local FADE_TABLE = {seconds = 4, before_step = 9, after_step = 12}

local function fade_table_scenes()
  local S = local_value("S")
  params:set("v2_pan", 0.5); params:set("reverb_mix", 0.6)
  S.lib.matrix.set_routing(1, "lfo1", "delay_mix"); capture_scene(2)
  S.lib.matrix.set_routing(1, "", "")
  params:set("v2_pan", 0.8); params:set("reverb_mix", 0.9); capture_scene(3)
  params:set("v2_pan", -0.5); params:set("reverb_mix", 0.2); capture_scene(1)
  recall_scene(1, 0)
end

-- The fade to scene 2, run to the step given
local function fade_to_step(context, step)
  fade_table_scenes()
  recall_scene(2, FADE_TABLE.seconds)
  for _ = 2, step do wake(context, "scene_transition_clock") end
end

-- The state the script is in: fading (before or after the midpoint, by
-- the step applied last), landing (no fade, and a scene setting: inside
-- the landing's recall_scene_instant), else idle
local function fade_state()
  local S = local_value("S")
  if S.scene_transition_active then
    local transition = S.SCENE_TRANSITION
    return transition.step * 2 >= transition.steps and "fading, after it" or "fading, before the midpoint"
  end
  if S.lib.scenes.setting() then return "landing" end
  return "idle"
end

-- Every row's check: the current scene, the fade flag, the clock (a live
-- coroutine exactly while a fade runs) and the recall flag put back (no
-- scene sets after the event)
local function assert_fade(current, fading, what)
  local S = local_value("S")
  assert_equal(S.current_scene, current, what .. ": the current scene")
  assert_equal(S.scene_transition_active, fading, what .. ": the fade flag")
  if fading then
    local thread = clock.threads[S.scene_transition_clock]
    assert_true(type(thread) == "thread" and coroutine.status(thread) ~= "dead", what .. ": the fade's clock runs")
  else
    assert_equal(S.scene_transition_clock, nil, what .. ": no fade clock")
  end
  assert_equal(S.lib.scenes.setting(), false, what .. ": no scene is setting (the recall flag is back)")
end

-- A new fade to scene 3 from scene 1 (the last that landed), at its first
-- step; the clock of the fade it superseded no longer runs
local function assert_superseded(context, what)
  local S = local_value("S")
  assert_fade(3, true, what)
  assert_equal(S.SCENE_TRANSITION.target, 3, what .. ": the fade goes to scene 3")
  assert_equal(S.SCENE_TRANSITION.previous, 1, what .. ": from scene 1, the last that landed")
  assert_equal(S.SCENE_TRANSITION.step, 1, what .. ": at its first step")
  local old = context.fade_clock
  assert_true(old ~= S.scene_transition_clock and (clock.threads[old] == nil or S.lib.clocks.retired[old] ~= nil),
    what .. ": the old fade's clock was stopped")
end

local function routing_source() return local_value("S").lib.matrix.routing(1).source end

local function run_to_end(context)
  while local_value("S").scene_transition_active do wake(context, "scene_transition_clock") end
end

-- A fade that ended keeps no clock: one stopped as its wake was posted is
-- retired, and its wake runs no step and no end (the clock helper; "the
-- fade's clock stopped as its wake is posted", below)
local IDLE_WAKE_IMPOSSIBLE = "no fade's clock wakes while idle: a clock a recall or a cancel retired"
  .. " ends at its wake and runs no step and no end"

local LANDING_IMPOSSIBLE = "the landing runs inside one resume of the fade's clock and never yields: only its own sets run"
  .. " inside it, and none of them recalls, steps, ends or cancels a fade, lets go of a voice, captures, edits by hand"
  .. " or moves the morph (the end's row reads the state from inside it)"

h.transition_table({
  name = "scene fade",
  states = {
    idle = function() fade_table_scenes() end,
    ["fading, before the midpoint"] = function(context)
      fade_to_step(context, FADE_TABLE.before_step)
      context.fade_clock = local_value("S").scene_transition_clock
    end,
    ["fading, after it"] = function(context)
      fade_to_step(context, FADE_TABLE.after_step)
      context.fade_clock = local_value("S").scene_transition_clock
    end,
    -- never entered from outside: every cell of it is impossible
    landing = function() error("the landing is entered only from inside the fade's clock") end,
  },
  events = {
    ["recall, timed"] = function() recall_scene(3, FADE_TABLE.seconds) end,
    ["recall, instant"] = function() recall_scene(3, 0) end,
    step = function(context) wake(context, "scene_transition_clock") end,
    -- the steps left, then the end; the state read from inside the landing,
    -- as it applies the matrix's block (the scene's discrete part)
    ["end"] = function(context)
      local record
      for _, block in ipairs(local_value("S").registry.scene_blocks) do
        if block.key == "matrix" then record = block end
      end
      local real_apply = record.apply
      record.apply = function(value)
        if not local_value("S").scene_transition_active then
          context.landing = {state = fade_state(), current = local_value("S").current_scene}
        end
        return real_apply(value)
      end
      local ran, run_error = pcall(run_to_end, context)
      record.apply = real_apply
      if not ran then error(run_error, 0) end
    end,
    cancel = function() cancel_scene_transition() end,
    release_voice = function(context) context.released = local_value("S").lib.scenes.release_voice(2) end,
    ["capture into the target"] = function() capture_scene(2) end,
    ["hand set"] = function() params:set("v2_loop_start", 0.5); params:set("v2_loop_length", 1) end,
    ["morph move"] = function(context) params:set("morph", 0.5); context.clock.run_for(0.05) end,
  },
  state_of = fade_state,
  rows = {
    {"idle", "recall, timed", "fading, before the midpoint", check = function()
      local S = local_value("S")
      assert_fade(3, true, "a fade from idle")
      assert_equal(S.SCENE_TRANSITION.previous, 1, "from the current scene")
      assert_equal(S.SCENE_TRANSITION.step, 1, "its first step ran inside the recall")
    end},
    {"idle", "recall, instant", "idle", check = function()
      assert_fade(3, false, "an instant recall")
      assert_near(params:get("reverb_mix"), 0.9, 1e-9, "scene 3's reverb")
    end},
    {"idle", "cancel", "idle", check = function() assert_fade(1, false, "a cancel with no fade") end},
    {"idle", "release_voice", "idle", check = function(context)
      assert_equal(context.released, false, "no fade lets go of the voice")
      assert_fade(1, false, "release_voice with no fade")
    end},
    {"idle", "capture into the target", "idle", check = function()
      assert_fade(1, false, "a capture")
      assert_near(local_value("S").scenes[2].data.reverb_mix, 0.2, 1e-9, "scene 2 holds the sound now")
    end},
    {"idle", "hand set", "idle", check = function()
      assert_cut_length("idle")
      assert_fade(1, false, "a hand set")
    end},
    {"idle", "morph move", "idle", check = function() assert_fade(0, false, "a morph move") end},

    {"fading, before the midpoint", "recall, timed", "fading, before the midpoint", check = function(context)
      assert_superseded(context, "a fade superseding one before its midpoint")
      assert_equal(routing_source(), "", "the superseded fade switched no routing")
    end},
    {"fading, before the midpoint", "recall, instant", "idle", check = function()
      assert_fade(3, false, "an instant recall during a fade")
      assert_near(params:get("reverb_mix"), 0.9, 1e-9, "scene 3's reverb")
    end},
    {"fading, before the midpoint", "step", "fading, after it", check = function()
      assert_fade(2, true, "the step to the midpoint")
      assert_equal(local_value("S").SCENE_TRANSITION.step, FADE_TABLE.before_step + 1, "one step")
      assert_equal(routing_source(), "lfo1", "the midpoint's step switched the routing through 0")
    end},
    {"fading, before the midpoint", "cancel", "idle", check = function()
      assert_fade(1, false, "a cancel before the midpoint")
      assert_equal(routing_source(), "", "no routing was switched")
    end},
    {"fading, before the midpoint", "release_voice", "fading, before the midpoint", check = function(context)
      assert_equal(context.released, true, "the fade lets go of voice 2")
      assert_fade(2, true, "release_voice during a fade")
      local pan = params:get("v2_pan")
      wake(context, "scene_transition_clock")
      assert_near(params:get("v2_pan"), pan, 1e-9, "no later step moves voice 2")
    end},
    {"fading, before the midpoint", "capture into the target", "fading, before the midpoint", check = function(context)
      local S = local_value("S")
      assert_fade(2, true, "a capture into the fade's target")
      local captured = S.scenes[2].data.reverb_mix
      run_to_end(context)
      assert_fade(2, false, "the fade landed")
      assert_near(params:get("reverb_mix"), 0.6, 1e-9, "on the scene as it was recalled")
      assert_true(math.abs(captured - 0.6) > 0.01, "not on the capture's " .. captured)
    end},
    {"fading, before the midpoint", "hand set", "fading, before the midpoint", check = function()
      local S = local_value("S")
      assert_cut_length("fading")
      assert_fade(2, true, "a hand set during a fade")
      cancel_scene_transition()
      assert_cut_length("after a cancel")
      -- a capture of a pair set during a fade validates only if it fits
      capture_scene(3)
      local values = S.scenes[3].data.voices[2].values
      assert_true(validate_scene(S.scenes[3]), "the capture validates")
      assert_true(values.loop_start + values.loop_length <= 1 + S.lib.loops.LOOP.tolerance,
        "and its pair fits: " .. values.loop_start .. " + " .. values.loop_length)
    end},
    {"fading, before the midpoint", "morph move", "idle", check = function()
      assert_fade(0, false, "a morph move during a fade")
    end},

    {"fading, after it", "recall, timed", "fading, before the midpoint", check = function(context)
      assert_superseded(context, "a fade superseding one after its midpoint")
      assert_equal(routing_source(), "lfo1", "the switch the superseded fade ran stays")
    end},
    {"fading, after it", "recall, instant", "idle", check = function()
      assert_fade(3, false, "an instant recall after the midpoint")
      assert_equal(routing_source(), "", "scene 3's routings")
    end},
    {"fading, after it", "step", "fading, after it", check = function()
      assert_fade(2, true, "a step after the midpoint")
      assert_equal(local_value("S").SCENE_TRANSITION.step, FADE_TABLE.after_step + 1, "one step")
    end},
    {"fading, after it", "end", "idle", check = function(context)
      assert_fade(2, false, "the landing")
      assert_true(context.landing ~= nil, "the landing applied the matrix's block")
      assert_equal(context.landing.state, "landing", "read from inside the landing")
      assert_equal(context.landing.current, 2, "with its target current while it applies it")
      assert_near(params:get("reverb_mix"), 0.6, 1e-9, "the scene's exact reverb")
      assert_near(params:get("v2_pan"), 0.5, 1e-9, "and voice 2's pan")
    end},
    {"fading, after it", "cancel", "idle", check = function()
      assert_fade(1, false, "a cancel after the midpoint")
      assert_equal(routing_source(), "lfo1", "the routing the midpoint switched stays")
    end},
    {"fading, after it", "release_voice", "fading, after it", check = function(context)
      assert_equal(context.released, true, "the fade lets go of voice 2")
      local pan = params:get("v2_pan")
      run_to_end(context)
      assert_fade(2, false, "the fade landed")
      assert_near(params:get("v2_pan"), pan, 1e-9, "without voice 2")
      assert_near(params:get("reverb_mix"), 0.6, 1e-9, "and with the rest")
    end},
    {"fading, after it", "capture into the target", "fading, after it", check = function(context)
      run_to_end(context)
      assert_fade(2, false, "the fade landed")
      assert_near(params:get("reverb_mix"), 0.6, 1e-9, "on the scene as it was recalled")
    end},
    {"fading, after it", "hand set", "fading, after it", check = function()
      assert_cut_length("after the midpoint")
      assert_fade(2, true, "a hand set after the midpoint")
    end},
    {"fading, after it", "morph move", "idle", check = function()
      assert_fade(0, false, "a morph move after the midpoint")
    end},
  },
  impossible = {
    {"idle", "step", IDLE_WAKE_IMPOSSIBLE},
    {"idle", "end", IDLE_WAKE_IMPOSSIBLE},
    {"fading, before the midpoint", "end", "the end follows the twentieth step: a fade before its midpoint steps first"},
    {"landing", "recall, timed", LANDING_IMPOSSIBLE},
    {"landing", "recall, instant", LANDING_IMPOSSIBLE},
    {"landing", "step", LANDING_IMPOSSIBLE},
    {"landing", "end", LANDING_IMPOSSIBLE},
    {"landing", "cancel", LANDING_IMPOSSIBLE},
    {"landing", "release_voice", LANDING_IMPOSSIBLE},
    {"landing", "capture into the target", LANDING_IMPOSSIBLE},
    {"landing", "hand set", LANDING_IMPOSSIBLE},
    {"landing", "morph move", LANDING_IMPOSSIBLE},
  },
  notes = {"docs/notes/lua/scenes/transitions.md", "scene fade"},
})

-- 3.9 (#870): the fade's clock and the scene sequencer's run on the clock
-- helper (lib/clocks.lua): a stop as matron posts the clock's wake retires
-- it, and the wake ends it without an error and without running a step
test("the fade's clock stopped as its wake is posted: no clock error, and nothing more happens", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  fade_scenes()
  recall_scene(2, 2)                                   -- a 2 s fade: steps 0.1 s apart
  local id = S.scene_transition_clock
  context.clock.advance_until(id, function() recall_scene(1, 0) end)  -- a recall supersedes it
  context.clock.run_for(0.5)
  local errors = context.clock.take_errors()
  assert_equal(#errors, 0, "no resume reaches a canceled clock" .. (errors[1] and (": " .. errors[1]) or ""))
  assert_true(not S.scene_transition_active, "no fade runs")
  assert_equal(S.current_scene, 1, "the instant recall's scene is current")
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "and no step of the old fade ran after it")
  assert_equal(S.lib.clocks.retired[id], nil, "the retired clock ended at its wake")
end)

test("the scene sequencer's clock stopped as its wake is posted: no clock error, and nothing more happens", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  fade_scenes()
  params:set("scene_sequence_length", 2)
  params:set("scene_duration", 4)
  params:set("scene_transition_time", 0)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(1)
  local id = S.scene_sequencer_clock
  assert_true(id ~= nil, "the sequencer runs")
  assert_equal(S.current_scene, 1, "it recalled scene 1")
  local position = S.scene_sequencer_position
  context.clock.advance_until(id, function() params:set("scene_sequencer_enabled", 0) end)
  context.clock.run_for(5)
  local errors = context.clock.take_errors()
  assert_equal(#errors, 0, "no resume reaches a canceled clock" .. (errors[1] and (": " .. errors[1]) or ""))
  assert_equal(S.current_scene, 1, "scene 2 was never recalled")
  assert_equal(S.scene_sequencer_position, position, "the pass did not advance after its hold")
  assert_equal(S.scene_sequencer_recall_due, false, "and marked no recall due")
  assert_equal(S.scene_sequencer_clock, nil, "no sequencer clock")
  assert_equal(S.lib.clocks.retired[id], nil, "the retired clock ended at its wake")
end)

-- 3.9 (#867): a hand-moved FX fader during a fade is drawn at once, not at
-- the fade's next step (lib/params_setup.lua, lib/delay_sync.lua)
test("a hand-moved FX fader during a fade redraws the grid at once", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  fade_scenes()
  recall_scene(2, 4); context.clock.run_for(0.3)
  assert_true(S.scene_transition_active, "a fade runs")
  S.lib.grid_core.any_fx_faders = function() return true end  -- a pane shows the FX page
  local real_redraw, redraws = grid_redraw, 0
  grid_redraw = function(...) redraws = redraws + 1; return real_redraw(...) end
  params:set("filter_freq", 1000)
  local after_filter = redraws
  params:set("delay_division", 2)
  grid_redraw = real_redraw
  assert_true(after_filter > 0, "the filter's fader is drawn at once")
  assert_true(redraws > after_filter, "and the delay division's")
  cancel_scene_transition()
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
  -- its settle wait wakes every 0.01 s, inside the clock helper's margin:
  -- the stop retires it, and it ends at that wake (3.9, #870)
  assert_true(local_value("S").lib.clocks.retired[waiting_clock] ~= nil, "stopping retires the waiting clock")
  context.clock.run_for(1, 0.001)
  assert_true(context.clock.threads[waiting_clock] == nil, "which ends at its wake")
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
    for voice_idx = 1, local_value("S").constants.NUM_VOICES do
      local voice = voices[voice_idx]
      if voice.active then
        local label = where .. ": voice " .. voice_idx .. " "
        local sent = engine_state_for_voice(context.engine_calls, voice_idx - 1)
        for _, key in ipairs(voice.param_order) do
          assert_near(sent.voice[key], voice.values[key], 1e-9, label .. key)
        end
        assert_near(sent.grain.grainSize, voice.values.grain_size, 1e-9, label .. "grainSize")
        assert_near(sent.grain.grainDensity, voice.values.grain_density * master, 1e-9, label .. "grainDensity")
        assert_near(sent.grain.pitchShift, voice.values.grain_pitch, 1e-9, label .. "pitchShift")
        assert_near(sent.grain.posSpread, voice.values.grain_spread, 1e-9, label .. "posSpread")
        assert_near(sent.grain.windowShape, voice.values.grain_shape, 1e-9, label .. "windowShape")
        assert_equal(sent.grain.grainMode, voice.values.grain_mode - 1, label .. "grainMode")
        assert_near(sent.grain.bufPos, voice.values.buf_pos, 1e-9, label .. "bufPos")
        assert_near(sent.grain.bufRate, voice.values.buf_rate, 1e-9, label .. "bufRate")
        assert_near(sent.grain.bufScan, voice.values.buf_scan, 1e-9, label .. "bufScan")
        for slot = 1, 3 do
          local slot_state = {source = voice.values["mod_source_" .. slot],
            amp_amt = voice.values["mod_amp_amt_" .. slot], freq_amt = voice.values["mod_freq_amt_" .. slot]}
          assert_equal(sent.source[slot], slot_state.source == 0 and -1 or slot_state.source - 1, label .. "mod source " .. slot)
          assert_near(sent.amp_amt[slot], slot_state.amp_amt, 1e-9, label .. "amp mod " .. slot)
          assert_near(sent.freq_amt[slot], slot_state.freq_amt, 1e-9, label .. "freq mod " .. slot)
        end
        assert_near(sent.speed, voice.values.mod_speed, 1e-9, label .. "mod speed")
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
      -- (3.7's lib/slices.lua: the own note's region)
      if record.name == "slices" then registered.regionStart, registered.regionLength = true, true end
      -- (lib/scan.lua's: the follow rate)
      if record.name == "scan" then registered.followRate = true end
      -- (3.8's lib/arp.lua: the fold)
      if record.name == "arp" then registered.arpFold = true end
      -- (lib/variation.lua's)
      if record.name == "variation" then
        for index = 1, local_value("S").lib.variation.VARIATION.max_intervals do registered["interval" .. index] = true end
        registered.intervalCount, registered.scaleNote, registered.rootNote = true, true, true  -- (3.7: rootNote)
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
    for voice_idx = 1, local_value("S").constants.NUM_VOICES do
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

-- 3.9 (#892): apply_entries puts S.scene_recall_in_progress back as it
-- found it, so an apply inside another (a param action of the recall that
-- applies entries of its own) leaves the outer one's flag set
test("a nested apply leaves the recall flag as it found it", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("reverb_mix", 0.4); capture_scene(1)
  params:set("reverb_mix", 0.1)
  local real_action, seen = params:lookup_param("reverb_mix").action, {}
  params:set_action("reverb_mix", function(value)
    real_action(value)
    if #seen == 0 then
      S.lib.scenes.apply_entries({})                    -- an apply inside the recall's
      seen[1] = S.scene_recall_in_progress
    end
  end)
  recall_scene(1, 0)
  assert_equal(seen[1], true, "the outer apply's flag is still set after the inner one")
  assert_equal(S.scene_recall_in_progress, false, "and cleared once the outer apply ends")
  -- an apply made while the flag is set leaves it set
  S.scene_recall_in_progress = true
  S.lib.scenes.apply_entries({})
  assert_equal(S.scene_recall_in_progress, true, "an apply leaves a flag it found set")
  S.scene_recall_in_progress = false
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
  assert_true(local_value("locked")[1], "and its lock")
end)

test("fill_scene fills a voice's missing keys with their defaults and tolerates malformed data", function()
  load_strata()
  params:set("v2_grain_cloud", 2); params:set("v2_grain_mode", 2)
  capture_scene(1)
  local scene = deep_copy(local_value("scenes")[1])
  -- a missing key is filled with its default (the param's), present ones are kept
  scene.data.voices[2].values.grain_cloud = nil
  scene.data.voices[2].values.mod_speed = nil
  scene.data.voices[3].values.freq = nil
  scene.data.voices[5].values.reverb_send = nil
  fill_scene(scene)
  assert_equal(scene.data.voices[2].values.grain_cloud, params:lookup_param("v2_grain_cloud").default, "grain_cloud filled")
  assert_near(scene.data.voices[2].values.mod_speed, params:lookup_param("v2_mod_speed").controlspec.default, 1e-9,
    "mod_speed filled")
  assert_near(scene.data.voices[3].values.freq, params:lookup_param("v3_freq").controlspec.default, 1e-9, "freq filled")
  assert_near(scene.data.voices[5].values.reverb_send, params:lookup_param("v5_reverb_send").controlspec.default, 1e-9,
    "a registered key filled")
  assert_equal(scene.data.voices[2].values.grain_mode, 2, "a present value is kept")
  assert_true(validate_scene(scene), "the filled scene validates")
  -- a voice without values is not invented one
  scene.data.voices[4].values = nil
  fill_scene(scene)
  assert_equal(scene.data.voices[4].values, nil, "missing parent tables are not invented")
  scene.data.reverb_mix = nil
  fill_scene(scene)
  assert_near(scene.data.reverb_mix, 0.43, 1e-9, "missing global filled from its default")
  scene.data.reverb_mix = 0.9
  fill_scene(scene)
  assert_near(scene.data.reverb_mix, 0.9, 1e-9, "present values are kept")
  -- malformed scenes are left for validate_scene to reject
  for _, bad in ipairs({ "x", {}, { populated = true }, { populated = true, data = { voices = "v" } },
      { populated = true, data = { voices = { "a", 3 } } }, { populated = false } }) do
    fill_scene(bad)
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
  for _, bad in ipairs({ 0, #local_value("S").constants.SOURCE_OPTIONS + 1, 2.5, "buf 1" }) do  -- (3.8: 17 options)
    scene.data.voices[2].source = bad
    assert_true(not validate_scene(scene), "source " .. tostring(bad) .. " rejected")
  end
  for voice_idx = 1, local_value("S").constants.NUM_VOICES do
    scene.data.voices[voice_idx].source = nil
    for _, key in ipairs({ "buf_pos", "buf_rate", "buf_scan" }) do scene.data.voices[voice_idx].values[key] = nil end
  end
  fill_scene(scene)
  assert_equal(scene.data.voices[2].source, 1, "missing source migrates to synth")
  assert_equal(scene.data.voices[2].values.buf_rate, 1, "missing buf_rate migrates to 1")
  assert_equal(scene.data.voices[2].values.buf_pos, 0, "missing buf_pos migrates to 0")
  assert_true(validate_scene(scene), "migrated scene validates")
end)

test("scenes capture and recall the LFOs", function()
  local context = load_strata({ data_subdir = "lfo_scenes" }); finish_startup(context)
  params:set("strata_lfo1_shape", 2); params:set("strata_lfo1_mode", 2); params:set("strata_lfo1_division", 5)
  local matrix = local_value("S").lib.matrix
  params:set("strata_lfo2_rate", 9); params:set("strata_lfo2_depth", 60); matrix.set_home(2, "v1_grain_size")
  params:set("strata_lfo2_phase", 30); params:set("strata_lfo2_rate_mod", 2); params:set("strata_lfo2_depth_mod_amt", -40)
  params:set("strata_lfo2", 1)
  capture_scene(1)
  local data = local_value("scenes")[1].data
  assert_equal(data.strata_lfo1_shape, 2); assert_equal(data.strata_lfo1_mode, 2); assert_equal(data.strata_lfo1_division, 5)
  assert_near(data.strata_lfo2_rate, 9, 1e-6); assert_equal(data.strata_lfo2_depth, 60)
  -- the destination is LFO 2's home routing, in the matrix's block (the groundwork before 3.8)
  assert_equal(data.matrix[18].dest, "v1_grain_size", "the destination by its key"); assert_equal(data.strata_lfo2, 1)
  assert_equal(data.strata_lfo2_dest_key, nil, "no block of its own")
  assert_equal(data.strata_lfo2_dest, nil, "never its index")
  assert_equal(data.strata_lfo2_phase, 30); assert_equal(data.strata_lfo2_rate_mod, 2)
  assert_equal(data.strata_lfo2_depth_mod_amt, -40)
  params:set("strata_lfo2", 0); params:set("strata_lfo2_depth", 0); matrix.set_home(2, "")
  params:set("strata_lfo1_shape", 1); params:set("strata_lfo2_phase", 0); params:set("strata_lfo2_rate_mod", 1)
  recall_scene(1, 0)
  assert_equal(params:get("strata_lfo2"), 1); assert_equal(params:get("strata_lfo2_depth"), 60)
  assert_equal(matrix.home(2), "v1_grain_size"); assert_equal(params:string("strata_lfo1_shape"), "tri")
  assert_equal(local_value("S").lib.lfos.label(2), "v1 size~", "the LFO reads it")
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
      "depth_mod_amt" }) do
      assert_equal(continuous["strata_lfo" .. n .. "_" .. field], false, field .. " switches")
    end
    assert_equal(continuous["strata_lfo" .. n .. "_dest"], nil, "the destination is no global field")
    for _, record in ipairs(local_value("S").registry.scene_blocks) do
      assert_true(record.key ~= "strata_lfo" .. n .. "_dest_key", "nor a block of its own")
    end
    assert_equal(continuous["strata_lfo" .. n], false, "the state switches")
  end
  -- a destination that is no key is rejected
  local bad = deep_copy(local_value("scenes")[1]); bad.data.matrix[18] = { source = "lfo2", dest = 0.5 }
  assert_true(not validate_scene(bad), "a number is no key")
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

test("LFO offsets in scenes: save and load, a scene without them, validation (#103)", function()
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

  -- a scene without offsets loads with offsets 0
  local old = deep_copy(local_value("scenes")[2])
  for n = 1, 3 do old.data["strata_lfo" .. n .. "_offset"] = nil end
  tab.save({ version = local_value("SCENE_DATA_VERSION"), scenes = { [2] = deep_copy(old) } },
    context.data_dir .. "strata/scenes.data")
  load_scenes_from_disk()
  local loaded = local_value("scenes")[2]
  assert_true(loaded.populated, "a scene without offsets loads")
  for n = 1, 3 do
    assert_equal(loaded.data["strata_lfo" .. n .. "_offset"], 0, "offset " .. n .. " is filled with 0")
  end
  params:set("strata_lfo3_offset", 25)
  recall_scene(2, 0)
  assert_equal(params:get("strata_lfo3_offset"), 0, "the filled offset is recalled")

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
  tab.save({ version = local_value("SCENE_DATA_VERSION"), scenes = { scene } }, context.data_dir .. "strata/scenes.data")
  local captured_offset = local_value("scenes")[1].data.strata_lfo2_offset
  load_scenes_from_disk()
  assert_equal(local_value("scenes")[1].data.strata_lfo2_offset, captured_offset, "the bad file is not loaded")
  assert_true(local_value("scenes")[2].populated, "the current scenes stay")
  assert_true(table.concat(context.printed, "\n"):find("scene file corrupted", 1, true), "the bad file is reported")
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
  local freq = S.scenes[2].data.voices[1].values.freq
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
  assert_near(S.scenes[2].data.voices[1].values.freq, freq, 1e-6)
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
  rejects(function(data) data.voices[2].values.future_key = 0.5 end, "a grain key from a later version")
  rejects(function(data) data.voices[5].values.mod_amp_amt_2 = nil end, "a missing amp amount")
  rejects(function(data) data.voices[5].values.mod_amp_amt_3 = "deep" end, "an amp amount that is not a number")
  rejects(function(data) data.voices[6].values.mod_freq_amt_1 = nil end, "a missing freq amount")
  rejects(function(data) data.voices[6].values.mod_freq_amt_2 = 0 / 0 end, "a freq amount that is NaN")
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
  assert_true(S.locked[4], "the recall locked voice 4")
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
        S.lib.params_setup.add_voice_param(voice_idx, record, key, { type = "control", name = key,
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

-- A scene voice's keys in recall order since the groundwork before 3.8
-- (ruling 4), written out here: the voice's synth keys sorted, the eight
-- grain keys sorted, the ten crossmod keys sorted, then every other key of
-- the voice's values (its registered keys) sorted
local REFERENCE_GRAIN_KEYS = { "buf_pos", "buf_rate", "buf_scan", "grain_density", "grain_mode",
  "grain_pitch", "grain_size", "grain_spread" }
local REFERENCE_CROSSMOD_KEYS = { "mod_amp_amt_1", "mod_amp_amt_2", "mod_amp_amt_3", "mod_freq_amt_1", "mod_freq_amt_2",
  "mod_freq_amt_3", "mod_source_1", "mod_source_2", "mod_source_3", "mod_speed" }
local function reference_voice_keys(S, voice_idx, values)
  local keys, built_in = {}, {}
  local synth = {}
  for _, key in ipairs(S.voices[voice_idx].param_order) do synth[#synth + 1] = key end
  table.sort(synth)
  for _, list in ipairs({ synth, REFERENCE_GRAIN_KEYS, REFERENCE_CROSSMOD_KEYS }) do
    for _, key in ipairs(list) do keys[#keys + 1] = key; built_in[key] = true end
  end
  local registered = {}
  for key in pairs(values) do
    if not built_in[key] then registered[#registered + 1] = key end
  end
  table.sort(registered)
  for _, key in ipairs(registered) do keys[#keys + 1] = key end
  return keys
end

-- The merged recall_scene_instant (lib/scenes.lua at 3.3.2), from its flag
-- to its pattern restore, copied verbatim but for the voice's values, with
-- the local helper it calls (set_scene_param). Its clear_undo, current
-- scene and redraws send nothing to the engine and are left out. The
-- groundwork before 3.8 re-bases it on the format 9 voice (one values
-- table), whose keys it sets in recall order (reference_voice_keys), where
-- 3.3.2 set the synth and grain params in pairs order and crossmod per slot.
-- 3.9 (#977) re-bases its set_scene_param: a control param that already
-- holds the value is set to its own raw value (no action, no send)
local function reference_recall(S, scene_data)
  local NUM_VOICES = S.constants.NUM_VOICES
  local function set_scene_param(param_id, value)
    local param = params:lookup_param(param_id)
    if param.t == params.tBINARY then
      set_binary_param(param_id, value)
    elseif param.t == params.tCONTROL and param:get() == value then
      params:set_raw(param_id, params:get_raw(param_id))
    else
      params:set(param_id, value)
    end
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

      -- the voice's values, after the source, in recall order
      for _, key in ipairs(reference_voice_keys(S, i, voice_data.values)) do
        set_scene_param(prefix .. key, voice_data.values[key])
      end

      -- 3.4 (0b) adds the lock hooks to a recall: a lock that changes runs
      -- them (scatter's voice mask, lib/scatter.lua, sends setScatter)
      local was_locked = S.locked[i]
      S.locked[i] = scene_data.locked[i]
      if (not was_locked) ~= (not S.locked[i]) then
        for _, hook in ipairs(S.registry.lock_change) do hook(i, S.locked[i]) end
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
-- verbatim but for the voice's values (re-based as reference_recall is),
-- with the local helpers it calls (LFO_STATE, registered_voice_scene_keys).
-- The discrete built-in keys (the grain mode, the mod sources)
-- are written out
local REFERENCE_DISCRETE_KEYS = { grain_mode = true, mod_source_1 = true, mod_source_2 = true,
  mod_source_3 = true }
local function reference_targets(S, scene_data)
  local NUM_VOICES = S.constants.NUM_VOICES
  local LFO_STATE = {off = 0, on = 1}
  local function registered_voice_scene_keys()
    local keys = {}
    for _, record in ipairs(S.registry.voice_params) do
      -- 3.7: scene_defaults may be a function of the voice (the keys are every voice's)
      for key, default in pairs(S.voice_scene_defaults(record, 1)) do
        keys[key] = {default = default, range = record.discrete and record.discrete[key],
          limits = record.scene_ranges and record.scene_ranges[key]}
      end
    end
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
    -- every key that crossfades (discrete ones switch at the end)
    for _, key in ipairs(reference_voice_keys(S, i, voice_data.values)) do
      local registered = extra_keys[key]
      if not REFERENCE_DISCRETE_KEYS[key] and not (registered and registered.range) then
        add_target(prefix .. key, voice_data.values[key])
      end
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
  math.randomseed(run)  -- equal starting states: the random sequences draw their values at the first start
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function set_active(voice, active)
    if S.voices[voice].active ~= active then toggle_voice(voice) end
  end
  scramble_state(100 + run)
  params:set("reverb_mix", 0.62); params:set("filter_type", 2); params:set("strata_lfo1", 0)
  for voice = 1, S.constants.NUM_VOICES do
    local plan = recall_combination(((run - 1) * S.constants.NUM_VOICES + voice - 1) % 24)
    params:set("v" .. voice .. "_source", plan.scene_source)
    set_active(voice, plan.scene_active)
    if voice % 2 == 1 then toggle_lock(voice) end
    toggle_pattern_step(voice, voice)
  end
  capture_scene(1)
  scramble_state(200 + run)
  params:set("reverb_mix", 0.15); params:set("filter_type", 1); params:set("strata_lfo1", 1)
  for voice = 1, S.constants.NUM_VOICES do
    local plan = recall_combination(((run - 1) * S.constants.NUM_VOICES + voice - 1) % 24)
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
        voices = deep_copy(S.voices), locked = deep_copy(S.locked), patterns = deep_copy(S.patterns),
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
      assert_same(outcome.locked, reference.locked, where .. ": S.locked")
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
  assert_true(S.locked[4], "a lock is set")
  assert_true(S.voices[5].active, "a voice the scene runs is started")
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "reverb mix stays")
  -- only = continuous: the continuous values, and no discrete one
  params:set("filter_type", 1); toggle_lock(4); toggle_voice(5)
  S.lib.scenes.apply_entries(entries, { only = "continuous" })
  assert_near(params:get("reverb_mix"), 0.7, 1e-9, "only = continuous sets reverb mix")
  assert_equal(params:get("filter_type"), 1, "and no discrete global")
  assert_true(not S.locked[4], "no lock")
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

-- 3.9 (#867, the review of 1d): a fade step's through-zero switches run as
-- a scene's sets (S.lib.scenes.setting() true), as its loop of sets does;
-- between steps no scene is setting
test("a fade step's through-zero switches run while the scene is setting", function()
  local seen = {}
  local context = load_strata({ before_init = function()
    add_scene_block(local_value("S"), { key = "tz", default = function() return 0 end,
      capture = function() return 5 end, validate = function(value) return type(value) == "number" end,
      apply = function() end, discrete = true,
      through_zero = function()
        return { { id = "reverb_mix", switch = function() table.insert(seen, local_value("S").lib.scenes.setting()) end } }
      end })
  end })
  finish_startup(context)
  local S = local_value("S")
  params:set("reverb_mix", 0.8); capture_scene(1)
  params:set("reverb_mix", 0.4)
  recall_scene(1, 2)                                              -- 20 steps of 0.1 s; step 1 runs at once
  for _ = 2, 10 do
    assert_equal(S.lib.scenes.setting(), false, "between steps no scene is setting")
    wake(context, "scene_transition_clock")                       -- step 10: f = 0.5
  end
  assert_equal(#seen, 1, "the switch ran at the midpoint")
  assert_equal(seen[1], true, "while the scene was setting")
  assert_equal(S.lib.scenes.setting(), false, "and the step put the flag back")
  cancel_scene_transition()
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

-- 3.7 (design §5.4, decision 12): the scene sequencer's next scene is drawn
-- from three chances through S.lib.chance.pick, once, right after a recall

-- Scenes in `slots` saved, the sequence `length` long, the chances set
local function chance_scenes(slots, length, chances)
  for _, slot in ipairs(slots) do capture_scene(slot) end
  params:set("scene_sequence_length", length)
  params:set("scene_chance_next", chances[1])
  params:set("scene_chance_previous", chances[2])
  params:set("scene_chance_random", chances[3])
end

local function recalled_scenes(recalls)
  local scenes = {}
  for index, recall in ipairs(recalls) do scenes[index] = recall.scene end
  return table.concat(scenes, " ")
end

test("the scene sequencer's three chances are PSET settings after the sequence length, 100, 0 and 0", function()
  load_strata()
  local order = {}
  for index, param in ipairs(params.params) do order[param.id or ""] = index end
  local length = order.scene_sequence_length
  for offset, id in ipairs({ "scene_chance_next", "scene_chance_previous", "scene_chance_random" }) do
    assert_equal(order[id], length + offset, id .. " follows the sequence length")
  end
  assert_equal(params:get("scene_chance_next"), 100); assert_equal(params:get("scene_chance_previous"), 0)
  assert_equal(params:get("scene_chance_random"), 0)
  params:set("scene_chance_random", 150); assert_equal(params:get("scene_chance_random"), 100, "at most 100")
  params:set("scene_chance_random", -5); assert_equal(params:get("scene_chance_random"), 0, "at least 0")
  params:set("scene_chance_previous", 35)
  assert_equal(params:string("scene_chance_previous"), "35%", "shown as a percent")
  capture_scene(1)
  local data = local_value("scenes")[1].data
  for _, id in ipairs({ "scene_chance_next", "scene_chance_previous", "scene_chance_random" }) do
    assert_equal(data[id], nil, "a scene never stores " .. id)
  end
end)

test("at 100, 0, 0 the sequencer plays in order and draws nothing", function()
  local context = load_strata(); finish_startup(context)
  chance_scenes({ 1, 2, 3, 4 }, 4, { 100, 0, 0 })
  local real_random, draws = math.random, 0
  math.random = function() draws = draws + 1; error("the scene sequencer drew a random number") end
  local ok, recalls = pcall(run_scene_sequencer, context, 0, 4, 17)
  math.random = real_random
  assert_true(ok, tostring(recalls))
  assert_equal(draws, 0, "no random number drawn")
  assert_equal(recalled_scenes(recalls), "1 2 3 4 1", "in order, as 3.6 plays")
  params:set("scene_sequencer_enabled", 0)
end)

test("the next scene is drawn once and the grids show the one that plays", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 2, 3, 4 }, 4, { 0, 0, 100 })
  math.randomseed(1)
  local real_random, draws = math.random, 0
  math.random = function(...) draws = draws + 1; return real_random(...) end
  local ok, problem = pcall(function()
    local recalls = run_scene_sequencer(context, 0, 4, 1)
    for pass = 1, 8 do
      local where = "pass " .. pass .. ": "
      assert_equal(#recalls, pass, where .. "one recall a pass")
      local playing = recalls[pass].scene
      assert_equal(draws, pass, where .. "one draw a pass: random takes no draw for its move, one for its slot")
      local next_slot = S.lib.scenes.sequencer_next_slot()
      for _ = 1, 5 do assert_equal(S.lib.scenes.sequencer_next_slot(), next_slot, where .. "the same slot however often asked") end
      assert_equal(draws, pass, where .. "asking draws nothing")
      assert_true(next_slot ~= playing, where .. "random picks another slot")
      assert_equal(S.scene_sequencer_next, next_slot, where .. "kept in S.scene_sequencer_next")
      assert_equal(S.lib.grid_core.scene_recall_level(next_slot), 10, where .. "the grids light it as next")
      context.clock.run_for(4, 0.001)
      assert_equal(recalls[pass + 1].scene, next_slot, where .. "and the next pass recalls it")
    end
  end)
  math.random = real_random
  assert_true(ok, tostring(problem))
  params:set("scene_sequencer_enabled", 0)
end)

test("previous runs backward and wraps to the last populated slot", function()
  local context = load_strata(); finish_startup(context)
  chance_scenes({ 1, 2, 4 }, 5, { 0, 100, 0 })               -- slots 3 and 5 empty
  local recalls = run_scene_sequencer(context, 0, 4, 17)
  assert_equal(recalled_scenes(recalls), "1 4 2 1 4", "scene 1 first, then back past the empty slots")
  params:set("scene_sequencer_enabled", 0)
end)

test("a repeat holds the scene and recalls nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 2, 3 }, 3, { 0, 0, 0 })
  local recalls = run_scene_sequencer(context, 0, 4, 1)
  assert_equal(#recalls, 1, "the first recall")
  for pass = 1, 3 do
    context.clock.run_for(4, 0.001)
    assert_equal(#recalls, 1, "pass " .. pass .. " recalls nothing")
    assert_equal(S.current_scene, 1, "scene 1 holds")
    assert_equal(S.scene_sequencer_position, 1)
    assert_equal(S.lib.scenes.sequencer_next_slot(), 1, "and repeats again")
  end
  params:set("scene_chance_next", 100)                       -- a chance changed during the hold draws nothing
  assert_equal(S.lib.scenes.sequencer_next_slot(), 1, "the kept repeat stands")
  context.clock.run_for(4, 0.001)
  assert_equal(#recalls, 1, "so this pass holds too")
  context.clock.run_for(4, 0.001)
  assert_equal(recalled_scenes(recalls), "1 2", "then the next pass's draw moves on")
  params:set("scene_sequencer_enabled", 0)
end)

test("empty slots are never picked", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 2, 5, 6 }, 8, { 30, 30, 30 })
  math.randomseed(7)
  local recalls = run_scene_sequencer(context, 0, 4, 1)
  for pass = 1, 40 do
    local next_slot = S.lib.scenes.sequencer_next_slot()
    assert_true(S.scenes[next_slot].populated, "pass " .. pass .. ": next is slot " .. next_slot .. ", which holds a scene")
    context.clock.run_for(4, 0.001)
  end
  local seen = {}
  for _, recall in ipairs(recalls) do
    assert_true(S.scenes[recall.scene].populated, "scene " .. recall.scene .. " holds a scene")
    seen[recall.scene] = true
  end
  assert_true(seen[2] and seen[5] and seen[6], "each saved scene played")
  assert_true(#recalls < 41, "some passes repeated")
  params:set("scene_sequencer_enabled", 0)
end)

test("a shortened sequence drops a kept slot past its end", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 2, 3, 4 }, 4, { 0, 100, 0 })
  local recalls = run_scene_sequencer(context, 0, 4, 1)
  assert_equal(S.lib.scenes.sequencer_next_slot(), 4, "scene 1 playing: previous is the last, 4")
  params:set("scene_sequence_length", 3)                     -- 4 is past the end now
  assert_equal(S.lib.scenes.sequencer_next_slot(), 3, "picked again over 1-3: previous is 3")
  context.clock.run_for(4, 0.001)
  assert_equal(recalls[#recalls].scene, 3, "and scene 3 is recalled")
  assert_equal(S.lib.scenes.sequencer_next_slot(), 2, "then 2")
  params:set("scene_chance_previous", 0); params:set("scene_chance_next", 100)
  assert_equal(S.lib.scenes.sequencer_next_slot(), 2, "a chance changed during the wait redraws nothing")
  params:set("scene_sequence_length", 4)
  assert_equal(S.lib.scenes.sequencer_next_slot(), 2, "nor does a longer sequence: 2 is still inside it")
  context.clock.run_for(4, 0.001)
  assert_equal(recalled_scenes(recalls), "1 3 2", "the kept slot played")
  assert_equal(S.lib.scenes.sequencer_next_slot(), 3, "then next, by the new chances")
  params:set("scene_sequencer_enabled", 0)
end)

-- 1f's review: a pick made again when the playing scene is outside the
-- sequence (or empty) is no pick: 3.6's advance stands in, with no draw

-- Count math.random's calls while fn runs (the real one draws)
local function counting_draws(fn)
  local real_random, draws = math.random, 0
  math.random = function(...) draws = draws + 1; return real_random(...) end
  local ok, problem = pcall(fn, function() return draws end)
  math.random = real_random
  assert_true(ok, tostring(problem))
end

-- Ask for the next slot as often as a screen and a grid redraw do
local function ask_often(S)
  local slots = {}
  for _ = 1, 5 do slots[#slots + 1] = S.lib.scenes.sequencer_next_slot() end
  for slot = 1, S.constants.NUM_SCENES do S.lib.grid_core.scene_recall_level(slot) end
  return slots
end

test("a repeat over a shortened sequence falls back to the next scene, and the mark follows what plays", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 2, 3, 4 }, 4, { 100, 0, 0 })
  local recalls = run_scene_sequencer(context, 0, 4, 9)        -- scenes 1, 2, 3: 3 playing
  assert_equal(recalls[#recalls].scene, 3, "scene 3 playing")
  params:set("scene_chance_next", 0)                           -- 0, 0, 0 from the next draw
  context.clock.run_for(4, 0.001)                              -- scene 4, then a repeat drawn
  assert_equal(recalls[#recalls].scene, 4, "scene 4 playing")
  assert_equal(S.lib.scenes.sequencer_next_slot(), 4, "a repeat of scene 4 drawn")
  params:set("scene_sequence_length", 2)                       -- scene 4 is past the end now
  assert_equal(table.concat(ask_often(S), " "), "1 1 1 1 1", "3.6's advance: past the end wraps to scene 1")
  context.clock.run_for(4, 0.001)
  assert_equal(recalls[#recalls].scene, 1, "scene 1 is recalled, not held silently")
  assert_equal(S.current_scene, 1)
  assert_equal(S.scene_sequencer_position, 1, "the mark is on the scene playing")
  params:set("scene_sequencer_enabled", 0)
end)

test("a pick made again draws at most once however often the grids ask", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 2, 3, 4 }, 4, { 100, 0, 0 })
  local recalls = run_scene_sequencer(context, 0, 4, 1)        -- scene 1 playing, 2 picked
  assert_equal(S.lib.scenes.sequencer_next_slot(), 2)
  params:set("scene_chance_next", 50)
  math.randomseed(3)
  counting_draws(function(draws)
    S.scenes[2] = { name = "", populated = false, data = {} }  -- the picked slot empties
    local asked = ask_often(S)
    assert_equal(draws(), 1, "the pick is made again once, however often asked")
    for index = 2, #asked do assert_equal(asked[index], asked[1], "the same slot every time") end
    assert_true(asked[1] == 1 or asked[1] == 3, "next (3) or a repeat (1): " .. tostring(asked[1]))
    context.clock.run_for(4, 0.001)
    assert_equal(draws(), 2, "then the pass's own draw after its recall")
    assert_equal(S.scene_sequencer_position, asked[1], "the pass went to the slot the grids showed")
    if asked[1] == 3 then assert_equal(recalls[#recalls].scene, 3) else assert_equal(#recalls, 1, "a repeat recalls nothing") end
  end)
  params:set("scene_sequencer_enabled", 0)
end)

test("at 50, 0, 0 a shortened sequence under the playing scene draws nothing and the next scene can play", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 2, 3, 4 }, 4, { 100, 0, 0 })
  local recalls = run_scene_sequencer(context, 0, 4, 9)        -- scene 3 playing
  assert_equal(recalls[#recalls].scene, 3)
  params:set("scene_chance_next", 50)
  counting_draws(function(draws)
    params:set("scene_sequence_length", 2)                     -- scene 3 and its pick past the end
    local asked = ask_often(S)
    assert_equal(draws(), 0, "no draw: the playing scene is outside the sequence")
    assert_equal(table.concat(asked, " "), "1 1 1 1 1", "3.6's advance, wrapped to 1")
    context.clock.run_for(4, 0.001)
    assert_equal(recalls[#recalls].scene, 1, "and scene 1 is recalled")
  end)
  params:set("scene_sequencer_enabled", 0)
end)

test("a load that empties the playing and the picked slots goes on to the scene after the position, as 3.6", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 2, 3, 4 }, 4, { 100, 0, 0 })
  local recalls = run_scene_sequencer(context, 0, 4, 5)        -- scenes 1, 2: 2 playing, 3 next
  assert_equal(recalls[#recalls].scene, 2)
  assert_equal(S.lib.scenes.sequencer_next_slot(), 3)
  for _, slot in ipairs({ 2, 3 }) do S.scenes[slot] = { name = "", populated = false, data = {} } end
  assert_equal(S.lib.scenes.sequencer_next_slot(), 4, "the first scene after the position, not scene 1")
  context.clock.run_for(4, 0.001)
  assert_equal(recalls[#recalls].scene, 4, "scene 4 is recalled")
  params:set("scene_sequencer_enabled", 0)
end)

test("a scene saved into a skipped slot during the hold waits: the picked scene plays first", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 3 }, 3, { 100, 0, 0 })
  local recalls = run_scene_sequencer(context, 0, 4, 1)        -- scene 1 playing, 3 picked past empty 2
  assert_equal(S.lib.scenes.sequencer_next_slot(), 3)
  capture_scene(2)                                             -- 3.6 would play 2 next
  assert_equal(S.lib.scenes.sequencer_next_slot(), 3, "the light keeps the picked scene")
  context.clock.run_for(4, 0.001)
  assert_equal(recalls[#recalls].scene, 3, "scene 3 plays, as the light showed")
  context.clock.run_for(4, 0.001)
  assert_equal(recalls[#recalls].scene, 1, "then 1, and 2 from the following pass")
  context.clock.run_for(4, 0.001)
  assert_equal(recalls[#recalls].scene, 2)
  params:set("scene_sequencer_enabled", 0)
end)

test("no next slot is kept while the sequencer is off", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 2 }, 2, { 100, 0, 0 })
  assert_equal(S.scene_sequencer_next, nil, "none before the sequencer starts")
  run_scene_sequencer(context, 0, 4, 1)
  assert_equal(S.scene_sequencer_next, 2, "kept while it runs")
  params:set("scene_sequencer_enabled", 0)
  assert_equal(S.scene_sequencer_next, nil, "dropped when it stops")
  S.scene_sequencer_next = 2
  local broken = table.concat(h.check_invariants(), "; ")
  S.scene_sequencer_next = nil
  assert_true(broken:find("scene sequencer: scene_sequencer_next is 2 but the sequencer is off", 1, true),
    "the invariant names a kept slot while it is off: " .. broken)
end)

-- The groundwork's stepper (design §5, ruling 27): S.lib.scenes.playable,
-- playable_slots and next_slot, under the scene sequencer, the chain and the
-- next-scene action. A scene made invalid is a fresh table written into its
-- slot (only a table written outside lib/scenes.lua is checked again)

-- Slot `slot`'s scene, captured, replaced by a fresh copy that fails
-- validate_scene (a condition no step takes)
local function make_invalid(S, slot)
  S.scenes[slot] = deep_copy(S.scenes[slot])
  S.scenes[slot].data.steps[1][1] = { cond = "9:9" }
  assert_true(not validate_scene(S.scenes[slot]), "slot " .. slot .. "'s copy fails validate_scene")
end

test("playable_slots lists a range's populated valid slots, wrapping past 16", function()
  load_strata()
  local S = local_value("S")
  for _, slot in ipairs({ 1, 2, 15, 16 }) do capture_scene(slot) end
  make_invalid(S, 2)
  local scenes = S.lib.scenes
  local function listed(first, count) return table.concat(scenes.playable_slots(first, count), " ") end
  assert_equal(listed(15, 4), "15 16 1", "15, 16, 1 and 2, the invalid 2 left out")
  assert_equal(listed(1, 16), "1 15 16", "the whole range, in order")
  assert_equal(listed(1, 20), "1 15 16", "a count of 20 counts 16")
  assert_equal(listed(3, 12), "", "none in 3-14")
  for _, bad in ipairs({ { 0, 4 }, { 17, 4 }, { 1.5, 4 }, { 1, 0 }, { 1, 2.5 }, { "1", 4 }, { 1, nil } }) do
    assert_equal(listed(bad[1], bad[2]), "", tostring(bad[1]) .. ", " .. tostring(bad[2]) .. ": no list")
  end
  assert_true(scenes.playable(1) and scenes.playable(16), "a captured scene plays")
  assert_true(not scenes.playable(2), "an invalid one does not")
  assert_true(not scenes.playable(3), "nor an empty one")
  assert_true(not scenes.playable(0) and not scenes.playable(17) and not scenes.playable(1.5), "nor a number that is no slot")
end)

test("next_slot: no slot is nil; a lone slot keeps the playing scene; a position not in the list goes on with no draw", function()
  load_strata()
  local S = local_value("S")
  local scenes = S.lib.scenes
  local function raising_random() error("next_slot drew a random number") end
  local slot, move = scenes.next_slot(1, {}, { 100, 0, 0 })
  assert_equal(slot, nil, "no slot"); assert_equal(move, nil, "and no move")
  slot, move = scenes.next_slot(3, { 3 }, { 100, 0, 0 }, raising_random)
  assert_equal(slot, 3, "a lone slot at 100, 0, 0: the playing scene"); assert_equal(move, "next", "applied again")
  slot, move = scenes.next_slot(3, { 3 }, { 0, 0, 100 })
  assert_equal(slot, 3, "random with no other slot keeps it"); assert_equal(move, "repeat", "held")
  slot, move = scenes.next_slot(2, { 1, 4 }, { 0, 100, 0 }, raising_random)
  assert_equal(slot, 4, "2 is not in the list: the first after it"); assert_equal(move, "next", "with no draw")
  slot, move = scenes.next_slot(15, { 1, 4 }, { 0, 0, 100 }, raising_random)
  assert_equal(slot, 1, "past the last, around to the first"); assert_equal(move, "next")
  slot, move = scenes.next_slot(nil, { 13, 14, 1 }, { 0, 0, 100 }, raising_random)
  assert_equal(slot, 13, "no position: the list's first"); assert_equal(move, "next")
  -- the picker is looked up at each call
  local real_pick, picked = S.lib.chance.pick, nil
  S.lib.chance.pick = function(...) picked = { ... }; return 4, "previous" end
  slot, move = scenes.next_slot(1, { 1, 4 }, { 0, 100, 0 })
  S.lib.chance.pick = real_pick
  assert_equal(slot, 4); assert_equal(move, "previous", "the picker's answer")
  assert_equal(picked[1], 1, "the position"); assert_equal(table.concat(picked[2], " "), "1 4", "the slots")
  assert_equal(table.concat(picked[3], " "), "0 100 0", "the chances")
end)

test("the scene sequencer never draws or recalls an invalid scene (#754)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 2, 3, 4 }, 4, { 0, 0, 100 })
  make_invalid(S, 3)
  math.randomseed(1)
  local recalls = run_scene_sequencer(context, 0, 4, 1)
  for pass = 1, 40 do
    assert_true(S.lib.scenes.sequencer_next_slot() ~= 3, "pass " .. pass .. ": the invalid 3 is never next")
    context.clock.run_for(4, 0.001)
  end
  for index, recall in ipairs(recalls) do
    assert_true(recall.scene ~= 3, "recall " .. index .. " is not of scene 3")
  end
  assert_true(#recalls > 30, "the sequencer went on: " .. #recalls .. " recalls")
  assert_true(not table.concat(context.printed, "\n"):find("invalid data", 1, true), "no invalid data line")
  params:set("scene_sequencer_enabled", 0)
end)

test("a sequence whose one playable slot is the playing scene keeps it", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  chance_scenes({ 1, 2 }, 2, { 100, 0, 0 })
  make_invalid(S, 2)
  local recalls = run_scene_sequencer(context, 0, 4, 9)
  assert_equal(recalled_scenes(recalls), "1 1 1", "next to itself, applied again each pass")
  assert_true(not table.concat(context.printed, "\n"):find("invalid data", 1, true), "scene 2 is never tried")
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
        .. (local_value("S").locked[voice_idx] == locked and "" or " (before the state)"))
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
  assert_true(not S.locked[4], "no lock")
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
  for voice = 1, S.constants.NUM_VOICES do assert_true((per_voice[voice] or 0) > 10, "voice " .. voice .. "'s params are listed") end
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

-- 3.9 (#894): who holds the sound. held_by_scene() is true while a scene
-- is current or a fade runs; release_current() leaves no scene current
-- and cancels a running fade as cancel_scene_transition does (morph's
-- apply calls it, and morph no longer writes S.current_scene)
test("held_by_scene and release_current: a scene holds the sound until it is released", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local scenes = S.lib.scenes
  assert_true(not scenes.held_by_scene(), "nothing recalled at the start")
  params:set("reverb_mix", 0.6); capture_scene(2)
  params:set("reverb_mix", 0.2); capture_scene(1)
  recall_scene(1, 0)
  assert_true(scenes.held_by_scene(), "a recalled scene holds the sound")
  scenes.release_current()
  assert_equal(S.current_scene, 0, "released: no scene is current")
  assert_true(not scenes.held_by_scene(), "and none holds the sound")
  recall_scene(2, 2)
  context.clock.run_for(0.5)
  assert_true(S.scene_transition_active, "a fade runs")
  assert_true(scenes.held_by_scene(), "a fade holds the sound")
  local mix = params:get("reverb_mix")
  scenes.release_current()
  assert_true(not S.scene_transition_active and S.scene_transition_clock == nil, "the fade is canceled")
  assert_equal(S.current_scene, 0, "and no scene is current, not the fade's previous one")
  assert_true(not scenes.held_by_scene(), "nothing holds the sound")
  context.clock.run_for(3)
  assert_equal(params:get("reverb_mix"), mix, "the canceled fade sets nothing more")
  assert_equal(S.current_scene, 0, "nor lands")
  assert_equal(#context.clock.take_errors(), 0, "no clock error")
  scenes.release_current()
  assert_equal(S.current_scene, 0, "a release with nothing held changes nothing")
end)

-- The places in a Lua source that assign S.current_scene (`S.current_scene =`,
-- in a target list, by its key or by rawset; never `==`), each as
-- "<line>: <the functions around it, outermost first>"
local function current_scene_assignments(text)
  local code = h.sync_check.sanitize_lua(text)
  local events = {}
  for at, word in code:gmatch("()%f[%w_]([%a_][%w_]*)") do
    if word == "function" or word == "do" or word == "if" or word == "repeat" or word == "end" or word == "until" then
      table.insert(events, {at = at, word = word})
    end
  end
  for index, pattern in ipairs({"()S%.current_scene%s*=()", "()S%.current_scene%s*,[%w_%.%[%] \t,]-=()"}) do
    for at, after in code:gmatch(pattern) do
      local before = code:sub(1, at - 1):match("(%S)%s*$")
      local read = index == 2 and (before == "{" or before == "(" or before == "=")
      if code:sub(after, after) ~= "=" and not read then table.insert(events, {at = at, assignment = true}) end
    end
  end
  table.sort(events, function(a, b) return a.at < b.at end)
  local blocks, found = {}, {}
  for _, event in ipairs(events) do
    if event.assignment then
      local names = {}
      for _, block in ipairs(blocks) do
        if block ~= true then table.insert(names, block) end
      end
      local _, line = code:sub(1, event.at):gsub("\n", "")
      table.insert(found, (line + 1) .. ": " .. (#names > 0 and table.concat(names, " > ") or "main chunk"))
    elseif event.word == "function" then
      local own = code:match("^function%s+([%w_%.:]+)%s*%(", event.at)
      local before = code:sub(math.max(1, event.at - 80), event.at - 1)
      local name = own and own:match("([%w_]+)$") or before:match("([%w_]+)%s*=%s*$")
        or (before:match("%f[%w_]return%s*$") and "constructor") or "function"
      table.insert(blocks, name)
    elseif event.word == "end" or event.word == "until" then
      table.remove(blocks)
    else
      table.insert(blocks, true)
    end
  end
  return found
end

-- The one file that owns the mark, and the function whose states set it
-- for the page renders and the layout tests (lib/pages/scenes.lua's)
local CURRENT_SCENE_OWNER, CURRENT_SCENE_LAYOUT = "lib/scenes.lua", "layout_states"

test("S.current_scene is assigned only in lib/scenes.lua and in layout states", function()
  local problems, owner_sites, layout_sites = {}, 0, 0
  for _, source in ipairs(h.read_lua_sources()) do
    -- (sanitize_lua blanks a string's contents: a key is found in the text)
    if source.text:find("S%[%s*[\"']current_scene[\"']%s*%]%s*=[^=]")
      or source.text:find("rawset%(%s*S%s*,%s*[\"']current_scene") then table.insert(problems, source.path .. ": S.current_scene assigned by its key") end
    for _, site in ipairs(current_scene_assignments(source.text)) do
      local chain = " > " .. site:match("^%d+: (.*)$") .. " > "
      if source.path == CURRENT_SCENE_OWNER then
        owner_sites = owner_sites + 1
      elseif chain:find(" > " .. CURRENT_SCENE_LAYOUT .. " > ", 1, true) then
        layout_sites = layout_sites + 1
      else
        table.insert(problems, source.path .. ":" .. site)
      end
    end
  end
  table.sort(problems)
  assert_true(#problems == 0, "S.current_scene assigned outside lib/scenes.lua and the layout states:\n"
    .. table.concat(problems, "\n"))
  assert_true(owner_sites > 0, "the scan finds lib/scenes.lua's own assignments")
  assert_true(layout_sites > 0, "and the layout states'")
end)

test("the current scene scan finds an assignment's functions and skips comments, strings and comparisons", function()
  local found = current_scene_assignments(table.concat({
    "return function(S)",
    "  -- S.current_scene = 2 (a comment)",
    "  local text = \"S.current_scene = 3\"",
    "  if S.current_scene == 1 then end",
    "  S.current_scene = 1",
    "  S.current_scene, other = 5, 6",
    "  f(S.current_scene, x == 1)",
    "  local function layout_states()",
    "    local function populate() S.current_scene = 3 end",
    "  end",
    "  local function apply() for i = 1, 2 do S.current_scene = i end end",
    "  return M",
    "end",
  }, "\n"))
  assert_equal(table.concat(found, "; "),
    "5: constructor; 6: constructor; 9: constructor > layout_states > populate; 11: constructor > apply",
    "the sites")
end)

-- 3.6 (design §0.1): the scene-recalled hook, for the targets' program changes
test("the recalled hook runs once per recall", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  capture_freq_scenes()
  local heard = {}
  S.register_scene_recalled(function(scene_num) table.insert(heard, scene_num) end)
  local function take() local text = table.concat(heard, " "); for i = #heard, 1, -1 do heard[i] = nil end; return text end
  recall_scene(3, 0)
  assert_equal(take(), "3", "an instant recall")
  recall_scene(1, 2)
  assert_equal(take(), "1", "a fade, at its first step")
  context.clock.run_for(2.5, 0.001)
  assert_equal(local_value("current_scene"), 1, "the fade landed")
  assert_equal(take(), "", "none at its landing")
  recall_scene(10, 0)
  assert_equal(take(), "", "an empty scene")
  params:set_action("v1_freq", function() error("apply failed") end)
  assert_true(not pcall(recall_scene, 2, 0), "the recall's apply raises")
  assert_equal(take(), "", "a failed recall")
  assert_true(not pcall(recall_scene, 3, 4), "the fade's first step raises")
  context.clock.take_errors()
  assert_true(not local_value("scene_transition_active"), "the fade ended")
  assert_equal(take(), "", "a fade whose first step failed")
  params:set_action("v1_freq", function() end)
  run_scene_sequencer(context, 0, 4, 1)
  assert_equal(take(), "1", "the scene sequencer's advance")
end)

-- 3.7 (1d's review): the scene-applied hooks, for the delay's one send
test("the scene-applied hooks run once per apply_entries, after its flag clears, each contained", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  capture_freq_scenes()
  local runs, flags, later = 0, {}, 0
  S.register_scene_applied({ name = "probe", fn = function()
    runs = runs + 1; table.insert(flags, tostring(S.scene_recall_in_progress))
  end })
  S.register_scene_applied({ name = "raises", fn = function() error("hook failed") end })
  S.register_scene_applied({ name = "after", fn = function() later = later + 1 end })
  recall_scene(3, 0)
  assert_equal(runs, 1, "an instant recall: once")
  assert_equal(flags[1], "false", "after the flag is clear")
  assert_equal(later, 1, "a hook that raises leaves the next one running")
  assert_equal(printed_count(context, "scene applied hook"), 1, "its error is printed once")
  recall_scene(3, 0)
  assert_equal(printed_count(context, "scene applied hook"), 1, "and not again for the same message")
  runs, later = 0, 0
  recall_scene(1, 2)
  context.clock.run_for(2.5, 0.001)
  assert_equal(local_value("current_scene"), 1, "the fade landed")
  assert_equal(runs, 1, "a fade: once, at its landing")
  runs = 0
  S.lib.scenes.apply_entries({}, { only = "discrete" })
  assert_equal(runs, 1, "a morph's discrete apply: once")
  runs = 0
  params:set_action("v1_freq", function() error("apply failed") end)
  assert_true(not pcall(recall_scene, 2, 0), "the recall's apply raises")
  assert_equal(runs, 1, "a failed apply still runs them, once")
  assert_equal(S.scene_recall_in_progress, false)
  params:set_action("v1_freq", function() end)
  assert_equal(later, 3, "the hook after the raising one ran each time")
  local claimed = context.take_script_errors()  -- the printed failure this test raises (#473)
  assert_equal(#claimed, 1, "one failure printed")
  assert_true(claimed[1]:find("scene applied hook raises failed: ", 1, true) ~= nil, "the hook's error: " .. claimed[1])
end)

-- 3.7 (design decision 21): the format floor. A scenes file from
-- SCENE_FORMAT_FLOOR to SCENE_DATA_VERSION loads, its missing fields filled
-- from the defaults (fill_scene); an older one is set aside to its first
-- free backup name, never converted, and reads as older. The groundwork
-- before 3.8 raises the floor to 9 (rulings 1-3): 3.5's 7 and 3.7's 8 are
-- set aside too; 3.8 raises it to 10 (package 0d): the groundwork's 9 as well
test("a scenes file below format 10 is set aside whole, never converted", function()
  local context = load_strata({ data_subdir = "floor_source" })
  local S = local_value("S")
  assert_equal(S.constants.SCENE_FORMAT_FLOOR, 10, "the floor is format 10")
  capture_scene(2)
  local scenes = deep_copy(S.scenes)
  local cases = {
    { name = "format 1", value = { version = 1, scenes = scenes } },
    { name = "format 5", value = { version = 5, scenes = scenes } },
    { name = "format 6", value = { version = 6, scenes = scenes } },
    { name = "format 7 (3.5's)", value = { version = 7, scenes = scenes } },
    { name = "format 8 (3.7's)", value = { version = 8, scenes = scenes } },
    { name = "format 9 (the groundwork's, never released)", value = { version = 9, scenes = scenes } },
    { name = "the bare array before 2.1", value = scenes },
  }
  for index, case in ipairs(cases) do
    local subdir = "floor_" .. index
    local dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. dir .. "'")
    local text = tabutil_text(case.value)
    write_text(dir .. "scenes.data", text)
    context = load_strata({ data_subdir = subdir })
    S = local_value("S")
    for slot = 1, S.constants.NUM_SCENES do
      assert_true(S.scenes[slot].populated == false, case.name .. ": slot " .. slot .. " loads nothing")
    end
    assert_true(not util.file_exists(dir .. "scenes.data"), case.name .. ": the file is moved")
    assert_equal(file_text(dir .. "scenes.data.bak"), text, case.name .. ": whole, as scenes.data.bak")
    assert_equal(S.scene_file.problem, "older", case.name .. ": SETUP names it as older")
    assert_equal(S.scene_file.backup, dir .. "scenes.data.bak", case.name .. ": and its backup")
    assert_equal(printed_count(context, "older than format " .. S.constants.SCENE_FORMAT_FLOOR), 1, case.name .. ": one console line names the floor")
    -- the next save writes this session's scenes beside the backup, which stays
    capture_scene(3)
    cleanup()
    assert_equal(file_text(dir .. "scenes.data.bak"), text, case.name .. ": the backup is never overwritten")
    assert_equal(S.lib.data_files.read(dir .. "scenes.data").version, S.constants.SCENE_DATA_VERSION,
      case.name .. ": the save writes the build's format")
  end
end)

test("a file at the floor loads, and a field it lacks is its default", function()
  local context = load_strata({ data_subdir = "floor_seven" })
  local S = local_value("S")
  capture_scene(4)
  local scene = deep_copy(S.scenes[4])
  scene.data.reverb_size = nil
  scene.data.voices[2].values.slide_depth = nil
  scene.data.voices[3].values.grain_mode = nil
  scene.name = nil
  local dir = context.data_dir .. "strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  assert_true(S.lib.data_files.write(dir .. "scenes.data",
    { version = S.constants.SCENE_FORMAT_FLOOR, scenes = { [4] = scene } }), "written")
  context = load_strata({ data_subdir = "floor_seven" })
  S = local_value("S")
  assert_true(S.scenes[4].populated, "the file at the floor loads")
  assert_near(S.scenes[4].data.reverb_size, params:lookup_param("reverb_size").controlspec.default, 1e-9,
    "a missing global is its default")
  assert_equal(S.scenes[4].data.voices[2].values.slide_depth, 50, "a missing registered voice key is its default")
  assert_equal(S.scenes[4].data.voices[3].values.grain_mode, 1, "a missing voice field is its default")
  assert_equal(S.scenes[4].name, "", "a missing name is none")
  assert_true(not util.file_exists(dir .. "scenes.data.bak"), "nothing is set aside")
  assert_equal(printed_count(context, "older than format"), 0, "and nothing is said of a floor")
  -- the generic fill, by its name: only what is missing, on a populated scene
  local filled = deep_copy(S.scenes[4]); filled.data.reverb_size = nil; filled.data.reverb_mix = 0.9
  fill_scene(filled)
  assert_near(filled.data.reverb_size, params:lookup_param("reverb_size").controlspec.default, 1e-9, "fill_scene fills")
  assert_near(filled.data.reverb_mix, 0.9, 1e-9, "and keeps what is there")
end)

test("no copy of an older format is kept at a save", function()
  local context = load_strata({ data_subdir = "floor_no_copy" })
  local S = local_value("S")
  assert_equal(S.lib.data_files.keep_copy, nil, "no copy function")
  capture_scene(1)
  local dir = context.data_dir .. "strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  assert_true(S.lib.data_files.write(dir .. "scenes.data",
    { version = S.constants.SCENE_FORMAT_FLOOR, scenes = deep_copy(S.scenes) }), "written")
  context = load_strata({ data_subdir = "floor_no_copy" })
  S = local_value("S")
  assert_true(S.scenes[1].populated, "the file loads")
  capture_scene(2)
  assert_true(save_scenes_to_disk(), "saved")
  assert_equal(S.lib.data_files.read(dir .. "scenes.data").version, S.constants.SCENE_DATA_VERSION, "written")
  cleanup()
  -- the folder holds scenes.data and no copy of it under any .v<n> name
  local listing = assert(io.popen("ls -a '" .. dir .. "'"))
  local copies = {}
  for name in listing:lines() do
    if name:find("^scenes%.data%.v") then table.insert(copies, name) end
  end
  listing:close()
  assert_equal(table.concat(copies, ", "), "", "no scenes.data.v* file")
end)

-- Review focus 2: the first start after the update finds 3.7's scenes.data
-- (format 8). It is set aside whole and reads as older, not damaged, and
-- the next save writes the build's format
test("a 3.7 scenes file is set aside whole and reads as older", function()
  local context = load_strata({ data_subdir = "format_eight" })
  local S = local_value("S")
  capture_scene(3)
  local dir = context.data_dir .. "strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  local text = tabutil_text({ version = 8, scenes = deep_copy(S.scenes) })
  write_text(dir .. "scenes.data", text)
  context = load_strata({ data_subdir = "format_eight" })
  S = local_value("S")
  assert_equal(file_text(dir .. "scenes.data.bak"), text, "scenes.data.bak holds the file's bytes")
  for slot = 1, S.constants.NUM_SCENES do
    assert_true(S.scenes[slot].populated == false, "slot " .. slot .. " loads nothing")
  end
  assert_equal(S.scene_file.problem, "older", "the file reads as older")
  assert_equal(S.lib.ui_flash.text("hints"), "scenes older (SETUP)", "the start's flash says older")
  local lines = 0
  for _, line in ipairs(context.printed) do
    if line:find("format 8", 1, true) and line:find("format " .. S.constants.SCENE_DATA_VERSION, 1, true) then lines = lines + 1 end
  end
  assert_equal(lines, 1, "one console line names format 8 and the build's format")
  capture_scene(1)
  assert_true(save_scenes_to_disk(), "saved")
  assert_equal(S.lib.data_files.read(dir .. "scenes.data").version, S.constants.SCENE_DATA_VERSION, "the next save writes the build's format")
  assert_equal(S.scene_file.problem, "older", "SETUP still names the set-aside file")
  assert_equal(file_text(dir .. "scenes.data.bak"), text, "and the backup stays")
  cleanup()
end)

-- An older file that cannot be set aside (every backup name taken) is never
-- written over by an autosave; a save from SETUP writes the build's format over it
test("an older file still in place is not autosaved over", function()
  local context = load_strata({ data_subdir = "format_eight_in_place" })
  local S = local_value("S")
  capture_scene(3)
  local dir = context.data_dir .. "strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  local text = tabutil_text({ version = 8, scenes = deep_copy(S.scenes) })
  write_text(dir .. "scenes.data", text)
  write_text(dir .. "scenes.data.bak", "kept")
  for n = 2, 9 do write_text(dir .. "scenes.data.bak." .. n, "kept") end
  context = load_strata({ data_subdir = "format_eight_in_place" })
  S = local_value("S")
  assert_equal(S.scene_file.problem, "older", "older")
  assert_equal(S.scene_file.backup, nil, "and still in place")
  capture_scene(1)
  assert_equal(S.lib.scenes.autosave(), nil, "the autosave does not write")
  assert_equal(file_text(dir .. "scenes.data"), text, "the older file is as it was")
  assert_true(save_scenes_to_disk(), "a save from SETUP writes")
  assert_equal(S.lib.data_files.read(dir .. "scenes.data").version, S.constants.SCENE_DATA_VERSION, "the build's format")
  assert_equal(S.scene_file.problem, nil, "and the problem is over")
end)

test("a file newer than the build is set aside and its line names one format", function()
  local context = load_strata({ data_subdir = "format_ten" })
  local S = local_value("S")
  capture_scene(2)
  local dir = context.data_dir .. "strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  local text = tabutil_text({ version = S.constants.SCENE_DATA_VERSION + 1, scenes = deep_copy(S.scenes) })
  write_text(dir .. "scenes.data", text)
  context = load_strata({ data_subdir = "format_ten" })
  S = local_value("S")
  assert_equal(file_text(dir .. "scenes.data.bak"), text, "set aside whole")
  assert_equal(S.scene_file.problem, "unreadable", "a newer file is unreadable, not older")
  local version = S.constants.SCENE_DATA_VERSION
  assert_equal(printed_count(context, version .. " to " .. version), 0, "the line does not say " .. version .. " to " .. version)
  assert_equal(printed_count(context, "version " .. (version + 1)), 1, "one line names the file's version")
  assert_equal(printed_count(context, "format " .. version), 1, "and the one format this build reads")
end)

-- The first path at which two values differ, or nil when they are equal
-- (tables compared key by key, both ways; numbers to the precision a data
-- file writes them in: S.lib.data_files.encode writes a number with
-- tostring, 14 significant digits, as tab.save does, so a captured
-- filter_freq of 4999.9999999999973 is written "5000.0" and reads back
-- 5000, a relative difference under 5e-14)
local function first_difference(a, b, path)
  path = path or "scene"
  if type(a) ~= "table" or type(b) ~= "table" then
    if a == b then return nil end
    if type(a) == "number" and type(b) == "number" and math.abs(a - b) <= 1e-13 * math.abs(a) then
      return nil
    end
    return path .. ": " .. tostring(a) .. " ~= " .. tostring(b)
  end
  for key, value in pairs(a) do
    local found = first_difference(value, b[key], path .. "." .. tostring(key))
    if found then return found end
  end
  for key, value in pairs(b) do
    if a[key] == nil then return path .. "." .. tostring(key) .. ": nil ~= " .. tostring(value) end
  end
  return nil
end

-- The groundwork before 3.8: a file of the build's format (3.8: 10),
-- written from captures, loads with every scene as it was saved, and the
-- next save writes it again
test("a format 10 file loads with nothing changed", function()
  local context = load_strata({ data_subdir = "format_nine" })
  local S = local_value("S")
  assert_equal(S.constants.SCENE_DATA_VERSION, 10, "the build's format is 10")
  assert_equal(S.constants.SCENE_FORMAT_FLOOR, 10, "the floor is 10")
  params:set("v2_type", S.lib.types.record("ring").index)  -- a voice on another type
  scramble_state(17); capture_scene(1)
  scramble_state(23); capture_scene(5)
  S.lib.scenes.set_name(5, "five")
  local before = deep_copy(S.scenes)
  local dir = context.data_dir .. "strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  assert_true(S.lib.data_files.write(dir .. "scenes.data", { version = S.constants.SCENE_DATA_VERSION, scenes = deep_copy(S.scenes) }), "written")
  context = load_strata({ data_subdir = "format_nine" })
  S = local_value("S")
  for slot = 1, S.constants.NUM_SCENES do
    local difference = first_difference(before[slot], S.scenes[slot], "scene " .. slot)
    assert_true(difference == nil, "every scene equals itself: " .. tostring(difference))
  end
  assert_true(S.scenes[1].populated and S.scenes[5].populated, "the saved scenes load")
  assert_true(not util.file_exists(dir .. "scenes.data.bak"), "nothing is set aside")
  assert_true(save_scenes_to_disk(), "saved")
  assert_equal(S.lib.data_files.read(dir .. "scenes.data").version, S.constants.SCENE_DATA_VERSION, "the save writes the build's format")
  cleanup()
end)

test("a record's scene defaults may depend on the voice", function()
  local function probe_default(voice) return voice / 10 end
  local context = load_strata({ data_subdir = "floor_voice_defaults", before_init = function()
    local record = { name = "probe voice", count = 1, fader = false,
      scene_defaults = function(voice) return { probe_level = probe_default(voice) } end }
    function record.add(voice)
      local_value("S").lib.params_setup.add_voice_param(voice, record, "probe_level",
        { type = "control", name = "probe level", controlspec = controlspec.new(0, 1, "lin", 0, probe_default(voice)) })
    end
    local_value("S").register_voice_params(record)
  end })
  local S = local_value("S")
  capture_scene(1)
  local scene = deep_copy(S.scenes[1])
  for voice = 1, S.constants.NUM_VOICES do
    assert_near(scene.data.voices[voice].values.probe_level, probe_default(voice), 1e-9, "voice " .. voice .. " captured")
    scene.data.voices[voice].values.probe_level = nil
    scene.data.voices[voice].values.attack = nil
    scene.data.voices[voice].values.release = nil
  end
  fill_scene(scene)
  -- each voice's own times: its default type's envelope (3.8)
  local function envelope(voice) return S.lib.types.record(S.lib.types.default_key(voice)).envelope end
  for voice = 1, S.constants.NUM_VOICES do
    local extras = scene.data.voices[voice].values
    assert_near(extras.probe_level, probe_default(voice), 1e-9, "voice " .. voice .. ": its own probe default")
    -- a scene without the notes voice's attack and release gets each
    -- voice's own default, as 3.5's migration gave
    assert_equal(extras.attack, envelope(voice).attack, "voice " .. voice .. " attack")
    assert_equal(extras.release, envelope(voice).release, "voice " .. voice .. " release")
  end
  assert_true(validate_scene(scene), "the filled scene validates")
  -- a file without them loads with each voice's own times
  local dir = context.data_dir .. "strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  for voice = 1, S.constants.NUM_VOICES do
    scene.data.voices[voice].values.attack = nil; scene.data.voices[voice].values.release = nil
  end
  assert_true(S.lib.data_files.write(dir .. "scenes.data", { version = S.constants.SCENE_DATA_VERSION, scenes = { scene } }),
    "written")
  assert_equal(load_scenes_from_disk(), "loaded")
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(S.scenes[1].data.voices[voice].values.release, envelope(voice).release, "voice " .. voice .. " loads its release")
  end
  -- a function whose table for some voice holds a value that is no number
  -- is refused, as such a table is, at init (3.8, ruling 19: the function
  -- may read the voice types, which are read at init)
  cleanup()
  local ok, problem = pcall(load_strata, { data_subdir = "floor_bad_voice_defaults", before_init = function()
    local record = { name = "bad voice defaults", count = 1, fader = false,
      scene_defaults = function(voice) return { probe = voice == 3 and "x" or 0 } end }
    function record.add(voice)
      local_value("S").lib.params_setup.add_voice_param(voice, record, "probe",
        { type = "control", name = "probe", controlspec = controlspec.new(0, 1, "lin", 0, 0) })
    end
    local_value("S").register_voice_params(record)
  end })
  assert_true(not ok and tostring(problem):find("bad voice defaults", 1, true) ~= nil,
    "a function's tables are checked, every voice's: " .. tostring(problem))
end)

---------------------------------------------------------------------------
-- The groundwork before 3.8 (design §3, rulings 4 to 8): a scene voice
-- (3.8's format 10) is {active, source, type, values}; capture_voice,
-- apply_voice, voice_entries
---------------------------------------------------------------------------

-- A plain value as text with sorted keys, so two captures compare as text
-- (numbers to nine digits: a set through an exp spec moves the last bits)
local function encode(value)
  if type(value) ~= "table" then
    return type(value) == "number" and string.format("%.9g", value) or tostring(value)
  end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. encode(value[key]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function key_set_text(keys)
  local list = {}
  for key in pairs(keys) do list[#list + 1] = key end
  table.sort(list)
  return table.concat(list, ",")
end

test("capture_voice holds exactly the scene keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    local data = S.lib.scenes.capture_voice(voice)
    assert_equal(type(data.active), "boolean", "voice " .. voice .. ": active")
    assert_equal(data.source, S.voices[voice].source, "voice " .. voice .. ": source")
    local _, by_key = S.lib.params_setup.voice_scene_keys(voice)
    assert_equal(key_set_text(data.values), key_set_text(by_key), "voice " .. voice .. ": the scene keys")
    for key, value in pairs(data.values) do
      assert_equal(type(value), "number", "voice " .. voice .. " " .. key .. " is a number")
    end
    assert_equal(data.values.note_cap, nil, "no note_cap")
    assert_equal(data.values.solo, nil, "no solo")
    local fields = {}
    for field in pairs(data) do fields[field] = true end
    assert_equal(key_set_text(fields), "active,source,type,values", "voice " .. voice .. ": four fields (3.8: type)")
    assert_equal(data.type, S.voices[voice].name, "voice " .. voice .. ": its type's key")
  end
  assert_equal(S.lib.scenes.capture_voice(4).values.pan, nil, "voice 4 (sub) has no pan")
  assert_true(S.lib.scenes.capture_voice(1).values.pan ~= nil, "voice 1 has one")
  assert_equal(S.lib.scenes.capture_voice(0), nil, "no voice 0")
  assert_equal(S.lib.scenes.capture_voice(S.constants.NUM_VOICES + 1), nil, "no voice past the last")
  assert_equal(S.lib.scenes.capture_voice(1.5), nil, "no fractional voice")
  -- capture_scene's voices are capture_voice's
  capture_scene(1)
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(encode(S.scenes[1].data.voices[voice]), encode(S.lib.scenes.capture_voice(voice)),
      "capture_scene's voice " .. voice)
  end
end)

test("apply_voice round-trips a voice and leaves the other six, the patterns, the locks and the globals", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  scramble_state(17)
  toggle_lock(5)
  toggle_pattern_step(2, 3)
  params:set("v3_source", 1)
  local data = S.lib.scenes.capture_voice(3)
  scramble_state(18)
  params:set("v3_source", 4)
  local before = {}
  for voice = 1, S.constants.NUM_VOICES do before[voice] = encode(S.lib.scenes.capture_voice(voice)) end
  local patterns, locked, current = encode(S.patterns), encode(S.locked), S.current_scene
  local globals = {}
  for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do globals[global.id] = params:get(global.id) end
  local kept = encode(data)
  assert_equal(S.lib.scenes.apply_voice(3, data), true, "applied")
  assert_equal(encode(data), kept, "the data handed in is left alone")
  assert_equal(encode(S.lib.scenes.capture_voice(3)), kept, "voice 3 is the data again")
  for voice = 1, S.constants.NUM_VOICES do
    if voice ~= 3 then
      assert_equal(encode(S.lib.scenes.capture_voice(voice)), before[voice], "voice " .. voice .. " is unchanged")
    end
  end
  assert_equal(encode(S.patterns), patterns, "the patterns are unchanged")
  assert_equal(encode(S.locked), locked, "the locks are unchanged")
  for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
    assert_equal(params:get(global.id), globals[global.id], global.id .. " is unchanged")
  end
  assert_equal(S.current_scene, current, "no scene becomes current")
end)

test("apply_voice refuses an unknown key and applies nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  if not S.voices[2].active then toggle_voice(2) end
  params:set("v2_freq", 200)
  local data = S.lib.scenes.capture_voice(2)
  data.values.freq = 300
  data.values.bogus = 1
  context.clear_engine_calls()
  local printed = #context.printed
  assert_equal(S.lib.scenes.apply_voice(2, data), false, "refused")
  assert_near(params:get("v2_freq"), 200, 1e-9, "nothing applied")
  assert_equal(#context.engine_calls, 0, "nothing sent")
  assert_equal(#context.printed - printed, 1, "one console line")
  -- a bad index, and data that is no table, are refused too
  assert_equal(S.lib.scenes.apply_voice(0, S.lib.scenes.capture_voice(1)), false, "no voice 0")
  assert_equal(S.lib.scenes.apply_voice(2, "voice"), false, "no data")
  assert_equal(#context.engine_calls, 0, "still nothing sent")
end)

test("apply_voice sends one sync on a source change, and starts an active voice after its keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  -- a running voice whose source the data changes: one sync
  if not S.voices[2].active then toggle_voice(2) end
  params:set("v2_source", 3)
  local data = S.lib.scenes.capture_voice(2)
  params:set("v2_source", 1)
  local syncs = {}
  local sync = sync_voice_values_to_engine
  sync_voice_values_to_engine = function(voice)
    syncs[#syncs + 1] = voice
    return sync(voice)
  end
  local applied, apply_error = pcall(S.lib.scenes.apply_voice, 2, data)
  sync_voice_values_to_engine = sync
  assert_true(applied, tostring(apply_error))
  assert_equal(table.concat(syncs, ","), "2", "one sync, of voice 2")
  assert_equal(S.voices[2].source, 3, "the source is the data's")
  -- a stopped voice the data has running: started after its keys
  if S.voices[5].active then toggle_voice(5) end
  toggle_voice(5)
  params:set("v5_freq", 330)
  data = S.lib.scenes.capture_voice(5)
  toggle_voice(5)
  params:set("v5_freq", 110)
  context.clear_engine_calls()
  assert_equal(S.lib.scenes.apply_voice(5, data), true, "applied")
  assert_true(S.voices[5].active, "voice 5 runs")
  local on = context.calls_named("voiceOn")
  assert_equal(#on, 1, "one start")
  assert_near(on[1].args[2], 330, 1e-6, "with the data's freq")
end)

test("a recall applies a voice's built-in keys sorted, then its registered keys sorted", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  capture_scene(1)
  for voice = 1, S.constants.NUM_VOICES do
    local voice_data = S.scenes[1].data.voices[voice]
    local entries = S.lib.scenes.voice_entries(voice, voice_data)
    assert_equal(entries[1].key, "active", "voice " .. voice .. ": active first")
    assert_equal(entries[2].id, "v" .. voice .. "_source", "then the source")
    assert_equal(entries[3].id, "v" .. voice .. "_type", "then the type (3.8)")
    local expected = reference_voice_keys(S, voice, voice_data.values)
    assert_equal(#entries, #expected + 3, "voice " .. voice .. ": one entry a key")
    local position = {}
    for index, key in ipairs(expected) do
      assert_equal(entries[index + 3].id, "v" .. voice .. "_" .. key, "voice " .. voice .. " entry " .. (index + 3))
      assert_equal(entries[index + 3].voice, voice, "carries its voice")
      position[key] = index
    end
    assert_true(position.freq < position.freeze, "freq before freeze")
    assert_true(position.loop_length < position.loop_start, "loop_length before loop_start")
  end
  -- scene_entries: the blocks, the globals, then per voice its entries and its lock, then the patterns
  local entries = S.lib.scenes.scene_entries(S.scenes[1].data)
  local first_voice
  for index, entry in ipairs(entries) do
    if entry.key == "active" and entry.voice == 1 then first_voice = index; break end
  end
  local voice_one = S.lib.scenes.voice_entries(1, S.scenes[1].data.voices[1])
  for offset, entry in ipairs(voice_one) do
    assert_equal(entries[first_voice + offset - 1].id, entry.id, "scene_entries holds voice 1's entries")
  end
  assert_equal(entries[first_voice + #voice_one].key, "lock", "then voice 1's lock")
  assert_equal(entries[#entries].key, "pattern", "the patterns last")
end)

test("a recall that freezes a running synth voice takes its reference from the scene's freq", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  if not S.voices[1].active then toggle_voice(1) end
  params:set("v1_source", 1)
  params:set("v1_freq", 440)
  params:set("v1_freeze", 1)
  capture_scene(1)
  params:set("v1_freeze", 0)
  params:set("v1_freq", 220)
  recall_scene(1, 0)
  assert_equal(params:get("v1_freeze"), 1, "the recall froze voice 1")
  assert_near(S.lib.notes.freeze_reference(1), 69, 1e-9, "at the scene's A4, not the A3 it played")
end)

test("a scene voice missing a key, or holding another voice's synth key, is refused", function()
  load_strata()
  capture_scene(1)
  local S = local_value("S")
  local good = deep_copy(S.scenes[1])
  assert_true(validate_scene(good), "a captured scene is valid")
  local function refused(mutate, message)
    local candidate = deep_copy(good)
    mutate(candidate.data.voices)
    assert_true(not validate_scene(candidate), message)
  end
  refused(function(voices) voices[1].values.rq = nil end, "voice 1 without its rq")
  refused(function(voices) voices[3].values.loop_start = nil end, "voice 3 without a registered key")
  refused(function(voices) voices[2].values.rq = 0.5 end, "voice 2 (fm) holding the resonator's rq")
  refused(function(voices) voices[4].values.pan = 0 end, "voice 4 (sub) holding a pan")
  refused(function(voices) voices[5].values.grain_cloud = 1.5 end, "a fractional cloud")
  refused(function(voices) voices[5].values.grain_mode = 3 end, "a grain mode past the options")
  refused(function(voices) voices[6].values.solo = 0 end, "a solo (no scene key)")
  refused(function(voices) voices[6].params = {} end, "a 3.7 field beside values")
end)

-------------------------------------------------------------------------------
-- Scenes with the PSET (the groundwork before 3.8, design §6, rulings 34
-- and 35): <pset>.scenes.data beside every PSET, the live file's pset field
-------------------------------------------------------------------------------

-- A data folder name no other test of this run uses: a count, never
-- math.random (scramble_state seeds it, so a name drawn after it repeats)
local pset_folders = 0
local function fresh_name()
  pset_folders = pset_folders + 1
  return tostring(pset_folders)
end

-- A session of its own data folder (data_subdir), started
local function pset_session(subdir)
  local context = load_strata({ data_subdir = subdir or ("pset-scenes-" .. fresh_name()) })
  finish_startup(context)
  return context, local_value("S")
end

-- PSET n's path, its base (no .pset) and its scenes file
local function pset_files(context, n)
  local base = context.data_dir .. string.format("strata-%02d", n)
  return base .. ".pset", base, base .. ".scenes.data"
end

local function live_scenes_path(context) return context.data_dir .. "strata/scenes.data" end

local function lines_holding(context, text)
  local found = {}
  for _, line in ipairs(context.printed) do
    if line:find(text, 1, true) then found[#found + 1] = line end
  end
  return found
end

test("a PSET save writes its sixteen scenes beside it, an empty set too", function()
  local context, S = pset_session()
  local pset, base, side = pset_files(context, 1)
  params:write(pset)
  local written = S.lib.data_files.read(side)
  assert_equal(type(written), "table", "strata-01.scenes.data written")
  assert_equal(written.version, S.constants.SCENE_DATA_VERSION, "the build's format")
  assert_equal(#written.scenes, S.constants.NUM_SCENES, "sixteen slots")
  for slot = 1, S.constants.NUM_SCENES do assert_true(not written.scenes[slot].populated, "slot " .. slot .. " empty") end
  assert_equal(S.lib.data_files.read(live_scenes_path(context)).pset, base, "the live file names the PSET")
  assert_equal(S.scene_file.pset, base)
  -- a capture clears the mark at its write; the next PSET's save holds it and sets it
  scramble_state(4); S.lib.scenes.save(3)
  assert_equal(S.scene_file.pset, nil, "a capture: no PSET holds these scenes")
  assert_equal(S.lib.data_files.read(live_scenes_path(context)).pset, nil, "and the live file says so")
  local pset_2, base_2, side_2 = pset_files(context, 2)
  params:write(pset_2)
  local second = S.lib.data_files.read(side_2)
  assert_true(second.scenes[3].populated, "the PSET holds scene 3")
  assert_equal(S.lib.data_files.encode(second.scenes), S.lib.data_files.encode(S.scenes), "exactly the live scenes")
  assert_equal(S.lib.data_files.read(live_scenes_path(context)).pset, base_2, "the live file names PSET 2")
  -- a name clears it too
  S.lib.scenes.set_name(3, "dusk")
  assert_equal(S.lib.data_files.read(live_scenes_path(context)).pset, nil, "a name: cleared before the write")
end)

test("a PSET load replaces the live scenes, rewrites the live file and recalls nothing", function()
  for _, case in ipairs({ { current = 1, kept = true }, { current = 2, kept = false } }) do
    local context, S = pset_session()
    local pset_1, base_1, side_1 = pset_files(context, 1)
    local pset_2 = pset_files(context, 2)
    scramble_state(5); S.lib.scenes.save(1)
    params:write(pset_1)
    scramble_state(6); S.lib.scenes.save(2)
    params:write(pset_2)
    recall_scene(case.current, 0)
    assert_equal(S.current_scene, case.current, "scene " .. case.current .. " current")
    local takeovers = S.lib.scenes.takeovers()
    local recalls = 0
    local real_recall, real_instant = recall_scene, recall_scene_instant
    recall_scene = function(...) recalls = recalls + 1; return real_recall(...) end
    recall_scene_instant = function(...) recalls = recalls + 1; return real_instant(...) end
    local revision = S.lib.scenes.revision(1)
    params:read(pset_1)
    recall_scene, recall_scene_instant = real_recall, real_instant
    assert_equal(recalls, 0, "nothing recalled")
    assert_equal(S.lib.scenes.takeovers(), takeovers, "no recall started")
    assert_true(S.scenes[1].populated, "PSET 1's scene 1")
    assert_true(not S.scenes[2].populated, "and no scene 2: it was captured after PSET 1")
    assert_true(S.lib.scenes.revision(1) > revision, "every revision raised")
    assert_true(S.lib.scenes.playable(1) and not S.lib.scenes.playable(2), "the cache follows the new scenes")
    assert_equal(S.current_scene, case.kept and case.current or 0,
      "the current scene kept only when its slot holds the same: " .. case.current)
    local live = S.lib.data_files.read(live_scenes_path(context))
    assert_equal(S.lib.data_files.encode(live.scenes), S.lib.data_files.encode(S.lib.data_files.read(side_1).scenes),
      "the live file holds PSET 1's scenes")
    assert_equal(live.pset, base_1, "and names PSET 1")
    assert_true(not util.file_exists(live_scenes_path(context) .. ".bak"), "no backup: PSET 2 held the live scenes")
  end
end)

test("a PSET load ends a running transition, and the sequencer and the chain go on over the new scenes", function()
  -- PSET 1, made in a session of its own: scenes 3 and 4, the scene
  -- sequencer on (saved so, not started) over 4 slots, the chain over slots 1-4
  local _, S = pset_session()
  local shared = data_root .. "pset-shared-" .. fresh_name() .. "/"
  os.execute("mkdir -p '" .. shared .. "'")
  local pset_1 = shared .. "strata-01.pset"
  local function sequencer_settings()
    params:set("scene_sequence_length", 4); params:set("scene_duration", 2); params:set("scene_transition_time", 4)
    params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 4)
    params:set("seq_chain_bars", 1)
  end
  -- each scene's voice 1 plays one step of its own: the step is the slot
  local function mark(slot)
    for step = 1, S.constants.PATTERN_LENGTH do S.patterns[1][step] = step == slot and 15 or 0 end
  end
  scramble_state(7); mark(3); S.lib.scenes.save(3)
  scramble_state(8); mark(4); S.lib.scenes.save(4)
  sequencer_settings()
  params:set("scene_sequencer_enabled", 1, true)
  params:write(pset_1)
  -- the session the PSET is loaded in: scenes 1 and 2, a 4 s fade, the
  -- scene sequencer and the chain running
  local context
  context, S = pset_session()
  scramble_state(9); mark(1); S.lib.scenes.save(1)
  scramble_state(10); mark(2); S.lib.scenes.save(2)
  params:write((pset_files(context, 2)))  -- a PSET holds the live scenes: no backup at the load
  sequencer_settings()
  pattern_clock_start()
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(1, 0.001)
  assert_true(S.scene_transition_active, "a fade runs")
  local recalls, links = {}, {}
  local real_recall = recall_scene
  recall_scene = function(slot, ...)
    recalls[#recalls + 1] = slot
    return real_recall(slot, ...)
  end
  -- every pattern voice 1 is given (the chain's links, and the recalls'),
  -- by the step it plays
  local sequencer = S.lib.sequencer
  local real_replace = sequencer.replace_pattern
  sequencer.replace_pattern = function(voice_idx, pattern, ...)
    if voice_idx == 1 then
      for step = 1, S.constants.PATTERN_LENGTH do
        if pattern[step] > 0 then links[#links + 1] = step end
      end
    end
    return real_replace(voice_idx, pattern, ...)
  end
  params:read(pset_1)
  assert_true(not S.scene_transition_active, "the fade ended")
  assert_true(S.scene_sequencer_enabled, "the scene sequencer still runs")
  assert_equal(#recalls, 0, "the load recalls nothing")
  local next_slot = S.lib.scenes.sequencer_next_slot()
  assert_true(next_slot == 3 or next_slot == 4, "the sequencer's next slot is a new scene: " .. tostring(next_slot))
  context.clock.run_for(12, 0.001)
  recall_scene, sequencer.replace_pattern = real_recall, real_replace
  assert_true(#recalls > 0, "the sequencer went on")
  for index, slot in ipairs(recalls) do
    assert_true(slot == 3 or slot == 4, "recall " .. index .. " from the new scenes: " .. tostring(slot))
  end
  assert_true(#links > #recalls, "the chain linked too: " .. #links .. " patterns for " .. #recalls .. " recalls")
  for index, step in ipairs(links) do
    assert_true(step == 3 or step == 4, "pattern " .. index .. " from the new scenes: step " .. step)
  end
  pattern_clock_stop()
end)

test("a PSET delete removes its scenes file and the live file's mark", function()
  local context, S = pset_session()
  local pset_1, base_1, side_1 = pset_files(context, 1)
  local pset_2, _, side_2 = pset_files(context, 2)
  params:write(pset_2)
  params:write(pset_1)
  assert_equal(S.scene_file.pset, base_1, "PSET 1 holds the live scenes")
  params:delete(pset_2)
  assert_true(not util.file_exists(side_2), "PSET 2's scenes file deleted")
  assert_equal(S.scene_file.pset, base_1, "another PSET's delete keeps the mark")
  params:delete(pset_1)
  assert_true(not util.file_exists(side_1), "PSET 1's scenes file deleted")
  assert_equal(S.scene_file.pset, nil, "the mark cleared")
  assert_equal(S.lib.data_files.read(live_scenes_path(context)).pset, nil, "in the live file too")
end)

test("a PSET with no scenes file leaves the live scenes, with no backup and no line", function()
  local context, S = pset_session()
  local pset_1, _, side_1 = pset_files(context, 1)
  scramble_state(11); S.lib.scenes.save(1)
  params:write(pset_1)
  os.remove(side_1)  -- a PSET saved before scenes traveled with it
  scramble_state(12); S.lib.scenes.save(2)
  local before = S.lib.data_files.encode(S.scenes)
  local live_text = h.file_text(live_scenes_path(context))
  local printed = #context.printed
  params:read(pset_1)
  assert_equal(S.lib.data_files.encode(S.scenes), before, "the live scenes stay")
  assert_equal(h.file_text(live_scenes_path(context)), live_text, "the live file as it was")
  assert_true(not util.file_exists(live_scenes_path(context) .. ".bak"), "no backup")
  for index = printed + 1, #context.printed do
    assert_true(not context.printed[index]:find("scenes", 1, true), "no scenes line: " .. context.printed[index])
  end
end)

-- #859: a PSET without scenes read during a fade ends the fade, so its
-- later steps and its landing never put the scene's values back over the
-- PSET's sound (as a PSET with scenes already did, take_scenes)
test("a PSET with no scenes file read during a fade ends the fade: the PSET's sound stays", function()
  local context, S = pset_session()
  local pset_1, _, side_1 = pset_files(context, 1)
  params:set("v1_grain_size", 0.3)
  params:write(pset_1)
  os.remove(side_1)
  params:set("v1_grain_size", 0.1)
  capture_scene(1)
  params:set("v1_grain_size", 0.2)
  recall_scene(1, 20)
  context.clock.run_for(2)
  assert_true(S.scene_transition_active, "a fade runs")
  params:read(pset_1)
  assert_true(not S.scene_transition_active, "the read ended the fade")
  assert_equal(S.scene_transition_clock, nil, "and its clock")
  context.clock.run_for(25)
  assert_near(params:get("v1_grain_size"), 0.3, 1e-9, "the PSET's grain size stays")
end)

test("an unusable scenes file beside a PSET is set aside with one line and the live scenes stay", function()
  for _, case in ipairs({ "text", "format 8" }) do
    local context, S = pset_session()
    local pset_1, _, side_1 = pset_files(context, 1)
    scramble_state(13); S.lib.scenes.save(1)
    params:write(pset_1)
    local text = "return {"
    if case == "format 8" then
      local relabeled, count = h.file_text(side_1):gsub('%["version"%]=' .. S.constants.SCENE_DATA_VERSION .. ',',
        '["version"]=8,')
      assert_equal(count, 1, "the one version field")
      text = relabeled
    end
    h.write_text(side_1, text)
    scramble_state(14); S.lib.scenes.save(2)
    local before = S.lib.data_files.encode(S.scenes)
    local live_text = h.file_text(live_scenes_path(context))
    params:read(pset_1)
    assert_equal(h.file_text(side_1 .. ".bak"), text, case .. ": the side file set aside whole")
    local lines = lines_holding(context, "error loading scenes file " .. side_1 .. ": ")
    assert_equal(#lines, 1, case .. ": one line")
    assert_true(lines[1]:find("; kept as " .. side_1 .. ".bak", 1, true) ~= nil, lines[1])
    if case == "format 8" then
      assert_true(lines[1]:find(": not a version " .. S.constants.SCENE_DATA_VERSION .. " scenes file;", 1, true) ~= nil,
        "one version named: " .. lines[1])
    end
    assert_equal(S.lib.data_files.encode(S.scenes), before, case .. ": the live scenes stay")
    assert_equal(h.file_text(live_scenes_path(context)), live_text, case .. ": the live file as it was")
    assert_true(not util.file_exists(live_scenes_path(context) .. ".bak"), case .. ": no live backup")
  end
end)

test("a load over unsaved scenes makes one backup first; over none, none", function()
  local context, S = pset_session()
  local pset_1, base_1 = pset_files(context, 1)
  local live = live_scenes_path(context)
  scramble_state(15); S.lib.scenes.save(1)
  params:write(pset_1)
  scramble_state(16); S.lib.scenes.save(2)  -- after the PSET's save: in no PSET
  local unsaved_text = h.file_text(live)
  params:read(pset_1)
  assert_equal(h.file_text(live .. ".bak"), unsaved_text, "the scenes in no PSET kept as scenes.data.bak")
  assert_equal(#lines_holding(context, "scenes in no PSET kept as " .. live .. ".bak"), 1, "one line names it")
  assert_true(not S.scenes[2].populated, "then PSET 1's scenes")
  assert_equal(S.scene_file.pset, base_1)
  params:read(pset_1)
  assert_true(not util.file_exists(live .. ".bak.2"), "a second load with no edit makes no backup")
  assert_equal(#lines_holding(context, "scenes in no PSET kept as "), 1, "and no line")
end)

test("with no backup name free the live scenes stay", function()
  for _, case in ipairs({ "every name taken", "the card refuses" }) do
    local context, S = pset_session()
    local pset_1, _, side_1 = pset_files(context, 1)
    local live = live_scenes_path(context)
    scramble_state(17); S.lib.scenes.save(1)
    params:write(pset_1)
    scramble_state(18); S.lib.scenes.save(2)
    local why
    if case == "every name taken" then
      os.execute("mkdir -p '" .. live .. ".bak'")
      for number = 2, 9 do os.execute("mkdir -p '" .. live .. ".bak." .. number .. "'") end
      why = "every backup name is taken"
    else
      S.scenes[2].name = "later"  -- a change the load's write must carry, which fails
      os.execute("mkdir -p '" .. live .. ".part/inside'")  -- the .part is a folder: the write fails
    end
    local before = S.lib.data_files.encode(S.scenes)
    local live_text = h.file_text(live)
    params:read(pset_1)
    assert_equal(S.lib.data_files.encode(S.scenes), before, case .. ": the live scenes stay")
    assert_equal(h.file_text(live), live_text, case .. ": the live file's bytes unchanged")
    local lines = lines_holding(context, "scenes from " .. side_1
      .. " not loaded: the scenes in no PSET could not be kept (")
    assert_equal(#lines, 1, case .. ": one line")
    assert_true(lines[1]:find("); the live scenes stay", 1, true) ~= nil, lines[1])
    if why then assert_true(lines[1]:find("(" .. why .. ")", 1, true) ~= nil, lines[1]) end
  end
end)

test("a silent PSET read takes the PSET's scenes and prints no scenes loaded line", function()
  local context, S = pset_session()
  local pset_1, _, side_1 = pset_files(context, 1)
  scramble_state(29); S.lib.scenes.save(3)
  params:write(pset_1)
  local held = S.lib.data_files.encode(S.scenes)
  S.lib.scenes.set_name(3, "later")  -- then a PSET save of these: the load needs no backup
  params:write((pset_files(context, 2)))
  params:read(pset_1, true)
  assert_equal(S.lib.data_files.encode(S.scenes), held, "PSET 1's scenes taken")
  assert_equal(#lines_holding(context, "scenes loaded from " .. side_1), 0, "no scenes loaded line")
  params:read(pset_1)
  assert_equal(#lines_holding(context, "scenes loaded from " .. side_1), 1, "a read that is not silent prints it")
end)

test("a PSET's scenes refused in a session whose live file is blocked say so on the hint row too", function()
  local subdir = "pset-blocked-" .. fresh_name()
  local live_dir = data_root .. subdir .. "/strata/"
  -- every backup name is taken (by a folder): the newer file cannot be moved aside
  os.execute("mkdir -p '" .. live_dir .. "scenes.data.bak'")
  for number = 2, 9 do os.execute("mkdir -p '" .. live_dir .. "scenes.data.bak." .. number .. "'") end
  h.write_text(live_dir .. "scenes.data", tabutil_text({ version = 99, scenes = {} }))
  local context, S = pset_session(subdir)
  assert_equal(S.scene_autosave_blocked, true, "the live file blocks the autosave")
  local pset_1, _, side_1 = pset_files(context, 1)
  scramble_state(27); S.lib.scenes.save(1)
  params:write(pset_1)
  scramble_state(28); S.lib.scenes.save(2)  -- in no PSET, and not on disk
  local before = S.lib.data_files.encode(S.scenes)
  params:read(pset_1)
  assert_equal(S.lib.data_files.encode(S.scenes), before, "the live scenes stay")
  assert_equal(#lines_holding(context, "scenes from " .. side_1 .. " not loaded"), 1, "one console line")
  assert_equal(S.lib.ui_flash.text("hints"), S.lib.scenes.PSET_SCENES.refused, "and the hint row says so")
end)

test("an edit from an earlier session still counts; a PSET save then a new session makes no backup", function()
  local subdir = "pset-earlier-" .. fresh_name()
  local context, S = pset_session(subdir)
  local pset_1 = pset_files(context, 1)
  scramble_state(19); S.lib.scenes.save(1)
  params:write(pset_1)
  scramble_state(20); S.lib.scenes.save(2)
  cleanup()
  context, S = pset_session(subdir)
  assert_equal(S.scene_file.pset, nil, "read back: no PSET holds them")
  params:read(pset_1)
  assert_true(util.file_exists(live_scenes_path(context) .. ".bak"), "one backup")
  assert_true(not util.file_exists(live_scenes_path(context) .. ".bak.2"), "only one")
  -- conversely: a PSET save, then a new session
  subdir = "pset-saved-" .. fresh_name()
  context, S = pset_session(subdir)
  local base_1
  pset_1, base_1 = pset_files(context, 1)
  scramble_state(21); S.lib.scenes.save(1)
  params:write(pset_1)
  cleanup()
  context, S = pset_session(subdir)
  assert_equal(S.scene_file.pset, base_1, "read back: PSET 1 holds them")
  params:read(pset_1)
  assert_true(not util.file_exists(live_scenes_path(context) .. ".bak"), "no backup")
end)

-- #766: the mark is trusted only while the PSET it names still holds the
-- live scenes (its scenes file there, encoding as S.scenes)
test("a mark whose PSET lost its scenes file counts as no PSET: the next load backs the live scenes up (#766)", function()
  local subdir = "pset-stale-" .. fresh_name()
  local context, S = pset_session(subdir)
  local pset_1, base_1, side_1 = pset_files(context, 1)
  local pset_2 = pset_files(context, 2)
  params:write(pset_2)  -- PSET 2: sixteen empty slots
  scramble_state(22); S.lib.scenes.save(1)
  params:write(pset_1)
  assert_equal(S.scene_file.pset, base_1, "PSET 1 marked")
  os.remove(side_1)  -- deleted in maiden, or the PSET copied without it
  cleanup()
  context, S = pset_session(subdir)
  assert_equal(S.scene_file.pset, base_1, "the mark read back")
  local live = live_scenes_path(context)
  params:read(pset_2)
  assert_true(util.file_exists(live .. ".bak"), "the live scenes kept as scenes.data.bak")
  local backup = S.lib.data_files.read(live .. ".bak")
  assert_true(type(backup) == "table" and backup.scenes[1].populated, "the backup holds scene 1")
  assert_equal(backup.pset, nil, "and names no PSET")
  assert_equal(#lines_holding(context, "scenes in no PSET kept as " .. live .. ".bak"), 1, "one line names it")
  assert_true(not S.scenes[1].populated, "then PSET 2's scenes")
end)

test("loading the marked PSET with its scenes file missing or set aside clears the mark and keeps the live scenes (#766)", function()
  for _, case in ipairs({ "missing", "unusable" }) do
    local context, S = pset_session()
    local pset_1, base_1, side_1 = pset_files(context, 1)
    scramble_state(23); S.lib.scenes.save(1)
    params:write(pset_1)
    assert_equal(S.scene_file.pset, base_1, case .. ": PSET 1 marked")
    if case == "missing" then os.remove(side_1) else h.write_text(side_1, "return {") end
    local before = S.lib.data_files.encode(S.scenes)
    params:read(pset_1)
    assert_equal(S.scene_file.pset, nil, case .. ": the mark cleared")
    assert_equal(S.lib.data_files.read(live_scenes_path(context)).pset, nil, case .. ": in the live file too")
    assert_equal(S.lib.data_files.encode(S.scenes), before, case .. ": the live scenes stay")
    assert_true(not util.file_exists(live_scenes_path(context) .. ".bak"), case .. ": no live backup")
  end
end)

test("a mark whose PSET holds other scenes than the live ones counts as no PSET (#766)", function()
  local context, S = pset_session()
  local pset_1, base_1, side_1 = pset_files(context, 1)
  local pset_2 = pset_files(context, 2)
  params:write(pset_2)  -- PSET 2: sixteen empty slots
  scramble_state(24); S.lib.scenes.save(1)
  params:write(pset_1)
  local older = h.file_text(side_1)  -- PSET 1 holding scene 1 alone
  scramble_state(25); S.lib.scenes.save(2)
  params:write(pset_1)
  assert_equal(S.scene_file.pset, base_1, "PSET 1 marked, holding scenes 1 and 2")
  h.write_text(side_1, older)  -- an older copy of PSET 1's scenes put back
  local live = live_scenes_path(context)
  params:read(pset_2)
  local backup = S.lib.data_files.read(live .. ".bak")
  assert_true(type(backup) == "table" and backup.scenes[2].populated, "the live scenes (scene 2 too) kept")
  assert_true(not S.scenes[1].populated and not S.scenes[2].populated, "then PSET 2's scenes")
end)

test("a mark whose PSET still holds the live scenes is trusted across sessions: no backup (#766)", function()
  local subdir = "pset-trusted-" .. fresh_name()
  local context, S = pset_session(subdir)
  local pset_1, base_1 = pset_files(context, 1)
  local pset_2 = pset_files(context, 2)
  params:write(pset_2)
  scramble_state(26); S.lib.scenes.save(1)
  params:write(pset_1)
  cleanup()
  context, S = pset_session(subdir)
  assert_equal(S.scene_file.pset, base_1, "the mark read back")
  params:read(pset_2)
  assert_true(not util.file_exists(live_scenes_path(context) .. ".bak"), "no backup: PSET 1 holds the live scenes")
  assert_true(not S.scenes[1].populated, "PSET 2's scenes")
end)

-- #799 (fixed by 1a; pinned by 1c): a format 10 file of a build before a
-- package added a voice scene key (3.8's 1c added six) loads with the key
-- filled, and its PSET still counts as holding the live scenes: the
-- mark's comparison fills the PSET's scenes as a load does, so a load of
-- another PSET backs nothing up
test("a format 10 scenes file lacking a later key loads, the key filled, and its PSET still holds it: no backup (#799)", function()
  local subdir = "pset-later-key-" .. fresh_name()
  local context, S = pset_session(subdir)
  local pset_1, base_1, side_1 = pset_files(context, 1)
  local pset_2 = pset_files(context, 2)
  params:write(pset_2)
  scramble_state(27); S.lib.scenes.save(1)
  params:write(pset_1)
  -- both files as a build before grain_prob existed wrote them
  local stripped = 0
  for _, path in ipairs({ live_scenes_path(context), side_1 }) do
    local file = S.lib.data_files.read(path)
    for _, scene in ipairs(file.scenes) do
      for _, voice in ipairs(scene.data and scene.data.voices or {}) do
        if voice.values.grain_prob ~= nil then stripped = stripped + 1 end
        voice.values.grain_prob = nil
      end
    end
    S.lib.data_files.write(path, file)
  end
  assert_true(stripped >= 2 * S.constants.NUM_VOICES, "grain_prob taken out of every voice of both files (" .. stripped .. ")")
  cleanup()
  context, S = pset_session(subdir)
  assert_equal(S.scene_file.problem, nil, "the scenes file loads")
  assert_true(S.scenes[1].populated, "scene 1 with it")
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(S.scenes[1].data.voices[voice].values.grain_prob, S.lib.grain.GRAIN.prob_default,
      "voice " .. voice .. "'s grain_prob filled with its default")
  end
  assert_equal(S.scene_file.pset, base_1, "the mark read back")
  params:read(pset_2)
  assert_true(not util.file_exists(live_scenes_path(context) .. ".bak"), "no backup: PSET 1 holds the live scenes")
  assert_true(not S.scenes[1].populated, "PSET 2's scenes")
end)

test("the live file's pset field is no scene", function()
  local context, S = pset_session()
  for slot = 1, S.constants.NUM_SCENES do scramble_state(slot); S.lib.scenes.save(slot) end
  local scenes = S.lib.data_files.read(live_scenes_path(context)).scenes
  local version = S.constants.SCENE_DATA_VERSION
  for _, case in ipairs({ { pset = "x", reads = "x" }, { pset = 5, reads = nil } }) do
    local subdir = "pset-field-" .. fresh_name()
    local dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. dir .. "'")
    assert_true(S.lib.data_files.write(dir .. "scenes.data", { version = version, scenes = scenes, pset = case.pset }))
    local _, loaded = pset_session(subdir)
    for slot = 1, loaded.constants.NUM_SCENES do
      assert_true(loaded.scenes[slot].populated, "pset " .. tostring(case.pset) .. ": scene " .. slot .. " loads")
    end
    assert_equal(loaded.scene_file.problem, nil, "the file is fine")
    assert_equal(loaded.scene_file.pset, case.reads, "pset " .. tostring(case.pset) .. " reads as " .. tostring(case.reads))
  end
end)

---------------------------------------------------------------------------
-- 3.8 (package 0d): format 10, a scene voice's type
---------------------------------------------------------------------------

local function type_index(S, key) return S.lib.types.record(key).index end

test("capture_voice holds the type and only its keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local data = S.lib.scenes.capture_voice(1)
  assert_equal(data.type, "resonator", "voice 1's type")
  assert_true(data.values.rq ~= nil, "rq in")
  assert_equal(data.values.ratio, nil, "ratio out")
  params:set("v1_type", type_index(S, "fm"))
  data = S.lib.scenes.capture_voice(1)
  assert_equal(data.type, "fm", "after the change: fm")
  assert_true(data.values.ratio ~= nil, "ratio in")
  assert_equal(data.values.rq, nil, "rq out")
end)

test("a scene's synth keys are checked against its own type", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("v1_type", type_index(S, "fm"))
  capture_scene(1)
  params:set("v1_type", type_index(S, "resonator"))
  assert_true(validate_scene(S.scenes[1]), "a scene of fm with fm's keys is valid while voice 1 is resonator")
  local bad = deep_copy(S.scenes[1])
  bad.data.voices[1].values.rq = 0.5
  S.scenes[2] = bad
  assert_true(not validate_scene(S.scenes[2]), "fm holding rq is refused")
  local untyped = deep_copy(S.scenes[1])
  untyped.data.voices[1].type = nil
  untyped.data.voices[1].values.ratio, untyped.data.voices[1].values.index = nil, nil
  untyped.data.voices[1].values.modFreq = nil
  untyped.data.voices[1].values.rq, untyped.data.voices[1].values.noise = 0.2, 0.3
  untyped.data.voices[1].values.mod1, untyped.data.voices[1].values.mod2 = 0.2, 0.3
  fill_scene(untyped)
  assert_equal(untyped.data.voices[1].type, "resonator", "a missing type is the voice's default")
  S.scenes[3] = untyped
  assert_true(validate_scene(S.scenes[3]), "and the filled scene is valid")
  local typo = deep_copy(S.scenes[1])
  typo.data.voices[1].type = 7
  S.scenes[4] = typo
  assert_true(not validate_scene(S.scenes[4]), "a type that is no key string is refused")
end)

test("a scene of a type this build lacks keeps its keys and leaves the voice's type", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  capture_scene(1)
  local scene = deep_copy(S.scenes[1])
  local voice = scene.data.voices[1]
  voice.type = "glass"
  for _, key in ipairs(S.lib.types.record("resonator").param_order) do
    if key ~= "freq" and key ~= "amp" and key ~= "pan" then voice.values[key] = nil end
  end
  voice.values.shimmer = 0.5
  voice.values.freq = 333          -- a synth key: kept, never applied
  voice.values.grain_size = 0.33   -- a shared key
  S.scenes[5] = scene
  assert_true(validate_scene(S.scenes[5]), "valid: the shared keys and any finite number")
  params:set("v1_type", type_index(S, "pulse"))
  context.clear_engine_calls()
  recall_scene(5)
  assert_equal(params:get("v1_type"), type_index(S, "pulse"), "the voice keeps its type")
  assert_near(params:get("v1_grain_size"), 0.33, 1e-6, "the shared keys apply")
  assert_true(math.abs(params:get("v1_freq") - 333) > 1, "the lacking type's synth keys do not")
  assert_equal(#context.calls_named("setVoiceType"), 0, "no type is sent")
  local dir = context.data_dir .. "strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  assert_true(save_scenes_to_disk(), "saved")
  local written = S.lib.data_files.read(dir .. "scenes.data").scenes[5].data.voices[1]
  assert_equal(written.type, "glass", "a save keeps glass")
  assert_equal(written.values.shimmer, 0.5, "and its own key")
  local nan = deep_copy(scene)
  nan.data.voices[1].values.shimmer = 0 / 0
  S.scenes[6] = nan
  assert_true(not validate_scene(S.scenes[6]), "but not a value that is no finite number")
end)

test("a recall applies the type before the keys, one sync after", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  params:set("v1_type", type_index(S, "fm"))
  params:set("v1_ratio", 3)
  capture_scene(1)
  params:set("v1_type", type_index(S, "resonator"))
  local syncs = {}
  local sync = sync_voice_values_to_engine
  sync_voice_values_to_engine = function(voice)
    syncs[#syncs + 1] = voice
    return sync(voice)
  end
  context.clear_engine_calls()
  local recalled, recall_error = pcall(recall_scene, 1)
  sync_voice_values_to_engine = sync
  assert_true(recalled, tostring(recall_error))
  local type_at, first_fm
  for index, call in ipairs(context.engine_calls) do
    if call.name == "setVoiceType" and call.args[1] == 0 then type_at = type_at or index end
    if call.name == "setVoiceParam" and call.args[1] == 0 and (call.args[2] == "ratio" or call.args[2] == "index") then
      first_fm = first_fm or index
    end
  end
  assert_true(type_at ~= nil and first_fm ~= nil and type_at < first_fm, "setVoiceType(0, 1) before any fm send")
  assert_equal(context.engine_calls[type_at].args[2], type_index(S, "fm") - 1, "fm")
  local voice_1 = 0
  for _, voice in ipairs(syncs) do if voice == 1 then voice_1 = voice_1 + 1 end end
  assert_equal(voice_1, 1, "one sync of voice 1")
  assert_equal(params:get("v1_ratio"), 3, "the scene's ratio")
end)

test("a fade of one type fades the synth keys; across types the type and its keys land at the end", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("v1_rq", 0.2); params:set("v1_grain_size", 0.1)
  capture_scene(1)
  params:set("v1_rq", 0.8); params:set("v1_grain_size", 0.3)
  capture_scene(2)
  recall_scene(1)
  recall_scene(2, 1)
  context.clock.run_for(0.5)
  local rq = params:get("v1_rq")
  assert_true(rq > 0.2 and rq < 0.8, "one type: rq moves mid-fade (" .. rq .. ")")
  context.clock.run_for(1)
  assert_near(params:get("v1_rq"), 0.8, 1e-9, "and lands")
  -- across types
  params:set("v1_type", type_index(S, "fm")); params:set("v1_ratio", 4); params:set("v1_grain_size", 0.4)
  capture_scene(3)
  recall_scene(1)
  assert_equal(params:get("v1_type"), type_index(S, "resonator"))
  params:set("v1_ratio", 1.5)  -- the fade's start: fm's ratio (hidden on resonator) away from the scene's 4
  local ratio = params:get("v1_ratio")
  recall_scene(3, 1)
  context.clock.run_for(0.5)
  assert_equal(params:get("v1_type"), type_index(S, "resonator"), "mid-fade: the type unchanged")
  assert_equal(params:get("v1_ratio"), ratio, "and fm's ratio unchanged, no fade toward 4")
  local size = params:get("v1_grain_size")
  assert_true(size > 0.1 and size < 0.4, "the shared grain size moves (" .. size .. ")")
  context.clock.run_for(1)
  assert_equal(S.lib.types.of(1).key, "fm", "at the end: fm")
  assert_equal(params:get("v1_ratio"), 4, "with the scene's ratio")
end)

test("apply_voice applies another type's data, type first", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("v2_type", type_index(S, "karplus")); params:set("v2_decay", 7)
  local data = S.lib.scenes.capture_voice(2)
  params:set("v2_type", type_index(S, "fm"))
  context.clear_engine_calls()
  assert_equal(S.lib.scenes.apply_voice(2, data), true, "applied")
  assert_equal(S.lib.types.of(2).key, "karplus", "the data's type")
  assert_near(params:get("v2_decay"), 7, 1e-9, "its keys")
  assert_equal(encode(S.lib.scenes.capture_voice(2)), encode(data), "voice 2 is the data again")
  local wrong = deep_copy(data)
  wrong.values.ratio = 2
  assert_equal(S.lib.scenes.apply_voice(2, wrong), false, "another type's key is refused")
end)

-- Review Focus 2 (3.8 plan): a recall that changes the type of a frozen
-- voice, a voice holding a chord and a buffer voice
test("a recall changes the type of a frozen voice, a voice holding a chord and a buffer voice", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice = 1, 3 do
    if not S.voices[voice].active then toggle_voice(voice) end
  end
  params:set("v3_source", S.constants.SOURCE_SYNTH + 1)  -- buffer 1
  -- voice 1 frozen on its synth (the scene holds it frozen too); each voice
  -- captured on another type
  params:set("v1_freeze", 1)
  params:set("v1_type", type_index(S, "pulse"))
  params:set("v2_type", type_index(S, "ring"))
  params:set("v3_type", type_index(S, "sub"))
  capture_scene(1)
  params:set("v1_type", type_index(S, "resonator"))
  params:set("v2_type", type_index(S, "fm"))
  params:set("v3_type", type_index(S, "folder"))
  for _, note in ipairs({ 60, 64, 67, 71 }) do
    S.lib.notes.play(2, { owner = "midi", key = note, pitch = note, velocity = 1, park = true, set_own = function() end })
  end
  local held = S.lib.notes.held(2)
  assert_equal(held, 4, "voice 2 holds its chord: its own note and three extra (#839)")
  assert_equal(S.lib.notes.pool_used(), 3, "exactly three extra notes")
  context.clear_engine_calls()
  local recalled, recall_error = pcall(recall_scene, 1)
  assert_true(recalled, "the recall raises nothing: " .. tostring(recall_error))
  assert_equal(S.lib.types.of(1).key, "pulse", "voice 1 on the scene's type")
  assert_equal(S.lib.types.of(2).key, "ring", "voice 2 too")
  assert_equal(S.lib.types.of(3).key, "sub", "voice 3 too")
  for voice = 1, 3 do
    local count = 0
    for _, call in ipairs(context.calls_named("setVoiceType")) do
      if call.args[1] == voice - 1 then count = count + 1 end
    end
    assert_equal(count, 1, "one setVoiceType for voice " .. voice)
  end
  assert_equal(params:get("v1_freeze"), 1, "voice 1 still frozen")
  assert_equal(S.lib.notes.held(2), held, "voice 2's notes still held by S.lib.notes")
  assert_equal(S.voices[3].source, S.constants.SOURCE_SYNTH + 1, "voice 3 keeps its buffer")
end)

test("the scenes' PSET hook runs before morph's", function()
  local _, S = pset_session()
  local index = {}
  for position, hook in ipairs(S.registry.pset_hooks) do index[hook.name] = position end
  assert_true(index.scenes ~= nil, "scenes registers a PSET hook")
  assert_true(index.morph ~= nil and index.scenes < index.morph, "before morph's")
end)

-- 3.8 (package 1d): a voice's source ranges over the seventeen options
test("a scene with source 17 is valid; one with 18 is set aside", function()
  local context = load_strata(); finish_startup(context)
  local C = local_value("S").constants
  assert_equal(#C.SOURCE_OPTIONS, C.SOURCE_VOICE_FIRST + C.NUM_VOICES - 1, "the last option is voice 7's ring")
  capture_scene(1)
  local scene = deep_copy(local_value("scenes")[1])
  scene.data.voices[2].source = #C.SOURCE_OPTIONS
  assert_true(validate_scene(scene), "source " .. #C.SOURCE_OPTIONS .. " (voice 7's ring) is valid")
  scene.data.voices[2].source = #C.SOURCE_OPTIONS + 1
  assert_true(not validate_scene(scene), "source " .. (#C.SOURCE_OPTIONS + 1) .. " is set aside")
end)

-- 3.8 (4d, ruling 49): whether a scenes file was found at this start, for
-- the factory's first run
test("the scenes start step records its outcome", function()
  local context = load_strata({ data_subdir = "outcome-" .. fresh_name() })
  local S = local_value("S")
  assert_equal(S.scene_file.start_outcome, "missing", "a fresh data folder: missing")
  capture_scene(1)
  cleanup()
  context = load_strata({ data_subdir = context.data_dir:match("([^/]+)/$") })
  S = local_value("S")
  assert_equal(S.scene_file.start_outcome, "loaded", "a saved scenes file: loaded")
  local dir = context.data_dir .. "strata/"
  write_text(dir .. "scenes.data", "garbage")
  context = load_strata({ data_subdir = context.data_dir:match("([^/]+)/$") })
  assert_equal(local_value("S").scene_file.start_outcome, "unreadable", "an unreadable file: unreadable")
  write_text(dir .. "scenes.data", tabutil_text({ version = 8, scenes = {} }))
  load_strata({ data_subdir = context.data_dir:match("([^/]+)/$") })
  assert_equal(local_value("S").scene_file.start_outcome, "older", "a 3.7 file: older")
end)

test("a read-only scenes load neither backs up nor marks a PSET", function()
  local context, S = pset_session()
  scramble_state(3); S.lib.scenes.save(4)
  local set_scenes = deep_copy(S.scenes)
  local base = context.data_dir .. "set"
  assert_true(S.lib.data_files.write(base .. S.lib.scenes.PSET_SCENES.side_suffix,
    { version = S.constants.SCENE_DATA_VERSION, scenes = set_scenes }))
  scramble_state(8); S.lib.scenes.save(1)
  assert_equal(S.scene_file.pset, nil, "the live scenes are in no PSET")
  local kept = S.lib.scenes.back_up_live()
  assert_equal(kept, true, "the explicit backup is made")
  assert_true(util.file_exists(live_scenes_path(context) .. ".bak"), "as scenes.data.bak")
  local hook
  for _, record in ipairs(S.registry.pset_hooks) do
    if record.name == "scenes" then hook = record end
  end
  S.lib.side_files.read_only(function() hook.read(base, nil, base .. ".params", false) end)
  assert_equal(S.lib.data_files.encode(S.scenes), S.lib.data_files.encode(set_scenes), "the set's scenes are taken")
  assert_equal(S.scene_file.pset, nil, "no PSET is marked as holding them")
  assert_true(not util.file_exists(live_scenes_path(context) .. ".bak.2"), "one .bak, the explicit one's")
  local live = S.lib.data_files.read(live_scenes_path(context))
  assert_equal(S.lib.data_files.encode(live.scenes), S.lib.data_files.encode(set_scenes), "the live file holds them")
  assert_equal(live.pset, nil, "and names no PSET")
end)

-- #977: a scene holds a control param's get(), its controlspec's map of the
-- raw value, and norns' Control:set runs the action on any change of the
-- raw value; an exponential spec's unmap of that value can land an ulp from
-- the raw value in force, so a recall of the value in force sent it again,
-- an ulp off. A recall compares the value with the param's get() first
test("a recall after a hand set of an exp freq sends nothing for it (#977)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  params:set("v1_freq", 440)
  local held = params:get("v1_freq")
  local spec = params:lookup_param("v1_freq").controlspec
  assert_true(spec:map(spec:unmap(held)) ~= held, "440 Hz is a value the freq spec does not round-trip")
  capture_scene(4)
  context.clear_engine_calls()
  recall_scene(4, 0)
  for _, call in ipairs(context.engine_calls) do
    assert_true(not (call.name == "setVoiceParam" and call.args[1] == 0 and call.args[2] == "freq"),
      "no freq sent: " .. tostring(call.args[3]))
    assert_true(not (call.name == "setGrainParam" and call.args[1] == 0 and call.args[2] == "scaleNote"),
      "no scaleNote sent: " .. tostring(call.args[3]))
  end
  assert_equal(params:get("v1_freq"), held, "the freq is the one the hand set left")
end)

test("the first recall of the state in force sends nothing (#977)", function()
  local context = load_strata(); finish_startup(context)
  capture_scene(3)
  context.clear_engine_calls()
  recall_scene(3, 0)
  local sent = {}
  for _, call in ipairs(context.engine_calls) do sent[#sent + 1] = call.name .. "(" .. tostring(call.args[2]) .. ")" end
  assert_equal(#context.engine_calls, 0, "nothing sent, no attackTime or releaseTime either: " .. table.concat(sent, ", "))
  -- a fade to it sets each value through the same path: nothing either
  recall_scene(3, 1)
  context.clock.run_for(1.5, 0.01)
  sent = {}
  for _, call in ipairs(context.engine_calls) do sent[#sent + 1] = call.name .. "(" .. tostring(call.args[2]) .. ")" end
  assert_equal(#context.engine_calls, 0, "a fade to the state in force sends nothing: " .. table.concat(sent, ", "))
end)

test("six rounds of capture and recall leave attackTime and releaseTime where they were (#977)", function()
  local context = load_strata(); finish_startup(context)
  local attack, release = params:get("v1_attack"), params:get("v1_release")
  assert_near(release, 8, 1e-9, "voice 1's release is 8 s")
  local sends = 0
  for _ = 1, 6 do
    capture_scene(3)
    context.clear_engine_calls()
    recall_scene(3, 0)
    sends = sends + #context.engine_calls
  end
  assert_equal(string.format("%.17g", params:get("v1_attack")), string.format("%.17g", attack), "the attack has not crept")
  assert_equal(string.format("%.17g", params:get("v1_release")), string.format("%.17g", release),
    "the release 8 stays 8, exactly")
  assert_equal(sends, 0, "no round sent anything")
end)

-- #910, #917: a recall's lock goes through S.lib.engine_sync.set_locked, so
-- its hooks are contained: one that raises is printed once, the next still
-- runs and the recall applies the entries after the lock (the next voice's
-- values, the patterns)
test("a recall's lock change runs the hooks contained (#910)", function()
  local heard = {}
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    S.register_lock_change(function() error("scene lock hook boom") end)
    S.register_lock_change(function(voice_idx, locked) heard[#heard + 1] = voice_idx .. ":" .. tostring(locked) end)
  end })
  finish_startup(context)
  local S = local_value("S")
  local NUM_VOICES = S.constants.NUM_VOICES
  params:set("v3_grain_size", 0.4)
  toggle_pattern_step(NUM_VOICES, 5)
  local captured_step = local_value("patterns")[NUM_VOICES][5]
  S.locked[2] = true  -- the scene holds voice 2 locked; no hook runs here
  capture_scene(1)
  S.locked[2] = false
  params:set("v3_grain_size", 0.1)
  toggle_pattern_step(NUM_VOICES, 5)
  context.take_script_errors()
  heard = {}
  local recalled, recall_error = pcall(recall_scene, 1, 0)
  assert_true(recalled, "the recall completes: " .. tostring(recall_error))
  assert_true(S.locked[2] == true, "the scene's lock is set")
  assert_equal(table.concat(heard, " "), "2:true", "the next hook runs, once")
  assert_near(params:get("v3_grain_size"), 0.4, 1e-6, "the next voice's values are applied")
  assert_equal(local_value("patterns")[NUM_VOICES][5], captured_step, "the patterns are applied")
  local errors = context.take_script_errors()
  assert_equal(#errors, 1, "one line printed: " .. table.concat(errors, "\n"))
  assert_true(errors[1]:find("strata: lock change hook failed: ", 1, true) == 1, errors[1])
  assert_true(errors[1]:find("scene lock hook boom", 1, true) ~= nil, errors[1])
end)

end

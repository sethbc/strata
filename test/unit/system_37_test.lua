-- test/unit/system_37_test.lua
-- Every 3.7 feature at once (3.7 design §12, the whole-system test; plan
-- Task 3a, Review Focus 2): the real modules, driven through params, the
-- clocks, a grid and the data folder, read through the engine calls the
-- stub records. A fresh Strata sends what 3.6.0 sent but the values every
-- voice sync now carries (the fixture test/fixtures/3.6.0-start-calls.lua);
-- 3.6's files load as saved and the ones below the floors are set aside; a
-- sliced loop plays under a reversed pattern with conditions and fill,
-- follow, an envelope, a random sequence and a chain; and every way out of
-- that state leaves nothing held. The test only observes: no double stands
-- in for a module, and a failure here is a finding in the module it names.
-- Run alone: lua test/run.lua system_37

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local write_text, file_text, tabutil_text, deep_copy = h.write_text, h.file_text, h.tabutil_text, h.deep_copy

-- The values the tests use (the brief's, verbatim where it gives them)
local SYSTEM = {
  seed = 37,
  -- the sliced loop: slot 1, 8 s at 48 kHz, equal parts, 8 of them, a file tempo of 120
  slot_seconds = 8, rate = 48000, slices = 8, file_tempo = 120,
  tempo = 90, bars = 4, bar_beats = 4, factor = 0.75,  -- 90 / 120
  options = {v1_slices = "overlap", v1_scan_mode = "one shot", v1_follow = "stretch", v1_seq_direction = "reverse"},
  cond_step = 3, cond = "1:2", fill_step = 5,
  routings = {envelope = 1, sequence = 2}, depth = 50,
  chain = {scenes = 2, bars = 1, chances = {0, 0, 100}},
  -- fill held over the third bar (passes 5 and 6), pressed and released a
  -- little before the bar's edges so no step falls on the press
  fill_margin = 0.05,
  grid_port = 1, fill_key = {x = 9, y = 8},
}

-- The commands a 3.6 Strata never sent, and the grain keys every voice sync carries since 3.7
local NEW_COMMANDS = {"noteRegion", "syncScan", "setSlotGain", "analyzeBuffer", "setFastEnv", "stopFastEnv"}
local NEW_SYNC_KEYS = {scanMode = 0, followRate = 1, rootNote = 60, regionStart = 0, regionLength = 0}

-- A call as the fixture writes it: name(args), numbers "%.9g", strings "%q"
local function call_line(call)
  local parts = {}
  for index = 1, #call.args do
    local value = call.args[index]
    parts[index] = type(value) == "number" and string.format("%.9g", value) or string.format("%q", tostring(value))
  end
  return call.name .. "(" .. table.concat(parts, ", ") .. ")"
end

-- Each run of consecutive setVoiceParam lines of one voice sorted (the
-- order a pairs() loop gives them changes from run to run); nothing else moves
local function canonical(lines)
  local out, run, run_key = {}, {}, nil
  local function flush()
    table.sort(run)
    for _, line in ipairs(run) do out[#out + 1] = line end
    run, run_key = {}, nil
  end
  for _, line in ipairs(lines) do
    local key = line:match("^(setVoiceParam%(%d+),")
    if key and key == run_key then
      run[#run + 1] = line
    else
      flush()
      if key then run_key, run[1] = key, line else out[#out + 1] = line end
    end
  end
  flush()
  return out
end

local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

local function option_index(id, text)
  for index, name in ipairs(params:lookup_param(id).options) do
    if name == text then return index end
  end
  error("no option " .. text .. " for " .. id, 2)
end

---------------------------------------------------------------------------
-- 1. Nothing new by default
---------------------------------------------------------------------------

test("a fresh Strata has every 3.7 feature off", function()
  math.randomseed(SYSTEM.seed)  -- a fresh load draws the random sequences' values (1g)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local NUM_VOICES = S.constants.NUM_VOICES
  for voice = 1, NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_buf_scan"), 0, "voice " .. voice .. "'s scan at 0, as recorded")
    assert_equal(params:string("v" .. voice .. "_scan_mode"), "wrap", "voice " .. voice .. ": scan mode wrap")
    assert_equal(params:string("v" .. voice .. "_follow"), "off", "follow off")
    assert_equal(params:string("v" .. voice .. "_slices"), "off", "slices off")
    assert_equal(params:string("v" .. voice .. "_seq_direction"), "forward", "forward")
    assert_equal(params:get("v" .. voice .. "_seq_misstep"), 0, "no misstep")
  end
  for _, set in ipairs({"scene_chance", "seq_chain"}) do
    assert_equal(params:get(set .. "_next") .. " " .. params:get(set .. "_previous") .. " " .. params:get(set .. "_random"),
      "100 0 0", set .. ": 100, 0, 0")
  end
  assert_equal(params:get("delay_sync"), 0, "the delay is not synced")
  assert_equal(params:get("delay_pingpong"), 0, "no ping-pong")
  assert_equal(params:get("seq_fill"), 0, "fill off")
  for slot = 1, S.constants.NUM_BUFFERS do assert_equal(S.lib.samples.settings(slot), nil, "slot " .. slot .. ": no settings") end
  for voice = 1, NUM_VOICES do
    if not S.voices[voice].active then toggle_voice(voice) end
  end
  for voice = 1, NUM_VOICES do
    if S.voices[voice].active then toggle_voice(voice) end
  end
  -- every call since the load, the new sync keys and setDelay's fourth value taken out
  local lines, removed = {}, {}
  for _, call in ipairs(context.engine_calls) do
    for _, name in ipairs(NEW_COMMANDS) do assert_true(call.name ~= name, "no " .. name .. " is sent") end
    local key = call.name == "setGrainParam" and call.args[2]
    if key and NEW_SYNC_KEYS[key] ~= nil then
      assert_equal(call.args[3], NEW_SYNC_KEYS[key], key .. " at its 3.6 value")
      removed[key] = (removed[key] or 0) + 1
    elseif call.name == "setDelay" then
      assert_equal(#call.args, 4, "setDelay has four values")
      assert_equal(call.args[4], 0, "its fourth, ping-pong, at 0")
      lines[#lines + 1] = call_line({name = call.name, args = {call.args[1], call.args[2], call.args[3]}})
    else
      lines[#lines + 1] = call_line(call)
    end
  end
  for key in pairs(NEW_SYNC_KEYS) do
    assert_equal(removed[key], NUM_VOICES, key .. ": once in each voice's start")
  end
  local fixture = dofile(h.repo_root .. "/test/fixtures/3.6.0-start-calls.lua")
  local expected, actual = canonical(fixture), canonical(lines)
  for index = 1, math.max(#expected, #actual) do
    if expected[index] ~= actual[index] then
      h.fail("call " .. index .. ": 3.6.0 sent " .. tostring(expected[index]) .. ", this build " .. tostring(actual[index]))
    end
  end
  assert_equal(#actual, #expected, "as many calls as 3.6.0")
end)

---------------------------------------------------------------------------
-- 2 and 3. Old files
---------------------------------------------------------------------------

-- What 3.7 added to the scenes and the PSETs, measured from the tag v3.6.0
-- (its params and a captured scene's keys against this build's): a 3.6
-- file is this build's with these taken out, and the LFO destinations as
-- 3.6 kept them (an index under strata_lfo<n>_dest, which 3.7 reads as
-- none: decision 24, docs/notes/lua/lfos.md), and a PSET with 3.6's
-- strata_pset_format line
local ADDED = {
  globals = {"delay_sync", "delay_division", "delay_pingpong"},
  blocks = {"sequences"},
  voice_extras = {"env_attack", "env_decay", "env_sustain", "env_release", "env_curve", "env_loop", "follow",
    "scan_mode", "seq_direction", "seq_misstep", "slices"},
  step_keys = {"slice", "cond"},
  -- PSET lines: these ids, each voice's v<i>_<extra>, and rseq<n>_* for n 1..4
  pset_ids = {"delay_sync", "delay_division", "delay_pingpong", "scene_chance_next", "scene_chance_previous",
    "scene_chance_random", "seq_chain_next", "seq_chain_previous", "seq_chain_random", "strata_rseq"},
  rseq_params = {"clock", "drift", "length", "new"},
  lfo_dest_key = "^strata_lfo%d_dest_key$",
}

local function in_list(list, value)
  for _, entry in ipairs(list) do if entry == value then return true end end
  return false
end

-- Whether a PSET line's id is one 3.6 never wrote
local function added_pset_id(id)
  if in_list(ADDED.pset_ids, id) or id:match(ADDED.lfo_dest_key) then return true end
  local extra = id:match("^v%d_(.+)$")
  if extra and in_list(ADDED.voice_extras, extra) then return true end
  local rseq = id:match("^rseq%d_(.+)$")
  return rseq ~= nil and in_list(ADDED.rseq_params, rseq)
end

-- A 3.6 scene from one this build captured: 3.7's fields out, the LFO
-- destinations as indices
local function as_3_6_scene(scene, lfo_count)
  local old = deep_copy(scene)
  if not old.populated then return old end
  for _, id in ipairs(ADDED.globals) do old.data[id] = nil end
  for _, key in ipairs(ADDED.blocks) do old.data[key] = nil end
  for n = 1, lfo_count do
    old.data["strata_lfo" .. n .. "_dest_key"] = nil
    old.data["strata_lfo" .. n .. "_dest"] = n + 1  -- an index of 3.6's list
  end
  for _, voice in pairs(old.data.voices or {}) do
    for _, key in ipairs(ADDED.voice_extras) do voice.extras[key] = nil end
  end
  for _, steps in pairs(old.data.steps or {}) do
    for _, step in pairs(steps) do
      for _, key in ipairs(ADDED.step_keys) do step[key] = nil end
    end
  end
  return old
end

-- The id: value lines of a PSET's text, in order
local function pset_lines(text)
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    local id, value = line:match('^"(.-)"%s*:%s*(.*)$')
    if id then lines[#lines + 1] = {id = id, value = value, line = line} end
  end
  return lines
end

-- The first path at which two values differ (numbers to a data file's 14 digits), or nil
local function first_difference(a, b, path)
  if type(a) ~= "table" or type(b) ~= "table" then
    if a == b then return nil end
    if type(a) == "number" and type(b) == "number" and math.abs(a - b) <= 1e-12 * math.max(1, math.abs(a)) then
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

-- A data folder of its own, under the harness's data root
local function fresh_dir(name)
  local subdir = name .. "-" .. math.random(1, 1e9)
  local dir = h.data_root .. subdir .. "/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  return subdir, dir
end

test("a 3.6 scenes file, a 3.6 PSET and a version 2 buffers.data load with their values as saved", function()
  math.randomseed(SYSTEM.seed)
  -- the session the files are written from: every voice scrambled (a non-zero scan
  -- included), steps with attributes, two scenes
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local NUM_VOICES, NUM_LFOS = S.constants.NUM_VOICES, S.constants.NUM_LFOS
  h.scramble_state(SYSTEM.seed)
  params:set("v1_buf_scan", 0.5)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  S.patterns[2][3] = 9
  S.lib.sequencer.set_step_attr(2, 3, "prob", 40)
  S.lib.sequencer.set_step_attr(2, 3, "notes", {0, 7})
  capture_scene(1)
  h.scramble_state(SYSTEM.seed + 1)
  capture_scene(4)
  S.lib.scenes.set_name(4, "four")
  local old_scenes = {}
  for slot = 1, S.constants.NUM_SCENES do old_scenes[slot] = as_3_6_scene(S.scenes[slot], NUM_LFOS) end
  for slot = 1, S.constants.NUM_SCENES do
    for _, key in ipairs(ADDED.voice_extras) do
      local voices = old_scenes[slot].populated and old_scenes[slot].data.voices
      if voices then assert_equal(voices[1].extras[key], nil, "the 3.6 scene has no " .. key) end
    end
  end
  local pset_text = {}
  local saved_from = context.data_dir .. "strata-05.pset"
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  params:set("v1_buf_scan", 0.5)  -- a non-zero scan in the PSET too
  params:write(saved_from, "three six")
  for _, entry in ipairs(pset_lines(file_text(saved_from))) do
    if not added_pset_id(entry.id) then pset_text[#pset_text + 1] = entry.line end
  end
  for n = 1, NUM_LFOS do pset_text[#pset_text + 1] = '"strata_lfo' .. n .. '_dest": ' .. (n + 1) end
  pset_text[#pset_text + 1] = '"strata_pset_format": 2'
  local pset_body = "-- three six\n" .. table.concat(pset_text, "\n") .. "\n"
  cleanup()

  -- the 3.6 files, in a data folder of their own, with a 30 s file in slot 3 from 1.5 s
  local subdir, dir = fresh_dir("system37-old-files")
  write_text(dir .. "scenes.data", tabutil_text({version = 7, scenes = old_scenes}))
  local audio = h.data_root .. subdir .. "/audio/"
  os.execute("mkdir -p '" .. audio .. "'")
  local drone = audio .. "drone.wav"
  io.open(drone, "w"):close()
  write_text(dir .. "buffers.data", tabutil_text({version = 2, paths = {"", "", drone}, starts = {0, 0, 1.5}}))
  local pset = h.data_root .. subdir .. "/strata-05.pset"
  write_text(pset, pset_body)
  context = load_strata({data_subdir = subdir, before_load = function(started)
    started.audio.register(drone, {channels = 2, frames = 48000 * 30, rate = 48000})  -- longer than a slot
  end})
  finish_startup(context)
  S = local_value("S")
  -- the scenes, each as it was saved, the 3.7 fields at their defaults
  for slot = 1, S.constants.NUM_SCENES do
    local loaded = S.scenes[slot]
    local difference
    if old_scenes[slot].populated then
      local trimmed = as_3_6_scene(loaded, NUM_LFOS)
      for n = 1, NUM_LFOS do trimmed.data["strata_lfo" .. n .. "_dest"] = old_scenes[slot].data["strata_lfo" .. n .. "_dest"] end
      difference = first_difference(old_scenes[slot], trimmed, "scene " .. slot)
    else
      difference = loaded.populated and ("scene " .. slot .. " loaded from nothing") or nil
    end
    assert_true(difference == nil, "every value as saved: " .. tostring(difference))
  end
  assert_true(S.scenes[1].populated and S.scenes[4].populated, "the two scenes load")
  assert_equal(S.scenes[4].name, "four")
  local one = S.scenes[1].data
  assert_near(one.voices[1].grain.buf_scan or one.voices[1].params.buf_scan, 0.5, 1e-9, "a scan of 0.5, now a speed")
  for voice = 1, NUM_VOICES do
    local extras = one.voices[voice].extras
    assert_equal(extras.scan_mode, 1, "voice " .. voice .. ": wrap"); assert_equal(extras.follow, 1, "follow off")
    assert_equal(extras.slices, 1, "slices off"); assert_equal(extras.seq_direction, 1, "forward")
    assert_equal(extras.seq_misstep, 0, "no misstep"); assert_equal(extras.env_loop, 1, "the envelope does not loop")
  end
  assert_equal(one.delay_sync, 0, "the delay unsynced"); assert_equal(one.delay_pingpong, 0, "no ping-pong")
  for n = 1, NUM_LFOS do assert_equal(one["strata_lfo" .. n .. "_dest_key"], "none", "LFO " .. n .. ": none (decision 24)") end
  assert_equal(one.steps[2][3].prob, 40, "a step's attribute as saved")
  assert_equal(one.steps[2][3].slice, nil, "and no slice"); assert_equal(one.steps[2][3].cond, nil, "nor condition")
  assert_true(not util.file_exists(dir .. "scenes.data.bak"), "nothing is set aside")
  -- the buffers: slot 3 reloads its file from 1.5 s, with no settings
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "one slot reloads")
  assert_equal(loads[1].args[1], 2, "slot 3"); assert_equal(loads[1].args[2], drone)
  assert_near(loads[1].args[3], 1.5, 1e-9, "from its start")
  context.polls.fire("bufferState", context.polls.buffer_state_value(3, S.buffers[3].loads_sent, 16))
  assert_equal(S.lib.buffers.status(3), "loaded", "slot 3 holds it")
  local settings = S.lib.samples.settings(3)
  assert_true(settings ~= nil, "a default record")
  assert_equal(settings.tempo, nil, "no tempo"); assert_equal(settings.key, nil, "no key")
  assert_equal(settings.normalize, false, "no normalize"); assert_equal(settings.mode, 1, "no slices")
  assert_true(not util.file_exists(dir .. "buffers.data.bak"), "nothing is set aside")
  -- the PSET: every line it holds as written, every 3.7 param at its default
  context.clear_engine_calls()
  params:read(pset)
  lfo_step(context, 3)
  for _, entry in ipairs(pset_lines(pset_body)) do
    local param = params.lookup[entry.id] and params:lookup_param(entry.id)
    if param and entry.id ~= "strata_lfo1_dest" and not entry.id:match("^strata_lfo%d_dest$") then
      local number = tonumber(entry.value)
      if number and param.t ~= params.tTEXT then
        assert_near(params:get(entry.id), number, 1e-9 * math.max(1, math.abs(number)), entry.id .. " as saved")
      else
        assert_equal(tostring(params:get(entry.id)), entry.value, entry.id .. " as saved")
      end
    end
  end
  assert_near(params:get("v1_buf_scan"), 0.5, 1e-9, "the scan of 0.5, a speed")
  for voice = 1, NUM_VOICES do
    for _, key in ipairs({"scan_mode", "follow", "slices", "seq_direction", "env_loop"}) do
      assert_equal(params:get("v" .. voice .. "_" .. key), 1, "voice " .. voice .. "'s " .. key .. " off")
    end
    assert_equal(params:get("v" .. voice .. "_seq_misstep"), 0)
  end
  for n = 1, NUM_LFOS do assert_equal(params:get("strata_lfo" .. n .. "_dest_key"), "none", "LFO " .. n .. ": none") end
  assert_equal(params:get("delay_sync"), 0); assert_equal(params:get("delay_pingpong"), 0)
  for _, name in ipairs(NEW_COMMANDS) do assert_equal(#context.calls_named(name), 0, "the read sends no " .. name) end
  cleanup()
end)

test("a scenes file older than format 7 and a version 1 buffers.data are set aside, never converted or overwritten",
    function()
  math.randomseed(SYSTEM.seed)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  h.scramble_state(SYSTEM.seed)
  capture_scene(2)
  local scenes = as_3_6_scene(S.scenes[2], S.constants.NUM_LFOS)
  cleanup()
  local subdir, dir = fresh_dir("system37-below-floors")
  local audio = h.data_root .. subdir .. "/audio/"
  os.execute("mkdir -p '" .. audio .. "'")
  local drone = audio .. "drone.wav"
  io.open(drone, "w"):close()
  local scenes_text = tabutil_text({version = 6, scenes = {[2] = scenes}})
  local buffers_text = tabutil_text({version = 1, paths = {drone}, starts = {0}})
  write_text(dir .. "scenes.data", scenes_text)
  write_text(dir .. "buffers.data", buffers_text)
  context = load_strata({data_subdir = subdir, before_load = function(started)
    started.audio.register(drone, {channels = 2, frames = 48000 * 4, rate = 48000})
  end})
  finish_startup(context)
  S = local_value("S")
  for slot = 1, S.constants.NUM_SCENES do
    assert_true(not S.scenes[slot].populated, "scene " .. slot .. ": nothing converted")
  end
  assert_equal(#context.calls_named("loadBuffer"), 0, "no slot reloads")
  assert_equal(file_text(dir .. "scenes.data.bak"), scenes_text, "the scenes file set aside whole")
  assert_equal(file_text(dir .. "buffers.data.bak"), buffers_text, "the buffers file set aside whole")
  assert_equal(S.scene_file.problem, "unreadable"); assert_equal(S.buffer_file.problem, "unreadable")
  -- a session that saves both files writes beside the backups, which stay
  capture_scene(3)
  load_buffer(1, drone)
  context.clock.run_for(1)
  cleanup()
  assert_equal(file_text(dir .. "scenes.data.bak"), scenes_text, "the scenes backup never overwritten")
  assert_equal(file_text(dir .. "buffers.data.bak"), buffers_text, "the buffers backup never overwritten")
  assert_equal(context.tab.load(dir .. "scenes.data").version, S.constants.SCENE_DATA_VERSION, "scenes in the build's format")
  assert_equal(context.tab.load(dir .. "buffers.data").version, S.constants.BUFFER_DATA_VERSION,
    "buffers in the build's version")
end)

---------------------------------------------------------------------------
-- 4 and 5. A sliced loop with everything on
---------------------------------------------------------------------------

local function sixteenth() return 60 / SYSTEM.tempo / 4 end
local function bar_seconds() return 60 / SYSTEM.tempo * SYSTEM.bar_beats end

-- The extra slots voice 1 holds (any record past the own note's)
local function extra_slots(S)
  local count = 0
  for _, used in ipairs(S.lib.notes.slots(1)) do if used.slot > 1 then count = count + 1 end end
  return count
end

local function calls_since(context, from, name)
  local list = {}
  for index = from + 1, #context.engine_calls do
    local call = context.engine_calls[index]
    if call.name == name then list[#list + 1] = call end
  end
  return list
end

-- The state: slot 1 holds 8 s, cut in 8 equal slices, at a file tempo of
-- 120; voice 1 (running) reads it with slices overlap, one shot, a scan of
-- 1 and follow stretch; its pattern plays slice k on step k (1-8), in
-- reverse, cond 1:2 on step 3 and fill on step 5; env1 is routed to v1
-- cutoff (routing 1) and rseq1, clocked by voice 1's hits, to v1 pos
-- (routing 2); scenes 1 and 2 hold it all, and the chain runs over them at
-- 0, 0, 100; the clock is at 90 BPM; a 256 is on port 1. Before any of it a
-- PSET of the defaults is written (the PSET way out). The probe output
-- keeps each first hit of voice 1: its step, the time, fill, rseq1's
-- position and how many engine calls had been made
local function sliced_loop()
  math.randomseed(SYSTEM.seed)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  local state = {defaults_pset = context.data_dir .. "strata-07.pset", events = {}}
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  params:write(state.defaults_pset, "defaults")
  -- slot 1 and its slices
  load_buffer(1, context.audio_dir .. "loop.wav")
  if S.buffers[1].awaiting_zero then
    context.polls.fire("bufferState", context.polls.buffer_state_value(1, S.buffers[1].loads_sent, 0))
  end
  context.polls.fire("bufferState", context.polls.buffer_state_value(1, S.buffers[1].loads_sent, SYSTEM.slot_seconds))
  local folder = S.lib.scenes.scene_data_dir
  util.make_dir(folder)
  write_text(folder .. "buf1.peaks", string.format("strata-peaks 1\nslot 1\nframes %d\nrate %d\ngeneration 1\npeaks %s\n",
    SYSTEM.slot_seconds * SYSTEM.rate, SYSTEM.rate, string.rep("0.500 ", 64)))
  context.clock.run_for(2 / local_value("UI_PAGES").FRAMES_PER_SECOND + 0.001)
  assert_equal(S.lib.buffers.status(1), "loaded", "slot 1 holds the loop")
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  local modes = S.lib.samples.SAMPLES.modes
  local equal
  for index, name in ipairs(modes) do if name == "equal" then equal = index end end
  assert_true(S.lib.samples.set(1, "mode", equal), "equal parts")
  assert_true(S.lib.samples.set(1, "count", SYSTEM.slices), "8 of them")
  S.lib.slices.make(1)
  assert_true(S.lib.samples.set(1, "tempo", SYSTEM.file_tempo), "a file tempo of 120")
  assert_equal(S.lib.slices.count(1), SYSTEM.slices, "8 slices")
  for _, id in ipairs({"v1_slices", "v1_scan_mode", "v1_follow"}) do
    params:set(id, option_index(id, SYSTEM.options[id]))
  end
  params:set("v1_buf_scan", 1)
  params:set("clock_tempo", SYSTEM.tempo)
  -- the pattern: voice 1 alone
  for voice = 1, S.constants.NUM_VOICES do
    for step = 1, S.constants.PATTERN_LENGTH do S.patterns[voice][step] = 0 end
  end
  for step = 1, SYSTEM.slices do
    S.patterns[1][step] = S.constants.MAX_STEP_LEVEL
    S.lib.sequencer.set_step_attr(1, step, "slice", step)
  end
  params:set("v1_seq_length", SYSTEM.slices)
  params:set("v1_seq_direction", option_index("v1_seq_direction", SYSTEM.options.v1_seq_direction))
  S.lib.sequencer.set_step_attr(1, SYSTEM.cond_step, "cond", SYSTEM.cond)
  S.lib.sequencer.set_step_attr(1, SYSTEM.fill_step, "cond", "fill")
  -- the modulators
  assert_true(S.lib.matrix.set_routing(SYSTEM.routings.envelope, "env1", "v1_filter_freq"), "env1 to v1 cutoff")
  params:set("matrix_" .. SYSTEM.routings.envelope .. "_depth", SYSTEM.depth)
  params:set("rseq1_clock", option_index("rseq1_clock", "voice 1"))
  assert_true(S.lib.matrix.set_routing(SYSTEM.routings.sequence, "rseq1", "v1_buf_pos"), "rseq1 to v1 pos")
  params:set("matrix_" .. SYSTEM.routings.sequence .. "_depth", SYSTEM.depth)
  -- the chain
  capture_scene(1); capture_scene(2)
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", SYSTEM.chain.scenes)
  params:set("seq_chain_bars", SYSTEM.chain.bars)
  params:set("seq_chain_next", SYSTEM.chain.chances[1]); params:set("seq_chain_previous", SYSTEM.chain.chances[2])
  params:set("seq_chain_random", SYSTEM.chain.chances[3])
  state.device = context.grid.plug(SYSTEM.grid_port, 16, 16)
  lfo_step(context, 3)
  -- the chain's moves, as the picker returns them (the real one)
  state.moves = {}
  local real_pick = S.lib.chance.pick
  S.lib.chance.pick = function(...)
    local slot, move = real_pick(...)
    state.moves[#state.moves + 1] = move .. " " .. tostring(slot)
    return slot, move
  end
  S.register_step_output({name = "system probe", play = function(event)
    if event.voice ~= 1 or not event.first then return end
    state.events[#state.events + 1] = {step = event.step, time = util.time(), fill = S.lib.conditions.fill(),
      position = S.lib.random_sequences.position(1), calls = #context.engine_calls}
  end})
  return context, S, state
end

local function press_fill(context, z)
  context.grid.press(SYSTEM.grid_port, SYSTEM.fill_key.x, SYSTEM.fill_key.y, z)
end

-- The pass each probe event fell in (a pass is a length of 8 sixteenths)
local function pass_of(state, event)
  local taken = math.floor((event.time - state.events[1].time) / sixteenth() + 0.5) + 1
  return math.floor((taken - 1) / SYSTEM.slices) + 1
end

local function passes_of_step(state, step)
  local passes = {}
  for _, event in ipairs(state.events) do
    if event.step == step then passes[#passes + 1] = pass_of(state, event) end
  end
  return table.concat(passes, " ")
end

test("a sliced loop under a pattern, follow, an envelope, a sequence and a chain", function()
  local context, S, state = sliced_loop()
  local routed_at = 0  -- every call since the load: the routing's own send included
  assert_equal(#calls_since(context, routed_at, "setFastEnv"), 1, "the routing's one setFastEnv")
  local env = calls_since(context, routed_at, "setFastEnv")[1]
  assert_equal(env.args[1], SYSTEM.routings.envelope - 1, "route 0"); assert_equal(env.args[2], 0, "fired by voice 1")
  assert_equal(env.args[3], 0, "on voice 1"); assert_equal(env.args[4], 3, "its cutoff")
  local started = #context.engine_calls
  -- four bars at 90 BPM, fill held over the third
  pattern_clock_start()
  context.clock.run_for(2 * bar_seconds() - SYSTEM.fill_margin)
  press_fill(context, 1)
  assert_true(S.lib.conditions.fill(), "fill held")
  context.clock.run_for(bar_seconds())
  press_fill(context, 0)
  assert_true(not S.lib.conditions.fill(), "fill let go")
  context.clock.run_for((SYSTEM.bars - 3) * bar_seconds() + SYSTEM.fill_margin - 0.01)  -- the 64th sixteenth plays
  local played = #state.events
  local passes = SYSTEM.bars * SYSTEM.bar_beats * 4 / SYSTEM.slices  -- 8 passes of 8 sixteenths
  -- the steps: 64 sixteenths in reverse, step 3 on odd passes, step 5 while fill is held
  assert_equal(state.events[1].step, SYSTEM.slices, "reverse: step 8 first")
  assert_equal(passes_of_step(state, SYSTEM.cond_step), "1 3 5 7", "step 3 on the odd passes")
  assert_equal(passes_of_step(state, SYSTEM.fill_step), "5 6", "step 5 only while fill is held")
  for _, event in ipairs(state.events) do
    if event.step == SYSTEM.fill_step then assert_true(event.fill, "step 5 played with fill on") end
  end
  assert_equal(passes_of_step(state, SYSTEM.slices), "1 2 3 4 5 6 7 8", "step 8 on every pass")
  assert_equal(played, passes * SYSTEM.slices - passes / 2 - (passes - 2),
    "64 steps less step 3's four misses and step 5's six")
  -- the chain: a link a bar at 0, 0, 100, which over two scenes is always the other
  assert_equal(table.concat(state.moves, ", "), "random 2, random 1, random 2", "the chain's three links")
  -- every hit's slice in a slot of its own: its noteRegion, the slice's, right before its noteOn
  local last_note_call = {}
  for index = started + 1, #context.engine_calls do
    local call = context.engine_calls[index]
    if (call.name == "noteRegion" or call.name == "noteOn") and call.args[1] == 0 then
      if call.name == "noteOn" then
        assert_true(last_note_call.name == "noteRegion" and last_note_call.args[2] == call.args[2],
          "call " .. index .. ": a noteRegion of slot " .. call.args[2] .. " precedes its noteOn")
      end
      last_note_call = call
    end
  end
  -- each hit's calls: from the probe's count at the hit before to its own
  local from = started
  for index, event in ipairs(state.events) do
    local window = {}
    for at = from + 1, event.calls do
      local call = context.engine_calls[at]
      if call.name == "noteRegion" and call.args[1] == 0 then window[#window + 1] = call end
    end
    assert_equal(#window, 1, "hit " .. index .. " (step " .. event.step .. "): one noteRegion")
    assert_near(window[1].args[3], (event.step - 1) / SYSTEM.slices, 1e-9, "hit " .. index .. ": slice " .. event.step
      .. "'s start")
    assert_near(window[1].args[4], 1 / SYSTEM.slices, 1e-9, "and its length")
    from = event.calls
  end
  assert_equal(#calls_since(context, started, "voiceOn"), 0, "no hit starts a voice")
  local own = {}
  for _, call in ipairs(calls_since(context, started, "setGrainParam")) do
    if call.args[1] == 0 and call.args[2]:find("^region") then own[#own + 1] = call end
  end
  assert_equal(#own, 0, "an overlap step leaves the own note's region alone")
  -- follow: the scan at 0.75 of itself, sent so
  assert_near(S.lib.engine_sync.engine_factor("v1_buf_scan"), SYSTEM.factor, 1e-9, "the scan's factor is 0.75")
  assert_near(engine_param_value("v1_buf_scan"), SYSTEM.factor, 1e-9, "and what the engine plays")
  assert_near(params:get("v1_buf_scan"), 1, 1e-9, "the param stays")
  local scans = {}
  for index = 1, #context.engine_calls do
    local call = context.engine_calls[index]
    if call.name == "setGrainParam" and call.args[1] == 0 and call.args[2] == "bufScan" then scans[#scans + 1] = call.args[3] end
  end
  assert_near(scans[#scans], SYSTEM.factor, 1e-9, "bufScan 0.75 reached the engine")
  -- the envelope: one setFastEnv in all, and no message of its own at a hit
  assert_equal(#calls_since(context, started, "setFastEnv"), 0, "no setFastEnv at a hit")
  assert_equal(#calls_since(context, started, "stopFastEnv"), 0, "no stopFastEnv")
  for _, call in ipairs(calls_since(context, started, "setFastOffset")) do
    assert_true(not (call.args[1] == 0 and call.args[3] == 3 and call.args[4] ~= 0),
      "the envelope's cutoff never reaches the fast channel")
  end
  assert_equal(#calls_since(context, started, "retrigger"), played, "one retrigger a hit")
  -- the sequence steps once a hit
  local length = params:get("rseq1_length")
  for index = 2, #state.events do
    assert_equal(state.events[index].position, state.events[index - 1].position % length + 1,
      "hit " .. index .. ": rseq1 one step on")
  end
  -- after the patterns stop and the voice stops: nothing held
  pattern_clock_stop()
  toggle_voice(1)
  lfo_step(context, 2)
  assert_equal(extra_slots(S), 0, "no extra slot held")
  assert_equal(S.lib.notes.own_region(1), nil, "the own region cleared")
  assert_equal(#S.lib.slices.playing(1), 0, "no slice sounds")
end)

-- The ways out (the brief's four), each on a fresh state playing for a bar
-- and a half with fill held by the 256's key
local WAYS_OUT = {
  {name = "a slot clear", run = function() clear_buffer(1) end},
  {name = "a source switch", run = function(_, S) params:set("v1_source", S.constants.SOURCE_SYNTH) end},
  {name = "a PSET load", ends_routing = true, run = function(_, _, state) params:read(state.defaults_pset) end},
  {name = "cleanup", cleanup = true, run = function() cleanup() end},
}

test("every way out leaves nothing held", function()
  for _, way in ipairs(WAYS_OUT) do
    local context, S, state = sliced_loop()
    pattern_clock_start()
    context.clock.run_for(bar_seconds())
    press_fill(context, 1)
    context.clock.run_for(bar_seconds() / 2)
    assert_true(extra_slots(S) > 0, way.name .. ": slices sound in extra slots")
    assert_true(S.lib.conditions.fill(), way.name .. ": fill held")
    assert_equal(#context.calls_named("stopFastEnv"), 0, way.name .. ": the route plays")
    local before = #context.engine_calls
    way.run(context, S, state)
    if way.cleanup then
      -- norns has freed the engine: step 160's voiceOffs are the only calls (docs/notes/lua/state-and-voices.md)
      for index = before + 1, #context.engine_calls do
        assert_equal(context.engine_calls[index].name, "voiceOff", "cleanup sends only its voiceOffs")
      end
      assert_equal(extra_slots(S), 0, "cleanup: no slice note held")
      assert_true(not S.lib.conditions.fill(), "cleanup: fill ends with its grid")
    else
      lfo_step(context, 3)
      assert_equal(extra_slots(S), 0, way.name .. ": no slice note held")
      assert_equal(#S.lib.slices.playing(1), 0, way.name .. ": no slice sounds")
      assert_equal(S.lib.notes.own_region(1), nil, way.name .. ": no own region")
      press_fill(context, 0)
      assert_true(not S.lib.conditions.fill(), way.name .. ": fill off once its holder lets go")
      assert_equal(params:get("seq_fill"), 0, way.name .. ": and no latch")
      if not way.ends_routing then
        assert_equal(#calls_since(context, before, "stopFastEnv"), 0, way.name .. ": the routing plays on")
        S.lib.matrix.set_routing(SYSTEM.routings.envelope, "", "")
      end
      lfo_step(context, 6)
      local stops = calls_since(context, before, "stopFastEnv")
      assert_equal(#stops, 1, way.name .. ": one stopFastEnv at the routing's end")
      assert_equal(stops[1].args[1], SYSTEM.routings.envelope - 1, way.name .. ": route 0's")
      pattern_clock_stop()
    end
  end
end)

end

-- test/unit/system_37_test.lua
-- Every 3.7 feature at once (3.7 design §12, the whole-system test; plan
-- Task 3a, Review Focus 2): the real modules, driven through params, the
-- clocks, a grid and the data folder, read through the engine calls the
-- stub records. A fresh Strata sends what 3.6.0 sent but the values every
-- voice sync now carries (the fixture test/fixtures/3.6.0-start-calls.lua);
-- 3.6.0's own scenes file, PSET and side files (test/fixtures/3.6.0-files.lua)
-- load as saved and the files below the floors are set aside; a sliced
-- loop plays under a reversed pattern with conditions and fill, follow, an
-- envelope, a random sequence and a chain; and every way out of that state
-- leaves nothing held, in Lua's records and in the engine's notes (every
-- noteOn paired with one end). The test only observes: no double stands
-- in for a module, and a failure here is a finding in the module it names.
-- Run alone: lua test/run.lua system_37

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local write_text, file_text, tabutil_text = h.write_text, h.file_text, h.tabutil_text

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
  grid_port = 1, fill_key = {x = 2, y = 8},
}

-- The commands a 3.6 Strata never sent (a 3.6 PSET's read sends none of them either)
local NEW_COMMANDS = {"noteRegion", "syncScan", "setSlotGain", "analyzeBuffer", "setFastEnv", "stopFastEnv"}

-- What a fresh run (init, the start-up, every voice started and stopped)
-- sends beyond test/fixtures/3.6.0-start-calls.lua: entries for
-- h.allowed_call_lines (test/helpers.lua; docs/notes/test-harness/run-and-helpers.md),
-- applied to the whole run's lines and the fixture's before the
-- comparison. count is for the run; an entry whose match or replace holds
-- <v> or <v0> stands for one entry a voice, its count per voice. A match
-- is anchored: it starts with ^, and ends with $ when count is above 0 (a
-- prefix such as '^noteRegion%(' only for count 0), or the helper raises. The
-- package that changes a start message adds its entries here in the same
-- commit, as it does to START_CALLS_ALLOWED (test/unit/engine_sync_test.lua):
-- registration lines, a block of its own opening `-- <id>: <what> (design §n)`,
-- one entry a line, each why beginning "<id>: "
local RUN_VOICES = h.voice_count()
local RUN_CALLS_ALLOWED = {
  -- 3.7: the commands a fresh start never sends (3.7 design §12)
  {kind = "drop", match = "^noteRegion%(", count = 0, why = "3.7: noteRegion is new in 3.7, and a fresh run sends none"},
  {kind = "drop", match = "^syncScan%(", count = 0, why = "3.7: syncScan is new in 3.7, and a fresh run sends none"},
  {kind = "drop", match = "^setSlotGain%(", count = 0, why = "3.7: setSlotGain is new in 3.7, and a fresh run sends none"},
  {kind = "drop", match = "^analyzeBuffer%(", count = 0, why = "3.7: analyzeBuffer is new in 3.7, and a fresh run sends none"},
  {kind = "drop", match = "^setFastEnv%(", count = 0, why = "3.7: setFastEnv is new in 3.7, and a fresh run sends none"},
  {kind = "drop", match = "^stopFastEnv%(", count = 0, why = "3.7: stopFastEnv is new in 3.7, and a fresh run sends none"},
  -- 3.7: the grain keys every voice sync carries, each at its 3.6 sound, once in each voice's start (3.7 design §12)
  {kind = "drop", match = '^setGrainParam%(%d+, "scanMode", 0%)$', count = RUN_VOICES, why = "3.7: the scan mode, wrap"},
  {kind = "drop", match = '^setGrainParam%(%d+, "followRate", 1%)$', count = RUN_VOICES, why = "3.7: follow's rate, 1"},
  {kind = "drop", match = '^setGrainParam%(%d+, "rootNote", 60%)$', count = RUN_VOICES, why = "3.7: the root note, 60"},
  {kind = "drop", match = '^setGrainParam%(%d+, "regionStart", 0%)$', count = RUN_VOICES,
    why = "3.7: the own region's start, 0"},
  {kind = "drop", match = '^setGrainParam%(%d+, "regionLength", 0%)$', count = RUN_VOICES,
    why = "3.7: the own region's length, 0 (the loop)"},
  -- 3.7: setDelay's fourth value, ping-pong, at 0 (3.7 design §6); no start sends setDelay, so its count is 0
  {kind = "rewrite", match = "^(setDelay%([^,]+, [^,]+, [^,]+), 0%)$", replace = "%1)", count = 0,
    why = "3.7: setDelay carries ping-pong, 0 by default"},
}

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
  -- every call since the load, RUN_CALLS_ALLOWED's differences applied
  local lines = {}
  for _, call in ipairs(context.engine_calls) do lines[#lines + 1] = call_line(call) end
  local recorded, sent = h.allowed_call_lines(dofile(h.repo_root .. "/test/fixtures/3.6.0-start-calls.lua"), lines,
    RUN_CALLS_ALLOWED, "a fresh run")
  local expected, actual = canonical(recorded), canonical(sent)
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
-- A scenes file, a PSET and its three side files as 3.6.0 wrote them
-- (test/fixtures/3.6.0-files.lua, recorded from the tag; its header says how)
local function files_3_6()
  return dofile(h.repo_root .. "/test/fixtures/3.6.0-files.lua")
end

local PSET_3_6 = {
  base = "strata-05",                 -- PSET 5: the side files are strata-05.<key>.data
  sides = {"macros", "matrix", "gestures"},
  -- the 3.6 lines 3.7 has no param for, each with why
  drops = {strata_pset_format = "3.7 writes no format line and reads one as nothing (0d)"},
  -- an LFO's destination: since the groundwork before 3.8 its home routing
  -- in the matrix, so the line names no param, and the version 1 matrix
  -- side file holds no home: the LFO is aimed at nothing
  lfo_dest = "^strata_lfo(%d)_dest$",
  -- the state the recording set through 3.6.0's code (the fixture's header)
  scan = 0.5, keyed = {cc_out1_source = "pressure", crow_out1_source = "pressure"},
  macro = {id = "reverb_mix", min = 0.2, max = 0.8}, routing = {source = "macro1", dest = "v3_grain_pitch"},
}

-- The id: value lines of a PSET's text, in order
local function pset_lines(text)
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    local id, value = line:match('^"(.-)"%s*:%s*(.*)$')
    if id then lines[#lines + 1] = {id = id, value = value} end
  end
  return lines
end

-- A data folder of its own, under the harness's data root
local function fresh_dir(name)
  local subdir = name .. "-" .. math.random(1, 1e9)
  local dir = h.data_root .. subdir .. "/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  return subdir, dir
end

-- The groundwork before 3.8 raises the scenes floor to 9 (rulings 1-3): a
-- 3.6 scenes file (format 7) is set aside whole; its PSET and buffers.data
-- still load
test("a 3.6 scenes file is set aside whole; a 3.6 PSET and a version 2 buffers.data load with their values as saved",
    function()
  math.randomseed(SYSTEM.seed)
  local files = files_3_6()
  local subdir, dir = fresh_dir("system37-old-files")
  local root = h.data_root .. subdir .. "/"
  write_text(dir .. "scenes.data", files["scenes.data"])
  -- buffers.data as 3.6.0 writes it ({version, paths, starts}): a 30 s file in slot 3 from 1.5 s
  local audio = root .. "audio/"
  os.execute("mkdir -p '" .. audio .. "'")
  local drone = audio .. "drone.wav"
  io.open(drone, "w"):close()
  write_text(dir .. "buffers.data", tabutil_text({version = 2, paths = {"", "", drone}, starts = {0, 0, 1.5}}))
  local pset = root .. PSET_3_6.base .. ".pset"
  local pset_text = files[PSET_3_6.base .. ".pset"]:gsub("@AUDIO@", audio)
  write_text(pset, pset_text)
  for _, key in ipairs(PSET_3_6.sides) do
    local name = PSET_3_6.base .. "." .. key .. ".data"
    write_text(root .. name, files[name])
  end
  local context = load_strata({data_subdir = subdir, before_load = function(started)
    started.audio.register(drone, {channels = 2, frames = 48000 * 30, rate = 48000})  -- longer than a slot
  end})
  finish_startup(context)
  local S = local_value("S")
  local NUM_VOICES = S.constants.NUM_VOICES
  -- the scenes: 3.6.0 writes format 7, below the floor, so the file is set
  -- aside whole and reads as older; no slot is filled
  assert_equal(S.lib.data_files.read(dir .. "scenes.data.bak").version, 7, "3.6.0 writes format 7")
  assert_equal(file_text(dir .. "scenes.data.bak"), files["scenes.data"], "the scenes file set aside whole")
  assert_true(not util.file_exists(dir .. "scenes.data"), "and moved")
  assert_equal(S.scene_file.problem, "older", "it reads as older")
  for slot = 1, S.constants.NUM_SCENES do
    assert_true(not S.scenes[slot].populated, "scene " .. slot .. ": nothing loaded")
  end
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
  -- the PSET: every line as written, but those 3.7 names (drops, the LFO destinations)
  context.clear_engine_calls()
  params:read(pset)
  lfo_step(context, 3)
  local in_file, compared = {}, 0
  for _, entry in ipairs(pset_lines(pset_text)) do
    in_file[entry.id] = true
    local id = entry.id
    if id:match(PSET_3_6.lfo_dest) then
      assert_equal(params.lookup[id], nil, id .. ": no param")
      assert_equal(S.lib.matrix.home(tonumber(id:match(PSET_3_6.lfo_dest))), "", id .. ": the LFO is aimed at nothing")
    elseif not params.lookup[id] then
      assert_true(PSET_3_6.drops[id] ~= nil, id .. ": a 3.6 line with no param here, and none expected")
    elseif params:lookup_param(id).t == params.tGROUP then
      -- a group's line holds its size, no value
    else
      local number = tonumber(entry.value)
      if number and params:lookup_param(id).t ~= params.tTEXT then
        assert_near(params:get(id), number, 1e-9 * math.max(1, math.abs(number)), id .. " as saved")
      else
        assert_equal(tostring(params:get(id)), entry.value, id .. " as saved")
      end
      compared = compared + 1
    end
  end
  assert_true(compared > 800, compared .. " of the PSET's values compared")
  for id in pairs(PSET_3_6.drops) do assert_true(in_file[id], "the 3.6 PSET holds " .. id) end
  assert_near(params:get("v1_buf_scan"), PSET_3_6.scan, 1e-9, "the scan of 0.5, a speed")
  for id, text in pairs(PSET_3_6.keyed) do assert_equal(params:string(id), text, id .. " by its key") end
  -- the side files
  local routing = S.lib.matrix.routing(1)
  assert_equal(routing.source, PSET_3_6.routing.source, "routing 1 from the matrix side file")
  assert_equal(routing.dest, PSET_3_6.routing.dest)
  local target = S.lib.macros.targets(1)[1]
  assert_equal(target.id, PSET_3_6.macro.id, "macro 1's target from the macros side file")
  assert_near(target.min, PSET_3_6.macro.min, 1e-9); assert_near(target.max, PSET_3_6.macro.max, 1e-9)
  -- 3.7's params the file lacks: their defaults, all off
  for voice = 1, NUM_VOICES do
    for _, key in ipairs({"scan_mode", "follow", "slices", "seq_direction", "env_loop"}) do
      assert_equal(params:get("v" .. voice .. "_" .. key), 1, "voice " .. voice .. "'s " .. key .. " off")
    end
    assert_equal(params:get("v" .. voice .. "_seq_misstep"), 0)
  end
  assert_equal(params:get("delay_sync"), 0); assert_equal(params:get("delay_pingpong"), 0)
  for _, name in ipairs(NEW_COMMANDS) do assert_equal(#context.calls_named(name), 0, "the read sends no " .. name) end
  cleanup()
end)

test("a scenes file older than format 9 and a version 1 buffers.data are set aside, never converted or overwritten",
    function()
  math.randomseed(SYSTEM.seed)
  local subdir, dir = fresh_dir("system37-below-floors")
  local audio = h.data_root .. subdir .. "/audio/"
  os.execute("mkdir -p '" .. audio .. "'")
  local drone = audio .. "drone.wav"
  io.open(drone, "w"):close()
  -- 3.6.0's scenes file as it is (format 7), and labeled format 8 (3.7's)
  local scenes_7 = files_3_6()["scenes.data"]
  local scenes_8, labeled = scenes_7:gsub('%["version"%]=7,', '["version"]=8,')
  assert_equal(labeled, 1, "the one version field")
  local buffers_text = tabutil_text({version = 1, paths = {drone}, starts = {0}})
  write_text(dir .. "scenes.data", scenes_7)
  write_text(dir .. "buffers.data", buffers_text)
  local context = load_strata({data_subdir = subdir, before_load = function(started)
    started.audio.register(drone, {channels = 2, frames = 48000 * 4, rate = 48000})
  end})
  finish_startup(context)
  local S = local_value("S")
  for slot = 1, S.constants.NUM_SCENES do
    assert_true(not S.scenes[slot].populated, "scene " .. slot .. ": nothing converted")
  end
  assert_equal(#context.calls_named("loadBuffer"), 0, "no slot reloads")
  assert_equal(file_text(dir .. "scenes.data.bak"), scenes_7, "the scenes file set aside whole")
  assert_equal(file_text(dir .. "buffers.data.bak"), buffers_text, "the buffers file set aside whole")
  assert_equal(S.scene_file.problem, "older"); assert_equal(S.buffer_file.problem, "unreadable")
  -- a session that saves both files writes beside the backups, which stay
  capture_scene(3)
  load_buffer(1, drone)
  context.clock.run_for(1)
  cleanup()
  assert_equal(file_text(dir .. "scenes.data.bak"), scenes_7, "the scenes backup never overwritten")
  assert_equal(file_text(dir .. "buffers.data.bak"), buffers_text, "the buffers backup never overwritten")
  assert_equal(context.tab.load(dir .. "scenes.data").version, S.constants.SCENE_DATA_VERSION, "scenes in the build's format")
  assert_equal(context.tab.load(dir .. "buffers.data").version, S.constants.BUFFER_DATA_VERSION,
    "buffers in the build's version")
  -- 3.7's format 8 (the fixture relabeled) is set aside whole as well
  local subdir_8, dir_8 = fresh_dir("system37-format-8")
  write_text(dir_8 .. "scenes.data", scenes_8)
  context = load_strata({data_subdir = subdir_8})
  S = local_value("S")
  assert_equal(file_text(dir_8 .. "scenes.data.bak"), scenes_8, "a format 8 file set aside whole")
  assert_equal(S.scene_file.problem, "older", "and older")
  for slot = 1, S.constants.NUM_SCENES do
    assert_true(not S.scenes[slot].populated, "format 8, scene " .. slot .. ": nothing converted")
  end
  cleanup()
end)

-- The lines a read printed from index `from` on that hold "error", in any case
local function error_lines(context, from)
  local found = {}
  for index = from, #context.printed do
    if context.printed[index]:lower():find("error", 1, true) then found[#found + 1] = context.printed[index] end
  end
  return found
end

-- Each LFO's destination key as a 3.7 PSET holds it beside the option
local KEYS_3_7 = {"v2_main", "reverb_mix", "none", "none", "none", "none"}

-- The groundwork's Review Focus 1: a PSET 3.7 saved, loaded after the
-- update. The 3.6 fixture's PSET as 3.7 writes it (midi_note_off 3, 3.7's
-- release, and each LFO's destination line with its key line: twelve lines
-- that name no param now), its version 1 matrix file, and no scenes file
test("a 3.7 PSET and its side files load with no error line", function()
  math.randomseed(SYSTEM.seed)
  local files = files_3_6()
  local subdir, dir = fresh_dir("system37-pset-3-7")
  local root = h.data_root .. subdir .. "/"
  local audio = root .. "audio/"
  os.execute("mkdir -p '" .. audio .. "'")
  local text, count = files[PSET_3_6.base .. ".pset"]:gsub("@AUDIO@", audio)
  text, count = text:gsub('"midi_note_off": 1\n', '"midi_note_off": 3\n')
  assert_equal(count, 1, "the note off line")
  text, count = text:gsub('("strata_lfo(%d)_dest": [^\n]*\n)', function(line, n)
    return line .. '"strata_lfo' .. n .. '_dest_key": ' .. KEYS_3_7[tonumber(n)] .. "\n"
  end)
  assert_equal(count, 6, "six destination lines, each given its key line")
  local pset = root .. PSET_3_6.base .. ".pset"
  write_text(pset, text)
  for _, key in ipairs(PSET_3_6.sides) do
    local name = PSET_3_6.base .. "." .. key .. ".data"
    write_text(root .. name, files[name])
  end
  assert_true(files[PSET_3_6.base .. ".matrix.data"]:find('["version"]=1,', 1, true) ~= nil, "a version 1 matrix file")
  local context = load_strata({data_subdir = subdir}); finish_startup(context)
  local S = local_value("S")
  h.scramble_state(SYSTEM.seed); S.lib.scenes.save(2)  -- live scenes no PSET holds
  local scenes_before, live_text = S.lib.data_files.encode(S.scenes), file_text(dir .. "scenes.data")
  local from = #context.printed + 1
  params:read(pset)
  lfo_step(context, 3)
  local errors = error_lines(context, from)
  assert_equal(#errors, 0, "no line holding error: " .. table.concat(errors, " | "))
  for n = 1, S.constants.NUM_LFOS do assert_equal(S.lib.matrix.home(n), "", "LFO " .. n .. " aimed at nothing") end
  assert_equal(S.lib.midi_in.note_off_mode(), "release", "3.7's release reads as release")
  local routing = S.lib.matrix.routing(1)
  assert_equal(routing.source, PSET_3_6.routing.source, "routing 1 holds")
  assert_equal(routing.dest, PSET_3_6.routing.dest)
  assert_equal(S.lib.data_files.encode(S.scenes), scenes_before, "the live scenes untouched")
  assert_equal(file_text(dir .. "scenes.data"), live_text, "and the live file")
  assert_true(not util.file_exists(dir .. "scenes.data.bak"), "no backup")
  cleanup()
end)

-- The groundwork plan's ruling 2: this build's own files, recorded from it
-- (test/fixtures/groundwork-files.lua; its header says how), load as saved
test("this build's own files load: a format 9 scenes file, a PSET and its five side files", function()
  math.randomseed(SYSTEM.seed)
  local files = dofile(h.repo_root .. "/test/fixtures/groundwork-files.lua")
  local subdir, dir = fresh_dir("system-groundwork-files")
  local root = h.data_root .. subdir .. "/"
  local audio = root .. "audio/"
  os.execute("mkdir -p '" .. audio .. "'")
  local base = root .. "strata-05"
  write_text(dir .. "scenes.data", (files["scenes.data"]:gsub("@DATA@", root)))
  local pset_text = files["strata-05.pset"]:gsub("@AUDIO@", audio)
  write_text(base .. ".pset", pset_text)
  local sides = {"macros", "matrix", "gestures", "sequences", "scenes"}
  for _, key in ipairs(sides) do
    write_text(base .. "." .. key .. ".data", files["strata-05." .. key .. ".data"])
  end
  local context = load_strata({data_subdir = subdir}); finish_startup(context)
  local S = local_value("S")
  -- the live scenes file: format 9, held by PSET 5
  assert_equal(S.scene_file.problem, nil, "the scenes file loads")
  assert_equal(S.scene_file.pset, base, "naming the PSET that holds its scenes")
  assert_true(S.scenes[1].populated and S.scenes[4].populated, "scenes 1 and 4")
  assert_equal(S.lib.scenes.name(4), "four", "with scene 4's name")
  assert_equal(S.scenes[1].data.patterns[2][3], 9, "scene 1's voice 2 step 3 at level 9")
  local scenes_before = S.lib.data_files.encode(S.scenes)
  -- the PSET and its five side files
  local from = #context.printed + 1
  params:read(base .. ".pset")
  lfo_step(context, 3)
  local errors = error_lines(context, from)
  assert_equal(#errors, 0, "no line holding error: " .. table.concat(errors, " | "))
  local compared = 0
  for _, entry in ipairs(pset_lines(pset_text)) do
    local id = entry.id
    assert_true(params.lookup[id] ~= nil, id .. ": every line names a param of this build")
    if params:lookup_param(id).t ~= params.tGROUP then
      local number = tonumber(entry.value)
      if number and params:lookup_param(id).t ~= params.tTEXT then
        assert_near(params:get(id), number, 1e-9 * math.max(1, math.abs(number)), id .. " as saved")
      else
        assert_equal(tostring(params:get(id)), entry.value, id .. " as saved")
      end
      compared = compared + 1
    end
  end
  assert_true(compared > 800, compared .. " of the PSET's values compared")
  assert_equal(S.scenes[1].data.voices[1].source, 2, "scene 1 holds voice 1 on buffer 1")
  local routing = S.lib.matrix.routing(1)
  assert_equal(routing.source, "macro1", "routing 1 from the matrix file"); assert_equal(routing.dest, "v3_grain_pitch")
  assert_equal(S.lib.matrix.home(1), "v2_main", "LFO 1's home"); assert_equal(S.lib.matrix.home(2), "reverb_mix")
  local target = S.lib.macros.targets(1)[1]
  assert_equal(target.id, "reverb_mix", "macro 1's target from the macros file")
  assert_near(target.min, 0.2, 1e-9); assert_near(target.max, 0.8, 1e-9)
  assert_equal(S.lib.data_files.encode(S.scenes), scenes_before, "the PSET's scenes are the ones the live file held")
  assert_equal(S.scene_file.pset, base, "still held by PSET 5")
  assert_true(not util.file_exists(dir .. "scenes.data.bak"), "no backup: a PSET held the live scenes")
  for _, key in ipairs(sides) do
    assert_true(not util.file_exists(base .. "." .. key .. ".data.bak"), key .. ": nothing set aside")
  end
  cleanup()
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

-- Every extra note the engine was told to start, followed through the
-- calls as the notes area keeps its slots (docs/notes/engine/notes.md): a
-- noteOn on an empty slot, or on a releasing one (whose tail the engine
-- cuts first), starts a note; a noteOff ends a live note (cut 0 releases
-- it, cut 1 cuts it); voiceOff releases every live extra note of its voice.
-- Slot 0, the own note, only parks and is left out. Returns the notes still
-- live (as "voice:slot") and the problems: a noteOn on a live slot (a
-- second note where Lua started one) and a noteOff on a slot with no live
-- note (a note ended twice, or one never started)
local function engine_notes(context)
  local live, problems = {}, {}
  for index, call in ipairs(context.engine_calls) do
    local voice, slot = call.args[1], call.args[2]
    if (call.name == "noteOn" or call.name == "noteOff") and slot > 0 then
      local key = voice .. ":" .. slot
      if call.name == "noteOn" then
        if live[key] then problems[#problems + 1] = "call " .. index .. ": noteOn on live slot " .. key end
        live[key] = true
      else
        if not live[key] then problems[#problems + 1] = "call " .. index .. ": noteOff of slot " .. key .. " with no live note" end
        live[key] = nil
      end
    elseif call.name == "voiceOff" then
      for key in pairs(live) do
        if key:match("^(%d+):") == tostring(voice) then live[key] = nil end
      end
    end
  end
  local open = {}
  for key in pairs(live) do open[#open + 1] = key end
  table.sort(open)
  return open, problems
end

-- Every extra note the engine started was ended once, and none sounds on
local function assert_notes_ended(context, where)
  local open, problems = engine_notes(context)
  assert_equal(table.concat(problems, "; "), "", where .. ": no note started twice or ended twice")
  assert_equal(table.concat(open, " "), "", where .. ": no note left live in the engine")
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
  params:set("v1_source", option_index("v1_source", "buf 1"))
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
  -- every hit's slice (design §3.5, decision 23, the final review's I-2):
  -- on the own note (its region, then the retrigger, no node) while no
  -- earlier step's slice rings there, else in a slot of its own (its
  -- noteRegion, the slice's, right before its noteOn, and no retrigger)
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
  -- (an own hit of the slice the own note already holds sends no region: a
  -- one-shot hit of the same slice restarts it by the retrigger alone)
  local from, on_own, in_slots, last_own = started, 0, 0, {}
  for index, event in ipairs(state.events) do
    local where = "hit " .. index .. " (step " .. event.step .. ")"
    local window, own_region, region_at, note_ons, note_on_after, retriggers = {}, {}, nil, 0, false, 0
    for at = from + 1, event.calls do
      local call = context.engine_calls[at]
      if call.name == "noteRegion" and call.args[1] == 0 then window[#window + 1] = call; region_at = at end
      if call.name == "setGrainParam" and call.args[1] == 0 and call.args[2]:find("^region") then
        own_region[call.args[2]] = call.args[3]
      end
      if call.name == "retrigger" and call.args[1] == 0 then retriggers = retriggers + 1 end
      if call.name == "noteOn" and call.args[1] == 0 then
        note_ons = note_ons + 1
        if region_at then note_on_after = true end
      end
    end
    local start, length
    if #window == 0 then
      on_own = on_own + 1
      assert_equal(note_ons, 0, where .. ": on the own note, no node")
      assert_equal(retriggers, 1, where .. ": its retrigger")
      start = own_region.regionStart or last_own.regionStart
      length = own_region.regionLength or last_own.regionLength
      last_own = {regionStart = start, regionLength = length}
    else
      in_slots = in_slots + 1
      assert_equal(#window, 1, where .. ": one noteRegion")
      assert_equal(note_ons, 1, where .. ": one noteOn")
      assert_true(note_on_after, where .. ": its noteOn after its noteRegion")
      assert_equal(retriggers, 0, where .. ": no retrigger, the own note's slice rings on")
      start, length = window[1].args[3], window[1].args[4]
    end
    assert_near(start, (event.step - 1) / SYSTEM.slices, 1e-9, where .. ": slice " .. event.step .. "'s start")
    assert_near(length, 1 / SYSTEM.slices, 1e-9, where .. ": and its length")
    from = event.calls
  end
  assert_true(on_own > 1, "the own note takes a slice again once its last has played out (" .. on_own .. " hits)")
  assert_true(in_slots > on_own, "the others ring in slots of their own (" .. in_slots .. " hits)")
  assert_equal(on_own + in_slots, played, "every hit plays its slice")
  assert_equal(#calls_since(context, started, "voiceOn"), 0, "no hit starts a voice")
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
  assert_equal(#calls_since(context, started, "retrigger"), on_own, "one retrigger an own note's hit, none else")
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
  assert_notes_ended(context, "after the stops")
end)

-- The ways out (the brief's four), each on a fresh state playing for a bar
-- and a half with fill held by the 256's key and by the latch (seq_fill)
local WAYS_OUT = {
  {name = "a slot clear", run = function() clear_buffer(1) end},
  {name = "a source switch", run = function() params:set("v1_source", option_index("v1_source", "synth")) end},
  {name = "a PSET load", ends_routing = true, run = function(_, _, state) params:read(state.defaults_pset) end},
  {name = "cleanup", cleanup = true, run = function() cleanup() end},
}

-- The two orders fill's holders let go in after a way out. Each proves the
-- holder that lets go second still held: the latch first, then fill still
-- on is the key's alone; the key first, then it is the latch's. Cleanup ends
-- the key with its grid, so it runs once
local RELEASE_ORDERS = {"latch first", "key first"}

-- Fill after a way out that ends neither holder (rulings 10 and 11), its
-- two holders let go in order
local function release_fill(context, S, where, order)
  assert_true(S.lib.conditions.fill(), where .. ": fill still on")
  assert_equal(params:get("seq_fill"), 1, where .. ": the latch survives")
  if order == "latch first" then
    params:set("seq_fill", 0)
    assert_true(S.lib.conditions.fill(), where .. ": the latch let go, the key still holds")
    press_fill(context, 0)
  else
    press_fill(context, 0)
    assert_true(S.lib.conditions.fill(), where .. ": the key let go, the latch still holds")
    params:set("seq_fill", 0)
  end
  assert_true(not S.lib.conditions.fill(), where .. ": off once both have let go")
end

-- One way out on a fresh state, fill's holders let go in order after it
local function way_out(way, order)
  local where = way.cleanup and way.name or (way.name .. ", " .. order)
  local context, S, state = sliced_loop()
  pattern_clock_start()
  context.clock.run_for(bar_seconds())
  press_fill(context, 1)
  params:set("seq_fill", 1)
  context.clock.run_for(bar_seconds() / 2)
  assert_true(extra_slots(S) > 0, where .. ": slices sound in extra slots")
  assert_true(#engine_notes(context) > 0, where .. ": and in the engine")
  assert_true(S.lib.conditions.fill(), where .. ": fill held")
  assert_equal(#context.calls_named("stopFastEnv"), 0, where .. ": the route plays")
  local before = #context.engine_calls
  way.run(context, S, state)
  if way.cleanup then
    -- norns has freed the engine (docs/notes/lua/state-and-voices.md): step
    -- 160's voiceOffs, and the patterns' stop ending the own note's step
    -- region (its clear reaches no handler), are the only calls
    for index = before + 1, #context.engine_calls do
      local call = context.engine_calls[index]
      assert_true(call.name == "voiceOff" or (call.name == "setGrainParam" and call.args[2]:find("^region") ~= nil
        and call.args[3] == 0), "cleanup sends only its voiceOffs and the own region's clear (got " .. call.name .. ")")
    end
    assert_equal(extra_slots(S), 0, "cleanup: no slice note held")
    assert_notes_ended(context, "cleanup")
    -- the key's hold ended with its grid, with no release: only the latch is left
    assert_true(S.lib.conditions.fill(), "cleanup: the latch stays")
    params:set("seq_fill", 0)
    assert_true(not S.lib.conditions.fill(), "cleanup: the key holds no more")
    return
  end
  lfo_step(context, 3)
  assert_equal(extra_slots(S), 0, where .. ": no slice note held")
  assert_equal(#S.lib.slices.playing(1), 0, where .. ": no slice sounds")
  assert_equal(S.lib.notes.own_region(1), nil, where .. ": no own region")
  assert_notes_ended(context, where)
  release_fill(context, S, where, order)
  if not way.ends_routing then
    assert_equal(#calls_since(context, before, "stopFastEnv"), 0, where .. ": the routing plays on")
    S.lib.matrix.set_routing(SYSTEM.routings.envelope, "", "")
  end
  lfo_step(context, 6)
  local stops = calls_since(context, before, "stopFastEnv")
  assert_equal(#stops, 1, where .. ": one stopFastEnv at the routing's end")
  assert_equal(stops[1].args[1], SYSTEM.routings.envelope - 1, where .. ": route 0's")
  pattern_clock_stop()
  assert_notes_ended(context, where .. ", the patterns stopped")
end

test("every way out leaves nothing held", function()
  for _, way in ipairs(WAYS_OUT) do
    for index, order in ipairs(RELEASE_ORDERS) do
      if index == 1 or not way.cleanup then way_out(way, order) end
    end
  end
end)

end

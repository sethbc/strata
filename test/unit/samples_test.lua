-- test/unit/samples_test.lua
-- A file's settings (3.7, design §4, decision 10): lib/samples.lua's store
-- (samples.data, a take's record in buffers.data), the binds, the key's
-- pitch, the normalize gain and the tempo
-- Run alone: lua test/run.lua samples

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local wake_buffer_clock, write_text, file_text = h.wake_buffer_clock, h.write_text, h.file_text

local function samples() return local_value("S").lib.samples end

-- The engine's bufferState report of the slot's newest load, holding seconds
local function report(context, slot, seconds)
  local S = local_value("S")
  context.polls.fire("bufferState", context.polls.buffer_state_value(slot, S.buffers[slot].loads_sent, seconds))
end

-- Load path into the slot (from start) and let it take effect with seconds of
-- audio: over audio, the engine reports the load's 0 s first
local function settle_load(context, slot, path, seconds, start)
  local S = local_value("S")
  load_buffer(slot, path, start)
  if S.buffers[slot].awaiting_zero then report(context, slot, 0) end
  report(context, slot, seconds)
  assert_equal(S.lib.buffers.status(slot), "loaded", "slot " .. slot .. " holds " .. path)
end

-- A replace take of the slot, recorded and reported with seconds of audio
local function settle_take(context, slot, seconds)
  params:set("record_feedback", 0); params:set("record_loop", 1)
  params:set("record_duration", seconds)
  record_buffer(slot)
  wake_buffer_clock(context, slot)
  report(context, slot, seconds)
  assert_equal(local_value("S").buffers[slot].name, "take " .. slot)
end

local function record_state_value(number, state, slot) return ((number * 4) + state) * 8 + (slot - 1) end

-- An overdub of the slot that records and ends
local function overdub(context, slot)
  local S = local_value("S")
  params:set("record_feedback", 50)
  record_buffer(slot)
  local number = S.buffers[slot].records_sent
  context.polls.fire("recordState", record_state_value(number, 1, slot))
  context.polls.fire("recordState", record_state_value(number, 2, slot))
  params:set("record_feedback", 0)
end

-- Write the slot's peaks file as the engine does (frames at 48 kHz)
local function write_peaks(slot, seconds, largest)
  local folder = local_value("S").lib.scenes.scene_data_dir
  util.make_dir(folder)
  local parts = {}
  for index = 1, 64 do parts[index] = index == 10 and largest or "0.000" end
  write_text(folder .. "buf" .. slot .. ".peaks", string.format("strata-peaks 1\nslot %d\nframes %d\nrate 48000\n"
    .. "generation 1\npeaks %s\n", slot, math.floor(seconds * 48000), table.concat(parts, " ")))
end

local function tick(context, ticks)
  context.clock.run_for((ticks or 2) / local_value("UI_PAGES").FRAMES_PER_SECOND + 0.001)
end

local function gains(context)
  local list = {}
  for _, call in ipairs(context.calls_named("setSlotGain")) do list[#list + 1] = call.args end
  return list
end

-- The grain param name's values sent to engine voice since the last clear
local function grain_values(context, engine_voice, name)
  local list = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == engine_voice and call.args[2] == name then list[#list + 1] = call.args[3] end
  end
  return list
end

local function samples_file(context)
  return context.tab.load(context.data_dir .. "strata/samples.data")
end

test("a burst of sample edits encodes once at the first change and once to save the latest data (#1273)", function()
  local context = load_strata(); finish_startup(context)
  settle_load(context, 1, context.audio_dir .. "chords.wav", 4)
  context.clock.run_for(0.2)
  local data_files = local_value("S").lib.data_files
  local encode, encodes = data_files.encode, 0
  data_files.encode = function(value)
    if value.files then encodes = encodes + 1 end
    return encode(value)
  end
  assert_true(samples().set(1, "tempo", 90))
  assert_true(samples().set(1, "tempo", 95))
  assert_equal(encodes, 1, "a pending change shares the first edit's clock")
  context.clock.run_for(0.2)
  assert_equal(samples_file(context).files[1].settings.tempo, 95, "published the latest tempo")
  assert_equal(encodes, 2, "one more encoding at publication, reused for the cache")
end)

test("a file's settings come back when it is loaded into another slot", function()
  local context = load_strata(); finish_startup(context)
  local file = context.audio_dir .. "a.wav"
  settle_load(context, 1, file, 8)
  assert_true(samples().set(1, "tempo", 120)); assert_true(samples().set(1, "key", 57))
  assert_true(samples().set(1, "markers", { 0, 24000 }))
  clear_buffer(1)
  assert_equal(samples().settings(1), nil, "a cleared slot has no record")
  settle_load(context, 5, file, 8)
  local record = samples().settings(5)
  assert_equal(record.tempo, 120); assert_equal(record.key, 57)
  assert_equal(#record.markers, 2); assert_equal(record.markers[1], 0); assert_equal(record.markers[2], 24000)
  context.clock.run_for(0.11)  -- the write waits 0.1 s
  local saved = samples_file(context)
  assert_equal(saved.version, 1); assert_equal(#saved.files, 1)
  assert_equal(saved.files[1].path, file); assert_equal(saved.files[1].start, 0)
  assert_equal(saved.files[1].settings.tempo, 120)
  -- and in the next session
  cleanup()
  local again = load_strata({ data_subdir = context.data_dir:match("([^/]+)/$") }); finish_startup(again)
  settle_load(again, 2, file, 8)
  assert_equal(samples().settings(2).key, 57, "remembered across sessions")
end)

-- 3.8 (4d, ruling 53): a factory set's records are checked before they are
-- stored, as a samples.data entry is
test("store_file refuses a record its checks refuse", function()
  local context = load_strata(); finish_startup(context)
  local file = context.audio_dir .. "refused.wav"
  assert_equal(samples().store_file(file, { tempo = 1000 }), false, "a tempo of 1000 is refused")
  settle_load(context, 1, file, 8)
  assert_equal(samples().settings(1).tempo, nil, "nothing was stored for the file")
  context.clock.run_for(0.11)
  local saved = samples_file(context)
  assert_true(saved == nil or #saved.files == 0 or saved.files[1].settings.tempo == nil, "nor written")
  local good = context.audio_dir .. "kept.wav"
  assert_equal(samples().store_file(good, { tempo = 90, key = 57 }), true, "a record the checks take is stored")
  settle_load(context, 2, good, 8)
  assert_equal(samples().settings(2).tempo, 90)
  assert_equal(samples().settings(2).mode, 1, "a field the record lacks takes its default")
end)

test("a start point is part of the key", function()
  local context = load_strata(); finish_startup(context)
  local file = context.audio_dir .. "long.wav"
  context.audio.register(file, { channels = 2, frames = 48000 * 60, rate = 48000 })
  settle_load(context, 1, file, 16)
  samples().set(1, "tempo", 120)
  settle_load(context, 2, file, 16, 2)
  assert_equal(samples().settings(2).tempo, nil, "from 2 s: another record")
  samples().set(2, "tempo", 90)
  clear_buffer(1); settle_load(context, 1, file, 16)
  assert_equal(samples().tempo(1), 120, "from 0 s: its own")
  assert_equal(samples().tempo(2), 90)
end)

test("a take's settings stay with its slot until it is cleared or recorded over", function()
  local subdir = "samples-take-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  settle_take(context, 2, 4)
  assert_true(samples().set(2, "tempo", 100))
  settle_load(context, 3, context.audio_dir .. "other.wav", 4)
  clear_buffer(3)
  assert_equal(samples().tempo(2), 100, "other slots' loads and clears leave it")
  util.make_dir(context.audio_dir .. "strata/scratch/")
  io.open(scratch_take_path(2), "w"):close()  -- the engine wrote the take
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.settings[2].tempo, 100, "kept in buffers.data")
  assert_equal(saved.settings[1], false, "a slot without a take's record")
  local samples_saved = samples_file(context)
  assert_equal(#samples_saved.files, 0, "a take is not a file's entry")
  -- restored with its take
  context = load_strata({ data_subdir = subdir }); finish_startup(context)
  report(context, 2, 4)
  assert_equal(samples().tempo(2), 100, "the restored take's record")
  -- recorded over by a replace take: dropped
  settle_take(context, 2, 3)
  assert_equal(samples().tempo(2), nil, "a replace take starts with no settings")
  samples().set(2, "tempo", 80)
  clear_buffer(2)
  settle_take(context, 2, 3)
  assert_equal(samples().tempo(2), nil, "a clear drops it")
end)

test("an overdub of a file makes a take that starts with the file's settings and leaves the file's alone",
    function()
  local context = load_strata(); finish_startup(context)
  local file = context.audio_dir .. "a.wav"
  settle_load(context, 1, file, 8)
  samples().set(1, "tempo", 120); samples().set(1, "key", 57)
  overdub(context, 1)
  local S = local_value("S")
  assert_equal(S.buffers[1].path, scratch_take_path(1), "the slot holds a take")
  assert_equal(samples().tempo(1), 120, "a copy of the file's")
  assert_equal(samples().settings(1).key, 57)
  samples().set(1, "key", 62)
  settle_load(context, 4, file, 8)
  assert_equal(samples().settings(4).key, 57, "the file's own is untouched")
  assert_equal(samples().settings(1).key, 62)
  -- an overdub of a take keeps the take's record
  overdub(context, 1)
  assert_equal(samples().settings(1).key, 62, "a take dubbed keeps its own")
end)

test("a whole save copies the settings to the saved file; a loop save does not", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  settle_take(context, 2, 4)
  samples().set(2, "tempo", 100); samples().set(2, "key", 50)
  local function save_result(slot, failed)
    local number = S.buffers[slot].saves_sent
    -- the engine wrote the file (so the next save's name is another)
    if not failed then io.open(S.buffers[slot].pending_saves[1].path, "w"):close() end
    context.save_result(((number * 2) + (failed and 1 or 0)) * 8 + slot - 1)
  end
  assert_true(save_buffer(2))
  local whole = S.buffers[2].pending_saves[1].path
  samples().set(2, "key", 52)  -- after the send: the save holds the audio as it was sent
  save_result(2, false)
  assert_true(save_buffer_loop(2))
  local loop = S.buffers[2].pending_saves[1].path
  save_result(2, false)
  assert_true(save_buffer(2))
  local failed = S.buffers[2].pending_saves[1].path
  save_result(2, true)
  settle_load(context, 3, whole, 4)
  assert_equal(samples().tempo(3), 100, "a whole save's file has the take's settings")
  assert_equal(samples().settings(3).key, 50, "as they were when it was sent")
  settle_load(context, 4, loop, 2)
  assert_equal(samples().tempo(4), nil, "a loop save copies nothing")
  settle_load(context, 5, failed, 4)
  assert_equal(samples().tempo(5), nil, "a failed save copies nothing")
end)

test("past 256 files the least recently loaded is dropped", function()
  local context = load_strata(); finish_startup(context)
  local max = samples().SAMPLES.max_files
  assert_equal(max, 256)
  for n = 1, max + 1 do
    settle_load(context, 1, context.audio_dir .. "f" .. n .. ".wav", 4)
    samples().set(1, "tempo", 60 + n % 200)
  end
  context.clock.run_for(0.11)
  assert_equal(#samples_file(context).files, max, "the file holds 256")
  settle_load(context, 2, context.audio_dir .. "f2.wav", 4)
  assert_equal(samples().tempo(2), 62, "the second is kept")
  settle_load(context, 3, context.audio_dir .. "f1.wav", 4)
  assert_equal(samples().tempo(3), nil, "the first, least recently loaded, is gone")
end)

test("an unreadable samples.data is set aside and the slots still load", function()
  for _, case in ipairs({ { name = "text", text = "{ not lua" },
      { name = "another version", text = h.tabutil_text({ version = 9, files = {} }) },
      { name = "not a list", text = h.tabutil_text({ version = 1, files = "x" }) } }) do
    local subdir = "samples-unreadable-" .. math.random(1, 1e9)
    local dir = h.data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. dir .. "'")
    write_text(dir .. "samples.data", case.text)
    -- a remembered buffer path the restore at start loads
    local audio = h.data_root .. subdir .. "/audio/"
    os.execute("mkdir -p '" .. audio .. "'")
    local kept = audio .. "kept.wav"
    io.open(kept, "w"):close()
    write_text(dir .. "buffers.data", h.tabutil_text({ version = 2, paths = { "", kept }, starts = { 0, 0 } }))
    local context = load_strata({ data_subdir = subdir }); finish_startup(context)
    assert_equal(file_text(dir .. "samples.data.bak"), case.text, case.name .. ": set aside whole")
    local said = 0
    for _, line in ipairs(context.printed) do if line:find("samples.data", 1, true) then said = said + 1 end end
    assert_equal(said, 1, case.name .. ": one console line")
    local loads = context.calls_named("loadBuffer")
    assert_equal(#loads, 1, case.name .. ": the restore loads"); assert_equal(loads[1].args[2], kept)
    report(context, 2, 4)
    assert_equal(local_value("S").lib.buffers.status(2), "loaded", case.name .. ": the restored slot holds it")
    assert_equal(samples().tempo(2), nil, case.name .. ": with no settings")
    settle_load(context, 1, context.audio_dir .. "a.wav", 4)
    assert_equal(samples().tempo(1), nil, case.name .. ": no settings")
    assert_true(samples().set(1, "tempo", 99), case.name .. ": the store works")
    context.clock.run_for(0.11)
    assert_equal(samples_file(context).files[1].settings.tempo, 99, case.name .. ": a new file")
  end
end)

-- 3.9 (#906): the writer's gate, as buffers.data's: a samples.data that can
-- be neither used nor set aside is written over neither by a timed write
-- nor at cleanup
test("a samples.data that cannot be set aside is never written over", function()
  local subdir = "samples-unmovable-" .. math.random(1, 1e9)
  local dir = h.data_root .. subdir .. "/strata/"
  -- every backup name is taken (by a folder): the file cannot be moved aside
  os.execute("mkdir -p '" .. dir .. "samples.data.bak'")
  for number = 2, 9 do os.execute("mkdir -p '" .. dir .. "samples.data.bak." .. number .. "'") end
  write_text(dir .. "samples.data", "{ not lua")
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  settle_load(context, 1, context.audio_dir .. "a.wav", 4)
  assert_true(samples().set(1, "tempo", 99), "the store works")
  context.clock.run_for(0.2)
  assert_equal(file_text(dir .. "samples.data"), "{ not lua", "no timed write over it")
  cleanup()
  assert_equal(file_text(dir .. "samples.data"), "{ not lua", "nor at cleanup")
end)

test("damaged samples.data entries are left out with one console line naming how many", function()
  local subdir = "samples-damaged-" .. math.random(1, 1e9)
  local dir = h.data_root .. subdir .. "/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  local good = h.data_root .. subdir .. "/audio/good.wav"
  write_text(dir .. "samples.data", h.tabutil_text({ version = 1, files = {
    { path = good, start = 0, used = 3, settings = { tempo = 120 } },
    { path = "/x/bad-tempo.wav", start = 0, used = 2, settings = { tempo = 1000 } },
    { path = 5, start = 0, used = 1, settings = { tempo = 90 } } } }))
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local said = {}
  for _, line in ipairs(context.printed) do if line:find("samples.data", 1, true) then said[#said + 1] = line end end
  assert_equal(#said, 1, "one console line")
  assert_true(said[1]:find("2 ", 1, true) ~= nil, "it names the count: " .. tostring(said[1]))
  assert_true(not util.file_exists(dir .. "samples.data.bak"), "the file is used, not set aside")
  settle_load(context, 1, good, 4)
  assert_equal(samples().tempo(1), 120, "the good entry loads")
end)

test("an undamaged samples.data says nothing", function()
  local subdir = "samples-clean-" .. math.random(1, 1e9)
  local dir = h.data_root .. subdir .. "/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  write_text(dir .. "samples.data", h.tabutil_text({ version = 1, files = {
    { path = "/x/good.wav", start = 0, used = 3, settings = { tempo = 120 } } } }))
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  for _, line in ipairs(context.printed) do
    assert_true(not line:find("samples.data", 1, true), "nothing said: " .. line)
  end
end)

test("a record at its defaults is not written", function()
  local context = load_strata(); finish_startup(context)
  settle_load(context, 1, context.audio_dir .. "a.wav", 4)
  samples().set(1, "tempo", 120)
  context.clock.run_for(0.11)
  assert_equal(#samples_file(context).files, 1)
  samples().set(1, "tempo", nil)
  context.clock.run_for(0.11)
  assert_equal(#samples_file(context).files, 0, "back at its defaults: no entry")
  settle_take(context, 2, 2)
  samples().set(2, "normalize", true); samples().set(2, "normalize", false)
  context.clock.run_for(0.11)
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.settings[2], false, "a take's record at its defaults")
  -- refused values change nothing
  assert_equal(samples().set(1, "tempo", 19), false); assert_equal(samples().set(1, "tempo", 301), false)
  assert_equal(samples().set(1, "key", 57.5), false); assert_equal(samples().set(1, "key", 128), false)
  assert_equal(samples().set(1, "markers", { 10, 20 }), false, "the first marker is 0")
  assert_equal(samples().set(1, "markers", { 0, 20, 10 }), false, "ascending")
  assert_equal(samples().set(1, "mode", 4), false); assert_equal(samples().set(1, "count", 1), false)
  assert_equal(samples().set(1, "sensitivity", 101), false); assert_equal(samples().set(1, "normalize", 1), false)
  assert_equal(samples().set(1, "shade", 1), false, "an unknown field")
  assert_equal(samples().set(6, "tempo", 120), false, "a slot with no audio")
  assert_equal(samples().settings(1).tempo, nil)
  local record = samples().settings(1)
  assert_equal(record.normalize, false); assert_equal(record.mode, 1); assert_equal(record.count, 8)
  assert_equal(record.sensitivity, 50); assert_equal(record.edited, false); assert_equal(record.markers, nil)
end)

test("a bind clears nothing by itself and tells its listeners; a clear unbinds", function()
  local context = load_strata(); finish_startup(context)
  local told = {}
  samples().on_bind(function(slot) told[#told + 1] = slot end)
  samples().on_bind(function() error("a listener that fails") end)
  local file = context.audio_dir .. "a.wav"
  settle_load(context, 3, file, 4)
  assert_equal(table.concat(told, " "), "3", "the load's bind")
  samples().set(3, "tempo", 110)
  samples().bind(3)
  assert_equal(samples().tempo(3), 110, "a bind keeps the record")
  clear_buffer(3)
  assert_equal(table.concat(told, " "), "3 3 3", "and the clear's unbind")
  assert_equal(samples().settings(3), nil)
  -- a failed load's undo binds what it puts back
  settle_load(context, 3, file, 4)
  load_buffer(3, context.audio_dir .. "missing.wav")
  context.polls.fire("bufferLoadFailed", ((local_value("S").buffers[3].loads_sent * 2) * 8) + 2)
  assert_equal(local_value("S").buffers[3].path, file)
  assert_equal(samples().tempo(3), 110, "the undo's bind")
  assert_equal(told[#told], 3)
  assert_equal(#context.take_script_errors(), 1, "the failing listener is printed once")
end)

-- A buffer voice reading slot 1, running
local function buffer_voice(context, voice_idx, slot)
  local S = local_value("S")
  params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_SYNTH + (slot or 1))
  if not S.voices[voice_idx].active then toggle_voice(voice_idx) end
end

local function note_on(context, note)
  context.midi.send(1, { type = "note_on", note = note, vel = 100, ch = 1 })
end

-- 3.6's pitch, as a patched build: the variation's sync without its rootNote
-- line, and lib/samples.lua's key functions 3.6's constants (60, none)
local function pitch_36_sources()
  local function read(path)
    local file = assert(io.open(h.repo_root .. "/" .. path, "r")); local text = file:read("*a"); file:close()
    return text
  end
  local function replace(text, old, new)
    local at = text:find(old, 1, true); assert(at, old)
    return text:sub(1, at - 1) .. new .. text:sub(at + #old)
  end
  local variation = replace(read("lib/variation.lua"),
    '      engine.setGrainParam(voice_idx - 1, "rootNote", S.lib.samples.rate_root(voice_idx))\n', "")
  local samples_text = read("lib/samples.lua")
  samples_text = replace(samples_text, "return voice_key(voice) or S.lib.notes.NOTES.rate_root_note", "return 60")
  samples_text = replace(samples_text, "function M.scale_reference(voice) return voice_key(voice) end",
    "function M.scale_reference(voice) return nil end")
  return { ["lib/variation"] = variation, ["lib/samples"] = samples_text }
end

-- A buffer voice's engine calls (voice 1's) for a source change's sync, a
-- MIDI note and a step with a chord, on a file with no key
local function pitch_scenario(module_sources)
  math.randomseed(37)
  local context = load_strata({ module_sources = module_sources }); finish_startup(context)
  local S = local_value("S")
  settle_load(context, 1, context.audio_dir .. "a.wav", 8)
  local function voice_calls()
    local list = {}
    for _, call in ipairs(context.engine_calls) do
      if call.args[1] == 0 then
        local parts = {}
        for index, value in ipairs(call.args) do
          parts[index] = type(value) == "number" and string.format("%.6f", value) or tostring(value)
        end
        list[#list + 1] = call.name .. "(" .. table.concat(parts, ", ") .. ")"
      end
    end
    context.clear_engine_calls()
    return list
  end
  context.clear_engine_calls()
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)  -- running: a full sync
  local sync = voice_calls()
  context.midi.send(1, { type = "note_on", note = 72, vel = 100, ch = 1 })
  local midi_note = voice_calls()
  context.midi.send(1, { type = "note_off", note = 72, vel = 0, ch = 1 })
  reset_midi_input()
  voice_calls()
  S.patterns[1][1] = 15
  S.lib.sequencer.set_step_attr(1, 1, "notes", { 0, 7 })
  pattern_clock_start()
  context.clock.run_for(0.05)
  pattern_clock_stop()
  local step = voice_calls()
  return { sync = sync, midi = midi_note, step = step }
end

test("an unset key is 3.6's pitch: every call of a sync, a MIDI note and a step, rootNote 60 added", function()
  local expected = pitch_scenario(pitch_36_sources())
  local actual = pitch_scenario(nil)
  for _, kind in ipairs({ "sync", "midi", "step" }) do
    local without, roots = {}, {}
    for _, text in ipairs(actual[kind]) do
      if text:find("^setGrainParam%(0%.000000, rootNote,") then roots[#roots + 1] = text
      else without[#without + 1] = text end
    end
    assert_true(#expected[kind] > 0, kind .. ": calls to compare")
    assert_equal(table.concat(without, "\n"), table.concat(expected[kind], "\n"), kind .. ": 3.6's calls")
    for _, text in ipairs(roots) do
      assert_equal(text, "setGrainParam(0.000000, rootNote, 60.000000)", kind .. ": rootNote 60")
    end
    assert_equal(#roots, kind == "sync" and 1 or 0, kind .. ": rootNote only in the sync")
  end
  -- what 3.6 plays: note 72 at rate 2, the chord's fifth over it an extra note at 2 x 2 ^ (7 / 12)
  local found_rate, found_extra = false, false
  for _, text in ipairs(actual.midi) do
    if text == "setGrainParam(0.000000, bufRate, 2.000000)" then found_rate = true end
  end
  for _, text in ipairs(actual.step) do
    if text:find("^noteOn%(0%.000000, 1%.000000, ") and text:find(string.format("%.6f", 2 * 2 ^ (7 / 12)), 1, true) then
      found_extra = true
    end
  end
  assert_true(found_rate, "the MIDI note's rate 2: " .. table.concat(actual.midi, " | "))
  assert_true(found_extra, "the step's extra note: " .. table.concat(actual.step, " | "))
end)

test("an unset key is note 60 at rate 1 and the scale's root + 60 as the reference", function()
  local context = load_strata(); finish_startup(context)
  settle_load(context, 1, context.audio_dir .. "a.wav", 8)
  params:set("midi_channel_mode", 2)  -- omni: the selected voice
  local S = local_value("S")
  S.lib.ui_keys.select_voice_by(1 - S.selected_voice)
  context.clear_engine_calls()
  buffer_voice(context, 1)
  assert_equal(samples().rate_root(1), 60); assert_equal(samples().scale_reference(1), nil)
  local roots = grain_values(context, 0, "rootNote")
  assert_true(#roots >= 1, "a voice sync sends rootNote"); assert_equal(roots[#roots], 60)
  local scale_notes = grain_values(context, 0, "scaleNote")
  assert_equal(scale_notes[#scale_notes], 60, "the root C + 60")
  note_on(context, 72)
  assert_near(params:get("v1_buf_rate"), 2, 1e-9, "note 72: rate 2")
  assert_near(S.lib.notes.note_values(1, 67).rate, 2 ^ (7 / 12), 1e-9, "an extra note's rate")
  assert_equal(#context.calls_named("setSlotGain"), 0, "no gain")
end)

test("a key of 57 makes note 57 rate 1 and the quantize reference", function()
  local context = load_strata(); finish_startup(context)
  settle_load(context, 1, context.audio_dir .. "a.wav", 8)
  local S = local_value("S")
  params:set("midi_channel_mode", 2)
  S.lib.ui_keys.select_voice_by(1 - S.selected_voice)
  samples().set(1, "key", 57)
  context.clear_engine_calls()
  buffer_voice(context, 1)
  assert_equal(samples().rate_root(1), 57); assert_equal(samples().scale_reference(1), 57)
  local roots = grain_values(context, 0, "rootNote")
  assert_equal(roots[#roots], 57, "the sync's rootNote")
  local scale_notes = grain_values(context, 0, "scaleNote")
  assert_equal(scale_notes[#scale_notes], 57, "the quantize reference")
  note_on(context, 69)
  assert_near(params:get("v1_buf_rate"), 2, 1e-9, "note 69: rate 2")
  assert_near(S.lib.notes.note_values(1, 57).rate, 1, 1e-9, "note 57: rate 1")
  -- a step's degrees count from 57 + 12 log2(rate)
  params:set("scale", 2)  -- a scale on: degrees are its tones
  assert_near(S.lib.sequencer.degree_semitones(1, 0), 0, 1e-9)
  local degree = S.lib.sequencer.degree_semitones(1, 1)
  local expected = nil
  local mask, root = S.lib.variation.scale_mask(), S.lib.variation.root()
  for tone = 70, 82 do
    if math.floor(mask / 2 ^ ((tone - root) % 12)) % 2 == 1 then expected = tone - 69; break end
  end
  assert_near(degree, expected, 1e-9, "the tone above 69 (rate 2 over 57)")
  -- an input voice is untouched
  params:set("v2_source", S.constants.SOURCE_INPUT)
  assert_equal(samples().rate_root(2), 60); assert_equal(samples().scale_reference(2), nil)
end)

test("one file in two slots: a key or normalize set through one acts for both", function()
  local context = load_strata(); finish_startup(context)
  local file = context.audio_dir .. "a.wav"
  settle_load(context, 1, file, 8); settle_load(context, 5, file, 8)
  buffer_voice(context, 1, 1); buffer_voice(context, 2, 5)
  write_peaks(1, 8, "0.250"); write_peaks(5, 8, "0.500")
  local_value("S").lib.waveforms.stale(1); tick(context); local_value("S").lib.waveforms.stale(5); tick(context)
  context.clear_engine_calls()
  samples().set(1, "key", 57)
  assert_equal(samples().settings(5).key, 57, "one record")
  for engine_voice = 0, 1 do
    assert_equal(grain_values(context, engine_voice, "rootNote")[1], 57, "voice " .. engine_voice + 1 .. "'s rootNote")
    assert_equal(grain_values(context, engine_voice, "scaleNote")[1], 57, "voice " .. engine_voice + 1 .. "'s scaleNote")
  end
  context.clear_engine_calls()
  samples().set(5, "normalize", true)
  local by_slot = {}
  for _, args in ipairs(gains(context)) do by_slot[args[1]] = args[2] end
  assert_near(by_slot[0], 4, 1e-9, "slot 1 from its peaks"); assert_near(by_slot[4], 2, 1e-9, "slot 5 from its own")
end)

test("setting the key, and a bind, resend scaleNote and rootNote to running voices of the slot", function()
  local context = load_strata(); finish_startup(context)
  settle_load(context, 1, context.audio_dir .. "a.wav", 8)
  settle_load(context, 2, context.audio_dir .. "b.wav", 8)
  buffer_voice(context, 1, 1); buffer_voice(context, 2, 1); buffer_voice(context, 3, 2)
  context.clear_engine_calls()
  samples().set(1, "key", 64)
  for engine_voice = 0, 1 do
    assert_equal(grain_values(context, engine_voice, "rootNote")[1], 64, "voice " .. engine_voice + 1)
    assert_equal(grain_values(context, engine_voice, "scaleNote")[1], 64)
  end
  assert_equal(#grain_values(context, 2, "rootNote"), 0, "a voice of another slot")
  -- a bind of a file with no key: back to 60 and the root's reference
  context.clear_engine_calls()
  settle_load(context, 1, context.audio_dir .. "c.wav", 8)
  assert_equal(grain_values(context, 0, "rootNote")[1], 60)
  assert_equal(grain_values(context, 1, "scaleNote")[1], 60)
  assert_equal(#grain_values(context, 2, "scaleNote"), 0)
  -- a stopped voice gets nothing until its start
  toggle_voice(2)
  context.clear_engine_calls()
  settle_load(context, 1, context.audio_dir .. "a.wav", 8)
  assert_equal(#grain_values(context, 1, "rootNote"), 0, "voice 2 is stopped")
  assert_equal(grain_values(context, 0, "rootNote")[1], 64)
  -- a clear's unbind: back to 60 and the root's reference
  context.clear_engine_calls()
  clear_buffer(1)
  assert_equal(grain_values(context, 0, "rootNote")[1], 60, "a clear: rootNote 60")
  assert_equal(grain_values(context, 0, "scaleNote")[1], 60, "a clear: root C + 60")
  assert_equal(#grain_values(context, 2, "rootNote"), 0, "a voice of another slot")
  settle_load(context, 1, context.audio_dir .. "a.wav", 8)
  -- a source change moves a running voice's rootNote
  context.clear_engine_calls()
  params:set("v1_source", local_value("S").constants.SOURCE_SYNTH + 2)
  local roots = grain_values(context, 0, "rootNote")
  assert_equal(roots[#roots], 60, "slot 2 has no key")
end)

test("normalize sends the gain when the slot's peaks are read, never at a bind", function()
  local context = load_strata(); finish_startup(context)
  local file = context.audio_dir .. "a.wav"
  settle_load(context, 1, file, 8)
  write_peaks(1, 8, "0.250"); tick(context)
  assert_equal(#gains(context), 0, "normalize off: nothing")
  assert_equal(samples().gain(1), 1)
  samples().set(1, "normalize", true)
  local sent = gains(context)
  assert_equal(#sent, 1); assert_equal(sent[1][1], 0); assert_near(sent[1][2], 4, 1e-9, "peak 0.25: gain 4")
  assert_near(samples().gain(1), 4, 1e-9)
  -- a reload of the same file: the engine's gain is 1 again until its peaks are read
  context.clear_engine_calls()
  settle_load(context, 1, file, 8)
  assert_equal(#gains(context), 0, "a bind sends none")
  tick(context)
  sent = gains(context)
  assert_equal(#sent, 1, "sent again after its peaks are read"); assert_near(sent[1][2], 4, 1e-9)
  -- The 16-bit peaks at 9 and 25 / 32768 share the first positive
  -- bin in the engine's file. Only a file of zeros means silence.
  for _, case in ipairs({
    { peak = "0.000", gain = 1 }, { peak = "0.001", gain = 16 },
    { peak = "0.062", gain = 16 }, { peak = "0.063", gain = 1 / 0.063 },
    { peak = "0.125", gain = 8 }, { peak = "1.000", gain = 1 },
  }) do
    context.clear_engine_calls()
    write_peaks(1, 8, case.peak); local_value("S").lib.waveforms.stale(1); tick(context)
    sent = gains(context)
    assert_equal(#sent, 1); assert_near(sent[1][2], case.gain, 1e-9, "peak " .. case.peak)
  end
  context.clear_engine_calls()
  samples().set(1, "normalize", false)
  sent = gains(context)
  assert_equal(#sent, 1); assert_near(sent[1][2], 1, 1e-9, "normalize off: 1")
  -- while the slot records, the engine's 1 stands; its end's peaks send it
  samples().set(1, "normalize", true)
  write_peaks(1, 8, "0.500")
  context.clear_engine_calls()
  params:set("record_feedback", 50)
  record_buffer(1)
  local number = local_value("S").buffers[1].records_sent
  context.polls.fire("recordState", record_state_value(number, 1, 1))
  local_value("S").lib.waveforms.stale(1); tick(context)
  assert_equal(#gains(context), 0, "a dub is heard at its own level")
  context.polls.fire("recordState", record_state_value(number, 2, 1))
  tick(context)
  sent = gains(context)
  assert_equal(#sent, 1, "the take's peaks"); assert_near(sent[1][2], 2, 1e-9)
  -- an armed dub canceled: the engine set 1 at its command; the slot's
  -- peaks read again send its gain
  params:set("record_sync", 2)
  context.clear_engine_calls()
  record_buffer(1)
  number = local_value("S").buffers[1].records_sent
  context.polls.fire("recordState", record_state_value(number, 0, 1))
  context.polls.fire("recordState", record_state_value(number, 3, 1))
  tick(context)
  sent = gains(context)
  assert_equal(#sent, 1, "a canceled dub: the gain again"); assert_near(sent[1][2], 2, 1e-9)
end)

-- The binding names the audio that plays (fix round 2's ruling): a replace
-- take the engine empties at once (a threshold, no delay) unbinds at its
-- send; a synced one when the engine empties the slot (its 0 s report) or
-- at its start; a cancel after the slot was emptied leaves it unbound, so a
-- later dub into the empty slot starts with no settings
test("a replace take canceled after its slot was emptied leaves it unbound; a later dub has no settings", function()
  for _, case in ipairs({ { name = "a threshold", threshold = 2, sync = 1 },
      { name = "a synced take in its last 0.21 s", threshold = 1, sync = 2 },
      -- its emptying unreported before the cancel: the cancel's 0 s report unbinds
      { name = "a synced take whose emptying went unreported", threshold = 1, sync = 2, unreported = true } }) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    settle_load(context, 1, context.audio_dir .. "a.wav", 8)
    buffer_voice(context, 1, 1)
    samples().set(1, "key", 57); samples().set(1, "tempo", 133)
    local told = 0
    samples().on_bind(function(slot) if slot == 1 then told = told + 1 end end)
    params:set("record_feedback", 0); params:set("record_threshold", case.threshold)
    params:set("record_sync", case.sync)
    context.clock.run_for(1)
    context.clear_engine_calls()
    record_buffer(1)
    local number = S.buffers[1].records_sent
    context.polls.fire("recordState", record_state_value(number, 0, 1))
    if not case.unreported then
      report(context, 1, 0)  -- the engine emptied the slot for the take
      assert_equal(told, 1, case.name .. ": unbound once the old audio stops")
      assert_equal(grain_values(context, 0, "rootNote")[1], 60, case.name .. ": the voice's rootNote back to 60")
    end
    record_buffer(1)       -- K3: canceled while armed
    context.polls.fire("recordState", record_state_value(number, 3, 1))
    report(context, 1, 0)
    assert_equal(grain_values(context, 0, "rootNote")[1], 60, case.name .. ": rootNote 60 by the cancel's report")
    assert_equal(S.lib.buffers.status(1), "empty", case.name .. ": the slot is empty")
    assert_equal(told, 1, case.name .. ": told once")
    -- a dub into the empty slot
    params:set("record_feedback", 50); params:set("record_threshold", 1); params:set("record_sync", 1)
    record_buffer(1)
    number = S.buffers[1].records_sent
    context.polls.fire("recordState", record_state_value(number, 1, 1))
    report(context, 1, 4)
    record_buffer(1)
    context.polls.fire("recordState", record_state_value(number, 2, 1))
    local record = samples().settings(1)
    assert_true(record ~= nil, case.name .. ": the dub's take has a record")
    assert_equal(record.key, nil, case.name .. ": not the old file's key")
    assert_equal(record.tempo, nil, case.name .. ": nor its tempo")
  end
end)

-- a canceled take that had never emptied its slot (a synced one before its
-- preparation) puts the old audio back, still bound, with its settings
test("a synced take canceled before its slot was emptied keeps the old file's settings", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  settle_load(context, 1, context.audio_dir .. "a.wav", 8)
  samples().set(1, "key", 57)
  local told = 0
  samples().on_bind(function() told = told + 1 end)
  params:set("record_feedback", 0); params:set("record_sync", 2)
  record_buffer(1)
  local number = S.buffers[1].records_sent
  context.polls.fire("recordState", record_state_value(number, 0, 1))
  assert_equal(samples().settings(1).key, 57, "through the arm wait")
  record_buffer(1)
  context.polls.fire("recordState", record_state_value(number, 3, 1))
  report(context, 1, 8)  -- the old audio still in place
  assert_equal(S.lib.buffers.status(1), "loaded")
  assert_equal(samples().settings(1).key, 57, "the old file's settings")
  assert_equal(told, 1, "the put-back's bind")
end)

test("bars and tempo set each other", function()
  local context = load_strata(); finish_startup(context)
  settle_load(context, 1, context.audio_dir .. "a.wav", 8)
  assert_equal(samples().bars(1), nil, "no tempo: no bars")
  samples().set(1, "tempo", 120)
  assert_near(samples().bars(1), 4, 1e-9, "8 s at 120: 4 bars")
  assert_true(samples().set_bars(1, 2))
  assert_near(samples().tempo(1), 60, 1e-9, "2 bars: 60 BPM")
  assert_equal(samples().set_bars(1, 16), false, "480 BPM is refused")
  assert_equal(samples().set_bars(1, 32), false, "960 BPM is refused")
  assert_equal(samples().set_bars(1, 0.25), false, "7.5 BPM is refused")
  assert_near(samples().tempo(1), 60, 1e-9, "unchanged")
  assert_equal(samples().bars(2), nil, "an empty slot")
end)

test("a synced take takes the clock's tempo", function()
  local context = load_strata(); finish_startup(context)
  local seen = {}
  samples().on_bind(function(slot)
    local tempo = samples().tempo(slot)
    seen[#seen + 1] = slot .. ":" .. (tempo and string.format("%g", tempo) or "none")
  end)
  params:set("clock_tempo", 100); context.clock.run_for(1)
  params:set("record_sync", 2); params:set("record_beats", 4)
  record_buffer(2)
  local S = local_value("S")
  local number = S.buffers[2].records_sent
  context.polls.fire("recordState", record_state_value(number, 1, 2))
  params:set("clock_tempo", 130)  -- a change after its start counts for nothing
  wake_buffer_clock(context, 2)
  context.polls.fire("recordState", record_state_value(number, 2, 2))
  report(context, 2, 2.4)
  assert_equal(S.buffers[2].name, "take 2")
  assert_near(samples().tempo(2), 100, 1e-9, "the clock's tempo at its start")
  assert_equal(seen[#seen], "2:100", "its bind's listeners see the tempo")
  -- a synced overdub of a file: the take's, never the file's
  settle_load(context, 3, context.audio_dir .. "a.wav", 8)
  params:set("clock_tempo", 90)
  params:set("record_feedback", 50)
  record_buffer(3)
  number = S.buffers[3].records_sent
  context.polls.fire("recordState", record_state_value(number, 1, 3))
  context.polls.fire("recordState", record_state_value(number, 2, 3))
  assert_near(samples().tempo(3), 90, 1e-9, "the dub's take")
  assert_equal(seen[#seen], "3:90", "the dub's bind's listeners see it too")
  settle_load(context, 4, context.audio_dir .. "a.wav", 8)
  assert_equal(samples().tempo(4), nil, "the file has none")
  -- sync off: no tempo
  params:set("record_sync", 1); params:set("record_feedback", 0)
  settle_take(context, 5, 2)
  assert_equal(samples().tempo(5), nil)
end)

-- 3.9 (#907): the "settings binding" invariant: a slot that holds settled
-- audio is bound, and a free one is not. Each state is put in through the
-- binding's own calls, out of turn
test("the settings binding invariant: settled audio is bound, a free slot is not (#907)", function()
  local context = load_strata(); finish_startup(context)
  h.allow_broken_invariants("each line is broken by hand")
  local function broken() return table.concat(h.check_invariants(), "; ") end
  settle_load(context, 1, "/tmp/one.wav", 4)
  assert_equal(broken(), "", "a loaded file holds")
  samples().unbind(1)
  assert_equal(broken(), "settings binding: slot 1 holds settled audio (loaded, 4 s) but is not bound")
  samples().bind(1)
  assert_equal(broken(), "")
  clear_buffer(1)
  assert_equal(broken(), "", "a cleared slot holds")
  samples().bind(1)
  assert_equal(broken(), "settings binding: slot 1 is free (empty) but bound")
end)


-- 3.9 (#907): the binding by the slot's events, slot 2: what the slot is
-- bound to (nothing, its own take's record or its file's), read from the
-- module's `bound` and `OWN`. Each state is settled through the script and
-- the engine stub's reports; each event too, its reports in the engine's
-- order (a dub's length before its "ended", a canceled take's length after
-- its "canceled")
local BIND_SLOT = 2
local function samples_local(name)
  for index = 1, math.huge do
    local upvalue_name, value = debug.getupvalue(samples().is_bound, index)
    if not upvalue_name then break end
    if upvalue_name == name then return value end
  end
  for index = 1, math.huge do
    local upvalue_name, value = debug.getupvalue(samples().bind, index)
    if not upvalue_name then return nil end
    if upvalue_name == name then return value end
  end
end
local function binding_of()
  local bound = samples_local("bound")[BIND_SLOT]
  if bound == nil then return "unbound" end
  if bound == samples_local("OWN") then return "own" end
  return "file"
end
local function bind_load(context) settle_load(context, BIND_SLOT, "/tmp/bind.wav", 4) end
local function bind_take(context) settle_take(context, BIND_SLOT, 2) end
h.transition_table({
  name = "settings binding",
  notes = {"docs/notes/lua/samples.md", "settings binding"},
  states = {
    ["unbound"] = function(context) bind_load(context); clear_buffer(BIND_SLOT) end,
    ["file"] = bind_load,
    ["own"] = bind_take,
  },
  events = {
    ["a load settles"] = function(context) settle_load(context, BIND_SLOT, "/tmp/other.wav", 5) end,
    ["a load settles empty"] = function(context)
      load_buffer(BIND_SLOT, "/tmp/other.wav")
      if local_value("S").buffers[BIND_SLOT].awaiting_zero then report(context, BIND_SLOT, 0) end
      context.set_time(util.time() + 1.5); report(context, BIND_SLOT, 0)
      assert_equal(local_value("S").lib.buffers.status(BIND_SLOT), "unsettled")
    end,
    ["a load fails"] = function(context)
      local S = local_value("S")
      load_buffer(BIND_SLOT, "/tmp/missing.wav")
      context.polls.fire("bufferLoadFailed",
        (S.buffers[BIND_SLOT].loads_sent * 2) * S.constants.NUM_BUFFERS + BIND_SLOT - 1)
    end,
    ["a replace take starts"] = function() record_buffer(BIND_SLOT) end,
    ["a replace take settles"] = bind_take,
    ["a dub ends"] = function(context)
      local S = local_value("S")
      params:set("record_feedback", 50)
      record_buffer(BIND_SLOT)
      local number = S.buffers[BIND_SLOT].records_sent
      context.polls.fire("recordState", record_state_value(number, 1, BIND_SLOT))
      report(context, BIND_SLOT, math.max(S.buffers[BIND_SLOT].seconds, 3))   -- max(V, D) (engine row 2)
      context.polls.fire("recordState", record_state_value(number, 2, BIND_SLOT))
      params:set("record_feedback", 0)
    end,
    ["a synced take is canceled"] = function(context)
      local S = local_value("S")
      local seconds = S.buffers[BIND_SLOT].seconds
      params:set("record_sync", 2); record_buffer(BIND_SLOT); params:set("record_sync", 1)
      record_buffer(BIND_SLOT)                                     -- K3 while armed
      context.polls.fire("recordState", record_state_value(S.buffers[BIND_SLOT].records_sent, 3, BIND_SLOT))
      report(context, BIND_SLOT, seconds)                          -- the slot as it was (engine row 6)
    end,
    ["a clear"] = function() clear_buffer(BIND_SLOT) end,
  },
  state_of = binding_of,
  rows = {
    {"unbound", "a load settles", "file"},
    {"unbound", "a load settles empty", "unbound"},
    {"unbound", "a load fails", "unbound"},
    {"unbound", "a replace take starts", "unbound"},
    {"unbound", "a replace take settles", "own"},
    {"unbound", "a dub ends", "own"},
    {"unbound", "a synced take is canceled", "unbound"},
    {"unbound", "a clear", "unbound"},
    {"file", "a load settles", "file", check = function()
      assert_equal(samples_local("bound")[BIND_SLOT].path, "/tmp/other.wav", "the new file's record")
    end},
    {"file", "a load settles empty", "unbound"},
    {"file", "a load fails", "file"},
    {"file", "a replace take starts", "unbound"},
    {"file", "a replace take settles", "own"},
    {"file", "a dub ends", "own"},
    {"file", "a synced take is canceled", "file"},
    {"file", "a clear", "unbound"},
    {"own", "a load settles", "file"},
    {"own", "a load settles empty", "unbound"},
    {"own", "a load fails", "own"},
    {"own", "a replace take starts", "unbound"},
    {"own", "a replace take settles", "own"},
    {"own", "a dub ends", "own"},
    {"own", "a synced take is canceled", "own"},
    {"own", "a clear", "unbound"},
  },
})


-- 3.9 (#975): a dub into an empty slot that ends with no length known (its
-- fallback, no bufferState report) leaves the slot empty, and binds
-- nothing: the binding names the audio that plays
test("a dub that leaves its slot empty binds nothing (#975)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("record_feedback", 50)
  record_buffer(3)
  record_buffer(3)                       -- K3: the fallback starts
  wake_buffer_clock(context, 3)          -- no report: it ends from 0 s
  params:set("record_feedback", 0)
  assert_equal(S.lib.buffers.status(3), "empty", "0 s known: the slot is empty")
  assert_equal(S.buffers[3].name, "take 3", "a take with no length")
  assert_true(not samples().is_bound(3), "and unbound")
  assert_equal(table.concat(h.check_invariants(), "; "), "", "every invariant holds")
end)

end

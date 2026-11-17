-- test/unit/slices_test.lua
-- Slices (3.7, design §3.1-§3.6; package 2b): lib/slices.lua's markers from
-- equal parts or the transients pass (analyzeBuffer, the bufferOnsets poll,
-- buf<n>.onsets), the v<i>_slices option, and a slice played as a note
-- through S.lib.notes: its region on the own note (regionStart and
-- regionLength) or on an extra slot (noteRegion), and a one-shot note that
-- plays to its end. S.lib.scan (package 2a) is a double of its one function
-- the slices consume, pass_seconds
-- Run alone: lua test/run.lua slices

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, write_text = h.load_strata, h.local_value, h.finish_startup,
  h.write_text

local function slices() return local_value("S").lib.slices end

-- The engine's bufferState report of the slot's newest load, holding seconds
local function report(context, slot, seconds)
  local S = local_value("S")
  context.polls.fire("bufferState", context.polls.buffer_state_value(slot, S.buffers[slot].loads_sent, seconds))
end

-- Load path into the slot and let it take effect with seconds of audio
local function settle_load(context, slot, path, seconds)
  local S = local_value("S")
  load_buffer(slot, path)
  if S.buffers[slot].awaiting_zero then report(context, slot, 0) end
  report(context, slot, seconds)
  assert_equal(S.lib.buffers.status(slot), "loaded", "slot " .. slot .. " holds " .. path)
end

-- The slot's peaks file as the engine writes it (frames at 48 kHz)
local function write_peaks(slot, seconds)
  local folder = local_value("S").lib.scenes.scene_data_dir
  util.make_dir(folder)
  local parts = {}
  for index = 1, 64 do parts[index] = "0.500" end
  write_text(folder .. "buf" .. slot .. ".peaks", string.format("strata-peaks 1\nslot %d\nframes %d\nrate 48000\n"
    .. "generation 1\npeaks %s\n", slot, math.floor(seconds * 48000 + 0.5), table.concat(parts, " ")))
end

local function tick(context, ticks)
  context.clock.run_for((ticks or 2) / local_value("UI_PAGES").FRAMES_PER_SECOND + 0.001)
end

local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

-- S.lib.scan's pass_seconds (package 2a) as a double: fraction x full while
-- full is a number (one shot with a moving scan), else nil (wrap)
local function scan_double(S, full)
  local double = {full = full}
  local scan = S.lib.scan
  function scan.pass_seconds(_, fraction) return double.full and fraction * double.full or nil end
  return double
end

-- A started script: voice 1 (running) reads buffer 1, which holds seconds
-- of audio (default 2 s: 96000 frames) with its peaks read; count equal
-- slices when count is given; v1_slices set to option (1 off, 2 one, 3
-- overlap) when given
local function sliced(seconds, count, option)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  seconds = seconds or 2
  settle_load(context, 1, context.audio_dir .. "loop.wav", seconds)
  write_peaks(1, seconds); tick(context)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  if count then
    assert_true(S.lib.samples.set(1, "mode", 2)); assert_true(S.lib.samples.set(1, "count", count))
    S.lib.slices.make(1)
  end
  if option then params:set("v1_slices", option) end
  context.clear_engine_calls()
  return context, S
end

local function list_text(list)
  local parts = {}
  for index, value in ipairs(list or {}) do parts[index] = tostring(value) end
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- An engine call as "name(arg, ...)", numbers to 4 decimals
local function call_text(call)
  local args = {}
  for index, value in ipairs(call.args) do
    args[index] = type(value) == "number" and (string.format("%.4f", value):gsub("%.?0+$", "")) or tostring(value)
    if args[index] == "-0" or args[index] == "" then args[index] = "0" end
  end
  return call.name .. "(" .. table.concat(args, ", ") .. ")"
end

local function call_texts(context, only)
  local texts = {}
  for _, call in ipairs(context.engine_calls) do
    if not only or only[call.name] then table.insert(texts, call_text(call)) end
  end
  return table.concat(texts, " ")
end

-- The text of an onsets file (design §3.3); fields replaces any line's value
local function onsets_text(slot, frames, onsets, strengths, fields)
  fields = fields or {}
  local lines = {fields.magic or "strata-onsets 1", "slot " .. (fields.slot or slot), "frames " .. (fields.frames or frames),
    "rate " .. (fields.rate or 48000), "onsets " .. table.concat(onsets, " "), "strengths " .. table.concat(strengths, " ")}
  return table.concat(lines, "\n") .. "\n"
end

local function onsets_path(slot) return local_value("S").lib.scenes.scene_data_dir .. "buf" .. slot .. ".onsets" end

-- The bufferOnsets report of the slot's count-th analysis
local function onsets_value(slot, count, failed)
  return ((count * 2) + (failed and 1 or 0)) * local_value("S").constants.NUM_BUFFERS + slot - 1
end

-- The count-th analysis of the slot ends with text written as its file
local function answer(context, slot, count, text)
  write_text(onsets_path(slot), text)
  context.polls.fire("bufferOnsets", onsets_value(slot, count))
  context.clock.run_for(0.05)
end

local CANDIDATES = {onsets = {10000, 20000, 30000}, strengths = {"1.000", "0.400", "0.700"}}

-- Slot 1 (2 s) in transients mode with the three candidates read
local function transients(sensitivity)
  local context, S = sliced(2)
  S.lib.samples.set(1, "sensitivity", sensitivity or 50)
  S.lib.samples.set(1, "mode", 3)
  S.lib.slices.make(1)
  assert_equal(#context.calls_named("analyzeBuffer"), 1, "no candidates held: an analysis")
  assert_true(S.lib.slices.analyzing(1), "analyzing")
  answer(context, 1, 1, onsets_text(1, 96000, CANDIDATES.onsets, CANDIDATES.strengths))
  assert_true(not S.lib.slices.analyzing(1), "its report came")
  context.clear_engine_calls()
  return context, S
end

-------------------------------------------------------------------------------
-- Making them
-------------------------------------------------------------------------------

test("equal parts cut a slot into count slices", function()
  local _, S = sliced(2, 4)
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 24000, 48000, 72000}")
  assert_equal(S.lib.slices.count(1), 4)
  local region = S.lib.slices.region(1, 2)
  assert_near(region[1], 0.25, 1e-12, "slice 2's start"); assert_near(region[2], 0.25, 1e-12, "and length")
  assert_near(S.lib.slices.region(1, 4)[2], 0.25, 1e-12, "the last runs to the region's end")
  assert_equal(S.lib.slices.region(1, 5), nil, "no fifth slice")
  assert_equal(S.lib.slices.region(1, 0), nil)
  assert_equal(S.lib.slices.count(2), 0, "an empty slot has none")
  -- the markers are a copy
  S.lib.slices.markers(1)[2] = 1
  assert_equal(S.lib.slices.markers(1)[2], 24000, "a copy")
  assert_equal(S.lib.samples.settings(1).frames, 96000, "the record keeps the frames they were made on")
  assert_equal(S.lib.samples.settings(1).edited, false)
end)

-- The final review's M-2: slices made and then set back to off leave the
-- file's record at its defaults, so samples.data keeps no entry for it
test("a file's slices set back to off leave no entry in samples.data", function()
  local context, S = sliced(2, 8)
  context.clock.run_for(0.11)
  local path = context.data_dir .. "strata/samples.data"
  assert_equal(#context.tab.load(path).files, 1, "the slices are kept")
  assert_true(S.lib.samples.set(1, "mode", 1), "off")
  S.lib.slices.make(1)
  context.clock.run_for(0.11)
  local record = S.lib.samples.settings(1)
  assert_equal(record.markers, nil); assert_equal(record.frames, nil, "no frames"); assert_equal(record.rate, nil, "no rate")
  assert_equal(#context.tab.load(path).files, 0, "back at its defaults: no entry")
end)

test("transients take the candidates at or above the sensitivity's threshold, and frame 0", function()
  local context, S = transients(50)
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 10000, 30000}", "sensitivity 50")
  S.lib.samples.set(1, "sensitivity", 100); S.lib.slices.make(1)
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 10000, 20000, 30000}", "100: all four")
  S.lib.samples.set(1, "sensitivity", 0); S.lib.slices.make(1)
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 10000}", "0: the strongest")
  local held = S.lib.slices.candidates(1)
  assert_equal(list_text(held.frames), "{10000, 20000, 30000}")
  assert_near(held.strengths[2], 0.4, 1e-9)
  assert_equal(#context.calls_named("analyzeBuffer"), 0, "nothing analyzed again")
end)

test("an onsets file that does not match the slot is ignored", function()
  local context, S = sliced(2)
  S.lib.samples.set(1, "mode", 3)
  local onsets, strengths = CANDIDATES.onsets, CANDIDATES.strengths
  local cases = {
    {"another slot's number", onsets_text(1, 96000, onsets, strengths, {slot = 2})},
    {"a length 0.02 s off", onsets_text(1, 96000 + 960, onsets, strengths)},
    {"a frame past the end", onsets_text(1, 96000, {10000, 96000}, {"1.000", "0.500"})},
    {"unequal counts", onsets_text(1, 96000, onsets, {"1.000", "0.400"})},
    {"a wrong first line", onsets_text(1, 96000, onsets, strengths, {magic = "strata-peaks 1"})},
    {"frames out of order", onsets_text(1, 96000, {20000, 10000}, {"1.000", "0.500"})},
    {"a strength above 1", onsets_text(1, 96000, {10000}, {"1.500"})},
    {"a frame that is not whole", onsets_text(1, 96000, {10000.5}, {"1.000"})},
    {"garbage", "return {}"},
  }
  for index, case in ipairs(cases) do
    S.lib.slices.analyze(1)
    local printed = #context.printed
    answer(context, 1, index, case[2])
    assert_equal(S.lib.slices.candidates(1), nil, case[1] .. ": no candidates")
    assert_true(#context.printed - printed <= 1, case[1] .. ": at most one line")
    assert_equal(S.lib.slices.count(1), 0, case[1] .. ": no markers made")
  end
end)

test("only the newest analysis of a slot is read, and never in the poll's callback", function()
  local context, S = sliced(2)
  S.lib.samples.set(1, "mode", 3)
  S.lib.slices.analyze(1); S.lib.slices.analyze(1)
  assert_equal(#context.calls_named("analyzeBuffer"), 2)
  assert_equal(context.calls_named("analyzeBuffer")[1].args[1], 0, "engine slot 0")
  -- the first analysis's report: not the newest, so nothing is read
  answer(context, 1, 1, onsets_text(1, 96000, CANDIDATES.onsets, CANDIDATES.strengths))
  assert_equal(S.lib.slices.candidates(1), nil, "an older analysis's report changes nothing")
  assert_true(S.lib.slices.analyzing(1), "the newest is still awaited")
  -- the newest: the file is read by a clock, after the callback
  local opened = 0
  local real_open = io.open
  io.open = function(path, ...)
    if tostring(path):find("buf1.onsets", 1, true) then opened = opened + 1 end
    return real_open(path, ...)
  end
  context.polls.fire("bufferOnsets", onsets_value(1, 2))
  local in_callback = opened
  context.clock.run_for(0.05)
  io.open = real_open
  assert_equal(in_callback, 0, "nothing read in the poll's callback")
  assert_equal(opened, 1, "read once, by the clock")
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 10000, 30000}", "made from the newest")
  -- a failed report of a later analysis reads nothing and makes nothing
  S.lib.slices.analyze(1)
  context.polls.fire("bufferOnsets", onsets_value(1, 3, true))
  context.clock.run_for(0.05)
  assert_true(not S.lib.slices.analyzing(1), "failed: no longer analyzing")
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 10000, 30000}", "the markers stay")
end)

test("turning the sensitivity with candidates held analyzes nothing", function()
  local context, S = transients(50)
  for _, sensitivity in ipairs({20, 80, 100}) do
    S.lib.samples.set(1, "sensitivity", sensitivity); S.lib.slices.make(1)
  end
  assert_equal(#context.calls_named("analyzeBuffer"), 0, "no analysis")
  -- a bind drops them: the next make analyzes
  settle_load(context, 1, context.audio_dir .. "other.wav", 2)
  assert_equal(S.lib.slices.candidates(1), nil, "dropped at the bind")
  S.lib.samples.set(1, "mode", 3); S.lib.slices.make(1)
  assert_equal(#context.calls_named("analyzeBuffer"), 1, "analyzed for the new audio")
end)

test("new candidates never replace hand-edited markers", function()
  local context, S = transients(50)
  assert_true(S.lib.slices.add_marker(1, 50000), "added")
  assert_equal(S.lib.samples.settings(1).edited, true, "a hand edit")
  S.lib.slices.analyze(1)
  answer(context, 1, 2, onsets_text(1, 96000, {40000}, {"1.000"}))
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 10000, 30000, 50000}", "the edits stay")
  assert_equal(list_text(S.lib.slices.candidates(1).frames), "{40000}", "the new candidates are held")
  -- make drops the edits (and clears the mark)
  S.lib.slices.make(1)
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 40000}")
  assert_equal(S.lib.samples.settings(1).edited, false)
end)

test("a take's end on a transients slot analyzes again; a load does not", function()
  local context, S = transients(50)
  -- an overdub's end: the slot's audio changed in place
  params:set("record_feedback", 50)
  record_buffer(1)
  local number = S.buffers[1].records_sent
  local function record_state(state) return ((number * 4) + state) * 8 end
  context.polls.fire("recordState", record_state(1))
  context.polls.fire("recordState", record_state(2))
  params:set("record_feedback", 0)
  assert_equal(S.lib.slices.candidates(1), nil, "the old audio's candidates dropped")
  assert_equal(S.lib.samples.settings(1).mode, 3, "the take keeps the file's transients")
  lfo_step(context, 2)
  assert_equal(#context.calls_named("analyzeBuffer"), 1, "analyzed again")
  -- a load of a file whose settings are transients analyzes nothing
  context.clear_engine_calls()
  settle_load(context, 2, context.audio_dir .. "loop.wav", 2)
  assert_equal(S.lib.samples.settings(2).mode, 3, "the file's settings")
  lfo_step(context, 2)
  assert_equal(#context.calls_named("analyzeBuffer"), 0, "a load never analyzes")
  assert_equal(S.lib.slices.count(2), 3, "its stored markers play without it")
end)

test("markers stay sorted, 10 ms apart and at most 64, and the first cannot be deleted", function()
  local _, S = sliced(2)
  local many = {30000, 10000, 10100, 0, 10479, 10480}
  S.lib.slices.set_markers(1, many, true)
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 10000, 10480, 30000}",
    "sorted, none within 480 frames (10 ms) of the one before")
  assert_equal(S.lib.samples.settings(1).edited, true)
  S.lib.slices.set_markers(1, {5000, 96000, 200000}, false)
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 5000}", "the 0 added, none past the frames")
  local list = {}
  for k = 1, 70 do list[k] = (k - 1) * 1000 end
  S.lib.slices.set_markers(1, list, false)
  assert_equal(S.lib.slices.count(1), 64, "at most 64")
  assert_equal(S.lib.slices.add_marker(1, 90000), false, "an add at 64")
  assert_equal(S.lib.slices.delete_marker(1, 1), false, "never the first")
  assert_true(S.lib.slices.delete_marker(1, 64), "the last")
  assert_equal(S.lib.slices.count(1), 63)
  assert_true(S.lib.slices.add_marker(1, 90000), "room again")
  assert_equal(S.lib.slices.add_marker(1, 90100), false, "too near another")
  S.lib.slices.set_markers(1, {0, 10000, 20000}, false)
  assert_true(S.lib.slices.nudge_marker(1, 2, 48))
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 10048, 20000}")
  assert_equal(S.lib.samples.settings(1).edited, true, "a nudge is a hand edit")
  S.lib.slices.nudge_marker(1, 2, 20000)
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 19520, 20000}", "it stops 10 ms before the next")
  assert_equal(S.lib.slices.nudge_marker(1, 1, 100), false, "the first stays at 0")
  assert_equal(S.lib.slices.SLICES.max, 64); assert_equal(S.lib.slices.SLICES.first_note, 36)
end)

-------------------------------------------------------------------------------
-- Playing them
-------------------------------------------------------------------------------

local function note(key, fields)
  local played = {owner = "midi", key = key, velocity = 0.5, park = true}
  for name, value in pairs(fields or {}) do played[name] = value end
  return played
end

test("a slice that does not exist plays nothing", function()
  local context, S = sliced(2, 12, 2)
  assert_equal(S.lib.slices.play(1, 40, note(1)), false, "slice 40 of 12")
  assert_equal(S.lib.slices.play(1, 0, note(1)), false)
  assert_equal(S.lib.slices.play(2, 1, note(1)), false, "voice 2 reads no buffer")
  assert_equal(#context.engine_calls, 0, "no engine call")
  assert_equal(S.lib.notes.held(1), 0)
  assert_true(S.lib.slices.takes_notes(1), "a buffer voice with slices and its option on")
  assert_true(not S.lib.slices.takes_notes(2), "a synth voice")
  params:set("v1_slices", 1)
  assert_true(not S.lib.slices.takes_notes(1), "off")
end)

test("one: every slice note takes the own note and creates no node", function()
  local context, S = sliced(2, 4, 2)
  local resets = 0
  local real_reset = S.lib.playheads.reset
  S.lib.playheads.reset = function(voice) if voice == 1 then resets = resets + 1 end; return real_reset(voice) end
  assert_equal(S.lib.slices.play(1, 3, note(1)), 1, "the own note")
  assert_equal(call_texts(context), "setGrainParam(0, regionStart, 0.5) setGrainParam(0, regionLength, 0.25) "
    .. "retrigger(0, 0.5)")
  assert_equal(resets, 1, "the playhead restarts with the scan")
  context.clear_engine_calls()
  assert_equal(S.lib.slices.play(1, 4, note(2)), 1, "a second slice replaces the first")
  assert_equal(#context.calls_named("noteOn"), 0, "no node")
  assert_equal(call_texts(context, {setGrainParam = true}),
    "setGrainParam(0, regionStart, 0.75) setGrainParam(0, regionLength, 0.25)")
  assert_equal(S.lib.notes.held(1), 1, "one note")
  assert_equal(list_text(S.lib.slices.playing(1)), "{4}")
  assert_equal(list_text(S.lib.notes.own_region(1)), "{0.75, 0.25}")
  -- 2b's review, the controller's ruling: a hit of the same slice restarts
  -- its region's scan in every mode (here wrap, the scan moving): the
  -- region is sent again, the playhead restarts with it
  params:set("v1_buf_scan", 0.5)
  context.clear_engine_calls()
  resets = 0
  S.lib.slices.play(1, 4, note(3))
  assert_equal(call_texts(context, {setGrainParam = true}),
    "setGrainParam(0, regionStart, 0.75) setGrainParam(0, regionLength, 0.25)", "a re-hit restarts the scan")
  assert_equal(resets, 1, "and the playhead")
  assert_equal(#context.calls_named("retrigger"), 1, "the hit")
  -- a send that is no hit (the option's clear of nothing, a set to the same region) sends only a change
  context.clear_engine_calls()
  S.lib.notes.set_own_region(1, {0.75, 0.25})
  assert_equal(#context.engine_calls, 0, "not a hit, unchanged: nothing")
  S.lib.playheads.reset = real_reset
end)

-- The Wave 2 landing: a slice hit restarts the engine's scan once and the
-- playhead once, in every scan mode. The engine restarts the own scan at
-- every regionLength (a region sent) and, on a one-shot voice, at every
-- retrigger (positionsHit), which every hit sends; the playhead resets at
-- each (set_own_region, the voice_hit hook)
test("a slice hit restarts the scan once and the playhead once, in every mode", function()
  for mode, name in ipairs({"wrap", "bounce", "one shot"}) do
    local context, S = sliced(2, 4, 2)
    params:set("v1_scan_mode", mode)
    params:set("v1_buf_scan", 0.5)
    local resets = 0
    local real_reset = S.lib.playheads.reset
    S.lib.playheads.reset = function(voice) if voice == 1 then resets = resets + 1 end; return real_reset(voice) end
    local function restarts()
      local count = 0
      for _, call in ipairs(context.calls_named("setGrainParam")) do
        if call.args[2] == "regionLength" or call.args[2] == "t_scanReset" then count = count + 1 end
      end
      if name == "one shot" then count = count + #context.calls_named("retrigger") end
      return count
    end
    S.lib.slices.play(1, 3, note(1))
    context.clear_engine_calls(); resets = 0
    S.lib.slices.play(1, 3, note(2))
    assert_equal(restarts(), 1, name .. ": a re-hit of the same slice restarts the engine's scan once")
    assert_equal(resets, 1, name .. ": and the playhead once")
    assert_equal(#context.calls_named("retrigger"), 1, name .. ": the hit")
    assert_equal(list_text(S.lib.notes.own_region(1)), "{0.5, 0.25}", name .. ": on its slice")
    context.clear_engine_calls(); resets = 0
    S.lib.slices.play(1, 4, note(3))
    assert_equal(resets, 1, name .. ": another slice restarts the playhead once")
    assert_equal(call_texts(context, {setGrainParam = true}),
      "setGrainParam(0, regionStart, 0.75) setGrainParam(0, regionLength, 0.25)", name .. ": its region sent")
    S.lib.playheads.reset = real_reset
  end
end)

test("overlap: each note takes a slot with its own region", function()
  local context, S = sliced(2, 4, 3)
  params:set("v1_note_cap", 3)  -- slots 1-3: the next note takes the slot let go
  for key = 1, 3 do assert_equal(S.lib.slices.play(1, key, note(key)), key, "slice " .. key .. "'s slot") end
  local texts = call_texts(context, {noteRegion = true, noteOn = true, setGrainParam = true})
  assert_equal(texts, "setGrainParam(0, regionStart, 0) setGrainParam(0, regionLength, 0.25) "
    .. "noteRegion(0, 1, 0.25, 0.25) noteOn(0, 1, 60, 261.6256, 1, 0.5) "
    .. "noteRegion(0, 2, 0.5, 0.25) noteOn(0, 2, 60, 261.6256, 1, 0.5)",
    "the own note's region, then each extra slot's before its noteOn, at the voice's own pitch")
  assert_equal(list_text(S.lib.slices.playing(1)), "{1, 2, 3}")
  -- a note off releases it (wrap: no pass)
  context.clear_engine_calls()
  S.lib.slices.note_off(1, "midi", 3)
  assert_equal(call_texts(context, {noteOff = true}), "noteOff(0, 2, 0)")
  -- a plain note in the slot after it clears the slot's region
  context.clear_engine_calls()
  S.lib.notes.play(1, {owner = "midi", key = 9, pitch = 60, velocity = 0.5, set_own = function() end})
  assert_equal(call_texts(context, {noteRegion = true, noteOn = true}), "noteRegion(0, 2, 0, 0) noteOn(0, 2, 60, 261.6256, 1, 0.5)")
end)

test("a played-out one-shot note is released within two steps of its slice's end", function()
  local context, S = sliced(2, 4, 3)
  scan_double(S, 2)  -- the slot's whole valid region in 2 s: a quarter in 0.5 s
  local start = util.time()
  S.lib.slices.play(1, 1, note(1))
  S.lib.slices.play(1, 2, note(2))
  assert_equal(S.lib.notes.find(1, "midi", 2), 2, "an extra slot")
  context.clear_engine_calls()
  S.lib.slices.note_off(1, "midi", 2)
  S.lib.slices.note_off(1, "midi", 1)
  assert_equal(#context.engine_calls, 0, "its key's release sends nothing")
  assert_equal(S.lib.notes.find(1, "midi", 2), 2, "it plays on")
  context.clock.run_for(0.45)
  assert_equal(#context.calls_named("noteOff"), 0, "not before its end")
  context.clock.run_for(0.05 + 2 / 48)
  local offs = context.calls_named("noteOff")
  assert_equal(#offs, 1, "released once")
  assert_equal(call_text(offs[1]), "noteOff(0, 1, 0)")
  assert_true(util.time() - start <= 0.5 + 2 / 48 + 0.01, "within two steps of 0.5 s")
  assert_equal(S.lib.notes.find(1, "midi", 2), nil, "its slot free")
  assert_equal(S.lib.notes.held(1), 0, "the own slice ended at its time too")
  -- a chord's or a pitched note's extra note on a one-shot voice takes the pass over its loop
  S.lib.notes.play(1, {owner = "midi", key = 6, pitch = 60, velocity = 0.5, set_own = function() end})
  context.clear_engine_calls()
  S.lib.notes.play(1, {owner = "midi", key = 7, pitch = 64, velocity = 0.5, set_own = function() end})
  assert_true(S.lib.notes.find(1, "midi", 7) > 1, "an extra note")
  context.clock.run_for(2 + 2 / 48)
  assert_equal(#context.calls_named("noteOff"), 1, "released after the loop's pass, 2 s")
end)

test("in wrap a slice note sounds while it is held", function()
  local context, S = sliced(2, 4, 3)
  scan_double(S, nil)
  S.lib.slices.play(1, 1, note(1)); S.lib.slices.play(1, 2, note(2))
  context.clock.run_for(3)
  assert_equal(S.lib.notes.find(1, "midi", 2), 2, "it sounds on")
  context.clear_engine_calls()
  S.lib.slices.note_off(1, "midi", 2)
  assert_equal(call_texts(context, {noteOff = true}), "noteOff(0, 1, 0)", "its key's release ends it")
end)

test("every way a slice note ends frees its slot", function()
  local cases = {
    {"a steal", function(context, S)
      S.lib.notes.set_pool(1)
      params:set("v2_note_cap", 8)
      context.set_time(util.time() + 0.1)
      S.lib.notes.play(2, {owner = "midi", key = 1, pitch = 60, velocity = 0.5, set_own = function() end})
      S.lib.notes.play(2, {owner = "midi", key = 2, pitch = 64, velocity = 0.5, set_own = function() end})
    end},
    {"the voice's stop", function() toggle_voice(1) end},
    {"a source switch", function(_, S) params:set("v1_source", S.constants.SOURCE_SYNTH + 2) end},
    {"a bind of the slot", function(context)
      settle_load(context, 1, context.audio_dir .. "other.wav", 2)
      lfo_step(context, 2)
    end},
    -- the final review's I-1: release_owner (latch's next chord) leaves a
    -- one-shot slice to its time, which ends it
    {"release_owner, then its time", function(context, S)
      S.lib.notes.release_owner(1, "midi")
      assert_equal(S.lib.notes.find(1, "midi", 2), 2, "release_owner: the one-shot slice plays on")
      context.clock.run_for(0.25 * 20 + 0.1)
    end},
    {"cleanup", function() cleanup() end},
  }
  for _, case in ipairs(cases) do
    local context, S = sliced(2, 4, 3)
    scan_double(S, 20)
    S.lib.slices.play(1, 1, note(1)); S.lib.slices.play(1, 2, note(2))
    assert_equal(S.lib.notes.find(1, "midi", 2), 2, case[1] .. ": an extra slot held")
    case[2](context, S)
    assert_equal(S.lib.notes.find(1, "midi", 2), nil, case[1] .. ": its slot is free")
    local held = 0
    for _, used in ipairs(S.lib.notes.slots(1)) do if used.slot > 1 then held = held + 1 end end
    assert_equal(held, 0, case[1] .. ": no extra slot held")
  end
end)

test("a bind clears the own region of every voice reading the slot", function()
  local context, S = sliced(2, 4, 2)
  params:set("v2_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v2_slices", 2)
  S.lib.slices.play(1, 2, note(1)); S.lib.slices.play(2, 3, note(1))
  assert_equal(list_text(S.lib.notes.own_region(2)), "{0.5, 0.25}")
  context.clear_engine_calls()
  settle_load(context, 1, context.audio_dir .. "other.wav", 2)
  assert_equal(call_texts(context, {setGrainParam = true}):find("region") == nil, true, "the listener sends nothing")
  lfo_step(context, 2)
  assert_equal(S.lib.notes.own_region(1), nil, "voice 1's cleared")
  assert_equal(S.lib.notes.own_region(2), nil, "voice 2's cleared")
  local cleared = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "regionLength" then cleared[#cleared + 1] = call.args[1] .. ":" .. call.args[3] end
  end
  assert_equal(table.concat(cleared, " "), "0:0 1:0", "each running voice gets the clear")
end)

test("a voice sync sends the own region as it is, before voiceOn", function()
  local context, S = sliced(2, 4)
  assert_true(not S.voices[3].active, "voice 3 is stopped")
  params:set("v3_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v3_slices", 2)
  S.patterns[3][1] = 15
  S.lib.sequencer.set_step_attr(3, 1, "slice", 2)
  context.clear_engine_calls()
  pattern_clock_start()
  local before, on = {}, nil
  for index, call in ipairs(context.engine_calls) do
    if call.name == "voiceOn" and call.args[1] == 2 then on = index; break end
    if call.name == "setGrainParam" and call.args[1] == 2 and call.args[2]:find("^region") then
      before[#before + 1] = call.args[2] .. " " .. call.args[3]
    end
  end
  assert_true(on ~= nil, "the step started voice 3")
  assert_equal(table.concat(before, ", "), "regionStart 0.25, regionLength 0.25", "slice 2's region before voiceOn")
  pattern_clock_stop()
  toggle_voice(3)
  assert_equal(S.lib.notes.own_region(3), nil, "the stop cleared it")
  context.clear_engine_calls()
  toggle_voice(3)
  local sent = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == "voiceOn" then break end
    if call.name == "setGrainParam" and call.args[2]:find("^region") then sent[#sent + 1] = call.args[2] .. " " .. call.args[3] end
  end
  assert_equal(table.concat(sent, ", "), "regionStart 0, regionLength 0", "a start by hand: both 0")
end)

test("the slices option is off by default, a discrete scene field and a buffer voice's VOICE row", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_slices"), 1, "voice " .. voice .. ": off")
  end
  assert_equal(params:string("v1_slices"), "off")
  params:set("v1_slices", 3)
  assert_equal(params:string("v1_slices"), "overlap")
  assert_equal(S.lib.slices.SLICES.options[2], "one")
end)

-- 2b's review, Minor 3: a strength printed at the threshold is taken
test("a strength exactly at the sensitivity's threshold is taken", function()
  local context, S = sliced(2)
  S.lib.samples.set(1, "sensitivity", 70)
  S.lib.samples.set(1, "mode", 3)
  S.lib.slices.make(1)
  answer(context, 1, 1, onsets_text(1, 96000, {10000, 20000}, {"1.000", "0.300"}))
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 10000, 20000}", "0.300 at sensitivity 70")
end)

-- 2b's review, Minor 4: a read that raises is contained and never leaves the reader stuck
test("a read that raises prints once and the next report is read", function()
  local context, S = sliced(2)
  S.lib.samples.set(1, "mode", 3)
  S.lib.slices.make(1)
  local real_settings = S.lib.samples.settings
  S.lib.samples.settings = function() error("boom") end
  answer(context, 1, 1, onsets_text(1, 96000, {10000}, {"1.000"}))
  S.lib.samples.settings = real_settings
  h.claim_script_errors(context, 1, "strata: onsets read failed: ", "boom")
  S.lib.slices.analyze(1)
  answer(context, 1, 2, onsets_text(1, 96000, {30000}, {"1.000"}))
  assert_equal(list_text(S.lib.slices.markers(1)), "{0, 30000}", "the next report was read")
end)

-- 2b's review, Minor 5: the own note's slice is playing only while its record is held
test("playing names the own slice only while its note is held", function()
  local context, S = sliced(2, 4, 3)
  S.lib.slices.play(1, 1, note(1)); S.lib.slices.play(1, 2, note(2))
  assert_equal(list_text(S.lib.slices.playing(1)), "{1, 2}")
  S.lib.slices.note_off(1, "midi", 1)  -- wrap: the own note parks under slice 2
  assert_equal(list_text(S.lib.slices.playing(1)), "{2}", "a parked own slice is not playing")
  -- one shot: played out, the own slice is no longer playing
  context, S = sliced(2, 4, 2)
  scan_double(S, 2)
  S.lib.slices.play(1, 3, note(1))
  assert_equal(list_text(S.lib.slices.playing(1)), "{3}")
  context.clock.run_for(0.5 + 2 / 48)
  assert_equal(list_text(S.lib.slices.playing(1)), "{}", "played out")
end)

-- The final review's M-1: playing runs once per grid cell, so it reads the
-- slot's markers once, not once per slice (64 slices: 130 reads before)
test("playing reads the slot's settings once, whatever the count", function()
  local context, S = sliced(2, 64, 3)
  assert_equal(S.lib.slices.count(1), 64, "64 slices")
  S.lib.slices.play(1, 40, note(1)); S.lib.slices.play(1, 7, note(2))
  local samples, reads = S.lib.samples, 0
  local real = samples.settings
  samples.settings = function(...) reads = reads + 1; return real(...) end
  local playing = S.lib.slices.playing(1)
  samples.settings = real
  assert_equal(list_text(playing), "{7, 40}", "the two slices sounding")
  assert_equal(reads, 1, "one read of the slot's settings")
end)

end

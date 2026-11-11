-- test/unit/record_test.lua
-- Recording (lib/record.lua): record_buffer and its timers, the take
-- settling, S.lib.record.state and the hooks the 3.3 packages fill.
-- Run alone: lua test/run.lua record

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local assert_near, load_strata, local_value = h.assert_near, h.load_strata, h.local_value
local finish_startup, wake_buffer_clock = h.finish_startup, h.wake_buffer_clock

test("recording again stops early; clear and load cancel the timer", function()
  local context = load_strata(); finish_startup(context)   -- finish init's start-up coroutine
  local buffers = local_value("buffers")
  params:set("record_duration", 4)
  record_buffer(2); assert_true(buffers[2].recording)
  context.clear_engine_calls()
  record_buffer(2)
  assert_equal(#context.calls_named("stopRecord"), 1, "second press stops the recording")
  assert_equal(context.calls_named("stopRecord")[1].args[1], 1)
  assert_equal(#context.calls_named("recordBuffer"), 0, "and does not start a new one")
  context.polls.fire("bufferState", 1001)  -- the engine reports what was captured
  assert_true(not buffers[2].recording); assert_true(buffers[2].loaded); assert_equal(buffers[2].name, "take 2")
  local pending = context.clock.pending_count()
  record_buffer(2); assert_equal(context.clock.pending_count(), pending + 1, "new recording timer")
  clear_buffer(2)
  assert_true(not buffers[2].recording, "clear ends the recording state")
  assert_equal(context.clock.pending_count(), pending, "clear cancels the timer")
  record_buffer(2); load_buffer(2, "/tmp/b.wav")
  assert_true(not buffers[2].recording, "load ends the recording state")
  assert_equal(context.clock.pending_count(), pending, "load cancels the timer")
  -- out-of-range slots are ignored
  context.clear_engine_calls()
  record_buffer(0); record_buffer(9); clear_buffer(9); load_buffer(0, "/tmp/c.wav"); save_buffer(9)
  assert_equal(#context.engine_calls, 0, "invalid slots send nothing")
  -- cleanup stops the poll and any recording timer
  record_buffer(5)
  cleanup()
  assert_equal(context.clock.pending_count(), 0, "no recording timer left")
  assert_true(not context.polls.polls.bufferState.running, "bufferState poll stopped")
  assert_true(not context.polls.polls.bufferLoadFailed.running, "bufferLoadFailed poll stopped")
  assert_true(not context.polls.polls.bufferSaveResult.running, "bufferSaveResult poll stopped")
end)

test("a take settled empty adopts audio the engine reports later; a clear wins", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  params:set("record_duration", 2)
  record_buffer(3); wake_buffer_clock(context, 3)     -- the timer ends; the engine is slow
  context.set_time(5); context.polls.fire("bufferState", 2000)
  assert_equal(buffers[3].name, "empty", "a periodic 0 after the settle time empties the slot")
  context.polls.fire("bufferState", 2002)        -- the take completes late
  assert_true(buffers[3].loaded, "the late take is adopted"); assert_equal(buffers[3].name, "take 3")
  assert_equal(buffers[3].path, scratch_take_path(3), "with the scratch take path")
  context.polls.fire("bufferState", 2002); context.polls.fire("bufferState", 2003)
  assert_equal(buffers[3].name, "take 3", "later reports leave it a take")
  -- a slot cleared after an empty take is not brought back by a report
  record_buffer(4); record_buffer(4)
  context.set_time(10); context.polls.fire("bufferState", 3000)
  assert_equal(buffers[4].name, "empty")
  clear_buffer(4); context.polls.fire("bufferState", 3002)
  assert_true(not buffers[4].loaded, "clear wins"); assert_equal(buffers[4].path, nil)
  -- nor is a slot whose last event was a load or a new recording
  record_buffer(5); record_buffer(5)
  context.set_time(15); context.polls.fire("bufferState", 4000)
  record_buffer(5); context.polls.fire("bufferState", 4001)
  assert_true(buffers[5].recording, "a new recording is not adopted as the old take")
  assert_true(not buffers[5].finishing)
end)

test("a finishing take settles from the last known seconds when no report comes", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  -- BUFFER_SETTLE is an upvalue of the local finish_buffer_take, which the
  -- global record_buffer holds
  local finish_buffer_take = local_value("finish_buffer_take")
  local buffer_settle
  for index = 1, math.huge do
    local name, value = debug.getupvalue(finish_buffer_take, index)
    if not name then break end
    if name == "BUFFER_SETTLE" then buffer_settle = value end
  end
  assert_true(buffer_settle ~= nil, "BUFFER_SETTLE reached through finish_buffer_take")
  local fallback_seconds = buffer_settle.fallback_seconds
  params:set("record_duration", 2)
  record_buffer(3); wake_buffer_clock(context, 3)     -- the timer ends: finishing, no report ever
  assert_true(buffers[3].finishing, "finishing")
  local log = context.clock.sleep_log
  assert_equal(log[#log].amount, fallback_seconds, "the fallback waits fallback_seconds after the take ends")
  wake_buffer_clock(context, 3)                       -- the fallback runs
  assert_true(not buffers[3].finishing and not buffers[3].recording, "settled")
  assert_equal(buffers[3].name, "empty", "no seconds known: empty")
  context.clear_engine_calls(); record_buffer(3)
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records again")
  -- a stopped take gets the fallback too, and settles as a take when the
  -- slot's seconds are known
  record_buffer(3)
  assert_true(buffers[3].finishing)
  buffers[3].seconds = 1.5                      -- as an earlier report left it
  wake_buffer_clock(context, 3)
  assert_true(buffers[3].loaded, "known seconds: loaded"); assert_equal(buffers[3].name, "take 3")
  -- a report, a load, a clear or cleanup cancels the fallback
  local pending = context.clock.pending_count()
  record_buffer(4); record_buffer(4)
  assert_equal(context.clock.pending_count(), pending + 1, "fallback pending")
  context.polls.fire("bufferState", 3001)
  assert_equal(context.clock.pending_count(), pending, "a report settles it and cancels the fallback")
  record_buffer(5); record_buffer(5); load_buffer(5, "/tmp/x.wav")
  assert_equal(context.clock.pending_count(), pending, "load cancels the fallback")
  record_buffer(6); record_buffer(6); clear_buffer(6)
  assert_equal(context.clock.pending_count(), pending, "clear cancels the fallback")
  record_buffer(7); record_buffer(7)
  cleanup()
  assert_equal(context.clock.pending_count(), 0, "cleanup cancels the fallback")
end)

test("record_buffer sends the eight-argument recordBuffer with neutral values", function()
  local context = load_strata(); finish_startup(context)
  params:set("record_duration", 4); params:set("record_level", 0.8)
  record_buffer(2)
  local args = context.calls_named("recordBuffer")[1].args
  assert_equal(#args, 8, "slot, seconds, level, feedback, source, threshold, loop, delay")
  assert_equal(args[1], 1, "slot 2")
  assert_near(args[2], 4, 1e-9, "4 s")
  assert_near(args[3], 0.8, 1e-9, "level 0.8")
  assert_equal(args[4], 0, "feedback 0")
  assert_equal(args[5], 0, "source 0 (input)")
  assert_equal(args[6], 0, "threshold 0 (off)")
  assert_equal(args[7], 0, "loop 0")
  assert_equal(args[8], 0, "delay 0")
end)

test("record_buffer and the take timers live in lib/record.lua", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(debug.getinfo(record_buffer, "S").source:match("lib/record%.lua$") ~= nil, "record_buffer is lib/record.lua's")
  -- long enough that the recording timer does not fire during the fallback
  params:set("record_duration", 16)
  record_buffer(1)
  S.finish_buffer_take(1)
  assert_true(S.buffers[1].finishing, "finish_buffer_take marks the take finishing")
  context.clock.run_for(5)                       -- BUFFER_SETTLE.fallback_seconds: no bufferState report ever
  assert_true(not S.buffers[1].finishing and not S.buffers[1].recording, "the slot settles 5 s later")
end)

test("S.lib.record.state is nil when idle and a take while a slot records", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("record_duration", 4)
  assert_equal(S.lib.record.state(1), nil, "idle")
  context.set_time(10)
  record_buffer(1)
  local state = S.lib.record.state(1)
  assert_equal(state.number, 1); assert_equal(state.kind, "take"); assert_equal(state.phase, "recording")
  assert_equal(state.started_at, 10); assert_equal(state.seconds, 4); assert_equal(state.loop, false)
  assert_equal(S.lib.record.state(2), nil, "another slot is idle")
  wake_buffer_clock(context, 1)                   -- the 4 s timer passes (confirm_since is set only then)
  assert_true(S.lib.record.state(1) ~= nil, "still a take until the engine reports it")
  context.polls.fire("bufferState", 4.0)          -- slot 1 holds 4 s: the take settles
  assert_equal(S.lib.record.state(1), nil, "idle again")
end)

test("records_sent counts a slot's recordBuffer commands", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("record_duration", 4)
  record_buffer(3)                                -- the record
  record_buffer(3)                                -- the stop
  context.polls.fire("bufferState", 2001)          -- the stopped take settles
  record_buffer(3)                                -- records again
  assert_equal(S.buffers[3].records_sent, 2, "two recordings on slot 3")
  assert_equal(S.buffers[1].records_sent, 0, "none on slot 1")
end)

test("a recording slot's bufferState reports reach S.lib.record.slot_reported", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local calls = {}
  local original = S.lib.record.slot_reported
  S.lib.record.slot_reported = function(slot, seconds) table.insert(calls, {slot, seconds}) end
  record_buffer(2)
  context.polls.fire("bufferState", 1000)          -- slot 2, 0 s
  assert_equal(#calls, 1, "one report for the recording slot")
  assert_equal(calls[1][1], 2); assert_equal(calls[1][2], 0)
  context.polls.fire("bufferState", 3005)          -- slot 4, idle
  assert_equal(#calls, 1, "none for an idle slot")
  S.lib.record.slot_reported = original
end)

test("record_buffer calls S.lib.buffers.recording_started for the slot", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local calls = {}
  local original = S.lib.buffers.recording_started
  S.lib.buffers.recording_started = function(slot, playable) table.insert(calls, {slot, playable}) end
  record_buffer(5)
  assert_equal(#calls, 1, "one call when it sends recordBuffer")
  assert_equal(calls[1][1], 5); assert_equal(calls[1][2], false, "feedback 0: a replace take")
  record_buffer(5)                                -- a stop sends no recordBuffer
  assert_equal(#calls, 1, "no second call for the stop")
  params:set("record_feedback", 50)
  record_buffer(6)
  assert_equal(calls[2][1], 6); assert_equal(calls[2][2], true, "feedback above 0: playable")
  S.lib.buffers.recording_started = original
end)


-- 3.3 record settings, synced takes and playable recordings

local function record_state_value(number, state, slot) return ((number * 4) + state) * 8 + (slot - 1) end
local function S_record_state(slot) return local_value("S").lib.record.state(slot) end
local function recording_calls(context) return context.calls_named("recordBuffer") end

-- matron hands every poll value to Lua as a float (lua_pushnumber), and on
-- Lua 5.3 a float slot builds "take 3.0" and "buf3.0_file" (#300). The
-- reports are floats here whatever the stub does
test("recordState reports arrive as floats: an ended dub is take <n> on its scratch path", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_buffer(3, "/tmp/drone.wav"); context.polls.fire("bufferState", 2004.0)
  params:set("record_feedback", 50)
  record_buffer(3)
  context.polls.fire("recordState", record_state_value(1, 1, 3) + 0.0)
  context.polls.fire("recordState", record_state_value(1, 2, 3) + 0.0)
  assert_equal(buffers[3].name, "take 3"); assert_equal(buffers[3].path, scratch_take_path(3))
  assert_equal(params:get("buf3_file"), _path.audio, "the file param is back at its folder")
  assert_true(not buffers[3].recording, "the handler ran to its end")
  -- an armed replace take that only the fallback settles carries the slot
  -- into its timers
  params:set("record_feedback", 0); params:set("record_threshold", 4)
  record_buffer(2)
  context.polls.fire("recordState", record_state_value(1, 0, 2) + 0.0)
  context.polls.fire("recordState", record_state_value(1, 1, 2) + 0.0)
  assert_equal(S_record_state(2).phase, "recording")
  buffers[2].seconds = 4  -- what the engine captured, with no bufferState report
  context.clock.run_for(params:get("record_duration") + local_value("BUFFER_SETTLE").fallback_seconds + 1)
  assert_true(not buffers[2].recording, "the fallback settled it")
  assert_equal(buffers[2].name, "take 2"); assert_equal(buffers[2].path, scratch_take_path(2))
end)

-- The buffer slots invariant (lib/buffers.lua): a take is named for its own
-- slot, and a scratch take's path is buf<whole number>.wav (#300)
test("the buffer slots invariant: a take is named for its own slot, a scratch path names a whole slot", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  local function broken() return table.concat(h.check_invariants(), "; ") end
  load_buffer(1, "/tmp/take 1.wav"); context.polls.fire("bufferState", 4)
  assert_equal(buffers[1].name, "take 1.wav"); assert_equal(broken(), "", "a file named take ... is not a take")
  load_buffer(2, scratch_take_path(1)); context.polls.fire("bufferState", 1004)
  assert_equal(broken(), "", "another slot's scratch take, loaded as a file, is a whole-numbered path")
  buffers[3].name = "take 4"
  assert_equal(broken(), "buffer slots: slot 3 is named take 4")
  buffers[3].name = "take 3.0"
  assert_equal(broken(), "buffer slots: slot 3 is named take 3.0")
  local scratch_dir = scratch_take_path(3):match("^(.*/)")
  buffers[3].name, buffers[3].path = "take 3", scratch_dir .. "buf3.0.wav"
  assert_equal(broken(), "buffer slots: slot 3 has the scratch path " .. scratch_dir .. "buf3.0.wav")
  buffers[3].name, buffers[3].path = "take 3", scratch_take_path(3)
  assert_equal(broken(), "", "a take in its own slot on its own path holds")
end)

test("record params default to 3.2's take and are not scene fields", function()
  local context = load_strata(); finish_startup(context)
  local ids = {"record_source", "record_feedback", "record_loop", "record_threshold", "record_sync", "record_beats"}
  assert_equal(params:get("record_source"), 1); assert_equal(params:string("record_source"), "input")
  assert_equal(params:get("record_feedback"), 0); assert_equal(params:get("record_loop"), 1)
  assert_equal(params:get("record_threshold"), 1); assert_equal(params:get("record_sync"), 1)
  assert_equal(params:get("record_beats"), 16)
  assert_equal(params:lookup_param("strata_record").n, 6, "the strata_record group holds exactly 6 params")
  capture_scene(1)
  local scene = local_value("scenes")[1]
  local function holds(table_value, id, seen)
    seen = seen or {}
    if type(table_value) ~= "table" or seen[table_value] then return false end
    seen[table_value] = true
    for key, value in pairs(table_value) do
      if key == id or holds(value, id, seen) then return true end
    end
    return false
  end
  for _, id in ipairs(ids) do assert_true(not holds(scene, id), id .. " is not in a scene") end
end)

test("the record settings reach recordBuffer", function()
  local context = load_strata(); finish_startup(context)
  params:set("record_source", 6); params:set("record_feedback", 50); params:set("record_loop", 2)
  params:set("record_threshold", 6); params:set("record_duration", 4)
  context.clear_engine_calls()
  record_buffer(1)
  local args = recording_calls(context)[1].args
  assert_equal(args[1], 0); assert_equal(args[2], 4.0); assert_equal(args[3], 1.0)
  assert_near(args[4], 0.5, 1e-9); assert_equal(args[5], 5)
  assert_near(args[6], 0.0631, 1e-4); assert_equal(args[7], 1); assert_equal(args[8], 0.0)
end)

test("a synced take waits for the next beat or bar with a 0.25 s lead", function()
  local context = load_strata(); finish_startup(context)
  params:set("clock_tempo", 120); context.set_time(1.8)
  params:set("record_sync", 2)
  context.clear_engine_calls(); record_buffer(1)
  local args = recording_calls(context)[1].args
  assert_near(args[8], 0.7, 1e-6, "next beat"); assert_near(args[2], 8.0, 1e-6, "16 beats at 120 BPM")
  params:set("record_sync", 3)
  clear_buffer(2); context.clear_engine_calls(); record_buffer(2)
  assert_near(recording_calls(context)[1].args[8], 2.2, 1e-6, "next bar")
end)

test("a length in beats is capped at the slot length", function()
  local context = load_strata(); finish_startup(context)
  params:set("clock_tempo", 60); params:set("record_sync", 2); params:set("record_beats", 64)
  context.clear_engine_calls(); record_buffer(1)
  assert_equal(recording_calls(context)[1].args[2], 16.0)
end)

-- #321: the len field showed the whole beats a slot holds ("26b max") while
-- the take was a whole slot (26.67 beats at 100 BPM), so a loop recorded
-- that way wrapped off the beat. One take_length() now feeds both
test("a synced length that does not fit is the whole beats that do, as BUFFER shows", function()
  local context = load_strata(); finish_startup(context); h.show_page("BUFFER")
  local S = local_value("S")
  params:set("record_sync", 2); params:set("record_beats", 64); params:set("record_loop", 2)
  -- the whole beats a 16 s slot holds, and their seconds, by hand: 60 / bpm a beat
  for _, case in ipairs({ { bpm = 100, beats = 26, seconds = 15.6 }, { bpm = 110, beats = 29, seconds = 29 * 60 / 110 },
    { bpm = 30, beats = 8, seconds = 16 }, { bpm = 120, beats = 32, seconds = 16 } }) do
    params:set("clock_tempo", case.bpm)
    local length = S.lib.record.take_length()
    assert_equal(length.beats, case.beats, case.bpm .. " BPM: the whole beats a 16 s slot holds")
    assert_equal(length.capped, true, case.bpm .. " BPM: capped")
    context.clear_engine_calls(); record_buffer(1)
    local seconds = recording_calls(context)[1].args[2]
    assert_near(seconds, case.seconds, 1e-6, case.bpm .. " BPM: the take is those beats long")
    assert_true(seconds <= S.performance.buffer_seconds, case.bpm .. " BPM: never past the slot")
    redraw()
    assert_true(h.screen_shows(context, case.beats .. "b max"), case.bpm .. " BPM: the field names the same beats")
    record_buffer(1)   -- stop, then the engine's canceled report ends it
    context.polls.fire("recordState", ((S.buffers[1].records_sent * 4) + 3) * 8)
  end
  -- beats that fit are sent whole; under a beat the take is a slot long
  params:set("clock_tempo", 100); params:set("record_beats", 16)
  assert_near(S.lib.record.take_length().seconds, 9.6, 1e-6, "16 beats at 100 BPM")
  assert_equal(S.lib.record.take_length().capped, false, "16 beats fit")
  assert_equal(S.lib.record.take_length().beats, 16)
  params:set("clock_tempo", 3); params:set("record_beats", 64)
  assert_equal(S.lib.record.take_length().seconds, 16, "not one beat fits: a slot")
  assert_equal(S.lib.record.take_length().beats, 0, "shown as <1b max")
  -- sync off: the duration, no beats
  params:set("record_sync", 1); params:set("record_duration", 4)
  assert_equal(S.lib.record.take_length().seconds, 4)
  assert_equal(S.lib.record.take_length().beats, nil)
end)

test("K3 while armed or recording sends stopRecord", function()
  local context = load_strata(); finish_startup(context)
  params:set("record_sync", 3)
  context.clear_engine_calls(); record_buffer(1)
  assert_equal(#recording_calls(context), 1)
  context.polls.fire("recordState", 32)
  assert_equal(S_record_state(1).phase, "armed")
  record_buffer(1)
  assert_equal(#context.calls_named("stopRecord"), 1); assert_equal(context.calls_named("stopRecord")[1].args[1], 0)
  assert_equal(#recording_calls(context), 1, "no second recordBuffer")
end)

test("a replace take's timer starts at its recording report", function()
  local context = load_strata(); finish_startup(context)
  params:set("record_sync", 3); params:set("record_duration", 4)
  local pending = context.clock.pending_count()
  record_buffer(1)
  assert_equal(context.clock.pending_count(), pending, "no take timer while armed")
  assert_equal(S_record_state(1).started_at, nil)
  context.set_time(3)
  context.polls.fire("recordState", record_state_value(1, 1, 1))
  assert_equal(context.clock.pending_count(), pending + 1, "the report starts it")
  assert_equal(S_record_state(1).phase, "recording"); assert_equal(S_record_state(1).started_at, 3)
  local buffers = local_value("buffers")
  wake_buffer_clock(context, 1)
  assert_true(buffers[1].finishing, "record_duration later it finishes")
end)

test("a playable recording stays loaded, shows its length and becomes take n when it ends", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_buffer(3, "/tmp/drone.wav"); context.polls.fire("bufferState", 2008)
  assert_true(buffers[3].loaded)
  buffers[3].records_sent = 1
  params:set("record_feedback", 50); params:set("record_duration", 12)
  record_buffer(3)
  assert_equal(S_record_state(3).kind, "playable"); assert_equal(S_record_state(3).number, 2)
  assert_equal(buffers[3].name, "drone.wav"); assert_true(buffers[3].loaded); assert_equal(buffers[3].seconds, 8)
  context.polls.fire("recordState", record_state_value(2, 1, 3))
  context.polls.fire("bufferState", 2012)
  assert_equal(buffers[3].seconds, 12); assert_true(buffers[3].loaded)
  assert_true(not buffers[3].finishing, "never settles")
  context.polls.fire("recordState", record_state_value(2, 2, 3))
  assert_equal(buffers[3].name, "take 3"); assert_equal(buffers[3].path, scratch_take_path(3))
  assert_true(buffers[3].loaded); assert_equal(S_record_state(3), nil); assert_true(not buffers[3].recording)
end)

-- #311's state table: a canceled take leaves its slot as the take left it,
-- and the engine follows "canceled" with the slot's length, which says which
test("a replace take canceled after the engine prepared its slot leaves it empty", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 8)
  params:set("record_sync", 3)
  record_buffer(1); context.polls.fire("recordState", 32)
  context.polls.fire("bufferState", 0)             -- the engine prepared the slot: 0 s
  record_buffer(1)                                -- K3: canceled
  context.polls.fire("recordState", 56); context.polls.fire("bufferState", 0)
  assert_equal(buffers[1].name, "empty"); assert_true(not buffers[1].loaded); assert_true(not buffers[1].recording)
  assert_equal(buffers[1].path, nil); assert_equal(local_value("S").lib.buffers.status(1), "empty")
  context.polls.fire("bufferState", 8)             -- a later report of audio puts nothing back
  assert_equal(buffers[1].name, "empty"); assert_true(not buffers[1].loaded); assert_equal(buffers[1].path, nil)
end)

test("a canceled playable recording keeps its slot", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_buffer(2, "/tmp/b.wav"); context.polls.fire("bufferState", 1006)
  params:set("record_feedback", 50)
  record_buffer(2); context.polls.fire("recordState", 33); context.polls.fire("recordState", 57)
  assert_equal(buffers[2].name, "b.wav"); assert_true(buffers[2].loaded); assert_equal(buffers[2].seconds, 6)
  assert_true(not buffers[2].recording)
end)

test("a synced replace take canceled before the engine prepared its slot puts the slot back", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  local S = local_value("S")
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 0.5)
  params:set("record_sync", 3)
  record_buffer(1); context.polls.fire("recordState", 32)
  assert_equal(buffers[1].seconds, 0.5, "the slot keeps its length until the engine prepares it")
  assert_equal(S.lib.buffers.status(1), "armed")
  record_buffer(1)                                -- K3 again before the bar
  context.polls.fire("recordState", 56); context.polls.fire("bufferState", 0.5)
  assert_equal(buffers[1].name, "a.wav"); assert_true(buffers[1].loaded); assert_equal(buffers[1].path, "/tmp/a.wav")
  assert_equal(params:get("buf1_file"), "/tmp/a.wav", "the file param shows it again")
  assert_equal(S.lib.buffers.status(1), "loaded")
  assert_true(not buffers[1].recording and not buffers[1].finishing)
end)

test("a periodic report of the old audio between K3 and the canceled report never names the slot a take", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  local S = local_value("S")
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 8)
  params:set("record_sync", 3)
  record_buffer(1); context.polls.fire("recordState", 32)
  record_buffer(1)                                -- K3: the stop is on its way
  context.polls.fire("bufferState", 8)             -- a periodic report, sent before the engine canceled
  assert_true(buffers[1].name ~= "take 1", "not a take: " .. tostring(buffers[1].name))
  assert_true(buffers[1].path ~= scratch_take_path(1), "nor its path")
  assert_equal(S.lib.buffers.status(1), "finishing", "still waiting for the canceled report")
  context.polls.fire("recordState", 56); context.polls.fire("bufferState", 8)
  assert_equal(buffers[1].name, "a.wav"); assert_equal(buffers[1].path, "/tmp/a.wav"); assert_true(buffers[1].loaded)
end)

test("a playable recording waits for a load the engine has not confirmed", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  local S = local_value("S")
  S.lib.ui_keys.set_ui_page(local_value("UI_PAGES").index.BUFFER)
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 8)
  load_buffer(1, "/tmp/b.wav")                     -- not confirmed yet
  params:set("record_feedback", 50)
  context.clear_engine_calls(); record_buffer(1)
  assert_equal(#recording_calls(context), 0, "no recordBuffer while the load awaits the engine")
  assert_equal(S.lib.buffers.status(1), "loading"); assert_equal(buffers[1].name, "b.wav")
  assert_equal(S.lib.ui_flash.text("hints"), "buf 1 loading")
  context.polls.fire("bufferState", 0)             -- the load takes effect (0 s, #401)
  context.polls.fire("bufferState", 6)             -- b.wav is in
  record_buffer(1)
  assert_equal(#recording_calls(context), 1, "K3 once the length shows records")
  assert_equal(S.lib.buffers.status(1), "dub")
  -- a replace take in the same place is still sent: it is the same take on both sides
  load_buffer(2, "/tmp/c.wav")
  params:set("record_feedback", 0)
  context.clear_engine_calls(); record_buffer(2)
  assert_equal(#recording_calls(context), 1, "a replace take during a load is sent")
  assert_equal(S.lib.buffers.status(2), "recording")
end)

-- #457: the engine reports a take's length, then "ended"; both can arrive
-- before the take's own timer
test("a take whose ended report beats its timer settles at once", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  local S = local_value("S")
  params:set("record_threshold", 3); params:set("record_duration", 4)
  local pending = context.clock.pending_count()
  record_buffer(1)
  context.polls.fire("recordState", record_state_value(1, 0, 1)); context.polls.fire("recordState", record_state_value(1, 1, 1))
  context.polls.fire("bufferState", 4); context.polls.fire("recordState", record_state_value(1, 2, 1))
  assert_equal(S.lib.buffers.status(1), "loaded"); assert_equal(buffers[1].name, "take 1")
  assert_equal(buffers[1].path, scratch_take_path(1)); assert_true(not buffers[1].recording)
  assert_equal(context.clock.pending_count(), pending, "no timer or fallback left")
  -- the timer between the length and "ended": "ended" settles it too
  record_buffer(2)
  context.polls.fire("recordState", record_state_value(1, 0, 2)); context.polls.fire("recordState", record_state_value(1, 1, 2))
  context.polls.fire("bufferState", 1004)
  wake_buffer_clock(context, 2)                   -- the take's timer: finishing
  assert_equal(S.lib.buffers.status(2), "finishing")
  context.polls.fire("recordState", record_state_value(1, 2, 2))
  assert_equal(S.lib.buffers.status(2), "loaded"); assert_equal(buffers[2].name, "take 2")
  assert_equal(context.clock.pending_count(), pending, "no fallback left")
end)

test("a stale recordState report never acts on a newer recording", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  buffers[3].records_sent = 1
  params:set("record_sync", 3)
  record_buffer(3)
  assert_equal(buffers[3].records_sent, 2)
  context.polls.fire("recordState", record_state_value(1, 1, 3))
  assert_equal(S_record_state(3).phase, "armed", "record 1's report changes nothing")
  context.polls.fire("recordState", record_state_value(2, 1, 3))
  context.polls.fire("recordState", record_state_value(1, 1, 3))
  assert_equal(S_record_state(3).number, 2); assert_equal(S_record_state(3).phase, "recording")
  context.polls.fire("recordState", record_state_value(1, 3, 3))
  assert_true(buffers[3].recording, "a stale cancel changes nothing")
end)

test("a playable recording into a 44.1 kHz slot flashes replaced (rate)", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_buffer(1, "/tmp/cd.wav"); context.polls.fire("bufferState", 8)
  buffers[1].sample_rate = 44100
  params:set("record_feedback", 50)
  local_value("S").lib.ui_keys.set_ui_page(local_value("UI_PAGES").index.BUFFER)
  record_buffer(1)
  assert_equal(S_record_state(1).kind, "take")
  assert_equal(local_value("S").lib.ui_flash.text("hints"), "buf 1: replaced (rate)")
end)

test("any_recording and any_armed follow every slot", function()
  local context = load_strata(); finish_startup(context)
  local record = local_value("S").lib.record
  params:set("record_sync", 3)
  record_buffer(1); context.polls.fire("recordState", 32)
  assert_true(record.any_armed()); assert_true(not record.any_recording())
  params:set("record_sync", 1)
  record_buffer(2); context.polls.fire("recordState", 41)
  assert_true(record.any_armed()); assert_true(record.any_recording())
  context.polls.fire("recordState", record_state_value(1, 3, 1))
  assert_true(not record.any_armed(), "slot 1's cancel ends its arming")
  context.polls.fire("recordState", 57)
  assert_true(not record.any_recording(), "slot 2's cancel ends its recording")
end)

test("the record poll starts at init and stops at cleanup", function()
  local context = load_strata(); finish_startup(context)
  assert_true(context.polls.polls.recordState.running)
  cleanup()
  assert_true(not context.polls.polls.recordState.running)
end)


test("a late armed report never regresses a recording", function()
  local context = load_strata(); finish_startup(context)
  params:set("record_sync", 3)
  record_buffer(1)
  context.polls.fire("recordState", record_state_value(1, 1, 1))
  context.polls.fire("recordState", record_state_value(1, 0, 1))
  assert_equal(S_record_state(1).phase, "recording")
end)

-- A 60 s file in slot 1 (standard tier: the slot holds 16 s), started at 12 s
-- and reloaded there, then an armed dub (feedback 50%, a threshold) into it
local DUB_FILE = "/tmp/dub60.wav"
local function arm_dub_over_long_file(context)
  context.audio.register(DUB_FILE, {channels = 2, frames = 2880000, rate = 48000})
  load_buffer(1, DUB_FILE); context.polls.fire("bufferState", 16)
  local_value("S").lib.buffers.set_start(1, 12)
  context.clock.run_for(0.4); context.polls.fire("bufferState", 0); context.polls.fire("bufferState", 16)
  params:set("record_feedback", 50); params:set("record_threshold", 2)
  record_buffer(1)
end

test("a canceled dub keeps the file's start, rate and length", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  arm_dub_over_long_file(context)
  record_buffer(1)                                -- K3 again: the armed dub is canceled
  context.polls.fire("recordState", 56)
  assert_equal(buffers[1].start, 12); assert_equal(buffers[1].file_seconds, 60)
  assert_equal(buffers[1].sample_rate, 48000); assert_equal(buffers[1].path, DUB_FILE)
  assert_equal(buffers[1].recording, false)
end)

test("a dub that ends becomes take n with start 0 and no file length", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  arm_dub_over_long_file(context)
  context.polls.fire("recordState", 40); context.polls.fire("recordState", 48)
  assert_equal(buffers[1].name, "take 1"); assert_equal(buffers[1].start, 0)
  assert_equal(buffers[1].file_seconds, nil); assert_equal(buffers[1].sample_rate, nil)
end)

test("a loop recording downgraded by the sample rate is sent with loop 0", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_buffer(1, "/tmp/cd.wav"); context.polls.fire("bufferState", 8)
  buffers[1].sample_rate = 44100
  params:set("record_loop", 2)
  context.clear_engine_calls(); record_buffer(1)
  assert_equal(recording_calls(context)[1].args[7], 0, "a replace take never loops")
  assert_equal(S_record_state(1).kind, "take"); assert_equal(S_record_state(1).loop, false)
end)

-- #400: a dub into an empty slot is take <n> once it has a length (its path
-- comes at "ended"), so a failed load during it, which the engine answers
-- by canceling the dub and keeping its audio (the state table's row 11),
-- puts back a named slot, never a loaded one named "empty"
test("a failed load during a dub over an empty slot leaves a named slot", function()
  local context = load_strata(); finish_startup(context)
  local S, buffers = local_value("S"), local_value("buffers")
  params:set("record_feedback", 50)
  record_buffer(1)
  context.polls.fire("recordState", record_state_value(1, 1, 1))
  assert_equal(buffers[1].name, "empty", "nothing to name before the engine reports a length")
  context.polls.fire("bufferState", 4)
  assert_equal(buffers[1].name, "take 1", "the dub's audio is take 1 once it has a length")
  assert_equal(buffers[1].path, nil, "its file comes at ended"); assert_equal(S.lib.buffers.status(1), "dub")
  load_buffer(1, "/tmp/bad.wav")
  context.polls.fire("recordState", record_state_value(1, 3, 1))   -- canceled by the load
  context.polls.fire("bufferState", 4)                             -- the slot keeps its audio
  context.polls.fire("bufferLoadFailed", (1 * 2) * 8 + 0)          -- load 1 failed
  context.polls.fire("bufferState", 4)
  assert_equal(S.lib.buffers.status(1), "loaded")
  assert_equal(buffers[1].name, "take 1", "named, not empty"); assert_true(not S.lib.buffers.is_free(1))
  assert_equal(buffers[1].path, nil, "no file was written for it")
  -- a dub over a file keeps the file's name until it ends
  load_buffer(2, "/tmp/drone.wav"); context.polls.fire("bufferState", 1008)
  record_buffer(2); context.polls.fire("recordState", record_state_value(1, 1, 2))
  context.polls.fire("bufferState", 1012)
  assert_equal(buffers[2].name, "drone.wav")
end)

-- #404 (3): K3 on a dub stops it in the engine and waits for its "ended"
-- report: it never finishes as a replace take does
test("K3 on a dub sends stopRecord and leaves it recording until its ended report", function()
  local context = load_strata(); finish_startup(context)
  local S, buffers = local_value("S"), local_value("buffers")
  load_buffer(1, "/tmp/drone.wav"); context.polls.fire("bufferState", 8)
  params:set("record_feedback", 50)
  record_buffer(1); context.polls.fire("recordState", record_state_value(1, 1, 1))
  context.clear_engine_calls()
  record_buffer(1)
  assert_equal(#context.calls_named("stopRecord"), 1)
  assert_true(not buffers[1].finishing, "a dub never finishes"); assert_equal(buffers[1].confirm_since, nil)
  assert_equal(S.lib.buffers.status(1), "dub")
  context.clock.run_for(local_value("BUFFER_SETTLE").fallback_seconds + 1)
  assert_true(buffers[1].recording, "no fallback settles it")
  context.polls.fire("recordState", record_state_value(1, 2, 1))
  assert_equal(buffers[1].name, "take 1"); assert_true(not buffers[1].recording)
end)

-- #404 (4): a recording forgets the slot's tracked loads, so a failure
-- reported for a load sent before it changes nothing, also in a slot that
-- held a file before that load
test("a failed load's report after a recording into a slot that held a file changes nothing", function()
  local context = load_strata(); finish_startup(context)
  local S, buffers = local_value("S"), local_value("buffers")
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 8)   -- load 1
  load_buffer(1, "/tmp/b.wav")                                          -- load 2
  record_buffer(1)                                                      -- a replace take supersedes it
  local before = S.lib.buffers.shown_state(1)
  context.polls.fire("bufferLoadFailed", (2 * 2) * 8 + 0)               -- load 2's late failure
  local after = S.lib.buffers.shown_state(1)
  for _, field in ipairs({ "name", "path", "file_param", "loaded", "confirm_since" }) do
    assert_equal(after[field], before[field], field .. " is as the recording left it")
  end
  assert_true(buffers[1].recording); assert_equal(S.lib.buffers.status(1), "recording")
end)

-- #404 (9): a dub's "ended" report marks its peaks stale, so its waveform is
-- read again although its length did not change
test("a dub's ended report causes a peaks read", function()
  local context = load_strata(); finish_startup(context)
  local frame = 1 / local_value("UI_PAGES").FRAMES_PER_SECOND
  load_buffer(1, "/tmp/drone.wav"); context.polls.fire("bufferState", 8)
  context.clock.run_for(3 * frame)                  -- the load's own read
  params:set("record_feedback", 50); params:set("record_duration", 4)
  record_buffer(1)
  context.polls.fire("recordState", record_state_value(1, 1, 1))
  context.polls.fire("bufferState", 8)              -- a 4 s dub over 8 s: the length stays 8 s
  local reads = 0
  local original_open = io.open
  io.open = function(path, ...)
    if tostring(path):match("buf1%.peaks$") then reads = reads + 1 end
    return original_open(path, ...)
  end
  local ok, problem = pcall(function()
    context.polls.fire("recordState", record_state_value(1, 2, 1))   -- ended
    context.clock.run_for(2 * frame)
  end)
  io.open = original_open
  assert_true(ok, tostring(problem))
  assert_equal(reads, 1, "the ended take's peaks are read")
end)

-- #404 (11): a synced take lasts record_beats at the tempo
test("a synced take at 90 BPM lasts record_beats x 60 / 90 s", function()
  local context = load_strata(); finish_startup(context)
  params:set("clock_tempo", 90); params:set("record_sync", 2); params:set("record_beats", 16)
  context.clear_engine_calls(); record_buffer(1)
  assert_near(recording_calls(context)[1].args[2], 16 * 60 / 90, 1e-6, "16 beats at 90 BPM")
end)

end

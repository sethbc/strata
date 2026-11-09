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
  S.lib.buffers.recording_started = function(slot) table.insert(calls, slot) end
  record_buffer(5)
  assert_equal(#calls, 1, "one call when it sends recordBuffer"); assert_equal(calls[1], 5)
  record_buffer(5)                                -- a stop sends no recordBuffer
  assert_equal(#calls, 1, "no second call for the stop")
  S.lib.buffers.recording_started = original
end)


-- 3.3 record settings, synced takes and playable recordings

local function record_state_value(number, state, slot) return ((number * 4) + state) * 8 + (slot - 1) end
local function S_record_state(slot) return local_value("S").lib.record.state(slot) end
local function recording_calls(context) return context.calls_named("recordBuffer") end

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

test("a canceled armed replace take leaves its slot empty; a canceled playable one keeps it", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 8)
  load_buffer(2, "/tmp/b.wav"); context.polls.fire("bufferState", 1006)
  params:set("record_sync", 3)
  record_buffer(1); context.polls.fire("recordState", 32); context.polls.fire("recordState", 56)
  assert_equal(buffers[1].name, "empty"); assert_true(not buffers[1].loaded); assert_true(not buffers[1].recording)
  params:set("record_sync", 1); params:set("record_feedback", 50)
  record_buffer(2); context.polls.fire("recordState", 33); context.polls.fire("recordState", 57)
  assert_equal(buffers[2].name, "b.wav"); assert_true(buffers[2].loaded); assert_equal(buffers[2].seconds, 6)
  assert_true(not buffers[2].recording)
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

end

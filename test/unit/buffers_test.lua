-- test/unit/buffers_test.lua
-- Buffers: recording, loading, clearing, saving, load failures, the
-- bufferState poll and buffers.data (lib/buffers.lua)
-- Run alone: lua test/run.lua buffers

return function(h)
local test, data_root, assert_true, assert_equal = h.test, h.data_root, h.assert_true, h.assert_equal
local assert_near, load_strata, find_upvalue = h.assert_near, h.load_strata, h.find_upvalue
local local_value, next_frame, finish_startup = h.local_value, h.next_frame, h.finish_startup
local wake_buffer_clock, deep_copy, tabutil_text = h.wake_buffer_clock, h.deep_copy, h.tabutil_text
local HINT_ROW_Y, show_page, assert_screen_layout = h.HINT_ROW_Y, h.show_page, h.assert_screen_layout
local tap = h.tap

test("buffer triggers call the engine and track recording state", function()
  local context = load_strata(); finish_startup(context)  -- finish init's start-up coroutine
  params:set("record_duration", 2); params:set("buf3_record", 1)
  local call = context.calls_named("recordBuffer")[1]
  assert_equal(call.args[1], 2); assert_near(call.args[2], 2, 1e-9); assert_near(call.args[3], 1, 1e-9)
  assert_true(local_value("buffers")[3].recording)
  wake_buffer_clock(context, 3); assert_true(local_value("buffers")[3].recording, "finishing until the engine reports")
  context.polls.fire("bufferState", 202)  -- the engine reports the take
  assert_true(not local_value("buffers")[3].recording)
  assert_equal(local_value("buffers")[3].name, "take 3"); assert_true(local_value("buffers")[3].loaded)
  assert_equal(local_value("buffers")[3].path, _path.audio .. "strata/scratch/buf3.wav", "scratch take path")
  params:set("buf3_file", "/tmp/a.wav"); assert_equal(context.calls_named("loadBuffer")[1].args[2], "/tmp/a.wav")
  assert_equal(context.calls_named("loadBuffer")[1].args[1], 2)
  assert_equal(local_value("buffers")[3].name, "a.wav"); assert_equal(local_value("buffers")[3].path, "/tmp/a.wav")
  params:set("buf3_clear", 1); assert_equal(context.calls_named("clearBuffer")[1].args[1], 2)
  assert_equal(local_value("buffers")[3].name, "empty"); assert_true(not local_value("buffers")[3].loaded)
  context.polls.fire("bufferState", 201.5); assert_near(local_value("buffers")[3].seconds, 1.5, 1e-9)
  context.polls.fire("bufferState", 716); assert_near(local_value("buffers")[8].seconds, 16, 1e-9)
  context.polls.fire("bufferState", 0); assert_near(local_value("buffers")[1].seconds, 0, 1e-9)
  context.polls.fire("bufferState", 950); context.polls.fire("bufferState", -1)  -- out of range: ignored
  -- an empty path or norns' "-" (no file chosen) loads nothing
  context.clear_engine_calls()
  params:set("buf4_file", ""); params:set("buf4_file", "-"); params:set("buf4_file", _path.audio)
  assert_equal(#context.calls_named("loadBuffer"), 0, "no load without a file")
end)

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
  context.polls.fire("bufferState", 101)  -- the engine reports what was captured
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
end)

test("a file the engine cannot read, loaded during a recording, leaves a canceled recording", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  params:set("record_duration", 4)
  local pending = context.clock.pending_count()
  record_buffer(3)
  load_buffer(3, "/tmp/missing.wav")   -- the engine cancels the recording, then cannot read the file
  assert_true(not buffers[3].recording and not buffers[3].finishing, "the load ends the recording state")
  assert_equal(context.clock.pending_count(), pending, "no recording timer or fallback is left to finish a take")
  -- the canceled recording left the slot empty: the engine reports 0 s
  context.polls.fire("bufferState", 200)
  context.set_time(5); context.polls.fire("bufferState", 200)
  assert_true(not buffers[3].loaded, "not loaded"); assert_equal(buffers[3].settled_empty, "load")
  assert_equal(buffers[3].name, "missing.wav", "a failed load, never take 3")
  assert_equal(buffers[3].path, "/tmp/missing.wav")
  context.clock.run_for(10)              -- nothing pending turns it into a take later
  assert_equal(buffers[3].name, "missing.wav"); assert_true(not buffers[3].loaded)
end)

test("a take or a load is confirmed by the engine's bufferState report", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  local function hint()
    for _, entry in ipairs(context.screen.texts) do
      if entry.x == 0 and entry.y == HINT_ROW_Y then return entry.text end
    end
  end
  -- a take that ran its full duration
  params:set("record_duration", 2)
  record_buffer(3)
  wake_buffer_clock(context, 3)                       -- the recording timer ends
  assert_true(buffers[3].recording, "finishing: still shown as recording")
  assert_true(not buffers[3].loaded, "not loaded before the engine reports it")
  assert_equal(buffers[3].name, "empty", "no take name yet")
  params:set("v1_source", 4); show_page("BUFFER")      -- voice 1 reads buf 3
  assert_equal(hint(), "K2:load K3:... K2+3:save", "BUFFER hint while finishing")
  context.clear_engine_calls(); record_buffer(3)
  assert_equal(#context.engine_calls, 0, "a press while finishing sends nothing (no new take, no stop)")
  assert_true(buffers[3].recording, "and changes nothing")
  context.polls.fire("bufferState", 200)        -- a periodic 0 s sent before the take completed
  assert_true(buffers[3].recording and not buffers[3].loaded, "0 s inside the settle time is not the outcome")
  context.polls.fire("bufferState", 202)        -- the engine reports the take
  assert_true(not buffers[3].recording, "finished"); assert_true(buffers[3].loaded, "loaded")
  assert_equal(buffers[3].name, "take 3"); assert_equal(buffers[3].path, scratch_take_path(3))
  show_page("BUFFER")
  assert_equal(hint(), "K2:load K3:rec K2+3:save", "hint back to rec")

  -- stopped within the start-up window: the engine captured nothing
  record_buffer(4); record_buffer(4)
  assert_equal(#context.calls_named("stopRecord"), 1, "the stop is sent")
  assert_true(buffers[4].recording and not buffers[4].loaded, "finishing after the stop")
  context.set_time(5)                           -- past the settle time
  context.polls.fire("bufferState", 300)
  assert_true(not buffers[4].recording, "settled"); assert_true(not buffers[4].loaded, "nothing captured: empty")
  assert_equal(buffers[4].name, "empty"); assert_equal(buffers[4].path, nil)
  context.clear_engine_calls(); record_buffer(4)
  assert_equal(#context.calls_named("recordBuffer"), 1, "an empty slot records again")

  -- a file load shows its name at once; 0 s after the settle time clears loaded
  load_buffer(5, "/tmp/unreadable.wav")
  assert_true(buffers[5].loaded, "optimistic load"); assert_equal(buffers[5].name, "unreadable.wav")
  context.polls.fire("bufferState", 400)
  assert_true(buffers[5].loaded, "0 s inside the settle time keeps the load")
  context.set_time(10); context.polls.fire("bufferState", 400)
  assert_true(not buffers[5].loaded, "the engine has no audio: not loaded")
  assert_equal(buffers[5].name, "unreadable.wav", "the name stays")
  load_buffer(6, "/tmp/fine.wav"); context.polls.fire("bufferState", 503.5)
  assert_true(buffers[6].loaded, "audio reported: loaded"); assert_near(buffers[6].seconds, 3.5, 1e-9)
end)

test("a take settled empty adopts audio the engine reports later; a clear wins", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  params:set("record_duration", 2)
  record_buffer(3); wake_buffer_clock(context, 3)     -- the timer ends; the engine is slow
  context.set_time(5); context.polls.fire("bufferState", 200)
  assert_equal(buffers[3].name, "empty", "a periodic 0 after the settle time empties the slot")
  context.polls.fire("bufferState", 202)        -- the take completes late
  assert_true(buffers[3].loaded, "the late take is adopted"); assert_equal(buffers[3].name, "take 3")
  assert_equal(buffers[3].path, scratch_take_path(3), "with the scratch take path")
  context.polls.fire("bufferState", 202); context.polls.fire("bufferState", 203)
  assert_equal(buffers[3].name, "take 3", "later reports leave it a take")
  -- a slot cleared after an empty take is not brought back by a report
  record_buffer(4); record_buffer(4)
  context.set_time(10); context.polls.fire("bufferState", 300)
  assert_equal(buffers[4].name, "empty")
  clear_buffer(4); context.polls.fire("bufferState", 302)
  assert_true(not buffers[4].loaded, "clear wins"); assert_equal(buffers[4].path, nil)
  -- nor is a slot whose last event was a load or a new recording
  record_buffer(5); record_buffer(5)
  context.set_time(15); context.polls.fire("bufferState", 400)
  record_buffer(5); context.polls.fire("bufferState", 401)
  assert_true(buffers[5].recording, "a new recording is not adopted as the old take")
  assert_true(not buffers[5].finishing)
end)

test("a load settled empty adopts audio the engine reports later; restores count; a clear wins", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  -- a slow read: the engine keeps reporting 0 s past the settle time
  load_buffer(2, "/tmp/slow.wav")
  context.set_time(2); context.polls.fire("bufferState", 100)
  assert_true(not buffers[2].loaded, "settled empty")
  context.polls.fire("bufferState", 116)        -- the read completes
  assert_true(buffers[2].loaded, "the late load is adopted")
  assert_equal(buffers[2].name, "slow.wav", "it keeps the file name")
  assert_equal(buffers[2].path, "/tmp/slow.wav")
  -- a restored slot read late counts once
  load_buffer(3, "/tmp/restored.wav"); buffers[3].restoring = true   -- as load_buffers_from_disk does
  context.set_time(4); context.polls.fire("bufferState", 200)
  assert_equal(local_value("buffers_restored"), 0, "not counted while empty")
  context.polls.fire("bufferState", 208); context.polls.fire("bufferState", 208)
  assert_true(buffers[3].loaded); assert_equal(local_value("buffers_restored"), 1, "counted once when adopted")
  -- a clear, or a new load, in between wins
  load_buffer(4, "/tmp/gone.wav")
  context.set_time(6); context.polls.fire("bufferState", 300)
  clear_buffer(4); context.polls.fire("bufferState", 305)
  assert_true(not buffers[4].loaded, "clear wins"); assert_equal(buffers[4].name, "empty")
  load_buffer(5, "/tmp/first.wav")
  context.set_time(8); context.polls.fire("bufferState", 400)
  load_buffer(5, "/tmp/second.wav"); context.set_time(10); context.polls.fire("bufferState", 400)
  assert_true(not buffers[5].loaded, "the second load settled empty too")
  assert_equal(buffers[5].name, "second.wav", "a new load replaces the old one")
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
  context.polls.fire("bufferState", 301)
  assert_equal(context.clock.pending_count(), pending, "a report settles it and cancels the fallback")
  record_buffer(5); record_buffer(5); load_buffer(5, "/tmp/x.wav")
  assert_equal(context.clock.pending_count(), pending, "load cancels the fallback")
  record_buffer(6); record_buffer(6); clear_buffer(6)
  assert_equal(context.clock.pending_count(), pending, "clear cancels the fallback")
  record_buffer(7); record_buffer(7)
  cleanup()
  assert_equal(context.clock.pending_count(), 0, "cleanup cancels the fallback")
end)

test("bufferState poll is found and started in init", function()
  local context = load_strata()
  local entry = context.polls.polls.bufferState
  assert_true(entry ~= nil, "the engine registers bufferState")
  assert_true(entry.running, "poll started"); assert_true(entry.callback ~= nil, "callback set")
  entry = context.polls.polls.bufferLoadFailed
  assert_true(entry ~= nil, "the engine registers bufferLoadFailed")
  assert_true(entry.running, "bufferLoadFailed started"); assert_true(entry.callback ~= nil, "its callback set")
end)

-- bufferLoadFailed poll value for Lua slot `slot`'s load number `load_number`
-- (the engine counts the loads of each slot from 1); emptied: the server's
-- read failed after the slot was zeroed
local function load_failed_value(slot, load_number, emptied)
  return (load_number * 2 + (emptied and 1 or 0)) * local_value("NUM_BUFFERS") + (slot - 1)
end

local function buffer_hint(context)
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == HINT_ROW_Y then return entry.text end
  end
end

test("a failed load over audio puts the slot's file back and is never remembered", function()
  local subdir = "failed-load-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local buffers = local_value("buffers")
  params:set("v1_source", 3); show_page("BUFFER")      -- voice 1 reads buf 2
  load_buffer(2, "/tmp/good.wav"); context.polls.fire("bufferState", 104)
  assert_true(buffers[2].loaded); assert_equal(buffers[2].name, "good.wav")
  load_buffer(2, "/tmp/corrupt.wav")
  assert_equal(buffers[2].name, "corrupt.wav", "shown at once")
  -- the engine keeps the old audio, so its next report of 4 s settles the load
  context.polls.fire("bufferState", 104)
  assert_true(buffers[2].loaded)
  next_frame(context)
  context.polls.fire("bufferLoadFailed", load_failed_value(2, 2))
  assert_equal(buffers[2].name, "good.wav", "the previous name is back")
  assert_equal(buffers[2].path, "/tmp/good.wav", "and its path")
  assert_true(buffers[2].loaded, "the old audio is still there")
  assert_equal(buffers[2].confirm_since, nil, "nothing left to settle")
  assert_equal(params:get("buf2_file"), "/tmp/good.wav", "the file param shows the old file again")
  assert_true(table.concat(context.printed, "\n"):find("/tmp/corrupt.wav", 1, true), "the console names the bad file")
  next_frame(context)
  assert_equal(buffer_hint(context), "buf 2 load failed", "the BUFFER page says so")
  assert_screen_layout(context, "BUFFER page load failed flash")
  context.clock.run_for(2); next_frame(context)
  assert_equal(buffer_hint(context), "K2:load K3:rec K2+3:save", "briefly")
  -- a duplicate report changes nothing
  context.polls.fire("bufferLoadFailed", load_failed_value(2, 2))
  assert_equal(buffers[2].name, "good.wav"); assert_true(buffers[2].loaded)
  -- the bad path is never remembered
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[2], "/tmp/good.wav", "buffers.data keeps the old file")
end)

test("a failed load into an empty slot leaves it empty; a failed restore is forgotten", function()
  local subdir = "failed-restore-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local buffers = local_value("buffers")
  load_buffer(3, "/tmp/bad.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 1))
  assert_equal(buffers[3].name, "empty"); assert_equal(buffers[3].path, nil)
  assert_true(not buffers[3].loaded, "not loaded"); assert_equal(buffers[3].settled_empty, false)
  assert_equal(buffers[3].confirm_since, nil)
  assert_equal(params:get("buf3_file"), _path.audio, "the file param is back at its starting folder")
  context.set_time(5); context.polls.fire("bufferState", 200)
  assert_equal(buffers[3].name, "empty", "a later 0 s report changes nothing")
  -- a remembered file that exists but cannot be read is not kept for the next start
  util.make_dir(context.audio_dir)
  local good = context.audio_dir .. "good.wav"
  local corrupt = context.audio_dir .. "corrupt.wav"
  for _, path in ipairs({ good, corrupt }) do io.open(path, "w"):close() end
  load_buffer(1, good); load_buffer(4, corrupt)
  cleanup()
  context = load_strata({ data_subdir = subdir })
  buffers = local_value("buffers")
  assert_equal(#context.calls_named("loadBuffer"), 2, "both restored")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 1))
  assert_equal(buffers[4].name, "empty"); assert_equal(buffers[4].path, nil)
  assert_true(not buffers[4].restoring, "no longer restoring")
  context.polls.fire("bufferState", 3)          -- buffer 1 holds 3 s
  assert_equal(local_value("buffers_restored"), 1, "only the readable file counts")
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[1], good); assert_equal(saved.paths[4], "", "the unreadable file is forgotten")
end)

test("a late or duplicate load failure report never undoes a later load, clear or recording", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  -- two loads sent before the first one's failure arrives
  load_buffer(5, "/tmp/orig.wav"); context.polls.fire("bufferState", 403)   -- load 1 holds 3 s
  load_buffer(5, "/tmp/bad.wav")                -- load 2: the engine cannot read it
  load_buffer(5, "/tmp/worse.wav")              -- load 3, sent before load 2's report arrived
  context.polls.fire("bufferLoadFailed", load_failed_value(5, 2))
  assert_equal(buffers[5].name, "worse.wav", "the later load stays")
  assert_equal(buffers[5].path, "/tmp/worse.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(5, 3))
  assert_equal(buffers[5].name, "orig.wav", "both failed: the file before them is back")
  assert_equal(buffers[5].path, "/tmp/orig.wav"); assert_true(buffers[5].loaded)
  assert_equal(params:get("buf5_file"), "/tmp/orig.wav")
  -- duplicates, loads that succeeded, loads never sent and bad values change nothing
  local before = deep_copy(buffers)
  for _, value in ipairs({ load_failed_value(5, 3), load_failed_value(5, 2), load_failed_value(5, 3, true),
    load_failed_value(5, 9), load_failed_value(6, 1), 0 / 0, math.huge, -math.huge, -1, 41.5 }) do
    local ok, message = pcall(context.polls.fire, "bufferLoadFailed", value)
    assert_true(ok, "report " .. tostring(value) .. " raises no error: " .. tostring(message))
    for slot = 1, 8 do
      assert_equal(buffers[slot].name, before[slot].name, "report " .. tostring(value) .. ", slot " .. slot .. " name")
      assert_equal(buffers[slot].path, before[slot].path, "report " .. tostring(value) .. ", slot " .. slot .. " path")
    end
    assert_equal(rawget(buffers, 0), nil); assert_equal(rawget(buffers, 9), nil)
  end
  -- a clear or a new recording after the load wins
  load_buffer(6, "/tmp/x.wav"); clear_buffer(6)
  context.polls.fire("bufferLoadFailed", load_failed_value(6, 1))
  assert_equal(buffers[6].name, "empty", "clear wins"); assert_equal(buffers[6].path, nil)
  load_buffer(7, "/tmp/y.wav"); record_buffer(7)
  context.polls.fire("bufferLoadFailed", load_failed_value(7, 1))
  assert_true(buffers[7].recording, "the new recording wins")
  assert_equal(params:get("buf7_file"), _path.audio)
  -- a failed load during a recording canceled it in the engine: the slot is empty
  params:set("record_duration", 4)
  record_buffer(8); load_buffer(8, "/tmp/z.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(8, 1))
  assert_equal(buffers[8].name, "empty"); assert_equal(buffers[8].path, nil)
  assert_true(not buffers[8].recording and not buffers[8].finishing and not buffers[8].loaded)
  assert_equal(params:get("buf8_file"), _path.audio)
  context.set_time(10); context.polls.fire("bufferState", 700)
  assert_equal(buffers[8].name, "empty", "still empty")
  context.clear_engine_calls(); record_buffer(8)
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records again")
  -- ... unless its take had completed: the engine's report of it is adopted
  record_buffer(4); wake_buffer_clock(context, 4)     -- the timer ends; the engine has the take
  load_buffer(4, "/tmp/w.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 1))
  assert_equal(buffers[4].name, "empty")
  context.polls.fire("bufferState", 304)
  assert_true(buffers[4].loaded, "the take is adopted"); assert_equal(buffers[4].name, "take 4")
  assert_equal(buffers[4].path, scratch_take_path(4))
end)

test("a load whose server read failed leaves the slot empty, in either report order", function()
  local subdir = "failed-read-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local buffers = local_value("buffers")
  -- the file vanished between the engine's checks and the server's read
  load_buffer(2, "/tmp/good.wav"); context.polls.fire("bufferState", 104)
  load_buffer(2, "/tmp/vanished.wav")
  context.polls.fire("bufferState", 100)        -- the slot reads 0 while it fades and reads
  context.polls.fire("bufferLoadFailed", load_failed_value(2, 2, true))
  assert_equal(buffers[2].name, "empty", "the old audio was zeroed: empty, not good.wav")
  assert_equal(buffers[2].path, nil); assert_true(not buffers[2].loaded)
  assert_equal(buffers[2].confirm_since, nil); assert_equal(buffers[2].settled_empty, false)
  assert_equal(params:get("buf2_file"), _path.audio)
  local printed = table.concat(context.printed, "\n")
  assert_true(printed:find("/tmp/vanished.wav", 1, true) and printed:find("the buffer is now empty", 1, true),
    "the console names the file and says the buffer is empty")
  -- a later load that fails at once is reported first: it puts back the
  -- earlier load, whose emptied report then empties the slot
  load_buffer(3, "/tmp/first.wav"); context.polls.fire("bufferState", 203)
  load_buffer(3, "/tmp/vanishing.wav")          -- load 2: its read will fail
  load_buffer(3, "/tmp/missing.wav")            -- load 3: rejected at once
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 3))
  assert_equal(buffers[3].name, "vanishing.wav", "load 3 undone: load 2 is shown")
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 2, true))
  assert_equal(buffers[3].name, "empty", "then load 2 empties the slot"); assert_equal(buffers[3].path, nil)
  -- ... and the other way round
  load_buffer(4, "/tmp/first.wav"); context.polls.fire("bufferState", 303)
  load_buffer(4, "/tmp/vanishing.wav")          -- load 2
  load_buffer(4, "/tmp/missing.wav")            -- load 3, sent before load 2's report arrived
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 2, true))
  assert_equal(buffers[4].name, "missing.wav", "the later load stays")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 3))
  assert_equal(buffers[4].name, "empty", "it fails too: the slot load 2 emptied")
  assert_equal(buffers[4].path, nil); assert_equal(params:get("buf4_file"), _path.audio)
  -- a load that succeeds after an emptied one stays
  load_buffer(5, "/tmp/vanishing.wav"); load_buffer(5, "/tmp/fine.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(5, 1, true))
  assert_equal(buffers[5].name, "fine.wav"); context.polls.fire("bufferState", 402)
  assert_true(buffers[5].loaded, "and is loaded")
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[2], "", "the vanished file is not remembered")
  assert_equal(saved.paths[3], ""); assert_equal(saved.paths[4], ""); assert_equal(saved.paths[5], "/tmp/fine.wav")
end)

test("save_buffer writes a timestamped wav under audio/strata", function()
  local context = load_strata()
  load_buffer(6, "/tmp/x.wav")
  -- the engine has not reported any audio yet: nothing to save (a failed load
  -- leaves loaded = true, so the guard is the poll's seconds)
  save_buffer(6)
  assert_equal(#context.calls_named("saveBuffer"), 0, "loaded flag alone does not save")
  context.polls.fire("bufferState", 504)  -- slot index 5 (buffer 6) holds 4 s
  save_buffer(6)
  local call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[1], 5)
  local dir = _path.audio .. "strata/"
  assert_equal(call.args[2]:sub(1, #dir), dir, "saved under " .. dir)
  assert_true(call.args[2]:sub(#dir + 1):match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-buf6%.wav$"),
    "timestamped name: " .. call.args[2])
  assert_equal(buffer_save_path(6):sub(1, #dir), dir)
  assert_true(util.file_exists(dir), "directory created")
  assert_true(table.concat(context.printed, "\n"):find(call.args[2], 1, true), "path printed")
  -- an empty slot has nothing to save
  context.clear_engine_calls(); save_buffer(1)
  assert_equal(#context.calls_named("saveBuffer"), 0, "empty slot not saved")
  params:set("buf6_save", 1); assert_equal(#context.calls_named("saveBuffer"), 1, "save trigger")
end)

test("explicit save writes a timestamped file; cleanup/init persist buffer paths", function()
  local context = load_strata({ data_subdir = "buf" }); finish_startup(context)  -- init's start-up coroutine
  context.polls.fire("bufferState", 104)  -- buffer 2 holds 4 s (save needs the engine's seconds)
  params:set("buf2_save", 1)
  local call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[1], 1); assert_true(call.args[2]:match("strata/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-buf2%.wav$"))
  params:set("buf1_file", context.audio_dir .. "one.wav"); io.open(context.audio_dir .. "one.wav", "w"):close()
  params:set("buf4_record", 1); wake_buffer_clock(context, 4)
  context.polls.fire("bufferState", 304)  -- the engine reports the take
  assert_equal(local_value("buffers")[4].path, context.audio_dir .. "strata/scratch/buf4.wav")
  assert_equal(scratch_take_path(4), context.audio_dir .. "strata/scratch/buf4.wav")
  cleanup()
  local again = load_strata({ data_subdir = "buf" })
  local loads = again.calls_named("loadBuffer")
  assert_equal(loads[1].args[1], 0); assert_equal(loads[1].args[2], context.audio_dir .. "one.wav")
  assert_equal(#loads, 1, "scratch take not restored when its file is missing")
end)

test("buffers.data format, restored scratch takes and the SETUP count", function()
  local context = load_strata({ data_subdir = "buf_format" }); finish_startup(context)  -- init's start-up coroutine
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  show_page("SETUP")
  assert_true(screen_has("buffers: 0 restored"), "nothing restored without a file")
  local loaded_file = context.audio_dir .. "loop.wav"
  io.open(loaded_file, "w"):close()
  load_buffer(3, loaded_file)
  record_buffer(5); wake_buffer_clock(context, 5)
  context.polls.fire("bufferState", 404)        -- the engine reports the take
  -- the engine wrote the take
  util.make_dir(context.audio_dir .. "strata/scratch/")
  io.open(scratch_take_path(5), "w"):close()
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.version, 1, "format version")
  for slot = 1, 8 do
    local expected = ({ [3] = loaded_file, [5] = scratch_take_path(5) })[slot] or ""
    assert_equal(saved.paths[slot], expected, "slot " .. slot .. " path")
  end

  context = load_strata({ data_subdir = "buf_format" })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 2, "both existing files restored")
  assert_equal(loads[1].args[1], 2); assert_equal(loads[1].args[2], loaded_file)
  assert_equal(loads[2].args[1], 4); assert_equal(loads[2].args[2], scratch_take_path(5))
  local buffers = local_value("buffers")
  assert_equal(buffers[3].name, "loop.wav"); assert_equal(buffers[3].path, loaded_file)
  assert_equal(buffers[5].name, "take 5", "a restored scratch take keeps its take name")
  assert_equal(buffers[5].path, scratch_take_path(5))
  assert_equal(params:get("buf3_file"), loaded_file, "a restored slot's file param shows its path")
  assert_equal(params:get("buf5_file"), scratch_take_path(5), "a restored take's file param shows the take")
  assert_equal(params:get("buf1_file"), _path.audio, "a slot with nothing restored stays at its starting folder")
  assert_equal(local_value("buffers_restored"), 0, "restored once the engine reports audio")
  context.polls.fire("bufferState", 202); context.polls.fire("bufferState", 404)
  assert_equal(local_value("buffers_restored"), 2)
  show_page("SETUP")
  assert_true(screen_has("buffers: 2 restored"), "SETUP shows the restored count")
  -- a slot whose file has gone is skipped and reported, and stays empty
  os.remove(loaded_file)
  cleanup()
  context = load_strata({ data_subdir = "buf_format" })
  assert_equal(#context.calls_named("loadBuffer"), 1, "missing file not loaded")
  assert_equal(local_value("buffers")[3].name, "empty")
  assert_true(table.concat(context.printed, "\n"):find(loaded_file, 1, true), "missing file reported")
  assert_equal(local_value("buffers_restored"), 0, "nothing confirmed by the engine yet")
  context.polls.fire("bufferState", 403)        -- buffer 5's take
  assert_equal(local_value("buffers_restored"), 1)
end)

test("a buffer cleared before exit is saved empty and not restored", function()
  local context = load_strata({ data_subdir = "buf_cleared" })
  local kept_file, cleared_file = context.audio_dir .. "kept.wav", context.audio_dir .. "cleared.wav"
  io.open(kept_file, "w"):close(); io.open(cleared_file, "w"):close()
  load_buffer(2, kept_file); load_buffer(6, cleared_file)
  cleanup()
  context = load_strata({ data_subdir = "buf_cleared" })
  assert_equal(#context.calls_named("loadBuffer"), 2, "both files restored")
  clear_buffer(6)
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[6], "", "the cleared slot is saved as an empty path")
  assert_equal(saved.paths[2], kept_file, "the other slot keeps its file")
  context = load_strata({ data_subdir = "buf_cleared" })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "only the kept slot is restored")
  assert_equal(loads[1].args[1], 1); assert_equal(loads[1].args[2], kept_file)
  local buffers = local_value("buffers")
  assert_equal(buffers[6].name, "empty", "the cleared slot starts empty")
  assert_equal(buffers[6].path, nil, "the cleared slot has no path")
end)

test("restores count engine-confirmed slots; missing remembered files are kept across restarts", function()
  local subdir = "buf_missing"
  local context = load_strata({ data_subdir = subdir })
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  local present = context.audio_dir .. "here.wav"
  local unreadable = context.audio_dir .. "bad.wav"
  local away = context.audio_dir .. "drive/away.wav"   -- on a drive that is unmounted later
  util.make_dir(context.audio_dir .. "drive/")
  for _, path in ipairs({ present, unreadable, away }) do io.open(path, "w"):close() end
  load_buffer(1, present); load_buffer(2, unreadable); load_buffer(3, away)
  cleanup()
  os.remove(away)

  context = load_strata({ data_subdir = subdir })
  local buffers = local_value("buffers")
  assert_equal(#context.calls_named("loadBuffer"), 2, "the two files present are loaded")
  assert_equal(buffers[3].name, "empty", "the missing file's slot stays empty")
  assert_true(not buffers[3].loaded)
  assert_true(table.concat(context.printed, "\n"):find(away, 1, true), "the console names the missing file")
  assert_equal(local_value("buffers_restored"), 0, "nothing restored until the engine reports audio")
  show_page("SETUP")
  assert_true(screen_has("buffers: 0 ok, 1 missing"), "SETUP shows the missing file")
  context.polls.fire("bufferState", 3)          -- buffer 1 holds 3 s
  context.polls.fire("bufferState", 3)          -- the periodic poll repeats it
  assert_equal(local_value("buffers_restored"), 1, "a confirmed slot counts once")
  context.set_time(5); context.polls.fire("bufferState", 100)   -- buffer 2: the engine could not read it
  assert_equal(local_value("buffers_restored"), 1, "a slot without audio does not count")
  assert_true(not buffers[2].loaded, "and is not loaded")
  show_page("SETUP")
  assert_true(screen_has("buffers: 1 ok, 1 missing"), "SETUP count after the reports")
  assert_screen_layout(context, "SETUP with missing buffers")

  -- the missing path survives the next exit, so the sample comes back once
  -- its drive is mounted again
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[1], present); assert_equal(saved.paths[2], unreadable)
  assert_equal(saved.paths[3], away, "the missing file's path is kept")
  io.open(away, "w"):close()
  context = load_strata({ data_subdir = subdir })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 3, "the file is back: restored")
  assert_equal(loads[3].args[1], 2); assert_equal(loads[3].args[2], away)
  context.polls.fire("bufferState", 3); context.polls.fire("bufferState", 201)
  assert_equal(local_value("buffers_restored"), 2)
  show_page("SETUP")
  assert_true(screen_has("buffers: 2 restored"), "no missing files: the plain count")
  -- a slot cleared after a missing restore forgets the path
  cleanup(); os.remove(away)
  context = load_strata({ data_subdir = subdir })
  clear_buffer(3)
  cleanup()
  saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[3], "", "cleared: the missing path is forgotten")

  -- an earlier blocked auto-save does not outlive the next load
  local _, set_blocked = find_upvalue("buffer_autosave_blocked")
  set_blocked(true)
  load_buffers_from_disk()
  assert_equal(local_value("buffer_autosave_blocked"), false, "reset at the top of load_buffers_from_disk")
  set_blocked(true)
  os.remove(context.data_dir .. "strata/buffers.data")
  load_buffers_from_disk()
  assert_equal(local_value("buffer_autosave_blocked"), false, "reset even when there is no file")
end)

test("a buffers file that fails to load does not stop init and survives cleanup", function()
  local bad_files = {
    { name = "wrong version", content = tabutil_text({ version = 99, paths = {} }) },
    { name = "raises on load", content = 'error("corrupt buffers file")' },
    { name = "not a table", content = "return 42" },
    { name = "paths not a table", content = tabutil_text({ version = 1, paths = "x" }) },
  }
  for index, bad in ipairs(bad_files) do
    local subdir = "buf_survive_" .. index
    local data_dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. data_dir .. "'")
    local file = assert(io.open(data_dir .. "buffers.data", "w"))
    file:write(bad.content)
    file:close()

    local context = load_strata({ data_subdir = subdir })  -- init's load fails
    assert_equal(#context.calls_named("loadBuffer"), 0, bad.name .. ": nothing loaded")
    assert_equal(local_value("buffers_restored"), 0, bad.name .. ": nothing restored")
    local recorded = context.audio_dir .. "new.wav"
    io.open(recorded, "w"):close()
    load_buffer(2, recorded)  -- new work after the failed load
    cleanup()
    local backup = io.open(data_dir .. "buffers.data.bak", "r")
    assert_true(backup ~= nil, bad.name .. ": original kept as buffers.data.bak")
    assert_equal(backup:read("*a"), bad.content, bad.name .. ": backup content unchanged")
    backup:close()
    context = load_strata({ data_subdir = subdir })
    assert_equal(context.calls_named("loadBuffer")[1].args[2], recorded, bad.name .. ": new work saved on exit")
  end

  -- if the file cannot be moved aside, cleanup must not overwrite it
  local data_dir = data_root .. "buf_survive_blocked/strata/"
  os.execute("mkdir -p '" .. data_dir .. "buffers.data.bak/occupied'")  -- rename target is a non-empty dir
  local file = assert(io.open(data_dir .. "buffers.data", "w"))
  file:write(bad_files[1].content)
  file:close()
  load_strata({ data_subdir = "buf_survive_blocked" })
  cleanup()
  file = assert(io.open(data_dir .. "buffers.data", "r"))
  assert_equal(file:read("*a"), bad_files[1].content, "unmovable bad file not overwritten by cleanup")
  file:close()
end)

-- #72: a start that failed before init restored the buffers must not let
-- cleanup overwrite buffers.data with the empty in-memory paths
test("cleanup leaves buffers.data alone when init never loaded it (#72)", function()
  local saved_path = "/saved/by/an/earlier/session.wav"
  local sentinel = tabutil_text({ version = 1, paths = { saved_path } })
  local started
  local function write_sentinel(context)
    started = context
    os.execute("mkdir -p '" .. context.data_dir .. "strata/'")
    local file = assert(io.open(context.data_dir .. "strata/buffers.data", "w"))
    file:write(sentinel)
    file:close()
  end
  local function buffers_file_text()
    local file = assert(io.open(started.data_dir .. "strata/buffers.data", "r"))
    local text = file:read("*a")
    file:close()
    return text
  end

  local before_loads, count = h.patched_script("%-%- Load saved scenes from disk",
    'error("simulated init failure before the loads")')
  assert_equal(count, 1, "init's scenes load found")
  before_loads.before_load = write_sentinel
  local between_loads
  between_loads, count = h.patched_script("%-%- Reload the buffers remembered on exit[^\n]*",
    'error("simulated init failure between the loads")')
  assert_equal(count, 1, "init's buffers load found")
  between_loads.before_load = write_sentinel
  local failed_starts = {
    { name = "init never ran", options = { before_load = write_sentinel,
      before_init = function() error("simulated failure before init") end } },
    { name = "init failed before the loads", options = before_loads },
    { name = "init failed after the scenes load", options = between_loads },
  }
  for _, start in ipairs(failed_starts) do
    local ok, load_error = pcall(load_strata, start.options)
    assert_true(not ok and tostring(load_error):find("simulated", 1, true), start.name .. ": the start failed")
    local cleaned, cleanup_error = pcall(cleanup)
    assert_equal(buffers_file_text(), sentinel, start.name .. ": buffers.data unchanged by cleanup")
    assert_true(cleaned, start.name .. ": cleanup runs after a failed start: " .. tostring(cleanup_error))
  end

  -- a start that loaded the file still saves on exit
  local context = load_strata({ before_load = write_sentinel })
  local recorded = context.audio_dir .. "new.wav"
  io.open(recorded, "w"):close()
  load_buffer(2, recorded)
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[1], saved_path, "the missing file's path is kept")
  assert_equal(saved.paths[2], recorded, "after a full start cleanup saves the buffer paths")
end)

test("the same file loads again after a record or clear, from the BUFFER page and PARAMS", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2)  -- voice 1 reads buffer 1
  context.clear_engine_calls()
  local function loads() return #context.calls_named("loadBuffer") end
  tap(2); context.fileselect.last.callback("/tmp/foo.wav")
  assert_equal(loads(), 1, "the BUFFER page loads the picked file")
  assert_equal(params:get("buf1_file"), "/tmp/foo.wav", "and the file param shows it")
  clear_buffer(1)
  assert_equal(params:get("buf1_file"), _path.audio, "clear resets the file param to its starting folder")
  assert_equal(loads(), 1, "the reset is silent (loads nothing)")
  tap(2); context.fileselect.last.callback("/tmp/foo.wav")
  assert_equal(loads(), 2, "the same file loads again after a clear (BUFFER page)")
  record_buffer(1)
  assert_equal(params:get("buf1_file"), _path.audio, "a recording resets the file param")
  assert_equal(loads(), 2, "silently")
  params:set("buf1_file", "/tmp/foo.wav")
  assert_equal(loads(), 3, "the same file loads again after a recording (PARAMS)")
  assert_true(not local_value("buffers")[1].recording, "the load ended the recording")
  tap(2); context.fileselect.last.callback("/tmp/foo.wav")
  assert_equal(loads(), 4, "picking the loaded file again on the BUFFER page reloads it")
  assert_equal(context.calls_named("loadBuffer")[4].args[1], 0); assert_equal(context.calls_named("loadBuffer")[4].args[2], "/tmp/foo.wav")
end)

test("bufferState poll redraws the screen and the grid's buffer page", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local device = context.grid.plug(1, 16, 16); context.grid.press(1, 16, 8, 1)
  load_buffer(3, "/tmp/a.wav")
  local refreshes = device.refresh_count
  context.screen.texts = {}
  context.polls.fire("bufferState", 212.5)
  next_frame(context)
  local found = false
  for _, entry in ipairs(context.screen.texts) do if entry.text == "12.5s" then found = true end end
  assert_true(found, "poll redraws the BUFFER page with the new seconds on the next frame")
  assert_true(device.refresh_count > refreshes, "grid page 4 redrawn")
end)

test("bufferState poll ignores NaN, infinities and out-of-range slots", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local buffers = local_value("buffers")
  context.polls.fire("bufferState", 304)   -- slot 4 holds 4 s
  local before = deep_copy(buffers)
  for _, value in ipairs({ 0 / 0, math.huge, -math.huge, -1, 800 }) do
    local ok, message = pcall(context.polls.fire, "bufferState", value)
    assert_true(ok, "poll value " .. tostring(value) .. " raises no error: " .. tostring(message))
    for slot = 1, 8 do
      assert_equal(buffers[slot].seconds, before[slot].seconds, "poll value " .. tostring(value) .. ", slot " .. slot .. " seconds")
    end
    assert_equal(rawget(buffers, 0), nil, "no slot 0 after " .. tostring(value))
    assert_equal(rawget(buffers, 9), nil, "no slot 9 after " .. tostring(value))
  end
  redraw(); assert_screen_layout(context, "BUFFER page after bad poll values")
end)

end

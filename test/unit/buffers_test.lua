-- test/unit/buffers_test.lua
-- Buffers: loading, clearing, saving, load failures, the
-- bufferState poll and buffers.data (lib/buffers.lua)
-- Run alone: lua test/run.lua buffers

return function(h)
local test, data_root, assert_true, assert_equal = h.test, h.data_root, h.assert_true, h.assert_equal
local assert_near, load_strata, find_upvalue = h.assert_near, h.load_strata, h.find_upvalue
local local_value, next_frame, finish_startup = h.local_value, h.next_frame, h.finish_startup
local wake_buffer_clock, deep_copy, tabutil_text = h.wake_buffer_clock, h.deep_copy, h.tabutil_text
local HINT_ROW_Y, show_page, assert_screen_layout = h.HINT_ROW_Y, h.show_page, h.assert_screen_layout
local tap = h.tap

-- The BUFFER page record's own hint row (its exact keys are tested in
-- pages_buffer_test.lua)
local function buffer_record_hints()
  local S = h.local_value("S")
  return S.registry.pages[S.constants.UI_PAGES.index.BUFFER].hints(false)
end

-- #402: one slot check (lib/buffers.lua's valid_buffer_slot) for every
-- entry point: a slot is a whole number from 1 to NUM_BUFFERS. A whole
-- float (a poll's 3.0 on the device) is that slot; anything else sends
-- nothing and raises nothing
test("a slot that is not a whole number sends nothing and raises nothing; 3.0 is slot 3", function()
  local context = load_strata(); finish_startup(context)
  local S, buffers = local_value("S"), local_value("buffers")
  load_buffer(1, "/tmp/one.wav"); context.polls.fire("bufferState", 4)
  context.clear_engine_calls()
  local bad_slots = { 0, 9, 1.5, 3.5, "2", false, 0 / 0, math.huge, -math.huge }
  for _, slot in ipairs(bad_slots) do
    local where = "slot " .. tostring(slot)
    local ok, problem = pcall(function()
      load_buffer(slot, "/tmp/x.wav"); clear_buffer(slot); record_buffer(slot)
      assert_equal(save_buffer(slot), false, where .. ": save_buffer"); assert_equal(save_buffer_loop(slot), false)
      S.lib.buffers.set_start(slot, 3); S.lib.buffers.recording_started(slot, false)
      assert_equal(S.lib.buffers.status(slot), nil, where .. ": status")
      assert_equal(S.lib.buffers.is_free(slot), false, where .. ": is_free")
      assert_equal(S.lib.buffers.valid_buffer_slot(slot), false, where .. ": valid_buffer_slot")
      assert_equal(S.lib.files.random_into(slot), false, where .. ": random_into")
      S.lib.waveforms.stale(slot)
      assert_equal(S.lib.waveforms.peaks(slot), nil, where .. ": peaks")
      assert_equal(S.lib.playheads.record_head(slot), nil, where .. ": record_head")
      assert_equal(S.lib.playheads.moving(slot), false, where .. ": moving")
    end)
    assert_true(ok, where .. " raises nothing: " .. tostring(problem))
  end
  local ok, problem = pcall(function() load_buffer(nil, "/tmp/x.wav"); clear_buffer(); record_buffer() end)
  assert_true(ok, "nil raises nothing: " .. tostring(problem))
  assert_equal(#context.engine_calls, 0, "no engine call for any of them")
  assert_equal(buffers[1].name, "one.wav", "slot 1 is untouched")
  -- a whole float is the slot itself
  ok, problem = pcall(function()
    load_buffer(3.0, "/tmp/three.wav")
    assert_equal(context.calls_named("loadBuffer")[1].args[1], 2, "loadBuffer for engine slot 2")
    assert_equal(buffers[3].name, "three.wav"); assert_equal(params:get("buf3_file"), "/tmp/three.wav")
    assert_equal(S.lib.buffers.status(3.0), "loading")
    context.polls.fire("bufferState", 2004)
    assert_true(save_buffer(3.0), "a save of slot 3")
    assert_equal(context.calls_named("saveBuffer")[1].args[1], 2)
    record_buffer(3.0)
    assert_equal(context.calls_named("recordBuffer")[1].args[1], 2)
    clear_buffer(3.0)
    assert_equal(context.calls_named("clearBuffer")[1].args[1], 2)
    assert_equal(params:get("buf3_file"), _path.audio)
  end)
  assert_true(ok, "3.0 is slot 3: " .. tostring(problem))
end)

test("buffer triggers call the engine and track recording state", function()
  local context = load_strata(); finish_startup(context)  -- finish init's start-up coroutine
  params:set("record_duration", 2); params:set("buf3_record", 1)
  local call = context.calls_named("recordBuffer")[1]
  assert_equal(call.args[1], 2); assert_near(call.args[2], 2, 1e-9); assert_near(call.args[3], 1, 1e-9)
  assert_true(local_value("buffers")[3].recording)
  wake_buffer_clock(context, 3); assert_true(local_value("buffers")[3].recording, "finishing until the engine reports")
  context.polls.fire("bufferState", 2002)  -- the engine reports the take
  assert_true(not local_value("buffers")[3].recording)
  assert_equal(local_value("buffers")[3].name, "take 3"); assert_true(local_value("buffers")[3].loaded)
  assert_equal(local_value("buffers")[3].path, _path.audio .. "strata/scratch/buf3.wav", "scratch take path")
  params:set("buf3_file", "/tmp/a.wav"); assert_equal(context.calls_named("loadBuffer")[1].args[2], "/tmp/a.wav")
  assert_equal(context.calls_named("loadBuffer")[1].args[1], 2)
  assert_equal(local_value("buffers")[3].name, "a.wav"); assert_equal(local_value("buffers")[3].path, "/tmp/a.wav")
  params:set("buf3_clear", 1); assert_equal(context.calls_named("clearBuffer")[1].args[1], 2)
  assert_equal(local_value("buffers")[3].name, "empty"); assert_true(not local_value("buffers")[3].loaded)
  context.polls.fire("bufferState", 2001.5); assert_near(local_value("buffers")[3].seconds, 1.5, 1e-9)
  context.polls.fire("bufferState", 7016); assert_near(local_value("buffers")[8].seconds, 16, 1e-9)
  context.polls.fire("bufferState", 0); assert_near(local_value("buffers")[1].seconds, 0, 1e-9)
  context.polls.fire("bufferState", 9050); context.polls.fire("bufferState", -1)  -- out of range: ignored
  -- an empty path or norns' "-" (no file chosen) loads nothing
  context.clear_engine_calls()
  params:set("buf4_file", ""); params:set("buf4_file", "-"); params:set("buf4_file", _path.audio)
  assert_equal(#context.calls_named("loadBuffer"), 0, "no load without a file")
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
  context.polls.fire("bufferState", 2000)
  context.set_time(5); context.polls.fire("bufferState", 2000)
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
  local_value("buffer_page").slot = 3; redraw()      -- BUFFER's slot cursor on it
  assert_equal(hint(), buffer_record_hints(), "BUFFER hint while finishing")
  assert_true(hint():find("K3:...", 1, true), "K3 waits while the take finishes")
  context.clear_engine_calls(); record_buffer(3)
  assert_equal(#context.engine_calls, 0, "a press while finishing sends nothing (no new take, no stop)")
  assert_true(buffers[3].recording, "and changes nothing")
  context.polls.fire("bufferState", 2000)        -- a periodic 0 s sent before the take completed
  assert_true(buffers[3].recording and not buffers[3].loaded, "0 s inside the settle time is not the outcome")
  context.polls.fire("bufferState", 2002)        -- the engine reports the take
  assert_true(not buffers[3].recording, "finished"); assert_true(buffers[3].loaded, "loaded")
  assert_equal(buffers[3].name, "take 3"); assert_equal(buffers[3].path, scratch_take_path(3))
  show_page("BUFFER")
  assert_equal(hint(), buffer_record_hints(), "hint back to rec")
  assert_true(hint():find("K3:rec", 1, true), "K3 records again")

  -- stopped within the start-up window: the engine captured nothing
  record_buffer(4); record_buffer(4)
  assert_equal(#context.calls_named("stopRecord"), 1, "the stop is sent")
  assert_true(buffers[4].recording and not buffers[4].loaded, "finishing after the stop")
  context.set_time(5)                           -- past the settle time
  context.polls.fire("bufferState", 3000)
  assert_true(not buffers[4].recording, "settled"); assert_true(not buffers[4].loaded, "nothing captured: empty")
  assert_equal(buffers[4].name, "empty"); assert_equal(buffers[4].path, nil)
  context.clear_engine_calls(); record_buffer(4)
  assert_equal(#context.calls_named("recordBuffer"), 1, "an empty slot records again")

  -- a file load shows its name at once; 0 s after the settle time clears loaded
  load_buffer(5, "/tmp/unreadable.wav")
  assert_true(buffers[5].loaded, "optimistic load"); assert_equal(buffers[5].name, "unreadable.wav")
  context.polls.fire("bufferState", 4000)
  assert_true(buffers[5].loaded, "0 s inside the settle time keeps the load")
  context.set_time(10); context.polls.fire("bufferState", 4000)
  assert_true(not buffers[5].loaded, "the engine has no audio: not loaded")
  assert_equal(buffers[5].name, "unreadable.wav", "the name stays")
  load_buffer(6, "/tmp/fine.wav"); context.polls.fire("bufferState", 5003.5)
  assert_true(buffers[6].loaded, "audio reported: loaded"); assert_near(buffers[6].seconds, 3.5, 1e-9)
end)

test("a load settled empty adopts audio the engine reports later; restores count; a clear wins", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  -- a slow read: the engine keeps reporting 0 s past the settle time
  load_buffer(2, "/tmp/slow.wav")
  context.set_time(2); context.polls.fire("bufferState", 1000)
  assert_true(not buffers[2].loaded, "settled empty")
  context.polls.fire("bufferState", 1016)        -- the read completes
  assert_true(buffers[2].loaded, "the late load is adopted")
  assert_equal(buffers[2].name, "slow.wav", "it keeps the file name")
  assert_equal(buffers[2].path, "/tmp/slow.wav")
  -- a restored slot read late counts once
  load_buffer(3, "/tmp/restored.wav"); buffers[3].restoring = true   -- as load_buffers_from_disk does
  context.set_time(4); context.polls.fire("bufferState", 2000)
  assert_equal(local_value("buffers_restored"), 0, "not counted while empty")
  context.polls.fire("bufferState", 2008); context.polls.fire("bufferState", 2008)
  assert_true(buffers[3].loaded); assert_equal(local_value("buffers_restored"), 1, "counted once when adopted")
  -- a clear, or a new load, in between wins
  load_buffer(4, "/tmp/gone.wav")
  context.set_time(6); context.polls.fire("bufferState", 3000)
  clear_buffer(4); context.polls.fire("bufferState", 3005)
  assert_true(not buffers[4].loaded, "clear wins"); assert_equal(buffers[4].name, "empty")
  load_buffer(5, "/tmp/first.wav")
  context.set_time(8); context.polls.fire("bufferState", 4000)
  load_buffer(5, "/tmp/second.wav"); context.set_time(10); context.polls.fire("bufferState", 4000)
  assert_true(not buffers[5].loaded, "the second load settled empty too")
  assert_equal(buffers[5].name, "second.wav", "a new load replaces the old one")
end)

test("load_buffer sends start 0 and save_buffer the whole region", function()
  local context = load_strata(); finish_startup(context)
  load_buffer(3, "/x/a.wav")
  local load = context.calls_named("loadBuffer")[1]
  assert_equal(#load.args, 3, "slot, path, start")
  assert_equal(load.args[1], 2); assert_equal(load.args[2], "/x/a.wav"); assert_equal(load.args[3], 0)
  context.polls.fire("bufferState", 2004)  -- the engine reports the file's length
  assert_true(save_buffer(3), "a loaded slot saves")
  local save = context.calls_named("saveBuffer")[1]
  assert_equal(#save.args, 4, "slot, path, start, length")
  assert_equal(save.args[1], 2); assert_equal(save.args[3], 0); assert_equal(save.args[4], 1)
end)

-- A restore that settles empty is no longer restoring; a late report of
-- audio still adopts it and counts it once (#163)
test("a restore that settles empty clears restoring, and late audio still counts once", function()
  local subdir = "restore-settles-empty-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  util.make_dir(context.audio_dir)
  local slow = context.audio_dir .. "slow.wav"
  io.open(slow, "w"):close()
  load_buffer(2, slow)
  cleanup()
  context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local buffers = local_value("buffers")
  assert_true(buffers[2].restoring, "restoring until the engine reports")
  context.set_time(5); context.polls.fire("bufferState", 1000)   -- 0 s, past the settle time
  assert_true(not buffers[2].loaded, "settled empty")
  assert_true(not buffers[2].restoring, "a settled slot is no longer restoring")
  assert_equal(buffers[2].settled_empty, "restore", "the settle remembers it was a restore")
  assert_equal(buffer_state_before_load(2).restoring, false, "a later load's undo state is not restoring")
  context.polls.fire("bufferState", 1012); context.polls.fire("bufferState", 1012)
  assert_true(buffers[2].loaded, "the late read is adopted")
  assert_equal(buffers[2].name, "slow.wav", "under its file name")
  assert_equal(buffers[2].settled_empty, false)
  assert_equal(local_value("buffers_restored"), 1, "and counted once")
  -- a restore that gets audio at once counts and clears restoring too
  load_buffer(3, slow); buffers[3].restoring = true   -- as load_buffers_from_disk does
  context.polls.fire("bufferState", 2004)
  assert_true(not buffers[3].restoring); assert_equal(local_value("buffers_restored"), 2)
  -- a plain load that settles empty is still a load
  load_buffer(4, slow)
  context.set_time(10); context.polls.fire("bufferState", 3000)
  assert_equal(buffers[4].settled_empty, "load")
  context.polls.fire("bufferState", 3004)
  assert_equal(local_value("buffers_restored"), 2, "a plain load never counts as restored")
end)

test("bufferState poll is found and started in init", function()
  local context = load_strata()
  local entry = context.polls.polls.bufferState
  assert_true(entry ~= nil, "the engine registers bufferState")
  assert_true(entry.running, "poll started"); assert_true(entry.callback ~= nil, "callback set")
  entry = context.polls.polls.bufferLoadFailed
  assert_true(entry ~= nil, "the engine registers bufferLoadFailed")
  assert_true(entry.running, "bufferLoadFailed started"); assert_true(entry.callback ~= nil, "its callback set")
  entry = context.polls.polls.bufferSaveResult
  assert_true(entry ~= nil, "the engine registers bufferSaveResult")
  assert_true(entry.running, "bufferSaveResult started"); assert_true(entry.callback ~= nil, "its callback set")
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
  load_buffer(2, "/tmp/good.wav"); context.polls.fire("bufferState", 1004)
  assert_true(buffers[2].loaded); assert_equal(buffers[2].name, "good.wav")
  load_buffer(2, "/tmp/corrupt.wav")
  assert_equal(buffers[2].name, "corrupt.wav", "shown at once")
  -- the engine keeps the old audio, so its next report of 4 s settles the load
  context.polls.fire("bufferState", 1004)
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
  assert_equal(buffer_hint(context), buffer_record_hints(), "briefly: then the page's own hints")
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
  context.set_time(5); context.polls.fire("bufferState", 2000)
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
  load_buffer(5, "/tmp/orig.wav"); context.polls.fire("bufferState", 4003)   -- load 1 holds 3 s
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
  context.set_time(10); context.polls.fire("bufferState", 7000)
  assert_equal(buffers[8].name, "empty", "still empty")
  context.clear_engine_calls(); record_buffer(8)
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records again")
  -- ... unless its take had completed: the engine's report of it is adopted
  record_buffer(4); wake_buffer_clock(context, 4)     -- the timer ends; the engine has the take
  load_buffer(4, "/tmp/w.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 1))
  assert_equal(buffers[4].name, "empty")
  context.polls.fire("bufferState", 3004)
  assert_true(buffers[4].loaded, "the take is adopted"); assert_equal(buffers[4].name, "take 4")
  assert_equal(buffers[4].path, scratch_take_path(4))
end)

-- #311: a synced replace take prepares its slot only just before its start;
-- a bad load before then cancels the take and leaves the slot's audio, and
-- the engine reports the slot's length after "canceled", then the failure
test("a failed load while a synced replace take waits puts back what the slot holds", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  local S = local_value("S")
  load_buffer(5, "/tmp/a.wav"); context.polls.fire("bufferState", 4000.5)
  params:set("record_sync", 3)
  record_buffer(5); context.polls.fire("recordState", 36)           -- armed (record 1, slot 5)
  load_buffer(5, "/tmp/missing.wav")                                -- load 2
  context.polls.fire("recordState", 60)                             -- canceled
  context.polls.fire("bufferState", 4000.5)                         -- the slot as the take left it
  context.polls.fire("bufferLoadFailed", load_failed_value(5, 2))
  context.polls.fire("bufferState", 4000.5)                         -- the periodic report
  assert_equal(buffers[5].name, "a.wav", "not take 5"); assert_equal(buffers[5].path, "/tmp/a.wav")
  assert_true(buffers[5].loaded); assert_equal(params:get("buf5_file"), "/tmp/a.wav")
  assert_equal(S.lib.buffers.status(5), "loaded")
  -- the engine had prepared the slot (0 s): the take left it empty
  load_buffer(6, "/tmp/b.wav"); context.polls.fire("bufferState", 5000.5)
  record_buffer(6); context.polls.fire("recordState", 37)
  context.polls.fire("bufferState", 5000)                           -- prepared
  load_buffer(6, "/tmp/missing.wav")
  context.polls.fire("recordState", 61); context.polls.fire("bufferState", 5000)
  context.polls.fire("bufferLoadFailed", load_failed_value(6, 2))
  assert_equal(buffers[6].name, "empty"); assert_equal(buffers[6].path, nil); assert_true(not buffers[6].loaded)
  assert_equal(buffers[6].settled_empty, "take", "a take that had completed would still be adopted")
end)

-- The same after K3: Lua asked the engine to cancel the armed take, and the
-- bad load is sent before the "canceled" report arrives. The take never
-- recorded, so the length the engine reports after its cancel decides
test("a failed load right after K3 cancels a synced take, before its canceled report, puts back what the slot holds", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  local S = local_value("S")
  load_buffer(4, "/tmp/a.wav"); context.polls.fire("bufferState", 3008)
  params:set("record_sync", 3)
  record_buffer(4); context.polls.fire("recordState", 35)           -- armed (record 1, slot 4)
  record_buffer(4)                                                  -- K3: the cancel is on its way
  load_buffer(4, "/tmp/missing.wav")                                -- load 2, before the cancel's report
  context.polls.fire("recordState", 59); context.polls.fire("bufferState", 3008)
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 2))
  context.polls.fire("bufferState", 3008)                           -- the periodic report
  assert_equal(buffers[4].name, "a.wav", "not take 4"); assert_equal(buffers[4].path, "/tmp/a.wav")
  assert_true(buffers[4].loaded); assert_equal(S.lib.buffers.status(4), "loaded")
  -- the engine had prepared the slot (0 s after the cancel): empty
  load_buffer(6, "/tmp/b.wav"); context.polls.fire("bufferState", 5008)
  record_buffer(6); context.polls.fire("recordState", 37)
  context.polls.fire("bufferState", 5000)                           -- prepared
  record_buffer(6); load_buffer(6, "/tmp/missing.wav")
  context.polls.fire("recordState", 61); context.polls.fire("bufferState", 5000)
  context.polls.fire("bufferLoadFailed", load_failed_value(6, 2))
  assert_equal(buffers[6].name, "empty"); assert_equal(buffers[6].path, nil); assert_true(not buffers[6].loaded)
end)

test("a load whose server read failed leaves the slot empty, in either report order", function()
  local subdir = "failed-read-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local buffers = local_value("buffers")
  -- the file vanished between the engine's checks and the server's read
  load_buffer(2, "/tmp/good.wav"); context.polls.fire("bufferState", 1004)
  load_buffer(2, "/tmp/vanished.wav")
  context.polls.fire("bufferState", 1000)        -- the slot reads 0 while it fades and reads
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
  load_buffer(3, "/tmp/first.wav"); context.polls.fire("bufferState", 2003)
  load_buffer(3, "/tmp/vanishing.wav")          -- load 2: its read will fail
  load_buffer(3, "/tmp/missing.wav")            -- load 3: rejected at once
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 3))
  assert_equal(buffers[3].name, "vanishing.wav", "load 3 undone: load 2 is shown")
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 2, true))
  assert_equal(buffers[3].name, "empty", "then load 2 empties the slot"); assert_equal(buffers[3].path, nil)
  -- ... and the other way round
  load_buffer(4, "/tmp/first.wav"); context.polls.fire("bufferState", 3003)
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
  assert_equal(buffers[5].name, "fine.wav"); context.polls.fire("bufferState", 4002)
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
  context.polls.fire("bufferState", 5004)  -- slot index 5 (buffer 6) holds 4 s
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

-- bufferSaveResult poll value for Lua slot `slot`'s save number
-- `save_number` (the engine counts the saveBuffer commands of each slot from
-- 1); failed: the engine could not write the file
local function save_result_value(slot, save_number, failed)
  return (save_number * 2 + (failed and 1 or 0)) * local_value("NUM_BUFFERS") + (slot - 1)
end

local function printed_since(context, count)
  local lines = {}
  for index = count + 1, #context.printed do lines[#lines + 1] = context.printed[index] end
  return table.concat(lines, "\n")
end

test("a save says saved only once the engine reports the file written (#127)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  context.polls.fire("bufferState", 1004)   -- buffer 2 holds 4 s
  local printed = #context.printed
  assert_equal(save_buffer(2), true, "save_buffer says it sent the save")
  local path = context.calls_named("saveBuffer")[1].args[2]
  local text = printed_since(context, printed)
  assert_true(text:find("buffer 2 saving to " .. path, 1, true), "the console says the save is under way: " .. text)
  assert_true(not text:find("saved", 1, true), "and never that it is saved before the engine says so")
  -- the engine wrote it
  printed = #context.printed
  context.polls.fire("bufferSaveResult", save_result_value(2, 1)); next_frame(context)
  assert_true(printed_since(context, printed):find("buffer 2 saved to " .. path, 1, true), "then that it is saved")
  assert_equal(buffer_hint(context), "saved buf 2", "and the BUFFER page confirms it")
  assert_screen_layout(context, "BUFFER page saved flash")
  -- the engine could not write the next one (a full disk, a folder it cannot make)
  context.clock.run_for(2)
  save_buffer(2)
  local failed_path = context.calls_named("saveBuffer")[2].args[2]
  printed = #context.printed
  context.polls.fire("bufferSaveResult", save_result_value(2, 2, true)); next_frame(context)
  text = printed_since(context, printed)
  assert_true(text:find("buffer 2: cannot save " .. failed_path, 1, true), "the console says it failed: " .. text)
  assert_true(not text:find("saved to", 1, true), "never that it saved")
  assert_equal(buffer_hint(context), "buf 2 save failed", "the BUFFER page says the save failed")
  assert_screen_layout(context, "BUFFER page save failed flash")
  context.clock.run_for(2); next_frame(context)
  assert_equal(buffer_hint(context), buffer_record_hints(), "briefly: then the page's own hints")
  -- an empty slot sends nothing, so it takes no save number
  assert_equal(save_buffer(3), false, "an empty slot is not saved")
  context.polls.fire("bufferState", 2002); save_buffer(3)
  context.polls.fire("bufferSaveResult", save_result_value(3, 1)); next_frame(context)
  assert_equal(buffer_hint(context), "saved buf 3", "the slot's first save sent is its save 1")
end)

test("a late, duplicate or bad save report never corrects a newer save", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  context.polls.fire("bufferState", 4003)   -- buffer 5 holds 3 s
  save_buffer(5); save_buffer(5)            -- save 2 sent before save 1's report
  context.polls.fire("bufferSaveResult", save_result_value(5, 2)); next_frame(context)
  assert_equal(buffer_hint(context), "saved buf 5", "the newest save is confirmed")
  local printed = #context.printed
  context.polls.fire("bufferSaveResult", save_result_value(5, 1, true)); next_frame(context)
  assert_equal(buffer_hint(context), "saved buf 5", "an older save's late failure leaves the newer save's flash")
  assert_true(printed_since(context, printed):find("buffer 5: cannot save", 1, true),
    "the console still names the older file")
  -- the other order: the older save's late success never confirms a newer save still writing
  save_buffer(5); save_buffer(5)            -- saves 3 and 4
  context.clock.run_for(2); next_frame(context)
  context.polls.fire("bufferSaveResult", save_result_value(5, 3)); next_frame(context)
  assert_equal(buffer_hint(context), buffer_record_hints(), "save 3's success says nothing of save 4")
  context.polls.fire("bufferSaveResult", save_result_value(5, 4, true)); next_frame(context)
  assert_equal(buffer_hint(context), "buf 5 save failed", "save 4's own report shows")
  -- repeats, saves never sent, another slot's numbers and bad values do nothing
  context.clock.run_for(2); next_frame(context)
  printed = #context.printed
  for _, value in ipairs({ save_result_value(5, 4, true), save_result_value(5, 4), save_result_value(5, 3),
    save_result_value(5, 9), save_result_value(6, 1), 0, 0 / 0, math.huge, -math.huge, -1, 41.5 }) do
    local ok, message = pcall(context.polls.fire, "bufferSaveResult", value)
    assert_true(ok, "report " .. tostring(value) .. " raises no error: " .. tostring(message))
    next_frame(context)
    assert_equal(buffer_hint(context), buffer_record_hints(), "report " .. tostring(value) .. " flashes nothing")
  end
  assert_equal(printed_since(context, printed), "", "and prints nothing")
  assert_equal(rawget(local_value("buffers"), 0), nil); assert_equal(rawget(local_value("buffers"), 9), nil)
  -- a load, clear or recording in the slot leaves a save in flight alone:
  -- its report is about the file it writes
  save_buffer(5); clear_buffer(5)
  context.polls.fire("bufferSaveResult", save_result_value(5, 5)); next_frame(context)
  assert_equal(buffer_hint(context), "saved buf 5", "the save sent before the clear is still confirmed")
end)

test("explicit save writes a timestamped file; cleanup/init persist buffer paths", function()
  local context = load_strata({ data_subdir = "buf" }); finish_startup(context)  -- init's start-up coroutine
  context.polls.fire("bufferState", 1004)  -- buffer 2 holds 4 s (save needs the engine's seconds)
  params:set("buf2_save", 1)
  local call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[1], 1); assert_true(call.args[2]:match("strata/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-buf2%.wav$"))
  params:set("buf1_file", context.audio_dir .. "one.wav"); io.open(context.audio_dir .. "one.wav", "w"):close()
  params:set("buf4_record", 1); wake_buffer_clock(context, 4)
  context.polls.fire("bufferState", 3004)  -- the engine reports the take
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
  show_page("SETUP"); enc(2, 20); redraw()  -- the status lines are below the fields
  assert_true(screen_has("buffers: 0 restored"), "nothing restored without a file")
  local loaded_file = context.audio_dir .. "loop.wav"
  io.open(loaded_file, "w"):close()
  load_buffer(3, loaded_file)
  record_buffer(5); wake_buffer_clock(context, 5)
  context.polls.fire("bufferState", 4004)        -- the engine reports the take
  -- the engine wrote the take
  util.make_dir(context.audio_dir .. "strata/scratch/")
  io.open(scratch_take_path(5), "w"):close()
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.version, 2, "format version")
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
  context.polls.fire("bufferState", 2002); context.polls.fire("bufferState", 4004)
  assert_equal(local_value("buffers_restored"), 2)
  show_page("SETUP"); enc(2, 20); redraw()  -- the status lines are below the fields
  assert_true(screen_has("buffers: 2 restored"), "SETUP shows the restored count")
  -- a slot whose file has gone is skipped and reported, and stays empty
  os.remove(loaded_file)
  cleanup()
  context = load_strata({ data_subdir = "buf_format" })
  assert_equal(#context.calls_named("loadBuffer"), 1, "missing file not loaded")
  assert_equal(local_value("buffers")[3].name, "empty")
  assert_true(table.concat(context.printed, "\n"):find(loaded_file, 1, true), "missing file reported")
  assert_equal(local_value("buffers_restored"), 0, "nothing confirmed by the engine yet")
  context.polls.fire("bufferState", 4003)        -- buffer 5's take
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
  show_page("SETUP"); enc(2, 20); redraw()  -- the status lines are below the fields
  assert_true(screen_has("buffers: 0 ok, 1 missing"), "SETUP shows the missing file")
  context.polls.fire("bufferState", 3)          -- buffer 1 holds 3 s
  context.polls.fire("bufferState", 3)          -- the periodic poll repeats it
  assert_equal(local_value("buffers_restored"), 1, "a confirmed slot counts once")
  context.set_time(5); context.polls.fire("bufferState", 1000)   -- buffer 2: the engine could not read it
  assert_equal(local_value("buffers_restored"), 1, "a slot without audio does not count")
  assert_true(not buffers[2].loaded, "and is not loaded")
  show_page("SETUP"); enc(2, 20); redraw()  -- the status lines are below the fields
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
  context.polls.fire("bufferState", 3); context.polls.fire("bufferState", 2001)
  assert_equal(local_value("buffers_restored"), 2)
  show_page("SETUP"); enc(2, 20); redraw()  -- the status lines are below the fields
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

-- #480: norns' file param lists the folder of every new path it is set to
-- (File:loaddir: util.scandir, a blocking ls with the folder between double
-- quotes). A file's folder is listed, as PARAMETERS' E3 needs; the audio
-- folder a clear, a take or a dub's end shows names no file, so nothing is
-- listed for it; nor is a folder the shell would read inside double quotes
-- ($, `, \ or "), where the listing would run what the name says (#465)
test("the file param lists a loaded file's folder only, never one the shell reads (#480)", function()
  local context = load_strata(); finish_startup(context)
  local folder = context.audio_dir .. "kit/"
  local marker = context.audio_dir .. "f480_marker"
  local odd = context.audio_dir .. "$(touch " .. marker .. ")/"
  util.make_dir(folder)
  os.execute("mkdir -p -- '" .. odd:gsub("'", "'\\''") .. "'")
  for _, path in ipairs({ folder .. "a.wav", folder .. "b.wav", odd .. "c.wav" }) do io.open(path, "w"):close() end
  local listed = {}
  local scandir = util.scandir
  util.scandir = function(directory)
    table.insert(listed, directory)
    return scandir(directory)
  end
  local ok, problem = pcall(function()
    load_buffer(1, folder .. "a.wav")
    assert_equal(table.concat(listed, " "), folder, "a loaded file's folder, once")
    assert_equal(params:lookup_param("buf1_file").dirpos, 1, "PARAMETERS' E3 steps from it")
    load_buffer(1, folder .. "a.wav", 0)
    assert_equal(#listed, 1, "the same file again lists nothing")
    clear_buffer(1)
    assert_equal(#listed, 1, "a clear lists nothing")
    assert_equal(params:get("buf1_file"), _path.audio, "it shows the audio folder")
    assert_equal(params:lookup_param("buf1_file").dir, _path.audio, "where PARAMETERS' file selector opens")
    record_buffer(2)
    assert_equal(#listed, 1, "a take lists nothing")
    load_buffer(3, odd .. "c.wav")
    assert_equal(#listed, 1, "a folder the shell would read is not listed")
    assert_equal(params:get("buf3_file"), odd .. "c.wav", "the param still shows the file")
    assert_equal(params:string("buf3_file"), "c.wav")
  end)
  util.scandir = scandir
  assert_true(ok, tostring(problem))
  assert_true(not util.file_exists(marker), "no folder name ran as a command")
end)

-- #524: a PSET read sets each file param, and norns' File:set runs the
-- action (a load) only for a path that changed (ParamSet:read never bangs),
-- so a slot whose file the PSET names again is not reloaded; one the PSET
-- names a different file for is
test("a PSET round trip reloads no slot whose file is unchanged (#524)", function()
  local context = load_strata(); finish_startup(context)
  local num_buffers = local_value("NUM_BUFFERS")
  for slot = 1, num_buffers do
    load_buffer(slot, "/tmp/f" .. slot .. ".wav"); context.polls.fire("bufferState", (slot - 1) * 1000 + 4)
  end
  local path = context.data_dir .. "buffers-524.pset"
  params:write(path)
  context.clear_engine_calls()
  params:read(path)
  assert_equal(#context.calls_named("loadBuffer"), 0, "every slot already holds the PSET's file")
  clear_buffer(4)
  context.clear_engine_calls()
  params:read(path)
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "only the cleared slot loads"); assert_equal(loads[1].args[2], "/tmp/f4.wav")
end)

-- #404 (5): a load into a slot whose remembered file was missing forgets
-- that file, which SETUP counted as missing
test("a load into a missing slot lowers SETUP's missing count", function()
  local subdir = "load_missing_" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local away = context.audio_dir .. "away.wav"
  util.make_dir(context.audio_dir)
  io.open(away, "w"):close()
  load_buffer(3, away)
  cleanup()
  os.remove(away)
  context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local function screen_has(text)
    show_page("SETUP"); enc(2, 20); redraw()  -- the status lines are below the fields
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  assert_true(screen_has("buffers: 0 ok, 1 missing"), "the missing file is counted")
  load_buffer(3, "/tmp/other.wav")
  assert_equal(local_value("buffers")[3].missing_path, nil)
  assert_true(screen_has("buffers: 0 restored"), "a load in its slot forgets it")
end)

-- #404 (8): a failed load's undo shows on the grid's buffer page as on the
-- screen
test("a failed load redraws the grid", function()
  local context = load_strata(); finish_startup(context)
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 8)
  load_buffer(1, "/tmp/bad.wav")
  local grid_redraws = 0
  local original_grid = grid_redraw
  grid_redraw = function(...) grid_redraws = grid_redraws + 1; return original_grid(...) end
  local ok, problem = pcall(function() context.polls.fire("bufferLoadFailed", load_failed_value(1, 2)) end)
  grid_redraw = original_grid
  assert_true(ok, tostring(problem))
  assert_equal(local_value("buffers")[1].name, "a.wav")
  assert_true(grid_redraws >= 1, "the grid is redrawn")
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
  -- every backup name is taken (by a folder): the file cannot be moved aside
  os.execute("mkdir -p '" .. data_dir .. "buffers.data.bak'")
  for number = 2, 9 do os.execute("mkdir -p '" .. data_dir .. "buffers.data.bak." .. number .. "'") end
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
  context.polls.fire("bufferState", 2012.5)
  next_frame(context)
  local found = false
  for _, entry in ipairs(context.screen.texts) do if entry.text == "12.5s" then found = true end end
  assert_true(found, "poll redraws the BUFFER page with the new seconds on the next frame")
  assert_true(device.refresh_count > refreshes, "grid page 4 redrawn")
end)

test("bufferState poll ignores NaN, infinities and out-of-range slots", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local buffers = local_value("buffers")
  context.polls.fire("bufferState", 3004)   -- slot 4 holds 4 s
  local before = deep_copy(buffers)
  for _, value in ipairs({ 0 / 0, math.huge, -math.huge, -1, 8000 }) do
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

test("a restored 300 s file on a 60 s tier shows 60 s", function()
  local high_60 = { tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60, reason = "high: setting" }
  h.write_performance_active(high_60)
  local context = load_strata({ data_subdir = "buf_long_restore" }); finish_startup(context)
  local long_file = context.audio_dir .. "five-minutes.wav"
  io.open(long_file, "w"):close()
  load_buffer(2, long_file)
  cleanup()
  h.write_performance_active(high_60)
  context = load_strata({ data_subdir = "buf_long_restore" }); finish_startup(context)
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "the remembered file is restored")
  assert_equal(loads[1].args[2], long_file)
  -- the engine reads at most its 60 s slot of the 300 s file
  context.polls.fire("bufferState", 1060)
  local buffer = local_value("buffers")[2]
  assert_true(buffer.loaded and buffer.name == "five-minutes.wav", "the restore is confirmed")
  assert_equal(buffer.seconds, 60, "it holds the slot's 60 s")
  assert_equal(local_value("buffers_restored"), 1)
  local_value("buffer_page").slot = 2
  show_page("BUFFER")
  assert_true(h.screen_shows(context, "1:00"), "BUFFER shows 1:00")
  assert_screen_layout(context, "BUFFER with a restored 60 s slot")
  context.clear_engine_calls()
  save_buffer(2)
  assert_equal(#context.calls_named("saveBuffer"), 1, "the 60 s slot saves")
end)


-- A file the engine checks in its routine (high tier, longer than 16 s at
-- 48 kHz) is checking until the engine reports a length other than the one
-- shown before the load: the old length's reports never settle it (#171)
test("a long file's load waits for the engine's check before it settles", function()
  h.write_performance_active({ tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  context.audio.files["/tmp/long.wav"] = {2, 48000 * 120, 48000}    -- 120 s
  context.audio.files["/tmp/short.wav"] = {2, 48000 * 10, 48000}    -- 10 s: checked at once
  context.audio.files["/tmp/hires.wav"] = {2, 96000 * 12, 96000}    -- 12 s at 96 kHz: 24 s of frames
  -- over a slot holding 8 s
  load_buffer(1, "/tmp/old.wav"); context.polls.fire("bufferState", 8)
  assert_true(buffers[1].loaded); assert_equal(buffers[1].checking_from, nil, "a file with no info is not checked")
  load_buffer(1, "/tmp/long.wav")
  assert_equal(buffers[1].checking_from, 8, "checking, from the 8 s shown before")
  context.set_time(5); context.polls.fire("bufferState", 8); context.polls.fire("bufferState", 8)
  assert_equal(buffers[1].checking_from, 8, "the old length's reports do not end the check")
  assert_true(buffers[1].confirm_since ~= nil, "nor settle the load")
  context.polls.fire("bufferState", 0)            -- the load takes effect: the slot is zeroed
  assert_equal(buffers[1].checking_from, nil, "the check is over")
  assert_true(buffers[1].confirm_since ~= nil, "the load waits for its read")
  context.polls.fire("bufferState", 120)
  assert_true(buffers[1].loaded); assert_equal(buffers[1].confirm_since, nil, "settled on the new length")
  assert_equal(buffers[1].name, "long.wav")
  -- over an empty slot: the periodic 0 s never settles it empty
  load_buffer(2, "/tmp/long.wav")
  assert_equal(buffers[2].checking_from, 0)
  context.set_time(10); context.polls.fire("bufferState", 1000)
  assert_equal(buffers[2].settled_empty, false, "not settled empty while the engine checks")
  context.polls.fire("bufferState", 1120)
  assert_equal(buffers[2].checking_from, nil); assert_true(buffers[2].loaded)
  -- a short file is applied at once, as before; a high-rate file by its frames
  load_buffer(3, "/tmp/short.wav"); assert_equal(buffers[3].checking_from, nil, "10 s is checked at once")
  load_buffer(4, "/tmp/hires.wav"); assert_equal(buffers[4].checking_from, 0, "24 s of frames at 96 kHz is checked")
  -- a clear, a recording, another load or a failed load ends it
  load_buffer(5, "/tmp/long.wav"); clear_buffer(5)
  assert_equal(buffers[5].checking_from, nil, "a clear ends it")
  load_buffer(6, "/tmp/long.wav"); record_buffer(6)
  assert_equal(buffers[6].checking_from, nil, "a recording ends it")
  load_buffer(7, "/tmp/long.wav"); load_buffer(7, "/tmp/short.wav")
  assert_equal(buffers[7].checking_from, nil, "a later short load ends it")
  load_buffer(8, "/tmp/long.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(8, 1))
  assert_equal(buffers[8].checking_from, nil, "a failed check ends it")
  assert_equal(buffers[8].name, "empty")
  -- a short load that fails while a long one checks puts the check back
  load_buffer(7, "/tmp/long.wav"); load_buffer(7, "/tmp/bad.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(7, 4))
  assert_equal(buffers[7].name, "long.wav"); assert_equal(buffers[7].checking_from, 0, "the long load still checks")
end)

-- A check that outlasts check_notice_seconds stays the slot's load: only the
-- engine knows how it ends. The player is told once (a console line, a
-- flash on BUFFER); a late report of the load taking effect settles it, a
-- late failure report undoes it (#317)
test("a long file's check that outlasts 30 s is still adopted when the engine applies it", function()
  h.write_performance_active({ tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
  local context = load_strata({ data_subdir = "late_check_" .. math.random(1, 1e9) }); finish_startup(context)
  local S, buffers = local_value("S"), local_value("buffers")
  context.audio.files["/tmp/long.wav"] = {2, 48000 * 400, 48000}   -- 400 s: the slot reads 300 of it
  show_page("BUFFER")
  -- the console lines that say the engine still checks the slot's load
  local function told_about(slot)
    local count = 0
    for _, line in ipairs(context.printed) do
      if line:find("buffer " .. slot .. ": the engine is still checking", 1, true) then count = count + 1 end
    end
    return count
  end
  -- over an empty slot: 30.1 s with no report, then the engine applies it
  load_buffer(2, "/tmp/long.wav")
  context.clock.run_for(29.9)
  assert_equal(told_about(2), 0, "nothing is said before the bound")
  context.clock.run_for(0.2)
  assert_equal(buffers[2].name, "long.wav", "the load is still the slot's")
  assert_equal(buffers[2].path, "/tmp/long.wav")
  assert_equal(buffers[2].checking_from, 0, "and still checked"); assert_equal(S.lib.buffers.status(2), "loading")
  assert_equal(S.lib.ui_flash.text("hints"), "buf 2 still checking", "BUFFER says so")
  assert_equal(told_about(2), 1, "one console line")
  context.clock.run_for(60)
  assert_equal(told_about(2), 1, "once")
  context.polls.fire("bufferState", 1000); context.polls.fire("bufferState", 1300); context.polls.fire("bufferState", 1300)
  assert_equal(S.lib.buffers.status(2), "loaded"); assert_equal(buffers[2].name, "long.wav")
  assert_equal(buffers[2].path, "/tmp/long.wav"); assert_equal(buffers[2].seconds, 300)
  assert_true(not S.lib.buffers.is_free(2), "the fill cannot load over it")
  -- over a slot holding another file whose length the new one equals
  load_buffer(1, "/tmp/old.wav"); context.polls.fire("bufferState", 300)
  load_buffer(1, "/tmp/long.wav")
  context.clock.run_for(45); context.polls.fire("bufferState", 300)
  assert_equal(buffers[1].name, "long.wav"); assert_equal(buffers[1].checking_from, 300, "the old length settles nothing")
  context.polls.fire("bufferState", 0); context.polls.fire("bufferState", 300)
  assert_equal(S.lib.buffers.status(1), "loaded"); assert_equal(buffers[1].path, "/tmp/long.wav")
  -- a failure reported after the notice undoes the load
  load_buffer(3, "/tmp/old.wav"); context.polls.fire("bufferState", 2008)
  load_buffer(3, "/tmp/long.wav")
  context.clock.run_for(31)
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 2))
  assert_equal(buffers[3].name, "old.wav", "the slot is the file it still holds"); assert_true(buffers[3].loaded)
  assert_equal(buffers[3].checking_from, nil)
  -- a check that ends in time cancels its notice
  local pending = context.clock.pending_count()
  load_buffer(4, "/tmp/long.wav")
  assert_equal(context.clock.pending_count(), pending + 1, "the notice waits")
  context.polls.fire("bufferState", 3300)
  assert_equal(context.clock.pending_count(), pending, "the end of the check cancels it")
  -- a short load that fails while a long one checks starts the long one's notice again
  load_buffer(5, "/tmp/long.wav")
  context.clock.run_for(20)
  load_buffer(5, "/tmp/bad.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(5, 2))
  assert_equal(buffers[5].checking_from, 0, "the long load checks again")
  context.clock.run_for(29.9)
  assert_equal(told_about(5), 0, "a whole bound from the failure")
  context.clock.run_for(0.2)
  assert_equal(told_about(5), 1, "its notice started again")
  assert_equal(buffers[5].name, "long.wav", "and changes nothing"); assert_equal(buffers[5].checking_from, 0)
  assert_equal(S.lib.buffers.BUFFER_SETTLE.check_notice_seconds, 30, "the bound is a named setting")
end)

-- A restored long file whose check outlasts the bound is still the restore's
-- file, and counts as restored when its length arrives (#317)
test("a restored long file whose check outlasts the bound counts as restored", function()
  local subdir = "late_restore_" .. math.random(1, 1e9)
  h.write_performance_active({ tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local kept = context.audio_dir .. "long_kept.wav"
  util.make_dir(context.audio_dir)
  io.open(kept, "w"):close()
  context.audio.register(kept, { channels = 2, frames = 48000 * 400, rate = 48000 })
  load_buffer(6, kept); context.polls.fire("bufferState", 5000); context.polls.fire("bufferState", 5300)
  assert_equal(local_value("S").lib.buffers.status(6), "loaded")
  cleanup()
  h.write_performance_active({ tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
  context = load_strata({ data_subdir = subdir, before_init = function(c)
    c.audio.register(kept, { channels = 2, frames = 48000 * 400, rate = 48000 })
  end })
  finish_startup(context)
  local S, buffers = local_value("S"), local_value("buffers")
  assert_equal(buffers[6].checking_from, 0, "the restored long file is checked")
  context.clock.run_for(40)
  assert_equal(buffers[6].name, "long_kept.wav", "still the restore's file after the bound")
  assert_equal(buffers[6].path, kept)
  context.polls.fire("bufferState", 5300)
  assert_equal(S.lib.buffers.status(6), "loaded")
  assert_equal(S.buffers_restored, 1, "and counted as restored")
end)

-- Without the bufferState poll no report can end a check, so none starts
-- (#317: no fallback gives a check up any more)
test("a long file's load is not a check when the engine has no bufferState poll", function()
  h.write_performance_active({ tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
  local context = load_strata(); finish_startup(context)
  local S, buffers = local_value("S"), local_value("buffers")
  context.audio.files["/tmp/long.wav"] = {2, 48000 * 120, 48000}
  local poll_entry = S.buffer_polls.state
  S.buffer_polls.state = nil
  load_buffer(1, "/tmp/long.wav")
  assert_equal(buffers[1].checking_from, nil, "no check without the poll")
  assert_equal(buffers[1].name, "long.wav")
  S.buffer_polls.state = poll_entry
  load_buffer(2, "/tmp/long.wav")
  assert_equal(buffers[2].checking_from, 0, "with the poll it checks")
end)

-- The engine reads a file from its start (loadSlot: the frames left after
-- start x rate, at most a slot's): a start that leaves no more than a
-- standard slot is applied at once, so Lua does not wait for a check
-- (#317's note: the two sides agree on which loads are checked)
test("a long file's load from a start near its end is not a check", function()
  h.write_performance_active({ tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  context.audio.files["/tmp/long60.wav"] = {2, 48000 * 60, 48000}
  load_buffer(1, "/tmp/long60.wav", 50)
  assert_equal(buffers[1].checking_from, nil, "10 s left after the start: read at once")
  load_buffer(2, "/tmp/long60.wav", 40)
  assert_equal(buffers[2].checking_from, 0, "20 s left: checked")
  load_buffer(3, "/tmp/long60.wav", 100)
  assert_equal(buffers[3].checking_from, 0, "a start past the end loads the last slot's length: checked")
end)

-- #399: two long loads; the first takes effect while the second is the one
-- shown, then the second fails. The slot comes back as the first file,
-- loaded, never as a check no report will end
test("a failed second long load leaves the first one, which took effect, loaded", function()
  h.write_performance_active({ tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
  local context = load_strata(); finish_startup(context)
  local S, buffers = local_value("S"), local_value("buffers")
  for _, name in ipairs({ "x", "a", "b" }) do
    context.audio.files["/tmp/" .. name .. ".wav"] = {2, 48000 * 400, 48000}
  end
  load_buffer(1, "/tmp/x.wav"); context.polls.fire("bufferState", 0); context.polls.fire("bufferState", 300)
  assert_equal(S.lib.buffers.status(1), "loaded")
  load_buffer(1, "/tmp/a.wav"); load_buffer(1, "/tmp/b.wav")       -- both checked; b is damaged
  context.polls.fire("bufferState", 0); context.polls.fire("bufferState", 300)   -- a took effect
  context.polls.fire("bufferLoadFailed", load_failed_value(1, 3))               -- b's check failed
  context.polls.fire("bufferState", 300)
  assert_equal(buffers[1].name, "a.wav"); assert_equal(buffers[1].path, "/tmp/a.wav")
  assert_equal(buffers[1].checking_from, nil, "no check is left")
  assert_equal(S.lib.buffers.status(1), "loaded")
  context.clock.run_for(40)
  assert_equal(buffers[1].name, "a.wav", "and nothing puts x.wav back")
  assert_equal(params:get("buf1_file"), "/tmp/a.wav")
end)

-- #311 with a long file: the engine cancels the take at the load's command
-- and the slot keeps its audio while the file is checked
test("a long file that fails its check while a synced take waits puts the slot back", function()
  h.write_performance_active({ tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  local S = local_value("S")
  context.audio.files["/tmp/long.wav"] = {2, 48000 * 120, 48000}    -- 120 s: checked
  load_buffer(1, "/tmp/old.wav"); context.polls.fire("bufferState", 8)
  params:set("record_sync", 3)
  record_buffer(1); context.polls.fire("recordState", 32)
  load_buffer(1, "/tmp/long.wav")                                    -- load 2
  assert_equal(buffers[1].checking_from, 8, "the check waits from the engine's 8 s, not a 0 Lua wrote")
  context.polls.fire("recordState", 56); context.polls.fire("bufferState", 8)   -- the command's cancel
  assert_equal(S.lib.buffers.status(1), "loading", "the kept length does not end the check")
  context.polls.fire("bufferLoadFailed", load_failed_value(1, 2))
  assert_equal(buffers[1].name, "old.wav"); assert_equal(buffers[1].path, "/tmp/old.wav"); assert_true(buffers[1].loaded)
  assert_equal(S.lib.buffers.status(1), "loaded")
  -- a synced replace take armed while the file is checked, canceled before
  -- its preparation: the load never arrives, the slot holds what it held
  load_buffer(2, "/tmp/old.wav"); context.polls.fire("bufferState", 1008)
  local pending = context.clock.pending_count()
  load_buffer(2, "/tmp/long.wav")
  assert_equal(buffers[2].checking_from, 8)
  record_buffer(2); context.polls.fire("recordState", 33)
  record_buffer(2)                                                   -- K3 before the bar
  context.polls.fire("recordState", 57); context.polls.fire("bufferState", 1008)
  assert_equal(buffers[2].name, "old.wav"); assert_equal(buffers[2].path, "/tmp/old.wav"); assert_true(buffers[2].loaded)
  assert_equal(buffers[2].checking_from, nil, "no check pending"); assert_equal(buffers[2].confirm_since, nil)
  assert_equal(context.clock.pending_count(), pending, "no check fallback left")
  assert_equal(S.lib.buffers.status(2), "loaded")
  -- two long loads in their checks: the take supersedes both, so the slot
  -- holds what the first one replaced
  context.audio.files["/tmp/long2.wav"] = {2, 48000 * 90, 48000}
  load_buffer(3, "/tmp/old.wav"); context.polls.fire("bufferState", 2008)
  load_buffer(3, "/tmp/long.wav"); load_buffer(3, "/tmp/long2.wav")
  record_buffer(3); context.polls.fire("recordState", 34)
  record_buffer(3)
  context.polls.fire("recordState", 58); context.polls.fire("bufferState", 2008)
  assert_equal(buffers[3].name, "old.wav", "not a load the take superseded"); assert_true(buffers[3].loaded)
  assert_equal(buffers[3].checking_from, nil); assert_equal(S.lib.buffers.status(3), "loaded")
end)

test("a standard tier never checks a load, whatever the file", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  context.audio.files["/tmp/long.wav"] = {2, 48000 * 120, 48000}
  load_buffer(1, "/tmp/long.wav")
  assert_equal(buffers[1].checking_from, nil, "standard slots end at 16 s: the engine checks at once")
end)

-- 3.3's files: the start point of a long file, trim and buffers.data v2

-- Register a 60 s stereo file at 48 kHz and load it into slot 1 (or slot)
local function load_long_file(context, slot, path)
  path = path or "/tmp/long60.wav"
  context.audio.register(path, { channels = 2, frames = 48000 * 60, rate = 48000 })
  load_buffer(slot or 1, path)
  context.clear_engine_calls()
  return path
end

-- Make lib/record.lua report a recording of this kind in slot, until restore()
local function fake_record_state(slot, kind)
  local records = local_value("S").lib.record
  local original = records.state
  records.state = function(asked)
    if asked == slot then return { kind = kind, phase = "recording" } end
    return original(asked)
  end
  return function() records.state = original end
end

test("loading a file keeps its sample rate and length, a start point of 0", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_long_file(context, 1)
  assert_equal(buffers[1].start, 0); assert_equal(buffers[1].sample_rate, 48000)
  assert_near(buffers[1].file_seconds, 60, 1e-9)
  load_buffer(2, "/tmp/unreadable.wav")
  assert_equal(buffers[2].file_seconds, nil, "a file audio.file_info cannot open has no length")
  assert_equal(buffers[2].sample_rate, nil)
end)

test("a long file's start reloads 0.3 s after the last set_start", function()
  local context = load_strata(); finish_startup(context)
  local buffers_lib = local_value("S").lib.buffers
  local path = load_long_file(context, 1)
  buffers_lib.set_start(1, 12.0)
  context.clock.run_for(0.1); buffers_lib.set_start(1, 12.0)
  context.clock.run_for(0.1); buffers_lib.set_start(1, 12.0)
  context.clock.run_for(0.25)
  assert_equal(#context.calls_named("loadBuffer"), 0, "not yet: 0.25 s after the last call")
  context.clock.run_for(0.1)
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "one reload for the three calls")
  assert_equal(loads[1].args[1], 0); assert_equal(loads[1].args[2], path); assert_near(loads[1].args[3], 12.0, 1e-9)
  assert_near(local_value("buffers")[1].start, 12.0, 1e-9)
  context.clock.run_for(2)
  assert_equal(#context.calls_named("loadBuffer"), 1, "and no more")
end)

test("the start clamps to the file's length less the slot's", function()
  local context = load_strata(); finish_startup(context)
  local buffers_lib, buffers = local_value("S").lib.buffers, local_value("buffers")
  load_long_file(context, 1)
  buffers_lib.set_start(1, 50); assert_near(buffers[1].start, 44.0, 1e-9)
  buffers_lib.set_start(1, -3); assert_equal(buffers[1].start, 0)
  -- a file that fits the slot has no start to move
  context.audio.register("/tmp/short.wav", { channels = 2, frames = 48000 * 5, rate = 48000 })
  load_buffer(2, "/tmp/short.wav"); buffers_lib.set_start(2, 3); assert_equal(buffers[2].start, 0)
  buffers_lib.set_start(0, 3); buffers_lib.set_start(9, 3)   -- invalid slots do nothing
  -- a slot without a file
  buffers_lib.set_start(3, 3); assert_equal(buffers[3].start, 0)
end)

-- #326: the engine's slot holds buffer_seconds of frames at the server
-- rate (loadSlot's slotFrames), so a file above 48 kHz keeps fewer of its
-- own seconds, and its start reaches further
test("a file above the server rate can be started in its last part", function()
  local context = load_strata(); finish_startup(context)
  local buffers_lib, buffers = local_value("S").lib.buffers, local_value("buffers")
  -- 60 s at 96 kHz: a 16 s slot holds 8 s of it, so the last start is 52 s
  context.audio.register("/tmp/hi60.wav", { channels = 2, frames = 96000 * 60, rate = 96000 })
  load_buffer(1, "/tmp/hi60.wav")
  context.clear_engine_calls()
  buffers_lib.set_start(1, 60); assert_near(buffers[1].start, 52.0, 1e-9, "the file's last 8 s are in reach")
  context.clock.run_for(0.5)
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1); assert_near(loads[1].args[3], 52.0, 1e-9, "and the reload is sent there")
  -- 12 s at 96 kHz: the slot holds 8 s of it, so it has a start, up to 4 s
  context.audio.register("/tmp/hi12.wav", { channels = 2, frames = 96000 * 12, rate = 96000 })
  load_buffer(2, "/tmp/hi12.wav")
  buffers_lib.set_start(2, 9); assert_near(buffers[2].start, 4.0, 1e-9, "a file between the two lengths has a start")
  -- at or below the server rate a slot holds buffer_seconds of the file
  context.audio.register("/tmp/cd60.wav", { channels = 2, frames = 44100 * 60, rate = 44100 })
  load_buffer(3, "/tmp/cd60.wav")
  buffers_lib.set_start(3, 60); assert_near(buffers[3].start, 44.0, 1e-9, "44.1 kHz keeps today's limit")
  context.audio.register("/tmp/cd12.wav", { channels = 2, frames = 44100 * 12, rate = 44100 })
  load_buffer(4, "/tmp/cd12.wav")
  buffers_lib.set_start(4, 3); assert_equal(buffers[4].start, 0, "a 44.1 kHz file that fits has no start")
end)

test("a restored start of a high-rate file is clamped with the seconds the slot holds", function()
  local subdir = "hi_rate_restore_" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local path = context.audio_dir .. "hi60.wav"
  util.make_dir(context.audio_dir)
  io.open(path, "w"):close()
  context.audio.register(path, { channels = 2, frames = 96000 * 60, rate = 96000 })
  load_buffer(1, path)
  local_value("S").lib.buffers.set_start(1, 51)
  context.clock.run_for(0.5)
  cleanup()
  context = load_strata({ data_subdir = subdir, before_init = function(c)
    c.audio.register(path, { channels = 2, frames = 96000 * 60, rate = 96000 })
  end })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1)
  assert_near(loads[1].args[3], 51.0, 1e-9, "a start past 44 s survives the restart")
end)

-- #516: one server rate (NORNS_SAMPLE_RATE) for the long-file check, as for
-- the seconds a slot holds of a file: a second copy could drift from it
test("the long-file check reads the one server rate, NORNS_SAMPLE_RATE", function()
  h.write_performance_active({ tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
  local context = load_strata(); finish_startup(context)
  local S, buffers = local_value("S"), local_value("buffers")
  context.audio.files["/tmp/twenty.wav"] = {2, 48000 * 20, 48000}   -- 20 s at 48 kHz
  load_buffer(1, "/tmp/twenty.wav")
  assert_equal(buffers[1].checking_from, 0, "more than 16 s at 48 kHz: checked")
  local rate = S.constants.NORNS_SAMPLE_RATE
  S.constants.NORNS_SAMPLE_RATE = 96000   -- as if the server ran at 96 kHz
  local checked = nil
  local ok, problem = pcall(function()
    load_buffer(2, "/tmp/twenty.wav")
    checked = buffers[2].checking_from
  end)
  S.constants.NORNS_SAMPLE_RATE = rate
  assert_true(ok, tostring(problem))
  assert_equal(checked, nil, "960000 frames are under 16 s at 96 kHz: read at once")
end)

test("a replace take, a clear or another file sets the start back to 0", function()
  local context = load_strata(); finish_startup(context)
  local buffers_lib, buffers = local_value("S").lib.buffers, local_value("buffers")
  load_long_file(context, 1)
  buffers_lib.set_start(1, 12.0)
  buffers_lib.recording_started(1, false)
  assert_equal(buffers[1].start, 0); assert_equal(buffers[1].sample_rate, nil); assert_equal(buffers[1].file_seconds, nil)
  load_long_file(context, 1); buffers_lib.set_start(1, 12.0)
  clear_buffer(1); assert_equal(buffers[1].start, 0); assert_equal(buffers[1].file_seconds, nil)
  load_long_file(context, 1); buffers_lib.set_start(1, 12.0)
  context.audio.register("/other.wav", { channels = 2, frames = 48000 * 20, rate = 48000 })
  context.clear_engine_calls()
  load_buffer(1, "/other.wav")
  local load = context.calls_named("loadBuffer")[1]
  assert_equal(load.args[2], "/other.wav"); assert_equal(load.args[3], 0, "another file starts at 0")
  assert_equal(buffers[1].start, 0)
  -- a playable recording leaves the file's start, rate and length alone
  load_long_file(context, 2); buffers_lib.set_start(2, 12.0)
  params:set("record_feedback", 50)
  context.clock.run_for(0.4)                     -- the reload settles: 12 is what plays
  record_buffer(2)
  assert_near(buffers[2].start, 12.0, 1e-9); assert_equal(buffers[2].sample_rate, 48000)
  assert_near(buffers[2].file_seconds, 60, 1e-9)
end)

test("a replace take forgets the file's start, rate and length at once", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_long_file(context, 1)                      -- 2880000 frames at 48000
  local_value("S").lib.buffers.set_start(1, 12.0)
  params:set("record_feedback", 0)
  record_buffer(1)
  assert_equal(buffers[1].start, 0); assert_equal(buffers[1].file_seconds, nil)
  assert_equal(buffers[1].sample_rate, nil)
end)

test("a recording, a clear or a load inside the 0.3 s cancels the pending start reload", function()
  local context = load_strata(); finish_startup(context)
  local buffers_lib = local_value("S").lib.buffers
  local function pending_then(action)
    load_long_file(context, 1)
    buffers_lib.set_start(1, 12.0)
    context.clock.run_for(0.1)
    action()
    context.clock.run_for(1)
  end
  pending_then(function() buffers_lib.recording_started(1, false) end)
  assert_equal(#context.calls_named("loadBuffer"), 0, "a replace take cancels it")
  pending_then(function() buffers_lib.recording_started(1, true) end)
  assert_equal(#context.calls_named("loadBuffer"), 0, "a playable recording cancels it")
  pending_then(function() clear_buffer(1) end)
  assert_equal(#context.calls_named("loadBuffer"), 0, "a clear cancels it")
  context.clear_engine_calls()
  pending_then(function() load_buffer(1, "/other.wav") end)
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "a load replaces it")
  assert_equal(loads[1].args[2], "/other.wav"); assert_equal(loads[1].args[3], 0)
end)

test("set_start does nothing while the slot records", function()
  local context = load_strata(); finish_startup(context)
  local buffers_lib, buffers = local_value("S").lib.buffers, local_value("buffers")
  load_long_file(context, 1)
  local restore = fake_record_state(1, "playable")
  buffers_lib.set_start(1, 12.0)
  context.clock.run_for(1)
  restore()
  assert_equal(buffers[1].start, 0); assert_equal(#context.calls_named("loadBuffer"), 0)
end)

test("cleanup cancels a pending start reload", function()
  local context = load_strata(); finish_startup(context)
  load_long_file(context, 1)
  local_value("S").lib.buffers.set_start(1, 12.0)
  cleanup()
  assert_equal(context.clock.pending_count(), 0)
  context.clock.run_for(1)
  assert_equal(#context.calls_named("loadBuffer"), 0)
end)

test("a failed load during a playable recording restores the slot", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_buffer(3, "/tmp/drone.wav"); context.polls.fire("bufferState", 2008)
  assert_true(buffers[3].loaded)
  local restore = fake_record_state(3, "playable")
  buffers[3].recording = true
  load_buffer(3, "/tmp/bad.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 2))
  restore()
  assert_equal(buffers[3].name, "drone.wav"); assert_true(buffers[3].loaded)
  assert_equal(buffers[3].path, "/tmp/drone.wav")
  -- a replace take still leaves it empty
  context = load_strata(); finish_startup(context)
  buffers = local_value("buffers")
  load_buffer(3, "/tmp/drone.wav"); context.polls.fire("bufferState", 2008)
  record_buffer(3)
  load_buffer(3, "/tmp/bad.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 2))
  assert_equal(buffers[3].name, "empty", "as in 3.2")
  assert_true(not buffers[3].loaded)
end)

test("a restored start is clamped to the file's current length", function()
  local subdir = "data-clamp-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  util.make_dir(context.audio_dir)
  local path = context.audio_dir .. "shrunk.wav"
  io.open(path, "w"):close()
  context.audio.register(path, { channels = 2, frames = 48000 * 60, rate = 48000 })
  load_buffer(1, path)
  local_value("S").lib.buffers.set_start(1, 50)
  cleanup()
  -- the file was replaced by a 30 s one: 16 s slots leave starts up to 14 s
  context = load_strata({ data_subdir = subdir, before_init = function(c)
    c.audio.register(path, { channels = 2, frames = 48000 * 30, rate = 48000 })
  end })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1); assert_near(loads[1].args[3], 14, 1e-9)
  assert_near(local_value("buffers")[1].start, 14, 1e-9)
end)

test("a failed load puts the slot's start back too", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  load_long_file(context, 1)
  local_value("S").lib.buffers.set_start(1, 12.0)
  context.clock.run_for(0.4)
  load_buffer(1, "/tmp/bad.wav")
  assert_equal(buffers[1].start, 0)
  context.polls.fire("bufferLoadFailed", load_failed_value(1, 3))
  assert_near(buffers[1].start, 12.0, 1e-9, "the start that file had")
  assert_near(buffers[1].file_seconds, 60, 1e-9)
end)

test("a start reload that fails puts the start back", function()
  local context = load_strata(); finish_startup(context)
  local buffers, buffers_lib = local_value("buffers"), local_value("S").lib.buffers
  local path = load_long_file(context, 1)
  context.polls.fire("bufferState", 16)
  buffers_lib.set_start(1, 12.0)
  context.clock.run_for(0.4)
  assert_equal(#context.calls_named("loadBuffer"), 1, "the reload was sent (load 2)")
  context.polls.fire("bufferLoadFailed", load_failed_value(1, 2))
  assert_equal(buffers[1].start, 0, "the start the file was loaded at")
  assert_equal(buffers[1].path, path)
  assert_equal(buffers[1].name, "long60.wav")
  assert_near(buffers[1].file_seconds, 60, 1e-9)
  -- a second move settles (load 3); a third fails (load 4) and goes back to the second
  buffers_lib.set_start(1, 12.0)
  context.clock.run_for(0.4)
  context.polls.fire("bufferState", 16)
  buffers_lib.set_start(1, 20.0)
  context.clock.run_for(0.4)
  context.polls.fire("bufferLoadFailed", load_failed_value(1, 4))
  assert_near(buffers[1].start, 12.0, 1e-9)
end)

test("a failed load over a remembered missing file puts its start back", function()
  local subdir = "missing-start-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local gone = context.audio_dir .. "gone.wav"
  cleanup()   -- makes the data folder
  local file = assert(io.open(context.data_dir .. "strata/buffers.data", "w"))
  file:write(tabutil_text({ version = 2, paths = { gone }, starts = { 12 } })); file:close()
  context = load_strata({ data_subdir = subdir })
  local buffers = local_value("buffers")
  assert_equal(buffers[1].missing_path, gone); assert_near(buffers[1].start, 12.0, 1e-9)
  load_buffer(1, "/tmp/bad.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(1, 1))
  assert_equal(buffers[1].missing_path, gone, "the missing file is shown again")
  assert_near(buffers[1].start, 12.0, 1e-9)
  cleanup()
  assert_near(context.tab.load(context.data_dir .. "strata/buffers.data").starts[1], 12.0, 1e-9)
end)

test("a dub that starts inside the start reload's wait leaves the start at what plays", function()
  local context = load_strata(); finish_startup(context)
  local buffers, buffers_lib = local_value("buffers"), local_value("S").lib.buffers
  load_long_file(context, 1)
  context.polls.fire("bufferState", 16)
  buffers_lib.set_start(1, 12.0)
  context.clock.run_for(0.1)
  params:set("record_feedback", 50)
  record_buffer(1)
  assert_equal(buffers[1].start, 0, "the file still plays from 0")
  context.clock.run_for(1)
  assert_equal(#context.calls_named("loadBuffer"), 0, "no reload")
  context.polls.fire("recordState", 56)   -- the dub is canceled
  assert_equal(buffers[1].start, 0)
end)

test("start reloads that fail out of order end at the start before them", function()
  local context = load_strata(); finish_startup(context)
  local buffers, buffers_lib = local_value("buffers"), local_value("S").lib.buffers
  local function two_pending()
    load_long_file(context, 1)
    context.polls.fire("bufferState", 16)
    buffers_lib.set_start(1, 12.0); context.clock.run_for(0.4)   -- load n
    buffers_lib.set_start(1, 20.0); context.clock.run_for(0.4)   -- load n + 1
  end
  two_pending()   -- loads 2 and 3 over load 1
  context.polls.fire("bufferLoadFailed", load_failed_value(1, 3))
  assert_near(buffers[1].start, 12.0, 1e-9)
  context.polls.fire("bufferLoadFailed", load_failed_value(1, 2))
  assert_equal(buffers[1].start, 0)
  two_pending()   -- loads 5 and 6 over load 4
  context.polls.fire("bufferLoadFailed", load_failed_value(1, 5))
  context.polls.fire("bufferLoadFailed", load_failed_value(1, 6))
  assert_equal(buffers[1].start, 0)
end)

-- Put voice voice_idx on buffer slot with a loop
local function loop_voice(voice_idx, slot, start, length)
  local S = local_value("S")
  S.voices[voice_idx].source = S.constants.SOURCE_SYNTH + slot
  S.voices[voice_idx].extras.loop_start = start
  S.voices[voice_idx].extras.loop_length = length
end

test("the save param sends nothing while the slot records", function()
  local context = load_strata(); finish_startup(context)
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 8)
  context.clock.run_for(2)
  params:set("record_feedback", 50)
  record_buffer(1)
  assert_true(local_value("buffers")[1].recording, "slot 1 records")
  context.clear_engine_calls()
  params:set("buf1_save", 1)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing is sent while the slot records")
  assert_equal(local_value("buffers")[1].saves_sent, 0, "and no save is counted")
end)

test("save_buffer and save_buffer_loop say why they sent nothing", function()
  local context = load_strata(); finish_startup(context)
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 8)
  context.clock.run_for(2)
  for _, save in ipairs({save_buffer, save_buffer_loop}) do
    context.clear_engine_calls()
    local sent, reason = save(0)
    assert_equal(sent, false); assert_equal(reason, "invalid", "not a slot")
    sent, reason = save(2)
    assert_equal(sent, false); assert_equal(reason, "empty", "an empty slot")
    sent, reason = save(1)
    assert_equal(sent, true); assert_equal(reason, nil, "a loaded slot is sent")
    assert_equal(#context.calls_named("saveBuffer"), 1)
  end
  params:set("record_feedback", 50)
  record_buffer(1)
  for _, save in ipairs({save_buffer, save_buffer_loop}) do
    context.clear_engine_calls()
    local sent, reason = save(1)
    assert_equal(sent, false); assert_equal(reason, "busy", "a recording slot")
    assert_equal(#context.calls_named("saveBuffer"), 0)
  end
end)

test("the busy edges: an armed take and a finishing take refuse, an ended dub saves", function()
  local function loaded_context()
    local context = load_strata(); finish_startup(context)
    load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 8)
    context.clock.run_for(2)
    return context
  end
  local function record_report(slot, state)
    return ((local_value("buffers")[slot].records_sent * 4) + state) * 8 + slot - 1
  end
  local function refuses(context, slot)
    for _, save in ipairs({save_buffer, save_buffer_loop}) do
      context.clear_engine_calls()
      local sent, reason = save(slot)
      assert_equal(sent, false); assert_equal(reason, "busy")
      assert_equal(#context.calls_named("saveBuffer"), 0)
    end
  end
  -- armed: waiting for the source's level, not recording yet
  local context = loaded_context()
  params:set("record_threshold", 6); params:set("record_feedback", 50)
  record_buffer(1)
  assert_true(local_value("buffers")[1].recording, "an armed recording has recording set")
  refuses(context, 1)
  -- a replace take that ended and waits for the engine
  context = loaded_context()
  params:set("record_feedback", 0)
  record_buffer(1)
  context.polls.fire("recordState", record_report(1, 2))
  assert_true(local_value("buffers")[1].finishing, "the ended take is finishing")
  refuses(context, 1)
  -- a dub that just ended is take 1: saved
  context = loaded_context()
  params:set("record_feedback", 50)
  record_buffer(1)
  context.polls.fire("recordState", record_report(1, 2))
  assert_equal(local_value("buffers")[1].name, "take 1")
  assert_true(not local_value("buffers")[1].recording)
  for _, save in ipairs({save_buffer, save_buffer_loop}) do
    context.clear_engine_calls()
    assert_equal(save(1), true)
    assert_equal(#context.calls_named("saveBuffer"), 1)
  end
end)

test("save_buffer_loop saves the selected voice's loop region", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 8)
  loop_voice(2, 1, 0.25, 0.5)
  S.selected_voice = 2
  context.clear_engine_calls()
  assert_true(save_buffer_loop(1))
  local call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[1], 0)
  assert_true(call.args[2]:match("/strata/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-buf1%-loop%.wav$") ~= nil, call.args[2])
  assert_near(call.args[3], 0.25, 1e-9); assert_near(call.args[4], 0.5, 1e-9)
  -- its result flashes the loop wording
  context.polls.fire("bufferSaveResult", (1 * 2) * 8 + 0)
  show_page("BUFFER")
  assert_equal(S.lib.ui_flash.text("hints"), "saved buf 1 loop")
end)

test("save_buffer_loop falls back to the lowest voice on the slot, then the whole slot", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  load_buffer(2, "/tmp/a.wav"); context.polls.fire("bufferState", 1008)
  loop_voice(4, 2, 0.5, 0.25); loop_voice(6, 2, 0.1, 0.9)
  S.selected_voice = 1
  context.clear_engine_calls()
  assert_true(save_buffer_loop(2))
  local call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[1], 1); assert_near(call.args[3], 0.5, 1e-9); assert_near(call.args[4], 0.25, 1e-9)
  S.voices[4].source = S.constants.SOURCE_SYNTH; S.voices[6].source = S.constants.SOURCE_SYNTH
  context.clear_engine_calls()
  assert_true(save_buffer_loop(2))
  call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[3], 0); assert_equal(call.args[4], 1, "no voice reads the slot: all of it")
  -- an empty slot and an invalid one save nothing
  context.clear_engine_calls()
  assert_equal(save_buffer_loop(3), false); assert_equal(save_buffer_loop(9), false)
  assert_equal(#context.calls_named("saveBuffer"), 0)
end)

test("buffers.data saves version 2 with starts and loads version 1 with starts 0", function()
  local subdir = "data-v2-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  util.make_dir(context.audio_dir)
  local path = context.audio_dir .. "long.wav"
  io.open(path, "w"):close()
  context.audio.register(path, { channels = 2, frames = 48000 * 60, rate = 48000 })
  load_buffer(1, path)
  local_value("S").lib.buffers.set_start(1, 12.0)
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.version, 2); assert_equal(saved.paths[1], path)
  assert_near(saved.starts[1], 12.0, 1e-9)
  for slot = 2, 8 do assert_equal(saved.starts[slot], 0, "slot " .. slot .. " start") end
  context = load_strata({ data_subdir = subdir })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1); assert_equal(loads[1].args[2], path); assert_near(loads[1].args[3], 12.0, 1e-9)
  -- a version 1 file loads with every start 0
  local file = assert(io.open(context.data_dir .. "strata/buffers.data", "w"))
  file:write(tabutil_text({ version = 1, paths = { path } })); file:close()
  context = load_strata({ data_subdir = subdir })
  loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1); assert_equal(loads[1].args[3], 0, "no start in version 1")
  -- a version 2 file with a damaged starts list loads with starts 0
  file = assert(io.open(context.data_dir .. "strata/buffers.data", "w"))
  file:write(tabutil_text({ version = 2, paths = { path }, starts = { "x" } })); file:close()
  context = load_strata({ data_subdir = subdir })
  assert_equal(context.calls_named("loadBuffer")[1].args[3], 0)
  -- inf and nan read as numbers (lib/data_files.lua, #464): a start that is not finite loads from 0
  file = assert(io.open(context.data_dir .. "strata/buffers.data", "w"))
  file:write(tabutil_text({ version = 2, paths = { path, path, path }, starts = { math.huge, 0 / 0, -math.huge } }))
  file:close()
  context = load_strata({ data_subdir = subdir, before_load = function(started)
    started.audio.register(path, { channels = 2, frames = 48000 * 60, rate = 48000 })  -- the restore clamps
  end })
  loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 3)
  for slot = 1, 3 do assert_equal(loads[slot].args[3], 0, "slot " .. slot .. " loads from 0") end
end)

test("status names what a slot holds, one answer for every reader", function()
  local context = load_strata(); finish_startup(context)
  local buffers_lib = local_value("S").lib.buffers
  local status, is_free = buffers_lib.status, buffers_lib.is_free
  local function every_slot_has_a_status()
    for slot = 1, 8 do assert_true(status(slot) ~= nil, "slot " .. slot .. " has a status") end
  end
  assert_equal(status(1), "empty", "a fresh slot"); assert_true(is_free(1))
  load_buffer(1, "/tmp/a.wav")
  assert_equal(status(1), "loading", "the engine has not confirmed the load"); assert_true(not is_free(1))
  context.polls.fire("bufferState", 4)
  assert_equal(status(1), "loaded")
  -- a named load whose length the engine has not reported after the settle time
  load_buffer(2, "/tmp/slow.wav")
  context.set_time(util.time() + 1.1); context.polls.fire("bufferState", 1000)
  assert_equal(status(2), "unsettled"); assert_true(not is_free(2), "an unsettled load is not free")
  context.polls.fire("bufferState", 1004)
  assert_equal(status(2), "loaded", "a later report adopts it")
  every_slot_has_a_status()
  -- a replace take, then its timer ends
  params:set("record_feedback", 0)
  record_buffer(3)
  assert_equal(status(3), "recording"); assert_true(not is_free(3))
  wake_buffer_clock(context, 3)
  assert_equal(status(3), "finishing")
  -- playable recordings that wait for the source's level
  params:set("record_feedback", 50); params:set("record_threshold", 6)
  record_buffer(1)
  assert_equal(status(1), "armed")
  context.polls.fire("recordState", 40)   -- slot 1's first recording starts
  assert_equal(status(1), "dub")
  params:set("record_loop", 2)
  record_buffer(4)
  assert_equal(status(4), "armed")
  context.polls.fire("recordState", 43)   -- slot 4's first recording starts
  assert_equal(status(4), "loop")
  -- an armed replace take stopped with K3 finishes, whatever its phase
  params:set("record_feedback", 0); params:set("record_loop", 1)
  record_buffer(5)
  assert_equal(status(5), "armed")
  record_buffer(5)
  assert_equal(status(5), "finishing", "K3 on an armed take: finishing before its canceled report")
  context.polls.fire("recordState", 60)   -- slot 5's first recording is canceled
  assert_equal(status(5), "empty"); assert_true(is_free(5))
  every_slot_has_a_status()
  -- a remembered file missing at start
  local subdir = "status-missing-" .. math.random(1, 1e9)
  context = load_strata({ data_subdir = subdir })
  util.make_dir(context.data_dir .. "strata/")
  local file = assert(io.open(context.data_dir .. "strata/buffers.data", "w"))
  file:write(tabutil_text({ version = 2, paths = { context.audio_dir .. "gone.wav" }, starts = { 0 } })); file:close()
  context = load_strata({ data_subdir = subdir }); finish_startup(context)
  buffers_lib = local_value("S").lib.buffers
  assert_equal(buffers_lib.status(1), "missing"); assert_true(buffers_lib.is_free(1), "a missing file's slot is free")
  assert_equal(buffers_lib.status(0), nil, "slot 0 is out of range"); assert_equal(buffers_lib.status(9), nil)
  assert_true(not buffers_lib.is_free(0) and not buffers_lib.is_free(9), "out of range is never free")
end)

-- buffers.data on disk (#301)

local file_text, write_text, watch_writes = h.file_text, h.write_text, h.watch_writes

-- The names in `opened` that are buffers.data or a file beside it
local function data_writes(opened)
  local found = {}
  for _, name in ipairs(opened) do
    if name:find("buffers.data", 1, true) then table.insert(found, name) end
  end
  return found
end

test("a buffer's file is remembered when it loads, not only at exit; reports that change no path write nothing (#327)",
    function()
  local subdir = "buffers-on-disk-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local S = local_value("S")
  local path = context.data_dir .. "strata/buffers.data"
  assert_true(not util.file_exists(path), "no buffers file yet")
  load_buffer(2, "/tmp/drone.wav")
  local remembered = S.lib.data_files.read(path)
  assert_true(remembered ~= nil, "buffers.data is written at the load")
  assert_equal(remembered.version, 2); assert_equal(remembered.paths[2], "/tmp/drone.wav")
  -- reports that settle the load, a new length, the periodic repeats: no write
  local restore, opened = watch_writes("buffers.data")
  context.polls.fire("bufferState", 1004); context.polls.fire("bufferState", 1004)
  context.polls.fire("bufferState", 1005)
  restore()
  assert_equal(#data_writes(opened), 0, "a new length is not a new path")
  -- a take that ends has its scratch path at once
  record_buffer(5); wake_buffer_clock(context, 5)
  context.polls.fire("bufferState", 4004)
  assert_equal(S.lib.data_files.read(path).paths[5], scratch_take_path(5), "the take is remembered when it settles")
  -- a clear is remembered too, and survives a session with no clean exit
  clear_buffer(2)
  assert_equal(S.lib.data_files.read(path).paths[2], "", "a clear is remembered at once")
  load_buffer(3, "/tmp/pad.wav")
  context = load_strata({ data_subdir = subdir })
  assert_equal(#context.calls_named("loadBuffer"), 0, "neither file exists here, so nothing reloads")
  assert_equal(local_value("S").buffers[3].missing_path, "/tmp/pad.wav", "the load before the crash is remembered")
  -- the restore and an exit with nothing new write nothing
  restore, opened = watch_writes("buffers.data")
  cleanup()
  restore()
  assert_equal(#data_writes(opened), 0, "an unchanged buffers.data is not rewritten at exit")
end)

test("a buffers write that fails keeps the old file and says so; the next change that writes clears it (#301)",
    function()
  local subdir = "buffers-write-fails-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local S = local_value("S")
  local path = context.data_dir .. "strata/buffers.data"
  load_buffer(1, "/tmp/one.wav")
  local good = file_text(path)
  assert_true(good ~= nil, "the first load is on disk")
  -- the card fills: every write to buffers.data (or a file beside it) stops at 40 bytes
  local restore = watch_writes("buffers.data", { at = "write", after = 40 })
  load_buffer(2, "/tmp/two.wav")
  assert_equal(file_text(path), good, "the file is byte for byte the last good one")
  assert_equal(S.buffer_file.problem, "not saved")
  local said = { saved = 0, failed = 0 }
  for _, line in ipairs(context.printed) do
    if line:find("buffer paths saved to", 1, true) then said.saved = said.saved + 1 end
    if line:find("error: buffer paths not saved to " .. path, 1, true) then said.failed = said.failed + 1 end
  end
  assert_equal(said.saved, 1, "a failed write never says saved"); assert_equal(said.failed, 1, "it says why")
  cleanup()
  assert_equal(file_text(path), good, "a failed exit save keeps the file too")
  restore()
  context = load_strata({ data_subdir = subdir }); finish_startup(context)
  S = local_value("S")
  restore = watch_writes("buffers.data", { at = "write", after = 40 })
  load_buffer(4, "/tmp/four.wav")
  restore()
  assert_equal(S.buffer_file.problem, "not saved")
  load_buffer(5, "/tmp/five.wav")
  assert_equal(S.buffer_file.problem, nil, "a write that works clears the problem")
  local saved = S.lib.data_files.read(path)
  assert_equal(saved.paths[4], "/tmp/four.wav", "the change the failed write missed went with the next")
  assert_equal(saved.paths[5], "/tmp/five.wav")
end)

test("a version 1 buffers.data is kept as buffers.data.v1 when it is first replaced (#467)", function()
  local subdir = "buffers-v1-" .. math.random(1, 1e9)
  local dir = data_root .. subdir .. "/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  local original = tabutil_text({ version = 1, paths = { "", "", "", "", "", "", "", "" } })
  write_text(dir .. "buffers.data", original)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  assert_true(not util.file_exists(dir .. "buffers.data.v1"), "nothing is copied until the file is replaced")
  load_buffer(1, "/tmp/drone.wav")
  assert_equal(file_text(dir .. "buffers.data.v1"), original, "the older file's bytes are kept")
  local S = local_value("S")
  assert_equal(S.lib.data_files.read(dir .. "buffers.data").version, 2, "the file is this format now")
  load_buffer(2, "/tmp/pad.wav")
  cleanup()
  load_strata({ data_subdir = subdir }); load_buffer(3, "/tmp/other.wav"); cleanup()
  assert_true(not util.file_exists(dir .. "buffers.data.v1.2"), "no second copy")
  assert_equal(file_text(dir .. "buffers.data.v1"), original)
end)

test("an unreadable buffers.data is named on the hint row at start and kept under its own name (#463, #466)",
    function()
  local subdir = "buffers-start-flash-" .. math.random(1, 1e9)
  local dir = data_root .. subdir .. "/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  write_text(dir .. "buffers.data", "return {")
  write_text(dir .. "buffers.data.bak", "an earlier backup")
  local context = load_strata({ data_subdir = subdir })
  local S = local_value("S")
  assert_equal(S.lib.ui_flash.text("hints"), "buffers unreadable (SETUP)")
  assert_equal(file_text(dir .. "buffers.data.bak"), "an earlier backup", "the earlier backup is untouched")
  assert_equal(file_text(dir .. "buffers.data.bak.2"), "return {", "the file has a backup of its own")
  assert_equal(S.buffer_file.problem, "unreadable")
  assert_equal(S.buffer_file.backup, dir .. "buffers.data.bak.2", "the name it was kept under")
  next_frame(context)
  context.clock.run_for(4.1)
  assert_equal(S.lib.ui_flash.text("hints"), nil, "for 4 s")
end)

end

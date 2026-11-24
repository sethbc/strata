-- test/unit/buffers_slot_test.lua
-- 3.9 (#903): the buffer slot's machine (lib/buffers.lua and
-- lib/record.lua) as a table: S.lib.buffers.status(slot) and the fields of
-- its sub-states, by every event a slot meets. Its notes' table is
-- docs/notes/lua/buffers/slot.md's, and the Machines entry
-- docs/notes/lua/buffers.md's ("buffer slot").
-- Run alone: lua test/run.lua buffers_slot

return function(h)
local assert_true, assert_equal, local_value = h.assert_true, h.assert_equal, h.local_value
local wake_buffer_clock = h.wake_buffer_clock

-- Every state is slot 1's, entered at the clock's time with nothing run
-- after it, so each 0 s report an event sends comes inside
-- BUFFER_SETTLE.confirm_seconds of the change (the rows that settle later
-- move the time on in their check)
local SLOT = 1
local RECORD_ARMED, RECORD_RECORDING, RECORD_ENDED, RECORD_CANCELED = 0, 1, 2, 3
local LATER = 1.5          -- s: past BUFFER_SETTLE.confirm_seconds (1)
local AUDIO, OLD_AUDIO, OTHER_AUDIO = 6, 4, 7   -- s: a report's new audio, a file's, an older load's
local LOST_LOAD = 2        -- the prelude's load a clear forgot in flight: no slot tracks it
local HIGH_SECONDS = 300   -- a high tier's slot, where a long file is checked

local function S_() return local_value("S") end
local function buffer() return S_().buffers[SLOT] end
local function num_buffers() return S_().constants.NUM_BUFFERS end

local function report(context, seconds, load_number)
  context.polls.fire("bufferState", context.polls.buffer_state_value(SLOT, load_number or buffer().loads_sent, seconds))
end
local function record_report(context, state)
  context.polls.fire("recordState", ((buffer().records_sent * 4) + state) * num_buffers() + SLOT - 1)
end
local function load_failed(context, load_number)
  context.polls.fire("bufferLoadFailed", (load_number * 2) * num_buffers() + SLOT - 1)
end
local function later(context) context.set_time(util.time() + LATER) end

-- Wake the slot's clock, which must hold `role`
local function wake(context, role)
  assert_equal(S_().lib.record.clock_role(SLOT), role, "the slot's clock")
  wake_buffer_clock(context, SLOT)
end

-- Most states start here: a file loaded and reported, a replace take of it
-- recorded (its "recording" report heard), stopped and settled from its
-- length (its "ended" report and a failed write of it may still come),
-- then a load the clear forgets in flight (its failure may still come).
-- The restoring states and `missing` start from a fresh script instead,
-- as init's restore does
local function prelude(context)
  load_buffer(SLOT, "/tmp/first.wav"); report(context, OLD_AUDIO)
  record_buffer(SLOT); record_report(context, RECORD_RECORDING)
  record_buffer(SLOT); report(context, 2)
  assert_equal(S_().lib.buffers.status(SLOT), "loaded", "the prelude's take settled")
  load_buffer(SLOT, "/tmp/lost.wav")
  clear_buffer(SLOT)
  assert_equal(buffer().loads_sent, LOST_LOAD, "the prelude sent two loads")
end

-- The record params a state's recording is sent with, put back after it
local function with_params(values, fn)
  local before = {}
  for id, value in pairs(values) do before[id] = params:get(id); params:set(id, value) end
  fn()
  for id, value in pairs(before) do params:set(id, value) end
end

local function load_file(context)
  load_buffer(SLOT, "/tmp/a.wav"); report(context, OLD_AUDIO)
  assert_equal(S_().lib.buffers.status(SLOT), "loaded", "a.wav settled")
end

-- A high tier's slot (set through S: the tier is read from the engine's
-- file at load, before any state can be entered) and two long files
local function high_tier(context)
  S_().performance.buffer_seconds = HIGH_SECONDS
  for _, path in ipairs({"/tmp/long1.wav", "/tmp/long2.wav"}) do
    context.audio.files[path] = {2, 48000 * 120, 48000}
  end
end

-- buffers.data naming `path` for the slot, then the restore read again
-- (load_buffers_from_disk, as init's start step runs it, on a fresh script)
local function restore(context, path, exists, long)
  local S = S_()
  util.make_dir(S.lib.scenes.scene_data_dir)
  if exists then
    util.make_dir(context.audio_dir)
    local file = assert(io.open(path, "w")); file:write("audio"); file:close()
  end
  if long then context.audio.files[path] = {2, 48000 * 120, 48000} end
  assert_true(S.lib.data_files.write(S.lib.scenes.scene_data_dir .. "buffers.data",
    {version = S.constants.BUFFER_DATA_VERSION, paths = {path}, starts = {0}, settings = {}}), "buffers.data written")
  load_buffers_from_disk()
end

local function kept_path(context) return context.audio_dir .. "kept.wav" end

local function dub(context) with_params({record_feedback = 50}, function() record_buffer(SLOT) end) end
local function loop(context) with_params({record_loop = 2}, function() record_buffer(SLOT) end) end
local function armed_dub(context)
  with_params({record_feedback = 50, record_threshold = 2}, function() record_buffer(SLOT) end)
end

local STATES = {
  ["empty"] = prelude,
  ["empty, kept state awaited"] = function(context)
    prelude(context); load_file(context)
    with_params({record_sync = 2}, function() record_buffer(SLOT) end)
    record_buffer(SLOT)                     -- stopped while armed
    record_report(context, RECORD_CANCELED)
  end,
  ["empty, adoptable"] = function(context)
    prelude(context)
    record_buffer(SLOT); wake(context, "take")
    later(context); report(context, 0)      -- settled empty
  end,
  ["loading"] = function(context)
    prelude(context)
    load_buffer(SLOT, "/tmp/a.wav"); load_buffer(SLOT, "/tmp/b.wav")
  end,
  ["loading, zero awaited"] = function(context)
    prelude(context); load_file(context)
    load_buffer(SLOT, "/tmp/b.wav"); load_buffer(SLOT, "/tmp/c.wav")
  end,
  ["loading, checking"] = function(context)
    prelude(context); high_tier(context); load_file(context)
    load_buffer(SLOT, "/tmp/long1.wav"); load_buffer(SLOT, "/tmp/long2.wav")
  end,
  ["loading, checking, empty before"] = function(context)
    prelude(context); high_tier(context)
    load_buffer(SLOT, "/tmp/long1.wav"); load_buffer(SLOT, "/tmp/long2.wav")
  end,
  ["loading, restoring"] = function(context) restore(context, kept_path(context), true) end,
  -- the restore, then four bad loads (the fourth pushes the restore's own
  -- out of the list, BUFFER_SETTLE.tracked_loads), failing in the order
  -- sent: the last one's undo gives the restore back, at 0 s, with no load
  -- tracked, the restore's own forgotten in flight
  ["loading, restoring, no load tracked"] = function(context)
    restore(context, kept_path(context), true)
    for index = 2, 5 do load_buffer(SLOT, "/tmp/bad" .. index .. ".wav") end
    for number = 2, 5 do load_failed(context, number) end
    context.forgotten_load = 1
  end,
  -- the restore, then a synced take, during which the restore's audio is
  -- reported (6 s), then a bad load that cancels the take (engine row 9)
  -- and fails: the take had not prepared the slot, so what it replaced
  -- comes back, with no load tracked (the recording emptied the list).
  -- The take and the load come after the restore by more than
  -- confirm_seconds: the restore's confirm_since comes back with it
  ["loading, restoring, no load tracked, audio known"] = function(context)
    restore(context, kept_path(context), true)
    later(context)
    with_params({record_sync = 2}, function() record_buffer(SLOT) end)
    report(context, AUDIO)
    load_buffer(SLOT, "/tmp/bad.wav")
    record_report(context, RECORD_CANCELED); report(context, AUDIO)
    load_failed(context, buffer().loads_sent)
  end,
  ["loading, checking, restoring"] = function(context)
    S_().performance.buffer_seconds = HIGH_SECONDS
    restore(context, kept_path(context), true, true)
  end,
  -- the restore's check, then four bad loads (the fourth pushes the
  -- restore's own out of the list, BUFFER_SETTLE.tracked_loads), failing
  -- in the order sent: the last one's undo gives the check back, with no
  -- load tracked, the restore's load forgotten in flight
  ["loading, checking, restoring, no load tracked"] = function(context)
    S_().performance.buffer_seconds = HIGH_SECONDS
    restore(context, kept_path(context), true, true)
    for index = 2, 5 do load_buffer(SLOT, "/tmp/bad" .. index .. ".wav") end
    for number = 2, 5 do load_failed(context, number) end
    context.forgotten_load = 1
  end,
  ["armed, unprepared"] = function(context)
    prelude(context); load_file(context)
    with_params({record_sync = 2}, function() record_buffer(SLOT) end)
  end,
  ["armed, prepared"] = function(context)
    prelude(context); load_file(context)
    with_params({record_threshold = 2}, function() record_buffer(SLOT) end)
  end,
  ["armed, playable"] = function(context) prelude(context); load_file(context); armed_dub(context) end,
  ["armed, playable, stopped"] = function(context)
    prelude(context); load_file(context); armed_dub(context); record_buffer(SLOT)
  end,
  ["recording"] = function(context) prelude(context); record_buffer(SLOT) end,
  ["dub"] = function(context) prelude(context); load_file(context); dub(context) end,
  ["dub, stopped"] = function(context) prelude(context); load_file(context); dub(context); record_buffer(SLOT) end,
  ["loop"] = function(context) prelude(context); load_file(context); loop(context) end,
  ["loop, stopped"] = function(context) prelude(context); load_file(context); loop(context); record_buffer(SLOT) end,
  ["finishing, recorded"] = function(context)
    prelude(context); record_buffer(SLOT); wake(context, "take")
  end,
  ["finishing, stopped armed"] = function(context)
    prelude(context); load_file(context)
    with_params({record_sync = 2}, function() record_buffer(SLOT) end)
    record_buffer(SLOT)
  end,
  -- a.wav then long1.wav (checked, from 0 s) sent back to back; the
  -- engine counts long1's load when it arrives and its periodic poll
  -- repeats a.wav's 4 s under long1's number, which differs from the 0 s
  -- the check waits past: the slot settles loaded as long1.wav while the
  -- engine still checks it (both loads tracked, long1's still to fail):
  -- the fault #983, the table's way in until its fix puts the common one back
  ["loaded"] = function(context)
    prelude(context); high_tier(context)
    load_buffer(SLOT, "/tmp/a.wav"); load_buffer(SLOT, "/tmp/long1.wav"); report(context, OLD_AUDIO)
    assert_equal(buffer().name, "long1.wav", "today (#983): settled as the checked load")
  end,
  ["unsettled"] = function(context)
    prelude(context)
    load_buffer(SLOT, "/tmp/z.wav"); load_buffer(SLOT, "/tmp/a.wav"); later(context); report(context, 0)
  end,
  ["missing"] = function(context)
    restore(context, context.audio_dir .. "gone.wav", false)
    load_buffer(SLOT, "/tmp/bad.wav"); load_failed(context, 1)   -- a failed load puts it back
  end,
}

local EVENTS = {
  ["load_buffer"] = function() load_buffer(SLOT, "/tmp/next.wav") end,
  ["clear_buffer"] = function() clear_buffer(SLOT) end,
  ["record_buffer"] = function() record_buffer(SLOT) end,
  ["take timer"] = function(context) wake(context, "take") end,
  ["recordState armed"] = function(context) record_report(context, RECORD_ARMED) end,
  ["recordState recording"] = function(context) record_report(context, RECORD_RECORDING) end,
  ["recordState ended"] = function(context) record_report(context, RECORD_ENDED) end,
  ["recordState canceled"] = function(context) record_report(context, RECORD_CANCELED) end,
  ["bufferState audio"] = function(context) report(context, AUDIO) end,
  ["bufferState 0 s"] = function(context) report(context, 0) end,
  ["another load's number"] = function(context) report(context, OTHER_AUDIO, buffer().loads_sent - 1) end,
  -- the newest load the slot tracks, and the one tracked before it
  ["bufferLoadFailed newest"] = function(context)
    local pending = buffer().pending_loads
    assert_true(#pending >= 1, "a load is tracked")
    load_failed(context, pending[#pending].number)
  end,
  ["bufferLoadFailed older"] = function(context)
    local pending = buffer().pending_loads
    assert_true(#pending >= 2, "an older load is tracked")
    load_failed(context, pending[#pending - 1].number)
  end,
  -- a load the slot does not track: the prelude's, forgotten in flight,
  -- or the one a state's own way in forgot
  ["bufferLoadFailed untracked"] = function(context) load_failed(context, context.forgotten_load or LOST_LOAD) end,
  ["takeWriteFailed"] = function(context)
    context.polls.fire("takeWriteFailed", buffer().records_sent * num_buffers() + SLOT - 1)
  end,
  ["the fallback"] = function(context) wake(context, "fallback") end,
  ["the notice"] = function(context) wake(context, "notice") end,
}

-- The state the slot is in: its status (S.lib.buffers.status), and for
-- "empty", "loading", "armed", "dub", "loop" and "finishing" the sub-state
-- its fields, its take and its clock's role name
local function state_of()
  local S = S_()
  local status, slot, take = S.lib.buffers.status(SLOT), buffer(), S.lib.record.state(SLOT)
  local stopped = S.lib.record.clock_role(SLOT) == "fallback"
  if status == "empty" then
    if slot.kept_state ~= nil then return "empty, kept state awaited" end
    if slot.settled_empty == "take" then return "empty, adoptable" end
    return "empty"
  elseif status == "loading" then
    -- a restore that tracks no load: its own was forgotten, or a recording
    -- emptied the list before what it replaced came back
    local unlisted = #slot.pending_loads == 0 and ", no load tracked" or ""
    if slot.checking_from ~= nil then
      -- a check over an empty slot waits for a length other than 0 s; a
      -- restore's check over audio is no state of the table (the notes say
      -- why), so its name is none of STATES
      if slot.restoring then
        return slot.checking_from == 0 and ("loading, checking, restoring" .. unlisted)
          or "loading, checking over audio, restoring"
      end
      return slot.checking_from == 0 and "loading, checking, empty before" or "loading, checking"
    end
    if slot.restoring then
      if slot.awaiting_zero then return "loading, zero awaited, restoring" end
      -- with no load tracked, the length the engine reported decides what
      -- a load waits for and whether the restore's own load can still fail
      local known = (unlisted ~= "" and slot.seconds > 0) and ", audio known" or ""
      return "loading, restoring" .. unlisted .. known
    end
    return slot.awaiting_zero and "loading, zero awaited" or "loading"
  elseif status == "armed" then
    if take.kind == "playable" then return stopped and "armed, playable, stopped" or "armed, playable" end
    -- a replace take's slot is prepared once the engine has emptied it
    -- (record.lua's take_started: at the send, a 0 s report or "recording")
    return take.unbound and "armed, prepared" or "armed, unprepared"
  elseif status == "dub" or status == "loop" then
    return stopped and (status .. ", stopped") or status
  elseif status == "finishing" then
    return take.phase == "armed" and "finishing, stopped armed" or "finishing, recorded"
  end
  return status
end

-- Row checks: what the next state alone cannot show
local function flag(name, value)
  return function() assert_equal(buffer()[name], value, name) end
end
local function then_settles(expected)
  return function(context)
    later(context); report(context, 0)
    assert_equal(state_of(), expected, "a 0 s report past confirm_seconds")
  end
end
local function named(name) return function() assert_equal(buffer().name, name, "name") end end
local function unsaved() assert_true(buffer().take_unsaved, "take_unsaved") end
local function no_clock() assert_equal(S_().lib.record.clock_role(SLOT), nil, "no clock") end
local function unbound() assert_true(not S_().lib.samples.is_bound(SLOT), "unbound") end
local function restored() assert_equal(S_().buffers_restored, 1, "counted as restored") end
local function noticed()
  h.show_page("BUFFER")
  assert_equal(S_().lib.ui_flash.text("hints"), "buf " .. SLOT .. " still checking K2:ld/clr", "the notice's flash")
end
local function adopts_unsaved(context)
  unsaved(); report(context, AUDIO)
  assert_equal(state_of(), "loaded"); assert_equal(buffer().path, nil, "an unsaved take has no path")
end
-- The playable recording ended as a take: on the scratch path, or on none
local function ended_take(path_kind)
  return function()
    assert_equal(buffer().name, "take " .. SLOT)
    assert_equal(buffer().path, path_kind == "scratch" and scratch_take_path(SLOT) or nil, "its path")
    assert_true(S_().lib.samples.is_bound(SLOT), "bound to its take")
  end
end
-- A canceled playable recording: the file it recorded over plays on
local function file_kept()
  named("a.wav")(); assert_equal(buffer().path, "/tmp/a.wav", "the file's path")
  assert_true(S_().lib.samples.is_bound(SLOT), "bound to the file")
end
local function role(expected) return function() assert_equal(S_().lib.record.clock_role(SLOT), expected, "clock") end end

local ZERO_SETTLES = then_settles("unsettled")
local STILL_CHECKING = then_settles("loading, checking, empty before")

-- The rows a state whose slot holds no take has for the reports of a take
-- a load, a clear or a settle has left (engine rows 12 and 13): ignored
local function late_reports(rows, state, which)
  for _, event in ipairs(which or {"recordState armed", "recordState recording", "recordState ended",
      "recordState canceled"}) do
    rows[#rows + 1] = {state, event, state}
  end
end

local ROWS = {
  {"empty", "load_buffer", "loading"},
  {"empty", "clear_buffer", "empty"},
  {"empty", "record_buffer", "recording"},
  {"empty", "bufferState audio", "empty"},
  {"empty", "bufferState 0 s", "empty"},
  {"empty", "another load's number", "empty"},
  {"empty", "bufferLoadFailed untracked", "empty"},
  {"empty", "takeWriteFailed", "empty", check = flag("take_unsaved", false)},

  {"empty, kept state awaited", "load_buffer", "loading"},
  {"empty, kept state awaited", "clear_buffer", "empty"},
  {"empty, kept state awaited", "record_buffer", "recording"},
  {"empty, kept state awaited", "bufferState audio", "loaded", check = named("a.wav")},
  {"empty, kept state awaited", "bufferState 0 s", "empty", check = unbound},
  {"empty, kept state awaited", "another load's number", "empty, kept state awaited"},
  {"empty, kept state awaited", "bufferLoadFailed untracked", "empty, kept state awaited"},

  {"empty, adoptable", "load_buffer", "loading"},
  {"empty, adoptable", "clear_buffer", "empty"},
  {"empty, adoptable", "record_buffer", "recording"},
  {"empty, adoptable", "bufferState audio", "loaded", check = named("take " .. SLOT)},
  {"empty, adoptable", "bufferState 0 s", "empty, adoptable"},
  {"empty, adoptable", "another load's number", "empty, adoptable"},
  {"empty, adoptable", "bufferLoadFailed untracked", "empty, adoptable"},
  {"empty, adoptable", "takeWriteFailed", "empty, adoptable", check = adopts_unsaved},

  {"loading", "load_buffer", "loading"},
  {"loading", "clear_buffer", "empty"},
  {"loading", "record_buffer", "recording"},
  {"loading", "bufferState audio", "loaded", check = named("b.wav")},
  {"loading", "bufferState 0 s", "loading", check = ZERO_SETTLES},
  {"loading", "another load's number", "loading"},
  {"loading", "bufferLoadFailed newest", "loading", check = named("a.wav")},
  {"loading", "bufferLoadFailed older", "loading", check = named("b.wav")},
  {"loading", "bufferLoadFailed untracked", "loading"},
  {"loading", "takeWriteFailed", "loading"},

  {"loading, zero awaited", "load_buffer", "loading, zero awaited"},
  {"loading, zero awaited", "clear_buffer", "empty"},
  {"loading, zero awaited", "record_buffer", "recording"},
  {"loading, zero awaited", "bufferState audio", "loading, zero awaited"},
  {"loading, zero awaited", "bufferState 0 s", "loading", check = ZERO_SETTLES},
  {"loading, zero awaited", "another load's number", "loading, zero awaited"},
  {"loading, zero awaited", "bufferLoadFailed newest", "loading", check = named("b.wav")},
  {"loading, zero awaited", "bufferLoadFailed older", "loading, zero awaited", check = named("c.wav")},
  {"loading, zero awaited", "bufferLoadFailed untracked", "loading, zero awaited"},
  {"loading, zero awaited", "takeWriteFailed", "loading, zero awaited"},

  {"loading, checking", "load_buffer", "loading, zero awaited", check = no_clock},
  {"loading, checking", "clear_buffer", "empty", check = no_clock},
  {"loading, checking", "record_buffer", "recording"},
  {"loading, checking", "bufferState audio", "loaded", check = no_clock},
  {"loading, checking", "bufferState 0 s", "loading", check = no_clock},
  {"loading, checking", "another load's number", "loading, checking"},
  {"loading, checking", "bufferLoadFailed newest", "loading, checking", check = named("long1.wav")},
  {"loading, checking", "bufferLoadFailed older", "loading, checking", check = named("long2.wav")},
  {"loading, checking", "bufferLoadFailed untracked", "loading, checking"},
  {"loading, checking", "takeWriteFailed", "loading, checking"},
  {"loading, checking", "the notice", "loading, checking", check = noticed},

  {"loading, checking, empty before", "load_buffer", "loading", check = no_clock},
  {"loading, checking, empty before", "clear_buffer", "empty", check = no_clock},
  {"loading, checking, empty before", "record_buffer", "recording"},
  {"loading, checking, empty before", "bufferState audio", "loaded", check = no_clock},
  {"loading, checking, empty before", "bufferState 0 s", "loading, checking, empty before", check = STILL_CHECKING},
  {"loading, checking, empty before", "another load's number", "loading, checking, empty before"},
  {"loading, checking, empty before", "bufferLoadFailed newest", "loading, checking, empty before",
    check = function() named("long1.wav")(); role("notice")() end},
  {"loading, checking, empty before", "bufferLoadFailed older", "loading, checking, empty before",
    check = named("long2.wav")},
  {"loading, checking, empty before", "bufferLoadFailed untracked", "loading, checking, empty before"},
  {"loading, checking, empty before", "takeWriteFailed", "loading, checking, empty before"},
  {"loading, checking, empty before", "the notice", "loading, checking, empty before", check = noticed},

  {"loading, restoring", "load_buffer", "loading"},
  {"loading, restoring", "clear_buffer", "empty"},
  {"loading, restoring", "record_buffer", "recording"},
  {"loading, restoring", "bufferState audio", "loaded", check = restored},
  {"loading, restoring", "bufferState 0 s", "loading, restoring", check = ZERO_SETTLES},
  {"loading, restoring", "another load's number", "loading, restoring"},
  {"loading, restoring", "bufferLoadFailed newest", "empty"},

  -- the restore given back by the last of four failed loads, at 0 s; its
  -- own load forgotten (it fell out of the tracked list)
  {"loading, restoring, no load tracked", "load_buffer", "loading"},
  {"loading, restoring, no load tracked", "clear_buffer", "empty"},
  {"loading, restoring, no load tracked", "record_buffer", "recording"},
  {"loading, restoring, no load tracked", "bufferState audio", "loaded", check = restored},
  {"loading, restoring, no load tracked", "bufferState 0 s", "loading, restoring, no load tracked",
    check = ZERO_SETTLES},
  {"loading, restoring, no load tracked", "another load's number", "loading, restoring, no load tracked"},
  -- #980: the restore's own failure finds nothing to undo, so the slot
  -- waits on a load the engine has ended (a later 0 s settles it
  -- unsettled, named for the failed file)
  {"loading, restoring, no load tracked", "bufferLoadFailed untracked", "loading, restoring, no load tracked",
    known = 980, check = ZERO_SETTLES},

  -- a restore that a canceled take's undo gave back (6 s known, take 1
  -- canceled by the failed load, engine row 9)
  {"loading, restoring, no load tracked, audio known", "load_buffer", "loading, zero awaited"},
  {"loading, restoring, no load tracked, audio known", "clear_buffer", "empty"},
  {"loading, restoring, no load tracked, audio known", "record_buffer", "recording"},
  {"loading, restoring, no load tracked, audio known", "bufferState audio", "loaded", check = restored},
  -- a 0 s comes only from a preparation reported after #974's fallback
  -- gave the restore back: past confirm_seconds of the restore, it settles
  {"loading, restoring, no load tracked, audio known", "bufferState 0 s", "unsettled"},
  {"loading, restoring, no load tracked, audio known", "another load's number", "loading, restoring, no load tracked, audio known"},
  {"loading, restoring, no load tracked, audio known", "takeWriteFailed", "loading, restoring, no load tracked, audio known",
    check = function(context)
      assert_equal(buffer().path, kept_path(context), "the restored file's path")
      assert_true(not buffer().take_unsaved, "no unsaved take")
    end},

  {"loading, checking, restoring", "load_buffer", "loading", check = no_clock},
  {"loading, checking, restoring", "clear_buffer", "empty", check = no_clock},
  {"loading, checking, restoring", "record_buffer", "recording"},
  {"loading, checking, restoring", "bufferState audio", "loaded", check = restored},
  {"loading, checking, restoring", "bufferState 0 s", "loading, checking, restoring"},
  {"loading, checking, restoring", "another load's number", "loading, checking, restoring"},
  {"loading, checking, restoring", "bufferLoadFailed newest", "empty", check = no_clock},
  {"loading, checking, restoring", "the notice", "loading, checking, restoring", check = noticed},

  -- the restore's check given back by the last of four failed loads; its
  -- own load forgotten (it fell out of the tracked list)
  {"loading, checking, restoring, no load tracked", "load_buffer", "loading", check = no_clock},
  {"loading, checking, restoring, no load tracked", "clear_buffer", "empty", check = no_clock},
  {"loading, checking, restoring, no load tracked", "record_buffer", "recording"},
  {"loading, checking, restoring, no load tracked", "bufferState audio", "loaded", check = restored},
  {"loading, checking, restoring, no load tracked", "bufferState 0 s", "loading, checking, restoring, no load tracked",
    check = then_settles("loading, checking, restoring, no load tracked")},
  {"loading, checking, restoring, no load tracked", "another load's number",
    "loading, checking, restoring, no load tracked"},
  -- #980: the checked load's own failure finds nothing to undo: the slot
  -- checks on until a report differs, or the player loads or clears (its
  -- notice)
  {"loading, checking, restoring, no load tracked", "bufferLoadFailed untracked",
    "loading, checking, restoring, no load tracked", known = 980, check = role("notice")},
  {"loading, checking, restoring, no load tracked", "the notice", "loading, checking, restoring, no load tracked",
    check = noticed},

  -- armed: take 2, a replace take synced (unprepared), one by a threshold
  -- (prepared at the send) or a dub by a threshold (stopped: K3 since)
  {"armed, unprepared", "load_buffer", "loading, zero awaited"},
  {"armed, unprepared", "clear_buffer", "empty"},
  {"armed, unprepared", "record_buffer", "finishing, stopped armed"},
  {"armed, unprepared", "recordState armed", "armed, unprepared"},
  {"armed, unprepared", "recordState recording", "recording", check = unbound},
  {"armed, unprepared", "bufferState audio", "armed, unprepared"},
  {"armed, unprepared", "bufferState 0 s", "armed, prepared", check = unbound},
  {"armed, unprepared", "another load's number", "armed, unprepared"},
  {"armed, unprepared", "bufferLoadFailed untracked", "armed, unprepared"},
  {"armed, unprepared", "takeWriteFailed", "armed, unprepared", check = unsaved},

  {"armed, prepared", "load_buffer", "loading"},
  {"armed, prepared", "clear_buffer", "empty"},
  {"armed, prepared", "record_buffer", "finishing, stopped armed"},
  {"armed, prepared", "recordState armed", "armed, prepared"},
  {"armed, prepared", "recordState recording", "recording"},
  {"armed, prepared", "bufferState audio", "armed, prepared"},
  {"armed, prepared", "bufferState 0 s", "armed, prepared"},
  {"armed, prepared", "another load's number", "armed, prepared"},
  {"armed, prepared", "bufferLoadFailed untracked", "armed, prepared"},
  {"armed, prepared", "takeWriteFailed", "armed, prepared", check = unsaved},

  {"armed, playable", "load_buffer", "loading, zero awaited"},
  {"armed, playable", "clear_buffer", "empty"},
  {"armed, playable", "record_buffer", "armed, playable, stopped"},
  {"armed, playable", "recordState armed", "armed, playable"},
  {"armed, playable", "recordState recording", "dub", check = role("take")},
  {"armed, playable", "bufferState audio", "armed, playable"},
  {"armed, playable", "bufferState 0 s", "armed, playable"},
  {"armed, playable", "another load's number", "armed, playable"},
  {"armed, playable", "bufferLoadFailed untracked", "armed, playable"},
  {"armed, playable", "takeWriteFailed", "armed, playable", check = unsaved},

  {"armed, playable, stopped", "load_buffer", "loading, zero awaited", check = no_clock},
  {"armed, playable, stopped", "clear_buffer", "empty", check = no_clock},
  {"armed, playable, stopped", "record_buffer", "armed, playable, stopped"},
  {"armed, playable, stopped", "recordState armed", "armed, playable, stopped"},
  {"armed, playable, stopped", "recordState recording", "dub, stopped"},
  {"armed, playable, stopped", "recordState canceled", "loaded", check = file_kept},
  {"armed, playable, stopped", "bufferState audio", "armed, playable, stopped"},
  {"armed, playable, stopped", "bufferState 0 s", "armed, playable, stopped"},
  {"armed, playable, stopped", "another load's number", "armed, playable, stopped"},
  {"armed, playable, stopped", "bufferLoadFailed untracked", "armed, playable, stopped"},
  {"armed, playable, stopped", "takeWriteFailed", "armed, playable, stopped", check = unsaved},
  {"armed, playable, stopped", "the fallback", "loaded", check = function() ended_take(nil)(); unsaved() end},

  -- recording: take 2, a replace take with no delay (its timer from the send)
  {"recording", "load_buffer", "loading"},
  {"recording", "clear_buffer", "empty"},
  {"recording", "record_buffer", "finishing, recorded"},
  {"recording", "take timer", "finishing, recorded"},
  {"recording", "recordState recording", "recording"},
  {"recording", "recordState ended", "finishing, recorded"},
  {"recording", "bufferState audio", "recording"},
  {"recording", "bufferState 0 s", "recording"},
  {"recording", "another load's number", "recording"},
  {"recording", "bufferLoadFailed untracked", "recording"},
  {"recording", "takeWriteFailed", "recording", check = unsaved},

  -- dub: take 2 over a.wav, with a length (its timer from the send)
  {"dub", "load_buffer", "loading, zero awaited"},
  {"dub", "clear_buffer", "empty"},
  {"dub", "record_buffer", "dub, stopped"},
  {"dub", "take timer", "dub, stopped"},
  {"dub", "recordState recording", "dub"},
  {"dub", "recordState ended", "loaded", check = ended_take("scratch")},
  {"dub", "bufferState audio", "dub"},
  {"dub", "bufferState 0 s", "dub"},
  {"dub", "another load's number", "dub"},
  {"dub", "bufferLoadFailed untracked", "dub"},
  {"dub", "takeWriteFailed", "dub", check = unsaved},

  {"dub, stopped", "load_buffer", "loading, zero awaited", check = no_clock},
  {"dub, stopped", "clear_buffer", "empty", check = no_clock},
  {"dub, stopped", "record_buffer", "dub, stopped"},
  {"dub, stopped", "recordState recording", "dub, stopped"},
  {"dub, stopped", "recordState ended", "loaded", check = ended_take("scratch")},
  {"dub, stopped", "recordState canceled", "loaded", check = file_kept},
  {"dub, stopped", "bufferState audio", "dub, stopped"},
  {"dub, stopped", "bufferState 0 s", "dub, stopped"},
  {"dub, stopped", "another load's number", "dub, stopped"},
  {"dub, stopped", "bufferLoadFailed untracked", "dub, stopped"},
  {"dub, stopped", "takeWriteFailed", "dub, stopped", check = unsaved},
  {"dub, stopped", "the fallback", "loaded", check = ended_take("scratch")},

  -- loop: take 2 over a.wav, looping (no length: K3 alone ends it)
  {"loop", "load_buffer", "loading, zero awaited"},
  {"loop", "clear_buffer", "empty"},
  {"loop", "record_buffer", "loop, stopped"},
  {"loop", "recordState recording", "loop"},
  {"loop", "bufferState audio", "loop"},
  {"loop", "bufferState 0 s", "loop"},
  {"loop", "another load's number", "loop"},
  {"loop", "bufferLoadFailed untracked", "loop"},
  {"loop", "takeWriteFailed", "loop", check = unsaved},

  {"loop, stopped", "load_buffer", "loading, zero awaited", check = no_clock},
  {"loop, stopped", "clear_buffer", "empty", check = no_clock},
  {"loop, stopped", "record_buffer", "loop, stopped"},
  {"loop, stopped", "recordState recording", "loop, stopped"},
  {"loop, stopped", "recordState ended", "loaded", check = ended_take("scratch")},
  {"loop, stopped", "recordState canceled", "loaded", check = file_kept},
  {"loop, stopped", "bufferState audio", "loop, stopped"},
  {"loop, stopped", "bufferState 0 s", "loop, stopped"},
  {"loop, stopped", "another load's number", "loop, stopped"},
  {"loop, stopped", "bufferLoadFailed untracked", "loop, stopped"},
  {"loop, stopped", "takeWriteFailed", "loop, stopped", check = unsaved},
  {"loop, stopped", "the fallback", "loaded", check = ended_take("scratch")},

  -- finishing: take 2's timer ran out (0 s known), or a synced take 2
  -- stopped while armed (a.wav's 4 s still reported)
  {"finishing, recorded", "load_buffer", "loading"},
  {"finishing, recorded", "clear_buffer", "empty"},
  {"finishing, recorded", "record_buffer", "finishing, recorded"},
  {"finishing, recorded", "recordState recording", "finishing, recorded"},
  {"finishing, recorded", "recordState ended", "finishing, recorded"},
  {"finishing, recorded", "recordState canceled", "empty, kept state awaited", check = function()
    no_clock(); assert_equal(buffer().kept_state.name, "empty", "it keeps the empty slot it replaced")
  end},
  {"finishing, recorded", "bufferState audio", "loaded", check = named("take " .. SLOT)},
  {"finishing, recorded", "bufferState 0 s", "finishing, recorded", check = then_settles("empty, adoptable")},
  {"finishing, recorded", "another load's number", "finishing, recorded"},
  {"finishing, recorded", "bufferLoadFailed untracked", "finishing, recorded"},
  {"finishing, recorded", "takeWriteFailed", "finishing, recorded", check = unsaved},
  {"finishing, recorded", "the fallback", "empty, adoptable", check = no_clock},

  {"finishing, stopped armed", "load_buffer", "loading, zero awaited"},
  {"finishing, stopped armed", "clear_buffer", "empty"},
  {"finishing, stopped armed", "record_buffer", "finishing, stopped armed"},
  {"finishing, stopped armed", "recordState armed", "finishing, stopped armed"},
  {"finishing, stopped armed", "recordState recording", "finishing, recorded"},
  {"finishing, stopped armed", "recordState canceled", "empty, kept state awaited"},
  {"finishing, stopped armed", "bufferState audio", "finishing, stopped armed"},
  {"finishing, stopped armed", "bufferState 0 s", "finishing, stopped armed"},
  {"finishing, stopped armed", "another load's number", "finishing, stopped armed"},
  {"finishing, stopped armed", "bufferLoadFailed untracked", "finishing, stopped armed"},
  {"finishing, stopped armed", "takeWriteFailed", "finishing, stopped armed", check = unsaved},
  -- it never started (#974): a.wav comes back, on its own path
  {"finishing, stopped armed", "the fallback", "loaded", check = function()
    named("a.wav")(); assert_equal(buffer().path, "/tmp/a.wav", "the file's path")
  end},

  -- loaded: a.wav settled, z.wav (sent just before it) still tracked
  {"loaded", "load_buffer", "loading, zero awaited"},
  {"loaded", "clear_buffer", "empty"},
  {"loaded", "record_buffer", "recording"},
  {"loaded", "bufferState audio", "loaded"},
  {"loaded", "bufferState 0 s", "loaded"},
  {"loaded", "another load's number", "loaded"},
  -- the check's own failure: what it replaced comes back, a.wav's load
  -- (the engine holds a.wav: its next report settles it). #983: the slot
  -- showed long1.wav loaded from a.wav's repeated length while the engine
  -- still checked long1
  {"loaded", "bufferLoadFailed newest", "loading", known = 983, check = function()
    named("a.wav")(); assert_equal(buffer().pending_loads[#buffer().pending_loads].number, buffer().loads_sent - 1,
      "a.wav's load, still tracked")
  end},
  {"loaded", "bufferLoadFailed older", "loaded", check = named("long1.wav")},
  {"loaded", "bufferLoadFailed untracked", "loaded"},
  {"loaded", "takeWriteFailed", "loaded"},

  -- unsettled: a.wav settled empty, z.wav (sent just before it) still tracked
  {"unsettled", "load_buffer", "loading"},
  {"unsettled", "clear_buffer", "empty"},
  {"unsettled", "record_buffer", "recording"},
  {"unsettled", "bufferState audio", "loaded", check = named("a.wav")},
  {"unsettled", "bufferState 0 s", "unsettled"},
  {"unsettled", "another load's number", "unsettled"},
  {"unsettled", "bufferLoadFailed newest", "loading", check = named("z.wav")},
  {"unsettled", "bufferLoadFailed older", "unsettled", check = named("a.wav")},
  {"unsettled", "bufferLoadFailed untracked", "unsettled"},
  {"unsettled", "takeWriteFailed", "unsettled"},

  -- missing: restored at start, a load over it failed and put it back
  {"missing", "load_buffer", "loading"},
  {"missing", "clear_buffer", "empty"},
  {"missing", "record_buffer", "recording"},
  {"missing", "bufferState 0 s", "missing"},
  {"missing", "another load's number", "missing"},
}
-- the reports of a take a load, a clear or a settle left, in the states
-- that hold no take of their own
for _, state in ipairs({"empty", "loading", "loading, zero awaited", "loading, checking",
    "loading, checking, empty before", "loading, restoring, no load tracked, audio known", "loaded", "unsettled"}) do
  late_reports(ROWS, state)
end
late_reports(ROWS, "empty, adoptable", {"recordState recording", "recordState ended", "recordState canceled"})

-- The cells that cannot happen, each with its reason
local IMPOSSIBLE = {}
local function impossible(states, events, reason)
  for _, state in ipairs(states) do
    for _, event in ipairs(events) do IMPOSSIBLE[#IMPOSSIBLE + 1] = {state, event, reason} end
  end
end
local ALL = {}
for state in pairs(STATES) do ALL[#ALL + 1] = state end
table.sort(ALL)
local function all_but(...)
  local skip, kept = {}, {}
  for _, state in ipairs({...}) do skip[state] = true end
  for _, state in ipairs(ALL) do if not skip[state] then kept[#kept + 1] = state end end
  return kept
end
local REPORTS = {"recordState armed", "recordState recording", "recordState ended", "recordState canceled"}
local TAKES = {"armed, unprepared", "armed, prepared", "armed, playable", "armed, playable, stopped", "recording",
  "dub", "dub, stopped", "loop", "loop, stopped", "finishing, recorded", "finishing, stopped armed"}
local CHECKED_RESTORES = {"loading, checking, restoring", "loading, checking, restoring, no load tracked"}

-- Each reason is a fact of the code (lib/buffers.lua, lib/record.lua, the
-- engine's record.md and buffers.md), true by every way into the state: a
-- key, a param, a grid key, MIDI, a scene, a PSET read, a late engine
-- report or a timer

-- the slot's one clock (S.lib.record.clock_role)
impossible(all_but("recording", "dub"), {"take timer"},
  "the take timer runs only while a take with a length records: start_take_timer starts it at the send of a"
  .. " replace take or a dub with no delay or threshold, or at an armed one's \"recording\"; a loop has none,"
  .. " and K3, its own end, a load and a clear end it")
impossible(all_but("finishing, recorded", "finishing, stopped armed", "armed, playable, stopped", "dub, stopped",
    "loop, stopped"), {"the fallback"},
  "the fallback runs only after a take ends or stops: finish_buffer_take (finishing) or start_playable_fallback"
  .. " (a playable recording stopped by K3 or its length); the report, load, clear or recording that ends the"
  .. " take ends it")
impossible(all_but("loading, checking", "loading, checking, empty before", "loading, checking, restoring",
    "loading, checking, restoring, no load tracked"), {"the notice"},
  "a check's notice clock runs only while the slot checks a load (the \"buffer slots\" invariant: a load, a"
  .. " clear, a recording, the check's end and a failure whose undo gives back no check each end it)")

-- the recordState reports, of the slot's newest recording (records_sent)
impossible({"missing"}, REPORTS,
  "no recording since the start: missing_path is set only by init's restore and every recording clears it;"
  .. " it comes back only as the state before a load sent while it was missing (a recording empties that"
  .. " list) or as what a canceled take kept, which needs audio a missing file's slot never reports")
impossible({"loading, restoring"}, REPORTS,
  "no recording since the start: the restore's own load is still tracked, and a recording empties the"
  .. " tracked loads for good (a restore loads only at init)")
impossible({"loading, restoring, no load tracked"}, REPORTS,
  "no recording since the start: a restore comes back after a recording only as what a canceled armed take"
  .. " replaced, and only with a length reported (resolve_previous, settle_kept_state), which is the other"
  .. " state; that state never drops to 0 s and stays restoring: its 0 s comes only from a preparation"
  .. " reported after #974's fallback, 5 s after the stop and so past confirm_seconds of the restore's"
  .. " confirm_since, and settles it unsettled; so at 0 s with no load tracked the restore came back through"
  .. " failed loads alone, the restore's own forgotten among them")
impossible(CHECKED_RESTORES, REPORTS,
  "no recording since the start: a recording ends the check, and what a canceled take gives back is never"
  .. " a check (state_before_take passes over every load still checked)")
impossible({"empty, kept state awaited"}, REPORTS,
  "kept_state rests only after the take's \"canceled\" (its fallback settles it at once), the engine's last"
  .. " report of a take (stopRecording); its earlier ones came before it on the same poll")
impossible({"empty, adoptable"}, {"recordState armed"},
  "the slot settled empty for a take Lua saw record (phase \"recording\", set at a send the engine reports"
  .. " no \"armed\" for, or by its \"recording\") or for one a failed load canceled: an armed take's"
  .. " \"armed\" is the engine's first report of it, sent at the recordBuffer, before any of those")
impossible({"recording", "dub", "loop", "finishing, recorded", "dub, stopped", "loop, stopped"}, {"recordState armed"},
  "phase \"recording\": Lua set it at the send of a take with no delay or threshold, of which the engine"
  .. " reports no \"armed\", or at its \"recording\", which comes after its \"armed\" on the same poll")
impossible({"armed, unprepared", "armed, prepared", "armed, playable", "recording", "dub", "loop"},
  {"recordState canceled"},
  "the engine cancels a take at a stopRecord, a load, a clear, a newer recordBuffer (stopRecording, rows"
  .. " 6-13) or its own free (after cleanup has stopped the poll), and, as a safety net, when a record synth"
  .. " frees before it armed (recordSynthFreed), which only a stop reaches: an unarmed synth's envelope is"
  .. " never opened, and stopRecordSlot frees one it gates off. Lua has sent none since the take:"
  .. " load_buffer and clear_buffer end the take, and record_buffer on a recording slot is K3, whose"
  .. " stopRecord leaves a finishing or stopped state")
impossible({"armed, unprepared", "armed, prepared", "armed, playable", "armed, playable, stopped",
    "finishing, stopped armed"}, {"recordState ended"},
  "phase \"armed\": Lua has not had the take's \"recording\", which the engine sends before its \"ended\""
  .. " on the same poll (takeArmed, endTake)")
impossible({"loop"}, {"recordState ended"},
  "a loop's record synth wraps until it is gated off, and Lua gates it off only by K3's stopRecord, which"
  .. " starts its fallback (the state is then loop, stopped); a load or a clear cancels it (\"canceled\")")

-- takeWriteFailed, of the newest recording
impossible({"missing", "loading, restoring", "loading, restoring, no load tracked", "loading, checking, restoring",
    "loading, checking, restoring, no load tracked"}, {"takeWriteFailed"},
  "no recording since the start (the recordState reports' reasons above), so no scratch write")
impossible({"empty, kept state awaited"}, {"takeWriteFailed"},
  "the newest recording was canceled, and the engine writes only a take that ended (endTake)")

-- bufferLoadFailed: the newest load the slot tracks, one tracked before
-- it, one it does not track
impossible(TAKES, {"bufferLoadFailed newest", "bufferLoadFailed older"},
  "no load is tracked while a take runs: record_buffer empties the list, and a load ends the take")
impossible({"empty", "empty, kept state awaited", "empty, adoptable"},
  {"bufferLoadFailed newest", "bufferLoadFailed older"},
  "no tracked load's failure can still come: a clear, a recording and a take's end empty the list; a failure"
  .. " that empties the slot comes after the failures of the loads before it (the server reads a slot's files"
  .. " in order), and one that gives back an empty slot only once every later load has failed")
impossible({"missing", "loading, restoring, no load tracked", "loading, restoring, no load tracked, audio known",
    "loading, checking, restoring, no load tracked"},
  {"bufferLoadFailed newest", "bufferLoadFailed older"},
  "no load is tracked: none at the start, and a failed load gives back the missing path only once every"
  .. " later load has failed (the three no-load states are named for it)")
impossible({"loading, restoring, no load tracked, audio known"}, {"bufferLoadFailed untracked"},
  "no load the slot sent can still fail untracked: the restore's own took effect (the known length is its"
  .. " audio, reported while the take was armed), the recording emptied the list, and every load since has"
  .. " failed (the one whose undo gave this state back was the newest tracked; four newer ones would push"
  .. " it out, and this state could not come back)")
impossible({"loading, restoring", "loading, checking, restoring"}, {"bufferLoadFailed older"},
  "a restoring slot tracks at most the restore's own load: a failed later load gives back the state from"
  .. " before it, with only the loads before it")
impossible({"loading, restoring", "loading, checking, restoring"}, {"bufferLoadFailed untracked"},
  "every load since the restore's has failed or is tracked: four newer ones would push the restore's own"
  .. " out of the list first (the no-load states), and a clear or a recording ends the restore")
impossible({"missing"}, {"bufferLoadFailed untracked"},
  "every load sent since the slot was missing has reported its failure (only that gives the missing path"
  .. " back), and none came before it")
impossible({"missing"}, {"bufferState audio"},
  "the slot has held no audio since the start: init's restore found no file, and every load since failed")

-- The table's states split every case of S.lib.buffers.status, none left out
h.test("the buffer slot's states cover every status a slot can have", function()
  local statuses = {"finishing", "armed", "loop", "dub", "recording", "loading", "loaded", "unsettled", "missing",
    "empty"}
  for _, status in ipairs(statuses) do
    local found = false
    for state in pairs(STATES) do
      if state == status or state:sub(1, #status + 2) == status .. ", " then found = true end
    end
    assert_true(found, "a state of the status " .. status)
  end
end)

h.transition_table({
  name = "buffer slot",
  notes = {"docs/notes/lua/buffers/slot.md", "buffer slot"},
  states = STATES,
  events = EVENTS,
  state_of = state_of,
  rows = ROWS,
  impossible = IMPOSSIBLE,
})

end

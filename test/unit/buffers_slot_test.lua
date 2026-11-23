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

-- Every state starts here: a file loaded and reported, a replace take of it
-- recorded (its "recording" report heard), stopped and settled from its
-- length (its "ended" report and a failed write of it may still come),
-- then a load the clear forgets in flight (its failure may still come).
-- So the slot is empty, its newest recording is take 1, and each event
-- that names an older load, an untracked one or a late report has a real
-- one to name
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
-- (load_buffers_from_disk, as init's start step runs it)
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
  ["loading, restoring"] = function(context)
    prelude(context); restore(context, kept_path(context), true)
  end,
  ["loading, zero awaited, restoring"] = function(context)
    prelude(context); load_file(context); restore(context, kept_path(context), true)
  end,
  ["loading, checking, restoring"] = function(context)
    prelude(context); high_tier(context); load_file(context); restore(context, kept_path(context), true, true)
  end,
  ["armed, unprepared"] = function(context)
    prelude(context); load_file(context)
    with_params({record_sync = 2}, function() record_buffer(SLOT) end)
  end,
  ["armed, prepared"] = function(context)
    prelude(context); load_file(context)
    with_params({record_threshold = 2}, function() record_buffer(SLOT) end)
  end,
  ["armed, playable"] = function(context)
    prelude(context); load_file(context)
    with_params({record_feedback = 50, record_threshold = 2}, function() record_buffer(SLOT) end)
  end,
  ["recording"] = function(context) prelude(context); record_buffer(SLOT) end,
  ["dub"] = function(context)
    prelude(context); load_file(context)
    with_params({record_feedback = 50}, function() record_buffer(SLOT) end)
  end,
  ["loop"] = function(context)
    prelude(context); load_file(context)
    with_params({record_loop = 2}, function() record_buffer(SLOT) end)
  end,
  ["finishing, recorded"] = function(context)
    prelude(context); record_buffer(SLOT); wake(context, "take")
  end,
  ["finishing, stopped armed"] = function(context)
    prelude(context); load_file(context)
    with_params({record_sync = 2}, function() record_buffer(SLOT) end)
    record_buffer(SLOT)
  end,
  ["loaded"] = function(context) prelude(context); load_file(context) end,
  ["unsettled"] = function(context)
    prelude(context); load_buffer(SLOT, "/tmp/a.wav"); later(context); report(context, 0)
  end,
  ["missing"] = function(context) prelude(context); restore(context, context.audio_dir .. "gone.wav", false) end,
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
  ["bufferLoadFailed newest"] = function(context) load_failed(context, buffer().loads_sent) end,
  ["bufferLoadFailed older"] = function(context) load_failed(context, buffer().loads_sent - 1) end,
  ["bufferLoadFailed untracked"] = function(context) load_failed(context, LOST_LOAD) end,
  ["takeWriteFailed"] = function(context)
    context.polls.fire("takeWriteFailed", buffer().records_sent * num_buffers() + SLOT - 1)
  end,
  ["the fallback"] = function(context) wake(context, "fallback") end,
  ["the notice"] = function(context) wake(context, "notice") end,
}

-- The state the slot is in: its status (S.lib.buffers.status), and for
-- "empty", "loading", "armed" and "finishing" the sub-state its fields and
-- its take name
local function state_of()
  local S = S_()
  local status, slot, take = S.lib.buffers.status(SLOT), buffer(), S.lib.record.state(SLOT)
  if status == "empty" then
    if slot.kept_state ~= nil then return "empty, kept state awaited" end
    if slot.settled_empty == "take" then return "empty, adoptable" end
    return "empty"
  elseif status == "loading" then
    local name = slot.checking_from ~= nil and "loading, checking" or (slot.awaiting_zero and "loading, zero awaited")
      or "loading"
    return slot.restoring and (name .. ", restoring") or name
  elseif status == "armed" then
    if take.kind == "playable" then return "armed, playable" end
    -- a replace take's slot is prepared once the engine has emptied it
    -- (record.lua's take_started: at the send, a 0 s report or "recording")
    return take.unbound and "armed, prepared" or "armed, unprepared"
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
-- The fallback runs now (a K3, or a dub's length that ran out): it ends the
-- recording from its last known length, on `path` (the scratch take, or nil)
local function then_fallback(path_kind)
  return function(context)
    wake(context, "fallback")
    assert_equal(state_of(), "loaded", "the fallback ended it")
    assert_equal(buffer().name, "take " .. SLOT)
    assert_equal(buffer().path, path_kind == "scratch" and scratch_take_path(SLOT) or nil, "its path")
    assert_true(S_().lib.samples.is_bound(SLOT), "bound to its take")
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

local ZERO_SETTLES = then_settles("unsettled")

local ROWS = {
  -- empty: the prelude's take 1 has settled, its "ended" may come late
  {"empty", "load_buffer", "loading"},
  {"empty", "clear_buffer", "empty"},
  {"empty", "record_buffer", "recording"},
  {"empty", "recordState ended", "empty"},
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
  {"empty, adoptable", "recordState recording", "empty, adoptable"},
  {"empty, adoptable", "recordState ended", "empty, adoptable"},
  {"empty, adoptable", "bufferState audio", "loaded", check = named("take " .. SLOT)},
  {"empty, adoptable", "bufferState 0 s", "empty, adoptable"},
  {"empty, adoptable", "another load's number", "empty, adoptable"},
  {"empty, adoptable", "bufferLoadFailed untracked", "empty, adoptable"},
  {"empty, adoptable", "takeWriteFailed", "empty, adoptable", check = adopts_unsaved},

  {"loading", "load_buffer", "loading"},
  {"loading", "clear_buffer", "empty"},
  {"loading", "record_buffer", "recording"},
  {"loading", "recordState ended", "loading"},
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
  {"loading, zero awaited", "recordState ended", "loading, zero awaited"},
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
  {"loading, checking", "recordState ended", "loading, checking"},
  {"loading, checking", "bufferState audio", "loaded", check = no_clock},
  {"loading, checking", "bufferState 0 s", "loading", check = no_clock},
  {"loading, checking", "another load's number", "loading, checking"},
  {"loading, checking", "bufferLoadFailed newest", "loading, checking", check = named("long1.wav")},
  {"loading, checking", "bufferLoadFailed older", "loading, checking", check = named("long2.wav")},
  {"loading, checking", "bufferLoadFailed untracked", "loading, checking"},
  {"loading, checking", "takeWriteFailed", "loading, checking"},
  {"loading, checking", "the notice", "loading, checking", check = noticed},

  {"loading, restoring", "load_buffer", "loading"},
  {"loading, restoring", "clear_buffer", "empty"},
  {"loading, restoring", "record_buffer", "recording"},
  {"loading, restoring", "recordState ended", "loading, restoring"},
  {"loading, restoring", "bufferState audio", "loaded", check = restored},
  {"loading, restoring", "bufferState 0 s", "loading, restoring", check = ZERO_SETTLES},
  {"loading, restoring", "another load's number", "loading, restoring"},
  {"loading, restoring", "bufferLoadFailed newest", "empty"},
  {"loading, restoring", "bufferLoadFailed untracked", "loading, restoring"},
  {"loading, restoring", "takeWriteFailed", "loading, restoring"},

  {"loading, zero awaited, restoring", "load_buffer", "loading, zero awaited"},
  {"loading, zero awaited, restoring", "clear_buffer", "empty"},
  {"loading, zero awaited, restoring", "record_buffer", "recording"},
  {"loading, zero awaited, restoring", "recordState ended", "loading, zero awaited, restoring"},
  {"loading, zero awaited, restoring", "bufferState audio", "loading, zero awaited, restoring"},
  {"loading, zero awaited, restoring", "bufferState 0 s", "loading, restoring"},
  {"loading, zero awaited, restoring", "another load's number", "loading, zero awaited, restoring"},
  {"loading, zero awaited, restoring", "bufferLoadFailed newest", "loaded", check = named("a.wav")},
  {"loading, zero awaited, restoring", "bufferLoadFailed untracked", "loading, zero awaited, restoring"},
  {"loading, zero awaited, restoring", "takeWriteFailed", "loading, zero awaited, restoring"},

  {"loading, checking, restoring", "load_buffer", "loading, zero awaited", check = no_clock},
  {"loading, checking, restoring", "clear_buffer", "empty", check = no_clock},
  {"loading, checking, restoring", "record_buffer", "recording"},
  {"loading, checking, restoring", "recordState ended", "loading, checking, restoring"},
  {"loading, checking, restoring", "bufferState audio", "loaded", check = restored},
  {"loading, checking, restoring", "bufferState 0 s", "loading, restoring", check = no_clock},
  {"loading, checking, restoring", "another load's number", "loading, checking, restoring"},
  {"loading, checking, restoring", "bufferLoadFailed newest", "loaded", check = named("a.wav")},
  {"loading, checking, restoring", "bufferLoadFailed untracked", "loading, checking, restoring"},
  {"loading, checking, restoring", "takeWriteFailed", "loading, checking, restoring"},
  {"loading, checking, restoring", "the notice", "loading, checking, restoring", check = noticed},

  -- armed: take 2, a replace take synced (unprepared), one by a threshold
  -- (prepared at the send) or a dub by a threshold
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
  {"armed, playable", "record_buffer", "armed, playable", check = function(context)
    then_fallback(nil)(context); unsaved()
  end},
  {"armed, playable", "recordState armed", "armed, playable"},
  {"armed, playable", "recordState recording", "dub", check = function(context)
    wake(context, "take"); then_fallback("scratch")(context)
  end},
  {"armed, playable", "bufferState audio", "armed, playable"},
  {"armed, playable", "bufferState 0 s", "armed, playable"},
  {"armed, playable", "another load's number", "armed, playable"},
  {"armed, playable", "bufferLoadFailed untracked", "armed, playable"},
  {"armed, playable", "takeWriteFailed", "armed, playable", check = unsaved},

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
  {"dub", "record_buffer", "dub", check = then_fallback("scratch")},
  {"dub", "take timer", "dub", check = then_fallback("scratch")},
  {"dub", "recordState recording", "dub"},
  {"dub", "recordState ended", "loaded", check = named("take " .. SLOT)},
  {"dub", "bufferState audio", "dub"},
  {"dub", "bufferState 0 s", "dub"},
  {"dub", "another load's number", "dub"},
  {"dub", "bufferLoadFailed untracked", "dub"},
  {"dub", "takeWriteFailed", "dub", check = unsaved},

  -- loop: take 2 over a.wav, looping (no length: K3 alone ends it)
  {"loop", "load_buffer", "loading, zero awaited"},
  {"loop", "clear_buffer", "empty"},
  {"loop", "record_buffer", "loop", check = then_fallback("scratch")},
  {"loop", "recordState recording", "loop"},
  {"loop", "bufferState audio", "loop"},
  {"loop", "bufferState 0 s", "loop"},
  {"loop", "another load's number", "loop"},
  {"loop", "bufferLoadFailed untracked", "loop"},
  {"loop", "takeWriteFailed", "loop", check = unsaved},

  -- finishing: take 2's timer ran out (0 s known), or a synced take 2
  -- stopped while armed (a.wav's 4 s still reported)
  {"finishing, recorded", "load_buffer", "loading"},
  {"finishing, recorded", "clear_buffer", "empty"},
  {"finishing, recorded", "record_buffer", "finishing, recorded"},
  {"finishing, recorded", "recordState recording", "finishing, recorded"},
  {"finishing, recorded", "recordState ended", "finishing, recorded"},
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
  -- a fault, its issue yet to be filed: the fallback settles a take that
  -- may never have recorded as take 1 on the scratch path (the old audio's
  -- 4 s), as #904 kept an armed dub from doing
  {"finishing, stopped armed", "the fallback", "loaded", check = function()
    named("take " .. SLOT)(); assert_equal(buffer().path, scratch_take_path(SLOT), "today: the scratch path")
  end},

  {"loaded", "load_buffer", "loading, zero awaited"},
  {"loaded", "clear_buffer", "empty"},
  {"loaded", "record_buffer", "recording"},
  {"loaded", "recordState ended", "loaded"},
  {"loaded", "bufferState audio", "loaded"},
  {"loaded", "bufferState 0 s", "loaded"},
  {"loaded", "another load's number", "loaded"},
  {"loaded", "bufferLoadFailed untracked", "loaded"},
  {"loaded", "takeWriteFailed", "loaded"},

  {"unsettled", "load_buffer", "loading"},
  {"unsettled", "clear_buffer", "empty"},
  {"unsettled", "record_buffer", "recording"},
  {"unsettled", "recordState ended", "unsettled"},
  {"unsettled", "bufferState audio", "loaded", check = named("a.wav")},
  {"unsettled", "bufferState 0 s", "unsettled"},
  {"unsettled", "another load's number", "unsettled"},
  {"unsettled", "bufferLoadFailed newest", "empty"},
  {"unsettled", "bufferLoadFailed untracked", "unsettled"},
  {"unsettled", "takeWriteFailed", "unsettled"},

  {"missing", "load_buffer", "loading"},
  {"missing", "clear_buffer", "empty"},
  {"missing", "record_buffer", "recording"},
  {"missing", "recordState ended", "missing"},
  {"missing", "bufferState audio", "missing"},
  {"missing", "bufferState 0 s", "missing"},
  {"missing", "another load's number", "missing"},
  {"missing", "bufferLoadFailed untracked", "missing"},
  {"missing", "takeWriteFailed", "missing"},
}

-- The cells that cannot happen, by kind, each with its reason
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
local TAKE_1_DONE = {"empty", "loading", "loading, zero awaited", "loading, checking", "loading, restoring",
  "loading, zero awaited, restoring", "loading, checking, restoring", "loaded", "unsettled", "missing"}
impossible(all_but("recording", "dub"), {"take timer"},
  "no take timer runs: only a replace take recording, or a dub with a length, has one")
impossible(all_but("finishing, recorded", "finishing, stopped armed"), {"the fallback"},
  "no fallback runs: only a finishing take has one as the state is entered (a K3 or a dub's length starts a playable one: those rows' checks run it)")
impossible(all_but("loading, checking", "loading, checking, restoring"), {"the notice"},
  "no check runs, so no notice")
impossible(TAKE_1_DONE, {"recordState armed", "recordState recording", "recordState canceled"},
  "the newest recording is the prelude's take 1, whose \"recording\" came and whose length settled it: only its \"ended\" can still come")
impossible({"empty, kept state awaited"},
  {"recordState armed", "recordState recording", "recordState ended", "recordState canceled"},
  "the take's \"canceled\" was its last report")
impossible({"empty, kept state awaited"}, {"takeWriteFailed"}, "a canceled take writes no scratch file")
impossible({"empty, adoptable"}, {"recordState armed"}, "a take with no delay or threshold is never armed")
impossible({"empty, adoptable", "recording", "dub", "finishing, recorded"}, {"recordState canceled"},
  "the engine cancels a take only at a stopRecord of an armed take, a load or a clear, and none was sent")
impossible({"armed, unprepared", "armed, prepared", "armed, playable", "loop", "finishing, stopped armed"},
  {"recordState ended"},
  "the engine sends a take's \"recording\" before its \"ended\" on the same poll, and a loop ends only at a stop")
impossible({"armed, unprepared", "armed, prepared", "armed, playable", "loop"}, {"recordState canceled"},
  "the engine cancels a take only at a stopRecord of an armed take, a load or a clear, and none was sent")
impossible({"recording", "dub", "loop", "finishing, recorded"}, {"recordState armed"},
  "a take that records was never armed, or has said so already")
impossible(all_but("loading", "loading, zero awaited", "loading, checking", "loading, restoring",
    "loading, zero awaited, restoring", "loading, checking, restoring", "unsettled"),
  {"bufferLoadFailed newest"},
  "no load in flight is tracked (a clear or a recording forgot them; a loaded slot's load reported its audio)")
impossible(all_but("loading", "loading, zero awaited", "loading, checking"), {"bufferLoadFailed older"},
  "no older load is in flight: a restore's load is the slot's only one, and an earlier tracked load reported its audio or was forgotten")

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

-- test/unit/notes_test.lua
-- The notes module (lib/notes.lua, S.lib.notes, design §2, §6.4): the pool
-- setting and notes.data, note_values, the allocator's six branches, release
-- and parking, stealing, the freeze reference, the voice-stop and
-- freeze-change hooks, the expression flush and the note cap.
-- Run alone: lua test/run.lua notes

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local HIGH = {tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60, reason = "high: setting"}

local function notes_path(context) return context.data_dir .. "strata/notes.data" end

-- Write notes.data before init: a value in tab.save's layout, or text as it is
local function with_notes_file(case)
  return function(context)
    os.execute("mkdir -p '" .. context.data_dir .. "strata'")
    local text = type(case) == "string" and case or local_value("S").lib.data_files.encode(case)
    h.write_text(notes_path(context), text)
  end
end

-- The console lines that name notes.data
local function notes_lines(context)
  local lines = {}
  for _, line in ipairs(context.printed) do
    if line:find("notes.data", 1, true) then lines[#lines + 1] = line end
  end
  return lines
end

test("the pool is the tier's default until a file says otherwise", function()
  local context = load_strata(); finish_startup(context)
  local notes = local_value("S").lib.notes
  assert_equal(notes.pool(), 4, "standard: 4")
  assert_equal(#notes_lines(context), 0, "no file: no line")
  assert_equal(notes.pool_used(), 0, "no extra note is held")
  for voice = 1, local_value("S").constants.NUM_VOICES do
    assert_equal(notes.held(voice), 0, "voice " .. voice .. " holds no extra note")
  end
  h.write_performance_active(HIGH)
  load_strata()
  assert_equal(local_value("S").lib.notes.pool(), 8, "a high start: 8")
  context = load_strata({ before_init = with_notes_file({ version = 1, pool = 11 }) })
  assert_equal(local_value("S").lib.notes.pool(), 11, "notes.data's pool")
  assert_equal(#notes_lines(context), 0, "a good file: no line")
end)

test("set_pool clamps, writes first and keeps the old value when the write fails", function()
  local subdir = "notes_pool_kept"
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local S = local_value("S")
  local notes = S.lib.notes
  context.clear_engine_calls()
  assert_equal(notes.set_pool(20), true, "set")
  assert_equal(notes.pool(), 16, "clamped to the maximum")
  local value = S.lib.data_files.read(notes_path(context))
  assert_equal(type(value), "table", "written to notes.data")
  assert_equal(value.version, 1); assert_equal(value.pool, 16)
  assert_equal(notes.set_pool(-3), true)
  assert_equal(notes.pool(), 0, "clamped to 0")
  assert_equal(S.lib.data_files.read(notes_path(context)).pool, 0, "and written")
  for _, bad in ipairs({ "3", 2.5, 0 / 0, math.huge }) do
    assert_equal(notes.set_pool(bad), false, "refused: " .. tostring(bad))
  end
  assert_equal(notes.set_pool(), false, "refused: nil")
  assert_equal(notes.pool(), 0, "unchanged")
  local told = context.calls_named("setNotePool")
  assert_equal(#context.engine_calls, 2, "only the two pools set are sent")
  assert_equal(#told, 2); assert_equal(told[1].args[1], 16); assert_equal(told[2].args[1], 0)
  -- a write that fails sets nothing
  os.execute("mkdir -p '" .. notes_path(context) .. ".part/inside'")  -- the .part is a folder: the write fails
  assert_equal(notes.set_pool(5), false, "not set")
  assert_equal(notes.pool(), 0, "the old value")
  assert_equal(S.lib.data_files.read(notes_path(context)).pool, 0, "the file keeps it")
  assert_equal(#context.calls_named("setNotePool"), 2, "and the engine is not told")
  -- the next start reads the file back, on any tier
  h.write_performance_active(HIGH)
  load_strata({ data_subdir = subdir })
  assert_equal(local_value("S").lib.notes.pool(), 0, "read back")
end)

test("an unreadable or wrong-version notes.data gives the default and one line", function()
  local cases = {
    "return {", "ran_notes_data = true return {}", { version = 2, pool = 3 }, { version = 1, pool = 17 },
    { version = 1, pool = -1 }, { version = 1, pool = 2.5 }, { version = 1, pool = "3" }, { version = 1 },
    { version = 1, pool = math.huge }, { pool = 3 },  -- the last: a pool but no version
  }
  for index, case in ipairs(cases) do
    local context = load_strata({ before_init = with_notes_file(case) })
    assert_equal(local_value("S").lib.notes.pool(), 4, "case " .. index .. ": the tier's default")
    local lines = notes_lines(context)
    assert_equal(#lines, 1, "case " .. index .. ": one line")
    assert_true(lines[1]:find("^strata: notes.data") ~= nil, "naming the file: " .. lines[1])
  end
  assert_equal(rawget(_G, "ran_notes_data"), nil, "the file was never run")
end)

test("note_values gives a note, its frequency and its rate", function()
  load_strata()
  local notes = local_value("S").lib.notes
  local values = notes.note_values(1, 69)
  assert_equal(values.note, 69, "the note")
  assert_near(values.freq, 440, 1e-9, "A4 is 440 Hz")
  assert_near(values.rate, 2 ^ (9 / 12), 1e-9, "nine semitones above middle C")
  assert_near(notes.note_values(1, 60).rate, 1, 1e-12, "middle C plays at rate 1")
  assert_near(notes.note_values(1, 60.5).freq, 13.75 * 2 ^ ((60.5 - 9) / 12), 1e-9, "a fractional pitch")
  assert_equal(notes.note_values(1, 127).freq, 2000, "the voice's freq range's end")
  assert_equal(notes.note_values(1, 0).freq, 20, "and its start")
  assert_equal(notes.note_values(1, 0).rate, 0.25, "the slowest rate")
  assert_equal(notes.note_values(1, 108).rate, 4, "the fastest rate")
  for _, voice in ipairs({ 0, 8, 1.5, "1" }) do
    assert_equal(notes.note_values(voice, 60), nil, "no values for voice " .. tostring(voice))
  end
  for _, pitch in ipairs({ "60", 0 / 0, math.huge, -math.huge }) do
    assert_equal(notes.note_values(1, pitch), nil, "no values for pitch " .. tostring(pitch))
  end
end)

-------------------------------------------------------------------------------
-- The allocator (package 1b)
-------------------------------------------------------------------------------

-- A note for S.lib.notes.play: MIDI's, key `key`, velocity 0.5, parking,
-- with a set_own that logs set_own(pitch) among the engine calls, so its
-- order against them shows. fields overrides any of them
local function note(context, key, pitch, fields)
  local played = { owner = "midi", key = key, pitch = pitch, velocity = 0.5, park = true,
    set_own = function(own_pitch) table.insert(context.engine_calls, { name = "set_own", args = { own_pitch } }) end }
  for name, value in pairs(fields or {}) do played[name] = value end
  return played
end

local function play(context, voice, key, pitch, fields)
  return local_value("S").lib.notes.play(voice, note(context, key, pitch, fields))
end

-- The engine calls since the last clear, as "name(arg, ...)" with numbers to
-- 4 decimals, set_own included
local function call_text(call)
  local args = {}
  for index, value in ipairs(call.args) do
    args[index] = type(value) == "number" and (string.format("%.4f", value):gsub("%.?0+$", "")) or tostring(value)
    if args[index] == "-0" or args[index] == "" then args[index] = "0" end
  end
  return call.name .. "(" .. table.concat(args, ", ") .. ")"
end

local function calls(context)
  local texts = {}
  for _, call in ipairs(context.engine_calls) do table.insert(texts, call_text(call)) end
  return texts
end

local function names(context)
  local list = {}
  for _, call in ipairs(context.engine_calls) do table.insert(list, call.name) end
  return list
end

local function later(context, seconds) context.set_time(util.time() + seconds) end

local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

local function started(context)
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active and S.voices[2].active and not S.voices[3].active, "voices 1 and 2 run")
  return S
end

test("the first note on a voice is its own note, with today's messages", function()
  local context = load_strata()
  local S = started(context)
  -- what a start sends, as toggle_voice sends it
  toggle_voice(1)
  context.clear_engine_calls()
  toggle_voice(1)
  local start = names(context)
  assert_true(#start > 3, "a start sends its messages")
  toggle_voice(1)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 1, 60), 1, "slot 1")
  local sent = names(context)
  assert_equal(call_text(context.engine_calls[1]), "set_own(60)", "the pitch first")
  assert_equal(table.concat(sent, ",", 2, #sent - 1), table.concat(start, ","), "then the voice's start")
  assert_equal(call_text(context.engine_calls[#sent]), "retrigger(0, 0.5)", "then today's accent")
  assert_equal(#context.calls_named("noteOn") + #context.calls_named("noteExpression"), 0, "no note command")
  assert_true(S.voices[1].active, "the voice runs")
  assert_equal(S.lib.notes.held(1), 1); assert_equal(S.lib.notes.pool_used(), 0)
  -- on a running voice: the pitch, then the accent
  context.clear_engine_calls()
  assert_equal(play(context, 2, 1, 62), 1)
  assert_equal(table.concat(calls(context), " "), "set_own(62) retrigger(1, 0.5)")
end)

test("quiet: slot 1 only sets the pitch, and the caller starts and accents the voice", function()
  local context = load_strata()
  local S = started(context)
  context.clear_engine_calls()
  assert_equal(play(context, 3, 1, 60, { quiet = true }), 1, "slot 1")
  assert_equal(table.concat(calls(context), " "), "set_own(60)", "the pitch alone")
  assert_true(not S.voices[3].active, "the voice is the caller's to start")
  assert_equal(S.lib.notes.held(3), 1, "the note is recorded")
  toggle_voice(3)
  assert_equal(S.lib.notes.held(3), 1, "and kept through the caller's start")
  context.clear_engine_calls()
  assert_equal(play(context, 1, 1, 64, { quiet = true }), 1)
  assert_equal(table.concat(calls(context), " "), "set_own(64)", "a running voice: no accent")
  -- an extra slot plays as without quiet
  context.clear_engine_calls()
  assert_equal(play(context, 3, 2, 64, { quiet = true }), 2)
  assert_equal(table.concat(names(context), " "), "noteExpression noteOn")
end)

test("a second note is an extra note: its expression, then its noteOn", function()
  local context = load_strata()
  local S = started(context)
  play(context, 1, 1, 60)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 2, 64), 2, "slot 2")
  local sent = context.engine_calls
  assert_equal(#sent, 2, "two messages")
  assert_equal(call_text(sent[1]), "noteExpression(0, 1, 1, 1, 0, 0, 0)", "the neutral expression first")
  assert_equal(sent[2].name, "noteOn")
  assert_equal(sent[2].args[1], 0); assert_equal(sent[2].args[2], 1); assert_equal(sent[2].args[3], 64)
  assert_near(sent[2].args[4], 329.6276, 1e-3, "E4's frequency")
  assert_near(sent[2].args[5], 1.259921, 1e-6, "four semitones above middle C")
  assert_equal(sent[2].args[6], 0.5, "the velocity")
  assert_equal(S.lib.notes.held(1), 2); assert_equal(S.lib.notes.pool_used(), 1)
  -- a note's own expression goes with its start, and what it lacks is neutral
  context.clear_engine_calls()
  assert_equal(play(context, 1, 3, 67, { expression = { bend = 2, size = -0.5 } }), 3)
  assert_equal(call_text(context.engine_calls[1]), "noteExpression(0, 2, 2, 1, 0, -0.5, 0)")
  local listed = S.lib.notes.slots(1)
  assert_equal(#listed, 3, "three slots in use")
  assert_equal(listed[2].slot, 2); assert_equal(listed[2].owner, "midi"); assert_equal(listed[2].key, 2)
  assert_equal(listed[2].pitch, 64); assert_equal(listed[2].held, true); assert_equal(listed[2].parked, false)
  listed[2].pitch = 0
  assert_equal(S.lib.notes.slots(1)[2].pitch, 64, "slots gives copies")
  assert_equal(S.lib.notes.find(1, "midi", 3), 3); assert_equal(S.lib.notes.find(1, "seq", 3), nil, "another owner")
  -- a refused note plays nothing
  context.clear_engine_calls()
  for _, bad in ipairs({ { owner = "grid" }, { pitch = 0 / 0 }, { set_own = 1 }, { velocity = "1" }, { key = 0 / 0 },
      { park = 1 }, { expression = 2 } }) do
    assert_equal(play(context, 1, 9, 60, bad), nil, "refused")
  end
  assert_equal(S.lib.notes.play(8, note(context, 9, 60)), nil, "no voice 8")
  assert_equal(#context.engine_calls, 0, "nothing sent")
end)

test("the same owner and key again re-pitches its slot and creates nothing", function()
  local context = load_strata()
  local S = started(context)
  play(context, 1, 1, 60); play(context, 1, 2, 64)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 2, 67), 2, "its slot again")
  assert_equal(table.concat(names(context), " "), "noteOn", "re-pitched and accented, its expression unchanged")
  assert_equal(context.engine_calls[1].args[2], 1); assert_equal(context.engine_calls[1].args[3], 67)
  assert_equal(S.lib.notes.slots(1)[2].pitch, 67)
  assert_equal(S.lib.notes.held(1), 2); assert_equal(S.lib.notes.pool_used(), 1, "no slot more")
  context.clear_engine_calls()
  assert_equal(play(context, 1, 1, 62), 1, "the own note's key again")
  assert_equal(table.concat(calls(context), " "), "set_own(62) retrigger(0, 0.5)")
end)

test("a free slot is the one whose note ended longest ago", function()
  local context = load_strata()
  local S = started(context)
  params:set("v1_note_cap", 4)
  play(context, 1, 1, 60)
  for key = 2, 4 do assert_equal(play(context, 1, key, 60 + key), key) end
  for _, key in ipairs({ 3, 2, 4 }) do
    later(context, 0.1)
    S.lib.notes.release(1, "midi", key)
  end
  later(context, 0.1)
  for index, slot in ipairs({ 3, 2, 4 }) do
    assert_equal(play(context, 1, 10 + index, 70 + index), slot, "note " .. index)
  end
end)

test("the pool full: the oldest held extra note anywhere is cut for the new one", function()
  local context = load_strata()
  local S = started(context)
  S.lib.notes.set_pool(2)
  play(context, 1, 1, 60); play(context, 1, 2, 64)
  later(context, 0.01)
  play(context, 2, 1, 60); play(context, 2, 2, 64)
  assert_equal(S.lib.notes.pool_used(), 2)
  later(context, 0.1)
  context.clear_engine_calls()
  assert_equal(play(context, 2, 3, 67), 3, "voice 2's next free slot")
  assert_equal(table.concat(names(context), " "), "noteOff noteExpression noteOn")
  assert_equal(call_text(context.engine_calls[1]), "noteOff(0, 1, 1)", "voice 1's slot 2 cut first")
  assert_equal(context.engine_calls[2].args[1], 1); assert_equal(context.engine_calls[2].args[2], 2)
  assert_equal(context.engine_calls[3].args[1], 1); assert_equal(context.engine_calls[3].args[2], 2)
  assert_equal(S.lib.notes.held(1), 1, "voice 1 keeps its own note")
  assert_equal(S.lib.notes.pool_used(), 2)
  context.clear_engine_calls()
  S.lib.notes.release(1, "midi", 2)
  assert_equal(#context.engine_calls, 0, "the stolen note's release sends nothing")
end)

test("the cap reached: the voice's oldest extra note is re-pitched in place", function()
  local context = load_strata()
  local S = started(context)
  params:set("v1_note_cap", 3)
  play(context, 1, "a", 60)
  play(context, 1, "b", 62)
  later(context, 0.01)
  play(context, 1, "c", 64)
  later(context, 0.1)
  context.clear_engine_calls()
  assert_equal(play(context, 1, "d", 65), 2, "b's slot")
  assert_equal(table.concat(names(context), " "), "noteExpression noteOn", "no noteOff")
  assert_equal(context.engine_calls[2].args[2], 1); assert_equal(context.engine_calls[2].args[3], 65)
  assert_equal(S.lib.notes.find(1, "midi", "b"), nil); assert_equal(S.lib.notes.find(1, "midi", "d"), 2)
  assert_equal(S.lib.notes.held(1), 3); assert_equal(S.lib.notes.pool_used(), 2)
  -- a cap lowered under held notes keeps them; the next note steals under the new cap
  params:set("v1_note_cap", 2)
  later(context, 0.1)
  assert_equal(play(context, 1, "e", 67), 2, "the slot under the cap")
  assert_equal(S.lib.notes.find(1, "midi", "c"), 3, "the note above it stays")
end)

test("nothing to steal: slot 1 is re-pitched, the newest note winning", function()
  local context = load_strata()
  local S = started(context)
  -- a cap of 1
  params:set("v1_note_cap", 1)
  play(context, 1, 1, 60)
  later(context, 0.1)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 2, 64), 1)
  assert_equal(table.concat(calls(context), " "), "set_own(64) retrigger(0, 0.5)", "3.4's messages")
  assert_equal(S.lib.notes.find(1, "midi", 1), nil, "the older note lost the slot")
  assert_equal(S.lib.notes.find(1, "midi", 2), 1)
  -- a pool of 0 with a cap of 8
  S.lib.notes.set_pool(0)
  play(context, 2, 1, 60)
  later(context, 0.1)
  context.clear_engine_calls()
  assert_equal(play(context, 2, 2, 64), 1)
  assert_equal(table.concat(calls(context), " "), "set_own(64) retrigger(1, 0.5)")
  -- a pool held wholly by a locked voice
  S.lib.notes.set_pool(2)
  play(context, 3, 1, 60); play(context, 3, 2, 62); play(context, 3, 3, 64)
  toggle_lock(3)
  later(context, 0.1)
  params:set("v1_note_cap", 8)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 3, 67), 1, "past its own note")
  assert_equal(table.concat(calls(context), " "), "set_own(67) retrigger(0, 0.5)", "no noteOff")
  assert_equal(S.lib.notes.held(3), 3, "the locked voice keeps its notes")
end)

test("a note younger than the cut time is never stolen", function()
  local context = load_strata()
  local S = started(context)
  S.lib.notes.set_pool(2)
  play(context, 1, 1, 60); play(context, 1, 2, 62); play(context, 1, 3, 64)
  later(context, 0.01)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 4, 65), 1, "branch 6")
  assert_equal(table.concat(calls(context), " "), "set_own(65) retrigger(0, 0.5)", "no noteOff")
  later(context, 0.05)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 5, 67), 4, "a never used slot")
  assert_equal(table.concat(names(context), " "), "noteOff noteExpression noteOn", "a steal")
  assert_equal(call_text(context.engine_calls[1]), "noteOff(0, 1, 1)")
end)

-- ruling 32: a chord's further notes take only free room
test("extra_only: a play takes only a free extra slot or its own held slot, and is refused otherwise", function()
  local context = load_strata()
  local S = started(context)
  local notes = S.lib.notes
  local function refused(voice, key, what)
    local held, used = notes.held(voice), notes.pool_used()
    context.clear_engine_calls()
    assert_equal(play(context, voice, key, 70, { extra_only = true }), nil, what .. ": refused")
    assert_equal(#context.engine_calls, 0, what .. ": nothing sent, set_own included")
    assert_equal(notes.find(voice, "midi", key), nil, what .. ": nothing recorded")
    assert_equal(notes.held(voice), held, what .. ": the held count stands")
    assert_equal(notes.pool_used(), used, what .. ": and the pool's")
  end
  -- never slot 1 (branch 2)
  refused(3, 1, "a stopped voice, its slot 1 free")
  context.clear_engine_calls()
  assert_equal(play(context, 1, 1, 60, { extra_only = true }), 2, "a running voice, nothing held: an extra slot")
  assert_equal(table.concat(names(context), " "), "noteExpression noteOn", "branch 3's messages")
  play(context, 2, 1, 60); play(context, 2, 2, 62)
  notes.release(2, "midi", 1)
  assert_equal(notes.slots(2)[1].parked, true, "voice 2's own note parked")
  context.clear_engine_calls()
  assert_equal(play(context, 2, 3, 64, { extra_only = true }), 3, "beside a parked own note: an extra slot")
  assert_equal(table.concat(names(context), " "), "noteExpression noteOn", "no set_own, unpark or retrigger")
  assert_equal(notes.slots(2)[1].parked, true, "the own note stays parked")
  -- its own held slot again, whichever it is (branch 1)
  context.clear_engine_calls()
  assert_equal(play(context, 2, 3, 65, { extra_only = true }), 3, "an extra slot again")
  assert_equal(table.concat(names(context), " "), "noteOn", "re-pitched in place")
  play(context, 1, 9, 60)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 9, 61, { extra_only = true }), 1, "slot 1 again")
  assert_equal(table.concat(calls(context), " "), "set_own(61) retrigger(0, 0.5)", "as the own note")
  -- never a steal in place (branch 5) or across voices (branch 4), never slot 1 (branch 6)
  params:set("v1_note_cap", 3)
  assert_equal(play(context, 1, 2, 62, { extra_only = true }), 3, "room under the cap of 3")
  later(context, 0.1)
  refused(1, 3, "the cap reached, every note old enough to steal")
  assert_equal(notes.pool_used(), 4, "the pool full: two notes on voice 1, two on voice 2")
  refused(2, 4, "the pool full, old notes on another voice")
  notes.set_pool(0)
  refused(2, 5, "a pool of 0")
  -- extra_only is a boolean or absent
  context.clear_engine_calls()
  assert_equal(play(context, 1, 6, 67, { extra_only = 0 }), nil, "refused: not a boolean")
  assert_equal(#context.engine_calls, 0)
end)

test("release: an extra note gets noteOff; the own note parks only under others and only when asked", function()
  local context = load_strata()
  local S = started(context)
  local notes = S.lib.notes
  -- an extra note
  play(context, 1, 1, 60); play(context, 1, 2, 64)
  context.clear_engine_calls()
  notes.release(1, "midi", 2)
  assert_equal(table.concat(calls(context), " "), "noteOff(0, 1, 0)")
  assert_equal(notes.held(1), 1); assert_equal(notes.pool_used(), 0)
  -- the own note asked to park, another held
  play(context, 2, 1, 60); play(context, 2, 2, 64)
  context.clear_engine_calls()
  notes.release(2, "midi", 1)
  assert_equal(table.concat(calls(context), " "), "noteOff(1, 0, 0)", "parked")
  assert_equal(notes.slots(2)[1].slot, 1); assert_equal(notes.slots(2)[1].parked, true)
  assert_equal(notes.slots(2)[1].held, false); assert_equal(notes.held(2), 1)
  -- the own note not asked to park
  play(context, 3, 1, 60, { park = false }); play(context, 3, 2, 64)
  context.clear_engine_calls()
  notes.release(3, "midi", 1)
  assert_equal(#context.engine_calls, 0, "nothing sent")
  assert_equal(notes.slots(3)[1].slot, 2, "slot 1 is free"); assert_equal(notes.held(3), 1)
  -- the own note alone
  play(context, 4, 1, 60)
  context.clear_engine_calls()
  notes.release(4, "midi", 1)
  assert_equal(#context.engine_calls, 0, "nothing sent")
  assert_equal(#notes.slots(4), 0); assert_equal(notes.held(4), 0)
  -- an owner's notes, and an unknown key
  play(context, 5, 1, 60); play(context, 5, 2, 62, { owner = "seq" }); play(context, 5, 3, 64)
  context.clear_engine_calls()
  notes.release(5, "midi", 9)
  assert_equal(#context.engine_calls, 0, "an unknown key sends nothing")
  notes.release_owner(5, "midi")
  assert_equal(table.concat(calls(context), " "), "noteOff(4, 2, 0) noteOff(4, 0, 0)", "extras first, then the park")
  assert_equal(notes.held(5), 1); assert_equal(notes.find(5, "seq", 2), 2)
end)

test("a parked own note is the first choice for the next note", function()
  local context = load_strata()
  local S = started(context)
  play(context, 1, 1, 60); play(context, 1, 2, 64)
  S.lib.notes.release(1, "midi", 1)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 3, 67), 1)
  -- unparked, then accented: the stage's step gate and accent open only on retrigger (ruling 15)
  assert_equal(table.concat(calls(context), " "), "set_own(67) noteOn(0, 0, 67, 391.9954, 1.4983, 0.5) retrigger(0, 0.5)")
  assert_equal(S.lib.notes.slots(1)[1].parked, false)
  assert_equal(S.lib.notes.held(1), 2)
end)

test("quiet over a parked own note unparks it and leaves the accent to the caller", function()
  local context = load_strata()
  local S = started(context)
  play(context, 1, 1, 60); play(context, 1, 2, 64)
  S.lib.notes.release(1, "midi", 1)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 3, 67, { quiet = true }), 1)
  assert_equal(table.concat(calls(context), " "), "set_own(67) noteOn(0, 0, 67, 391.9954, 1.4983, 0.5)", "no retrigger")
  assert_equal(S.lib.notes.slots(1)[1].parked, false, "Lua and the engine agree: not parked")
  context.clear_engine_calls()
  assert_equal(play(context, 1, 3, 67), 1, "the same key again")
  assert_equal(table.concat(calls(context), " "), "set_own(67) retrigger(0, 0.5)", "no second noteOn")
end)

test("on a stopped voice slot 1 is always free: a quiet note never makes it refuse a key", function()
  local context = load_strata()
  local S = started(context)
  local notes = S.lib.notes
  assert_equal(play(context, 3, 1, 60, { quiet = true }), 1)  -- its caller never starts the voice
  local invariant
  for _, record in ipairs(S.registry.invariants) do if record.name == "notes" then invariant = record.fn end end
  assert_equal(invariant(), nil, "a stopped voice may hold a quiet note awaiting its caller's start")
  context.clear_engine_calls()
  assert_equal(play(context, 3, 2, 64, { quiet = true }), 1, "a second quiet note takes slot 1")
  assert_equal(table.concat(calls(context), " "), "set_own(64)")
  assert_equal(notes.find(3, "midi", 1), nil, "replacing the first"); assert_equal(notes.find(3, "midi", 2), 1)
  assert_true(not S.voices[3].active)
  context.clear_engine_calls()
  assert_equal(play(context, 3, 3, 67), 1, "a note not quiet takes slot 1 too")
  local sent = calls(context)
  assert_equal(sent[1], "set_own(67)")
  assert_equal(#context.calls_named("voiceOn"), 1, "and starts the voice")
  assert_equal(sent[#sent], "retrigger(2, 0.5)")
  assert_true(S.voices[3].active)
  assert_equal(notes.held(3), 1); assert_equal(notes.find(3, "midi", 3), 1); assert_equal(notes.pool_used(), 0)
  assert_equal(play(context, 3, 4, 69), 2, "a running voice gets its extra slot")
end)

test("a change of a voice's held count updates the voice list and asks for a redraw", function()
  local context = load_strata()
  local S = started(context)
  local lists, redraws = 0, 0
  local real_list, real_redraw = update_voice_list, request_redraw
  update_voice_list = function(...) lists = lists + 1; return real_list(...) end
  request_redraw = function(...) redraws = redraws + 1; return real_redraw(...) end
  local function changed(what, expected)
    assert_equal(lists > 0, expected, what .. ": the voice list")
    assert_equal(redraws > 0, expected, what .. ": a redraw")
    lists, redraws = 0, 0
  end
  play(context, 1, 1, 60); changed("the own note", true)
  play(context, 1, 2, 64); changed("an extra note", true)
  play(context, 1, 2, 65); changed("a held extra slot re-pitched", false)
  play(context, 1, 1, 62); changed("the held own note re-pitched", false)
  S.lib.notes.release(1, "midi", 2); changed("a release", true)
  play(context, 1, 2, 64); lists, redraws = 0, 0
  params:set("v1_freeze", 1); changed("a freeze's cuts", true)
  update_voice_list, request_redraw = real_list, real_redraw
end)

test("a voice stopped by anything forgets its notes", function()
  local context = load_strata()
  local S = started(context)
  play(context, 1, 1, 60); play(context, 1, 2, 64); play(context, 1, 3, 67)
  S.lib.notes.set_expression(1, 2, { bend = 2 })
  context.clear_engine_calls()
  toggle_voice(1)
  assert_equal(table.concat(names(context), " "), "voiceOff", "no noteOff: voiceOff ends them all")
  assert_equal(S.lib.notes.held(1), 0); assert_equal(S.lib.notes.pool_used(), 0)
  assert_equal(#S.lib.notes.slots(1), 0)
  S.lib.notes.release(1, "midi", 2)
  lfo_step(context)
  assert_equal(#context.calls_named("noteOff") + #context.calls_named("noteExpression"), 0, "nothing for it later")
  -- the next key starts the voice again on slot 1
  context.clear_engine_calls()
  assert_equal(play(context, 1, 2, 64), 1)
  assert_true(S.voices[1].active)
end)

test("a frozen synth voice plays rates from its freeze reference", function()
  local context = load_strata()
  local S = started(context)
  local notes = S.lib.notes
  params:set("v1_freq", 440)
  assert_equal(notes.freeze_reference(1), nil, "no reference unfrozen")
  params:set("v1_freeze", 1)
  assert_near(notes.freeze_reference(1), 69, 1e-9, "A4")
  play(context, 1, 1, 69)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 2, 76), 2)
  local on = context.calls_named("noteOn")[1]
  assert_equal(on.args[2], 1); assert_equal(on.args[3], 76)
  assert_near(on.args[4], 659.2551, 1e-3, "E5"); assert_near(on.args[5], 1.498307, 1e-6, "a fifth up")
  assert_equal(on.args[6], 0.5)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 1, 81), 1, "the own note again")
  assert_equal(table.concat(calls(context), " "), "set_own(81) noteOn(0, 0, 81, 880, 2, 0.5) retrigger(0, 0.5)")
  -- the reference stays through a freq change, and goes at the unfreeze
  params:set("v1_freq", 220)
  assert_near(notes.freeze_reference(1), 69, 1e-9, "kept")
  params:set("v1_freeze", 0)
  assert_equal(notes.freeze_reference(1), nil)
  assert_near(notes.note_values(1, 72).rate, 2, 1e-9, "C5 against middle C again")
  -- a buffer voice has none
  params:set("v2_source", 2); params:set("v2_freeze", 1)
  assert_equal(notes.freeze_reference(2), nil, "a buffer voice")
end)

test("a quiet play on a frozen synth voice sends its rate, and leaves the accent to the caller", function()
  local context = load_strata()
  local S = started(context)
  params:set("v1_freq", 440)
  params:set("v1_freeze", 1)
  context.clear_engine_calls()
  assert_equal(play(context, 1, 1, 81, { quiet = true }), 1)
  assert_equal(table.concat(calls(context), " "), "set_own(81) noteOn(0, 0, 81, 880, 2, 0.5)", "no retrigger")
end)

test("a quiet play on a stopped frozen synth voice leaves its rate to the start that follows", function()
  local context = load_strata()
  local S = started(context)
  params:set("v3_freq", 440)
  params:set("v3_freeze", 1)
  context.clear_engine_calls()
  assert_equal(play(context, 3, 1, 81, { quiet = true }), 1)
  assert_equal(table.concat(calls(context), " "), "set_own(81)", "nothing for a stopped voice but the pitch")
  toggle_voice(3)  -- the caller's start
  local sent, voice_on, note_on = calls(context), nil, nil
  for index, text in ipairs(sent) do
    if text:find("^voiceOn%(2,") then voice_on = index end
    if text:find("^noteOn%(") then note_on = index; assert_equal(text, "noteOn(2, 0, 81, 880, 2, 0.5)", "its rate") end
  end
  assert_true(voice_on ~= nil and note_on ~= nil and note_on > voice_on, "the noteOn after voiceOn")
  assert_equal(#context.calls_named("noteOn"), 1, "once")
  -- a real player's set_own moves the voice's freq: the start takes its
  -- reference from it, so the note plays the frozen sound as it is (rate 1)
  toggle_voice(4)
  params:set("v4_freq", 440)
  params:set("v4_freeze", 1)
  toggle_voice(4)
  local function set_freq(pitch) params:set("v4_freq", 440 * 2 ^ ((pitch - 69) / 12)) end
  context.clear_engine_calls()
  assert_equal(play(context, 4, 1, 81, { quiet = true, set_own = set_freq }), 1)
  assert_equal(#context.calls_named("noteOn"), 0, "nothing before the start")
  toggle_voice(4)
  sent, voice_on, note_on = calls(context), nil, nil
  for index, text in ipairs(sent) do
    if text:find("^voiceOn%(3,") then voice_on = index end
    if text:find("^noteOn%(") then note_on = index; assert_equal(text, "noteOn(3, 0, 81, 880, 1, 0.5)", "rate 1") end
  end
  assert_true(voice_on ~= nil and note_on ~= nil and note_on > voice_on, "the noteOn after voiceOn")
  assert_near(S.lib.notes.freeze_reference(4), 81, 1e-9, "the reference is the played pitch")
end)

test("a running voice's source switch sends no slot-0 noteOn, a recall's neither", function()
  local context = load_strata()
  local S = started(context)
  local function recall_source(option)
    S.scene_recall_in_progress = true
    params:set("v1_source", option)
    S.scene_recall_in_progress = false
  end
  for _, switch in ipairs({ function(option) params:set("v1_source", option) end, recall_source }) do
    params:set("v1_source", 2)
    params:set("v1_freeze", 1)
    play(context, 1, 1, 72)
    assert_equal(S.lib.notes.held(1), 1, "slot 1 held")
    context.clear_engine_calls()
    switch(S.constants.SOURCE_SYNTH)
    assert_equal(#context.calls_named("noteOn"), 0, "a source switch needs nothing from Lua")
    params:set("v1_freeze", 0)
    S.lib.notes.release(1, "midi", 1)
  end
end)

test("a voice that leaves the frozen synth state by another path never reuses its old reference", function()
  local context = load_strata()
  local S = started(context)
  local notes = S.lib.notes
  -- a recall's source switch runs no source-change hook: freeze stays 1, and no freeze-change hook runs
  local function recall_source(voice, option)
    S.scene_recall_in_progress = true
    params:set("v" .. voice .. "_source", option)
    S.scene_recall_in_progress = false
  end
  -- a running voice, no read in between
  params:set("v1_freq", 440)
  params:set("v1_freeze", 1)
  recall_source(1, 2)
  params:set("v1_freq", 220)
  recall_source(1, S.constants.SOURCE_SYNTH)
  assert_true(S.lib.freeze.is_frozen(1), "frozen all along")
  assert_near(notes.freeze_reference(1), 57, 1e-9, "a fresh reference, not the old 69")
  -- a stopped voice: its start takes a fresh one, and its scaleNote agrees
  params:set("v3_freq", 440)
  params:set("v3_freeze", 1)
  toggle_voice(3)
  assert_near(notes.freeze_reference(3), 69, 1e-9)
  toggle_voice(3)
  recall_source(3, 2)
  params:set("v3_freq", 220)
  recall_source(3, S.constants.SOURCE_SYNTH)
  context.clear_engine_calls()
  toggle_voice(3)
  local scale
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 2 and call.args[2] == "scaleNote" then scale = call.args[3] end
  end
  assert_near(scale, 57, 1e-9, "the start's scaleNote is the fresh reference")
  assert_near(notes.freeze_reference(3), 57, 1e-9, "a fresh reference at the start")
end)

test("a synth voice's extra notes are cut and forgotten when it freezes", function()
  local context = load_strata()
  local S = started(context)
  params:set("v1_freq", 220)
  play(context, 1, 1, 60); play(context, 1, 2, 64); play(context, 1, 3, 67)
  context.clear_engine_calls()
  params:set("v1_freeze", 1)
  local offs = context.calls_named("noteOff")
  assert_equal(#offs, 2)
  assert_equal(call_text(offs[1]), "noteOff(0, 1, 1)"); assert_equal(call_text(offs[2]), "noteOff(0, 2, 1)")
  assert_equal(S.lib.notes.held(1), 1); assert_equal(S.lib.notes.pool_used(), 0)
  local scale = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "scaleNote" then table.insert(scale, call.args[3]) end
  end
  assert_near(scale[#scale], 57, 1e-9, "scaleNote is the reference")
  context.clear_engine_calls()
  params:set("v1_freeze", 0)
  assert_equal(#context.calls_named("noteOff"), 0, "an unfreeze cuts nothing")
  -- a buffer voice keeps its notes
  params:set("v2_source", 2)
  play(context, 2, 1, 60); play(context, 2, 2, 64)
  context.clear_engine_calls()
  params:set("v2_freeze", 1)
  assert_equal(#context.calls_named("noteOff"), 0, "a buffer voice's notes are streams already")
  assert_equal(S.lib.notes.held(2), 2)
end)

test("the flush sends at most 16 a step, newest values, no note starved, none for an ended note", function()
  local context = load_strata()
  local S = started(context)
  local notes = S.lib.notes
  notes.set_pool(16)
  local counts = { 8, 8, 3, 1 }  -- 20 notes, 16 of them extra
  for voice, count in ipairs(counts) do
    for key = 1, count do play(context, voice, key, 60 + key) end
  end
  assert_equal(notes.pool_used(), 16)
  local counted = {}
  local real_count = S.lib.engine_sync.count_sends
  S.lib.engine_sync.count_sends = function(n) table.insert(counted, n); return real_count(n) end
  local marked = {}
  for voice, count in ipairs(counts) do
    for slot = 1, count do
      assert_equal(notes.set_expression(voice, slot, { bend = 1 + #marked / 100 }), true)
      table.insert(marked, (voice - 1) .. "," .. (slot - 1))
    end
  end
  local function sent_keys()
    local keys = {}
    for _, call in ipairs(context.calls_named("noteExpression")) do
      table.insert(keys, call.args[1] .. "," .. call.args[2])
    end
    return keys
  end
  context.clear_engine_calls()
  lfo_step(context)
  assert_equal(table.concat(sent_keys(), " "), table.concat(marked, " ", 1, 16), "the first 16 marked")
  assert_equal(table.concat(counted, ","), "16", "counted in the budget")
  -- the first 16 are marked again: the 4 still waiting go first
  for index = 1, 16 do
    local voice, slot = marked[index]:match("(%d+),(%d+)")
    notes.set_expression(tonumber(voice) + 1, tonumber(slot) + 1, { amp = 0.5 })
  end
  context.clear_engine_calls()
  lfo_step(context)
  local second = sent_keys()
  assert_equal(#second, 16)
  assert_equal(table.concat(second, " ", 1, 4), table.concat(marked, " ", 17, 20), "none starved")
  context.clear_engine_calls()
  lfo_step(context)
  assert_equal(#sent_keys(), 4, "the rest at the next step")
  context.clear_engine_calls()
  lfo_step(context)
  assert_equal(#sent_keys(), 0, "nothing due")
  assert_equal(table.concat(counted, ","), "16,16,4", "each step's count")
  -- marked twice in a step: once, with the newest values, keeping what the second lacks
  notes.set_expression(1, 2, { bend = 1.5 })
  notes.set_expression(1, 2, { amp = 0.25, main = 2 })
  context.clear_engine_calls()
  lfo_step(context)
  assert_equal(table.concat(calls(context), " "), "noteExpression(0, 1, 1.5, 0.25, 0, 0, 1)", "main clipped to 1")
  -- a note released before the step sends nothing
  notes.set_expression(1, 3, { bend = 2 })
  notes.release(1, "midi", 3)
  context.clear_engine_calls()
  lfo_step(context)
  assert_equal(#context.calls_named("noteExpression"), 0, "an ended note")
  assert_equal(notes.set_expression(1, 3, { bend = 2 }), false, "an empty slot is not marked")
  S.lib.engine_sync.count_sends = real_count
end)

-- Ruling 36: what a slot holds can be read, so a note's later expression
-- is compared with what the engine has or will have
test("a slot's stored expression can be read, as a copy", function()
  local context = load_strata()
  local S = started(context)
  local notes = S.lib.notes
  play(context, 1, 1, 60)
  local own = notes.expression(1, 1)
  assert_equal(table.concat({ own.bend, own.amp, own.position, own.size, own.main }, " "), "1 1 0 0 0",
    "a note played with none: neutral")
  play(context, 1, 2, 64, { expression = { bend = 2, size = -0.5, amp = 3 } })
  local held = notes.expression(1, 2)
  assert_equal(table.concat({ held.bend, held.amp, held.position, held.size, held.main }, " "), "2 2 0 -0.5 0",
    "its first expression, clipped as stored")
  held.amp = 0
  assert_equal(notes.expression(1, 2).amp, 2, "a copy")
  notes.set_expression(1, 2, { amp = 0.5, main = 0.25 })
  held = notes.expression(1, 2)
  assert_equal(held.amp, 0.5, "a set expression, before the flush sends it"); assert_equal(held.main, 0.25)
  assert_equal(held.bend, 2, "and what the set kept")
  assert_equal(notes.expression(1, 3), nil, "an empty slot")
  notes.release(1, "midi", 2)
  assert_equal(notes.expression(1, 2), nil, "a released note's slot")
  for _, index in ipairs({ { 0, 1 }, { 8, 1 }, { 1.5, 1 }, { "1", 1 }, { 1, 0 }, { 1, 9 }, { 1, 1.5 }, { 1, "1" } }) do
    assert_equal(notes.expression(index[1], index[2]), nil, "no slot " .. tostring(index[1]) .. "," .. tostring(index[2]))
  end
end)

test("a smaller pool releases the newest held extra notes past it, then tells the engine", function()
  local context = load_strata()
  local S = started(context)
  assert_equal(context.calls_named("setNotePool")[1].args[1], 4, "the start tells the engine the pool")
  play(context, 1, 1, 60)
  for key = 2, 5 do later(context, 0.01); play(context, 1, key, 60 + key) end
  assert_equal(S.lib.notes.pool_used(), 4)
  context.clear_engine_calls()
  assert_equal(S.lib.notes.set_pool(2), true)
  assert_equal(table.concat(calls(context), " "), "noteOff(0, 4, 0) noteOff(0, 3, 0) setNotePool(2)")
  assert_equal(S.lib.notes.pool_used(), 2); assert_equal(S.lib.notes.find(1, "midi", 3), 3)
  context.clear_engine_calls()
  S.lib.notes.set_pool(6)
  assert_equal(table.concat(calls(context), " "), "setNotePool(6)", "a larger pool releases nothing")
  h.write_performance_active(HIGH)
  context = load_strata()
  assert_equal(context.calls_named("setNotePool")[1].args[1], 8, "high's default")
end)

test("the note cap is a row of VOICE's notes section and is not a scene field", function()
  local context = load_strata()
  local S = started(context)
  local param = params:lookup_param("v1_note_cap")
  assert_equal(param.name, "note cap")
  assert_equal(params:get("v1_note_cap"), S.constants.NOTE_SLOTS, "8 by default")
  local min, max = param_range("v1_note_cap")
  assert_equal(min, 1); assert_equal(max, 8)
  for voice = 1, S.constants.NUM_VOICES do
    local sections, cap_section = {}, nil
    for _, row in ipairs(voice_page_rows(voice)) do
      if row.selectable == false then table.insert(sections, row.section) end
      if row.param_id == "v" .. voice .. "_note_cap" then cap_section = row.section end
    end
    assert_equal(cap_section, "notes", "voice " .. voice)
    local order = table.concat(sections, ",")
    assert_true(order:find("notes,variation", 1, true) ~= nil, "notes just before variation: " .. order)
  end
  -- VOICE's layout tests and renders draw the row under the cursor on every voice
  local states = {}
  for _, state in ipairs(S.registry.pages[S.constants.UI_PAGES.index.VOICE].layout_states) do
    states[state.name] = state
  end
  for voice = 1, S.constants.NUM_VOICES do
    local state = states["v" .. voice .. " note cap"]
    assert_true(state ~= nil, "a layout state for voice " .. voice)
    state.setup(context)
    assert_equal(S.selected_voice, voice)
    local rows, cursor = S.lib.pages_voice.sync_cursor()
    assert_equal(rows[cursor].param_id, "v" .. voice .. "_note_cap", "the cursor on the row")
  end
  params:set("v1_note_cap", 3)
  capture_scene(1)
  local extras = S.scenes[1].data.voices[1].extras
  assert_true(extras.freeze ~= nil, "a scene captures the extras")
  assert_equal(extras.note_cap, nil, "but not the note cap")
end)

-------------------------------------------------------------------------------
-- The envelope times (package 2g)
-------------------------------------------------------------------------------

test("attack and release default to each voice's times of 3.4", function()
  local context = load_strata()
  local S = started(context)
  local envelope = S.lib.notes.NOTES.envelope
  assert_equal(#envelope, S.constants.NUM_VOICES, "a pair per voice")
  for voice = 1, S.constants.NUM_VOICES do
    assert_near(params:get("v" .. voice .. "_attack"), envelope[voice][1], 1e-9, "voice " .. voice .. " attack")
    assert_near(params:get("v" .. voice .. "_release"), envelope[voice][2], 1e-9, "voice " .. voice .. " release")
  end
  assert_near(params:get("v1_attack"), 4, 1e-9); assert_near(params:get("v1_release"), 8, 1e-9)
  assert_near(params:get("v4_attack"), 8, 1e-9); assert_near(params:get("v4_release"), 12, 1e-9)
  assert_near(params:get("v6_attack"), 0.01, 1e-9); assert_near(params:get("v6_release"), 2, 1e-9)
  local a_min, a_max = param_range("v1_attack")
  local r_min, r_max = param_range("v1_release")
  assert_equal(a_min, 0.005); assert_equal(a_max, 30)
  assert_equal(r_min, 0.01); assert_equal(r_max, 30)
  for voice = 1, S.constants.NUM_VOICES do
    local rows = {}
    for _, row in ipairs(voice_page_rows(voice)) do rows[#rows + 1] = row.param_id or row.section end
    local text = table.concat(rows, ",")
    assert_true(text:find("v" .. voice .. "_note_cap,v" .. voice .. "_attack,v" .. voice .. "_release", 1, true)
      ~= nil, "attack and release follow note cap: " .. text)
  end
end)

test("they reach the engine as attackTime and releaseTime, at a turn and at a start", function()
  local context = load_strata()
  local S = started(context)
  context.clear_engine_calls()
  params:set("v2_attack", 0.05)
  params:set("v2_release", 3)
  local sent = context.calls_named("setVoiceParam")
  assert_equal(#sent, 2, "one message each")
  assert_equal(sent[1].args[1], 1); assert_equal(sent[1].args[2], "attackTime"); assert_near(sent[1].args[3], 0.05, 1e-9)
  assert_equal(sent[2].args[2], "releaseTime"); assert_near(sent[2].args[3], 3, 1e-9)
  -- a stopped voice sends nothing at a turn
  context.clear_engine_calls()
  params:set("v3_attack", 0.5)
  assert_equal(#context.calls_named("setVoiceParam"), 0, "stopped: nothing")
  -- a start sends both after voiceOn
  context.clear_engine_calls()
  toggle_voice(3)
  local order, seen = {}, {}
  for index, call in ipairs(context.engine_calls) do
    if call.name == "voiceOn" then order.on = index end
    if call.name == "setVoiceParam" and (call.args[2] == "attackTime" or call.args[2] == "releaseTime") then
      seen[call.args[2]] = call.args[3]; order[call.args[2]] = index
    end
  end
  assert_near(seen.attackTime, 0.5, 1e-9, "the start sends the attack"); assert_near(seen.releaseTime, 6, 1e-9, "and the release")
  assert_true(order.attackTime > order.on and order.releaseTime > order.on, "after voiceOn")
  -- a sync of a running voice sends both
  context.clear_engine_calls()
  sync_voice_values_to_engine(2)
  local synced = {}
  for _, call in ipairs(context.calls_named("setVoiceParam")) do synced[call.args[2]] = call.args[3] end
  assert_near(synced.attackTime, 0.05, 1e-9, "a sync sends the attack"); assert_near(synced.releaseTime, 3, 1e-9)
end)

test("a 3.4 scene recalls each voice's default times", function()
  local context = load_strata()
  local S = started(context)
  params:set("v1_attack", 9)
  capture_scene(1)
  assert_near(S.scenes[1].data.voices[1].extras.attack, 9, 1e-9, "a scene captures the attack")
  local scene = {populated = true, data = S.scenes[1].data}
  for voice = 1, S.constants.NUM_VOICES do
    scene.data.voices[voice].extras.attack = nil
    scene.data.voices[voice].extras.release = nil
  end
  migrate_scene(scene, 6)
  local envelope = S.lib.notes.NOTES.envelope
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(scene.data.voices[voice].extras.attack, envelope[voice][1], "voice " .. voice .. " attack")
    assert_equal(scene.data.voices[voice].extras.release, envelope[voice][2], "voice " .. voice .. " release")
  end
  scene.data.voices[1].extras.attack = 2
  migrate_scene(scene, 6)
  assert_equal(scene.data.voices[1].extras.attack, 2, "a stored value is kept (idempotent)")
end)

test("the engine's default times equal NOTES.envelope", function()
  load_strata()
  local file = assert(io.open("lib/engine/StrataVoiceDefs.sc"))
  local text = file:read("*a"); file:close()
  local pairs_found = {}
  for attack, release in text:gmatch("attackTime=([%d%.]+), releaseTime=([%d%.]+);") do
    pairs_found[#pairs_found + 1] = {tonumber(attack), tonumber(release)}
  end
  local envelope = local_value("S").lib.notes.NOTES.envelope
  assert_equal(#pairs_found, #envelope, "one default pair per voice def")
  for voice = 1, #envelope do
    assert_equal(pairs_found[voice][1], envelope[voice][1], "voice " .. voice .. " attack")
    assert_equal(pairs_found[voice][2], envelope[voice][2], "voice " .. voice .. " release")
  end
  local a_lo, a_hi = text:match("attackTimeRange { %^#%[([%d%.]+), ([%d%.]+)%] }")
  local r_lo, r_hi = text:match("releaseTimeRange { %^#%[([%d%.]+), ([%d%.]+)%] }")
  local a_min, a_max = param_range("v1_attack")
  local r_min, r_max = param_range("v1_release")
  assert_equal(tonumber(a_lo), a_min); assert_equal(tonumber(a_hi), a_max)
  assert_equal(tonumber(r_lo), r_min); assert_equal(tonumber(r_hi), r_max)
end)

end

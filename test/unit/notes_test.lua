-- test/unit/notes_test.lua
-- The notes module (lib/notes.lua, S.lib.notes), 3.5's skeleton (design
-- §0.1, §2.2, §2.3): the pool setting and notes.data, note_values, and every
-- voice at one note.
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
  assert_equal(#context.engine_calls, 0, "nothing is sent yet")
  -- a write that fails sets nothing
  os.execute("mkdir -p '" .. notes_path(context) .. ".part/inside'")  -- the .part is a folder: the write fails
  assert_equal(notes.set_pool(5), false, "not set")
  assert_equal(notes.pool(), 0, "the old value")
  assert_equal(S.lib.data_files.read(notes_path(context)).pool, 0, "the file keeps it")
  -- the next start reads the file back, on any tier
  h.write_performance_active(HIGH)
  load_strata({ data_subdir = subdir })
  assert_equal(local_value("S").lib.notes.pool(), 0, "read back")
end)

test("an unreadable or wrong-version notes.data gives the default and one line", function()
  local cases = {
    "return {", "ran_notes_data = true return {}", { version = 2, pool = 3 }, { version = 1, pool = 17 },
    { version = 1, pool = -1 }, { version = 1, pool = 2.5 }, { version = 1, pool = "3" }, { version = 1 },
    { version = 1, pool = math.huge }, { 5 },
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

end

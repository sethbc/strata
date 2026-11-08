-- test/unit/ui_cursors_test.lua
-- The shared cursors (lib/ui/cursors.lua: S.cursors, S.lib.ui_cursors) and
-- the VOICE page's rows and ring groups (lib/ui/voice_rows.lua:
-- voice_page_rows, voice_page_group), and SCENES_FIELDS
-- Run alone: lua test/run.lua ui_cursors

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- The param ids of a list of rows, label rows as "[<section>]"
local function row_ids(rows)
  local ids = {}
  for index, row in ipairs(rows) do
    ids[index] = row.selectable and row.param_id or ("[" .. tostring(row.section) .. "]")
  end
  return table.concat(ids, " ")
end

-- The row index of a param id in rows
local function row_of(rows, param_id)
  for index, row in ipairs(rows) do
    if row.param_id == param_id then return index end
  end
  error("no row for " .. param_id)
end

-- 3.1's rows only: rows without the registered voice params' rows
-- (S.registry.voice_params' voice_rows) and without a section left with no
-- field, so 3.1's layout is checked exactly whatever is registered
local function built_in(rows)
  local registered = {}
  for _, record in ipairs(local_value("S").registry.voice_params) do
    for _, key in ipairs(record.voice_rows and record.voice_rows.rows or {}) do registered[key] = true end
  end
  local kept = {}
  for _, row in ipairs(rows) do
    local key = row.param_id and row.param_id:match("^v%d+_(.+)$")
    if not (key and registered[key]) then table.insert(kept, row) end
  end
  local result = {}
  for index, row in ipairs(kept) do
    local next_row = kept[index + 1]
    if row.selectable ~= false or (next_row and next_row.selectable ~= false) then table.insert(result, row) end
  end
  return result
end

-- The param id of the first and of the last selectable row of rows
local function first_field(rows)
  for _, row in ipairs(rows) do
    if row.selectable then return row.param_id end
  end
end
local function last_field(rows)
  for index = #rows, 1, -1 do
    if rows[index].selectable then return rows[index].param_id end
  end
end

local function count_selectable(rows)
  local count = 0
  for _, row in ipairs(rows) do
    if row.selectable then count = count + 1 end
  end
  return count
end

-- v<i>_ prefixed ids of keys, space separated
local function ids(voice_idx, keys)
  local list = {}
  for index, key in ipairs(keys) do list[index] = "v" .. voice_idx .. "_" .. key end
  return table.concat(list, " ")
end

local GRAIN_KEYS = { "grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_env", "grain_mode" }
local CROSSMOD_KEYS = { "mod_speed", "mod_source_1", "mod_amp_amt_1", "mod_freq_amt_1", "mod_source_2",
  "mod_amp_amt_2", "mod_freq_amt_2", "mod_source_3", "mod_amp_amt_3", "mod_freq_amt_3" }

local function expected_rows(voice_idx, synth_keys, mix_keys)
  local parts = {}
  if synth_keys then table.insert(parts, "[synth] " .. ids(voice_idx, synth_keys)) end
  table.insert(parts, "[grain] " .. ids(voice_idx, GRAIN_KEYS))
  table.insert(parts, "[crossmod] " .. ids(voice_idx, CROSSMOD_KEYS))
  table.insert(parts, "[mix] " .. ids(voice_idx, mix_keys))
  return table.concat(parts, " ")
end

test("VOICE rows for a synth voice", function()
  load_strata()
  local rows = voice_page_rows(1)
  assert_equal(row_ids(built_in(rows)), expected_rows(1, { "freq", "rq", "noise", "mod1", "mod2" },
    { "source", "amp", "pan" }), "voice 1's rows")
  assert_equal(#built_in(rows), 28, "3.1's four label rows and 24 fields")
  local kinds = { [params.tCONTROL] = "control", [params.tNUMBER] = "number", [params.tOPTION] = "option",
    [params.tBINARY] = "binary" }
  for index, row in ipairs(rows) do
    assert_true(type(row.section) == "string", "row " .. index .. " names its section")
    assert_true(type(row.label) == "string" and row.label ~= "", "row " .. index .. " has a label")
    if row.selectable then
      local param = params:lookup_param(row.param_id)  -- errors on an unknown id
      assert_equal(row.kind, kinds[param.t], row.param_id .. "'s kind")
      assert_equal(row.label, param.name, row.param_id .. "'s label is the param's name")
    else
      assert_equal(row.selectable, false, "label row " .. index .. " is not selectable")
      assert_equal(row.label, row.section, "label row " .. index .. " shows its section name")
      assert_equal(row.param_id, nil, "label row " .. index .. " has no param")
    end
  end
  assert_equal(rows[row_of(rows, "v1_freq")].kind, "control")
  assert_equal(rows[row_of(rows, "v1_grain_env")].kind, "option")
  assert_equal(rows[row_of(rows, "v1_mod_source_2")].kind, "number")
  assert_equal(rows[row_of(rows, "v1_source")].kind, "option")
end)

test("VOICE rows for a buffer and an input voice", function()
  load_strata()
  local C = local_value("S").constants
  params:set("v2_source", C.SOURCE_SYNTH + 1)  -- buf 1
  assert_equal(row_ids(built_in(voice_page_rows(2))), expected_rows(2, { "buf_pos", "buf_rate", "buf_scan" },
    { "source", "amp", "pan" }), "a buffer voice's synth section holds its buffer params")
  params:set("v2_source", C.SOURCE_INPUT)
  local rows = voice_page_rows(2)
  assert_equal(row_ids(built_in(rows)), expected_rows(2, nil, { "source", "amp", "pan" }),
    "an input voice has no synth section, label row included")
  assert_equal(built_in(rows)[1].section, "grain", "an input voice's built-in rows start with the grain label")
  assert_equal(rows[1].selectable, false, "the rows start with a label")
  for _, row in ipairs(rows) do assert_true(row.param_id ~= "v2_freq", "no synth row") end
end)

test("the Sub voice has no pan row", function()
  load_strata()
  local rows = voice_page_rows(4)
  assert_equal(row_ids(built_in(rows)), expected_rows(4, { "freq", "drift" }, { "source", "amp" }), "voice 4's rows")
  for _, row in ipairs(rows) do
    assert_true(row.param_id ~= "v4_pan", "no pan row for the Sub voice")
  end
end)

test("the voice cursor is a row index on a selectable row", function()
  load_strata()
  local S = local_value("S")
  local rows = voice_page_rows(1)
  assert_equal(S.cursors.voice, 2, "row 1 is the synth label")
  assert_equal(rows[S.cursors.voice].param_id, "v1_freq", "the cursor starts on the first field")
  assert_equal(S.cursors.seq_step, 1)
  assert_equal(S.cursors.scene, 1)
  local grain_size = row_of(rows, "v1_grain_size")
  local synth_fields = 0  -- the selectable rows before grain size
  for index = 1, grain_size - 1 do
    if rows[index].selectable then synth_fields = synth_fields + 1 end
  end
  S.lib.ui_cursors.move("voice", synth_fields)
  assert_equal(rows[S.cursors.voice].param_id, "v1_grain_size", "past the synth fields: the grain label is skipped")
  assert_equal(S.cursors.voice, grain_size)
  S.lib.ui_cursors.move("voice", -1)
  assert_equal(rows[S.cursors.voice].param_id, rows[grain_size - 2].param_id, "back over the grain label")
  assert_true(rows[grain_size - 1].selectable == false, "the grain label")
  S.lib.ui_cursors.move("voice", 100)
  assert_equal(rows[S.cursors.voice].param_id, last_field(rows), "the cursor stops at the last row")
  S.lib.ui_cursors.move("voice", -100)
  assert_equal(S.cursors.voice, 2, "and at the first field, never on the label")
end)

test("the voice cursor moves on the selected voice's rows", function()
  load_strata()
  local S = local_value("S")
  S.selected_voice = 4
  S.lib.ui_cursors.move("voice", 100)
  local rows = voice_page_rows(4)
  assert_equal(S.cursors.voice, #rows, "the last row of voice 4")
  assert_equal(rows[S.cursors.voice].param_id, last_field(rows), "voice 4's last field")
  assert_equal(last_field(built_in(rows)), "v4_amp", "3.1's last row of voice 4 is its level")
end)

test("voice_page_group returns the cursor's group of four selectable rows", function()
  load_strata()
  -- on every voice's whole rows (registered ones included): the group of
  -- the cursor's k-th selectable row is ceil(k / 4), its rows the
  -- selectables 4g-3 .. 4g (fewer only in the last group)
  for voice_idx = 1, local_value("S").constants.NUM_VOICES do
    local all_rows = voice_page_rows(voice_idx)
    local selectable = {}
    for index, row in ipairs(all_rows) do
      if row.selectable then table.insert(selectable, index) end
    end
    for k, cursor in ipairs(selectable) do
      local group, indices = voice_page_group(all_rows, cursor)
      assert_equal(group, math.ceil(k / 4), "voice " .. voice_idx .. " field " .. k .. "'s group")
      local expected = {}
      for position = 4 * group - 3, math.min(4 * group, #selectable) do table.insert(expected, selectable[position]) end
      assert_equal(table.concat(indices, ","), table.concat(expected, ","), "voice " .. voice_idx .. " group " .. group)
    end
  end
  -- 3.1's rows (voice_page_group takes any rows)
  local rows = built_in(voice_page_rows(1))
  local function group_ids(group_rows, indices)
    local list = {}
    for index, row_index in ipairs(indices) do list[index] = group_rows[row_index].param_id end
    return table.concat(list, " ")
  end
  local group, indices = voice_page_group(rows, row_of(rows, "v1_grain_density"))
  assert_equal(group, 2, "v1_grain_density is selectable row 7: group 2")
  assert_equal(group_ids(rows, indices), "v1_mod2 v1_grain_size v1_grain_density v1_grain_pitch")
  group, indices = voice_page_group(rows, 2)
  assert_equal(group, 1)
  assert_equal(group_ids(rows, indices), "v1_freq v1_rq v1_noise v1_mod1", "the first group")
  -- voice 1 has 24 fields: its sixth group is full
  group, indices = voice_page_group(rows, #rows)
  assert_equal(group, 6)
  assert_equal(group_ids(rows, indices), "v1_mod_freq_amt_3 v1_source v1_amp v1_pan")
  -- voice 2 (FM) has 23 fields: its last group has three
  local fm_rows = built_in(voice_page_rows(2))
  assert_equal(count_selectable(fm_rows), 23)
  group, indices = voice_page_group(fm_rows, #fm_rows)
  assert_equal(group, 6)
  assert_equal(group_ids(fm_rows, indices), "v2_source v2_amp v2_pan", "voice 2's last group has three rows")
  -- voice 4 (Sub, no pan) has 20 fields, so 5 full groups; on input it has
  -- 18, and its last group two rows
  local sub_rows = built_in(voice_page_rows(4))
  assert_equal(count_selectable(sub_rows), 20)
  assert_equal(#select(2, voice_page_group(sub_rows, #sub_rows)), 4)
  params:set("v4_source", local_value("S").constants.SOURCE_INPUT)
  sub_rows = built_in(voice_page_rows(4))
  group, indices = voice_page_group(sub_rows, #sub_rows)
  assert_equal(group, 5)
  assert_equal(group_ids(sub_rows, indices), "v4_source v4_amp", "voice 4's last group on input has two rows")
end)

test("cursors clamp when the selected voice's rows shrink", function()
  load_strata()
  local S = local_value("S")
  local rows = voice_page_rows(1)
  S.lib.ui_cursors.move("voice", 1)
  assert_equal(rows[S.cursors.voice].param_id, "v1_rq", "the cursor sits in the synth section")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  S.lib.ui_cursors.clamp_all()
  rows = voice_page_rows(1)
  assert_true(S.cursors.voice <= #rows, "the cursor is a row of the shrunk list")
  assert_true(rows[S.cursors.voice].selectable, "on a selectable row")
  local group, indices = voice_page_group(rows, S.cursors.voice)
  assert_equal(group, 1, "the ring group follows the cursor")
  local holds_cursor = false
  for _, row_index in ipairs(indices) do
    assert_true(rows[row_index].selectable, "every ring row is selectable")
    if row_index == S.cursors.voice then holds_cursor = true end
  end
  assert_true(holds_cursor, "the ring group holds the cursor's row")

  -- the cursor on the last row (pan) when the synth section goes: it stays
  -- on the last row of the shorter list
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  S.lib.ui_cursors.move("voice", 100)
  local synth_rows = voice_page_rows(1)
  assert_equal(S.cursors.voice, #synth_rows)
  params:set("v1_source", S.constants.SOURCE_INPUT)
  S.lib.ui_cursors.clamp_all()
  rows = voice_page_rows(1)
  assert_equal(S.cursors.voice, #rows)
  assert_equal(rows[S.cursors.voice].param_id, last_field(rows))

  -- a cursor on a label row moves to the first field; the selected voice
  -- changing to one with fewer rows clamps too
  S.cursors.voice = 1
  S.lib.ui_cursors.clamp_all()
  assert_equal(voice_page_rows(1)[S.cursors.voice].param_id, first_field(voice_page_rows(1)))
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  S.cursors.voice = #voice_page_rows(1)
  S.selected_voice = 4
  S.lib.ui_cursors.clamp_all()
  rows = voice_page_rows(4)
  assert_equal(S.cursors.voice, #rows)
  assert_true(rows[S.cursors.voice].selectable)
end)

test("every screen and arc redraw clamps the cursors first", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.cursors.voice, S.cursors.seq_step, S.cursors.scene = 99, 40, 0
  redraw()
  assert_equal(S.cursors.voice, #voice_page_rows(1), "redraw() clamps the voice cursor")
  assert_equal(S.cursors.seq_step, S.constants.PATTERN_LENGTH, "and the step cursor")
  assert_equal(S.cursors.scene, 1, "and the scene cursor")
  context.arc.plug(1)
  S.cursors.voice = 1
  arc_redraw()
  assert_equal(S.cursors.voice, 2, "arc_redraw() clamps the voice cursor")
end)

test("the scene cursor covers eight slots and four fields", function()
  load_strata()
  local S = local_value("S")
  local C = S.constants
  assert_equal(table.concat(C.SCENES_FIELDS, " "),
    "scene_transition_time scene_sequencer_enabled scene_sequence_length scene_duration")
  for _, param_id in ipairs(C.SCENES_FIELDS) do params:lookup_param(param_id) end
  S.lib.ui_cursors.move("scene", 50); assert_equal(S.cursors.scene, 12)
  assert_equal(S.cursors.scene, C.NUM_SCENES + #C.SCENES_FIELDS)
  S.lib.ui_cursors.move("scene", -3); assert_equal(S.cursors.scene, 9, "stop 9 is the first field")
  S.lib.ui_cursors.move("scene", -50); assert_equal(S.cursors.scene, 1)
end)

test("the step cursor stays on the pattern's steps", function()
  load_strata()
  local S = local_value("S")
  S.lib.ui_cursors.move("seq_step", 3); assert_equal(S.cursors.seq_step, 4)
  S.lib.ui_cursors.move("seq_step", 100); assert_equal(S.cursors.seq_step, S.constants.PATTERN_LENGTH)
  S.lib.ui_cursors.move("seq_step", -100); assert_equal(S.cursors.seq_step, 1)
  local moved, problem = pcall(S.lib.ui_cursors.move, "nowhere", 1)
  assert_true(not moved and tostring(problem):find("nowhere", 1, true), "an unknown cursor is an error")
end)

-- The param id under the voice cursor after S.lib.ui_cursors.sync("voice"),
-- checking that sync returns the selected voice's current rows and the cursor
local function synced_voice_param(S)
  local rows, cursor = S.lib.ui_cursors.sync("voice")
  assert_equal(row_ids(rows), row_ids(voice_page_rows(S.selected_voice)), "sync returns the selected voice's rows")
  assert_equal(cursor, S.cursors.voice, "sync puts S.cursors.voice on the cursor it returns")
  return rows[cursor].param_id
end

test("sync keeps the voice cursor on its anchored param when the rows change", function()
  load_strata()
  local S = local_value("S")
  local rows, cursor = S.lib.ui_cursors.place("voice", row_of(voice_page_rows(1), "v1_grain_pitch"))
  assert_equal(rows[cursor].param_id, "v1_grain_pitch", "place returns the rows and the placed cursor")
  assert_equal(S.cursors.voice, cursor)
  params:set("v1_source", S.constants.SOURCE_INPUT)
  assert_equal(synced_voice_param(S), "v1_grain_pitch", "grain pitch when the synth section goes")
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  assert_equal(synced_voice_param(S), "v1_grain_pitch", "and when it comes back")
  S.selected_voice = 2
  assert_equal(synced_voice_param(S), "v2_grain_pitch", "the same param of another voice")
  -- a param the rows lack: clamped from the anchored index, then found again
  S.selected_voice = 1
  S.lib.ui_cursors.place("voice", row_of(voice_page_rows(1), "v1_rq"))
  local anchored_index = S.cursors.voice
  params:set("v1_source", S.constants.SOURCE_INPUT)
  rows = voice_page_rows(1)
  assert_equal(select(2, S.lib.ui_cursors.sync("voice")), S.lib.ui_field_list.clamp(rows, anchored_index),
    "no rq on an input voice: clamped from rq's index")
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  assert_equal(synced_voice_param(S), "v1_rq", "rq again after input and back")
end)

test("sync anchors where the cursor is before any deliberate move", function()
  load_strata()
  local S = local_value("S")
  S.cursors.voice = row_of(voice_page_rows(1), "v1_grain_size")
  assert_equal(synced_voice_param(S), "v1_grain_size", "the first sync anchors on the cursor's row")
  S.cursors.voice = 2
  assert_equal(synced_voice_param(S), "v1_grain_size", "later bare writes are taken back to it")
end)

test("move sets the voice anchor and starts from the anchored param", function()
  load_strata()
  local S = local_value("S")
  S.lib.ui_cursors.move("voice", 1)
  assert_equal(voice_page_rows(1)[S.cursors.voice].param_id, "v1_rq")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  S.lib.ui_cursors.sync("voice")
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  assert_equal(synced_voice_param(S), "v1_rq", "the move anchored rq: found again after input and back")
  -- a move right after a source change, before any sync, goes on from the param
  S.lib.ui_cursors.place("voice", row_of(voice_page_rows(1), "v1_grain_pitch"))
  params:set("v1_source", S.constants.SOURCE_INPUT)
  S.lib.ui_cursors.move("voice", 1)
  local rows = voice_page_rows(1)
  assert_equal(rows[S.cursors.voice].param_id, rows[row_of(rows, "v1_grain_pitch") + 1].param_id,
    "the row after grain pitch on the input voice's rows")
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  assert_equal(synced_voice_param(S), rows[row_of(rows, "v1_grain_pitch") + 1].param_id, "and anchored there")
end)

test("a bare write and clamp_all never move the voice anchor", function()
  load_strata()
  local S = local_value("S")
  S.lib.ui_cursors.place("voice", row_of(voice_page_rows(1), "v1_pan"))
  S.cursors.voice = 2
  S.lib.ui_cursors.clamp_all()
  assert_equal(S.cursors.voice, 2, "clamp_all only clamps the index")
  assert_equal(synced_voice_param(S), "v1_pan", "sync takes it back to the anchored param")
  local cursor = S.cursors.voice
  for _ = 1, 3 do
    assert_equal(select(2, S.lib.ui_cursors.sync("voice")), cursor, "sync is idempotent")
  end
end)

test("sync and place are only for cursors over rows", function()
  load_strata()
  local S = local_value("S")
  for _, name in ipairs({ "seq_step", "scene", "nowhere" }) do
    local synced, problem = pcall(S.lib.ui_cursors.sync, name)
    assert_true(not synced and tostring(problem):find(name, 1, true), "sync(" .. name .. ") is an error")
    local placed
    placed, problem = pcall(S.lib.ui_cursors.place, name, 1)
    assert_true(not placed and tostring(problem):find(name, 1, true), "place(" .. name .. ") is an error")
  end
end)

test("the VOICE page's cursor functions are the cursor module's", function()
  load_strata()
  local S = local_value("S")
  local voice_page = S.lib.pages_voice
  voice_page.place_cursor(row_of(voice_page_rows(1), "v1_grain_spread"))
  assert_equal(synced_voice_param(S), "v1_grain_spread", "place_cursor anchors in the cursor module")
  S.lib.ui_cursors.place("voice", row_of(voice_page_rows(1), "v1_amp"))
  local rows, cursor = voice_page.sync_cursor()
  assert_equal(rows[cursor].param_id, "v1_amp", "sync_cursor reads the cursor module's anchor")
end)

test("the cursor and row functions live in their modules", function()
  load_strata()
  local S = local_value("S")
  assert_equal(type(S.lib.ui_cursors), "table", "S.lib.ui_cursors")
  assert_equal(type(S.lib.ui_voice_rows), "table", "S.lib.ui_voice_rows")
  for _, name in ipairs({ "voice_page_rows", "voice_page_group" }) do
    local source = debug.getinfo(rawget(_G, name), "S").source
    assert_true(source:sub(-#"lib/ui/voice_rows.lua") == "lib/ui/voice_rows.lua", name .. " is in lib/ui/voice_rows.lua")
  end
  local moved, problem = pcall(voice_page_rows, 0)
  assert_true(not moved and tostring(problem):find("voice", 1, true), "voice 0 is out of range")
  moved = pcall(voice_page_rows, S.constants.NUM_VOICES + 1)
  assert_true(not moved, "voice 8 is out of range")
end)
end

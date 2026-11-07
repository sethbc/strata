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
  assert_equal(row_ids(rows), expected_rows(1, { "freq", "rq", "noise", "mod1", "mod2" },
    { "source", "amp", "pan" }), "voice 1's rows")
  assert_equal(#rows, 28, "four label rows and 24 fields")
  local kinds = { [params.tCONTROL] = "control", [params.tNUMBER] = "number", [params.tOPTION] = "option" }
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
  assert_equal(row_ids(voice_page_rows(2)), expected_rows(2, { "buf_pos", "buf_rate", "buf_scan" },
    { "source", "amp", "pan" }), "a buffer voice's synth section holds its buffer params")
  params:set("v2_source", C.SOURCE_INPUT)
  local rows = voice_page_rows(2)
  assert_equal(row_ids(rows), expected_rows(2, nil, { "source", "amp", "pan" }),
    "an input voice has no synth section, label row included")
  assert_equal(rows[1].section, "grain", "an input voice's rows start with the grain label")
  assert_equal(rows[1].selectable, false)
end)

test("the Sub voice has no pan row", function()
  load_strata()
  local rows = voice_page_rows(4)
  assert_equal(row_ids(rows), expected_rows(4, { "freq", "drift" }, { "source", "amp" }), "voice 4's rows")
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
  S.lib.ui_cursors.move("voice", 5)
  assert_equal(rows[S.cursors.voice].param_id, "v1_grain_size", "five fields on: the grain label is skipped")
  assert_equal(S.cursors.voice, 8)
  S.lib.ui_cursors.move("voice", -1)
  assert_equal(rows[S.cursors.voice].param_id, "v1_mod2", "back over the grain label")
  S.lib.ui_cursors.move("voice", 100)
  assert_equal(rows[S.cursors.voice].param_id, "v1_pan", "the cursor stops at the last row")
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
  assert_equal(rows[S.cursors.voice].param_id, "v4_amp", "voice 4's last row is its level")
end)

test("voice_page_group returns the cursor's group of four selectable rows", function()
  load_strata()
  local rows = voice_page_rows(1)
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
  local fm_rows = voice_page_rows(2)
  assert_equal(count_selectable(fm_rows), 23)
  group, indices = voice_page_group(fm_rows, #fm_rows)
  assert_equal(group, 6)
  assert_equal(group_ids(fm_rows, indices), "v2_source v2_amp v2_pan", "voice 2's last group has three rows")
  -- voice 4 (Sub, no pan) has 20 fields, so 5 full groups; on input it has
  -- 18, and its last group two rows
  local sub_rows = voice_page_rows(4)
  assert_equal(count_selectable(sub_rows), 20)
  assert_equal(#select(2, voice_page_group(sub_rows, #sub_rows)), 4)
  params:set("v4_source", local_value("S").constants.SOURCE_INPUT)
  sub_rows = voice_page_rows(4)
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
  assert_equal(S.cursors.voice, 28)
  params:set("v1_source", S.constants.SOURCE_INPUT)
  S.lib.ui_cursors.clamp_all()
  rows = voice_page_rows(1)
  assert_equal(S.cursors.voice, #rows)
  assert_equal(rows[S.cursors.voice].param_id, "v1_pan")

  -- a cursor on a label row moves to the first field; the selected voice
  -- changing to one with fewer rows clamps too
  S.cursors.voice = 1
  S.lib.ui_cursors.clamp_all()
  assert_equal(voice_page_rows(1)[S.cursors.voice].param_id, "v1_grain_size")
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  S.cursors.voice = 28
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

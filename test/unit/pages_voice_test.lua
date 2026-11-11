-- test/unit/pages_voice_test.lua
-- The VOICE page (lib/pages/voice.lua); its rings are in arc_pages_test.lua,
-- its rows and ring groups (voice_page_rows, voice_page_group) in
-- ui_cursors_test.lua
-- Run alone: lua test/run.lua pages_voice

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, hint_text, texts_on_row, text_span, tap = h.show_page, h.hint_text, h.texts_on_row, h.text_span, h.tap

-- The page's layout (lib/pages/voice.lua): the voice and section line at
-- y 16, field labels from x 3 (section labels at x 0), values right-aligned
-- at x 124, the ring group's marks 1 px wide at x 0
local SECTION_Y = 16
local FIELD_X = 3
local VALUE_RIGHT = 124
local MARK_X = 0

local function started_voice_page()
  local context = load_strata(); finish_startup(context)
  show_page("VOICE")
  return context, local_value("S")
end

-- The param id under the VOICE cursor
local function cursor_param(S)
  return voice_page_rows(S.selected_voice)[S.cursors.voice].param_id
end

-- Put the VOICE cursor on param_id (a row of the selected voice), as a
-- deliberate move, and redraw
local function put_cursor(S, param_id)
  local index = S.lib.pages_voice.row_of(param_id)
  assert_true(index, "no VOICE row " .. param_id)
  S.lib.pages_voice.place_cursor(index)
  redraw()
  return index
end

-- The drawn field label text and the value drawn on the same row
local function drawn_row(context, label)
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == FIELD_X and entry.text == label then
      local value
      for _, other in ipairs(texts_on_row(context, entry.y)) do
        if other.align == "right" and other.x == VALUE_RIGHT then value = other end
      end
      return entry, value
    end
  end
end

local function trimmed(text) return (text:gsub("%s+$", "")) end

-- The "<section> <k>/<n>" text VOICE shows for param_id, from the selected
-- voice's voice_page_rows (registered sections and rows included)
local function section_text(S, param_id)
  local sections, cursor_section, position = 0, nil, nil
  for _, row in ipairs(voice_page_rows(S.selected_voice)) do
    if row.selectable == false then sections = sections + 1 end
    if row.param_id == param_id then cursor_section, position = row.section, sections end
  end
  assert_true(cursor_section, "no VOICE row " .. param_id)
  return cursor_section .. " " .. position .. "/" .. sections
end

-- The selected voice's sections in order, each with its first and last
-- field's param id
local function voice_sections(S)
  local sections = {}
  for _, row in ipairs(voice_page_rows(S.selected_voice)) do
    if row.selectable == false then
      table.insert(sections, { name = row.section })
    else
      local section = sections[#sections]
      section.first = section.first or row.param_id
      section.last = row.param_id
    end
  end
  return sections
end

-- ALT+K2 acts on release (#557): a quick press randomizes the cursor's
-- section (or undoes), a press held past the hold time (0.5 s) resets the row
local HELD_SECONDS = 0.6
local function quick_alt_k2() key(1, 1); tap(2); key(1, 0) end
local function held_alt_k2(context)
  key(1, 1); key(2, 1); context.clock.run_for(HELD_SECONDS); key(2, 0); key(1, 0)
end

-- Every param's value, by id
local function all_param_values()
  local values = {}
  for _, param in ipairs(params.params) do
    if param.id and param.t ~= params.tSEPARATOR and param.t ~= params.tGROUP then values[param.id] = params:get(param.id) end
  end
  return values
end

-- The ranges VOICE's sections draw from (#557's plan), by param key; nil
-- for a synthesis param (its whole controlspec, as MAIN's randomize) and for
-- loop_length (0.05 to 1 - its new start, checked apart)
local function draw_ranges(S)
  local ranges = {
    buf_pos = { 0, 1 }, buf_rate = { 0.5, 2 }, buf_scan = { -0.5, 0.5 }, loop_start = { 0, 0.75 },
    history = { 0, S.lib.history.max_seconds() },                          -- the tier's history
    grain_size = { 0.05, 0.35 }, grain_density = { 2, 40 }, grain_pitch = { 0.5, 2.5 }, grain_spread = { 0, 0.6 },
    mod_speed = { 0.2, 10 }, pan = { -0.8, 0.8 },
    reverse = { 0, 50 }, pitch_jitter = { 0, 6 }, pan_jitter = { 0, 0.5 }, size_jitter = { 0, 0.5 },
    interval_prob = { 0, 100 },
    filter_freq = { 100, 8000 }, filter_res = { 0, 0.7 }, delay_send = { 0, 0.6 }, reverb_send = { 0, 0.6 },
  }
  for slot = 1, S.constants.NUM_MOD_SLOTS do
    ranges["mod_amp_amt_" .. slot] = { -0.5, 0.5 }
    ranges["mod_freq_amt_" .. slot] = { -0.5, 0.5 }
  end
  for n = 1, S.constants.NUM_BOOKMARKS do ranges["bookmark_" .. n] = { 0, 1 } end
  return ranges
end

-- Each section a press randomizes, on voice 1 (Resonator): the source, the
-- cursor's param and the keys drawn (every other param stays); undo_section
-- is the undo's section where it is not the rows' (a buffer voice's synth
-- section holds an undo of its own). Option keys may draw their old option;
-- every other drawn key changes
local function section_cases(S)
  local crossmod, bookmarks = { "mod_speed" }, {}
  for slot = 1, S.constants.NUM_MOD_SLOTS do
    crossmod[#crossmod + 1] = "mod_amp_amt_" .. slot
    crossmod[#crossmod + 1] = "mod_freq_amt_" .. slot
  end
  for n = 1, S.constants.NUM_BOOKMARKS do bookmarks[n] = "bookmark_" .. n end
  return {
    { section = "synth", source = "synth", cursor = "freq", drawn = { "freq", "rq", "noise", "mod1", "mod2" } },
    { section = "synth", undo_section = "synth (buffer)", source = "buffer", cursor = "buf_scan",
      drawn = { "buf_pos", "buf_rate", "buf_scan", "loop_start", "loop_length" } },
    { section = "input", source = "input", cursor = "history", drawn = { "history" } },
    { section = "grain", source = "synth", cursor = "grain_mode",
      drawn = { "grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_env" } },
    { section = "crossmod", source = "synth", cursor = "mod_source_2", drawn = crossmod },
    { section = "mix", source = "synth", cursor = "amp", drawn = { "pan" } },
    { section = "variation", source = "synth", cursor = "intervals",
      drawn = { "reverse", "pitch_jitter", "pan_jitter", "size_jitter", "interval_prob" } },
    { section = "filter & sends", source = "synth", cursor = "filter_mix",
      drawn = { "filter_type", "filter_freq", "filter_res", "delay_send", "reverb_send" } },
    { section = "bookmarks", source = "buffer", cursor = "bookmark_3", drawn = bookmarks },
  }
end

-- The cases, from a loaded script's constants
local function loaded_section_cases()
  load_strata()
  return section_cases(local_value("S"))
end

local function case_source(S, source)
  if source == "buffer" then return S.constants.SOURCE_SYNTH + 1 end
  if source == "input" then return S.constants.SOURCE_INPUT end
  return S.constants.SOURCE_SYNTH
end

-- Register a record with one binary row, "v<i>_probe_switch", in the mix
-- section (run before init)
local function register_binary_row(S)
  local record = { name = "probe", count = 1, grain_keys = {}, scene_defaults = { probe_switch = 0 },
    discrete = { probe_switch = { 0, 1 } }, voice_rows = { section = "mix", rows = { "probe_switch" } }, fader = false }
  function record.add(voice_idx)
    S.lib.params_setup.add_voice_extra(voice_idx, record, "probe_switch",
      { type = "binary", name = "probe switch", behavior = "toggle", default = 0 })
  end
  S.register_voice_params(record)
end

test("VOICE draws the section and its position at the top right", function()
  local context, S = started_voice_page()
  put_cursor(S, "v1_grain_density")
  local found
  local expected = section_text(S, "v1_grain_density")
  for _, entry in ipairs(texts_on_row(context, SECTION_Y)) do
    if entry.text == expected then found = entry end
  end
  assert_true(found, "VOICE shows " .. expected)
  assert_true(expected:find("^grain 2/"), "a synth voice's grain section is the second")
  assert_equal(found.align, "right", "right-aligned")
  assert_equal(found.x, VALUE_RIGHT, "at the values' right edge")
  local voice_text = texts_on_row(context, SECTION_Y)[1]
  assert_equal(voice_text.x, 0, "the selected voice at the left")
  assert_equal(voice_text.text, "1+ reso", "number, running mark and short name")
  -- an input voice has no synth section
  params:set("v1_source", S.constants.SOURCE_INPUT)
  redraw()
  for _, section in ipairs(voice_sections(S)) do
    assert_true(section.name ~= "synth", "an input voice has no synth section")
  end
  expected = section_text(S, "v1_grain_density")
  assert_true(h.screen_shows(context, expected), "VOICE shows " .. expected)
  -- crossmod and mix, and a locked, stopped voice
  put_cursor(S, "v1_mod_speed")
  assert_true(h.screen_shows(context, section_text(S, "v1_mod_speed")), "crossmod")
  put_cursor(S, "v1_amp")
  assert_true(h.screen_shows(context, section_text(S, "v1_amp")), "mix")
  toggle_lock(1); toggle_voice(1); redraw()
  assert_equal(texts_on_row(context, SECTION_Y)[1].text, "1- reso [L]", "stopped and locked")
end)

test("VOICE's section position counts come from voice_page_rows", function()
  -- a registered row in grain and a registered section: the counts follow
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    local record = { name = "probe", count = 1, scene_defaults = { probe = 0 },
      voice_rows = { section = "grain", rows = { "probe" } }, fader = false }
    function record.add(voice_idx)
      S.lib.params_setup.add_voice_extra(voice_idx, record, "probe",
        { type = "control", name = "probe", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
    end
    S.register_voice_params(record)
    local section = { name = "probe sect", count = 1, scene_defaults = { probe_level = 0 },
      voice_rows = { section = "probe sect", rows = { "probe_level" } }, fader = false }
    function section.add(voice_idx)
      S.lib.params_setup.add_voice_extra(voice_idx, section, "probe_level",
        { type = "control", name = "probe level", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
    end
    S.register_voice_params(section)
  end })
  finish_startup(context)
  show_page("VOICE")
  local S = local_value("S")
  local synth_sections = #voice_sections(S)
  assert_equal(voice_sections(S)[synth_sections].name, "probe sect", "the registered section, after mix")
  put_cursor(S, "v1_grain_density")
  local expected = section_text(S, "v1_grain_density")
  assert_equal(expected, "grain 2/" .. synth_sections, "from the rows")
  assert_true(h.screen_shows(context, expected), "VOICE shows " .. expected)
  put_cursor(S, "v1_probe")
  assert_true(h.screen_shows(context, section_text(S, "v1_probe")), "the registered row's section")
  put_cursor(S, "v1_probe_level")
  assert_true(h.screen_shows(context, "probe sect " .. synth_sections .. "/" .. synth_sections), "the registered section")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  put_cursor(S, "v1_grain_density")
  expected = section_text(S, "v1_grain_density")
  local grain_position
  for position, section in ipairs(voice_sections(S)) do
    assert_true(section.name ~= "synth", "an input voice has no synth section")
    if section.name == "grain" then grain_position = position end
  end
  assert_equal(expected, "grain " .. grain_position .. "/" .. #voice_sections(S), "an input voice's grain")
  assert_true(h.screen_shows(context, expected), "VOICE shows " .. expected)
end)

-- A MIDI-mapped param (norns.pmap.data, as lua/core/pmap.lua's pmap.new makes
-- it, with echo on) edited from the norns echoes its new value to the
-- controller, as ParamSet:delta does (#519): Binary:set sends nothing itself
test("E3 on a binary VOICE row echoes its value to a MIDI-mapped controller", function()
  local context = load_strata({ before_init = function() register_binary_row(local_value("S")) end })
  finish_startup(context)
  local controller = context.midi.plug(1)
  norns.pmap.data["v1_probe_switch"] = { dev = 1, ch = 2, cc = 21, in_lo = 0, in_hi = 127,
    out_lo = 0, out_hi = 1, echo = true, value = 0 }
  show_page("VOICE")
  local S = local_value("S")
  put_cursor(S, "v1_probe_switch")
  enc(3, 1)
  assert_equal(#controller.sent, 1, "one message to the controller")
  assert_equal(controller.sent[1][2], 21, "on its cc")
  assert_equal(controller.sent[1][3], 127, "the on value, scaled to the map's range")
  assert_equal(norns.pmap.data["v1_probe_switch"].value, 127, "the map keeps the value, as norns' does")
  enc(3, -1)
  assert_equal(controller.sent[2][3], 0, "off")
end)

test("E3 on a binary VOICE row sets it on and off", function()
  local context = load_strata({ before_init = function() register_binary_row(local_value("S")) end })
  finish_startup(context)
  show_page("VOICE")
  local S = local_value("S")
  put_cursor(S, "v1_probe_switch")
  assert_equal(voice_page_rows(1)[S.cursors.voice].kind, "binary", "a binary row")
  assert_equal(params:get("v1_probe_switch"), 0)
  local _, value = drawn_row(context, "probe switch")
  assert_equal(value.text, "off", "shown as off")
  enc(3, 1); assert_equal(params:get("v1_probe_switch"), 1, "+ turns it on")
  enc(3, 3); assert_equal(params:get("v1_probe_switch"), 1, "more + keeps it on")
  redraw()
  _, value = drawn_row(context, "probe switch")
  assert_equal(value.text, "on", "shown as on")
  enc(3, -1); assert_equal(params:get("v1_probe_switch"), 0, "- turns it off")
  enc(3, -2); assert_equal(params:get("v1_probe_switch"), 0, "more - keeps it off")
  key(1, 1); enc(3, 1); key(1, 0)
  assert_equal(params:get("v1_probe_switch"), 1, "ALT+E3 too")
  held_alt_k2(context)
  assert_equal(params:get("v1_probe_switch"), 0, "ALT+K2 held resets it to its default")
  redraw()
  h.assert_screen_layout(context, "VOICE on a binary row")
end)

test("E2 moves through fields and on into the next section", function()
  local context, S = started_voice_page()
  assert_equal(cursor_param(S), "v1_freq", "the cursor starts on the first field")
  enc(2, 1)
  assert_equal(cursor_param(S), "v1_rq")
  enc(2, 4)
  assert_equal(cursor_param(S), "v1_grain_size", "past the synth section's end into grain (the label takes no stop)")
  enc(2, -1)
  assert_equal(cursor_param(S), "v1_mod2", "and back")
  enc(2, -50)
  assert_equal(cursor_param(S), "v1_freq", "stops at the first field")
  enc(2, 100)
  local sections = voice_sections(S)
  assert_equal(cursor_param(S), sections[#sections].last, "stops at the last field")
  -- E3 edits the field under the cursor, ALT+E3 a tenth as far
  put_cursor(S, "v1_amp")
  local amp = params:get("v1_amp")
  enc(3, 1)
  local step = params:get("v1_amp") - amp
  assert_true(step > 0, "E3 raises the field")
  key(1, 1)
  local before = params:get("v1_amp")
  enc(3, 10)
  key(1, 0)
  assert_near(params:get("v1_amp") - before, step, 1e-6, "ALT+E3 ten detents move as far as one")
  assert_equal(cursor_param(S), "v1_amp", "E3 leaves the cursor")
  redraw()
  local label = drawn_row(context, "amp")
  assert_equal(label.level, 15, "the cursor row is bright")
  local other = drawn_row(context, "pan")
  assert_equal(other.level, 4, "the other rows dim")
end)

test("K2 and K3 jump to the previous and next section's first field", function()
  local _, S = started_voice_page()
  enc(2, 1)
  assert_equal(cursor_param(S), "v1_rq")
  tap(3); assert_equal(cursor_param(S), "v1_grain_size", "K3: grain")
  tap(3); assert_equal(cursor_param(S), "v1_mod_speed", "K3: crossmod")
  tap(3); assert_equal(cursor_param(S), "v1_source", "K3: mix")
  -- on through any later sections to the last, where K3 stays
  local sections = voice_sections(S)
  for _ = 1, #sections do tap(3) end
  assert_equal(cursor_param(S), sections[#sections].first, "K3 in the last section stays")
  put_cursor(S, "v1_source")
  enc(2, 1)
  assert_equal(cursor_param(S), "v1_amp")
  tap(2); assert_equal(cursor_param(S), "v1_mod_speed", "K2: crossmod")
  enc(2, 3)
  tap(2); assert_equal(cursor_param(S), "v1_grain_size", "K2 from inside crossmod: grain")
  tap(2); assert_equal(cursor_param(S), "v1_freq", "K2: synth")
  enc(2, 2)
  tap(2); assert_equal(cursor_param(S), "v1_freq", "K2 in the first section: its first field")
  -- an input voice: no synth section, so K2 stops at its first section
  -- (grain, or a registered section before it)
  params:set("v1_source", S.constants.SOURCE_INPUT)
  put_cursor(S, "v1_grain_size")
  tap(3); assert_equal(cursor_param(S), "v1_mod_speed", "input: K3 from grain to crossmod")
  sections = voice_sections(S)
  for _ = 1, #sections do tap(2) end
  assert_equal(cursor_param(S), sections[1].first, "input: K2 stops at the first section")
  assert_true(sections[1].name ~= "synth", "which is not synth")
end)

test("values use the param's own string with its unit, cut to fit", function()
  local context, S = started_voice_page()
  put_cursor(S, "v1_grain_size")
  local label, value = drawn_row(context, "grain size")
  assert_true(label and value, "the grain size row and its value")
  assert_equal(value.text, trimmed(params:string("v1_grain_size")), "the param's own string")
  put_cursor(S, "v1_freq")
  label, value = drawn_row(context, "freq")
  assert_equal(value.text, trimmed(params:string("v1_freq")), "freq's own string")
  assert_true(value.text:match(" Hz$"), "with its unit")
  -- mod sources show the voice's number and short name
  params:set("v1_mod_source_3", 3)
  put_cursor(S, "v1_mod_source_3")
  label, value = drawn_row(context, "mod source 3")
  assert_equal(value.text, "3 fold", "voice 3 by name")
  params:set("v1_mod_source_3", 0)
  redraw()
  label, value = drawn_row(context, "mod source 3")
  assert_equal(value.text, "none")
  -- a value too long for the space beside its label is cut, never overlaps
  local spread = params:lookup_param("v1_grain_spread")
  spread.formatter = function() return "a value far too long for this row of the screen" end
  put_cursor(S, "v1_grain_spread")
  label, value = drawn_row(context, "position spread")
  assert_true(#value.text > 0 and #value.text < #"a value far too long for this row of the screen", "cut")
  assert_equal(value.text, ("a value far too long for this row of the screen"):sub(1, #value.text), "from the end")
  local _, label_right = text_span(label)
  local value_left = text_span(value)
  assert_true(value_left >= label_right + 4, "at least 4 px after the label")
  spread.formatter = nil
end)

test("ALT+K2 on a mapped binary VOICE row sends one CC with its default (#519)", function()
  local context = load_strata({ before_init = function() register_binary_row(local_value("S")) end })
  finish_startup(context)
  local controller = context.midi.plug(1)
  show_page("VOICE")
  local S = local_value("S")
  put_cursor(S, "v1_probe_switch")
  enc(3, 1)
  norns.pmap.data["v1_probe_switch"] = { dev = 1, ch = 1, cc = 22, in_lo = 0, in_hi = 127,
    out_lo = 0, out_hi = 1, echo = true, value = 127 }
  held_alt_k2(context)
  assert_equal(params:get("v1_probe_switch"), 0, "reset to its default")
  assert_equal(#controller.sent, 1, "one message to the controller")
  assert_equal(controller.sent[1][3], 0, "the default's value")
end)

test("ALT+K2 held resets the field to its default; ALT+K3 locks", function()
  local context, S = started_voice_page()
  put_cursor(S, "v1_grain_spread")
  params:set("v1_grain_spread", 0.9)
  key(1, 1)
  key(2, 1); context.clock.run_for(HELD_SECONDS)
  assert_near(params:get("v1_grain_spread"), 0.9, 1e-9, "nothing happens while K2 is down")
  key(2, 0)
  assert_near(params:get("v1_grain_spread"), param_default("v1_grain_spread"), 1e-9, "ALT+K2 held resets the field")
  assert_true(math.abs(params:get("v1_grain_spread") - 0.9) > 0.01, "away from 0.9")
  assert_equal(local_value("undo"), nil, "a reset holds no undo")
  -- an option row too
  put_cursor(S, "v1_grain_env")
  params:set("v1_grain_env", 3)
  key(2, 1); context.clock.run_for(HELD_SECONDS); key(2, 0)
  assert_equal(params:get("v1_grain_env"), param_default("v1_grain_env"), "an option row resets")
  -- a locked voice's row resets too (a locked voice can still be edited)
  toggle_lock(1)
  params:set("v1_grain_env", 3)
  key(2, 1); context.clock.run_for(HELD_SECONDS); key(2, 0)
  assert_equal(params:get("v1_grain_env"), param_default("v1_grain_env"), "a locked voice's row resets")
  toggle_lock(1)
  assert_true(not S.frozen[1], "voice 1 starts unlocked")
  tap(3)
  assert_true(S.frozen[1], "ALT+K3 locks the selected voice")
  tap(3)
  assert_true(not S.frozen[1], "and unlocks it")
  key(1, 0)
  -- the plain keys never reset or lock
  params:set("v1_grain_env", 3)
  tap(2); tap(3)
  assert_equal(params:get("v1_grain_env"), 3, "K2 does not reset")
  assert_true(not S.frozen[1], "K3 does not lock")
end)

test("the VOICE cursor clamps when the synth section disappears", function()
  local context, S = started_voice_page()
  put_cursor(S, "v1_rq")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  redraw()
  local rows = voice_page_rows(1)
  assert_true(S.cursors.voice <= #rows and rows[S.cursors.voice].selectable, "the cursor is on a selectable row")
  local _, group_rows = voice_page_group(rows, S.cursors.voice)
  local holds_cursor = false
  for _, index in ipairs(group_rows) do holds_cursor = holds_cursor or index == S.cursors.voice end
  assert_true(holds_cursor, "the ring group follows the cursor")
  h.assert_screen_layout(context, "VOICE after the synth section went")
end)

test("a source or voice change keeps the cursor on its param when it still exists", function()
  local context, S = started_voice_page()
  put_cursor(S, "v1_grain_pitch")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  redraw()
  assert_equal(cursor_param(S), "v1_grain_pitch", "the rows shrank above the cursor; it keeps grain pitch")
  params:set("v1_source", 2)  -- buf 1
  redraw()
  assert_equal(cursor_param(S), "v1_grain_pitch", "the rows grew; it keeps grain pitch")
  -- E2 right after a switch, before any redraw, moves from the param
  params:set("v1_source", S.constants.SOURCE_INPUT)
  enc(2, 1)
  assert_equal(cursor_param(S), "v1_grain_spread", "E2 moves on from grain pitch")
  -- the switch while another page shows (its redraw clamps the cursor first)
  show_page("MAIN")
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  redraw()
  show_page("VOICE")
  assert_equal(cursor_param(S), "v1_grain_spread", "found again after MAIN's redraw clamped it")
  -- another selected voice: the same param of that voice
  S.selected_voice = 2
  redraw()
  assert_equal(cursor_param(S), "v2_grain_spread", "voice 2's grain spread")
  -- a param the new rows lack: clamped from where the cursor was
  put_cursor(S, "v2_index")
  S.selected_voice = 1
  redraw()
  local rows = voice_page_rows(1)
  assert_true(rows[S.cursors.voice].selectable, "a selectable row")
  assert_equal(rows[S.cursors.voice].section, "synth", "in voice 1's synth section")
end)

test("a change and back (A -> B -> A) returns the cursor to its param", function()
  local context, S = started_voice_page()
  -- source: synth -> input -> synth while MAIN shows (its redraws clamp)
  put_cursor(S, "v1_pan")
  show_page("MAIN")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  redraw()
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  redraw()
  show_page("VOICE")
  assert_equal(cursor_param(S), "v1_pan", "pan again after input and back")
  -- voice: 1 -> 4 (Sub, no pan) -> 1, as scrolling voices on MAIN does
  show_page("MAIN")
  for _ = 1, 3 do enc(2, 1); redraw() end
  assert_equal(S.selected_voice, 4, "MAIN's E2 selects voice 4")
  for _ = 1, 3 do enc(2, -1); redraw() end
  assert_equal(S.selected_voice, 1)
  show_page("VOICE")
  assert_equal(cursor_param(S), "v1_pan", "pan again after voice 4 and back")
  -- the param missing in between: on voice 4 the cursor is clamped, then
  -- back on voice 1 it is on pan again
  S.selected_voice = 4
  redraw()
  assert_true(voice_page_rows(4)[S.cursors.voice].selectable, "a selectable row on Sub")
  S.selected_voice = 1
  redraw()
  assert_equal(cursor_param(S), "v1_pan", "pan again")
  -- a deliberate move on voice 4 anchors there instead
  S.selected_voice = 4
  put_cursor(S, "v4_amp")
  S.selected_voice = 1
  redraw()
  assert_equal(cursor_param(S), "v1_amp", "the newer anchor wins")
end)

test("sync_cursor is idempotent and never moves the anchor", function()
  local context, S = started_voice_page()
  local voice_page = S.lib.pages_voice
  put_cursor(S, "v1_grain_pitch")
  local rows, cursor = voice_page.sync_cursor()
  assert_equal(rows[cursor].param_id, "v1_grain_pitch")
  for _ = 1, 3 do
    local again_rows, again = voice_page.sync_cursor()
    assert_equal(again, cursor, "the same cursor every call")
    assert_equal(#again_rows, #rows)
  end
  -- a bare write to S.cursors.voice is not a deliberate move
  S.cursors.voice = 2
  assert_equal(select(2, voice_page.sync_cursor()), cursor, "taken back to the anchored param")
  -- with the param gone, repeated calls agree too
  params:set("v1_source", S.constants.SOURCE_INPUT)
  local first = select(2, voice_page.sync_cursor())
  S.lib.ui_cursors.clamp_all()
  assert_equal(select(2, voice_page.sync_cursor()), first, "unchanged by clamp_all in between")
  assert_equal(cursor_param(S), "v1_grain_pitch")
end)

test("with an arc connected the screen marks the ring group", function()
  local context, S = started_voice_page()
  -- the marks drawn, as the labels of the rows they sit beside
  local function marked_labels()
    local labels = {}
    for _, rect in ipairs(context.screen.rects) do
      if rect.x == MARK_X and rect.w == 1 and rect.y > 9 then
        for _, entry in ipairs(context.screen.texts) do
          if entry.x == FIELD_X and entry.y >= rect.y and entry.y < rect.y + rect.h then
            table.insert(labels, entry.text)
          end
        end
      end
    end
    table.sort(labels)
    return table.concat(labels, ",")
  end
  put_cursor(S, "v1_grain_density")
  assert_equal(marked_labels(), "", "no marks without an arc")
  context.arc.plug(1)
  assert_true(S.arc_connected, "the arc is connected")
  redraw()
  local rows = voice_page_rows(1)
  local _, group_rows = voice_page_group(rows, S.cursors.voice)
  -- the group's rows that are in view (the view keeps one row above the cursor)
  local expected = {}
  for _, index in ipairs(group_rows) do
    if drawn_row(context, rows[index].label) then table.insert(expected, rows[index].label) end
  end
  table.sort(expected)
  assert_true(#expected >= 3, "most of the group shows")
  assert_equal(marked_labels(), table.concat(expected, ","), "a mark beside exactly the group's rows")
  context.arc.unplug(1)
  redraw()
  assert_equal(marked_labels(), "", "none once the arc is gone")
end)

test("VOICE hints", function()
  local context, S = started_voice_page()
  assert_equal(hint_text(context), "K2:prev K3:next")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "ALT: a quick ALT+K2 randomizes")
  toggle_lock(1); redraw()
  assert_equal(hint_text(context), "K2:locked K3:unlock", "ALT on a locked voice")
  key(1, 0)
end)

-- #557: ALT+K2 on VOICE acts on release. A quick press randomizes the
-- section under the cursor (again within 5 s to undo); held past 0.5 s it
-- resets the row; the hint says which, changing at the hold time
test("VOICE's ALT+K2 hint: rand, undo, and reset while held (#557)", function()
  local context, S = started_voice_page()
  put_cursor(S, "v1_grain_size")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "a quick press randomizes")
  key(2, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "while K2 is down: still the quick press's")
  context.clock.run_for(HELD_SECONDS)
  assert_equal(hint_text(context), "K2:reset K3:lock", "held past the hold time: letting go resets (drawn by the frame clock)")
  key(2, 0); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "released: the quick hint is back")
  tap(2); redraw()
  assert_equal(hint_text(context), "K2:undo K3:lock", "after a randomize: undo")
  put_cursor(S, "v1_mod_speed")
  assert_equal(hint_text(context), "K2:rand K3:lock", "another section: rand")
  put_cursor(S, "v1_grain_pitch")
  assert_equal(hint_text(context), "K2:undo K3:lock", "the same section: undo")
  toggle_lock(1); redraw()
  assert_equal(hint_text(context), "K2:undo K3:unlock", "a locked voice's undo still runs")
  tap(2); redraw()
  assert_equal(hint_text(context), "K2:locked K3:unlock", "undone: the locked voice offers nothing")
  key(1, 0)
end)

-- K1 let go before K2: the release still randomizes or resets, so the hint
-- row keeps K2's release hint, alone, until K2 comes up
test("K2's release hint stays after K1 comes up first (#557)", function()
  local context, S = started_voice_page()
  put_cursor(S, "v1_grain_size")
  context.screen.clear(); redraw()
  local plain = hint_text(context)
  key(1, 1); key(2, 1); key(1, 0)
  context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:rand", "K1 up, K2 down: the quick release's hint")
  context.clock.run_for(HELD_SECONDS); context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:reset", "held past the hold time: letting go resets")
  key(2, 0); context.screen.clear(); redraw()
  assert_equal(hint_text(context), plain, "K2 up: the plain hints")
end)

test("ALT+K2 on VOICE randomizes only the cursor's section (#557)", function()
  for _, case in ipairs(loaded_section_cases()) do
    local what = case.section .. " (" .. case.source .. ")"
    local context, S = started_voice_page()
    local ranges = draw_ranges(S)
    params:set("v1_source", case_source(S, case.source))
    if case.section == "synth" and case.source == "buffer" then
      params:set("v1_loop_start", 0.9)                                    -- a loop length of 0.1 at most
    end
    put_cursor(S, "v1_" .. case.cursor)
    assert_equal(voice_page_rows(1)[S.cursors.voice].section, case.section, what .. ": the cursor's section")
    local drawn = {}
    for _, key_name in ipairs(case.drawn) do drawn["v1_" .. key_name] = key_name end
    local before = all_param_values()
    math.randomseed(57)
    key(1, 1); key(2, 1)
    for id, value in pairs(all_param_values()) do assert_equal(value, before[id], what .. ": the press leaves " .. id) end
    key(2, 0); key(1, 0)
    for id, value in pairs(all_param_values()) do
      local key_name = drawn[id]
      if not key_name then
        assert_equal(value, before[id], what .. ": " .. id .. " is left alone")
      else
        if params:lookup_param(id).t ~= params.tOPTION then
          assert_true(value ~= before[id], what .. ": " .. id .. " is drawn")
        end
        local range = ranges[key_name]
        if range then
          assert_true(value >= range[1] - 1e-9 and value <= range[2] + 1e-9,
            what .. ": " .. id .. " " .. value .. " within " .. range[1] .. "-" .. range[2])
        end
      end
    end
    if case.source == "buffer" and case.section == "synth" then
      local start, length = params:get("v1_loop_start"), params:get("v1_loop_length")
      assert_true(length >= 0.05 - 1e-9 and length <= 1 - start + 1e-9,
        what .. ": the loop length " .. length .. " fits its new start " .. start)
    end
    assert_true(S.lib.mutation.undo_for(S.constants.UI_PAGES.index.VOICE, case.undo_section or case.section, 1),
      what .. ": the undo is VOICE's, this section's and voice 1's")
    -- a quick press again undoes it all
    quick_alt_k2()
    for id, value in pairs(all_param_values()) do
      assert_equal(value, before[id], what .. ": undone, " .. id .. " is back")
    end
  end
end)

test("VOICE's sections draw from their ranges (#557)", function()
  for _, case in ipairs(loaded_section_cases()) do
    local what = case.section .. " (" .. case.source .. ")"
    local context, S = started_voice_page()
    local ranges = draw_ranges(S)
    params:set("v1_source", case_source(S, case.source))
    put_cursor(S, "v1_" .. case.cursor)
    local spec = S.registry.pages[S.constants.UI_PAGES.index.VOICE].randomize_section()
    assert_equal(spec.page, S.constants.UI_PAGES.index.VOICE, what .. ": the spec's page")
    assert_equal(spec.section, case.undo_section or case.section, what .. ": the spec's section")
    assert_equal(spec.voice, 1, what .. ": the spec's voice")
    local ids = {}
    for _, entry in ipairs(spec.draws) do ids[#ids + 1] = entry.id end
    local expected = {}
    for _, key_name in ipairs(case.drawn) do expected[#expected + 1] = "v1_" .. key_name end
    assert_equal(table.concat(ids, ","), table.concat(expected, ","), what .. ": the drawn ids, in row order")
    math.randomseed(7)
    for _, entry in ipairs(spec.draws) do
      local key_name = entry.id:match("^v1_(.+)$")
      local range = ranges[key_name]
      local param = params:lookup_param(entry.id)
      local low, high, below_middle, draws = math.huge, -math.huge, 0, 400
      local seen = {}
      for _ = 1, draws do
        local value = entry.draw()
        low, high = math.min(low, value), math.max(high, value)
        seen[value] = true
        if range and value < (range[1] + range[2]) / 2 then below_middle = below_middle + 1 end
      end
      if param.t == params.tOPTION then
        for option = 1, param.count do assert_true(seen[option], what .. ": " .. entry.id .. " draws option " .. option) end
        for value in pairs(seen) do
          assert_true(value % 1 == 0 and value >= 1 and value <= param.count, what .. ": " .. entry.id .. " an option index")
        end
      elseif range then
        local span = range[2] - range[1]
        assert_true(low >= range[1] - 1e-9 and high <= range[2] + 1e-9,
          what .. ": " .. entry.id .. " draws " .. low .. "-" .. high .. " within " .. range[1] .. "-" .. range[2])
        -- (each bookmark draws above the one before it: positions_test.lua
        -- checks how the four spread)
        local independent = not key_name:find("^bookmark_")
        assert_true(not independent or (low < range[1] + span * 0.05 and high > range[2] - span * 0.05),
          what .. ": " .. entry.id .. " spans its range (" .. low .. "-" .. high .. ")")
        local octaves = key_name == "mod_speed" or key_name == "buf_rate" or key_name == "filter_freq"
        if independent and not octaves then  -- (octaves: below, and voice_mix_test.lua for the cutoff)
          assert_true(below_middle > draws * 0.4 and below_middle < draws * 0.6,
            what .. ": " .. entry.id .. " is uniform (" .. below_middle .. " of " .. draws .. " below the middle)")
        end
      elseif key_name ~= "loop_length" then
        -- a synthesis param: spec:map(random), its whole controlspec
        local spec_range = param.controlspec
        assert_true(low >= spec_range.minval and high <= spec_range.maxval, what .. ": " .. entry.id .. " within its spec")
      end
    end
  end
  -- mod speed and buffer rate spread evenly across octaves: half their
  -- draws below the geometric middle (about 1.41 Hz of 0.2-10 Hz; 1 of 0.5-2)
  for _, case in ipairs({ { source = "synth", id = "v1_mod_speed", middle = math.sqrt(0.2 * 10) },
    { source = "buffer", id = "v1_buf_rate", middle = 1 } }) do
    local context, S = started_voice_page()
    params:set("v1_source", case_source(S, case.source))
    put_cursor(S, case.id)
    local entry
    for _, each in ipairs(S.registry.pages[S.constants.UI_PAGES.index.VOICE].randomize_section().draws) do
      if each.id == case.id then entry = each end
    end
    math.randomseed(8)
    local below = 0
    for _ = 1, 400 do if entry.draw() < case.middle then below = below + 1 end end
    assert_true(below > 160 and below < 240, case.id .. " is even in octaves (" .. below .. " of 400 below " .. case.middle .. ")")
  end
end)

test("a synth voice's synth section draws every synthesis param but amp and pan (#557)", function()
  local context, S = started_voice_page()
  for voice_idx = 1, S.constants.NUM_VOICES do
    S.selected_voice = voice_idx
    local voice = S.voices[voice_idx]
    put_cursor(S, "v" .. voice_idx .. "_" .. voice.param_order[1])
    local ids, expected = {}, {}
    for _, entry in ipairs(S.registry.pages[S.constants.UI_PAGES.index.VOICE].randomize_section().draws) do
      ids[#ids + 1] = entry.id
    end
    for _, key_name in ipairs(voice.param_order) do
      if key_name ~= "amp" and key_name ~= "pan" then expected[#expected + 1] = "v" .. voice_idx .. "_" .. key_name end
    end
    assert_equal(table.concat(ids, ","), table.concat(expected, ","), voice.name .. ": its synthesis params")
  end
end)

test("ALT+K2 on a locked voice: K2:locked and nothing changes (#557)", function()
  local context, S = started_voice_page()
  toggle_lock(1)
  for _, case in ipairs(section_cases(S)) do
    params:set("v1_source", case_source(S, case.source))
    put_cursor(S, "v1_" .. case.cursor)
    key(1, 1); redraw()
    assert_equal(hint_text(context), "K2:locked K3:unlock", case.section .. ": the hint")
    local before = all_param_values()
    tap(2)
    for id, value in pairs(all_param_values()) do
      assert_equal(value, before[id], case.section .. ": a locked voice keeps " .. id)
    end
    assert_equal(local_value("undo"), nil, case.section .. ": no undo")
    key(1, 0)
  end
end)

test("a Sub voice's mix section has no pan: K2:rand, and the press does nothing (#557)", function()
  local context, S = started_voice_page()
  local sub
  for voice_idx = 1, S.constants.NUM_VOICES do
    if S.voices[voice_idx].params.pan == nil then sub = voice_idx end
  end
  assert_true(sub ~= nil, "a voice without pan (Sub)")
  S.selected_voice = sub
  put_cursor(S, "v" .. sub .. "_amp")
  assert_equal(#S.registry.pages[S.constants.UI_PAGES.index.VOICE].randomize_section().draws, 0, "no draws")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "the hint")
  local before = all_param_values()
  tap(2); redraw()
  for id, value in pairs(all_param_values()) do assert_equal(value, before[id], "Sub's mix: " .. id .. " unchanged") end
  assert_equal(local_value("undo"), nil, "no undo")
  assert_equal(hint_text(context), "K2:rand K3:lock", "still rand")
  key(1, 0)
end)

-- Review Focus 3: the grain section's undo survives a source switch
test("undo after a source switch restores the grain params (#557)", function()
  local context, S = started_voice_page()
  if not S.voices[1].active then toggle_voice(1) end
  assert_true(S.voices[1].active, "voice 1 runs")
  local grain_ids = { "v1_grain_size", "v1_grain_density", "v1_grain_pitch", "v1_grain_spread", "v1_grain_env" }
  local before = {}
  for _, id in ipairs(grain_ids) do before[id] = params:get(id) end
  put_cursor(S, "v1_grain_size")
  math.randomseed(3)
  quick_alt_k2()
  assert_true(params:get("v1_grain_size") ~= before.v1_grain_size, "the grain section is randomized")
  local randomized = {}
  for _, id in ipairs(grain_ids) do randomized[id] = params:get(id) end
  put_cursor(S, "v1_source")
  enc(3, 1)                                                                  -- E3: synth to buf 1
  assert_equal(params:get("v1_source"), S.constants.SOURCE_SYNTH + 1, "the source switched")
  for _, id in ipairs(grain_ids) do assert_equal(params:get(id), randomized[id], "the switch leaves " .. id) end
  put_cursor(S, "v1_grain_spread")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:undo K3:lock", "the grain section's undo is still held")
  context.clear_engine_calls()
  tap(2); key(1, 0)
  for _, id in ipairs(grain_ids) do assert_equal(params:get(id), before[id], "undone: " .. id .. " is back") end
  assert_equal(params:get("v1_source"), S.constants.SOURCE_SYNTH + 1, "the source stays")
  local sizes = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "grainSize" then sizes[#sizes + 1] = call.args[3] end
  end
  assert_near(sizes[#sizes], before.v1_grain_size, 1e-9, "the engine hears the old size")
end)

-- The loop pair's undo: the start's action cuts a length that no longer
-- fits, so the length held is the one before the randomize, not the cut one
test("the synth section's undo brings a buffer voice's loop back whole (#557)", function()
  local context, S = started_voice_page()
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v1_loop_start", 0)
  params:set("v1_loop_length", 1)                                          -- the whole slot
  put_cursor(S, "v1_buf_pos")
  math.randomseed(5)
  quick_alt_k2()
  assert_true(params:get("v1_loop_start") > 1e-6, "a new start leaves no room for a length of 1")
  quick_alt_k2()
  assert_near(params:get("v1_loop_start"), 0, 1e-9, "undone: the start")
  assert_near(params:get("v1_loop_length"), 1, 1e-9, "undone: the length, as it was before the randomize")
end)

-- A synth voice's synth section and a buffer voice's (its buffer params and
-- loop) hold separate undos: after a switch between them, a quick ALT+K2 in
-- the synth section randomizes the rows it shows, never undoing rows it no
-- longer shows
local function ids_changed(before, ids)
  local changed = {}
  for _, id in ipairs(ids) do
    if params:get(id) ~= before[id] then changed[#changed + 1] = id end
  end
  return table.concat(changed, ",")
end
local SYNTH_IDS = { "v1_freq", "v1_rq", "v1_noise", "v1_mod1", "v1_mod2" }
local BUFFER_IDS = { "v1_buf_pos", "v1_buf_rate", "v1_buf_scan", "v1_loop_start", "v1_loop_length" }

test("after a synth-source randomize and a switch to a buffer, the synth section offers K2:rand (#557)", function()
  local context, S = started_voice_page()
  put_cursor(S, "v1_freq")
  math.randomseed(13)
  quick_alt_k2()
  local randomized = all_param_values()
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  put_cursor(S, "v1_buf_pos")
  assert_equal(voice_page_rows(1)[S.cursors.voice].section, "synth", "the buffer rows are the synth section")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "nothing here to undo")
  tap(2); key(1, 0)
  assert_equal(ids_changed(randomized, BUFFER_IDS), table.concat(BUFFER_IDS, ","), "the press randomizes the buffer rows")
  assert_equal(ids_changed(randomized, SYNTH_IDS), "", "the hidden synth params keep their randomized values")
end)

test("after a buffer-source randomize and a switch to the synth, the synth section offers K2:rand (#557)", function()
  local context, S = started_voice_page()
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  put_cursor(S, "v1_buf_pos")
  math.randomseed(14)
  quick_alt_k2()
  local randomized = all_param_values()
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  put_cursor(S, "v1_freq")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "nothing here to undo")
  tap(2); key(1, 0)
  assert_equal(ids_changed(randomized, SYNTH_IDS), table.concat(SYNTH_IDS, ","), "the press randomizes the synth params")
  assert_equal(ids_changed(randomized, BUFFER_IDS), "", "the hidden buffer params keep their randomized values")
end)

test("the arc button starts and stops the selected voice on VOICE", function()
  local context, S = started_voice_page()
  context.arc.plug(1)
  S.selected_voice = 3
  assert_true(not S.voices[3].active, "voice 3 starts stopped")
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_true(S.voices[3].active, "the button starts it")
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_true(not S.voices[3].active, "and stops it")
  assert_true(not S.frozen[3], "never locks")
end)

test("VOICE's layout states cover every voice and source at each section's ends", function()
  load_strata()
  local S = local_value("S")
  local states = S.registry.pages[S.constants.UI_PAGES.index.VOICE].layout_states
  assert_true(type(states) == "table", "VOICE lists layout states")
  local names = {}
  for _, state in ipairs(states) do names[state.name] = true end
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, source in ipairs({ "synth", "buf 1", "input" }) do
      for _, section in ipairs({ "grain", "crossmod", "mix" }) do
        for _, edge in ipairs({ "first", "last" }) do
          local name = string.format("v%d %s %s %s", voice_idx, source, section, edge)
          assert_true(names[name], "a state " .. name)
        end
      end
      local synth = string.format("v%d %s synth first", voice_idx, source)
      assert_equal(names[synth] == true, source ~= "input", synth)
    end
  end
  -- a state puts the cursor where its name says
  local context = load_strata(); finish_startup(context)
  show_page("VOICE")
  S = local_value("S")
  for _, state in ipairs(S.registry.pages[S.constants.UI_PAGES.index.VOICE].layout_states) do
    if state.name == "v4 input mix last" then state.setup(context) end
  end
  redraw()
  assert_equal(S.selected_voice, 4)
  local last_of_mix
  for _, row in ipairs(voice_page_rows(4)) do
    if row.section == "mix" and row.param_id then last_of_mix = row.param_id end
  end
  assert_equal(cursor_param(S), last_of_mix, "Sub on input: the mix section's last field")
end)


test("a locked voice keeps its whole lock tag in the filter & sends section, or none (#421)", function()
  local context = load_strata(); finish_startup(context)
  show_page("VOICE")
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    S.selected_voice = voice_idx
    if not S.frozen[voice_idx] then toggle_lock(voice_idx) end
    put_cursor(S, "v" .. voice_idx .. "_filter_mix")
    redraw()
    local voice_text = texts_on_row(context, SECTION_Y)[1].text
    assert_true(voice_text:find("%[L%]$") or not voice_text:find("[", 1, true),
      "voice " .. voice_idx .. "'s line '" .. voice_text .. "' ends with [L] or has no bracket")
    assert_true(voice_text:find("%[L%]$") ~= nil, "voice " .. voice_idx .. " still shows it is locked")
    h.assert_screen_layout(context, "VOICE locked, filter & sends, voice " .. voice_idx)
  end
  local found
  for _, state in ipairs(S.registry.pages[S.constants.UI_PAGES.index.VOICE].layout_states) do
    if state.name == "locked voice, filter & sends" then found = state end
  end
  assert_true(found ~= nil, "a layout state for it")
end)

end

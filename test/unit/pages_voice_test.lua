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

-- Put the VOICE cursor on param_id (a row of the selected voice) and redraw
local function put_cursor(S, param_id)
  for index, row in ipairs(voice_page_rows(S.selected_voice)) do
    if row.param_id == param_id then
      S.cursors.voice = index
      redraw()
      return index
    end
  end
  error("no VOICE row " .. param_id)
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

test("VOICE draws the section and its position at the top right", function()
  local context, S = started_voice_page()
  put_cursor(S, "v1_grain_density")
  local found
  for _, entry in ipairs(texts_on_row(context, SECTION_Y)) do
    if entry.text == "grain 2/4" then found = entry end
  end
  assert_true(found, "a synth voice's grain section is the second of four")
  assert_equal(found.align, "right", "right-aligned")
  assert_equal(found.x, VALUE_RIGHT, "at the values' right edge")
  local voice_text = texts_on_row(context, SECTION_Y)[1]
  assert_equal(voice_text.x, 0, "the selected voice at the left")
  assert_equal(voice_text.text, "1+ reso", "number, running mark and short name")
  -- an input voice has no synth section: grain is the first of three
  params:set("v1_source", S.constants.SOURCE_INPUT)
  redraw()
  assert_true(h.screen_shows(context, "grain 1/3"), "an input voice's grain section is the first of three")
  -- crossmod and mix, and a locked, stopped voice
  put_cursor(S, "v1_mod_speed")
  assert_true(h.screen_shows(context, "crossmod 2/3"), "crossmod")
  put_cursor(S, "v1_amp")
  assert_true(h.screen_shows(context, "mix 3/3"), "mix")
  toggle_lock(1); toggle_voice(1); redraw()
  assert_equal(texts_on_row(context, SECTION_Y)[1].text, "1- reso [L]", "stopped and locked")
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
  assert_equal(cursor_param(S), "v1_pan", "stops at the last field")
  -- E3 edits the field under the cursor, ALT+E3 a tenth as far
  enc(2, -1)
  assert_equal(cursor_param(S), "v1_amp")
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
  tap(3); assert_equal(cursor_param(S), "v1_source", "K3 in the last section stays")
  enc(2, 1)
  assert_equal(cursor_param(S), "v1_amp")
  tap(2); assert_equal(cursor_param(S), "v1_mod_speed", "K2: crossmod")
  enc(2, 3)
  tap(2); assert_equal(cursor_param(S), "v1_grain_size", "K2 from inside crossmod: grain")
  tap(2); assert_equal(cursor_param(S), "v1_freq", "K2: synth")
  enc(2, 2)
  tap(2); assert_equal(cursor_param(S), "v1_freq", "K2 in the first section: its first field")
  -- an input voice: grain is the first section
  params:set("v1_source", S.constants.SOURCE_INPUT)
  tap(3); assert_equal(cursor_param(S), "v1_mod_speed", "input: K3 from grain to crossmod")
  tap(2); tap(2); assert_equal(cursor_param(S), "v1_grain_size", "input: K2 stops at grain")
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

test("ALT+K2 resets the field to its default; ALT+K3 locks", function()
  local context, S = started_voice_page()
  put_cursor(S, "v1_grain_spread")
  params:set("v1_grain_spread", 0.9)
  key(1, 1)
  tap(2)
  assert_near(params:get("v1_grain_spread"), param_default("v1_grain_spread"), 1e-9, "ALT+K2 resets the field")
  assert_true(math.abs(params:get("v1_grain_spread") - 0.9) > 0.01, "away from 0.9")
  -- an option row too
  put_cursor(S, "v1_grain_env")
  params:set("v1_grain_env", 3)
  tap(2)
  assert_equal(params:get("v1_grain_env"), param_default("v1_grain_env"), "an option row resets")
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
  assert_equal(hint_text(context), "K2:reset K3:lock", "ALT")
  toggle_lock(1); redraw()
  assert_equal(hint_text(context), "K2:reset K3:unlock", "ALT on a locked voice")
  key(1, 0)
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
  assert_equal(cursor_param(S), "v4_amp", "Sub on input: the mix section ends with amp")
end)

end

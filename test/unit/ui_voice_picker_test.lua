-- test/unit/ui_voice_picker_test.lua
-- The voice picker (lib/ui/voice_picker.lua, S.lib.ui_voice_picker, 3.8
-- design §8.4, §12): a modal owner K3 on VOICE's preset row opens, listing
-- the six other voices and the library's slots; K3 copies or loads, ALT+K3
-- names a slot and saves, ALT+K2 held clears, K2 goes back
-- Run alone: lua test/run.lua ui_voice_picker

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, next_frame, finish_startup = h.load_strata, h.local_value, h.next_frame, h.finish_startup
local show_page, hint_text, tap = h.show_page, h.hint_text, h.tap

-- VOICE shown on voice 1, the cursor on its preset row
local function on_preset_row()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("VOICE")
  S.selected_voice = 1
  for index, row in ipairs(voice_page_rows(1)) do
    if row.kind == "preset" then S.lib.pages_voice.place_cursor(index) end
  end
  next_frame(context)
  return context, S, S.lib.ui_voice_picker
end

-- The picker open on voice 1
local function opened()
  local context, S, picker = on_preset_row()
  tap(3)
  next_frame(context)
  return context, S, picker
end

-- The texts drawn on the row at y, left to right, joined by a space
local function row_at(context, y)
  local entries = h.texts_on_row(context, y)
  table.sort(entries, function(a, b) return (h.text_span(a)) < (h.text_span(b)) end)
  local texts = {}
  for index, entry in ipairs(entries) do texts[index] = entry.text end
  return table.concat(texts, " ")
end

-- The picker's rows in view, from its first row's y
local function rows_shown(context, S)
  local layout = S.lib.ui_voice_picker.VOICE_PICKER
  local shown = {}
  for index = 0, layout.visible - 1 do
    local text = row_at(context, layout.first_y + index * layout.spacing)
    if text ~= "" then shown[#shown + 1] = text end
  end
  return shown
end

-- The text of the row drawn at the selected level (the cursor's)
local function selected_row(context, S)
  local layout = S.lib.ui_voice_picker.VOICE_PICKER
  for _, entry in ipairs(context.screen.texts) do
    if entry.level == layout.levels.selected and entry.y >= layout.first_y and entry.y < h.HINT_ROW_Y
      and entry.align ~= "right" then
      return row_at(context, entry.y)
    end
  end
end

local function shows(context, S, text)
  for _, row in ipairs(rows_shown(context, S)) do
    if row == text then return true end
  end
  return false
end

test("K3 on the preset row opens the picker; K2 closes it", function()
  local context, S, picker = opened()
  assert_true(picker.is_open(), "K3 on the row opens it")
  assert_true(S.lib.ui_modal.top() ~= nil, "a modal owner")
  assert_equal(row_at(context, picker.VOICE_PICKER.title_y), "LOAD INTO VOICE 1", "the title")
  tap(2)
  assert_true(not picker.is_open(), "K2 closes it")
  assert_equal(S.lib.ui_modal.top(), nil, "its owner is off the stack")
end)

test("the list is the six other voices, then 64 slots", function()
  local context, S, picker = opened()
  local presets = S.lib.voice_presets
  assert_equal(presets.VOICE_PRESETS.slots, 64, "64 slots")
  local shown = rows_shown(context, S)
  assert_equal(shown[1], "from voice 2 " .. S.lib.types.of(2).list_name, "voice 2 first: voice 1 is the one loaded into")
  assert_equal(shown[2], "from voice 3 " .. S.lib.types.of(3).list_name, "then voice 3")
  enc(2, S.constants.NUM_VOICES - 1)
  next_frame(context)
  assert_true(shows(context, S, "01 --"), "slot 1 after the other voices")
  assert_true(presets.save(2, 1, "glass pad"), "a preset in slot 1")
  next_frame(context)
  assert_true(shows(context, S, "01 glass pad fm"), "a filled slot: its number, name and type")
end)

test("E2 moves the picker's cursor and scrolls; E3 does nothing", function()
  local context, S, picker = opened()
  local layout = picker.VOICE_PICKER
  enc(2, S.constants.NUM_VOICES - 1)
  next_frame(context)
  assert_equal(hint_text(context), "K2:back", "on an empty slot")
  assert_true(shows(context, S, "01 --"), "the view scrolled to show slot 1")
  enc(2, 100)
  next_frame(context)
  assert_true(shows(context, S, "64 --"), "stops on slot 64")
  local last = row_at(context, layout.first_y + (layout.visible - 1) * layout.spacing)
  assert_equal(last, "64 --", "slot 64 is the last row in view")
  enc(2, -100)
  next_frame(context)
  assert_equal(rows_shown(context, S)[1], "from voice 2 " .. S.lib.types.of(2).list_name, "back on the first voice row")
  assert_equal(hint_text(context), "K2:back K3:copy", "a voice row's hint")
  -- one E3 turn on slot 1 leaves the cursor, the view and every param
  enc(2, S.constants.NUM_VOICES - 1)
  next_frame(context)
  local view, cursor_row = table.concat(rows_shown(context, S), "|"), selected_row(context, S)
  assert_equal(cursor_row, "01 --", "on slot 1")
  local before = {}
  for _, param_id in ipairs(params.params) do
    if param_id.id then before[param_id.id] = params:get(param_id.id) end
  end
  context.clear_engine_calls()
  enc(3, 1)
  next_frame(context)
  assert_equal(#context.engine_calls, 0, "E3 sends nothing")
  for id, value in pairs(before) do assert_equal(params:get(id), value, id .. " unchanged") end
  assert_equal(selected_row(context, S), cursor_row, "the cursor unmoved")
  assert_equal(table.concat(rows_shown(context, S), "|"), view, "the view unmoved")
end)

test("a refused load flashes on the picker's hint row", function()
  local context, S = opened()
  enc(2, S.constants.NUM_VOICES - 1)
  tap(3)
  next_frame(context)
  assert_equal(hint_text(context), S.lib.voice_presets.VOICE_PRESETS.texts.nothing, "an empty slot")
end)

test("a preset of a type this build lacks flashes on the picker's hint row", function()
  local subdir = "voice-picker-nope-" .. math.random(1, 1e9)
  local dir = h.data_root .. subdir .. "/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  local first = load_strata({ data_subdir = subdir }); finish_startup(first)
  local S0 = local_value("S")
  assert_true(S0.lib.voice_presets.save(2, 1, "later"), "saved")
  local value = S0.lib.data_files.read(dir .. "voices.data")
  value.presets[1].type = "nope"
  assert_true(S0.lib.data_files.write(dir .. "voices.data", value), "a later build's type")
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local S = local_value("S")
  show_page("VOICE")
  for index, row in ipairs(voice_page_rows(1)) do
    if row.kind == "preset" then S.lib.pages_voice.place_cursor(index) end
  end
  tap(3)
  enc(2, S.constants.NUM_VOICES - 1)
  next_frame(context)
  assert_true(shows(context, S, "01 later ?"), "the slot shows ? for the type")
  tap(3)
  next_frame(context)
  assert_equal(hint_text(context), S.lib.voice_presets.VOICE_PRESETS.texts.no_type, "the refusal")
end)

test("the hints follow the row and ALT", function()
  local context, S, picker = opened()
  assert_true(S.lib.voice_presets.save(2, 1, "glass"), "a preset in slot 1")
  enc(2, S.constants.NUM_VOICES - 1)
  next_frame(context)
  assert_equal(hint_text(context), "K2:back K3:load", "a filled slot")
  key(1, 1); next_frame(context)
  assert_equal(hint_text(context), "K2:clear K3:save", "with ALT")
  key(1, 0); enc(2, 1); key(1, 1); next_frame(context)
  assert_equal(hint_text(context), "K3:save", "an empty slot with ALT")
  key(1, 0)
  -- #850: on a voice row ALT's K2 and K3 do nothing, E2 still moves
  enc(2, -100); key(1, 1); next_frame(context)
  assert_equal(hint_text(context), "E2:row", "a voice row with ALT")
  enc(2, 1); next_frame(context)
  assert_equal(selected_row(context, S):match("^from voice"), "from voice", "E2 moved with ALT held")
  key(1, 0)
end)

test("K3 copies a voice row and loads a filled slot", function()
  local context, S, picker = opened()
  tap(3)
  assert_equal(S.voices[1].name, S.voices[2].name, "voice 2's sound copied into voice 1")
  assert_equal(S.lib.voice_presets.loaded_name(1), "v2", "the row's name")
  next_frame(context)
  assert_equal(hint_text(context), "loaded v2", "the hint row says what it loaded")
  assert_true(S.lib.voice_presets.save(3, 1, "folded"), "a preset of voice 3")
  enc(2, S.constants.NUM_VOICES - 1)
  tap(3)
  assert_equal(S.voices[1].name, S.voices[3].name, "voice 3's preset loaded")
  assert_equal(S.lib.voice_presets.loaded_name(1), "folded", "the row's name")
  next_frame(context)
  assert_equal(hint_text(context), "loaded folded", "the hint row says what it loaded")
  assert_true(picker.is_open(), "the picker stays open to try another")
  enc(2, 1)
  local name = S.voices[1].name
  tap(3)
  assert_equal(S.voices[1].name, name, "an empty slot loads nothing")
  next_frame(context)
end)

test("ALT+K3 on a slot names it on K3's release and saves", function()
  local context, S, picker = opened()
  enc(2, S.constants.NUM_VOICES - 1 + 2)  -- slot 3
  key(1, 1); key(3, 1)
  assert_true(not context.textentry.open, "nothing opens on the press")
  key(3, 0)
  assert_true(context.textentry.open, "the release opens the entry")
  local te = context.textentry.library
  assert_equal(te.txt, "", "an empty slot's entry starts empty")
  assert_equal(te.heading, "preset 03 name", "its heading names the slot")
  context.textentry.finish("dusk")
  assert_true(not context.textentry.open, "closed")
  local preset = S.lib.voice_presets.preset(3)
  assert_equal(preset and preset.name, "dusk", "slot 3 saved as dusk")
  assert_equal(preset and preset.type, S.voices[1].name, "voice 1's sound")
  assert_true(picker.is_open(), "the picker is still open")
  key(1, 1); key(3, 1); key(3, 0)
  assert_equal(te.txt, "dusk", "a filled slot's entry starts from its name")
  assert_equal(te.heading, "preset 03 name", "the heading")
  context.textentry.finish("a much longer name than twelve")
  assert_equal(S.lib.voice_presets.preset(3).name, ("a much longer name than twelve"):sub(1, S.constants.SCENE_NAME_MAX),
    "a longer name is cut to twelve")
end)

test("a canceled entry saves nothing", function()
  local context, S = opened()
  enc(2, S.constants.NUM_VOICES - 1)
  key(1, 1); key(3, 1); key(3, 0)
  assert_true(context.textentry.open, "open")
  key(2, 0)  -- the entry's cancel
  assert_true(not context.textentry.open, "canceled")
  assert_equal(S.lib.voice_presets.preset(1), nil, "nothing saved")
end)

test("ALT is not held after the entry", function()
  local context, S = opened()
  enc(2, S.constants.NUM_VOICES - 1)
  key(1, 1); key(3, 1); key(3, 0)
  assert_true(not S.alt_held, "the entry took ALT with the keys")
  key(1, 0)  -- K1's release goes to the entry
  context.textentry.finish("noon")
  assert_true(not S.alt_held, "ALT is not held after it")
  next_frame(context)
  assert_equal(hint_text(context), "K2:back K3:load", "the picker's plain hints")
end)

test("ALT+K2 held 0.5 s then released clears a slot; quick does nothing", function()
  local context, S = opened()
  assert_true(S.lib.voice_presets.save(2, 1, "keep"), "a preset in slot 1")
  enc(2, S.constants.NUM_VOICES - 1)
  key(1, 1); key(2, 1); key(2, 0); key(1, 0)
  assert_true(S.lib.voice_presets.preset(1) ~= nil, "a quick press clears nothing")
  key(1, 1); key(2, 1)
  next_frame(context)
  assert_equal(hint_text(context), "K2:hold", "held, before the hold time")
  context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
  next_frame(context)
  assert_equal(hint_text(context), "K2:clear", "past the hold time its release clears")
  key(2, 0); key(1, 0)
  assert_equal(S.lib.voice_presets.preset(1), nil, "cleared")
end)


test("a name entry the norns menu took over is forgotten when the menu closes", function()
  local context, S, picker = opened()
  local te = context.textentry.library
  local script_key, script_enc = key, enc
  enc(2, S.constants.NUM_VOICES - 1)
  key(1, 1); key(3, 1); key(3, 0)
  assert_true(context.textentry.open, "the picker's entry is open")
  -- K1 opens the norns menu; PARAMS names a PSET through the one textentry
  _menu.set_mode(true)
  local pset_name
  te.enter(function(text) pset_name = text end, "pset", "PSET NAME: 1")
  context.textentry.finish("mine")
  assert_equal(pset_name, "mine", "the menu's entry called the menu back")
  _menu.set_mode(false)
  assert_true(key == script_key and enc == script_enc, "the script's key and enc are back")
  assert_equal(S.lib.voice_presets.preset(1), nil, "nothing saved")
  assert_equal(S.scenes_page.naming, nil, "SCENES' entry is not touched")
  -- the picker works again, a new entry too
  key(1, 1); key(3, 1); key(3, 0)
  context.textentry.finish("noon")
  assert_equal(S.lib.voice_presets.preset(1).name, "noon", "which saves its slot")
  assert_true(picker.is_open(), "the picker stays open")
end)


-- A press the norns menu took never reaches the picker's release: the menu
-- close forgets it (as SEQ's step editor forgets its ALT+K2)
local function menu_opens_and_closes()
  _menu.set_mode(true)
  _menu.set_mode(false)
end

test("an ALT+K2 press the menu took is forgotten", function()
  local context, S = opened()
  assert_true(S.lib.voice_presets.save(2, 1, "keep"), "a preset in slot 1")
  enc(2, S.constants.NUM_VOICES - 1)
  key(1, 1); key(2, 1)
  menu_opens_and_closes()
  next_frame(context)
  assert_equal(hint_text(context), "K2:back K3:load", "no held ALT+K2 after the menu")
  assert_true(not S.lib.ui_modal.top().animates(), "the picker stops redrawing every frame")
  context.clock.run_for(S.constants.ALT_HOLD_SECONDS * 4)
  next_frame(context)
  assert_equal(hint_text(context), "K2:back K3:load", "nor later")
  assert_true(S.lib.voice_presets.preset(1) ~= nil, "nothing cleared")
end)

test("an ALT+K3 press the menu took is forgotten", function()
  local context, S = opened()
  assert_true(S.lib.voice_presets.save(3, 1, "folded"), "a preset in slot 1")
  enc(2, S.constants.NUM_VOICES - 1)
  key(1, 1); key(3, 1)
  menu_opens_and_closes()
  tap(3)
  assert_equal(S.lib.voice_presets.loaded_name(1), "folded", "the next K3 loads")
  assert_true(not context.textentry.open, "and opens no name entry")
end)

-- Found with the scale editor's (as #847 of the factory list): cleanup
-- closes an open picker
test("cleanup closes the picker", function()
  local _, S, picker = opened()
  assert_true(picker.is_open(), "open")
  cleanup()
  assert_true(not picker.is_open(), "closed at cleanup")
  assert_equal(S.lib.ui_modal.top(), nil, "its owner is off the stack")
end)

end

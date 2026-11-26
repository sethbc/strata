-- test/unit/ui_scale_editor_test.lua
-- The scale and tuning editor (lib/ui/scale_editor.lua,
-- S.lib.ui_scale_editor, 3.8 design §6.3, §12): opened from SETUP's scale &
-- tuning row as a modal owner, it edits the root, the scale, the scale's
-- twelve classes (a custom scale held as a mask) and the tuning, and a MIDI
-- note toggles its class while it is open
-- Run alone: lua test/run.lua ui_scale_editor

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, next_frame, finish_startup = h.load_strata, h.local_value, h.next_frame, h.finish_startup
local show_page, assert_screen_layout, hint_text, tap = h.show_page, h.assert_screen_layout, h.hint_text, h.tap

local function option_index(param_id, name)
  for index, option in ipairs(params:lookup_param(param_id).options) do
    if option == name then return index end
  end
  error("no option " .. name .. " in " .. param_id)
end

-- SETUP shown, the cursor on its scale & tuning row, K3: the editor open
local function loaded()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("SETUP")
  local rows = S.lib.pages_setup.setup_rows()
  for index, row in ipairs(rows) do
    if row.label == "scale & tuning" then S.setup_cursor = index end
  end
  next_frame(context)
  tap(3)
  next_frame(context)
  return context, S, S.lib.ui_scale_editor
end

-- The texts drawn on the row whose first text is label, left to right
local function row(context, label)
  local y
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == label and entry.y > 8 and entry.y < h.HINT_ROW_Y then y = entry.y end
  end
  if not y then return nil end
  local entries = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == y then entries[#entries + 1] = entry end
  end
  table.sort(entries, function(a, b) return (h.text_span(a)) < (h.text_span(b)) end)
  local texts = {}
  for index, entry in ipairs(entries) do texts[index] = entry.text end
  return table.concat(texts, " "), entries
end

local function select_tuning(S, name)
  for _, entry in ipairs(S.lib.tuning.built_ins()) do
    if entry.name == name then return S.lib.tuning.select(entry) end
  end
end

test("SETUP's scale & tuning row opens the editor; K2 closes it", function()
  local context, S, editor = loaded()
  assert_true(editor.is_open(), "K3 on the row opens it")
  assert_equal(S.lib.ui_modal.top() ~= nil, true, "a modal owner")
  assert_equal(row(context, "root"), "root C", "the root")
  assert_equal(row(context, "scale"), "scale off", "the scale")
  assert_equal(row(context, "notes"), "notes C # D # E F # G # A # B", "every class in, a sharp as #")
  assert_equal(row(context, "tuning"), "tuning 12 equal", "the tuning")
  tap(2)
  assert_true(not editor.is_open(), "K2 closes it")
  assert_equal(S.lib.ui_modal.top(), nil, "its owner is off the stack")
end)

test("E2 moves over the rows; E3 edits the root and the scale", function()
  local context, S, editor = loaded()
  enc(3, 2)
  assert_equal(params:string("root"), "D", "E3 on root")
  enc(2, 1); enc(3, 1)
  assert_equal(params:string("scale"), "Major", "E3 on scale")
  next_frame(context)
  assert_equal(row(context, "notes"), "notes D . E . # G . A . B . #", "D major from the root: a sharp as #")
end)

test("on the notes row E3 moves the class and K3 toggles it, under a built-in scale writing the mask then custom", function()
  local context, S, editor = loaded()
  enc(2, 1); enc(3, 1)  -- Major, root C
  assert_equal(params:string("scale"), "Major")
  enc(2, 1)
  next_frame(context)
  assert_equal(row(context, "notes"), "notes C . D . E F . G . A . B", "C major's classes")
  enc(3, 6)  -- the cursor on F#, class 6
  next_frame(context)
  assert_equal(hint_text(context), "K2:back E3:note K3:F#", "the hint names the cursor's class")
  local order = {}
  local real_set = params.set
  params.set = function(self, id, ...)
    if id == "scale" or id == "scale_mask" then order[#order + 1] = id end
    return real_set(self, id, ...)
  end
  context.clear_engine_calls()
  tap(3)
  params.set = real_set
  assert_equal(params:get("scale_mask"), 2741 + 64, "F# joins the mask")
  assert_equal(params:string("scale"), "custom", "and the scale is custom")
  assert_equal(table.concat(order, ","), "scale_mask,scale", "the mask first, then custom")
  local calls = context.calls_named("setScale")
  assert_equal(#calls, 1, "one setScale")
  assert_equal(calls[1].args[2], 2805, "with the new mask")
  tap(3)
  assert_equal(params:get("scale_mask"), 2741, "K3 again takes it out")
  -- the last class cannot be turned off
  params:set("scale_mask", 1)
  enc(3, -20)
  tap(3)
  assert_equal(params:get("scale_mask"), 1, "the last class stays")
end)

test("a MIDI note toggles its class while the editor is open, and plays nothing", function()
  local context, S, editor = loaded()
  local played = 0
  local real_play = S.lib.notes.play
  S.lib.notes.play = function(...) played = played + 1; return real_play(...) end
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 1 })
  assert_equal(params:string("scale"), "custom", "F# toggled: a custom scale")
  assert_equal(params:get("scale_mask"), 4095 - 64, "without F#")
  assert_equal(played, 0, "the note plays nothing")
  context.midi.send(1, { type = "note_off", note = 66, vel = 0, ch = 1 })
  tap(2)
  next_frame(context)
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 1 })
  assert_equal(params:get("scale_mask"), 4095 - 64, "closed: the note toggles nothing")
  assert_true(played > 0, "and plays")
  S.lib.notes.play = real_play
end)

-- 3.9 (#900): reset_midi_input clears the note tap and tells its owner
-- (fn(nil)); the open editor takes the tap back at once, with no draw
-- (3.8's fix round 1 set it again at the next draw)
test("a MIDI reset tells the scale editor, which takes its tap back at once", function()
  local context, S = loaded()
  local owner = S.lib.ui_scale_editor.SCALE_EDITOR.tap_owner
  assert_equal(S.lib.midi_in.note_tap_owner(), owner, "open: the tap is the editor's")
  reset_midi_input()
  assert_equal(S.lib.midi_in.note_tap_owner(), owner, "told, it took the tap back")
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 1 })
  assert_equal(params:get("scale_mask"), 4095 - 64, "F# toggled after the reset, with no draw between")
end)

-- 3.9 (#900): only the editor on top takes notes. SEQ's step editor (the
-- one owner a grid pushes over it) covers it: a note then toggles no class
-- the player cannot see and plays as with no tap; uncovered, the editor
-- takes notes again, with nothing set at a draw
test("a note while the step editor covers the scale editor toggles no scale class", function()
  local context, S = loaded()
  assert_true(S.lib.pages_seq.open_step_editor(1, 1, 1), "the step editor opens over the scale editor")
  next_frame(context)
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 1 })
  assert_equal(params:get("scale_mask"), 4095, "covered: F# is not toggled")
  assert_true(params:string("scale") ~= "custom", "and the scale is not made custom")
  assert_true(S.midi_state.held[1][1 * 128 + 66], "the note plays on voice 1, as with no tap: its key is down")
  context.midi.send(1, { type = "note_off", note = 66, vel = 0, ch = 1 })
  S.lib.pages_seq.close_step_editor(1)
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 1 })
  assert_equal(params:get("scale_mask"), 4095 - 64, "uncovered: the editor takes the note again")
end)

test("MIDI plays while the norns menu covers SCALE and edits again when it closes", function()
  local context, S = loaded()
  params:set("scale", option_index("scale", "Chromatic"))
  local note_on = { type = "note_on", note = 66, vel = 100, ch = 1 }
  local held_key = 128 + 66  -- channel 1, F#
  _menu.set_mode(true)
  context.midi.send(1, note_on)
  assert_equal(params:get("scale_mask"), 4095, "the menu leaves F# in the mask")
  assert_equal(params:string("scale"), "Chromatic")
  assert_true(S.midi_state.held[1][held_key], "voice 1 plays F#")
  context.midi.send(1, { type = "note_off", note = 66, vel = 0, ch = 1 })
  assert_true(not S.midi_state.held[1][held_key], "voice 1 releases F#")

  _menu.set_mode(false)
  context.midi.send(1, note_on)
  assert_equal(params:get("scale_mask"), 4031, "the visible editor removes F#")
  assert_equal(params:string("scale"), "custom")
  assert_true(not S.midi_state.held[1][held_key], "the editor consumes the note")
end)

-- 3.9 (#900): the tap is set once, at open; no draw sets it (a reset tells
-- the editor, which takes it back then)
test("the scale editor sets its note tap at open and at no draw", function()
  local context, S, editor = loaded()
  local sets = 0
  local real_set = S.lib.midi_in.set_note_tap
  S.lib.midi_in.set_note_tap = function(...) sets = sets + 1; return real_set(...) end
  editor.close()
  assert_equal(S.lib.midi_in.note_tap_owner(), nil, "closed: the tap is cleared")
  editor.open()
  assert_equal(sets, 1, "the open sets the tap")
  assert_equal(S.lib.midi_in.note_tap_owner(), editor.SCALE_EDITOR.tap_owner, "under the editor's owner")
  for _ = 1, 3 do request_redraw(); next_frame(context) end
  S.lib.midi_in.set_note_tap = real_set
  assert_equal(sets, 1, "no draw sets the tap")
end)

test("in 19 equal the scale and notes rows show -- and change nothing", function()
  local context, S, editor = loaded()
  select_tuning(S, "19 equal")
  next_frame(context)
  assert_equal(row(context, "scale"), "scale --", "no scale in 19 tones")
  assert_equal(row(context, "notes"), "notes --", "no classes")
  enc(2, 1); enc(3, 1)
  assert_equal(params:get("scale"), 1, "E3 on scale does nothing")
  next_frame(context)
  assert_equal(hint_text(context), "K2:back", "only K2 acts")
  enc(2, 1); enc(3, 3); tap(3)
  assert_equal(params:get("scale_mask"), 4095, "K3 on notes does nothing")
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 1 })
  assert_equal(params:get("scale_mask"), 4095, "the note tap takes nothing")
end)

test("the tuning row: E3 moves a dim pending choice and K3 applies it; a refused file says why", function()
  local context, S, editor = loaded()
  local folder = _path.data .. S.lib.tuning.TUNING.folder
  h.write_text(folder .. "broken.scl", "Broken\n0\n")
  editor.close(); editor.open()  -- the folder is listed at open
  enc(2, 3)
  next_frame(context)
  assert_equal(hint_text(context), "K2:back E3:tuning", "nothing pending")
  context.clear_engine_calls()
  enc(3, 1)
  next_frame(context)
  local text, entries = row(context, "tuning")
  assert_equal(text, "tuning ji normal", "the pending choice")
  assert_true(entries[2].level < 15, "dim")
  assert_equal(#context.calls_named("setTuning"), 0, "a pending choice sends nothing")
  assert_equal(hint_text(context), "K2:back K3:apply E3:tuning", "K3 applies it")
  tap(3)
  assert_equal(#context.calls_named("setTuning"), 1, "one setTuning set")
  assert_equal(params:get("tuning_name"), "ji normal", "applied")
  enc(3, 100)  -- the last choice: the file
  next_frame(context)
  assert_equal(row(context, "tuning"), "tuning broken", "the files follow the built-ins")
  tap(3)
  next_frame(context)
  assert_equal(params:get("tuning_name"), "ji normal", "a refused file leaves the tuning")
  assert_true(hint_text(context):find("count", 1, true) ~= nil, "its reason in the editor's hints: " .. hint_text(context))
end)

-- Fix round 1: a file's name is drawn printable (#551) and fits
test("a tuning file's name with a non-ASCII byte draws printable and fits", function()
  local context, S, editor = loaded()
  local folder = _path.data .. S.lib.tuning.TUNING.folder
  h.write_text(folder .. "caf\195\169 tuning.scl", "Cafe\n1\n2/1\n")
  editor.close(); editor.open()
  enc(2, 3); enc(3, 100)
  next_frame(context)
  assert_equal(row(context, "tuning"), "tuning cafe tuning", "drawn as norns' font can draw it")
  assert_screen_layout(context, "a non-ASCII file name")
end)

-- Fix round 1: one rule names a file's choice and its tuning (the extension
-- matched without case, cut to name_max), so after a file is applied E3
-- steps on from it
test("E3 steps on from an applied file, whatever its name's length or extension's case", function()
  local context, S, editor = loaded()
  local folder = _path.data .. S.lib.tuning.TUNING.folder
  local long = string.rep("a", 30)
  h.write_text(folder .. long .. ".scl", "Long\n1\n2/1\n")
  h.write_text(folder .. "b.SCL", "Upper\n1\n2/1\n")
  editor.close(); editor.open()
  enc(2, 3)
  local built_ins = #S.lib.tuning.built_ins()
  enc(3, built_ins)  -- from 12 equal to the first file
  next_frame(context)
  tap(3)
  assert_equal(params:get("tuning_name"), string.rep("a", S.lib.tuning.TUNING.name_max), "the long file, its name cut")
  enc(3, 1)
  next_frame(context)
  assert_equal(row(context, "tuning"), "tuning b", "E3 steps on from the long file to b (.SCL dropped)")
  tap(3)
  assert_equal(params:get("tuning_name"), "b", "b applied")
  enc(3, -1)
  next_frame(context)
  local text = row(context, "tuning")
  assert_true(text:find("aaaa", 1, true) ~= nil, "E3 back from b reaches the long file: " .. text)
end)

-- Fix round 1 (#419): with ALT held E3 still acts (no row has a fine
-- step), K2 and K3 do not: the hints say so
test("with ALT held the hints name E2 and E3, as the keys act", function()
  local context, S, editor = loaded()
  key(1, 1)
  next_frame(context)
  assert_equal(hint_text(context), "E2:row E3:value", "root, ALT held")
  enc(3, 2)
  assert_equal(params:string("root"), "D", "E3 acts with ALT held")
  tap(2)
  assert_true(editor.is_open(), "K2 does nothing with ALT held")
  key(1, 0)
end)

test("the editor's every state stays inside the layout", function()
  local context, S, editor = loaded()
  params:set("scale", option_index("scale", "Gagaku Rittsu Sen Pou"))
  for row_index = 1, 4 do
    enc(2, -10); enc(2, row_index - 1)
    for _, alt in ipairs({ false, true }) do
      if alt then key(1, 1) end
      next_frame(context)
      assert_screen_layout(context, string.format("the editor, row %d, alt %s", row_index, tostring(alt)))
      if alt then key(1, 0) end
    end
  end
  local names = {}
  for _, state in ipairs(S.registry.pages[S.constants.UI_PAGES.index.SETUP].layout_states) do names[state.name] = true end
  for _, name in ipairs({ "scale & tuning editor, root", "scale & tuning editor, the widest scale",
      "scale & tuning editor, every class in", "scale & tuning editor, the longest tuning",
      "scale & tuning editor, a long file name", "scale & tuning editor, a non-ASCII file name",
      "scale & tuning editor, 19 equal",
      "scale & tuning editor, a pending choice", "scale & tuning editor, a refused file" }) do
    assert_true(names[name], "SETUP's layout state: " .. name)
  end
end)

-- #843: the hint row shows only the editor's own reason (a refused file);
-- another module's flash, unscoped or SETUP's, leaves its hints
test("another module's hints flash leaves the editor's hints; its own refused file still shows", function()
  local context, S, editor = loaded()
  S.lib.ui_flash.start("hints", "scenes loaded")  -- unscoped, as lib/scenes.lua's
  next_frame(context)
  assert_equal(hint_text(context), "K2:back E3:value", "an unscoped flash: the editor's hints")
  S.lib.ui_flash.start("hints", "setting not saved", nil, S.constants.UI_PAGES.index.SETUP)
  next_frame(context)
  assert_equal(hint_text(context), "K2:back E3:value", "a SETUP flash of another module: the editor's hints")
  local folder = _path.data .. S.lib.tuning.TUNING.folder
  h.write_text(folder .. "broken.scl", "Broken\n0\n")
  editor.close(); editor.open()
  enc(2, 3); enc(3, 100)
  tap(3)
  next_frame(context)
  local reason = hint_text(context)
  assert_true(reason:find("count", 1, true) ~= nil, "its own reason shows: " .. reason)
  editor.close(); editor.open()
  next_frame(context)
  assert_equal(hint_text(context), "K2:back E3:tuning", "a reason from before a close is not shown again")
end)

-- Found by Y5 (as #847 of the factory list): cleanup closes the editor
test("cleanup closes the editor and clears the note tap", function()
  local _, S, editor = loaded()
  assert_true(editor.is_open(), "open")
  assert_equal(S.lib.midi_in.note_tap_owner(), editor.SCALE_EDITOR.tap_owner, "the note tap is the editor's")
  local cleared = {}
  local real_clear = S.lib.midi_in.clear_note_tap
  S.lib.midi_in.clear_note_tap = function(owner) cleared[#cleared + 1] = owner; return real_clear(owner) end
  cleanup()
  assert_true(not editor.is_open(), "closed at cleanup")
  assert_equal(S.lib.ui_modal.top(), nil, "its owner is off the stack")
  assert_equal(cleared[1], editor.SCALE_EDITOR.tap_owner, "the editor cleared its own tap")
  assert_equal(S.lib.midi_in.note_tap_owner(), nil, "the note tap is no one's")
end)
end

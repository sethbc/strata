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

-- Fix round 1: reset_midi_input clears the note tap without telling the
-- editor; its next draw sets it again (every path that resets the input
-- also asks for a redraw: a port's removal, the MIDI params' actions)
test("the note tap is set again at the next draw after reset_midi_input", function()
  local context, S, editor = loaded()
  reset_midi_input()
  request_redraw()
  next_frame(context)
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 1 })
  assert_equal(params:get("scale_mask"), 4095 - 64, "F# toggled after the reset")
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
      "scale & tuning editor, a long file name", "scale & tuning editor, 19 equal",
      "scale & tuning editor, a pending choice", "scale & tuning editor, a refused file" }) do
    assert_true(names[name], "SETUP's layout state: " .. name)
  end
end)
end

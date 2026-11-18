-- lib/ui/scale_editor.lua
-- The scale and tuning editor (3.8, design §6.3, §12), S.lib.ui_scale_editor:
-- a modal screen owner (S.lib.ui_modal) that SETUP's scale & tuning row
-- opens. Its rows: root, scale, notes (the scale's twelve classes from the
-- root, a custom scale held as scale_mask) and tuning (the built-ins, then
-- the tunings folder's files). E2 the row, E3 the value (on notes the class
-- under the cursor, on tuning a dim pending choice), K3 toggles a class or
-- applies the pending tuning, K2 closes. A MIDI note toggles its class
-- while it is open (the MIDI module's note tap, re-armed at each draw). In
-- a tuning that is not twelve notes to an octave the scale and notes rows
-- show -- and change nothing. Fields of this module's table: open, close,
-- is_open, note, SCALE_EDITOR. See docs/notes/lua/ui/scale-editor.md.

return function(S)
  local M = {}
  local field_list = S.lib.ui_field_list
  local musicutil = require "musicutil"

  -- The editor's layout: six rows from y 18, 7 px apart, values
  -- right-aligned at value_right (the scroll marker owns x 127), as SETUP's
  -- and the zones editor's; the notes row's classes in cells of
  -- class_spacing px from class_x (one glyph each: a natural's letter, #
  -- for a sharp, . for a class out of the scale); a value's gap after its
  -- label; the levels (the selected row or class, the rest of the row, the
  -- other rows, a pending choice); the text of a row that does not apply
  local SCALE_EDITOR = {visible = 6, first_y = 18, spacing = 7, value_right = 124,
    class_x = 28, class_spacing = 8, classes = 12, value_gap = 4,
    levels = {selected = 15, row = 8, other = 4, pending = 4},
    absent = "--", sharp = "#", out = "."}
  M.SCALE_EDITOR = SCALE_EDITOR

  local ROWS = {
    {label = "root", key = "root"},
    {label = "scale", key = "scale"},
    {label = "notes", key = "notes"},
    {label = "tuning", key = "tuning"},
  }

  -- open; the cursor's row (an index into ROWS), the notes row's class (0
  -- to 11, a degree from the root), the tuning row's choices (listed at
  -- open: the built-ins, then the files' names) and the pending choice's
  -- index in them (nil: none)
  local editor = {open = false, row = 1, class = 0, choices = {}, pending = nil}

  local function variation() return S.lib.variation end
  local function tuning() return S.lib.tuning end

  -- The scale applies (twelve notes to an octave)
  local function scale_rows() return tuning().scale_active() end

  local function custom_index()
    local options = params:lookup_param("scale").options
    for index, option in ipairs(options) do
      if option == variation().VARIATION.custom_scale then return index end
    end
  end

  -- Whether degree class's bit is set in mask
  local function has_class(mask, class) return math.floor(mask / 2 ^ class) % 2 == 1 end

  -- Toggle a class (a degree from the root, 0-11) of the scale: under a
  -- built-in scale (or off) its mask goes to scale_mask first, then the
  -- scale becomes custom (one setScale, with the new mask); under custom
  -- the mask changes. The last class stays. Returns whether it changed
  local function toggle_class(class)
    if not scale_rows() then return false end
    local mask = variation().scale_mask()
    local toggled = has_class(mask, class) and mask - 2 ^ class or mask + 2 ^ class
    toggled = math.floor(toggled)
    if toggled < 1 then return false end
    params:set("scale_mask", toggled)
    if not variation().scale_is_custom() then params:set("scale", custom_index()) end
    request_redraw()
    return true
  end

  -- The note tap: while the editor is open and the scale applies, a note on
  -- toggles its class (its distance from degree 0's key, in semitones,
  -- modulo twelve) and is taken (true), so it plays nothing
  function M.note(note)
    if not editor.open or type(note) ~= "number" or not scale_rows() then return false end
    local class = (note - tuning().TUNING.root_key - variation().root()) % SCALE_EDITOR.classes
    toggle_class(class)
    return true
  end

  local function arm_tap() S.lib.midi_in.set_note_tap(M.note) end

  ---------------------------------------------------------------------------
  -- The tuning row
  ---------------------------------------------------------------------------

  -- The choices: every built-in, then every file of the folder
  local function list_choices()
    local choices = {}
    for _, entry in ipairs(tuning().built_ins()) do choices[#choices + 1] = {name = entry.name, entry = entry} end
    for _, name in ipairs(tuning().files()) do
      choices[#choices + 1] = {name = name:gsub("%." .. tuning().TUNING.extension .. "$", ""), file = name}
    end
    editor.choices = choices
  end

  -- The choice the tuning in force is (by name), or 1
  local function current_choice()
    local name = tuning().name()
    for index, choice in ipairs(editor.choices) do
      if choice.name == name then return index end
    end
    return 1
  end

  local function move_pending(d)
    if #editor.choices == 0 then return end
    local from = editor.pending or current_choice()
    editor.pending = util.clamp(from + d, 1, #editor.choices)
  end

  -- Apply the pending choice: a built-in at once; a file read first, and a
  -- refused one leaves the tuning and flashes its reason on the hint row
  local function apply_pending()
    local choice = editor.pending and editor.choices[editor.pending]
    editor.pending = nil
    if not choice then return end
    local entry = choice.entry
    if choice.file then
      local loaded, reason = tuning().load_file(choice.file)
      if not loaded then
        S.lib.ui_flash.start("hints", reason, nil, S.constants.UI_PAGES.index.SETUP)
        request_redraw()
        return
      end
      entry = loaded
    end
    tuning().select(entry)
    request_redraw()
  end

  ---------------------------------------------------------------------------
  -- The modal owner
  ---------------------------------------------------------------------------

  local owner

  local function note_name(class)
    return musicutil.NOTE_NAMES[(variation().root() + class) % SCALE_EDITOR.classes + 1]
  end

  -- A class's cell: its letter for a natural in the scale, # for a sharp,
  -- . for a class out of it
  local function class_text(mask, class)
    if not has_class(mask, class) then return SCALE_EDITOR.out end
    local name = note_name(class)
    if #name > 1 then return SCALE_EDITOR.sharp end
    return name
  end

  local function value_text(row)
    if row.key == "root" then return params:string("root") end
    if row.key == "scale" then return scale_rows() and params:string("scale") or SCALE_EDITOR.absent end
    if row.key == "tuning" then
      local choice = editor.pending and editor.choices[editor.pending]
      return choice and choice.name or tuning().name(), choice ~= nil
    end
  end

  local function draw_row(row, y, selected, value_right)
    local levels = SCALE_EDITOR.levels
    screen.level(selected and levels.selected or levels.other)
    screen.move(0, y)
    screen.text(row.label)
    if row.key == "notes" then
      if not scale_rows() then
        screen.move(value_right, y)
        screen.text_right(SCALE_EDITOR.absent)
        return
      end
      local mask = variation().scale_mask()
      for class = 0, SCALE_EDITOR.classes - 1 do
        local level = levels.other
        if selected then level = class == editor.class and levels.selected or levels.row end
        screen.level(level)
        screen.move(SCALE_EDITOR.class_x + class * SCALE_EDITOR.class_spacing, y)
        screen.text(class_text(mask, class))
      end
      return
    end
    local text, pending = value_text(row)
    local room = value_right - screen.text_extents(row.label) - SCALE_EDITOR.value_gap
    screen.level(pending and levels.pending or (selected and levels.selected or levels.other))
    screen.move(value_right, y)
    screen.text_right(S.lib.ui_text.fit_text(text, room))
  end

  local function draw()
    if not editor.open then return end
    arm_tap()  -- reset_midi_input clears the tap: each draw sets it again
    field_list.draw(ROWS, editor.row, {visible = SCALE_EDITOR.visible, first_y = SCALE_EDITOR.first_y,
      spacing = SCALE_EDITOR.spacing, value_right = SCALE_EDITOR.value_right}, draw_row)
  end

  -- The hint row: a refused file's reason while it shows; otherwise only
  -- the keys that act on the row (with ALT, E2 alone)
  local function hints(alt_held)
    local flash = S.lib.ui_flash.text("hints")
    if flash then return flash end
    if alt_held then return "E2:row" end
    local key = ROWS[editor.row].key
    if (key == "scale" or key == "notes") and not scale_rows() then return "K2:back" end
    if key == "notes" then return "K2:back E3:note K3:" .. note_name(editor.class) end
    if key == "tuning" then return editor.pending and "K2:back K3:apply E3:tuning" or "K2:back E3:tuning" end
    return "K2:back E3:value"
  end

  -- E2 the row (clamped); E3 the value under the cursor: the root and the
  -- scale through enc_param_delta, the class cursor, the pending tuning
  local function enc(n, d)
    if not editor.open then return end
    if n == 2 then
      editor.row = util.clamp(editor.row + d, 1, #ROWS)
    elseif n == 3 then
      local key = ROWS[editor.row].key
      if key == "root" then
        enc_param_delta(n, "root", d)
      elseif key == "scale" and scale_rows() then
        enc_param_delta(n, "scale", d)
      elseif key == "notes" and scale_rows() then
        editor.class = util.clamp(editor.class + d, 0, SCALE_EDITOR.classes - 1)
      elseif key == "tuning" then
        move_pending(d)
      end
    end
    request_redraw()
  end

  -- At the press: K2 closes (with ALT nothing); K3 toggles the class or
  -- applies the pending tuning
  local function key(n, z)
    if not editor.open or z ~= 1 or S.alt_held then return end
    local row_key = ROWS[editor.row].key
    if n == 2 then
      M.close()
    elseif n == 3 and row_key == "notes" then
      toggle_class(editor.class)
    elseif n == 3 and row_key == "tuning" then
      apply_pending()
    end
  end

  owner = {draw = draw, hints = hints, enc = enc, key = key}

  -- Open the editor over the page (from SETUP's scale & tuning row): the
  -- tuning row's choices listed once, nothing pending, the note tap set;
  -- already open, nothing
  function M.open()
    if editor.open then return end
    editor.open = true
    editor.pending = nil
    list_choices()
    arm_tap()
    S.lib.ui_modal.push(owner)
  end

  -- Close it: the note tap cleared, a pending choice dropped; closed, nothing
  function M.close()
    if not editor.open then return end
    editor.open = false
    editor.pending = nil
    S.lib.midi_in.set_note_tap(nil)
    S.lib.ui_modal.pop(owner)
  end

  function M.is_open()
    return editor.open
  end

  -- The closed editor's owner is never the modal one; the open editor's is
  -- (or is beneath SEQ's step editor); the cursor is on a row and a class,
  -- and a pending choice is one of the choices
  S.register_invariant("scale editor", function()
    local top = S.lib.ui_modal.top()
    if not editor.open and top == owner then return "the editor is closed but its owner is the modal one" end
    if editor.open and top ~= owner and not (top == S.lib.pages_seq.step_editor_owner and S.lib.pages_seq.step_editor()) then
      return "the editor is open but the modal owner is " .. tostring(top) .. ", not its own"
    end
    if editor.row < 1 or editor.row > #ROWS or editor.class < 0 or editor.class >= SCALE_EDITOR.classes then
      return "the cursor is on row " .. tostring(editor.row) .. ", class " .. tostring(editor.class)
    end
    if editor.pending and not editor.choices[editor.pending] then
      return "the pending choice " .. tostring(editor.pending) .. " is none of the " .. #editor.choices
    end
  end)

  return M
end

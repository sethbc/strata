-- lib/ui/voice_picker.lua
-- The voice picker (3.8, design §8.4, §12), S.lib.ui_voice_picker: a modal
-- screen owner (S.lib.ui_modal) that K3 on VOICE's preset row opens for the
-- selected voice. Its list: the six other voices, then the library's
-- VOICE_PRESETS.slots slots (S.lib.voice_presets). E2 moves (the cursor
-- kept while it is closed), E3 does nothing; K3 copies a voice row's sound
-- or loads a filled slot into the voice; ALT+K3 on a slot names it in
-- norns' textentry, opened on K3's release, and saves the voice there;
-- ALT+K2 held VOICE_PICKER.hold_seconds and released clears a slot; K2
-- goes back; cleanup closes it. Fields of this module's table: open,
-- close, is_open, VOICE_PICKER. See docs/notes/lua/ui/voice-picker.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local field_list = S.lib.ui_field_list

  -- The layout: the title at title_y, visible rows from first_y, spacing px
  -- apart, a row's type right-aligned at value_right (the scroll marker owns
  -- x 127), at least type_gap px after its text; the levels; the texts; a
  -- slot's number format; the ALT+K2 hold before a release clears
  local VOICE_PICKER = {
    title_y = 16, first_y = 24, spacing = 7, visible = 5, value_right = 124, type_gap = 4,
    levels = {title = 10, selected = 15, other = 4},
    title = "LOAD INTO VOICE ", from = "from voice ", empty = "--", unknown_type = "?", slot_format = "%02d",
    entry_heading = "preset %02d name", loaded = "loaded ", alt_voice_hint = "E2:row",
    hold_seconds = S.constants.ALT_HOLD_SECONDS,
  }
  M.VOICE_PICKER = VOICE_PICKER

  -- open; the voice it loads into; the cursor (a row index) and the view's
  -- tail, kept while it is closed; ALT+K2's press time (nil when up) and
  -- the slot ALT+K3 went down on (its release opens the name entry)
  local picker = {open = false, voice = 1, cursor = 1, tail = 0, k2_at = nil, k3_slot = nil}

  local function presets() return S.lib.voice_presets end

  -- The rows: {voice = n} for each other voice, then {slot = n}
  local function rows_for(voice_idx)
    local rows = {}
    for other = 1, NUM_VOICES do
      if other ~= voice_idx then rows[#rows + 1] = {voice = other} end
    end
    for slot = 1, presets().VOICE_PRESETS.slots do rows[#rows + 1] = {slot = slot} end
    return rows
  end

  local function current_row()
    local rows = rows_for(picker.voice)
    return rows[field_list.clamp(rows, picker.cursor)]
  end

  local function type_text(key)
    local record = S.lib.types.record(key)
    return record and record.list_name or VOICE_PICKER.unknown_type
  end

  -- A row's text and its type (nil: none)
  local function row_texts(row)
    if row.voice then return VOICE_PICKER.from .. row.voice, S.lib.types.of(row.voice).list_name end
    local number = string.format(VOICE_PICKER.slot_format, row.slot)
    local preset = presets().preset(row.slot)
    if not preset then return number .. " " .. VOICE_PICKER.empty, nil end
    return number .. " " .. preset.name, type_text(preset.type)
  end

  local function draw_row(row, y, selected, value_right)
    local levels = VOICE_PICKER.levels
    screen.level(selected and levels.selected or levels.other)
    local text, type_name = row_texts(row)
    local room = value_right
    if type_name then
      screen.move(value_right, y)
      screen.text_right(type_name)
      room = value_right - screen.text_extents(type_name) - VOICE_PICKER.type_gap
    end
    screen.move(0, y)
    -- a name as norns' font can draw it, measured as drawn (#551)
    screen.text(S.lib.ui_text.fit_text(S.lib.ui_text.printable(text), room))
  end

  local function draw()
    if not picker.open then return end
    screen.level(VOICE_PICKER.levels.title)
    screen.move(0, VOICE_PICKER.title_y)
    screen.text(VOICE_PICKER.title .. picker.voice)
    local rows = rows_for(picker.voice)
    picker.cursor = field_list.clamp(rows, picker.cursor)
    field_list.draw(rows, picker.cursor, {visible = VOICE_PICKER.visible, first_y = VOICE_PICKER.first_y,
      spacing = VOICE_PICKER.spacing, value_right = VOICE_PICKER.value_right, tail = picker.tail}, draw_row)
  end

  local function k2_held_long()
    return picker.k2_at ~= nil and util.time() - picker.k2_at >= VOICE_PICKER.hold_seconds
  end

  -- The hint row: a flash while one shows (a refused load or save); with
  -- ALT on a slot K2:clear (a filled one) and K3:save, on a voice row E2
  -- alone (ALT's K2 and K3 do nothing there, #850), ALT+K2 down K2:hold
  -- and, past the hold time, K2:clear (its release clears); without ALT
  -- K2:back and K3's act on the row (copy, load; nothing on an empty slot)
  local function hints(alt_held)
    local flash = S.lib.ui_flash.text("hints")
    if flash then return flash end
    local row = current_row()
    local filled = row.slot and presets().preset(row.slot) ~= nil
    if picker.k2_at then
      if not filled then return "K2:cancel" end
      return k2_held_long() and "K2:clear" or "K2:hold"
    end
    if alt_held then
      if not row.slot then return VOICE_PICKER.alt_voice_hint end
      return filled and "K2:clear K3:save" or "K3:save"
    end
    if row.voice then return "K2:back K3:copy" end
    return filled and "K2:back K3:load" or "K2:back"
  end

  local function animates() return picker.k2_at ~= nil end

  local function enc_handler(n, d)
    if not picker.open or n ~= 2 then return end  -- E3 does nothing
    picker.cursor, picker.tail = field_list.move_scroll(rows_for(picker.voice), picker.cursor, picker.tail, d,
      VOICE_PICKER.visible)
    request_redraw()
  end

  ---------------------------------------------------------------------------
  -- The name entry: norns' textentry through S.lib.ui_name_entry (SCENES'
  -- too, #849), which takes the global key, enc and redraw while it is
  -- open and cancels on a K2 release, opened on K3's release
  ---------------------------------------------------------------------------

  local name_entry = S.lib.ui_name_entry.new()

  -- Open the entry for slot, from its name; the text saves the voice there
  -- (S.lib.voice_presets.save), a cancel saves nothing
  local function open_name_entry(slot)
    local voice_idx = picker.voice
    local preset = presets().preset(slot)
    name_entry.open(preset and preset.name or "", string.format(VOICE_PICKER.entry_heading, slot),
      function(text) presets().save(voice_idx, slot, text) end)
  end

  -- The menu-close hook: first an ALT+K2 or ALT+K3 press the menu took
  -- (its release never comes) is forgotten, as SEQ's step editor forgets
  -- its ALT+K2 (forget_editor_k2_press); then the entry's reconcile (a menu
  -- that took the one textentry over forgets the entry; one that came and
  -- went hands it the screen back), which acts only on the picker's own
  -- entry, so SCENES' is left to SCENES
  function M.reconcile_name_entry()
    picker.k2_at, picker.k3_slot = nil, nil
    name_entry.reconcile()
  end
  S.register_menu_close(function() M.reconcile_name_entry() end)

  ---------------------------------------------------------------------------
  -- Keys
  ---------------------------------------------------------------------------

  -- K3: a voice row's sound copied, a slot's preset loaded (an empty slot:
  -- nothing, and the library's flash); what it loaded flashes on the hint
  -- row (the picker stays open, so the player sees what changed)
  local function press_k3()
    local row = current_row()
    local applied
    if row.voice then
      applied = presets().copy(row.voice, picker.voice)
    else
      applied = presets().load(picker.voice, row.slot)
    end
    if applied then
      S.lib.ui_flash.start("hints", VOICE_PICKER.loaded .. S.lib.ui_text.printable(presets().loaded_name(picker.voice)),
        nil, S.constants.UI_PAGES.index.VOICE)
    end
    request_redraw()
  end

  -- K2 (no ALT) closes at the press; ALT+K2 notes its press and acts at the
  -- release: held hold_seconds on a filled slot, it clears it. K3 (no ALT)
  -- acts at the press; ALT+K3 on a slot opens the name entry at its release
  local function key_handler(n, z)
    if not picker.open then return end
    if n == 2 then
      if z == 1 then
        if S.alt_held then picker.k2_at = util.time() else M.close() end
      elseif picker.k2_at then
        local long = k2_held_long()
        picker.k2_at = nil
        local row = current_row()
        if long and row.slot then presets().clear(row.slot) end
      end
    elseif n == 3 then
      if z == 1 then
        if S.alt_held then
          picker.k3_slot = current_row().slot
        else
          press_k3()
        end
      elseif picker.k3_slot then
        local slot = picker.k3_slot
        picker.k3_slot = nil
        open_name_entry(slot)
      end
    end
    request_redraw()
  end

  local owner = {draw = draw, hints = hints, enc = enc_handler, key = key_handler, animates = animates}

  -- Open the picker over VOICE for voice_idx (K3 on its preset row): the
  -- cursor where it was left; already open, nothing
  function M.open(voice_idx)
    if picker.open then return end
    if type(voice_idx) ~= "number" or voice_idx % 1 ~= 0 or voice_idx < 1 or voice_idx > NUM_VOICES then return end
    picker.open, picker.voice, picker.k2_at, picker.k3_slot = true, voice_idx, nil, nil
    S.lib.ui_modal.push(owner)
  end

  -- Close it (K2); closed, nothing. The cursor stays for the next open
  function M.close()
    if not picker.open then return end
    picker.open, picker.k2_at, picker.k3_slot = false, nil, nil
    S.lib.ui_modal.pop(owner)
  end

  function M.is_open() return picker.open end

  -- The cleanup step: an open picker closes, so its owner is not left on
  -- the modal stack (as the factory list's, #847)
  S.register_cleanup(S.constants.CLEANUP_ORDER.voice_picker, function() M.close() end)

  -- The open picker's owner is the modal one (or beneath SEQ's step
  -- editor), the closed picker's never; its cursor is a row of its list;
  -- a key held on it only while it is open
  S.register_invariant("voice picker", function()
    local top = S.lib.ui_modal.top()
    if not picker.open and top == owner then return "the picker is closed but its owner is the modal one" end
    if picker.open and top ~= owner and not (top == S.lib.pages_seq.step_editor_owner and S.lib.pages_seq.step_editor()) then
      return "the picker is open but the modal owner is " .. tostring(top)
    end
    local count = NUM_VOICES - 1 + presets().VOICE_PRESETS.slots
    if picker.cursor < 1 or picker.cursor > count or picker.cursor % 1 ~= 0 then
      return "the cursor is on " .. tostring(picker.cursor) .. " of " .. count
    end
    if not picker.open and (picker.k2_at ~= nil or picker.k3_slot ~= nil) then
      return "a key is held on the closed picker"
    end
  end)

  return M
end

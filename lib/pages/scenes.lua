-- lib/pages/scenes.lua
-- The SCENES page: one bank of eight of the sixteen scene slots in two
-- columns (the number, a box that is filled when the slot holds a scene,
-- the slot's name; the current scene bright, a mark at the scene
-- sequencer's position) and the seven sequencer fields below them in rows
-- of two, two rows in view, scrolled by row with the cursor (3.7 adds the
-- chances next, prev and rand). The bank shown is the cursor's slot's (on
-- a field, the last one shown). E2 runs the cursor (S.cursors.scene)
-- through the slots and then the fields, ALT+E2 jumps a bank, E3 edits (a
-- slot: the transition time), K2 recalls with the transition, K3 recalls
-- at once (both, and the arc button, through S.lib.quantize), ALT+K2's
-- release names the slot (norns'
-- textentry), ALT+K3 saves (a populated slot asks for a second ALT+K3
-- within the chosen confirmation time. The hint row shows the page's
-- prompt, and the page animates until it lapses).
-- M.move_cursor (S.lib.pages_scenes) moves the cursor for E2 and arc ring 1.
-- Registers its S.registry.pages record (every field but the arc fields,
-- which are lib/arc/scenes.lua's) and a menu-close hook for the name entry.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local NUM_SCENES = S.constants.NUM_SCENES
  local SCENE_BANK_SIZE = S.constants.SCENE_BANK_SIZE
  local SCENES_FIELDS = S.constants.SCENES_FIELDS

  local SCENES_PAGE = {
    column_x = {0, 64},          -- left edge of each column
    rows_per_column = 4,
    first_row_y = 16,            -- text baseline of a bank's first slot
    row_spacing = 8,             -- room for the cursor box between rows
    number_right = 10,           -- the number ends here (right-aligned), from the column edge
    box_offset = 11,             -- the box's x from the column edge
    box_size = 5,
    name_offset = 20,            -- the name's x from the column edge
    name_width = 42,             -- the name is cut to this
    mark_width = 5,              -- the sequencer mark before the name (">" and a space)
    cursor_width = 18,           -- the cursor box, from the column edge, around number and box
    fields_y = {48, 55},         -- the field rows' text baselines (two rows in view)
    fields_per_row = 2,          -- a field row's fields, one per column
  }

  -- The field rows: SCENES_FIELDS' stops, fields_per_row a row
  local field_rows = {}
  for index = 1, #SCENES_FIELDS do
    local row = math.ceil(index / SCENES_PAGE.fields_per_row)
    field_rows[row] = field_rows[row] or {}
    table.insert(field_rows[row], index)
  end

  -- The overwrite confirmation (the slot it was asked for and when it
  -- lapses), the bank shown last (a field shows it) and the slot the name
  -- entry is open for (nil while none is)
  S.scenes_page = {armed_slot = nil, armed_until = 0, bank = 1, naming = nil}

  -- The name entry (norns' textentry through S.lib.ui_name_entry, the
  -- voice picker's too, #849; opened on ALT+K2's release, below): naming
  -- goes back to nil whenever it closes
  local name_entry = S.lib.ui_name_entry.new(function() S.scenes_page.naming = nil end)

  -- armed_slot and naming are each nil or a slot, and naming is set exactly
  -- while the page keeps an open entry's callback
  S.register_invariant("scenes prompt", function()
    local function is_slot(slot)
      return type(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= NUM_SCENES
    end
    local slot, naming = S.scenes_page.armed_slot, S.scenes_page.naming
    if slot ~= nil and not is_slot(slot) then return "armed_slot is " .. tostring(slot) end
    if naming ~= nil and not is_slot(naming) then return "naming is " .. tostring(naming) end
    if (naming ~= nil) ~= name_entry.is_open() then
      return "naming is " .. tostring(naming) .. " but the name entry is " .. (name_entry.is_open() and "open" or "closed")
    end
  end)

  -- A bank's slot at index 1..SCENE_BANK_SIZE: its column's left edge and
  -- its row's baseline
  local function slot_position(index)
    local column = math.ceil(index / SCENES_PAGE.rows_per_column)
    local row = (index - 1) % SCENES_PAGE.rows_per_column
    return SCENES_PAGE.column_x[column], SCENES_PAGE.first_row_y + row * SCENES_PAGE.row_spacing
  end

  -- The sequencer's three chances (3.7): each field's label
  local CHANCE_LABELS = {scene_chance_next = "next", scene_chance_previous = "prev", scene_chance_random = "random"}

  -- The sequencer's field (#893): on with no slot in 1..length it can play
  -- (S.lib.scenes.playable_slots, the pass's own list), it holds a slot and
  -- recalls nothing, and the field says so
  local function sequencer_text()
    if params:get("scene_sequencer_enabled") ~= 1 then return "seq off" end
    if #S.lib.scenes.playable_slots(1, params:get("scene_sequence_length")) == 0 then return "seq on [none]" end
    return "seq on"
  end

  local function field_text(field_id)
    if field_id == "scene_transition_time" then
      return string.format("fade %.1fs", params:get(field_id))
    elseif field_id == "scene_sequencer_enabled" then
      return sequencer_text()
    elseif field_id == "scene_sequence_length" then
      return "len " .. params:get(field_id)
    elseif CHANCE_LABELS[field_id] then
      return CHANCE_LABELS[field_id] .. " " .. params:get(field_id) .. "%"
    end
    return string.format("dur %.0fs", params:get(field_id))
  end

  -- Armed: the confirmation was asked for on the cursor's slot and has not
  -- lapsed. Only then does the hint row ask and a second ALT+K3 save
  local armed_prompt  -- each arming has its own identity, even on the same slot
  local function armed()
    local state = S.scenes_page
    return armed_prompt ~= nil and state.armed_slot == S.cursors.scene and util.time() < state.armed_until
      and armed_prompt.revision == S.lib.scenes.revision(state.armed_slot)
  end

  local function disarm()
    armed_prompt = nil
    S.scenes_page.armed_slot = nil
    S.scenes_page.armed_until = 0
  end

  -- The overwrite prompt for a slot, as the hint row shows it: it names the
  -- keys that answer it (with ALT up a plain K3 recalls instead)
  local function overwrite_prompt(slot, alt_held)
    if alt_held then return "K3 again: overwrite S" .. slot end
    return "ALT+K3: overwrite S" .. slot
  end

  -- Each slot's name as drawn, cut to its room (the last cut is kept per
  -- slot, so a steady name is measured once)
  local name_cuts = {}
  local function name_cut(slot, width)
    local name = S.lib.scenes.name(slot)
    local cut = name_cuts[slot]
    if not (cut and cut.name == name and cut.width == width) then
      cut = {name = name, width = width, text = S.lib.ui_text.fit_text(name, width)}
      name_cuts[slot] = cut
    end
    return cut.text
  end

  -- The bank the page shows: the cursor's slot's, or on a field the last
  -- bank shown (S.scenes_page.bank, which move_cursor keeps)
  local function shown_bank()
    return S.lib.scenes.bank_of(S.cursors.scene) or S.scenes_page.bank
  end

  local function draw_slot(slot, index, cursor)
    local x, y = slot_position(index)
    local level = S.lib.scenes.shows_current(slot) and 15 or 4
    screen.level(level)
    screen.move(x + SCENES_PAGE.number_right, y)
    screen.text_right(tostring(slot))
    screen.rect(x + SCENES_PAGE.box_offset, y - SCENES_PAGE.box_size, SCENES_PAGE.box_size, SCENES_PAGE.box_size)
    if S.scenes[slot].populated then
      screen.fill()
    else
      screen.level(2)
      screen.stroke()
    end
    local name_x, name_width = x + SCENES_PAGE.name_offset, SCENES_PAGE.name_width
    if S.scene_sequencer_enabled and slot == S.scene_sequencer_position then
      screen.level(10)
      screen.move(name_x, y)
      screen.text(">")
      name_x, name_width = name_x + SCENES_PAGE.mark_width, name_width - SCENES_PAGE.mark_width
    end
    local name = name_cut(slot, name_width)
    if name ~= "" then
      screen.level(level)
      screen.move(name_x, y)
      screen.text(name)
    end
    if slot == cursor then
      screen.level(15)
      -- one clear pixel around the number and box, inside and out
      screen.rect(x, y - SCENES_PAGE.box_size - 2, SCENES_PAGE.cursor_width, SCENES_PAGE.box_size + 4)
      screen.stroke()
    end
  end

  -- The field rows in view below the slots, scrolled by row with the cursor
  -- (one row above it kept; on a slot, the first rows), then field_list's
  -- scroll marker at x 127 beside them
  local function draw_fields(cursor)
    local list = S.lib.ui_field_list
    local visible = #SCENES_PAGE.fields_y
    local cursor_row = cursor > NUM_SCENES and math.ceil((cursor - NUM_SCENES) / SCENES_PAGE.fields_per_row) or 1
    local first = list.first_visible(field_rows, cursor_row, visible)
    for offset = 0, math.min(visible, #field_rows - first + 1) - 1 do
      for column, index in ipairs(field_rows[first + offset]) do
        screen.level(cursor == NUM_SCENES + index and 15 or 4)
        screen.move(SCENES_PAGE.column_x[column], SCENES_PAGE.fields_y[offset + 1])
        screen.text(field_text(SCENES_FIELDS[index]))
      end
    end
    list.draw_marker(first, visible, #field_rows, SCENES_PAGE.fields_y[1] - 6, SCENES_PAGE.fields_y[visible] + 1)
  end

  local function redraw_scenes()
    local cursor = S.cursors.scene
    local first = (shown_bank() - 1) * SCENE_BANK_SIZE
    for index = 1, SCENE_BANK_SIZE do
      draw_slot(first + index, index, cursor)
    end
    draw_fields(cursor)
  end

  -- A slot's hint names only the keys that act: an empty slot's recall does
  -- nothing (naming and saving it do), and ALT+K2 and ALT+K3 on a field
  -- return at once
  local function scenes_hints(alt_held)
    if armed() then return overwrite_prompt(S.scenes_page.armed_slot, alt_held), armed_prompt end
    local cursor = S.cursors.scene
    if cursor > NUM_SCENES then return "E2:move E3:edit" end
    if alt_held then return "K2:name K3:save" end
    if not S.scenes[cursor].populated then return "empty  ALT+K3:save" end
    return "K2:fade K3:recall"
  end

  -- The frame clock draws the page every frame while this returns true: the
  -- prompt lapses with no clock of its own. Once it has lapsed (its time
  -- passed, or the cursor left its slot) it disarms and returns true once
  -- more, for the frame that takes the prompt off the hint row
  local function scenes_animates()
    if S.scenes_page.armed_slot == nil then return false end
    if not armed() then disarm() end
    return true
  end

  -- Put the scene cursor on stop `slot` (clamped to the slots and fields).
  -- A slot's bank becomes the one a field shows. A move to another stop
  -- disarms a pending overwrite confirmation (its prompt goes with it). E2,
  -- ALT+E2 and arc ring 1 (lib/arc/scenes.lua) move through it
  function M.move_cursor(slot)
    local before = S.cursors.scene
    S.lib.ui_cursors.move("scene", slot - before)
    S.scenes_page.bank = S.lib.scenes.bank_of(S.cursors.scene) or S.scenes_page.bank
    if S.cursors.scene ~= before and S.scenes_page.armed_slot then
      disarm()
      request_redraw()
    end
  end

  local function scenes_enc(n, d)
    if n == 2 then
      M.move_cursor(S.cursors.scene + d)
    elseif n == 3 then
      local cursor = S.cursors.scene
      if cursor <= NUM_SCENES then
        enc_param_delta(n, "scene_transition_time", d)
      elseif SCENES_FIELDS[cursor - NUM_SCENES] == "scene_sequencer_enabled" then
        set_binary_param("scene_sequencer_enabled", d > 0 and 1 or 0)  -- echoes to a MIDI map (#538)
      else
        enc_param_delta(n, SCENES_FIELDS[cursor - NUM_SCENES], d)
      end
    end
  end

  -- ALT+E2 on a slot jumps a bank: to the slot SCENE_BANK_SIZE away (slot 3
  -- to 11 and back), only when that slot exists, else it does nothing, so
  -- it never lands on a field. On a field row it moves one stop, as E2.
  -- ALT+E3 is E3 (fine adjustment)
  local function scenes_alt_enc(n, d)
    if n ~= 2 then return false end
    local cursor = S.cursors.scene
    if cursor > NUM_SCENES then
      M.move_cursor(cursor + d)
    else
      local target = cursor + (d > 0 and 1 or -1) * SCENE_BANK_SIZE
      if d ~= 0 and target >= 1 and target <= NUM_SCENES then M.move_cursor(target) end
    end
    return true
  end

  -- A user's recall (SCENES' keys, the arc button) goes through the
  -- quantizer (design §8.9): at once, or (with quantize_actions) at the next
  -- beat or bar. recall_scene is looked up when it runs (tests replace it)
  local function recall_quantized(slot, transition_time)
    S.lib.quantize.schedule("scene", function() recall_scene(slot, transition_time) end, "S" .. slot, slot)
  end

  local function scenes_key(n)
    local slot = S.cursors.scene
    if slot > NUM_SCENES then return end
    if n == 2 then
      recall_quantized(slot, params:get("scene_transition_time"))
    elseif n == 3 then
      recall_quantized(slot, 0)
    end
  end

  -- The name entry: norns' textentry (S.lib.ui_name_entry), which takes
  -- the global key, enc and redraw for itself while it is open (and
  -- cancels on a K2 release), so it opens on ALT+K2's release, with no
  -- modal owner. Open for `slot`, starting from its name: its text names
  -- the slot (S.lib.scenes.set_name); a cancel (nil) keeps the old name
  local function open_name_entry(slot)
    S.scenes_page.naming = slot
    name_entry.open(S.lib.scenes.name(slot), "scene " .. slot .. " name",
      function(text) S.lib.scenes.set_name(slot, text) end)
  end

  -- The menu-close hook (S.lib.ui_name_entry's reconcile: a menu that took
  -- the one textentry over forgets the entry; one that came and went hands
  -- it the screen back). A field of S.lib.pages_scenes
  function M.reconcile_name_entry()
    name_entry.reconcile()
  end
  S.register_menu_close(function() M.reconcile_name_entry() end)

  -- ALT+K3: save the cursor slot. A populated slot needs a second ALT+K3
  -- within the chosen interval on the same slot while its prompt shows.
  -- A "hints" flash showing on SCENES covers it and leaves the press
  -- only arming again; any cursor move disarms. ALT+K2 acts on its release
  -- (scenes_alt_key_release)
  local function scenes_alt_key(n)
    local slot = S.cursors.scene
    if n ~= 3 or slot > NUM_SCENES then return end
    local state = S.scenes_page
    local confirmed = armed() and S.displayed_hint_token == armed_prompt and S.lib.ui_flash.text("hints") == nil
    if S.scenes[slot].populated and not confirmed then
      armed_prompt = {revision = S.lib.scenes.revision(slot)}
      state.armed_slot = slot
      state.armed_until = util.time() + params:get("scene_confirm_seconds")
      request_redraw()
      return
    end
    disarm()
    S.lib.scenes.save(slot)
  end

  -- ALT+K2 released on a slot: open the name entry. On the release, since
  -- the entry cancels on a K2 release and K2's would reach it
  local function scenes_alt_key_release(n)
    local slot = S.cursors.scene
    if n == 2 and slot <= NUM_SCENES then open_name_entry(slot) end
  end

  -- The arc button: recall the cursor slot at once
  local function scenes_arc_button()
    if S.cursors.scene <= NUM_SCENES then recall_quantized(S.cursors.scene, 0) end
  end

  local function state(name, setup) return {name = name, setup = setup} end
  local function layout_states()
    local states = {}
    -- every slot holds a scene and the widest name (12 characters of 6 px)
    local function populate_all()
      for slot = 1, NUM_SCENES do
        capture_scene(slot)
        S.scenes[slot].name = string.rep("W", S.constants.SCENE_NAME_MAX)
      end
      S.current_scene = 3
      params:set("scene_sequencer_enabled", 1)
    end
    for cursor = 1, NUM_SCENES + #SCENES_FIELDS do
      table.insert(states, state("cursor " .. cursor, function()
        populate_all()
        S.cursors.scene = cursor
      end))
    end
    local function arm_last_slot()
      populate_all()
      S.cursors.scene = NUM_SCENES
      scenes_alt_key(3)
    end
    table.insert(states, state("armed", arm_last_slot))
    -- the renders draw each state with ALT up: this one holds it
    table.insert(states, state("armed with ALT", function()
      arm_last_slot()
      key(1, 1)
    end))
    -- bank 2 with the sequencer's mark on a named slot, and S16 current
    -- beside REC in the header
    table.insert(states, state("sequencer in bank 2", function()
      populate_all()
      S.cursors.scene = 12
      S.scene_sequencer_position = 12
    end))
    -- the sequencer on with no scene to play (#893), the cursor on its field
    table.insert(states, state("sequencer on with nothing to play", function()
      params:set("scene_sequencer_enabled", 1)
      for index, field_id in ipairs(SCENES_FIELDS) do
        if field_id == "scene_sequencer_enabled" then S.cursors.scene = NUM_SCENES + index end
      end
    end))
    table.insert(states, state("S16 current beside REC", function()
      populate_all()
      S.current_scene = NUM_SCENES
      S.cursors.scene = NUM_SCENES
      record_buffer(1)  -- a real take (3.9, #903: a slot records only with one)
    end))
    return states
  end

  -- The page's record, at SCENES's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]
  S.registry.pages[UI_PAGES.index.SCENES] = {name = "SCENES", draw = redraw_scenes, hints = scenes_hints,
    enc = scenes_enc, alt_enc = scenes_alt_enc, key = scenes_key, alt_key = scenes_alt_key,
    alt_key_release = scenes_alt_key_release, arc_button = scenes_arc_button,
    animates = scenes_animates, layout_states = layout_states()}

  return M
end

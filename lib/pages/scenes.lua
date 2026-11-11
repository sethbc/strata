-- lib/pages/scenes.lua
-- The SCENES page: the eight scene slots in two columns (number, a box that
-- is filled when the slot holds a scene, the current scene bright, a mark at
-- the scene sequencer's position) and the four sequencer fields as a 2x2
-- block below them. E2 runs the cursor (S.cursors.scene) through the slots
-- and then the fields, E3 edits (a slot: the transition time), K2 recalls
-- with the transition, K3 recalls at once, ALT+K3 saves (a populated slot
-- asks for a second ALT+K3 within 2 s: the hint row shows the page's own
-- prompt meanwhile, and the page animates until it lapses).
-- M.move_cursor (S.lib.pages_scenes) moves the cursor for E2 and arc ring 1.
-- Registers its S.registry.pages record (every field but the arc fields,
-- which are lib/arc/scenes.lua's).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local NUM_SCENES = S.constants.NUM_SCENES
  local SCENES_FIELDS = S.constants.SCENES_FIELDS

  local SCENES_PAGE = {
    column_x = {2, 66},          -- left edge of each column
    rows_per_column = 4,
    first_row_y = 16,            -- text baseline of slot 1
    row_spacing = 8,             -- room for the cursor box between rows
    box_offset = 8,              -- the box's x from the column edge
    box_size = 5,
    mark_offset = 22,            -- the sequencer mark's x from the column edge
    cursor_left = 2,             -- the cursor box's left edge, left of the column edge
    cursor_width = 21,
    fields_y = {48, 55},         -- the 2x2 block's text baselines
    arm_seconds = 2,             -- the second ALT+K3 must come within this
  }

  -- The overwrite confirmation: the slot it was asked for and when it lapses
  S.scenes_page = {armed_slot = nil, armed_until = 0}

  S.register_invariant("scenes prompt", function()
    local slot = S.scenes_page.armed_slot
    if slot ~= nil and not (type(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= NUM_SCENES) then
      return "armed_slot is " .. tostring(slot)
    end
  end)

  local function slot_position(slot)
    local column = math.ceil(slot / SCENES_PAGE.rows_per_column)
    local row = (slot - 1) % SCENES_PAGE.rows_per_column
    return SCENES_PAGE.column_x[column], SCENES_PAGE.first_row_y + row * SCENES_PAGE.row_spacing
  end

  local function field_text(field_id)
    if field_id == "scene_transition_time" then
      return string.format("fade %.1fs", params:get(field_id))
    elseif field_id == "scene_sequencer_enabled" then
      return params:get(field_id) == 1 and "seq on" or "seq off"
    elseif field_id == "scene_sequence_length" then
      return "len " .. params:get(field_id)
    end
    return string.format("dur %.0fs", params:get(field_id))
  end

  -- Armed: the confirmation was asked for on the cursor's slot and has not
  -- lapsed. Only then does the hint row ask and a second ALT+K3 save
  local function armed()
    local state = S.scenes_page
    return state.armed_slot == S.cursors.scene and util.time() < state.armed_until
  end

  local function disarm()
    S.scenes_page.armed_slot = nil
    S.scenes_page.armed_until = 0
  end

  -- The overwrite prompt for a slot, as the hint row shows it: it names the
  -- keys that answer it (with ALT up a plain K3 recalls instead)
  local function overwrite_prompt(slot, alt_held)
    if alt_held then return "K3 again: overwrite S" .. slot end
    return "ALT+K3: overwrite S" .. slot
  end

  local function redraw_scenes()
    local cursor = S.cursors.scene
    for slot = 1, NUM_SCENES do
      local x, y = slot_position(slot)
      local populated = S.scenes[slot].populated
      local level = S.lib.scenes.shows_current(slot) and 15 or 4
      screen.level(level)
      screen.move(x, y)
      screen.text(tostring(slot))
      screen.rect(x + SCENES_PAGE.box_offset, y - SCENES_PAGE.box_size, SCENES_PAGE.box_size, SCENES_PAGE.box_size)
      if populated then
        screen.fill()
      else
        screen.level(2)
        screen.stroke()
      end
      if S.scene_sequencer_enabled and slot == S.scene_sequencer_position then
        screen.level(10)
        screen.move(x + SCENES_PAGE.mark_offset, y)
        screen.text(">")
      end
      if slot == cursor then
        screen.level(15)
        -- one clear pixel around the number and box, inside and out
        screen.rect(x - SCENES_PAGE.cursor_left, y - SCENES_PAGE.box_size - 2, SCENES_PAGE.cursor_width, SCENES_PAGE.box_size + 4)
        screen.stroke()
      end
    end
    for index, field_id in ipairs(SCENES_FIELDS) do
      local column = (index - 1) % 2 + 1
      local row = math.ceil(index / 2)
      screen.level(cursor == NUM_SCENES + index and 15 or 4)
      screen.move(SCENES_PAGE.column_x[column], SCENES_PAGE.fields_y[row])
      screen.text(field_text(field_id))
    end
  end

  -- A slot's hint names only the keys that act: an empty slot's recall does
  -- nothing, and ALT+K3 on a field returns at once
  local function scenes_hints(alt_held)
    if armed() then return overwrite_prompt(S.scenes_page.armed_slot, alt_held) end
    local cursor = S.cursors.scene
    if cursor > NUM_SCENES then return "E2:move E3:edit" end
    if alt_held then return "K3:save" end
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
  -- A move to another stop disarms a pending overwrite confirmation (its
  -- prompt goes with it). E2 and arc ring 1 (lib/arc/scenes.lua) move through it
  function M.move_cursor(slot)
    local before = S.cursors.scene
    S.lib.ui_cursors.move("scene", slot - before)
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
        params:set("scene_sequencer_enabled", d > 0 and 1 or 0)
      else
        enc_param_delta(n, SCENES_FIELDS[cursor - NUM_SCENES], d)
      end
    end
  end

  local function scenes_key(n)
    local slot = S.cursors.scene
    if slot > NUM_SCENES then return end
    if n == 2 then
      recall_scene(slot, params:get("scene_transition_time"))
    elseif n == 3 then
      recall_scene(slot, 0)
    end
  end

  -- ALT+K3: save the cursor slot. A populated slot needs a second ALT+K3
  -- within arm_seconds on the same slot while its prompt shows on the hint
  -- row: a "hints" flash showing on SCENES covers it and leaves the press
  -- only arming again; any cursor move disarms
  local function scenes_alt_key(n)
    local slot = S.cursors.scene
    if n ~= 3 or slot > NUM_SCENES then return end
    local state = S.scenes_page
    if S.scenes[slot].populated and not (armed() and S.lib.ui_flash.text("hints") == nil) then
      state.armed_slot = slot
      state.armed_until = util.time() + SCENES_PAGE.arm_seconds
      request_redraw()
      return
    end
    disarm()
    S.lib.scenes.save(slot)
  end

  -- The arc button: recall the cursor slot at once
  local function scenes_arc_button()
    if S.cursors.scene <= NUM_SCENES then recall_scene(S.cursors.scene, 0) end
  end

  local function state(name, setup) return {name = name, setup = setup} end
  local function layout_states()
    local states = {}
    local function populate_all()
      for slot = 1, NUM_SCENES do capture_scene(slot) end
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
      S.scenes_page.armed_slot = NUM_SCENES
      S.scenes_page.armed_until = util.time() + SCENES_PAGE.arm_seconds
    end
    table.insert(states, state("armed", arm_last_slot))
    -- the renders draw each state with ALT up: this one holds it
    table.insert(states, state("armed with ALT", function()
      arm_last_slot()
      key(1, 1)
    end))
    return states
  end

  -- The page's record, at SCENES's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]
  S.registry.pages[UI_PAGES.index.SCENES] = {name = "SCENES", draw = redraw_scenes, hints = scenes_hints,
    enc = scenes_enc, key = scenes_key, alt_key = scenes_alt_key, arc_button = scenes_arc_button,
    animates = scenes_animates, layout_states = layout_states()}

  return M
end

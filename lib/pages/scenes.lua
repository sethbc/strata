-- lib/pages/scenes.lua
-- The SCENES page: the eight scene slots in two columns (number, a box that
-- is filled when the slot holds a scene, the current scene bright, a mark at
-- the scene sequencer's position) and the four sequencer fields as a 2x2
-- block below them. E2 runs the cursor (S.cursors.scene) through the slots
-- and then the fields, E3 edits (a slot: the transition time), K2 recalls
-- with the transition, K3 recalls at once, ALT+K3 saves (a populated slot
-- asks for a second ALT+K3 within 2 s, while its prompt still shows).
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

  -- The confirmation counts only on the slot it was asked for
  local function armed_here()
    return S.scenes_page.armed_slot == S.cursors.scene
  end

  local function redraw_scenes()
    if S.scenes_page.armed_slot and not armed_here() then
      S.scenes_page.armed_slot = nil
      S.lib.ui_flash.start("hints", nil)
    end
    local cursor = S.cursors.scene
    for slot = 1, NUM_SCENES do
      local x, y = slot_position(slot)
      local populated = S.scenes[slot].populated
      local level = slot == S.current_scene and 15 or 4
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

  local function scenes_hints(alt_held)
    if S.scenes_page.armed_slot and not armed_here() then
      S.scenes_page.armed_slot = nil
      S.lib.ui_flash.start("hints", nil)
    end
    if alt_held then return "K3:save" end
    if S.cursors.scene > NUM_SCENES then return "E2:move E3:edit" end
    return "K2:fade K3:recall"
  end

  local function disarm()
    S.scenes_page.armed_slot = nil
    S.scenes_page.armed_until = 0
  end

  -- The overwrite prompt for a slot, as the hint row shows it
  local function overwrite_prompt(slot)
    return "K3 again: overwrite S" .. slot
  end

  -- Put the scene cursor on stop `slot` (clamped to the slots and fields).
  -- A move to another stop disarms a pending overwrite confirmation and
  -- clears its prompt. E2 and arc ring 1 (lib/arc/scenes.lua) move through it
  function M.move_cursor(slot)
    local before = S.cursors.scene
    S.lib.ui_cursors.move("scene", slot - before)
    if S.cursors.scene ~= before and S.scenes_page.armed_slot then
      disarm()
      S.lib.ui_flash.start("hints", nil)
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
  -- within arm_seconds on the same slot while its prompt still shows on the
  -- hint row (another flash that replaced it, a failed buffer load say,
  -- leaves the press only arming again); any cursor move disarms
  local function scenes_alt_key(n)
    local slot = S.cursors.scene
    if n ~= 3 or slot > NUM_SCENES then return end
    local state = S.scenes_page
    if S.scenes[slot].populated then
      local confirmed = state.armed_slot == slot and util.time() < state.armed_until
        and S.lib.ui_flash.text("hints") == overwrite_prompt(slot)
      if not confirmed then
        state.armed_slot = slot
        state.armed_until = util.time() + SCENES_PAGE.arm_seconds
        S.lib.ui_flash.start("hints", overwrite_prompt(slot), SCENES_PAGE.arm_seconds, UI_PAGES.index.SCENES)
        return
      end
    end
    disarm()
    S.lib.ui_flash.start("hints", nil)
    capture_scene(slot)
    grid_redraw()
    request_redraw()
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
    table.insert(states, state("armed", function()
      populate_all()
      S.cursors.scene = 8
      S.lib.ui_flash.start("hints", overwrite_prompt(8), SCENES_PAGE.arm_seconds, UI_PAGES.index.SCENES)
    end))
    return states
  end

  -- The page's record, at SCENES's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]
  S.registry.pages[UI_PAGES.index.SCENES] = {name = "SCENES", draw = redraw_scenes, hints = scenes_hints,
    enc = scenes_enc, key = scenes_key, alt_key = scenes_alt_key, arc_button = scenes_arc_button,
    layout_states = layout_states()}

  return M
end

-- lib/grid/layout_128h.lua
-- The 16x8 grid: its four pages (1 patterns, 2 faders, 3 scenes, 4 sources
-- and buffer slots), keys and LEDs. Row 8 works on every page. Registers
-- S.registry.grid_layouts["128h"]. The functions stay global.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_SCENES = S.constants.NUM_SCENES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS
  local grid_core = S.lib.grid_core
  local FADER_ROWS = grid_core.GRID_LAYOUT.fader_rows

  -- Where things sit on the 16x8 (columns and rows, 1-based)
  local LAYOUT_128H = {
    control_row = 8,          -- row 8, every page
    play_last_column = 4,     -- columns 1-4 play/stop
    page_first_column = 5,    -- columns 5-8 pages 1-4
    num_pages = 4,
    voice_first_column = 9,   -- columns 9-15 voice on/off
    voice_cycle_column = 16,  -- the next voice for page 2's faders
    -- page 2: faders on rows 1-4 (FADER_ROWS), then these rows
    fader_page_row = 5,
    voice_select_row = 6,
    lock_row = 7,
    -- page 4: voice v's sources on row v (columns 1-10, as the 256's rows
    -- 9-15), slots 1-4 then 5-8 on columns 13-16: record on rows 1-2,
    -- clear on rows 3-4
    slot_first_column = 13,
    slot_columns = 4,
    record_first_row = 1,
    clear_first_row = 3,
  }
  M.LAYOUT = LAYOUT_128H
  local SLOT_ROWS = math.ceil(NUM_BUFFERS / LAYOUT_128H.slot_columns)

  -- Page 4: the slot a key in the record or clear block names, and whether
  -- it records; nil outside the blocks
  local function slot_key(x, y)
    local column = x - LAYOUT_128H.slot_first_column + 1
    if column < 1 or column > LAYOUT_128H.slot_columns then return nil end
    local record_row = y - LAYOUT_128H.record_first_row + 1
    local clear_row = y - LAYOUT_128H.clear_first_row + 1
    if record_row >= 1 and record_row <= SLOT_ROWS then
      return (record_row - 1) * LAYOUT_128H.slot_columns + column, true
    elseif clear_row >= 1 and clear_row <= SLOT_ROWS then
      return (clear_row - 1) * LAYOUT_128H.slot_columns + column, false
    end
    return nil
  end

  -- A slot's column and its row in the record block (add the clear block's
  -- offset for its clear key)
  local function slot_position(slot)
    local column = LAYOUT_128H.slot_first_column + (slot - 1) % LAYOUT_128H.slot_columns
    local row = math.floor((slot - 1) / LAYOUT_128H.slot_columns)
    return column, row
  end

  -- Page 2, rows 1-7
  local function fader_page_key(x, y)
    if y >= 1 and y <= FADER_ROWS then
      set_fader_param(S.grid_voice_select, (S.param_page - 1) * FADER_ROWS + y, x)
    elseif y == LAYOUT_128H.fader_page_row then
      if x <= fader_page_count(S.grid_voice_select) then S.param_page = x end
    elseif y == LAYOUT_128H.voice_select_row then
      if x <= NUM_VOICES then select_grid_voice(x) end
    elseif y == LAYOUT_128H.lock_row then
      if x <= NUM_VOICES then toggle_lock(x) end
    end
  end

  -- Page 4, rows 1-7
  local function source_page_key(x, y)
    local slot, records = slot_key(x, y)
    if slot then
      if records then grid_core.record_key(slot) else grid_core.clear_key(slot) end
    elseif y >= 1 and y <= NUM_VOICES and x <= #SOURCE_OPTIONS then
      grid_core.source_key(y, x)
    end
  end

  -- Page 3, rows 1-5
  local function scene_page_key(port, x, y, z)
    if y == 1 and x <= NUM_SCENES then
      -- Row 1: Scene recall (instant)
      recall_scene(x, 0)
    elseif y == 2 and x <= NUM_SCENES then
      -- Row 2: Scene recall (with transition)
      recall_scene(x, params:get("scene_transition_time"))
    elseif y == 3 and x <= NUM_SCENES then
      -- Row 3: Scene save, once held
      grid_core.scene_save_key(port, x, y, z, x)
    elseif y == 4 and x <= NUM_SCENES then
      -- Row 4: Set sequence length
      params:set("scene_sequence_length", x)
    elseif y == 5 and x == 1 then
      -- Toggle scene sequencer
      local enabled = params:get("scene_sequencer_enabled")
      params:set("scene_sequencer_enabled", enabled == 1 and 0 or 1)
    end
  end

  -- Row 8, every page
  local function control_row_key(port, x)
    local page_offset = x - LAYOUT_128H.page_first_column + 1
    local voice_offset = x - LAYOUT_128H.voice_first_column + 1
    if x <= LAYOUT_128H.play_last_column then
      pattern_toggle()
    elseif page_offset >= 1 and page_offset <= LAYOUT_128H.num_pages then
      grid_core.set_page(port, page_offset)
    elseif voice_offset >= 1 and voice_offset <= NUM_VOICES then
      toggle_voice(voice_offset)
    elseif x == LAYOUT_128H.voice_cycle_column then
      select_grid_voice(S.grid_voice_select % NUM_VOICES + 1)
    end
  end

  -- 16x8 grid layout (128 buttons horizontal)
  function grid_key_128h(port, x, y, z)
    if z == 0 then return end  -- presses only
    if y == LAYOUT_128H.control_row then
      control_row_key(port, x)
      return
    end
    local page = grid_core.page(port)
    if page == 2 then
      fader_page_key(x, y)
    elseif page == 3 then
      scene_page_key(port, x, y, z)
    elseif page == 4 then
      source_page_key(x, y)
    elseif y >= 1 and y <= NUM_VOICES then
      -- Rows 1-7: Pattern triggers
      grid_core.step_key(port, x, y, z, y, x, x, PATTERN_LENGTH)
    end
  end

  -- Page 2: faders on rows 1-4 (a bar at 8 up to the value at 15), the
  -- fader pages on row 5 (selected 15), voice select on row 6 (selected 15,
  -- others 4), lock on row 7 (locked 12, others 2)
  local function redraw_fader_page(grid_device)
    local ids = fader_param_ids(S.grid_voice_select)
    for row = 1, FADER_ROWS do
      local param_id = ids[(S.param_page - 1) * FADER_ROWS + row]
      if param_id then grid_redraw_fader_row(grid_device, row, param_id) end
    end
    for fader_page = 1, fader_page_count(S.grid_voice_select) do
      grid_device:led(fader_page, LAYOUT_128H.fader_page_row, fader_page == S.param_page and 15 or 4)
    end
    for i = 1, NUM_VOICES do
      grid_device:led(i, LAYOUT_128H.voice_select_row, i == S.grid_voice_select and 15 or 4)
      grid_device:led(i, LAYOUT_128H.lock_row, S.frozen[i] and 12 or 2)
    end
  end

  -- Page 3: the scenes (simplified from the 256's)
  local function redraw_scene_page(port, grid_device)
    for i = 1, NUM_SCENES do
      -- Row 1: Scene recall (instant)
      local brightness = S.scenes[i].populated and 8 or 2
      if S.current_scene == i then brightness = 15 end
      grid_device:led(i, 1, brightness)
      -- Row 2: Scene recall (with transition)
      grid_device:led(i, 2, S.scenes[i].populated and 6 or 2)
      -- Row 3: Scene save (15 while a save is held)
      grid_device:led(i, 3, grid_core.hold_pending(port, i, 3) and 15 or 4)
    end

    -- Row 4: Sequence length
    local seq_length = params:get("scene_sequence_length")
    for i = 1, NUM_SCENES do
      grid_device:led(i, 4, i <= seq_length and 8 or 2)
    end

    -- Row 5: Scene sequencer on/off
    grid_device:led(1, 5, S.scene_sequencer_enabled and 15 or 4)
  end

  -- Page 4: each voice's source (selected 15, empty buffers 2, others 4),
  -- the record keys (15 recording, 8 holding audio, 2 empty) and the clear
  -- keys
  local function redraw_source_page(grid_device)
    for voice_idx = 1, NUM_VOICES do
      for option = 1, #SOURCE_OPTIONS do
        grid_device:led(option, voice_idx, grid_core.source_level(voice_idx, option))
      end
    end
    for slot = 1, NUM_BUFFERS do
      local column, row = slot_position(slot)
      grid_device:led(column, LAYOUT_128H.record_first_row + row, grid_core.record_level(slot))
      grid_device:led(column, LAYOUT_128H.clear_first_row + row, grid_core.CLEAR_LEVEL)
    end
  end

  -- Row 8: play/stop, the pages (shown 15), the voices (running 12) and the
  -- voice cycle key
  local function redraw_control_row(page, grid_device)
    local y = LAYOUT_128H.control_row
    for x = 1, LAYOUT_128H.play_last_column do
      grid_device:led(x, y, S.pattern_playing and 15 or 4)
    end
    for i = 1, LAYOUT_128H.num_pages do
      grid_device:led(LAYOUT_128H.page_first_column + i - 1, y, i == page and 15 or 4)
    end
    for i = 1, NUM_VOICES do
      grid_device:led(LAYOUT_128H.voice_first_column + i - 1, y, S.voices[i].active and 12 or 2)
    end
    grid_device:led(LAYOUT_128H.voice_cycle_column, y, 8)
  end

  function grid_redraw_128h(port, grid_device)
    local page = grid_core.page(port)
    if page == 2 then
      redraw_fader_page(grid_device)
    elseif page == 3 then
      redraw_scene_page(port, grid_device)
    elseif page == 4 then
      redraw_source_page(grid_device)
    else
      -- Patterns (rows 1-NUM_VOICES)
      for voice_idx = 1, NUM_VOICES do
        for step = 1, PATTERN_LENGTH do
          grid_device:led(step, voice_idx, step_brightness(voice_idx, step))
        end
      end
    end
    redraw_control_row(page, grid_device)
  end

  S.registry.grid_layouts["128h"] = {key = grid_key_128h, redraw = grid_redraw_128h}

  return M
end

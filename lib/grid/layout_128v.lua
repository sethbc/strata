-- lib/grid/layout_128v.lua
-- The 8x16 grid: five pages (1 patterns, 2 faders, 3 scenes, 4 sources and freeze,
-- 5 positions),
-- cycled by (8,8), keys and LEDs. Column 8 rows 1-7 and 9 work on every
-- page. Registers S.registry.grid_layouts["128v"]. The functions stay
-- global.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_SCENES = S.constants.NUM_SCENES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS
  local grid_core = S.lib.grid_core
  local GRID_LAYOUT = grid_core.GRID_LAYOUT

  -- The 128v's geometry and LED levels
  local LAYOUT_128V = {
    pages = {PATTERNS = 1, FADERS = 2, SCENES = 3, SOURCES = 4, POSITIONS = 5},
    page_count = 5,
    page_levels = {3, 6, 9, 12, 15},  -- (8,8) shows the page
    control_column = 8,
    page_key_row = 8,
    play_row = 9,
    voice_select_first_row = 10,   -- rows 10-16: voices 1-7 (pages 1-3)
    -- faders page: columns 1-4 faders (row 16 minimum, row 1 maximum),
    -- column 5 the fader page selector
    fader_page_column = 5,
    fader_bottom_row = 16,
    -- column 7 rows 10-16: voices 1-7's lock keys (locked 12, others 2)
    lock_column = 7,
    lock_first_row = 10,
    locked_level = 12,
    unlocked_level = 2,
    -- scenes page
    scene_recall_column = 1,
    scene_fade_column = 2,
    scene_save_column = 3,
    scene_sequencer_column = 4,
    scene_sequencer_row = 1,
    scene_length_first_row = 9,    -- rows 9-16: lengths 1-8
    scene_position_level = 10,
    -- sources page: rows 1-10 the source options, row 12 record, row 13
    -- clear, row 14 each voice's freeze key (S.lib.freeze)
    record_row = 12,
    clear_row = 13,
    freeze_row = 14,
    frozen_level = 15,
    unfrozen_level = 3,
    -- positions page: columns 1-7 the voices' 16 position cells down; column 8
    -- rows 10-16 the grid voice's strip: bookmarks 1-4, store, hold, whole
    position_cells = 16,
    strip_first_row = 10,
    strip_keys = {1, 2, 3, 4, "store", "hold", "whole"},
  }
  M.LAYOUT = LAYOUT_128V
  local PAGES = LAYOUT_128V.pages

  -- The fader index (into fader_param_ids) of column x on the faders page
  local function fader_index(x)
    return (S.param_page - 1) * GRID_LAYOUT.fader_rows + x
  end

  -- A fader key's row as the 256's column: row 16 is column 1 (minimum),
  -- row 1 column 16 (maximum)
  local function fader_column_for_row(y)
    return LAYOUT_128V.fader_bottom_row + 1 - y
  end

  local function grid_key_128v_faders(x, y)
    if x <= GRID_LAYOUT.fader_rows then
      set_fader_param(S.grid_voice_select, fader_index(x), fader_column_for_row(y))
    elseif x == LAYOUT_128V.fader_page_column and y <= fader_page_count(S.grid_voice_select) then
      S.param_page = y
    elseif x == LAYOUT_128V.lock_column and y >= LAYOUT_128V.lock_first_row then
      toggle_lock(y - LAYOUT_128V.lock_first_row + 1)
    end
  end

  local function grid_key_128v_scenes(port, x, y, z)
    if x == LAYOUT_128V.scene_recall_column and y <= NUM_SCENES then
      recall_scene(y, 0)
    elseif x == LAYOUT_128V.scene_fade_column and y <= NUM_SCENES then
      recall_scene(y, params:get("scene_transition_time"))
    elseif x == LAYOUT_128V.scene_save_column and y <= NUM_SCENES then
      grid_core.scene_save_key(port, x, y, z, y)
    elseif x == LAYOUT_128V.scene_sequencer_column then
      local length = y - LAYOUT_128V.scene_length_first_row + 1
      if y == LAYOUT_128V.scene_sequencer_row then
        local enabled = params:get("scene_sequencer_enabled")
        params:set("scene_sequencer_enabled", enabled == 1 and 0 or 1)
      elseif length >= 1 and length <= NUM_SCENES then
        params:set("scene_sequence_length", length)
      end
    end
  end

  local function grid_key_128v_sources(x, y)
    if x <= NUM_VOICES and y <= #SOURCE_OPTIONS then
      grid_core.source_key(x, y)
    elseif y == LAYOUT_128V.record_row then
      grid_core.record_key(x)
    elseif y == LAYOUT_128V.clear_row then
      grid_core.clear_key(x)
    elseif y == LAYOUT_128V.freeze_row and x <= NUM_VOICES then
      S.lib.freeze.toggle(x)
    end
  end

  -- Column 8: voices 1-7, the page key, play / stop, and voice select on
  -- pages 1-3 (the sources page uses rows 12-13 for slot 8)
  local function grid_key_128v_controls(port, y, page, z)
    if y <= NUM_VOICES then
      toggle_voice(y)
    elseif y == LAYOUT_128V.page_key_row then
      grid_core.set_page(port, page % LAYOUT_128V.page_count + 1)
    elseif y == LAYOUT_128V.play_row then
      pattern_toggle()
    elseif page == PAGES.POSITIONS then
      local key = LAYOUT_128V.strip_keys[y - LAYOUT_128V.strip_first_row + 1]
      if key then S.lib.positions.strip_key(port, S.grid_voice_select, key, z) end
    elseif page ~= PAGES.SOURCES then
      select_grid_voice(y - LAYOUT_128V.voice_select_first_row + 1)
    else
      grid_key_128v_sources(LAYOUT_128V.control_column, y)
    end
  end

  -- 8x16 grid layout (128 buttons vertical)
  function grid_key_128v(port, x, y, z)
    local page = grid_core.page(port)
    if page == PAGES.POSITIONS then
      -- the positions page needs releases (held loop and strip keys)
      if x == LAYOUT_128V.control_column then
        if z == 1 or y >= LAYOUT_128V.strip_first_row then grid_key_128v_controls(port, y, page, z) end
      elseif x <= NUM_VOICES and y <= LAYOUT_128V.position_cells then
        S.lib.positions.grid_key(port, x, y, LAYOUT_128V.position_cells, z)
      end
      return
    end
    if z == 0 then return end  -- presses only
    if x == LAYOUT_128V.control_column then
      grid_key_128v_controls(port, y, page, z)
    elseif page == PAGES.FADERS then
      grid_key_128v_faders(x, y)
    elseif page == PAGES.SCENES then
      grid_key_128v_scenes(port, x, y, z)
    elseif page == PAGES.SOURCES then
      grid_key_128v_sources(x, y)
    elseif x <= NUM_VOICES and y <= PATTERN_LENGTH then
      -- Pattern triggers (levels follow the 16 rows)
      grid_core.step_key(port, x, y, z, x, y, y, PATTERN_LENGTH)
    end
  end

  local function grid_redraw_128v_patterns(grid_device)
    for voice_idx = 1, NUM_VOICES do
      for step = 1, PATTERN_LENGTH do
        grid_device:led(voice_idx, step, step_brightness(voice_idx, step))
      end
    end
  end

  -- One vertical fader in column x: a bar (8) up from row 16 to the value's
  -- row, which is at 15
  local function grid_redraw_128v_fader(grid_device, x, param_id)
    local row = fader_column_for_row(fader_position(param_id))
    for y = row + 1, LAYOUT_128V.fader_bottom_row do
      grid_device:led(x, y, 8)
    end
    grid_device:led(x, row, 15)
  end

  local function grid_redraw_128v_faders(grid_device)
    local ids = fader_param_ids(S.grid_voice_select)
    for x = 1, GRID_LAYOUT.fader_rows do
      local param_id = ids[fader_index(x)]
      if param_id then grid_redraw_128v_fader(grid_device, x, param_id) end
    end
    for voice_idx = 1, NUM_VOICES do
      grid_device:led(LAYOUT_128V.lock_column, LAYOUT_128V.lock_first_row + voice_idx - 1,
        S.frozen[voice_idx] and LAYOUT_128V.locked_level or LAYOUT_128V.unlocked_level)
    end
    for page = 1, fader_page_count(S.grid_voice_select) do
      grid_device:led(LAYOUT_128V.fader_page_column, page, page == S.param_page and 15 or 4)
    end
  end

  local function grid_redraw_128v_scenes(port, grid_device)
    -- the scene the running sequencer recalls next at 10 (#303)
    local next_slot = S.lib.scenes.sequencer_next_slot()
    for i = 1, NUM_SCENES do
      local recall_level = S.scenes[i].populated and 8 or 2
      if i == next_slot then recall_level = LAYOUT_128V.scene_position_level end
      if S.lib.scenes.shows_current(i) then recall_level = 15 end
      grid_device:led(LAYOUT_128V.scene_recall_column, i, recall_level)
      grid_device:led(LAYOUT_128V.scene_fade_column, i, S.scenes[i].populated and 6 or 2)
      local save_column = LAYOUT_128V.scene_save_column
      grid_device:led(save_column, i, grid_core.hold_pending(port, save_column, i) and 15 or 4)
    end
    local sequencer_column = LAYOUT_128V.scene_sequencer_column
    grid_device:led(sequencer_column, LAYOUT_128V.scene_sequencer_row, S.scene_sequencer_enabled and 15 or 4)
    local length = params:get("scene_sequence_length")
    for i = 1, NUM_SCENES do
      grid_device:led(sequencer_column, LAYOUT_128V.scene_length_first_row + i - 1, i <= length and 8 or 2)
    end
  end

  local function grid_redraw_128v_sources(grid_device)
    for voice_idx = 1, NUM_VOICES do
      for option = 1, #SOURCE_OPTIONS do
        grid_device:led(voice_idx, option, grid_core.source_level(voice_idx, option))
      end
    end
    for slot = 1, NUM_BUFFERS do
      grid_device:led(slot, LAYOUT_128V.record_row, grid_core.record_level(slot))
      grid_device:led(slot, LAYOUT_128V.clear_row, grid_core.CLEAR_LEVEL)
    end
    for voice_idx = 1, NUM_VOICES do
      grid_device:led(voice_idx, LAYOUT_128V.freeze_row,
        S.lib.freeze.is_frozen(voice_idx) and LAYOUT_128V.frozen_level or LAYOUT_128V.unfrozen_level)
    end
  end

  local function grid_redraw_128v_positions(port, grid_device)
    for voice_idx = 1, NUM_VOICES do
      for cell = 1, LAYOUT_128V.position_cells do
        grid_device:led(voice_idx, cell, S.lib.positions.grid_level(voice_idx, cell, LAYOUT_128V.position_cells))
      end
    end
    for i, key in ipairs(LAYOUT_128V.strip_keys) do
      grid_device:led(LAYOUT_128V.control_column, LAYOUT_128V.strip_first_row + i - 1,
        S.lib.positions.strip_level(S.grid_voice_select, key, port))
    end
  end

  local function grid_redraw_128v_controls(grid_device, page)
    local column = LAYOUT_128V.control_column
    for i = 1, NUM_VOICES do
      grid_device:led(column, i, S.voices[i].active and 12 or 4)
    end
    grid_device:led(column, LAYOUT_128V.page_key_row, LAYOUT_128V.page_levels[page])
    grid_device:led(column, LAYOUT_128V.play_row, S.pattern_playing and 15 or 4)
    if page == PAGES.SOURCES or page == PAGES.POSITIONS then return end  -- slot 8's keys, the strip
    for i = 1, NUM_VOICES do
      grid_device:led(column, LAYOUT_128V.voice_select_first_row + i - 1, i == S.grid_voice_select and 15 or 2)
    end
  end

  function grid_redraw_128v(port, grid_device)
    local page = grid_core.page(port)
    if page == PAGES.FADERS then
      grid_redraw_128v_faders(grid_device)
    elseif page == PAGES.SCENES then
      grid_redraw_128v_scenes(port, grid_device)
    elseif page == PAGES.SOURCES then
      grid_redraw_128v_sources(grid_device)
    elseif page == PAGES.POSITIONS then
      grid_redraw_128v_positions(port, grid_device)
    else
      grid_redraw_128v_patterns(grid_device)
    end
    grid_redraw_128v_controls(grid_device, page)
  end

  -- selects_grid_voice: one strip, for the grid voice (S.lib.positions)
  S.registry.grid_layouts["128v"] = {key = grid_key_128v, redraw = grid_redraw_128v, selects_grid_voice = true}

  return M
end

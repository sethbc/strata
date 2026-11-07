-- lib/grid/layout_256.lua
-- The 16x16 grid: its four pages (1 patterns, 2 parameters, 3 scenes,
-- 4 buffers / FX), keys and LEDs. Registers S.registry.grid_layouts["256"].
-- The functions stay global.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_SCENES = S.constants.NUM_SCENES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS
  local grid_core = S.lib.grid_core
  local GRID_LAYOUT = grid_core.GRID_LAYOUT

  -- 16x16 grid layout
  function grid_key_256(port, x, y, z)
    if z == 0 then return end  -- presses only
    local page = grid_core.page(port)
    -- Handle page navigation first (always accessible from row 8)
    if y == 8 and x >= 13 and x <= 16 then
      -- Page selection (always accessible)
      grid_core.set_page(port, x - 12)
      return
    end

    if page == 3 then
      -- Scene page
      if y == 1 and x <= NUM_SCENES then
        -- Row 1: Scene recall (instant)
        recall_scene(x, 0)
      elseif y == 2 and x <= NUM_SCENES then
        -- Row 2: Scene recall (with transition)
        recall_scene(x, params:get("scene_transition_time"))
      elseif y == 3 and x <= NUM_SCENES then
        -- Row 3: Scene save, once held
        grid_core.scene_save_key(port, x, y, z, x)
      elseif y == 5 then
        -- Row 5: Scene sequencer controls
        if x == 1 then
          -- Toggle sequencer
          local enabled = params:get("scene_sequencer_enabled")
          params:set("scene_sequencer_enabled", enabled == 1 and 0 or 1)
        elseif x >= 3 and x <= 2 + NUM_SCENES then
          -- Set sequence length
          params:set("scene_sequence_length", x - 2)
        end
      end
    elseif page == 4 then
      -- BUFFER / FX page: buffer rows 1-2, FX faders on rows 3-7, voice
      -- sources on rows 9-15; rows 8 and 16 work as on page 1
      local fx_param_id = GRID_LAYOUT.fx_fader_ids[y - GRID_LAYOUT.fx_first_row + 1]
      local source_voice = y - GRID_LAYOUT.source_first_row + 1
      if y == GRID_LAYOUT.buffer_record_row then
        -- record into buffer x, or stop its recording early
        grid_core.record_key(x)
      elseif y == GRID_LAYOUT.buffer_clear_row then
        grid_core.clear_key(x)
      elseif fx_param_id then
        set_param_from_column(fx_param_id, x)
      elseif source_voice >= 1 and source_voice <= NUM_VOICES then
        grid_core.source_key(source_voice, x)
      elseif y == 8 then
        grid_key_256_transport(x)
      elseif y == 16 then
        grid_key_256_lock(x)
      end
    elseif y >= 1 and y <= NUM_VOICES then
      -- Rows 1-NUM_VOICES: Pattern triggers for each voice
      grid_core.step_key(port, x, y, z, y, x, x, PATTERN_LENGTH)
    elseif y == 8 then
      grid_key_256_transport(x)
    elseif y >= GRID_LAYOUT.fader_first_row and y < GRID_LAYOUT.fader_first_row + GRID_LAYOUT.fader_rows then
      -- Rows 9-12 (parameter page): one fader per row for the selected voice
      if page == 2 then
        local fader_index = (S.param_page - 1) * GRID_LAYOUT.fader_rows + (y - GRID_LAYOUT.fader_first_row + 1)
        set_fader_param(S.grid_voice_select, fader_index, x)
      end
    elseif y == GRID_LAYOUT.param_page_row then
      -- Row 13 (parameter page): choose which group of four faders is shown
      if page == 2 and x <= fader_page_count(S.grid_voice_select) then
        S.param_page = x
      end
    elseif y == 14 then
      -- Row 14: Voice selection for parameters (columns 1-7), voice
      -- on/off (columns 9-15)
      if x <= NUM_VOICES then
        select_grid_voice(x)
      elseif x >= 9 and x <= 8 + NUM_VOICES then
        toggle_voice(x - 8)
      end
    elseif y == 15 then
      -- Row 15: Pattern operations
      if x <= NUM_VOICES then
        -- Clear pattern for voice
        clear_pattern(x)
      elseif x >= 9 and x <= 8 + NUM_VOICES then
        -- Randomize pattern for voice
        randomize_pattern(x - 8)
      end
    elseif y == 16 then
      grid_key_256_lock(x)
    end
  end

  -- 256 row 8: pattern controls (page selection is handled by grid_key_256)
  function grid_key_256_transport(x)
    if x <= 4 then
      -- Play/stop
      pattern_toggle()
    elseif x >= 5 and x <= 8 then
      -- Tempo controls
      if x == 5 then params:delta("tempo", -10) end
      if x == 6 then params:delta("tempo", -1) end
      if x == 7 then params:delta("tempo", 1) end
      if x == 8 then params:delta("tempo", 10) end
    end
  end

  -- 256 row 16: global functions
  function grid_key_256_lock(x)
    if x <= NUM_VOICES then
      -- Lock voice
      toggle_lock(x)
    elseif x >= 9 and x <= 16 then
      -- Copy/paste patterns
      -- (Future expansion)
    end
  end

  function grid_redraw_256(port, grid_device)
    local page = grid_core.page(port)
    if page == 3 then
      -- Scene page
      -- Row 1: Scene recall (instant)
      for i = 1, NUM_SCENES do
        local brightness = S.scenes[i].populated and 8 or 2
        if S.current_scene == i then brightness = 15 end
        grid_device:led(i, 1, brightness)
      end

      -- Row 2: Scene recall (with transition)
      for i = 1, NUM_SCENES do
        local brightness = S.scenes[i].populated and 6 or 2
        grid_device:led(i, 2, brightness)
      end

      -- Row 3: Scene save (15 while a save is held)
      for i = 1, NUM_SCENES do
        grid_device:led(i, 3, grid_core.hold_pending(port, i, 3) and 15 or 4)
      end

      -- Row 5: Scene sequencer controls
      if S.scene_sequencer_enabled then
        grid_device:led(1, 5, 15)  -- Sequencer on
        -- Show next scene in sequence
        if S.scene_sequencer_position >= 1 and S.scene_sequencer_position <= NUM_SCENES then
          grid_device:led(S.scene_sequencer_position, 1, 15)
        end
      else
        grid_device:led(1, 5, 4)  -- Sequencer off
      end

      -- Sequence length indicators
      local seq_length = params:get("scene_sequence_length")
      for i = 1, NUM_SCENES do
        grid_device:led(i + 2, 5, i <= seq_length and 8 or 2)
      end

      grid_redraw_256_page_row(port, grid_device)
    elseif page == 4 then
      -- BUFFER / FX page: buffer rows 1-2, FX faders on rows 3-7, voice
      -- sources on rows 9-15, rows 8 and 16 as on page 1
      grid_redraw_256_buffers(grid_device)
      for index, param_id in ipairs(GRID_LAYOUT.fx_fader_ids) do
        grid_redraw_fader_row(grid_device, GRID_LAYOUT.fx_first_row + index - 1, param_id)
      end
      grid_redraw_256_sources(grid_device)
      grid_redraw_256_transport(port, grid_device)
      grid_redraw_256_lock(grid_device)
    else
      -- Patterns/parameters pages
      -- Draw patterns (rows 1-NUM_VOICES)
      for voice_idx = 1, NUM_VOICES do
        for step = 1, PATTERN_LENGTH do
          local brightness = step_brightness(voice_idx, step)
          grid_device:led(step, voice_idx, brightness)
        end
      end

      grid_redraw_256_transport(port, grid_device)

      -- Rows 9-13 (parameter page): faders and fader page selection
      if page == 2 then
        grid_redraw_faders(grid_device)
      end

      -- Row 14: Voice status
      for i = 1, NUM_VOICES do
        grid_device:led(i, 14, i == S.grid_voice_select and 15 or 4)
        grid_device:led(i + 8, 14, S.voices[i].active and 12 or 2)
      end

      grid_redraw_256_lock(grid_device)
    end
  end

  -- 256 page 4, rows 1-2: buffer state (15 recording, 8 loaded, 2 empty)
  -- above each slot's clear key
  function grid_redraw_256_buffers(grid_device)
    for slot = 1, NUM_BUFFERS do
      grid_device:led(slot, GRID_LAYOUT.buffer_record_row, grid_core.record_level(slot))
      grid_device:led(slot, GRID_LAYOUT.buffer_clear_row, grid_core.CLEAR_LEVEL)
    end
  end

  -- 256 page 4, rows 9-15: each voice's source (selected 15, others 4, empty
  -- buffers 2)
  function grid_redraw_256_sources(grid_device)
    for voice_idx = 1, NUM_VOICES do
      local y = GRID_LAYOUT.source_first_row + voice_idx - 1
      for source = 1, #SOURCE_OPTIONS do
        grid_device:led(source, y, grid_core.source_level(voice_idx, source))
      end
    end
  end

  -- 256 row 8, columns 13-16: page indicators
  function grid_redraw_256_page_row(port, grid_device)
    local page = grid_core.page(port)
    for i = 1, 4 do
      grid_device:led(12 + i, 8, i == page and 15 or 2)
    end
  end

  -- 256 row 8: pattern controls, tempo and page indicators
  function grid_redraw_256_transport(port, grid_device)
    -- columns 1-4 all act as play/stop
    for x = 1, 4 do
      grid_device:led(x, 8, S.pattern_playing and 15 or 4)
    end

    -- Tempo indicators
    grid_device:led(5, 8, 2)
    grid_device:led(6, 8, 2)
    grid_device:led(7, 8, 2)
    grid_device:led(8, 8, 2)

    grid_redraw_256_page_row(port, grid_device)
  end

  -- 256 row 16: lock status
  function grid_redraw_256_lock(grid_device)
    for i = 1, NUM_VOICES do
      grid_device:led(i, 16, S.frozen[i] and 12 or 2)
    end
  end

  S.registry.grid_layouts["256"] = {key = grid_key_256, redraw = grid_redraw_256}

  return M
end

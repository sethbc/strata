-- lib/grid/layout_128h.lua
-- The 16x8 grid: keys and LEDs. Registers S.registry.grid_layouts["128h"].
-- The functions stay global.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_SCENES = S.constants.NUM_SCENES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local grid_core = S.lib.grid_core

  -- 16x8 grid layout (128 buttons horizontal)
  function grid_key_128h(port, x, y, z)
    if z == 0 then return end  -- presses only
    if grid_core.page(port) == 3 then
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
      elseif y == 5 and x == 1 then
        -- Toggle scene sequencer
        local enabled = params:get("scene_sequencer_enabled")
        params:set("scene_sequencer_enabled", enabled == 1 and 0 or 1)
      elseif y == 4 and x <= NUM_SCENES then
        -- Row 4: Set sequence length
        params:set("scene_sequence_length", x)
      end
    elseif y >= 1 and y <= NUM_VOICES then
      -- Rows 1-7: Pattern triggers
      grid_core.step_key(port, x, y, z, y, x, x, PATTERN_LENGTH)
    end

    -- Row 8: Always accessible (multi-function)
    if y == 8 then
      if x <= 4 then
        pattern_toggle()
      elseif x == 5 then
        grid_core.set_page(port, 1)  -- Patterns
      elseif x == 6 then
        grid_core.set_page(port, 2)  -- Parameters
      elseif x == 7 then
        grid_core.set_page(port, 3)  -- Scenes
      elseif x >= 9 and x <= 8 + NUM_VOICES then
        -- Voice toggle
        toggle_voice(x - 8)
      elseif x == 16 then
        -- Voice selection for parameters
        select_grid_voice(S.grid_voice_select % NUM_VOICES + 1)
      end
    end
  end

  function grid_redraw_128h(port, grid_device)
    local page = grid_core.page(port)
    if page == 3 then
      -- Scene page (simplified for 128h layout)
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
      else
        grid_device:led(1, 5, 4)  -- Sequencer off
      end

      -- Sequence length indicators (simplified)
      local seq_length = params:get("scene_sequence_length")
      for i = 1, NUM_SCENES do
        grid_device:led(i, 4, i <= seq_length and 8 or 2)
      end
    else
      -- Pattern/parameter pages
      -- Draw patterns (rows 1-NUM_VOICES)
      for voice_idx = 1, NUM_VOICES do
        for step = 1, PATTERN_LENGTH do
          local brightness = step_brightness(voice_idx, step)
          grid_device:led(step, voice_idx, brightness)
        end
      end
    end

    -- Row 8: Controls (always visible)
    -- columns 1-4 all act as play/stop
    for x = 1, 4 do
      grid_device:led(x, 8, S.pattern_playing and 15 or 4)
    end

    -- Page indicators (3 pages now)
    grid_device:led(5, 8, page == 1 and 15 or 4)
    grid_device:led(6, 8, page == 2 and 15 or 4)
    grid_device:led(7, 8, page == 3 and 15 or 4)

    -- Voice status
    for i = 1, NUM_VOICES do
      grid_device:led(i + 8, 8, S.voices[i].active and 12 or 2)
    end

    -- Voice selection indicator
    grid_device:led(16, 8, 8)
  end

  S.registry.grid_layouts["128h"] = {key = grid_key_128h, redraw = grid_redraw_128h}

  return M
end

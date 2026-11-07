-- lib/grid/layout_128v.lua
-- The 8x16 grid: keys and LEDs. Registers S.registry.grid_layouts["128v"].
-- The functions stay global.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH

  -- 8x16 grid layout (128 buttons vertical)
  function grid_key_128v(x, y, z)
    if x >= 1 and x <= NUM_VOICES then
      -- Columns 1-7: Pattern triggers
      if y <= PATTERN_LENGTH then
        toggle_pattern_step(x, y)
      end
    elseif x == 8 then
      -- Column 8: Controls
      if y >= 1 and y <= NUM_VOICES then
        toggle_voice(y)
      elseif y == 9 then
        pattern_toggle()
      elseif y >= 10 and y <= 9 + NUM_VOICES then
        -- Voice selection for parameters
        select_grid_voice(y - 9)
      end
    end
  end

  function grid_redraw_128v(grid_device)
    -- Draw patterns (columns 1-NUM_VOICES)
    for voice_idx = 1, NUM_VOICES do
      for step = 1, PATTERN_LENGTH do
        local brightness = step_brightness(voice_idx, step)
        grid_device:led(voice_idx, step, brightness)
      end
    end

    -- Column 8: Controls
    for i = 1, NUM_VOICES do
      grid_device:led(8, i, S.voices[i].active and 12 or 4)
    end
    grid_device:led(8, 9, S.pattern_playing and 15 or 4)

    -- Voice selection
    for i = 1, NUM_VOICES do
      grid_device:led(8, 9 + i, (i == S.grid_voice_select) and 15 or 2)
    end
  end

  S.registry.grid_layouts["128v"] = {key = grid_key_128v, redraw = grid_redraw_128v}

  return M
end

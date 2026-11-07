-- lib/grid/layout_64.lua
-- The 8x8 grid: keys and LEDs. Registers S.registry.grid_layouts["64"].
-- The functions stay global.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local grid_core = S.lib.grid_core

  -- 8x8 grid layout (64 buttons)
  function grid_key_64(port, x, y, z)
    if z == 0 then return end  -- presses only
    if y >= 1 and y <= NUM_VOICES then
      -- Rows 1-7: Pattern triggers (only steps 1-8 fit on this grid; levels
      -- follow its columns)
      local visible_steps = math.min(PATTERN_LENGTH, S.grids[port].cols)
      grid_core.step_key(port, x, y, z, y, x, x, visible_steps)
    elseif y == 8 then
      -- Row 8: Controls
      if x == 1 then
        pattern_toggle()
      elseif x >= 3 and x <= 7 then
        toggle_voice(x - 2)
      end
    end
  end

  function grid_redraw_64(port, grid_device)
    -- Draw patterns (rows 1-7). Only the first 8 steps of each 16-step
    -- pattern fit; the sequencer still plays all PATTERN_LENGTH steps.
    local visible_steps = math.min(PATTERN_LENGTH, grid_device.cols)
    for voice_idx = 1, NUM_VOICES do
      for step = 1, visible_steps do
        local brightness = step_brightness(voice_idx, step)
        grid_device:led(step, voice_idx, brightness)
      end
    end

    -- Row 8: Controls
    grid_device:led(1, 8, S.pattern_playing and 15 or 4)
    for i = 1, 5 do
      grid_device:led(i + 2, 8, S.voices[i].active and 12 or 4)
    end
  end

  S.registry.grid_layouts["64"] = {key = grid_key_64, redraw = grid_redraw_64}

  return M
end

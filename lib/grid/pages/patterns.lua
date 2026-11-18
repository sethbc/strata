-- lib/grid/pages/patterns.lua
-- Grid page 1, patterns (3.8, design §10.3): seven lines of sixteen steps,
-- a line per voice. A step key goes through the pane's step_key (a toggle
-- at its release, the step editor after GRID_HOLD.step_edit_seconds, a
-- second key of the line sets the held step's level over the keys
-- shown); its LEDs are step_brightness, as SEQ draws them. Written in pane
-- coordinates (lib/grid/pane.lua), so it is the same on every layout

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH

  M.record = {
    name = "patterns",
    index = S.constants.GRID_PAGES.patterns,
    press = function(pane, x, y, z)
      if y < 1 or y > NUM_VOICES or x < 1 or x > PATTERN_LENGTH then return end
      pane.step_key(x, y, z, y, x)
    end,
    redraw = function(_, led)
      for voice_idx = 1, NUM_VOICES do
        for step = 1, PATTERN_LENGTH do led(step, voice_idx, step_brightness(voice_idx, step)) end
      end
    end,
  }
  S.register_grid_page(M.record)

  return M
end

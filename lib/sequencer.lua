-- lib/sequencer.lua
-- The pattern sequencer: S.patterns (built fresh by the constructor), the
-- pattern clock and its state (S.pattern_position, S.pattern_playing,
-- S.pattern_clock), pattern edits and the step LED levels. Steps accent
-- running voices with engine.retrigger and never create nodes. The
-- functions stay global.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL

  -- Pattern sequencer
  S.patterns = {}
  S.pattern_position = 1
  S.pattern_playing = false
  S.pattern_clock = nil

  -- Initialize patterns for each voice
  for i = 1, NUM_VOICES do
    S.patterns[i] = {}
    for step = 1, PATTERN_LENGTH do
      S.patterns[i][step] = 0  -- 0=off, 1-15=velocity/brightness
    end
  end

  function toggle_pattern_step(voice_idx, step)
    -- Bounds checking to prevent array expansion
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    if step < 1 or step > PATTERN_LENGTH then return end

    if S.patterns[voice_idx][step] == 0 then
      S.patterns[voice_idx][step] = 15  -- Full brightness
    else
      S.patterns[voice_idx][step] = 0
    end
  end

  function clear_pattern(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    for step = 1, PATTERN_LENGTH do
      S.patterns[voice_idx][step] = 0
    end
  end

  function randomize_pattern(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    for step = 1, PATTERN_LENGTH do
      if math.random() > 0.5 then
        S.patterns[voice_idx][step] = math.random(8, 15)
      else
        S.patterns[voice_idx][step] = 0
      end
    end
  end

  function pattern_toggle()
    if S.pattern_playing then
      pattern_clock_stop()
    else
      pattern_clock_start()
    end
  end

  function pattern_clock_start()
    if S.pattern_clock then
      clock.cancel(S.pattern_clock)
    end

    S.pattern_playing = true
    S.pattern_position = 1

    S.pattern_clock = clock.run(function()
      while S.pattern_playing do
        -- Trigger voices that have active steps
        for voice_idx = 1, NUM_VOICES do
          if S.patterns[voice_idx][S.pattern_position] > 0 then
            if S.voices[voice_idx].active then
              -- Voice is already running: accent it in place, at the step's
              -- level (1-15) as velocity. A step must never create new synth
              -- nodes (toggling would stack whole voice/grain/mod chains
              -- through their long release tails).
              engine.retrigger(voice_idx - 1, S.patterns[voice_idx][S.pattern_position] / MAX_STEP_LEVEL)
            else
              -- Voice is off - turn it on
              toggle_voice(voice_idx)
            end
          end
        end

        -- Show the step that just played, then advance
        grid_redraw()
        S.pattern_position = S.pattern_position % PATTERN_LENGTH + 1

        -- Wait for next step based on tempo
        clock.sync(1/4)  -- 16th notes
      end
    end)
  end

  function pattern_clock_stop()
    S.pattern_playing = false
    if S.pattern_clock then
      clock.cancel(S.pattern_clock)
      S.pattern_clock = nil
    end
    grid_redraw()
  end

  -- LED level for a pattern step: its stored level, or at the playhead 15 for
  -- an active step and 4 for an empty one
  function step_brightness(voice_idx, step)
    local level = S.patterns[voice_idx][step]
    if S.pattern_playing and step == S.pattern_position then
      return level > 0 and 15 or 4
    end
    return level
  end

  return M
end

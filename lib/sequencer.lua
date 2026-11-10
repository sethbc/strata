-- lib/sequencer.lua
-- The pattern sequencer: S.patterns (built fresh by the constructor), the
-- pattern clock and its state (S.pattern_position, S.pattern_sounding_step,
-- S.pattern_playing, S.pattern_clock), pattern edits (every whole-pattern
-- change through M.replace_pattern), the sounding step
-- (M.sounding_step, the playhead every grid layout and SEQ draw) and the
-- step LED levels. Steps accent running voices with engine.retrigger and
-- never create nodes. The functions stay global.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL

  -- Pattern sequencer
  S.patterns = {}
  S.pattern_position = 1         -- the next step the clock plays
  S.pattern_sounding_step = nil  -- the step it played last (nil before the first)
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

  -- A step level from any value: a number floored to a whole level and
  -- clamped to 0..MAX_STEP_LEVEL; anything else (nil, a string, NaN) is 0
  local function whole_step_level(value)
    if type(value) ~= "number" or value ~= value then return 0 end
    return math.min(MAX_STEP_LEVEL, math.max(0, math.floor(value)))
  end

  -- Replace voice_idx's whole pattern: step s takes steps[s] as a whole
  -- level. A voice outside 1..NUM_VOICES or a steps that is not a table
  -- does nothing. It ends the voice's step-level gesture on every grid
  -- (#242), so a step held from before never takes a level in the new
  -- pattern. Every whole-pattern change goes through it; it redraws
  -- nothing (callers do)
  function M.replace_pattern(voice_idx, steps)
    if type(voice_idx) ~= "number" or voice_idx % 1 ~= 0 then return end
    if voice_idx < 1 or voice_idx > NUM_VOICES or type(steps) ~= "table" then return end
    for step = 1, PATTERN_LENGTH do
      S.patterns[voice_idx][step] = whole_step_level(steps[step])
    end
    S.lib.grid_core.end_step_gestures(voice_idx)
  end

  function clear_pattern(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    M.replace_pattern(voice_idx, {})
  end

  function randomize_pattern(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    local steps = {}
    for step = 1, PATTERN_LENGTH do
      if math.random() > 0.5 then
        steps[step] = math.random(8, 15)
      else
        steps[step] = 0
      end
    end
    M.replace_pattern(voice_idx, steps)
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
    S.pattern_sounding_step = nil

    local function play_step()
      -- This step sounds from now on: every grid redraw until the next
      -- step (the one below, a voice it starts, a key press) shows it
      S.pattern_sounding_step = S.pattern_position

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

      -- Show the step that just played, then advance to the next one
      grid_redraw()
      S.pattern_position = S.pattern_position % PATTERN_LENGTH + 1
    end

    local started = clock.run(function()
      while S.pattern_playing do
        local played, step_error = xpcall(play_step, with_traceback)
        if not played then
          -- Forget our own id first, so the stop never cancels this clock
          -- from inside itself, then show the pattern stopped and raise the
          -- error again for maiden
          S.pattern_clock = nil
          pattern_clock_stop()
          error(step_error, 0)
        end

        -- Wait for next step based on tempo
        clock.sync(1/4)  -- 16th notes
      end
    end)
    -- A first step that failed has already stopped the pattern (clock.run
    -- runs it at once): its id must not be recorded
    if S.pattern_playing then S.pattern_clock = started end
  end

  function pattern_clock_stop()
    S.pattern_playing = false
    S.pattern_sounding_step = nil
    if S.pattern_clock then
      clock.cancel(S.pattern_clock)
      S.pattern_clock = nil
    end
    grid_redraw()
  end

  -- The step sounding now: the one the pattern clock played last, so
  -- between steps it is the position before S.pattern_position (which the
  -- clock has already advanced). nil while stopped and before the first
  -- step plays. Every playhead (each grid layout, the SEQ page) is this step
  function M.sounding_step()
    if not S.pattern_playing then return nil end
    local step = S.pattern_sounding_step
    if type(step) ~= "number" or step < 1 or step > PATTERN_LENGTH then return nil end
    return step
  end

  -- LED level for a pattern step: its stored level, or at the playhead (the
  -- sounding step) 15 for an active step and 4 for an empty one
  function step_brightness(voice_idx, step)
    local level = S.patterns[voice_idx][step]
    if step == M.sounding_step() then
      return level > 0 and 15 or 4
    end
    return level
  end

  S.register_cleanup(S.constants.CLEANUP_ORDER.pattern_clock, function()
    pattern_clock_stop()
  end)

  -- The patterns play exactly while their clock runs
  S.register_invariant("pattern clock", function()
    if S.pattern_playing ~= (S.pattern_clock ~= nil) then
      return "pattern_playing is " .. tostring(S.pattern_playing) .. " but pattern_clock is " .. tostring(S.pattern_clock)
    end
  end)

  return M
end

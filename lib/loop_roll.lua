-- lib/loop_roll.lua
-- The loop (3.9 grid sequencer, package 5a, design section 4, The loop,
-- calls 10, 15 and 21; S.lib.loop_roll): a voice plays its hits from
-- between two steps, in its own direction, while its own position
-- (lib/sequencer.lua's take_position) runs on underneath, so let go it
-- plays the step it would have reached. A loop is held by its key's own
-- answer to "still held?" (a function of no argument, the grid's
-- pane.still), asked at every tick the voice takes, or by its latch
-- (press_latch: 5c's LP key). It is the sequencer's state, never a param,
-- a scene field or a PSET field. The sequencer asks played_step for the
-- step it plays at each tick, played or skipped. 5b adds the roll here.
-- See docs/notes/lua/loop-roll.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH

  -- Per voice: its loop {lo, hi, still, latched, last (the loop's step
  -- played last, nil before its first), heading (ping-pong's way, 1 or
  -- -1)} or nil; whether its latch is armed (only with no loop)
  local LOOP = {loops = {}, armed = {}}

  local function valid_voice(voice_idx)
    return type(voice_idx) == "number" and voice_idx == math.floor(voice_idx) and voice_idx >= 1
      and voice_idx <= NUM_VOICES
  end

  local function valid_step(step)
    return type(step) == "number" and step == math.floor(step) and step >= 1 and step <= PATTERN_LENGTH
  end

  local function voice_values(voice_idx) return S.voices[voice_idx].values or {} end

  local function voice_length(voice_idx) return voice_values(voice_idx).seq_length or PATTERN_LENGTH end

  -- The voice's loop if it holds: latched, or its key still held. A loop
  -- whose key has gone is dead: no reader sees it, and the next tick
  -- (played_step) or write drops it
  local function live(voice_idx)
    local loop = LOOP.loops[voice_idx]
    if loop and (loop.latched or loop.still()) then return loop end
    return nil
  end

  local function drop_dead(voice_idx)
    if LOOP.loops[voice_idx] and not live(voice_idx) then LOOP.loops[voice_idx] = nil end
  end

  -- The voice's loop, lo and hi, or nil with none (a dead one is none)
  function M.loop(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    local loop = live(voice_idx)
    if loop == nil then return nil end
    return loop.lo, loop.hi
  end

  -- Whether the voice's latch is armed (its next loop is kept)
  function M.armed(voice_idx)
    return valid_voice(voice_idx) and LOOP.armed[voice_idx] == true
  end

  -- Whether the voice has a loop that its latch holds
  function M.latched(voice_idx)
    if not valid_voice(voice_idx) then return false end
    local loop = live(voice_idx)
    return loop ~= nil and loop.latched
  end

  -- Loop the voice between steps a and b (either order), held by still (a
  -- function of no argument: the key's own answer to "still held?"). The
  -- loop is cut to the voice's length: one wholly past it is none. It is
  -- latched when the latch is armed (which it then no longer is) or when
  -- the loop it replaces was latched: the latch holds the voice's loop
  -- until press_latch ends it. It plays from its first step at the next
  -- tick. Anything out of range does nothing. Repaints the grid
  function M.set_loop(voice_idx, a, b, still)
    if not valid_voice(voice_idx) or not valid_step(a) or not valid_step(b) or type(still) ~= "function" then return end
    local lo, hi = math.min(a, b), math.max(a, b)
    local length = voice_length(voice_idx)
    if lo > length then return end
    local latched = LOOP.armed[voice_idx] == true or M.latched(voice_idx)
    LOOP.armed[voice_idx] = nil
    LOOP.loops[voice_idx] = {lo = lo, hi = math.min(hi, length), still = still, latched = latched, heading = 1}
    grid_redraw()
  end

  -- End the voice's loop, latched or not. Repaints the grid
  function M.end_loop(voice_idx)
    if not valid_voice(voice_idx) then return end
    LOOP.loops[voice_idx] = nil
    grid_redraw()
  end

  -- The latch's key: a latched loop ends, and the latch with it; a held
  -- loop becomes latched; with no loop the latch is armed, or disarmed if
  -- it was. Repaints the grid
  function M.press_latch(voice_idx)
    if not valid_voice(voice_idx) then return end
    drop_dead(voice_idx)
    local loop = LOOP.loops[voice_idx]
    if loop and loop.latched then
      LOOP.loops[voice_idx] = nil
    elseif loop then
      loop.latched = true
    else
      LOOP.armed[voice_idx] = not LOOP.armed[voice_idx] or nil
    end
    grid_redraw()
  end

  -- The voice's length changed (v<i>_seq_length's action): below the
  -- loop's lo it ends, below its hi it is cut there; a longer length gives
  -- nothing back
  function M.fit_length(voice_idx, length)
    if not valid_voice(voice_idx) or type(length) ~= "number" then return end
    local loop = LOOP.loops[voice_idx]
    if loop == nil then return end
    if length < loop.lo then
      LOOP.loops[voice_idx] = nil
    elseif length < loop.hi then
      loop.hi = length
    end
  end

  -- The voice's position starts (lib/sequencer.lua's start_position: a
  -- pattern start, a restart, a division reset's bar, a stop): the loop
  -- plays from its first step again
  function M.start(voice_idx)
    local loop = valid_voice(voice_idx) and LOOP.loops[voice_idx]
    if loop then loop.last, loop.heading = nil, 1 end
  end

  -- The loop's next step after last, in the voice's direction over lo..hi:
  -- the direction's first from none (or from a step a cut left outside),
  -- forward and reverse wrapping, ping-pong turning at both ends (no end
  -- played twice), random drawn inside. A misstep is the voice's own
  -- position's, never the loop's
  local function next_loop_step(voice_idx, loop)
    local SEQ = S.lib.sequencer.SEQ
    local way, last, lo, hi = voice_values(voice_idx).seq_direction or SEQ.forward, loop.last, loop.lo, loop.hi
    if way == SEQ.random then return math.random(lo, hi) end
    if last == nil or last < lo or last > hi then
      loop.heading = 1
      return way == SEQ.reverse and hi or lo
    end
    if way == SEQ.forward then return last + 1 > hi and lo or last + 1 end
    if way == SEQ.reverse then return last - 1 < lo and hi or last - 1 end
    if lo == hi then return lo end
    local step = last + loop.heading
    if step > hi or step < lo then
      loop.heading = -loop.heading
      step = last + loop.heading
    end
    return step
  end

  -- The step the voice plays at a tick (played or skipped:
  -- lib/sequencer.lua's begin_voice_step and skip_due_ticks), given its own
  -- step (take_position's): with no loop that step; with one, the loop's
  -- own next step. An unlatched loop whose key has gone ends first, so the
  -- voice plays its own step
  function M.played_step(voice_idx, step)
    if not valid_voice(voice_idx) then return step end
    drop_dead(voice_idx)
    local loop = LOOP.loops[voice_idx]
    if loop == nil then return step end
    loop.last = next_loop_step(voice_idx, loop)
    return loop.last
  end

  -- loop (design section 7): a loop lies inside 1 to the voice's length
  -- with lo <= hi, carries its key's still (a function) and a latch flag;
  -- a latch is armed only with no loop; while the patterns play, a loop
  -- that has played a step is the step the voice sounds (so the sequencer
  -- played the loop's step, which played_step gives only for a loop that
  -- held at that tick)
  S.register_invariant("loop", function()
    for voice_idx = 1, NUM_VOICES do
      local loop = LOOP.loops[voice_idx]
      if loop then
        local length = voice_length(voice_idx)
        if not (valid_step(loop.lo) and valid_step(loop.hi) and loop.lo <= loop.hi and loop.hi <= length) then
          return "voice " .. voice_idx .. "'s loop " .. tostring(loop.lo) .. " to " .. tostring(loop.hi)
            .. " is not inside 1 to its length " .. tostring(length)
        end
        if type(loop.still) ~= "function" or type(loop.latched) ~= "boolean" then
          return "voice " .. voice_idx .. "'s loop has no still function or latch flag"
        end
        if LOOP.armed[voice_idx] then return "voice " .. voice_idx .. "'s latch is armed over a loop" end
        local sounding = S.pattern_sounding_steps and S.pattern_sounding_steps[voice_idx]
        if S.pattern_playing and loop.last ~= nil and sounding ~= loop.last then
          return "voice " .. voice_idx .. "'s loop played step " .. loop.last .. ", but it sounds "
            .. tostring(sounding)
        end
      end
    end
  end)

  return M
end

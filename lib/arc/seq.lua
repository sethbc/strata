-- lib/arc/seq.lua
-- The SEQ page's arc rings: ring 1 the step cursor (S.cursors.seq_step),
-- ring 2 that step's level on the selected voice's pattern, ring 3 the
-- tempo, ring 4 the voice row (the selected voice). Every ring steps whole
-- values, carrying its spare ticks under "seq:<ring>" (arc_whole_steps).
-- Sets only the arc fields (arc_delta, arc_redraw) on SEQ's
-- S.registry.pages record (lib/pages/seq.lua).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL
  local NUM_VOICES = S.constants.NUM_VOICES

  -- Ticks per whole step of each ring, and the brightness of each
  local ARC_SEQ = {
    ticks = {10, 10, 10, 20},  -- step, level, BPM, voice
    levels = {15, 15, 12, 12},
  }

  -- The step ring 2's carried ticks were turned on ("<voice>:<step>"), so
  -- they never set another step
  local level_target = nil

  local function cursor_step()
    return util.clamp(S.cursors.seq_step, 1, PATTERN_LENGTH)
  end

  local function ring_steps(n, delta)
    return arc_whole_steps("seq:" .. n, delta, ARC_SEQ.ticks[n])
  end

  local function set_step_level(steps)
    local voice_idx, step = S.selected_voice, cursor_step()
    local pattern = S.patterns[voice_idx]
    if pattern == nil then return end
    pattern[step] = util.clamp(pattern[step] + steps, 0, MAX_STEP_LEVEL)
    S.lib.mutation.note_pattern_edit(voice_idx)
    grid_redraw()  -- the grid shows the patterns
  end

  local function arc_seq_delta(n, delta)
    if n == 1 then
      local steps = ring_steps(n, delta)
      if steps ~= 0 then S.lib.ui_cursors.move("seq_step", steps) end
    elseif n == 2 then
      local target = S.selected_voice .. ":" .. cursor_step()
      if level_target ~= target then
        forget_arc_ticks("seq:2")
        level_target = target
      end
      local steps = ring_steps(n, delta)
      if steps ~= 0 then set_step_level(steps) end
    elseif n == 3 then
      local steps = ring_steps(n, delta)
      if steps ~= 0 then delta_with_detent("tempo", steps, {source = "arc"}) end
    elseif n == 4 then
      local steps = ring_steps(n, delta)
      if steps ~= 0 then S.lib.ui_keys.select_voice_by(steps) end
    end
  end

  -- The cursor and level rings show their position (exactly these
  -- fractions, the first position lighting LED 1); the tempo ring its param
  local function arc_seq_redraw(arc_port)
    local pattern = S.patterns[S.selected_voice]
    local level = pattern and pattern[cursor_step()] or 0
    arc_ring_fill_position(arc_port, 1, (cursor_step() - 1) / (PATTERN_LENGTH - 1), ARC_SEQ.levels[1])
    arc_ring_fill_position(arc_port, 2, level / MAX_STEP_LEVEL, ARC_SEQ.levels[2])
    arc_ring_fill_param(arc_port, 3, "tempo", ARC_SEQ.levels[3])
    arc_ring_fill_position(arc_port, 4, (S.selected_voice - 1) / (NUM_VOICES - 1), ARC_SEQ.levels[4])
  end

  -- SEQ's record gains its rings: arc_delta and arc_redraw in
  -- lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[UI_PAGES.index.SEQ]
  assert(record, "lib/arc/seq.lua: no SEQ page record in S.registry.pages")
  record.arc_delta = arc_seq_delta
  record.arc_redraw = arc_seq_redraw

  return M
end

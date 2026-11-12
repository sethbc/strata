-- lib/arc/seq.lua
-- The SEQ page's arc rings: ring 1 the step cursor (S.cursors.seq_step),
-- ring 2 that step's level on the selected voice's pattern, ring 3 the
-- tempo, ring 4 the voice row (the selected voice), in the pattern view and
-- the edit view alike. Every ring steps whole values, carrying its spare
-- ticks under "seq:<ring>" (arc_whole_steps). Sets only the arc fields
-- (arc_delta, arc_redraw) on SEQ's S.registry.pages record
-- (lib/pages/seq.lua). Also the step editor's rings (design 8.7), set on
-- its modal owner (S.lib.pages_seq.step_editor_owner): 1 pos, 2 pitch, 3
-- size (each a lock, a full turn its param's range), 4 prob (whole
-- percents); with ALT 1 ratchet, 2 note, 3 bookmark, 4 level (whole steps).
-- The edits go through S.lib.pages_seq.turn_step, the edit view's own.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_BOOKMARKS = S.constants.NUM_BOOKMARKS

  -- Ticks per whole step of each ring, and the brightness of each; the
  -- step editor's: its plain rings' attributes (the locks, then prob), its
  -- ALT rings', the ALT rings' ticks per step, and a ring's level while its
  -- attribute is set (bright) or off (dim, at the value a turn starts from)
  local ARC_SEQ = {
    ticks = {10, 10, 10, 20},  -- step, level, BPM, voice
    levels = {15, 15, 12, 12},
    editor_rings = {"pos", "pitch", "size", "prob"},
    editor_alt_rings = {"ratchet", "notes", "bookmark", "level"},
    editor_ticks = 20,
    editor_set_level = 15,
    editor_off_level = 4,
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

  -- The step editor's rings -------------------------------------------------

  -- Per carry key: the "<voice>:<step>" its ticks were turned on, so a step
  -- the editor moved to never takes another's carried ticks
  local editor_targets = {}

  local function editor_steps(carry, voice_idx, step, delta, ticks_per_step)
    local target = voice_idx .. ":" .. step
    if editor_targets[carry] ~= target then
      forget_arc_ticks(carry)
      editor_targets[carry] = target
    end
    return arc_whole_steps(carry, delta, ticks_per_step)
  end

  -- Plain rings 1-3 move their lock by delta / ARC_TICKS_PER_SWEEP of its
  -- param's range (from off at the stored value; past the start, off),
  -- ring 4 prob by whole percents (a turn for the whole 0-100); with ALT
  -- each ring steps its attribute every editor_ticks ticks. The bookmark
  -- ring does nothing while the voice has no set bookmark
  local function editor_delta(n, delta)
    local editor = S.lib.pages_seq.step_editor()
    if editor == nil then return end
    local voice_idx, step = editor.voice, editor.step
    local turn_step = S.lib.pages_seq.turn_step
    if S.alt_held then
      local attr = ARC_SEQ.editor_alt_rings[n]
      if attr == nil or (attr == "bookmark" and not S.lib.pages_seq.has_bookmarks(voice_idx)) then return end
      local steps = editor_steps("seq_editor:alt:" .. n, voice_idx, step, delta, ARC_SEQ.editor_ticks)
      if steps ~= 0 then turn_step(voice_idx, step, attr, steps) end
    elseif ARC_SEQ.editor_rings[n] == "prob" then
      local SEQ = S.lib.sequencer.SEQ
      local steps = editor_steps("seq_editor:" .. n, voice_idx, step, delta, UI_PAGES.ARC_TICKS_PER_SWEEP / SEQ.max_prob)
      if steps ~= 0 then turn_step(voice_idx, step, "prob", steps) end
    elseif ARC_SEQ.editor_rings[n] then
      turn_step(voice_idx, step, ARC_SEQ.editor_rings[n], nil, {raw = delta / UI_PAGES.ARC_TICKS_PER_SWEEP})
    end
  end

  -- A whole-step attribute's ring: its position on low..high, bright while
  -- set; off, dim at start (nil: dark)
  local function fill_whole(arc_port, n, value, start, low, high)
    local shown = value == nil and start or value
    if shown == nil then return end
    local level = value == nil and ARC_SEQ.editor_off_level or ARC_SEQ.editor_set_level
    arc_ring_fill_position(arc_port, n, (shown - low) / (high - low), level)
  end

  -- The locks from param_value_fraction of their param (off: dim at the
  -- stored value, where a turn starts); prob, ratchet, note and level at
  -- their place in their range; bookmark dark without a set bookmark
  local function editor_redraw(arc_port)
    local editor = S.lib.pages_seq.step_editor()
    if editor == nil then return end
    local voice_idx, step = editor.voice, editor.step
    local seq = S.lib.sequencer
    local SEQ = seq.SEQ
    if S.alt_held then
      fill_whole(arc_port, 1, seq.step_attr(voice_idx, step, "ratchet"), 1, 1, SEQ.max_ratchet)
      local notes = seq.step_attr(voice_idx, step, "notes")
      fill_whole(arc_port, 2, notes and notes[1], 0, -SEQ.max_degree, SEQ.max_degree)
      if S.lib.pages_seq.has_bookmarks(voice_idx) then
        fill_whole(arc_port, 3, seq.step_attr(voice_idx, step, "bookmark"), 1, 1, NUM_BOOKMARKS)
      end
      fill_whole(arc_port, 4, S.patterns[voice_idx][step], 0, 0, MAX_STEP_LEVEL)
      return
    end
    for n = 1, 3 do
      local attr = ARC_SEQ.editor_rings[n]
      local param_id = S.lib.pages_seq.lock_param_id(voice_idx, attr)
      local value = seq.step_attr(voice_idx, step, attr)
      if value == nil then
        arc_ring_fill(arc_port, n, param_fraction(param_id), ARC_SEQ.editor_off_level)
      else
        arc_ring_fill(arc_port, n, param_value_fraction(param_id, value), ARC_SEQ.editor_set_level)
      end
    end
    fill_whole(arc_port, 4, seq.step_attr(voice_idx, step, "prob"), SEQ.max_prob, 0, SEQ.max_prob)
  end

  -- The step editor's owner gains its rings: arc_delta and arc_redraw in
  -- lib/arc/core.lua dispatch to a pushed modal owner
  local editor_owner = S.lib.pages_seq.step_editor_owner
  assert(editor_owner, "lib/arc/seq.lua: no step editor owner on S.lib.pages_seq")
  editor_owner.arc_delta = editor_delta
  editor_owner.arc_redraw = editor_redraw

  return M
end

-- lib/arc/buffer.lua
-- The BUFFER page's arc rings: the selected voice's buffer position, loop
-- start, loop length and scan; with ALT held its buffer rate, the scrub
-- friction and the record feedback. Sets arc_delta, arc_redraw,
-- arc_alt_delta and arc_alt_redraw on BUFFER's S.registry.pages record.

return function(S)
  local M = {}

  -- Rings 1-4 plain and with ALT. voice_key: the param id suffix after
  -- "v<i>_"; param_id: a global param. always_level: the ring's level
  -- whatever the voice's source. Each sweeps its range in
  -- UI_PAGES.ARC_TICKS_PER_SWEEP ticks (arc_sweep_param).
  local ARC_BUFFER_RINGS = {
    {voice_key = "buf_pos", scrub = true},
    {voice_key = "loop_start"},
    {voice_key = "loop_length"},
    {voice_key = "buf_scan"}
  }
  local ARC_BUFFER_ALT_RINGS = {
    {voice_key = "buf_pos", scrub = true},
    {voice_key = "buf_rate"},
    {param_id = "scrub_friction"},
    {param_id = "record_feedback", always_level = 12}
  }
  local ARC_BUFFER_LEVELS = {buffer = 15, other = 4}

  local function ring_param(ring)
    return ring.param_id or ("v" .. S.selected_voice .. "_" .. ring.voice_key)
  end

  -- The voice whose scan the ALT ring 1 holds (nil when none); selecting
  -- another voice while ALT is held moves the hold to it
  local held_voice

  local function turn_ring(ring, delta)
    local voice = S.selected_voice
    arc_sweep_param(ring_param(ring), delta)
    if ring.scrub then S.lib.positions.scrub_turned(voice) end
  end

  local function arc_buffer_delta(n, delta)
    local ring = ARC_BUFFER_RINGS[n]
    if ring then turn_ring(ring, delta) end
  end

  -- ALT ring 1 also holds the selected voice's own scan (as the holder
  -- "arc"), once, until ALT comes up (the release hook below); a voice sync
  -- (the voice restarted) drops the arc from the holders, so the next turn
  -- joins again, even while a grid holds the voice
  local function arc_buffer_alt_delta(n, delta)
    local ring = ARC_BUFFER_ALT_RINGS[n]
    if not ring then return end
    if n == 1 and (held_voice ~= S.selected_voice or not S.lib.positions.holds_scan(held_voice, "arc")) then
      if held_voice then S.lib.positions.hold_scan(held_voice, false, "arc") end
      held_voice = S.selected_voice
      S.lib.positions.hold_scan(held_voice, true, "arc")
    end
    turn_ring(ring, delta)
  end

  local function draw_rings(arc_port, rings)
    local uses_buffer = voice_uses_buffer(S.selected_voice)
    local voice_level = uses_buffer and ARC_BUFFER_LEVELS.buffer or ARC_BUFFER_LEVELS.other
    for n, ring in ipairs(rings) do
      arc_ring_fill_param(arc_port, n, ring_param(ring), ring.always_level or voice_level)
    end
  end

  local function arc_buffer_redraw(arc_port) draw_rings(arc_port, ARC_BUFFER_RINGS) end
  local function arc_buffer_alt_redraw(arc_port) draw_rings(arc_port, ARC_BUFFER_ALT_RINGS) end

  S.register_alt_release(function()
    local voice = held_voice
    held_voice = nil
    if voice then S.lib.positions.hold_scan(voice, false, "arc") end
  end)

  -- BUFFER's record (lib/pages/buffer.lua) gains its rings: arc_delta and
  -- arc_redraw in lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[S.constants.UI_PAGES.index.BUFFER]
  assert(record, "lib/arc/buffer.lua: no BUFFER page record in S.registry.pages")
  record.arc_delta = arc_buffer_delta
  record.arc_redraw = arc_buffer_redraw
  record.arc_alt_delta = arc_buffer_alt_delta
  record.arc_alt_redraw = arc_buffer_alt_redraw

  return M
end

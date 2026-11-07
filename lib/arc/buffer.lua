-- lib/arc/buffer.lua
-- The BUFFER page's arc rings: the selected voice's buffer position and
-- rate, the recording duration and level. Sets arc_delta and arc_redraw on
-- BUFFER's S.registry.pages record.

return function(S)
  local M = {}

  -- BUFFER page rings: the selected voice's buffer position and rate, then
  -- the recording duration and level. Param id suffixes after "v<i>_" for
  -- the voice rings. Each sweeps its range in UI_PAGES.ARC_TICKS_PER_SWEEP ticks.
  local ARC_BUFFER_RINGS = {
    {voice_key = "buf_pos"},
    {voice_key = "buf_rate"},
    {param_id = "record_duration"},
    {param_id = "record_level"}
  }

  local function arc_buffer_ring_param(ring)
    return ring.param_id or ("v" .. S.selected_voice .. "_" .. ring.voice_key)
  end

  -- Rings 1-2 adjust the voice's buffer params whatever its source (they are
  -- ready when it switches to a buffer)
  local function arc_buffer_delta(n, delta)
    local ring = ARC_BUFFER_RINGS[n]
    if ring then
      arc_sweep_param(arc_buffer_ring_param(ring), delta)
    end
  end

  -- Rings 1-2 are bright for a buffer-sourced voice and dim otherwise (the
  -- buffer params do nothing then); the recording rings are always lit
  local function arc_buffer_redraw(arc_port)
    local uses_buffer = voice_uses_buffer(S.selected_voice)
    for n, ring in ipairs(ARC_BUFFER_RINGS) do
      local level = 12
      if ring.voice_key then
        level = uses_buffer and 15 or 4
      end
      arc_ring_fill(arc_port, n, param_fraction(arc_buffer_ring_param(ring)), level)
    end
  end

  -- BUFFER's record (lib/pages/buffer.lua) gains its rings: arc_delta and
  -- arc_redraw in lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[S.constants.UI_PAGES.index.BUFFER]
  assert(record, "lib/arc/buffer.lua: no BUFFER page record in S.registry.pages")
  record.arc_delta = arc_buffer_delta
  record.arc_redraw = arc_buffer_redraw

  return M
end

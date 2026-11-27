-- lib/arc/io.lua
-- The IO page's arc rings (3.6): the tape's level, speed, feedback and
-- wear. Sets arc_delta and arc_redraw on IO's S.registry.pages record.

return function(S)
  local M = {}

  -- IO page rings: the param each ring adjusts (each sweeps its range in
  -- UI_PAGES.ARC_TICKS_PER_SWEEP ticks)
  local ARC_IO_RINGS = {
    {param_id = "tapeloop_level"},
    {param_id = "tapeloop_rate"},
    {param_id = "tapeloop_feedback"},
    {param_id = "tapeloop_wear"}
  }

  local ARC_IO_LEVEL = 12

  local function arc_io_delta(n, delta)
    local ring = ARC_IO_RINGS[n]
    if ring then
      arc_sweep_param(ring.param_id, delta)
    end
  end

  local function arc_io_redraw(arc_port)
    for n, ring in ipairs(ARC_IO_RINGS) do
      arc_ring_fill_param(arc_port, n, ring.param_id, ARC_IO_LEVEL)
    end
  end

  local record = S.registry.pages[S.constants.UI_PAGES.index.IO]
  assert(record, "lib/arc/io.lua: no IO page record in S.registry.pages")
  record.arc_delta = arc_io_delta
  record.arc_redraw = arc_io_redraw

  return M
end

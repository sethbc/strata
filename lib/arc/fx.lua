-- lib/arc/fx.lua
-- The FX page's arc rings: filter freq and res, delay time and mix. Sets
-- arc_delta and arc_redraw on FX's S.registry.pages record.

return function(S)
  local M = {}

  -- FX page rings: the param each ring adjusts (each sweeps its range in
  -- UI_PAGES.ARC_TICKS_PER_SWEEP ticks)
  local ARC_FX_RINGS = {
    {param_id = "filter_freq"},
    {param_id = "filter_res"},
    {param_id = "delay_time"},
    {param_id = "delay_mix"}
  }

  local function arc_fx_delta(n, delta)
    local ring = ARC_FX_RINGS[n]
    if ring then
      arc_sweep_param(ring.param_id, delta)
    end
  end

  -- Each ring shows its param across its controlspec (following the warp,
  -- so exp params such as filter freq and delay time sweep evenly)
  local function arc_fx_redraw(arc_port)
    for n, ring in ipairs(ARC_FX_RINGS) do
      arc_ring_fill(arc_port, n, param_fraction(ring.param_id), 12)
    end
  end

  -- FX's record (lib/pages/fx.lua) gains its rings: arc_delta and arc_redraw
  -- in lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local found = false
  for _, page in ipairs(S.registry.pages) do
    if page.name == "FX" then
      page.arc_delta = arc_fx_delta
      page.arc_redraw = arc_fx_redraw
      found = true
    end
  end
  assert(found, "lib/arc/fx.lua: no FX page record in S.registry.pages")

  return M
end

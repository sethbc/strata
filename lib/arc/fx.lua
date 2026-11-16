-- lib/arc/fx.lua
-- The FX page's arc rings: filter freq and res, delay time and mix. While
-- the delay is synced (S.lib.delay_sync, 3.7) ring 3 turns its division
-- instead, one whole step per ARC_FX.ticks_per_step ticks carried under
-- "fx:3", and shows the division's place. Sets arc_delta and arc_redraw on
-- FX's S.registry.pages record.

return function(S)
  local M = {}

  -- FX page rings: the param each ring adjusts (each sweeps its range in
  -- UI_PAGES.ARC_TICKS_PER_SWEEP ticks); synced: the param the ring steps
  -- while the delay plays a division
  local ARC_FX_RINGS = {
    {param_id = "filter_freq"},
    {param_id = "filter_res"},
    {param_id = "delay_time", synced = "delay_division"},
    {param_id = "delay_mix"}
  }

  local ARC_FX = {
    level = 12,
    ticks_per_step = 20,  -- a whole division, as VOICE's option rings step
  }

  -- The param a ring steps while the delay plays a division, or nil
  local function synced_param(ring)
    if ring.synced and S.lib.delay_sync.playing() then return ring.synced end
  end

  local function arc_fx_delta(n, delta)
    local ring = ARC_FX_RINGS[n]
    if not ring then return end
    local synced = synced_param(ring)
    if synced then
      local steps = arc_whole_steps("fx:" .. n, delta, ARC_FX.ticks_per_step)
      if steps ~= 0 then delta_with_detent(synced, steps, {source = "arc"}) end
      return
    end
    forget_arc_ticks("fx:" .. n)  -- the carry belongs to the division alone
    arc_sweep_param(ring.param_id, delta)
  end

  -- Each ring shows its param across its controlspec (following the warp,
  -- so exp params such as filter freq and delay time sweep evenly); a
  -- synced ring 3 the division's place among the twelve
  local function arc_fx_redraw(arc_port)
    for n, ring in ipairs(ARC_FX_RINGS) do
      local synced = synced_param(ring)
      if synced then
        arc_ring_fill_position(arc_port, n, param_fraction(synced), ARC_FX.level)
      else
        arc_ring_fill(arc_port, n, param_fraction(ring.param_id), ARC_FX.level)
      end
    end
  end

  -- FX's record (lib/pages/fx.lua) gains its rings: arc_delta and arc_redraw
  -- in lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[S.constants.UI_PAGES.index.FX]
  assert(record, "lib/arc/fx.lua: no FX page record in S.registry.pages")
  record.arc_delta = arc_fx_delta
  record.arc_redraw = arc_fx_redraw

  return M
end

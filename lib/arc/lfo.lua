-- lib/arc/lfo.lua
-- The LFO page's arc rings: the depths of the window's three LFOs and the
-- selected LFO's rate or division. Sets arc_delta and arc_redraw on LFO's
-- S.registry.pages record. The whole-step rings carry their ticks through
-- arc_whole_steps (lib/arc/core.lua) under the keys "lfo:<ring>"; the page
-- forgets them when the window or the selected LFO changes, and
-- forget_arc_lfo_period_ticks ring 4's when the selected LFO's mode does.

return function(S)
  local M = {}

  -- LFO page rings: 1-3 the depths of the window's LFOs (whole percents),
  -- 4 the selected LFO's rate (free, swept like every continuous ring) or
  -- its division (clocked, in whole steps)
  local ARC_LFO = {
    ticks_per_percent = 10,
    ticks_per_rate = 20,
    depth_rings = 3,
    rate_ring = 4,
    levels = {running = 15, stopped = 4, rate = 12}
  }

  -- The arc_whole_steps key of ring n's carried ticks
  local function ticks_key(n)
    return "lfo:" .. n
  end

  -- The LFO depth ring n shows: the window's n-th
  local function ring_lfo(n)
    return S.lib.lfos.window(S.selected_lfo) + n - 1
  end

  local function rate_param_id(n)
    return S.lib.lfos.param_id(n, S.lib.lfos.is_clocked(n) and "division" or "rate")
  end

  local function arc_lfo_delta(n, delta)
    if n <= ARC_LFO.depth_rings then
      local steps = arc_whole_steps(ticks_key(n), delta, ARC_LFO.ticks_per_percent)
      if steps ~= 0 then delta_with_detent(S.lib.lfos.param_id(ring_lfo(n), "depth"), steps, {source = "arc"}) end
    elseif n == ARC_LFO.rate_ring then
      local lfo = S.selected_lfo
      if not S.lib.lfos.is_clocked(lfo) then
        arc_sweep_param(rate_param_id(lfo), delta)
      else
        local steps = arc_whole_steps(ticks_key(n), delta, ARC_LFO.ticks_per_rate)
        if steps ~= 0 then delta_with_detent(rate_param_id(lfo), steps, {source = "arc"}) end
      end
    end
  end

  -- Depth rings are bright while their LFO runs
  local function arc_lfo_redraw(arc_port)
    for n = 1, ARC_LFO.depth_rings do
      local lfo = ring_lfo(n)
      arc_ring_fill(arc_port, n, param_fraction(S.lib.lfos.param_id(lfo, "depth")),
        S.lib.pages_lfo.lfo_running(lfo) and ARC_LFO.levels.running or ARC_LFO.levels.stopped)
    end
    arc_ring_fill(arc_port, ARC_LFO.rate_ring, param_fraction(rate_param_id(S.selected_lfo)), ARC_LFO.levels.rate)
  end

  -- LFO's record (lib/pages/lfo.lua) gains its rings: arc_delta and
  -- arc_redraw in lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[S.constants.UI_PAGES.index.LFO]
  assert(record, "lib/arc/lfo.lua: no LFO page record in S.registry.pages")
  record.arc_delta = arc_lfo_delta
  record.arc_redraw = arc_lfo_redraw

  return M
end

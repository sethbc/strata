-- lib/arc/lfo.lua
-- The LFO page's arc rings: the depth of each LFO and the selected LFO's
-- period. Sets arc_delta and arc_redraw on LFO's S.registry.pages record.
-- The whole-step rings carry their ticks through arc_whole_steps
-- (lib/arc/core.lua) under the keys "lfo:<ring>"; forget_arc_lfo_period_ticks
-- forgets ring 4's.

return function(S)
  local M = {}
  local NUM_LFOS = S.constants.NUM_LFOS

  -- LFO page rings: 1-3 the depth of LFO 1-3 (whole percents), 4 the
  -- selected LFO's period (free seconds, swept like every continuous ring, or
  -- the clocked rate option in whole steps)
  local ARC_LFO = {
    ticks_per_percent = 10,
    ticks_per_rate = 20,
    period_ring = 4
  }

  -- The arc_whole_steps key of ring n's carried ticks
  -- (forget_arc_lfo_period_ticks forgets ring 4's, "lfo:4")
  local function ticks_key(n)
    return "lfo:" .. n
  end

  local function lfo_period_param_id(n)
    if params:string("lfo_mode_" .. n) == "clocked" then
      return "lfo_clocked_" .. n
    end
    return "lfo_free_" .. n
  end

  local function arc_lfo_delta(n, delta)
    if n <= NUM_LFOS then
      local steps = arc_whole_steps(ticks_key(n), delta, ARC_LFO.ticks_per_percent)
      if steps ~= 0 then delta_with_detent("lfo_depth_" .. n, steps) end
    elseif n == ARC_LFO.period_ring then
      local period_id = lfo_period_param_id(S.selected_lfo)
      if period_id == "lfo_free_" .. S.selected_lfo then
        arc_sweep_param(period_id, delta)
      else
        local steps = arc_whole_steps(ticks_key(n), delta, ARC_LFO.ticks_per_rate)
        if steps ~= 0 then delta_with_detent(period_id, steps) end
      end
    end
  end

  -- Depth rings are bright while their LFO runs
  local function arc_lfo_redraw(arc_port)
    for n = 1, NUM_LFOS do
      arc_ring_fill(arc_port, n, param_fraction("lfo_depth_" .. n), S.lib.pages_lfo.lfo_running(n) and 15 or 4)
    end
    arc_ring_fill(arc_port, ARC_LFO.period_ring, param_fraction(lfo_period_param_id(S.selected_lfo)), 12)
  end

  -- LFO's record (lib/pages/lfo.lua) gains its rings: arc_delta and
  -- arc_redraw in lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[S.constants.UI_PAGES.index.LFO]
  assert(record, "lib/arc/lfo.lua: no LFO page record in S.registry.pages")
  record.arc_delta = arc_lfo_delta
  record.arc_redraw = arc_lfo_redraw

  return M
end

-- lib/pages/lfo.lua
-- The LFO page: one row per LFO (shape, phase dot, destination, depth), E2
-- LFO, E3 depth, K2 destination, K3 on/off. Registers its S.registry.pages
-- record. The functions that were global stay global; lfo_running is a
-- field of this module's table (S.lib.pages_lfo) for the arc rings in
-- strata.lua.

return function(S)
  local M = {}
  local NUM_LFOS = S.constants.NUM_LFOS
  local UI_PAGES = S.constants.UI_PAGES

  -- LFO page: one row per LFO at y 16-57 (clear of the header and the hint
  -- row): "L<n>", one cycle of its shape (64 px), a dot at the estimated phase
  -- and last raw value while it runs, then its destination and state/depth
  -- right-aligned
  local LFO_PAGE = {
    row_first_y = 16,   -- top of LFO 1's row
    row_spacing = 15,
    wave_height = 10,   -- shape value 1 at the row top, 0 at top + 10
    wave_x = 12,
    wave_width = 64,
    -- the random shape holds a new value each half cycle; drawn as two steps
    random_display_levels = {0.75, 0.3}
  }

  -- One point (0..1) of a shape at a phase, as the library's process_lfo
  -- computes its raw value
  function lfo_shape_value(shape, phase)
    if shape == "sine" then
      return (math.sin(2 * math.pi * phase) + 1) / 2
    elseif shape == "tri" then
      return phase < 0.5 and phase / 0.5 or 1 - (phase - 0.5) / 0.5
    elseif shape == "up" then
      return phase
    elseif shape == "down" then
      return 1 - phase
    elseif shape == "square" then
      return phase < 0.5 and 1 or 0
    end
    return LFO_PAGE.random_display_levels[phase < 0.5 and 1 or 2]  -- random
  end

  local function lfo_running(n)
    return params:get("lfo_" .. n) == 2
  end
  M.lfo_running = lfo_running

  function redraw_lfo()
    for n = 1, NUM_LFOS do
      local top = LFO_PAGE.row_first_y + (n - 1) * LFO_PAGE.row_spacing
      local bottom = top + LFO_PAGE.wave_height
      local running = lfo_running(n)
      local label_level = n == S.selected_lfo and 15 or 4

      screen.level(label_level)
      screen.move(0, top + 7)
      screen.text("L" .. n)

      local shape = params:string("lfo_shape_" .. n)
      screen.level(running and 6 or 2)
      for px = 0, LFO_PAGE.wave_width - 1 do
        local y = bottom - lfo_shape_value(shape, px / (LFO_PAGE.wave_width - 1)) * LFO_PAGE.wave_height
        if px == 0 then
          screen.move(LFO_PAGE.wave_x, y)
        else
          screen.line(LFO_PAGE.wave_x + px, y)
        end
      end
      screen.stroke()

      if running and S.lfo_last_raw[n] then
        local x = util.round(LFO_PAGE.wave_x + lfo_phase_estimate(n) * (LFO_PAGE.wave_width - 1))
        local y = util.round(bottom - S.lfo_last_raw[n] * LFO_PAGE.wave_height)
        screen.level(15)
        screen.rect(x - 1, y - 1, 3, 3)
        screen.fill()
      end

      screen.level(label_level)
      screen.move(127, top + 5)
      screen.text_right(S.LFO_DESTINATIONS[params:get("strata_lfo" .. n .. "_dest")].label)
      screen.move(127, top + 11)
      screen.text_right((running and "on " or "off ") .. string.format("%.0f%%", params:get("lfo_depth_" .. n)))
    end
  end

  -- The hint row (redraw() draws it after the page)
  local function lfo_hints(alt_held)
    return "E3:depth K2:dest K3:" .. (lfo_running(S.selected_lfo) and "off" or "on")
  end

  local function lfo_enc(n, d)
    if n == 2 then
      local previous_lfo = S.selected_lfo
      S.selected_lfo = util.clamp(S.selected_lfo + d, 1, NUM_LFOS)
      if S.selected_lfo ~= previous_lfo then forget_arc_lfo_period_ticks() end
    elseif n == 3 then
      params:delta("lfo_depth_" .. S.selected_lfo, d)  -- percent steps
    end
  end

  local function lfo_key(n)
    if n == 2 then
      local dest_id = "strata_lfo" .. S.selected_lfo .. "_dest"
      params:set(dest_id, params:get(dest_id) % #S.LFO_DESTINATIONS + 1)
    elseif n == 3 then
      params:set("lfo_" .. S.selected_lfo, lfo_running(S.selected_lfo) and 1 or 2)
    end
  end

  -- The page's record, at LFO's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/lfo.lua's
  S.registry.pages[UI_PAGES.index.LFO] = {name = "LFO", draw = redraw_lfo, hints = lfo_hints,
    enc = lfo_enc, key = lfo_key}

  return M
end

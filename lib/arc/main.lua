-- lib/arc/main.lua
-- The MAIN page's arc rings: density, the selected voice's main param,
-- grain size and grain density. Sets arc_delta and arc_redraw on MAIN's
-- S.registry.pages record.

return function(S)
  local M = {}

  local function arc_main_delta(n, delta)
    if n == 1 then
      -- Ring 1: Master density
      arc_sweep_param("master_density", delta)
    elseif n == 2 then
      -- Ring 2: Selected voice's main parameter
      arc_sweep_param(main_param_id(S.selected_voice), delta)
    elseif n == 3 then
      -- Ring 3: Grain size
      arc_sweep_param("v" .. S.selected_voice .. "_grain_size", delta)
    elseif n == 4 then
      -- Ring 4: Grain density
      arc_sweep_param("v" .. S.selected_voice .. "_grain_density", delta)
    end
  end

  local function arc_main_redraw(arc_port)
    -- Every ring is drawn across its param's controlspec range (as the sweep
    -- moves it): density, the selected voice's main param, grain size, grain density
    local v = S.voices[S.selected_voice]
    local prefix = "v" .. S.selected_voice .. "_"
    arc_ring_fill(arc_port, 1, param_fraction("master_density"), 15)
    arc_ring_fill(arc_port, 2, param_fraction(main_param_id(S.selected_voice)), v.active and 15 or 4)
    arc_ring_fill(arc_port, 3, param_fraction(prefix .. "grain_size"), v.active and 12 or 3)
    arc_ring_fill(arc_port, 4, param_fraction(prefix .. "grain_density"), v.active and 12 or 3)
  end

  -- MAIN's record (lib/pages/main.lua) gains its rings: arc_delta and
  -- arc_redraw in lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  for _, page in ipairs(S.registry.pages) do
    if page.name == "MAIN" then
      page.arc_delta = arc_main_delta
      page.arc_redraw = arc_main_redraw
    end
  end

  return M
end

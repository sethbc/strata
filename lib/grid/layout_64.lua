-- lib/grid/layout_64.lua
-- The 8x8 grid (3.8, design §10.1): the left or the right half of one pane
-- on rows 1-7, row 8 its small strip (NV, the voices). NV tapped plays or
-- stops; held, it shows the chooser, which picks the page, side and half.
-- Registers S.registry.grid_layouts["64"] (lib/grid/pane.lua's arrange)

return function(S)
  local M = {}

  M.layout = S.lib.grid_pane.arrange({half = true, panes = {{strip = {row = 8, keys = "small"}}}})
  S.registry.grid_layouts["64"] = M.layout

  return M
end

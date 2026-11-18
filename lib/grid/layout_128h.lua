-- lib/grid/layout_128h.lua
-- The 16x8 grid (3.8, design §10.1): one pane on rows 1-7, row 8 its strip
-- (play, fill, the page keys, the voices). Registers
-- S.registry.grid_layouts["128h"] (lib/grid/pane.lua's arrange)

return function(S)
  local M = {}

  M.layout = S.lib.grid_pane.arrange({panes = {{x = 0, y = 0, strip = {row = 8, keys = "upper"}}}})
  S.registry.grid_layouts["128h"] = M.layout

  return M
end

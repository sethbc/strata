-- lib/grid/layout_128v.lua
-- The 8x16 grid, a 128 stood upright (3.8, design §10.1): one pane turned,
-- a line down each of columns 1-7 (pane x is the row, y the column), so a
-- line of sixteen runs down and a fader runs up; column 8 is its strip,
-- the 128h's top to bottom. Registers S.registry.grid_layouts["128v"]
-- (lib/grid/pane.lua's arrange)

return function(S)
  local M = {}

  M.layout = S.lib.grid_pane.arrange({turned = true, panes = {{strip = {column = 8, keys = "upper"}}}})
  S.registry.grid_layouts["128v"] = M.layout

  return M
end

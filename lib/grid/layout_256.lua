-- lib/grid/layout_256.lua
-- The 16x16 grid (3.8, design §10.1): two panes, rows 1-7 over rows 9-15,
-- each with its own page; row 8 is the top pane's strip (play, fill, its
-- page keys, the voices), row 16 the bottom's (tempo down and up, its page
-- keys, the mutes). It starts on patterns over voices. Registers
-- S.registry.grid_layouts["256"] (lib/grid/pane.lua's arrange)

return function(S)
  local M = {}
  local PAGES = S.constants.GRID_PAGES

  M.layout = S.lib.grid_pane.arrange({
    panes = {{x = 0, y = 0, strip = {row = 8, keys = "upper"}}, {x = 0, y = 8, strip = {row = 16, keys = "lower"}}},
    start = {PAGES.patterns, PAGES.voices},
  })
  S.registry.grid_layouts["256"] = M.layout

  return M
end

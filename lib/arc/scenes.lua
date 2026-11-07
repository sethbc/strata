-- lib/arc/scenes.lua
-- The SCENES page's arc rings. For now a stub: the rings stay dark and
-- ignore turns. Sets only the arc fields (arc_delta, arc_redraw) on SCENES's
-- S.registry.pages record (lib/pages/scenes.lua).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES

  local function arc_scenes_delta(n, delta) end

  local function arc_scenes_redraw(arc_port) end

  -- SCENES's record gains its rings: arc_delta and arc_redraw in
  -- lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[UI_PAGES.index.SCENES]
  assert(record, "lib/arc/scenes.lua: no SCENES page record in S.registry.pages")
  record.arc_delta = arc_scenes_delta
  record.arc_redraw = arc_scenes_redraw

  return M
end

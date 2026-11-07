-- lib/arc/seq.lua
-- The SEQ page's arc rings. For now a stub: the rings stay dark and
-- ignore turns. Sets only the arc fields (arc_delta, arc_redraw) on SEQ's
-- S.registry.pages record (lib/pages/seq.lua).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES

  local function arc_seq_delta(n, delta) end

  local function arc_seq_redraw(arc_port) end

  -- SEQ's record gains its rings: arc_delta and arc_redraw in
  -- lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[UI_PAGES.index.SEQ]
  assert(record, "lib/arc/seq.lua: no SEQ page record in S.registry.pages")
  record.arc_delta = arc_seq_delta
  record.arc_redraw = arc_seq_redraw

  return M
end

-- lib/arc/voice.lua
-- The VOICE page's arc rings. For now a stub: the rings stay dark and
-- ignore turns. Sets only the arc fields (arc_delta, arc_redraw) on VOICE's
-- S.registry.pages record (lib/pages/voice.lua).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES

  local function arc_voice_delta(n, delta) end

  local function arc_voice_redraw(arc_port) end

  -- VOICE's record gains its rings: arc_delta and arc_redraw in
  -- lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[UI_PAGES.index.VOICE]
  assert(record, "lib/arc/voice.lua: no VOICE page record in S.registry.pages")
  record.arc_delta = arc_voice_delta
  record.arc_redraw = arc_voice_redraw

  return M
end

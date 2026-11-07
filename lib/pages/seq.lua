-- lib/pages/seq.lua
-- The SEQ page: all seven patterns, the transport and the tempo.
-- For now a stub: it draws nothing, its hint row reads "E1:page" and it
-- ignores encoders and keys. Registers its S.registry.pages record (every
-- field but the arc fields, which are lib/arc/seq.lua's).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local ignore_page_input = S.lib.ui_keys.ignore_page_input

  local function seq_hints(alt_held)
    return "E1:page"
  end

  -- The page's record, at SEQ's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]
  S.registry.pages[UI_PAGES.index.SEQ] = {name = "SEQ", draw = ignore_page_input, hints = seq_hints,
    enc = ignore_page_input, key = ignore_page_input}

  return M
end

-- lib/ui/text.lua
-- Text helpers for the screen pages: fit_text is a field of this module's
-- table (S.lib.ui_text).

return function(S)
  local M = {}

  -- Cut text, a whole UTF-8 character at a time, until it fits max_width px
  local function fit_text(text, max_width)
    while text ~= "" and screen.text_extents(text) > max_width do
      text = text:gsub("[^\128-\191][\128-\191]*$", "")
    end
    return text
  end
  M.fit_text = fit_text

  return M
end

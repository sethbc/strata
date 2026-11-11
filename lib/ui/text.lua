-- lib/ui/text.lua
-- Text helpers for the screen pages: fit_text is a field of this module's
-- table (S.lib.ui_text).

return function(S)
  local M = {}

  -- Cut text, a whole UTF-8 character at a time, until it fits max_width px.
  -- It stops when a pass cuts nothing (only continuation bytes are left),
  -- so a text it cannot shorten comes back as it is instead of looping
  -- inside a draw (#514)
  local function fit_text(text, max_width)
    while text ~= "" and screen.text_extents(text) > max_width do
      local shorter = text:gsub("[^\128-\191][\128-\191]*$", "")
      if shorter == text then break end
      text = shorter
    end
    return text
  end
  M.fit_text = fit_text

  return M
end

-- lib/ui/text.lua
-- Text helpers for the screen pages: fit_text and printable are fields of
-- this module's table (S.lib.ui_text).

return function(S)
  local M = {}

  -- The letters of Latin-1 and Latin Extended-A (U+00C0 to U+017F, one word
  -- each, in code order) as plain ASCII: norns' screen font (norns.ttf) has
  -- glyphs for printable ASCII and next to nothing else, so "é" would be a
  -- gap (#551). "?" for the two signs among them (U+00D7, U+00F7)
  local PLAIN_LETTERS = {}
  for word in ("A A A A A A AE C E E E E I I I I D N O O O O O ? O U U U U Y TH ss "
    .. "a a a a a a ae c e e e e i i i i d n o o o o o ? o u u u u y th y "
    .. "A a A a A a C c C c C c C c D d D d E e E e E e E e E e G g G g G g G g H h H h "
    .. "I i I i I i I i I i IJ ij J j K k k L l L l L l L l L l N n N n N n n N n O o O o O o OE oe "
    .. "R r R r R r S s S s S s S s T t T t T t U u U u U u U u U u U u W w Y y Y Z z Z z Z z s"):gmatch("%S+") do
    PLAIN_LETTERS[#PLAIN_LETTERS + 1] = word
  end
  local FIRST_PLAIN_CODE = 0xC0  -- PLAIN_LETTERS[1]

  -- One UTF-8 character (a lead byte and its continuation bytes) as ASCII:
  -- a letter in PLAIN_LETTERS plainly, anything else "?"
  local function plain_character(char)
    if #char ~= 2 then return "?" end
    local code = (char:byte(1) - 0xC0) * 64 + char:byte(2) - 0x80
    return PLAIN_LETTERS[code - FIRST_PLAIN_CODE + 1] or "?"
  end

  -- A text as norns' font can draw it: printable ASCII as it is, accented
  -- Latin letters plainly ("café" is "cafe", "ß" is "ss"), every other
  -- character, control character or byte that is not UTF-8 as one "?".
  -- Only for drawing: a file name is drawn through it (BUFFER's slot rows,
  -- the hint row) and loaded and saved by its real name (#551)
  local function printable(text)
    text = tostring(text)
    if not text:find("[^ -~]") then return text end
    text = text:gsub("[\192-\255][\128-\191]*", plain_character)
    return (text:gsub("[^ -~]", "?"))
  end
  M.printable = printable

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

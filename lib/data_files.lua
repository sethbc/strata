-- lib/data_files.lua
-- Strata's data files (S.lib.data_files): scenes.data and buffers.data are
-- read here. Their layout is norns' tab.save's (lib/tabutil.lua), and the
-- reader is a parser of exactly that layout, so a file is never run as Lua
-- (#464):
--   decode(text)     the value, or nil and what is wrong
--   read(path)       the value of the file at path; nil and "missing"; or
--                    nil, "unreadable" and why
--   read_text(path)  a file's bytes, or nil
-- See docs/notes/lua/data-files.md.

return function(S)
  local M = {}

  local DATA_FILES = {
    max_bytes = 4 * 1024 * 1024,  -- a larger file is not read (8 full scenes are about 100 KB)
    -- the most tables a file may hold: a scenes file of eight full scenes
    -- holds 546, so this leaves fifteen times that, and it bounds what a
    -- hostile file can make the reader build (each table about 60 bytes
    -- empty, so under 1 MB for the tables themselves)
    max_tables = 8192,
  }
  M.DATA_FILES = DATA_FILES

  -- What %q writes after a backslash, besides digits (\n and \r are older
  -- Lua's)
  local ESCAPES = {['"'] = '"', ["\\"] = "\\", ["\n"] = "\n", n = "\n", r = "\r"}

  -- The value tab.save's text holds, or nil and what is wrong (with the byte
  -- it was found at). A parser of exactly that layout: "return {", then per
  -- table a "-- Table: {n}" comment and "{ ... },", each entry a value or
  -- [key]=value, each key or value a number, a %q string, true, false, inf,
  -- -inf, nan, -nan or a table reference {n}; then "}". Spaces, newlines and
  -- "--" comments may stand between tokens. Nothing in the text is run, so a
  -- file can call nothing and loop nowhere, reading takes time in proportion
  -- to its length, at most DATA_FILES.max_tables tables are made, and
  -- nothing is raised
  function M.decode(text)
    if type(text) ~= "string" then return nil, "not text" end
    local max_tables = DATA_FILES.max_tables
    local position = 1
    -- tables[n] is the file's table n, made when it is first read or first
    -- named by a reference (a reference may name a later table, or its own),
    -- so a reference is the table itself and nothing is linked afterward
    local tables, highest_named = {}, 0
    local function fail(what) error({problem = what .. " at byte " .. position}, 0) end
    local function numbered_table(number)
      if number < 1 then fail("reference to a missing table {" .. number .. "}") end
      if number > max_tables then fail("more than " .. max_tables .. " tables") end
      local found = tables[number]
      if not found then
        found = {}
        tables[number] = found
      end
      return found
    end

    -- past spaces, newlines and "--" comments
    local function skip()
      while true do
        local _, last = text:find("^%s+", position)
        if last then position = last + 1 end
        if text:sub(position, position + 1) == "--" then
          local line_end = text:find("\n", position, true)
          position = (line_end or #text) + 1
        elseif not last then
          return
        end
      end
    end
    local function at(literal)
      skip()
      return text:sub(position, position + #literal - 1) == literal
    end
    local function expect(literal)
      if not at(literal) then fail("expected " .. literal) end
      position = position + #literal
    end

    -- One escape: a backslash's character and the (up to two) digits after
    -- it. A digit starts a decimal escape of up to three digits; any other
    -- character keeps the digits after it as they are
    local function unescape(escaped, digits)
      if escaped:find("^%d") then
        local code = tonumber(escaped .. digits)
        if code > 255 then fail("bad escape") end
        return string.char(code)
      end
      local plain = ESCAPES[escaped]
      if not plain then fail("bad escape") end
      return plain .. digits
    end

    -- A string from the opening quote to the next unescaped one: its text is
    -- taken whole and unescaped in one pass, so an escape costs no table
    local function quoted()
      local first = position + 1  -- after the opening quote
      local cursor = first
      while true do
        local stop = text:find('["\\\n]', cursor)
        if not stop then fail("unfinished string") end
        local found = text:sub(stop, stop)
        if found == '"' then
          position = stop + 1
          local raw = text:sub(first, stop - 1)
          if not raw:find("\\", 1, true) then return raw end
          return (raw:gsub("\\(.)(%d?%d?)", unescape))
        end
        if found == "\n" then
          position = stop
          fail("unfinished string")
        end
        cursor = stop + 2  -- past the backslash and the character it escapes
      end
    end

    -- A table reference {n}: the table itself
    local function reference()
      expect("{")
      skip()
      local digits = text:match("^%d+", position)
      if not digits then fail("expected a table number") end
      position = position + #digits
      expect("}")
      local number = tonumber(digits)
      local found = numbered_table(number)
      if number > highest_named then highest_named = number end
      return found
    end

    local function scalar()
      skip()
      local first = text:sub(position, position)
      if first == '"' then return quoted() end
      if first == "{" then return reference() end
      local word = text:match("^%-?%a+", position)
      if word then
        if text:find("^[%w_]", position + #word) then fail("unexpected word") end
        if word == "true" then position = position + #word; return true end
        if word == "false" then position = position + #word; return false end
        -- what tostring writes for the numbers that have no literal
        if word == "inf" then position = position + #word; return math.huge end
        if word == "-inf" then position = position + #word; return -math.huge end
        if word == "nan" or word == "-nan" then position = position + #word; return 0 / 0 end
        fail("unexpected word")
      end
      local number_text = text:match("^%-?[%d%.]+[eE][%+%-]?%d+", position) or text:match("^%-?[%d%.]+", position)
      local number = number_text and tonumber(number_text)
      if not number then fail("expected a value") end
      position = position + #number_text
      return number
    end

    -- One table's entries, into target. A positional value takes the next
    -- index and wins over a keyed entry for the same index, wherever that
    -- stands, as in a table constructor
    local function entries(target)
      local listed = 0
      expect("{")
      while not at("}") do
        if at("[") then
          position = position + 1
          local key = scalar()
          expect("]")
          expect("=")
          local value = scalar()
          if key ~= key then fail("a NaN key") end
          if not (type(key) == "number" and key >= 1 and key <= listed and key % 1 == 0) then target[key] = value end
        else
          listed = listed + 1
          target[listed] = scalar()
        end
        expect(",")
      end
      expect("}")
    end

    local ok, result = pcall(function()
      local count = 0
      expect("return")
      expect("{")
      while not at("}") do
        count = count + 1
        entries(numbered_table(count))
        expect(",")
      end
      expect("}")
      skip()
      if position <= #text then fail("text after the end") end
      if count == 0 then fail("no table") end
      if highest_named > count then fail("reference to a missing table {" .. highest_named .. "}") end
      return tables[1]
    end)
    if ok then return result end
    if type(result) == "table" and result.problem then return nil, result.problem end
    return nil, "cannot be decoded (" .. tostring(result) .. ")"
  end

  -- A file's bytes, or nil when it cannot be read
  local function read_text(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return type(text) == "string" and text or nil
  end
  M.read_text = read_text

  -- The value the file at path holds; or nil and "missing" (it cannot be
  -- opened); or nil, "unreadable" and why (larger than
  -- DATA_FILES.max_bytes, or not tab.save's layout)
  function M.read(path)
    local file = io.open(path, "rb")
    if not file then return nil, "missing" end
    local size = file:seek("end")
    if type(size) ~= "number" or size > DATA_FILES.max_bytes then
      file:close()
      return nil, "unreadable", "larger than " .. DATA_FILES.max_bytes .. " bytes"
    end
    file:seek("set", 0)
    local text = file:read("*a")
    file:close()
    if type(text) ~= "string" then return nil, "unreadable", "cannot be read" end
    local value, problem = M.decode(text)
    if value == nil then return nil, "unreadable", problem end
    return value
  end

  return M
end

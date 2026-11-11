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
  }
  M.DATA_FILES = DATA_FILES

  -- What %q writes after a backslash, besides digits and a newline (\n and
  -- \r are older Lua's)
  local ESCAPES = {['"'] = '"', ["\\"] = "\\", n = "\n", r = "\r"}

  -- The value tab.save's text holds, or nil and what is wrong (with the byte
  -- it was found at). A parser of exactly that layout: "return {", then per
  -- table a "-- Table: {n}" comment and "{ ... },", each entry a value or
  -- [key]=value, each key or value a number, a %q string, true, false, inf,
  -- -inf, nan, -nan or a table reference {n}; then "}". Spaces, newlines and
  -- "--" comments may stand between tokens. Nothing in the text is run, so a
  -- file can call nothing and loop nowhere, reading takes time in proportion
  -- to its length, and nothing is raised
  function M.decode(text)
    if type(text) ~= "string" then return nil, "not text" end
    local position = 1
    local function fail(what) error({problem = what .. " at byte " .. position}, 0) end

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

    -- A string from the opening quote to the next unescaped one
    local function quoted()
      local parts = {}
      position = position + 1  -- the opening quote
      while true do
        local stop = text:find('["\\\n]', position)
        if not stop then fail("unfinished string") end
        parts[#parts + 1] = text:sub(position, stop - 1)
        local found = text:sub(stop, stop)
        position = stop + 1
        if found == '"' then return table.concat(parts) end
        if found == "\n" then fail("unfinished string") end
        local escaped = text:sub(position, position)
        local digits = text:match("^%d%d?%d?", position)
        if digits then
          if tonumber(digits) > 255 then fail("bad escape") end
          parts[#parts + 1] = string.char(tonumber(digits))
          position = position + #digits
        elseif escaped == "\n" then
          parts[#parts + 1] = "\n"
          position = position + 1
        elseif ESCAPES[escaped] then
          parts[#parts + 1] = ESCAPES[escaped]
          position = position + 1
        else
          fail("bad escape")
        end
      end
    end

    -- A table reference {n}: a marker until every table is read
    local function reference()
      expect("{")
      skip()
      local digits = text:match("^%d+", position)
      if not digits then fail("expected a table number") end
      position = position + #digits
      expect("}")
      return {reference = tonumber(digits)}
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

    -- One table's entries, as read: keyed ({key, value} pairs) and listed
    local function entries()
      local keyed, listed = {}, {}
      expect("{")
      while not at("}") do
        if at("[") then
          position = position + 1
          local key = scalar()
          expect("]")
          expect("=")
          keyed[#keyed + 1] = {key, scalar()}
        else
          listed[#listed + 1] = scalar()
        end
        expect(",")
      end
      expect("}")
      return {keyed = keyed, listed = listed}
    end

    local ok, result = pcall(function()
      local parsed = {}
      expect("return")
      expect("{")
      while not at("}") do
        parsed[#parsed + 1] = entries()
        expect(",")
      end
      expect("}")
      skip()
      if position <= #text then fail("text after the end") end
      if #parsed == 0 then fail("no table") end
      -- every table exists before any reference is resolved (a reference can
      -- name a later table, or its own)
      local tables = {}
      for index = 1, #parsed do tables[index] = {} end
      local function resolve(item)
        if type(item) ~= "table" then return item end
        local target = tables[item.reference]
        if not target then fail("reference to a missing table {" .. tostring(item.reference) .. "}") end
        return target
      end
      for index, source in ipairs(parsed) do
        local target = tables[index]
        for _, pair in ipairs(source.keyed) do
          local key = resolve(pair[1])
          if key ~= key then fail("a NaN key") end
          target[key] = resolve(pair[2])
        end
        -- after the keyed entries, as a table constructor sets them
        for list_index, item in ipairs(source.listed) do target[list_index] = resolve(item) end
      end
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

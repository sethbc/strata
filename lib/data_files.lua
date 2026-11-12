-- lib/data_files.lua
-- Strata's data files (S.lib.data_files): scenes.data, buffers.data and
-- grids.data (lib/grid/core.lua's rotations) are written and read here, and
-- nowhere else. Their layout is norns'
-- tab.save's (lib/tabutil.lua), so every earlier Strata (which reads with
-- tab.load) reads what this writes, and the reader is a parser of exactly
-- that layout, so a file is never run as Lua (#464):
--   encode(value)        the text, each table's keys in a fixed order (the
--                        same value always gives the same bytes)
--   decode(text)         the value, or nil and what is wrong
--   write(path, value)   the text to <path>.part, each step checked, then
--                        renamed over path; nothing is written when path
--                        already holds the same bytes (#301)
--   read(path)           the value of the file at path; nil and "missing";
--                        or nil, "unreadable" and why
--   read_text(path)      a file's bytes, or nil
--   set_aside(path, s)   rename path to its first free backup name
--   keep_copy(path, s)   copy path to its first free backup name
-- See docs/notes/lua/data-files.md.

return function(S)
  local M = {}

  local DATA_FILES = {
    max_bytes = 4 * 1024 * 1024,  -- a larger file is not read (16 full scenes are at most about 1.1 MB)
    -- the most tables a file may hold: the largest scenes file 3.4 writes
    -- (16 full scenes: every step of every voice with every attribute, every
    -- macro target and every matrix routing set) holds 7394, 788 KB to about
    -- 1.1 MB as its numbers print short or long, so this leaves about a
    -- tenth more; it bounds what a hostile file can make the reader build
    -- (each table about 60 bytes empty, so under 1 MB for the tables
    -- themselves)
    max_tables = 8192,
    backups = 9,  -- the backup names: <file><suffix>, then <file><suffix>.2 ... .9
  }
  M.DATA_FILES = DATA_FILES

  -- A number, string or boolean as tab.save writes it (a string through %q,
  -- the others through tostring); nil for anything else
  local function scalar_text(value)
    local kind = type(value)
    if kind == "string" then return string.format("%q", value) end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    return nil
  end

  -- tab.save's text for a table: "return {", then each table reached from
  -- value as "-- Table: {n}" and "{ ... },", a table value as "{n}", then
  -- "}". Per table the array part (ipairs) comes first, then the other keys
  -- in a fixed order (numbers ascending, strings ascending, false, true),
  -- and tables are numbered in the order first reached, so the same value
  -- always gives the same bytes whatever order its keys were set in (what
  -- lets write tell an unchanged file; tab.save follows pairs). A function
  -- or userdata value and a table key are left out (Strata's data has
  -- none; tab.save leaves the first out)
  function M.encode(value)
    assert(type(value) == "table", "encode: not a table")
    local tables, lookup, out = {value}, {[value] = 1}, {"return {\n"}
    local function item_text(item)
      if type(item) ~= "table" then return scalar_text(item) end
      local number = lookup[item]
      if not number then
        number = #tables + 1
        tables[number] = item
        lookup[item] = number
      end
      return "{" .. number .. "}"
    end
    local index = 0
    while index < #tables do
      index = index + 1
      local current = tables[index]
      out[#out + 1] = "-- Table: {" .. index .. "}\n{\n"
      local listed = 0
      for position, item in ipairs(current) do
        listed = position
        local text = item_text(item)
        if text then out[#out + 1] = "   " .. text .. ",\n" end
      end
      local numbers, strings, booleans = {}, {}, {}
      for key in pairs(current) do
        local kind = type(key)
        if kind == "string" then
          strings[#strings + 1] = key
        elseif kind == "number" then
          -- past the array part (a whole key inside it is written above)
          if not (key >= 1 and key <= listed and key % 1 == 0) then numbers[#numbers + 1] = key end
        elseif kind == "boolean" then
          booleans[#booleans + 1] = key
        end
      end
      table.sort(numbers)
      table.sort(strings)
      if #booleans == 2 then booleans = {false, true} end
      for _, keys in ipairs({numbers, strings, booleans}) do
        for _, key in ipairs(keys) do
          local text = item_text(current[key])
          if text then out[#out + 1] = "   [" .. scalar_text(key) .. "]=" .. text .. ",\n" end
        end
      end
      out[#out + 1] = "},\n"
    end
    out[#out + 1] = "}"
    return table.concat(out)
  end

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

  -- Write text to <path>.part and rename it over path. The open, write,
  -- flush, close and rename are each checked (a full card often fails only
  -- at the flush or close); on any failure the .part file is removed and
  -- path is left as it was. true, or false and what failed
  local function replace_file(path, text)
    local part_path = path .. ".part"
    local file, problem = io.open(part_path, "wb")
    if not file then return false, tostring(problem) end
    local written, write_problem = file:write(text)
    local flushed, flush_problem
    if written then flushed, flush_problem = file:flush() end
    local closed, close_problem = file:close()
    if not (written and flushed and closed) then
      os.remove(part_path)
      return false, tostring(write_problem or flush_problem or close_problem or "the write failed")
    end
    local renamed, rename_problem = os.rename(part_path, path)
    if not renamed then
      os.remove(part_path)
      return false, tostring(rename_problem)
    end
    return true
  end

  -- Save value as the file at path: true and "written"; true and
  -- "unchanged" when path already holds exactly encode(value) (nothing is
  -- opened for writing, so an exit or a repeated save with nothing new
  -- costs the card no write); or false and what failed (path then holds
  -- what it held before, whole)
  function M.write(path, value)
    local text = M.encode(value)
    if read_text(path) == text then return true, "unchanged" end
    local done, problem = replace_file(path, text)
    if not done then return false, problem end
    return true, "written"
  end

  -- The backup names of path: path .. suffix, then path .. suffix .. ".2"
  -- ... up to DATA_FILES.backups
  local function backup_name(path, suffix, number)
    return path .. suffix .. (number > 1 and ("." .. number) or "")
  end

  -- The first backup name no file (or folder) has, or nil when every one
  -- is taken: a backup never replaces an earlier one (#466)
  local function free_backup_name(path, suffix)
    for number = 1, DATA_FILES.backups do
      local candidate = backup_name(path, suffix, number)
      if not util.file_exists(candidate) then return candidate end
    end
    return nil
  end

  -- Move path out of the way, to its first free backup name: that name, or
  -- nil and why (every name taken, or the rename failed; path is then still
  -- in place)
  function M.set_aside(path, suffix)
    local backup = free_backup_name(path, suffix)
    if not backup then return nil, "every backup name is taken" end
    local moved, problem = os.rename(path, backup)
    if not moved then return nil, tostring(problem) end
    return backup
  end

  -- Keep a copy of path under its first free backup name (written to a
  -- .part and renamed, so a copy is whole or absent): that name and
  -- "copied"; the name of a backup that already holds the same bytes and
  -- "found" (nothing is copied again); true when path has no file (nothing
  -- to keep); true and "full" when every name is taken: copies of that
  -- format are kept already, so the caller writes anyway rather than
  -- refusing every save (the console says why); or nil and why. path
  -- itself is never touched (#467)
  function M.keep_copy(path, suffix)
    if not util.file_exists(path) then return true end
    local text = read_text(path)
    if not text then return nil, "cannot be read" end
    for number = 1, DATA_FILES.backups do
      local candidate = backup_name(path, suffix, number)
      if read_text(candidate) == text then return candidate, "found" end
    end
    local backup = free_backup_name(path, suffix)
    if not backup then
      print(string.format("%s: every %s copy name is taken (%d copies of that format are kept), so it is written"
        .. " over without another copy", path, suffix, DATA_FILES.backups))
      return true, "full"
    end
    local done, problem = replace_file(backup, text)
    if not done then return nil, problem end
    return backup, "copied"
  end

  return M
end

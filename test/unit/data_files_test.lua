-- test/unit/data_files_test.lua
-- The data files' reader (lib/data_files.lua): scenes.data and buffers.data
-- are parsed as the layout norns' tab.save writes, never run as Lua (#464).
-- The files are written by the stub's tab.save (h.tabutil_text,
-- context.tab.save), which is lib/tabutil.lua's, ported unchanged.
-- Run alone: lua test/run.lua data_files

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, data_root, tabutil_text = h.load_strata, h.local_value, h.data_root, h.tabutil_text

local function write_text(path, text)
  local file = assert(io.open(path, "wb")); file:write(text); file:close()
end

local function file_text(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("*a"); file:close()
  return text
end

-- nil when actual holds what expected holds (the same keys and values, NaN
-- where expected has NaN, the same number subtype on Lua 5.3, and a table
-- reached twice in expected reached twice as one table in actual), else
-- where they differ
local number_kind = math.type or function() return "number" end
local function difference(expected, actual, where, seen, claimed)
  if type(expected) ~= "table" then
    if expected ~= expected then
      if actual ~= actual then return nil end
      return where .. ": NaN expected, got " .. tostring(actual)
    end
    if type(expected) ~= type(actual) or expected ~= actual then
      return where .. ": " .. tostring(expected) .. " expected, got " .. tostring(actual)
    end
    if type(expected) == "number" and number_kind(expected) ~= number_kind(actual) then
      return where .. ": subtype " .. tostring(number_kind(expected)) .. " expected, got " .. tostring(number_kind(actual))
    end
    return nil
  end
  if type(actual) ~= "table" then return where .. ": a table expected, got " .. tostring(actual) end
  if seen[expected] then
    return seen[expected] ~= actual and (where .. ": a shared table read as two tables") or nil
  end
  if claimed[actual] then return where .. ": two tables read as one" end
  seen[expected], claimed[actual] = actual, true
  local expected_count, actual_count = 0, 0
  for _ in pairs(actual) do actual_count = actual_count + 1 end
  -- keys that are tables last: by then the tables they name have been met
  for pass = 1, 2 do
    for key, inner in pairs(expected) do
      if (type(key) == "table") == (pass == 2) then
        expected_count = expected_count + 1
        local actual_key = key
        if pass == 2 then actual_key = seen[key] end
        if actual_key == nil then return where .. ": a table key never met as a value" end
        local found = difference(inner, actual[actual_key], where .. "[" .. tostring(key):sub(1, 20) .. "]",
          seen, claimed)
        if found then return found end
      end
    end
  end
  if expected_count ~= actual_count then
    return where .. ": " .. expected_count .. " keys expected, got " .. actual_count
  end
  return nil
end

test("decode never runs the file: code, a loop and a truncated file are unreadable", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local marker = context.data_dir .. "marker"
  local good = tabutil_text({ version = 4, scenes = {} })
  local bad = {
    'io.open("' .. marker .. '", "w"):close()\n' .. good,
    'os.execute("touch ' .. marker .. '")\n' .. good,
    "while true do end\n" .. good,
    'return {\n-- Table: {1}\n{\n   ["x"]=("y"):rep(1e9),\n},\n}',
    'return {\n-- Table: {1}\n{\n   ["x"]=os.time(),\n},\n}',
    'return {\n-- Table: {1}\n{\n   ["x"]={7},\n},\n}',       -- a reference to no table
    good:sub(1, #good - 40),                                    -- cut short
    good .. "\nos.exit()",
    "return {", "", "\27Lua",
  }
  assert_equal(#bad, 11)
  for index, text in ipairs(bad) do
    local value, problem = data_files.decode(text)
    assert_equal(value, nil, "bad text " .. index .. " decodes to no value")
    assert_equal(type(problem), "string", "bad text " .. index .. " says why")
    -- the same text as a file, through read (the scenes and buffers loads' reader)
    local path = context.data_dir .. "bad_" .. index .. ".data"
    write_text(path, text)
    local read_value, outcome, why = data_files.read(path)
    assert_equal(read_value, nil, "bad file " .. index .. " reads as no value")
    assert_equal(outcome, "unreadable", "bad file " .. index)
    assert_equal(type(why), "string", "bad file " .. index .. " says why")
    assert_true(not util.file_exists(marker), "nothing in bad file " .. index .. " ran")
  end
  local value = data_files.decode(good)
  assert_equal(type(value), "table", "the plain file decodes")
  assert_equal(value.version, 4); assert_equal(type(value.scenes), "table")
  write_text(context.data_dir .. "good.data", good)
  assert_equal(data_files.read(context.data_dir .. "good.data").version, 4, "and reads")
end)

test("decode reads every layout tab.save writes as the value saved: escapes, inf and nan, shared and cyclic tables",
    function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local bytes = {}
  for byte = 0, 255 do bytes[#bytes + 1] = string.char(byte) end
  local every_byte = table.concat(bytes)
  local shared = { "shared", 2 }
  shared.again = shared                          -- a table that names itself
  local value = {
    version = 4,
    -- %q's escapes: \" \\ backslash-newline, \0 and the other control bytes
    -- as decimal digits (\000 before a digit), raw bytes from 128 up
    name = 'a "quoted" \\ name\non two lines\r\0 -- not a comment',
    every_byte = every_byte,
    before_digits = "\0" .. "1" .. "\1" .. "23" .. "\127" .. "9",
    list = { 1, -2, 2.0, 3.5, -0.25, 1e+20, 1.25e-07, 123456789012, true, false, "x", shared },
    first = shared, second = shared,
    [0.5] = "half", [-3] = "negative", [10] = "past the array", [true] = "yes", [false] = "no",
    [every_byte] = "a key of every byte",
    [shared] = "a table key",
    nested = { deep = { deeper = { x = 1 } } },
  }
  value.self = value
  value.nested.deep.up = value.nested             -- a cycle through a later table
  local path = context.data_dir .. "layout.data"
  context.tab.save(value, path)
  local text = file_text(path)
  assert_true(text:find("\\0001", 1, true) ~= nil, "the file holds a \\000 escape before a digit")
  local decoded, problem = data_files.decode(text)
  assert_equal(type(decoded), "table", tostring(problem))
  assert_equal(difference(value, decoded, "value", {}, {}), nil)
  -- norns' reader reads the same value from the same file
  assert_equal(difference(context.tab.load(path), decoded, "tab.load's value", {}, {}), nil)

  -- inf, -inf and NaN, written as tostring writes them (tab.load cannot read them)
  value.limits = { math.huge, -math.huge, 0 / 0, -(0 / 0) }
  value.not_a_number = 0 / 0
  context.tab.save(value, path)
  text = file_text(path)
  assert_true(text:find("inf,", 1, true) ~= nil and text:find("-inf,", 1, true) ~= nil, "the file holds inf")
  assert_true(text:find("nan,", 1, true) ~= nil, "the file holds nan")
  decoded, problem = data_files.decode(text)
  assert_equal(type(decoded), "table", tostring(problem))
  assert_equal(difference(value, decoded, "value", {}, {}), nil)

  -- older Lua's \n and \r escapes (hand-written: %q no longer writes them)
  decoded, problem = data_files.decode('return {\n-- Table: {1}\n{\n   "a\\nb\\rc",\n},\n}')
  assert_equal(type(decoded), "table", tostring(problem))
  assert_equal(decoded[1], "a\nb\rc")
end)

-- The heap's growth while fn runs, in KB, garbage included (the collector
-- is stopped meanwhile)
local function heap_growth_kb(fn)
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  local ok, problem = pcall(fn)
  local grown = collectgarbage("count") - before
  collectgarbage("restart")
  assert_true(ok, tostring(problem))
  return grown
end

test("decode refuses more than max_tables tables, and hostile 4 MB texts cost a bounded heap", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local max_tables, max_bytes = data_files.DATA_FILES.max_tables, data_files.DATA_FILES.max_bytes
  -- a scenes file of eight full scenes holds 546 tables (97157 bytes)
  assert_true(max_tables >= 15 * 546, "room for fifteen times a full scenes file's tables: " .. max_tables)
  local function tables_text(count, entry) return "return {\n" .. string.rep("{" .. entry .. "},\n", count) .. "}" end
  local value, problem = data_files.decode(tables_text(max_tables, "1,"))
  assert_equal(type(value), "table", tostring(problem)); assert_equal(value[1], 1)
  value, problem = data_files.decode(tables_text(max_tables + 1, "1,"))
  assert_equal(value, nil)
  assert_true(tostring(problem):find("more than " .. max_tables .. " tables", 1, true) ~= nil, tostring(problem))
  -- a reference past max_tables names a table the file cannot hold
  value, problem = data_files.decode(tables_text(1, "{" .. (max_tables + 1) .. "},"))
  assert_equal(value, nil)
  assert_true(tostring(problem):find("more than " .. max_tables .. " tables", 1, true) ~= nil, tostring(problem))
  -- 4 MB texts of empty tables, of tables of one entry and of tables of one
  -- reference: the reader gives up at max_tables + 1, having built at most
  -- max_tables tables (under 2 MB)
  for _, entry in ipairs({ "", "1,", "{1}," }) do
    local text = tables_text(math.floor(max_bytes / (#entry + 4)), entry)
    local grown = heap_growth_kb(function()
      value, problem = data_files.decode(text)
    end)
    assert_equal(value, nil, "{" .. entry .. "} repeated")
    assert_true(grown < 2048, "{" .. entry .. "} repeated grows the heap by " .. math.floor(grown) .. " KB")
  end
  -- a 4 MB string of \0 escapes: the heap grows by at most three times the text
  local text = 'return {\n{\n"' .. string.rep("\\0", math.floor((max_bytes - 16) / 2)) .. '",\n},\n}'
  local grown = heap_growth_kb(function()
    value, problem = data_files.decode(text)
  end)
  assert_equal(type(value), "table", tostring(problem)); assert_equal(#value[1], math.floor((max_bytes - 16) / 2))
  assert_true(grown < 3 * #text / 1024, "\\0 escapes grow the heap by " .. math.floor(grown) .. " KB")
end)

test("read says a file is missing, too large or damaged; read_text gives a file's bytes", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local max_bytes = data_files.DATA_FILES.max_bytes
  assert_equal(max_bytes, 4 * 1024 * 1024, "4 MB (eight full scenes are about 100 KB)")
  local path = context.data_dir .. "read.data"
  local value, outcome, why = data_files.read(context.data_dir .. "no_such.data")
  assert_equal(value, nil); assert_equal(outcome, "missing"); assert_equal(why, nil)
  -- a good file padded with spaces to exactly max_bytes reads; one byte more does not
  local good = tabutil_text({ version = 2, paths = { "a.wav" } })
  write_text(path, good .. string.rep(" ", max_bytes - #good))
  assert_equal(data_files.read(path).paths[1], "a.wav", "a file of max_bytes reads")
  write_text(path, good .. string.rep(" ", max_bytes - #good + 1))
  value, outcome, why = data_files.read(path)
  assert_equal(value, nil); assert_equal(outcome, "unreadable")
  assert_true(tostring(why):find(tostring(max_bytes), 1, true) ~= nil, "why names the limit: " .. tostring(why))
  -- damaged: why names the byte
  write_text(path, good:sub(1, 30))
  value, outcome, why = data_files.read(path)
  assert_equal(value, nil); assert_equal(outcome, "unreadable")
  assert_true(tostring(why):find("at byte %d+") ~= nil, "why names the byte: " .. tostring(why))
  -- read_text: the bytes as they are, or nil
  write_text(path, "a\r\n\0b")
  assert_equal(data_files.read_text(path), "a\r\n\0b")
  assert_equal(data_files.read_text(context.data_dir .. "no_such.data"), nil)
end)

test("scenes.data and buffers.data that hold code run none of it at start and are kept as .bak (#464)", function()
  local dir = data_root .. "data_files_code/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  local scenes_marker, buffers_marker = dir .. "scenes_ran", dir .. "buffers_ran"
  local scenes_text = 'io.open("' .. scenes_marker .. '", "w"):close()\n'
    .. tabutil_text({ version = 4, scenes = {} })
  local buffers_text = 'io.open("' .. buffers_marker .. '", "w"):close()\n'
    .. tabutil_text({ version = 2, paths = { "" }, starts = { 0 } })
  write_text(dir .. "scenes.data", scenes_text)
  write_text(dir .. "buffers.data", buffers_text)
  local context = load_strata({ data_subdir = "data_files_code" })
  assert_true(not util.file_exists(scenes_marker), "nothing in scenes.data ran")
  assert_true(not util.file_exists(buffers_marker), "nothing in buffers.data ran")
  assert_equal(file_text(dir .. "scenes.data.bak"), scenes_text, "the scenes file is kept, byte for byte")
  assert_equal(file_text(dir .. "buffers.data.bak"), buffers_text, "the buffers file is kept, byte for byte")
  local said = { scenes = false, buffers = false }
  for _, line in ipairs(context.printed) do
    if line:find("error loading scenes file: ", 1, true) then said.scenes = true end
    if line:find("error loading buffers file: ", 1, true) then said.buffers = true end
  end
  assert_true(said.scenes and said.buffers, "the console says each file could not be loaded")
end)
end

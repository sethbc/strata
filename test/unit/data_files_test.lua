-- test/unit/data_files_test.lua
-- The data files' reader (lib/data_files.lua): scenes.data and buffers.data
-- are parsed as the layout norns' tab.save writes, never run as Lua (#464).
-- The files are written by the stub's tab.save (h.tabutil_text,
-- context.tab.save), which is lib/tabutil.lua's, ported unchanged.
-- Run alone: lua test/run.lua data_files

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, data_root, tabutil_text = h.load_strata, h.local_value, h.data_root, h.tabutil_text
local write_text, file_text, watch_writes = h.write_text, h.file_text, h.watch_writes

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

-- The heap's growth while fn runs, in bytes: full collections first, then
-- the collector stopped while fn runs, so the figure is everything fn
-- allocates, garbage included, whenever the collector would have run
local function heap_growth_bytes(fn)
  collectgarbage("collect")
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  local ok, problem = pcall(fn)
  local grown = (collectgarbage("count") - before) * 1024
  collectgarbage("restart")
  assert_true(ok, tostring(problem))
  return grown
end

-- The memory bounds, from the heap growth measured on Lua 5.3 and LuaJIT
-- 2.1 (repeated runs: LuaJIT's figures move by up to a sixth). Each sits
-- about halfway, on a ratio scale, between what this reader costs and what
-- the reader before the #464 review cost, so it has room on both
-- interpreters and still fails that reader: a table costs 72 to 97 bytes
-- here and 320 to 465 with a wrapper, keyed and listed tables and a marker
-- per reference; a string of \0 escapes costs 1.5 to 2.6 bytes of heap per
-- byte of text here and 8.5 to 16.5 with a part kept per escape
local MEMORY_BOUNDS = { bytes_per_table = 160, heap_per_text_byte = 5 }

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
  -- max_tables tables, each at a small cost
  for _, entry in ipairs({ "", "1,", "{1}," }) do
    local text = tables_text(math.floor(max_bytes / (#entry + 4)), entry)
    local grown = heap_growth_bytes(function()
      value, problem = data_files.decode(text)
    end)
    assert_equal(value, nil, "{" .. entry .. "} repeated")
    local per_table = grown / max_tables
    assert_true(per_table < MEMORY_BOUNDS.bytes_per_table,
      "{" .. entry .. "} repeated costs " .. math.floor(per_table) .. " bytes per table")
  end
  -- a 4 MB string of \0 escapes: the heap grows by a small multiple of the text
  local text = 'return {\n{\n"' .. string.rep("\\0", math.floor((max_bytes - 16) / 2)) .. '",\n},\n}'
  local grown = heap_growth_bytes(function()
    value, problem = data_files.decode(text)
  end)
  assert_equal(type(value), "table", tostring(problem)); assert_equal(#value[1], math.floor((max_bytes - 16) / 2))
  local per_byte = grown / #text
  assert_true(per_byte < MEMORY_BOUNDS.heap_per_text_byte,
    string.format("\\0 escapes cost %.2f bytes of heap per byte of text", per_byte))
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

-- The writer (#301)

test("encode writes tab.save's layout, the same bytes whatever order the keys were set in", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  -- each table's array part first, then numbers, strings, false and true,
  -- each ascending; tables numbered in the order first reached
  local value = { "first", 2.5, { "inner" }, [0.5] = "half", [-3] = "negative", [10] = "ten",
    version = 4, name = 'a "q"', [true] = "yes", [false] = "no", flag = false }
  local expected = table.concat({
    "return {",
    "-- Table: {1}",
    "{",
    '   "first",',
    "   2.5,",
    "   {2},",
    '   [-3]="negative",',
    '   [0.5]="half",',
    '   [10]="ten",',
    "   [\"flag\"]=false,",
    '   ["name"]="a \\"q\\"",',
    '   ["version"]=4,',
    '   [false]="no",',
    '   [true]="yes",',
    "},",
    "-- Table: {2}",
    "{",
    '   "inner",',
    "},",
    "}",
  }, "\n")
  assert_equal(data_files.encode(value), expected)
  -- twenty-six keys set in two orders: the same bytes (pairs order follows
  -- the insertion history, so without the sort they differ)
  local forward, backward = {}, {}
  for code = 97, 122 do forward[string.char(code)] = code end
  for code = 122, 97, -1 do backward[string.char(code)] = code end
  local text = data_files.encode(forward)
  assert_equal(data_files.encode(backward), text, "the same value in another key order gives the same bytes")
  assert_true(text:find('["a"]=97,\n   ["b"]=98,', 1, true) ~= nil, "the keys are sorted")
  -- a shared table is written once and stays shared; norns' reader reads the text
  local shared = { 1, 2, 3 }
  local nested = { list = shared, again = shared, deep = { x = 1 } }
  text = data_files.encode(nested)
  local path = context.data_dir .. "layout.data"
  write_text(path, text)
  local loaded = context.tab.load(path)
  assert_equal(loaded.list[3], 3); assert_true(loaded.list == loaded.again, "a shared table stays shared")
  assert_equal(loaded.deep.x, 1)
  local decoded = assert(data_files.decode(text))
  assert_true(decoded.list == decoded.again); assert_equal(data_files.encode(decoded), text, "decode then encode")
  -- what norns' writer wrote encodes to this layout once read
  assert_equal(data_files.encode(assert(data_files.decode(tabutil_text(nested)))), text)
end)

test("write goes to a .part file and replaces the file only when every step worked", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local path = context.data_dir .. "w.data"
  local saved, detail = data_files.write(path, { a = 1 })
  assert_equal(saved, true); assert_equal(detail, "written")
  assert_equal(file_text(path), data_files.encode({ a = 1 }))
  local before = file_text(path)
  -- the same value again: nothing is opened for writing
  local restore, opened = watch_writes(".part")
  saved, detail = data_files.write(path, { a = 1 })
  restore()
  assert_equal(saved, true); assert_equal(detail, "unchanged")
  assert_equal(#opened, 0, "an unchanged file is not rewritten")
  -- a write, a flush or a close that fails: the old bytes stay, the .part is gone
  for _, how in ipairs({ "write", "flush", "close" }) do
    restore, opened = watch_writes(".part", { at = how, after = 10 })
    saved, detail = data_files.write(path, { a = 2, b = "more than ten bytes" })
    restore()
    assert_equal(saved, false, how .. " fails: write says so")
    assert_true(tostring(detail):find("No space left", 1, true) ~= nil, how .. ": " .. tostring(detail))
    assert_equal(opened[1], path .. ".part", how .. ": the bytes went to the .part file, never the file itself")
    assert_equal(#opened, 1, how .. ": nothing else was opened for writing")
    assert_equal(file_text(path), before, how .. ": the file is byte for byte what it was")
    assert_true(not util.file_exists(path .. ".part"), how .. ": the .part file is removed")
  end
  -- a rename that fails (the name is a folder that holds a file)
  local folder = context.data_dir .. "taken.data"
  os.execute("mkdir -p '" .. folder .. "/inside'")
  saved, detail = data_files.write(folder, { a = 1 })
  assert_equal(saved, false); assert_equal(type(detail), "string")
  assert_true(not util.file_exists(folder .. ".part"), "the .part file is removed after a failed rename")
  -- a folder that does not exist
  saved, detail = data_files.write(context.data_dir .. "no/such/folder/w.data", { a = 1 })
  assert_equal(saved, false, "an unwritable folder says so"); assert_equal(type(detail), "string")
end)

test("a backup never replaces an earlier one; a copy is kept once per content", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  assert_equal(data_files.DATA_FILES.backups, 9, "<file>.bak, then .bak.2 to .bak.9")
  local path = context.data_dir .. "b.data"
  write_text(path, "first"); assert_equal(data_files.set_aside(path, ".bak"), path .. ".bak")
  assert_true(not util.file_exists(path), "set aside: moved, not copied")
  write_text(path, "second"); assert_equal(data_files.set_aside(path, ".bak"), path .. ".bak.2")
  assert_equal(file_text(path .. ".bak"), "first"); assert_equal(file_text(path .. ".bak.2"), "second")
  -- a copy: the file stays; the same bytes are copied once
  write_text(path, "third")
  local kept, how = data_files.keep_copy(path, ".v3")
  assert_equal(kept, path .. ".v3"); assert_equal(how, "copied")
  kept, how = data_files.keep_copy(path, ".v3")
  assert_equal(kept, path .. ".v3", "the same bytes are not copied twice")
  assert_equal(how, "found", "and keep_copy says it found them")
  write_text(path, "fourth")
  assert_equal(data_files.keep_copy(path, ".v3"), path .. ".v3.2", "other bytes get the next name")
  assert_equal(file_text(path), "fourth"); assert_equal(file_text(path .. ".v3"), "third")
  assert_equal(file_text(path .. ".v3.2"), "fourth")
  assert_equal(data_files.keep_copy(context.data_dir .. "none.data", ".v3"), true, "no file: nothing to keep")
  -- every name taken: nothing moves, nothing is copied
  for number = 3, 9 do write_text(path .. ".bak." .. number, "x") end
  write_text(path, "fifth")
  local moved, problem = data_files.set_aside(path, ".bak")
  assert_equal(moved, nil); assert_equal(type(problem), "string"); assert_equal(file_text(path), "fifth")
  for number = 3, 9 do write_text(path .. ".v3." .. number, "x") end
  kept, problem = data_files.keep_copy(path, ".v3")
  assert_equal(kept, nil); assert_equal(type(problem), "string")
  for number = 1, 9 do
    assert_true(file_text(path .. ".bak" .. (number > 1 and ("." .. number) or "")) ~= "fifth", "no backup was replaced")
  end
end)
end

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

test("decode refuses more than max_tables tables, and hostile 12 MB texts cost a bounded heap", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local max_tables, max_bytes = data_files.DATA_FILES.max_tables, data_files.DATA_FILES.max_bytes
  -- The cap keeps at least SCENES_MARGIN times the tables of the largest
  -- scenes file this version writes (DATA_FILES.largest_scenes_tables, the
  -- one place that names it: 16 full scenes, which test/unit/matrix_test.lua
  -- writes and checks against it), so a full file of the player's scenes
  -- always loads, with room for later releases' blocks
  local SCENES_MARGIN = 4
  local largest = data_files.DATA_FILES.largest_scenes_tables
  assert_true(type(largest) == "number" and largest > 0, "the largest scenes file's tables: " .. tostring(largest))
  assert_true(max_tables >= SCENES_MARGIN * largest, string.format(
    "max_tables %d keeps %d times the largest scenes file's %d tables", max_tables, SCENES_MARGIN, largest))
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
  -- max_bytes texts of empty tables, of tables of one entry and of tables of one
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
  -- a max_bytes string of \0 escapes: the heap grows by a small multiple of the text
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
  assert_equal(max_bytes, 12 * 1024 * 1024, "12 MB (16 full scenes, every letter full, are about 3.3 MB)")
  local path = context.data_dir .. "read.data"
  local value, outcome, why = data_files.read(context.data_dir .. "no_such.data")
  assert_equal(value, nil); assert_equal(outcome, "missing"); assert_equal(why, nil)
  -- A regular file in the path makes open fail with ENOTDIR, even as root.
  write_text(path, "a file")
  value, outcome, why = data_files.read(path .. "/child")
  assert_equal(value, nil); assert_equal(outcome, "unreadable")
  assert_true(type(why) == "string" and why ~= "", "the system error reaches the caller")
  -- a good file padded with spaces to exactly max_bytes reads; one byte more does not
  local good = tabutil_text({ version = 2, paths = { "a.wav" } })
  write_text(path, good .. string.rep(" ", max_bytes - #good))
  assert_equal(data_files.read(path).paths[1], "a.wav", "a file of max_bytes reads")
  write_text(path, good .. string.rep(" ", max_bytes - #good + 1))
  value, outcome, why = data_files.read(path)
  assert_equal(value, nil); assert_equal(outcome, "unreadable")
  assert_true(tostring(why):find(tostring(max_bytes), 1, true) ~= nil, "why names the limit: " .. tostring(why))
  write_text(path, "")
  value, outcome, why = data_files.read(path)
  assert_equal(value, nil); assert_equal(outcome, "unreadable")
  assert_true(tostring(why):find("at byte 1", 1, true) ~= nil, "an empty file reaches the parser at byte 1")
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

test("read bounds the bytes requested when a file grows after its size check (#1272)", function()
  local context = load_strata()
  local files = local_value("S").lib.data_files
  local path = context.data_dir .. "growing.data"
  local initial = files.encode({version = 1})
  write_text(path, initial .. "   ")  -- still valid if a reader consumed the changed file
  local open, requested = io.open, 0
  io.open = function(name, mode)
    if name ~= path or mode ~= "rb" then return open(name, mode) end
    local descriptor = assert(open(path, mode))
    return {
      seek = function(_, whence, offset)
        local position = descriptor:seek(whence, offset)
        if whence == "end" then return #initial end  -- the size before the append
        return position
      end,
      read = function(_, count)
        requested = requested + (tonumber(count) or math.huge)
        return descriptor:read(count)
      end,
      close = function() return descriptor:close() end,
    }
  end
  local value, outcome = files.read(path)
  io.open = open
  assert_equal(outcome, "unreadable", "an append during this read requires a fresh read")
  assert_equal(value, nil)
  assert_true(requested <= #initial + 1, "read at most the measured length and one extra byte")
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

test("a PSET save bounds the comparison with the existing side file (#1204)", function()
  local context = load_strata(); h.finish_startup(context)
  local base = context.data_dir .. "strata-01"
  local side = base .. ".macros.data"
  params:write(base .. ".pset")
  local expected = file_text(side)
  local function save(existing, grow)
    write_text(side, existing)
    local reads, open = {}, io.open
    io.open = function(path, mode)
      local file, why, errno = open(path, mode)
      if path ~= side or mode ~= "rb" or not file then return file, why, errno end
      return {
        seek = function(_, ...) return file:seek(...) end,
        close = function() return file:close() end,
        read = function(_, count)
          reads[#reads + 1] = count
          if grow then
            local writer = assert(open(path, "ab"))
            writer:write("extra bytes")
            writer:close()
            grow = false
          end
          return file:read(count)
        end,
      }
    end
    local ok, err = pcall(params.write, params, base .. ".pset")
    io.open = open
    assert_true(ok, tostring(err))
    assert_equal(file_text(side), expected, "the saved side file contains exactly the encoded bytes")
    return reads
  end
  assert_equal(#save(expected .. string.rep("x", 4096)), 0, "no content read when the size differs")
  for _, grow in ipairs({false, true}) do
    local reads = save(expected, grow)
    assert_true(#reads > 0, "matching size is checked for content")
    for _, count in ipairs(reads) do
      assert_true(type(count) == "number" and count <= #expected + 1, "every read has a byte limit")
    end
  end
end)

test("a backup never replaces an earlier one", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  assert_equal(data_files.DATA_FILES.backups, 9, "<file>.bak, then .bak.2 to .bak.9")
  local path = context.data_dir .. "b.data"
  write_text(path, "first"); assert_equal(data_files.set_aside(path, ".bak"), path .. ".bak")
  assert_true(not util.file_exists(path), "set aside: moved, not copied")
  write_text(path, "second"); assert_equal(data_files.set_aside(path, ".bak"), path .. ".bak.2")
  assert_equal(file_text(path .. ".bak"), "first"); assert_equal(file_text(path .. ".bak.2"), "second")
  -- every name taken: nothing moves
  for number = 3, 9 do write_text(path .. ".bak." .. number, "x") end
  write_text(path, "fifth")
  local moved, problem = data_files.set_aside(path, ".bak")
  assert_equal(moved, nil); assert_equal(type(problem), "string"); assert_equal(file_text(path), "fifth")
  for number = 1, 9 do
    assert_true(file_text(path .. ".bak" .. (number > 1 and ("." .. number) or "")) ~= "fifth", "no backup was replaced")
  end
  assert_equal(file_text(path), "fifth", "the file itself is untouched")
end)

test("setting a file aside skips unreadable backups, directories and dangling links (#1072)", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local path = context.data_dir .. "bad.data"
  local backup = path .. ".bak"
  write_text(path, "new archive")
  write_text(backup, "old archive")
  os.execute("chmod 000 " .. h.shell_quote(backup))
  os.execute("mkdir " .. h.shell_quote(backup .. ".2"))
  write_text(backup .. ".2/inside", "keep the directory")
  os.execute("ln -s " .. h.shell_quote("missing-target") .. " " .. h.shell_quote(backup .. ".3"))

  local moved = data_files.set_aside(path, ".bak")
  os.execute("chmod 600 " .. h.shell_quote(backup))
  assert_equal(file_text(backup), "old archive", "the unreadable backup keeps its bytes")
  assert_equal(moved, backup .. ".4", "the first available name")
  assert_equal(file_text(moved), "new archive")
  assert_true(not util.file_exists(path), "the source moved")
  assert_equal(file_text(backup .. ".2/inside"), "keep the directory")
  write_text(context.data_dir .. "missing-target", "link target")
  assert_equal(file_text(backup .. ".3"), "link target", "the old link still points to its target")
end)

test("a backup lookup that cannot traverse the destination keeps the source (#1072)", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local path = context.data_dir .. "bad.data"
  write_text(path, "keep the source")
  write_text(path .. ".parent", "a file, not a directory")
  local moved, problem = data_files.set_aside(path, ".parent/archive")
  assert_equal(moved, nil)
  assert_true(type(problem) == "string" and problem ~= "every backup name is taken", "report the filesystem error")
  assert_equal(file_text(path), "keep the source")
  assert_equal(file_text(path .. ".parent"), "a file, not a directory")
end)

-- 3.9 (#895, ruling 8): read, set_aside and write keep each file's problem,
-- and problems() lists them for SETUP, in the order each was first touched
local function problem_of(data_files, path)
  for _, entry in ipairs(data_files.problems()) do
    if entry.file == path then return entry end
  end
end

test("a file that later reads well loses its row", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local path = context.data_dir .. "later.data"
  write_text(path, "return {")
  assert_equal(data_files.read(path), nil)
  local entry = problem_of(data_files, path)
  assert_true(entry ~= nil, "an unreadable file has a row")
  assert_equal(entry.problem, "unreadable"); assert_equal(entry.backup, nil, "still in place")
  write_text(path, data_files.encode({ version = 1 }))
  assert_equal(data_files.read(path).version, 1)
  assert_equal(problem_of(data_files, path), nil, "read well: the row is gone")
  -- a missing file is no problem either
  write_text(path, "return {"); data_files.read(path); os.remove(path)
  assert_equal(select(2, data_files.read(path)), "missing")
  assert_equal(problem_of(data_files, path), nil, "missing: no row")
end)

test("problems() keeps a set-aside's backup, a failed write and a write over an unreadable file", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local kept, in_place = context.data_dir .. "kept.data", context.data_dir .. "in-place.data"
  -- refused by its reader after a good read (another version): set aside
  write_text(kept, data_files.encode({ version = 99 }))
  assert_equal(data_files.read(kept).version, 99)
  assert_equal(problem_of(data_files, kept), nil, "a good read is no problem")
  assert_equal(data_files.set_aside(kept, ".bak"), kept .. ".bak")
  assert_equal(problem_of(data_files, kept).backup, kept .. ".bak", "set aside: kept as its backup")
  assert_equal(problem_of(data_files, kept).problem, "set aside", "it read, and its reader set it aside")
  -- a good write then keeps the set-aside's row (#868's rule)
  assert_true(data_files.write(kept, { version = 1 }))
  assert_equal(problem_of(data_files, kept).backup, kept .. ".bak", "the set-aside's row stays")
  -- unreadable in place: a failed write says not saved, a good one ends both
  write_text(in_place, "return {")
  data_files.read(in_place)
  local restore = watch_writes("in-place.data", { at = "write", after = 0 })
  assert_equal(data_files.write(in_place, { version = 1 }), false)
  restore()
  assert_equal(problem_of(data_files, in_place).problem, "not saved", "the write's problem shows first")
  assert_true(data_files.write(in_place, { version = 1 }))
  assert_equal(problem_of(data_files, in_place), nil, "written over: no row")
  -- the order each was first touched: three files with a problem, kept first, then
  -- unparsed, then failed (whose failed write comes after the others' reads)
  local unparsed, failed = context.data_dir .. "unparsed.data", context.data_dir .. "no/such/failed.data"
  write_text(unparsed, "return {")
  data_files.read(unparsed)
  assert_equal(data_files.write(failed, { version = 1 }), false)
  local order = {}
  for _, entry in ipairs(data_files.problems()) do order[#order + 1] = entry.file end
  assert_equal(table.concat(order, "|"), table.concat({ kept, unparsed, failed }, "|"), "the order first touched")
  -- a file this session wrote, then set aside on purpose (the live scenes
  -- kept before a PSET load): no problem
  local mine = context.data_dir .. "mine.data"
  assert_true(data_files.write(mine, { version = 1 }))
  assert_true(data_files.set_aside(mine, ".pset.bak") ~= nil)
  assert_equal(problem_of(data_files, mine), nil, "kept on purpose: no row")
  -- problems() is a copy: changing it changes nothing kept
  data_files.problems()[1].backup = "x"
  assert_equal(problem_of(data_files, kept).backup, kept .. ".bak")
end)

-- 5f's review: a missing read keeps a set-aside's row, as a write does
-- (#868's rule), so a probe read or a PSET reload does not drop it while
-- the backup is on the card; and only a write that worked makes a later
-- set_aside a file kept on purpose
test("a missing read keeps a set-aside's row; a failed write leaves the next set_aside recorded", function()
  local context = load_strata()
  local data_files = local_value("S").lib.data_files
  local side = context.data_dir .. "probe.gestures.data"
  write_text(side, "return {")
  data_files.read(side)
  assert_equal(data_files.set_aside(side, ".bak"), side .. ".bak")
  assert_equal(select(2, data_files.read(side)), "missing")
  local entry = problem_of(data_files, side)
  assert_true(entry ~= nil, "the set-aside's row stays after a missing read")
  assert_equal(entry.backup, side .. ".bak"); assert_equal(entry.problem, "unreadable")
  -- a good read still ends it
  write_text(side, data_files.encode({ version = 1 }))
  data_files.read(side)
  assert_equal(problem_of(data_files, side), nil, "a good read ends the row")
  -- read well, a write that fails, then set aside: a problem, with its backup
  local presets = context.data_dir .. "presets.data"
  write_text(presets, data_files.encode({ version = 1 }))
  data_files.read(presets)
  local restore = watch_writes("presets.data", { at = "write", after = 0 })
  assert_equal(data_files.write(presets, { version = 2 }), false)
  restore()
  assert_equal(data_files.set_aside(presets, ".bak"), presets .. ".bak")
  entry = problem_of(data_files, presets)
  assert_true(entry ~= nil and entry.backup == presets .. ".bak", "a failed write is no write of this session's")
  assert_equal(entry.problem, "not saved", "the write's problem shows first")
end)
end

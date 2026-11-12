-- test/unit/side_files_test.lua
-- The side files' helper (lib/side_files.lua, S.lib.side_files, #648): a
-- module's live file in data/strata/ and its file beside each PSET, read,
-- set aside when unusable, never written over when it could not be set
-- aside (#590), written, the PSET hook's write, read and delete, and the
-- live file's timed write. A probe module's spec stands in for the macros',
-- the matrix's and the gestures' (their own tests cover each one's data)
-- Run alone: lua test/run.lua side_files

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local write_text, file_text = h.write_text, h.file_text

local function loaded()
  local context = load_strata(); finish_startup(context)
  return context, local_value("S")
end

-- A probe module's files: its data is state.data, each load is noted in
-- state.loads ({data, path, silent}); options replace spec fields
local function probe(S, options)
  local state = { data = {}, loads = {} }
  local spec = {
    name = "probe", contents = "probes", version = 1, key = "probes",
    live_file = "probe.data", side_suffix = ".probe.data", backup_suffix = ".bak",
    save_delay = 0.1, clock_field = "probe_save_clock",
    capture = function() return state.data end,
    validate = function(data)
      if type(data) ~= "table" then return "no table of probes" end
      if data.bad then return "a bad probe" end
      return nil
    end,
    load = function(data, path, silent) table.insert(state.loads, { data = data, path = path, silent = silent }) end,
  }
  for key, value in pairs(options or {}) do spec[key] = value end
  return S.lib.side_files.new(spec), state
end

local function lines_with(context, text)
  local found = {}
  for _, line in ipairs(context.printed) do
    if line:find(text, 1, true) then table.insert(found, line) end
  end
  return found
end

-- Count the data files' writes to path while body runs
local function counting_writes(S, path)
  local count = { writes = 0 }
  local real_write = S.lib.data_files.write
  S.lib.data_files.write = function(written_path, value)
    if written_path == path then count.writes = count.writes + 1 end
    return real_write(written_path, value)
  end
  function count.stop() S.lib.data_files.write = real_write end
  return count
end

test("side files: a missing file loads nothing, says nothing and may be written", function()
  local context, S = loaded()
  local files, state = probe(S)
  local path = context.data_dir .. "none.probe.data"
  assert_equal(files.read(path), true, "may be written")
  assert_equal(#state.loads, 1, "one load")
  assert_equal(state.loads[1].data, nil, "of nothing")
  assert_equal(state.loads[1].path, path, "naming the file")
  assert_equal(#lines_with(context, "probe"), 0, "no console line")
  assert_true(not util.file_exists(path .. ".bak"), "nothing set aside")
end)

test("side files: a file of the right version loads its data, as validate passed it", function()
  local context, S = loaded()
  local files, state = probe(S)
  local path = context.data_dir .. "good.probe.data"
  assert_true(S.lib.data_files.write(path, { version = 1, probes = { x = 3 } }))
  assert_equal(files.read(path, true), true)
  assert_equal(state.loads[1].data.x, 3, "the file's data, under its key")
  assert_equal(state.loads[1].silent, true, "with the read's silent flag")
  assert_true(util.file_exists(path), "left in place")
  assert_equal(#lines_with(context, "probe"), 0, "no console line")
end)

test("side files: an unusable file is set aside with one console line and loads nothing", function()
  local cases = {
    { text = "return {\n  {1},\n", why = nil },                       -- not a data file: the reader's message
    { value = { version = 2, probes = {} }, why = "not a version 1 probe file" },
    { value = { version = 1 }, why = "no table of probes" },          -- validate sees the missing data
    { value = { version = 1, probes = { bad = true } }, why = "a bad probe" },
    { value = { 1, 2 }, why = "not a version 1 probe file" },
  }
  for index, case in ipairs(cases) do
    local context, S = loaded()
    local files, state = probe(S)
    local path = context.data_dir .. "case" .. index .. ".probe.data"
    write_text(path, case.text or S.lib.data_files.encode(case.value))
    local bytes = file_text(path)
    assert_equal(files.read(path), true, "case " .. index .. ": set aside, so it may be written")
    assert_equal(state.loads[1].data, nil, "case " .. index .. ": nothing loads")
    assert_true(not util.file_exists(path), "case " .. index .. ": moved")
    assert_equal(file_text(path .. ".bak"), bytes, "case " .. index .. ": to its first free backup name, whole")
    local lines = lines_with(context, "error loading probe file " .. path .. ": ")
    assert_equal(#lines, 1, "case " .. index .. ": one console line")
    local suffix = "; kept as " .. path .. ".bak"
    assert_equal(lines[1]:sub(-#suffix), suffix, "case " .. index .. ": naming the backup")
    if case.why then
      assert_equal(lines[1], "error loading probe file " .. path .. ": " .. case.why .. suffix, "case " .. index)
    end
  end
end)

test("side files: a live file that can be neither used nor set aside is never written over (#590)", function()
  local context, S = loaded()
  local files = probe(S)
  local path = context.data_dir .. "strata/probe.data"
  local bad = "return {\n  {1},\n"
  util.make_dir(context.data_dir .. "strata/")
  write_text(path, bad)
  local real_set_aside = S.lib.data_files.set_aside
  S.lib.data_files.set_aside = function() return nil, "permission denied" end  -- looked up at the call
  local ok, problem = pcall(function()
    assert_equal(files.load_live(), false, "not loaded")
    local line = lines_with(context, "error loading probe file " .. path .. ": ")[1]
    assert_true(line ~= nil and line:find("; not moved: permission denied", 1, true) ~= nil, tostring(line))
    assert_equal(#lines_with(context, "probe: " .. path
      .. " could not be read or moved aside; the probes will not be saved this session"), 1, "one line says so")
    files.save_live()
    assert_equal(S.probe_save_clock, nil, "no timed write starts")
    context.clock.run_for(0.2)
    assert_equal(file_text(path), bad, "not written over after a change")
    files.save_now()
    assert_equal(file_text(path), bad, "nor at cleanup")
    assert_equal(files.read(context.data_dir .. "elsewhere.probe.data"), true, "a missing file elsewhere may be written")
  end)
  S.lib.data_files.set_aside = real_set_aside
  if not ok then error(problem, 0) end
end)

test("side files: a damaged live file that is set aside loads nothing and is saved normally", function()
  local context, S = loaded()
  local files, state = probe(S)
  local path = context.data_dir .. "strata/probe.data"
  util.make_dir(context.data_dir .. "strata/")
  write_text(path, "return {\n  {1},\n")
  assert_equal(files.load_live(), true, "set aside: loaded")
  assert_equal(state.loads[1].data, nil)
  assert_equal(#lines_with(context, "will not be saved"), 0, "saves stay on")
  state.data = { x = 1 }
  files.save_live(); context.clock.run_for(0.2)
  assert_equal(S.lib.data_files.read(path).probes.x, 1, "saved normally afterward")
  assert_equal(file_text(path .. ".bak"), "return {\n  {1},\n", "the damaged text is kept")
end)

test("side files: write writes the version and the data, and a failed write says so", function()
  local context, S = loaded()
  local files, state = probe(S)
  state.data = { x = 2, list = { 1, 2 } }
  local path = context.data_dir .. "written.probe.data"
  assert_equal(files.write(path), true)
  local value = S.lib.data_files.read(path)
  assert_equal(value.version, 1); assert_equal(value.probes.x, 2); assert_equal(value.probes.list[2], 2)
  local missing = context.data_dir .. "no_such_folder/written.probe.data"
  assert_equal(files.write(missing), false, "a folder that does not exist")
  local line = lines_with(context, "error: probe not saved to " .. missing .. " (")[1]
  assert_true(line ~= nil and line:sub(-1) == ")", "one console line with the system's reason: " .. tostring(line))
end)

test("side files: the live file is loaded at the start, then written once per burst with the newest data", function()
  local context, S = loaded()
  local files, state = probe(S)
  local path = context.data_dir .. "strata/probe.data"
  assert_true(not util.file_exists(context.data_dir .. "strata/"), "a fresh data folder: the live folder is made")
  local count = counting_writes(S, path)
  local ok, problem = pcall(function()
    files.save_live()
    assert_equal(S.probe_save_clock, nil, "before the start step's read: no timed write")
    context.clock.run_for(0.2)
    assert_equal(count.writes, 0)
    assert_equal(files.load_live(), true, "a missing live file: loaded")
    for step = 1, 20 do
      state.data = { n = step }
      files.save_live()
    end
    assert_true(S.probe_save_clock ~= nil, "one clock waits")
    context.clock.run_for(0.05)
    assert_equal(count.writes, 0, "nothing is written during the delay")
    context.clock.run_for(0.1)
    assert_equal(count.writes, 1, "one write after it")
    assert_equal(S.probe_save_clock, nil, "and the clock is gone")
    assert_equal(S.lib.data_files.read(path).probes.n, 20, "with the newest data")
    -- the cleanup step: what waits is written at once, and nothing after
    state.data = { n = 21 }
    files.save_live()
    files.save_now()
    assert_equal(count.writes, 2, "written at once")
    assert_equal(S.probe_save_clock, nil, "the timed write is canceled")
    assert_equal(S.lib.data_files.read(path).probes.n, 21)
    context.clock.run_for(0.2)
    assert_equal(count.writes, 2, "no write follows")
  end)
  count.stop()
  if not ok then error(problem, 0) end
end)

test("side files: the PSET hook's write always writes, its read passes silent on, its delete removes the file", function()
  local context, S = loaded()
  local order = {}
  local files, state = probe(S, {
    load = function(data, path, silent) table.insert(order, "load " .. tostring(data and data.x) .. " " .. tostring(silent)) end,
  })
  local hook = files.pset_hook(function(silent) table.insert(order, "before " .. tostring(silent)) end,
    function(silent) table.insert(order, "after " .. tostring(silent)) end)
  assert_equal(hook.name, "probe", "named as the files")
  local base = context.data_dir .. "strata-07"
  local side = base .. ".probe.data"
  hook.write(base, "07")
  assert_equal(next(S.lib.data_files.read(side).probes), nil, "empty data is written too")
  state.data = { x = 5 }
  hook.write(base, "07")
  hook.read(base, "07", base .. ".pset", true)
  assert_equal(table.concat(order, ", "), "before true, load 5 true, after true", "in order, each with silent")
  order = {}
  hook.read(base, "07", base .. ".pset", false)
  assert_equal(table.concat(order, ", "), "before false, load 5 false, after false")
  hook.delete(base, "07")
  assert_true(not util.file_exists(side), "deleted with its PSET")
  -- without before and after, a read only loads
  order = {}
  files.pset_hook().read(base, "07", base .. ".pset", nil)
  assert_equal(table.concat(order, ", "), "load nil nil", "a missing side file loads nothing")
end)

test("side files: a spec is checked when it is made", function()
  local context, S = loaded()
  for _, field in ipairs({ "name", "contents", "key", "live_file", "side_suffix", "backup_suffix", "capture",
      "validate", "load", "version" }) do
    local ok, problem = pcall(probe, S, { [field] = false })
    assert_true(not ok and tostring(problem):find(field, 1, true) ~= nil, field .. " is required: " .. tostring(problem))
  end
  local ok, problem = pcall(probe, S, { clock_field = false })
  assert_true(not ok and tostring(problem):find("clock_field", 1, true) ~= nil, "a timed write needs its clock field")
  local files = probe(S, { save_delay = false, clock_field = false })
  files.load_live()
  assert_true(not pcall(files.save_live), "no timed write without a delay")
end)

end

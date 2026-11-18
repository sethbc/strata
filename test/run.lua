-- test/run.lua
-- Off-device test harness for strata. Run from the repo root:
--   lua test/run.lua [--jobs N] [--shard K/N] [filter]      (or luajit)
-- Runs the tests of every test/unit/*_test.lua or, with a filter, of the
-- unit files whose name contains it (`lua test/run.lua scenes`). The shared
-- harness is test/helpers.lua.
--
-- The unit files run in parallel, each in a process of its own, as many at
-- once as --jobs (-j) says, else STRATA_TEST_JOBS, else the machine's cores
-- (at most 8: helpers.lua's default_jobs), never more than there are files.
-- One process (--jobs 1, one file, or a run started from inside a run,
-- which STRATA_TEST_INSIDE_RUN marks) runs every test here, printing what
-- this runner printed before it ran in parallel. A parallel run prints
-- each file's lines whole as its process ends, every failure again at the
-- end, a line of the processes and the seconds, then the same totals.
-- --shard K/N takes only shard K of N of the unit files (helpers.lua's
-- shard_files: every file in exactly one, whatever the filter). --dir DIR
-- reads the unit files from DIR (the runner's own tests); --only NAME and
-- --report PATH are the parallel run's processes' own.
--
-- Exits 2 on a malformed option (a usage line), else non-zero if any test
-- fails, no unit file matches, a unit file fails to load or registers no
-- test, the run stops on an error, or, in a parallel run, a process ends
-- abnormally (a crash, a signal, an exit without its report) or a file is
-- reported by no process or by two (each counts as a failure in the
-- totals). The run's temporary folder (h.data_root, made as helpers.lua
-- loads, which holds its processes' folders) is removed on every one of
-- those ways out (#483).

local test_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "test"
package.path = test_dir .. "/?.lua;" .. package.path

local USAGE = "usage: lua test/run.lua [--jobs N] [--shard K/N] [filter]"

-- The options in `arguments` (arg), or nil and why not
local function parse_options(arguments)
  local options, index = {}, 1
  local function value_of(name)
    local value = arguments[index + 1]
    if value == nil then return nil, name .. " needs a value" end
    index = index + 2
    return value
  end
  while arguments[index] ~= nil do
    local argument, value, problem = arguments[index], nil, nil
    if argument == "--jobs" or argument == "-j" then
      value, problem = value_of(argument)
      if problem then return nil, problem end
      options.jobs = value:match("^%d+$") and tonumber(value)
      if not options.jobs or options.jobs < 1 then return nil, argument .. " takes a whole number of processes, 1 or more: " .. value end
    elseif argument == "--shard" then
      value, problem = value_of(argument)
      if problem then return nil, problem end
      local shard, count = value:match("^(%d+)/(%d+)$")
      shard, count = tonumber(shard), tonumber(count)
      if not shard or shard < 1 or shard > count then return nil, "--shard takes K/N, whole numbers with 1 <= K <= N: " .. value end
      options.shard, options.shard_count = shard, count
    elseif argument == "--dir" or argument == "--only" or argument == "--report" then
      value, problem = value_of(argument)
      if problem then return nil, problem end
      options[argument:sub(3)] = value
    elseif argument:sub(1, 1) == "-" then
      return nil, "no option " .. argument
    elseif options.filter then
      return nil, "one filter at most: " .. options.filter .. ", " .. argument
    else
      options.filter, index = argument, index + 1
    end
  end
  local variable = os.getenv("STRATA_TEST_JOBS")
  if variable and variable ~= "" then
    options.variable_jobs = variable:match("^%d+$") and tonumber(variable)
    if not options.variable_jobs or options.variable_jobs < 1 then
      return nil, "STRATA_TEST_JOBS takes a whole number of processes, 1 or more: " .. variable
    end
  end
  return options
end

local options, problem = parse_options(arg or {})
if not options then
  io.write("test/run.lua: " .. problem .. "\n" .. USAGE .. "\n")
  os.exit(2)
end

-- Every command a run starts (its processes, and whatever its tests start)
-- marks itself as inside a run, so a run started there is single-process
-- and never fans out again, and leaves out a process's folder
local INSIDE_RUN = os.getenv("STRATA_TEST_INSIDE_RUN")
local MARK = "STRATA_TEST_INSIDE_RUN=1; export STRATA_TEST_INSIDE_RUN; unset STRATA_TEST_DATA_ROOT; "
do
  local execute, popen = os.execute, io.popen
  os.execute = function(command, ...)
    if command == nil then return execute() end
    return execute(MARK .. command, ...)
  end
  io.popen = function(command, ...) return popen(MARK .. command, ...) end
end

local h = require("helpers")
local unit_dir = options.dir or (test_dir .. "/unit")

-- The unit files this run takes: the filter's (or --only's one), in the
-- shard's part of every unit file
local function selected_files()
  local names = h.unit_files(unit_dir, options.filter)
  if options.only then
    local only = {}
    for _, name in ipairs(names) do if name == options.only then only[1] = name end end
    names = only
  end
  if options.shard then
    local in_shard, kept = {}, {}
    for _, name in ipairs(h.shard_files(h.unit_files(unit_dir), options.shard, options.shard_count)) do in_shard[name] = true end
    for _, name in ipairs(names) do if in_shard[name] then kept[#kept + 1] = name end end
    names = kept
  end
  return names
end

-- A file's bytes, or nil
local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("*a"); file:close()
  return text
end

-- Write a process's report for the parallel run (--report): its counts and
-- each failure as it printed it, then "end"; written beside and renamed
-- into place, so a report is whole or missing
local function write_report(path, count, failures, blocks)
  local parts = { "strata test report\n", "tests " .. count .. "\n", "failures " .. failures .. "\n" }
  for _, block in ipairs(blocks) do parts[#parts + 1] = "fail " .. #block .. "\n" .. block .. "\n" end
  parts[#parts + 1] = "end\n"
  local file = assert(io.open(path .. ".part", "wb"))
  assert(file:write(table.concat(parts)))
  assert(file:close())
  assert(os.rename(path .. ".part", path))
end

-- A report's counts and failure blocks, or nil when it is missing or not whole
local function read_report(path)
  local text = read_file(path)
  if not text then return nil end
  local count, failures, at = text:match("^strata test report\ntests (%d+)\nfailures (%d+)\n()")
  if not count then return nil end
  local report = { tests = tonumber(count), failures = tonumber(failures), blocks = {} }
  while true do
    local length, start = text:match("^fail (%d+)\n()", at)
    if not length then break end
    local block = text:sub(start, start + tonumber(length) - 1)
    if #block ~= tonumber(length) or text:sub(start + #block, start + #block) ~= "\n" then return nil end
    report.blocks[#report.blocks + 1] = block
    at = start + #block + 1
  end
  if text:sub(at) ~= "end\n" or #report.blocks ~= report.failures then return nil end
  return report
end

-- Run the tests of `names` in this process: the exit status
local function run_here(names)
  local loaded = h.load_unit_files(unit_dir, (options.only or options.shard) and names or options.filter, h)
  if #h.tests == 0 then
    h.real_print("the unit files loaded (" .. table.concat(loaded, ", ") .. ") registered no test")
    return 1
  end

  local failures, blocks = 0, {}
  for _, entry in ipairs(h.tests) do
    local ok, err = h.run_test(entry.func)
    print = h.real_print
    if ok then
      h.real_print("ok   " .. entry.name)
    else
      failures = failures + 1
      local block = "FAIL " .. entry.name .. "\n     " .. tostring(err):gsub("\n", "\n     ")
      blocks[#blocks + 1] = block
      h.real_print(block)
    end
  end
  if options.report then
    write_report(options.report, #h.tests, failures, blocks)
  else
    h.real_print(string.format("\n%d tests, %d failures", #h.tests, failures))
  end
  return failures == 0 and 0 or 1
end

-- The interpreter this run is under (arg's lowest index)
local function interpreter()
  local lowest = 0
  while arg[lowest - 1] do lowest = lowest - 1 end
  return arg[lowest]
end

-- Run `names` in `jobs` processes at once, each file in its own (xargs -P,
-- heaviest first), each writing its output and report under the run's
-- folder: the exit status
local function run_parallel(names, jobs)
  local started = os.time()
  local quote = h.shell_quote
  local workers = h.data_root .. "workers/"
  os.execute("mkdir -p " .. quote(workers))
  for _, name in ipairs(names) do
    if not name:match("^[%w_%-%.]+$") then error("a unit file's name the parallel run cannot pass on: " .. name, 0) end
  end
  local script = workers .. "worker.sh"
  local file = assert(io.open(script, "wb"))
  assert(file:write("#!/bin/sh\n# one unit file of a parallel run (test/run.lua): its output, report and exit status\n",
    'name=$1\n',
    "STRATA_TEST_INSIDE_RUN=1 STRATA_TEST_DATA_ROOT=", quote(workers), '"${name%.lua}/" ', quote(interpreter()), " ",
    quote(arg[0]), " --jobs 1 --dir ", quote(unit_dir), ' --only "$name" --report ', quote(workers), '"$name.report" > ',
    quote(workers), '"$name.out" 2>&1\n',
    'echo "done $name $?"\n'))
  assert(file:close())

  local queue = h.heaviest_first(names)
  local expected, reported = {}, {}
  for _, name in ipairs(names) do expected[name] = true end
  local tests, failures, recap = 0, 0, {}
  local function fail_file(line)
    io.write(line, "\n")
    failures = failures + 1
    recap[#recap + 1] = line
  end
  local pipe = assert(io.popen("printf '%s\\n' " .. table.concat(queue, " ") .. " | xargs -n 1 -P " .. jobs .. " sh "
    .. quote(script) .. " 2>&1"))
  for line in pipe:lines() do
    local name, status = line:match("^done (%S+) (%d+)$")
    status = tonumber(status)
    if not (name and expected[name]) then
      io.write(line, "\n")
    elseif reported[name] then
      fail_file("FAIL " .. name .. ": reported by a second process (exit " .. status .. ")")
    else
      reported[name] = true
      local output = read_file(workers .. name .. ".out") or ""
      io.write(output, (output == "" or output:sub(-1) == "\n") and "" or "\n")
      local report = read_report(workers .. name .. ".report")
      if report and ((status == 0 and report.failures == 0) or (status == 1 and report.failures > 0)) then
        tests, failures = tests + report.tests, failures + report.failures
        for _, block in ipairs(report.blocks) do recap[#recap + 1] = block end
      else
        fail_file("FAIL " .. name .. ": its process ended abnormally (exit " .. status
          .. (report and "" or ", no report") .. ")")
      end
    end
    io.stdout:flush()
  end
  pipe:close()
  for _, name in ipairs(names) do
    if not reported[name] then fail_file("FAIL " .. name .. ": no process reported it") end
  end
  if #recap > 0 then
    io.write("\nthe failures again (", #recap, "):\n", table.concat(recap, "\n"), "\n")
  end
  io.write(string.format("%d unit files in %d processes, %d s\n", #names, jobs, os.time() - started))
  io.write(string.format("\n%d tests, %d failures\n", tests, failures))
  return failures == 0 and 0 or 1
end

-- Find the unit files and run them, here or in parallel: the exit status
local function run()
  local names = selected_files()
  if #names == 0 then
    h.real_print("no unit file in " .. unit_dir .. " matches '" .. tostring(options.filter) .. "'"
      .. (options.shard and (" in shard " .. options.shard .. "/" .. options.shard_count) or ""))
    return 1
  end
  local jobs = (INSIDE_RUN and INSIDE_RUN ~= "") and 1 or options.jobs or options.variable_jobs or h.default_jobs()
  jobs = math.min(jobs, #names)
  if jobs == 1 then return run_here(names) end
  return run_parallel(names, jobs)
end

local ran, status = xpcall(run, debug.traceback)
print = h.real_print
h.remove_tree(h.data_root)
if not ran then
  h.real_print("the run stopped: " .. tostring(status))
  os.exit(1)
end
os.exit(status)

-- test/run.lua
-- Off-device test harness for strata. Run from the repo root:
--   lua test/run.lua      (or)      luajit test/run.lua
-- Exits non-zero if any test fails.

local test_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "test"
local repo_root = test_dir .. "/.."
package.path = test_dir .. "/?.lua;" .. package.path

local stubs = require("norns_stubs")
local sync_check = require("sync_check")
local real_print = print

-- The globals of plain Lua and of this harness, before any stub or script
-- adds its own (the global-reference check starts from these)
local harness_globals = {}
for name in pairs(_G) do harness_globals[name] = true end

local SC_PATH = repo_root .. "/lib/Engine_Strata.sc"
local LUA_PATH = repo_root .. "/strata.lua"
local signatures = stubs.parse_engine_signatures(SC_PATH)
local engine_polls = stubs.parse_engine_polls(SC_PATH)
local engine_spec = stubs.parse_engine_spec(SC_PATH)

local data_root = os.tmpname()
os.remove(data_root)
os.execute("mkdir -p '" .. data_root .. "'")
data_root = data_root .. "/"

local tests = {}
local function test(name, func) table.insert(tests, { name = name, func = func }) end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function fail(message, level) error(message, (level or 1) + 1) end

-- Run one test function: ok, or false and the error. Errors the scheduler
-- reported while resuming a clock (norns prints them and keeps running)
-- fail the test unless it claimed them (clock.take_errors); when the test
-- failed anyway, they are added to its error
local function run_test(func)
  local ok, err = xpcall(func, debug.traceback)
  local clock_errors = stubs.take_clock_errors()
  if #clock_errors > 0 then
    local report = "clock errors reported while the scheduler resumed a coroutine:\n" .. table.concat(clock_errors, "\n")
    err = ok and report or (tostring(err) .. "\n" .. report)
    ok = false
  end
  return ok, err
end

local function assert_true(value, message)
  if not value then fail(message or "expected true", 2) end
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    fail(string.format("%s: expected %s, got %s", message or "values differ", tostring(expected), tostring(actual)), 2)
  end
end

local function assert_near(actual, expected, tolerance, message)
  if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-9) then
    fail(string.format("%s: expected %s, got %s", message or "values differ", tostring(expected), tostring(actual)), 2)
  end
end

-- Load strata.lua (or options.source, a patched copy of it) into fresh
-- stubs and run init(). options.module_sources ({ ["lib/x"] = source })
-- replaces the text of the modules it names (include). init() has added
-- every param: each group must have all of its params. Each load gets its
-- own data directory (unless options.data_subdir names a shared one): a
-- counter, since tests reseed math.random and two loads after one seed
-- would draw the same name. options.skip_init loads the script but leaves
-- init() to the caller (the golden session).
local loads = 0
local function load_strata(options)
  options = options or {}
  loads = loads + 1
  local data_dir = data_root .. (options.data_subdir or ("load" .. loads)) .. "/"
  local context = stubs.install { signatures = signatures, engine_polls = engine_polls, engine_spec = engine_spec,
    data_dir = data_dir, quiet = true, module_sources = options.module_sources }
  context.data_dir = data_dir
  context.audio_dir = data_dir .. "audio/"
  if options.before_load then options.before_load(context) end
  local chunk = options.source and assert(load(options.source, "@" .. LUA_PATH)) or assert(loadfile(LUA_PATH))
  chunk()
  if options.before_init then options.before_init(context) end
  if options.skip_init then return context end  -- the caller runs init() and check_param_groups()
  init()
  context.check_param_groups()
  return context
end

-- The script's shared table S (lib/state.lua): the upvalue S of init, or
-- nil before a load
local function shared_state()
  local init_function = rawget(_G, "init")
  if type(init_function) ~= "function" then return nil end
  local index = 1
  while true do
    local upvalue_name, upvalue_value = debug.getupvalue(init_function, index)
    if not upvalue_name then return nil end
    if upvalue_name == "S" then return upvalue_value end
    index = index + 1
  end
end

-- Find a script value by name: a field of S (one it holds, or one ever
-- assigned, even to nil: S.__declared), then of S.constants, then a script
-- local, found by searching the upvalues of global functions. Returns the
-- value and a setter that writes where the name was found.
local function find_upvalue(name)
  local S = shared_state()
  if type(S) == "table" then
    local declared = rawget(S, "__declared")
    for _, home in ipairs({ S, rawget(S, "constants") }) do
      if type(home) == "table" and (rawget(home, name) ~= nil
          or (home == S and type(declared) == "table" and declared[name])) then
        return rawget(home, name), function(new_value) rawset(home, name, new_value) end
      end
    end
  end
  for _, value in pairs(_G) do
    if type(value) == "function" then
      local index = 1
      while true do
        local upvalue_name, upvalue_value = debug.getupvalue(value, index)
        if not upvalue_name then break end
        if upvalue_name == name then
          return upvalue_value, function(new_value) debug.setupvalue(value, index, new_value) end
        end
        index = index + 1
      end
    end
  end
  error("script local '" .. name .. "' not found")
end

local function local_value(name) return (find_upvalue(name)) end

-- Run the clocks to the frame clock's next tick, which draws the screen and
-- the arc if anything asked for a redraw since the last frame (any clock due
-- before it runs first, as on norns)
local function next_frame(context)
  context.clock.advance_until(local_value("UI_PAGES").frame_clock)
end

-- Run the clocks through init's start-up coroutine, which sleeps
-- STARTUP.voice_delay_seconds and then starts voice 2 (the frame clock
-- ticks meanwhile)
local function finish_startup(context)
  context.clock.run_for(STARTUP.voice_delay_seconds)
end

-- Run the clocks until the clock held in the script local `name` wakes once
-- (a pattern step, a scene transition step, ...)
local function wake(context, name)
  context.clock.advance_until(local_value(name))
end

-- Run the clocks until buffer slot's recording timer or fallback wakes once
local function wake_buffer_clock(context, slot)
  context.clock.advance_until(local_value("buffer_record_clocks")[slot])
end

-- Deep copy of plain data tables
local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, inner in pairs(value) do copy[key] = deep_copy(inner) end
  return copy
end

-- The text lib/tabutil.lua's tab.save writes for `value`: a data file as
-- norns writes it (tab.load reads only that layout)
local function tabutil_text(value)
  local path = os.tmpname()
  stubs.make_tab().save(value, path)
  local file = assert(io.open(path, "r")); local text = file:read("*a"); file:close()
  os.remove(path)
  return text
end

-- The maintained docs (paths from the repo root): CLAUDE.md, README.md,
-- docs/status.md and every docs/notes file. Their engine.<name>( mentions
-- must name commands the engine has, and the repo paths they name must
-- exist. CHANGELOG.md and docs/design/ are history: they describe a release
-- as it was, so they are not held to today's commands and files
local function maintained_docs()
  local docs = { "CLAUDE.md", "README.md", "docs/status.md" }
  local listing = io.popen('ls "' .. repo_root .. '/docs/notes" 2>/dev/null')
  for name in listing:read("*a"):gmatch("[^\n]+") do
    if name:match("%.md$") then table.insert(docs, "docs/notes/" .. name) end
  end
  listing:close()
  return docs
end

-- The script's Lua files: strata.lua first, then every lib/**/*.lua, as
-- { path = "strata.lua" | "lib/...", text = source }
local function read_lua_sources() return sync_check.lua_sources(repo_root) end

-- Load options running a copy of the script's Lua sources with `pattern`
-- replaced by `replacement` (string.gsub) in the one file that holds it:
-- { source = ... } for strata.lua, { module_sources = ... } for a module.
-- Returns them and the number of replacements (0 when no file matches)
local function patched_script(pattern, replacement)
  for _, source in ipairs(read_lua_sources()) do
    local patched, count = source.text:gsub(pattern, replacement)
    if count > 0 then
      if source.path == "strata.lua" then return { source = patched }, count end
      return { module_sources = { [source.path:gsub("%.lua$", "")] = patched } }, count
    end
  end
  return {}, 0
end

-- The repo paths a maintained doc's text names that do not exist, and the
-- number of paths it names: `docs/...`, `test/...`, `.github/...` and
-- `lib/...` in backticks, and relative Markdown link targets to a file,
-- such as [CHANGELOG.md](CHANGELOG.md) (not code such as
-- `PAGE_KEY[ui_page](n)`). A norns library is named by its path in the
-- norns repo (`lua/lib/lfo.lua`), which is not checked
local function doc_paths_missing(text)
  local paths = {}
  for path in text:gmatch("`([%w%._/%-]+)`") do
    if path:match("^docs/") or path:match("^test/") or path:match("^%.github/") or path:match("^lib/") then
      table.insert(paths, path)
    end
  end
  for target in text:gmatch("%]%(([%w%._/%-]+%.%a+)%)") do
    table.insert(paths, target)
  end
  local missing = {}
  for _, path in ipairs(paths) do
    local handle = io.open(repo_root .. "/" .. path, "r")
    if handle then handle:close() else table.insert(missing, path) end
  end
  return missing, #paths
end

-- Compare a voice's live state with a captured scene voice, allowing for
-- each param's controlspec quantization
local function assert_voice_matches(voice_idx, voice, captured)
  local prefix = "voice " .. voice_idx .. " "
  for key, value in pairs(captured.params) do
    local spec = params:lookup_param("v" .. voice_idx .. "_" .. key).controlspec
    assert_near(voice.params[key], value, spec.step + 1e-6, prefix .. key)
  end
  for key, value in pairs(captured.grain) do
    assert_near(voice.grain[key], value, 0.011, prefix .. "grain " .. key)
  end
  for slot = 1, 3 do
    local live, saved = voice.crossmod["slot" .. slot], captured.crossmod["slot" .. slot]
    assert_equal(live.source, saved.source, prefix .. "slot " .. slot .. " source")
    assert_near(live.amp_amt, saved.amp_amt, 0.011, prefix .. "slot " .. slot .. " amp")
    assert_near(live.freq_amt, saved.freq_amt, 0.011, prefix .. "slot " .. slot .. " freq")
  end
  assert_near(voice.crossmod.speed, captured.crossmod.speed, 0.11, prefix .. "mod speed")
  assert_equal(voice.source, captured.source, prefix .. "source")
  assert_equal(voice.active, captured.active, prefix .. "active")
end

-- Put every voice into a distinctive, non-default state through params
local function scramble_state(seed)
  math.randomseed(seed)
  for voice_idx = 1, 7 do
    -- source first: randomize_voice then picks buffer or synth params
    params:set("v" .. voice_idx .. "_source", math.random(1, 10))
    randomize_voice(voice_idx)
    params:set("v" .. voice_idx .. "_buf_pos", math.random())
    params:set("v" .. voice_idx .. "_buf_rate", 0.25 + math.random() * 3.75)
    params:set("v" .. voice_idx .. "_buf_scan", math.random() * 4 - 2)
    params:set("v" .. voice_idx .. "_grain_spread", math.random())
    params:set("v" .. voice_idx .. "_grain_density", math.random(1, 100))
    params:set("v" .. voice_idx .. "_grain_env", math.random(1, 5))
    params:set("v" .. voice_idx .. "_grain_mode", math.random(1, 2))
    for slot = 1, 3 do
      params:set("v" .. voice_idx .. "_mod_source_" .. slot, math.random(0, 7))
      params:set("v" .. voice_idx .. "_mod_amp_amt_" .. slot, math.random() * 4 - 2)
      params:set("v" .. voice_idx .. "_mod_freq_amt_" .. slot, math.random() * 4 - 2)
    end
    params:set("v" .. voice_idx .. "_mod_speed", math.random() * 40 + 0.5)
  end
end

---------------------------------------------------------------------------
-- tests
---------------------------------------------------------------------------

test("strata.lua loads and init() runs", function()
  local context = load_strata()
  assert_true(#context.engine_calls > 0, "init should talk to the engine")
end)

test("each load gets its own data directory, even after the same random seed (#50)", function()
  math.randomseed(1); local first = load_strata()
  math.randomseed(1); local second = load_strata()
  assert_true(first.data_dir ~= second.data_dir, "two loads share " .. first.data_dir)
end)

test("Lua engine calls and SC addCommand signatures are in sync (sync_check)", function()
  local ok, problems, summary = sync_check.run(repo_root)
  assert_true(ok, summary .. "\n" .. table.concat(problems, "\n"))
  -- the scanner itself: nested calls, strings and comments
  local calls = sync_check.lua_calls('engine.foo(a, f(b, c), "x,y)", {1, 2}) -- engine.bar(1)\nengine.baz()')
  assert_equal(#calls, 2, "comment ignored")
  assert_equal(calls[1].arg_count, 4, "nested commas ignored")
  assert_equal(calls[2].arg_count, 0, "empty call")
end)

test("sync_check fails on engine uses it cannot check: engine[...], references, the table as a value (#27)", function()
  local sample = table.concat({
    'local f = engine.voiceOn',          -- 1: a command passed by value
    'engine["voiceOff"](0)',             -- 2: a computed name
    'local e = engine',                  -- 3: the table itself
    'engine:voiceOff(0)',                -- 4: a method call
    'engine.loadBuffer "x.wav"',         -- 5: a call without parentheses
    'engine.name = "Strata"',            -- allowed: the engine to load
    'x = context.engine; s = "a" .. engine.name',  -- a field of another table; engine.name read
    'engine . retrigger (0, 1)',         -- a call, spaces and all
    'local engine_senders = {} -- engine.bad', 'y = "engine.bad"',
  }, "\n")
  local problems = sync_check.lua_reference_problems(sample)
  local lines = {}
  for _, entry in ipairs(problems) do table.insert(lines, entry.line) end
  assert_equal(table.concat(lines, " "), "1 2 3 4 5", "each unchecked use is reported, nothing else")
  assert_true(problems[1].text:find("engine.voiceOn", 1, true), "the report names the command")
  local calls = sync_check.lua_calls(sample)
  assert_equal(#calls, 1, "only engine.<name>(...) is a call")
  assert_equal(calls[1].name, "retrigger"); assert_equal(calls[1].arg_count, 2, "a spaced call is counted")
  -- the whole check fails when one of the script's files holds one
  local lua_sources = read_lua_sources()
  local file = assert(io.open(SC_PATH, "r")); local sc_source = file:read("*a"); file:close()
  assert_true((sync_check.check_sources(lua_sources, sc_source)), "the script's files pass as they are")
  for _, patch in ipairs({ "local f = engine.voiceOn", 'engine["voiceOff"](0)', "local e = engine" }) do
    local patched = {}
    for index, source in ipairs(lua_sources) do
      patched[index] = { path = source.path, text = source.text .. (index == 1 and "\n" .. patch .. "\n" or "") }
    end
    local ok, found = sync_check.check_sources(patched, sc_source)
    assert_true(not ok, "the check fails on: " .. patch)
    assert_true(found[#found]:find("strata.lua:%d+ "), "with the line: " .. tostring(found[#found]))
  end
end)

test("sync_check accepts a table key or parameter named engine and #engine (#51)", function()
  local allowed = table.concat({
    'local t = { engine = 1 }',
    'local u = { a = 1, engine = { 2 }; [3] = 4 }',
    'local v = {',
    '  engine = "Strata",',
    '}',
    'local function f(engine) return 1 end',
    'local g = function(x, engine, ...) end',
    'function obj:method(a,engine) end',
    'local n = #engine',
  }, "\n")
  local problems = sync_check.lua_reference_problems(allowed)
  local reported = {}
  for _, entry in ipairs(problems) do table.insert(reported, entry.line .. ": " .. entry.text) end
  assert_equal(#problems, 0, "nothing to report, got:\n" .. table.concat(reported, "\n"))
  -- the global engine still fails in the same places
  local flagged = table.concat({
    'local t = { engine }',              -- 1: the table as a list item
    'f(engine)',                         -- 2: as an argument
    'local w = { k = engine }',          -- 3: as a key's value
    'if { engine == 1 } then end',       -- 4: compared, not a key
    'local e = (engine)',                -- 5: in parentheses
    'g(function() end, engine)',         -- 6: an argument after a function
    'functions.apply(engine)',           -- 7: calls whose names start with "function"
    'function_call(a, engine)',          -- 8
    'local x = functional(engine)',      -- 9
  }, "\n")
  local lines = {}
  for _, entry in ipairs(sync_check.lua_reference_problems(flagged)) do table.insert(lines, entry.line) end
  assert_equal(table.concat(lines, " "), "1 2 3 4 5 6 7 8 9", "each use of the table as a value is reported")
end)

test("sync check reports a bad engine call in a module file", function()
  local file = assert(io.open(SC_PATH, "r")); local sc_source = file:read("*a"); file:close()
  local function problems_of(sources)
    local ok, problems = sync_check.check_sources(sources, sc_source)
    return ok, table.concat(problems, "\n")
  end
  local ok, report = problems_of({ { path = "strata.lua", text = "" }, { path = "lib/x.lua", text = "engine.nope(1)" } })
  assert_true(not ok, "an unknown command in a module fails the check")
  assert_true(report:find("lib/x.lua:1 engine.nope", 1, true), "the report names the module and line:\n" .. report)
  ok, report = problems_of({ { path = "strata.lua", text = "" }, { path = "lib/x.lua", text = "\n\nengine.voiceOff(1, 2)\nlocal e = engine" } })
  assert_true(report:find("lib/x.lua:3 engine.voiceOff passes 2 args", 1, true), "a wrong argument count:\n" .. report)
  assert_true(report:find("lib/x.lua:4 the engine table", 1, true), "an unchecked use:\n" .. report)
  -- every command is called somewhere: a call in any file counts
  local sources = read_lua_sources()
  assert_equal(sources[1].path, "strata.lua", "strata.lua comes first")
  local moved = { { path = "strata.lua", text = "" } }
  for _, source in ipairs(sources) do table.insert(moved, { path = "lib/moved_" .. #moved .. ".lua", text = source.text }) end
  ok, report = problems_of(moved)
  assert_true(ok, "the calls moved into modules still cover every command:\n" .. report)
  ok, report = problems_of({ { path = "strata.lua", text = "" } })
  assert_true(not ok and report:find("is never called", 1, true), "a command no file calls is reported")
  -- the single-source entry point reports its source as strata.lua
  local _, single = sync_check.check("\nengine.nope(1)", sc_source)
  assert_equal(single[1], "strata.lua:2 engine.nope has no addCommand in the engine", "check() reads one source")
end)

-- Every include(...) call in the script's Lua files: problems found (a call
-- outside strata.lua, a path not under lib/ or not a string literal, a path
-- included twice) and the paths included
local function include_problems(sources)
  local problems, included, seen = {}, {}, {}
  for _, source in ipairs(sources) do
    local sanitized = sync_check.sanitize_lua(source.text)
    assert_equal(#sanitized, #source.text, source.path .. " keeps its length when sanitized")
    for start in sanitized:gmatch("()%f[%w_]include%s*%(") do
      local before = sanitized:sub(1, start - 1)
      if not before:match("function%s+$") and not before:match("[%.:]%s*$") then
        local where = source.path .. ":" .. select(2, before:gsub("\n", "")) + 1
        local path = source.text:match('^include%s*%(%s*"([^"]*)"%s*%)', start)
        if source.path ~= "strata.lua" then table.insert(problems, where .. " includes outside strata.lua") end
        if not path then
          table.insert(problems, where .. " includes a path that is not a string literal")
        elseif not path:match("^lib/") then
          table.insert(problems, where .. " includes " .. path .. ", not a lib/ path")
        elseif seen[path] then
          table.insert(problems, where .. " includes " .. path .. " again")
        end
        if path then seen[path] = true; table.insert(included, path) end
      end
    end
  end
  return problems, included
end

test("only strata.lua includes, once per module, by lib/ paths", function()
  local problems, included = include_problems(read_lua_sources())
  assert_equal(#problems, 0, table.concat(problems, "; "))
  assert_equal(included[1], "lib/state", "strata.lua includes lib/state first")
  -- the scanner itself
  problems = include_problems({
    { path = "strata.lua", text = '-- include("lib/comment")\nlocal s = "include(\\"lib/string\\")"\ninclude("lib/a")\n'
      .. 'include("strata/lib/b")\ninclude("lib/a")\ninclude(name)\nfunction include(x) end\nx.include("y")' },
    { path = "lib/a.lua", text = 'local m = include("lib/c")' },
  })
  assert_equal(table.concat(problems, "; "), "strata.lua:4 includes strata/lib/b, not a lib/ path; "
    .. "strata.lua:5 includes lib/a again; strata.lua:6 includes a path that is not a string literal; "
    .. "lib/a.lua:1 includes outside strata.lua", "each bad include is reported, comments and strings are not")
end)

test("include stub loads lib modules and honors overrides", function()
  local function install(module_sources)
    return stubs.install { signatures = signatures, engine_polls = engine_polls, engine_spec = engine_spec,
      data_dir = data_root .. "include_stub/", quiet = true, module_sources = module_sources }
  end
  install()
  local constructor = include("lib/state")
  assert_equal(type(constructor), "function", "lib/state returns a constructor")
  assert_true(debug.getinfo(constructor, "S").source:sub(-#"lib/state.lua") == "lib/state.lua",
    "the module's functions are defined in lib/state.lua")
  assert_true(constructor() ~= constructor(), "each call builds a new table")
  local ok, message = pcall(include, "lib/missing")
  assert_true(not ok and tostring(message):find("MISSING INCLUDE: lib/missing", 1, true), "a missing file is an error: " .. tostring(message))
  install({ ["lib/state"] = "return function() return { marker = 1 } end" })
  constructor = include("lib/state")
  assert_equal(constructor().marker, 1, "an override replaces the file")
  assert_true(debug.getinfo(constructor, "S").source:sub(-#"lib/state.lua") == "lib/state.lua",
    "an override keeps the file's chunk name")
  install()
  assert_equal(include("lib/state")().marker, nil, "overrides last one install")
  -- load_strata passes them through
  load_strata { module_sources = { ["lib/state"] =
    "return function() return { marker = 2, registry = { pages = {}, params = {}, cleanup = {}, grid_layouts = {} } } end" } }
  assert_equal(local_value("S").marker, 2, "load_strata's module_sources reach include")
end)

test("S is init's upvalue and holds the registries", function()
  load_strata()
  local upvalue
  for index = 1, math.huge do
    local name, value = debug.getupvalue(init, index)
    if not name then break end
    if name == "S" then upvalue = value end
  end
  assert_equal(type(upvalue), "table", "init's upvalue S")
  local S = local_value("S")
  assert_equal(S, upvalue, "local_value finds S")
  for _, registry in ipairs({ "pages", "params", "cleanup", "grid_layouts" }) do
    assert_equal(type(S.registry[registry]), "table", "S.registry." .. registry)
  end
  -- lookups look in S, then S.constants, then the upvalues; setters write where the name was found
  S.lookup_probe = 1; S.constants = { constant_probe = 2 }; S.NUM_VOICES = 99
  assert_equal(local_value("lookup_probe"), 1, "a field of S")
  assert_equal(local_value("constant_probe"), 2, "a field of S.constants")
  assert_equal(local_value("NUM_VOICES"), 99, "S before the upvalues")
  S.NUM_VOICES = nil; S.__declared.NUM_VOICES = nil  -- a name S never declared
  assert_equal(local_value("NUM_VOICES"), 7, "the upvalues last")
  local _, set_field = find_upvalue("lookup_probe"); set_field(3)
  local _, set_constant = find_upvalue("constant_probe"); set_constant(4)
  assert_equal(S.lookup_probe, 3, "the setter writes into S")
  assert_equal(S.constants.constant_probe, 4, "the setter writes into S.constants")
  assert_equal(S.constant_probe, nil, "and not into S")
  S.lookup_probe = nil; S.constants = nil
end)

test("a field of S assigned nil stays reachable by name", function()
  load_strata()
  local S = local_value("S")
  assert_true(S.__declared.registry, "the registries are a declared key")
  S.some_clock = nil  -- as a module declares a clock that is not running
  assert_true(S.__declared.some_clock, "the nil assignment is recorded")
  local ok, value = pcall(local_value, "some_clock")
  assert_true(ok, "a declared nil field is found: " .. tostring(value))
  assert_equal(value, nil, "its value is nil")
  local _, set_field = find_upvalue("some_clock"); set_field(7)
  assert_equal(rawget(S, "some_clock"), 7, "the setter writes into S")
  S.some_clock = nil
  assert_equal(local_value("some_clock"), nil, "set back to nil, still found")
  assert_true(not pcall(local_value, "never_declared_name"), "a name never assigned is still not found")
end)

test("a reload builds a fresh S that shares no tables", function()
  load_strata(); local first = local_value("S")
  load_strata(); local second = local_value("S")
  assert_true(first ~= second, "a reload builds a new S")
  local function tables_in(root)
    local found, pending = {}, { root }
    while #pending > 0 do
      local value = table.remove(pending)
      if not found[value] then
        found[value] = true
        for key, inner in pairs(value) do
          if type(key) == "table" then table.insert(pending, key) end
          if type(inner) == "table" then table.insert(pending, inner) end
        end
      end
    end
    return found
  end
  local in_second = tables_in(second)
  for key, value in pairs(first) do
    if type(value) == "table" then assert_true(second[key] ~= value, "S." .. tostring(key) .. " is shared") end
  end
  for value in pairs(tables_in(first)) do
    assert_true(not in_second[value], "the two loads share a table")
  end
  for name in pairs(package.loaded) do
    assert_true(not tostring(name):match("^lib[/.]"), "a module is cached in package.loaded: " .. tostring(name))
  end
end)

-- Module path -> the global functions defined there. Later moves add a
-- module's entry before moving its functions
local MODULE_HOMES = {}

test("functions live in their module", function()
  load_strata()
  for path, names in pairs(MODULE_HOMES) do
    for _, name in ipairs(names) do
      local value = rawget(_G, name)
      assert_equal(type(value), "function", name .. " is a global function")
      local source = debug.getinfo(value, "S").source
      assert_true(source:sub(-#path) == path, name .. " is defined in " .. path .. ", not " .. source)
    end
  end
end)

test("constants live in lib/constants.lua, a plain table", function()
  load_strata()
  local constants = local_value("S").constants
  assert_equal(type(constants), "table", "S.constants is a table")
  assert_equal(constants.NUM_VOICES, 7, "S.constants.NUM_VOICES")
  assert_equal(constants.UI_PAGES[1], "MAIN", "S.constants.UI_PAGES")
  local chunk = assert(loadfile(repo_root .. "/lib/constants.lua"))
  assert_equal(type(chunk()), "table", "lib/constants.lua returns a plain table, not a constructor")
end)

---------------------------------------------------------------------------
-- Refactor safety nets (Wave 0): a golden-master log of one scripted
-- session, a static check that every global read is defined, and a probe
-- of each file's free locals. They prove that a move into lib/ changed
-- nothing
---------------------------------------------------------------------------

local GOLDEN_BASELINE_PATH = repo_root .. "/test/fixtures/wave0_baseline.txt"

-- A number as the golden log writes it, the same under Lua 5.3 and LuaJIT
-- (5.3 writes an integral float as "2.0"): whole numbers as integers, the
-- rest with 12 significant digits (libm may differ in the last bits)
local function golden_number(value)
  if value ~= value then return "nan" end
  if value == math.huge then return "inf" end
  if value == -math.huge then return "-inf" end
  if value == math.floor(value) and math.abs(value) < 2 ^ 53 then return string.format("%d", value) end
  return string.format("%.12g", value)
end

-- A string in quotes, with quotes, backslashes and control characters as
-- decimal escapes (%q differs between Lua 5.3 and LuaJIT)
local function golden_string(text)
  return '"' .. text:gsub('[%c"\\]', function(char) return "\\" .. char:byte() end) .. '"'
end

local function golden_scalar(value)
  if type(value) == "number" then return golden_number(value) end
  if type(value) == "string" then return golden_string(value) end
  if type(value) == "table" or type(value) == "function" then return "<" .. type(value) .. ">" end
  return tostring(value)
end

-- pairs' order depends on string hashes, which Lua 5.3 seeds per run, and
-- differs between Lua 5.3 and LuaJIT. The golden session runs with keys in
-- sorted order instead: numbers, then strings, then booleans. A key of
-- another type has no stable order: on_unordered is told
local KEY_RANK = { number = 1, string = 2, boolean = 3 }
local function key_before(left, right)
  local left_rank, right_rank = KEY_RANK[type(left)] or 4, KEY_RANK[type(right)] or 4
  if left_rank ~= right_rank then return left_rank < right_rank end
  if left_rank == 3 then return (not left) and right end
  if left_rank == 4 then return tostring(left) < tostring(right) end
  return left < right
end

local function make_sorted_pairs(on_unordered)
  return function(target)
    local keys = {}
    local key = next(target)
    while key ~= nil do
      if not KEY_RANK[type(key)] then on_unordered(key) end
      keys[#keys + 1] = key
      key = next(target, key)
    end
    table.sort(keys, key_before)
    local index = 0
    return function()
      repeat
        index = index + 1
        local current = keys[index]
        if current == nil then return nil end
        local value = rawget(target, current)
        if value ~= nil then return current, value end
      until false
    end, target, nil
  end
end

-- math.random differs between Lua 5.3 and LuaJIT even after the same
-- seed. The golden session draws from the Park-Miller generator instead
-- (exact in integers and in doubles), with Lua 5.3's argument forms
local function make_portable_random()
  local state = 1
  local function random(low, high)
    state = (state * 16807) % 2147483647
    local fraction = (state - 1) / 2147483646
    if low == nil then return fraction end
    if high == nil then low, high = 1, low end
    return low + math.floor(fraction * (high - low + 1))
  end
  local function randomseed(seed) state = math.floor(seed or 0) % 2147483646 + 1 end
  return random, randomseed
end

-- Run fn with sorted pairs and the portable generator seeded with 1, then
-- put the real ones back. Returns fn's result and the number of keys
-- without a stable order that pairs met
local function with_deterministic_runtime(fn)
  local real_pairs, real_random, real_randomseed = pairs, math.random, math.randomseed
  local unordered = 0
  pairs = make_sorted_pairs(function() unordered = unordered + 1 end)
  math.random, math.randomseed = make_portable_random()
  math.randomseed(1)
  local ok, result = xpcall(fn, debug.traceback)
  pairs, math.random, math.randomseed = real_pairs, real_random, real_randomseed
  if not ok then error(result, 0) end
  return result, unordered
end

-- Every leaf of a value as "<prefix>.<key path> = <value>" lines, keys in
-- sorted order (a scene or buffers file, loaded back with tab.load; the
-- log writes "file <path>: <key path> = <value>")
local function golden_flatten(prefix, value, lines, seen)
  seen = seen or {}
  if type(value) ~= "table" then
    table.insert(lines, prefix .. " = " .. golden_scalar(value))
    return lines
  end
  if seen[value] then
    table.insert(lines, prefix .. " = <repeated table>")
    return lines
  end
  seen[value] = true
  local keys = {}
  for key in next, value do table.insert(keys, key) end
  table.sort(keys, key_before)
  if #keys == 0 then table.insert(lines, prefix .. " = {}") end
  for _, key in ipairs(keys) do
    local name = type(key) == "string" and key or ("[" .. golden_scalar(key) .. "]")
    golden_flatten(prefix .. "." .. name, value[key], lines, seen)
  end
  seen[value] = nil
  return lines
end

-- One LED level as a hex digit (a level that is not a whole 0..15 in
-- parentheses)
local function golden_level(level)
  if type(level) == "number" and level >= 0 and level <= 15 and level == math.floor(level) then
    return string.format("%x", level)
  end
  return "(" .. golden_scalar(level) .. ")"
end

-- One grid of each layout, on its own port (they stay plugged to the end,
-- so cleanup darkens all four)
local GOLDEN_GRIDS = {
  { name = "256", cols = 16, rows = 16 },
  { name = "128h", cols = 16, rows = 8 },
  { name = "128v", cols = 8, rows = 16 },
  { name = "64", cols = 8, rows = 8 },
}

-- The scripted Wave 0 session on a script loaded with skip_init: init,
-- the startup clock, every page's draw and controls, voices, sources, a
-- recording, scenes, grids, arc, MIDI and cleanup. Returns the log: every
-- engine call, screen frame (texts, lines, rectangles), grid and arc LED
-- frame and file written under the data directory, in the order they
-- happened, under "## <step>" headings. Paths under the data directory read
-- "<data>/" and os.date stamps "<date>"
local function golden_session(context)
  local log = {}
  local data_dir = context.data_dir
  -- a sound file for the session's load (the stub engine never reads it),
  -- written before the file recorders start
  local load_path = context.audio_dir .. "golden.wav"
  local sound_file = assert(io.open(load_path, "w")); sound_file:write("RIFF"); sound_file:close()

  local function normalize(text)
    local start = 1
    local parts = {}
    while true do
      local found = text:find(data_dir, start, true)
      if not found then break end
      table.insert(parts, text:sub(start, found - 1)); table.insert(parts, "<data>/")
      start = found + #data_dir
    end
    table.insert(parts, text:sub(start))
    return (table.concat(parts):gsub("%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d", "<date>"))
  end
  local function emit(line) table.insert(log, normalize(line)) end

  local engine_logged = 0
  local function flush_engine()
    for index = engine_logged + 1, #context.engine_calls do
      local call = context.engine_calls[index]
      local args = {}
      for position = 1, #call.args do args[position] = golden_scalar(call.args[position]) end
      emit("engine." .. call.name .. "(" .. table.concat(args, ", ") .. ")")
    end
    engine_logged = #context.engine_calls
  end

  -- files: writes, renames and removals under the data directory are logged
  -- as they happen; a written file's contents follow at the next flush
  local real_open, real_rename, real_remove = io.open, os.rename, os.remove
  local pending_files = {}
  local function under_data(path) return type(path) == "string" and path:sub(1, #data_dir) == data_dir end
  local function flush_files()
    local paths = pending_files
    pending_files = {}
    for _, path in ipairs(paths) do
      local loaded_ok, loaded = pcall(context.tab.load, path)
      if loaded_ok and type(loaded) == "table" then
        for _, line in ipairs(golden_flatten("", loaded, {})) do emit("file " .. path .. ": " .. line:sub(2)) end
      else
        local handle = real_open(path, "r")
        if handle then
          local text = handle:read("*a"); handle:close()
          for line in (text .. "\n"):gmatch("([^\n]*)\n") do emit("file " .. path .. " | " .. line) end
        else
          emit("file " .. path .. " (gone)")
        end
      end
    end
  end
  io.open = function(path, mode, ...)
    if under_data(path) and mode and mode:find("[wa+]") then
      flush_engine()
      emit("file write " .. path .. " (" .. mode .. ")")
      table.insert(pending_files, path)
    end
    return real_open(path, mode, ...)
  end
  os.rename = function(from, to)
    if under_data(from) or under_data(to) then
      flush_engine(); emit("file rename " .. tostring(from) .. " -> " .. tostring(to))
    end
    return real_rename(from, to)
  end
  os.remove = function(path)
    if under_data(path) then flush_engine(); emit("file remove " .. path) end
    return real_remove(path)
  end

  -- screen: one frame per screen.update
  local screen, last_screen = context.screen, nil
  screen.update = function()
    flush_engine()
    local lines = {}
    for _, text in ipairs(screen.texts) do
      table.insert(lines, string.format("  text %s %s %s %s %s", golden_number(text.x), golden_number(text.y),
        text.align, golden_number(text.level), golden_string(text.text)))
    end
    for _, line in ipairs(screen.lines) do
      table.insert(lines, string.format("  line %s %s %s %s %s", golden_number(line.x1), golden_number(line.y1),
        golden_number(line.x2), golden_number(line.y2), golden_number(line.level)))
    end
    for _, rect in ipairs(screen.rects) do
      table.insert(lines, string.format("  rect %s %s %s %s %s", golden_number(rect.x), golden_number(rect.y),
        golden_number(rect.w), golden_number(rect.h), golden_number(rect.level)))
    end
    local frame = table.concat(lines, "\n")
    if frame == last_screen then
      emit("screen frame (unchanged)")
    else
      emit("screen frame"); if frame ~= "" then emit(frame) end
      last_screen = frame
    end
  end

  -- grid and arc: one frame per refresh of a plugged device
  local function record_refreshes(device, label, frame_of)
    local real_refresh, last_frame = device.refresh, nil
    device.refresh = function(self, ...)
      flush_engine()
      local frame = frame_of(self)
      if frame == last_frame then emit(label .. " frame (unchanged)") else emit(label .. " frame " .. frame) end
      last_frame = frame
      return real_refresh(self, ...)
    end
  end
  local function grid_frame(device)
    local rows = {}
    for y = 1, device.rows do
      local row = {}
      for x = 1, device.cols do row[x] = golden_level(device:get_led(x, y)) end
      rows[y] = table.concat(row)
    end
    return table.concat(rows, " ")
  end
  local function arc_frame(device)
    local rings = {}
    for ring = 1, 4 do
      local leds = {}
      for x = 1, 64 do leds[x] = golden_level(device:get_led(ring, x)) end
      rings[ring] = table.concat(leds)
    end
    return table.concat(rings, " ")
  end

  local function step(name, action)
    emit("## " .. name)
    action()
    flush_engine(); flush_files()
  end
  local function current_page() return local_value("ui_page") end

  local ok, problem = xpcall(function()
    step("init", function() init(); context.check_param_groups() end)
    step("startup clock", function() finish_startup(context); next_frame(context) end)

    -- every page: its draw, then E2/E3 both ways, K2 and K3, and E1 to the next
    local _, set_ui_page = find_upvalue("ui_page")
    for page = 1, #local_value("UI_PAGES") do
      step("page " .. page .. " draw", function() set_ui_page(page); redraw() end)
      step("page " .. page .. " controls", function()
        enc(2, 1); enc(2, -1); enc(3, 1); enc(3, -1)
        key(2, 1); key(2, 0); key(3, 1); key(3, 0)
        next_frame(context)
      end)
      step("page " .. page .. " E1", function() enc(1, 1); next_frame(context) end)
    end
    step("back to MAIN", function() enc(1, 1 - current_page()); next_frame(context) end)

    for voice_idx = 1, 7 do
      step("toggle voice " .. voice_idx, function() toggle_voice(voice_idx); next_frame(context) end)
    end
    step("voice 3 source buffer 1", function() params:set("v3_source", 2); next_frame(context) end)
    step("voice 4 source input", function() params:set("v4_source", 10); next_frame(context) end)

    step("record buffer 1", function()
      record_buffer(1); next_frame(context)
      context.polls.fire("bufferState", 0)        -- slot 1 recording: 0 s
      wake_buffer_clock(context, 1)
      context.polls.fire("bufferState", params:get("record_duration"))  -- the take
      context.clock.run_for(1.5)
      context.polls.fire("bufferState", params:get("record_duration"))
      next_frame(context)
      -- the BUFFER page shows the take
      enc(1, 3); next_frame(context); enc(1, -3); next_frame(context)
    end)
    step("load buffer 2", function()
      load_buffer(2, load_path); next_frame(context)
      context.polls.fire("bufferState", 1 * 100 + 3.5)  -- slot 2 (index 1) holds 3.5 s
      context.clock.run_for(1.5)
      context.polls.fire("bufferState", 1 * 100 + 3.5)
      next_frame(context)
    end)
    step("failed load into buffer 3", function()
      load_buffer(3, context.audio_dir .. "missing.wav"); next_frame(context)
      -- the engine's report: (load number * 2 + emptied 0) * NUM_BUFFERS + slot index 2
      local load_number = local_value("buffers")[3].loads_sent
      context.polls.fire("bufferLoadFailed", (load_number * 2) * local_value("NUM_BUFFERS") + 2)
      next_frame(context)
      -- the BUFFER page shows both slots
      enc(1, 3); next_frame(context); enc(1, -3); next_frame(context)
    end)

    step("capture scene 1", function() capture_scene(1); next_frame(context) end)
    step("instant recall", function()
      params:set("filter_freq", 2000); toggle_voice(5)
      recall_scene(1, 0); next_frame(context)
    end)
    step("smooth recall", function()
      params:set("filter_freq", 500); toggle_voice(6)
      recall_scene(1, 2)
      for _ = 1, 1000 do
        if not local_value("scene_transition_clock") then break end
        wake(context, "scene_transition_clock")
      end
      assert_true(not local_value("scene_transition_clock"), "the transition ended")
      next_frame(context)
    end)

    -- grid keys on each layout: a diagonal and an anti-diagonal (every row
    -- and column), on each of the 256's four pages
    for port, size in ipairs(GOLDEN_GRIDS) do
      step("grid " .. size.name .. " plug", function()
        local device = context.grid.plug(port, size.cols, size.rows)
        record_refreshes(device, "grid" .. port, grid_frame)
        grid_redraw()
      end)
      local pages = size.name == "256" and { 1, 2, 3, 4 } or { 1 }
      for _, grid_page in ipairs(pages) do
        step("grid " .. size.name .. " keys, page " .. grid_page, function()
          if size.name == "256" then
            context.grid.press(port, 12 + grid_page, 8, 1); context.grid.press(port, 12 + grid_page, 8, 0)
          end
          for index = 1, math.max(size.cols, size.rows) do
            for _, x in ipairs({ (index - 1) % size.cols + 1, size.cols - (index - 1) % size.cols }) do
              local y = (index - 1) % size.rows + 1
              context.grid.press(port, x, y, 1); context.grid.press(port, x, y, 0)
              next_frame(context)
            end
          end
        end)
      end
    end

    step("arc plug", function()
      local device = context.arc.plug(1)
      record_refreshes(device, "arc", arc_frame)
      next_frame(context)
    end)
    for page = 1, #local_value("UI_PAGES") do
      step("arc page " .. page, function()
        enc(1, page - current_page()); next_frame(context)
        for ring = 1, 4 do
          context.arc.turn(1, ring, 20); context.arc.turn(1, ring, -7)
          next_frame(context)
        end
        context.arc.push(1, 1, 1); context.arc.push(1, 1, 0); next_frame(context)
      end)
    end

    step("midi plug", function() context.midi.plug(1, "keys"); next_frame(context) end)
    step("midi notes", function()
      local notes = { { ch = 1, note = 60, vel = 100 }, { ch = 3, note = 64, vel = 80 }, { ch = 7, note = 67, vel = 40 } }
      for _, note in ipairs(notes) do
        context.midi.send(1, { type = "note_on", ch = note.ch, note = note.note, vel = note.vel })
        next_frame(context)
        context.midi.send(1, { type = "note_off", ch = note.ch, note = note.note, vel = 0 })
        next_frame(context)
      end
    end)
    step("midi bend", function()
      context.midi.send(1, { type = "pitchbend", ch = 3, val = 12000 }); next_frame(context)
    end)

    step("cleanup", function() cleanup() end)
    -- cleanup detached the handlers: input that arrives later reaches no
    -- engine command
    step("input after cleanup", function()
      context.midi.send(1, { type = "note_on", ch = 1, note = 62, vel = 90 })
      context.midi.send(1, { type = "note_off", ch = 1, note = 62, vel = 0 })
      context.grid.press(1, 1, 1, 1); context.grid.press(1, 1, 1, 0)
      context.arc.turn(1, 1, 10)
      context.clock.run_for(1)
    end)
  end, debug.traceback)
  io.open, os.rename, os.remove = real_open, real_rename, real_remove
  if not ok then error(problem, 0) end
  return table.concat(log, "\n") .. "\n"
end

-- The first line where two logs differ, with the step it falls in (nil
-- when they are equal)
local function first_difference(expected, actual)
  local function lines_of(text)
    local lines = {}
    for line in text:gmatch("([^\n]*)\n") do table.insert(lines, line) end
    return lines
  end
  local expected_lines, actual_lines = lines_of(expected), lines_of(actual)
  local section = "(before the first step)"
  for index = 1, math.max(#expected_lines, #actual_lines) do
    local want, got = expected_lines[index], actual_lines[index]
    if want ~= got then
      return string.format("line %d, in step %s:\n  baseline: %s\n  session:  %s", index, section,
        tostring(want or "(end of baseline)"), tostring(got or "(end of session)"))
    end
    if want:sub(1, 3) == "## " then section = want:sub(4) end
  end
  return nil
end

test("golden master: the session matches the Wave 0 baseline", function()
  local log, unordered = with_deterministic_runtime(function()
    return golden_session(load_strata { skip_init = true, data_subdir = "golden" })
  end)
  assert_equal(unordered, 0, "pairs met keys without a stable order (tables or functions as keys)")
  local output_path = os.getenv("STRATA_GOLDEN_OUT")
  if output_path and output_path ~= "" then
    local out = assert(io.open(output_path, "w")); out:write(log); out:close()
  end
  local file = io.open(GOLDEN_BASELINE_PATH, "r")
  if not file then
    os.execute("mkdir -p '" .. repo_root .. "/test/fixtures'")
    local out = assert(io.open(GOLDEN_BASELINE_PATH, "w")); out:write(log); out:close()
    fail("baseline written; rerun")
  end
  local expected = file:read("*a"); file:close()
  if expected ~= log then
    fail("the session differs from test/fixtures/wave0_baseline.txt at " .. tostring(first_difference(expected, log))
      .. "\n  (STRATA_GOLDEN_OUT=<path> writes the session's log there; never edit the baseline to pass a move)")
  end
end)

test("the golden log normalizes what varies between runs and interpreters", function()
  assert_equal(golden_number(2.0), "2"); assert_equal(golden_number(0.1 + 0.2), "0.3")
  assert_equal(golden_number(-3), "-3"); assert_equal(golden_number(1 / 3), "0.333333333333")
  assert_equal(golden_string('a"b\n'), '"a\\34b\\10"')
  local order = {}
  local _, unordered = with_deterministic_runtime(function()
    for key in pairs({ b = 1, [2] = 1, a = 1, [1] = 1, [true] = 1, [false] = 1 }) do table.insert(order, tostring(key)) end
    for _ in pairs({ [{}] = 1 }) do end
    local first = { math.random(), math.random(1, 10), math.random(5) }
    math.randomseed(1)
    assert_equal(math.random(), first[1], "reseeding repeats the sequence")
    assert_true(first[1] >= 0 and first[1] < 1); assert_true(first[2] >= 1 and first[2] <= 10)
    assert_true(first[3] >= 1 and first[3] <= 5 and first[3] == math.floor(first[3]))
  end)
  assert_equal(table.concat(order, " "), "1 2 a b false true", "sorted pairs")
  assert_equal(unordered, 1, "a table key is reported")
  assert_true(not pcall(with_deterministic_runtime, function() error("x") end), "errors pass through")
  assert_true(pairs ~= nil and math.random ~= nil, "the real pairs and math.random are back")
  local lines = golden_flatten("f", { b = { 1, 2 }, a = "x" }, {})
  assert_equal(table.concat(lines, "; "), 'f.a = "x"; f.b.[1] = 1; f.b.[2] = 2')
  assert_equal(first_difference("a\nb\n", "a\nb\n"), nil, "equal logs")
  assert_true(first_difference("## s\na\n", "## s\nc\n"):find("line 2, in step s", 1, true), "the line and step")
end)

-- The global-reference check runs under Lua 5.3, norns' Lua, and is
-- skipped only under another interpreter (LuaJIT has no luac)
local GLOBAL_CHECK_RUNS = _VERSION == "Lua 5.3" and not rawget(_G, "jit")

-- Lua 5.3's luac for the global-reference check: `luac`, or Debian's
-- `luac5.3` (CI installs the lua5.3 package), when it reports 5.3; nil
-- when there is none (the check then fails) or under another interpreter
local function luac_53_command()
  if not GLOBAL_CHECK_RUNS then return nil end
  for _, command in ipairs({ "luac", "luac5.3" }) do
    local pipe = io.popen(command .. " -v 2>&1")
    if pipe then
      local version = pipe:read("*a"); pipe:close()
      if version:find("Lua 5%.3") then return command end
    end
  end
  return nil
end
local LUAC = luac_53_command()

-- The globals a file's bytecode reads (GETTABUP on _ENV) and writes
-- (SETTABUP on _ENV), from `luac -l -l -p`, as name -> "<path>:<line>" of
-- the first. A key in the first 256 constants names the global in the
-- instruction's comment (`; _ENV "name"`); a constant index above 255
-- cannot be an operand, so the key is a register, loaded before by
-- `LOADK <reg> ... ; "name"`. Keys found neither way are returned as
-- unresolved. `label` names the file in the result
local function global_accesses(file_path, label)
  local pipe = assert(io.popen(LUAC .. " -l -l -p '" .. file_path .. "' 2>&1"))
  local listing = pipe:read("*a"); pipe:close()
  local reads, writes, unresolved = {}, {}, {}
  -- opcodes that write no register A (the rest clear what LOADK put there)
  local keeps_register = { SETTABUP = true, SETTABLE = true, SETUPVAL = true, SETLIST = true, EQ = true,
    LT = true, LE = true, TEST = true, JMP = true, RETURN = true }
  local loaded = {}  -- register -> the string constant LOADK put there, in the function being read
  local listed = 0
  for line in listing:gmatch("[^\n]+") do
    if line:match("^main <") or line:match("^function <") then
      loaded = {}
    else
      local source_line, opcode, rest = line:match("^%s*%d+%s+%[(%-?%d+)%]%s+(%u+)(.*)$")
      local operands, comment = (rest or ""):match("^([^;]*);%s*(.-)%s*$")
      if not operands then operands, comment = rest, "" end
      if opcode then
        listed = listed + 1
        local numbers = {}
        for number in operands:gmatch("%-?%d+") do table.insert(numbers, tonumber(number)) end
        local where = label .. ":" .. source_line
        if opcode == "LOADK" then
          loaded[numbers[1]] = comment:match('^"(.*)"$')
        elseif (opcode == "GETTABUP" or opcode == "SETTABUP") and comment:match("^_ENV") then
          local key_operand = opcode == "GETTABUP" and numbers[3] or numbers[2]
          local name
          if key_operand < 0 then name = comment:match('^_ENV "([^"]*)"') else name = loaded[key_operand] end
          if not name then
            table.insert(unresolved, where .. " " .. opcode)
          else
            local into = opcode == "GETTABUP" and reads or writes
            into[name] = into[name] or where
          end
          if opcode == "GETTABUP" then loaded[numbers[1]] = nil end
        elseif not keeps_register[opcode] and numbers[1] then
          loaded[numbers[1]] = nil
        end
      end
    end
  end
  assert(listed > 0, "luac listed no instructions for " .. label .. ":\n" .. listing)
  return reads, writes, unresolved
end

-- The globals norns (as stubbed) and the Lua standard library provide: the
-- keys of _G right after stubs.install, with every global a script load
-- left behind cleared first (and put back after)
local function stub_global_names()
  local left_over = {}
  for name, value in next, _G do
    if not harness_globals[name] then left_over[name] = value end
  end
  for name in next, left_over do _G[name] = nil end
  stubs.install { signatures = signatures, engine_polls = engine_polls, engine_spec = engine_spec,
    data_dir = data_root .. "stub_globals/", quiet = true }
  local names = {}
  for name in next, _G do names[name] = true end
  for name, value in next, left_over do
    if rawget(_G, name) == nil then rawset(_G, name, value) end
  end
  return names
end

-- Globals Strata reads that neither a script file nor norns defines, found
-- by the check below. Each one is a known bug with a GitHub issue; remove
-- its entry when the bug is fixed
local KNOWN_UNDEFINED_GLOBALS = {}

-- Every global read from a list of { path, text } files (path relative to
-- `root`) that no file writes and no stub provides, as
-- "<path>:<line> reads <name>"
local function undefined_global_reads(root, sources, provided)
  local all_reads, written, problems = {}, {}, {}
  for _, source in ipairs(sources) do
    local reads, writes, unresolved = global_accesses(root .. "/" .. source.path, source.path)
    for _, entry in ipairs(unresolved) do
      table.insert(problems, entry .. " uses a global whose name the listing does not show")
    end
    for name in next, writes do written[name] = true end
    table.insert(all_reads, reads)
  end
  for _, reads in ipairs(all_reads) do
    for name, where in next, reads do
      if not written[name] and not provided[name] and not KNOWN_UNDEFINED_GLOBALS[name] then
        table.insert(problems, where .. " reads " .. name)
      end
    end
  end
  table.sort(problems)
  return problems
end

test("every global read is defined", function()
  if not GLOBAL_CHECK_RUNS then
    real_print("     (skipped: the global-reference check runs under Lua 5.3 only; " .. _VERSION
      .. (rawget(_G, "jit") and ", LuaJIT" or "") .. " has no luac)")
    return
  end
  -- under Lua 5.3 a missing luac is a failure, never a skip: this check
  -- is what finds a bare name a module move left behind
  assert_true(LUAC, "the global-reference check needs Lua 5.3's luac on PATH (`luac` or `luac5.3`, reporting 5.3)")
  local provided = stub_global_names()
  local problems = undefined_global_reads(repo_root, read_lua_sources(), provided)
  assert_equal(#problems, 0, "undefined globals:\n  " .. table.concat(problems, "\n  "))
  -- the scanner: constant keys, register keys (past 255 constants), reads
  -- in nested functions, and writes in any file
  local scratch = data_root .. "global_check"
  os.execute("mkdir -p '" .. scratch .. "/lib'")
  local filler = {}
  for index = 1, 300 do filler[index] = string.format("%q", "k" .. index) end
  local files = {
    { path = "strata.lua", text = "defined_a = 1\nlocal t = { " .. table.concat(filler, ", ") .. " }\n"
      .. "function late() return defined_b, missing_late end\nlate_global = 2\nprint(missing_early)\n" },
    { path = "lib/x.lua", text = "defined_b = defined_a + late_global\nreturn missing_in_module\n" },
  }
  for _, source in ipairs(files) do
    local out = assert(io.open(scratch .. "/" .. source.path, "w")); out:write(source.text); out:close()
  end
  local found = undefined_global_reads(scratch, files, provided)
  local names = {}
  for _, entry in ipairs(found) do table.insert(names, entry:match("reads (.*)$") or entry) end
  table.sort(names)
  assert_equal(table.concat(names, " "), "missing_early missing_in_module missing_late",
    "each undefined read is found, defined ones are not:\n  " .. table.concat(found, "\n  "))
  -- in the main chunk, past its 300 constants, the keys are registers; the
  -- nested function late has its own constants, so its keys are constants
  local reads, writes = global_accesses(scratch .. "/strata.lua", "strata.lua")
  assert_true(reads.print and reads.missing_early, "reads with a register key are seen")
  assert_true(writes.late_global and writes.late, "writes with a register key are seen")
  assert_true(writes.defined_a, "a write with a constant key is seen")
  assert_true(reads.missing_late and reads.defined_b, "reads with a constant key in a nested function are seen")
end)

-- The number of locals that can still be declared at a point of a file:
-- insert(text, probe) puts `local p1, ..., pN` there, and the largest N
-- that still loads is the answer (nil and the error when the text does not
-- load with no probe)
local function free_locals(text, chunk_name, insert)
  local function loads(count)
    local names = {}
    for index = 1, count do names[index] = "p" .. index end
    local probe = count > 0 and ("local " .. table.concat(names, ", ") .. "\n") or ""
    local chunk, problem = load(insert(text, probe), chunk_name)
    return chunk ~= nil, problem
  end
  local ok, problem = loads(0)
  if not ok then return nil, problem end
  local low, high = 0, 256
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if loads(middle) then low = middle else high = middle - 1 end
  end
  return low
end

-- The probe at the end of a main chunk: before a module's final top-level
-- `return`, or after strata.lua's last line
local function probe_main_chunk(path)
  return function(text, probe)
    if path ~= "strata.lua" then
      local last
      for position in text:gmatch("()\nreturn[%s%(%{]") do last = position end
      if last then return text:sub(1, last) .. probe .. text:sub(last + 1) end
      if text:match("^return[%s%(%{]") then return probe .. text end
    end
    return text .. "\n" .. probe
  end
end

-- The probe at the end of a constructor (`return function(S) ... return M
-- end`): before its final `  return M\nend`. constructor_end is the
-- position of that line's newline, or nil for a file that ends otherwise
local CONSTRUCTOR_END = "\n  return M\nend"
local function constructor_end(text)
  local last, start = nil, 1
  while true do
    local found = text:find(CONSTRUCTOR_END, start, true)
    if not found then break end
    last, start = found, found + 1
  end
  if last and text:sub(last + #CONSTRUCTOR_END):match("^%s*$") then return last end
  return nil
end
local function probe_constructor(text, probe)
  local position = constructor_end(text)
  return text:sub(1, position) .. probe .. text:sub(position + 1)
end

-- strata.lua's main chunk keeps at least this many free locals until the
-- end of Wave 0 raises it to 30 (15 free once S was added; the margin is
-- for the module moves, which may add an alias before code moves out)
local STRATA_MIN_FREE_LOCALS = 14
local PLAIN_TABLE_MODULE = "lib/constants.lua"  -- the one module that is not a constructor
local MODULE_MIN_FREE_LOCALS = 30

test("each file keeps 30 free locals", function()
  local problems = {}
  local function check(label, free, problem, minimum)
    if not free then
      table.insert(problems, label .. " does not load with the probe: " .. tostring(problem))
    elseif free < minimum then
      table.insert(problems, string.format("%s has %d free locals, fewer than %d", label, free, minimum))
    end
  end
  for _, source in ipairs(read_lua_sources()) do
    local minimum = source.path == "strata.lua" and STRATA_MIN_FREE_LOCALS or MODULE_MIN_FREE_LOCALS
    local free, problem = free_locals(source.text, "@" .. source.path, probe_main_chunk(source.path))
    check(source.path .. "'s main chunk", free, problem, minimum)
    -- every module but the plain table lib/constants.lua is a constructor
    -- ending in `  return M\nend`, so none escapes the constructor probe
    if source.path ~= "strata.lua" and source.path ~= PLAIN_TABLE_MODULE then
      if constructor_end(source.text) then
        free, problem = free_locals(source.text, "@" .. source.path, probe_constructor)
        check(source.path .. "'s constructor", free, problem, minimum)
      else
        table.insert(problems, source.path .. " does not end in the constructor's `  return M\nend`")
      end
    end
  end
  assert_equal(#problems, 0, table.concat(problems, "\n"))
  -- the probe itself: 190 locals leave 10 free in a main chunk; a
  -- constructor also holds S and M
  local names = {}
  for index = 1, 190 do names[index] = "v" .. index end
  local declared = "local " .. table.concat(names, ", ")
  assert_equal(free_locals(declared .. "\n", "=probe", probe_main_chunk("strata.lua")), 10, "main chunk")
  local module_text = "local a\nreturn function(S)\n  local M = {}\n  " .. declared .. "\n  return M\nend\n"
  assert_equal(free_locals(module_text, "=probe", probe_constructor), 8, "constructor")
  assert_equal(free_locals(module_text, "=probe", probe_main_chunk("lib/x.lua")), 199, "module main chunk")
  assert_equal(constructor_end("return {}\n"), nil, "a plain table module has no constructor")
end)

test("the engine source parsers skip // and /* */ comments (#25)", function()
  local stripped = stubs.strip_sc_comments('a = "x // y /* z"; b = \'s//\'; c = $"; // gone\nd /* e /* f */ g */ h')
  assert_equal(stripped, 'a = "x // y /* z"; b = \'s//\'; c = $"; ' .. string.rep(" ", #"// gone")
    .. "\nd " .. string.rep(" ", #"/* e /* f */ g */") .. " h",
    "comments become spaces (newlines kept); strings, symbols and characters are not comments")
  local file = assert(io.open(SC_PATH, "r")); local source = file:read("*a"); file:close()
  -- the 3.0.1 review's mutation: \stopRecord wrapped in a block comment
  local start = assert(source:find("this.addCommand(\\stopRecord", 1, true), "stopRecord found")
  local finish = assert(source:find("this.addCommand(", start + 1, true), "next command found")
  local commented = source:sub(1, start - 1) .. "/* " .. source:sub(start, finish - 1) .. "*/ " .. source:sub(finish)
    .. '\n// this.addCommand(\\ghostLine, "i", { arg msg; });'
    .. '\n/* outer /* nested */ this.addCommand(\\ghostNested, "i", { arg msg; }); */'
    .. '\n// this.addPoll(\\ghostPoll, { 0 });'
  -- the engine stub's (which the CLAUDE.md table check uses) and sync_check's
  for parser_name, parse in pairs({ stub = stubs.engine_signatures_from_source, sync_check = sync_check.sc_commands }) do
    local commands = parse(commented)
    for _, name in ipairs({"stopRecord", "ghostLine", "ghostNested"}) do
      assert_true(commands[name] == nil, parser_name .. " skips the commented-out \\" .. name)
    end
    assert_equal(commands.clearBuffer, signatures.clearBuffer, parser_name .. " reads the command before it")
    assert_equal(commands.saveBuffer, signatures.saveBuffer, parser_name .. " reads the command after it")
  end
  assert_true(signatures.stopRecord ~= nil, "the real engine has \\stopRecord")
  for _, name in ipairs(stubs.engine_polls_from_source(commented)) do
    assert_true(name ~= "ghostPoll", "a commented-out poll is skipped")
  end
  -- #24's SynthDef and envelope parsers: a commented-out SynthDef, argument or Env
  local patched, count = source:gsub("SynthDef%(\\strataGrain, {%s*arg ", "%0/* ghostControl=0, */ ")
  assert_equal(count, 1, "argument patch applies")
  patched, count = patched:gsub("envBuffers%s*=%s*%[", "%0\n            // Env.ghost,")
  assert_equal(count, 1, "envelope patch applies")
  local spec = stubs.engine_spec_from_source(patched .. "\n// SynthDef(\\ghostDef, { arg ghost; });")
  assert_true(spec.synthdef_controls.ghostDef == nil, "a commented-out SynthDef is skipped")
  assert_true(not spec.synthdef_controls.strataGrain.ghostControl, "a commented-out argument is skipped")
  assert_true(spec.synthdef_controls.strataGrain.grainSize, "the arguments around it are read")
  assert_equal(spec.enumerations.envShape[2], engine_spec.enumerations.envShape[2], "a commented-out Env is not counted")
end)

test("strip_sc_comments fails on an unterminated string, symbol or block comment (#51)", function()
  local function assert_strip_fails(source, expected_text, line)
    local ok, message = pcall(stubs.strip_sc_comments, source)
    assert_true(not ok, "unterminated " .. expected_text .. " is an error, not the rest of the file")
    assert_true(tostring(message):find("unterminated " .. expected_text, 1, true)
      and tostring(message):find("line " .. line, 1, true), "the error says what and where: " .. tostring(message))
  end
  assert_strip_fails('a = 1;\nb = "open;\nc = 2;', "string", 2)
  assert_strip_fails("a = 1;\n\nb = 'open;", "symbol", 3)
  assert_strip_fails('a = 1; /* open /* nested */ still open', "block comment", 1)
  assert_strip_fails('a = "ends in an escape\\"', "string", 1)
  -- a SynthDef whose { never closes: the error names its line too
  local file = assert(io.open(SC_PATH, "r")); local source = file:read("*a"); file:close()
  local _, lines = source:gsub("\n", "")
  local ok, message = pcall(stubs.engine_spec_from_source, source .. "\nSynthDef(\\open, { arg x; x = 1;\n")
  assert_true(not ok and tostring(message):find("unbalanced { from line " .. (lines + 2), 1, true),
    "unbalanced: " .. tostring(message))
  -- closed ones, with escapes, still pass
  assert_equal(stubs.strip_sc_comments('a = "x\\"y"; b = \'q\\\'r\';'), 'a = "x\\"y"; b = \'q\\\'r\';', "escaped quotes")
end)

-- Expects engine.<name>(...) to be rejected by the engine stub with an error
-- containing `expected_text`
local function assert_engine_rejects(expected_text, name, ...)
  local ok, message = pcall(engine[name], ...)
  assert_true(not ok, "engine." .. name .. " should be rejected (" .. expected_text .. ")")
  assert_true(tostring(message):find(expected_text, 1, true) ~= nil,
    "engine." .. name .. " error mentions " .. expected_text .. ": " .. tostring(message))
end

test("the engine stub reads its limits and controls from the engine source (#24)", function()
  load_strata()
  local spec = stubs.parse_engine_spec(SC_PATH)
  assert_equal(spec.num_voices, local_value("NUM_VOICES"), "numVoices")
  assert_equal(spec.num_buffers, local_value("NUM_BUFFERS"), "numBuffers")
  assert_equal(spec.input_source, local_value("NUM_BUFFERS") + 1, "inputSource")
  assert_equal(spec.mod_slots, local_value("NUM_MOD_SLOTS"), "modBus1..N on every voice SynthDef")
  assert_equal(#spec.voice_synthdefs, spec.num_voices, "one voice SynthDef per voice")
  assert_equal(spec.voice_synthdefs[1], "strataResonator", "voice 0 SynthDef")
  assert_equal(spec.voice_synthdefs[7], "strataRing", "voice 6 SynthDef")
  assert_true(spec.synthdef_controls.strataFM.ratio, "strataFM controls parsed")
  assert_true(spec.synthdef_controls.strataGrainBuf.bufPos, "strataGrainBuf controls parsed")
  assert_true(spec.grain_params.envShape, "setGrainParam's own envShape is accepted")
  assert_true(spec.grain_params.bufPos and spec.grain_params.grainSize, "grain SynthDef controls are accepted")
  -- each enumerated control is 0..options - 1 of its Lua option param
  assert_equal(spec.enumerations.grainMode[1], 0, "grainMode from 0")
  assert_equal(spec.enumerations.grainMode[2], #local_value("GRAIN_MODE_OPTIONS") - 1, "grainMode to triggered")
  assert_equal(spec.enumerations.envShape[1], 0, "envShape from Hann")
  assert_equal(spec.enumerations.envShape[2], #local_value("GRAIN_ENV_OPTIONS") - 1, "envShape to the last envelope buffer")
  assert_equal(spec.enumerations.filterType[1], 0, "filterType from lowpass")
  assert_equal(spec.enumerations.filterType[2], 2, "filterType to bandpass")
  -- a control added to a grain SynthDef is picked up without stub changes
  local file = assert(io.open(SC_PATH, "r")); local source = file:read("*a"); file:close()
  local extended, count = source:gsub("SynthDef%(\\strataGrain, {%s*arg ", "%0newGrainControl=0, ")
  assert_equal(count, 1, "test patch applies")
  assert_true(stubs.engine_spec_from_source(extended).grain_params.newGrainControl, "new grain control accepted")
end)

test("the engine's shared constants equal strata.lua's (#25)", function()
  load_strata()
  assert_equal(engine_spec.num_voices, local_value("NUM_VOICES"), "numVoices = NUM_VOICES")
  assert_equal(engine_spec.num_buffers, local_value("NUM_BUFFERS"), "numBuffers = NUM_BUFFERS")
  assert_equal(engine_spec.buffer_seconds, local_value("BUFFER_SECONDS"), "bufferSeconds = BUFFER_SECONDS")
  -- the crossmod commands accept slots 1..numModSlots, the modBus1..N of every voice SynthDef (#47)
  assert_equal(engine_spec.num_mod_slots, local_value("NUM_MOD_SLOTS"), "numModSlots = NUM_MOD_SLOTS")
  assert_equal(engine_spec.num_mod_slots, engine_spec.mod_slots, "numModSlots = the modBus1..N controls")
  -- only buffer_state_changed, a local function, reads BUFFER_STATE_STRIDE
  -- (declared in exactly one of the script's files)
  local stride
  for _, source in ipairs(read_lua_sources()) do
    local found = tonumber(source.text:match("\nlocal BUFFER_STATE_STRIDE%s*=%s*(%d+)"))
    if found then
      assert_equal(stride, nil, "BUFFER_STATE_STRIDE is declared once")
      stride = found
    end
  end
  assert_equal(engine_spec.buffer_state_stride, stride, "bufferStateStride = BUFFER_STATE_STRIDE")
end)

test("the engine stub's voice and slot limits follow numVoices and numBuffers in the engine source (#51)", function()
  local file = assert(io.open(SC_PATH, "r")); local source = file:read("*a"); file:close()
  local patched, count = source:gsub("var <numVoices = %d+;", "var <numVoices = 6;")
  assert_equal(count, 1, "numVoices patch applies")
  patched, count = patched:gsub(",%s*\\strataRing%]", "]")
  assert_equal(count, 1, "voiceSynthDefs patch applies")
  patched, count = patched:gsub("var <numBuffers = %d+;", "var <numBuffers = 4;")
  assert_equal(count, 1, "numBuffers patch applies")
  local path = data_root .. "Engine_Patched.sc"
  file = assert(io.open(path, "w")); file:write(patched); file:close()
  local spec = stubs.parse_engine_spec(path)
  os.remove(path)
  assert_equal(spec.num_voices, 6, "numVoices read from the patched copy")
  assert_equal(spec.num_buffers, 4, "numBuffers read from the patched copy")
  assert_equal(spec.input_source, 5, "inputSource follows numBuffers")
  -- the stub's range checks use them
  stubs.install { signatures = signatures, engine_polls = engine_polls, engine_spec = spec,
    data_dir = data_root .. "patched_engine/", quiet = true }
  engine.voiceOff(5); engine.clearBuffer(3); engine.setGrainSource(0, 5); engine.setModSource(0, 1, 5)
  assert_engine_rejects("voice", "voiceOff", 6)
  assert_engine_rejects("slot", "clearBuffer", 4)
  assert_engine_rejects("source", "setGrainSource", 0, 6)
  assert_engine_rejects("mod source", "setModSource", 0, 1, 6)
end)

-- The script never bangs its params, so until a param changes the engine
-- plays the FX SynthDef's own default: it must be the Lua param's default.
-- Each FX command sets FX synth controls from its arguments (parsed from
-- every setSynth in the command bodies); sending every fx param's default
-- must send exactly those SynthDef defaults.
test("the FX SynthDefs' defaults equal the Lua param defaults (#25)", function()
  local context = load_strata()
  local fx_commands = engine_spec.fx_commands
  for _, name in ipairs({"setFilter", "setDelay", "setReverb", "setMasterDrift"}) do
    assert_true(fx_commands[name] ~= nil, "engine." .. name .. " sets an FX synth")
  end
  local group_index
  for index, param in ipairs(params.params) do
    if param.id == "strata_fx" then group_index = index end
  end
  assert_true(group_index ~= nil, "the fx group exists")
  context.clear_engine_calls()
  for index = group_index + 1, group_index + params:get("strata_fx") do
    local param_id = params.params[index].id
    send_param_to_engine(param_id, params:get(param_id))
  end
  for name, settings in pairs(fx_commands) do
    local calls = context.calls_named(name)
    assert_true(#calls > 0, "an fx param sends engine." .. name)
    local set_arguments = {}
    for _, setting in ipairs(settings) do
      set_arguments[setting.argument] = true
      local defaults = engine_spec.synthdef_defaults[setting.synthdef]
      local label = "\\" .. setting.synthdef .. " " .. setting.control
      assert_true(defaults[setting.control] ~= nil, label .. " has a numeric default")
      assert_near(calls[#calls].args[setting.argument], defaults[setting.control], 1e-6,
        "engine." .. name .. " argument " .. setting.argument .. " (Lua default) vs " .. label)
    end
    for index = 1, #signatures[name] do
      assert_true(set_arguments[index], "engine." .. name .. " argument " .. index .. " sets a control")
    end
  end
end)

-- A Lua FX param whose range is wider than the limit the engine clips its
-- control to fails here (the range check only sees the values sent)
-- The FX params whose controlspec range leaves the limit the engine clips
-- their argument to (each param's argument: the one that changes with it),
-- and how many param/limit pairs were compared
local function fx_specs_outside_engine_limits(context)
  local group_index
  for index, param in ipairs(params.params) do
    if param.id == "strata_fx" then group_index = index end
  end
  local problems, compared = {}, 0
  for index = group_index + 1, group_index + params:get("strata_fx") do
    local param = params.params[index]
    local spec = param.controlspec
    if spec then
      local function sent(fraction)
        context.clear_engine_calls(); send_param_to_engine(param.id, spec:map(fraction))
        return context.engine_calls[#context.engine_calls]
      end
      local low, high = sent(0.25), sent(0.75)
      for argument = 1, #high.args do
        local limit = (engine_spec.argument_limits[high.name] or {})[argument]
        if low.args[argument] ~= high.args[argument] and limit then
          compared = compared + 1
          if spec.minval < limit.low or spec.maxval > limit.high then
            table.insert(problems, string.format("%s %g..%g leaves engine.%s's %s limit %g..%g", param.id,
              spec.minval, spec.maxval, high.name, limit.name, limit.low, limit.high))
          end
        end
      end
    end
  end
  return problems, compared
end

-- A Lua FX range wider than the engine's limit fails here directly (the
-- range check only sees the values a test happens to send)
test("each FX param's controlspec lies within the engine's limit for its argument (#51)", function()
  local problems, compared = fx_specs_outside_engine_limits(load_strata())
  assert_equal(#problems, 0, table.concat(problems, "; "))
  assert_equal(compared, 6, "filter freq, res and mix; delay time, feedback and mix compared")
  local widened, count = patched_script('controlspec%.new%(0, 0%.95, "lin", 0%.01, 0%.4%)', 'controlspec.new(0, 0.99, "lin", 0.01, 0.4)')
  assert_equal(count, 1, "delay feedback patch applies")
  problems = fx_specs_outside_engine_limits(load_strata(widened))
  assert_true(#problems == 1 and problems[1]:find("delay_feedback", 1, true), "a widened range fails: " .. table.concat(problems, "; "))
end)

test("fx_commands reads every setSynth in a command body (#51)", function()
  local file = assert(io.open(SC_PATH, "r")); local source = file:read("*a"); file:close()
  -- \setFilter split into two setSynth calls, and \setReverb also setting the master's drift
  local patched, count = source:gsub(
    "this%.setSynth%(\\filter, \\freq, msg%[1%], \\res, msg%[2%], \\filterType, msg%[3%], \\mix, msg%[4%]%);",
    "this.setSynth(\\filter, \\freq, msg[1], \\res, msg[2]);\n            "
      .. "this.setSynth(\\filter, \\filterType, msg[3], \\mix, msg[4]);")
  assert_equal(count, 1, "setFilter patch applies")
  patched, count = patched:gsub("(this%.setSynth%(\\reverb, [^;]*;)", "%1 this.setSynth(\\master, \\drift, msg[3]);")
  assert_equal(count, 1, "setReverb patch applies")
  local function settings_of(spec, command)
    local found = {}
    for _, setting in ipairs(spec.fx_commands[command]) do
      table.insert(found, setting.argument .. ":" .. setting.synthdef .. "." .. setting.control)
    end
    table.sort(found)
    return table.concat(found, " ")
  end
  local spec = stubs.engine_spec_from_source(patched)
  assert_equal(settings_of(spec, "setFilter"), settings_of(engine_spec, "setFilter"), "both setSynth calls read")
  assert_equal(settings_of(spec, "setFilter"),
    "1:strataFilter.freq 2:strataFilter.res 3:strataFilter.filterType 4:strataFilter.mix", "every argument")
  assert_equal(settings_of(spec, "setReverb"),
    "1:strataReverb.mix 2:strataReverb.size 3:strataMaster.drift 3:strataReverb.damp",
    "a second FX synth set by the same command")
end)

test("the engine stub rejects out-of-range engine arguments (#24)", function()
  load_strata()
  -- voices are 0..numVoices-1
  assert_engine_rejects("voice", "voiceOff", 7)
  assert_engine_rejects("voice", "voiceOff", -1)
  assert_engine_rejects("voice", "voiceOn", 7, 100, 0.3, 0, 0.1, 20, 1)
  assert_engine_rejects("voice", "retrigger", 7, 1)
  assert_engine_rejects("voice", "setVoiceParam", 7, "amp", 0.3)
  assert_engine_rejects("voice", "setGrainParam", 7, "grainSize", 0.1)
  assert_engine_rejects("voice", "setModSpeed", 7, 1)
  engine.voiceOff(0); engine.voiceOff(6)
  -- slots are 0..numBuffers-1
  for _, command in ipairs({"clearBuffer", "stopRecord"}) do
    assert_engine_rejects("slot", command, 8)
    assert_engine_rejects("slot", command, -1)
  end
  assert_engine_rejects("slot", "loadBuffer", 8, "/tmp/x.wav")
  assert_engine_rejects("slot", "saveBuffer", 8, "/tmp/x.wav")
  assert_engine_rejects("slot", "recordBuffer", 8, 4, 1)
  engine.clearBuffer(0); engine.clearBuffer(7)
  -- sources are 0 (synth), 1..numBuffers, numBuffers + 1 (input)
  assert_engine_rejects("source", "setGrainSource", 0, 10)
  assert_engine_rejects("source", "setGrainSource", 0, -1)
  engine.setGrainSource(0, 0); engine.setGrainSource(0, 9)
  -- mod slots are 1..3, mod sources -1 (none) or a voice
  for _, command in ipairs({"setModAmpAmt", "setModFreqAmt"}) do
    assert_engine_rejects("mod slot", command, 0, 0, 0.5)
    assert_engine_rejects("mod slot", command, 0, 4, 0.5)
    assert_engine_rejects("voice", command, 7, 1, 0.5)
  end
  assert_engine_rejects("mod slot", "setModSource", 0, 4, 1)
  assert_engine_rejects("mod source", "setModSource", 0, 1, 7)
  assert_engine_rejects("mod source", "setModSource", 0, 1, -2)
  engine.setModSource(0, 1, -1); engine.setModSource(0, 3, 6)
  -- filter type 0..2
  assert_engine_rejects("filterType", "setFilter", 5000, 0.5, 3, 0)
  assert_engine_rejects("filterType", "setFilter", 5000, 0.5, -1, 0)
  engine.setFilter(5000, 0.5, 2, 0)
  -- enumerated grain params: whole numbers in range
  assert_engine_rejects("grainMode", "setGrainParam", 0, "grainMode", 2)
  assert_engine_rejects("grainMode", "setGrainParam", 0, "grainMode", 0.5)
  assert_engine_rejects("envShape", "setGrainParam", 0, "envShape", 5)
  assert_engine_rejects("envShape", "setGrainParam", 0, "envShape", -1)
  engine.setGrainParam(0, "grainMode", 1); engine.setGrainParam(0, "envShape", 4)
end)

-- Continuous limits come from where the engine enforces them: a control its
-- FX SynthDef clips (feedback.clip(0, 0.95), freq.lag(0.05).clip(20, 20000))
-- or an argument the command clips (msg[2].clip(0, 1)). The engine clips no
-- crossmod depth or mod speed itself; CLAUDE.md's command table documents
-- their ranges, and the stub reads them from the spec of the Lua param that
-- sends the value.
test("the engine stub range-checks continuous arguments at the engine's own limits (#51)", function()
  load_strata()
  local limits = engine_spec.argument_limits
  local unpack_args = table.unpack or unpack
  -- base_args with argument `index` set to `value`
  local function args_with(base_args, index, value)
    local args = { unpack_args(base_args) }
    args[index] = value
    return unpack_args(args)
  end
  local function check_limits(command, base_args, index, name, low, high)
    assert_engine_rejects(name, command, args_with(base_args, index, high + 1e-6))
    assert_engine_rejects(name, command, args_with(base_args, index, low - 1e-6))
    engine[command](args_with(base_args, index, low)); engine[command](args_with(base_args, index, high))
  end
  local function engine_limit(command, index, name)
    local limit = limits[command] and limits[command][index]
    assert_true(limit ~= nil, "engine." .. command .. " argument " .. index .. " (" .. name .. ") has a limit")
    assert_true(limit.name == name, "engine." .. command .. " argument " .. index .. " is " .. name)
    return limit.low, limit.high
  end
  check_limits("setFilter", {5000, 0.5, 0, 0}, 1, "freq", engine_limit("setFilter", 1, "freq"))
  check_limits("setFilter", {5000, 0.5, 0, 0}, 2, "res", engine_limit("setFilter", 2, "res"))
  check_limits("setFilter", {5000, 0.5, 0, 0}, 4, "mix", engine_limit("setFilter", 4, "mix"))
  check_limits("setDelay", {0.375, 0.4, 0}, 1, "time", engine_limit("setDelay", 1, "time"))
  check_limits("setDelay", {0.375, 0.4, 0}, 2, "feedback", engine_limit("setDelay", 2, "feedback"))
  check_limits("setDelay", {0.375, 0.4, 0}, 3, "mix", engine_limit("setDelay", 3, "mix"))
  check_limits("retrigger", {0, 1}, 2, "velocity", engine_limit("retrigger", 2, "velocity"))
  -- the limits follow the engine source
  local file = assert(io.open(SC_PATH, "r")); local source = file:read("*a"); file:close()
  local patched, count = source:gsub("feedback%.clip%(0, 0%.95%)", "feedback.clip(0, 0.5)")
  assert_equal(count, 1, "feedback patch applies")
  patched, count = patched:gsub("msg%[2%]%.clip%(0, 1%)", "msg[2].clip(0, 0.8)")
  assert_equal(count, 1, "velocity patch applies")
  local patched_limits = stubs.engine_spec_from_source(patched).argument_limits
  assert_equal(patched_limits.setDelay[2].high, 0.5, "the delay feedback limit is read from \\strataDelay")
  assert_equal(patched_limits.retrigger[2].high, 0.8, "the velocity limit is read from \\retrigger")
  -- documented, not clipped: the Lua param's controlspec, which CLAUDE.md's row states
  file = assert(io.open(repo_root .. "/CLAUDE.md", "r")); local doc = file:read("*a"); file:close()
  local documented = {
    { command = "setModAmpAmt", args = {6, 3, 0}, index = 3, param = "v7_mod_amp_amt_3", range = "%g to %g" },
    { command = "setModFreqAmt", args = {0, 1, 0}, index = 3, param = "v1_mod_freq_amt_1", range = "%g to %g" },
    { command = "setModSpeed", args = {2, 10}, index = 2, param = "v3_mod_speed", range = "%g-%g" },
  }
  for _, entry in ipairs(documented) do
    local spec = params:lookup_param(entry.param).controlspec
    check_limits(entry.command, entry.args, entry.index, entry.param, spec.minval, spec.maxval)
    local row = doc:match("\n| `engine%." .. entry.command .. "%(.-\n")
    assert_true(row and row:find(string.format(entry.range, spec.minval, spec.maxval), 1, true),
      "CLAUDE.md documents engine." .. entry.command .. "'s range as " .. entry.param .. "'s spec")
  end
end)

test("the engine stub rejects param names the SynthDefs do not have (#24)", function()
  load_strata()
  local spec = stubs.parse_engine_spec(SC_PATH)
  -- ratio is a strataFM control (voice 1), not one of strataResonator (voice 0)
  assert_engine_rejects("ratio", "setVoiceParam", 0, "ratio", 1.5)
  engine.setVoiceParam(1, "ratio", 1.5)
  assert_engine_rejects("nonsense", "setVoiceParam", 0, "nonsense", 1)
  for engine_voice = 0, spec.num_voices - 1 do engine.setVoiceParam(engine_voice, "bend", 1) end
  -- grain params: either grain SynthDef's controls (kept for a source switch) plus envShape
  assert_engine_rejects("ratio", "setGrainParam", 0, "ratio", 1)
  assert_engine_rejects("grainsize", "setGrainParam", 0, "grainsize", 0.1)
  engine.setGrainParam(0, "bufPos", 0.5); engine.setGrainParam(0, "grainSize", 0.1)
  engine.setGrainParam(0, "envShape", 0)
end)

test("CLAUDE.md command table lists exactly the engine's commands", function()
  local file = assert(io.open(repo_root .. "/CLAUDE.md", "r")); local doc = file:read("*a"); file:close()
  -- table rows: | `engine.<name>(<args>)` | `"<signature>"` | purpose |
  local rows = {}
  for line in doc:gmatch("[^\n]+") do
    local name, args, signature = line:match('^| `engine%.(%w+)%((.-)%)` | `"(%a*)"` |')
    if name then
      assert_true(rows[name] == nil, "CLAUDE.md documents engine." .. name .. " twice")
      local arg_count = 0
      if args:match("%S") then arg_count = select(2, args:gsub(",", ",")) + 1 end
      rows[name] = { signature = signature, arg_count = arg_count }
    end
  end
  for name, signature in pairs(signatures) do
    local row = rows[name]
    assert_true(row ~= nil, "CLAUDE.md command table documents engine." .. name)
    assert_equal(row.signature, signature, "CLAUDE.md signature of engine." .. name)
    assert_equal(row.arg_count, #signature, "CLAUDE.md argument count of engine." .. name)
  end
  for name in pairs(rows) do
    assert_true(signatures[name] ~= nil, "CLAUDE.md command table lists engine." .. name .. ", which the engine does not have")
  end
  -- no engine command mentioned anywhere in CLAUDE.md, README.md,
  -- docs/status.md or docs/notes is gone
  local doc_names = maintained_docs()
  for _, note in ipairs({"docs/status.md", "docs/notes/engine.md", "docs/notes/lua.md"}) do
    local listed = false
    for _, doc_name in ipairs(doc_names) do listed = listed or doc_name == note end
    assert_true(listed, "the check reads " .. note)
  end
  for _, doc_name in ipairs(doc_names) do
    file = assert(io.open(repo_root .. "/" .. doc_name, "r")); local text = file:read("*a"); file:close()
    for name in text:gmatch("engine%.(%w+)%(") do
      assert_true(signatures[name] ~= nil, doc_name .. " mentions engine." .. name .. ", which the engine does not have")
    end
  end
end)

test("every repo path the maintained docs name exists (#52)", function()
  local checked = 0
  for _, doc_name in ipairs(maintained_docs()) do
    local file = assert(io.open(repo_root .. "/" .. doc_name, "r")); local text = file:read("*a"); file:close()
    local missing, count = doc_paths_missing(text)
    checked = checked + count
    if #missing > 0 then fail(doc_name .. " names " .. missing[1] .. ", which does not exist") end
  end
  assert_true(checked > 0, "the check finds the paths the docs name")
end)

test("the docs path check covers lib/ paths", function()
  local missing, checked = doc_paths_missing("see `lib/missing.lua`, `lib/Engine_Strata.sc` and `lib/x`, not lib/bare.lua")
  assert_equal(table.concat(missing, " "), "lib/missing.lua lib/x", "the missing lib/ paths are reported")
  assert_equal(checked, 3, "every backticked lib/ path is checked")
end)

test("CI cancels superseded runs of pull requests only, never of main (#51)", function()
  local file = assert(io.open(repo_root .. "/.github/workflows/test.yml", "r")); local workflow = file:read("*a"); file:close()
  local setting = workflow:match("\n%s*cancel%-in%-progress:%s*([^\n]-)%s*\n")
  assert_equal(setting, "${{ github.event_name == 'pull_request' }}", "cancel-in-progress")
  -- a pending run in a shared group is replaced by the next one even without
  -- cancel-in-progress, so a run on main gets a group of its own
  local group = workflow:match("\n%s*group:%s*([^\n]-)%s*\n")
  assert_equal(group, "tests-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}", "group")
end)

test("every voice param has a menu param, ordered by param_order", function()
  load_strata()
  local voices = local_value("voices")
  for voice_idx = 1, 7 do
    local voice = voices[voice_idx]
    local listed = {}
    for _, key in ipairs(voice.param_order) do
      listed[key] = true
      local param = params:lookup_param("v" .. voice_idx .. "_" .. key)
      assert_near(param.controlspec.default, voice.params[key], 1e-9,
        "voice " .. voice_idx .. " " .. key .. " default comes from the voices table")
    end
    for key in pairs(voice.params) do
      assert_true(listed[key], "voice " .. voice_idx .. " param_order lists " .. key)
    end
  end
end)

-- index engine calls for one voice by command and key
local function engine_state_for_voice(calls, engine_voice)
  local state = { voice = {}, grain = {}, source = {}, amp_amt = {}, freq_amt = {} }
  for _, call in ipairs(calls) do
    local args = call.args
    if args[1] == engine_voice then
      if call.name == "setVoiceParam" then state.voice[args[2]] = args[3]
      elseif call.name == "setGrainParam" then state.grain[args[2]] = args[3]
      elseif call.name == "setModSource" then state.source[args[2]] = args[3]
      elseif call.name == "setModAmpAmt" then state.amp_amt[args[2]] = args[3]
      elseif call.name == "setModFreqAmt" then state.freq_amt[args[2]] = args[3]
      elseif call.name == "setModSpeed" then state.speed = args[2]
      elseif call.name == "voiceOn" then state.voice_on = args end
    end
  end
  return state
end

test("starting a voice sends its complete state to the engine (C1, C2)", function()
  local context = load_strata()
  finish_startup(context)
  local voices = local_value("voices")
  -- turn everything off, then edit every voice while it is off
  for voice_idx = 1, 7 do
    if voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  params:set("master_density", 1.5)
  context.clear_engine_calls()
  scramble_state(42)
  for _, call in ipairs(context.engine_calls) do
    -- the source is always sent (the engine only records it for a stopped voice)
    assert_equal(call.name, "setGrainSource", "edits to stopped voices are not sent")
  end

  for voice_idx = 1, 7 do
    context.clear_engine_calls()
    toggle_voice(voice_idx)
    local voice = voices[voice_idx]
    local sent = engine_state_for_voice(context.engine_calls, voice_idx - 1)
    assert_true(sent.voice_on ~= nil, "voiceOn sent for voice " .. voice_idx)
    assert_equal(sent.voice_on[2], voice.params.freq, "voiceOn freq (number) for voice " .. voice_idx)
    for key, value in pairs(voice.params) do
      assert_equal(sent.voice[key], value, "voice " .. voice_idx .. " setVoiceParam " .. key)
    end
    assert_equal(sent.grain.grainSize, voice.grain.size, "voice " .. voice_idx .. " grainSize")
    assert_near(sent.grain.grainDensity, voice.grain.density * 1.5, 1e-9, "voice " .. voice_idx .. " grainDensity")
    assert_equal(sent.grain.pitchShift, voice.grain.pitch, "voice " .. voice_idx .. " pitchShift")
    assert_equal(sent.grain.posSpread, voice.grain.spread, "voice " .. voice_idx .. " posSpread")
    assert_equal(sent.grain.envShape, voice.grain.env - 1, "voice " .. voice_idx .. " envShape")
    assert_equal(sent.grain.grainMode, voice.grain.mode - 1, "voice " .. voice_idx .. " grainMode")
    assert_equal(sent.grain.bufPos, voice.grain.buf_pos, "voice " .. voice_idx .. " bufPos")
    assert_equal(sent.grain.bufRate, voice.grain.buf_rate, "voice " .. voice_idx .. " bufRate")
    assert_equal(sent.grain.bufScan, voice.grain.buf_scan, "voice " .. voice_idx .. " bufScan")
    -- the source goes first after voiceOn, before any other voice state
    assert_equal(context.engine_calls[1].name, "voiceOn", "voice " .. voice_idx .. " voiceOn first")
    assert_equal(context.engine_calls[2].name, "setGrainSource", "voice " .. voice_idx .. " source synced first")
    assert_equal(context.engine_calls[2].args[2], voice.source - 1, "voice " .. voice_idx .. " source")
    for slot = 1, 3 do
      local slot_state = voice.crossmod["slot" .. slot]
      local expected_source = slot_state.source == 0 and -1 or slot_state.source - 1
      assert_equal(sent.source[slot], expected_source, "voice " .. voice_idx .. " slot " .. slot .. " source")
      assert_equal(sent.amp_amt[slot], slot_state.amp_amt, "voice " .. voice_idx .. " slot " .. slot .. " amp")
      assert_equal(sent.freq_amt[slot], slot_state.freq_amt, "voice " .. voice_idx .. " slot " .. slot .. " freq")
    end
    assert_equal(sent.speed, voice.crossmod.speed, "voice " .. voice_idx .. " mod speed")
  end
end)

test("voiceOn's grain density is the voice's density times master density as the engine has them", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  if voices[5].active then toggle_voice(5) end
  params:set("v5_grain_density", 20); params:set("master_density", 1.5)
  -- as LFOs on both params would have left them
  local sent_values = local_value("engine_param_values")
  sent_values.master_density = 0.5; sent_values.v5_grain_density = 30
  context.clear_engine_calls(); toggle_voice(5)
  assert_near(context.calls_named("voiceOn")[1].args[6], 15, 1e-9, "voiceOn grainDensity")
end)

test("the largest grain overlap Lua can send fits the engine's maxGrains", function()
  load_strata()
  local file = assert(io.open(SC_PATH, "r")); local source = file:read("*a"); file:close()
  local max_grains = tonumber(source:match("var <maxGrains = (%d+);"))
  assert_true(max_grains ~= nil, "the engine declares var <maxGrains = <n>;")
  local master_max = params:lookup_param("master_density").controlspec.maxval
  for voice_idx = 1, 7 do
    local size_max = params:lookup_param("v" .. voice_idx .. "_grain_size").controlspec.maxval
    local density_max = params:lookup_param("v" .. voice_idx .. "_grain_density").controlspec.maxval
    -- a GrainIn/GrainBuf runs at most maxGrains - 1 grains and drops the rest
    assert_true(size_max * density_max * master_max <= max_grains - 1,
      string.format("voice %d: %.2f s x %d x %.1f = %.0f overlapping grains fit maxGrains %d",
        voice_idx, size_max, density_max, master_max, size_max * density_max * master_max, max_grains))
  end
end)

test("grain envelope option reaches the engine and is synced on start", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_grain_env", 3)
  local calls = context.calls_named("setGrainParam"); local last = calls[#calls]
  assert_equal(last.args[2], "envShape"); assert_equal(last.args[3], 2)
  toggle_voice(3); params:set("v3_grain_env", 5); toggle_voice(3)       -- on, edit, off
  context.clear_engine_calls(); toggle_voice(3)                          -- on again: synced
  local sent = engine_state_for_voice(context.engine_calls, 2)
  assert_equal(sent.grain.envShape, 4)
  capture_scene(1); params:set("v1_grain_env", 1)
  recall_scene(1, 2); wake(context, "scene_transition_clock")
  assert_equal(params:get("v1_grain_env"), 1, "transition does not interpolate env")
  recall_scene(1, 0); assert_equal(params:get("v1_grain_env"), 3)
  -- an option param floors fractional values, so check the fade list directly
  for _, target in ipairs(scene_transition_targets(local_value("scenes")[1].data)) do
    assert_true(not target.id:find("_grain_env$"), target.id .. " is not crossfaded")
  end
end)

test("grain envelope param: options, default, scenes, never mutated or randomized", function()
  local context = load_strata(); finish_startup(context)
  for voice_idx = 1, 7 do
    local param = params:lookup_param("v" .. voice_idx .. "_grain_env")
    assert_equal(param.t, params.tOPTION, "voice " .. voice_idx .. " grain_env is an option")
    assert_equal(param.count, 5, "five envelope shapes")
    assert_equal(params:get("v" .. voice_idx .. "_grain_env"), 1, "default hann")
    assert_equal(local_value("voices")[voice_idx].grain.env, 1, "voices table holds the index")
  end
  local names = {}
  for index = 1, 5 do params:set("v1_grain_env", index); names[index] = params:string("v1_grain_env") end
  assert_equal(table.concat(names, ","), "hann,sine,perc,linen,trap")
  -- every per-voice scene default equals its param default
  local found_env = false
  for _, field in ipairs(local_value("VOICE_SCENE_DEFAULTS")) do
    if field.path[1] == "grain" and field.path[2] == "env" then found_env = true end
    if field.path[1] == "grain" then
      local suffix = local_value("GRAIN_PARAM_IDS")[field.path[2]]
      for voice_idx = 1, 7 do
        local param = params:lookup_param("v" .. voice_idx .. "_" .. suffix)
        local param_default = param.controlspec and param.controlspec.default or param.default
        assert_equal(field.default, param_default, "voice " .. voice_idx .. " " .. suffix .. " scene default")
      end
    end
  end
  assert_true(found_env, "grain.env has a scene default")
  -- scenes written before grain envelopes migrate to hann
  params:set("v2_grain_env", 4)
  capture_scene(3)
  local scene = local_value("scenes")[3]
  for voice_idx = 1, 7 do scene.data.voices[voice_idx].grain.env = nil end
  migrate_scene(scene, 2)
  assert_equal(scene.data.voices[2].grain.env, 1, "missing env migrates to hann")
  assert_true(validate_scene(scene), "migrated scene validates")
  scene.data.voices[2].grain.env = 2.5
  assert_true(not validate_scene(scene), "a fractional envelope index is rejected")
  scene.data.voices[2].grain.env = 0
  assert_true(not validate_scene(scene), "envelope index 0 is rejected")
  scene.data.voices[2].grain.env = 1
  -- mutation and randomize leave the envelope alone
  for voice_idx = 1, 7 do
    if not local_value("voices")[voice_idx].active then toggle_voice(voice_idx) end
    params:set("v" .. voice_idx .. "_grain_env", 4)
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(5)
  for _ = 1, 50 do gentle_mutate() end
  for voice_idx = 1, 7 do randomize_voice(voice_idx) end
  for voice_idx = 1, 7 do
    assert_equal(params:get("v" .. voice_idx .. "_grain_env"), 4, "voice " .. voice_idx .. " envelope unchanged")
  end
end)

test("pattern steps retrigger running voices and never stack synths (C3)", function()
  local context = load_strata()
  finish_startup(context)  -- voices 1 and 2 running
  local voices = local_value("voices")
  assert_true(voices[1].active and not voices[3].active, "voice 1 on, voice 3 off")
  for step = 1, 16 do toggle_pattern_step(1, step) end
  toggle_pattern_step(3, 1)
  context.clear_engine_calls()

  pattern_toggle()  -- plays step 1 immediately
  for _ = 1, 31 do wake(context, "pattern_clock") end  -- 31 more 16ths: two full bars
  pattern_toggle()

  local retriggers = context.calls_named("retrigger")
  local voice_on_calls = context.calls_named("voiceOn")
  local voice1_retriggers, voice3_retriggers = 0, 0
  for _, call in ipairs(retriggers) do
    if call.args[1] == 0 then voice1_retriggers = voice1_retriggers + 1 end
    if call.args[1] == 2 then voice3_retriggers = voice3_retriggers + 1 end
  end
  assert_equal(voice1_retriggers, 32, "voice 1 retriggered on each of 32 steps")
  assert_equal(#voice_on_calls, 1, "only the stopped voice was started")
  assert_equal(voice_on_calls[1].args[1], 2, "voice 3 started by its first step")
  assert_equal(voice3_retriggers, 1, "voice 3 retriggered on its second pass")
  assert_equal(#context.calls_named("voiceOff"), 0, "no voice was stopped")
  for _, entry in ipairs(context.clock.sleep_log) do
    assert_true(entry.mode ~= "sleep" or entry.amount ~= 0.01, "no 10 ms retrigger gap")
  end
end)

test("pattern steps retrigger with velocity from the step level", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns"); patterns[1][1] = 15; patterns[1][2] = 6
  context.clear_engine_calls(); pattern_toggle(); wake(context, "pattern_clock"); pattern_toggle()
  local calls = context.calls_named("retrigger")
  assert_equal(#calls, 2, "one retrigger per active step")
  assert_equal(calls[1].args[1], 0); assert_near(calls[1].args[2], 1.0, 1e-9)
  assert_equal(calls[2].args[1], 0); assert_near(calls[2].args[2], 6 / 15, 1e-9)
end)

test("restarting the pattern clock leaves one pattern clock running", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  for step = 1, 16 do patterns[1][step] = 15 end
  pattern_clock_start()
  local first_clock = local_value("pattern_clock")
  pattern_clock_start()                                          -- restart while it plays
  assert_true(context.clock.threads[first_clock] == nil, "the first pattern clock was canceled")
  context.clear_engine_calls()
  context.clock.run_for(clock.get_beat_sec() + 0.01)             -- four 16th steps
  local retriggers = 0
  for _, call in ipairs(context.calls_named("retrigger")) do
    if call.args[1] == 0 then retriggers = retriggers + 1 end
  end
  assert_equal(retriggers, 4, "voice 1 retriggered once per step")
  pattern_clock_stop()
end)

test("grain mode option is sent, synced and never mutated", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_grain_mode", 2)
  local calls = context.calls_named("setGrainParam"); assert_equal(calls[#calls].args[2], "grainMode"); assert_equal(calls[#calls].args[3], 1)
  params:set("mutation_probability", 1); params:set("mutation_amount", 1); gentle_mutate()
  assert_equal(params:get("v1_grain_mode"), 2)
end)

test("grain mode param: options, default, sync, scenes, never mutated, randomized or crossfaded", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  for voice_idx = 1, 7 do
    local param = params:lookup_param("v" .. voice_idx .. "_grain_mode")
    assert_equal(param.t, params.tOPTION, "voice " .. voice_idx .. " grain_mode is an option")
    assert_equal(param.count, 2, "two grain modes")
    assert_equal(params:get("v" .. voice_idx .. "_grain_mode"), 1, "default continuous")
    assert_equal(voices[voice_idx].grain.mode, 1, "voices table holds the index")
  end
  params:set("v1_grain_mode", 1); assert_equal(params:string("v1_grain_mode"), "continuous")
  params:set("v1_grain_mode", 2); assert_equal(params:string("v1_grain_mode"), "triggered")
  -- edited while off, sent when the voice starts
  assert_true(not voices[3].active, "voice 3 starts off")
  context.clear_engine_calls(); params:set("v3_grain_mode", 2)
  assert_equal(#context.calls_named("setGrainParam"), 0, "a stopped voice's mode is not sent")
  toggle_voice(3)
  assert_equal(engine_state_for_voice(context.engine_calls, 2).grain.grainMode, 1, "start syncs grainMode")
  -- scenes: default, capture/recall, switched at the end of a transition
  local found_mode = false
  for _, field in ipairs(local_value("VOICE_SCENE_DEFAULTS")) do
    if field.path[1] == "grain" and field.path[2] == "mode" then
      found_mode = true
      assert_equal(field.default, params:lookup_param("v1_grain_mode").default, "scene default = param default")
    end
  end
  assert_true(found_mode, "grain.mode has a scene default")
  capture_scene(1); params:set("v1_grain_mode", 1)
  for _, target in ipairs(scene_transition_targets(local_value("scenes")[1].data)) do
    assert_true(not target.id:find("_grain_mode$"), target.id .. " is not crossfaded")
  end
  recall_scene(1, 0); assert_equal(params:get("v1_grain_mode"), 2, "scene recall restores the mode")
  local scene = local_value("scenes")[1]
  for voice_idx = 1, 7 do scene.data.voices[voice_idx].grain.mode = nil end
  migrate_scene(scene, 2)
  assert_equal(scene.data.voices[1].grain.mode, 1, "missing mode migrates to continuous")
  assert_true(validate_scene(scene), "migrated scene validates")
  scene.data.voices[1].grain.mode = 3
  assert_true(not validate_scene(scene), "a mode index past the options is rejected")
  scene.data.voices[1].grain.mode = 1.5
  assert_true(not validate_scene(scene), "a fractional mode index is rejected")
  -- mutation and randomize leave the mode alone
  for voice_idx = 1, 7 do
    if not voices[voice_idx].active then toggle_voice(voice_idx) end
    params:set("v" .. voice_idx .. "_grain_mode", 2)
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(9)
  for _ = 1, 50 do gentle_mutate() end
  for voice_idx = 1, 7 do randomize_voice(voice_idx) end
  for voice_idx = 1, 7 do
    assert_equal(params:get("v" .. voice_idx .. "_grain_mode"), 2, "voice " .. voice_idx .. " mode unchanged")
  end
end)

test("MAIN shows [TRIG] for a voice in triggered grain mode", function()
  local context = load_strata(); finish_startup(context)
  local function trig_drawn()
    redraw()
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == "[TRIG]" then return entry end
    end
  end
  assert_true(not trig_drawn(), "no indicator in continuous mode")
  params:set("v1_grain_mode", 2)
  local entry = trig_drawn()
  assert_true(entry, "indicator in triggered mode")
  assert_equal(entry.y, 42, "on the main parameter label row")
end)

test("grain pitch drift wanders subtly around the user-set pitch (C4)", function()
  local context = load_strata()
  local drift_metro = context.metro.all[1]
  assert_true(drift_metro.running and drift_metro.event == drift_update, "drift metro running")
  params:set("v1_grain_pitch", 1.5)
  math.randomseed(3)
  local max_offset = 0
  for _ = 1, 20000 do
    drift_metro.event()
    max_offset = math.max(max_offset, math.abs(params:get("v1_grain_pitch") - 1.5))
  end
  assert_true(max_offset > 0.001, "pitch actually drifts (" .. max_offset .. ")")
  assert_true(max_offset < 0.06, "drift stays within a few percent (" .. max_offset .. ")")
  -- a new user value becomes the new center
  params:set("v1_grain_pitch", 0.5)
  for _ = 1, 2000 do drift_metro.event() end
  assert_near(params:get("v1_grain_pitch"), 0.5, 0.06, "walk re-centers on the new value")
  -- frozen voices do not drift
  toggle_freeze(1)
  local frozen_pitch = params:get("v1_grain_pitch")
  for _ = 1, 100 do drift_metro.event() end
  assert_equal(params:get("v1_grain_pitch"), frozen_pitch, "frozen voice pitch unchanged")
end)

-- drift_writing tells the param actions a write is the drift's: left set
-- after an error, every later edit would stop re-centering the walk
test("drift_update clears drift_writing when a param action raises (#48)", function()
  load_strata()                                                 -- voice 1 starts at once
  local centers = { v1_grain_pitch = "grain_pitch_base", v1_buf_pos = "buf_pos_base" }
  for _, id in ipairs({ "v1_grain_pitch", "v1_buf_pos" }) do
    params:set("v1_source", id == "v1_buf_pos" and 2 or 1)     -- buffer 1: its position drifts too
    params:set(id, 0.5)                                          -- clear of the rails: every step moves it
    local param = params:lookup_param(id)
    local real_action = param.action
    param.action = function() error(id .. " failed") end
    local ok, message = pcall(drift_update)
    assert_true(not ok and tostring(message):find(id .. " failed", 1, true), id .. ": the error is raised")
    assert_true(tostring(message):find("stack traceback:", 1, true), id .. ": with its traceback")
    assert_equal(local_value("drift_writing"), false, id .. ": drift_writing cleared")
    param.action = real_action
    params:set(id, 0.6)
    assert_equal(local_value(centers[id])[1], 0.6, id .. ": a later edit is the drift's new center")
  end
end)

test("tempo param drives clock_tempo and grid tempo buttons (I1)", function()
  local context = load_strata({ before_init = function() params:set("clock_tempo", 97) end })
  assert_equal(params:get("tempo"), 97, "tempo initialized from clock_tempo")
  params:set("tempo", 133)
  assert_equal(params:get("clock_tempo"), 133, "tempo param sets clock_tempo")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 13, 8, 1)  -- page 1
  context.grid.press(1, 8, 8, 1)   -- +10 BPM
  context.grid.press(1, 5, 8, 1)   -- -10 BPM
  context.grid.press(1, 7, 8, 1)   -- +1 BPM
  assert_equal(params:get("clock_tempo"), 134, "grid tempo buttons reach clock_tempo")
end)

test("tempo param follows a clock_tempo change made elsewhere (#15)", function()
  local context = load_strata({ before_init = function() params:set("clock_tempo", 97) end })
  -- PARAMETERS > CLOCK > tempo: a plain params:set on the system param
  params:set("clock_tempo", 150)
  assert_equal(params:get("tempo"), 150, "tempo param follows clock_tempo")
  -- a scene captures the tempo that is playing
  capture_scene(1)
  assert_equal(local_value("scenes")[1].data.tempo, 150, "scene captured the external tempo")
  -- grid +1 / -1 step from the external tempo, not from a stale value
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 13, 8, 1)
  context.grid.press(1, 7, 8, 1)
  assert_equal(params:get("clock_tempo"), 151, "grid +1 steps from the external tempo")
  params:set("clock_tempo", 200)
  context.grid.press(1, 6, 8, 1)
  assert_equal(params:get("clock_tempo"), 199, "grid -1 steps from the external tempo")
  -- recall applies the scene's tempo to the clock
  params:set("clock_tempo", 80)
  recall_scene(1)
  assert_equal(params:get("clock_tempo"), 150, "recall sets clock_tempo")
  assert_equal(params:get("tempo"), 150, "recall sets the tempo param")
  assert_true(clock.tempo_change_handler ~= nil, "handler installed")
  cleanup()
  assert_equal(clock.tempo_change_handler, nil, "cleanup restores the previous handler")
end)

test("the tempo param has clock_tempo's range: a 30 BPM scene recalls at 30 (#48)", function()
  local context = load_strata({ before_init = function() params:set("clock_tempo", 30) end })
  local clock_min, clock_max = param_range("clock_tempo")
  local tempo_min, tempo_max = param_range("tempo")
  assert_equal(tempo_min, clock_min, "tempo minimum is clock_tempo's")
  assert_equal(tempo_max, clock_max, "tempo maximum is clock_tempo's")
  assert_equal(params:get("tempo"), 30, "tempo initialized from a 30 BPM clock")
  capture_scene(1)
  assert_equal(local_value("scenes")[1].data.tempo, 30, "the scene captured 30 BPM")
  params:set("tempo", 100)
  recall_scene(1)
  assert_equal(params:get("clock_tempo"), 30, "recall sets the clock to 30 BPM")
  context.grid.plug(1, 16, 16)
  context.grid.press(1, 13, 8, 1)  -- page 1
  context.grid.press(1, 7, 8, 1)   -- +1 BPM
  assert_equal(params:get("clock_tempo"), 31, "grid +1 steps from 30 BPM")
  params:set("clock_tempo", clock_min)
  assert_equal(params:get("tempo"), clock_min, "the param follows the clock down to its minimum")
  context.grid.press(1, 6, 8, 1)   -- -1 BPM
  assert_equal(params:get("tempo"), clock_min, "grid -1 at the minimum keeps the tempo param there")
  assert_equal(params:get("clock_tempo"), clock_min, "and the clock")
  -- an external source's tempo reaches the handler unclamped
  clock.tempo_change_handler(clock_max + 100)
  assert_equal(params:get("tempo"), clock_max, "the param clamps to the clock's maximum")
end)

test("the tempo handler is installed once and cleanup restores only its own (#48)", function()
  local previous_calls, previous_bpm = 0, nil
  local function previous_handler(bpm) previous_calls = previous_calls + 1; previous_bpm = bpm end
  load_strata({ before_init = function() clock.tempo_change_handler = previous_handler end })
  local strata_handler = clock.tempo_change_handler
  assert_true(strata_handler ~= previous_handler, "the script's handler is installed")
  install_tempo_change_handler()                               -- installed again (init run twice)
  assert_equal(clock.tempo_change_handler, strata_handler, "a second install changes nothing")
  params:set("clock_tempo", 90)
  assert_equal(params:get("tempo"), 90, "the param follows the clock")
  assert_equal(previous_calls, 1, "the previous handler is still called, once per change")
  assert_equal(previous_bpm, 90, "with the bpm")
  cleanup()
  assert_equal(clock.tempo_change_handler, previous_handler, "cleanup restores the handler found at init")
  -- a handler installed after the script's (another library's) is left alone
  load_strata()
  local later_handler = function() end
  clock.tempo_change_handler = later_handler
  cleanup()
  assert_equal(clock.tempo_change_handler, later_handler, "cleanup keeps a handler installed after the script's")
end)

test("256-grid parameter page faders set values and show them (I8)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  local press = function(x, y) context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0) end
  press(14, 8)  -- grid page 2 (parameters)
  press(2, 14)  -- select voice 2 (fm)
  local ids = fader_param_ids(2)
  assert_equal(ids[1], "v2_freq", "first fader is freq")
  assert_equal(#ids, 6 + 6 + 9, "fm has 21 faders")
  assert_equal(fader_page_count(2), 6, "fm has 6 fader pages")
  assert_equal(ids[11], "v2_grain_env", "grain envelope follows the other grain faders")
  assert_equal(ids[12], "v2_grain_mode", "grain mode follows the envelope")
  assert_equal(fader_page_count(1), 6, "resonator has 6 fader pages")
  assert_equal(fader_page_count(3), 5, "folder has 5 fader pages")
  assert_equal(fader_page_count(4), 5, "sub has 5 fader pages")

  press(16, 9)  -- page 1 row 1 full right -> freq max
  assert_near(params:get("v2_freq"), 2000, 1, "column 16 sets max")
  press(1, 10)  -- row 2 (ratio) far left -> min
  assert_near(params:get("v2_ratio"), 0.5, 1e-6, "column 1 sets min")
  press(8, 11)  -- row 3 (index) column 8 -> linlin(1, 16, 0, 10, 8)
  assert_near(params:get("v2_index"), 70 / 15, 0.1, "column 8 sets the proportional value")
  -- LEDs: bar at 8 up to the value, value column at 15
  assert_equal(device:get_led(8, 11), 15, "value column bright")
  assert_equal(device:get_led(7, 11), 8, "bar below the value")
  assert_equal(device:get_led(9, 11), 0, "nothing above the value")
  assert_equal(device:get_led(16, 9), 15, "freq at max")
  assert_equal(device:get_led(1, 13), 15, "row 13 shows page 1 selected")

  -- exponential params follow their warp: freq (20-2000 Hz exp)
  press(1, 14)  -- select voice 1 (resonator)
  press(8, 9)   -- freq fader, column 8
  assert_near(params:get("v1_freq"), 20 * (2000 / 20) ^ (7 / 15), 1.0, "column 8 on an exp fader")
  assert_equal(device:get_led(8, 9), 15, "exp fader shows its value at column 8")
  press(4, 14)  -- select voice 4 (sub), freq 40 Hz
  assert_near(params:get("v4_freq"), 40, 1e-9, "sub freq default")
  local sub_column = fader_position("v4_freq")
  assert_true(sub_column > 1, "40 Hz shows above column 1 (got " .. sub_column .. ")")
  assert_equal(device:get_led(sub_column, 9), 15, "sub freq LED at its column")
  press(2, 14)  -- back to voice 2 (fm)
  assert_equal(device:get_led(6, 13), 4, "row 13 shows page 6 available")
  assert_equal(device:get_led(7, 13), 0, "no page 7")

  press(3, 13)  -- page 3: faders 9-12 = grain_pitch, grain_spread, grain_env, grain_mode
  assert_equal(device:get_led(3, 13), 15, "page 3 selected")
  -- grain envelope is an option param: an index fader over its 5 options
  press(16, 11)
  assert_equal(params:get("v2_grain_env"), 5, "envelope fader column 16 -> last option")
  assert_equal(device:get_led(16, 11), 15, "envelope fader shows the last option at column 16")
  press(1, 11)
  assert_equal(params:get("v2_grain_env"), 1, "envelope fader column 1 -> first option")
  press(9, 11)
  assert_equal(params:get("v2_grain_env"), 3, "envelope column 9 -> round(linlin(1,16,1,5,9))")
  assert_equal(fader_position("v2_grain_env"), 9, "option 3 of 5 shows at the middle column")
  assert_equal(device:get_led(9, 11), 15, "envelope fader LED at its option")
  -- grain mode: two options, columns 1-8 continuous, 9-16 triggered
  press(16, 12)
  assert_equal(params:get("v2_grain_mode"), 2, "mode fader column 16 -> triggered")
  press(8, 12)
  assert_equal(params:get("v2_grain_mode"), 1, "mode fader column 8 -> continuous")
  press(9, 12)
  assert_equal(params:get("v2_grain_mode"), 2, "mode fader column 9 -> triggered")
  assert_equal(device:get_led(16, 12), 15, "triggered shows at column 16")
  press(4, 13)  -- page 4: faders 13-16 = source 1, amp mod 1, freq mod 1, source 2
  press(16, 9)  -- mod source 1 -> 7 (number param, rounded)
  assert_equal(params:get("v2_mod_source_1"), 7, "mod source fader rounds to an integer")
  press(9, 9)
  assert_equal(params:get("v2_mod_source_1"), 4, "mod source column 9 -> round(linlin(1,16,0,7,9))")
  press(1, 10)  -- amp mod 1 -> -2
  assert_near(params:get("v2_mod_amp_amt_1"), -2, 1e-6, "amp mod fader min")
  press(16, 8)  -- grid page 4: rows 9-13 hold voice sources, not parameter faders
  for y = 9, 13 do
    local source = params:get("v" .. (y - 8) .. "_source")
    for x = 1, 16 do
      local level = device:get_led(x, y)
      if x > 10 then
        assert_equal(level, 0, "no fader past the source columns on page 4")
      elseif x == source then
        assert_equal(level, 15, "source rows on page 4")
      else
        assert_true(level == 4 or level == 2, "source rows, not fader bars, on page 4")
      end
    end
  end
end)

test("bipolar grid faders have a column that sets exactly 0, and keep both ends (#49)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  -- 16 columns have no center: a plain sweep of -1..1 gives +/-0.07 there
  params:set("v1_source", 2)  -- a buffer voice: its faders include scan and pan
  for _, param_id in ipairs({"v1_pan", "v1_buf_scan", "v1_mod_amp_amt_1", "v1_mod_freq_amt_1"}) do
    local minval, maxval = param_range(param_id)
    local zero_column
    local previous = -math.huge
    for x = 1, 16 do
      set_param_from_column(param_id, x)
      local value = params:get(param_id)
      assert_true(value > previous, param_id .. ": column " .. x .. " sets more than column " .. (x - 1))
      previous = value
      if value == 0 then zero_column = x end
      assert_equal(fader_position(param_id), x, param_id .. ": the value set by column " .. x .. " shows there")
    end
    assert_true(zero_column ~= nil, param_id .. ": a column sets exactly 0")
    assert_equal(zero_column, 9, param_id .. ": column 9 for a symmetric range (README)")
    set_param_from_column(param_id, 1)
    assert_near(params:get(param_id), minval, 1e-9, param_id .. ": column 1 still sets the minimum")
    set_param_from_column(param_id, 16)
    assert_near(params:get(param_id), maxval, 1e-9, param_id .. ": column 16 still sets the maximum")
    params:set(param_id, 0)  -- 0 set elsewhere (PARAMS, a scene) shows at the zero column
    assert_equal(fader_position(param_id), zero_column, param_id .. ": 0 shows at its column")
  end
  -- on the grid: page 2, voice 1, fader page 2 (row 9: pan)
  context.grid.press(1, 14, 8, 1); context.grid.press(1, 1, 14, 1); context.grid.press(1, 2, 13, 1)
  params:set("v1_pan", 1)
  local pan_zero_column = (function()
    for x = 1, 16 do
      set_param_from_column("v1_pan", x)
      if params:get("v1_pan") == 0 then return x end
    end
  end)()
  params:set("v1_pan", 1)
  context.grid.press(1, pan_zero_column, 9, 1)
  assert_equal(params:get("v1_pan"), 0, "the pan fader's zero column centers the pan")
  assert_equal(device:get_led(pan_zero_column, 9), 15, "and the fader shows it there")
  -- unipolar faders keep the plain sweep: column 8 on the exp freq fader
  params:set("v1_source", 1)
  set_param_from_column("v1_freq", 8)
  assert_near(params:get("v1_freq"), 20 * (2000 / 20) ^ (7 / 15), 1.0, "column 8 on an exp fader")
end)

local GRID_SIZES = {
  { name = "256", cols = 16, rows = 16 },
  { name = "128h", cols = 16, rows = 8 },
  { name = "128v", cols = 8, rows = 16 },
  { name = "64", cols = 8, rows = 8 },
}

test("every grid key on every layout and page runs without error", function()
  for _, size in ipairs(GRID_SIZES) do
    local context = load_strata()
    local device = context.grid.plug(1, size.cols, size.rows)
    -- 256 has four pages selected from row 8; other layouts are swept once
    local pages = size.name == "256" and { 1, 2, 3, 4 } or { 1 }
    for _, page in ipairs(pages) do
      for y = 1, size.rows do
        for x = 1, size.cols do
          if size.name == "256" then context.grid.press(1, 12 + page, 8, 1) end
          context.grid.press(1, x, y, 1)
          context.grid.press(1, x, y, 0)
          context.clock.advance()
        end
      end
    end
    assert_true(device.refresh_count > 0, size.name .. " grid was redrawn")
  end
end)

test("grid_redraw draws every layout (I2) and a hot-plugged grid (I3)", function()
  for _, size in ipairs(GRID_SIZES) do
    local context = load_strata()
    local device = context.grid.plug(2, size.cols, size.rows)
    local refreshes = device.refresh_count
    grid_redraw()
    assert_equal(device.refresh_count, refreshes + 1, size.name .. " redraw reaches a hot-plugged grid")
    -- voice 1 is running after init: its status LED must be lit on every layout
    local lit = false
    for x = 1, size.cols do
      for y = 1, size.rows do
        if device:get_led(x, y) >= 12 then lit = true end
      end
    end
    assert_true(lit, size.name .. " layout drew something")
  end
end)

-- Voice 1 needs no such guard: clock.run resumes the startup clock at once,
-- so it starts voice 1 inside init(), before any MIDI note, grid press or
-- key can reach the script
test("the startup clock leaves a voice 2 started within STARTUP.voice_delay_seconds running", function()
  local starters = {
    { name = "toggle_voice (a grid press)", start = function() toggle_voice(2) end },
    { name = "a MIDI note on channel 2 (midi_note_on)", start = function(context)
      context.midi.plug(1, "keys")
      context.midi.send(1, { type = "note_on", ch = 2, note = 60, vel = 100 })
    end },
  }
  for _, starter in ipairs(starters) do
    local context = load_strata()
    local voices = local_value("voices")
    assert_true(voices[1].active, starter.name .. ": init started voice 1")
    assert_true(not voices[2].active, starter.name .. ": voice 2 starts stopped")
    starter.start(context)  -- before the startup sleep ends
    assert_true(voices[2].active, starter.name .. ": started voice 2")
    finish_startup(context)
    assert_true(voices[2].active, starter.name .. ": voice 2 is still running after the startup clock")
    for _, call in ipairs(context.calls_named("voiceOff")) do
      assert_true(call.args[1] ~= 1, starter.name .. ": the startup clock sent no voiceOff for voice 2")
    end
  end
end)

test("init's start-up clock is stored, ends after starting voice 2 and is canceled by cleanup (#48)", function()
  local context = load_strata()
  assert_true(type(STARTUP.voice_delay_seconds) == "number" and STARTUP.voice_delay_seconds > 0,
    "STARTUP.voice_delay_seconds")
  assert_true(context.clock.threads[STARTUP.clock] ~= nil, "the start-up clock is stored and running")
  finish_startup(context)
  assert_true(local_value("voices")[2].active, "voice 2 started")
  assert_equal(STARTUP.clock, nil, "the clock is forgotten once it has ended")
  -- a script stopped before the delay ends starts nothing afterward
  context = load_strata()
  cleanup()
  assert_equal(STARTUP.clock, nil, "cleanup forgets the start-up clock")
  local voice_ons = #context.calls_named("voiceOn")
  context.clock.run_for(STARTUP.voice_delay_seconds + 0.1)
  assert_true(not local_value("voices")[2].active, "voice 2 not started after cleanup")
  assert_equal(#context.calls_named("voiceOn"), voice_ons, "no voiceOn after cleanup")
end)

test("scene capture -> change -> recall restores every voice", function()
  local context = load_strata()
  finish_startup(context)  -- let init start voice 2
  scramble_state(11)
  toggle_voice(3)
  toggle_freeze(1)
  toggle_pattern_step(4, 5)
  params:set("reverb_mix", 0.71)
  capture_scene(2)
  local scenes = local_value("scenes")
  local captured = deep_copy(scenes[2].data)
  assert_true(validate_scene_data(scenes), "a captured scene validates")

  scramble_state(99)
  toggle_voice(3)   -- off again
  toggle_voice(6)   -- on
  toggle_freeze(1)
  toggle_pattern_step(4, 5)
  params:set("reverb_mix", 0.1)

  context.clear_engine_calls()
  recall_scene(2, 0)
  local voices = local_value("voices")
  local frozen = local_value("frozen")
  local patterns = local_value("patterns")
  for voice_idx = 1, 7 do
    assert_voice_matches(voice_idx, voices[voice_idx], captured.voices[voice_idx])
    assert_equal(frozen[voice_idx], captured.frozen[voice_idx], "voice " .. voice_idx .. " frozen")
    for step = 1, 16 do
      assert_equal(patterns[voice_idx][step], captured.patterns[voice_idx][step], "pattern " .. voice_idx .. "/" .. step)
    end
  end
  assert_near(params:get("reverb_mix"), 0.71, 1e-9, "reverb mix")
  -- voice 3 was restarted by the recall: the engine got its recalled state
  local started = false
  for _, call in ipairs(context.calls_named("voiceOn")) do
    if call.args[1] == 2 then started = true end
  end
  assert_true(started, "recall started voice 3")
  for _, call in ipairs(context.calls_named("setModSource")) do
    if call.args[1] == 2 then
      local source = captured.voices[3].crossmod["slot" .. call.args[2]].source
      assert_equal(call.args[3], source == 0 and -1 or source - 1, "voice 3 mod source sent after recall")
    end
  end
end)

test("validate_scene_data rejects malformed scenes and accepts captured ones", function()
  load_strata()
  capture_scene(1)
  local scenes = local_value("scenes")
  local good = deep_copy(scenes)
  assert_true(validate_scene_data(good), "captured scenes are valid")

  local function rejects(mutator, message)
    local candidate = deep_copy(good)
    mutator(candidate[1].data, candidate)
    assert_true(not validate_scene_data(candidate), "should reject: " .. message)
  end
  rejects(function(data) data.frozen = nil end, "missing frozen")
  rejects(function(data) data.frozen[3] = nil end, "frozen entry missing")
  rejects(function(data) data.patterns[2][16] = nil end, "short pattern")
  rejects(function(data) data.patterns[7] = nil end, "missing pattern row")
  rejects(function(data) data.patterns[1][1] = "x" end, "non-numeric step")
  -- a step is a whole level 0..MAX_STEP_LEVEL
  rejects(function(data) data.patterns[1][1] = local_value("MAX_STEP_LEVEL") + 1 end, "step level past MAX_STEP_LEVEL")
  rejects(function(data) data.patterns[1][1] = 2.5 end, "fractional step level")
  rejects(function(data) data.patterns[1][1] = -1 end, "negative step level")
  rejects(function(data) data.master_density = "loud" end, "non-numeric master_density")
  rejects(function(data) data.tempo = nil end, "missing tempo")
  rejects(function(data) data.reverb_damp = {} end, "non-numeric reverb_damp")
  rejects(function(data) data.voices[7] = nil end, "missing voice")
  rejects(function(data) data.voices[2].crossmod.slot2 = nil end, "missing crossmod slot")
  rejects(function(data) data.voices[2].crossmod.slot1.source = 9 end, "out-of-range mod source")
  -- recall would send engine.setModSpeed with nil
  rejects(function(data) data.voices[4].crossmod.speed = nil end, "missing mod speed")
  rejects(function(data) data.voices[4].crossmod.speed = "fast" end, "non-numeric mod speed")
  rejects(function(data) data.voices[1].params.bogus = 1 end, "unknown voice param")
  rejects(function(data) data.voices[1].grain.size = "big" end, "non-numeric grain param")
  rejects(function(data, all) all[1].populated = "yes" end, "non-boolean populated")
  assert_true(not validate_scene_data("nope"), "should reject a non-table")
  assert_true(not validate_scene_data({ [3] = 7 }), "should reject a non-table slot")
end)

test("scene files: round trip, version check, missing slots, erroring file", function()
  local context = load_strata({ data_subdir = "roundtrip" })
  finish_startup(context)
  scramble_state(5)
  capture_scene(4)
  save_scenes_to_disk()
  local saved = deep_copy(local_value("scenes")[4].data)

  -- reload into a fresh script: auto-load in init restores the scene
  context = load_strata({ data_subdir = "roundtrip" })
  local scenes = local_value("scenes")
  assert_true(scenes[4].populated, "scene 4 reloaded from disk")
  assert_near(scenes[4].data.voices[1].params.freq, saved.voices[1].params.freq, 1e-9, "scene 4 data")
  for slot = 1, 8 do assert_true(scenes[slot] ~= nil, "slot " .. slot .. " exists") end
  local file_path = context.data_dir .. "strata/scenes.data"

  -- a file that raises an error when run must not break init
  local file = assert(io.open(file_path, "w"))
  file:write('error("corrupt scenes file")')
  file:close()
  context = load_strata({ data_subdir = "roundtrip" })
  scenes = local_value("scenes")
  for slot = 1, 8 do assert_true(scenes[slot] and scenes[slot].populated == false, "empty slot " .. slot) end
  load_scenes_from_disk()  -- the manual trigger survives it too

  -- wrong version is rejected
  file = assert(io.open(file_path, "w"))
  file:write(tabutil_text({ version = 99, scenes = {} }))
  file:close()
  context = load_strata({ data_subdir = "roundtrip" })
  local found = false
  for _, line in ipairs(context.printed) do
    if line:find("version 99") then found = true end
  end
  assert_true(found, "version mismatch reported")

  -- a pre-2.1 bare array with only some slots loads, missing slots filled
  local legacy = { [1] = { name = "scene 1", populated = false, data = {} } }
  legacy[2] = { name = "scene 2", populated = true, data = saved }
  context.tab.save(legacy, file_path)
  context = load_strata({ data_subdir = "roundtrip" })
  scenes = local_value("scenes")
  assert_true(scenes[2].populated, "legacy scene 2 loaded")
  for slot = 3, 8 do assert_true(scenes[slot] and scenes[slot].populated == false, "filled slot " .. slot) end
  recall_scene(2, 0)
  grid_redraw()
end)

test("a scenes file that fails to load survives cleanup (fix round 1)", function()
  local bad_files = {
    { name = "wrong version", content = tabutil_text({ version = 99, scenes = {} }) },
    { name = "raises on load", content = 'error("corrupt scenes file")' },
  }
  -- a versioned file with one bad slot (validate_scene_data rejects it whole)
  local context = load_strata({ data_subdir = "survive_source" })
  capture_scene(1)
  capture_scene(2)
  local scenes = deep_copy(local_value("scenes"))
  scenes[2].data.frozen = nil
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  local bad_slot_path = context.data_dir .. "bad_slot.data"
  context.tab.save({ version = 1, scenes = scenes }, bad_slot_path)
  local bad_slot_file = assert(io.open(bad_slot_path, "r"))
  table.insert(bad_files, { name = "one bad slot", content = bad_slot_file:read("*a") })
  bad_slot_file:close()

  for index, bad in ipairs(bad_files) do
    local subdir = "survive_" .. index
    local data_dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. data_dir .. "'")
    local file = assert(io.open(data_dir .. "scenes.data", "w"))
    file:write(bad.content)
    file:close()

    context = load_strata({ data_subdir = subdir })  -- init's load fails
    for slot = 1, 8 do
      assert_true(local_value("scenes")[slot].populated == false, bad.name .. ": scenes empty after failed load")
    end
    capture_scene(3)  -- new work after the failed load
    cleanup()
    local backup = io.open(data_dir .. "scenes.data.bak", "r")
    assert_true(backup ~= nil, bad.name .. ": original kept as scenes.data.bak")
    assert_equal(backup:read("*a"), bad.content, bad.name .. ": backup content unchanged")
    backup:close()
    -- the new save is a valid file again
    context = load_strata({ data_subdir = subdir })
    assert_true(local_value("scenes")[3].populated, bad.name .. ": new work saved on exit")
  end

  -- if the file cannot be moved aside, cleanup must not overwrite it
  local data_dir = data_root .. "survive_blocked/strata/"
  os.execute("mkdir -p '" .. data_dir .. "scenes.data.bak/occupied'")  -- rename target is a non-empty dir
  local file = assert(io.open(data_dir .. "scenes.data", "w"))
  file:write(bad_files[1].content)
  file:close()
  load_strata({ data_subdir = "survive_blocked" })
  cleanup()
  file = assert(io.open(data_dir .. "scenes.data", "r"))
  assert_equal(file:read("*a"), bad_files[1].content, "unmovable bad file not overwritten by cleanup")
  file:close()
end)

test("scene transitions crossfade linearly from snapshotted start values (I6)", function()
  local context = load_strata(); finish_startup(context)  -- finish init's start-up coroutine
  params:set("v1_freq", 1000)
  params:set("reverb_mix", 0.8)
  params:set("v2_mod_source_1", 3)
  capture_scene(1)
  params:set("v1_freq", 200)
  params:set("reverb_mix", 0.0)
  params:set("v2_mod_source_1", 0)

  recall_scene(1, 20)  -- 20 s over 20 steps; the first step runs immediately
  for step = 1, 19 do
    local mix = step / 20
    assert_near(params:get("v1_freq"), 200 + 800 * mix, 1.0, "freq at step " .. step)
    assert_near(params:get("reverb_mix"), 0.8 * mix, 0.0051, "reverb mix at step " .. step)
    assert_equal(params:get("v2_mod_source_1"), 0, "mod source switches only at the end")
    wake(context, "scene_transition_clock")
  end
  assert_near(params:get("v1_freq"), 1000, 1.0, "freq at the end")
  wake(context, "scene_transition_clock")
  assert_equal(params:get("v2_mod_source_1"), 3, "mod source set when the fade ends")
  assert_equal(local_value("scene_transition_active"), false, "transition finished")

  -- a second recall cancels a running transition and clears the flag
  params:set("v1_freq", 300)
  recall_scene(1, 10)
  assert_equal(local_value("scene_transition_active"), true, "transition running")
  recall_scene(1, 0)
  assert_equal(local_value("scene_transition_active"), false, "canceled transition clears the flag")
  assert_equal(local_value("scene_transition_clock"), nil, "canceled transition clock cleared")
  assert_near(params:get("v1_freq"), 1000, 1.0, "instant recall wins")
  context.clock.run_for(1)  -- longer than a step of the canceled 10 s fade
  assert_near(params:get("v1_freq"), 1000, 1.0, "canceled transition no longer writes")
end)

test("a smooth scene transition holds filter_type until the fade ends", function()
  local context = load_strata(); finish_startup(context)  -- finish init's start-up coroutine
  -- the filter freq fades, so setFilter goes out on every step
  params:set("filter_type", 3); params:set("filter_freq", 8000)
  capture_scene(1)
  params:set("filter_type", 1); params:set("filter_freq", 200)
  local function last_filter_type()
    local calls = context.calls_named("setFilter")
    return calls[#calls].args[3]
  end

  recall_scene(1, 20)  -- 20 steps; the first runs immediately, the switch after the last
  for step = 1, 20 do
    assert_equal(params:get("filter_type"), 1, "filter_type at step " .. step)
    assert_equal(last_filter_type(), 0, "engine filter type at step " .. step)
    wake(context, "scene_transition_clock")
  end
  assert_equal(local_value("scene_transition_active"), false, "transition finished")
  assert_equal(params:get("filter_type"), 3, "filter_type lands on the target")
  assert_equal(last_filter_type(), 2, "engine filter type lands on the target")
  assert_near(params:get("filter_freq"), 8000, 1.0, "the filter freq faded to its target")
end)

test("a smooth transition fades LFO depths in whole percents and ends on the scene's exact depth", function()
  local context = load_strata()
  params:set("lfo_depth_1", 75); params:set("lfo_depth_2", 37.5)   -- a file may hold any number
  capture_scene(1)
  params:set("lfo_depth_1", 0); params:set("lfo_depth_2", 100)

  recall_scene(1, 20)  -- 20 steps; the first runs immediately
  for step = 1, 20 do
    local mix = step / 20
    for n, fade in ipairs({ { from = 0, to = 75 }, { from = 100, to = 37.5 } }) do
      local depth = params:get("lfo_depth_" .. n)
      assert_equal(depth, math.floor(depth), "LFO " .. n .. " depth is a whole percent at step " .. step)
      assert_near(depth, fade.from + (fade.to - fade.from) * mix, 0.5, "LFO " .. n .. " depth at step " .. step)
    end
    wake(context, "scene_transition_clock")
  end
  assert_equal(local_value("scene_transition_active"), false, "transition finished")
  assert_equal(params:get("lfo_depth_1"), 75, "LFO 1 ends on the scene's depth")
  assert_equal(params:get("lfo_depth_2"), 37.5, "LFO 2 ends on the scene's exact depth")
end)

-- Loading scenes replaces every slot: a transition that is running must not
-- apply the slot's new data (or fail on a slot that is now empty) when it ends
for _, slot_on_disk in ipairs({ "empty", "other" }) do
  test("loading scenes from disk during a transition (its slot on disk: " .. slot_on_disk .. ")", function()
    local context = load_strata(); finish_startup(context)
    local voices = local_value("voices")
    if slot_on_disk == "other" then
      params:set("v1_freq", 500); toggle_voice(3); capture_scene(1); toggle_voice(3)
    end
    save_scenes_to_disk()
    params:set("v1_freq", 1000); params:set("v4_grain_mode", 2); capture_scene(1)
    params:set("v1_freq", 200); params:set("v4_grain_mode", 1)

    recall_scene(1, 4)
    context.clock.run_for(1, 0.001)
    local faded = params:get("v1_freq")
    assert_true(faded > 200 and faded < 1000, "the fade is under way")
    load_scenes_from_disk()
    assert_equal(local_value("scenes")[1].populated, slot_on_disk == "other", "slot 1 loaded from disk")
    local ran, run_error = pcall(context.clock.run_for, 5, 0.001)
    assert_true(ran, "the transition's end raised no error: " .. tostring(run_error))
    assert_equal(local_value("scene_transition_active"), false, "no transition left running")
    assert_equal(params:get("v1_freq"), faded, "the canceled fade applied nothing more")
    assert_equal(params:get("v4_grain_mode"), 1, "nor the old scene's discrete state")
    assert_true(not voices[3].active, "nor the new slot's voices")
  end)
end

test("capturing the scene a transition fades to keeps the fade's target (#48)", function()
  local context = load_strata(); finish_startup(context)
  params:set("filter_freq", 8000); params:set("v4_grain_mode", 2); capture_scene(2)
  params:set("filter_freq", 200); params:set("v4_grain_mode", 1)
  recall_scene(2, 10)
  context.clock.run_for(5, 0.001)
  local halfway = params:get("filter_freq")
  assert_true(halfway > 200 and halfway < 8000, "the fade is under way")
  capture_scene(2)                                    -- the half-faded state, into scene 2
  assert_equal(local_value("scenes")[2].data.filter_freq, halfway, "scene 2 holds the half-faded state")
  context.clock.run_for(6, 0.001)
  assert_equal(local_value("scene_transition_active"), false, "the transition ended")
  assert_near(params:get("filter_freq"), 8000, 1.0, "it ended on the scene it was recalled with")
  assert_equal(params:get("v4_grain_mode"), 2, "with that scene's discrete state")
end)

-- Two scenes for the sequencer: scene 2 starts voice 3 in triggered grain
-- mode (both switch only when a transition ends), scene 1 has it stopped
local function capture_sequencer_scenes()
  local voices = local_value("voices")
  if voices[3].active then toggle_voice(3) end
  params:set("v3_grain_mode", 1); capture_scene(1)
  toggle_voice(3); params:set("v3_grain_mode", 2); capture_scene(2)
  toggle_voice(3); params:set("v3_grain_mode", 1)
  params:set("scene_sequence_length", 2)
  return voices
end

-- Run the scene sequencer time-ordered with a scheduling delay per wake-up
-- (`latency`, 1 ms unless given: the fade's 20 sleeps fall behind one long
-- sleep, as on norns).
-- Returns the list of recalls (it keeps growing while the test runs the
-- clocks on; the next load_strata defines recall_scene afresh): scene,
-- seconds since the sequencer started and whether a transition was still
-- running (the recall would cancel it)
local function run_scene_sequencer(context, transition, duration, seconds, latency)
  local recalls = {}
  local real_recall = recall_scene
  local start = util.time()
  recall_scene = function(scene_num, transition_time)
    table.insert(recalls, { scene = scene_num, time = util.time() - start,
      interrupts = local_value("scene_transition_active") })
    return real_recall(scene_num, transition_time)
  end
  params:set("scene_transition_time", transition); params:set("scene_duration", duration)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(seconds, latency or 0.001)
  return recalls
end

for _, case in ipairs({ { transition = 20, duration = 16 }, { transition = 16, duration = 16 } }) do
  test(string.format("the scene sequencer lets a %d s transition finish with a %d s scene duration",
    case.transition, case.duration), function()
    local context = load_strata(); finish_startup(context)
    local voices = capture_sequencer_scenes()
    local period = math.max(case.transition, case.duration)
    local recalls = run_scene_sequencer(context, case.transition, case.duration, period + 1)
    assert_equal(#recalls, 2, "scene 2 recalled once scene 1's transition ended")
    assert_equal(recalls[2].scene, 2, "the sequencer moved on to scene 2")
    assert_true(not recalls[2].interrupts, "scene 1's transition was not cut short")
    assert_true(recalls[2].time >= case.transition, "scene 2 recalled after scene 1's transition")
    assert_true(recalls[2].time < period + 0.1, "the sequencer moved on as soon as it ended")
    assert_true(not voices[3].active, "voice 3 waits for the end of scene 2's transition")
    context.clock.run_for(period, 0.001)                   -- scene 2's transition ends
    assert_true(voices[3].active, "voice 3 started at the end of scene 2's transition")
    assert_equal(params:get("v3_grain_mode"), 2, "grain mode switched at the end of the transition")
    assert_equal(#recalls, 3, "then the sequencer moved on to scene 1")
    context.clock.run_for(period, 0.001)                   -- back to scene 1, which ends too
    assert_true(not voices[3].active, "scene 1 stopped voice 3 again")
    for index, recall in ipairs(recalls) do
      assert_true(not recall.interrupts, "recall " .. index .. " cut no transition short")
    end
    assert_equal(params:get("v3_grain_mode"), 1, "scene 1's grain mode")
  end)
end

-- Under load every wake-up runs late: a fade's 21 wake-ups add 60 ms each,
-- so it ends well over a second after its transition time. It is still
-- progressing, so the sequencer must wait for it, not cancel it
test("the scene sequencer lets a 16 s transition finish when every wake-up runs 60 ms late (#48)", function()
  local context = load_strata(); finish_startup(context)
  local voices = capture_sequencer_scenes()
  local latency = 0.06
  local recalls = run_scene_sequencer(context, 16, 16, 18, latency)
  assert_equal(#recalls, 2, "scene 2 recalled once scene 1's transition ended")
  assert_true(recalls[2].time > 16 + local_value("SCENE_TRANSITION").overrun_seconds,
    "scene 1's transition ran past the overrun margin")
  assert_true(not recalls[2].interrupts, "scene 1's transition was not cut short")
  context.clock.run_for(18, latency)
  assert_true(voices[3].active, "voice 3 started at the end of scene 2's transition")
  assert_equal(params:get("v3_grain_mode"), 2, "scene 2's grain mode")
  assert_true(not table.concat(context.printed, "\n"):find("overran", 1, true), "no transition reported as overrun")
end)

test("the scene sequencer holds a scene for its duration when the transition is shorter", function()
  local context = load_strata(); finish_startup(context)
  local voices = capture_sequencer_scenes()
  local recalls = run_scene_sequencer(context, 10, 16, 43)
  assert_equal(#recalls, 3, "a recall every 16 s")
  assert_near(recalls[2].time, 16, 0.01, "scene 2 after the scene duration")
  assert_near(recalls[3].time, 32, 0.02, "scene 1 after another scene duration")
  assert_true(not voices[3].active, "scene 1's transition has ended")
end)

-- A transition is stuck once its next step is SCENE_TRANSITION.overrun_seconds
-- late (SCENE_TRANSITION.next_step_due: util.time() when it is due)
test("the scene sequencer moves on when a transition never finishes", function()
  local context = load_strata(); finish_startup(context)
  capture_sequencer_scenes()
  local overrun = local_value("SCENE_TRANSITION").overrun_seconds
  assert_true(type(overrun) == "number" and overrun > 0, "SCENE_TRANSITION.overrun_seconds")
  -- stuck early on: the sequencer moves on as soon as the scene's hold ends
  local recalls = run_scene_sequencer(context, 4, 4, 1)          -- scene 1's 4 s transition is running
  assert_true(local_value("scene_transition_active"), "scene 1's transition is running")
  clock.cancel(local_value("scene_transition_clock"))            -- its clock is lost: the flag stays set
  context.clock.run_for(3.5, 0.001)
  assert_equal(#recalls, 2, "the sequencer moved on")
  assert_equal(recalls[2].scene, 2, "to scene 2")
  assert_near(recalls[2].time, 4, 0.05, "when the scene's hold ended")
  assert_true(not recalls[2].interrupts, "the stuck transition was cleared first")
  assert_true(table.concat(context.printed, "\n"):find("scene transition overran", 1, true), "reported")
  context.clock.run_for(4.5, 0.001)
  assert_true(local_value("voices")[3].active, "scene 2's transition ended normally")

  -- stuck just before its end: the sequencer waits until its next step is overrun_seconds late
  context = load_strata(); finish_startup(context)
  capture_sequencer_scenes()
  recalls = run_scene_sequencer(context, 4, 4, 3.9)              -- scene 1's last step has run
  local started = util.time() - 3.9                              -- recall times count from here
  local due = local_value("SCENE_TRANSITION").next_step_due - started
  assert_true(due > 4, "the transition's end is due after the scene's hold")
  clock.cancel(local_value("scene_transition_clock"))
  context.clock.run_for(overrun + 0.5, 0.001)
  assert_equal(#recalls, 2, "the sequencer moved on")
  assert_near(recalls[2].time, due + overrun, 0.05, "once the transition's end was overrun_seconds late")
  assert_true(not recalls[2].interrupts, "the stuck transition was cleared first")
end)

test("the scene sequencer waits for a manual transition it did not start, within a bound", function()
  local context = load_strata(); finish_startup(context)
  local voices = capture_sequencer_scenes()
  local overrun = local_value("SCENE_TRANSITION").overrun_seconds
  local recalls = run_scene_sequencer(context, 0, 4, 1)           -- instant recalls every 4 s
  recall_scene(2, 25)                                              -- a manual 25 s transition
  context.clock.run_for(24, 0.001)
  assert_equal(#recalls, 2, "the sequencer waits for the manual transition")
  context.clock.run_for(1.5, 0.001)
  assert_true(voices[3].active, "the manual transition ended and applied scene 2")
  assert_equal(#recalls, 3, "then the sequencer moved on")
  assert_true(not recalls[3].interrupts, "without cutting it short")
  -- a manual transition that gets stuck is canceled once its next step is overrun_seconds late
  recall_scene(2, 25)
  local started = util.time() - recalls[#recalls].time           -- recall times count from here
  context.clock.run_for(10, 0.001)                                 -- the sequencer is waiting for it
  assert_equal(#recalls, 4, "the sequencer waits for the second manual transition")
  local due = local_value("SCENE_TRANSITION").next_step_due - started
  clock.cancel(local_value("scene_transition_clock"))
  context.clock.run_for(overrun + 2, 0.001)
  assert_equal(#recalls, 5, "the sequencer moved on after the bound")
  assert_near(recalls[5].time, due + overrun, 0.05, "once its next step was overrun_seconds late")
  assert_true(not recalls[5].interrupts, "the stuck transition was cleared first")
end)

-- A sequenced recall that fails validation starts no transition: a manual
-- transition still running is not the sequencer's, and is not cut short
test("a sequenced scene that fails validation leaves a manual transition running (#48)", function()
  local context = load_strata(); finish_startup(context)
  local voices = capture_sequencer_scenes()
  local_value("scenes")[1].data.patterns = nil                    -- scene 1 no longer validates
  recall_scene(2, 25)                                              -- a manual 25 s transition
  local recalls = run_scene_sequencer(context, 2, 4, 24)           -- scene 1 (invalid), held 4 s
  assert_equal(recalls[1].scene, 1, "the sequencer tried scene 1")
  assert_true(table.concat(context.printed, "\n"):find("scene 1 has invalid data", 1, true), "reported invalid")
  assert_equal(#recalls, 1, "the sequencer waits for the manual transition")
  assert_true(local_value("scene_transition_active"), "the manual transition is still running")
  context.clock.run_for(1.5, 0.001)
  assert_true(voices[3].active, "the manual transition ended and applied scene 2")
  assert_equal(#recalls, 2, "then the sequencer moved on")
  assert_true(not recalls[2].interrupts, "without cutting it short")
  assert_true(not table.concat(context.printed, "\n"):find("overran", 1, true), "nothing reported as overrun")
end)

test("an error inside a scene transition's fade clears the transition flag", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_freq", 1000); capture_scene(1); params:set("v1_freq", 200)
  params:set_action("v1_freq", function() error("fade failed") end)
  local ok, message = pcall(recall_scene, 1, 4)                  -- the first step runs at once
  assert_true(not ok and tostring(message):find("fade failed", 1, true), "the error is raised")
  -- with the traceback of where the param action failed (maiden shows it)
  local traceback = tostring(message):match("stack traceback:.*")
  assert_true(traceback and traceback:find("run.lua:%d+"), "the raised error keeps its traceback: " .. tostring(message))
  assert_equal(local_value("scene_transition_active"), false, "flag cleared")
  assert_equal(local_value("scene_transition_clock"), nil, "clock cleared")
  -- an error in a later step
  params:set_action("v1_freq", function() end)
  recall_scene(1, 4)
  params:set_action("v1_freq", function() error("fade failed") end)
  wake(context, "scene_transition_clock")                                        -- the scheduler reports the error
  local errors = context.clock.take_errors()
  assert_true(#errors == 1 and errors[1]:find("fade failed", 1, true), "the later error is raised")
  traceback = errors[1]:match("stack traceback:.*")
  assert_true(traceback and traceback:find("run.lua:%d+"), "a later step's error keeps its traceback")
  assert_equal(local_value("scene_transition_active"), false, "flag cleared after a later step")
  assert_equal(local_value("scene_transition_clock"), nil, "clock cleared after a later step")
end)

-- An error in a sequenced recall (here the first step of its fade, which
-- runs inside the sequencer's own clock) is reported and the sequencer
-- keeps going: the recall has already cleared its transition state
test("an error in a sequenced recall is reported and the scene sequencer keeps going", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_freq", 1000); capture_scene(1)
  params:set("v1_freq", 400); capture_scene(2)
  params:set("v1_freq", 200); params:set("scene_sequence_length", 2)
  local freq_param = params:lookup_param("v1_freq")
  local real_action, failures = freq_param.action, 1
  freq_param.action = function(value)
    if failures > 0 then failures = failures - 1; error("fade failed") end
    return real_action(value)
  end
  local ran, run_error = pcall(run_scene_sequencer, context, 2, 4, 1)  -- scene 1's first step fails
  assert_true(ran, "the error did not escape the sequencer: " .. tostring(run_error))
  local printed = table.concat(context.printed, "\n")
  assert_true(printed:find("fade failed", 1, true), "the error is printed")
  assert_true(printed:find("stack traceback:", 1, true), "with its traceback")
  assert_equal(params:get("scene_sequencer_enabled"), 1, "the sequencer param stays on")
  assert_true(context.clock.threads[local_value("scene_sequencer_clock")] ~= nil, "its clock is still running")
  assert_true(not local_value("scene_transition_active"), "no transition left flagged")
  ran, run_error = pcall(context.clock.run_for, 6, 0.001)
  assert_true(ran, "the sequencer runs on: " .. tostring(run_error))
  assert_equal(local_value("current_scene"), 2, "it recalled scene 2 after scene 1's duration")
  assert_near(params:get("v1_freq"), 400, 1.0, "and scene 2's transition ended")
end)

test("a failing instant sequenced recall is reported and the scene sequencer holds the scene, then goes on (#50)", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_freq", 1000); capture_scene(1)
  params:set("v1_freq", 400); capture_scene(2)
  params:set("v1_freq", 200); params:set("scene_sequence_length", 2)
  local freq_param = params:lookup_param("v1_freq")
  local real_action, failures = freq_param.action, 1
  freq_param.action = function(value)
    if failures > 0 then failures = failures - 1; error("recall failed") end
    return real_action(value)
  end
  local ran, recalls = pcall(run_scene_sequencer, context, 0, 4, 1)  -- scene 1's instant recall fails
  assert_true(ran, "the error did not escape the sequencer: " .. tostring(recalls))
  assert_equal(#recalls, 1, "one recall so far")
  local printed = table.concat(context.printed, "\n")
  assert_true(printed:find("scene sequencer: scene 1 failed", 1, true), "the failure is printed")
  assert_true(printed:find("recall failed", 1, true) and printed:find("stack traceback:", 1, true),
    "with the error and its traceback")
  assert_equal(params:get("scene_sequencer_enabled"), 1, "the sequencer param stays on")
  assert_true(context.clock.threads[local_value("scene_sequencer_clock")] ~= nil, "its clock is still running")
  assert_true(not local_value("scene_recall_in_progress"), "no recall left flagged")
  assert_true(not local_value("scene_transition_active"), "no transition left flagged")
  local run_error
  ran, run_error = pcall(context.clock.run_for, 4, 0.001)
  assert_true(ran, "the sequencer runs on: " .. tostring(run_error))
  assert_equal(#recalls, 2, "it recalled once more")
  assert_equal(recalls[2].scene, 2, "scene 2")
  assert_near(recalls[2].time, 4, 0.01, "after holding the failed scene for its duration")
  assert_equal(local_value("current_scene"), 2, "scene 2 recalled")
  assert_near(params:get("v1_freq"), 400, 1.0, "and applied at once")
end)

test("a manual recall still interrupts a transition the scene sequencer started", function()
  local context = load_strata(); finish_startup(context)
  local voices = capture_sequencer_scenes()
  local recalls = run_scene_sequencer(context, 20, 16, 25)       -- scene 2's transition is running
  assert_equal(recalls[#recalls].scene, 2, "the sequencer recalled scene 2")
  assert_true(local_value("scene_transition_active"), "scene 2's transition is running")
  recall_scene(2, 0)                                             -- a manual instant recall
  assert_true(not local_value("scene_transition_active"), "the manual recall canceled the transition")
  assert_true(voices[3].active, "and applied scene 2 at once")
  context.clock.run_for(16, 0.001)                               -- the sequencer keeps going
  assert_equal(local_value("current_scene"), 1, "the sequencer moved on to scene 1")
end)

test("shortening the sequence while the sequencer waits wraps to scene 1", function()
  local context = load_strata(); finish_startup(context)
  for scene = 1, 4 do capture_scene(scene) end
  params:set("scene_sequence_length", 4)
  local recalls = run_scene_sequencer(context, 0, 4, 9)          -- scene 3 is playing
  assert_equal(recalls[#recalls].scene, 3, "the sequencer reached scene 3")
  params:set("scene_sequence_length", 2)                         -- scene 3 is now past the end
  context.clock.run_for(4, 0.001)
  assert_equal(recalls[#recalls].scene, 1, "the sequencer wrapped to scene 1")
  context.clock.run_for(8, 0.001)
  assert_equal(recalls[#recalls - 1].scene, 2, "then played scene 2")
  assert_equal(recalls[#recalls].scene, 1, "and wrapped again")
end)

test("restarting the scene sequencer leaves one sequencer clock running", function()
  local context = load_strata(); finish_startup(context)
  capture_sequencer_scenes()
  local recalls = run_scene_sequencer(context, 0, 4, 1)          -- scene 1 at 0 s
  local first_clock = local_value("scene_sequencer_clock")
  scene_sequencer_start()                                        -- restart at 1 s: scene 1 again
  assert_true(context.clock.threads[first_clock] == nil, "the first sequencer clock was canceled")
  context.clock.run_for(8.5, 0.001)
  assert_equal(#recalls, 4, "one recall every 4 s from the restart")
  assert_near(recalls[3].time, 5, 0.01, "scene 2 4 s after the restart")
  assert_near(recalls[4].time, 9, 0.01, "scene 1 4 s later")
  assert_equal(recalls[3].scene, 2); assert_equal(recalls[4].scene, 1)
end)

test("stopping and restarting the scene sequencer while it waits for a transition leaves one clock (#50)", function()
  local context = load_strata(); finish_startup(context)
  capture_sequencer_scenes()
  local recalls = run_scene_sequencer(context, 0, 4, 1)           -- instant recalls every 4 s
  recall_scene(2, 25)                                              -- a manual 25 s transition
  context.clock.run_for(4, 0.001)                                  -- the sequencer waits for it
  assert_equal(#recalls, 2, "the sequencer is waiting inside wait_for_scene_transition")
  local waiting_clock = local_value("scene_sequencer_clock")
  params:set("scene_sequencer_enabled", 0)
  assert_true(context.clock.threads[waiting_clock] == nil, "stopping cancels the waiting clock")
  context.clock.run_for(1, 0.001)
  assert_equal(#recalls, 2, "a stopped sequencer recalls nothing")
  params:set("scene_sequencer_enabled", 1)                         -- restart at 6 s: scene 1 again
  context.clock.run_for(8.5, 0.001)
  assert_equal(#recalls, 5, "one recall every 4 s from the restart, from one clock")
  for index, expected in ipairs({ { scene = 1, time = 6 }, { scene = 2, time = 10 }, { scene = 1, time = 14 } }) do
    local recall = recalls[2 + index]
    assert_equal(recall.scene, expected.scene, "recall " .. (2 + index) .. " scene")
    assert_near(recall.time, expected.time, 0.01, "recall " .. (2 + index) .. " time")
  end
  assert_true(not table.concat(context.printed, "\n"):find("overran", 1, true), "the old wait never resumed")
end)

-- A PSET load (norns' params:read, from the PARAMS menu) sets params in file
-- order. scene_sequencer_enabled comes before the transition time, FX, LFO
-- and voice params, so a sequencer started inside the read would recall
-- scene 1 with the old transition time and then have the PSET overwrite it
test("a PSET read that turns the scene sequencer on starts it once the read has finished", function()
  local context = load_strata(); finish_startup(context)
  params:set("reverb_mix", 0.9); params:set("v1_freq", 1000); capture_scene(1)
  -- the PSET: the sequencer on, a 4 s transition and other values
  params:set("reverb_mix", 0.2); params:set("v1_freq", 300)
  params:set("scene_transition_time", 4); params:set("scene_duration", 30)
  params:set("scene_sequencer_enabled", 1, true)                 -- saved on, not started
  local pset_path = context.data_dir .. "strata-01.pset"
  params:write(pset_path)
  params:set("scene_sequencer_enabled", 0, true)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("reverb_mix", 0.5); params:set("v1_freq", 500)

  local recalls = {}
  local real_recall = recall_scene
  recall_scene = function(scene_num, transition_time)
    table.insert(recalls, { scene = scene_num, transition = transition_time, reverb = params:get("reverb_mix") })
    return real_recall(scene_num, transition_time)
  end
  params:read(pset_path)
  assert_equal(#recalls, 0, "no scene recalled while the PSET was being read")
  assert_equal(params:get("scene_sequencer_enabled"), 1, "the PSET turned the sequencer on")
  context.clock.run_for(5, 0.001)
  assert_equal(#recalls, 1, "the sequencer recalled scene 1 after the read")
  assert_equal(recalls[1].scene, 1, "scene 1")
  assert_equal(recalls[1].transition, 4, "with the PSET's transition time")
  assert_near(recalls[1].reverb, 0.2, 1e-9, "fading from the PSET's values")
  assert_near(params:get("reverb_mix"), 0.9, 1e-9, "scene 1's reverb after the transition")
  assert_near(params:get("v1_freq"), 1000, 1.0, "scene 1's voice 1 freq after the transition")
end)

test("scene recall: one full sync per voice whose source changed, after its params", function()
  -- every engine call since the script loaded, for each running voice, must
  -- leave the engine with the voice's Lua state
  local function assert_engine_has_lua_state(context, where)
    local voices = local_value("voices")
    local master = params:get("master_density")
    for voice_idx = 1, 7 do
      local voice = voices[voice_idx]
      if voice.active then
        local label = where .. ": voice " .. voice_idx .. " "
        local sent = engine_state_for_voice(context.engine_calls, voice_idx - 1)
        for key, value in pairs(voice.params) do
          assert_near(sent.voice[key], value, 1e-9, label .. key)
        end
        assert_near(sent.grain.grainSize, voice.grain.size, 1e-9, label .. "grainSize")
        assert_near(sent.grain.grainDensity, voice.grain.density * master, 1e-9, label .. "grainDensity")
        assert_near(sent.grain.pitchShift, voice.grain.pitch, 1e-9, label .. "pitchShift")
        assert_near(sent.grain.posSpread, voice.grain.spread, 1e-9, label .. "posSpread")
        assert_equal(sent.grain.envShape, voice.grain.env - 1, label .. "envShape")
        assert_equal(sent.grain.grainMode, voice.grain.mode - 1, label .. "grainMode")
        assert_near(sent.grain.bufPos, voice.grain.buf_pos, 1e-9, label .. "bufPos")
        assert_near(sent.grain.bufRate, voice.grain.buf_rate, 1e-9, label .. "bufRate")
        assert_near(sent.grain.bufScan, voice.grain.buf_scan, 1e-9, label .. "bufScan")
        for slot = 1, 3 do
          local slot_state = voice.crossmod["slot" .. slot]
          assert_equal(sent.source[slot], slot_state.source == 0 and -1 or slot_state.source - 1, label .. "mod source " .. slot)
          assert_near(sent.amp_amt[slot], slot_state.amp_amt, 1e-9, label .. "amp mod " .. slot)
          assert_near(sent.freq_amt[slot], slot_state.freq_amt, 1e-9, label .. "freq mod " .. slot)
        end
        assert_near(sent.speed, voice.crossmod.speed, 1e-9, label .. "mod speed")
        local grain_sources = {}
        for _, call in ipairs(context.calls_named("setGrainSource")) do
          if call.args[1] == voice_idx - 1 then table.insert(grain_sources, call.args[2]) end
        end
        assert_equal(grain_sources[#grain_sources], voice.source - 1, label .. "grain source")
      end
    end
  end
  -- a full sync (sync_voice_values_to_engine) ends with the voice's bend.
  -- MIDI pitchbend also sends setVoiceParam "bend", so this test must not
  -- send any pitchbend, or it would count as a sync
  local function full_syncs(context, first_call, engine_voice)
    local count, last_sync, last_call = 0, nil, nil
    for index = first_call, #context.engine_calls do
      local call = context.engine_calls[index]
      if call.args[1] == engine_voice then
        last_call = index
        if call.name == "setVoiceParam" and call.args[2] == "bend" then
          count = count + 1; last_sync = index
        end
      end
    end
    return count, last_sync, last_call
  end

  for _, transition_time in ipairs({ 0, 4 }) do
    local where = transition_time == 0 and "instant recall" or "smooth transition"
    local context = load_strata(); finish_startup(context)
    local voices = local_value("voices")
    for voice_idx = 1, 7 do
      if voices[voice_idx].active ~= (voice_idx <= 3) then toggle_voice(voice_idx) end
    end
    scramble_state(11)
    params:set("v1_source", 1); params:set("v2_source", 3)
    capture_scene(1)                     -- voices 1-3 running, v1 synth, v2 buf 2
    scramble_state(23)
    params:set("v1_source", 4)           -- v1's source differs from the scene's
    params:set("v2_source", 3)           -- v2's is the scene's
    toggle_voice(3); toggle_voice(4)     -- the recall starts voice 3 and stops voice 4

    local first_call = #context.engine_calls + 1
    recall_scene(1, transition_time)
    context.clock.run_for(transition_time + 1)
    assert_equal(local_value("scene_transition_active"), false, where .. " finished")

    local syncs, last_sync, last_call = full_syncs(context, first_call, 0)
    assert_equal(syncs, 1, where .. ": voice 1 (source changed) gets one full sync")
    assert_equal(last_sync, last_call, where .. ": voice 1's full sync comes after its recalled params")
    assert_equal((full_syncs(context, first_call, 1)), 0, where .. ": voice 2 (same source) gets no full sync")
    assert_equal((full_syncs(context, first_call, 2)), 1, where .. ": voice 3 (started) gets toggle_voice's sync only")
    assert_equal((full_syncs(context, first_call, 3)), 0, where .. ": voice 4 (stopped) gets none")
    assert_equal(local_value("scene_recall_in_progress"), false, where .. ": flag cleared")
    assert_engine_has_lua_state(context, where)
  end
end)

test("a scene recall stops a voice before switching its source (#46)", function()
  -- scenes A = voice 1 on/synth, B = off/input, C = on/buffer 1, recalled
  -- A -> B -> A -> C: only C's switch may reach a running voice. A switch
  -- sent before B's voiceOff would build an input grain synth only to
  -- release it at once, and leave the engine more synths than its bound
  for _, transition_time in ipairs({ 0, 4 }) do
    local where = transition_time == 0 and "instant recalls" or "smooth transitions"
    local context = load_strata(); finish_startup(context)   -- voices 1 and 2 running
    params:set("v1_source", 1); capture_scene(1)
    toggle_voice(1); params:set("v1_source", 10); params:set("v1_amp", 0.123); capture_scene(2)
    toggle_voice(1); params:set("v1_source", 2); params:set("v1_amp", 0.3); capture_scene(3)
    recall_scene(1, 0)
    context.clear_engine_calls()
    local scene_b_calls = {}
    for _, scene in ipairs({ 2, 1, 3 }) do
      local first_call = #context.engine_calls + 1
      recall_scene(scene, transition_time)
      context.clock.run_for(transition_time + 1)
      if scene == 2 then
        for index = first_call, #context.engine_calls do
          local call = context.engine_calls[index]
          if call.args[1] == 0 then table.insert(scene_b_calls, call.name) end
        end
      end
    end
    -- replay voice 1's calls on a model of the engine (running, on its synth)
    local running, source, replacements, order = true, 0, 0, {}
    for _, call in ipairs(context.engine_calls) do
      if call.args[1] == 0 then
        if call.name == "voiceOn" then running = true; table.insert(order, "on")
        elseif call.name == "voiceOff" then running = false; table.insert(order, "off")
        elseif call.name == "setGrainSource" and call.args[2] ~= source then
          if running then replacements = replacements + 1 end
          source = call.args[2]
          table.insert(order, "source " .. source)
        end
      end
    end
    assert_equal(table.concat(order, ", "), "off, source 9, source 0, on, source 1",
      where .. ": B stops voice 1 before its source switch, A switches it before starting it")
    assert_equal(replacements, 1, where .. ": only C's switch replaces a running voice's grain synth")
    -- an instant B stops voice 1 before setting its params (B's amp), so its
    -- release tail keeps A's values (a smooth one fades them in first)
    if transition_time == 0 then
      assert_equal(table.concat(scene_b_calls, ", "), "voiceOff, setGrainSource",
        where .. ": B sends voice 1 only its stop and its source")
    end
    assert_equal(local_value("voices")[1].active, true, where .. ": voice 1 ends running")
    assert_equal(local_value("voices")[1].source, 2, where .. ": on buffer 1")
  end
end)

test("an error during a scene recall clears scene_recall_in_progress and is raised", function()
  local context = load_strata(); finish_startup(context)   -- voices 1 and 2 running
  local function voice1_full_syncs()
    local bends = 0
    for _, call in ipairs(context.calls_named("setVoiceParam")) do
      if call.args[1] == 0 and call.args[2] == "bend" then bends = bends + 1 end
    end
    return bends
  end
  -- the scene has voice 1 on buffer 2; voice 2's mod speed action fails
  -- after voice 1's source has switched
  params:set("v1_source", 3); params:set("v2_mod_speed", 3); capture_scene(1)
  params:set("v1_source", 1); params:set("v2_mod_speed", 7)
  params:set_action("v2_mod_speed", function() error("mod speed action failed") end)
  context.clear_engine_calls()
  local ok, recall_error = pcall(recall_scene, 1, 0)
  assert_true(not ok, "the error reaches the caller")
  assert_true(tostring(recall_error):find("mod speed action failed", 1, true), "the original error: " .. tostring(recall_error))
  local traceback = tostring(recall_error):match("stack traceback:.*")
  assert_true(traceback and traceback:find("run.lua:%d+"), "the raised error keeps its traceback")
  assert_equal(local_value("scene_recall_in_progress"), false, "flag cleared after the error")
  assert_equal(local_value("voices")[1].source, 3, "voice 1's source switched before the error")
  assert_equal(voice1_full_syncs(), 1, "the switched running voice still gets its end-of-recall sync")
  -- the source action syncs a running voice again
  context.clear_engine_calls(); params:set("v1_source", 1)
  assert_equal(voice1_full_syncs(), 1, "a later source switch sends its full sync")
end)

local text_width = stubs.text_width

local function text_span(entry)
  local width = text_width(entry.text)
  if entry.align == "right" then return entry.x - width, entry.x end
  if entry.align == "center" then return entry.x - width / 2, entry.x + width / 2 end
  return entry.x, entry.x + width
end

local PAGE_TITLES = { "MAIN", "FX", "LFO", "BUFFER", "SETUP" }
local HINT_ROW_Y = 62
local TEXT_HEIGHT = 6   -- 04B_03 glyph height plus one row of spacing
-- MAIN: the voice list ends at x 60, left of the divider at 62; the selected
-- voice's details start at x 65
local MAIN_LIST_RIGHT = 60
local MAIN_DETAILS_LEFT = 65

local function show_page(page)
  enc(1, page - local_value("ui_page"))
  redraw()
end

-- Check the drawn screen: everything inside 128x64, no two strings overlap on
-- a row, the page title at 0,8 with dens: at least 4 px after it, and a hint
-- row at y 62.
local function assert_screen_layout(context, where)
  local rows = {}
  for _, entry in ipairs(context.screen.texts) do
    local left, right = text_span(entry)
    assert_true(left >= 0 and right <= 128 and entry.y <= 64,
      string.format("'%s' at %d,%d leaves the screen (%s)", entry.text, entry.x, entry.y, where))
    rows[entry.y] = rows[entry.y] or {}
    for _, other in ipairs(rows[entry.y]) do
      assert_true(right <= other.left or left >= other.right,
        string.format("'%s' overlaps '%s' on row %d (%s)", entry.text, other.text, entry.y, where))
    end
    table.insert(rows[entry.y], { left = left, right = right, text = entry.text })
    -- between the header and the hint row, MAIN text stays in its column
    if local_value("ui_page") == 1 and entry.y > 8 and entry.y < HINT_ROW_Y then
      assert_true(right <= MAIN_LIST_RIGHT or left >= MAIN_DETAILS_LEFT,
        string.format("'%s' at %d,%d crosses the MAIN divider (%s)", entry.text, entry.x, entry.y, where))
    end
  end
  local title = PAGE_TITLES[local_value("ui_page")]
  local title_right, density_left, hint_found
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == title and entry.x == 0 and entry.y == 8 then title_right = select(2, text_span(entry)) end
    if entry.text:find("^dens:") then density_left = entry.x end
    if entry.x == 0 and entry.y == HINT_ROW_Y then hint_found = true end
  end
  assert_true(title_right, "page title " .. title .. " drawn at 0,8 (" .. where .. ")")
  assert_true(density_left and density_left - title_right >= 4,
    "dens: starts at least 4 px after " .. title .. " (" .. where .. ")")
  assert_true(hint_found, "hint row at y " .. HINT_ROW_Y .. " (" .. where .. ")")
end

test("stub text_width counts UTF-8 characters, not bytes", function()
  assert_equal(text_width("\226\151\143"), text_width("o"), "a three-byte glyph is one character")
  assert_equal(text_width("\226\151\139 ab"), 4 * text_width("o"), "glyph, space and two letters")
end)

test("every page's header, hints and text stay apart and inside 128x64 (M7)", function()
  local context = load_strata()
  params:set("mutation_enabled", 1)
  params:set("master_density", 2.0)
  capture_scene(8)
  recall_scene(8, 0)
  -- the widest SETUP page: four grids of every size and an arc
  context.grid.plug(1, 16, 16)
  context.grid.plug(2, 16, 8)
  context.grid.plug(3, 8, 16)
  context.grid.plug(4, 8, 8)
  context.arc.plug(1)
  local voices = local_value("voices")
  local _, set_selected = find_upvalue("selected_voice")
  for voice_idx = 1, 7 do
    set_selected(voice_idx)
    if not voices[voice_idx].active then toggle_voice(voice_idx) end
    if not local_value("frozen")[voice_idx] then toggle_freeze(voice_idx) end
    params:set("v" .. voice_idx .. "_grain_mode", 2)  -- MAIN shows [TRIG]
    for page = 1, #PAGE_TITLES do
      show_page(page)
      assert_screen_layout(context, PAGE_TITLES[page] .. ", voice " .. voice_idx)
    end
  end
  -- UI.ScrollingList draws row i at y + 5 + (i - 1) * 11; its last row must
  -- end above the hint row
  local voice_list = local_value("voice_list")
  local last_row_y = voice_list.y + 5 + (voice_list.num_visible - 1) * 11
  assert_true(last_row_y <= HINT_ROW_Y - TEXT_HEIGHT,
    "voice list's last row (y " .. last_row_y .. ") clears the hint row")
end)

test("MAIN voice list fits its column for every voice, state and selection (#23)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  local frozen = local_value("frozen")
  local _, set_selected = find_upvalue("selected_voice")
  local states = { { active = false, frozen = false }, { active = false, frozen = true },
    { active = true, frozen = false }, { active = true, frozen = true } }
  local entries_by_state = {}
  for state_idx, state in ipairs(states) do
    for voice_idx = 1, 7 do
      if voices[voice_idx].active ~= state.active then toggle_voice(voice_idx) end
      if (frozen[voice_idx] or false) ~= state.frozen then toggle_freeze(voice_idx) end
    end
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      update_voice_list()
      show_page(1)
      local where = string.format("MAIN, voice %d, active %s, frozen %s", voice_idx,
        tostring(state.active), tostring(state.frozen))
      assert_screen_layout(context, where)
      -- the list draws its four rows; the selected voice's entry is bright
      local voice_list = local_value("voice_list")
      local rows_drawn, selected_entry = 0, nil
      for _, entry in ipairs(context.screen.texts) do
        local row = (entry.y - voice_list.y - 5) / 11
        if entry.x == voice_list.x and row >= 0 and row < voice_list.num_visible and row % 1 == 0 then
          rows_drawn = rows_drawn + 1
          if entry.level == 15 then selected_entry = entry.text end
        end
      end
      assert_equal(rows_drawn, voice_list.num_visible, "list rows drawn (" .. where .. ")")
      assert_equal(selected_entry, voice_list.entries[voice_idx], "selected entry bright (" .. where .. ")")
    end
    entries_by_state[state_idx] = local_value("voice_list").entries
  end
  for voice_idx = 1, 7 do
    local stopped, stopped_frozen = entries_by_state[1][voice_idx], entries_by_state[2][voice_idx]
    local running, running_frozen = entries_by_state[3][voice_idx], entries_by_state[4][voice_idx]
    assert_true(stopped ~= running, "running and stopped entries differ: " .. stopped)
    assert_true(not stopped:find("[F]", 1, true) and not running:find("[F]", 1, true), "[F] only when frozen")
    assert_true(stopped_frozen:find("[F]", 1, true) and running_frozen:find("[F]", 1, true),
      "frozen entries show [F]: " .. running_frozen)
    -- every entry is plain ASCII, so its width does not depend on how the
    -- norns font draws other glyphs
    for _, entry in ipairs({ stopped, stopped_frozen, running, running_frozen }) do
      assert_true(not entry:find("[\128-\255]"), "ASCII entry: " .. entry)
    end
  end
end)

test("every voice type's list name is at most 5 characters, as MAIN_PARAMS states (#49)", function()
  load_strata()
  local main_params = local_value("MAIN_PARAMS")
  local voices = local_value("voices")
  for voice_idx = 1, #voices do
    local voice_type = voices[voice_idx].name
    local list_name = main_params[voice_type].list_name
    assert_true(type(list_name) == "string" and #list_name >= 1, voice_type .. " has a list name")
    assert_true(#list_name <= 5, voice_type .. "'s list name '" .. list_name .. "' has at most 5 characters")
  end
end)

test("E1 selects pages; MAIN keeps its encoder and key mappings", function()
  local context = load_strata(); finish_startup(context)
  assert_equal(local_value("ui_page"), 1)
  local density = params:get("master_density")
  enc(1, 1); assert_equal(local_value("ui_page"), 2)
  assert_equal(params:get("master_density"), density, "E1 no longer changes density")
  enc(1, 10); assert_equal(local_value("ui_page"), 5)
  enc(1, -10); assert_equal(local_value("ui_page"), 1)
  enc(2, 1); assert_equal(local_value("selected_voice"), 2)
  local before = params:get(main_param_id(2)); enc(3, 1)
  assert_true(params:get(main_param_id(2)) ~= before, "E3 moves the main param on MAIN")
  key(3, 1); assert_true(local_value("frozen")[2], "K3 freezes a running voice on MAIN")
end)

test("E1 steps one page per detent: no acceleration, 4 ticks per page", function()
  local context = load_strata()
  local encoders = context.encoders
  assert_equal(encoders.accel[1], false, "E1 acceleration off")
  assert_equal(encoders.sens[1], 4, "E1 needs 4 ticks per page")
  assert_equal(encoders.accel[2], true, "E2 keeps norns' default acceleration")
  assert_equal(encoders.accel[3], true, "E3 keeps norns' default acceleration")
  -- a fast turn (1 ms between ticks) of 4 ticks moves exactly one page
  for _ = 1, 4 do encoders.deliver(1, 1, 0.001) end
  assert_equal(local_value("ui_page"), 2, "fast E1 turn does not skip pages")
  for _ = 1, 3 do encoders.deliver(1, 1, 0.001) end
  assert_equal(local_value("ui_page"), 2, "three ticks are not yet a page")
  encoders.deliver(1, 1, 0.001)
  assert_equal(local_value("ui_page"), 3, "the fourth tick is")
  for _ = 1, 8 do encoders.deliver(1, -1, 0.001) end
  assert_equal(local_value("ui_page"), 1, "eight ticks back return two pages")
end)

test("every page draws within 128x64 with a header and hint row", function()
  local context = load_strata(); finish_startup(context)
  for page = 1, 5 do
    enc(1, page - local_value("ui_page")); redraw()
    local texts = context.screen.texts
    assert_equal(texts[1].text, ({"MAIN","FX","LFO","BUFFER","SETUP"})[page], "page title")
    for _, entry in ipairs(texts) do
      local left, right = text_span(entry)
      assert_true(left >= 0 and right <= 128 and entry.y <= 64, "text inside screen on page " .. page)
    end
  end
end)

test("arc rings follow the page; MAIN mapping unchanged", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  context.arc.turn(1, 1, 20); assert_true(params:get("master_density") > 1.0, "ring 1 density on MAIN")
  -- rings drawn (with at least one segment) on each page: SETUP none
  local expected_rings = { 4, 4, 4, 4, 0 }
  for page = 1, #PAGE_TITLES do
    show_page(page); arc_redraw()
    local drawn = 0
    for ring in pairs(device.segments) do
      assert_true(ring >= 1 and ring <= 4, "ring " .. tostring(ring) .. " exists (" .. PAGE_TITLES[page] .. ")")
      drawn = drawn + 1
    end
    assert_equal(drawn, expected_rings[page], PAGE_TITLES[page] .. " rings drawn")
  end
end)

test("every arc ring lights all 64 LEDs at its maximum, about half at half, none at its minimum", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  local function set_fraction(param_id, fraction)
    local spec = params:lookup_param(param_id).controlspec
    if spec then
      params:set(param_id, spec:map(fraction))
    else
      local minval, maxval = param_range(param_id)
      params:set(param_id, util.linlin(0, 1, minval, maxval, fraction))
    end
  end
  local function lit(ring)
    local count = 0
    for _, level in ipairs(device.segments[ring].leds) do
      if level > 0 then count = count + 1 end
    end
    return count
  end
  local function check(page, ring_params, where)
    show_page(page)
    for ring, param_id in pairs(ring_params) do
      local label = where .. " ring " .. ring .. " (" .. param_id .. ")"
      set_fraction(param_id, 1); arc_redraw()
      assert_equal(lit(ring), 64, label .. " at maximum")
      set_fraction(param_id, 0.5); arc_redraw()
      assert_true(math.abs(lit(ring) - 32) <= 1, label .. " at half lights about 32, got " .. lit(ring))
      set_fraction(param_id, 0); arc_redraw()
      assert_equal(lit(ring), 0, label .. " at minimum")
    end
  end
  local voice = local_value("selected_voice")
  check(1, { "master_density", main_param_id(voice),
             "v" .. voice .. "_grain_size", "v" .. voice .. "_grain_density" }, "MAIN")
  check(2, { "filter_freq", "filter_res", "delay_time", "delay_mix" }, "FX")
  local lfo = {}
  for n = 1, local_value("NUM_LFOS") do lfo[n] = "lfo_depth_" .. n end
  local selected_lfo = local_value("selected_lfo")
  lfo[4] = "lfo_free_" .. selected_lfo
  check(3, lfo, "LFO")
  -- in clocked mode ring 4 shows the rate: an option param with an even
  -- number of rates has no middle index, so only its ends are checked
  params:set("lfo_mode_" .. selected_lfo, 1)
  local clocked_id = "lfo_clocked_" .. selected_lfo
  local _, slowest_rate = param_range(clocked_id)
  params:set(clocked_id, slowest_rate); arc_redraw()
  assert_equal(lit(4), 64, "LFO ring 4 (" .. clocked_id .. ") at maximum")
  params:set(clocked_id, 1); arc_redraw()
  assert_equal(lit(4), 0, "LFO ring 4 (" .. clocked_id .. ") at minimum")
  check(4, { "v" .. voice .. "_buf_pos", "v" .. voice .. "_buf_rate", "record_duration", "record_level" }, "BUFFER")
end)

test("MAIN rings 1, 3 and 4 are drawn from the param spec, like the other rings", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  show_page(1)
  local voice = local_value("selected_voice")
  local function lit(ring)
    local count = 0
    for _, level in ipairs(device.segments[ring].leds) do
      if level > 0 then count = count + 1 end
    end
    return count
  end
  local rings = { [1] = "master_density", [3] = "v" .. voice .. "_grain_size", [4] = "v" .. voice .. "_grain_density" }
  for ring, param_id in pairs(rings) do
    local param = params:lookup_param(param_id)
    -- a different range: a ring with its own hardcoded range would not follow
    param.controlspec = controlspec.new(0, 10, "lin", 0.01, 5)
    for _, value in ipairs({0, 2.5, 5, 7.5, 10}) do
      params:set(param_id, value); arc_redraw()
      local expected = param_fraction(param_id) >= 1 and 64 or math.floor(param_fraction(param_id) * 64 + 0.5)
      assert_true(math.abs(lit(ring) - expected) <= 1,
        param_id .. " = " .. value .. " lights " .. expected .. " LEDs, got " .. lit(ring))
    end
  end
end)

test("Strata follows one arc: any port, the first one plugged, removal of that one disconnects", function()
  local function screen_has(context, text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  local function setup_text(context)
    local page = local_value("ui_page")
    show_page(5); redraw()
    local result = screen_has(context, "arc: connected") and "connected" or (screen_has(context, "arc: none") and "none" or "?")
    show_page(page)
    return result
  end
  -- the only arc is on port 2
  local context = load_strata(); finish_startup(context)
  context.arc.plug(2)
  assert_equal(setup_text(context), "connected", "arc on port 2 connects")
  local density = params:lookup_param("master_density")
  local before = density.raw
  context.arc.turn(2, 1, 20)
  assert_near(density.raw - before, 20 / 512, 1e-9, "arc on port 2 works")
  context.arc.unplug(2)
  assert_equal(setup_text(context), "none", "removing it disconnects")

  -- already plugged at start: found on its port
  context = load_strata(); finish_startup(context)
  context.arc.plug(3)
  context.arc.unplug(3)
  context.arc.vports[4].device = {port = 4, segments = {}, all = function() end, refresh = function() end, segment = function() end, led = function() end}
  arc_init()
  assert_true(context.arc.vports[4].delta ~= nil, "init attaches the vport holding a device")

  -- port 2 first, then port 1: Strata stays on 2
  context = load_strata(); finish_startup(context)
  density = params:lookup_param("master_density")
  context.arc.plug(2)
  context.arc.plug(1)
  assert_equal(context.arc.vports[1].delta, nil, "a second arc gets no handler")
  context.arc.unplug(1)
  assert_equal(setup_text(context), "connected", "removing the other arc keeps Strata's")
  before = density.raw
  context.arc.turn(2, 1, 20)
  assert_near(density.raw - before, 20 / 512, 1e-9, "still handled on port 2")
  context.arc.unplug(2)
  assert_equal(setup_text(context), "none", "removing Strata's arc disconnects")

  -- port 1 first, then 2
  context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  context.arc.plug(2)
  assert_equal(context.arc.vports[2].delta, nil, "no handler on the second arc")
  context.arc.unplug(2)
  assert_equal(setup_text(context), "connected", "removing another port's arc keeps Strata's arc")
  context.arc.unplug(1)
  assert_equal(setup_text(context), "none", "removing Strata's arc disconnects it")

  -- two arcs: unplugging the followed one moves to the other (#49). norns
  -- clears the removed vport only after arc.remove returns, so it is skipped
  context = load_strata(); finish_startup(context)
  density = params:lookup_param("master_density")
  context.arc.plug(1)
  local second_arc = context.arc.plug(3)
  context.arc.unplug(1)
  assert_equal(setup_text(context), "connected", "the other arc is followed")
  assert_true(context.arc.vports[3].delta ~= nil, "its vport gets the handlers")
  assert_equal(context.arc.vports[1].delta, nil, "the removed arc's vport keeps none")
  before = density.raw
  context.arc.turn(3, 1, 20)
  assert_near(density.raw - before, 20 / 512, 1e-9, "turning the other arc works")
  local refreshes = second_arc.refresh_count
  next_frame(context)
  assert_equal(second_arc.refresh_count, refreshes + 1, "its rings are drawn")
  context.arc.plug(1)
  assert_equal(context.arc.vports[1].delta, nil, "an arc plugged back in is not followed")
  context.arc.unplug(3)
  assert_true(context.arc.vports[1].delta ~= nil, "until the followed one goes")
  context.arc.unplug(1)
  assert_equal(setup_text(context), "none", "removing the last arc disconnects")
end)

test("every continuous arc ring sweeps its param's range in 512 ticks, following the warp", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  local _, set_selected = find_upvalue("selected_voice")
  local function sweep(page, ring, param_id, where)
    show_page(page)
    local spec = params:lookup_param(param_id).controlspec
    -- the param's step quantizes the value; step-0 params land within float error
    local tolerance = spec.step + 1e-6 * (spec.maxval - spec.minval)
    params:set(param_id, spec.minval)
    for _ = 1, 256 do context.arc.turn(1, ring, 1) end
    assert_near(params:get(param_id), spec:map(0.5), tolerance, where .. ": 256 ticks reach the warp's midpoint")
    for _ = 1, 256 do context.arc.turn(1, ring, 1) end
    assert_near(params:get(param_id), spec.maxval, tolerance, where .. ": 512 ticks reach the maximum")
    for _ = 1, 512 do context.arc.turn(1, ring, -1) end
    assert_near(params:get(param_id), spec.minval, tolerance, where .. ": 512 back reach the minimum")
  end
  assert_equal(local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, 512, "half of the arc's 1024 ticks per turn")
  -- MAIN: density, every voice's main param, grain size and density
  sweep(1, 1, "master_density", "MAIN ring 1")
  for voice_idx = 1, 7 do
    set_selected(voice_idx)
    sweep(1, 2, main_param_id(voice_idx), "MAIN ring 2, voice " .. voice_idx)
    sweep(1, 3, "v" .. voice_idx .. "_grain_size", "MAIN ring 3, voice " .. voice_idx)
    sweep(1, 4, "v" .. voice_idx .. "_grain_density", "MAIN ring 4, voice " .. voice_idx)
  end
  set_selected(1)
  params:set("v1_source", 3); sweep(1, 2, "v1_buf_pos", "MAIN ring 2, buffer source")
  params:set("v1_source", 10); sweep(1, 2, "v1_grain_size", "MAIN ring 2, input source")
  params:set("v1_source", 1)
  for ring, param_id in ipairs({ "filter_freq", "filter_res", "delay_time", "delay_mix" }) do
    sweep(2, ring, param_id, "FX ring " .. ring)
  end
  for ring, param_id in ipairs({ "v1_buf_pos", "v1_buf_rate", "record_duration", "record_level" }) do
    sweep(4, ring, param_id, "BUFFER ring " .. ring)
  end
  -- LFO ring 4 in free mode (the selected LFO's period); its depth rings and
  -- clocked rate keep their whole steps (the arc LFO page test)
  sweep(3, 4, "lfo_free_1", "LFO ring 4, free period")
end)

test("main_param_id and main_param_label name each voice's E3 and arc ring 2 param", function()
  local context = load_strata()
  local device = context.arc.plug(1)
  local expected = { resonator = "freq", fm = "index", folder = "fold", sub = "drift",
    pulse = "width", karplus = "decay", ring = "ratio" }
  local voices = local_value("voices")
  local _, set_selected = find_upvalue("selected_voice")
  for voice_idx = 1, 7 do
    local key_name = expected[voices[voice_idx].name]
    local param_id = "v" .. voice_idx .. "_" .. key_name
    assert_equal(main_param_id(voice_idx), param_id, "main param id of voice " .. voice_idx)
    assert_equal(main_param_label(voice_idx), key_name, "main param label of voice " .. voice_idx)
    -- arc ring 2 adjusts it and shows it across its controlspec range,
    -- following the warp (param_fraction, as the FX and BUFFER rings)
    set_selected(voice_idx)
    local min_value, max_value = param_range(param_id)
    params:set(param_id, min_value)
    context.arc.turn(1, 2, 100)  -- enough for one step of sub's fine-scaled drift
    next_frame(context)
    local value = params:get(param_id)
    assert_true(value > min_value, "arc ring 2 raises " .. param_id)
    assert_near(device.segments[2].to, param_fraction(param_id) * math.pi * 2, 1e-9, "ring 2 shows " .. param_id)
    -- MAIN shows the label and value in the right column
    redraw()
    local label_found = false
    for _, entry in ipairs(context.screen.texts) do
      if entry.x == 65 and entry.y == 42 and entry.text == key_name then label_found = true end
    end
    assert_true(label_found, "MAIN shows the " .. key_name .. " label")
  end
  -- an exp main param: the resonator's freq at the sweep's midpoint (200 Hz
  -- on 20-2000) is drawn at half a turn, not at its linear 9 %
  set_selected(1)
  params:set("v1_freq", 20)
  for _ = 1, 256 do context.arc.turn(1, 2, 1) end
  next_frame(context)
  assert_near(params:get("v1_freq"), 200, 1e-6, "256 ticks reach the exp midpoint")
  assert_near(device.segments[2].to, math.pi, 1e-6, "ring 2 draws the exp midpoint at half a turn")
end)

test("every encoder, key and arc control is safe on every page; arc button only acts on MAIN", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  context.grid.plug(1, 16, 16)
  for page = 1, #PAGE_TITLES do
    show_page(page)
    for _, n in ipairs({ 2, 3 }) do
      enc(n, 1); enc(n, -1)
      assert_equal(local_value("ui_page"), page, "E" .. n .. " stays on " .. PAGE_TITLES[page])
    end
    for n = 1, 3 do key(n, 1); key(n, 0) end
    for ring = 1, 4 do context.arc.turn(1, ring, 5); context.arc.turn(1, ring, -5) end
    arc_redraw()
    if page ~= 1 then
      local frozen = deep_copy(local_value("frozen"))
      local active = {}
      for voice_idx, voice in ipairs(local_value("voices")) do active[voice_idx] = voice.active end
      context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
      for voice_idx, voice in ipairs(local_value("voices")) do
        assert_equal(voice.active, active[voice_idx], "arc button leaves voices alone on " .. PAGE_TITLES[page])
        assert_equal(local_value("frozen")[voice_idx], frozen[voice_idx], "arc button leaves freeze alone on " .. PAGE_TITLES[page])
      end
    end
  end
  -- SETUP: arc rings do nothing
  show_page(5)
  local density = params:get("master_density")
  context.arc.turn(1, 1, 40)
  assert_equal(params:get("master_density"), density, "arc ring 1 does not change density on SETUP")
end)

test("the arc button finds MAIN by its page index, not its title", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1); show_page(1)
  local pages = local_value("UI_PAGES")
  assert_equal(pages.MAIN_PAGE, 1, "MAIN_PAGE is MAIN's index")
  assert_equal(pages[pages.MAIN_PAGE], "MAIN")
  local _, set_selected = find_upvalue("selected_voice"); set_selected(3)
  local voices = local_value("voices")
  assert_true(not voices[3].active, "voice 3 starts stopped")
  local title = pages[1]
  pages[1] = "HOME"   -- a renamed title must not change what the button does
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  pages[1] = title
  assert_true(voices[3].active, "the button starts the selected voice on page 1")
end)

-- Counts screen draws (calls of the global redraw(), as the frame clock and
-- norns make them) in counter.screen until restore() is called
local function count_screen_draws()
  local counter = { screen = 0 }
  local real_redraw = redraw
  redraw = function() counter.screen = counter.screen + 1; real_redraw() end
  function counter.restore() redraw = real_redraw end
  return counter
end

local function screen_shows(context, text)
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == text then return true end
  end
  return false
end

-- change() must only ask for a redraw: nothing draws until the next frame,
-- which draws the screen and the arc once each (only the screen when
-- arc_hardware is nil: no arc is connected after the change)
local function assert_drawn_on_next_frame(context, arc_hardware, where, change)
  next_frame(context)  -- start from a frame with nothing left to draw
  local counter = count_screen_draws()
  local arc_refreshes = arc_hardware and arc_hardware.refresh_count
  change()
  local drawn_before_frame = counter.screen
  local arc_before_frame = arc_hardware and arc_hardware.refresh_count - arc_refreshes
  next_frame(context)
  counter.restore()
  assert_equal(drawn_before_frame, 0, where .. ": the screen waits for the frame")
  assert_equal(counter.screen, 1, where .. ": the next frame draws the screen once")
  if arc_hardware then
    assert_equal(arc_before_frame, 0, where .. ": the arc waits for the frame")
    assert_equal(arc_hardware.refresh_count - arc_refreshes, 1, where .. ": and the arc once")
  end
end

test("the frame clock draws the screen and arc at 15 fps, only when asked (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  local pages = local_value("UI_PAGES")
  assert_equal(pages.FRAMES_PER_SECOND, 15, "one named frame rate")
  local frame_clock = pages.frame_clock
  assert_true(context.clock.threads[frame_clock] ~= nil, "init starts the frame clock")
  next_frame(context)
  local sleeps = context.clock.sleep_log
  assert_equal(sleeps[#sleeps].id, frame_clock)
  assert_near(sleeps[#sleeps].amount, 1 / 15, 1e-9, "a frame every 1/15 s")
  -- nothing changed since the last frame: nothing is drawn
  local counter = count_screen_draws()
  local arc_refreshes = arc_hardware.refresh_count
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "an idle frame leaves the screen alone")
  assert_equal(arc_hardware.refresh_count, arc_refreshes, "and the arc")
  -- steps of a running LFO (the library writes its scaled and raw text
  -- params) and the drift of a synth voice's grain pitch show nowhere
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  next_frame(context)
  counter = count_screen_draws()
  context.lfo.tick(local_value("lfos")[1], 0.7)
  local drift_metro = local_value("drift_metro")
  drift_metro.event()
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "LFO steps and grain pitch drift ask for no redraw")
  -- a drifting buffer position shows on MAIN
  params:set("v1_source", 2)
  next_frame(context)
  counter = count_screen_draws()
  drift_metro.event()
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 1, "a buffer voice's drifting position redraws")
  -- norns' own redraw() (e.g. as its menu closes) still draws the page
  context.screen.texts = {}
  redraw()
  assert_true(screen_shows(context, "MAIN"), "redraw() draws the current page at once")
  cleanup()
  assert_equal(context.clock.threads[frame_clock], nil, "cleanup cancels the frame clock")
end)

test("a drifting buffer position redraws only for the selected voice (#49)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  local voices = local_value("voices")
  assert_true(voices[2].active, "voice 2 runs")
  params:set("v2_source", 3)  -- voice 2 drifts its buffer position; voice 1 (selected) is a synth
  params:set("v2_buf_pos", 0.5)  -- away from the ends, so every drift step moves it
  local drift_metro = local_value("drift_metro")
  for page = 1, #PAGE_TITLES do
    show_page(page)
    next_frame(context)
    local counter = count_screen_draws()
    local arc_refreshes = arc_hardware.refresh_count
    local position = params:get("v2_buf_pos")
    drift_metro.event()
    next_frame(context)
    counter.restore()
    assert_true(params:get("v2_buf_pos") ~= position, "voice 2's position drifted")
    -- the LFO page draws every frame anyway
    if PAGE_TITLES[page] ~= "LFO" then
      assert_equal(counter.screen, 0, PAGE_TITLES[page] .. ": an unselected voice's drift draws nothing")
    end
    assert_equal(arc_hardware.refresh_count, arc_refreshes, PAGE_TITLES[page] .. ": nor the arc")
  end
  -- selected, its drift shows on MAIN and the BUFFER page's arc ring
  show_page(1); enc(2, 1)
  assert_equal(local_value("selected_voice"), 2)
  next_frame(context)
  local counter = count_screen_draws()
  drift_metro.event()
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 1, "the selected voice's drift redraws")
end)

test("the arc keeps drawing while the norns menu is open (#49)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  next_frame(context)
  _menu.set_mode(true)
  -- norns' set_mode(true) swaps the global redraw for norns.none (the stub only tracks the mode)
  local script_redraw = redraw
  local screen_draws = 0
  redraw = function() screen_draws = screen_draws + 1 end
  local arc_refreshes = arc_hardware.refresh_count
  local density = params:get("master_density")
  params:set("master_density", density / 2)  -- PARAMS, a CC map or an LFO while the menu is open
  next_frame(context)
  assert_equal(arc_hardware.refresh_count, arc_refreshes + 1, "the frame draws the arc's rings")
  assert_equal(screen_draws, 1, "and calls the global redraw, which is norns.none in the menu")
  redraw = script_redraw
  _menu.set_mode(false)
end)

test("a draw that fails prints the error and the frame clock keeps drawing (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  next_frame(context)
  local frame_clock = local_value("UI_PAGES").frame_clock
  local real_redraw, real_arc_redraw = redraw, arc_redraw
  local screen_draws = 0
  redraw = function() error("screen draw failed") end
  arc_redraw = function() error("arc draw failed") end
  request_redraw()
  context.printed = {}
  next_frame(context)
  redraw = function() screen_draws = screen_draws + 1; real_redraw() end
  arc_redraw = real_arc_redraw
  assert_true(context.clock.threads[frame_clock] ~= nil, "the frame clock survives the failed draws")
  local output = table.concat(context.printed, "\n")
  assert_true(output:find("screen draw failed", 1, true), "the screen error is printed")
  assert_true(output:find("arc draw failed", 1, true), "the arc error is printed")
  assert_true(output:find("stack traceback", 1, true), "with a traceback")
  -- the failed frame cleared its flags: nothing is retried until asked
  local arc_refreshes = arc_hardware.refresh_count
  next_frame(context)
  assert_equal(screen_draws, 0, "a failed frame is not retried on its own")
  request_redraw()
  next_frame(context)
  redraw = real_redraw
  assert_equal(screen_draws, 1, "the next request draws the screen again")
  assert_equal(arc_hardware.refresh_count, arc_refreshes + 1, "and the arc")
end)

test("a draw that keeps failing prints its error once, until the error changes (#49)", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  next_frame(context)
  local real_redraw, real_arc_redraw = redraw, arc_redraw
  local screen_message = "screen draw failed"
  redraw = function() error(screen_message) end
  arc_redraw = function() error("arc draw failed") end
  local function failures_printed(text)
    local count = 0
    for _, line in ipairs(context.printed) do
      if line:find(text, 1, true) then count = count + 1 end
    end
    return count
  end
  context.printed = {}
  for _ = 1, 15 do  -- a second of frames, each asked for
    request_redraw()
    next_frame(context)
  end
  assert_equal(failures_printed("screen draw failed"), 1, "a persistent screen error prints once")
  assert_equal(failures_printed("arc draw failed"), 1, "a persistent arc error prints once")
  screen_message = "another screen failure"
  request_redraw(); next_frame(context)
  request_redraw(); next_frame(context)
  assert_equal(failures_printed("another screen failure"), 1, "a new error prints, once")
  assert_equal(failures_printed("arc draw failed"), 1, "the arc's unchanged error stays quiet")
  -- after a good frame the same error is news again
  redraw = real_redraw
  request_redraw(); next_frame(context)
  redraw = function() error(screen_message) end
  request_redraw(); next_frame(context)
  assert_equal(failures_printed("another screen failure"), 2, "the error after a good frame prints")
  -- a non-string error is a new table on every frame: keyed by its message
  -- field, or by its type when it has none, it still prints once
  context.printed = {}
  redraw = function() error({ message = "table draw failure" }) end
  for _ = 1, 15 do request_redraw(); next_frame(context) end
  assert_equal(failures_printed("frame draw failed"), 1, "a table error with a message prints once")
  assert_equal(failures_printed("table draw failure"), 1, "and shows its message")
  redraw = function() error({}) end
  for _ = 1, 15 do request_redraw(); next_frame(context) end
  assert_equal(failures_printed("frame draw failed"), 2, "a table error without one prints once too")
  redraw, arc_redraw = real_redraw, real_arc_redraw
end)

test("displayed changes from every source reach the screen and arc on the next frame (#11)", function()
  local context = load_strata()
  local arc_hardware = context.arc.plug(1)
  local grid_device = context.grid.plug(1, 16, 16)
  context.midi.plug(1, "keys")
  local voices = local_value("voices")
  show_page(1)

  assert_drawn_on_next_frame(context, arc_hardware, "the startup clock starting voice 2", function()
    context.clock.advance_until(STARTUP.clock)
  end)
  assert_true(voices[2].active, "the startup clock started voice 2")
  assert_drawn_on_next_frame(context, arc_hardware, "MIDI note", function()
    context.midi.send(1, { type = "note_on", ch = 1, note = 69, vel = 100 })
  end)
  assert_true(screen_shows(context, "440 Hz"), "MAIN shows the note's frequency")
  -- nothing shows the bend: a wheel's stream draws nothing (#49)
  next_frame(context)
  local bend_counter = count_screen_draws()
  local bend_arc_refreshes = arc_hardware.refresh_count
  context.midi.send(1, { type = "pitchbend", ch = 1, val = 12000 })
  next_frame(context)
  bend_counter.restore()
  assert_equal(bend_counter.screen, 0, "MIDI pitchbend draws no screen")
  assert_equal(arc_hardware.refresh_count, bend_arc_refreshes, "nor the arc")
  assert_drawn_on_next_frame(context, arc_hardware, "MIDI note on a stopped voice", function()
    context.midi.send(1, { type = "note_on", ch = 4, note = 40, vel = 100 })
  end)
  assert_true(voices[4].active, "the note started voice 4")
  params:set("midi_note_off", 2)   -- voice off
  assert_drawn_on_next_frame(context, arc_hardware, "MIDI note off stopping a voice", function()
    context.midi.send(1, { type = "note_off", ch = 4, note = 40, vel = 0 })
  end)
  assert_true(not voices[4].active, "the note off stopped voice 4")

  params:set("mutation_probability", 1)
  assert_drawn_on_next_frame(context, arc_hardware, "gentle_mutate", gentle_mutate)

  assert_drawn_on_next_frame(context, arc_hardware, "K3 on MAIN", function() key(3, 1); key(3, 0) end)
  assert_true(screen_shows(context, "[FREEZE]"), "K3 froze voice 1")
  assert_drawn_on_next_frame(context, arc_hardware, "arc button", function()
    context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  end)
  assert_true(not screen_shows(context, "[FREEZE]"), "the arc button unfroze voice 1")
  -- its callers (keys, arc, grid) ask for redraws too: call it directly
  assert_drawn_on_next_frame(context, arc_hardware, "toggle_freeze", function() toggle_freeze(1) end)
  assert_true(screen_shows(context, "[FREEZE]"), "toggle_freeze froze voice 1"); toggle_freeze(1)
  assert_drawn_on_next_frame(context, arc_hardware, "grid voice button", function()
    context.grid.press(1, 13, 14, 1); context.grid.press(1, 13, 14, 0)
  end)
  assert_true(voices[5].active, "the grid started voice 5")
  assert_drawn_on_next_frame(context, arc_hardware, "arc turn", function() context.arc.turn(1, 2, 8) end)
  assert_drawn_on_next_frame(context, arc_hardware, "E3", function() enc(3, 1) end)
  assert_drawn_on_next_frame(context, arc_hardware, "E1 page change", function() enc(1, 1) end)
  assert_true(screen_shows(context, "FX"), "E1 moved to the FX page")

  show_page(2)
  assert_drawn_on_next_frame(context, arc_hardware, "params:set of an FX param", function()
    params:set("filter_freq", 1234)
  end)
  assert_true(screen_shows(context, "1234 Hz"), "FX shows the new filter freq")

  show_page(3)
  assert_drawn_on_next_frame(context, arc_hardware, "LFO page K3", function() key(3, 1); key(3, 0) end)
  assert_equal(params:string("lfo_1"), "on", "K3 started LFO 1")

  show_page(4)
  assert_drawn_on_next_frame(context, arc_hardware, "bufferState report", function()
    context.polls.fire("bufferState", 305)
  end)
  assert_true(screen_shows(context, "5.0s"), "BUFFER shows the reported seconds")
  -- voice 1 records into slot 1; no report comes, so the take settles empty
  params:set("v1_source", 2)
  record_buffer(1)
  assert_drawn_on_next_frame(context, arc_hardware, "recording timer end", function()
    wake_buffer_clock(context, 1)
  end)
  assert_true(screen_shows(context, "K2:load K3:... K2+3:save"), "BUFFER shows the take finishing")
  assert_drawn_on_next_frame(context, arc_hardware, "fallback settle", function()
    wake_buffer_clock(context, 1)
  end)
  assert_true(screen_shows(context, "K2:load K3:rec K2+3:save"), "BUFFER shows the take settled")
  assert_true(grid_device.refresh_count > 0, "the grid still redraws on its own")

  -- hot-plugged devices: SETUP shows them
  show_page(5)
  context.midi.unplug(1)
  assert_drawn_on_next_frame(context, arc_hardware, "midi.add", function() context.midi.plug(1, "pads") end)
  assert_true(screen_shows(context, "midi 1: pads"), "SETUP shows the new MIDI device")
  assert_drawn_on_next_frame(context, arc_hardware, "grid.add", function() context.grid.plug(2, 8, 8) end)
  assert_true(screen_shows(context, "grid: 2 connected"), "SETUP shows the second grid")
  assert_drawn_on_next_frame(context, arc_hardware, "grid.remove", function() context.grid.unplug(2) end)
  assert_true(screen_shows(context, "grid: 1 connected"), "SETUP shows the grid gone")
  assert_drawn_on_next_frame(context, nil, "arc.remove", function() context.arc.unplug(1) end)
  assert_true(screen_shows(context, "arc: none"), "SETUP shows the arc gone")
  local new_arc, arc_before_frame
  assert_drawn_on_next_frame(context, nil, "arc.add", function()
    new_arc = context.arc.plug(1); arc_before_frame = new_arc.refresh_count
  end)
  assert_true(screen_shows(context, "arc: connected"), "SETUP shows the new arc")
  assert_equal(arc_before_frame, 0, "arc.add: the new arc waits for the frame")
  assert_equal(new_arc.refresh_count, 1, "arc.add: the next frame draws the new arc once")
end)

test("a smooth scene transition reaches the screen and arc on every step and at its end (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  show_page(1)
  -- the scene: voice 1 frozen at 100 Hz; now it plays 1000 Hz, unfrozen
  toggle_freeze(1); capture_scene(1); toggle_freeze(1)
  params:set("v1_freq", 1000)
  assert_drawn_on_next_frame(context, arc_hardware, "transition start (step 1)", function()
    recall_scene(1, 2)
  end)
  -- each step runs 0.1 s after the last and a frame comes every 1/15 s, so
  -- the frame after a step always comes before the next step (frames that
  -- run before a step find nothing to draw)
  local steps = 1
  while local_value("scene_transition_clock") do
    steps = steps + 1
    local where = "transition step " .. steps
    local counter = count_screen_draws()
    local arc_refreshes = arc_hardware.refresh_count
    wake(context, "scene_transition_clock")
    local drawn_before_frame = counter.screen
    local arc_before_frame = arc_hardware.refresh_count - arc_refreshes
    next_frame(context)
    counter.restore()
    assert_equal(drawn_before_frame, 0, where .. ": the screen waits for the frame")
    assert_equal(arc_before_frame, 0, where .. ": the arc waits for the frame")
    assert_equal(counter.screen, 1, where .. ": the next frame draws the screen once")
    assert_equal(arc_hardware.refresh_count - arc_refreshes, 1, where .. ": and the arc once")
  end
  assert_equal(steps, local_value("SCENE_TRANSITION").steps + 1, "every step, then the end")
  assert_true(screen_shows(context, "100 Hz"), "the end shows the scene's freq")
  assert_true(screen_shows(context, "[FREEZE]"), "and its freeze")
end)

test("many arc turns and encoder steps within one frame draw the screen and the arc once (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  show_page(1)
  next_frame(context)
  local counter = count_screen_draws()
  local arc_refreshes = arc_hardware.refresh_count
  for _ = 1, 50 do
    for ring = 1, 4 do context.arc.turn(1, ring, 3) end
    enc(3, 1)
  end
  assert_equal(counter.screen, 0, "no draws between frames")
  assert_equal(arc_hardware.refresh_count, arc_refreshes, "no arc refreshes between frames")
  next_frame(context)
  assert_equal(counter.screen, 1, "one screen draw for the whole burst")
  assert_equal(arc_hardware.refresh_count, arc_refreshes + 1, "one arc redraw for the whole burst")
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 1, "the next frame has nothing left to draw")
  assert_equal(arc_hardware.refresh_count, arc_refreshes + 1)
end)

test("SETUP page shows grids, arc and scenes; K3 saves scenes to disk", function()
  local context = load_strata()
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  show_page(5)
  assert_true(screen_has("grid: 0 connected"), "no grids")
  assert_true(screen_has("arc: none"), "no arc")
  assert_true(screen_has("scenes: 0/8 saved"), "no scenes")
  context.grid.plug(1, 16, 16)
  context.grid.plug(3, 8, 8)
  context.arc.plug(1)
  capture_scene(3)
  redraw()
  assert_true(screen_has("grid: 2 connected"), "two grids")
  assert_true(screen_has("16x16 8x8"), "grid sizes in port order")
  assert_true(screen_has("arc: connected"), "arc connected")
  assert_true(screen_has("scenes: 1/8 saved"), "one scene")
  context.arc.unplug(1)
  context.grid.unplug(3)
  next_frame(context)
  assert_true(screen_has("arc: none"), "unplugging the arc redraws SETUP on the next frame")
  assert_true(screen_has("grid: 1 connected"), "unplugging a grid redraws SETUP on the next frame")

  local scene_file = context.data_dir .. "strata/scenes.data"
  assert_true(not util.file_exists(scene_file), "no scenes file yet")
  key(3, 1)
  assert_true(util.file_exists(scene_file), "K3 on SETUP saves scenes")
end)

test("grid LEDs follow non-grid state changes (I9) and the played step (M7)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  -- row 14, columns 9-15 show voice on/off; row 16 shows freeze
  toggle_voice(5)
  assert_equal(device:get_led(13, 14), 12, "voice 5 on lights row 14")
  toggle_voice(5)
  assert_equal(device:get_led(13, 14), 2, "voice 5 off dims row 14")
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(1)
  key(3, 1)  -- voice 1 is active: K3 freezes it
  assert_equal(device:get_led(1, 16), 12, "K3 freeze lights row 16")
  context.arc.plug(1)
  context.arc.push(1, 1, 1)
  assert_equal(device:get_led(1, 16), 2, "arc button unfreeze dims row 16")

  -- the highlighted step is the one that just played
  toggle_pattern_step(1, 1)
  pattern_toggle()
  assert_equal(device:get_led(1, 1), 15, "step 1 highlighted while it plays")
  assert_equal(device:get_led(2, 1), 0, "step 2 not highlighted")
  assert_equal(device:get_led(1, 2), 4, "empty step under the playhead shows dim")
  pattern_toggle()

  -- page 2 faders follow mutations
  context.grid.press(1, 14, 8, 1)  -- grid page 2 (parameters)
  context.grid.press(1, 1, 14, 1)  -- voice 1
  params:set("v1_freq", 20)        -- changes the param without a grid redraw
  params:set("mutation_probability", 1)
  params:set("mutation_amount", 1)
  -- gentle_mutate visits params with pairs(), so which random draw lands on
  -- freq varies between processes; a negative draw clamps freq back to the
  -- minimum. Mutate until it moves (each try has about an even chance).
  local freq_column = 1
  for _ = 1, 40 do
    gentle_mutate()
    freq_column = fader_position("v1_freq")
    if freq_column > 1 then break end
  end
  assert_true(freq_column > 1, "mutation moved freq off the minimum")
  assert_equal(device:get_led(freq_column, 9), 15, "freq fader LED follows the mutation")

  -- grid_redraw with no grids is a no-op
  context.grid.unplug(1)
  assert_equal(next(local_value("grids")), nil, "unplug clears the grids table")
  grid_redraw()
end)

test("grid scene LEDs light the scene a sequenced instant recall loaded at once (#49)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 15, 8, 1)  -- grid page 3 (scenes)
  capture_scene(1); capture_scene(2)
  params:set("scene_sequence_length", 2)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(1, 0.001)
  assert_equal(local_value("current_scene"), 1, "the sequencer recalled scene 1")
  -- at 4 s the sequencer moves on and recalls scene 2 instantly
  context.clock.run_for(4, 0.001)
  assert_equal(local_value("current_scene"), 2, "the sequencer recalled scene 2")
  assert_equal(device:get_led(2, 1), 15, "scene 2 is lit")
  assert_equal(device:get_led(1, 1), 8, "scene 1 shows as populated, no longer as the current scene")
  params:set("scene_sequencer_enabled", 0)
  -- recalls from outside the grid (MIDI-mapped, the sequencer): an instant
  -- one repaints the grid once, a smooth one lights its scene at once
  local refreshes = device.refresh_count
  recall_scene(1, 0)
  assert_equal(device.refresh_count, refreshes + 1, "an instant recall repaints the grid once")
  assert_equal(device:get_led(1, 1), 15, "scene 1 lit")
  assert_equal(device:get_led(2, 1), 8, "scene 2 no longer")
  recall_scene(2, 2)
  assert_equal(device:get_led(2, 1), 15, "a smooth recall lights its scene as it starts")
  assert_equal(device:get_led(1, 1), 8, "and dims the previous one")
  context.clock.run_for(3, 0.001)
  assert_equal(device:get_led(2, 1), 15, "scene 2 still lit after the fade")
end)

test("grid sequencer LEDs follow a length or start set outside the grid (#49)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 15, 8, 1)  -- grid page 3 (scenes)
  -- row 5: column 1 the sequencer, columns 3-10 the sequence length
  params:set("scene_sequence_length", 6)  -- PARAMS, a CC map or a PSET
  assert_equal(device:get_led(8, 5), 8, "length 6 lights column 8")
  assert_equal(device:get_led(9, 5), 2, "and not column 9")
  params:set("scene_sequence_length", 2)
  assert_equal(device:get_led(4, 5), 8, "length 2 lights column 4")
  assert_equal(device:get_led(5, 5), 2, "the LEDs past it go dark at once")
  params:set("scene_sequencer_enabled", 1)  -- started from PARAMS
  assert_equal(device:get_led(1, 5), 15, "the sequencer LED lights as it starts")
  params:set("scene_sequencer_enabled", 0)
  assert_equal(device:get_led(1, 5), 4, "and dims as it stops")
end)

test("hot-plugged grid and arc fire handlers once per event (I3)", function()
  local context = load_strata()
  context.grid.plug(3, 16, 16)
  local calls = 0
  local real_grid_key = grid_key
  grid_key = function(...) calls = calls + 1; return real_grid_key(...) end
  context.grid.press(3, 1, 1, 1)
  assert_equal(calls, 1, "grid_key runs once per press")
  context.grid.unplug(3)
  context.grid.plug(3, 16, 16)
  context.grid.press(3, 1, 2, 1)
  assert_equal(calls, 2, "replugged grid still runs grid_key once per press")
  grid_key = real_grid_key

  -- compared on the raw 0-1 position: the 0.01 step quantizes the value
  local density = params:lookup_param("master_density")
  context.arc.plug(1)
  local before = density.raw
  context.arc.turn(1, 1, 20)  -- one delta of 20 -> 20/512 of the range
  assert_near(density.raw - before, 20 / 512, 1e-9, "a turn is handled once")
  context.arc.unplug(1)
  context.arc.plug(1)
  before = density.raw
  context.arc.turn(1, 1, 20)
  assert_near(density.raw - before, 20 / 512, 1e-9, "replugged arc handles a turn once")
end)

test("cleanup stops everything and darkens controllers (M9)", function()
  local context = load_strata()
  local grid_device = context.grid.plug(1, 16, 16)
  local arc_hardware = context.arc.plug(1)
  finish_startup(context)  -- finish init's voice start-up coroutine
  capture_scene(1)
  params:set("scene_sequencer_enabled", 1)
  params:set("mutation_enabled", 1)
  pattern_toggle()
  recall_scene(1, 5)
  local voices = local_value("voices")
  local expected_off = {}
  for voice_idx = 1, local_value("NUM_VOICES") do
    if voices[voice_idx].active then table.insert(expected_off, voice_idx - 1) end
  end
  assert_true(#expected_off >= 2 and expected_off[1] == 0, "voice 1 and others are running before cleanup")
  context.clear_engine_calls()
  cleanup()
  assert_equal(params:get("scene_sequencer_enabled"), 0, "scene sequencer param reset")
  assert_equal(params:get("mutation_enabled"), 0, "mutation param reset")
  assert_equal(context.clock.pending_count(), 0, "no clocks left running")
  for _, timer in ipairs(context.metro.all) do assert_true(not timer.running, "metro stopped") end
  local lit = 0
  for x = 1, 16 do for y = 1, 16 do lit = lit + grid_device:get_led(x, y) end end
  assert_equal(lit, 0, "grid LEDs cleared")
  assert_true(next(arc_hardware.segments) == nil, "arc rings cleared")
  local voices_off = {}
  for _, call in ipairs(context.calls_named("voiceOff")) do table.insert(voices_off, call.args[1]) end
  assert_equal(table.concat(voices_off, ","), table.concat(expected_off, ","),
    "exactly the running voices are turned off, by 0-based engine index")
  assert_true(util.file_exists(context.data_dir .. "strata/scenes.data"), "scenes saved on cleanup")
end)

---------------------------------------------------------------------------
-- effects chain, FX page, scene format 2
---------------------------------------------------------------------------

local FX_PARAM_IDS = { "filter_type", "filter_freq", "filter_res", "filter_mix",
  "delay_time", "delay_feedback", "delay_mix", "reverb_mix", "reverb_size", "reverb_damp", "drift_amount" }

test("fx params drive setFilter/setDelay and live in scenes", function()
  local context = load_strata(); context.clear_engine_calls()
  params:set("filter_type", 3); params:set("filter_freq", 1200); params:set("filter_mix", 1)
  local call = context.calls_named("setFilter"); call = call[#call]
  assert_near(call.args[1], 1200, 1); assert_equal(call.args[3], 2); assert_equal(call.args[4], 1)
  params:set("delay_time", 0.5); params:set("delay_feedback", 0.6); params:set("delay_mix", 0.3)
  call = context.calls_named("setDelay"); call = call[#call]
  assert_near(call.args[1], 0.5, 1e-6); assert_near(call.args[2], 0.6, 1e-6); assert_near(call.args[3], 0.3, 1e-6)
  capture_scene(1); params:set("filter_freq", 300); params:set("delay_mix", 0)
  recall_scene(1, 0)
  assert_near(params:get("filter_freq"), 1200, 1); assert_near(params:get("delay_mix"), 0.3, 1e-6)
end)

test("fx params: defaults, one exactly sized strata_fx group, scene defaults match", function()
  load_strata()
  local expected_defaults = { filter_type = 1, filter_freq = 5000, filter_res = 0.5, filter_mix = 0,
    delay_time = 0.375, delay_feedback = 0.4, delay_mix = 0 }
  for param_id, default in pairs(expected_defaults) do
    assert_near(params:get(param_id), default, 1e-9, param_id .. " default")
  end
  assert_equal(params:lookup_param("filter_type").count, 3, "lowpass, highpass, bandpass")
  assert_equal(params:string("filter_type"), "lowpass")
  -- the group holds exactly the FX params, in order
  local group_index
  for index, param in ipairs(params.params) do
    if param.id == "strata_fx" then group_index = index end
  end
  assert_true(group_index, "strata_fx group exists")
  assert_equal(params.params[group_index].t, params.tGROUP)
  assert_equal(params.params[group_index].n, #FX_PARAM_IDS, "group size")
  for offset, param_id in ipairs(FX_PARAM_IDS) do
    assert_equal(params.params[group_index + offset].id, param_id, "group entry " .. offset)
  end
  assert_true(not params.lookup["strata_reverb"], "the reverb separator is replaced by the group")
  -- every scene global carries its param's default (tempo follows clock_tempo)
  local in_scene = {}
  for _, global in ipairs(local_value("SCENE_GLOBAL_PARAMS")) do
    in_scene[global.id] = global
    assert_true(type(global.default) == "number", global.id .. " has a default")
    if global.id ~= "tempo" then
      local param = params:lookup_param(global.id)
      local param_default = param.controlspec and param.controlspec.default or param.default
      assert_near(global.default, param_default, 1e-9, global.id .. " scene default")
    end
  end
  for _, param_id in ipairs(FX_PARAM_IDS) do
    assert_true(in_scene[param_id], param_id .. " is a scene global")
    assert_equal(in_scene[param_id].continuous, param_id ~= "filter_type", param_id .. " continuity")
  end
end)

test("v1 scene file migrates to v2 with fx defaults", function()
  local context = load_strata({ data_subdir = "v1" })
  capture_scene(2)
  local scenes = local_value("scenes")
  for _, param_id in ipairs(FX_PARAM_IDS) do
    if param_id:find("^filter_") or param_id:find("^delay_") then
      scenes[2].data[param_id] = nil   -- as a v1 file lacks them
    end
  end
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  tab.save(scenes, context.data_dir .. "strata/scenes.data")  -- v1 wrote the bare array
  params:set("filter_freq", 300); params:set("delay_mix", 0.5)
  load_scenes_from_disk()
  assert_true(local_value("scenes")[2].populated)
  recall_scene(2, 0)                                           -- must not error on nil
  assert_near(params:get("filter_freq"), 5000, 1); assert_equal(params:get("delay_mix"), 0)
  assert_true(table.concat(context.printed, "\n"):find("migrated scenes file from version 1"),
    "migration message printed")
  -- a versioned version-1 file migrates too, and the next save writes version 2
  tab.save({ version = 1, scenes = scenes }, context.data_dir .. "strata/scenes.data")
  context = load_strata({ data_subdir = "v1" })
  assert_true(local_value("scenes")[2].populated, "versioned v1 file loads")
  save_scenes_to_disk()
  local saved = context.tab.load(context.data_dir .. "strata/scenes.data")
  assert_equal(saved.version, 2, "scenes are saved as version 2")
  assert_near(saved.scenes[2].data.filter_freq, 5000, 1, "migrated default saved")
end)

test("migrate_scene fills table-driven voice defaults and tolerates malformed data", function()
  load_strata()
  capture_scene(1)
  local scene = deep_copy(local_value("scenes")[1])
  local voice_defaults = local_value("VOICE_SCENE_DEFAULTS")
  -- later formats add per-voice fields through VOICE_SCENE_DEFAULTS
  table.insert(voice_defaults, { path = { "test_block", "field" }, default = 7 })
  table.insert(voice_defaults, { path = { "grain", "test_field" }, default = 3 })
  migrate_scene(scene, 1)
  table.remove(voice_defaults); table.remove(voice_defaults)
  for voice_idx = 1, 7 do
    assert_equal(scene.data.voices[voice_idx].grain.test_field, 3, "nested voice default filled")
    assert_equal(scene.data.voices[voice_idx].test_block, nil, "missing parent tables are not invented")
  end
  scene.data.reverb_mix = nil
  migrate_scene(scene, 1)
  assert_near(scene.data.reverb_mix, 0.3, 1e-9, "missing global filled from its default")
  scene.data.reverb_mix = 0.9
  migrate_scene(scene, 1)
  assert_near(scene.data.reverb_mix, 0.9, 1e-9, "present values are kept")
  -- malformed scenes are left for validate_scene to reject
  for _, bad in ipairs({ "x", {}, { populated = true }, { populated = true, data = { voices = "v" } },
      { populated = true, data = { voices = { "a", 3 } } }, { populated = false } }) do
    migrate_scene(bad, 1)
  end
end)

test("FX page: E2 selects a row, E3 adjusts it, K3 bypasses the filter", function()
  local context = load_strata(); enc(1, 1)
  params:set("filter_mix", 0.8); key(3, 1); assert_equal(params:get("filter_mix"), 0)
  key(3, 1); assert_near(params:get("filter_mix"), 0.8, 1e-6)
  enc(2, 3); local before = params:get("filter_freq"); enc(3, 2)
  assert_true(params:get("filter_freq") > before, "row 4 is filter freq")
  -- K3 from a bypassed default turns the filter fully on
  context = load_strata(); enc(1, 1)
  key(3, 1); assert_equal(params:get("filter_mix"), 1, "first K3 turns the filter on")
  local function hint_text()
    for _, entry in ipairs(context.screen.texts) do
      if entry.y == 62 then return entry.text end
    end
  end
  redraw(); assert_equal(hint_text(), "K3:filter bypass")
  key(3, 1); redraw(); assert_equal(hint_text(), "K3:filter on")
end)

test("FX page K3 restores the last non-zero filter mix however it was set", function()
  load_strata(); enc(1, 1)
  enc(2, 5)                                    -- row 6: filter mix
  enc(3, 50); assert_near(params:get("filter_mix"), 0.5, 1e-6, "E3 sets the mix to 0.5")
  enc(3, -50); assert_equal(params:get("filter_mix"), 0, "E3 brings it to 0")
  key(3, 1); assert_near(params:get("filter_mix"), 0.5, 1e-6, "K3 restores the mix E3 last set")
  params:set("filter_mix", 0.3); params:set("filter_mix", 0)  -- PARAMS menu, scene recall, ...
  key(3, 1); assert_near(params:get("filter_mix"), 0.3, 1e-6, "K3 restores a mix set through params")
end)

test("FX page rows stay apart and inside 128x64 at every row and value", function()
  local context = load_strata()
  params:set("mutation_enabled", 1)
  capture_scene(8); recall_scene(8, 0)
  show_page(2)
  local rows = local_value("FX_PAGE").rows
  assert_equal(#rows, 12, "density, drift, 4 filter, 3 delay, 3 reverb rows")
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  for _, extreme in ipairs({ "max", "min" }) do
    for _, row in ipairs(rows) do
      local min_value, max_value = param_range(row.param_id)
      if row.param_id == "filter_type" then min_value, max_value = 2, 3 end  -- highpass, bandpass
      params:set(row.param_id, extreme == "max" and max_value or min_value)
    end
    enc(2, -100)
    for row = 1, #rows do
      assert_equal(local_value("fx_row"), row, "E2 steps one row")
      redraw()
      assert_screen_layout(context, "FX row " .. row .. ", " .. extreme)
      assert_true(screen_has(rows[row].label), "selected row " .. rows[row].label .. " is visible")
      enc(2, 1)
    end
    assert_equal(local_value("fx_row"), #rows, "E2 stops at the last row")
  end
end)

test("arc FX page: rings adjust filter freq/res, delay time/mix and show them", function()
  local context = load_strata()
  local device = context.arc.plug(1)
  show_page(2)
  local density = params:get("master_density")
  for ring, param_id in ipairs({ "filter_freq", "filter_res", "delay_time", "delay_mix" }) do
    local before = params:get(param_id)
    context.arc.turn(1, ring, 100)
    next_frame(context)
    assert_true(params:get(param_id) > before, "ring " .. ring .. " raises " .. param_id)
    local spec = params:lookup_param(param_id).controlspec
    assert_near(device.segments[ring].to, spec:unmap(params:get(param_id)) * math.pi * 2, 1e-9,
      "ring " .. ring .. " shows " .. param_id)
  end
  assert_equal(params:get("master_density"), density, "density is not on the FX rings")
end)

test("play/stop columns 1-4 on row 8 all light with the state (256 and 16x8)", function()
  for _, size in ipairs({ { 16, 16 }, { 16, 8 } }) do
    local context = load_strata()
    local device = context.grid.plug(1, size[1], size[2])
    for x = 1, 4 do
      assert_equal(device:get_led(x, 8), 4, size[2] .. " rows: play column " .. x .. " dim when stopped")
    end
    context.grid.press(1, 4, 8, 1)  -- column 4 starts the pattern
    assert_true(local_value("pattern_playing"), "column 4 plays")
    for x = 1, 4 do
      assert_equal(device:get_led(x, 8), 15, size[2] .. " rows: play column " .. x .. " lit while playing")
    end
    context.grid.press(1, 3, 8, 1)  -- column 3 stops it
    for x = 1, 4 do
      assert_equal(device:get_led(x, 8), 4, size[2] .. " rows: play column " .. x .. " dim after stop")
    end
  end
end)

test("grid page 4 shows FX faders in rows 3-7 and keeps row 8/16", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 16, 8, 1)              -- page 4
  context.grid.press(1, 16, 3, 1); assert_near(params:get("filter_freq"), 20000, 1)
  context.grid.press(1, 1, 7, 1); assert_equal(params:get("delay_mix"), 0)
  assert_equal(device:get_led(16, 3), 15, "filter freq fader at max")
  context.grid.press(1, 8, 4, 1)               -- filter res, column 8
  assert_near(params:get("filter_res"), 7 / 15, 0.01, "column 8 sets the proportional value")
  assert_equal(device:get_led(7, 4), 8, "bar below the value")
  assert_equal(device:get_led(9, 4), 0, "nothing above the value")
  local patterns = local_value("patterns")
  assert_equal(patterns[3][16], 0, "FX fader presses do not toggle pattern steps")
  -- rows 1-2 (buffers, columns 1-8) and 9-15 (sources, columns 1-10) are
  -- the buffer controls; the columns past them stay dark
  for x = 1, 16 do
    for _, y in ipairs({ 1, 2 }) do
      if x > 8 then assert_equal(device:get_led(x, y), 0, "row " .. y .. " column " .. x .. " dark on page 4") end
    end
    for y = 9, 15 do
      if x > 10 then assert_equal(device:get_led(x, y), 0, "row " .. y .. " column " .. x .. " dark on page 4") end
    end
  end
  context.grid.press(1, 1, 8, 1); assert_true(local_value("pattern_playing"), "row 8 play on page 4")
  context.grid.press(1, 1, 16, 1); assert_true(local_value("frozen")[1], "row 16 freeze on page 4")
  assert_equal(device:get_led(1, 16), 12, "row 16 shows freeze on page 4")
  assert_equal(device:get_led(16, 8), 15, "row 8 shows page 4 selected")
  -- FX changes made elsewhere move the faders
  params:set("delay_mix", 1)
  assert_equal(device:get_led(16, 7), 15, "delay mix fader follows a param change")
end)

test("a scene transition redraws the grid once per step on grid page 4", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 16, 8, 1)              -- page 4: the FX faders
  local fx = { filter_freq = 1000, filter_res = 0.2, filter_mix = 0.6, delay_time = 0.8,
    delay_feedback = 0.7, delay_mix = 0.5 }
  for id, value in pairs(fx) do params:set(id, value) end
  capture_scene(1)
  for id, value in pairs(fx) do params:set(id, value / 2) end
  recall_scene(1, 4)                           -- step 1 runs now
  for step = 2, 20 do
    local refreshes = device.refresh_count
    wake(context, "scene_transition_clock")
    assert_equal(device.refresh_count - refreshes, 1, "one grid redraw at step " .. step)
  end
  wake(context, "scene_transition_clock")                      -- the end: the instant recall
  assert_near(params:get("filter_freq"), 1000, 1, "transition landed")
  -- outside a transition each FX change still moves the faders at once
  local refreshes = device.refresh_count
  params:set("delay_mix", 0.1)
  assert_equal(device.refresh_count - refreshes, 1, "an FX edit redraws the grid")
end)

---------------------------------------------------------------------------
-- harness: stubs for the norns APIs used by later features
---------------------------------------------------------------------------

test("stub params support option, group, trigger, binary, file and set_action", function()
  load_strata()
  params:add_option("stub_opt", "opt", {"a", "b", "c"}, 2)
  assert_equal(params:get("stub_opt"), 2); assert_equal(params:string("stub_opt"), "b")
  assert_equal(params:lookup_param("stub_opt").count, 3)
  local fired
  params:set_action("stub_opt", function(v) fired = v end)
  params:set("stub_opt", 3); assert_equal(fired, 3)
  fired = nil
  params:set("stub_opt", 9); assert_equal(fired, nil, "option clamps to its count, unchanged value is silent")
  params:set("stub_opt", 1.7); assert_equal(params:get("stub_opt"), 1, "option index is floored")
  params:add_file("stub_file", "file", ""); params:set("stub_file", "/tmp/x.wav")
  assert_equal(params:get("stub_file"), "/tmp/x.wav")
  assert_equal(params:string("stub_file"), "x.wav", "file params display the file name")
  params:add_trigger("stub_trig", "trig"); params:add_binary("stub_bin", "bin", "toggle", 0)
  local triggered = 0
  params:set_action("stub_trig", function() triggered = triggered + 1 end)
  params:set("stub_trig", 1); params:set("stub_trig", 1)
  assert_equal(triggered, 2, "triggers fire on every set")
  params:set("stub_bin", 5); assert_equal(params:get("stub_bin"), 1, "toggle binary stores 0/1")
  -- core/params/binary.lua: a trigger binary fires for a value above 0 only (#51)
  params:add_binary("stub_trigger_bin", "trigger bin", "trigger")
  local trigger_fired = 0
  params:set_action("stub_trigger_bin", function() trigger_fired = trigger_fired + 1 end)
  params:set("stub_trigger_bin", 0); params:set("stub_trigger_bin", -1)
  assert_equal(trigger_fired, 0, "a trigger binary set to 0 or below does not fire")
  params:set("stub_trigger_bin", 1); params:set("stub_trigger_bin", 1); params:set("stub_trigger_bin")
  assert_equal(trigger_fired, 3, "it fires on every set above 0 (nil counts as 1)")
  params:add_group("stub_group", "group", 2); params:hide("stub_opt"); params:show("stub_opt")
  assert_true(params:visible("stub_opt"), "shown param is visible")
  params:hide("stub_file"); assert_true(not params:visible("stub_file"), "hidden param is not visible")
  params:add_text("stub_text", "text", ""); params:set("stub_text", "hello")
  assert_equal(params:string("stub_text"), "hello")
end)

-- norns cannot see where a group ends: it takes the next n params. The
-- stub requires each group's n params to end where its section does, at
-- the next group or separator, or at the end of the list after init()
test("stub params: each group is followed by exactly n params (#25)", function()
  -- the 3.0.1 review's mutation: the strata_midi group one param short or long
  for _, size in ipairs({2, 4}) do
    local mutated, count = patched_script('params:add_group%("strata_midi", "midi", 3%)',
      'params:add_group("strata_midi", "midi", ' .. size .. ')')
    assert_equal(count, 1, "test patch applies")
    local ok, message = pcall(load_strata, mutated)
    assert_true(not ok, "a strata_midi group of " .. size .. " is rejected")
    assert_true(tostring(message):find("strata_midi", 1, true) ~= nil, "the error names the group: " .. tostring(message))
  end
  local function assert_group_error(expected_text, func)
    local ok, message = pcall(func)
    assert_true(not ok, "expected a group size error (" .. expected_text .. ")")
    assert_true(tostring(message):find(expected_text, 1, true) ~= nil,
      "group error mentions " .. expected_text .. ": " .. tostring(message))
  end
  -- too few: the next group (or the end of the list) arrives first
  load_strata()
  params:add_separator("stub_sep"); params:add_group("stub_short", "short", 2); params:add_number("stub_a", "a")
  assert_group_error("stub_short", function() params:add_group("stub_next", "next", 1) end)
  local context = load_strata()
  params:add_separator("stub_sep"); params:add_group("stub_end", "end", 2); params:add_number("stub_a", "a")
  assert_group_error("stub_end", context.check_param_groups)
  -- too many: a param after the group's last that starts no new section
  load_strata()
  params:add_separator("stub_sep"); params:add_group("stub_long", "long", 1); params:add_number("stub_a", "a")
  assert_group_error("stub_long", function() params:add_number("stub_b", "b") end)
  -- exact groups, followed by a group, a separator or the end
  context = load_strata()
  params:add_separator("stub_sep")
  params:add_group("stub_one", "one", 1); params:add_number("stub_a", "a")
  params:add_group("stub_two", "two", 2); params:add_separator("stub_inner"); params:add_number("stub_b", "b")
  params:add_separator("stub_after"); params:add_number("stub_c", "c")
  params:add_group("stub_last", "last", 1); params:add_number("stub_d", "d")
  context.check_param_groups()
end)

test("stub params:write and params:read follow lua/core/paramset.lua", function()
  local context = load_strata()
  local pset_path = context.data_dir .. "stub.pset"
  params:set("reverb_mix", 0.25); params:set("filter_type", 2); params:set("lfo_depth_1", 40)
  params:write(pset_path, "my pset")
  local file = assert(io.open(pset_path, "r")); local text = file:read("*a"); file:close()
  assert_true(text:find('^%-%- my pset\n'), "the name line comes first")
  assert_true(text:find('"filter_type": 2\n', 1, true), "params are written as \"id\": value")
  assert_true(not text:find('"save_scenes"', 1, true), "triggers are not written")
  assert_true(not text:find('"strata_scenes"', 1, true), "separators are not written")
  params:set("reverb_mix", 0.5); params:set("filter_type", 1); params:set("lfo_depth_1", 0)
  local order, read_called = {}, nil
  params:set_action("filter_type", function() table.insert(order, "filter_type") end)
  params:set_action("reverb_mix", function() table.insert(order, "reverb_mix") end)
  params.action_read = function(filename, silent) read_called = { filename = filename, silent = silent } end
  params:read(pset_path)
  assert_equal(params:get("filter_type"), 2); assert_near(params:get("reverb_mix"), 0.25, 1e-9)
  assert_equal(params:get("lfo_depth_1"), 40)
  assert_equal(table.concat(order, ","), "filter_type,reverb_mix", "actions fire in file order, on a change")
  assert_equal(read_called and read_called.filename, pset_path, "action_read runs after the read")
  assert_equal(params.name, "my pset")
  params:set("filter_type", 1, true); order = {}
  params:read(pset_path, true)
  assert_equal(params:get("filter_type"), 2); assert_equal(#order, 0, "a silent read fires no actions")
  params.action_read = nil
end)

test("stub params store norns' numeric type constants in param.t", function()
  load_strata()
  -- lua/core/paramset.lua: ParamSet.tSEPARATOR = 0 ... tBINARY = 9
  local expected_codes = { tSEPARATOR = 0, tNUMBER = 1, tOPTION = 2, tCONTROL = 3, tFILE = 4, tTAPER = 5,
    tTRIGGER = 6, tGROUP = 7, tTEXT = 8, tBINARY = 9 }
  for name, code in pairs(expected_codes) do assert_equal(params[name], code, "params." .. name) end
  params:add_separator("stub_sep", "sep"); params:add_number("stub_num", "num", 0, 4, 1)
  params:add_option("stub_opt", "opt", {"a", "b"}, 1)
  params:add_control("stub_ctl", "ctl", controlspec.new(0, 1, "lin", 0, 0))
  params:add_file("stub_file", "file", ""); params:add_trigger("stub_trig", "trig")
  params:add_text("stub_text", "text", ""); params:add_binary("stub_bin", "bin", "toggle", 0)
  params:add_group("stub_group", "group", 1)
  local expected_types = { stub_sep = params.tSEPARATOR, stub_num = params.tNUMBER, stub_opt = params.tOPTION,
    stub_ctl = params.tCONTROL, stub_file = params.tFILE, stub_trig = params.tTRIGGER, stub_text = params.tTEXT,
    stub_bin = params.tBINARY, stub_group = params.tGROUP }
  for param_id, code in pairs(expected_types) do
    assert_equal(params:lookup_param(param_id).t, code, param_id .. " type code")
  end
end)

test("stub clock.run_for resumes sleeps and syncs in wake-time order and moves util.time", function()
  local context = load_strata(); finish_startup(context)
  params:set("clock_tempo", 120)                 -- 0.5 s per beat
  -- start on a beat, whatever init's start-up clock slept (STARTUP.voice_delay_seconds)
  context.clock.run_for((math.ceil(clock.get_beats() - 1e-9) - clock.get_beats()) * clock.get_beat_sec())
  local start = util.time()
  local events = {}
  local function log(name) table.insert(events, string.format("%s@%.3f", name, util.time() - start)) end
  clock.run(function() while true do clock.sleep(0.3); log("short") end end)
  clock.run(function() clock.sleep(1); log("long") end)
  clock.run(function() for _ = 1, 3 do clock.sync(1/4); log("sync") end end)
  local canceled = clock.run(function() clock.sleep(0.1); log("canceled") end)
  clock.cancel(canceled)
  context.clock.run_for(1)
  assert_equal(table.concat(events, " "),
    "sync@0.125 sync@0.250 short@0.300 sync@0.375 short@0.600 short@0.900 long@1.000",
    "wake-time order")
  assert_near(util.time(), start + 1, 1e-12, "util.time() ends at the start plus the run time")
  -- a scheduling delay on every wake-up: twenty short sleeps fall behind one long one
  events = {}
  clock.run(function() for _ = 1, 20 do clock.sleep(0.5) end; log("steps") end)
  clock.run(function() clock.sleep(10); log("once") end)
  local before = #events
  context.clock.run_for(11, 0.001)
  local order = {}
  for _, event in ipairs(events) do
    local name = event:match("^(%a+)@")
    if name == "steps" or name == "once" then table.insert(order, event) end
  end
  assert_equal(table.concat(order, " "), "once@11.001 steps@11.020", "latency accumulates per sleep")
  assert_true(#events > before, "the clocks ran")
end)

test("stub clock.advance is one time-ordered scheduler step and moves util.time (#27)", function()
  local context = load_strata()                  -- init's start-up clock sleeps STARTUP.voice_delay_seconds
  stop_frame_clock()                             -- (its 1/15 s ticks would come first)
  assert_true(STARTUP.voice_delay_seconds < 1, "this test needs the start-up clock to wake before the 1 s sleeps")
  local events = {}
  local function log(name) table.insert(events, string.format("%s@%.2f", name, util.time())) end
  clock.run(function() clock.sleep(2); log("two") end)
  clock.run(function() clock.sleep(1); log("one-a") end)
  clock.run(function() clock.sleep(1); log("one-b") end)
  context.clock.advance()
  assert_near(util.time(), STARTUP.voice_delay_seconds, 1e-12, "the first step is the start-up clock's wake-up")
  assert_true(local_value("voices")[2].active, "which started voice 2")
  assert_equal(#events, 0, "nothing else was due")
  context.clock.advance()
  assert_equal(table.concat(events, " "), "one-a@1.00 one-b@1.00", "both due at 1 s, in the order they slept")
  context.clock.advance()
  assert_equal(events[3], "two@2.00", "then the 2 s sleep")
  context.clock.advance()
  assert_near(util.time(), 2, 1e-12, "with nothing pending a step changes nothing")
  -- a clock overdue after util.time() jumped wakes at once, without moving time back
  clock.run(function() clock.sleep(1); log("late") end)
  context.set_time(10); context.clock.advance()
  assert_equal(events[4], "late@10.00", "an overdue sleep wakes at the current time")
end)

test("stub clock follows matron's scheduler: sync beats, offsets, FLT_EPSILON, tempo, resume values (#27)", function()
  local context = load_strata(); finish_startup(context)   -- util.time() STARTUP.voice_delay_seconds
  -- the beats below count from beat 1: the start-up delay must be one beat at 120 BPM
  assert_equal(STARTUP.voice_delay_seconds, 0.5, "this test assumes a 0.5 s start-up delay (beat 1 at 120 BPM)")
  assert_near(clock.get_beats(), 1, 1e-12, "the beat timeline runs at the clock tempo")
  -- a repeated sync counts from the sync's own beat (clock_scheduler.cc), so a
  -- coroutine that wakes a whole period late never skips a beat
  local wakes = {}
  local syncing = clock.run(function()
    while true do table.insert(wakes, clock.sync(1/4)) end
  end)
  context.clock.run_for(1, 0.125)                          -- a 16th's latency on every wake-up
  clock.cancel(syncing)
  assert_equal(#wakes, 7, "one wake-up per 16th after the first (0.75 s .. 1.5 s)")
  for index, beat in ipairs(wakes) do
    assert_near(beat, 1 + index * 0.25, 1e-9, "wake-up " .. index .. " resumes with the beat it fired on")
  end
  -- the offset argument (clock.sync(beats, offset)) moves the sync point
  local function wake_after(func)
    local from, woke = util.time(), nil
    clock.run(function() func(); woke = util.time() end)
    context.clock.run_for(4)
    return woke and (woke - from)
  end
  assert_near(clock.get_beats(), 3, 1e-9, "on beat 3")
  assert_near(wake_after(function() clock.sync(1, 0.5) end), 0.75, 1e-9, "beat 4.5: the next beat plus the offset")
  assert_near(wake_after(function() clock.sync(4, -0.5) end), 0.25, 1e-9,
    "beat 11.5: a negative offset lands before the next multiple (12)")
  assert_near(wake_after(function() clock.sync(2, -1.5) end), 0.75, 1e-9,
    "beat 20.5: never in the past (18.5), one period on")
  -- FLT_EPSILON: a clock within 2^-23 beat of a beat counts it as passed
  assert_near(clock.get_beats(), 27, 1e-9, "on beat 27")
  context.set_time((28 - 1.1e-7) * 0.5)
  assert_near(wake_after(function() clock.sync(1) end), 0.5 + 0.55e-7, 1e-9, "beat 29, not beat 28")
  -- a tempo change keeps the beat, and a waiting sync follows the new tempo
  context.set_time(18)
  assert_near(clock.get_beats(), 36, 1e-9, "on beat 36")
  params:set("clock_tempo", 60)
  assert_near(clock.get_beats(), 36, 1e-9, "the beat does not jump")
  assert_equal(clock.get_tempo(), 60, "the clock tempo follows clock_tempo")
  assert_near(wake_after(function() clock.sync(1) end), 1, 1e-9, "beat 37, 1 s a beat")
  local from, woke = util.time(), nil
  clock.run(function() clock.sync(1); woke = util.time() end)
  params:set("clock_tempo", 240)                           -- while it waits for beat 41
  context.clock.run_for(1)
  assert_near(woke - from, 0.25, 1e-9, "the waiting sync woke at the new tempo")
  -- sleeps resume with the clock time
  local slept
  from = util.time()
  clock.run(function() slept = clock.sleep(0.25) end)
  context.clock.run_for(0.5)
  assert_near(slept, from + 0.25, 1e-9, "clock.sleep returns the time it woke")
end)

test("stub clock errors: reported per wake-up, the other clocks keep running (#27)", function()
  local context = load_strata(); finish_startup(context)
  -- an error in a scheduler resume is reported, not raised, as l_report does
  local ticks = 0
  clock.run(function() while true do clock.sleep(0.1); ticks = ticks + 1 end end)
  local failing = clock.run(function() clock.sleep(0.25); error("tick failed") end)
  context.clock.run_for(1)
  assert_true(ticks >= 9, "the other clock kept running (" .. ticks .. " ticks)")
  local errors = context.clock.take_errors()
  assert_equal(#errors, 1, "one error reported")
  assert_true(errors[1]:find("tick failed", 1, true), "the coroutine's error")
  assert_equal(#context.clock.take_errors(), 0, "claimed errors are gone")
  assert_true(clock.threads[failing] ~= nil, "norns keeps the dead coroutine in clock.threads")
  -- a coroutine that cancels itself and then sleeps errors at its wake-up
  local own
  own = clock.run(function() clock.sleep(0.1); clock.cancel(own); clock.sleep(0.1); error("never reached") end)
  context.clock.run_for(0.5)
  errors = context.clock.take_errors()
  assert_equal(#errors, 1, "the self-canceled coroutine's wake-up errors")
  assert_true(errors[1]:find("expected", 1, true) and not errors[1]:find("never reached", 1, true),
    "coroutine.resume of the canceled coroutine raises: " .. tostring(errors[1]))
  -- the first run of clock.run is a direct call: its errors reach the caller
  assert_true(not pcall(clock.run, function() error("at once") end), "clock.run raises the first segment's error")
  local ok, message = pcall(clock.run, function() clock.sleep() end)
  assert_true(not ok and message:find("number expected", 1, true), "clock.sleep needs a number")
  ok, message = pcall(clock.run, function() clock.sync(0) end)
  assert_true(not ok and message:find("invalid sync beat", 1, true), "clock.sync needs a positive beat")
  assert_true(not pcall(clock.cancel, nil), "clock.cancel needs an id (luaL_checkinteger)")
  assert_equal(#context.clock.take_errors(), 0, "direct errors are raised, not reported")
end)

test("the runner adds the clock errors to a failing test's own error (#51)", function()
  local context = load_strata(); finish_startup(context)
  local function leave_clock_error()
    clock.run(function() clock.sleep(0); error("the clock failed") end)
    context.clock.run_for(0.01)
  end
  local ok, message = run_test(function() leave_clock_error(); error("the test failed") end)
  assert_true(not ok, "the test fails")
  assert_true(tostring(message):find("the test failed", 1, true), "its own error is kept: " .. tostring(message))
  assert_true(tostring(message):find("the clock failed", 1, true), "the clock error is added: " .. tostring(message))
  ok, message = run_test(leave_clock_error)
  assert_true(not ok and tostring(message):find("the clock failed", 1, true), "a passing test with a clock error fails")
  assert_true(run_test(function() end), "a passing test passes")
  assert_equal(#context.clock.take_errors(), 0, "the runner claimed them")
end)

test("stub clock.advance_until fails at once when its coroutine is canceled or nothing is pending (#51)", function()
  local context = load_strata(); finish_startup(context)
  stop_frame_clock()
  local ticker = clock.run(function() while true do clock.sleep(0.1) end end)
  local target = clock.run(function() clock.sleep(1) end)
  clock.run(function() clock.sleep(0.45); clock.cancel(target) end)
  local start = util.time()
  local ok, message = pcall(context.clock.advance_until, target)
  assert_true(not ok and tostring(message):find("canceled", 1, true), "a canceled target: " .. tostring(message))
  assert_near(util.time(), start + 0.45, 1e-9, "it stops at the cancel, the ticker running on no further")
  clock.cancel(ticker)
  ok, message = pcall(context.clock.advance_until, target)
  assert_true(not ok and tostring(message):find("nothing is pending", 1, true), "nothing pending: " .. tostring(message))
  local finished = clock.run(function() end)
  clock.run(function() clock.sleep(1) end)
  ok, message = pcall(context.clock.advance_until, finished)
  assert_true(not ok and tostring(message):find("is not waiting", 1, true), "a finished coroutine: " .. tostring(message))
end)

-- matron's scheduler keeps one event slot per coroutine (the lowest free one
-- when it first waits, kept until it is canceled or ends) and every tick
-- posts the due events in slot order; a sleep is due once the time reaches it
-- (>=), a sync once the beat is past it (>)
test("stub clock ties: equal wake times fire in event-slot order, a sync after a sleep (#51)", function()
  local context = load_strata(); finish_startup(context)
  stop_frame_clock()
  local events = {}
  local function log(name) table.insert(events, string.format("%s@%.2f", name, util.time())) end
  -- a placeholder takes the lowest free slot and B the next; once the
  -- placeholder is canceled, D (which sleeps after B) gets the lower slot
  local function start_tied_pair()
    local placeholder = clock.run(function() clock.sleep(100) end)
    clock.run(function() clock.sleep(1); log("B") end)
    clock.cancel(placeholder)
    clock.run(function() clock.sleep(1); log("D") end)
  end
  start_tied_pair()
  context.clock.run_for(1)
  assert_equal(table.concat(events, " "), "D@1.50 B@1.50", "event by event: slot order, not the order they slept")
  events = {}
  start_tied_pair()
  context.clock.advance()
  assert_equal(table.concat(events, " "), "D@2.50 B@2.50", "one step: both, in slot order")
  -- a sync (lower slot) and a sleep due at the same instant: the sleep first
  assert_near(clock.get_beats() % 1, 0, 1e-12, "on a beat")
  local function start_sync_and_sleep()
    clock.run(function() clock.sync(1); log("sync") end)
    clock.run(function() clock.sleep(clock.get_beat_sec()); log("sleep") end)
  end
  events = {}
  start_sync_and_sleep()
  context.clock.advance()
  assert_equal(table.concat(events, " "), "sleep@3.00", "the step at the tie fires the sleep only")
  context.clock.advance()
  assert_equal(table.concat(events, " "), "sleep@3.00 sync@3.00", "the next step, at the same time, the sync")
  events = {}
  start_sync_and_sleep()
  context.clock.run_for(1)
  assert_equal(table.concat(events, " "), "sleep@3.50 sync@3.50", "event by event: the sleep first too")
end)

-- matron's tick samples clock_time and clock_beat once and posts every due
-- event with them (clock_scheduler_tick_thread_run)
test("stub clock.advance resumes every event with the step's time and beat, whatever a tempo change in it (#51)", function()
  local context = load_strata(); finish_startup(context)   -- 0.5 s: beat 1 at 120 BPM
  stop_frame_clock()
  -- A wakes at 1 s and halves the tempo; S syncs to beat 2.5 (1.25 s), L
  -- sleeps to 1.5 s. util.time() jumps to 2 s (beat 4) past all three, so
  -- one step fires them, A first (its slot)
  local woke_on_beat, woke_at
  clock.run(function() clock.sleep(0.5); params:set("clock_tempo", 60) end)
  clock.run(function() woke_on_beat = clock.sync(1, 0.5) end)
  clock.run(function() woke_at = clock.sleep(1) end)
  context.set_time(2)
  context.clock.advance()
  assert_equal(clock.get_tempo(), 60, "A changed the tempo")
  assert_near(woke_on_beat, 4, 1e-9, "S resumes with the beat at the step, sampled before A ran")
  assert_near(woke_at, 2, 1e-9, "L resumes with the time at the step")
end)

test("stub param type codes come from one table; an unknown type is an error", function()
  load_strata()
  local codes = stubs.PARAM_TYPE_CODES
  assert_true(type(codes) == "table", "the stub exports PARAM_TYPE_CODES")
  local count = 0
  for name, code in pairs(codes) do
    assert_equal(params["t" .. name:upper()], code, "params.t" .. name:upper() .. " from PARAM_TYPE_CODES")
    count = count + 1
  end
  local constants = 0
  for key in pairs(getmetatable(params)) do
    if type(key) == "string" and key:match("^t%u+$") then
      assert_true(codes[key:sub(2):lower()] ~= nil, "params." .. key .. " is in PARAM_TYPE_CODES")
      constants = constants + 1
    end
  end
  assert_equal(constants, count, "one params.tX constant per PARAM_TYPE_CODES entry")
  -- the codes are written down once: no literal tX = <n> outside the table
  local file = assert(io.open(test_dir .. "/norns_stubs.lua", "r")); local source = file:read("*a"); file:close()
  assert_true(not source:find("%f[%w_]t%u+%s*=%s*%d"), "no type code assigned outside PARAM_TYPE_CODES")
  for _, bad_type in ipairs({ "bogus", "taper" }) do
    local ok, message = pcall(function() params:add { id = "stub_" .. bad_type, type = bad_type } end)
    assert_true(not ok, "params:add with type " .. bad_type .. " raises an error")
    assert_true(tostring(message):find(bad_type, 1, true), "the error names the type " .. bad_type)
    assert_equal(params.lookup["stub_" .. bad_type], nil, "nothing registered for type " .. bad_type)
  end
  assert_true(not pcall(function() params:add { id = "stub_untyped" } end), "params:add without a type raises an error")
end)

-- lua/core/paramset.lua's system_param_ids
local NORNS_SYSTEM_PARAM_IDS = {
  "comp_release", "monitor_level", "cut_input_eng", "comp_attack", "COMPRESSOR", "rev_cut_input",
  "rev_return_level", "tape_level", "reverb", "comp_post_gain", "rev_pre_delay", "clock_crow_out_div",
  "compressor", "cut_input_tape", "rev_lf_fc", "clock_crow_out", "REVERB", "rev_low_time", "comp_threshold",
  "rev_monitor_input", "LEVELS", "rev_hf_damping", "rev_eng_input", "input_level", "rev_tape_input",
  "clock_midi_out", "comp_pre_gain", "link_start_stop_sync", "softcut_level", "clock_reset", "link_quantum",
  "engine_level", "clock_tempo", "clock_source", "CLOCK", "output_level", "clock_crow_in_div", "rev_mid_time",
  "cut_input_adc", "comp_mix", "SOFTCUT", "monitor_mode", "headphone_gain", "comp_ratio",
}

test("stub params hold norns' system params, so a script id colliding with one fails (#27)", function()
  load_strata()
  local expected_types = { CLOCK = params.tGROUP, LEVELS = params.tGROUP, reverb = params.tOPTION,
    clock_tempo = params.tNUMBER, clock_source = params.tOPTION, clock_reset = params.tTRIGGER,
    output_level = params.tCONTROL, comp_mix = params.tCONTROL, headphone_gain = params.tNUMBER }
  for _, param_id in ipairs(NORNS_SYSTEM_PARAM_IDS) do
    if param_id == "clock_midi_out" then
      -- norns adds clock_midi_out_1..16, never clock_midi_out itself
      for port = 1, 16 do
        assert_equal(params:lookup_param("clock_midi_out_" .. port).t, params.tBINARY, "clock_midi_out_" .. port)
      end
      assert_equal(params.lookup.clock_midi_out, nil, "no clock_midi_out param, as on norns")
    else
      local param = params.lookup[param_id]
      assert_true(param ~= nil, "system param " .. param_id .. " registered")
      if expected_types[param_id] then assert_equal(param.t, expected_types[param_id], param_id .. " type") end
    end
  end
  assert_equal(params.params[1].id, "LEVELS", "system params come first, as norns adds them before the script")
  for _, param_id in ipairs({ "reverb", "comp_mix", "clock_source", "link_quantum" }) do
    local ok, message = pcall(params.add_number, params, param_id, "script param", 0, 1, 0)
    assert_true(not ok and tostring(message):find("collision", 1, true), param_id .. ": a script param collides")
  end
  -- the system groups hold exactly their params; the script's list starts after them
  for _, group in ipairs({ { "LEVELS", 9 }, { "REVERB", 11 }, { "COMPRESSOR", 8 }, { "SOFTCUT", 3 }, { "CLOCK", 29 } }) do
    assert_equal(params:get(group[1]), group[2], group[1] .. " size")
  end
  assert_equal(params:string("reverb"), "ON", "the reverb is on")
  assert_equal(params:get("clock_tempo"), 120)
end)

test("stub param strings and controlspec defaults follow core/params and core/controlspec (#27)", function()
  load_strata()
  -- Control:string: the value rounded to 0.01, a space and the units
  params:add_control("stub_time", "time", controlspec.new(0, 10, "lin", 0, 1.23456, "s"))
  assert_equal(params:string("stub_time"), "1.23 s", "control value and units")
  params:add_control("stub_plain", "plain", controlspec.new(0, 1, "lin", 0, 0.5))
  assert_equal(params:string("stub_plain"), "0.5 ", "no units: the space stays")
  -- Number:string and Binary:string return the value itself
  params:add_number("stub_count", "count", 0, 10, 3)
  assert_equal(params:string("stub_count"), 3, "a number param's string is its number")
  params:add_binary("stub_switch", "switch", "toggle", 1)
  assert_equal(params:string("stub_switch"), 1, "a binary param's string is its value")
  params:add_separator("stub_heading")
  assert_equal(params:string("stub_heading"), "stub_heading", "a separator shows its name (its id)")
  assert_equal(params:get("stub_heading"), "", "and has an empty value")
  -- a ControlSpec without a default has none: its control starts at raw 0
  local spec = controlspec.new(2, 8, "lin", 0)
  assert_equal(spec.default, nil, "no default (core/controlspec.lua reads an unset global)")
  params:add_control("stub_nodefault", "no default", spec)
  assert_equal(params:lookup_param("stub_nodefault").raw, 0, "raw 0")
  assert_equal(params:get("stub_nodefault"), 2, "the minimum")
  -- a control without a spec uses ControlSpec.UNIPOLAR
  params:add { type = "control", id = "stub_unipolar", name = "unipolar" }
  local unipolar = params:lookup_param("stub_unipolar").controlspec
  assert_true(unipolar.minval == 0 and unipolar.maxval == 1 and unipolar.default == 0, "UNIPOLAR")
  -- the db warp of norns' level params: -inf at 0, 0 dB in between, the maximum at 1
  local level = params:lookup_param("output_level").controlspec
  assert_equal(level:map(0), -math.huge, "db warp floor")
  assert_near(level:map(1), 6, 1e-9, "db warp top")
  assert_near(level:map(level:unmap(0)), 0, 1e-9, "db warp round trip")
end)

-- The first place source compares a param type (x.t) with a string literal,
-- either way round and with either quote, or nil
local function param_type_string_comparison(source)
  local patterns = {
    "[%w_%]%)]%.t%s*[=~]=%s*[\"']",            -- p.t == "option"
    "[\"']%s*[=~]=%s*[%w_%.:%(%)%[%]]-%.t%f[^%w_]", -- "option" == p.t
  }
  for _, pattern in ipairs(patterns) do
    local start, finish = source:find(pattern)
    if start then return source:sub(start, finish) end
  end
  return nil
end

test("strata.lua never compares a param type with a string", function()
  -- the check catches both quotes and both orders, and nothing else
  local caught = { 'if p.t == "option" then', "if p.t == 'option' then", 'if param.t ~= "number" then',
    'if "option" == p.t then', "if 'control' ~= params:lookup_param(id).t then", 'x = ("trigger" == p.t)' }
  for _, line in ipairs(caught) do
    assert_true(param_type_string_comparison(line), "caught: " .. line)
  end
  local allowed = { "if p.t == params.tOPTION then", 'if p.text == "option" then', 'if "option" == p.text then',
    'if p.type == "option" then', 'local s = "a.t == b"', "if params.tOPTION == p.t then" }
  for _, line in ipairs(allowed) do
    assert_equal(param_type_string_comparison(line), nil, "allowed: " .. line)
  end
  for _, source in ipairs(read_lua_sources()) do
    local found = param_type_string_comparison(source.text)
    assert_equal(found, nil, source.path .. ": param.t is numeric on norns; compare with params.tX")
  end
end)

test("stub lfo mirrors lib/lfo params and calls the action with scaled and raw", function()
  local context = load_strata()
  local LFO = require("lfo")
  local got
  local instance = LFO:add{ shape = "sine", min = -1, max = 1, depth = 0.5, mode = "free", period = 1,
    baseline = "center", action = function(scaled, raw) got = { scaled, raw } end }
  instance:add_params("stubtest", nil, "stub")
  -- the library's params, types and ranges (lua/lib/lfo.lua add_params)
  assert_equal(params:lookup_param("lfo_group_stubtest").n, 15, "group holds the library's 15 params")
  local expected_types = {
    lfo_stubtest = "option", lfo_shape_stubtest = "option", lfo_depth_stubtest = "number",
    lfo_phase_stubtest = "number", lfo_offset_stubtest = "number", lfo_scaled_stubtest = "text",
    lfo_raw_stubtest = "text", lfo_min_stubtest = "control", lfo_max_stubtest = "control",
    lfo_baseline_stubtest = "option", lfo_mode_stubtest = "option", lfo_clocked_stubtest = "option",
    lfo_free_stubtest = "control", lfo_reset_stubtest = "trigger", lfo_reset_target_stubtest = "option",
  }
  for param_id, param_type in pairs(expected_types) do
    assert_equal(params:lookup_param(param_id).t, params["t" .. param_type:upper()], param_id .. " type")
  end
  local depth_param = params:lookup_param("lfo_depth_stubtest")
  assert_equal(depth_param.min, 0); assert_equal(depth_param.max, 100)
  assert_equal(params:get("lfo_depth_stubtest"), 50, "depth is a percentage")
  assert_equal(params:lookup_param("lfo_shape_stubtest").count, 6)
  assert_equal(params:string("lfo_mode_stubtest"), "free")
  assert_equal(params:string("lfo_baseline_stubtest"), "from center")
  local free_spec = params:lookup_param("lfo_free_stubtest").controlspec
  assert_equal(free_spec.minval, 0.1); assert_equal(free_spec.maxval, 300)
  assert_near(params:get("lfo_free_stubtest"), 1, 1e-9, "free period")
  assert_equal(params:string("lfo_stubtest"), "off")
  assert_equal(instance:get("enabled"), 0)

  context.lfo.tick(instance, 1.0)
  assert_equal(got, nil, "disabled LFO never fires")
  params:set("lfo_stubtest", 2)
  assert_equal(instance:get("enabled"), 1, "state on enables the LFO")
  context.lfo.tick(instance, 1.0); assert_near(got[1], 0.5, 1e-9); assert_near(got[2], 1.0, 1e-9)
  context.lfo.tick(instance, 0.0); assert_near(got[1], -0.5, 1e-9, "center baseline is symmetric")
  assert_equal(params:get("lfo_scaled_stubtest"), -0.5, "scaled value is shown in the text param")
  params:set("lfo_depth_stubtest", 25)
  context.lfo.tick(instance, 1.0); assert_near(got[1], 0.25, 1e-9, "depth 25% scales to +-0.25")
  params:set("lfo_depth_stubtest", 0); got = nil
  context.lfo.tick(instance, 1.0); assert_equal(got, nil, "depth 0 never fires")
  params:set("lfo_depth_stubtest", 50); params:set("lfo_stubtest", 1); got = nil
  context.lfo.tick(instance, 1.0); assert_equal(got, nil, "state off stops the LFO")
  assert_equal(instance:get("enabled"), 0)
end)

-- lib/lfo.lua's reset_phase and change_period, line by line
test("stub lfo resets and rescales the phase counter as lib/lfo.lua does (#51)", function()
  load_strata()
  local LFO = require("lfo")
  local beat_sec = clock.get_beat_sec()
  local clocked = LFO:add{ mode = "clocked", period = 4 }
  local expected_clocked = { floor = 0.75 * 4, ceiling = 0.25 * 4, ["mid: falling"] = 0.5 * 4, ["mid: rising"] = 4 }
  for target, counter in pairs(expected_clocked) do
    clocked:set("reset_target", target); clocked:reset_phase()
    assert_near(clocked.phase_counter, counter, 1e-12, "clocked reset to " .. target)
  end
  local free = LFO:add{ mode = "free", period = 2 }
  local baseline = beat_sec / 2
  local expected_free = { floor = 0.75 / baseline, ceiling = 0.25 / baseline, ["mid: falling"] = 0.5 / baseline,
    ["mid: rising"] = baseline }
  for target, counter in pairs(expected_free) do
    free:set("reset_target", target); free:reset_phase()
    assert_near(free.phase_counter, counter, 1e-12, "free reset to " .. target)
  end
  -- a new period keeps the phase: the counter is rescaled (change_period)
  clocked:set("reset_target", "floor"); clocked:reset_phase()
  local ppqn = clocked:get("ppqn")
  clocked:set("period", 8)
  assert_equal(clocked:get("period"), 8)
  assert_near(clocked.phase_counter, ((3 + 1 / ppqn) / 4) * 8 - 1 / ppqn, 1e-12, "clocked counter rescaled")
  free:set("reset_target", "floor"); free:reset_phase()
  local counter = free.phase_counter
  free:set("period", 6)
  local phase = (counter + 1 / ppqn) * beat_sec / 2
  assert_near(free.phase_counter, (phase * 6 / beat_sec) - 1 / ppqn, 1e-12, "free counter rescaled")
  -- starting an LFO resets its phase first, as LFO:start does
  local started = LFO:add{ mode = "clocked", period = 2 }
  started:start()
  assert_near(started.phase_counter, 0.75 * 2, 1e-12, "start resets to the floor")
end)

test("stub midi delivers note_on, cc and pitchbend messages", function()
  local context = load_strata()
  -- port 3: Strata listens to port 1 (midi_device) and re-attaches it on midi.add
  local vport = midi.connect(3)
  local seen = {}
  vport.event = function(data) table.insert(seen, midi.to_msg(data)) end
  context.midi.send(3, { type = "note_on", note = 60, vel = 100, ch = 3 })
  context.midi.send(3, { type = "cc", cc = 1, val = 64, ch = 1 })
  context.midi.send(3, { type = "pitchbend", val = 8192 + 4096, ch = 1 })
  context.midi.send(3, { type = "note_on", note = 61, vel = 0, ch = 2 })
  assert_equal(seen[1].type, "note_on"); assert_equal(seen[1].note, 60); assert_equal(seen[1].ch, 3)
  assert_equal(seen[1].vel, 100)
  assert_equal(seen[2].type, "cc"); assert_equal(seen[2].cc, 1); assert_equal(seen[2].val, 64)
  assert_equal(seen[3].type, "pitchbend"); assert_equal(seen[3].val, 8192 + 4096)
  assert_equal(seen[4].type, "note_off", "velocity 0 note_on is a note_off, as in norns")
  assert_true(vport.device ~= nil and vport.name ~= "none", "sending plugs a device into the port")
  local added, removed
  midi.add = function(device) added = device end
  midi.remove = function(device) removed = device end
  local device = context.midi.plug(2, "keys")
  assert_equal(added, device); assert_equal(midi.connect(2).name, "keys")
  assert_equal(midi.devices[device.id], device)
  context.midi.unplug(2)
  assert_equal(removed, device); assert_equal(midi.connect(2).device, nil)
end)

test("stub arc segment, led and all follow lua/core/arc.lua and matron's LED buffer (#51)", function()
  local context = load_strata()
  local device = context.arc.plug(1)
  local vport = arc.connect(1)
  local function ring_levels(ring)
    local levels = {}
    for x = 1, 64 do levels[x] = device:get_led(ring, x) end
    return levels
  end
  -- segment sets each of the 64 LEDs through led(): half a turn at level 8
  local led_calls = 0
  local real_led = device.led
  device.led = function(self, ...) led_calls = led_calls + 1; return real_led(self, ...) end
  vport:segment(1, 0, math.pi, 8)
  assert_equal(led_calls, 64, "one led() call per LED")
  local levels = ring_levels(1)
  assert_equal(levels[1], 8); assert_equal(levels[32], 8); assert_equal(levels[33], 0)
  -- rel adds to the levels already there, clamped to 15 (dev_monome_arc_set_led)
  vport:segment(1, 0, math.pi / 2, 10, true)
  levels = ring_levels(1)
  assert_equal(levels[1], 15, "8 + 10 clamps to 15"); assert_equal(levels[16], 15)
  assert_equal(levels[17], 8, "rel adds 0 outside the segment"); assert_equal(levels[33], 0)
  -- without rel a segment overwrites every LED of its ring, lit or not
  vport:segment(1, 0, math.pi / 2, 4)
  levels = ring_levels(1)
  assert_equal(levels[1], 4); assert_equal(levels[17], 0, "outside the segment: 0")
  assert_equal(device.segments[1].level, 4, "the last segment is recorded for the ring tests")
  -- led and all, absolute and relative
  vport:led(2, 5, 9); assert_equal(device:get_led(2, 5), 9)
  vport:led(2, 5, -12, true); assert_equal(device:get_led(2, 5), 0, "rel clamps at 0")
  vport:all(3); assert_equal(device:get_led(4, 64), 3)
  vport:all(14, true); assert_equal(device:get_led(1, 1), 15); assert_equal(device:get_led(3, 2), 15)
  vport:all(0); assert_equal(device:get_led(1, 1), 0)
  assert_true(not pcall(vport.all, vport, 16), "an absolute all() level of 16 is out of range")
  assert_true(not pcall(vport.all, vport, -1), "and so is -1")
  vport:all(-1, true); assert_equal(device:get_led(1, 1), 0, "a relative all() clamps at 0")
  assert_true(next(device.segments) == nil, "all() clears the recorded segments")
  assert_true(not pcall(vport.led, vport, 5, 1, 1), "ring 5 does not exist")
  assert_true(not pcall(vport.led, vport, 1, 65, 1), "LED 65 does not exist")
  assert_true(not pcall(vport.led, vport, 1, 1, 16), "level 16 is out of range")
  assert_true(not pcall(vport.led, vport, 1, 1, 1.5), "levels are integers (luaL_checkinteger)")
end)

test("stub tab.save and tab.load are lib/tabutil.lua's (#27)", function()
  local context = load_strata()
  local shared = { 1, 2 }
  local path = context.data_dir .. "tabutil.data"
  tab.save({ version = 2, list = { "a", true, 0.1 + 0.2 }, first = shared, second = shared,
    skipped = function() end }, path)
  local file = assert(io.open(path, "r")); local text = file:read("*a"); file:close()
  assert_equal(text:sub(1, #"return {\n-- Table: {1}\n{\n"), "return {\n-- Table: {1}\n{\n", "tabutil's layout")
  assert_true(text:find('\n   ["version"]=2,\n', 1, true), "keys written as [\"key\"]=value")
  assert_true(not text:find("skipped", 1, true), "functions are not saved")
  local _, shared_count = text:gsub("%-%- Table: {", "")
  assert_equal(shared_count, 3, "the outer table, the list and the shared table once")
  local loaded = tab.load(path)
  assert_equal(loaded.version, 2)
  assert_equal(loaded.first, loaded.second, "a table saved twice loads as one table")
  assert_equal(loaded.list[1], "a"); assert_equal(loaded.list[2], true)
  assert_equal(loaded.list[3], 0.3, "numbers are written with tostring (%.14g), as on norns")
  assert_true(loaded.list[3] ~= 0.1 + 0.2, "so they lose precision")
  -- a plain `return {...}` file is not tabutil's: it has no table list, so it loads as nil
  file = assert(io.open(path, "w")); file:write("return { version = 2 }"); file:close()
  assert_equal(tab.load(path), nil, "a plain table file loads as nil")
  local missing, message = tab.load(context.data_dir .. "missing.data")
  assert_true(missing == nil and message ~= nil, "a missing file returns nil and the error")
end)

test("MIDI notes set pitch per source, start or retrigger the voice with velocity", function()
  local context = load_strata(); finish_startup(context)
  context.midi.send(1, { type = "note_on", note = 69, vel = 127, ch = 3 })   -- voice 3, off
  assert_near(params:get("v3_freq"), 440, 0.01); assert_true(local_value("voices")[3].active)
  local rt = context.calls_named("retrigger"); assert_equal(rt[#rt].args[1], 2); assert_near(rt[#rt].args[2], 1, 1e-9)
  params:set("v1_source", 2)
  context.midi.send(1, { type = "note_on", note = 72, vel = 64, ch = 1 })
  assert_near(params:get("v1_buf_rate"), 2, 1e-6); rt = context.calls_named("retrigger"); assert_near(rt[#rt].args[2], 64 / 127, 1e-9)
  params:set("v2_source", 10); context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 2 })  -- input source: no error
  context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 9 })  -- no voice: ignored
  params:set("v1_source", 1); params:set("midi_channel_mode", 2)        -- omni -> selected voice (1, synth again)
  context.midi.send(1, { type = "note_on", note = 57, vel = 100, ch = 9 })
  assert_near(params:get("v1_freq"), 220, 0.01)
end)

test("MIDI note details: start order, exact pitch, clamping, ignored channels", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  -- a stopped voice is started (voiceOn) before the retrigger
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 61, vel = 100, ch = 4 })
  local names = {}
  for _, call in ipairs(context.engine_calls) do table.insert(names, call.name) end
  local voice_on_at, retrigger_at
  for index, name in ipairs(names) do
    if name == "voiceOn" then voice_on_at = voice_on_at or index end
    if name == "retrigger" then retrigger_at = index end
  end
  assert_true(voice_on_at and retrigger_at and voice_on_at < retrigger_at, "voiceOn, then retrigger")
  assert_true(voices[4].active, "note on starts voice 4")
  -- equal temperament is not rounded to whole hertz
  assert_near(params:get("v4_freq"), 13.75 * 2 ^ ((61 - 9) / 12), 0.01, "note 61 = 277.18 Hz")
  -- a running voice is only retriggered (no second voiceOn)
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 62, vel = 50, ch = 4 })
  assert_equal(#context.calls_named("voiceOn"), 0, "running voice: no voiceOn")
  assert_equal(#context.calls_named("retrigger"), 1, "running voice: one retrigger")
  -- pitch is clamped to the voice's range
  context.midi.send(1, { type = "note_on", note = 127, vel = 100, ch = 4 })
  assert_near(params:get("v4_freq"), select(2, param_range("v4_freq")), 1e-9, "high notes clamp to the freq maximum")
  context.midi.send(1, { type = "note_on", note = 0, vel = 100, ch = 4 })
  assert_near(params:get("v4_freq"), (param_range("v4_freq")), 1e-9, "low notes clamp to the freq minimum")
  params:set("v5_source", 3)
  context.midi.send(1, { type = "note_on", note = 120, vel = 100, ch = 5 })
  assert_near(params:get("v5_buf_rate"), 4, 1e-9, "buffer rate clamps to 4")
  context.midi.send(1, { type = "note_on", note = 0, vel = 100, ch = 5 })
  assert_near(params:get("v5_buf_rate"), 0.25, 1e-9, "buffer rate clamps to 0.25")
  -- an input-sourced voice takes no pitch but still starts and accents
  params:set("v6_source", 10)
  local freq_before, rate_before = params:get("v6_freq"), params:get("v6_buf_rate")
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 90, vel = 127, ch = 6 })
  assert_equal(params:get("v6_freq"), freq_before); assert_equal(params:get("v6_buf_rate"), rate_before)
  assert_true(voices[6].active and #context.calls_named("retrigger") == 1, "input voice started and accented")
  -- per voice: channels 8-16 address no voice; other message types are ignored
  context.clear_engine_calls()
  for channel = 8, 16 do context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = channel }) end
  context.midi.send(1, { type = "cc", cc = 1, val = 64, ch = 1 })
  context.midi.send(1, { type = "program_change", val = 3, ch = 1 })
  context.midi.send(1, { type = "clock" })
  assert_equal(#context.engine_calls, 0, "nothing reaches the engine")
end)

test("note off mode and pitchbend", function()
  local context = load_strata(); finish_startup(context)
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 }); assert_true(local_value("voices")[1].active)
  params:set("midi_note_off", 2); context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 })
  assert_true(not local_value("voices")[1].active)
  context.midi.send(1, { type = "pitchbend", val = 8192 + 8191, ch = 2 })
  local calls = context.calls_named("setVoiceParam"); local last = calls[#calls]
  assert_equal(last.args[2], "bend"); assert_near(last.args[3], 2 ^ (2 / 12), 1e-3)
end)

test("voice off mode: the voice stops when its last held note is released", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  params:set("midi_note_off", 2)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  context.midi.send(1, { type = "note_on", note = 64, vel = 100, ch = 3 })
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 3 })
  assert_true(voices[3].active, "another note is still held")
  context.midi.send(1, { type = "note_on", note = 64, vel = 0, ch = 3 })   -- velocity 0 = note off
  assert_true(not voices[3].active, "last note released: voice off")
  -- a note during the release starts the voice again through voiceOn (the
  -- engine re-gates the releasing synths)
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 67, vel = 90, ch = 3 })
  assert_true(voices[3].active); assert_equal(#context.calls_named("voiceOn"), 1)
  -- omni: a note off reaches the voice its note on started, even if the selection moved
  params:set("midi_channel_mode", 2)
  context.midi.send(1, { type = "note_on", note = 48, vel = 100, ch = 1 })   -- selected voice 1
  local _, set_selected = find_upvalue("selected_voice"); set_selected(5)
  context.midi.send(1, { type = "note_off", note = 48, vel = 0, ch = 1 })
  assert_true(not voices[1].active, "voice 1 stops on its note's release")
  assert_true(not voices[5].active, "the newly selected voice is untouched")
  -- ignore mode leaves voices running
  params:set("midi_note_off", 1)
  context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 1 })
  context.midi.send(1, { type = "note_off", note = 50, vel = 0, ch = 1 })
  assert_true(voices[5].active, "ignore: note off does nothing")
end)

test("a MIDI-held voice stopped another way: its note off changes nothing and leaves nothing held", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  local midi_state = local_value("midi_state")
  context.grid.plug(1, 16, 16)
  params:set("midi_note_off", 2)
  for voice_idx = 1, 7 do
    if voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  capture_scene(1)   -- every voice off
  local function assert_nothing_held(voice_idx, channel, note, where)
    assert_equal(next(midi_state.held[voice_idx]), nil, where .. ": no note held on voice " .. voice_idx)
    local channel_notes = midi_state.note_voice[channel]
    assert_equal(channel_notes and channel_notes[note], nil, where .. ": note " .. note .. " not mapped")
  end
  -- K3 (and the arc button) never stop a running voice: on a held voice K3
  -- freezes it, and the note off then stops it as voice off mode says
  local _, set_selected = find_upvalue("selected_voice"); set_selected(2)
  show_page(1)
  context.midi.send(1, { type = "note_on", note = 62, vel = 100, ch = 2 })
  key(3, 1); key(3, 0)
  assert_true(voices[2].active and local_value("frozen")[2], "K3 freezes the held voice, it does not stop it")
  context.midi.send(1, { type = "note_off", note = 62, vel = 0, ch = 2 })
  assert_true(not voices[2].active, "K3: the note off stops the frozen voice")
  assert_nothing_held(2, 2, 62, "K3")
  toggle_freeze(2)
  local stoppers = {
    { name = "grid voice toggle", voice = 4, stop = function() context.grid.press(1, 8 + 4, 14, 1) end },
    { name = "scene recall", voice = 6, stop = function() recall_scene(1, 0) end },
  }
  for _, stopper in ipairs(stoppers) do
    local voice_idx = stopper.voice
    context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = voice_idx })
    assert_true(voices[voice_idx].active, stopper.name .. ": the note started the voice")
    assert_true(midi_state.held[voice_idx][60], stopper.name .. ": note 60 held")
    stopper.stop()
    assert_true(not voices[voice_idx].active, stopper.name .. ": the voice stopped")
    context.clear_engine_calls()
    local frozen = deep_copy(local_value("frozen"))
    context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = voice_idx })
    assert_equal(#context.engine_calls, 0, stopper.name .. ": the note off sends nothing")
    for other = 1, 7 do
      assert_true(not voices[other].active, stopper.name .. ": voice " .. other .. " still off")
      assert_equal(local_value("frozen")[other], frozen[other], stopper.name .. ": voice " .. other .. " freeze unchanged")
    end
    assert_nothing_held(voice_idx, voice_idx, 60, stopper.name)
  end
end)

test("pitchbend: range, buffer voices, stopped voices, restarts and resets", function()
  local context = load_strata(); finish_startup(context)
  local function last_bend(engine_voice)
    local value
    for _, call in ipairs(context.calls_named("setVoiceParam")) do
      if call.args[1] == engine_voice and call.args[2] == "bend" then value = call.args[3] end
    end
    return value
  end
  context.midi.send(1, { type = "pitchbend", val = 0, ch = 1 })
  assert_near(last_bend(0), 2 ^ (-2 / 12), 1e-9, "full down = -2 semitones")
  context.midi.send(1, { type = "pitchbend", val = 8192, ch = 1 })
  assert_near(last_bend(0), 1, 1e-12, "center = 1")
  -- a buffer-sourced voice gets the same voice-level bend (the engine passes it to strataGrainBuf)
  params:set("v2_source", 4)
  context.clear_engine_calls()
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 2 })
  assert_near(last_bend(1), 2 ^ (1 / 12), 1e-9, "buffer voice bend")
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    assert_true(call.args[2] ~= "bend", "bend is not a grain param")
  end
  -- bend is transient: not a param and not in scenes
  assert_equal(params.lookup["v2_bend"], nil, "no bend param")
  capture_scene(1)
  assert_equal(local_value("scenes")[1].data.voices[2].params.bend, nil, "scenes do not capture bend")
  -- a stopped voice remembers the wheel and gets it when it starts
  context.clear_engine_calls()
  context.midi.send(1, { type = "pitchbend", val = 8192 - 4096, ch = 4 })
  assert_equal(last_bend(3), nil, "stopped voice: nothing sent")
  toggle_voice(4)
  assert_near(last_bend(3), 2 ^ (-1 / 12), 1e-9, "starting the voice sends the held bend")
  -- changing the channel mode re-centers every bent voice
  context.clear_engine_calls()
  params:set("midi_channel_mode", 2)
  assert_near(last_bend(1), 1, 1e-12, "voice 2 re-centered"); assert_near(last_bend(3), 1, 1e-12, "voice 4 re-centered")
  assert_equal(last_bend(0), nil, "an unbent voice gets nothing")
end)

test("omni pitchbend follows the selection: the old voice re-centers, the new one takes the wheel", function()
  local context = load_strata(); finish_startup(context)
  local bend = local_value("midi_state").bend
  local function last_bend(engine_voice)
    local value
    for _, call in ipairs(context.calls_named("setVoiceParam")) do
      if call.args[1] == engine_voice and call.args[2] == "bend" then value = call.args[3] end
    end
    return value
  end
  local up = 2 ^ (1 / 12)
  params:set("midi_channel_mode", 2); show_page(1)
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 1 })   -- bends voice 1
  context.clear_engine_calls()
  enc(2, 1)   -- voice 2, wheel still up
  assert_near(last_bend(0), 1, 1e-12, "voice 1 re-centered"); assert_equal(bend[1], 1)
  assert_near(last_bend(1), up, 1e-9, "voice 2 takes the wheel"); assert_near(bend[2], up, 1e-9)
  -- a stopped voice keeps the wheel for its start
  context.clear_engine_calls()
  enc(2, 1)   -- voice 3 (stopped)
  assert_near(last_bend(1), 1, 1e-12, "voice 2 re-centered")
  assert_equal(last_bend(2), nil, "nothing sent to a stopped voice"); assert_near(bend[3], up, 1e-9)
  toggle_voice(3); assert_near(last_bend(2), up, 1e-9, "starting it sends the wheel")
  -- BUFFER page E2 is the same selection
  show_page(4); context.clear_engine_calls()
  enc(2, -1)
  assert_near(last_bend(2), 1, 1e-12, "voice 3 re-centered"); assert_near(last_bend(1), up, 1e-9, "voice 2 bent again")
  -- E2 against the end of the list changes nothing
  show_page(1); enc(2, -1)   -- voice 1
  context.clear_engine_calls(); enc(2, -1)
  assert_equal(#context.calls_named("setVoiceParam"), 0, "no selection change, no bend")
  -- wheel centered: moving the selection sends nothing
  context.midi.send(1, { type = "pitchbend", val = 8192, ch = 1 })
  context.clear_engine_calls(); enc(2, 1)
  assert_equal(#context.calls_named("setVoiceParam"), 0, "a centered wheel moves nothing")
  -- per voice: bends stay with their channels' voices
  params:set("midi_channel_mode", 1)
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 1 })
  context.clear_engine_calls(); enc(2, 1)
  assert_equal(#context.calls_named("setVoiceParam"), 0, "per voice mode: the selection does not move bends")
  assert_near(bend[1], up, 1e-9)
end)

test("MIDI device param, hot-plug and the SETUP page", function()
  local context = load_strata(); finish_startup(context)
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  assert_equal(params:get("midi_device"), 1); assert_equal(params:get("midi_channel_mode"), 1)
  assert_equal(params:get("midi_note_off"), 1)
  assert_equal(params:string("midi_channel_mode"), "per voice")
  show_page(5)
  assert_true(screen_has("midi 1: none"), "no device on port 1")
  assert_true(screen_has("ch: per voice"), "channel mode shown")
  context.midi.plug(1, "keys"); next_frame(context)
  assert_true(screen_has("midi 1: keys"), "plugging a device redraws SETUP")
  -- E2 selects the port; events on the old port no longer reach Strata
  enc(2, 1); next_frame(context); assert_equal(params:get("midi_device"), 2)
  assert_true(screen_has("midi 2: none"))
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_equal(#context.engine_calls, 0, "port 1 is no longer listened to")
  context.midi.send(2, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_true(#context.calls_named("retrigger") == 1, "port 2 is")
  -- E3 sets the channel mode
  enc(3, 1); next_frame(context); assert_equal(params:get("midi_channel_mode"), 2)
  assert_true(screen_has("ch: omni to selected"))
  assert_true(screen_has("midi 2: stub midi"), "the device that played is shown")
  -- unplugging the selected port's device shows none on the next frame
  context.midi.unplug(2); next_frame(context)
  assert_true(screen_has("midi 2: none"), "unplugging redraws SETUP without the device")
  -- a long device name is cut to fit the screen
  context.midi.plug(2, "Very Long Manufacturer Name USB MIDI Interface Port 1"); next_frame(context)
  local midi_line
  for _, entry in ipairs(context.screen.texts) do
    if entry.text:find("^midi 2: ") then midi_line = entry.text end
  end
  assert_true(midi_line and #midi_line < #"midi 2: Very Long Manufacturer Name USB MIDI Interface Port 1", "name shortened")
  assert_screen_layout(context, "SETUP with a long MIDI device name")
  assert_true(params:get("midi_device") <= 4 and select(2, param_range("midi_device")) == 4, "ports 1-4")
  -- a re-plug reattaches: the vport still delivers to Strata
  context.clear_engine_calls()
  context.midi.send(2, { type = "note_on", note = 62, vel = 100, ch = 1 })
  assert_equal(#context.calls_named("retrigger"), 1, "re-plugged device plays")
  cleanup()
  assert_equal(midi.connect(2).event, nil, "cleanup detaches the MIDI handler")
end)

test("stub fileselect, musicutil, polls and audio path", function()
  local context = load_strata()
  local picked
  assert_equal(rawget(_G, "fileselect"), nil, "fileselect is a module, not a global")
  local fileselect = require("fileselect")
  assert_equal(fileselect, context.fileselect)
  fileselect.enter(_path.audio, function(path) picked = path end, "audio")
  assert_equal(fileselect.last.folder, _path.audio); assert_equal(fileselect.last.filter, "audio")
  fileselect.last.callback("/x.wav"); assert_equal(picked, "/x.wav")
  assert_equal(_path.audio, context.audio_dir)
  assert_true(util.file_exists(_path.audio), "audio dir exists")
  local file = assert(io.open(_path.audio .. "a.wav", "w")); file:write("x"); file:close()
  local listing = util.scandir(_path.audio)
  assert_equal(#listing, 1); assert_equal(listing[1], "a.wav")
  assert_equal(util.os_capture("echo '  hi  '"), "hi")
  local musicutil = require("musicutil")
  assert_near(musicutil.note_num_to_freq(69), 440, 1e-9); assert_near(musicutil.note_num_to_freq(57), 220, 1e-9)
  local values = {}
  local amp_poll = poll.set("amp_in_l", function(value) table.insert(values, value) end)
  assert_true(amp_poll ~= nil, "system polls exist")
  assert_equal(poll.set("no_such_poll", function() end), nil, "unknown polls return nil, as in norns")
  amp_poll:start()
  context.polls.fire("amp_in_l", 0.25)
  amp_poll:stop()
  context.polls.fire("amp_in_l", 0.5)
  assert_equal(#values, 1, "stopped polls do not fire"); assert_equal(values[1], 0.25)
end)

---------------------------------------------------------------------------
-- audio sources and buffers
---------------------------------------------------------------------------

test("source switching syncs through setGrainSource and swaps the main param", function()
  local context = load_strata(); finish_startup(context)
  context.clear_engine_calls(); params:set("v1_source", 4)      -- buf 3
  local calls = context.calls_named("setGrainSource")
  assert_equal(#calls, 1, "one setGrainSource per switch")
  assert_equal(calls[1].args[1], 0); assert_equal(calls[1].args[2], 3)
  assert_equal(main_param_id(1), "v1_buf_pos"); assert_equal(main_param_label(1), "pos")
  params:set("v1_source", 10); calls = context.calls_named("setGrainSource"); assert_equal(calls[#calls].args[2], 9)
  assert_equal(main_param_id(1), "v1_grain_size", "input source shows grain size (a 3.0 decision: its buffer params are dead too)")
  params:set("v1_source", 1); assert_equal(main_param_id(1), "v1_freq")
  -- a stopped voice's source is sent at once (so voiceOn builds the right synths) and nothing else is
  context.clear_engine_calls(); params:set("v3_source", 5)
  assert_equal(#context.engine_calls, 1, "stopped voice: only the source is sent")
  assert_equal(context.engine_calls[1].name, "setGrainSource")
  assert_equal(context.engine_calls[1].args[1], 2); assert_equal(context.engine_calls[1].args[2], 4)
  toggle_voice(3); params:set("v3_source", 2); toggle_voice(3)          -- on, edit, off
  context.clear_engine_calls(); toggle_voice(3)                          -- on again: synced
  local sent = engine_state_for_voice(context.engine_calls, 2)
  assert_equal(context.calls_named("setGrainSource")[1].args[2], 1, "started voice sends its source")
  assert_equal(sent.grain.bufPos, 0); assert_equal(sent.grain.bufRate, 1); assert_equal(sent.grain.bufScan, 0)
  -- a running voice's switch resends the rest of its state after the source
  context.clear_engine_calls(); params:set("v3_source", 10)
  assert_equal(context.engine_calls[1].name, "setGrainSource")
  assert_equal(#context.calls_named("setGrainSource"), 1, "no second setGrainSource")
  assert_true(#context.calls_named("setVoiceParam") > 0, "running voice: voice state resent")
  assert_equal(engine_state_for_voice(context.engine_calls, 2).grain.bufPos, 0, "grain state resent")
  assert_equal(#context.calls_named("voiceOn"), 0, "switching creates no voice")
end)

test("source and buffer params: options, defaults, voices table, labels", function()
  load_strata()
  local voices = local_value("voices")
  local names = {}
  for index = 1, 10 do params:set("v1_source", index); names[index] = params:string("v1_source") end
  assert_equal(table.concat(names, ","), "synth,buf 1,buf 2,buf 3,buf 4,buf 5,buf 6,buf 7,buf 8,input")
  params:set("v1_source", 1)
  local expected = { buf_pos = 0, buf_rate = 1, buf_scan = 0 }
  for voice_idx = 1, 7 do
    local prefix = "v" .. voice_idx .. "_"
    local source = params:lookup_param(prefix .. "source")
    assert_equal(source.t, params.tOPTION, "source is an option")
    assert_equal(source.count, 10, "synth, eight buffers, input")
    assert_equal(params:get(prefix .. "source"), 1, "default synth")
    assert_equal(voices[voice_idx].source, 1, "voices table holds the source index")
    for key, default in pairs(expected) do
      assert_near(params:get(prefix .. key), default, 1e-9, prefix .. key .. " default")
      assert_near(voices[voice_idx].grain[key], default, 1e-9, "voices[" .. voice_idx .. "].grain." .. key)
      assert_equal(local_value("GRAIN_PARAM_IDS")[key], key, key .. " in GRAIN_PARAM_IDS")
    end
  end
  assert_equal(param_range("v1_buf_pos"), 0); assert_equal(select(2, param_range("v1_buf_pos")), 1)
  assert_equal(param_range("v1_buf_rate"), 0.25); assert_equal(select(2, param_range("v1_buf_rate")), 4)
  assert_equal(param_range("v1_buf_scan"), -2); assert_equal(select(2, param_range("v1_buf_scan")), 2)
  assert_equal(params:lookup_param("v1_buf_rate").controlspec.warp_name, "exp", "buf rate is exponential")
  params:set("v2_buf_rate", 2); assert_near(voices[2].grain.buf_rate, 2, 1e-9)
  params:set("v2_buf_scan", -1); assert_near(voices[2].grain.buf_scan, -1, 1e-9)
  params:set("v2_buf_pos", 0.123); assert_near(voices[2].grain.buf_pos, 0.123, 1e-9, "buf_pos is not quantized")
  assert_true(not voice_uses_buffer(2), "synth source is not a buffer")
  assert_equal(voice_source_label(2), "synth")
  params:set("v2_source", 9); assert_true(voice_uses_buffer(2)); assert_equal(voice_source_label(2), "buf 8")
  params:set("v2_source", 10); assert_true(not voice_uses_buffer(2), "input is not a buffer")
  assert_equal(voice_source_label(2), "input")
  -- every per-voice scene default equals its param default
  local found = {}
  for _, field in ipairs(local_value("VOICE_SCENE_DEFAULTS")) do
    local suffix = field.path[1] == "grain" and local_value("GRAIN_PARAM_IDS")[field.path[2]] or field.path[1]
    found[suffix] = true
    local param = params:lookup_param("v1_" .. suffix)
    local param_default = param.controlspec and param.controlspec.default or param.default
    assert_equal(field.default, param_default, suffix .. " scene default")
  end
  for _, suffix in ipairs({ "source", "buf_pos", "buf_rate", "buf_scan" }) do
    assert_true(found[suffix], suffix .. " has a scene default")
  end
end)

test("buffer-sourced voices: E3, arc ring 2 and MAIN use buf_pos", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  params:set("v1_source", 3)
  params:set("v1_buf_pos", 0.5)
  local freq = params:get("v1_freq")
  enc(3, 2)
  assert_near(params:get("v1_buf_pos"), 0.52, 1e-6, "E3 moves buf_pos")
  assert_equal(params:get("v1_freq"), freq, "E3 leaves the synth freq alone")
  context.arc.turn(1, 2, 10); next_frame(context)
  assert_true(params:get("v1_buf_pos") > 0.52, "arc ring 2 moves buf_pos")
  assert_equal(params:get("v1_freq"), freq, "arc ring 2 leaves the synth freq alone")
  assert_near(device.segments[2].to, params:get("v1_buf_pos") * math.pi * 2, 1e-9, "ring 2 shows buf_pos")
  redraw()
  local label, value
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 65 and entry.y == 42 then label = entry.text end
    if entry.x == 65 and entry.y == 50 then value = entry.text end
  end
  assert_equal(label, "pos", "MAIN label")
  assert_equal(value, string.format("%.2f", params:get("v1_buf_pos")), "MAIN value")
end)

test("randomize and mutate touch buffer params, never source", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_source", 2); local freq = params:get("v1_freq")
  local synth_before = deep_copy(local_value("voices")[1].params)
  math.randomseed(7); randomize_voice(1)
  assert_equal(params:get("v1_freq"), freq, "synth params untouched for a buffer voice")
  assert_true(params:get("v1_buf_rate") ~= 1 or params:get("v1_buf_pos") ~= 0, "buffer params randomized")
  for _ = 1, 20 do
    randomize_voice(1)
    assert_true(params:get("v1_buf_rate") >= 0.5 - 1e-9 and params:get("v1_buf_rate") <= 2 + 1e-9, "rate 0.5-2")
    assert_true(math.abs(params:get("v1_buf_scan")) <= 0.5 + 1e-9, "scan -0.5..0.5")
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  local pos_before = params:get("v1_buf_pos")
  gentle_mutate()
  assert_equal(params:get("v1_source"), 2)
  assert_true(params:get("v1_buf_pos") ~= pos_before, "mutation moves buf_pos")
  for key, value in pairs(synth_before) do
    assert_equal(local_value("voices")[1].params[key], value, "mutation leaves synth " .. key .. " alone")
  end
  -- synth-sourced voices keep mutating synth params, never the source
  params:set("v1_source", 1); local mutated = false
  for _ = 1, 5 do gentle_mutate(); if params:get("v1_freq") ~= freq then mutated = true end end
  assert_true(mutated, "synth source mutates synth params again")
  for _ = 1, 20 do randomize_voice(1); gentle_mutate() end
  assert_equal(params:get("v1_source"), 1, "source never randomized or mutated")
  -- freeze covers buffer params
  params:set("v1_source", 5); toggle_freeze(1)
  local frozen_state = deep_copy(local_value("voices")[1].grain)
  randomize_voice(1); gentle_mutate(); for _ = 1, 10 do drift_update() end
  for key, value in pairs(frozen_state) do
    assert_equal(local_value("voices")[1].grain[key], value, "frozen buffer voice keeps " .. key)
  end
end)

test("randomize and mutation work in normalized space for exponential params", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 (synth source) running
  local spec = params:lookup_param("v1_freq").controlspec
  assert_true(spec.minval == 20 and spec.maxval == 2000 and spec.warp_name == "exp",
    "voice 1 freq is the 20-2000 Hz exponential spec this test covers")
  local midpoint = math.sqrt(spec.minval * spec.maxval)
  math.randomseed(11)
  local below, draws = 0, 2000
  for _ = 1, draws do
    randomize_voice(1)
    if params:get("v1_freq") < midpoint then below = below + 1 end
  end
  local share = below / draws
  assert_true(share > 0.35 and share < 0.65,
    "freq randomize (20-2000 Hz exp) lands below the geometric midpoint about half the time (" .. share .. ")")
  -- a mutation step moves freq by at most amount in normalized distance
  params:set("mutation_probability", 1); params:set("mutation_amount", 0.25)
  local max_step = 0
  for _ = 1, 300 do
    params:set("v1_freq", spec:map(math.random()))
    local before = spec:unmap(params:get("v1_freq"))
    gentle_mutate()
    max_step = math.max(max_step, math.abs(spec:unmap(params:get("v1_freq")) - before))
  end
  assert_true(max_step <= 0.25 + 1e-6, "normalized mutation step within amount (" .. max_step .. ")")
  assert_true(max_step > 0.05, "mutation actually moves freq (" .. max_step .. ")")
end)

test("gentle_mutate skips every grain key in DISCRETE_GRAIN_KEYS", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 running
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  params:set("v1_grain_env", 3); params:set("v1_grain_mode", 2)
  math.randomseed(13)
  for _ = 1, 50 do gentle_mutate() end
  assert_equal(params:get("v1_grain_env"), 3, "envelope shape never mutates")
  assert_equal(params:get("v1_grain_mode"), 2, "grain mode never mutates")
  -- the guard is the table: any grain key marked discrete is left alone
  local discrete = local_value("DISCRETE_GRAIN_KEYS")
  for _, key in ipairs({ "size", "pitch", "spread", "buf_pos", "buf_rate", "buf_scan" }) do discrete[key] = 1 end
  for _, source in ipairs({ 1, 2, 10 }) do   -- synth, buffer, input
    params:set("v1_source", source)
    local before = deep_copy(local_value("voices")[1].grain)
    for _ = 1, 20 do gentle_mutate() end
    for key, value in pairs(before) do
      assert_equal(local_value("voices")[1].grain[key], value, "source " .. source .. ": grain " .. key .. " skipped")
    end
  end
end)

test("buffer position drifts subtly and reverts to the user-set position", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 running
  assert_true(local_value("voices")[1].active, "voice 1 on")
  params:set("v1_source", 2); params:set("v1_buf_pos", 0.4)
  local synth_freq = params:get("v1_freq")
  math.randomseed(3)
  local max_offset = 0
  for _ = 1, 3000 do
    drift_update()
    max_offset = math.max(max_offset, math.abs(params:get("v1_buf_pos") - 0.4))
  end
  assert_true(max_offset > 0, "buf_pos drifts")
  assert_true(max_offset < 0.05, "drift stays subtle (max " .. max_offset .. ")")
  assert_equal(params:get("v1_freq"), synth_freq, "drift leaves synth params alone")
  params:set("v1_buf_pos", 0.8)
  for _ = 1, 3000 do drift_update() end
  assert_true(math.abs(params:get("v1_buf_pos") - 0.8) < 0.05, "a new user position becomes the center")
  -- a synth-sourced voice's position does not drift
  params:set("v1_source", 1); local pos = params:get("v1_buf_pos")
  for _ = 1, 100 do drift_update() end
  assert_equal(params:get("v1_buf_pos"), pos, "synth source: no position drift")
end)

test("mean_reverting_step: one random step plus a pull toward the base, used by both drifts", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 running
  math.randomseed(5); local random = math.random()
  math.randomseed(5)
  assert_near(mean_reverting_step(1.2, 1.0, 0.004, 0.01), 1.2 + (random - 0.5) * 0.004 - 0.2 * 0.01, 1e-12,
    "current + (random - 0.5) * step - (current - base) * reversion")
  -- drift_update's grain pitch and buffer position steps are exactly that
  params:set("v1_source", 2); params:set("v1_grain_pitch", 1.5); params:set("v1_buf_pos", 0.4)
  for _ = 1, 50 do drift_update() end
  local pitch, position = params:get("v1_grain_pitch"), params:get("v1_buf_pos")
  math.randomseed(9); local pitch_random = math.random(); local position_random = math.random()
  math.randomseed(9); drift_update()
  assert_near(params:get("v1_grain_pitch"), pitch + (pitch_random - 0.5) * 0.004 - (pitch - 1.5) * 0.01, 1e-12,
    "grain pitch drift step")
  assert_near(params:get("v1_buf_pos"), position + (position_random - 0.5) * 0.002 - (position - 0.4) * 0.01, 1e-12,
    "buffer position drift step")
end)

test("transition skips discrete voice fields; scenes keep source and buffer params", function()
  local context = load_strata(); finish_startup(context)
  params:set("v2_source", 3); params:set("v2_buf_pos", 0.7); capture_scene(1)
  assert_equal(local_value("scenes")[1].data.voices[2].source, 3, "source captured")
  params:set("v2_source", 1); params:set("v2_buf_pos", 0.1)
  recall_scene(1, 4); wake(context, "scene_transition_clock")
  assert_equal(params:get("v2_source"), 1, "source only changes at the end of a transition")
  assert_true(params:get("v2_buf_pos") > 0.1, "buf_pos interpolates")
  for _, target in ipairs(scene_transition_targets(local_value("scenes")[1].data)) do
    assert_true(not target.id:find("_source$"), target.id .. " is not crossfaded")
  end
  context.clock.run_for(5)   -- past the 4 s transition
  assert_equal(params:get("v2_source"), 3); assert_near(params:get("v2_buf_pos"), 0.7, 1e-6)
  -- validation and migration of the source field
  local scene = deep_copy(local_value("scenes")[1])
  assert_true(validate_scene(scene), "captured scene validates")
  for _, bad in ipairs({ 0, 11, 2.5, "buf 1" }) do
    scene.data.voices[2].source = bad
    assert_true(not validate_scene(scene), "source " .. tostring(bad) .. " rejected")
  end
  for voice_idx = 1, 7 do
    scene.data.voices[voice_idx].source = nil
    for _, key in ipairs({ "buf_pos", "buf_rate", "buf_scan" }) do scene.data.voices[voice_idx].grain[key] = nil end
  end
  migrate_scene(scene, 1)
  assert_equal(scene.data.voices[2].source, 1, "missing source migrates to synth")
  assert_equal(scene.data.voices[2].grain.buf_rate, 1, "missing buf_rate migrates to 1")
  assert_equal(scene.data.voices[2].grain.buf_pos, 0, "missing buf_pos migrates to 0")
  assert_true(validate_scene(scene), "migrated scene validates")
end)

test("buffer faders replace synth faders for a buffer-sourced voice", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  local press = function(x, y) context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0) end
  press(14, 8); press(1, 14)            -- grid page 2, voice 1 (resonator: 6 fader pages)
  press(6, 13); assert_equal(local_value("param_page"), 6)
  params:set("v1_source", 2)
  local ids = fader_param_ids(1)
  assert_equal(ids[1], "v1_buf_pos"); assert_equal(ids[2], "v1_buf_rate")
  assert_equal(ids[3], "v1_buf_scan"); assert_equal(ids[4], "v1_amp")
  assert_equal(ids[5], "v1_pan", "pan follows the level (the engine pans buffer voices)")
  assert_equal(ids[6], "v1_grain_size", "grain faders follow")
  assert_equal(#ids, 5 + 6 + 9); assert_equal(fader_page_count(1), 5)
  assert_equal(local_value("param_page"), 5, "fader page clamped when the source shrinks the list")
  press(1, 13); press(16, 10)           -- page 1, row 2 = buf_rate max
  assert_near(params:get("v1_buf_rate"), 4, 1e-6, "buf_rate fader")
  assert_equal(device:get_led(16, 10), 15)
  -- page 2, row 1 = pan: column 1 pans hard left, and a running voice's engine gets it
  context.clock.advance()   -- voice 1 running
  context.clear_engine_calls()
  press(2, 13); press(1, 9)
  assert_near(params:get("v1_pan"), -1, 1e-6, "pan fader column 1 = hard left")
  assert_equal(device:get_led(1, 9), 15, "the pan fader shows its value")
  local sent
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 0 and call.args[2] == "pan" then sent = call.args[3] end
  end
  assert_near(sent, -1, 1e-6, "a buffer-sourced voice's pan reaches the engine")
  -- sub has no pan param: its buffer faders end at the level
  params:set("v4_source", 2)
  ids = fader_param_ids(4)
  assert_equal(ids[4], "v4_amp"); assert_equal(ids[5], "v4_grain_size", "sub has no pan fader")
  params:set("v1_source", 1)
  assert_equal(fader_param_ids(1)[1], "v1_freq", "synth faders return")
end)

test("buffer group params: exact group, triggers and defaults", function()
  load_strata()
  local expected = { "record_duration", "record_level" }
  for slot = 1, 8 do
    for _, suffix in ipairs({ "file", "record", "clear", "save" }) do
      table.insert(expected, "buf" .. slot .. "_" .. suffix)
    end
  end
  local group_index
  for index, param in ipairs(params.params) do
    if param.id == "strata_buffers" then group_index = index end
  end
  assert_true(group_index, "strata_buffers group exists")
  assert_equal(params.params[group_index].n, #expected, "group size")
  for offset, param_id in ipairs(expected) do
    assert_equal(params.params[group_index + offset].id, param_id, "group entry " .. offset)
  end
  assert_near(params:get("record_duration"), 8, 1e-9); assert_near(params:get("record_level"), 1, 1e-9)
  assert_equal(param_range("record_duration"), 0.5); assert_equal(select(2, param_range("record_duration")), 16)
  assert_equal(select(2, param_range("record_level")), 2)
  assert_equal(params:lookup_param("buf1_file").t, params.tFILE)
  assert_equal(params:lookup_param("buf1_record").t, params.tTRIGGER)
  local buffers = local_value("buffers")
  assert_equal(#buffers, 8)
  for slot = 1, 8 do
    assert_equal(buffers[slot].name, "empty"); assert_equal(buffers[slot].loaded, false)
    assert_equal(buffers[slot].recording, false); assert_equal(buffers[slot].seconds, 0)
    assert_equal(buffers[slot].path, nil)
  end
end)

test("buffer triggers call the engine and track recording state", function()
  local context = load_strata(); finish_startup(context)  -- finish init's start-up coroutine
  params:set("record_duration", 2); params:set("buf3_record", 1)
  local call = context.calls_named("recordBuffer")[1]
  assert_equal(call.args[1], 2); assert_near(call.args[2], 2, 1e-9); assert_near(call.args[3], 1, 1e-9)
  assert_true(local_value("buffers")[3].recording)
  wake_buffer_clock(context, 3); assert_true(local_value("buffers")[3].recording, "finishing until the engine reports")
  context.polls.fire("bufferState", 202)  -- the engine reports the take
  assert_true(not local_value("buffers")[3].recording)
  assert_equal(local_value("buffers")[3].name, "take 3"); assert_true(local_value("buffers")[3].loaded)
  assert_equal(local_value("buffers")[3].path, _path.audio .. "strata/scratch/buf3.wav", "scratch take path")
  params:set("buf3_file", "/tmp/a.wav"); assert_equal(context.calls_named("loadBuffer")[1].args[2], "/tmp/a.wav")
  assert_equal(context.calls_named("loadBuffer")[1].args[1], 2)
  assert_equal(local_value("buffers")[3].name, "a.wav"); assert_equal(local_value("buffers")[3].path, "/tmp/a.wav")
  params:set("buf3_clear", 1); assert_equal(context.calls_named("clearBuffer")[1].args[1], 2)
  assert_equal(local_value("buffers")[3].name, "empty"); assert_true(not local_value("buffers")[3].loaded)
  context.polls.fire("bufferState", 201.5); assert_near(local_value("buffers")[3].seconds, 1.5, 1e-9)
  context.polls.fire("bufferState", 716); assert_near(local_value("buffers")[8].seconds, 16, 1e-9)
  context.polls.fire("bufferState", 0); assert_near(local_value("buffers")[1].seconds, 0, 1e-9)
  context.polls.fire("bufferState", 950); context.polls.fire("bufferState", -1)  -- out of range: ignored
  -- an empty path or norns' "-" (no file chosen) loads nothing
  context.clear_engine_calls()
  params:set("buf4_file", ""); params:set("buf4_file", "-"); params:set("buf4_file", _path.audio)
  assert_equal(#context.calls_named("loadBuffer"), 0, "no load without a file")
end)

test("recording again stops early; clear and load cancel the timer", function()
  local context = load_strata(); finish_startup(context)   -- finish init's start-up coroutine
  local buffers = local_value("buffers")
  params:set("record_duration", 4)
  record_buffer(2); assert_true(buffers[2].recording)
  context.clear_engine_calls()
  record_buffer(2)
  assert_equal(#context.calls_named("stopRecord"), 1, "second press stops the recording")
  assert_equal(context.calls_named("stopRecord")[1].args[1], 1)
  assert_equal(#context.calls_named("recordBuffer"), 0, "and does not start a new one")
  context.polls.fire("bufferState", 101)  -- the engine reports what was captured
  assert_true(not buffers[2].recording); assert_true(buffers[2].loaded); assert_equal(buffers[2].name, "take 2")
  local pending = context.clock.pending_count()
  record_buffer(2); assert_equal(context.clock.pending_count(), pending + 1, "new recording timer")
  clear_buffer(2)
  assert_true(not buffers[2].recording, "clear ends the recording state")
  assert_equal(context.clock.pending_count(), pending, "clear cancels the timer")
  record_buffer(2); load_buffer(2, "/tmp/b.wav")
  assert_true(not buffers[2].recording, "load ends the recording state")
  assert_equal(context.clock.pending_count(), pending, "load cancels the timer")
  -- out-of-range slots are ignored
  context.clear_engine_calls()
  record_buffer(0); record_buffer(9); clear_buffer(9); load_buffer(0, "/tmp/c.wav"); save_buffer(9)
  assert_equal(#context.engine_calls, 0, "invalid slots send nothing")
  -- cleanup stops the poll and any recording timer
  record_buffer(5)
  cleanup()
  assert_equal(context.clock.pending_count(), 0, "no recording timer left")
  assert_true(not context.polls.polls.bufferState.running, "bufferState poll stopped")
  assert_true(not context.polls.polls.bufferLoadFailed.running, "bufferLoadFailed poll stopped")
end)

test("a file the engine cannot read, loaded during a recording, leaves a canceled recording", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  params:set("record_duration", 4)
  local pending = context.clock.pending_count()
  record_buffer(3)
  load_buffer(3, "/tmp/missing.wav")   -- the engine cancels the recording, then cannot read the file
  assert_true(not buffers[3].recording and not buffers[3].finishing, "the load ends the recording state")
  assert_equal(context.clock.pending_count(), pending, "no recording timer or fallback is left to finish a take")
  -- the canceled recording left the slot empty: the engine reports 0 s
  context.polls.fire("bufferState", 200)
  context.set_time(5); context.polls.fire("bufferState", 200)
  assert_true(not buffers[3].loaded, "not loaded"); assert_equal(buffers[3].settled_empty, "load")
  assert_equal(buffers[3].name, "missing.wav", "a failed load, never take 3")
  assert_equal(buffers[3].path, "/tmp/missing.wav")
  context.clock.run_for(10)              -- nothing pending turns it into a take later
  assert_equal(buffers[3].name, "missing.wav"); assert_true(not buffers[3].loaded)
end)

test("a take or a load is confirmed by the engine's bufferState report", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  local function hint()
    for _, entry in ipairs(context.screen.texts) do
      if entry.x == 0 and entry.y == HINT_ROW_Y then return entry.text end
    end
  end
  -- a take that ran its full duration
  params:set("record_duration", 2)
  record_buffer(3)
  wake_buffer_clock(context, 3)                       -- the recording timer ends
  assert_true(buffers[3].recording, "finishing: still shown as recording")
  assert_true(not buffers[3].loaded, "not loaded before the engine reports it")
  assert_equal(buffers[3].name, "empty", "no take name yet")
  params:set("v1_source", 4); show_page(4)      -- voice 1 reads buf 3
  assert_equal(hint(), "K2:load K3:... K2+3:save", "BUFFER hint while finishing")
  context.clear_engine_calls(); record_buffer(3)
  assert_equal(#context.engine_calls, 0, "a press while finishing sends nothing (no new take, no stop)")
  assert_true(buffers[3].recording, "and changes nothing")
  context.polls.fire("bufferState", 200)        -- a periodic 0 s sent before the take completed
  assert_true(buffers[3].recording and not buffers[3].loaded, "0 s inside the settle time is not the outcome")
  context.polls.fire("bufferState", 202)        -- the engine reports the take
  assert_true(not buffers[3].recording, "finished"); assert_true(buffers[3].loaded, "loaded")
  assert_equal(buffers[3].name, "take 3"); assert_equal(buffers[3].path, scratch_take_path(3))
  show_page(4)
  assert_equal(hint(), "K2:load K3:rec K2+3:save", "hint back to rec")

  -- stopped within the start-up window: the engine captured nothing
  record_buffer(4); record_buffer(4)
  assert_equal(#context.calls_named("stopRecord"), 1, "the stop is sent")
  assert_true(buffers[4].recording and not buffers[4].loaded, "finishing after the stop")
  context.set_time(5)                           -- past the settle time
  context.polls.fire("bufferState", 300)
  assert_true(not buffers[4].recording, "settled"); assert_true(not buffers[4].loaded, "nothing captured: empty")
  assert_equal(buffers[4].name, "empty"); assert_equal(buffers[4].path, nil)
  context.clear_engine_calls(); record_buffer(4)
  assert_equal(#context.calls_named("recordBuffer"), 1, "an empty slot records again")

  -- a file load shows its name at once; 0 s after the settle time clears loaded
  load_buffer(5, "/tmp/unreadable.wav")
  assert_true(buffers[5].loaded, "optimistic load"); assert_equal(buffers[5].name, "unreadable.wav")
  context.polls.fire("bufferState", 400)
  assert_true(buffers[5].loaded, "0 s inside the settle time keeps the load")
  context.set_time(10); context.polls.fire("bufferState", 400)
  assert_true(not buffers[5].loaded, "the engine has no audio: not loaded")
  assert_equal(buffers[5].name, "unreadable.wav", "the name stays")
  load_buffer(6, "/tmp/fine.wav"); context.polls.fire("bufferState", 503.5)
  assert_true(buffers[6].loaded, "audio reported: loaded"); assert_near(buffers[6].seconds, 3.5, 1e-9)
end)

test("a take settled empty adopts audio the engine reports later; a clear wins", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  params:set("record_duration", 2)
  record_buffer(3); wake_buffer_clock(context, 3)     -- the timer ends; the engine is slow
  context.set_time(5); context.polls.fire("bufferState", 200)
  assert_equal(buffers[3].name, "empty", "a periodic 0 after the settle time empties the slot")
  context.polls.fire("bufferState", 202)        -- the take completes late
  assert_true(buffers[3].loaded, "the late take is adopted"); assert_equal(buffers[3].name, "take 3")
  assert_equal(buffers[3].path, scratch_take_path(3), "with the scratch take path")
  context.polls.fire("bufferState", 202); context.polls.fire("bufferState", 203)
  assert_equal(buffers[3].name, "take 3", "later reports leave it a take")
  -- a slot cleared after an empty take is not brought back by a report
  record_buffer(4); record_buffer(4)
  context.set_time(10); context.polls.fire("bufferState", 300)
  assert_equal(buffers[4].name, "empty")
  clear_buffer(4); context.polls.fire("bufferState", 302)
  assert_true(not buffers[4].loaded, "clear wins"); assert_equal(buffers[4].path, nil)
  -- nor is a slot whose last event was a load or a new recording
  record_buffer(5); record_buffer(5)
  context.set_time(15); context.polls.fire("bufferState", 400)
  record_buffer(5); context.polls.fire("bufferState", 401)
  assert_true(buffers[5].recording, "a new recording is not adopted as the old take")
  assert_true(not buffers[5].finishing)
end)

test("a load settled empty adopts audio the engine reports later; restores count; a clear wins", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  -- a slow read: the engine keeps reporting 0 s past the settle time
  load_buffer(2, "/tmp/slow.wav")
  context.set_time(2); context.polls.fire("bufferState", 100)
  assert_true(not buffers[2].loaded, "settled empty")
  context.polls.fire("bufferState", 116)        -- the read completes
  assert_true(buffers[2].loaded, "the late load is adopted")
  assert_equal(buffers[2].name, "slow.wav", "it keeps the file name")
  assert_equal(buffers[2].path, "/tmp/slow.wav")
  -- a restored slot read late counts once
  load_buffer(3, "/tmp/restored.wav"); buffers[3].restoring = true   -- as load_buffers_from_disk does
  context.set_time(4); context.polls.fire("bufferState", 200)
  assert_equal(local_value("buffers_restored"), 0, "not counted while empty")
  context.polls.fire("bufferState", 208); context.polls.fire("bufferState", 208)
  assert_true(buffers[3].loaded); assert_equal(local_value("buffers_restored"), 1, "counted once when adopted")
  -- a clear, or a new load, in between wins
  load_buffer(4, "/tmp/gone.wav")
  context.set_time(6); context.polls.fire("bufferState", 300)
  clear_buffer(4); context.polls.fire("bufferState", 305)
  assert_true(not buffers[4].loaded, "clear wins"); assert_equal(buffers[4].name, "empty")
  load_buffer(5, "/tmp/first.wav")
  context.set_time(8); context.polls.fire("bufferState", 400)
  load_buffer(5, "/tmp/second.wav"); context.set_time(10); context.polls.fire("bufferState", 400)
  assert_true(not buffers[5].loaded, "the second load settled empty too")
  assert_equal(buffers[5].name, "second.wav", "a new load replaces the old one")
end)

test("a finishing take settles from the last known seconds when no report comes", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  -- BUFFER_SETTLE is an upvalue of the local finish_buffer_take, which the
  -- global record_buffer holds
  local finish_buffer_take = local_value("finish_buffer_take")
  local buffer_settle
  for index = 1, math.huge do
    local name, value = debug.getupvalue(finish_buffer_take, index)
    if not name then break end
    if name == "BUFFER_SETTLE" then buffer_settle = value end
  end
  assert_true(buffer_settle ~= nil, "BUFFER_SETTLE reached through finish_buffer_take")
  local fallback_seconds = buffer_settle.fallback_seconds
  params:set("record_duration", 2)
  record_buffer(3); wake_buffer_clock(context, 3)     -- the timer ends: finishing, no report ever
  assert_true(buffers[3].finishing, "finishing")
  local log = context.clock.sleep_log
  assert_equal(log[#log].amount, fallback_seconds, "the fallback waits fallback_seconds after the take ends")
  wake_buffer_clock(context, 3)                       -- the fallback runs
  assert_true(not buffers[3].finishing and not buffers[3].recording, "settled")
  assert_equal(buffers[3].name, "empty", "no seconds known: empty")
  context.clear_engine_calls(); record_buffer(3)
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records again")
  -- a stopped take gets the fallback too, and settles as a take when the
  -- slot's seconds are known
  record_buffer(3)
  assert_true(buffers[3].finishing)
  buffers[3].seconds = 1.5                      -- as an earlier report left it
  wake_buffer_clock(context, 3)
  assert_true(buffers[3].loaded, "known seconds: loaded"); assert_equal(buffers[3].name, "take 3")
  -- a report, a load, a clear or cleanup cancels the fallback
  local pending = context.clock.pending_count()
  record_buffer(4); record_buffer(4)
  assert_equal(context.clock.pending_count(), pending + 1, "fallback pending")
  context.polls.fire("bufferState", 301)
  assert_equal(context.clock.pending_count(), pending, "a report settles it and cancels the fallback")
  record_buffer(5); record_buffer(5); load_buffer(5, "/tmp/x.wav")
  assert_equal(context.clock.pending_count(), pending, "load cancels the fallback")
  record_buffer(6); record_buffer(6); clear_buffer(6)
  assert_equal(context.clock.pending_count(), pending, "clear cancels the fallback")
  record_buffer(7); record_buffer(7)
  cleanup()
  assert_equal(context.clock.pending_count(), 0, "cleanup cancels the fallback")
end)

test("bufferState poll is found and started in init", function()
  local context = load_strata()
  local entry = context.polls.polls.bufferState
  assert_true(entry ~= nil, "the engine registers bufferState")
  assert_true(entry.running, "poll started"); assert_true(entry.callback ~= nil, "callback set")
  entry = context.polls.polls.bufferLoadFailed
  assert_true(entry ~= nil, "the engine registers bufferLoadFailed")
  assert_true(entry.running, "bufferLoadFailed started"); assert_true(entry.callback ~= nil, "its callback set")
end)

-- bufferLoadFailed poll value for Lua slot `slot`'s load number `load_number`
-- (the engine counts the loads of each slot from 1); emptied: the server's
-- read failed after the slot was zeroed
local function load_failed_value(slot, load_number, emptied)
  return (load_number * 2 + (emptied and 1 or 0)) * local_value("NUM_BUFFERS") + (slot - 1)
end

local function buffer_hint(context)
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == HINT_ROW_Y then return entry.text end
  end
end

test("a failed load over audio puts the slot's file back and is never remembered", function()
  local subdir = "failed-load-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local buffers = local_value("buffers")
  params:set("v1_source", 3); show_page(4)      -- voice 1 reads buf 2
  load_buffer(2, "/tmp/good.wav"); context.polls.fire("bufferState", 104)
  assert_true(buffers[2].loaded); assert_equal(buffers[2].name, "good.wav")
  load_buffer(2, "/tmp/corrupt.wav")
  assert_equal(buffers[2].name, "corrupt.wav", "shown at once")
  -- the engine keeps the old audio, so its next report of 4 s settles the load
  context.polls.fire("bufferState", 104)
  assert_true(buffers[2].loaded)
  next_frame(context)
  context.polls.fire("bufferLoadFailed", load_failed_value(2, 2))
  assert_equal(buffers[2].name, "good.wav", "the previous name is back")
  assert_equal(buffers[2].path, "/tmp/good.wav", "and its path")
  assert_true(buffers[2].loaded, "the old audio is still there")
  assert_equal(buffers[2].confirm_since, nil, "nothing left to settle")
  assert_equal(params:get("buf2_file"), "/tmp/good.wav", "the file param shows the old file again")
  assert_true(table.concat(context.printed, "\n"):find("/tmp/corrupt.wav", 1, true), "the console names the bad file")
  next_frame(context)
  assert_equal(buffer_hint(context), "buf 2 load failed", "the BUFFER page says so")
  assert_screen_layout(context, "BUFFER page load failed flash")
  context.clock.run_for(2); next_frame(context)
  assert_equal(buffer_hint(context), "K2:load K3:rec K2+3:save", "briefly")
  -- a duplicate report changes nothing
  context.polls.fire("bufferLoadFailed", load_failed_value(2, 2))
  assert_equal(buffers[2].name, "good.wav"); assert_true(buffers[2].loaded)
  -- the bad path is never remembered
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[2], "/tmp/good.wav", "buffers.data keeps the old file")
end)

test("a failed load into an empty slot leaves it empty; a failed restore is forgotten", function()
  local subdir = "failed-restore-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local buffers = local_value("buffers")
  load_buffer(3, "/tmp/bad.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 1))
  assert_equal(buffers[3].name, "empty"); assert_equal(buffers[3].path, nil)
  assert_true(not buffers[3].loaded, "not loaded"); assert_equal(buffers[3].settled_empty, false)
  assert_equal(buffers[3].confirm_since, nil)
  assert_equal(params:get("buf3_file"), _path.audio, "the file param is back at its starting folder")
  context.set_time(5); context.polls.fire("bufferState", 200)
  assert_equal(buffers[3].name, "empty", "a later 0 s report changes nothing")
  -- a remembered file that exists but cannot be read is not kept for the next start
  util.make_dir(context.audio_dir)
  local good = context.audio_dir .. "good.wav"
  local corrupt = context.audio_dir .. "corrupt.wav"
  for _, path in ipairs({ good, corrupt }) do io.open(path, "w"):close() end
  load_buffer(1, good); load_buffer(4, corrupt)
  cleanup()
  context = load_strata({ data_subdir = subdir })
  buffers = local_value("buffers")
  assert_equal(#context.calls_named("loadBuffer"), 2, "both restored")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 1))
  assert_equal(buffers[4].name, "empty"); assert_equal(buffers[4].path, nil)
  assert_true(not buffers[4].restoring, "no longer restoring")
  context.polls.fire("bufferState", 3)          -- buffer 1 holds 3 s
  assert_equal(local_value("buffers_restored"), 1, "only the readable file counts")
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[1], good); assert_equal(saved.paths[4], "", "the unreadable file is forgotten")
end)

test("a late or duplicate load failure report never undoes a later load, clear or recording", function()
  local context = load_strata(); finish_startup(context)
  local buffers = local_value("buffers")
  -- two loads sent before the first one's failure arrives
  load_buffer(5, "/tmp/orig.wav"); context.polls.fire("bufferState", 403)   -- load 1 holds 3 s
  load_buffer(5, "/tmp/bad.wav")                -- load 2: the engine cannot read it
  load_buffer(5, "/tmp/worse.wav")              -- load 3, sent before load 2's report arrived
  context.polls.fire("bufferLoadFailed", load_failed_value(5, 2))
  assert_equal(buffers[5].name, "worse.wav", "the later load stays")
  assert_equal(buffers[5].path, "/tmp/worse.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(5, 3))
  assert_equal(buffers[5].name, "orig.wav", "both failed: the file before them is back")
  assert_equal(buffers[5].path, "/tmp/orig.wav"); assert_true(buffers[5].loaded)
  assert_equal(params:get("buf5_file"), "/tmp/orig.wav")
  -- duplicates, loads that succeeded, loads never sent and bad values change nothing
  local before = deep_copy(buffers)
  for _, value in ipairs({ load_failed_value(5, 3), load_failed_value(5, 2), load_failed_value(5, 3, true),
    load_failed_value(5, 9), load_failed_value(6, 1), 0 / 0, math.huge, -math.huge, -1, 41.5 }) do
    local ok, message = pcall(context.polls.fire, "bufferLoadFailed", value)
    assert_true(ok, "report " .. tostring(value) .. " raises no error: " .. tostring(message))
    for slot = 1, 8 do
      assert_equal(buffers[slot].name, before[slot].name, "report " .. tostring(value) .. ", slot " .. slot .. " name")
      assert_equal(buffers[slot].path, before[slot].path, "report " .. tostring(value) .. ", slot " .. slot .. " path")
    end
    assert_equal(rawget(buffers, 0), nil); assert_equal(rawget(buffers, 9), nil)
  end
  -- a clear or a new recording after the load wins
  load_buffer(6, "/tmp/x.wav"); clear_buffer(6)
  context.polls.fire("bufferLoadFailed", load_failed_value(6, 1))
  assert_equal(buffers[6].name, "empty", "clear wins"); assert_equal(buffers[6].path, nil)
  load_buffer(7, "/tmp/y.wav"); record_buffer(7)
  context.polls.fire("bufferLoadFailed", load_failed_value(7, 1))
  assert_true(buffers[7].recording, "the new recording wins")
  assert_equal(params:get("buf7_file"), _path.audio)
  -- a failed load during a recording canceled it in the engine: the slot is empty
  params:set("record_duration", 4)
  record_buffer(8); load_buffer(8, "/tmp/z.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(8, 1))
  assert_equal(buffers[8].name, "empty"); assert_equal(buffers[8].path, nil)
  assert_true(not buffers[8].recording and not buffers[8].finishing and not buffers[8].loaded)
  assert_equal(params:get("buf8_file"), _path.audio)
  context.set_time(10); context.polls.fire("bufferState", 700)
  assert_equal(buffers[8].name, "empty", "still empty")
  context.clear_engine_calls(); record_buffer(8)
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records again")
  -- ... unless its take had completed: the engine's report of it is adopted
  record_buffer(4); wake_buffer_clock(context, 4)     -- the timer ends; the engine has the take
  load_buffer(4, "/tmp/w.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 1))
  assert_equal(buffers[4].name, "empty")
  context.polls.fire("bufferState", 304)
  assert_true(buffers[4].loaded, "the take is adopted"); assert_equal(buffers[4].name, "take 4")
  assert_equal(buffers[4].path, scratch_take_path(4))
end)

test("a load whose server read failed leaves the slot empty, in either report order", function()
  local subdir = "failed-read-" .. math.random(1, 1e9)
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local buffers = local_value("buffers")
  -- the file vanished between the engine's checks and the server's read
  load_buffer(2, "/tmp/good.wav"); context.polls.fire("bufferState", 104)
  load_buffer(2, "/tmp/vanished.wav")
  context.polls.fire("bufferState", 100)        -- the slot reads 0 while it fades and reads
  context.polls.fire("bufferLoadFailed", load_failed_value(2, 2, true))
  assert_equal(buffers[2].name, "empty", "the old audio was zeroed: empty, not good.wav")
  assert_equal(buffers[2].path, nil); assert_true(not buffers[2].loaded)
  assert_equal(buffers[2].confirm_since, nil); assert_equal(buffers[2].settled_empty, false)
  assert_equal(params:get("buf2_file"), _path.audio)
  local printed = table.concat(context.printed, "\n")
  assert_true(printed:find("/tmp/vanished.wav", 1, true) and printed:find("the buffer is now empty", 1, true),
    "the console names the file and says the buffer is empty")
  -- a later load that fails at once is reported first: it puts back the
  -- earlier load, whose emptied report then empties the slot
  load_buffer(3, "/tmp/first.wav"); context.polls.fire("bufferState", 203)
  load_buffer(3, "/tmp/vanishing.wav")          -- load 2: its read will fail
  load_buffer(3, "/tmp/missing.wav")            -- load 3: rejected at once
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 3))
  assert_equal(buffers[3].name, "vanishing.wav", "load 3 undone: load 2 is shown")
  context.polls.fire("bufferLoadFailed", load_failed_value(3, 2, true))
  assert_equal(buffers[3].name, "empty", "then load 2 empties the slot"); assert_equal(buffers[3].path, nil)
  -- ... and the other way round
  load_buffer(4, "/tmp/first.wav"); context.polls.fire("bufferState", 303)
  load_buffer(4, "/tmp/vanishing.wav")          -- load 2
  load_buffer(4, "/tmp/missing.wav")            -- load 3, sent before load 2's report arrived
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 2, true))
  assert_equal(buffers[4].name, "missing.wav", "the later load stays")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 3))
  assert_equal(buffers[4].name, "empty", "it fails too: the slot load 2 emptied")
  assert_equal(buffers[4].path, nil); assert_equal(params:get("buf4_file"), _path.audio)
  -- a load that succeeds after an emptied one stays
  load_buffer(5, "/tmp/vanishing.wav"); load_buffer(5, "/tmp/fine.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(5, 1, true))
  assert_equal(buffers[5].name, "fine.wav"); context.polls.fire("bufferState", 402)
  assert_true(buffers[5].loaded, "and is loaded")
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[2], "", "the vanished file is not remembered")
  assert_equal(saved.paths[3], ""); assert_equal(saved.paths[4], ""); assert_equal(saved.paths[5], "/tmp/fine.wav")
end)

test("save_buffer writes a timestamped wav under audio/strata", function()
  local context = load_strata()
  load_buffer(6, "/tmp/x.wav")
  -- the engine has not reported any audio yet: nothing to save (a failed load
  -- leaves loaded = true, so the guard is the poll's seconds)
  save_buffer(6)
  assert_equal(#context.calls_named("saveBuffer"), 0, "loaded flag alone does not save")
  context.polls.fire("bufferState", 504)  -- slot index 5 (buffer 6) holds 4 s
  save_buffer(6)
  local call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[1], 5)
  local dir = _path.audio .. "strata/"
  assert_equal(call.args[2]:sub(1, #dir), dir, "saved under " .. dir)
  assert_true(call.args[2]:sub(#dir + 1):match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-buf6%.wav$"),
    "timestamped name: " .. call.args[2])
  assert_equal(buffer_save_path(6):sub(1, #dir), dir)
  assert_true(util.file_exists(dir), "directory created")
  assert_true(table.concat(context.printed, "\n"):find(call.args[2], 1, true), "path printed")
  -- an empty slot has nothing to save
  context.clear_engine_calls(); save_buffer(1)
  assert_equal(#context.calls_named("saveBuffer"), 0, "empty slot not saved")
  params:set("buf6_save", 1); assert_equal(#context.calls_named("saveBuffer"), 1, "save trigger")
end)

test("explicit save writes a timestamped file; cleanup/init persist buffer paths", function()
  local context = load_strata({ data_subdir = "buf" }); finish_startup(context)  -- init's start-up coroutine
  context.polls.fire("bufferState", 104)  -- buffer 2 holds 4 s (save needs the engine's seconds)
  params:set("buf2_save", 1)
  local call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[1], 1); assert_true(call.args[2]:match("strata/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-buf2%.wav$"))
  params:set("buf1_file", context.audio_dir .. "one.wav"); io.open(context.audio_dir .. "one.wav", "w"):close()
  params:set("buf4_record", 1); wake_buffer_clock(context, 4)
  context.polls.fire("bufferState", 304)  -- the engine reports the take
  assert_equal(local_value("buffers")[4].path, context.audio_dir .. "strata/scratch/buf4.wav")
  assert_equal(scratch_take_path(4), context.audio_dir .. "strata/scratch/buf4.wav")
  cleanup()
  local again = load_strata({ data_subdir = "buf" })
  local loads = again.calls_named("loadBuffer")
  assert_equal(loads[1].args[1], 0); assert_equal(loads[1].args[2], context.audio_dir .. "one.wav")
  assert_equal(#loads, 1, "scratch take not restored when its file is missing")
end)

test("buffers.data format, restored scratch takes and the SETUP count", function()
  local context = load_strata({ data_subdir = "buf_format" }); finish_startup(context)  -- init's start-up coroutine
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  show_page(5)
  assert_true(screen_has("buffers: 0 restored"), "nothing restored without a file")
  local loaded_file = context.audio_dir .. "loop.wav"
  io.open(loaded_file, "w"):close()
  load_buffer(3, loaded_file)
  record_buffer(5); wake_buffer_clock(context, 5)
  context.polls.fire("bufferState", 404)        -- the engine reports the take
  -- the engine wrote the take
  util.make_dir(context.audio_dir .. "strata/scratch/")
  io.open(scratch_take_path(5), "w"):close()
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.version, 1, "format version")
  for slot = 1, 8 do
    local expected = ({ [3] = loaded_file, [5] = scratch_take_path(5) })[slot] or ""
    assert_equal(saved.paths[slot], expected, "slot " .. slot .. " path")
  end

  context = load_strata({ data_subdir = "buf_format" })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 2, "both existing files restored")
  assert_equal(loads[1].args[1], 2); assert_equal(loads[1].args[2], loaded_file)
  assert_equal(loads[2].args[1], 4); assert_equal(loads[2].args[2], scratch_take_path(5))
  local buffers = local_value("buffers")
  assert_equal(buffers[3].name, "loop.wav"); assert_equal(buffers[3].path, loaded_file)
  assert_equal(buffers[5].name, "take 5", "a restored scratch take keeps its take name")
  assert_equal(buffers[5].path, scratch_take_path(5))
  assert_equal(params:get("buf3_file"), loaded_file, "a restored slot's file param shows its path")
  assert_equal(params:get("buf5_file"), scratch_take_path(5), "a restored take's file param shows the take")
  assert_equal(params:get("buf1_file"), _path.audio, "a slot with nothing restored stays at its starting folder")
  assert_equal(local_value("buffers_restored"), 0, "restored once the engine reports audio")
  context.polls.fire("bufferState", 202); context.polls.fire("bufferState", 404)
  assert_equal(local_value("buffers_restored"), 2)
  show_page(5)
  assert_true(screen_has("buffers: 2 restored"), "SETUP shows the restored count")
  -- a slot whose file has gone is skipped and reported, and stays empty
  os.remove(loaded_file)
  cleanup()
  context = load_strata({ data_subdir = "buf_format" })
  assert_equal(#context.calls_named("loadBuffer"), 1, "missing file not loaded")
  assert_equal(local_value("buffers")[3].name, "empty")
  assert_true(table.concat(context.printed, "\n"):find(loaded_file, 1, true), "missing file reported")
  assert_equal(local_value("buffers_restored"), 0, "nothing confirmed by the engine yet")
  context.polls.fire("bufferState", 403)        -- buffer 5's take
  assert_equal(local_value("buffers_restored"), 1)
end)

test("a buffer cleared before exit is saved empty and not restored", function()
  local context = load_strata({ data_subdir = "buf_cleared" })
  local kept_file, cleared_file = context.audio_dir .. "kept.wav", context.audio_dir .. "cleared.wav"
  io.open(kept_file, "w"):close(); io.open(cleared_file, "w"):close()
  load_buffer(2, kept_file); load_buffer(6, cleared_file)
  cleanup()
  context = load_strata({ data_subdir = "buf_cleared" })
  assert_equal(#context.calls_named("loadBuffer"), 2, "both files restored")
  clear_buffer(6)
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[6], "", "the cleared slot is saved as an empty path")
  assert_equal(saved.paths[2], kept_file, "the other slot keeps its file")
  context = load_strata({ data_subdir = "buf_cleared" })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "only the kept slot is restored")
  assert_equal(loads[1].args[1], 1); assert_equal(loads[1].args[2], kept_file)
  local buffers = local_value("buffers")
  assert_equal(buffers[6].name, "empty", "the cleared slot starts empty")
  assert_equal(buffers[6].path, nil, "the cleared slot has no path")
end)

test("restores count engine-confirmed slots; missing remembered files are kept across restarts", function()
  local subdir = "buf_missing"
  local context = load_strata({ data_subdir = subdir })
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  local present = context.audio_dir .. "here.wav"
  local unreadable = context.audio_dir .. "bad.wav"
  local away = context.audio_dir .. "drive/away.wav"   -- on a drive that is unmounted later
  util.make_dir(context.audio_dir .. "drive/")
  for _, path in ipairs({ present, unreadable, away }) do io.open(path, "w"):close() end
  load_buffer(1, present); load_buffer(2, unreadable); load_buffer(3, away)
  cleanup()
  os.remove(away)

  context = load_strata({ data_subdir = subdir })
  local buffers = local_value("buffers")
  assert_equal(#context.calls_named("loadBuffer"), 2, "the two files present are loaded")
  assert_equal(buffers[3].name, "empty", "the missing file's slot stays empty")
  assert_true(not buffers[3].loaded)
  assert_true(table.concat(context.printed, "\n"):find(away, 1, true), "the console names the missing file")
  assert_equal(local_value("buffers_restored"), 0, "nothing restored until the engine reports audio")
  show_page(5)
  assert_true(screen_has("buffers: 0 ok, 1 missing"), "SETUP shows the missing file")
  context.polls.fire("bufferState", 3)          -- buffer 1 holds 3 s
  context.polls.fire("bufferState", 3)          -- the periodic poll repeats it
  assert_equal(local_value("buffers_restored"), 1, "a confirmed slot counts once")
  context.set_time(5); context.polls.fire("bufferState", 100)   -- buffer 2: the engine could not read it
  assert_equal(local_value("buffers_restored"), 1, "a slot without audio does not count")
  assert_true(not buffers[2].loaded, "and is not loaded")
  show_page(5)
  assert_true(screen_has("buffers: 1 ok, 1 missing"), "SETUP count after the reports")
  assert_screen_layout(context, "SETUP with missing buffers")

  -- the missing path survives the next exit, so the sample comes back once
  -- its drive is mounted again
  cleanup()
  local saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[1], present); assert_equal(saved.paths[2], unreadable)
  assert_equal(saved.paths[3], away, "the missing file's path is kept")
  io.open(away, "w"):close()
  context = load_strata({ data_subdir = subdir })
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 3, "the file is back: restored")
  assert_equal(loads[3].args[1], 2); assert_equal(loads[3].args[2], away)
  context.polls.fire("bufferState", 3); context.polls.fire("bufferState", 201)
  assert_equal(local_value("buffers_restored"), 2)
  show_page(5)
  assert_true(screen_has("buffers: 2 restored"), "no missing files: the plain count")
  -- a slot cleared after a missing restore forgets the path
  cleanup(); os.remove(away)
  context = load_strata({ data_subdir = subdir })
  clear_buffer(3)
  cleanup()
  saved = context.tab.load(context.data_dir .. "strata/buffers.data")
  assert_equal(saved.paths[3], "", "cleared: the missing path is forgotten")

  -- an earlier blocked auto-save does not outlive the next load
  local _, set_blocked = find_upvalue("buffer_autosave_blocked")
  set_blocked(true)
  load_buffers_from_disk()
  assert_equal(local_value("buffer_autosave_blocked"), false, "reset at the top of load_buffers_from_disk")
  set_blocked(true)
  os.remove(context.data_dir .. "strata/buffers.data")
  load_buffers_from_disk()
  assert_equal(local_value("buffer_autosave_blocked"), false, "reset even when there is no file")
end)

test("a buffers file that fails to load does not stop init and survives cleanup", function()
  local bad_files = {
    { name = "wrong version", content = tabutil_text({ version = 99, paths = {} }) },
    { name = "raises on load", content = 'error("corrupt buffers file")' },
    { name = "not a table", content = "return 42" },
    { name = "paths not a table", content = tabutil_text({ version = 1, paths = "x" }) },
  }
  for index, bad in ipairs(bad_files) do
    local subdir = "buf_survive_" .. index
    local data_dir = data_root .. subdir .. "/strata/"
    os.execute("mkdir -p '" .. data_dir .. "'")
    local file = assert(io.open(data_dir .. "buffers.data", "w"))
    file:write(bad.content)
    file:close()

    local context = load_strata({ data_subdir = subdir })  -- init's load fails
    assert_equal(#context.calls_named("loadBuffer"), 0, bad.name .. ": nothing loaded")
    assert_equal(local_value("buffers_restored"), 0, bad.name .. ": nothing restored")
    local recorded = context.audio_dir .. "new.wav"
    io.open(recorded, "w"):close()
    load_buffer(2, recorded)  -- new work after the failed load
    cleanup()
    local backup = io.open(data_dir .. "buffers.data.bak", "r")
    assert_true(backup ~= nil, bad.name .. ": original kept as buffers.data.bak")
    assert_equal(backup:read("*a"), bad.content, bad.name .. ": backup content unchanged")
    backup:close()
    context = load_strata({ data_subdir = subdir })
    assert_equal(context.calls_named("loadBuffer")[1].args[2], recorded, bad.name .. ": new work saved on exit")
  end

  -- if the file cannot be moved aside, cleanup must not overwrite it
  local data_dir = data_root .. "buf_survive_blocked/strata/"
  os.execute("mkdir -p '" .. data_dir .. "buffers.data.bak/occupied'")  -- rename target is a non-empty dir
  local file = assert(io.open(data_dir .. "buffers.data", "w"))
  file:write(bad_files[1].content)
  file:close()
  load_strata({ data_subdir = "buf_survive_blocked" })
  cleanup()
  file = assert(io.open(data_dir .. "buffers.data", "r"))
  assert_equal(file:read("*a"), bad_files[1].content, "unmovable bad file not overwritten by cleanup")
  file:close()
end)

test("MAIN layout holds for buffer- and input-sourced voices", function()
  local context = load_strata(); finish_startup(context)
  local _, set_selected = find_upvalue("selected_voice")
  for _, source in ipairs({ 9, 10 }) do
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      params:set("v" .. voice_idx .. "_source", source)
      params:set("v" .. voice_idx .. "_buf_pos", 1)
      params:set("v" .. voice_idx .. "_grain_mode", 2)
      if not local_value("frozen")[voice_idx] then toggle_freeze(voice_idx) end
      show_page(1)
      assert_screen_layout(context, "MAIN, voice " .. voice_idx .. " source " .. source)
    end
  end
end)

---------------------------------------------------------------------------
-- BUFFER page, arc BUFFER page, grid page 4 buffer rows
---------------------------------------------------------------------------

-- Press and release a norns key
local function tap(n) key(n, 1); key(n, 0) end

-- The drawn strings on row y, left to right
local function texts_on_row(context, y)
  local row = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == y then table.insert(row, entry) end
  end
  table.sort(row, function(a, b) return select(1, text_span(a)) < select(1, text_span(b)) end)
  return row
end

local function hint_text(context)
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == HINT_ROW_Y then return entry.text end
  end
end

test("BUFFER page: E3 cycles source, K3 records into the voice's slot, K2 opens the file selector", function()
  local context = load_strata(); finish_startup(context); enc(1, 3)
  assert_equal(PAGE_TITLES[local_value("ui_page")], "BUFFER")
  enc(3, 2); assert_equal(params:get("v1_source"), 3)
  key(3, 1); assert_equal(context.calls_named("recordBuffer")[1].args[1], 1)
  key(3, 0)
  -- K2 acts on release (a 3.0 review fix), so the K2 press is a press and release
  tap(2); assert_true(context.fileselect.last ~= nil, "fileselect opened")
  assert_equal(context.fileselect.last.folder, _path.audio, "file selector starts in the audio folder")
  context.fileselect.last.callback("/tmp/b.wav"); assert_equal(params:get("buf2_file"), "/tmp/b.wav")
  params:set("v1_source", 1); context.clear_engine_calls(); context.fileselect.last = nil
  tap(3); tap(2)
  assert_equal(#context.calls_named("recordBuffer"), 0, "K3 does nothing for a synth voice")
  assert_equal(context.fileselect.last, nil, "K2 does nothing for a synth voice")
  redraw(); for _, entry in ipairs(context.screen.texts) do local l, r = text_span(entry); assert_true(r <= 128) end
  -- E2 selects the voice (shared with MAIN); a canceled selection loads nothing
  enc(2, 3); assert_equal(local_value("selected_voice"), 4)
  params:set("v4_source", 7); tap(2); context.clear_engine_calls()
  context.fileselect.last.callback("cancel")
  assert_equal(#context.calls_named("loadBuffer"), 0, "cancel loads nothing")
  assert_equal(voice_buffer_slot(4), 6); assert_equal(voice_buffer_slot(1), nil)
  params:set("v1_source", 10); assert_equal(voice_buffer_slot(1), nil, "input has no buffer slot")
end)

test("the same file loads again after a record or clear, from the BUFFER page and PARAMS", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  params:set("v1_source", 2)  -- voice 1 reads buffer 1
  context.clear_engine_calls()
  local function loads() return #context.calls_named("loadBuffer") end
  tap(2); context.fileselect.last.callback("/tmp/foo.wav")
  assert_equal(loads(), 1, "the BUFFER page loads the picked file")
  assert_equal(params:get("buf1_file"), "/tmp/foo.wav", "and the file param shows it")
  clear_buffer(1)
  assert_equal(params:get("buf1_file"), _path.audio, "clear resets the file param to its starting folder")
  assert_equal(loads(), 1, "the reset is silent (loads nothing)")
  tap(2); context.fileselect.last.callback("/tmp/foo.wav")
  assert_equal(loads(), 2, "the same file loads again after a clear (BUFFER page)")
  record_buffer(1)
  assert_equal(params:get("buf1_file"), _path.audio, "a recording resets the file param")
  assert_equal(loads(), 2, "silently")
  params:set("buf1_file", "/tmp/foo.wav")
  assert_equal(loads(), 3, "the same file loads again after a recording (PARAMS)")
  assert_true(not local_value("buffers")[1].recording, "the load ended the recording")
  tap(2); context.fileselect.last.callback("/tmp/foo.wav")
  assert_equal(loads(), 4, "picking the loaded file again on the BUFFER page reloads it")
  assert_equal(context.calls_named("loadBuffer")[4].args[1], 0); assert_equal(context.calls_named("loadBuffer")[4].args[2], "/tmp/foo.wav")
end)

test("the BUFFER page caches each slot's cut name (M3)", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  local measured = 0
  local text_extents = screen.text_extents
  screen.text_extents = function(text) measured = measured + 1; return text_extents(text) end
  -- the loads redraw the page on the next frame (and measure the new names)
  for slot = 1, 8 do load_buffer(slot, "/tmp/a very long sample name number " .. slot .. ".wav") end
  next_frame(context)
  assert_true(measured > 0, "a new name is measured")
  measured = 0
  redraw(); redraw()
  screen.text_extents = text_extents
  assert_equal(measured, 0, "later draws reuse the cut names")
  local names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_true(names[14] ~= nil and #names[14] < 20, "the cached name is the cut one")
  load_buffer(1, "/tmp/b.wav"); redraw()
  names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_equal(names[14], "b", "a new name is cut and shown")
  clear_buffer(1); redraw()
  names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_equal(names[14], "empty", "a cleared slot shows empty")
end)

test("BUFFER page: K2+K3 saves, K2 release then does not open the selector", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)  -- the engine reports buffer 3's audio
  context.clear_engine_calls(); context.fileselect.last = nil
  key(2, 1); tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K3 with K2 held saves")
  assert_equal(context.calls_named("saveBuffer")[1].args[1], 2, "the voice's buffer")
  assert_equal(#context.calls_named("recordBuffer"), 0, "and does not record")
  tap(3); assert_equal(#context.calls_named("saveBuffer"), 2, "each K3 while K2 is held saves")
  key(2, 0); assert_equal(context.fileselect.last, nil, "K2 release after a save opens nothing")
  -- the next plain K2 opens the selector again, and a plain K3 records
  tap(2); assert_true(context.fileselect.last ~= nil, "K2 alone opens the selector")
  tap(3); assert_equal(#context.calls_named("recordBuffer"), 1, "K3 alone records")
  tap(3); assert_equal(#context.calls_named("stopRecord"), 1, "K3 again stops early")
  context.polls.fire("bufferState", 205)  -- the engine reports the stopped take
  -- a K2 held across a page change is released elsewhere: no selector, and
  -- back on BUFFER K3 records
  context.fileselect.last = nil; context.clear_engine_calls()
  key(2, 1); show_page(1); key(2, 0); show_page(4)
  assert_equal(context.fileselect.last, nil, "K2 released on another page opens nothing")
  tap(3); assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records once K2 is up")
  assert_equal(#context.calls_named("saveBuffer"), 0)
end)

test("BUFFER page K2+K3 confirms the save in the hint row for 1.5 s", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)  -- buffer 3 holds 4 s
  context.set_time(100)
  key(2, 1); tap(3); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K2+K3 saves")
  assert_equal(hint_text(context), "saved buf 3", "the hint row confirms the save")
  assert_screen_layout(context, "BUFFER with the save confirmation")
  key(2, 0); next_frame(context); assert_equal(hint_text(context), "saved buf 3", "K2's release leaves it")
  context.set_time(101.4); redraw()
  assert_equal(hint_text(context), "saved buf 3", "still shown before 1.5 s")
  context.set_time(101.5); redraw()
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save", "the normal hint after 1.5 s")
  -- an empty buffer: nothing saved, the hint says so
  context.polls.fire("bufferState", 200)  -- buffer 3 reports 0 s
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "an empty buffer is not saved")
  assert_equal(hint_text(context), "buf 3 empty", "the hint says the buffer is empty")
  assert_screen_layout(context, "BUFFER with the empty-buffer flash")
  -- one clock ends the flash: it sleeps 1.5 s, clears the flash (even if it
  -- woke a little early) and asks for a redraw
  local page = local_value("BUFFER_PAGE")
  local flash_clock = page.flash_clock
  assert_true(flash_clock ~= nil, "the flash has a clock")
  local flash_sleep
  for _, entry in ipairs(context.clock.sleep_log) do
    if entry.id == flash_clock then flash_sleep = entry.amount end
  end
  assert_near(flash_sleep, 1.5, 1e-9, "it sleeps 1.5 s")
  key(2, 1); tap(3); key(2, 0)   -- a second flash replaces the first one's clock
  assert_equal(context.clock.threads[flash_clock], nil, "the earlier clock is canceled")
  flash_clock = page.flash_clock
  context.clock.advance_until(flash_clock)        -- the flash clock wakes 1.5 s later
  assert_equal(context.clock.threads[flash_clock], nil, "the clock ends after one wake")
  assert_equal(page.flash_clock, nil)
  next_frame(context)
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save", "the next frame shows the normal hint")
  -- cleanup cancels a pending flash clock
  key(2, 1); tap(3); key(2, 0)
  flash_clock = page.flash_clock
  cleanup()
  assert_equal(context.clock.threads[flash_clock], nil, "cleanup cancels the flash clock")
  assert_equal(page.flash_clock, nil)
end)

test("BUFFER page K2+K3 on a recording or finishing buffer flashes busy and saves nothing", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  params:set("v1_source", 4)
  local buffers = local_value("buffers")
  tap(3); assert_true(buffers[3].recording, "K3 records into buffer 3")
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while recording")
  assert_equal(#context.calls_named("stopRecord"), 0, "K2+K3 does not stop the recording")
  assert_equal(hint_text(context), "buf 3 busy", "the hint says the buffer is busy")
  assert_screen_layout(context, "BUFFER with the busy flash while recording")
  -- stopped early: the take waits for the engine (finishing)
  tap(3); assert_true(buffers[3].finishing, "the stopped take is finishing")
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while finishing")
  assert_equal(hint_text(context), "buf 3 busy", "still busy while finishing")
  assert_screen_layout(context, "BUFFER with the busy flash while finishing")
  -- once the engine reports the take, K2+K3 saves it
  context.polls.fire("bufferState", 205)
  assert_true(not buffers[3].finishing, "the take settled")
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 1, "the settled take saves")
  assert_equal(hint_text(context), "saved buf 3")
end)

test("a K2 released inside the norns menu is forgotten: K3 records again (fix round 1)", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  local drift_metro = local_value("drift_metro")
  context.clear_engine_calls(); context.fileselect.last = nil
  -- K2 down, then K1 opens the menu: the K2 release goes to the menu
  key(2, 1)
  context.menu.mode = true; drift_metro.event()   -- a 10 Hz tick while the menu is open
  context.menu.mode = false                       -- K1 again: back to the script
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save after K2 was released in the menu")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  assert_equal(context.fileselect.last, nil, "nothing opened the file selector")
  -- a save made with K2 held, then the menu: the next K2 tap opens the selector
  tap(3)  -- stop the recording
  context.polls.fire("bufferState", 202)  -- the engine reports the 2 s take
  key(2, 1); tap(3); assert_equal(#context.calls_named("saveBuffer"), 1, "K2+K3 still saves")
  context.menu.mode = true; drift_metro.event(); context.menu.mode = false
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the selector after the menu")
  -- ticks with the menu closed keep a held K2
  context.fileselect.last = nil; context.clear_engine_calls()
  key(2, 1); drift_metro.event(); tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K2 still held across a tick with the menu closed")
  key(2, 0); assert_equal(context.fileselect.last, nil)
  assert_equal(norns.menu.status(), false, "stub norns.menu.status mirrors _menu.mode")
end)

test("BUFFER K2's release forgets every held key as the file selector opens", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  params:set("v1_source", 4)
  local held_at_enter
  local stub_enter = context.fileselect.enter
  context.fileselect.enter = function(...)
    held_at_enter = {}
    for n, page in pairs(local_value("key_press_page")) do held_at_enter[n] = page end
    return stub_enter(...)
  end
  -- K3 goes down (it records), then K2 is pressed and released while K3 is
  -- still held: the selector opens and takes K3's release
  key(3, 1); key(2, 1); key(2, 0)
  assert_true(context.fileselect.last ~= nil, "K2's release opens the selector")
  assert_true(held_at_enter ~= nil and next(held_at_enter) == nil, "no key is held when the selector opens")
  assert_equal(next(local_value("key_press_page")), nil, "and none afterward")
  assert_equal(local_value("buffer_saved_during_k2"), false, "the K2-save flag is clear")
end)

test("BUFFER K2 loads a file with no fileselect global: the script requires it (issue #10)", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  assert_equal(rawget(_G, "fileselect"), nil, "norns has no fileselect global")
  params:set("v1_source", 2)  -- voice 1 reads buffer 1
  context.clear_engine_calls()
  tap(2); assert_true(context.fileselect.last ~= nil, "K2's release opens the selector")
  context.fileselect.close("/tmp/picked.wav")
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "the chosen file loads")
  assert_equal(loads[1].args[1], 0); assert_equal(loads[1].args[2], "/tmp/picked.wav")
end)

test("Strata's page never draws over the open file selector; redraws draw the selector (issue #10)", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  params:set("v1_source", 2)
  local draws = 0  -- Strata's page draws (the stub's fileselect.redraw draws nothing)
  local update = screen.update
  screen.update = function() draws = draws + 1; return update() end
  local selector = context.fileselect
  -- opening it on K2's release: fs.enter's redraw() (from norns.menu.init)
  -- and the frame after key() draw the selector, not the page
  key(2, 1); next_frame(context); draws = 0
  key(2, 0); assert_true(selector.last ~= nil, "K2's release opens the selector")
  next_frame(context)
  assert_equal(draws, 0, "the page does not draw over the selector as it opens")
  assert_equal(selector.redraws, 3, "menu.init's redraw, fs.enter's own and the next frame draw the selector")
  -- the norns menu opened and closed over it (K1 twice): set_mode(false)
  -- clears the screen and calls redraw(), which must show the selector again
  selector.redraws = 0
  _menu.set_mode(true); _menu.set_mode(false); redraw()
  assert_equal(selector.redraws, 1, "norns' redraw() as the menu closes draws the selector")
  assert_equal(draws, 0, "and not Strata's page")
  -- Strata's own redraws (a buffer report, page turns, a load) while it is
  -- open: the frame clock's redraw() draws the selector
  selector.redraws = 0
  context.polls.fire("bufferState", 305)
  enc(1, -1); enc(1, 1)
  load_buffer(5, "/tmp/other.wav")
  next_frame(context)
  assert_equal(draws, 0, "the page does not draw over the selector while it is open")
  assert_true(selector.redraws > 0, "they draw the selector instead")
  -- canceled: fs.exit's redraw() comes before the callback, which asks
  -- for one redraw
  context.clear_engine_calls()
  context.fileselect.close()
  assert_equal(draws, 0, "the page waits for the next frame")
  next_frame(context)
  assert_equal(draws, 1, "a cancel redraws once")
  assert_equal(#context.calls_named("loadBuffer"), 0, "a cancel loads nothing")
  assert_equal(PAGE_TITLES[local_value("ui_page")], "BUFFER")
  redraw(); assert_equal(draws, 2, "the script draws again after a cancel")
  -- a chosen file: loads it, then one redraw. K2's tap opens the selector
  -- before the next frame, which then draws the selector, not the page
  tap(2); next_frame(context); assert_equal(draws, 2, "the page does not draw as the selector opens again")
  draws = 0
  context.fileselect.close("/tmp/chosen.wav")
  next_frame(context)
  assert_equal(draws, 1, "a chosen file redraws once")
  assert_equal(#context.calls_named("loadBuffer"), 1, "and loads")
  redraw(); assert_equal(draws, 2, "the script draws again after a choice")
  screen.update = update
end)

test("a file selector that fails to open leaves the BUFFER page drawing (#49)", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  params:set("v1_source", 2)
  local stub_enter = context.fileselect.enter
  local script_key, script_enc = key, enc
  -- fails after it has routed its own handlers to play mode, as fs.enter
  -- would if its redraw raised: globals swapped, then norns.menu.init()
  context.fileselect.enter = function()
    key, enc = function() end, function() end
    norns.menu.init()
    error("no audio folder")
  end
  key(2, 1)
  local released, release_error = pcall(key, 2, 0)
  context.fileselect.enter = stub_enter
  assert_true(not released, "K2's release raises the selector's error")
  assert_true(tostring(release_error):find("no audio folder", 1, true), "the same error: " .. tostring(release_error))
  assert_equal(_menu.key, script_key, "play mode routes the keys to Strata again")
  assert_equal(norns.encoders.callback, script_enc, "and the encoders")
  assert_equal(key, script_key, "the key global is Strata's")
  assert_equal(enc, script_enc, "and the enc global")
  assert_equal(local_value("BUFFER_PAGE").file_selector_open, false, "the selector state is cleared")
  local draws = 0
  local update = screen.update
  screen.update = function() draws = draws + 1; return update() end
  next_frame(context)
  screen.update = update
  assert_equal(draws, 1, "the next frame draws the page, not a selector that never opened")
  tap(2); assert_true(context.fileselect.last ~= nil, "K2 opens the selector afterward")
  context.fileselect.close("/tmp/after.wav")
  assert_equal(#context.calls_named("loadBuffer"), 1, "and its choice loads")
end)

test("a menu file selector opened over BUFFER K2's gives Strata its keys and page back as the menu closes (#49)", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  params:set("v1_source", 2)
  local page = local_value("BUFFER_PAGE")
  local selector = context.fileselect
  local script_key, script_enc = key, enc
  -- norns' fs.enter, from play mode, puts its own key and enc handlers in
  -- the globals before norns.menu.init() routes them (the stub does not):
  -- only fs.exit for this selector restores them
  local selector_key, selector_enc = function() end, function() end
  local function open_strata_selector()
    tap(2); assert_true(page.file_selector_open, "K2 opens the selector")
    key, enc = selector_key, selector_enc
    norns.menu.init()
    assert_equal(_menu.key, selector_key, "the selector has the keys")
  end
  local function assert_strata_routed(where)
    assert_equal(page.file_selector_open, false, where .. ": the superseded selector state is cleared")
    assert_equal(_menu.key, script_key, where .. ": play mode routes the keys to Strata")
    assert_equal(norns.encoders.callback, script_enc, where .. ": and the encoders")
    assert_equal(key, script_key, where .. ": the key global is Strata's")
    assert_equal(enc, script_enc, where .. ": and the enc global")
  end
  open_strata_selector()
  -- K1 opens and closes the menu over it: the selector is still Strata's
  _menu.set_mode(true); _menu.set_mode(false)
  assert_true(page.file_selector_open, "the menu alone leaves the selector open")
  assert_equal(_menu.key, selector_key, "and its keys with it")
  -- K1, PARAMS, a file param: norns has one selector, now the menu's (Strata's
  -- callback is gone); fs.exit gives the menu its handlers back, not Strata's
  _menu.set_mode(true)
  local picked
  selector.enter(_path.audio, function(path) picked = path end)
  selector.close("/tmp/param.wav")
  assert_equal(picked, "/tmp/param.wav", "the PARAMS selector's choice")
  _menu.set_mode(false)  -- K1 back to play mode
  assert_strata_routed("a chosen PARAMS file")
  local draws, selector_redraws = 0, selector.redraws
  local update = screen.update
  screen.update = function() draws = draws + 1; return update() end
  redraw()
  screen.update = update
  assert_equal(draws, 1, "redraw() draws the page again")
  assert_equal(selector.redraws, selector_redraws, "not the file list")
  -- the PARAMS selector canceled (K2 in it) instead of a choice
  open_strata_selector()
  _menu.set_mode(true)
  selector.enter(_path.audio, function(path) picked = path end)
  selector.close()
  assert_equal(picked, "cancel", "the PARAMS selector was canceled")
  _menu.set_mode(false)
  assert_strata_routed("a canceled PARAMS selector")
  -- the menu closed while the PARAMS selector is still open
  open_strata_selector()
  _menu.set_mode(true)
  selector.enter(_path.audio, function() end)
  _menu.set_mode(false)
  assert_strata_routed("a PARAMS selector left open")
  -- Strata's own selector still works
  context.clear_engine_calls()
  tap(2); selector.close("/tmp/b.wav")
  assert_equal(#context.calls_named("loadBuffer"), 1, "K2's selector loads its choice")
  assert_equal(page.file_selector_open, false)
end)

test("the superseded-selector release acts only as the menu closes, and never breaks BUFFER K2 (#49)", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  params:set("v1_source", 2)
  local page = local_value("BUFFER_PAGE")
  local selector = context.fileselect
  -- play mode to play mode (norns.menu.init in fs.enter and fs.exit) is
  -- no menu closing: a callback that is not Strata's changes nothing then
  tap(2)
  local strata_callback = selector.callback
  selector.callback = function() end
  norns.menu.init()
  assert_true(page.file_selector_open, "a set_mode(false) from play mode releases nothing")
  selector.callback = strata_callback
  selector.close("/tmp/a.wav")
  assert_equal(page.file_selector_open, false, "the selector's own callback closes it")
  -- a norns whose fileselect keeps no `callback`: no release ever (the
  -- selector state may stay set, as before #49), and K2 still works
  local stub_enter = selector.enter
  selector.enter = function(...)
    stub_enter(...)
    selector.callback = nil
  end
  context.clear_engine_calls()
  tap(2); assert_true(page.file_selector_open, "K2 opens the selector")
  _menu.set_mode(true); _menu.set_mode(false)
  assert_true(page.file_selector_open, "no fileselect.callback: the menu closing releases nothing")
  selector.close("/tmp/b.wav")
  assert_equal(#context.calls_named("loadBuffer"), 1, "the choice loads")
  assert_equal(page.file_selector_open, false, "and the callback closes it")
  selector.enter = stub_enter
  -- an error in the release never stops the menu closing
  tap(2)
  key, enc = function() end, function() end
  _menu.set_mode(true)
  selector.enter(_path.audio, function() end)
  local real_request_redraw = request_redraw
  request_redraw = function() error("release failed") end
  context.printed = {}
  local closed = pcall(_menu.set_mode, false)
  request_redraw = real_request_redraw
  assert_true(closed, "set_mode(false) does not raise")
  assert_equal(norns.menu.status(), false, "the menu closed")
  assert_true(table.concat(context.printed, "\n"):find("release failed", 1, true), "the error is printed")
end)

test("opening the norns menu forgets held keys at once; cleanup restores _menu.set_mode", function()
  local stub_set_mode
  local context = load_strata({ before_init = function() stub_set_mode = _menu.set_mode end })
  finish_startup(context); show_page(4)
  assert_true(_menu.set_mode ~= stub_set_mode, "init watches _menu.set_mode")
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)
  context.clear_engine_calls(); context.fileselect.last = nil
  -- K2 down, then K1 opens and closes the menu between two 10 Hz ticks
  key(2, 1)
  _menu.set_mode(true)
  assert_equal(norns.menu.status(), true, "the wrapped set_mode still opens the menu")
  assert_equal(local_value("key_press_page")[2], nil, "the held K2 is forgotten as the menu opens")
  _menu.set_mode(false)
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  -- a K2+K3 save, then the menu: the next K2 tap opens the selector
  tap(3)  -- stop the recording
  context.polls.fire("bufferState", 202)  -- the engine reports the 2 s take
  key(2, 1); tap(3); assert_equal(#context.calls_named("saveBuffer"), 1)
  _menu.set_mode(true); _menu.set_mode(false)
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the selector")
  -- closing the menu forgets nothing (only an opening does)
  key(2, 1); _menu.set_mode(false)
  assert_equal(local_value("key_press_page")[2], 4, "set_mode(false) keeps a held key")
  key(2, 0)
  -- cleanup gives norns its own set_mode back
  cleanup()
  assert_equal(_menu.set_mode, stub_set_mode, "cleanup restores set_mode")
  -- something that wrapped set_mode after Strata keeps its wrapper; Strata's goes inert
  stub_set_mode = nil
  context = load_strata({ before_init = function() stub_set_mode = _menu.set_mode end })
  local strata_set_mode = _menu.set_mode
  local mod_set_mode = function(mode) strata_set_mode(mode) end
  _menu.set_mode = mod_set_mode
  cleanup()
  assert_equal(_menu.set_mode, mod_set_mode, "a later wrapper is left in place")
  show_page(4); key(2, 1)
  _menu.set_mode(true)
  assert_equal(norns.menu.status(), true, "the inert wrapper still passes the call on")
  assert_equal(local_value("key_press_page")[2], 4, "and no longer touches the script's keys")
  _menu.set_mode(false)
end)

test("key releases reach only the BUFFER page; other pages act once per press", function()
  local context = load_strata(); finish_startup(context)
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(2)
  show_page(1)
  key(3, 1); assert_true(local_value("frozen")[2], "K3 press freezes on MAIN")
  key(3, 0); assert_true(local_value("frozen")[2], "K3 release does not unfreeze")
  show_page(2)
  local mix = params:get("filter_mix")
  key(3, 1); key(3, 0)
  assert_true(params:get("filter_mix") ~= mix, "FX K3 press bypasses once, the release does not undo it")
  show_page(5); context.clear_engine_calls()
  local saved = 0
  local real_save = save_scenes_to_disk
  save_scenes_to_disk = function() saved = saved + 1 end
  key(3, 1); key(3, 0)
  save_scenes_to_disk = real_save
  assert_equal(saved, 1, "SETUP K3 saves once per press")
end)

test("BUFFER page draws the voice, its source and eight buffer rows", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(6); params:set("v6_source", 3)   -- karplus on buf 2
  load_buffer(2, "/tmp/drone.wav"); context.polls.fire("bufferState", 116)
  load_buffer(5, "/tmp/x.wav"); context.polls.fire("bufferState", 402.5)
  params:set("record_duration", 2); record_buffer(7)
  redraw()
  local left_name, left_source
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == 18 then left_name = entry.text end
    if entry.x == 0 and entry.y == 26 then left_source = entry.text end
  end
  assert_equal(left_name, "KARPLUS"); assert_equal(left_source, "src: buf 2")
  local rows = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.x >= 65 then
      rows[entry.y] = rows[entry.y] or {}
      table.insert(rows[entry.y], entry)
    end
  end
  local row_ys = {}
  for y in pairs(rows) do table.insert(row_ys, y) end
  table.sort(row_ys)
  assert_equal(#row_ys, 8, "eight buffer rows")
  assert_true(row_ys[1] > 8 and row_ys[8] < HINT_ROW_Y - TEXT_HEIGHT + 1, "rows between header and hints")
  local function row_text(slot)
    local parts = {}
    for _, entry in ipairs(texts_on_row(context, row_ys[slot])) do
      if entry.x >= 65 then table.insert(parts, entry.text) end
    end
    return table.concat(parts, " ")
  end
  local function row_level(slot)
    local level
    for _, entry in ipairs(rows[row_ys[slot]]) do
      assert_true(level == nil or level == entry.level, "one level per row")
      level = entry.level
    end
    return level
  end
  assert_equal(row_text(1), "1 empty 0.0s"); assert_equal(row_level(1), 2, "empty buffer dim")
  assert_equal(row_text(2), "2 drone 16.0s"); assert_equal(row_level(2), 15, "the voice's buffer bright")
  assert_equal(row_text(5), "5 x 2.5s"); assert_equal(row_level(5), 8, "loaded buffer")
  assert_equal(row_text(7), "7 empty REC", "REC while recording"); assert_equal(row_level(7), 8)
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save")
  -- the voice's buffer recording: the hint says K3 stops
  record_buffer(2); redraw()
  assert_equal(hint_text(context), "K2:load K3:stop K2+3:save")
  -- not a buffer: the hint says K2 and K3 do nothing
  params:set("v6_source", 1); redraw()
  assert_equal(hint_text(context), "K2:- K3:- E3:source")
  params:set("v6_source", 10); redraw()
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == 26 then assert_equal(entry.text, "src: input") end
  end
end)

test("BUFFER page layout holds for every voice, source and buffer state", function()
  local context = load_strata(); finish_startup(context)
  params:set("mutation_enabled", 1); params:set("master_density", 2.0)
  capture_scene(8); recall_scene(8, 0)
  local _, set_selected = find_upvalue("selected_voice")
  local long_names = { "WWWWWWWWWWWWWWWWWWWW.wav", "a_very_long_field_recording_name.aiff", "MMMM", "x",
    "café_crème_très_longue.wav", "no_extension_but_long" }
  local function set_buffers(state)
    for slot = 1, 8 do
      if state == "empty" then clear_buffer(slot)
      elseif state == "loaded" then
        load_buffer(slot, "/tmp/" .. long_names[(slot - 1) % #long_names + 1])
        context.polls.fire("bufferState", (slot - 1) * 100 + 16)
      elseif state == "recording" then
        clear_buffer(slot); record_buffer(slot)
      end
    end
  end
  for _, state in ipairs({ "empty", "loaded", "recording" }) do
    set_buffers(state)
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      for source = 1, 10 do
        params:set("v" .. voice_idx .. "_source", source)
        show_page(4)
        assert_screen_layout(context, "BUFFER, " .. state .. ", voice " .. voice_idx .. " source " .. source)
      end
    end
  end
end)

test("bufferState poll redraws the screen and the grid's buffer page", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  local device = context.grid.plug(1, 16, 16); context.grid.press(1, 16, 8, 1)
  load_buffer(3, "/tmp/a.wav")
  local refreshes = device.refresh_count
  context.screen.texts = {}
  context.polls.fire("bufferState", 212.5)
  next_frame(context)
  local found = false
  for _, entry in ipairs(context.screen.texts) do if entry.text == "12.5s" then found = true end end
  assert_true(found, "poll redraws the BUFFER page with the new seconds on the next frame")
  assert_true(device.refresh_count > refreshes, "grid page 4 redrawn")
end)

test("bufferState poll ignores NaN, infinities and out-of-range slots", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  local buffers = local_value("buffers")
  context.polls.fire("bufferState", 304)   -- slot 4 holds 4 s
  local before = deep_copy(buffers)
  for _, value in ipairs({ 0 / 0, math.huge, -math.huge, -1, 800 }) do
    local ok, message = pcall(context.polls.fire, "bufferState", value)
    assert_true(ok, "poll value " .. tostring(value) .. " raises no error: " .. tostring(message))
    for slot = 1, 8 do
      assert_equal(buffers[slot].seconds, before[slot].seconds, "poll value " .. tostring(value) .. ", slot " .. slot .. " seconds")
    end
    assert_equal(rawget(buffers, 0), nil, "no slot 0 after " .. tostring(value))
    assert_equal(rawget(buffers, 9), nil, "no slot 9 after " .. tostring(value))
  end
  redraw(); assert_screen_layout(context, "BUFFER page after bad poll values")
end)

test("arc BUFFER page: buf_pos, buf_rate, record duration and level", function()
  local context = load_strata(); finish_startup(context); show_page(4)
  local device = context.arc.plug(1)
  params:set("v1_source", 2)
  params:set("v1_buf_pos", 0.5); params:set("v1_buf_rate", 1)
  params:set("record_duration", 8); params:set("record_level", 1)
  context.arc.turn(1, 1, 20); assert_near(params:get("v1_buf_pos"), 0.5 + 20 / 512, 1e-6, "ring 1 buf_pos")
  context.arc.turn(1, 2, 100); assert_true(params:get("v1_buf_rate") > 1, "ring 2 buf_rate")
  context.arc.turn(1, 3, 100); assert_true(params:get("record_duration") > 8, "ring 3 record duration")
  context.arc.turn(1, 4, 100); assert_true(params:get("record_level") > 1, "ring 4 record level")
  next_frame(context)
  local ids = { "v1_buf_pos", "v1_buf_rate", "record_duration", "record_level" }
  for ring, param_id in ipairs(ids) do
    assert_near(device.segments[ring].to, param_fraction(param_id) * math.pi * 2, 1e-9, "ring " .. ring .. " shows " .. param_id)
  end
  assert_equal(device.segments[1].level, 15, "buffer voice: ring 1 bright")
  assert_equal(device.segments[3].level, 12)
  -- a synth voice: rings 1-2 still set its buffer params, drawn dim
  params:set("v1_source", 1); local rate = params:get("v1_buf_rate")
  context.arc.turn(1, 2, 100); assert_true(params:get("v1_buf_rate") > rate, "ring 2 still adjusts buf_rate")
  next_frame(context)
  assert_equal(device.segments[1].level, 4, "not buffer-sourced: ring 1 dim")
  assert_equal(device.segments[2].level, 4, "not buffer-sourced: ring 2 dim")
  assert_equal(device.segments[4].level, 12, "record rings stay lit")
  -- the selected voice follows E2
  enc(2, 1)
  local position = params:get("v2_buf_pos"); local voice1_position = params:get("v1_buf_pos")
  context.arc.turn(1, 1, 20)
  assert_true(params:get("v2_buf_pos") > position, "ring 1 follows the selected voice")
  assert_equal(params:get("v1_buf_pos"), voice1_position, "the previous voice's buf_pos is left alone")
end)

test("grid page 4 buffer rows record, clear and set sources with LED feedback", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16); context.grid.press(1, 16, 8, 1)
  context.grid.press(1, 5, 1, 1); assert_equal(context.calls_named("recordBuffer")[1].args[1], 4)
  assert_equal(device:get_led(5, 1), 15)
  context.grid.press(1, 3, 10, 1); assert_equal(params:get("v2_source"), 3); assert_equal(device:get_led(3, 10), 15)
  context.grid.press(1, 10, 15, 1); assert_equal(params:get("v7_source"), 10)
  context.grid.press(1, 5, 2, 1); assert_equal(context.calls_named("clearBuffer")[1].args[1], 4)
end)

test("grid page 4 buffer LEDs: row 1 state, row 2, source rows, and non-grid changes", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16); context.grid.press(1, 16, 8, 1)
  load_buffer(2, "/tmp/a.wav")              -- loaded, not from the grid
  params:set("record_duration", 2); params:set("buf6_record", 1)  -- recording, from params
  params:set("v1_source", 3)                -- voice 1 on buf 2
  for slot = 1, 8 do
    local expected = slot == 6 and 15 or (slot == 2 and 8 or 2)
    assert_equal(device:get_led(slot, 1), expected, "row 1 buffer " .. slot)
    assert_equal(device:get_led(slot, 2), 4, "row 2 clear " .. slot)
  end
  for voice_idx = 1, 7 do
    local y = 8 + voice_idx
    local source = params:get("v" .. voice_idx .. "_source")
    for x = 1, 10 do
      local expected
      if x == source then expected = 15
      elseif x >= 2 and x <= 9 and x - 1 ~= 2 and x - 1 ~= 6 then expected = 2
      else expected = 4 end
      assert_equal(device:get_led(x, y), expected, "voice " .. voice_idx .. " source col " .. x)
    end
    for x = 11, 16 do assert_equal(device:get_led(x, y), 0, "cols 11-16 dark") end
  end
  -- the selected source wins over "empty"
  params:set("v4_source", 9); assert_equal(device:get_led(9, 12), 15, "selected empty buffer lit 15")
  -- the recording completes: 15 -> 8
  wake_buffer_clock(context, 6); assert_equal(device:get_led(6, 1), 15, "a take waiting for the engine stays lit")
  context.polls.fire("bufferState", 503)  -- the engine reports the take
  assert_equal(device:get_led(6, 1), 8, "finished take shown as loaded")
  clear_buffer(2); assert_equal(device:get_led(2, 1), 2, "cleared buffer dim")
  -- a second row-1 press stops early; row 8 and 16 keep their meaning
  context.grid.press(1, 4, 1, 1); context.grid.press(1, 4, 1, 1)
  assert_equal(#context.calls_named("stopRecord"), 1, "second press stops the recording")
  context.grid.press(1, 3, 16, 1); assert_true(local_value("frozen")[3], "row 16 freezes on page 4")
  context.grid.press(1, 1, 8, 1); assert_true(local_value("pattern_playing"), "row 8 transport on page 4")
  -- the FX faders are still on rows 3-7
  context.grid.press(1, 16, 7, 1); assert_near(params:get("delay_mix"), 1, 1e-6, "row 7 delay mix")
  -- out-of-range columns do nothing
  context.clear_engine_calls()
  context.grid.press(1, 9, 1, 1); context.grid.press(1, 12, 2, 1); context.grid.press(1, 13, 11, 1)
  assert_equal(#context.engine_calls, 0, "columns past the buffers/sources send nothing")
  assert_equal(params:get("v3_source"), 1)
end)

test("input-sourced voices: main param, faders, randomize, mutate and drift use grain params", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 running
  local device = context.arc.plug(1)
  params:set("v1_source", 10)
  assert_equal(main_param_id(1), "v1_grain_size"); assert_equal(main_param_label(1), "size")
  assert_equal(fader_param_ids(1)[1], "v1_grain_size", "first grid fader")
  for _, id in ipairs(fader_param_ids(1)) do
    assert_true(not id:find("_buf_"), id .. ": no buffer faders for input")
  end
  -- the grain faders, then level and pan (the engine pans input voices), then crossmod
  assert_equal(fader_param_ids(1)[7], "v1_amp"); assert_equal(fader_param_ids(1)[8], "v1_pan")
  assert_equal(fader_param_ids(1)[9], "v1_mod_source_1")
  params:set("v4_source", 10)
  assert_equal(fader_param_ids(4)[7], "v4_amp"); assert_equal(fader_param_ids(4)[8], "v4_mod_source_1", "sub has no pan fader")
  assert_equal(#fader_param_ids(1), 6 + 2 + 9); assert_equal(fader_page_count(1), 5, "an input voice has 5 fader pages")
  assert_equal(fader_page_count(4), 4, "an input-sourced sub has 4 fader pages")
  params:set("v1_grain_size", 0.2)
  enc(3, 2); assert_true(params:get("v1_grain_size") > 0.2, "E3 on MAIN moves grain size")
  local size = params:get("v1_grain_size")
  context.arc.turn(1, 2, 200); assert_true(params:get("v1_grain_size") > size, "arc ring 2 moves grain size")
  next_frame(context)
  local param_min, param_max = param_range("v1_grain_size")
  assert_near(device.segments[2].to,
    util.linlin(param_min, param_max, 0, 64, params:get("v1_grain_size")) / 64 * math.pi * 2, 1e-9, "ring 2 shows grain size")
  redraw()
  local value
  for _, entry in ipairs(context.screen.texts) do if entry.x == 65 and entry.y == 50 then value = entry.text end end
  assert_equal(value, string.format("%.2f s", params:get("v1_grain_size")), "MAIN shows grain size")
  -- randomize, mutate and drift leave the synth and buffer params alone
  local synth_before = deep_copy(local_value("voices")[1].params)
  local buffer_before = {}
  for _, key in ipairs({ "buf_pos", "buf_rate", "buf_scan" }) do buffer_before[key] = params:get("v1_" .. key) end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(11)
  local grain_changed = false
  for _ = 1, 10 do
    local grain_before = params:get("v1_grain_size")
    randomize_voice(1); gentle_mutate(); for _ = 1, 10 do drift_update() end
    if params:get("v1_grain_size") ~= grain_before then grain_changed = true end
  end
  assert_true(grain_changed, "grain params still randomize and mutate")
  for key, val in pairs(synth_before) do
    assert_equal(local_value("voices")[1].params[key], val, "input voice keeps synth " .. key)
  end
  for key, val in pairs(buffer_before) do
    assert_equal(params:get("v1_" .. key), val, "input voice keeps " .. key)
  end
  -- buffer voices keep buf_pos
  params:set("v1_source", 2); assert_equal(main_param_id(1), "v1_buf_pos")
  assert_equal(fader_param_ids(1)[1], "v1_buf_pos")
end)

---------------------------------------------------------------------------
-- global LFOs, LFO page
---------------------------------------------------------------------------

-- lfo_depth_<n> is the library's percentage (0-100)
test("LFO modulates around the stored value without writing it, and restores on disable", function()
  local context = load_strata(); finish_startup(context)
  params:set("filter_freq", 1000); params:set("strata_lfo1_dest", 4)   -- filt freq
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.clear_engine_calls(); context.lfo.tick(local_value("lfos")[1], 1.0)   -- scaled = +0.5
  local call = context.calls_named("setFilter")[1]
  assert_near(call.args[1], 1000 + 0.5 * 0.5 * (20000 - 20), 1e-6)
  assert_near(params:get("filter_freq"), 1000, 1e-9, "param value untouched")
  context.clear_engine_calls(); params:set("lfo_1", 1)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000, 1e-6, "disable restores the stored value")
end)

test("main destination follows a voice's source and restores the old param", function()
  local context = load_strata(); finish_startup(context)
  params:set("strata_lfo2_dest", 13)   -- v1 main
  params:set("lfo_depth_2", 100); params:set("lfo_2", 2)
  context.lfo.tick(local_value("lfos")[2], 0.5)
  assert_equal(local_value("lfo_last_dest")[2], "v1_freq")
  params:set("v1_source", 2); context.clear_engine_calls(); context.lfo.tick(local_value("lfos")[2], 0.5)
  local voice_calls = context.calls_named("setVoiceParam")
  assert_equal(voice_calls[1].args[2], "freq"); assert_near(voice_calls[1].args[3], params:get("v1_freq"), 1e-9)
  assert_equal(local_value("lfo_last_dest")[2], "v1_buf_pos")
end)

test("LFO restores the stored value when its depth reaches 0 or its destination changes", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  params:set("delay_mix", 0.2); params:set("strata_lfo1_dest", 9)   -- dly mix
  params:set("lfo_depth_1", 40); params:set("lfo_1", 2)
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)     -- scaled +0.4
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2 + 0.4 * 0.5, 1e-9, "modulated mix")
  context.clear_engine_calls(); params:set("lfo_depth_1", 0)
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9, "depth 0 restores")
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)
  assert_equal(#context.engine_calls, 0, "a depth-0 LFO sends nothing")
  params:set("lfo_depth_1", 40); context.clear_engine_calls()
  context.lfo.tick(lfos[1], 0.0)                                    -- scaled -0.4: clamped at 0
  assert_near(context.calls_named("setDelay")[1].args[3], 0, 1e-9, "modulated value clamps to the range")
  context.clear_engine_calls(); params:set("strata_lfo1_dest", 10)  -- rev mix
  assert_near(context.calls_named("setDelay")[1].args[3], 0.2, 1e-9, "destination change restores the old one")
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)
  assert_equal(#context.calls_named("setDelay"), 0, "old destination left alone")
  assert_near(context.calls_named("setReverb")[1].args[1], util.clamp(params:get("reverb_mix") + 0.2, 0, 1), 1e-9,
    "new destination modulated")
  context.clear_engine_calls(); params:set("strata_lfo1_dest", 1)   -- none
  context.lfo.tick(lfos[1], 1.0)
  assert_near(context.calls_named("setReverb")[1].args[1], params:get("reverb_mix"), 1e-9, "none restores")
  assert_equal(#context.calls_named("setReverb"), 1, "and then sends nothing")
end)

test("a full-depth LFO clamps its destination to both ends of the range (#50)", function()
  local context = load_strata(); finish_startup(context)
  local lfo = local_value("lfos")[1]
  params:set("strata_lfo1_dest", 8)   -- dly fdbk, 0-0.95
  params:set("lfo_depth_1", 100); params:set("lfo_1", 2)
  -- each tick moves the sent value well past the send threshold
  params:set("delay_feedback", 0.95); context.lfo.tick(lfo, 0.0)    -- scaled -1: 0.475 sent
  context.clear_engine_calls(); context.lfo.tick(lfo, 1.0)          -- scaled +1: 0.95 + 0.475
  assert_near(context.calls_named("setDelay")[1].args[2], 0.95, 1e-9, "clamped at the top of the range")
  params:set("delay_feedback", 0)                                   -- 0 + 0.475 sent
  context.clear_engine_calls(); context.lfo.tick(lfo, 0.0)          -- scaled -1: 0 - 0.475
  assert_near(context.calls_named("setDelay")[1].args[2], 0, 1e-9, "clamped at the bottom of the range")
  assert_near(params:get("delay_feedback"), 0, 1e-9, "param value untouched")
end)

-- sync_voice_values_to_engine sends the stored density, so the modulated
-- value sent before the restart must be forgotten: master density scales
-- what the engine has
test("a restarted voice's grain density scales from its stored value until the next LFO step (#50)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  assert_true(voices[1].active, "voice 1 is running")
  params:set("v1_grain_density", 20); params:set("master_density", 1)
  params:set("strata_lfo1_dest", 15)   -- v1 dens
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(local_value("lfos")[1], 1.0)   -- scaled +0.5: the engine gets a modulated density
  assert_equal(voices[1].grain.density, 20, "the stored density is untouched")
  toggle_voice(1); toggle_voice(1)                -- restart: the sync sends the stored density
  context.clear_engine_calls()
  params:set("master_density", 1.5)               -- before the LFO's next step
  local density_calls = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "grainDensity" then table.insert(density_calls, call) end
  end
  assert_equal(#density_calls, 1, "master density resends voice 1's grain density")
  assert_near(density_calls[1].args[3], 20 * 1.5, 1e-6, "from the stored density, not the modulated one")
end)

test("LFOs on params of one command, or on one param, do not undo each other", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  params:set("filter_freq", 1000); params:set("filter_res", 0.5)
  params:set("strata_lfo1_dest", 4); params:set("strata_lfo2_dest", 5)   -- filt freq, filt res
  for n = 1, 2 do params:set("lfo_depth_" .. n, 20); params:set("lfo_" .. n, 2) end
  context.lfo.tick(lfos[1], 1.0); context.clear_engine_calls(); context.lfo.tick(lfos[2], 1.0)
  local call = context.calls_named("setFilter")[1]
  assert_near(call.args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "LFO 2 keeps LFO 1's filter freq")
  assert_near(call.args[2], 0.5 + 0.2 * 0.5, 1e-6, "and adds its res")
  -- a user change to res is sent with the modulated freq
  context.clear_engine_calls(); params:set("filter_res", 0.3)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "freq stays modulated")
  -- two LFOs on one destination add up; disabling one leaves the other's offset
  params:set("strata_lfo2_dest", 4)
  context.lfo.tick(lfos[1], 1.0); context.clear_engine_calls(); context.lfo.tick(lfos[2], 1.0)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.4 * 0.5 * 19980, 1e-6, "offsets add")
  context.clear_engine_calls(); params:set("lfo_2", 1)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000 + 0.2 * 0.5 * 19980, 1e-6, "LFO 1 still applies")
  -- master density modulation reaches every running voice's grain density
  params:set("strata_lfo1_dest", 2); params:set("master_density", 1)
  context.clear_engine_calls(); context.lfo.tick(lfos[1], 1.0)       -- +0.2 * 0.5 * 1.9
  local voices = local_value("voices")
  for _, density_call in ipairs(context.calls_named("setGrainParam")) do
    local voice_idx = density_call.args[1] + 1
    assert_true(voices[voice_idx].active, "only running voices")
    assert_near(density_call.args[3], voices[voice_idx].grain.density * (1 + 0.19), 1e-6, "modulated density")
  end
  assert_true(#context.calls_named("setGrainParam") >= 1, "a running voice got its density")
  assert_near(params:get("master_density"), 1, 1e-9, "master density param untouched")
end)

test("LFO params: library groups, a destination group, labels and resolvers", function()
  load_strata()
  local destinations = local_value("LFO_DESTINATIONS")
  assert_equal(#destinations, 12 + 7 * 8, "12 globals, 8 per voice")
  local expected_ids = { [1] = nil, [2] = "master_density", [3] = "drift_amount", [4] = "filter_freq",
    [5] = "filter_res", [6] = "filter_mix", [7] = "delay_time", [8] = "delay_feedback", [9] = "delay_mix",
    [10] = "reverb_mix", [11] = "reverb_size", [12] = "reverb_damp", [13] = "v1_freq", [14] = "v1_grain_size",
    [15] = "v1_grain_density", [16] = "v1_grain_pitch", [17] = "v1_grain_spread", [18] = "v1_buf_pos",
    [19] = "v1_buf_rate", [20] = "v1_buf_scan", [21] = "v2_index", [68] = "v7_buf_scan" }
  for index = 1, #destinations do
    local resolved = destinations[index].resolve()
    if expected_ids[index] or index == 1 then
      assert_equal(resolved, expected_ids[index], "destination " .. index)
    end
    if resolved then assert_true(params:lookup_param(resolved).controlspec, resolved .. " is a control param") end
    assert_true(stubs.text_width(destinations[index].label) <= 49, destinations[index].label .. " fits its column")
  end
  assert_equal(destinations[13].label, "v1 main")
  local group = params:lookup_param("strata_lfos")
  assert_equal(group.t, params.tGROUP); assert_equal(group.n, 3, "destination group holds the three dests")
  for n = 1, 3 do
    local dest = params:lookup_param("strata_lfo" .. n .. "_dest")
    assert_equal(dest.count, #destinations); assert_equal(params:get("strata_lfo" .. n .. "_dest"), 1, "none")
    assert_equal(params:lookup_param("lfo_group_" .. n).n, 15, "the library's own group")
    assert_equal(params:string("lfo_" .. n), "off", "LFOs start off")
    assert_equal(params:get("lfo_depth_" .. n), 0)
    assert_equal(params:string("lfo_mode_" .. n), "free")
    assert_near(params:get("lfo_free_" .. n), 4, 1e-9, "4 s period")
    assert_equal(params:string("lfo_baseline_" .. n), "from center")
    local lfo = local_value("lfos")[n]
    assert_equal(lfo:get("min"), -1); assert_equal(lfo:get("max"), 1)
  end
end)

test("LFO page: E2 selects, E3 depth in percent, K3 enables, K2 cycles destination", function()
  local context = load_strata(); finish_startup(context)
  show_page(3)
  enc(2, 1); assert_equal(local_value("selected_lfo"), 2)
  enc(2, 5); assert_equal(local_value("selected_lfo"), 3, "clamped to 3 LFOs")
  enc(2, -1)
  enc(3, 7); assert_equal(params:get("lfo_depth_2"), 7, "E3 steps depth by percent")
  key(3, 1); key(3, 0); assert_equal(params:string("lfo_2"), "on")
  key(3, 1); key(3, 0); assert_equal(params:string("lfo_2"), "off")
  key(2, 1); key(2, 0); assert_equal(params:get("strata_lfo2_dest"), 2)
  params:set("strata_lfo2_dest", #local_value("LFO_DESTINATIONS"))
  key(2, 1); key(2, 0); assert_equal(params:get("strata_lfo2_dest"), 1, "K2 wraps to none")
  -- MAIN is untouched by LFO page input
  assert_equal(local_value("selected_voice"), 1)
end)

test("the LFO page redraws on every frame while it is shown, with no clock of its own", function()
  local context = load_strata(); finish_startup(context)
  local baseline = context.clock.pending_count()
  show_page(3)
  assert_equal(context.clock.pending_count(), baseline, "no page clock: the frame clock draws it")
  next_frame(context)
  local counter = count_screen_draws()
  next_frame(context); next_frame(context)
  assert_equal(counter.screen, 2, "each frame redraws, so the dots move")
  show_page(4); next_frame(context)
  counter.screen = 0
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "other pages draw only when asked")
end)

-- The LFO page's waveform, dot and labels for LFO n
local function lfo_row_drawing(context, n)
  local top = 16 + (n - 1) * 15
  local row = { lines = {}, rects = {}, texts = {} }
  for _, line in ipairs(context.screen.lines) do
    if line.y1 >= top and line.y1 <= top + 10 then table.insert(row.lines, line) end
  end
  for _, rect in ipairs(context.screen.rects) do
    if rect.y >= top - 1 and rect.y <= top + 10 then table.insert(row.rects, rect) end
  end
  for _, entry in ipairs(context.screen.texts) do
    if entry.y > top and entry.y <= top + 11 then table.insert(row.texts, entry.text) end
  end
  return row
end

test("LFO page rows: waveform, dot from the last raw value and elapsed period, labels; cleanup stops LFOs", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  context.set_time(100)
  params:set("strata_lfo1_dest", 4); params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(lfos[1], 0.25)
  show_page(3)
  -- three rows, each labeled, and every string inside the screen
  for n = 1, 3 do
    local row = lfo_row_drawing(context, n)
    assert_true(table.concat(row.texts, " "):find("L" .. n, 1, true), "row " .. n .. " labeled L" .. n)
    assert_true(#row.lines >= 63, "row " .. n .. " draws its waveform")
  end
  for _, entry in ipairs(context.screen.texts) do
    local left, right = text_span(entry)
    assert_true(left >= 0 and right <= 128 and entry.y <= 64, "'" .. entry.text .. "' inside the screen")
  end
  -- every drawn shape stays inside its row, rows inside y 14-58
  for _, line in ipairs(context.screen.lines) do
    assert_true(line.y1 >= 14 and line.y2 <= 58 and line.y2 >= 14 and line.y1 <= 58, "line inside y 14-58")
    assert_true(line.x1 >= 12 and line.x2 <= 75, "waveform inside x 12-75")
  end
  local row = lfo_row_drawing(context, 1)
  assert_true(#row.lines >= 63, "64 px waveform ")
  assert_equal(#row.rects, 1, "one dot for a running LFO")
  -- reset to the floor (phase 0.75) at t 100, so at t 100 the dot is at 0.75
  local dot = row.rects[1]
  assert_near(dot.x + 1, 12 + 0.75 * 63, 0.51, "dot x from the phase since the reset")
  assert_near(dot.y + 1, 16 + 10 - 0.25 * 10, 0.51, "dot y from the last raw value")
  assert_true(table.concat(row.texts, " "):find("filt freq"), "destination label")
  assert_true(table.concat(row.texts, " "):find("on 50%%"), "state and depth")
  -- one second later at a 4 s period: a quarter cycle further, wrapped to 0
  context.set_time(101); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12, 0.51, "dot advanced and wrapped")
  -- a period change keeps the phase (like the library), then advances at the new rate
  params:set("lfo_free_1", 2)
  context.set_time(101.5); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.25 * 63, 0.51, "advances at the new period")
  -- the phase offset shifts the dot, the reset trigger restarts it
  params:set("lfo_phase_1", 50); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.75 * 63, 0.51, "phase offset")
  params:set("lfo_phase_1", 0); params:set("lfo_reset_1", 1); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.75 * 63, 0.51, "reset to the floor")
  -- stopped LFOs draw no dot
  assert_equal(#lfo_row_drawing(context, 2).rects, 0, "no dot for a stopped LFO")
  assert_true(table.concat(lfo_row_drawing(context, 2).texts, " "):find("off 0%%"), "stopped LFO shows off")
  -- every shape and every destination label keeps the page apart and inside the screen
  for shape = 1, 6 do
    for n = 1, 3 do params:set("lfo_shape_" .. n, shape) end
    for _, dest in ipairs({ 1, 3, 12, 17, 68 }) do
      params:set("strata_lfo2_dest", dest); params:set("lfo_depth_2", 100); redraw()
      assert_screen_layout(context, "LFO shape " .. shape .. ", dest " .. dest)
      for _, line in ipairs(context.screen.lines) do
        assert_true(line.y1 >= 14 and line.y2 <= 58 and line.y2 >= 14 and line.y1 <= 58, "shape " .. shape .. " inside rows")
      end
    end
  end
  -- cleanup turns a running LFO off
  params:set("lfo_3", 2); cleanup(); assert_equal(params:get("lfo_3"), 1, "cleanup stops LFO 3")
end)

test("arc LFO page: rings 1-3 depth, ring 4 period of the selected LFO", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  show_page(3)
  context.arc.turn(1, 1, 100); assert_equal(params:get("lfo_depth_1"), 10, "ring 1: 10 ticks per percent")
  context.arc.turn(1, 3, 55); assert_equal(params:get("lfo_depth_3"), 5, "whole percents only")
  context.arc.turn(1, 3, 5); assert_equal(params:get("lfo_depth_3"), 6, "remainder carried")
  next_frame(context)
  assert_near(device.segments[1].to, 0.1 * math.pi * 2, 1e-9, "ring 1 shows depth")
  enc(2, 1)   -- LFO 2
  local period = params:get("lfo_free_2")
  context.arc.turn(1, 4, 100); assert_true(params:get("lfo_free_2") > period, "ring 4: free period")
  assert_equal(params:get("lfo_free_1"), 4, "only the selected LFO")
  next_frame(context)
  assert_near(device.segments[4].to, param_fraction("lfo_free_2") * math.pi * 2, 1e-9, "ring 4 shows the period")
  params:set("lfo_mode_2", 1)   -- clocked
  local rate = params:get("lfo_clocked_2")
  context.arc.turn(1, 4, -40); assert_equal(params:get("lfo_clocked_2"), rate - 2, "ring 4: clocked rate, 20 ticks a step")
  next_frame(context)
  assert_near(device.segments[4].to, param_fraction("lfo_clocked_2") * math.pi * 2, 1e-9)
end)

test("arc LFO ring 4 forgets its carried ticks when the selected LFO or its mode changes", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1); show_page(3)
  for n = 1, 3 do params:set("lfo_mode_" .. n, 1) end   -- clocked: 20 ticks a rate step
  local rate_1, rate_2 = params:get("lfo_clocked_1"), params:get("lfo_clocked_2")
  context.arc.turn(1, 4, 15); assert_equal(params:get("lfo_clocked_1"), rate_1, "15 ticks carried for LFO 1")
  enc(2, 1)   -- LFO 2
  context.arc.turn(1, 4, 5)
  assert_equal(params:get("lfo_clocked_2"), rate_2, "LFO 1's carried ticks do not step LFO 2")
  context.arc.turn(1, 4, 15); assert_equal(params:get("lfo_clocked_2"), rate_2 + 1, "20 of its own ticks do")
  -- away and back again also forgets them
  context.arc.turn(1, 4, 15); enc(2, -1); enc(2, 1)
  context.arc.turn(1, 4, 5); assert_equal(params:get("lfo_clocked_2"), rate_2 + 1, "reselecting forgets the carry")
  -- the selected LFO's mode changing forgets them
  context.arc.turn(1, 4, 10)   -- 15 carried
  params:set("lfo_mode_2", 2); params:set("lfo_mode_2", 1)
  context.arc.turn(1, 4, 5); assert_equal(params:get("lfo_clocked_2"), rate_2 + 1, "a mode change forgets the carry")
  -- another LFO's mode changing does not
  context.arc.turn(1, 4, 10)   -- 15 carried
  params:set("lfo_mode_3", 2)
  context.arc.turn(1, 4, 5); assert_equal(params:get("lfo_clocked_2"), rate_2 + 2, "LFO 3's mode leaves LFO 2's carry")
  -- the depth rings keep their own remainders
  context.arc.turn(1, 1, 5); enc(2, 1); context.arc.turn(1, 1, 5)
  assert_equal(params:get("lfo_depth_1"), 1, "ring 1's carry survives a selection change")
end)

test("scenes capture and recall the LFOs; old files load with LFOs off", function()
  local context = load_strata({ data_subdir = "lfo_scenes" }); finish_startup(context)
  params:set("lfo_shape_1", 2); params:set("lfo_mode_1", 1); params:set("lfo_clocked_1", 5)
  params:set("lfo_free_2", 9); params:set("lfo_depth_2", 60); params:set("strata_lfo2_dest", 14)
  params:set("lfo_2", 2)
  capture_scene(1)
  local data = local_value("scenes")[1].data
  assert_equal(data.lfo_shape_1, 2); assert_equal(data.lfo_mode_1, 1); assert_equal(data.lfo_clocked_1, 5)
  assert_near(data.lfo_free_2, 9, 1e-9); assert_equal(data.lfo_depth_2, 60)
  assert_equal(data.strata_lfo2_dest, 14); assert_equal(data.lfo_2, 2)
  params:set("lfo_2", 1); params:set("lfo_depth_2", 0); params:set("strata_lfo2_dest", 1); params:set("lfo_shape_1", 1)
  recall_scene(1, 0)
  assert_equal(params:string("lfo_2"), "on"); assert_equal(params:get("lfo_depth_2"), 60)
  assert_equal(params:get("strata_lfo2_dest"), 14); assert_equal(params:string("lfo_shape_1"), "tri")
  assert_equal(local_value("lfos")[2]:get("enabled"), 1, "recalled LFO runs")
  -- smooth transitions fade depth and free period, switch the rest at the end
  local continuous = {}
  for _, global in ipairs(local_value("SCENE_GLOBAL_PARAMS")) do continuous[global.id] = global.continuous end
  for n = 1, 3 do
    assert_equal(continuous["lfo_depth_" .. n], true); assert_equal(continuous["lfo_free_" .. n], true)
    for _, id in ipairs({ "lfo_" .. n, "lfo_shape_" .. n, "lfo_mode_" .. n, "lfo_clocked_" .. n, "strata_lfo" .. n .. "_dest" }) do
      assert_equal(continuous[id], false, id .. " switches")
    end
  end
  -- invalid option values are rejected
  local bad = deep_copy(local_value("scenes")[1]); bad.data.strata_lfo2_dest = 0.5
  assert_true(not validate_scene(bad), "fractional destination rejected")
  bad.data.strata_lfo2_dest = #local_value("LFO_DESTINATIONS") + 1
  assert_true(not validate_scene(bad), "out-of-range destination rejected")
  -- a scene saved before the LFOs existed recalls them as off with defaults
  local old = deep_copy(local_value("scenes")[1])
  for key in pairs(old.data) do
    if key:find("^lfo_") or key:find("^strata_lfo") then old.data[key] = nil end
  end
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  tab.save({ version = 2, scenes = { old } }, context.data_dir .. "strata/scenes.data")
  load_scenes_from_disk()
  assert_true(local_value("scenes")[1].populated, "pre-LFO scene file loads")
  recall_scene(1, 0)
  assert_equal(params:string("lfo_2"), "off"); assert_equal(params:get("lfo_depth_2"), 0)
  assert_equal(params:get("strata_lfo2_dest"), 1); assert_equal(params:string("lfo_mode_1"), "free")
end)

test("param actions under a running LFO send the modulated value (drift, edits)", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  params:set("v1_source", 2)                                     -- buf 1: the drift moves buf_pos
  params:set("v1_buf_pos", 0.4); params:set("strata_lfo1_dest", 18)  -- v1 pos
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(lfos[1], 1.0)                                 -- scaled +0.5: +0.25 of the range
  math.randomseed(5)
  context.clear_engine_calls(); drift_update()
  local sent
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "bufPos" then sent = call.args[3] end
  end
  assert_true(params:get("v1_buf_pos") ~= 0.4, "the drift moved the stored position")
  assert_near(sent, params:get("v1_buf_pos") + 0.25, 1e-9, "drift sends the position with the LFO offset")
  -- a user edit of a modulated FX param keeps the offset too
  params:set("filter_freq", 1000); params:set("strata_lfo2_dest", 4)
  params:set("lfo_depth_2", 20); params:set("lfo_2", 2); context.lfo.tick(lfos[2], 1.0)
  context.clear_engine_calls(); params:set("filter_freq", 2000)
  assert_near(context.calls_named("setFilter")[1].args[1], 2000 + 0.2 * 0.5 * 19980, 1e-6, "edit keeps the offset")
  -- unmodulated params still send exactly their value
  context.clear_engine_calls(); params:set("filter_res", 0.3)
  assert_near(context.calls_named("setFilter")[1].args[2], 0.3, 1e-9)
end)

test("LFO steps run at 48 ppqn and skip sends below 1/1000 of the range; restores always send", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  for n = 1, 3 do assert_equal(lfos[n]:get("ppqn"), 48, "LFO " .. n .. " ppqn") end
  params:set("filter_mix", 0.5); params:set("strata_lfo1_dest", 6)  -- filt mix (0-1)
  params:set("lfo_free_1", 300); params:set("lfo_depth_1", 100); params:set("lfo_1", 2)
  -- ten seconds of a 300 s sine at 120 BPM: 96 steps a second, from the floor
  local steps = 10 * 96
  context.clear_engine_calls()
  for step = 1, steps do
    context.lfo.tick(lfos[1], (math.sin(2 * math.pi * (0.75 + step / (300 * 96))) + 1) / 2)
  end
  local calls = context.calls_named("setFilter")
  assert_true(#calls >= 5 and #calls <= 15, "a slow LFO sends rarely (" .. #calls .. " of " .. steps .. " steps)")
  for index = 2, #calls do
    assert_true(math.abs(calls[index].args[4] - calls[index - 1].args[4]) >= 0.001 - 1e-12, "each send moves >= 1/1000")
  end
  -- a step below the threshold is skipped, but turning the LFO off restores at once
  local last_sent = calls[#calls].args[4]
  context.clear_engine_calls()
  -- (mix 0.5 at depth 100: the sent mix equals the raw value)
  context.lfo.tick(lfos[1], last_sent + 0.0004)
  assert_equal(#context.calls_named("setFilter"), 0, "tiny step skipped")
  params:set("lfo_1", 1)
  calls = context.calls_named("setFilter")
  assert_equal(#calls, 1, "restore sends"); assert_near(calls[1].args[4], 0.5, 1e-9, "stored mix restored")
  assert_true(last_sent ~= 0.5, "the restore was a change")
  -- a restore sends even when the engine already has the stored value
  params:set("lfo_1", 2); context.lfo.tick(lfos[1], 0.5)        -- scaled 0: value 0.5
  context.clear_engine_calls(); params:set("lfo_depth_1", 0)
  assert_equal(#context.calls_named("setFilter"), 1, "depth 0 restore sends")
  -- a fast LFO sends on every step
  params:set("lfo_depth_1", 100); context.clear_engine_calls()
  for step = 1, 20 do context.lfo.tick(lfos[1], step % 2) end
  assert_equal(#context.calls_named("setFilter"), 20, "large steps all sent")
end)

test("cleanup stops the LFOs and restores their destinations", function()
  local context = load_strata(); finish_startup(context)
  params:set("filter_freq", 800); params:set("strata_lfo1_dest", 4)
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(local_value("lfos")[1], 1.0)
  context.clear_engine_calls(); cleanup()
  assert_equal(params:get("lfo_1"), 1); assert_equal(local_value("lfos")[1]:get("enabled"), 0)
  assert_near(context.calls_named("setFilter")[1].args[1], 800, 1e-6, "destination restored")
end)

---------------------------------------------------------------------------
-- runner
---------------------------------------------------------------------------

local failures = 0
for _, entry in ipairs(tests) do
  local ok, err = run_test(entry.func)
  print = real_print
  if ok then
    real_print("ok   " .. entry.name)
  else
    failures = failures + 1
    real_print("FAIL " .. entry.name .. "\n     " .. tostring(err):gsub("\n", "\n     "))
  end
end

os.execute("rm -rf '" .. data_root .. "'")

real_print(string.format("\n%d tests, %d failures", #tests, failures))
os.exit(failures == 0 and 0 or 1)

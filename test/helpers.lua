-- test/helpers.lua
-- The harness shared by every unit file: the stubs, the test registry, the
-- assertions, load_strata, the script lookups (find_upvalue, local_value)
-- and the helpers more than one unit file uses. Returns them as one table,
-- which test/run.lua passes to each test/unit/*_test.lua.

local test_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "test"
local repo_root = test_dir .. "/.."

local stubs = require("norns_stubs")
local sync_check = require("sync_check")
local real_print = print

-- The globals of plain Lua and of this harness, before any stub or script
-- adds its own (the global-reference check starts from these)
local harness_globals = {}
for name in pairs(_G) do harness_globals[name] = true end

local LUA_PATH = repo_root .. "/strata.lua"
-- The engine's source: lib/Engine_Strata.sc, then lib/engine/*.sc sorted,
-- each after a "// file: <path>" line. Every test that reads the engine
-- reads this, never one file.
local function engine_sources() return stubs.engine_sources(repo_root) end
local signatures = stubs.parse_engine_signatures(engine_sources())
local engine_polls = stubs.parse_engine_polls(engine_sources())
local engine_spec = stubs.parse_engine_spec(engine_sources())
local engine_spec_problems = stubs.engine_spec_problems(engine_spec)
assert(#engine_spec_problems == 0, table.concat(engine_spec_problems, "\n"))

local data_root = os.tmpname()
os.remove(data_root)
os.execute("mkdir -p '" .. data_root .. "'")
data_root = data_root .. "/"
-- an absolute folder at least two levels down (os.tmpname gives /tmp/lua_XXXXXX)
assert(data_root:match("^/[^/]+/.*[^/]/$"), "unexpected temporary folder: " .. data_root)

-- A string quoted for /bin/sh: single quotes, each ' written as '\''
local function shell_quote(text)
  return "'" .. (tostring(text):gsub("'", "'\\''")) .. "'"
end

-- Delete a folder tree the suite made: data_root itself or a path inside
-- it, absolute, with no "." or ".." segment. Any other path raises an error
-- and deletes nothing.
local function remove_tree(path)
  if type(path) ~= "string" then error("remove_tree: not a path: " .. tostring(path), 2) end
  local target, root = path:gsub("/+$", ""), data_root:gsub("/+$", "")
  if target:sub(1, 1) ~= "/" then error("remove_tree: not an absolute path: " .. path, 2) end
  for segment in target:gmatch("[^/]+") do
    if segment == "." or segment == ".." then error("remove_tree: a . or .. segment: " .. path, 2) end
  end
  if target ~= root and target:sub(1, #root + 1) ~= root .. "/" then
    error("remove_tree: outside the suite's temporary folder (" .. data_root .. "): " .. path, 2)
  end
  os.execute("rm -rf -- " .. shell_quote(target))
end

local tests = {}
local function test(name, func) table.insert(tests, { name = name, func = func }) end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function fail(message, level) error(message, (level or 1) + 1) end

-- The current test's invariant check (run_test): loaded is set by
-- load_strata, allowed (the reason) by allow_broken_invariants
local invariant_check = { loaded = false, allowed = nil }

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
-- would draw the same name.
local loads = 0

-- The performance_active.data the next load_strata finds, as the engine
-- would have written it at alloc: fields {tier, buffer_seconds, max_grains,
-- history_seconds, reason} written as "key value" lines in that order (a
-- field left out is not written), or a string written as it is (a garbled
-- or truncated file). nil: no file (the default; Lua then runs standard).
-- Applies to the next load only
local pending_performance_active
local PERFORMANCE_ACTIVE_KEYS = { "tier", "buffer_seconds", "max_grains", "history_seconds", "reason" }
local function write_performance_active(fields)
  pending_performance_active = fields
end

local function write_pending_performance_active(data_dir)
  local fields = pending_performance_active
  pending_performance_active = nil
  if fields == nil then return end
  local text = fields
  if type(fields) == "table" then
    local lines = {}
    for _, key in ipairs(PERFORMANCE_ACTIVE_KEYS) do
      if fields[key] ~= nil then table.insert(lines, key .. " " .. tostring(fields[key])) end
    end
    text = table.concat(lines, "\n") .. "\n"
  end
  os.execute("mkdir -p '" .. data_dir .. "strata'")
  local file = assert(io.open(data_dir .. "strata/performance_active.data", "w"))
  file:write(text)
  file:close()
end

local function load_strata(options)
  options = options or {}
  loads = loads + 1
  local data_dir = data_root .. (options.data_subdir or ("load" .. loads)) .. "/"
  invariant_check.loaded = true
  local context = stubs.install { signatures = signatures, engine_polls = engine_polls, engine_spec = engine_spec,
    data_dir = data_dir, quiet = true, module_sources = options.module_sources }
  context.data_dir = data_dir
  context.audio_dir = data_dir .. "audio/"
  write_pending_performance_active(data_dir)
  if options.before_load then options.before_load(context) end
  local chunk = options.source and assert(load(options.source, "@" .. LUA_PATH)) or assert(loadfile(LUA_PATH))
  chunk()
  -- lua/core/script.lua's Script.load: the script's redraw and refresh, for
  -- the menu's set_mode(false) to put back (#521)
  norns.script.redraw, norns.script.refresh = rawget(_G, "redraw"), rawget(_G, "refresh")
  if options.before_init then options.before_init(context) end
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

-- The invariants of the script loaded last (shared_state(): the one this
-- test loaded, or, in a test that loaded nothing, whatever script an earlier
-- test left; run_test checks only a test that loaded) that are broken now,
-- as "<name>: <message>" in registration order; an invariant that raises
-- is listed with its error. Empty when every one holds or nothing was ever
-- loaded. Raises when the loaded S has no S.registry.invariants (a patched
-- lib/state that left it out): run_test fails that test with the error
local function check_invariants()
  local S = shared_state()
  local broken = {}
  if type(S) ~= "table" then return broken end
  local invariants = type(S.registry) == "table" and S.registry.invariants
  if type(invariants) ~= "table" then
    error("the loaded script has no S.registry.invariants table", 2)
  end
  for _, record in ipairs(invariants) do
    local ok, message = pcall(record.fn)
    if not ok then
      table.insert(broken, record.name .. ": raised " .. tostring(message))
    elseif message ~= nil then
      table.insert(broken, record.name .. ": " .. tostring(message))
    end
  end
  return broken
end

-- Turn the invariant check off for the current test, which breaks one on
-- purpose (the reason says why)
local function allow_broken_invariants(reason)
  if type(reason) ~= "string" or reason == "" then
    error("allow_broken_invariants: a reason is a non-empty string", 2)
  end
  invariant_check.allowed = reason
end

-- Run one test function: ok, or false and the error. Errors the scheduler
-- reported while resuming a clock (norns prints them and keeps running)
-- fail the test unless it claimed them (clock.take_errors); when the test
-- failed anyway, they are added to its error. So do the errors the script
-- caught itself and printed (a frame draw, a playhead tick, a menu-close
-- hook: stubs.take_script_errors), unless the test claimed them
-- (context.take_script_errors, #473). A test that passed, reported
-- no clock error and called load_strata itself then has the script's
-- invariants checked (check_invariants), unless it allowed broken ones
-- (allow_broken_invariants); a check that raises fails the test with
-- "invariant check failed:" and its error. A run_test inside a test keeps
-- the outer test's flags: they are restored on every return
local function run_test(func)
  local outer_loaded, outer_allowed = invariant_check.loaded, invariant_check.allowed
  invariant_check.loaded, invariant_check.allowed = false, nil
  local ok, err = xpcall(func, debug.traceback)
  local unclaimed = {
    { errors = stubs.take_clock_errors(), what = "clock errors reported while the scheduler resumed a coroutine" },
    { errors = stubs.take_script_errors(),
      what = "errors the script caught and printed (context.take_script_errors() claims them)" },
  }
  for _, kind in ipairs(unclaimed) do
    if #kind.errors > 0 then
      local report = kind.what .. ":\n" .. table.concat(kind.errors, "\n")
      err = ok and report or (tostring(err) .. "\n" .. report)
      ok = false
    end
  end
  if ok and invariant_check.loaded and not invariant_check.allowed then
    local checked, broken = pcall(check_invariants)
    if not checked then
      ok, err = false, "invariant check failed: " .. tostring(broken)
    elseif #broken > 0 then
      ok, err = false, "invariants broken after the test:\n" .. table.concat(broken, "\n")
    end
  end
  invariant_check.loaded, invariant_check.allowed = outer_loaded, outer_allowed
  return ok, err
end

-- Claim the errors the script caught and printed in the current test
-- (context.take_script_errors, #473) and check them: exactly `count` lines,
-- each starting with `prefix` (such as "strata: frame failed: "), the last
-- holding `last_text` when given. Returns the lines
local function claim_script_errors(context, count, prefix, last_text)
  local claimed = context.take_script_errors()
  if #claimed ~= count then
    fail(string.format("%d printed errors expected, got %d:\n%s", count, #claimed, table.concat(claimed, "\n")), 2)
  end
  for _, line in ipairs(claimed) do
    if line:find(prefix, 1, true) ~= 1 then fail("a printed error starting '" .. prefix .. "' expected, got: " .. line, 2) end
  end
  if last_text and count > 0 and not claimed[count]:find(last_text, 1, true) then
    fail("the last printed error holds '" .. last_text .. "', got: " .. claimed[count], 2)
  end
  return claimed
end

-- Find a script value by name: a field of S (one it holds, or one ever
-- assigned, even to nil: S.__declared), then of S.constants, then a script
-- local, found by searching the upvalues of global functions. Returns the
-- value and a setter that writes where the name was found (every upvalue of
-- that name). A script local must have one value among all the upvalues of
-- its name: two different ones (two modules' own `local M`) raise an error
-- naming the functions, since which one pairs(_G) meets first changes from
-- run to run (#482).
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
  local found = {}
  for global_name, value in pairs(_G) do
    if type(value) == "function" then
      local index = 1
      while true do
        local upvalue_name, upvalue_value = debug.getupvalue(value, index)
        if not upvalue_name then break end
        if upvalue_name == name then
          table.insert(found, { holder = value, index = index, value = upvalue_value, global = tostring(global_name) })
          break
        end
        index = index + 1
      end
    end
  end
  if #found == 0 then error("script local '" .. name .. "' not found") end
  for _, entry in ipairs(found) do
    if entry.value ~= found[1].value then
      local holders = {}
      for _, other in ipairs(found) do table.insert(holders, other.global .. " (" .. tostring(other.value) .. ")") end
      table.sort(holders)
      error("script local '" .. name .. "' has different values in the upvalues of " .. table.concat(holders, ", "), 2)
    end
  end
  return found[1].value, function(new_value)
    for _, entry in ipairs(found) do debug.setupvalue(entry.holder, entry.index, new_value) end
  end
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

-- What 3.4's real step editor (the SEQ page's, S.lib.pages_seq) has open, as
-- "voice step port" ("3 5 1"), or nil while it is closed. The grid tests
-- run their held steps against the real editor (#630): its edits, its own
-- replacements (the euclid row) and a close from the screen (K2) are all
-- reached through its keys, encoders and grid holds
local function shown_step_editor()
  local editor = local_value("S").lib.pages_seq.step_editor()
  if editor == nil then return nil end
  return editor.voice .. " " .. editor.step .. " " .. editor.port
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

-- A file's bytes (binary mode), or nil when it cannot be opened
local function file_text(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("*a"); file:close()
  return text
end

-- Write `text` to path as it is (binary mode), replacing what it held
local function write_text(path, text)
  local file = assert(io.open(path, "wb")); file:write(text); file:close()
end

-- Wrap io.open to watch the data files' writes (#301): every name opened
-- for writing is recorded, and with `fail` ({at = "write" | "flush" |
-- "close", after = bytes}) a file whose name holds `part` (a plain find)
-- fails as a full card does: at "write", file:write returns nil and "No
-- space left on device" once `after` bytes are written (those bytes stay);
-- at "flush" or "close", that call returns nil and the message after the
-- bytes went out. Returns a function that puts io.open back, and the names
local function watch_writes(part, fail)
  local real_open, opened = io.open, {}
  io.open = function(name, mode)
    local file, problem = real_open(name, mode)
    if not file or not tostring(mode):find("w") then return file, problem end
    table.insert(opened, name)
    if fail == nil or not name:find(part, 1, true) then return file, problem end
    local written, proxy = 0, {}
    function proxy:write(text)
      if fail.at == "write" and written + #text > fail.after then
        file:write(text:sub(1, fail.after - written)); written = fail.after
        return nil, "No space left on device", 28
      end
      written = written + #text
      file:write(text)
      return self
    end
    function proxy:flush()
      if fail.at == "flush" then file:flush(); return nil, "No space left on device", 28 end
      return file:flush()
    end
    function proxy:close()
      if fail.at == "close" then file:close(); return nil, "No space left on device", 28 end
      return file:close()
    end
    function proxy:seek(...) return file:seek(...) end
    function proxy:read(...) return file:read(...) end
    return proxy
  end
  return function() io.open = real_open end, opened
end

-- The maintained docs (paths from the repo root): AGENTS.md, README.md,
-- ROADMAP.md, every .md file directly in docs/ (docs/status.md,
-- docs/checks.md, docs/workflow.md, docs/history.md and any added later)
-- and every .md file under docs/notes, docs/user and docs/decisions
-- (recursively). Their engine.<name>( mentions must name commands the
-- engine has, and the repo paths they name must exist. CHANGELOG.md and
-- docs/design/ are history: they describe a release as it was, so they are
-- not held to today's commands and files
local function maintained_docs()
  local docs = { "AGENTS.md", "README.md", "ROADMAP.md" }
  local prefix = repo_root .. "/"
  local found = {}
  for _, dir in ipairs({ "docs", "docs/notes", "docs/user", "docs/decisions" }) do
    local depth = dir == "docs" and "-maxdepth 1 " or ""
    local listing = io.popen('find "' .. prefix .. dir .. '" ' .. depth .. '-name "*.md" 2>/dev/null')
    for path in listing:read("*a"):gmatch("[^\n]+") do
      if path:sub(1, #prefix) == prefix then table.insert(found, path:sub(#prefix + 1)) end
    end
    listing:close()
  end
  table.sort(found)
  for _, path in ipairs(found) do table.insert(docs, path) end
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

-- The anchors GitHub gives a Markdown text's headings (outside code
-- fences): the heading lowercased, every character but letters, digits,
-- spaces, - and _ removed, each space a -; a repeated one gets -1, -2, ...
local function heading_anchors(text)
  local anchors, seen, fenced = {}, {}, false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fenced = not fenced
    elseif not fenced then
      local heading = line:match("^#+%s+(.-)%s*$")
      if heading then
        local anchor = heading:lower():gsub("[^%w _%-]", ""):gsub(" ", "-")
        anchors[seen[anchor] and (anchor .. "-" .. seen[anchor]) or anchor] = true
        seen[anchor] = (seen[anchor] or 0) + 1
      end
    end
  end
  return anchors
end

-- The repo paths a maintained doc's text names that do not exist, and the
-- number of paths it names: `docs/...`, `test/...`, `.github/...`, `lib/...`
-- and `changes/...` in backticks, the repo's root files in backticks (an
-- all-capitals .md name such as `README.md`, and `strata.lua`; a bare
-- lowercase name such as `voice.md` is a page's, not checked), and
-- relative Markdown link targets to a file, such as
-- [CHANGELOG.md](CHANGELOG.md) (not code such as `PAGE_KEY[ui_page](n)`).
-- A link with an #anchor names its file and the anchor must be one of the
-- file's headings (heading_anchors), reported as "file#anchor" when it is
-- not (#489). A norns library is named by its path in the norns repo
-- (`lua/lib/lfo.lua`), which is not checked. Link targets are relative to
-- the doc named by doc_name (a path from the repo root)
local function doc_paths_missing(text, doc_name)
  local doc_dir = doc_name and doc_name:match("^(.*)/[^/]*$") or ""
  local paths = {}
  for path in text:gmatch("`([%w%._/%-]+)`") do
    if path:match("^docs/") or path:match("^test/") or path:match("^%.github/") or path:match("^lib/")
        or path:match("^changes/") or path:match("^%u[%u%d_%-]*%.md$") or path == "strata.lua" then
      table.insert(paths, { path = path })
    end
  end
  for target, anchor in text:gmatch("%]%(([%w%._/%-]+%.%a+)#?([%w_%-]*)%)") do
    table.insert(paths, { path = target, link = true, anchor = anchor ~= "" and anchor or nil })
  end
  local missing = {}
  for _, entry in ipairs(paths) do
    local base = (entry.link and doc_dir ~= "") and (doc_dir .. "/") or ""
    local handle = io.open(repo_root .. "/" .. base .. entry.path, "r")
    local named = entry.path .. (entry.anchor and ("#" .. entry.anchor) or "")
    if not handle then
      table.insert(missing, named)
    else
      local target_text = entry.anchor and handle:read("*a")
      handle:close()
      if entry.anchor and not heading_anchors(target_text or "")[entry.anchor] then table.insert(missing, named) end
    end
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
-- helpers shared by several unit files
---------------------------------------------------------------------------

-- Run fn with one step of set_setting's save of performance.data failing:
-- kind "open" (the "w" open of the .part file returns nil), "write" (the
-- file's write fails; the file is closed for real) or "rename" (os.rename onto
-- performance.data fails). io.open and os.rename are put back on every exit,
-- and an error in fn is raised again
local function with_failing_setting_write(kind, fn)
  if kind ~= "open" and kind ~= "write" and kind ~= "rename" then
    error("with_failing_setting_write: kind is open, write or rename", 2)
  end
  local real_open, real_rename = io.open, os.rename
  local function is_part(path, mode)
    return mode == "w" and tostring(path):match("performance%.data%.part$") ~= nil
  end
  io.open = function(path, mode, ...)
    if not is_part(path, mode) then return real_open(path, mode, ...) end
    if kind == "open" then return nil, "refused" end
    local file = real_open(path, mode, ...)
    if kind ~= "write" or not file then return file end
    return { write = function() return nil end, close = function() return file:close() end }
  end
  if kind == "rename" then
    os.rename = function(from, to)
      if tostring(to):match("performance%.data$") then return nil, "refused" end
      return real_rename(from, to)
    end
  end
  local ok, err = pcall(fn)
  io.open, os.rename = real_open, real_rename
  if not ok then error(err, 0) end
end

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

local text_width = stubs.text_width

local function text_span(entry)
  local width = text_width(entry.text)
  if entry.align == "right" then return entry.x - width, entry.x end
  if entry.align == "center" then return entry.x - width / 2, entry.x + width / 2 end
  return entry.x, entry.x + width
end

-- The screen pages in E1 order (S.constants.UI_PAGES)
local PAGE_TITLES = { "MAIN", "VOICE", "SEQ", "FX", "LFO", "MOD", "BUFFER", "SCENES", "SETUP" }

local HINT_ROW_Y = 62

local TEXT_HEIGHT = 6   -- 04B_03 glyph height plus one row of spacing

-- MAIN: the voice list ends at x 60, left of the divider at 62; the selected
-- voice's details start at x 65
local MAIN_LIST_RIGHT = 60

local MAIN_DETAILS_LEFT = 65

-- Show a page by its name ("FX") or its index in PAGE_TITLES (E1 turns
-- there) and draw it. Tests name pages; an index is for loops over every page
local function show_page(page)
  local index = page
  if type(page) == "string" then
    index = nil
    for page_index, title in ipairs(PAGE_TITLES) do
      if title == page then index = page_index end
    end
    assert(index, "no page named " .. page)
  end
  enc(1, index - local_value("ui_page"))
  redraw()
end

-- The drawn strings on row y, left to right
local function texts_on_row(context, y)
  local row = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == y then table.insert(row, entry) end
  end
  table.sort(row, function(a, b) return select(1, text_span(a)) < select(1, text_span(b)) end)
  return row
end

-- The text drawn at the start of the hint row (nil when there is none)
local function hint_text(context)
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == HINT_ROW_Y then return entry.text end
  end
end

-- The header's page dots (lib/ui/header.lua): one 2x2 rect per page (nine
-- since 3.4) from x 36, 4 px apart
local HEADER_DOTS_X, HEADER_DOT_SPACING, HEADER_DOT_SIZE = 36, 4, 2

local HEADER_FLASH_X = 40

-- rows between one baseline and the next that clear a descender
local DESCENDER_CLEARANCE = 7

-- Check the drawn screen: everything inside 128x64, no two strings overlap on
-- a row, the page title at 0,8, then either the nine page dots (at least
-- 4 px after the title) or, while a header flash shows, its text at 40,8
-- and no dots; no header rect (dot, play mark) under a header string; and a
-- hint row at y 62.
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
  -- the norns font draws 2 px below the baseline for g, j, p, q and y: a
  -- string under one with a descender must start 7 px or more below it, or
  -- the descender's last pixel meets the next line (#422)
  for _, upper in ipairs(context.screen.texts) do
    if upper.text:find("[gjpqy]") then
      local upper_left, upper_right = text_span(upper)
      for _, lower in ipairs(context.screen.texts) do
        local gap = lower.y - upper.y
        if gap > 0 and gap < DESCENDER_CLEARANCE then
          local lower_left, lower_right = text_span(lower)
          assert_true(lower_right <= upper_left or lower_left >= upper_right,
            string.format("'%s' at y %d is %d px above '%s' and its descender meets it (%s)",
              upper.text, upper.y, gap, lower.text, where))
        end
      end
    end
  end
  local title = PAGE_TITLES[local_value("ui_page")]
  local title_right, flash_drawn, hint_found
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == title and entry.x == 0 and entry.y == 8 then title_right = select(2, text_span(entry)) end
    if entry.x == HEADER_FLASH_X and entry.y == 8 then flash_drawn = true end
    if entry.x == 0 and entry.y == HINT_ROW_Y then hint_found = true end
  end
  assert_true(title_right, "page title " .. title .. " drawn at 0,8 (" .. where .. ")")
  -- the header band: rects above y 9
  local dots = {}
  for _, rect in ipairs(context.screen.rects) do
    if rect.y + rect.h <= 9 then
      for _, text in ipairs(rows[8] or {}) do
        assert_true(rect.x + rect.w <= text.left or rect.x >= text.right,
          string.format("a header rect at x %d-%d is under '%s' (%s)", rect.x, rect.x + rect.w - 1, text.text, where))
      end
      if rect.w == HEADER_DOT_SIZE and rect.h == HEADER_DOT_SIZE then table.insert(dots, rect) end
    end
  end
  local flash = local_value("S").lib.ui_flash.text("header")
  if flash then
    assert_true(flash_drawn, "the header flash drawn at " .. HEADER_FLASH_X .. ",8 (" .. where .. ")")
    assert_equal(#dots, 0, "no page dots under the header flash (" .. where .. ")")
  else
    assert_equal(#dots, #PAGE_TITLES, "a page dot per page (" .. where .. ")")
    table.sort(dots, function(a, b) return a.x < b.x end)
    for index, dot in ipairs(dots) do
      assert_equal(dot.x, HEADER_DOTS_X + (index - 1) * HEADER_DOT_SPACING, "page dot " .. index .. " (" .. where .. ")")
    end
    assert_true(dots[1].x - title_right >= 4, "the page dots start at least 4 px after " .. title .. " (" .. where .. ")")
  end
  assert_true(hint_found, "hint row at y " .. HINT_ROW_Y .. " (" .. where .. ")")
end

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

local FX_PARAM_IDS = { "filter_type", "filter_freq", "filter_res", "filter_mix",
  "delay_time", "delay_feedback", "delay_mix", "reverb_mix", "reverb_size", "reverb_damp", "drift_amount" }

-- Press and release a norns key
local function tap(n) key(n, 1); key(n, 0) end

---------------------------------------------------------------------------
-- unit files
---------------------------------------------------------------------------

-- The unit files in `dir`: every *_test.lua or, with a filter, those whose
-- name contains it (plain text, not a pattern), sorted by name
local function unit_files(dir, filter)
  local names = {}
  local listing = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
  for name in listing:read("*a"):gmatch("[^\n]+") do
    if name:match("_test%.lua$") and (not filter or name:find(filter, 1, true)) then
      table.insert(names, name)
    end
  end
  listing:close()
  table.sort(names)
  return names
end

-- Load each unit file unit_files(dir, filter) lists, in order. A unit file
-- returns function(h), which registers its tests with h.test. Returns the
-- names loaded. A file that returns no function, or whose function
-- registers no test, is an error naming it (#484): a test file emptied or
-- all behind a condition never passes as 0 tests
local function load_unit_files(dir, filter, helpers)
  local names = unit_files(dir, filter)
  for _, name in ipairs(names) do
    local chunk = assert(loadfile(dir .. "/" .. name))
    local register = chunk()
    if type(register) ~= "function" then error(name .. " returns no function(h)", 0) end
    local registered = 0
    register(setmetatable({ test = function(...)
      registered = registered + 1
      return helpers.test(...)
    end }, { __index = helpers }))
    if registered == 0 then error(name .. " registered no test", 0) end
  end
  return names
end

return {
  test_dir = test_dir,
  repo_root = repo_root,
  stubs = stubs,
  sync_check = sync_check,
  real_print = real_print,
  harness_globals = harness_globals,
  engine_sources = engine_sources,
  LUA_PATH = LUA_PATH,
  signatures = signatures,
  engine_polls = engine_polls,
  engine_spec = engine_spec,
  data_root = data_root,
  shell_quote = shell_quote,
  remove_tree = remove_tree,
  tests = tests,
  test = test,
  fail = fail,
  run_test = run_test,
  claim_script_errors = claim_script_errors,
  check_invariants = check_invariants,
  allow_broken_invariants = allow_broken_invariants,
  with_failing_setting_write = with_failing_setting_write,
  assert_true = assert_true,
  assert_equal = assert_equal,
  assert_near = assert_near,
  load_strata = load_strata,
  write_performance_active = write_performance_active,
  shared_state = shared_state,
  find_upvalue = find_upvalue,
  local_value = local_value,
  next_frame = next_frame,
  finish_startup = finish_startup,
  wake = wake,
  wake_buffer_clock = wake_buffer_clock,
  shown_step_editor = shown_step_editor,
  deep_copy = deep_copy,
  tabutil_text = tabutil_text,
  file_text = file_text,
  write_text = write_text,
  watch_writes = watch_writes,
  maintained_docs = maintained_docs,
  read_lua_sources = read_lua_sources,
  patched_script = patched_script,
  doc_paths_missing = doc_paths_missing,
  assert_voice_matches = assert_voice_matches,
  scramble_state = scramble_state,
  engine_state_for_voice = engine_state_for_voice,
  text_width = text_width,
  text_span = text_span,
  PAGE_TITLES = PAGE_TITLES,
  HINT_ROW_Y = HINT_ROW_Y,
  TEXT_HEIGHT = TEXT_HEIGHT,
  MAIN_LIST_RIGHT = MAIN_LIST_RIGHT,
  MAIN_DETAILS_LEFT = MAIN_DETAILS_LEFT,
  show_page = show_page,
  texts_on_row = texts_on_row,
  hint_text = hint_text,
  assert_screen_layout = assert_screen_layout,
  count_screen_draws = count_screen_draws,
  screen_shows = screen_shows,
  assert_drawn_on_next_frame = assert_drawn_on_next_frame,
  FX_PARAM_IDS = FX_PARAM_IDS,
  tap = tap,
  unit_files = unit_files,
  load_unit_files = load_unit_files,
}

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
-- would draw the same name.
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
-- helpers shared by several unit files
---------------------------------------------------------------------------

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
-- names loaded
local function load_unit_files(dir, filter, helpers)
  local names = unit_files(dir, filter)
  for _, name in ipairs(names) do
    local chunk = assert(loadfile(dir .. "/" .. name))
    chunk()(helpers)
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
  SC_PATH = SC_PATH,
  LUA_PATH = LUA_PATH,
  signatures = signatures,
  engine_polls = engine_polls,
  engine_spec = engine_spec,
  data_root = data_root,
  tests = tests,
  test = test,
  fail = fail,
  run_test = run_test,
  assert_true = assert_true,
  assert_equal = assert_equal,
  assert_near = assert_near,
  load_strata = load_strata,
  shared_state = shared_state,
  find_upvalue = find_upvalue,
  local_value = local_value,
  next_frame = next_frame,
  finish_startup = finish_startup,
  wake = wake,
  wake_buffer_clock = wake_buffer_clock,
  deep_copy = deep_copy,
  tabutil_text = tabutil_text,
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
  assert_screen_layout = assert_screen_layout,
  count_screen_draws = count_screen_draws,
  screen_shows = screen_shows,
  assert_drawn_on_next_frame = assert_drawn_on_next_frame,
  FX_PARAM_IDS = FX_PARAM_IDS,
  tap = tap,
  unit_files = unit_files,
  load_unit_files = load_unit_files,
}

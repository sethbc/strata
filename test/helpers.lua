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

-- A process of a parallel run (test/run.lua) gets its folder from the run,
-- inside the run's own (STRATA_TEST_DATA_ROOT, "<run's folder>workers/<file>/",
-- beside the run's worker.sh), so the run removes it however the process
-- ends; any other value is refused. Every other run makes a fresh one
local given_root = os.getenv("STRATA_TEST_DATA_ROOT")
local data_root
if given_root and given_root ~= "" then
  local workers = given_root:match("^(/.+/workers/)[%w_%-%.]+/$")
  local script = workers and io.open(workers .. "worker.sh", "r")
  if not script then error("STRATA_TEST_DATA_ROOT is not a folder a parallel run gave: " .. given_root, 0) end
  script:close()
  data_root = given_root:sub(1, -2)
else
  data_root = os.tmpname()
  os.remove(data_root)
end
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
-- would draw the same name. options.script_dir (3.8) names the script's
-- folder (norns.state.path, context.script_dir; a factory test's copy of
-- its fixture), else it is the load's own empty <data_dir>script/.
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
    data_dir = data_dir, quiet = true, module_sources = options.module_sources, script_dir = options.script_dir }
  context.data_dir = data_dir
  context.audio_dir = data_dir .. "audio/"
  context.script_dir = norns.state.path  -- the script's folder (3.8: options.script_dir, else an empty one)
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

-- One registered invariant of the script loaded last, for a test that
-- breaks it on purpose: {check = its function (nil while it holds),
-- upvalue(name) (the value of its function's upvalue of that name: the
-- owning module's own locals), set(name, value)}. Raises naming the
-- invariant, or the upvalue, when there is none
local function registered_invariant(name)
  local S = shared_state()
  local registry = type(S) == "table" and type(S.registry) == "table" and S.registry.invariants or {}
  for _, record in ipairs(registry) do
    if record.name == name then
      local fn = record.fn
      local function index_of(wanted)
        for index = 1, math.huge do
          local found = debug.getupvalue(fn, index)
          if found == nil then break end
          if found == wanted then return index end
        end
        error("the invariant " .. name .. " has no upvalue " .. tostring(wanted), 3)
      end
      return {check = fn,
        upvalue = function(wanted) return (select(2, debug.getupvalue(fn, index_of(wanted)))) end,
        set = function(wanted, value) debug.setupvalue(fn, index_of(wanted), value) end}
    end
  end
  error("no invariant " .. tostring(name), 2)
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

-- 3.8's pane harness (lib/grid/pane.lua, design §10.1): the six places a
-- page can be shown, each a layout and the pane and half it shows. A test
-- loops over GRID_ARRANGEMENTS (or those that show the keys it needs) and
-- names keys in pane coordinates only: x 1-16 along a line, y 1-7 the
-- lines, y 8 the pane's strip (x its key, 1-16, or 1-8 on a 64)
local GRID_ARRANGEMENTS = {"128h", "256 top", "256 bottom", "128v", "64 left", "64 right"}
local GRID_ARRANGEMENT = {
  ["128h"] = {layout = "128h", cols = 16, rows = 8, pane = 1, half = 1},
  ["256 top"] = {layout = "256", cols = 16, rows = 16, pane = 1, half = 1},
  ["256 bottom"] = {layout = "256", cols = 16, rows = 16, pane = 2, half = 1},
  ["128v"] = {layout = "128v", cols = 8, rows = 16, pane = 1, half = 1},
  ["64 left"] = {layout = "64", cols = 8, rows = 8, pane = 1, half = 1},
  ["64 right"] = {layout = "64", cols = 8, rows = 8, pane = 1, half = 2},
}

-- A grid of the arrangement's size on opts.port (1 unless given; a grid of
-- that size already there is used, so "256 top" and "256 bottom" can share
-- one), its pane on the arrangement's half. Returns {port, device, pane,
-- arrangement, show(page, side, half), press(x, y, z), tap(x, y), led(x,
-- y), shows(x, y)}: led is nil for a key the arrangement does not show,
-- and press raises for one. Each key goes through the layout's own spec
-- (S.lib.grid_pane.physical), so no test writes a physical key
local function grid_pane(context, arrangement, opts)
  opts = opts or {}
  local info = GRID_ARRANGEMENT[arrangement]
  if info == nil then error("grid_pane: no arrangement " .. tostring(arrangement), 2) end
  local port = opts.port or 1
  local S = local_value("S")
  local core = S.lib.grid_core
  local device = context.grid.vports[port].device
  if not (device and device.cols == info.cols and device.rows == info.rows) then
    device = context.grid.plug(port, info.cols, info.rows)
  end
  local layout = S.registry.grid_layouts[info.layout]
  if info.half ~= 1 then core.set_half(port, info.pane, info.half); grid_redraw() end
  local function physical(x, y)
    return S.lib.grid_pane.physical(layout, info.pane, x, y, core.half(port, info.pane))
  end
  local handle = {port = port, device = device, pane = info.pane, arrangement = arrangement}
  -- raises unless the pane then shows that page, side and half (a side the
  -- page has not is refused by set_page, so a test never runs on another)
  function handle.show(page, side, half)
    side, half = side or 1, half or info.half
    core.set_page(port, page, info.pane, side)
    core.set_half(port, info.pane, half)
    local wanted = info.pane .. ":" .. page .. ":" .. side .. ":" .. half
    if core.view(port, info.pane) ~= wanted then
      error(arrangement .. " shows " .. core.view(port, info.pane) .. ", not " .. wanted, 2)
    end
    grid_redraw()
  end
  function handle.press(x, y, z)
    local px, py = physical(x, y)
    if px == nil then error(arrangement .. " shows no key " .. x .. "," .. y, 2) end
    context.grid.press(port, px, py, z)
  end
  -- a press and the release of the same physical key (a press may change
  -- the half shown)
  function handle.tap(x, y)
    local px, py = physical(x, y)
    if px == nil then error(arrangement .. " shows no key " .. x .. "," .. y, 2) end
    context.grid.press(port, px, py, 1); context.grid.press(port, px, py, 0)
  end
  function handle.led(x, y)
    local px, py = physical(x, y)
    if px == nil then return nil end
    return device:get_led(px, py)
  end
  function handle.shows(x, y) return physical(x, y) ~= nil end
  return handle
end

-- A probe page in S.registry.grid_pages[index] of the test's own S, so a
-- test of sides, fader lines or holds leans on no page main has: its name
-- the index's, opts.sides (1 or 2), opts.faders (a list of fader lines, or
-- fn(pane) -> one), opts.signature (fn(pane) -> string), opts.redraw ("all"
-- lights every key of the pane at 15; a function is the redraw itself).
-- Its press records each call in probe.presses ({pane, x, y, z, side});
-- with opts.hold (seconds) a press arms pane.on_hold, whose firing is
-- recorded in probe.fired ({pane, x, y, side}). Returns the record
local function probe_grid_page(index, opts)
  opts = opts or {}
  local S = local_value("S")
  local probe = {name = S.constants.GRID_PAGES.names[index], index = index, sides = opts.sides,
    signature = opts.signature}
  probe.presses, probe.fired = {}, {}
  if type(opts.faders) == "function" then
    probe.faders = opts.faders
  elseif opts.faders then
    probe.faders = function() return opts.faders end
  end
  probe.press = function(pane, x, y, z)
    probe.presses[#probe.presses + 1] = {pane = pane.index, x = x, y = y, z = z, side = pane.side}
    if opts.hold and z == 1 then
      local side = pane.side
      pane.on_hold(x, y, opts.hold, function()
        probe.fired[#probe.fired + 1] = {pane = pane.index, x = x, y = y, side = side}
      end)
    end
  end
  if type(opts.redraw) == "function" then
    probe.redraw = opts.redraw
  elseif opts.redraw == "all" then
    probe.redraw = function(_, led)
      for x = 1, 16 do
        for y = 1, S.constants.NUM_VOICES do led(x, y, 15) end
      end
    end
  else
    probe.redraw = function() end
  end
  S.registry.grid_pages[index] = probe
  return probe
end

-- No record at the page's index in the test's own S (a page main may have)
local function no_grid_page(index)
  local_value("S").registry.grid_pages[index] = nil
end

-- Turn the grid plugged on a port so it reports cols x rows (the stub's
-- rotation: a quarter turn swaps them), as a rotation made outside Strata
-- would, then redraw (the next redraw follows a size change)
local function resize_grid(context, port, cols, rows)
  local device = context.grid.vports[port].device
  if device == nil then error("resize_grid: no grid on port " .. port, 2) end
  if cols == device.native_cols and rows == device.native_rows then
    device:rotation(0)
  elseif cols == device.native_rows and rows == device.native_cols then
    device:rotation(1)
  else
    error("resize_grid: a " .. device.native_cols .. "x" .. device.native_rows .. " grid never reports "
      .. cols .. "x" .. rows, 2)
  end
  grid_redraw()
end

-- The slice editor's (lib/ui/slice_editor.lua, design §3.7) on top: a
-- slot with audio (S.buffers[slot].seconds above 0) has a settings record
-- (doubles.store[slot], made at its first read: off, count 8, sensitivity
-- 50); its frames are its seconds at 48 kHz; its slices are
-- doubles.markers[slot] (count reads them); doubles.analyzing[slot] and
-- doubles.playing[voice] are what analyzing and playing report (playing
-- adds the sounding keys'); doubles.gain, when set, is a normalized slot's
-- gain; doubles.log lists the edits made, doubles.made the makes, and
-- doubles.bind(slot) tells the on_bind listeners, as 2d's store does
local function slice_editor_doubles(S, doubles)
  doubles.store, doubles.markers, doubles.analyzing, doubles.playing = {}, {}, {}, {}
  doubles.log, doubles.made = {}, 0
  local slices, samples, waveforms = S.lib.slices, S.lib.samples, S.lib.waveforms
  local function seconds(slot) return S.buffers[slot] and S.buffers[slot].seconds or 0 end
  local function frames(slot) return seconds(slot) > 0 and math.floor(seconds(slot) * 48000 + 0.5) or nil end
  local function log(text) table.insert(doubles.log, text) end
  local function copy(list)
    if not list then return nil end
    local out = {}
    for index, value in ipairs(list) do out[index] = value end
    return out
  end
  function samples.settings(slot)
    if seconds(slot) <= 0 then return nil end
    doubles.store[slot] = doubles.store[slot]
      or {mode = 1, count = 8, sensitivity = 50, normalize = false, edited = false}
    return doubles.store[slot]
  end
  local function edited(slot) samples.settings(slot).edited = true end
  function slices.count(slot) return doubles.markers[slot] and #doubles.markers[slot] or 0 end
  function slices.markers(slot) return copy(doubles.markers[slot]) end
  function slices.add_marker(slot, frame)
    log("add " .. slot .. " " .. frame)
    local list = doubles.markers[slot] or {0}
    if #list >= slices.SLICES.max then return false end
    table.insert(list, frame); table.sort(list)
    doubles.markers[slot] = list
    edited(slot)
    return true
  end
  function slices.delete_marker(slot, index)
    log("delete " .. slot .. " " .. index)
    if index <= 1 then return false end
    table.remove(doubles.markers[slot], index)
    edited(slot)
    return true
  end
  function slices.nudge_marker(slot, index, by)
    log("nudge " .. slot .. " " .. index .. " " .. by)
    doubles.markers[slot][index] = doubles.markers[slot][index] + by
    edited(slot)
    return true
  end
  function slices.make(slot)
    doubles.made = doubles.made + 1
    local record = samples.settings(slot)
    record.edited = false
    if record.mode == 2 then
      local list, total = {}, frames(slot)
      for k = 1, record.count do list[k] = math.floor((k - 1) * total / record.count) end
      doubles.markers[slot] = list
    elseif record.mode == 3 then
      doubles.analyzing[slot] = true
    else
      doubles.markers[slot] = nil
    end
  end
  function slices.analyzing(slot) return doubles.analyzing[slot] == true end
  function samples.set(slot, field, value)
    log("set " .. slot .. " " .. field .. " " .. tostring(value))
    samples.settings(slot)[field] = value
  end
  function samples.bars(slot)
    local tempo = samples.settings(slot).tempo
    return tempo and seconds(slot) * tempo / 240 or nil
  end
  function samples.set_bars(slot, bars)
    local tempo = bars * 240 / seconds(slot)
    if tempo < samples.SAMPLES.tempo_min or tempo > samples.SAMPLES.tempo_max then return false end
    samples.settings(slot).tempo = tempo
    return true
  end
  -- doubles.gain, else min(16, 1 / the largest peak), as 2d works it out
  function samples.gain(slot)
    local record = samples.settings(slot)
    if not (record and record.normalize) then return 1 end
    if doubles.gain then return doubles.gain end
    local peak = 0
    for _, value in ipairs(waveforms.peaks(slot) or {}) do peak = math.max(peak, value) end
    return (peak > 0 and peak < 1) and math.min(samples.SAMPLES.max_gain, 1 / peak) or 1
  end
  waveforms.frames = frames
  function waveforms.rate(slot) return frames(slot) and 48000 or nil end
  function doubles.bind(slot) for _, fn in ipairs(doubles.binds) do fn(slot) end end
end

-- 3.7's slice rows (lib/positions.lua, design §10): doubles for the three
-- modules the rows consume, with exactly the functions they use, set as
-- fields of each module's table after startup (so they replace the real
-- ones too, and the real modules' start steps run unharmed): S.lib.slices
-- (takes_notes, count, play, note_off, playing), S.lib.scan (pass_seconds)
-- and S.lib.samples (on_bind). Voice v takes notes while takes[v] is set
-- and it reads a buffer whose slot holds counts[slot] slices; plays are
-- {voice, n, note}, offs {voice, owner, key}; a played slice sounds
-- (sounding[key]) until its key's note_off, or, while `pass` is a number
-- (one shot with a moving scan), until the test ends it; binds holds each
-- on_bind listener. options.editor adds the slice editor's doubles
-- (slice_editor_doubles, above), whose count reads the markers: with it
-- `counts` must be nil (it would be ignored)
local function slice_doubles(S, counts, options)
  assert(not (options and options.editor) or counts == nil, "slice_doubles: the editor's count reads markers, not counts")
  local doubles = {counts = counts or {}, takes = {}, plays = {}, offs = {}, sounding = {}, pass = nil, binds = {}}
  local slices = S.lib.slices
  function slices.count(slot) return doubles.counts[slot] or 0 end
  function slices.takes_notes(voice_idx)
    return doubles.takes[voice_idx] == true and voice_uses_buffer(voice_idx) and slices.count(voice_buffer_slot(voice_idx)) > 0
  end
  function slices.play(voice_idx, n, note)
    table.insert(doubles.plays, {voice = voice_idx, n = n, note = note})
    if n > slices.count(voice_buffer_slot(voice_idx)) then return false end
    doubles.sounding[note.key] = {voice = voice_idx, n = n}
    return 1
  end
  function slices.note_off(voice_idx, owner, key)
    table.insert(doubles.offs, {voice = voice_idx, owner = owner, key = key})
    if doubles.pass == nil then doubles.sounding[key] = nil end
  end
  function slices.playing(voice_idx)
    local list = {}
    for _, sounding in pairs(doubles.sounding) do
      if sounding.voice == voice_idx then list[#list + 1] = sounding.n end
    end
    if doubles.playing and doubles.playing[voice_idx] then
      for _, n in ipairs(doubles.playing[voice_idx]) do list[#list + 1] = n end
    end
    table.sort(list)
    return list
  end
  function S.lib.scan.pass_seconds(_, fraction) return doubles.pass and fraction * doubles.pass or nil end
  function S.lib.samples.on_bind(fn) table.insert(doubles.binds, fn) end
  if options and options.editor then slice_editor_doubles(S, doubles) end
  return doubles
end

-- Deep copy of plain data tables
local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, inner in pairs(value) do copy[key] = deep_copy(inner) end
  return copy
end

-- The comparisons with 3.7.0's fixtures (3.8's package 0g): an allowed
-- difference's text may name a voice by the tokens <v> (its number, 1 to
-- NUM_VOICES) and <v0> (its engine index, 0 to NUM_VOICES - 1).
-- voice_count() is lib/constants.lua's NUM_VOICES, read without a load
local voice_count_read
local function voice_count()
  voice_count_read = voice_count_read or dofile(repo_root .. "/lib/constants.lua").NUM_VOICES
  return voice_count_read
end
local function has_voice_token(text)
  return type(text) == "string" and (text:find("<v>", 1, true) or text:find("<v0>", 1, true)) ~= nil
end
local function fill_voice_tokens(text, voice)
  if type(text) ~= "string" then return text end
  return (text:gsub("<v0>", tostring(voice - 1)):gsub("<v>", tostring(voice)))
end
-- A copy of entry with its fields' tokens filled for voice
local function voice_entry(entry, fields, voice)
  local copy = {}
  for key, value in pairs(entry) do copy[key] = value end
  for _, field in ipairs(fields) do copy[field] = fill_voice_tokens(entry[field], voice) end
  return copy
end
-- The entries an allowed difference stands for: itself when none of its
-- fields (a list of keys) holds a token, otherwise one copy a voice, in
-- voice order, each filled and carrying its `voice`
local function voice_entries(entry, fields)
  local tokened = false
  for _, field in ipairs(fields) do tokened = tokened or has_voice_token(entry[field]) end
  if not tokened then return {entry} end
  local entries = {}
  for voice = 1, voice_count() do
    entries[voice] = voice_entry(entry, fields, voice)
    entries[voice].voice = voice
  end
  return entries
end

-- A recorded engine call ({name, args}, context.engine_calls') as the
-- start-call fixtures write it: name(args), numbers "%.9g", strings "%q"
local function call_line(call)
  local parts = {}
  for index = 1, #call.args do
    local value = call.args[index]
    parts[index] = type(value) == "number" and string.format("%.9g", value) or string.format("%q", tostring(value))
  end
  return call.name .. "(" .. table.concat(parts, ", ") .. ")"
end

-- A copy of call lines with each run of consecutive setVoiceParam lines of
-- one voice sorted (3.6.0 sent such a run in a pairs() order that changed
-- from run to run; 3.8.0 sends it sorted); nothing else moves
local function canonical_call_lines(lines)
  local out, run, run_key = {}, {}, nil
  local function flush()
    table.sort(run)
    for _, line in ipairs(run) do out[#out + 1] = line end
    run, run_key = {}, nil
  end
  for _, line in ipairs(lines) do
    local key = line:match("^(setVoiceParam%(%d+),")
    if key and key == run_key then
      run[#run + 1] = line
    else
      flush()
      if key then run_key, run[1] = key, line else out[#out + 1] = line end
    end
  end
  flush()
  return out
end

-- The fixture's and the build's call lines (`name(args)`, as the start-call
-- fixtures write them) with the allowed differences applied: copies, the
-- lines given left alone. Each entry, in order, is
--   {kind = "drop", side = "build" | "fixture" (default "build"),
--     match = <Lua pattern over a whole line>, count = <n>, why = <text>}:
--     every line of that side the pattern matches is removed (count 0
--     asserts no line matches: a message never sent); or
--   {kind = "rewrite", match = <pattern>, replace = <gsub replacement>,
--     count = <n>, why = <text>}: every matching build line is rewritten
--     into the old form (a changed value, a wider signature),
-- and raises unless exactly count lines matched. With voice (a start's
-- voice number), <v> and <v0> in match and replace are filled from it;
-- without (a whole run), an entry holding a token stands for one entry a
-- voice, each matched on its own and count per voice, a miss naming the
-- voice. label names the comparison in an error. An entry of no such kind
-- or side, with no why, match or whole count, or a rewrite with no replace
-- or of the fixture, raises.
-- The anchor rule: match is anchored to the whole line, or the entry raises
-- naming its why (unanchored, '"scanMode", 0' would also match a
-- "scanMode", 0.5 line). It starts with ^, and, when `whole` (a count above
-- 0), ends with a $ that no odd run of % escapes (%$ is a dollar sign; %%$
-- a percent sign, then the anchor); for count 0 a prefix such as
-- '^noteRegion%(' is enough. It is read on the entry's own text: a token
-- fills digits, so it neither makes nor breaks an anchor, and a $ before a
-- token is not last, so is a dollar sign
local function pattern_anchored(match, whole)
  if match:sub(1, 1) ~= "^" then return false end
  if not whole then return true end
  local escapes = #(match:match("(%%*)%$$") or "")
  return match:sub(-1) == "$" and escapes % 2 == 0
end
local CALL_TOKEN_FIELDS = {"match", "replace"}
local CALL_SIDES = {build = true, fixture = true}
local function allowed_call_lines(fixture_lines, build_lines, entries, label, voice)
  local sides = {fixture = {}, build = {}}
  for index, line in ipairs(fixture_lines) do sides.fixture[index] = line end
  for index, line in ipairs(build_lines) do sides.build[index] = line end
  for index, entry in ipairs(entries) do
    local where = tostring(label) .. ": allowed call " .. index .. " (" .. tostring(entry.match) .. ")"
    if type(entry.why) ~= "string" or entry.why == "" then error(where .. " says no why", 2) end
    if entry.kind ~= "drop" and entry.kind ~= "rewrite" then error(where .. ": no kind " .. tostring(entry.kind), 2) end
    if type(entry.match) ~= "string" then error(where .. ": no match", 2) end
    local count = entry.count
    if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
      error(where .. ": count " .. tostring(count) .. " is no whole number", 2)
    end
    if not pattern_anchored(entry.match, count > 0) then
      error(where .. " (" .. entry.why .. "): match is not anchored: it starts with ^"
        .. (count > 0 and ", and ends with an unescaped $ when count is above 0" or ""), 2)
    end
    local side = entry.side or "build"
    if not CALL_SIDES[side] then error(where .. ": no side " .. tostring(side), 2) end
    if entry.kind == "rewrite" then
      if side ~= "build" then error(where .. ": a rewrite rewrites build lines", 2) end
      if type(entry.replace) ~= "string" then error(where .. ": a rewrite with no replace", 2) end
    end
    local applied = voice and {voice_entry(entry, CALL_TOKEN_FIELDS, voice)} or voice_entries(entry, CALL_TOKEN_FIELDS)
    for _, one in ipairs(applied) do
      local kept, matched = {}, 0
      for _, line in ipairs(sides[side]) do
        if line:match(one.match) then
          matched = matched + 1
          if one.kind == "rewrite" then kept[#kept + 1] = (line:gsub(one.match, one.replace, 1)) end
        else
          kept[#kept + 1] = line
        end
      end
      sides[side] = kept
      if matched ~= count then
        error(where .. (one.voice and (", voice " .. one.voice) or "") .. ": " .. matched .. " " .. side
          .. " lines matched, count " .. count, 2)
      end
    end
  end
  return sides.fixture, sides.build
end

---------------------------------------------------------------------------
-- State machines (3.9's package 0a, its design's section 2): a transition
-- table run as tests, the table a notes file holds, and seeded walks. How to
-- use them: docs/notes/test-harness/run-and-helpers.md (State machines)
---------------------------------------------------------------------------

-- A cell of a table, as its tests and messages name it: "<state> + <event>"
local function cell_name(state, event) return tostring(state) .. " + " .. tostring(event) end

-- The cells of a Markdown table row, trimmed, backticks stripped; an escaped
-- pipe (\|) stays in its cell
local ESCAPED_PIPE = "\1"
local function table_cells(line)
  local body = line:gsub("\\|", ESCAPED_PIPE):match("^%s*|(.*)$")
  body = body:gsub("|%s*$", "")
  local cells = {}
  for cell in (body .. "|"):gmatch("([^|]*)|") do
    cells[#cells + 1] = (cell:gsub(ESCAPED_PIPE, "|"):gsub("`", ""):match("^%s*(.-)%s*$"))
  end
  return cells
end

-- The rows {state, event, next} of the first table under the heading
-- `### <machine>` of a notes file (a path from the repository's root, or
-- absolute), from its columns State, Event and Next wherever they stand,
-- backticks stripped. Headings and tables inside code fences do not count;
-- the table must come before the section's next heading. Raises on a file it
-- cannot read, no such heading, no table under it, or a column missing
local function notes_table(path, machine)
  local full = path:sub(1, 1) == "/" and path or (repo_root .. "/" .. path)
  local file = io.open(full, "r")
  if not file then error("notes_table: cannot read " .. path, 2) end
  local text = file:read("*a")
  file:close()
  local heading, found, fenced, header, columns, rows = "### " .. machine, false, false, nil, nil, nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fenced = not fenced
      if header then break end
    elseif not fenced then
      if line:match("^#+%s") then
        if found then break end
        found = line:gsub("%s+$", "") == heading
      elseif found and line:match("^%s*|") then
        local cells = table_cells(line)
        if not header then
          header, columns = cells, {}
          for index, name in ipairs(cells) do columns[name] = columns[name] or index end
        elseif not rows then
          if not line:match("^[%s|:%-]+$") then
            error("notes_table: the table under " .. path .. ", ### " .. machine .. " has no |---| row after its header", 2)
          end
          rows = {}  -- the separator row, |---|
        else
          local row = {cells[columns.State], cells[columns.Event], cells[columns.Next]}
          for position, column in ipairs({"State", "Event", "Next"}) do
            if row[position] == nil then
              error("notes_table: a row under " .. path .. ", ### " .. machine .. " has no " .. column .. " cell: "
                .. line, 2)
            end
          end
          rows[#rows + 1] = row
        end
      elseif header then
        break
      end
    end
  end
  local where = path .. ", ### " .. machine
  if not found then error("notes_table: no heading ### " .. machine .. " in " .. path, 2) end
  if not header then error("notes_table: no table under " .. where, 2) end
  for _, name in ipairs({"State", "Event", "Next"}) do
    if not columns[name] then error("notes_table: the table under " .. where .. " has no column " .. name, 2) end
  end
  return rows or {}
end

-- Where a known row's line goes when its test passes: printed, or, inside
-- with_known_lines, kept in its list
local known_lines_taken

-- Run fn with the known rows' lines kept instead of printed (a self-test's
-- own rows name no real issue): the lines, in order. Put back on every exit,
-- and an error in fn is raised again
local function with_known_lines(fn)
  local outer, taken = known_lines_taken, {}
  known_lines_taken = taken
  local ok, err = pcall(fn)
  known_lines_taken = outer
  if not ok then error(err, 0) end
  return taken
end

local function whole_positive(value) return type(value) == "number" and value >= 1 and value == math.floor(value) end

-- Run a state machine's table as tests (see the notes for the spec's
-- fields): one test a row, `<name>: <state> + <event>`; `<name>: every cell
-- is decided`; and, with spec.notes = {path, machine}, `<name>: the notes'
-- table equals these rows`. Returns {known = {"<name>: <state> + <event> ->
-- <next> (known #<issue>)", ...}}, the rows that assert a fault of an open
-- issue; each prints its line when its test passes
local function transition_table(spec)
  if type(spec) ~= "table" or type(spec.name) ~= "string" or spec.name == "" then
    error("transition_table: spec.name is a non-empty string", 2)
  end
  local name = spec.name
  for _, field in ipairs({"states", "events", "rows"}) do
    if type(spec[field]) ~= "table" then error("transition_table " .. name .. ": spec." .. field .. " is a table", 2) end
  end
  if type(spec.state_of) ~= "function" then error("transition_table " .. name .. ": spec.state_of is a function", 2) end
  if spec.impossible ~= nil and type(spec.impossible) ~= "table" then
    error("transition_table " .. name .. ": spec.impossible is a list", 2)
  end
  if spec.notes ~= nil and (type(spec.notes) ~= "table" or type(spec.notes[1]) ~= "string"
      or type(spec.notes[2]) ~= "string") then
    error("transition_table " .. name .. ": spec.notes is {path, machine}", 2)
  end
  local known = {}
  for _, row in ipairs(spec.rows) do
    local state, event, next_state = row[1], row[2], row[3]
    local cell = cell_name(state, event)
    local known_line = row.known ~= nil
      and (name .. ": " .. cell .. " -> " .. tostring(next_state) .. " (known #" .. tostring(row.known) .. ")")
    known[#known + 1] = known_line or nil
    test(name .. ": " .. cell, function()
      local enter, fire = spec.states[state], spec.events[event]
      if type(enter) ~= "function" then fail(cell .. ": no state " .. tostring(state) .. " in spec.states") end
      if type(fire) ~= "function" then fail(cell .. ": no event " .. tostring(event) .. " in spec.events") end
      local context = load_strata()
      finish_startup(context)
      enter(context)
      local now = spec.state_of(context)
      if now ~= state then fail(cell .. ": entering " .. tostring(state) .. ", state_of gave " .. tostring(now)) end
      fire(context)
      now = spec.state_of(context)
      if now ~= next_state then
        fail(cell .. ": the next state: expected " .. tostring(next_state) .. ", got " .. tostring(now))
      end
      if row.check then row.check(context) end
      if not invariant_check.allowed then
        local broken = check_invariants()
        if #broken > 0 then fail(cell .. ": invariants broken after the event:\n" .. table.concat(broken, "\n")) end
      end
      if known_line then
        local line = known_line .. ": asserts today's fault"
        if known_lines_taken then known_lines_taken[#known_lines_taken + 1] = line else real_print("     " .. line) end
      end
    end)
  end
  test(name .. ": every cell is decided", function()
    local problems, decided = {}, {}
    local function decide(kind, index, state, event)
      local cell = cell_name(state, event)
      local where = kind .. " " .. index .. " (" .. cell .. ")"
      if spec.states[state] == nil then problems[#problems + 1] = where .. ": no state " .. tostring(state) end
      if spec.events[event] == nil then problems[#problems + 1] = where .. ": no event " .. tostring(event) end
      if decided[cell] then
        problems[#problems + 1] = cell .. ": decided twice (" .. decided[cell] .. " and " .. kind .. " " .. index .. ")"
      else
        decided[cell] = kind .. " " .. index
      end
      return where
    end
    for index, row in ipairs(spec.rows) do
      local where = decide("row", index, row[1], row[2])
      if spec.states[row[3]] == nil then
        problems[#problems + 1] = where .. ": next state " .. tostring(row[3]) .. " is no state of spec.states"
      end
      if row.known ~= nil and not whole_positive(row.known) then
        problems[#problems + 1] = where .. ": known is an issue's number, not " .. tostring(row.known)
      end
      if row.check ~= nil and type(row.check) ~= "function" then problems[#problems + 1] = where .. ": check is a function" end
    end
    for index, entry in ipairs(spec.impossible or {}) do
      decide("impossible", index, entry[1], entry[2])
      if type(entry[3]) ~= "string" or entry[3] == "" then
        problems[#problems + 1] = cell_name(entry[1], entry[2]) .. ": no reason it is impossible"
      end
    end
    local states, events = {}, {}
    for state in pairs(spec.states) do states[#states + 1] = state end
    for event in pairs(spec.events) do events[#events + 1] = event end
    table.sort(states); table.sort(events)
    for _, state in ipairs(states) do
      for _, event in ipairs(events) do
        local cell = cell_name(state, event)
        if not decided[cell] then problems[#problems + 1] = cell .. ": undecided (no row and no impossible entry)" end
      end
    end
    if #problems > 0 then fail(name .. ": " .. #problems .. " problems:\n" .. table.concat(problems, "\n")) end
  end)
  if spec.notes then
    test(name .. ": the notes' table equals these rows", function()
      local path, machine = spec.notes[1], spec.notes[2]
      local problems, mine, theirs = {}, {}, {}
      for _, row in ipairs(spec.rows) do mine[cell_name(row[1], row[2])] = row[3] end
      local notes_rows = notes_table(path, machine)
      for _, row in ipairs(notes_rows) do
        local cell = cell_name(row[1], row[2])
        if theirs[cell] ~= nil then problems[#problems + 1] = cell .. ": twice in the notes" end
        theirs[cell] = row[3]
      end
      for _, row in ipairs(spec.rows) do
        local cell = cell_name(row[1], row[2])
        if theirs[cell] == nil then
          problems[#problems + 1] = cell .. ": the notes have no row (the test's next: " .. tostring(row[3]) .. ")"
        elseif theirs[cell] ~= row[3] then
          problems[#problems + 1] = cell .. ": the notes' next is " .. theirs[cell] .. ", the test's " .. tostring(row[3])
        end
      end
      for _, row in ipairs(notes_rows) do
        local cell = cell_name(row[1], row[2])
        if mine[cell] == nil then problems[#problems + 1] = cell .. ": in the notes, not a row of the test" end
      end
      if #problems > 0 then
        fail(name .. ": the table of " .. path .. ", ### " .. machine .. ", differs:\n" .. table.concat(problems, "\n"))
      end
    end)
  end
  return {known = known}
end

-- MINSTD: the same numbers under Lua and LuaJIT (every product under
-- 2 ^ 53), and none of the script's math.random draws; random(n) is 1 to n
local function seeded_random(seed)
  local state = seed
  return function(n)
    state = (state * 48271) % 2147483647
    return state % n + 1
  end
end

-- Seeded walks (see the notes for the spec's fields): one test a seed,
-- `<name> (seed <n>)`, which loads the script, runs spec.setup(context,
-- random) for its state, then spec.steps ops picked by weight; after each,
-- spec.after(state, op_name)'s problems and every invariant, and after the
-- last, spec.finish(state)'s. A problem fails the test naming the seed, the
-- step and the ops so far. With spec.reached, one more test, `<name>: the
-- walks reached every path`, asserts each counter spec.counts(state) gave,
-- summed over the seeds, above 0
local function walk(spec)
  if type(spec) ~= "table" or type(spec.name) ~= "string" or spec.name == "" then
    error("walk: spec.name is a non-empty string", 2)
  end
  local name = spec.name
  local function refuse(what) error("walk " .. name .. ": " .. what, 3) end
  if type(spec.seeds) ~= "table" or #spec.seeds == 0 then refuse("spec.seeds is a list of seeds") end
  for _, seed in ipairs(spec.seeds) do
    if not whole_positive(seed) or seed >= 2147483647 then refuse("a seed is a whole number from 1, not " .. tostring(seed)) end
  end
  if not whole_positive(spec.steps) then refuse("spec.steps is a whole number from 1") end
  if type(spec.setup) ~= "function" then refuse("spec.setup is a function") end
  if type(spec.ops) ~= "table" or #spec.ops == 0 then refuse("spec.ops is a list of {weight, name, fn}") end
  local total = 0
  for index, op in ipairs(spec.ops) do
    if type(op[1]) ~= "number" or op[1] <= 0 or type(op[2]) ~= "string" or type(op[3]) ~= "function" then
      refuse("op " .. index .. " is {weight above 0, name, fn}")
    end
    total = total + op[1]
  end
  for _, field in ipairs({"after", "finish", "counts"}) do
    if spec[field] ~= nil and type(spec[field]) ~= "function" then refuse("spec." .. field .. " is a function") end
  end
  if spec.reached ~= nil and (type(spec.reached) ~= "table" or type(spec.counts) ~= "function") then
    refuse("spec.reached is a list of counter names, with spec.counts")
  end
  local sums, walked = {}, {}
  for _, seed in ipairs(spec.seeds) do
    test(name .. " (seed " .. seed .. ")", function()
      local context = load_strata()
      finish_startup(context)
      local random = seeded_random(seed)
      local state = spec.setup(context, random)
      local names = {}
      local function check(where, problems)
        local found = {}
        if type(problems) == "string" then problems = {problems} end
        for _, problem in ipairs(problems or {}) do found[#found + 1] = tostring(problem) end
        if not invariant_check.allowed then
          for _, broken in ipairs(check_invariants()) do found[#found + 1] = "invariant " .. broken end
        end
        if #found > 0 then
          fail(name .. " (seed " .. seed .. "), " .. where .. ": " .. table.concat(found, "; ")
            .. "\nthe ops so far: " .. table.concat(names, ", "))
        end
      end
      for step = 1, spec.steps do
        local pick, index = random(1000) * total / 1000, 0
        repeat
          index = index + 1
          pick = pick - spec.ops[index][1]
        until pick <= 0 or index == #spec.ops
        local op = spec.ops[index]
        names[#names + 1] = op[2]
        op[3](state, random)
        check("step " .. step .. " (op " .. op[2] .. ")", spec.after and spec.after(state, op[2]))
      end
      check("at the end", spec.finish and spec.finish(state))
      if spec.counts then
        for counter, count in pairs(spec.counts(state) or {}) do sums[counter] = (sums[counter] or 0) + count end
      end
      walked[#walked + 1] = seed
    end)
  end
  if spec.reached then
    test(name .. ": the walks reached every path", function()
      local missing = {}
      for _, counter in ipairs(spec.reached) do
        if not ((sums[counter] or 0) > 0) then missing[#missing + 1] = counter .. " (" .. tostring(sums[counter] or 0) .. ")" end
      end
      if #missing > 0 then
        fail(name .. ": the walks never reached " .. table.concat(missing, ", ") .. " (summed over the seeds walked to"
          .. " the end: " .. (#walked > 0 and table.concat(walked, ", ") or "none") .. ", of " .. #spec.seeds .. ")")
      end
    end)
  end
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

-- The engine check's CI shards, in the workflow's order: the "- a,b,c"
-- items of the engine-shard matrix's areas list in
-- .github/workflows/test.yml (nil when it has no such list). The tests'
-- one Lua reader of that list; the runners read it through
-- test/run_engine_check_313.sh -l
local function workflow_shards()
  local workflow = file_text(repo_root .. "/.github/workflows/test.yml")
  local block = workflow and workflow:match("\n%s*areas:%s*\n(.-)\n%s*env:")
  if not block then return nil end
  local shards = {}
  for shard in block:gmatch("%-%s*([%w,]+)") do shards[#shards + 1] = shard end
  return shards
end

-- The workflow's table of area times (its comment, "Area times on ...:"
-- then "<area> <seconds>, ..."), in `workflow`'s text: the sum of every time
-- listed, and the sum the comment states ("<n> s in all"), nil without one.
-- The tests' one reader of that table (structure_test.lua's #491 and #731,
-- docs_test.lua's #816)
local function workflow_area_times(workflow)
  local after = workflow:match("Area times on [^\n]*\n(.*)")
  if not after then return nil end
  local lines = {}
  -- the table's comment lines (their "#" dropped), to the one with its sum
  for line in after:gmatch("([^\n]*)\n?") do
    local text = line:match("^%s*#%s?(.*)$")
    if not text then break end
    lines[#lines + 1] = text
    if text:find(":") then break end
  end
  local joined = table.concat(lines, " ")
  local times = joined:match("^(.-):") or joined
  local total = 0
  for seconds in times:gmatch("%a+ (%d+)") do total = total + tonumber(seconds) end
  return total, tonumber(joined:match(":%s*(%d+) s in all"))
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

-- Compare a voice's live state with a captured scene voice: every key of
-- the scene voice's values (a format 9 voice, {active, source, values}),
-- exactly (a recall sets the captured value itself, so only float noise
-- is allowed)
local function assert_voice_matches(voice_idx, voice, captured)
  local prefix = "voice " .. voice_idx .. " "
  for key, value in pairs(captured.values) do
    assert_true(params.lookup["v" .. voice_idx .. "_" .. key] ~= nil, prefix .. key .. " is a param")
    assert_near(voice.values[key], value, 1e-9, prefix .. key)
  end
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
    params:set("v" .. voice_idx .. "_grain_shape", math.random(1, 5) / 5)
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
local PAGE_TITLES = { "MAIN", "VOICE", "SEQ", "FX", "LFO", "MOD", "BUFFER", "SCENES", "SETUP", "IO" }

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

-- The header's page dots (lib/ui/header.lua): one 2x2 rect per page (ten
-- since 3.6) from x 32, 4 px apart
local HEADER_DOTS_X, HEADER_DOT_SPACING, HEADER_DOT_SIZE = 32, 4, 2

local HEADER_FLASH_X = 40

-- rows between one baseline and the next that clear a descender
local DESCENDER_CLEARANCE = 7

-- Check the drawn screen: everything inside 128x64, no two strings overlap on
-- a row, the page title at 0,8, then either the ten page dots (at least
-- 4 px after the title) or, while a header flash shows, its text at 40,8
-- and no dots; no header rect (dot, play mark) under a header string; and a
-- hint row at y 62.
local function assert_screen_layout(context, where)
  local header_constants = local_value("S").constants.HEADER
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
  -- the header band: rects above y 9. Every one over the dots' span is a
  -- page dot (2x2, or FX's 2x5 bar), so a rect of another shape there
  -- fails rather than going uncounted (#856)
  local dots = {}
  local dots_right = HEADER_DOTS_X + (#PAGE_TITLES - 1) * HEADER_DOT_SPACING + HEADER_DOT_SIZE
  for _, rect in ipairs(context.screen.rects) do
    if rect.y + rect.h <= 9 then
      for _, text in ipairs(rows[8] or {}) do
        assert_true(rect.x + rect.w <= text.left or rect.x >= text.right,
          string.format("a header rect at x %d-%d is under '%s' (%s)", rect.x, rect.x + rect.w - 1, text.text, where))
      end
      if rect.x + rect.w > HEADER_DOTS_X and rect.x < dots_right then
        assert_true(rect.w == HEADER_DOT_SIZE and (rect.h == HEADER_DOT_SIZE or rect.h == header_constants.frozen_h),
          string.format("a header rect of %dx%d at x %d over the page dots is no dot (%s)", rect.w, rect.h, rect.x, where))
        table.insert(dots, rect)
      end
    end
  end
  local flash = local_value("S").lib.ui_flash.text("header")
  if flash then
    assert_true(flash_drawn, "the header flash drawn at " .. HEADER_FLASH_X .. ",8 (" .. where .. ")")
    assert_equal(#dots, 0, "no page dots under the header flash (" .. where .. ")")
  else
    assert_equal(#dots, #PAGE_TITLES, "a page dot per page (" .. where .. ")")
    table.sort(dots, function(a, b) return a.x < b.x end)
    -- 3.8: while anything is frozen FX's dot is the 2x5 bar, and only then
    local bar_index = local_value("S").lib.fx_hold.any_frozen() and local_value("S").constants.UI_PAGES.index.FX
    for index, dot in ipairs(dots) do
      assert_equal(dot.x, HEADER_DOTS_X + (index - 1) * HEADER_DOT_SPACING, "page dot " .. index .. " (" .. where .. ")")
      assert_equal(dot.h, index == bar_index and header_constants.frozen_h or HEADER_DOT_SIZE,
        "page dot " .. index .. "'s height (" .. where .. ")")
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
  local listing = io.popen("ls -1 " .. shell_quote(dir) .. " 2>/dev/null")
  for name in listing:read("*a"):gmatch("[^\n]+") do
    if name:match("_test%.lua$") and (not filter or name:find(filter, 1, true)) then
      table.insert(names, name)
    end
  end
  listing:close()
  table.sort(names)
  return names
end

-- Load each unit file unit_files(dir, filter) lists, in order, or, when
-- `filter` is a list of names, those files in that order. A unit file
-- returns function(h), which registers its tests with h.test. Returns the
-- names loaded. A file that returns no function, or whose function
-- registers no test, is an error naming it (#484): a test file emptied or
-- all behind a condition never passes as 0 tests
local function load_unit_files(dir, filter, helpers)
  local names = type(filter) == "table" and filter or unit_files(dir, filter)
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

---------------------------------------------------------------------------
-- shards and the parallel run (test/run.lua)
---------------------------------------------------------------------------

-- Each unit file's weight for the shards and the parallel run's order: its
-- seconds run alone (`lua test/run.lua <name>`, Lua 5.3, rounded, at least
-- 1; measured at 3.8's package x5 with several files running at once).
-- A line is optional: a file with none runs as every file does, weighing
-- UNIT_FILE_DEFAULT_SECONDS, and a line only improves the balance, so a
-- heavy new file (over ten seconds alone, say) is worth one. A line naming
-- no unit file is stale, and a test in stubs_test.lua fails on it
local UNIT_FILE_SECONDS = {
  ["arc_core_test.lua"] = 1,
  ["arc_pages_test.lua"] = 3,
  ["bookmarks_test.lua"] = 1,
  ["buffers_test.lua"] = 7,
  ["buffers_slot_test.lua"] = 20,
  ["chance_test.lua"] = 1,
  ["conditions_test.lua"] = 1,
  ["data_files_test.lua"] = 2,
  ["delay_sync_test.lua"] = 2,
  ["docs_test.lua"] = 29,
  ["engine_sync_test.lua"] = 3,
  ["envelopes_test.lua"] = 1,
  ["expression_test.lua"] = 1,
  ["files_test.lua"] = 4,
  ["freeze_test.lua"] = 13,
  ["gestures_test.lua"] = 4,
  ["grid_core_test.lua"] = 4,
  ["grid_layout_128h_test.lua"] = 3,
  ["grid_layout_128v_test.lua"] = 2,
  ["grid_layout_256_test.lua"] = 4,
  ["grid_layout_64_test.lua"] = 2,
  ["grid_walk_test.lua"] = 5,
  ["history_test.lua"] = 1,
  ["input_level_test.lua"] = 1,
  ["io_actions_test.lua"] = 1,
  ["io_controllers_test.lua"] = 1,
  ["io_crow_test.lua"] = 2,
  ["io_er301_test.lua"] = 1,
  ["io_ii_test.lua"] = 3,
  ["io_jf_test.lua"] = 1,
  ["io_keyed_test.lua"] = 1,
  ["io_midi_out_test.lua"] = 11,
  ["io_nb_test.lua"] = 2,
  ["io_osc_test.lua"] = 1,
  ["io_ports_test.lua"] = 2,
  ["io_remote_test.lua"] = 2,
  ["io_rig_test.lua"] = 1,
  ["io_system_test.lua"] = 18,
  ["io_tape_test.lua"] = 1,
  ["io_targets_test.lua"] = 1,
  ["io_txo_test.lua"] = 2,
  ["io_wsyn_test.lua"] = 1,
  ["io_wtape_test.lua"] = 1,
  ["lfos_test.lua"] = 4,
  ["loops_test.lua"] = 1,
  ["macros_test.lua"] = 3,
  ["matrix_test.lua"] = 5,
  ["midi_in_test.lua"] = 5,
  ["mod_sources_test.lua"] = 1,
  ["modulation_walk_test.lua"] = 4,
  ["morph_test.lua"] = 3,
  ["mpe_test.lua"] = 1,
  ["mutation_test.lua"] = 21,
  ["notes_test.lua"] = 4,
  ["pages_buffer_test.lua"] = 8,
  ["pages_fx_test.lua"] = 2,
  ["pages_io_test.lua"] = 4,
  ["pages_lfo_test.lua"] = 2,
  ["pages_main_test.lua"] = 2,
  ["pages_mod_test.lua"] = 2,
  ["pages_scenes_test.lua"] = 2,
  ["pages_seq_test.lua"] = 3,
  ["pages_setup_test.lua"] = 3,
  ["pages_voice_test.lua"] = 3,
  ["params_setup_test.lua"] = 2,
  ["performance_test.lua"] = 2,
  ["playheads_test.lua"] = 2,
  ["positions_test.lua"] = 4,
  ["quantize_test.lua"] = 1,
  ["random_sequences_test.lua"] = 1,
  ["record_test.lua"] = 3,
  ["registries_test.lua"] = 3,
  ["samples_test.lua"] = 3,
  ["scan_test.lua"] = 1,
  ["scatter_test.lua"] = 1,
  ["scenes_test.lua"] = 15,
  ["sequencer_test.lua"] = 10,
  ["side_files_test.lua"] = 1,
  ["slices_test.lua"] = 2,
  ["strata_test.lua"] = 2,
  ["structure_test.lua"] = 88,
  ["stubs_test.lua"] = 19,
  ["system_37_test.lua"] = 2,
  ["ui_alt_test.lua"] = 1,
  ["ui_cursors_test.lua"] = 1,
  ["ui_detent_test.lua"] = 2,
  ["ui_field_list_test.lua"] = 1,
  ["ui_header_test.lua"] = 1,
  ["ui_layout_test.lua"] = 125,
  ["ui_modal_test.lua"] = 1,
  ["ui_pages_test.lua"] = 1,
  ["ui_slice_editor_test.lua"] = 2,
  ["ui_test.lua"] = 1,
  ["ui_walk_test.lua"] = 1,
  ["ui_zones_test.lua"] = 1,
  ["variation_test.lua"] = 2,
  ["voice_mix_test.lua"] = 1,
  ["voices_test.lua"] = 1,
  ["waveforms_test.lua"] = 1,
}
local UNIT_FILE_DEFAULT_SECONDS = 3

local function unit_file_seconds(name) return UNIT_FILE_SECONDS[name] or UNIT_FILE_DEFAULT_SECONDS end

-- The lines of `weights` (UNIT_FILE_SECONDS) that name none of the unit
-- files `names`, sorted
local function stale_unit_weights(names, weights)
  local listed, stale = {}, {}
  for _, name in ipairs(names) do listed[name] = true end
  for name in pairs(weights) do
    if not listed[name] then stale[#stale + 1] = name end
  end
  table.sort(stale)
  return stale
end

-- `names` heaviest first (unit_file_seconds, then the name): the order the
-- shards are dealt in and a parallel run starts its processes in
local function heaviest_first(names)
  local sorted = {}
  for index, name in ipairs(names) do sorted[index] = name end
  table.sort(sorted, function(a, b)
    local weight_a, weight_b = unit_file_seconds(a), unit_file_seconds(b)
    if weight_a ~= weight_b then return weight_a > weight_b end
    return a < b
  end)
  return sorted
end

-- Shard `shard` of `count` of the unit files `names` (all of them, never a
-- filter's, so a file's shard does not depend on the filter), sorted by
-- name: each file, heaviest first, goes to the shard with the least weight
-- so far (the lowest number on a tie). Whole numbers and names only, so
-- the shards are the same on every machine and interpreter, and each file
-- is in exactly one
local function shard_files(names, shard, count)
  local loads, mine = {}, {}
  for index = 1, count do loads[index] = 0 end
  for _, name in ipairs(heaviest_first(names)) do
    local lightest = 1
    for index = 2, count do
      if loads[index] < loads[lightest] then lightest = index end
    end
    loads[lightest] = loads[lightest] + unit_file_seconds(name)
    if lightest == shard then mine[#mine + 1] = name end
  end
  table.sort(mine)
  return mine
end

-- The machine's cores: nproc (GNU coreutils), else getconf (POSIX; macOS
-- has it), else 1
local function core_count()
  local pipe = io.popen("nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null")
  local text = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end
  local cores = tonumber(text:match("^%s*(%d+)%s*$") or "")
  return (cores and cores >= 1) and cores or 1
end

-- A run's processes when neither --jobs nor STRATA_TEST_JOBS names a
-- number: the machine's cores, at most DEFAULT_JOBS_CAP (why:
-- docs/notes/test-harness/run-and-helpers.md, The parallel run)
local DEFAULT_JOBS_CAP = 8
local function default_jobs() return math.min(core_count(), DEFAULT_JOBS_CAP) end

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
  registered_invariant = registered_invariant,
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
  GRID_ARRANGEMENTS = GRID_ARRANGEMENTS,
  grid_pane = grid_pane,
  probe_grid_page = probe_grid_page,
  no_grid_page = no_grid_page,
  resize_grid = resize_grid,
  slice_doubles = slice_doubles,
  deep_copy = deep_copy,
  voice_count = voice_count,
  voice_entries = voice_entries,
  allowed_call_lines = allowed_call_lines,
  call_line = call_line,
  canonical_call_lines = canonical_call_lines,
  transition_table = transition_table,
  notes_table = notes_table,
  walk = walk,
  with_known_lines = with_known_lines,
  tabutil_text = tabutil_text,
  file_text = file_text,
  workflow_shards = workflow_shards,
  workflow_area_times = workflow_area_times,
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
  UNIT_FILE_SECONDS = UNIT_FILE_SECONDS,
  UNIT_FILE_DEFAULT_SECONDS = UNIT_FILE_DEFAULT_SECONDS,
  unit_file_seconds = unit_file_seconds,
  stale_unit_weights = stale_unit_weights,
  heaviest_first = heaviest_first,
  shard_files = shard_files,
  core_count = core_count,
  default_jobs = default_jobs,
}

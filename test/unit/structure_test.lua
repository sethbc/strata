-- test/unit/structure_test.lua
-- The script's structure: includes, S, module homes, constants, the
-- static checks that every global read is defined and none is defined in
-- two files, the free-locals probe, the cleanup order, the param-type
-- comparison check and that no data file is run as Lua
-- Run alone: lua test/run.lua structure

return function(h)
local test, repo_root, stubs, sync_check = h.test, h.repo_root, h.stubs, h.sync_check
local real_print, harness_globals, signatures = h.real_print, h.harness_globals, h.signatures
local engine_polls, engine_spec, data_root = h.engine_polls, h.engine_spec, h.data_root
local assert_true, assert_equal, load_strata = h.assert_true, h.assert_equal, h.load_strata
local find_upvalue, local_value, read_lua_sources = h.find_upvalue, h.local_value, h.read_lua_sources
local finish_startup = h.finish_startup

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

-- The places the script's Lua files could run a data file as Lua (#464):
-- every mention of tab.load (a call, or passed to pcall), and every call of
-- loadfile, dofile, loadstring or load. A data file is parsed by
-- lib/data_files.lua, never run
local function chunk_loader_uses(sources)
  local found = {}
  for _, source in ipairs(sources) do
    local sanitized = sync_check.sanitize_lua(source.text)
    local function report(start, what)
      local line = select(2, sanitized:sub(1, start - 1):gsub("\n", "")) + 1
      table.insert(found, source.path .. ":" .. line .. " " .. what)
    end
    for start in sanitized:gmatch("()%f[%w_]tab%s*%.%s*load%f[^%w_]") do report(start, "tab.load") end
    for start, name in sanitized:gmatch("()%f[%w_]([%a_][%w_]*)%s*%(") do
      local before = sanitized:sub(1, start - 1)
      local loader = name == "loadfile" or name == "dofile" or name == "loadstring" or name == "load"
      if loader and not before:match("[%.:]%s*$") and not before:match("function%s+$") then report(start, name) end
    end
  end
  return found
end

test("no data file is run as Lua: strata.lua and lib/ never use tab.load or a chunk loader (#464)", function()
  -- the scanner itself
  local found = chunk_loader_uses({ { path = "lib/x.lua", text = table.concat({
    "local a = tab.load(path)",
    "local b = pcall(tab . load, path)",
    "local c = loadfile(path) or dofile(path) or loadstring(text) or load(text)",
    '-- tab.load(path) in a comment; "loadfile(x)" in a string',
    "local d = params:load(1) or S.lib.data_files.read(path) or x.load(y) or reload(z) or load_buffer(1)",
    "local function load(x) end",
    "for index, load in ipairs(loads) do if load.slot then end end",
  }, "\n") } })
  assert_equal(table.concat(found, "; "), "lib/x.lua:1 tab.load; lib/x.lua:2 tab.load; lib/x.lua:3 loadfile; "
    .. "lib/x.lua:3 dofile; lib/x.lua:3 loadstring; lib/x.lua:3 load",
    "each use is found; comments, strings, methods, other tables' load, definitions and locals are not")
  found = chunk_loader_uses(read_lua_sources())
  assert_equal(#found, 0, table.concat(found, "; "))
end)

-- Every mention of tab.save in the script's Lua files (a call, or the
-- function passed on): a data file is written by lib/data_files.lua, to a
-- checked .part file renamed into place, never rewritten in place (#301)
local function tab_save_uses(sources)
  local found = {}
  for _, source in ipairs(sources) do
    local sanitized = sync_check.sanitize_lua(source.text)
    for start in sanitized:gmatch("()%f[%w_]tab%s*%.%s*save%f[^%w_]") do
      local line = select(2, sanitized:sub(1, start - 1):gsub("\n", "")) + 1
      table.insert(found, source.path .. ":" .. line .. " tab.save")
    end
  end
  return found
end

test("no data file is written in place: strata.lua and lib/ never use tab.save (#301)", function()
  -- the scanner itself
  local found = tab_save_uses({ { path = "lib/x.lua", text = table.concat({
    "tab.save(value, path)",
    "local save = tab . save",
    '-- tab.save(value, path) in a comment; "tab.save(x)" in a string',
    "S.lib.data_files.write(path, value); params:save(1); mytab.save(x); tab.saved = 1",
  }, "\n") } })
  assert_equal(table.concat(found, "; "), "lib/x.lua:1 tab.save; lib/x.lua:2 tab.save",
    "each use is found; comments, strings and other names are not")
  found = tab_save_uses(read_lua_sources())
  assert_equal(#found, 0, table.concat(found, "; "))
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
local MODULE_HOMES = {
  ["lib/voices.lua"] = { "voice_uses_synth", "voice_uses_buffer", "voice_source_label", "voice_buffer_slot" },
  ["lib/ui/frame.lua"] = { "request_redraw", "draw_frame", "start_frame_clock", "stop_frame_clock" },
  ["lib/engine_sync.lua"] = { "send_param_to_engine", "engine_param_value", "toggle_voice", "toggle_lock",
    "sync_voice_values_to_engine" },
  ["lib/buffers.lua"] = { "scratch_take_path", "confirm_buffer_audio", "settle_buffer_slot",
    "set_buffer_file_param", "empty_buffer_state", "buffer_state_before_load", "load_buffer",
    "clear_buffer", "buffer_save_path", "save_buffer", "buffer_load_failed", "buffer_save_result",
    "save_buffers_to_disk", "load_buffers_from_disk", "save_buffer_loop" },
  ["lib/record.lua"] = { "record_buffer" },
  ["lib/lfos.lua"] = { "lfo_destination_id", "restore_lfo_destination", "add_lfo_params" },
  ["lib/mutation.lua"] = { "randomize_voice", "gentle_mutate", "drift_update", "mean_reverting_step",
    "set_drifted_param", "mutated_value", "clear_undo", "undo_available", "undo_randomize", "note_param_edit" },
  ["lib/scenes.lua"] = { "capture_scene", "recall_scene", "recall_scene_instant", "migrate_scene",
    "validate_scene", "validate_scene_data", "save_scenes_to_disk", "load_scenes_from_disk",
    "scene_sequencer_start", "scene_sequencer_stop", "cancel_scene_transition", "with_traceback",
    "scene_transition_targets", "wait_for_scene_transition" },
  ["lib/midi_in.lua"] = { "attach_midi", "midi_init", "midi_event", "midi_device_name",
    "midi_bend_follow_selection", "reset_midi_input", "midi_target_voice", "midi_note_on", "midi_note_off_for",
    "midi_pitchbend", "midi_set_bend" },
  ["lib/params_setup.lua"] = { "add_voice_params", "get_param_spec", "redraw_on_param_changes",
    "follow_clock_tempo", "install_tempo_change_handler", "restore_tempo_change_handler" },
  ["lib/ui/params.lua"] = { "set_binary_param", "param_range", "param_spans_zero", "param_default", "param_value_fraction",
    "param_fraction" },
  ["lib/ui/header.lua"] = { "draw_header", "draw_hints" },
  ["lib/ui/flash.lua"] = { "header_flash" },
  ["lib/ui/keys.lua"] = { "forget_held_keys" },
  ["lib/ui/alt.lua"] = { "alt_action" },
  ["lib/ui/detent.lua"] = { "delta_with_detent", "enc_param_delta" },
  ["lib/ui/menu_watch.lua"] = { "forget_keys_held_through_menu", "watch_menu_opening", "unwatch_menu_opening" },
  ["lib/pages/main.lua"] = { "update_voice_list", "main_param_entry", "main_param_id", "redraw_main" },
  ["lib/pages/fx.lua"] = { "redraw_fx" },
  ["lib/pages/lfo.lua"] = { "lfo_wave_value", "redraw_lfo" },
  ["lib/pages/buffer.lua"] = { "buffer_page_flash", "redraw_buffer",
    "close_buffer_file_selector", "release_superseded_file_selector" },
  ["lib/pages/setup.lua"] = { "redraw_setup", "setup_enc" },
  ["lib/arc/core.lua"] = { "arc_sweep_param", "arc_ring_fill", "arc_ring_fill_position", "arc_ring_fill_bipolar", "arc_ring_fill_param",
    "arc_whole_steps", "forget_arc_ticks", "arc_init", "first_arc_port", "arc_delta", "arc_key", "arc_redraw",
    "forget_arc_lfo_period_ticks" },
  ["lib/grid/core.lua"] = { "grid_init", "grid_key", "grid_redraw", "select_grid_voice" },
  ["lib/grid/faders.lua"] = { "voice_level_fader_keys", "fader_param_ids", "fader_page_count",
    "fader_zero_column", "fader_column_fraction", "set_param_from_column", "set_fader_param", "fader_position",
    "grid_redraw_fader_row", "grid_redraw_faders" },
  ["lib/grid/layout_256.lua"] = { "grid_key_256", "grid_key_256_transport", "grid_key_256_lock",
    "grid_redraw_256", "grid_redraw_256_buffers", "grid_redraw_256_sources", "grid_redraw_256_page_row",
    "grid_redraw_256_transport", "grid_redraw_256_lock" },
  ["lib/grid/layout_128h.lua"] = { "grid_key_128h", "grid_redraw_128h" },
  ["lib/grid/layout_128v.lua"] = { "grid_key_128v", "grid_redraw_128v" },
  ["lib/grid/layout_64.lua"] = { "grid_key_64", "grid_redraw_64" },
  ["lib/sequencer.lua"] = { "toggle_pattern_step", "clear_pattern", "randomize_pattern", "pattern_toggle",
    "pattern_clock_start", "pattern_clock_stop", "step_brightness" },
}

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

-- Globals more than one script file may write, each with the files that
-- may write it: strata.lua defines key, enc and redraw; lib/pages/buffer.lua
-- puts back the script's own key and enc when the file selector fails, and
-- lib/pages/scenes.lua when the norns menu took its name entry over; the
-- name entry puts norns.none in redraw again (as textentry.enter does)
-- when the menu closed over it
local GLOBALS_WRITTEN_IN_TWO_FILES = {
  key = { "strata.lua", "lib/pages/buffer.lua", "lib/pages/scenes.lua" },
  enc = { "strata.lua", "lib/pages/buffer.lua", "lib/pages/scenes.lua" },
  redraw = { "strata.lua", "lib/pages/scenes.lua" },
}

-- Every global (a global function or any other value) that more than one
-- of a list of { path, text } files writes, unless every file writing it
-- is one its allowance (allowed[name], a list of paths) names, as
-- "<name>: <path>:<line>, <path>:<line>, ..."
local function globals_written_twice(root, sources, allowed)
  local homes, problems = {}, {}
  for _, source in ipairs(sources) do
    local _, writes = global_accesses(root .. "/" .. source.path, source.path)
    for name, where in next, writes do
      homes[name] = homes[name] or {}
      table.insert(homes[name], where)
    end
  end
  local function all_allowed(name, places)
    local paths = {}
    for _, path in ipairs(allowed[name] or {}) do paths[path] = true end
    for _, where in ipairs(places) do
      if not paths[where:match("^(.*):%d+$") or where] then return false end
    end
    return true
  end
  for name, places in next, homes do
    if #places > 1 and not all_allowed(name, places) then
      table.sort(places)
      table.insert(problems, name .. ": " .. table.concat(places, ", "))
    end
  end
  table.sort(problems)
  return problems
end

test("no global is defined in two files", function()
  if not GLOBAL_CHECK_RUNS then
    real_print("     (skipped: the global-reference check runs under Lua 5.3 only; " .. _VERSION
      .. (rawget(_G, "jit") and ", LuaJIT" or "") .. " has no luac)")
    return
  end
  assert_true(LUAC, "the duplicate-global check needs Lua 5.3's luac on PATH (`luac` or `luac5.3`, reporting 5.3)")
  local problems = globals_written_twice(repo_root, read_lua_sources(), GLOBALS_WRITTEN_IN_TWO_FILES)
  assert_equal(#problems, 0, "globals defined in more than one file (a later include replaces the earlier one):\n  "
    .. table.concat(problems, "\n  "))
  -- the scanner: a function or value defined in two files is found, one
  -- written twice in the same file, or only by the files its allowance
  -- names, is not; an allowed name written by a file its allowance does not
  -- name is found
  local scratch = data_root .. "duplicate_global_check"
  os.execute("mkdir -p '" .. scratch .. "/lib'")
  local files = {
    { path = "strata.lua", text = "function twice() end\nvalue_twice = 1\nonce = 1\nonce = 2\nfunction allowed() end\n"
      .. "function strayed() end\n" },
    { path = "lib/x.lua", text = "return function() function twice() end value_twice = 2 allowed = nil strayed = nil end\n" },
    { path = "lib/y.lua", text = "return function() strayed = nil end\n" },
  }
  for _, source in ipairs(files) do
    local out = assert(io.open(scratch .. "/" .. source.path, "w")); out:write(source.text); out:close()
  end
  local found = globals_written_twice(scratch, files,
    { allowed = { "strata.lua", "lib/x.lua" }, strayed = { "strata.lua", "lib/x.lua" } })
  local names = {}
  for _, entry in ipairs(found) do table.insert(names, entry:match("^([^:]*)")) end
  assert_equal(table.concat(names, " "), "strayed twice value_twice", "each global defined in two files is found:\n  "
    .. table.concat(found, "\n  "))
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

-- strata.lua's main chunk keeps at least this many free locals, like every
-- module (it holds only the entry points)
local STRATA_MIN_FREE_LOCALS = 30

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

-- cleanup()'s steps, in the order cleanup has always run them: the files
-- are saved before anything stops, the LFOs give their destinations back
-- before the voices go off, MIDI is detached before the voices go off, and
-- the controllers go dark last
local CLEANUP_STEPS = { "tempo handler", "menu watch", "scenes saved", "macros saved", "gestures saved",
  "matrix saved",
  "buffer paths saved",
  "startup clock", "frame clock", "drift metro", "mutation metro", "undo clock", "pattern clock", "gesture recorders",
  "quantized actions", "scene sequencer", "scene transition",
  "morph clock", "macro clock", "zones learn", "matrix learn", "notes flush", "lfos", "playheads clock", "scan holds", "waveform loop",
  "engine budget",
  "buffer start reload", "buffer polls and timers", "record poll", "input meter", "flashes", "midi handler",
  "voices off", "grids dark", "arc dark" }

test("cleanup runs every registered step in today's order", function()
  local context = load_strata()  -- init's start-up clock still waits to start voice 2
  local S = local_value("S")
  context.grid.plug(1, 16, 16)
  context.arc.plug(1)
  capture_scene(1)
  params:set("scene_sequencer_enabled", 1)
  params:set("mutation_enabled", 1)
  pattern_toggle()
  recall_scene(1, 5)
  params:set("strata_lfo1", 1)
  record_buffer(1)
  context.audio.register("/tmp/long.wav", { channels = 2, frames = 48000 * 60, rate = 48000 })
  load_buffer(2, "/tmp/long.wav"); S.lib.buffers.set_start(2, 5)  -- a start reload waits
  context.clock.run_for(0.11)         -- buffers.data's coalesced write (#566) has run
  buffer_page_flash("flash")
  randomize_voice(1)  -- after the recall, which clears the undo: its expiry clock runs
  header_flash("flash")
  S.lib.ui_keys.set_ui_page(S.constants.UI_PAGES.index.BUFFER)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  S.lib.positions.hold_scan(1, true)  -- a scan hold for cleanup to end
  S.lib.engine_sync.deferrable(function()  -- a send past the budget waits: the flush clock runs
    for _ = 1, S.constants.ENGINE_BUDGET.messages_per_window + 1 do send_param_to_engine("drift_amount", 0) end
  end)
  params:set("morph", 0.5)  -- the morph clock waits to apply it
  params:set("macro_1", 0.5)  -- the macro clock waits to apply it
  params:set("gesture_2_quantize", 3)  -- recorder 1 plays a free loop (its metro), 2 a bar loop (its clock)
  for k = 1, 2 do S.lib.gestures.press(k); enc_param_delta(3, "reverb_mix", 1); S.lib.gestures.press(k) end
  params:set("quantize_actions", 2); S.lib.quantize.schedule("scene", function() end)  -- an action waits
  S.lib.matrix.learn(1)  -- matrix learn's timeout clock runs
  S.lib.midi_in.set_note_tap = function() end  -- the MIDI module's note tap (3.5's 2b): a stand-in
  S.lib.ui_zones.open(); S.lib.ui_zones.learn(1)  -- the zones editor's learn timeout clock runs

  -- the steps' observable effects, each logged once in a row; "|" marks
  -- the start of each registered step
  local log = {}
  local function observe(step) if log[#log] ~= step then table.insert(log, step) end end
  local function watch_field(target, key, step)
    assert_equal(getmetatable(target), nil, "a plain table to watch " .. key .. " on")
    local value = rawget(target, key)
    rawset(target, key, nil)
    setmetatable(target, {
      __index = function(_, name) if name == key then return value end end,
      __newindex = function(self, name, new_value)
        if name == key then value = new_value; observe(step) else rawset(self, name, new_value) end
      end,
    })
  end
  local function watch_method(object, method, step, unless)
    local original = object[method]
    object[method] = function(...)
      if not (unless and unless()) then observe(step) end
      return original(...)
    end
  end
  local clocks = { { "startup clock", STARTUP.clock }, { "frame clock", local_value("UI_PAGES").frame_clock },
    { "undo clock", local_value("undo_clock") },
    { "pattern clock", S.pattern_clock }, { "scene sequencer", S.scene_sequencer_clock },
    { "scene transition", S.scene_transition_clock }, { "buffer polls and timers", S.buffer_record_clocks[1] },
    { "waveform loop", S.lib.waveforms.read_clock }, { "buffer start reload", S.lib.buffers.start_reload_clocks[2] },
    { "flashes", S.lib.ui_flash.slots.hints.clock }, { "flashes", S.lib.ui_flash.slots.header.clock },
    { "playheads clock", S.lib.playheads.clock_id() }, { "engine budget", S.engine_budget_clock },
    { "morph clock", S.morph_clock }, { "macro clock", S.macro_clock },
    { "gestures saved", S.gesture_save_clock },  -- the recordings' timed write (#651), canceled as the step writes
    { "gesture recorders", S.gestures[2].clock }, { "quantized actions", S.lib.quantize.actions.scene.clock },
    { "zones learn", S.zones_learn_clock },
    { "matrix learn", S.matrix_learn_clock },
    { "lfos", S.lfo_clock } }
  for voice_idx = 1, S.constants.NUM_VOICES do table.insert(clocks, { "pattern clock", S.pattern_clocks[voice_idx] }) end
  local clock_steps = {}
  for _, entry in ipairs(clocks) do
    assert_true(entry[2] ~= nil, entry[1] .. ": its clock runs before cleanup")
    clock_steps[entry[2]] = entry[1]
  end
  local param_steps = { mutation_enabled = "mutation metro", scene_sequencer_enabled = "scene sequencer" }
  local file_steps = { ["scenes.data"] = "scenes saved", ["buffers.data"] = "buffer paths saved",
    ["gestures.data"] = "gestures saved", ["macros.data"] = "macros saved", ["matrix.data"] = "matrix saved" }

  watch_field(clock, "tempo_change_handler", "tempo handler")
  watch_field(_menu, "set_mode", "menu watch")
  -- the data files' one writer (lib/data_files.lua), looked up as it is called
  local real_save = S.lib.data_files.write
  S.lib.data_files.write = function(path, value)
    observe(file_steps[path:match("[^/]*$")] or ("file " .. path))
    return real_save(path, value)
  end
  local real_cancel = clock.cancel
  clock.cancel = function(id) observe(clock_steps[id] or ("clock " .. tostring(id))); return real_cancel(id) end
  watch_method(S.drift_metro, "stop", "drift metro")
  watch_method(S.mutation_metro, "stop", "mutation metro")
  watch_method(S.gestures[1].pattern.metro, "stop", "gesture recorders")
  watch_method(S.lib.positions, "hold_scan", "scan holds")
  watch_method(S.lib.notes, "stop_flush", "notes flush")
  local real_set = params.set
  params.set = function(self, id, ...)
    if param_steps[id] then observe(param_steps[id]) end
    return real_set(self, id, ...)
  end
  watch_method(S.buffer_polls.state, "stop", "buffer polls and timers")
  watch_method(S.buffer_polls.load_failed, "stop", "buffer polls and timers")
  watch_method(context.polls.polls.recordState, "stop", "record poll")
  for _, name in ipairs({ "amp_in_l", "amp_in_r" }) do watch_method(context.polls.polls[name], "stop", "input meter") end
  watch_field(S.midi_device, "event", "midi handler")
  local real_voice_off = engine.voiceOff
  engine.voiceOff = function(...) observe("voices off"); return real_voice_off(...) end
  -- a redraw clears the LEDs too: only a clear outside one counts
  local drawing = false
  local real_grid_redraw, real_arc_redraw = grid_redraw, arc_redraw
  grid_redraw = function(...) drawing = true; real_grid_redraw(...); drawing = false end
  arc_redraw = function(...) drawing = true; real_arc_redraw(...); drawing = false end
  for _, grid_port in pairs(S.grids) do
    watch_method(grid_port, "all", "grids dark", function() return drawing end)
  end
  watch_method(S.arc_device, "all", "arc dark", function() return drawing end)

  assert_equal(type(S.register_cleanup), "function", "S.register_cleanup")
  local registered = S.registry.cleanup
  for _, record in ipairs(registered) do
    local step = record.fn
    record.fn = function(...) table.insert(log, "|"); return step(...) end
  end
  local ok, problem = pcall(cleanup)
  S.lib.data_files.write, clock.cancel, params.set = real_save, real_cancel, nil
  grid_redraw, arc_redraw = real_grid_redraw, real_arc_redraw
  assert_true(ok, tostring(problem))

  local expected = {}
  for _, step in ipairs(CLEANUP_STEPS) do table.insert(expected, "|"); table.insert(expected, step) end
  assert_equal(table.concat(log, ", "), table.concat(expected, ", "), "one registered step per effect, in order")
  -- S.constants.CLEANUP_ORDER names each step's order, and no two steps share one
  local orders = 0
  for _ in pairs(S.constants.CLEANUP_ORDER) do orders = orders + 1 end
  assert_equal(orders, #CLEANUP_STEPS, "CLEANUP_ORDER has one order per step")
  assert_equal(#registered, #CLEANUP_STEPS, "one registered step per order")
  assert_true(not pcall(S.register_cleanup, S.constants.CLEANUP_ORDER.lfos, function() end),
    "a second step at a taken order is refused")
  assert_true(not pcall(S.register_cleanup, nil, function() end), "an order is a number")
end)

-- init's start steps, in the order init has always run them, each with its
-- observable effects (each logged once in a row): the param records are
-- added and their actions wrapped first (no step), then the voice list, E1's
-- settings, the menu watch, the two metros, the buffer polls, the arc, the
-- grids, MIDI, the scenes and buffers files (one saved scene and one saved
-- buffer path), the start-up clock (voice 1 starts and syncs at once) and the
-- frame clock
local function start_steps()
  -- a start: the source and the grain values (the registered voice params'
  -- grain keys and syncs with them), voiceOn, then the voice-level values (#325)
  local voice_sync = { "engine.setGrainSource", "engine.setGrainParam", "engine.voiceOn", "engine.setVoiceParam" }
  for _ = 1, local_value("NUM_MOD_SLOTS") do
    for _, command in ipairs({ "engine.setModSource", "engine.setModAmpAmt", "engine.setModFreqAmt" }) do
      table.insert(voice_sync, command)
    end
  end
  table.insert(voice_sync, "engine.setModSpeed")
  table.insert(voice_sync, "engine.setVoiceParam")
  for _, effect in ipairs({ "voice list built", "redraw requested", "grid redrawn" }) do
    table.insert(voice_sync, effect)
  end
  table.insert(voice_sync, 1, "clock started")
  return {
    { "started", {} },
    { "voice list", { "voice list built" } },
    { "voice layout states", {} },
    { "E1 settings", { "encoder 1 accel false", "encoder 1 sens 4" } },
    { "menu watch", { "menu watched" } },
    { "drift metro", { "metro created", "drift metro started" } },
    { "mutation metro", { "metro created" } },
    { "buffer polls", { "poll set bufferState", "poll started bufferState", "poll set bufferLoadFailed",
      "poll started bufferLoadFailed", "poll set bufferSaveResult", "poll started bufferSaveResult",
      "poll set takeWriteFailed", "poll started takeWriteFailed" } },
    { "input level polls", { "poll set amp_in_l", "poll started amp_in_l", "poll set amp_in_r",
      "poll started amp_in_r" } },
    { "record poll", { "poll set recordState", "poll started recordState" } },
    { "arc", { "arc connected" } },
    { "grids", { "file read grids.data", "grid connected", "print grid 1 connected: 16x16", "grid connected",
      "grid redrawn" } },
    { "midi", { "midi connected" } },
    { "scenes load", { "file read scenes.data", "print scenes loaded from scenes.data", "grid redrawn",
      "redraw requested" } },
    { "macros load", { "file read macros.data", "redraw requested", "grid redrawn" } },
    { "gestures load", { "file read gestures.data", "redraw requested", "grid redrawn" } },
    { "matrix load", { "file read matrix.data", "redraw requested" } },
    { "notes load", { "file read notes.data", "engine.setNotePool" } },
    { "buffers load", { "file read buffers.data", "engine.loadBuffer", "redraw requested", "grid redrawn",
      "print 1 buffers reloading from buffers.data" } },
    { "startup clock", voice_sync },
    { "lfo clock", { "clock started" } },
    { "frame clock", { "clock started" } },
    { "waveform loop", { "clock started" } },
    { "playheads", { "clock started" } },
    { "pattern transport", {} },
  }
end

test("init runs every registered start step in today's order", function()
  -- a session that saved a scene and a buffer path, so both loads read a file
  local first = load_strata(); finish_startup(first)
  capture_scene(1)
  local recorded = first.audio_dir .. "kept.wav"
  io.open(recorded, "w"):close()
  load_buffer(1, recorded)
  cleanup()

  local log = {}
  local function observe(effect) if log[#log] ~= effect then table.insert(log, effect) end end
  local function wrap_global(name, effect)
    local original = _G[name]
    _G[name] = function(...) observe(effect); return original(...) end
  end
  local function wrap_function(owner, name, effect)
    local original = owner[name]
    owner[name] = function(...) observe(type(effect) == "function" and effect(...) or effect); return original(...) end
  end
  local S
  -- the active file the engine writes at alloc (no file prints a line)
  h.write_performance_active({ tier = "standard", buffer_seconds = 16, max_grains = 128, history_seconds = 16 })
  local options = { data_subdir = first.data_dir:match("([^/]+)/$") }
  function options.before_load(context)
    context.grid.plug(1, 16, 16)
    context.arc.plug(1)
    context.midi.plug(1, "keys")
  end
  function options.before_init(context)
    S = local_value("S")
    for _, record in ipairs(S.registry.params) do wrap_function(record, "add", "params added") end
    wrap_global("redraw_on_param_changes", "param actions wrapped")
    local quiet_print = print
    print = function(...)
      observe("print " .. table.concat({ ... }, " "):gsub("%S*/", ""))  -- file names without their folders
      return quiet_print(...)
    end
    local engine_meta = getmetatable(engine)
    local real_command = engine_meta.__index
    engine_meta.__index = function(self, name)
      local command = real_command(self, name)
      return function(...) observe("engine." .. name); return command(...) end
    end
    wrap_function(context.UI.ScrollingList, "new", "voice list built")
    wrap_function(norns.enc, "accel", function(n, on) return "encoder " .. n .. " accel " .. tostring(on) end)
    wrap_function(norns.enc, "sens", function(n, sens) return "encoder " .. n .. " sens " .. sens end)
    local real_set_mode = _menu.set_mode
    setmetatable(_menu, {
      __index = function(_, name) if name == "set_mode" then return real_set_mode end end,
      __newindex = function(self, name, value)
        if name == "set_mode" then real_set_mode = value; observe("menu watched") else rawset(self, name, value) end
      end,
    })
    rawset(_menu, "set_mode", nil)
    local real_metro_init = metro.init
    metro.init = function(...)
      observe("metro created")
      local timer = real_metro_init(...)
      local real_start = timer.start
      function timer.start(self, ...)
        observe(self.event == drift_update and "drift metro started" or "metro started")
        return real_start(self, ...)
      end
      return timer
    end
    local real_poll_set = poll.set
    poll.set = function(name, ...)
      observe("poll set " .. name)
      local entry = real_poll_set(name, ...)
      if entry then wrap_function(entry, "start", "poll started " .. name) end
      return entry
    end
    wrap_function(arc, "connect", "arc connected")
    wrap_function(grid, "connect", "grid connected")
    wrap_function(midi, "connect", "midi connected")
    wrap_global("grid_redraw", "grid redrawn")
    wrap_global("request_redraw", "redraw requested")
    wrap_function(S.lib.data_files, "read", function(path) return "file read " .. path:match("[^/]*$") end)
    wrap_function(clock, "run", "clock started")
    -- "|" marks the start of each registered step
    assert_equal(type(S.register_start), "function", "S.register_start")
    for _, record in ipairs(S.registry.start) do
      local step = record.fn
      record.fn = function(...) table.insert(log, "|"); return step(...) end
    end
  end
  local ok, problem = pcall(load_strata, options)
  assert_true(ok, tostring(problem))

  local START_STEPS = start_steps()
  local expected = { "params added", "param actions wrapped" }
  for _, step in ipairs(START_STEPS) do
    table.insert(expected, "|")
    for _, effect in ipairs(step[2]) do table.insert(expected, effect) end
  end
  assert_equal(table.concat(log, "\n"), table.concat(expected, "\n"), "one registered step per group of effects, in order")
  -- the clocks init started: the start-up clock, then the frame clock
  assert_true(STARTUP.clock ~= nil and local_value("UI_PAGES").frame_clock ~= nil, "both clocks run")
  assert_true(STARTUP.clock < local_value("UI_PAGES").frame_clock, "the start-up clock starts first")
  assert_equal(S.mutation_metro.event, gentle_mutate, "the mutation metro runs gentle_mutate")
  assert_equal(S.mutation_metro.running, false, "and waits for its param")
  assert_equal(S.drift_metro.running, true, "the drift metro runs")
  assert_true(S.scenes_loaded and S.buffers_loaded, "both loads set their flags")
  -- S.constants.START_ORDER names each step's order, and no two steps share one
  local orders = 0
  for _ in pairs(S.constants.START_ORDER) do orders = orders + 1 end
  assert_equal(orders, #START_STEPS, "START_ORDER has one order per step")
  assert_equal(#S.registry.start, #START_STEPS, "one registered step per order")
  assert_true(not pcall(S.register_start, S.constants.START_ORDER.frame_clock, function() end),
    "a second step at a taken order is refused")
  assert_true(not pcall(S.register_start, nil, function() end), "an order is a number")
  assert_true(not pcall(S.register_start, 1000, nil), "a step is a function")
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

-- The engine's SuperCollider files: Engine_Strata.sc and lib/engine/*.sc,
-- as { path = "lib/...", text = source }
local function engine_files()
  local text, files = "\n" .. h.engine_sources(), {}
  local markers = {}
  for start, path, body_start in text:gmatch("\n()// file: (%S+)\n()") do markers[#markers + 1] = { start, path, body_start } end
  for index, marker in ipairs(markers) do
    local finish = markers[index + 1] and (markers[index + 1][1] - 1) or #text
    files[#files + 1] = { path = marker[2], text = text:sub(marker[3], finish) }
  end
  return files
end

-- The top-level blocks of SuperCollider source (a class or a class
-- extension), each with the methods defined directly inside it:
-- { head = "Engine_Strata : CroneEngine", methods = { { name = "*new", body = "{...}" }, ... } }.
-- Comments are stripped first; strings, symbols and $x characters are skipped.
local function sc_blocks(source)
  source = stubs.strip_sc_comments(source)
  local blocks, depth, cursor, block, start_of_head = {}, 0, 1, nil, 1
  local method_start, method_name
  while cursor <= #source do
    local char = source:sub(cursor, cursor)
    if char == '"' or char == "'" then
      cursor = cursor + 1
      while cursor <= #source and source:sub(cursor, cursor) ~= char do
        cursor = cursor + (source:sub(cursor, cursor) == "\\" and 2 or 1)
      end
    elseif char == "$" then
      cursor = cursor + (source:sub(cursor + 1, cursor + 1) == "\\" and 2 or 1)
    elseif char == "{" then
      if depth == 0 then
        block = { head = source:sub(start_of_head, cursor - 1):match("([^;{}]-)%s*$"):match("^%s*(.-)$"), methods = {} }
        table.insert(blocks, block)
      elseif depth == 1 then
        method_name = source:sub(1, cursor - 1):match("(%*?[%a_][%w_]*)%s*$")
        method_start = cursor
      end
      depth = depth + 1
    elseif char == "}" then
      depth = depth - 1
      if depth == 1 and method_start then
        table.insert(block.methods, { name = method_name, body = source:sub(method_start, cursor) })
        method_start = nil
      elseif depth == 0 then
        start_of_head = cursor + 1
      end
    end
    cursor = cursor + 1
  end
  return blocks
end

test("Engine_Strata.sc defines only *new, alloc and free", function()
  local files = engine_files()
  assert_equal(files[1].path, "lib/Engine_Strata.sc")
  local blocks = sc_blocks(files[1].text)
  assert_equal(#blocks, 1, "one class")
  assert_equal(blocks[1].head, "Engine_Strata : CroneEngine", "the class")
  local names = {}
  for _, method in ipairs(blocks[1].methods) do names[#names + 1] = method.name end
  assert_equal(table.concat(names, " "), "*new alloc free", "its methods")
  -- the parser sees a method in a class extension too
  local probe = sc_blocks('+ Engine_Strata {\n    a { ^"}" }\n    b { arg x; ^{ x } }\n}\n')
  assert_equal(probe[1].head, "+ Engine_Strata", "an extension's head")
  assert_equal(#probe[1].methods, 2, "both methods, nested braces and strings skipped")
end)

-- The variables Engine_Strata.sc declares at class level (before *new):
-- every var and classvar statement's names, comments stripped
local function engine_class_variables(text)
  local head = stubs.strip_sc_comments(text)
  head = head:sub(1, (head:find("%*new") or (#head + 1)) - 1)
  local names = {}
  for _, keyword in ipairs({ "classvar", "var" }) do
    for statement in head:gmatch("%f[%w_]" .. keyword .. "%s+([^;]+);") do
      statement = statement:gsub("=[^,]*", "")
      for name in statement:gmatch("[<>]*%s*([%a_][%w_]*)") do names[#names + 1] = name end
    end
  end
  return names
end

-- A variable nothing reads is a leftover (pitchShiftWindow outlived the
-- PitchShift stage 3.2 removed, #151): every class-level variable is named
-- again somewhere in the engine's code
test("every variable Engine_Strata.sc declares is used in the engine's code", function()
  local files = engine_files()
  local code = {}
  for _, file in ipairs(files) do code[#code + 1] = stubs.strip_sc_comments(file.text) end
  code = table.concat(code, "\n")
  local function uses(name)
    local count = 0
    for _ in code:gmatch("%f[%w_]" .. name .. "%f[^%w_]") do count = count + 1 end
    return count
  end
  local names = engine_class_variables(files[1].text)
  assert_true(#names > 50, "the class variables are found (" .. #names .. ")")
  local unused = {}
  for _, name in ipairs(names) do
    if uses(name) < 2 then unused[#unused + 1] = name end
  end
  assert_true(#unused == 0, "declared but never used: " .. table.concat(unused, ", "))
  -- the scan sees a variable declared and never used
  local probe = engine_class_variables("Engine_Strata : CroneEngine {\n    classvar <>a;\n    var <b = 1, c;  // x\n    *new { var d; }\n}")
  assert_equal(table.concat(probe, " "), "a b c", "classvar and var names, not a method's locals")
end)

-- The engine areas and their orders (the 3.2 design, §0)
local ENGINE_AREAS = { performance = 10, voices = 20, grains = 30, buffers = 40, files = 50, effects = 60, rings = 70,
  scale = 80, variation = 90, loop = 100, freeze = 110, mix = 120, record = 130, waveform = 140, positions = 150,
  modulation = 160, notes = 170 }

test("every engine file is named Strata*.sc and defines each strataArea method once", function()
  local files, areas, orders = engine_files(), {}, {}
  assert_true(#files > 1, "lib/engine holds the engine's areas")
  for index = 2, #files do
    local path = files[index].path
    assert_true(path:match("^lib/engine/Strata%u[%w]*%.sc$"), path .. " is named lib/engine/Strata<Name>.sc")
    for _, block in ipairs(sc_blocks(files[index].text)) do
      local class = block.head:match("^%+%s*([%w_]+)$") or block.head:match("^([%w_]+)")
      assert_true(class == "Engine_Strata" or block.head:match("^Strata"),
        path .. ": an extension of Engine_Strata or a Strata* class, not " .. block.head)
      for _, method in ipairs(block.methods) do
        local area = method.name:match("^strataArea(%u[%w_]*)$")
        if area then
          area = area:sub(1, 1):lower() .. area:sub(2)
          assert_true(areas[area] == nil, "strataArea" .. method.name:sub(11) .. " is defined in " .. tostring(areas[area]) .. " and " .. path)
          areas[area] = path
          local order = tonumber(method.body:match("order:%s*(%d+)"))
          assert_true(order ~= nil, method.name .. " has an order")
          assert_true(orders[order] == nil, method.name .. " shares order " .. tostring(order) .. " with " .. tostring(orders[order]))
          orders[order] = method.name
          assert_true(ENGINE_AREAS[area] ~= nil, method.name .. " is in ENGINE_AREAS (the table pins every area's order, #492)")
          if ENGINE_AREAS[area] then assert_equal(order, ENGINE_AREAS[area], method.name .. "'s order") end
        end
      end
    end
  end
  for area in pairs(ENGINE_AREAS) do assert_true(areas[area], "the " .. area .. " area is registered") end
  -- Engine_Strata.sc registers no area of its own
  for _, block in ipairs(sc_blocks(files[1].text)) do
    for _, method in ipairs(block.methods) do assert_true(not method.name:match("^strataArea"), "no area in Engine_Strata.sc") end
  end
end)

-- norns compiles every .sc under ~/dust (#332): a class file anywhere else
-- in the repository would load on the device. Only the engine's files may
-- be .sc; the runner's test classes are .sc.in.
local function stray_sc_files(paths)
  local stray = {}
  for _, path in ipairs(paths) do
    if path:match("%.sc$") and path ~= "lib/Engine_Strata.sc" and not path:match("^lib/engine/Strata%u[%w]*%.sc$") then
      stray[#stray + 1] = path
    end
  end
  return stray
end

test("no .sc file is tracked outside the engine's files (#332)", function()
  local planted = stray_sc_files({ "lib/Engine_Strata.sc", "lib/engine/StrataMix.sc", "test/StrataTestNoBoot.sc",
    "docs/StrayClass.sc", "lib/engine/helper.sc", "test/StrataTestNoBoot.sc.in" })
  assert_equal(table.concat(planted, " "), "test/StrataTestNoBoot.sc docs/StrayClass.sc lib/engine/helper.sc", "the scan names the strays")
  local paths = {}
  local listing = assert(io.popen("cd '" .. repo_root .. "' && git ls-files"))
  for path in listing:lines() do paths[#paths + 1] = path end
  listing:close()
  assert_true(#paths > 100, "git ls-files listed the repository")
  local stray = stray_sc_files(paths)
  assert_equal(#stray, 0, "norns would compile: " .. table.concat(stray, ", "))
  local file = assert(io.open(repo_root .. "/.gitignore", "r")); local ignore = file:read("*a"); file:close()
  assert_true(ignore:find("test/**/*.sc", 1, true) ~= nil, ".gitignore keeps a generated copy of a test class out of a commit")
end)

-- A LocalBuf built into a SynthDef corrupts sclang 3.13's garbage collector
-- (norns runs 3.13), which crashes sclang a little later (an assertion in
-- its collector). Engine SynthDefs take server buffers as controls instead.
local function uses_local_buf(text)
  return stubs.strip_sc_comments(text):match("%f[%w_]LocalBuf%f[^%w_]") ~= nil
end

test("no engine SynthDef uses LocalBuf (it crashes sclang 3.13)", function()
  assert_true(uses_local_buf("var chain = FFT(LocalBuf(2048), in);"), "caught: LocalBuf(2048)")
  assert_true(uses_local_buf("var b = LocalBuf.new(8);"), "caught: LocalBuf.new")
  assert_true(not uses_local_buf("// never a LocalBuf here\nvar x = 1; /* LocalBuf */"), "comments are skipped")
  assert_true(not uses_local_buf("var myLocalBufs = 1; var LocalBuffer = 2;"), "other names are not LocalBuf")
  for _, file in ipairs(engine_files()) do
    assert_true(not uses_local_buf(file.text), file.path .. " uses no LocalBuf")
  end
end)

-- Reusing a FloatArray across SoundFile readData calls makes sclang 3.13
-- (norns) abort in its garbage collector (#131): every readData in the
-- engine reads into an array freshReadArray made for it, in the same
-- statement or the line before
local function stale_reads(text)
  local stale, previous = {}, ""
  for line in (stubs.strip_sc_comments(text) .. "\n"):gmatch("([^\n]*)\n") do
    for target in line:gmatch("%.readData%(%s*([%w_]+)%s*%)") do
      local fresh = target .. "%s*=%s*this%.freshReadArray%("
      if not (line:match(fresh) or previous:match(fresh)) then table.insert(stale, target .. ": " .. line) end
    end
    previous = line
  end
  return stale
end

test("every engine readData reads into a fresh array (#131)", function()
  assert_equal(#stale_reads("chunk = this.freshReadArray(8);\nfile.readData(chunk);"), 0, "allowed: fresh on the line before")
  assert_equal(#stale_reads("while { a = this.freshReadArray(8); f.readData(a); a.size > 0 } { }"), 0, "allowed: the same statement")
  assert_equal(#stale_reads("chunk = FloatArray.newClear(8);\nwhile { true } {\nfile.readData(chunk);\n}"), 1, "caught: reused")
  assert_equal(#stale_reads("file.readData(data); // this.freshReadArray("), 1, "caught: a comment is not an allocation")
  local total = 0
  for _, file in ipairs(engine_files()) do
    local stale = stale_reads(file.text)
    assert_equal(#stale, 0, file.path .. ": " .. table.concat(stale, "; "))
    for _ in stubs.strip_sc_comments(file.text):gmatch("%.readData%(") do total = total + 1 end
  end
  assert_true(total >= 3, "the engine's reads are found (" .. total .. ")")
end)

-- A per-sample sclang loop (a function called per sample or frame) piles
-- up work for sclang's garbage collector until it fails (#131): the
-- engine's sample paths use C primitives only. The body of method `name`
-- in SC source (comments stripped), without its braces and its own
-- argument list, or nil
local function sc_method_body(text, name)
  local stripped = stubs.strip_sc_comments(text)
  local start = stripped:find("\n%s*" .. name .. "%s*{")
  if not start then return nil end
  local body = stripped:match("%b{}", start)
  body = body:sub(2, -2)
  return (body:gsub("^%s*arg%s[^;]*;", "", 1))
end

-- The per-sample iteration a piece of SC code holds: a function literal with
-- arguments or an iterating call
local function per_sample_loops(code)
  local found = {}
  for _, pattern in ipairs({ "{%s*arg%s", "{%s*|", "%.do%s*%(", "%.collect%s*%(", "%.fill%s*%(", "%.select%s*%(",
    "%.reject%s*%(", "%.every%s*%(", "%.any%s*%(", "%.inject%s*%(", "%.sum%s*%(", "%.do%s*{", "%.collect%s*{" }) do
    if code:find(pattern) then table.insert(found, pattern) end
  end
  return found
end

-- #211: sclang 3.13 and 3.14.1 free a function's frame as it returns, but a
-- method frame a kept closure holds keeps its caller pointing at that freed
-- frame, and once the collector's colors come round its scan revives dead
-- objects and can corrupt a free list (the collector's count error, crashes, hangs). So
-- a method whose frame outlives its call is called through areaCall (a
-- method frame, which clears its own caller): every area hook, strataAreas,
-- and every call of a method in AREA_CALL_METHODS (docs/notes/engine/structure.md).
local AREA_HOOKS = { "allocState", "addDefs", "addCommands", "start", "stop", "free" }
-- methods that keep a closure and are called from a function (a SynthDef
-- function, an onFree, a fork, a scheduled function, a makeBundle
-- function, a command function): never called but through areaCall. Each
-- is defined and called through areaCall at least once. The last six are
-- the commands' (loadBuffer, clearBuffer, saveBuffer, recordBuffer,
-- stopRecord, setBypass)
local AREA_CALL_METHODS = { "ringGrainReader", "slotGrainReader", "recordSynthFreed", "inputHeadFrame", "gateVoice",
  "voiceSynthFreed", "prepareTake", "startFastLfo", "watchFastLfo",
  "loadSlot", "clearSlot", "saveSlot", "recordSlot", "stopRecordSlot", "setEffectBypass" }
-- the calls that hand a function to something that runs it later (the
-- class library's and the engine's own): a method that makes one keeps its
-- frame past its return
-- (class-library names only, #680: getn's action in readSlotPeaks and
-- shrinkSlotPeaks, unixCmd's in the waveform area's mover, addDependant's
-- `confirm` in watchStart. An engine method such as afterSlotFade, writeSlot,
-- renameIntoPlace, readSlotPeaks or watchVoiceSynth is marked from its own
-- body, never by name: a name here would also match the symbol in
-- this.areaCall(\writeSlot, ...). A `get` is one only with a function
-- argument, see frame_guard.deferring_names; the engine has none today.) A
-- method that calls any of these, or an engine method that does, through any
-- chain of direct calls, is one that hands a function on
-- (frame_guard.deferring_methods)
local DEFERRING_CALLS = { "sched", "fork", "onFree", "OSCFunc", "OSCdef", "Routine", "defer", "getn", "unixCmd",
  "addDependant" }

-- SC source with its comments stripped and the text of its strings, quoted
-- symbols and characters blanked, so a brace inside one never ends a %b{}
-- match (a hook holds none today; this keeps it so)
local function sc_code_only(text)
  local code, out, index = stubs.strip_sc_comments(text), {}, 1
  while index <= #code do
    local char = code:sub(index, index)
    if char == '"' or char == "'" then
      local finish = index + 1
      while finish <= #code and code:sub(finish, finish) ~= char do
        finish = finish + (code:sub(finish, finish) == "\\" and 2 or 1)
      end
      out[#out + 1] = char .. code:sub(index + 1, finish - 1):gsub("[^\n]", " ") .. char
      index = finish + 1
    elseif char == "$" then
      local width = code:sub(index + 1, index + 1) == "\\" and 2 or 1
      out[#out + 1] = "$" .. string.rep(" ", width)
      index = index + 1 + width
    else
      out[#out + 1] = char
      index = index + 1
    end
  end
  return table.concat(out)
end

-- The calls of methods on `this` that do not go through areaCall in an
-- engine file's area hooks (in each strataArea<Name> method), and anywhere
-- of a method in AREA_CALL_METHODS: { "path:line: ..." }
local function direct_calls(path, text)
  local code, found = sc_code_only(text), {}
  local function line_of(position)
    local _, newlines = code:sub(1, position):gsub("\n", "")
    return newlines + 1
  end
  local function report(position, what) found[#found + 1] = string.format("%s:%d: %s", path, line_of(position), what) end
  for area_start, area in code:gmatch("()(strataArea%u[%w_]*)%s*{") do
    local body_start = code:find("{", area_start, true)
    local body = code:match("%b{}", body_start)
    for _, hook in ipairs(AREA_HOOKS) do
      local search = 1
      while true do
        local start, finish = body:find("%f[%w_]" .. hook .. ":%s*", search)
        if not start then break end
        local hook_body = body:match("^%b{}", finish + 1)
        if hook_body then
          for offset, name, after in hook_body:gmatch("()this%.([%a_][%w_]*)(.?.?)") do
            local position = body_start + finish + offset - 1
            if name ~= "areaCall" then
              report(position, area .. "'s " .. hook .. " hook calls this." .. name .. " directly, not through this.areaCall(\\" .. name .. ")")
            elseif after ~= "(\\" then
              report(position, area .. "'s " .. hook .. " hook calls areaCall without a method's symbol")
            end
          end
        end
        search = finish + 1
      end
    end
  end
  for _, name in ipairs(AREA_CALL_METHODS) do
    for position in code:gmatch("()%f[%w_]this%." .. name .. "%f[^%w_]") do
      report(position, "this." .. name .. " is called directly, not through this.areaCall(\\" .. name .. ", ...)")
    end
  end
  return found
end

test("an area hook, strataAreas and a method that keeps a closure are called through areaCall (#211)", function()
  local probe = direct_calls("probe.sc", "+ Engine_Strata {\n    strataAreaProbe {\n        ^(order: 1,\n"
    .. "            addDefs: { this.addProbeDefs; [] },  // not this.areaCall\n"
    .. "            start: { this.areaCall(\\startProbe) },\n"
    .. "            stop: { areaState[\\probe][\\stopped] = true; this.areaCall(\\stopProbe) },\n"
    .. "            free: { this.areaCall(selector) })\n    }\n"
    .. "    defs { SynthDef(\\p, { this.grainBody(c, this.ringGrainReader(1)) }).add }\n}\n")
  assert_equal(#probe, 3, "the probe's three direct calls: " .. table.concat(probe, "; "))
  assert_true(probe[1] and probe[1]:match("^probe%.sc:4: strataAreaProbe's addDefs hook calls this%.addProbeDefs directly"),
    "names the file, the line, the area, the hook and the method: " .. tostring(probe[1]))
  assert_true(probe[2] and probe[2]:match("^probe%.sc:7: strataAreaProbe's free hook calls areaCall without a method's symbol"),
    "an areaCall must name the method: " .. tostring(probe[2]))
  assert_true(probe[3] and probe[3]:match("^probe%.sc:9: this%.ringGrainReader is called directly"), "and a kept closure's method: " .. tostring(probe[3]))

  local found, hooks, files = {}, 0, engine_files()
  for index = 2, #files do
    local file = files[index]
    for _, line in ipairs(direct_calls(file.path, file.text)) do found[#found + 1] = line end
    for _, hook in ipairs(AREA_HOOKS) do
      for _ in stubs.strip_sc_comments(file.text):gmatch("%f[%w_]" .. hook .. ":%s*{%s*[^}]*this%.areaCall%(") do hooks = hooks + 1 end
    end
  end
  assert_true(#found == 0, table.concat(found, "\n"))
  assert_true(hooks >= 50, "the areas' hooks are found and go through areaCall (" .. hooks .. ")")
  -- each listed method is the engine's and is called through areaCall
  local all = {}
  for index = 2, #files do all[#all + 1] = sc_code_only(files[index].text) end
  all = table.concat(all, "\n")
  for _, name in ipairs(AREA_CALL_METHODS) do
    assert_true(all:match("\n    " .. name .. "%s*{") ~= nil, name .. " is an engine method (lib/engine/Strata*.sc)")
    assert_true(all:match("this%.areaCall%(\\" .. name .. "[,)]") ~= nil, name .. " is called through this.areaCall(\\" .. name .. ", ...)")
  end
  -- a brace in a string or a character never ends a hook's match
  assert_equal(#direct_calls("probe.sc", '+ Engine_Strata {\n    strataAreaQuoted {\n        ^(order: 1, start: { "}"; $}; this.startQuoted })\n    }\n}\n'), 1,
    "a quoted brace inside a hook does not end it")

  -- strataAreas reaches each strataArea<Name> through areaCall, and
  -- areaCall itself never makes it a tail call (^this.performList would
  -- give the method the caller of areaCall again)
  local util
  for _, file in ipairs(files) do if file.path == "lib/engine/StrataUtil.sc" then util = file.text end end
  local areas_body = sc_method_body(util, "strataAreas") or ""
  assert_true(areas_body:match("this%.areaCall%(method%.name%)") and not areas_body:match("this%.perform%("),
    "lib/engine/StrataUtil.sc: strataAreas calls each area's method through this.areaCall(method.name)")
  local call_body = sc_method_body(util, "areaCall") or ""
  assert_true(call_body:match("result%s*=%s*this%.performList%(selector,%s*args%)") and call_body:match("%^%s*result%s*$"),
    "lib/engine/StrataUtil.sc: areaCall assigns the method's result and then returns it (never ^this.performList)")
end)

-- The direct calls (this.<method>, with or without arguments, not through
-- areaCall) that a function sclang keeps and calls later makes of an engine
-- method that hands a function on, in files { { path, text } }:
-- { "path:line: ..." }. The functions are the commands' (addCommand), the
-- area Events' grainParamHandlers (the Event's entries and any
-- grainParamHandlers[\name] = { ... } an area adds) and grainDefs.
-- #211: such a method's frame outlives the call, and its caller is the
-- function's frame, freed as it returns, or, tail-called, the frame that
-- called the function: on norns the OSC dispatcher's, in the engine check a
-- function's. Through areaCall it is a live frame either way. A method
-- hands a function on when its body holds a DEFERRING_CALLS name or it calls,
-- anywhere (a tail call too), an engine method that does (#680); the
-- methods are the ones the engine's class and extensions define, so a
-- this.name that is a variable's getter is never one.
local frame_guard = {}

-- DEFERRING_CALLS names a piece of code (comments, strings blanked) holds;
-- a symbol (\fork) is not a call
function frame_guard.deferring_names(code)
  local names = {}
  code = code:gsub("\\[%a_][%w_]*", function(symbol) return (" "):rep(#symbol) end)
  for _, call in ipairs(DEFERRING_CALLS) do
    if code:find("%f[%w_]" .. call .. "%f[^%w_]") then names[#names + 1] = call end
  end
  for arguments in code:gmatch("%.get%s*(%b())") do
    if arguments:find("{") then names[#names + 1] = "get"; break end
  end
  return names
end

-- The engine's methods { name = body code } of the files (the class and its
-- extensions: the helper classes' are not called on this)
function frame_guard.engine_methods(files)
  local methods = {}
  for _, file in ipairs(files) do
    for _, block in ipairs(sc_blocks(file.text)) do
      if block.head:find("Engine_Strata", 1, true) then
        for _, method in ipairs(block.methods) do methods[(method.name:gsub("^%*", ""))] = sc_code_only(method.body) end
      end
    end
  end
  return methods
end

-- Every this.<name> a piece of code holds, with or without arguments:
-- { { name, offset } }
function frame_guard.this_calls(code)
  local calls = {}
  for offset, name in code:gmatch("()%f[%w_]this%.([%a_][%w_]*)%f[^%w_]") do calls[#calls + 1] = { name = name, offset = offset } end
  return calls
end

-- { method = chain } for each method that hands a function on: the chain is
-- "method -> next -> ... -> the deferring call", by a fixed point over the
-- direct calls (through areaCall a call is not one: its callee's frame is
-- live)
function frame_guard.deferring_methods(methods)
  local chains, changed = {}, true
  for name, body in pairs(methods) do
    local names = frame_guard.deferring_names(body)
    if #names > 0 then chains[name] = name .. " -> " .. names[1] end
  end
  while changed do
    changed = false
    for name, body in pairs(methods) do
      if not chains[name] then
        for _, call in ipairs(frame_guard.this_calls(body)) do
          if call.name ~= "areaCall" and call.name ~= name and chains[call.name] then
            chains[name] = name .. " -> " .. chains[call.name]
            changed = true
            break
          end
        end
      end
    end
  end
  return chains
end

-- The functions of a file's code that are kept and called later:
-- { { label, key, open (the offset of its brace), body } }
function frame_guard.kept_functions(code)
  local found = {}
  for command, open in code:gmatch('addCommand%(%s*\\([%w_]+)%s*,%s*"[^"]*"%s*,%s*(){') do
    found[#found + 1] = { label = command .. "'s command", key = command, open = open, body = code:match("^%b{}", open) }
  end
  for area_start in code:gmatch("()grainParamHandlers:%s*%(") do
    local event_start = code:find("(", area_start, true)
    local event = code:match("^%b()", event_start)
    for key, open in event:gmatch("%f[%w_]([%a_][%w_]*):%s*(){") do
      found[#found + 1] = { label = key .. "'s grain param handler", key = key, open = event_start + open - 1,
        body = event:match("^%b{}", open) }
    end
  end
  for key, open in code:gmatch("grainParamHandlers%[\\([%w_]+)%]%s*=%s*(){") do
    found[#found + 1] = { label = key .. "'s grain param handler", key = key, open = open, body = code:match("^%b{}", open) }
  end
  for list_start in code:gmatch("grainDefs:%s*()%[") do
    found[#found + 1] = { label = "a grainDefs function", key = "grainDefs", open = list_start, body = code:match("^%b[]", list_start) }
  end
  return found
end

local function kept_functions_deferring(files)
  local code, found = {}, {}
  for _, file in ipairs(files) do code[#code + 1] = { path = file.path, text = sc_code_only(file.text) } end
  local chains = frame_guard.deferring_methods(frame_guard.engine_methods(files))
  for _, file in ipairs(code) do
    for _, fn in ipairs(frame_guard.kept_functions(file.text)) do
      for _, call in ipairs(frame_guard.this_calls(fn.body)) do
        local chain = call.name ~= "areaCall" and chains[call.name]
        if chain then
          local _, newlines = file.text:sub(1, fn.open + call.offset - 1):gsub("\n", "")
          found[#found + 1] = string.format("%s:%d: %s calls this.%s directly, and %s hands a function to %s (%s):"
            .. " call it through this.areaCall(\\%s, ...) (docs/notes/engine/structure.md, Areas)",
            file.path, newlines + 1, fn.label, call.name, call.name, chain:match("([%w_]+)$"), chain, call.name)
        end
      end
    end
  end
  return found
end

test("a command calls a method that hands a function on only through areaCall (#211)", function()
  local probe = { { path = "probe.sc", text = '+ Engine_Strata {\n    addProbeCommands {\n'
    .. '        this.addCommand(\\probeLater, "i", { arg msg; this.validProbe(msg[1]); this.probeLater(msg[1]); });\n'
    .. '        this.addCommand(\\probeCalled, "i", { arg msg; this.areaCall(\\probeLater, msg[1]); });\n'
    .. '        this.addCommand(\\probeFork, "i", { arg msg; if (msg[1] > 0) { this.probeFork(msg[1]) }; });\n    }\n'
    .. '    validProbe { arg x; ^x.notNil }\n'
    .. '    probeLater { arg x; SystemClock.sched(1, { x.postln; nil }) }\n'
    .. '    probeFork { arg x; fork { x.postln } }\n}\n' } }
  local found = kept_functions_deferring(probe)
  assert_equal(#found, 2, "the probe's two direct calls: " .. table.concat(found, "; "))
  assert_true(found[1] and found[1]:match("^probe%.sc:3: probeLater's command calls this%.probeLater directly, and probeLater hands a function to sched"),
    "names the file, the line, the command, the method and the call: " .. tostring(found[1]))
  assert_true(found[2] and found[2]:match("^probe%.sc:5: probeFork's command calls this%.probeFork directly.* to fork"),
    "inside an if too: " .. tostring(found[2]))

  -- #680 (a): a method that reaches a deferring one by a tail call
  local tail = { { path = "probe.sc", text = '+ Engine_Strata {\n    addProbeCommands {\n'
    .. '        this.addCommand(\\probeTail, "i", { arg msg; this.startProbe(msg[1]); });\n    }\n'
    .. '    startProbe { arg x; ^this.watchProbe(x) }\n'
    .. '    watchProbe { arg x; x.onFree({ x.postln }) }\n}\n' } }
  found = kept_functions_deferring(tail)
  assert_equal(#found, 1, "a tail hop to a deferring method is caught: " .. table.concat(found, "; "))
  -- #680 (b): a call without parentheses
  local bare = { { path = "probe.sc", text = '+ Engine_Strata {\n    addProbeCommands {\n'
    .. '        this.addCommand(\\probeBare, "i", { arg msg; this.probeLater; });\n'
    .. '        this.addCommand(\\probeBareIf, "i", { arg msg; if (msg[1] > 0) { ^this.probeLater }; this.probeValue });\n    }\n'
    .. '    probeValue { ^3 }\n    numProbe { ^numVoices }\n'
    .. '    probeLater { SystemClock.sched(1, { 1.postln; nil }) }\n}\n' } }
  found = kept_functions_deferring(bare)
  assert_equal(#found, 2, "a call with no parentheses is caught, a plain method is not: " .. table.concat(found, "; "))
  -- #680 (c): a grain param handler
  local handler = { { path = "probe.sc", text = '+ Engine_Strata {\n    strataAreaProbe {\n        ^(order: 1,\n'
    .. '            grainParamHandlers: (\n                a: { arg voice, value; this.probeLater(voice); true },\n'
    .. '                b: { arg voice, value; this.probeValue(voice); true }\n            )\n        )\n    }\n'
    .. '    probeValue { arg x; ^x }\n    probeLater { arg x; x.fork }\n}\n' } }
  found = kept_functions_deferring(handler)
  assert_equal(#found, 1, "a grain param handler's direct call is caught: " .. table.concat(found, "; "))

  local files = engine_files()
  table.remove(files, 1)
  found = kept_functions_deferring(files)
  assert_true(#found == 0, table.concat(found, "\n"))
  -- the guard sees the engine's commands and the methods it reads
  local commands = 0
  for _, file in ipairs(files) do
    for _ in sc_code_only(file.text):gmatch('addCommand%(%s*\\[%w_]+%s*,%s*"[^"]*"%s*,%s*{') do commands = commands + 1 end
  end
  assert_true(commands >= 30, "the engine's command functions are found (" .. commands .. ")")
  local chains, deferring = frame_guard.deferring_methods(frame_guard.engine_methods(files)), 0
  for _ in pairs(chains) do deferring = deferring + 1 end
  -- the engine's own methods that keep a function or an action are marked from their bodies, not by name
  for _, name in ipairs({ "afterSlotFade", "writeSlot", "writeSlotPeaks", "renameIntoPlace", "readSlotPeaks",
    "shrinkSlotPeaks", "watchVoiceSynth", "watchNoteSynth", "watchStart" }) do
    assert_true(chains[name] ~= nil, name .. " hands a function on (fixed point)")
  end
  -- a symbol is not a call (#680): only the method that calls fork is marked
  local symbol_chains = frame_guard.deferring_methods(frame_guard.engine_methods({ { path = "probe.sc", text =
    '+ Engine_Strata {\n    named { this.areaCall(\\fork, 1); ^\\onFree }\n    calls { arg x; x.fork({ 1 }) }\n}\n' } }))
  assert_true(symbol_chains.named == nil and symbol_chains.calls ~= nil, "a symbol \\fork marks no method, a call does")
  assert_true(deferring >= 20 and chains.startVoiceSynth and chains.startVoiceSynth:find("watchVoiceSynth", 1, true),
    "the fixed point finds the methods that hand a function on, startVoiceSynth through its tail call (" .. deferring .. ")")
end)

-- #689: every function literal of the engine's methods, wherever it is (an
-- onFree, sched, fork, Routine, makeBundle, do or collect function, a reply
-- or an action, a function stored in an Event or a variable, a command, a
-- grain param handler, a SynthDef function, one nested in another), is
-- scanned as the commands are: a direct call in it of a method that hands a
-- function on is a failure. A block sclang inlines is no function: its code
-- is the enclosing method's or function's. Which blocks it inlines is read
-- from the compiler, lang/LangSource/PyrParseNode.cpp, identical in 3.13.0
-- and 3.14.1 for these: conjureSelectorIndex gives the selectors if, while,
-- and, or, case, switch, loop, ?, ?? and !?; compileAnyIfMsg, compileIfMsg
-- and compileIfNilMsg inline an if's one block, or its two only if both
-- inline; compileWhileMsg a while's one block, or its two (the first may be
-- a literal true, isWhileTrue); compileLoopMsg a loop's one block;
-- compileAndMsg, compileOrMsg, compileQQMsg and compileXQMsg the block
-- after and, or, ?? and !?; compileCaseMsg every block of a case or none;
-- compileSwitchMsg every block of a switch whose tests are all atomic
-- literals (isAtomicLiteral, isAnInlineableAtomicLiteralBlock) or none;
-- compileQMsg (?) inlines nothing. isAnInlineableBlock: only a literal block
-- that declares no arg and no var inlines. PyrCallNode::compileCall inlines
-- nothing in a call with a keyword argument, or with more than 15 arguments
-- but for case and switch.

-- The first character at or after index that is not a space, the last at
-- or before it
function frame_guard.skip_space(code, index) return code:find("[^%s]", index) or (#code + 1) end
function frame_guard.back_space(code, index)
  while index > 0 and code:sub(index, index):match("%s") do index = index - 1 end
  return index
end
-- The name (a method's, with its * if it has one) that ends at or before
-- index, or nil
function frame_guard.word_before(code, index)
  local last = frame_guard.back_space(code, index)
  local first = last
  while first > 0 and code:sub(first, first):match("[%w_%*]") do first = first - 1 end
  return code:sub(first + 1, last):match("^%*?[%a_][%w_]*$")
end

-- The brackets of code (comments stripped, strings blanked): { pairs =
-- { [open] = close }, opens = { [close] = open }, parent = { [open] = the
-- innermost bracket around it }, depth = { [brace] = braces around it } }
function frame_guard.brackets(code)
  local found, stack, braces = { pairs = {}, opens = {}, parent = {}, depth = {} }, {}, 0
  for index, char in code:gmatch("()([%{%}%(%)%[%]])") do
    if char == "{" or char == "(" or char == "[" then
      found.parent[index] = stack[#stack]
      stack[#stack + 1] = index
      if char == "{" then found.depth[index], braces = braces, braces + 1 end
    else
      local open = table.remove(stack)
      if open then found.pairs[open], found.opens[index] = index, open end
      if char == "}" then braces = braces - 1 end
    end
  end
  return found
end

-- An atomic literal (isAtomicLiteral): a number, a symbol, a character,
-- nil, true or false
function frame_guard.atomic(text)
  for _, pattern in ipairs({ "^%-?%d[%w%.]*$", "^\\[%a_][%w_]*$", "^'%s*'$", "^'[^']*'$", "^%$$", "^nil$", "^true$", "^false$" }) do
    if text:match(pattern) then return true end
  end
  return false
end

-- One argument of a call, from first to last: { kind = "block" (with
-- open, declares: an arg or a var, body: its trimmed text), "keyword",
-- "atomic" or "other" }
function frame_guard.argument(code, first, last, brackets)
  first, last = frame_guard.skip_space(code, first), frame_guard.back_space(code, last)
  local text = code:sub(first, last)
  if code:sub(first, first) == "{" and brackets.pairs[first] == last then
    local inner = code:sub(first + 1, last - 1)
    return { kind = "block", open = first, body = inner:match("^%s*(.-)%s*$"),
      declares = (inner:match("^%s*arg%f[^%w_]") or inner:match("^%s*var%f[^%w_]") or inner:match("^%s*|")) ~= nil }
  end
  if text:match("^[%a_][%w_]*%s*:%f[^:]") then return { kind = "keyword" } end
  return { kind = frame_guard.atomic(text) and "atomic" or "other", body = text }
end

-- The arguments of a paren group at open, added to list
function frame_guard.paren_arguments(code, open, brackets, list)
  local close = brackets.pairs[open]
  if code:sub(open + 1, close - 1):match("^%s*$") then return end
  local start, index = open + 1, open + 1
  while index < close do
    local char = code:sub(index, index)
    if (char == "(" or char == "[" or char == "{") and brackets.pairs[index] then
      index = brackets.pairs[index] + 1
    else
      if char == "," then
        list[#list + 1] = frame_guard.argument(code, start, index - 1, brackets)
        start = index + 1
      end
      index = index + 1
    end
  end
  list[#list + 1] = frame_guard.argument(code, start, close - 1, brackets)
end

-- A binary operator's right operand from index: a block only when no
-- message is sent to it ({ ... }.value is a call, not a literal block)
function frame_guard.operand(code, index, brackets)
  index = frame_guard.skip_space(code, index)
  local close = code:sub(index, index) == "{" and brackets.pairs[index]
  if not close then return { kind = "other" } end
  if code:sub(frame_guard.skip_space(code, close + 1), frame_guard.skip_space(code, close + 1)) == "." then return { kind = "other" } end
  return frame_guard.argument(code, index, close, brackets)
end

-- The indexes of a call's arguments sclang inlines, by its selector
function frame_guard.inlines(arg) return arg ~= nil and arg.kind == "block" and not arg.declares end
function frame_guard.while_true(arg)
  return arg.body == "true" and (arg.kind == "atomic" or frame_guard.inlines(arg))
end
frame_guard.INLINED = {
  ["if"] = function(args)
    if #args == 2 and frame_guard.inlines(args[2]) then return { 2 } end
    if #args == 3 and frame_guard.inlines(args[2]) and frame_guard.inlines(args[3]) then return { 2, 3 } end
  end,
  ["while"] = function(args)
    if #args == 1 and frame_guard.inlines(args[1]) then return { 1 } end
    if #args == 2 and (frame_guard.while_true(args[1]) or frame_guard.inlines(args[1])) and frame_guard.inlines(args[2]) then return { 1, 2 } end
  end,
  loop = function(args) if #args == 1 and frame_guard.inlines(args[1]) then return { 1 } end end,
  case = function(args)
    for _, arg in ipairs(args) do if not frame_guard.inlines(arg) then return end end
    local all = {}
    for index = 1, #args do all[index] = index end
    return all
  end,
  switch = function(args)
    if #args < 3 then return end
    local index, all = 2, {}
    while index <= #args do
      if index < #args then
        local test = args[index]
        if not (test.kind == "atomic" or (frame_guard.inlines(test) and frame_guard.atomic(test.body))) then return end
        if not frame_guard.inlines(args[index + 1]) then return end
        all[#all + 1], all[#all + 2], index = index, index + 1, index + 2
      else
        if not frame_guard.inlines(args[index]) then return end
        all[#all + 1], index = index, index + 1
      end
    end
    return all
  end,
}
for _, name in ipairs({ "and", "or", "??", "!?" }) do
  frame_guard.INLINED[name] = function(args) if #args == 2 and frame_guard.inlines(args[2]) then return { 2 } end end
end

-- The receiver of a .selector at dot: a block when it is a bare literal block
function frame_guard.receiver(code, dot, brackets)
  local before = frame_guard.back_space(code, dot - 1)
  local open = code:sub(before, before) == "}" and brackets.opens[before]
  if not open then return { kind = "other" } end
  local ahead = code:sub(frame_guard.back_space(code, open - 1), frame_guard.back_space(code, open - 1))
  if ahead:match("[%w_%)%]%}]") then return { kind = "other" } end
  return frame_guard.argument(code, open, before, brackets)
end

-- The opening braces of the blocks sclang inlines in code: { [open] = true }
function frame_guard.inlined_blocks(code, brackets)
  local inlined = {}
  local function apply(name, args)
    for _, arg in ipairs(args) do if arg.kind == "keyword" then return end end
    if #args > 15 and name ~= "case" and name ~= "switch" then return end
    for _, index in ipairs(frame_guard.INLINED[name](args) or {}) do
      if args[index].kind == "block" then inlined[args[index].open] = true end
    end
  end
  for _, name in ipairs({ "if", "while", "loop", "case", "switch", "and", "or" }) do
    for start, finish in code:gmatch("()%f[%w_]" .. name .. "%f[^%w_]()") do
      local before, next_index = code:sub(start - 1, start - 1), frame_guard.skip_space(code, finish)
      local char, args = code:sub(next_index, next_index), {}
      if before ~= "\\" then
        if before == "." then args[1] = frame_guard.receiver(code, start - 1, brackets) end
        if char == "(" and brackets.pairs[next_index] then
          frame_guard.paren_arguments(code, next_index, brackets, args)
          next_index = frame_guard.skip_space(code, brackets.pairs[next_index] + 1)
          char = code:sub(next_index, next_index)
        end
        while char == "{" and brackets.pairs[next_index] do
          args[#args + 1] = frame_guard.argument(code, next_index, brackets.pairs[next_index], brackets)
          next_index = frame_guard.skip_space(code, brackets.pairs[next_index] + 1)
          char = code:sub(next_index, next_index)
        end
        if #args > (before == "." and 1 or 0) or (before == "." and args[1].kind == "block") then
          apply(name, args)
        elseif (name == "and" or name == "or") and before ~= "." and char == ":" and code:sub(next_index + 1, next_index + 1) ~= ":" then
          apply(name, { { kind = "other" }, frame_guard.operand(code, next_index + 1, brackets) })
        end
      end
    end
  end
  for _, operator in ipairs({ "??", "!?" }) do
    for finish in code:gmatch(operator:gsub("%p", "%%%0") .. "()") do
      apply(operator, { { kind = "other" }, frame_guard.operand(code, finish, brackets) })
    end
  end
  return inlined
end

-- What a function at open is given to, for a report: "given to do",
-- "stored at later", ...
function frame_guard.function_place(code, open, brackets)
  local before = frame_guard.back_space(code, open - 1)
  local char = code:sub(before, before)
  local function word_before(index) return frame_guard.word_before(code, index) end
  if char:match("[%w_]") then return "given to " .. (word_before(before) or "a call") end
  if char == ":" then return "stored at " .. (word_before(before - 1) or "a key") end
  if char == "(" or char == "," then
    local parent = brackets.parent[open]
    local name = parent and code:sub(parent, parent) == "(" and word_before(parent - 1)
    if name then return "given to " .. name end
  end
  if char == "=" then return "assigned" end
  return "in an expression"
end

-- The real function literals of code (comments stripped, strings blanked)
-- inside the engine's methods: { { open, close, method, place } }
function frame_guard.function_literals(code, brackets)
  brackets = brackets or frame_guard.brackets(code)
  local inlined, found, engine_block, method = frame_guard.inlined_blocks(code, brackets), {}, false, nil
  local opens = {}
  for open in pairs(brackets.depth) do opens[#opens + 1] = open end
  table.sort(opens)
  for _, open in ipairs(opens) do
    local depth = brackets.depth[open]
    if depth == 0 then
      engine_block = code:sub(math.max(1, open - 80), open - 1):match("Engine_Strata[^{};]*$") ~= nil
    elseif depth == 1 then
      method = frame_guard.word_before(code, open - 1)
    elseif engine_block and not inlined[open] and brackets.pairs[open] then
      found[#found + 1] = { open = open, close = brackets.pairs[open], method = method, place = frame_guard.function_place(code, open, brackets) }
    end
  end
  -- a partial application is a function too: _.name is { arg x; x.name },
  -- this.name(_, ...) is { arg x; this.name(x, ...) } (one per call)
  local partial_calls = {}
  local function method_at(position)
    local name, best = nil, 0
    for open, depth in pairs(brackets.depth) do
      if depth == 1 and open > best and open < position and position < (brackets.pairs[open] or 0) then
        best, name = open, frame_guard.word_before(code, open - 1)
      end
    end
    return name
  end
  for position in code:gmatch("()%f[%w_]_%f[^%w_]") do
    local method_name = method_at(position)
    local paren = 0
    for open, close in pairs(brackets.pairs) do
      if open < position and position < close and open > paren and code:sub(open, open) == "(" then paren = open end
    end
    local after = code:sub(frame_guard.skip_space(code, position + 1), frame_guard.skip_space(code, position + 1))
    local before = code:sub(frame_guard.back_space(code, position - 1), frame_guard.back_space(code, position - 1))
    if not method_name then
      -- outside the engine's methods
    elseif after == "." then
      found[#found + 1] = { open = position - 1, close = position + 1, method = method_name, place = "made by a partial application (_)" }
    elseif paren > 0 and (before == "(" or before == ",") and not partial_calls[paren] then
      partial_calls[paren] = true
      local start = paren
      while start > 1 and code:sub(start - 1, start - 1):match("[%w_%.%s]") do start = start - 1 end
      found[#found + 1] = { open = start - 1, close = brackets.pairs[paren], method = method_name, place = "made by a partial application (_)" }
    end
  end
  table.sort(found, function(a, b) return a.open < b.open end)
  return found
end

-- Every this.<name> in code with the innermost real function it is in (fn,
-- nil for its method's own code) and, for an areaCall, the method it names
-- (target): { { name, offset, fn, target } }
function frame_guard.function_calls(code)
  local functions, calls = frame_guard.function_literals(code), {}
  for _, call in ipairs(frame_guard.this_calls(code)) do
    for _, fn in ipairs(functions) do
      if fn.open >= call.offset then break end
      if call.offset < fn.close then call.fn = fn end
    end
    if call.name == "areaCall" then call.target = code:match("^this%.areaCall%s*%(%s*\\([%a_][%w_]*)", call.offset) end
    calls[#calls + 1] = call
  end
  return calls
end

-- The direct calls (this.<method>, with or without arguments) of an engine
-- method that hands a function on made from a real function literal of the
-- files: { "path:line: ..." }
function frame_guard.functions_deferring(files)
  local found, chains = {}, frame_guard.deferring_methods(frame_guard.engine_methods(files))
  for _, file in ipairs(files) do
    local code = sc_code_only(file.text)
    for _, call in ipairs(frame_guard.function_calls(code)) do
      local chain = call.fn and call.name ~= "areaCall" and chains[call.name]
      if chain then
        local _, newlines = code:sub(1, call.offset):gsub("\n", "")
        found[#found + 1] = string.format("%s:%d: a function %s in %s calls this.%s directly, and %s hands a function to %s (%s):"
          .. " call it through this.areaCall(\\%s, ...) (docs/notes/engine/structure.md, Areas)",
          file.path, newlines + 1, call.fn.place, call.fn.method or "?", call.name, call.name, chain:match("([%w_]+)$"), chain, call.name)
      end
    end
  end
  return found
end

test("a function the engine keeps or runs calls a method that hands a function on only through areaCall (#689)", function()
  local probe = { { path = "probe.sc", text = '+ Engine_Strata {\n'
    .. '    probeLater { arg x; SystemClock.sched(1, { x.postln; nil }) }\n'
    .. '    probeUses { arg synth;\n'
    .. '        synth.onFree({ this.probeLater(1) });\n'
    .. '        context.server.makeBundle(nil, { this.probeLater(2) });\n'
    .. '        [1, 2].do({ arg each; this.probeLater(each) });\n'
    .. '        areaState[\\probe] = (later: { this.probeLater(3) });\n'
    .. '        synth.onFree({ this.areaCall(\\probeLater, 1) });\n'
    .. '        context.server.makeBundle(nil, { this.areaCall(\\probeLater, 2) });\n'
    .. '        [1, 2].do({ arg each; this.areaCall(\\probeLater, each) });\n'
    .. '        areaState[\\probe] = (later: { this.areaCall(\\probeLater, 3) });\n'
    .. '        this.probeLater(4);\n    }\n}\n' } }
  local found = frame_guard.functions_deferring(probe)
  assert_equal(#found, 4, "the probe's four direct calls from functions: " .. table.concat(found, "; "))
  for index, line in ipairs({ 4, 5, 6, 7 }) do
    local report = found[index] or ""
    assert_true(report:match("^probe%.sc:" .. line .. ": ") and report:find("calls this.probeLater directly", 1, true)
      and report:find("this.areaCall(\\probeLater, ...)", 1, true),
      "names the file, the line " .. line .. ", the method and the fix: " .. report)
  end
end)

test("an inlined block is its method's own code, a block with a var or inside a function is not (#689)", function()
  local probe = { { path = "probe.sc", text = '+ Engine_Strata {\n'
    .. '    probeLater { arg x; x.fork }\n'
    .. '    probeInline { arg x;\n'
    .. '        if (x) { this.probeLater(1) } { this.probeLater(0) };\n'
    .. '        while { x.notNil } { this.probeLater(2); x = nil };\n'
    .. '        case { x == 1 } { this.probeLater(3) } { true } { this.probeLater(4) };\n'
    .. '        switch (x) { \\a } { this.probeLater(5) } { this.probeLater(6) };\n'
    .. '        x ?? { this.probeLater(7) }; (x > 0) and: { this.probeLater(8) }; loop { this.probeLater(9) };\n'
    .. '        if (x) { var y = 1; this.probeLater(y) };\n'
    .. '        [1].do({ arg each; if (each > 0) { this.probeLater(each) } });\n'
    .. '        x !? { arg y; this.probeLater(y) };\n'
    .. '    }\n}\n' } }
  local found = frame_guard.functions_deferring(probe)
  assert_equal(#found, 3, "a block with a var, one inside a function and one with an arg: " .. table.concat(found, "; "))
  for index, line in ipairs({ 9, 10, 11 }) do
    assert_true((found[index] or ""):match("^probe%.sc:" .. line .. ": "), "line " .. line .. ": " .. tostring(found[index]))
  end
  -- an if whose other block declares a var is inlined in neither block
  -- (compileIfMsg inlines both or none), a case or a switch likewise
  local mixed = { { path = "probe.sc", text = '+ Engine_Strata {\n    probeLater { arg x; x.fork }\n'
    .. '    probeMixed { arg x;\n        if (x) { this.probeLater(1) } { var y; this.probeLater(2) };\n'
    .. '        case { x } { this.probeLater(3) } { var z; z };\n'
    .. '        switch (x) { "s" } { this.probeLater(4) };\n'
    .. '        [1].do(this.probeLater(_)); [1].do(_.probeLater);\n    }\n}\n' } }
  found = frame_guard.functions_deferring(mixed)
  assert_equal(#found, 5, "an if, a case and a switch that cannot be inlined, and a partial application, are functions: "
    .. table.concat(found, "; "))
  assert_true((found[5] or ""):match("^probe%.sc:7: a function made by a partial application %(_%) in probeMixed calls this%.probeLater directly"),
    "a partial application of this.name is a function: " .. tostring(found[5]))
end)

test("a transitively marked method is caught from an engine function (#689)", function()
  local probe = { { path = "probe.sc", text = '+ Engine_Strata {\n'
    .. '    probeLater { arg x; x.onFree({ x.postln }) }\n'
    .. '    probeOuter { arg x; ^this.probeLater(x) }\n'
    .. '    probeForks { arg x; fork { this.probeOuter(x) }; fork { this.areaCall(\\probeOuter, x) } }\n}\n' } }
  local found = frame_guard.functions_deferring(probe)
  assert_equal(#found, 1, "the fork function's direct call of probeOuter: " .. table.concat(found, "; "))
  assert_true((found[1] or ""):match("^probe%.sc:4: .*this%.probeOuter directly, and probeOuter hands a function to onFree %(probeOuter %-> probeLater %-> onFree%)"),
    "names the chain: " .. tostring(found[1]))
end)

test("the engine's own functions pass the scan (#689)", function()
  -- lib/Engine_Strata.sc's alloc and free too, though it is never edited
  local files = engine_files()
  local found = frame_guard.functions_deferring(files)
  assert_true(#found == 0, table.concat(found, "\n"))
  -- 470 in lib/engine/Strata*.sc when the scan was written (#689), as many
  -- as sclang 3.14.1 compiles there (the FunctionDefs in each method's
  -- literals, method by method)
  local literals = 0
  for _, file in ipairs(files) do
    if file.path:match("^lib/engine/") then literals = literals + #frame_guard.function_literals(sc_code_only(file.text)) end
  end
  assert_true(literals >= 450, "the scan finds the engine's function literals (" .. literals .. ")")
  -- the issue's calls sit in functions and go through areaCall
  local routed = {}
  for _, file in ipairs(files) do
    for _, call in ipairs(frame_guard.function_calls(sc_code_only(file.text))) do
      if call.fn and call.target then routed[call.target] = true end
    end
  end
  for _, name in ipairs({ "scatterEnded", "switchGrainSynth", "notesUnfrozen", "startNote" }) do
    assert_true(routed[name], name .. " is called from an engine function through this.areaCall(\\" .. name .. ", ...)")
  end
end)

test("the engine's sample paths run no sclang function per sample (#131)", function()
  local old_loop = "while { true } { interleaved = FloatArray.newClear(n); left.size.do({ arg frame; "
    .. "interleaved[frame * 2] = left[frame].clip(-1, 1) }) }"
  assert_true(#per_sample_loops(old_loop) > 0, "caught: the old per-frame interleave")
  assert_true(#per_sample_loops("FloatArray.fill(n, { |i| i })") > 0, "caught: a fill")
  assert_equal(#per_sample_loops("out.putEach(keys[0], left.clip(peak.neg, peak).at(keys[2]))"), 0, "allowed: primitives")
  local text
  for _, file in ipairs(engine_files()) do
    if file.path:match("StrataFiles%.sc$") then text = file.text end
  end
  assert_true(text ~= nil, "the engine sources hold StrataFiles.sc")
  for _, name in ipairs({ "interleaveChunk", "interleaveKeys", "fileDecodes", "freshReadArray" }) do
    local body = sc_method_body(text, name)
    assert_true(body ~= nil, "StrataFiles.sc defines " .. name)
    local loops = per_sample_loops(body or "")
    assert_equal(#loops, 0, name .. " runs no function per sample (found " .. table.concat(loops, ", ") .. ")")
  end
  local interleave = sc_method_body(text, "interleaveFiles") or ""
  local condition, loop = interleave:match("while%s*(%b{})%s*(%b{})")
  assert_true(loop ~= nil, "interleaveFiles reads its chunks in a while loop")
  local loops = per_sample_loops((condition or "") .. (loop or ""))
  assert_equal(#loops, 0, "interleaveFiles' chunk loop runs no function per sample (found " .. table.concat(loops, ", ") .. ")")
  assert_true((loop or ""):find("this%.interleaveChunk%(") ~= nil, "each chunk goes through interleaveChunk")
end)

-- The engine check's constant test files (#207): writeConstantFrames builds
-- one full chunk before its loop and writes it again and again. Building a
-- chunk per 65536 frames (an index Array of 131072 slots and a Signal each:
-- 220 of them for the waveform area's 300 s file) crashed sclang 3.13 in
-- the save that followed, about 1 run in 16 with 16 running at once. The
-- body of the SC function `var name = { ... };` in text (comments stripped)
local function sc_function_body(text, name)
  local stripped = stubs.strip_sc_comments(text)
  local start = stripped:find("\nvar%s+" .. name .. "%s*=%s*{")
  if not start then return nil end
  return stripped:match("%b{}", start)
end

-- What every while loop in the function body breaks of the rule: its
-- condition compares names and numbers only, and its body holds only
-- `<file>.writeData(<name>)` (a chunk built before the loop) and the `left`
-- decrement, so no call of any kind can build a chunk inside it
local function constant_chunk_loop_findings(body)
  local found, loops, writes = {}, 0, 0
  for condition, loop in (body or ""):gmatch("while%s*(%b{})%s*(%b{})") do
    loops = loops + 1
    if not condition:sub(2, -2):match("^[%s%w_<>=]*$") then
      table.insert(found, "condition " .. condition)
    end
    for statement in loop:sub(2, -2):gmatch("[^;]+") do
      statement = statement:match("^%s*(.-)%s*$")
      if statement:match("^[%a_][%w_]*%.writeData%(%s*[%a_][%w_]*%s*%)$") then
        writes = writes + 1
      elseif statement ~= "" and not statement:match("^left%s*=%s*left%s*%-%s*[%w_]+$") then
        table.insert(found, statement)
      end
    end
  end
  if loops == 0 then table.insert(found, "no while loop") end
  if writes == 0 then table.insert(found, "no loop writes a chunk built before it") end
  return found
end

test("the engine check builds a constant file's chunk once, not per chunk (#207)", function()
  local old = "{ arg file, frames, values;\n    var left = frames;\n    while { left > 0 } {\n"
    .. "        file.writeData(repeating.(left.min(65536) * values.size, values));\n        left = left - 65536;\n    };\n}"
  local fixed = "{ var full = repeating.(n, values), left = frames;\n"
    .. "    while { left >= chunkFrames } { file.writeData(full); left = left - chunkFrames };\n"
    .. "    if (left > 0) { file.writeData(repeating.(left * values.size, values)) };\n}"
  assert_true(#constant_chunk_loop_findings(old) > 0, "caught: a chunk built in the loop")
  for _, built in ipairs({ "Signal.fill(n, { 0 })", "Array.fill(n, 0)", "stereoOf.(a, b)", "periodic.(p, 0, n)",
    "noise.(n, 1)", "values.dup(n)", "values.collect(_.neg)" }) do
    local loop = "{ while { left > 0 } { file.writeData(" .. built .. "); left = left - 65536 } }"
    assert_true(#constant_chunk_loop_findings(loop) > 0, "caught: " .. built .. " in the loop")
  end
  assert_true(#constant_chunk_loop_findings(fixed .. "\nwhile { left > 0 } { file.writeData(noise.(n, 1)) }") > 0,
    "caught: a chunk built in a second while loop")
  assert_true(#constant_chunk_loop_findings("{ while { left > 0 } { file.writeData(full); full = noise.(n, 1) } }") > 0,
    "caught: a chunk built beside the write")
  assert_equal(table.concat(constant_chunk_loop_findings(fixed), ", "), "", "allowed: one chunk built before the loop")
  local file = assert(io.open(repo_root .. "/test/engine_check.scd", "r"))
  local text = file:read("*a")
  file:close()
  local body = sc_function_body(text, "writeConstantFrames")
  assert_true(body ~= nil, "test/engine_check.scd: writeConstantFrames could not be found or parsed "
    .. "(expected `var writeConstantFrames = { ... };` at the start of a line)")
  local findings = constant_chunk_loop_findings(body)
  assert_equal(#findings, 0, "writeConstantFrames' loop builds no chunk (found " .. table.concat(findings, ", ") .. ")")
end)

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

-- CI's LuaJIT is built without Lua 5.2 compatibility, so these names are nil
-- there even when a local LuaJIT has them (#119). A use passes only with a
-- fallback in the same expression (`table.unpack or unpack`).
local LUAJIT_MISSING_NAMES = {
  "table.unpack", "table.pack", "table.move", "math.type", "math.tointeger",
  "utf8", "string.pack", "string.unpack",
}

local function luajit_missing_name_problems(sources)
  local problems = {}
  for _, source in ipairs(sources) do
    local sanitized = sync_check.sanitize_lua(source.text)
    local line_number = 0
    for line in (sanitized .. "\n"):gmatch("([^\n]*)\n") do
      line_number = line_number + 1
      for _, name in ipairs(LUAJIT_MISSING_NAMES) do
        local pattern = "%f[%w_.]" .. name:gsub("%.", "%%.") .. (name == "utf8" and "%." or "%f[^%w_]")
        local first, last = line:find(pattern)
        if first then
          local fallback = line:sub(last + 1):match("^%s*or%s") or line:sub(1, first - 1):match("%sor%s+$")
          if not fallback then
            table.insert(problems, source.path .. ":" .. line_number .. " uses " .. name .. " with no fallback")
          end
        end
      end
    end
  end
  return problems
end

test("no Lua 5.2+ name that CI's LuaJIT lacks is used without a fallback (#119)", function()
  -- the scanner itself
  local problems = luajit_missing_name_problems({ { path = "x.lua", text = table.concat({
    "local a = table.unpack(t)",
    "local b = table.unpack or unpack",
    "local c = unpack or table.unpack",
    "-- table.pack in a comment",
    'local d = "math.type in a string"',
    "local e = math.type(1) + utf8.char(65)",
    "local f = mytable.unpack(t)",
    "local g = string.pack('i', 1) and string.unpack('i', s)",
  }, "\n") } })
  assert_equal(table.concat(problems, "; "), "x.lua:1 uses table.unpack with no fallback; "
    .. "x.lua:6 uses math.type with no fallback; x.lua:6 uses utf8 with no fallback; "
    .. "x.lua:8 uses string.pack with no fallback; x.lua:8 uses string.unpack with no fallback",
    "bad uses are reported; fallbacks, comments, strings and other tables are not")
  local sources = read_lua_sources()
  local listing = assert(io.popen('cd "' .. repo_root .. '" && find test -name "*.lua" | sort'))
  for path in listing:read("*a"):gmatch("[^\n]+") do
    local file = assert(io.open(repo_root .. "/" .. path, "r"))
    table.insert(sources, { path = path, text = file:read("*a") })
    file:close()
  end
  listing:close()
  problems = luajit_missing_name_problems(sources)
  assert_equal(#problems, 0, table.concat(problems, "; "))
end)

-- Recursive deletes (#134): code runs `rm -r` only at the three guarded
-- sites, each of which checks its path first and passes it after "--":
-- h.remove_tree, the engine check's scratch cleanup and the runner's trap
local GUARDED_RECURSIVE_DELETES = {
  ["test/helpers.lua"] = 'os.execute("rm -rf -- " .. shell_quote(target))',
  ["test/engine_check.scd"] = '("rm -rf -- " ++ scratchRoot.shellQuote).systemCmd;',
  ["test/run_engine_check.sh"] = '[ -d "$work_dir" ] && rm -rf -- "$work_dir" ;;',
}

-- An rm with r, R or --recursive in any of its options, before or after its
-- operands (GNU rm reads both), up to "--" or the end of the command (;, &
-- or |); find's -delete, git clean, rsync's --delete, Python's rmtree and
-- sclang's deleteAll (#488)
local function recursive_rm(line)
  for command in line:gmatch("%f[%w]rm(%s+[^;&|\n]*)") do
    for word in command:gmatch("%s+(%S+)") do
      if word == "--" then break end
      if word:match("^%-%-recursive") or (word:match("^%-%a") and word:match("^%-%a*[rR]")) then return true end
    end
  end
  return false
end

local function recursive_delete(line)
  return recursive_rm(line) or line:match("%f[%w]find%s.-%s%-delete%f[^%w]") ~= nil
    or line:match("%f[%w]git%s+clean%f[^%w]") ~= nil or line:match("%f[%w]rsync%s.-%-%-delete") ~= nil
    or line:match("rmtree") ~= nil or line:match("deleteAll") ~= nil
end

test("recursive deletes happen only at the guarded sites", function()
  for _, line in ipairs({ "rm -rf /x", "rm -r dir", "rm -fr dir", 'os.execute("rm -Rf " .. d)', "rm --recursive d",
      "shutil.rmtree(p)", "File.deleteAll(p)",
      -- any flags before the recursive one, and deletes that are not rm (#488)
      "rm -f -r dir", 'rm -v -rf "$dir"', "rm -i -R x", "sudo rm -f --recursive d", 'find "$dir" -delete',
      "git clean -fdx", "rsync -a --delete a/ b/",
      -- GNU rm reads options after its operands too
      'rm "$dir" -rf', 'rm -f "$x" -R', 'os.execute("rm " .. path .. " -r")' }) do
    assert_true(recursive_delete(line), "caught: " .. line)
  end
  for _, line in ipairs({ "rm file.txt", "os.remove(path)", "File.delete(path)", "-- a firm -r flag", "perform -r",
      "rm -f file.txt", "rm -- -r", "apt-get clean", "find . -name x", 'rm "$x" -- -r', 'rm -f "$x"; ls -R',
      'rm "$x" && ls -R', 'rm "$x" | grep -r y' }) do
    assert_true(not recursive_delete(line), "allowed: " .. line)
  end
  local listing = assert(io.popen("cd '" .. repo_root .. "' && git ls-files")):read("*a")
  local seen = {}
  for path in listing:gmatch("[^\n]+") do
    -- this file is skipped: its samples above are what the scan looks for
    if path ~= "test/unit/structure_test.lua" and (path:match("%.lua$") or path:match("%.sc$")
        or path:match("%.scd$") or path:match("%.sh$") or path:match("%.py$") or path:match("%.yml$")
        or path:match("%.in$") or path:match("Dockerfile$")) then
      local file = io.open(repo_root .. "/" .. path, "r")
      if file then
        local number = 0
        for line in file:lines() do
          number = number + 1
          local stripped = line:gsub("^%s+", ""):gsub("%s+$", "")
          if recursive_delete(line) and not stripped:match("^%-%-") and not stripped:match("^//") and not stripped:match("^#") then
            local allowed = GUARDED_RECURSIVE_DELETES[path]
            assert_true(allowed ~= nil and line:find(allowed, 1, true) ~= nil,
              path .. ":" .. number .. " deletes recursively outside the guarded sites: " .. stripped)
            seen[path] = true
          end
        end
        file:close()
      end
    end
  end
  for path in pairs(GUARDED_RECURSIVE_DELETES) do assert_true(seen[path], "the guarded delete in " .. path .. " is still there") end
end)

-- The runner stops what sclang started without pgrep, timeout or stdbuf
-- (#152). A fake sclang starts a fake scsynth (a script named scsynth)
-- and then either reports a compile error and waits, so the runner's own
-- stop must reach its child, or kills itself like a crashed sclang,
-- leaving the server orphaned with only the PID file the check writes
-- (scsynth.pid in its work dir) to find it by. The runner runs on a PATH
-- holding only the tools it needs.
local RUNNER_TOOLS = { "dirname", "mktemp", "cp", "mkdir", "uname", "cat", "grep", "sleep", "rm", "ps", "awk", "date" }

-- Whether the process numbered pid is still running after up to `seconds`
-- of waiting for its end, polled every 0.1 s (#673): a signaled process
-- ends a moment after kill returns, and a zombie (ended, not yet reaped:
-- kill -0 still finds it) has ended
local function still_running(pid, seconds)
  if pid == nil or pid:match("^%d+$") == nil then return false end
  local pipe = io.popen("n=0; while kill -0 " .. pid .. " 2>/dev/null; do"
    .. " case $(ps -o stat= -p " .. pid .. " 2>/dev/null) in *Z*) break ;; esac;"
    .. " [ $n -ge " .. math.ceil(seconds * 10) .. " ] && { echo running; exit 0; };"
    .. " sleep 0.1; n=$((n + 1)); done; echo ended")
  local verdict = pipe:read("*l")
  pipe:close()
  return verdict == "running"
end

-- A runner test's folder: bin holds links to RUNNER_TOOLS only, and
-- norns/sc/core stands in for a norns checkout
local function runner_folder(name)
  local shell_quote, root = h.shell_quote, data_root .. "runner-" .. name
  os.execute("mkdir -p " .. shell_quote(root .. "/bin") .. " " .. shell_quote(root .. "/norns/sc/core"))
  local function tool_path(tool)
    local pipe = io.popen("command -v " .. tool)
    local found = pipe:read("*l")
    pipe:close()
    assert_true(found ~= nil and found ~= "", tool .. " is installed")
    return found
  end
  for _, tool in ipairs(RUNNER_TOOLS) do
    os.execute("ln -s " .. shell_quote(tool_path(tool)) .. " " .. shell_quote(root .. "/bin/" .. tool))
  end
  return root
end

-- The runner's command, run from `checkout` on that PATH with the fake
-- sclang at root/sclang, in two parts: the setup, then the runner itself
-- (a command of its own, to run in the background). The setup clears the
-- caller's areas and one-sclang settings (one exported while working on an
-- area must not change what the tests see); `environment` holds the run's
-- own assignments
local RUNNER_CALLER_SETTINGS = "unset STRATA_ENGINE_CHECK_AREAS STRATA_ENGINE_CHECK_ONE_SCLANG && "
local function runner_command(root, checkout, environment, timeout)
  local shell_quote = h.shell_quote
  return "cd " .. shell_quote(checkout) .. " && " .. RUNNER_CALLER_SETTINGS,
    environment .. " PATH=" .. shell_quote(root .. "/bin") .. " SCLANG=" .. shell_quote(root .. "/sclang")
    .. " ENGINE_CHECK_TIMEOUT=" .. (timeout or 30) .. " TMPDIR=" .. shell_quote(root)
    .. " STRATA_SC_PORT=57399 /bin/sh test/run_engine_check.sh " .. shell_quote(root .. "/norns") .. " 2>&1"
end

-- The lines of a file, {} when there is none
local function file_lines(path)
  local file, lines = io.open(path, "r"), {}
  if not file then return lines end
  for line in file:lines() do lines[#lines + 1] = line end
  file:close()
  return lines
end

-- options.timeout: ENGINE_CHECK_TIMEOUT (30); options.environment: the
-- run's settings (default STRATA_ENGINE_CHECK_ONE_SCLANG=1, every area in
-- one sclang, the path these cases test; "" runs CI's shards)
local function run_runner_without_tools(case, options)
  options = options or {}
  local environment = options.environment or "STRATA_ENGINE_CHECK_ONE_SCLANG=1"
  local shell_quote = h.shell_quote
  local root = runner_folder(case .. (environment == "" and "-shards" or ""))
  -- a script, not a link to sleep: a multi-call coreutils refuses to run
  -- under another name. It sleeps in 1 s steps, so a stopped one leaves
  -- no long sleep behind
  local server = assert(io.open(root .. "/scsynth", "w"))
  server:write("#!/bin/sh\ncount=0\nwhile [ $count -lt 60 ]; do sleep 1; count=$((count + 1)); done\n")
  server:close()
  os.execute("chmod +x " .. shell_quote(root .. "/scsynth"))
  local lines = { "#!/bin/sh", shell_quote(root .. "/scsynth") .. " 60 &", "echo $! > " .. shell_quote(root .. "/fake.pid"),
    "echo $$ > " .. shell_quote(root .. "/sclang.pid"), "echo $$ >> " .. shell_quote(root .. "/starts.txt") }
  if case == "warning" then
    -- a run that passes in every way but one WARNING line (#486); its
    -- server's PID file lets the runner stop it, so the wait for its end
    -- (#673) is short
    lines[#lines + 1] = 'echo $! > "$STRATA_CHECK_TMPDIR/scsynth.pid"'
    lines[#lines + 1] = 'echo "WARNING: Extension overwrites a method"'
    lines[#lines + 1] = 'echo "ENGINE CHECK PASSED"'
  elseif case == "compile-error" then
    lines[#lines + 1] = 'echo "ERROR: syntax error, unexpected"'
    lines[#lines + 1] = "sleep 60"
  elseif case == "hang" or case == "signal" then
    -- a sclang that stops running: its own deadline never posts its FAIL line
    lines[#lines + 1] = 'echo $! > "$STRATA_CHECK_TMPDIR/scsynth.pid"'
    lines[#lines + 1] = "sleep 60"
  else
    lines[#lines + 1] = 'echo $! > "$STRATA_CHECK_TMPDIR/scsynth.pid"'
    lines[#lines + 1] = "kill -KILL $$"
  end
  local sclang = assert(io.open(root .. "/sclang", "w"))
  sclang:write(table.concat(lines, "\n") .. "\n")
  sclang:close()
  os.execute("chmod +x " .. shell_quote(root .. "/sclang"))
  local setup, runner = runner_command(root, repo_root, environment, options.timeout)
  local run = setup .. runner .. "; echo exit=$?"
  local leftover_folders
  if case == "signal" then
    -- the runner in the background; once the fake sclang has its server
    -- going, the runner is sent TERM, the way a caller's timeout would
    run = setup .. "( " .. runner .. " & runner=$!;"
      .. " n=0; while [ ! -s " .. shell_quote(root .. "/fake.pid") .. " ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done; sleep 1;"
      .. " kill -TERM $runner; wait $runner; echo exit=$?; sleep 1 )"
  end
  local pipe = io.popen(run)
  local output = pipe:read("*a")
  pipe:close()
  local folders = io.popen("ls " .. shell_quote(root) .. " | grep -c '^strata-engine-run\\.'")
  leftover_folders = tonumber(folders:read("*l")) or 0
  folders:close()
  local pid_file = io.open(root .. "/fake.pid", "r")
  local pid = pid_file and pid_file:read("*l")
  if pid_file then pid_file:close() end
  local alive = still_running(pid, 10)
  if alive then os.execute("kill " .. pid .. " 2>/dev/null") end
  local sclang_file = io.open(root .. "/sclang.pid", "r")
  local sclang_pid = sclang_file and sclang_file:read("*l")
  if sclang_file then sclang_file:close() end
  local sclang_alive = still_running(sclang_pid, 10)
  if sclang_alive then os.execute("kill " .. sclang_pid .. " 2>/dev/null") end
  local starts = #file_lines(root .. "/starts.txt")
  h.remove_tree(root)
  return output, pid, alive, leftover_folders, sclang_alive, starts
end

test("the engine check runner stops sclang's scsynth without pgrep or timeout (#152)", function()
  local output, pid, alive = run_runner_without_tools("compile-error")
  assert_true(pid ~= nil, "the fake sclang started its server: " .. output)
  assert_true(output:find("sclang reported a compile error", 1, true) ~= nil, "the runner stopped sclang: " .. output)
  assert_true(not alive, "the server sclang started is stopped with it")
end)

-- #673: a signaled process ends a moment after kill returns, and stays a
-- zombie (kill -0 still finds it) until its parent or init reaps it, so the
-- runner tests wait for its end, with a bound, and count a zombie as ended
test("the runner tests wait for a process's end and count a zombie as ended (#673)", function()
  local function started(command)
    local pipe = io.popen(command)
    local pid = pipe:read("*l")
    pipe:close()
    assert_true(pid ~= nil and pid:match("^%d+$") ~= nil, "started: " .. command)
    return pid
  end
  local ending = started("sleep 1 > /dev/null 2>&1 & echo $!")
  assert_true(not still_running(ending, 10), "a process that ends a second later is waited for")
  -- sleep 0's parent becomes sleep 6, which never reaps it, so it stays a
  -- zombie (kill -0 finds it) for longer than the 2 s bound: only the
  -- zombie test can call it ended
  local zombie = started("sh -c 'sleep 0 > /dev/null 2>&1 & echo $!; exec sleep 6 > /dev/null 2>&1' &")
  assert_true(not still_running(zombie, 2), "a zombie has ended")
  local running = started("sleep 5 > /dev/null 2>&1 & echo $!")
  assert_true(still_running(running, 0.5), "a process that outlives the bound is still running")
  os.execute("kill " .. running .. " 2>/dev/null")
end)

-- 1 s timeout: without a timeout command the runner's own loop stops it
-- 15 s later
test("the engine check runner tells a hung sclang from a slow check (#131)", function()
  local output, pid, alive = run_runner_without_tools("hang", { timeout = 1 })
  assert_true(pid ~= nil, "the fake sclang started its server: " .. output)
  assert_true(output:find("ENGINE CHECK FAILED: no result within 1 s, and its own deadline never fired: sclang hung", 1, true) ~= nil,
    "the run fails, naming a hang: " .. output)
  assert_true(not alive, "the server is stopped with it: " .. output)
end)

test("the engine check runner stops the scsynth a crashed sclang left behind (#152)", function()
  local output, pid, alive = run_runner_without_tools("crash")
  assert_true(pid ~= nil, "the fake sclang started its server: " .. output)
  assert_true(output:find("ENGINE CHECK FAILED: sclang ended on signal 9", 1, true) ~= nil,
    "the run fails, naming the crash, not a timeout: " .. output)
  assert_true(not alive, "the orphaned server is stopped through its PID file: " .. output)
end)

-- #331: a signal to the runner stops sclang's tree, its server and its folder
test("the engine check runner stops its sclang, scsynth and work folder when it is signaled (#331)", function()
  local output, pid, alive, folders, sclang_alive = run_runner_without_tools("signal")
  assert_true(pid ~= nil, "the fake sclang started its server: " .. output)
  assert_true(output:find("exit=130", 1, true) ~= nil, "the runner exits 130: " .. output)
  assert_true(not alive, "the server is stopped with the runner: " .. output)
  assert_true(not sclang_alive, "the fake sclang is gone too: " .. output)
  assert_equal(folders, 0, "the work folder is removed")
end)

-- #486: any WARNING line fails a run
test("the engine check runner fails a run that printed a WARNING line (#486)", function()
  local output = run_runner_without_tools("warning")
  assert_true(output:find("exit=1", 1, true) ~= nil, "a WARNING fails the run: " .. output)
end)

-- #671: with no areas named the runner runs CI's shards, each in a sclang
-- of its own, one after another, read from the workflow through the 3.13
-- runner's -l; STRATA_ENGINE_CHECK_AREAS runs its areas in one sclang, and
-- STRATA_ENGINE_CHECK_ONE_SCLANG=1 every area in one, as before. The fake
-- sclang records the areas each start was given (calls.txt) and whether two
-- ran at once, and passes, or fails when its areas are `failing`
local workflow_shards = h.workflow_shards

-- A checkout of the runner of its own: the runner, the 3.13 script (or
-- `lister` in its place, for its -l) and the class files a run copies,
-- beside a workflow listing `shards` (none: no list)
local function runner_checkout(name, shards, lister)
  local shell_quote, checkout = h.shell_quote, data_root .. "runner-checkout-" .. name
  os.execute("mkdir -p " .. shell_quote(checkout .. "/test") .. " " .. shell_quote(checkout .. "/.github/workflows"))
  for _, path in ipairs({ "test/run_engine_check.sh", "test/run_engine_check_313.sh", "test/StrataTestNoBoot.sc.in",
      "test/StrataTestTempDir.sc.in", "test/StrataTestNoBootOSX.sc.in" }) do
    os.execute("cp " .. shell_quote(repo_root .. "/" .. path) .. " " .. shell_quote(checkout .. "/" .. path))
  end
  if lister then h.write_text(checkout .. "/test/run_engine_check_313.sh", lister) end
  local lines = { "jobs:", "  engine-shard:", "    strategy:", "      matrix:", "        areas:" }
  for _, shard in ipairs(shards or {}) do lines[#lines + 1] = "          - " .. shard end
  lines[#lines + 1] = "    env:\n      STRATA_ENGINE_CHECK_AREAS: ${{ matrix.areas }}\n"
  h.write_text(checkout .. "/.github/workflows/test.yml", shards and table.concat(lines, "\n") or "jobs:\n  lua:\n    runs-on: ubuntu-24.04\n")
  return checkout
end

-- Runs the runner (from options.checkout, else the repository, with
-- options.environment) against a fake sclang: "#!/bin/sh", then
-- options.body(root, quoted), where quoted(file) is root/file shell-quoted.
-- With options.driver the runner runs in the background, its PID in
-- root/runner.pid, while that shell runs ($runner is the PID), then is
-- waited for. Returns the output (ending exit=<status>) and calls.txt's lines.
local function run_fake_runner(name, options)
  local shell_quote = h.shell_quote
  local root = runner_folder(name)
  local function quoted(file) return shell_quote(root .. "/" .. file) end
  h.write_text(root .. "/sclang", "#!/bin/sh\n" .. table.concat(options.body(root, quoted), "\n") .. "\n")
  os.execute("chmod +x " .. quoted("sclang"))
  local setup, runner = runner_command(root, options.checkout or repo_root, options.environment or "")
  local run = setup .. runner .. "; echo exit=$?"
  if options.driver then
    run = setup .. "( " .. runner .. " & runner=$!; echo $runner > " .. quoted("runner.pid") .. "; "
      .. options.driver .. "; wait $runner; echo exit=$? )"
  end
  local pipe = io.popen(run)
  local output = pipe:read("*a")
  pipe:close()
  local lines = file_lines(root .. "/calls.txt")
  h.remove_tree(root)
  return output, lines
end

-- The fake sclang records its areas (calls.txt) and whether two ran at
-- once, and passes, or fails when its areas are `failing`
local function run_runner_areas(name, environment, failing, checkout)
  return run_fake_runner(name, { environment = environment, checkout = checkout, body = function(_, quoted)
    return { 'echo "${STRATA_ENGINE_CHECK_AREAS-unset}" >> ' .. quoted("calls.txt"),
      "[ -e " .. quoted("running") .. " ] && echo overlap >> " .. quoted("calls.txt"),
      ": > " .. quoted("running"), "sleep 0.2", "rm -f " .. quoted("running"),
      'if [ "${STRATA_ENGINE_CHECK_AREAS-}" = ' .. h.shell_quote(failing or "no shard fails") .. ' ]; then',
      '  echo "FAIL fake: this shard fails"', "else", '  echo "ENGINE CHECK PASSED"', "fi" }
  end })
end

test("the engine check runner's full run is CI's shards, each in a sclang of its own, one after another (#671)", function()
  local shards = workflow_shards()
  assert_true(#shards >= 2, "the workflow has shards")
  local output, calls = run_runner_areas("shards", "")
  assert_equal(table.concat(calls, "\n"), table.concat(shards, "\n"), "one sclang per shard, in the workflow's order, none at once: " .. output)
  for _, shard in ipairs(shards) do
    assert_true(output:find("\nshard " .. shard .. ": passed in %d+ s\n") ~= nil, "a summary line for " .. shard .. ": " .. output)
  end
  assert_true(output:find("ENGINE CHECK PASSED: " .. #shards .. " of " .. #shards .. " shards\nexit=0\n", 1, true) ~= nil,
    "the run passes, and says so last: " .. output)
end)

test("a failed shard fails the engine check runner's full run, and every shard still runs (#671)", function()
  local shards = workflow_shards()
  local output, calls = run_runner_areas("shard-fails", "", shards[2])
  assert_equal(table.concat(calls, "\n"), table.concat(shards, "\n"), "every shard ran: " .. output)
  assert_true(output:find("\nshard " .. shards[2] .. ": failed in %d+ s %(exit 1%)\n") ~= nil, "the failed shard's line: " .. output)
  assert_true(output:find("\nshard " .. shards[1] .. ": passed in %d+ s\n") ~= nil, "a passed shard's line: " .. output)
  assert_true(output:find("ENGINE CHECK FAILED: 1 of " .. #shards .. " shards failed: " .. shards[2] .. "\nexit=1\n", 1, true) ~= nil,
    "the run fails, naming the shard: " .. output)
end)

test("the engine check runner runs named areas, or every area with STRATA_ENGINE_CHECK_ONE_SCLANG=1, in one sclang (#671)", function()
  local output, calls = run_runner_areas("named", "STRATA_ENGINE_CHECK_AREAS=memory,rings")
  assert_equal(table.concat(calls, "\n"), "memory,rings", "one sclang, with the named areas: " .. output)
  assert_true(output:find("exit=0", 1, true) ~= nil and output:find("shard", 1, true) == nil, "no shards: " .. output)
  output, calls = run_runner_areas("one", "STRATA_ENGINE_CHECK_ONE_SCLANG=1")
  assert_equal(table.concat(calls, "\n"), "unset", "one sclang, with no areas named (every area): " .. output)
  assert_true(output:find("exit=0", 1, true) ~= nil and output:find("shard", 1, true) == nil, "no shards: " .. output)
  output, calls = run_runner_areas("one-bad", "STRATA_ENGINE_CHECK_ONE_SCLANG=yes")
  assert_equal(#calls, 0, "a value other than 1 or empty starts nothing: " .. output)
  assert_true(output:find("STRATA_ENGINE_CHECK_ONE_SCLANG must be 1 or empty, got \"yes\"\nexit=2\n", 1, true) ~= nil,
    "and fails the start: " .. output)
end)

test("the engine check runner starts no sclang when it cannot read the workflow's shards (#671)", function()
  local checkout = runner_checkout("no-list")
  local output, calls = run_runner_areas("no-list", "", nil, checkout)
  h.remove_tree(checkout)
  assert_equal(#calls, 0, "no sclang started: " .. output)
  assert_true(output:find("no shard list", 1, true) ~= nil, "the 3.13 runner's reason is shown: " .. output)
  assert_true(output:find("\nENGINE CHECK FAILED: [^\n]*shard[^\n]*\nexit=2\n$") ~= nil, "the run ends on its own failure line: " .. output)
end)

-- #331 for a run in shards: the signal stops the running shard's sclang, its
-- server and its folder, no later shard starts, and the summary says where
test("the engine check runner's run in shards stops its shard's sclang and scsynth when it is signaled (#331, #671)", function()
  local output, pid, alive, folders, sclang_alive, starts = run_runner_without_tools("signal", { environment = "" })
  local shards = workflow_shards()
  assert_true(pid ~= nil, "the fake sclang started its server: " .. output)
  assert_true(output:find("exit=130", 1, true) ~= nil, "the runner exits 130: " .. output)
  assert_true(not alive, "the server is stopped with the runner: " .. output)
  assert_true(not sclang_alive, "the fake sclang is gone too: " .. output)
  assert_equal(folders, 0, "the work folder is removed")
  assert_equal(starts, 1, "no later shard started: " .. output)
  assert_true(output:find("\nshard " .. shards[1] .. ": interrupted after %d+ s\nENGINE CHECK FAILED: interrupted in shard "
    .. shards[1] .. "; " .. (#shards - 1) .. " of " .. #shards .. " shards did not run\nexit=130\n") ~= nil,
    "the summary names the shard the signal stopped: " .. output)
end)

-- A signal between two shards (the parent held still with SIGSTOP by the
-- first shard's sclang until that shard's run has ended) or before the
-- first (while the shard list is read): the summary of what ran, then where
-- the signal came, and nothing more starts (#671)
test("the engine check runner says where a signal came between shards or before the first, after what ran (#671)", function()
  local checkout = runner_checkout("between", { "alpha", "beta,gamma" })
  local output, calls = run_fake_runner("between", { checkout = checkout, body = function(root, quoted)
    return { 'echo "$STRATA_ENGINE_CHECK_AREAS" >> ' .. quoted("calls.txt"),
      "until [ -s " .. quoted("runner.pid") .. " ]; do sleep 0.1; done",
      "kill -STOP $(cat " .. quoted("runner.pid") .. ")", ": > " .. quoted("held"), 'echo "ENGINE CHECK PASSED"' }
  end, driver = "n=0; until [ -e " .. h.shell_quote(data_root .. "runner-between/held") .. " ] && ! ls "
    .. h.shell_quote(data_root .. "runner-between") .. " | grep -q '^strata-engine-run'; do sleep 0.1; n=$((n+1));"
    .. " [ $n -lt 150 ] || break; done; kill -TERM $runner; kill -CONT $runner" })
  h.remove_tree(checkout)
  assert_equal(table.concat(calls, " "), "alpha", "only the first shard started: " .. output)
  assert_true(output:find("\nshard alpha: passed in %d+ s\nENGINE CHECK FAILED: interrupted after shard alpha; 1 of 2 shards did not run\nexit=130\n$") ~= nil,
    "the first shard's line, then where the signal came: " .. output)
  -- before the first: the list's reader is held while the signal comes
  local lister = "#!/bin/sh\n: > " .. h.shell_quote(data_root .. "runner-before/listing") .. "\nsleep 2\necho alpha\necho beta\n"
  checkout = runner_checkout("before", { "alpha", "beta" }, lister)
  output, calls = run_fake_runner("before", { checkout = checkout, body = function(_, quoted)
    return { 'echo "$STRATA_ENGINE_CHECK_AREAS" >> ' .. quoted("calls.txt"), 'echo "ENGINE CHECK PASSED"' }
  end, driver = "n=0; until [ -e " .. h.shell_quote(data_root .. "runner-before/listing") .. " ] || [ $n -ge 50 ]; do sleep 0.1; n=$((n+1)); done;"
    .. " kill -TERM $runner" })
  h.remove_tree(checkout)
  assert_equal(#calls, 0, "no shard started: " .. output)
  assert_true(output:find("ENGINE CHECK FAILED: interrupted before the first shard; 2 of 2 shards did not run\nexit=130\n$") ~= nil,
    "the run says the signal came before any shard: " .. output)
  -- a Ctrl-C reaches the list's reader too, which then fails: the stand-in
  -- signals the run, then exits as one killed by that signal would
  lister = "#!/bin/sh\nuntil [ -s " .. h.shell_quote(data_root .. "runner-killed-lister/runner.pid") .. " ]; do sleep 0.1; done\n"
    .. "kill -TERM $(cat " .. h.shell_quote(data_root .. "runner-killed-lister/runner.pid") .. ")\nexit 143\n"
  checkout = runner_checkout("killed-lister", { "alpha", "beta" }, lister)
  output, calls = run_fake_runner("killed-lister", { checkout = checkout, body = function(_, quoted)
    return { 'echo "$STRATA_ENGINE_CHECK_AREAS" >> ' .. quoted("calls.txt"), 'echo "ENGINE CHECK PASSED"' }
  end, driver = "true" })
  h.remove_tree(checkout)
  assert_equal(#calls, 0, "no shard started: " .. output)
  assert_true(output:find("no shard list", 1, true) == nil
    and output:find("ENGINE CHECK FAILED: interrupted before the first shard, while the shard list was read\nexit=130\n$") ~= nil,
    "a signal that ends the list's reader is an interrupt, not a missing list: " .. output)
end)

-- A crashed shard leaves its server: the run waits, with a bound, for it to
-- end before the next shard starts, so the next one never meets it on the
-- port; one that outlives the bound fails its shard, says so, and no later
-- shard starts (#671's review). The first shard's sclang crashes, leaving a
-- fake scsynth that ends 2 s after TERM ("slow") or ignores it ("stays"); a
-- later sclang records whether that server is still running
local function crashed_shard_run(name, on_term)
  local shell_quote = h.shell_quote
  local checkout = runner_checkout(name, { "alpha", "beta" })
  -- the server: a sh loop in 1 s steps named scsynth (the runner signals
  -- only a scsynth), its PID kept outside the run's folder for the cleanup
  local server, server_pid = data_root .. name .. "-scsynth", data_root .. name .. "-scsynth.pid"
  h.write_text(server, "#!/bin/sh\n" .. on_term .. "\nn=0\nwhile [ $n -lt 30 ]; do sleep 1; n=$((n + 1)); done\n")
  os.execute("chmod +x " .. shell_quote(server))
  local output, calls = run_fake_runner(name, { checkout = checkout, body = function(_, quoted)
    return { 'echo "$STRATA_ENGINE_CHECK_AREAS" >> ' .. quoted("calls.txt"),
      'if [ "$STRATA_ENGINE_CHECK_AREAS" = alpha ]; then',
      "  " .. shell_quote(server) .. " &", "  echo $! > " .. shell_quote(server_pid),
      '  echo $! > "$STRATA_CHECK_TMPDIR/scsynth.pid"', "  kill -KILL $$", "fi",
      "server=$(cat " .. shell_quote(server_pid) .. ")",
      'if kill -0 "$server" 2>/dev/null; then case $(ps -o stat= -p "$server") in *Z*) ;; *) echo "server still running" >> '
        .. quoted("calls.txt") .. " ;; esac; fi",
      'echo "ENGINE CHECK PASSED"' }
  end })
  local pid = h.file_text(server_pid)
  if pid and pid:match("^%d+") then os.execute("kill -KILL " .. pid:match("^%d+") .. " 2>/dev/null") end
  os.remove(server)
  os.remove(server_pid)
  h.remove_tree(checkout)
  return output, calls
end

test("a crashed shard's leftover scsynth is waited for before the next shard starts, and one that stays fails the run (#671)", function()
  local output, calls = crashed_shard_run("slow-server", "trap 'sleep 2; exit 0' TERM")
  assert_equal(table.concat(calls, " "), "alpha beta", "both shards ran, and beta never met alpha's server: " .. output)
  assert_true(output:find("\nshard alpha: failed in %d+ s %(exit 1%)\nshard beta: passed in %d+ s\nENGINE CHECK FAILED: 1 of 2 shards failed: alpha\nexit=1\n$") ~= nil,
    "the crash fails its own shard only: " .. output)
  output, calls = crashed_shard_run("staying-server", "trap '' TERM")
  assert_equal(table.concat(calls, " "), "alpha", "no shard starts after a server that stays: " .. output)
  assert_true(output:find("\nshard alpha: failed in %d+ s %(exit 3: its scsynth was still running 10 s after it was stopped%)\n"
    .. "ENGINE CHECK FAILED: 1 of 2 shards failed: alpha; 1 did not run\nexit=1\n$") ~= nil,
    "its shard says why, and the run fails without the next: " .. output)
end)

-- The 3.13 image runs one sclang a container: its runner makes the shards
-- itself (a container per shard, or every area in one with -1), so the
-- image's check never shards again (#671)
test("the 3.13 image's check runs its container's areas in one sclang (#671)", function()
  local file = assert(io.open(repo_root .. "/test/docker/sc313/check.sh", "r"))
  local check = file:read("*a")
  file:close()
  assert_true(check:find("\nSTRATA_ENGINE_CHECK_ONE_SCLANG=1 SCLANG=/usr/bin/sclang test/run_engine_check.sh /norns", 1, true) ~= nil,
    "check.sh runs the runner with STRATA_ENGINE_CHECK_ONE_SCLANG=1")
end)

-- The 3.13 Docker script (#544, #545): every container carries a memory cap,
-- and a run is classified by what its log holds, not by how sclang ended.
-- Its tests never see the caller's settings: one exported while working on
-- an area (STRATA_ENGINE_CHECK_AREAS=memory) would make a full run one
-- container per run, and the others change the image and the cap
local SC313_CALLER_SETTINGS = "unset STRATA_ENGINE_CHECK_AREAS STRATA_SC313_IMAGE STRATA_SC313_MEMORY && "
local function run_313_script(root, arguments, extra_path)
  local shell_quote = h.shell_quote
  local pipe = io.popen("cd " .. shell_quote(repo_root) .. " && " .. SC313_CALLER_SETTINGS .. "PATH=" .. shell_quote(extra_path or "") .. (extra_path and ":" or "")
    .. "$PATH TMPDIR=" .. shell_quote(root) .. " /bin/sh test/run_engine_check_313.sh " .. arguments .. " 2>&1; echo exit=$?")
  local output = pipe:read("*a")
  pipe:close()
  return output
end

test("the 3.13 script's containers carry a memory cap (#544)", function()
  local shell_quote, root = h.shell_quote, data_root .. "sc313-cap"
  os.execute("mkdir -p " .. shell_quote(root .. "/bin") .. " " .. shell_quote(root .. "/norns/sc/core") .. " " .. shell_quote(root .. "/logs"))
  local fake = assert(io.open(root .. "/bin/docker", "w"))
  fake:write("#!/bin/sh\ncase \"$1\" in\n  image) exit 1 ;;\n  build) exit 0 ;;\n  run) echo \"$@\" >> " .. shell_quote(root .. "/docker-run.txt")
    .. "; exit 0 ;;\nesac\nexit 0\n")
  fake:close()
  os.execute("chmod +x " .. shell_quote(root .. "/bin/docker"))
  local output = run_313_script(root, "-n 2 -j 4 -o " .. shell_quote(root .. "/logs") .. " " .. shell_quote(root .. "/norns"), root .. "/bin")
  local file = io.open(root .. "/docker-run.txt", "r")
  local runs = file and file:read("*a") or ""
  if file then file:close() end
  local count = 0
  for line in runs:gmatch("[^\n]+") do
    count = count + 1
    assert_true(line:find("%-%-memory=%d+[gGmM]") ~= nil, "docker run carries --memory: " .. line)
    assert_true(line:find("%-%-memory%-swap=%d+[gGmM]") ~= nil, "docker run carries --memory-swap: " .. line)
  end
  -- a full run is one container per shard of the workflow's (#581)
  local shards = #h.workflow_shards()
  assert_equal(count, 2 * shards, "every shard of both runs started a container: " .. output)
  h.remove_tree(root)
end)

-- #581: the 3.13 script's full run is the workflow's shards, each in a
-- container (a fresh sclang) of its own. These tests run a copy of the
-- script in a folder of its own, beside a workflow listing the given shards,
-- the image's sources and a fake docker whose run branch is the given text
local function fake_313_checkout(root, shards, docker_run)
  local shell_quote = h.shell_quote
  os.execute("mkdir -p " .. shell_quote(root .. "/test/docker/sc313") .. " " .. shell_quote(root .. "/.github/workflows") .. " "
    .. shell_quote(root .. "/bin") .. " " .. shell_quote(root .. "/norns/sc/core"))
  for _, path in ipairs({ "test/run_engine_check_313.sh", "test/docker/sc313/Dockerfile", "test/docker/sc313/check.sh" }) do
    os.execute("cp " .. shell_quote(repo_root .. "/" .. path) .. " " .. shell_quote(root .. "/" .. path))
  end
  local lines = { "jobs:", "  engine-shard:", "    strategy:", "      fail-fast: false", "      matrix:", "        areas:" }
  for _, shard in ipairs(shards) do lines[#lines + 1] = "          - " .. shard end
  lines[#lines + 1] = "    env:\n      STRATA_ENGINE_CHECK_AREAS: ${{ matrix.areas }}\n"
  local workflow = assert(io.open(root .. "/.github/workflows/test.yml", "w"))
  workflow:write(table.concat(lines, "\n"))
  workflow:close()
  local fake = assert(io.open(root .. "/bin/docker", "w"))
  fake:write("#!/bin/sh\ncase \"$1\" in\n  image) exit 1 ;;\n  build) exit 0 ;;\n  run)\n"
    .. "    echo \"areas=${STRATA_ENGINE_CHECK_AREAS-unset} $*\" >> " .. shell_quote(root .. "/docker-run.txt") .. "\n"
    .. docker_run .. "\n    ;;\nesac\nexit 0\n")
  fake:close()
  os.execute("chmod +x " .. shell_quote(root .. "/bin/docker"))
end

-- environment: assignments for the script's own command (the caller's
-- settings are always cleared first)
local function run_fake_313(root, arguments, environment)
  local shell_quote = h.shell_quote
  local pipe = io.popen("cd " .. shell_quote(root) .. " && " .. SC313_CALLER_SETTINGS .. (environment or "")
    .. " PATH=" .. shell_quote(root .. "/bin") .. ":$PATH TMPDIR=" .. shell_quote(root)
    .. " /bin/sh test/run_engine_check_313.sh " .. arguments .. " 2>&1; echo exit=$?")
  local output = pipe:read("*a")
  pipe:close()
  return output
end

local function read_lines(path)
  local file, lines = io.open(path, "r"), {}
  if not file then return lines end
  for line in file:lines() do lines[#lines + 1] = line end
  file:close()
  return lines
end

local function file_exists(path)
  local file = io.open(path, "r")
  if file then file:close() end
  return file ~= nil
end

test("the 3.13 script runs a full run as the workflow's shards, each in a container of its own (#581)", function()
  local shell_quote, root = h.shell_quote, data_root .. "sc313-shards"
  -- run 2's second shard crashes; every other shard passes
  fake_313_checkout(root, { "alpha", "beta,gamma", "delta" }, table.concat({
    "    case \"$*\" in",
    "      *-2-beta_gamma\\ *) echo \"ENGINE CHECK FAILED: sclang ended on signal 11 after 9 s; sclang stopped\"; exit 1 ;;",
    "    esac",
    "    echo \"ENGINE CHECK PASSED\"; exit 0",
  }, "\n"))
  local logs = root .. "/logs"
  local output = run_fake_313(root, "-n 2 -j 8 -o " .. shell_quote(logs) .. " " .. shell_quote(root .. "/norns"))
  local runs = read_lines(root .. "/docker-run.txt")
  assert_equal(#runs, 6, "one container per shard of each run: " .. output)
  for run = 1, 2 do
    for _, shard in ipairs({ "alpha", "beta,gamma", "delta" }) do
      local stem = run .. "-" .. shard:gsub(",", "_")
      local found = 0
      for _, line in ipairs(runs) do
        if line:find("%-%-name strata%-sc313%-%d+%-" .. stem:gsub("%-", "%%-") .. " ") and line:find(" -e STRATA_ENGINE_CHECK_AREAS=" .. shard .. " ", 1, true) then
          found = found + 1
        end
      end
      assert_equal(found, 1, "run " .. run .. " runs " .. shard .. " alone in its container: " .. table.concat(runs, "\n"))
      assert_true(file_exists(logs .. "/run-" .. stem .. ".log") and file_exists(logs .. "/run-" .. stem .. ".status"),
        "run-" .. stem .. ".log and .status are written")
    end
  end
  for _, expected in ipairs({ "run 1: passed\n", "run 2: crashed in beta,gamma (sclang ended on signal 11 after 9 s), " .. logs .. "/run-2-beta_gamma.log",
      "passed 1 of 2; failed 0; capped 0 (#544); killed 0; collector failure 0 (#211); crashed 1 (#131)",
      "shards: passed 5 of 6; failed 0; capped 0 (#544); killed 0; collector failure 0 (#211); crashed 1 (#131); missing 0", "exit=1" }) do
    assert_true(output:find(expected, 1, true) ~= nil, "the summary holds \"" .. expected .. "\": " .. output)
  end
  -- -c reads the same folder to the same verdict
  local classified = run_fake_313(root, "-c -n 2 -o " .. shell_quote(logs))
  for _, expected in ipairs({ "run 1: passed\n", "run 2: crashed in beta,gamma (sclang ended on signal 11 after 9 s)", "passed 1 of 2;", "exit=1" }) do
    assert_true(classified:find(expected, 1, true) ~= nil, "-c's summary holds \"" .. expected .. "\": " .. classified)
  end
  h.remove_tree(root)
end)

test("the 3.13 script's -j counts containers, shards of one run and of different runs alike (#581)", function()
  local shell_quote, root = h.shell_quote, data_root .. "sc313-parallel"
  -- each fake container notes how many are running as it starts
  local active = shell_quote(root .. "/active")
  fake_313_checkout(root, { "alpha", "beta", "gamma" }, table.concat({
    "    mkdir -p " .. active .. "; : > " .. active .. "/$$",
    "    ls " .. active .. " | wc -l >> " .. shell_quote(root .. "/counts.txt"),
    "    sleep 0.3; rm -f -- " .. active .. "/$$",
    "    echo \"ENGINE CHECK PASSED\"; exit 0",
  }, "\n"))
  -- the log folder is reused: an earlier start's statuses are there already
  os.execute("mkdir -p " .. shell_quote(root .. "/logs"))
  for run = 1, 2 do
    for _, shard in ipairs({ "alpha", "beta", "gamma" }) do
      local old = assert(io.open(root .. "/logs/run-" .. run .. "-" .. shard .. ".status", "w")); old:write("0\n"); old:close()
    end
  end
  local output = run_fake_313(root, "-n 2 -j 2 -o " .. shell_quote(root .. "/logs") .. " " .. shell_quote(root .. "/norns"))
  local counts, most = read_lines(root .. "/counts.txt"), 0
  for _, count in ipairs(counts) do most = math.max(most, tonumber(count)) end
  assert_equal(#counts, 6, "every shard of both runs ran: " .. output)
  assert_equal(most, 2, "never more than -j containers at once, and the pool fills: " .. output)
  assert_true(output:find("passed 2 of 2;", 1, true) ~= nil and output:find("exit=0", 1, true) ~= nil, "both runs passed: " .. output)
  h.remove_tree(root)
end)

test("the 3.13 script's -1 and STRATA_ENGINE_CHECK_AREAS run one container per run, as before (#581)", function()
  local shell_quote, root = h.shell_quote, data_root .. "sc313-single"
  fake_313_checkout(root, { "alpha", "beta" }, "    echo \"ENGINE CHECK PASSED\"; exit 0")
  local norns = shell_quote(root .. "/norns")
  local output = run_fake_313(root, "-1 -n 2 -j 2 -o " .. shell_quote(root .. "/one") .. " " .. norns)
  output = output .. run_fake_313(root, "-n 2 -j 2 -o " .. shell_quote(root .. "/named") .. " " .. norns, "STRATA_ENGINE_CHECK_AREAS=beta")
  local runs = read_lines(root .. "/docker-run.txt")
  assert_equal(#runs, 4, "one container per run: " .. output)
  local unset, named = 0, 0
  for _, line in ipairs(runs) do
    assert_true(line:find("%-%-name strata%-sc313%-%d+%-[12] ") ~= nil, "a run's container is named by the run alone: " .. line)
    assert_true(line:find(" -e STRATA_ENGINE_CHECK_AREAS ", 1, true) ~= nil, "the caller's areas pass through: " .. line)
    if line:find("^areas=unset ") then unset = unset + 1 elseif line:find("^areas=beta ") then named = named + 1 end
  end
  assert_equal(unset, 2, "-1 runs every area in one process: " .. output)
  assert_equal(named, 2, "STRATA_ENGINE_CHECK_AREAS runs those areas: " .. output)
  for _, folder in ipairs({ "one", "named" }) do
    for run = 1, 2 do
      assert_true(file_exists(root .. "/" .. folder .. "/run-" .. run .. ".log"), folder .. "/run-" .. run .. ".log is written")
    end
  end
  assert_true(select(2, output:gsub("passed 2 of 2;", "")) == 2, "both invocations passed: " .. output)
  h.remove_tree(root)
end)

test("the 3.13 script reads its shards from the workflow at each start, and refuses a list it cannot read (#581)", function()
  local shell_quote, root = h.shell_quote, data_root .. "sc313-list"
  fake_313_checkout(root, { "alpha", "beta,gamma" }, "    exit 0")
  assert_equal(run_fake_313(root, "-l"), "alpha\nbeta,gamma\nexit=0\n", "-l prints this checkout's shards")
  -- a workflow with no shard list, or an item it cannot read, starts nothing
  for _, shards in ipairs({ {}, { "alpha", "'beta,gamma'" } }) do
    h.remove_tree(root)
    fake_313_checkout(root, shards, "    exit 0")
    local listed = run_fake_313(root, "-l")
    assert_true(listed:find("exit=2", 1, true) ~= nil and listed:find(".github/workflows/test.yml", 1, true) ~= nil,
      "-l refuses, naming the workflow: " .. listed)
    local output = run_fake_313(root, "-n 1 -o " .. shell_quote(root .. "/logs") .. " " .. shell_quote(root .. "/norns"))
    assert_true(output:find("exit=2", 1, true) ~= nil, "a run refuses: " .. output)
    assert_true(not file_exists(root .. "/docker-run.txt"), "no container starts: " .. output)
  end
  h.remove_tree(root)
end)

test("the 3.13 script classifies a sharded run by its worst shard, naming it (#581)", function()
  local shell_quote, checkout = h.shell_quote, data_root .. "sc313-classify-shards"
  fake_313_checkout(checkout, { "alpha", "beta,gamma" }, "    exit 0")
  local root = checkout .. "/logs"
  os.execute("mkdir -p " .. shell_quote(root))
  local crash = "ENGINE CHECK FAILED: sclang ended on signal 11 after 9 s; sclang stopped\n"
  local fixtures = {
    -- every shard passed
    ["1-alpha"] = { 0, "ENGINE CHECK PASSED\nstrata container seconds: 40\n" },
    ["1-beta_gamma"] = { 0, "ENGINE CHECK PASSED\nstrata container seconds: 60\n" },
    -- one shard crashed
    ["2-alpha"] = { 0, "ENGINE CHECK PASSED\nstrata container seconds: 41\n" },
    ["2-beta_gamma"] = { 1, crash .. "strata container seconds: 120\n" },
    -- a failed check outranks a crash in another shard; both are named
    ["3-alpha"] = { 1, "FAIL alpha: a check\n" .. crash },
    ["3-beta_gamma"] = { 1, crash },
  }
  for stem, fixture in pairs(fixtures) do
    local log = assert(io.open(root .. "/run-" .. stem .. ".log", "w")); log:write(fixture[2]); log:close()
    local status = assert(io.open(root .. "/run-" .. stem .. ".status", "w")); status:write(fixture[1] .. "\n"); status:close()
  end
  -- run 4 is a run in one process, in the same folder
  local log = assert(io.open(root .. "/run-4.log", "w")); log:write("ENGINE CHECK PASSED\n"); log:close()
  local status = assert(io.open(root .. "/run-4.status", "w")); status:write("0\n"); status:close()
  local output = run_fake_313(checkout, "-c -n 4 -o " .. shell_quote(root))
  for _, expected in ipairs({ "run 1: passed\n", "run 2: crashed in beta,gamma (sclang ended on signal 11 after 9 s), " .. root .. "/run-2-beta_gamma.log",
      "run 3: failed in alpha (FAIL alpha: a check), " .. root .. "/run-3-alpha.log",
      "  and crashed in beta,gamma (sclang ended on signal 11 after 9 s), " .. root .. "/run-3-beta_gamma.log", "run 4: passed\n",
      "slowest shard: beta,gamma in run 2, 120 s",
      "passed 2 of 4; failed 1; capped 0 (#544); killed 0; collector failure 0 (#211); crashed 1 (#131)",
      -- run 3's crash hides behind its failure in the run counts, never in the shard counts
      "shards: passed 3 of 6; failed 1; capped 0 (#544); killed 0; collector failure 0 (#211); crashed 2 (#131); missing 0", "exit=1" }) do
    assert_true(output:find(expected, 1, true) ~= nil, "the summary holds \"" .. expected .. "\": " .. output)
  end
  h.remove_tree(checkout)
end)

-- Writes run-<stem>.log and .status in folder for each { stem, status, log }
local function write_shard_fixtures(folder, fixtures)
  os.execute("mkdir -p " .. h.shell_quote(folder))
  for _, fixture in ipairs(fixtures) do
    local log = assert(io.open(folder .. "/run-" .. fixture[1] .. ".log", "w")); log:write(fixture[3]); log:close()
    local status = assert(io.open(folder .. "/run-" .. fixture[1] .. ".status", "w")); status:write(fixture[2] .. "\n"); status:close()
  end
end

test("the 3.13 script's -c reads a run's shards in the workflow's order, then any it no longer lists by name (#581)", function()
  local shell_quote, checkout = h.shell_quote, data_root .. "sc313-order"
  -- the workflow's order is not the file names' order
  fake_313_checkout(checkout, { "zeta", "alpha" }, "    exit 0")
  local root = checkout .. "/logs"
  local crash = "ENGINE CHECK FAILED: sclang ended on signal 11 after 9 s; sclang stopped\nstrata container seconds: 50\n"
  write_shard_fixtures(root, { { "1-alpha", 1, crash }, { "1-beta", 1, crash }, { "1-zeta", 1, crash } })
  local output = run_fake_313(checkout, "-c -n 1 -o " .. shell_quote(root))
  local expected = "run 1: crashed in zeta (sclang ended on signal 11 after 9 s), " .. root .. "/run-1-zeta.log\n"
    .. "  and crashed in alpha (sclang ended on signal 11 after 9 s), " .. root .. "/run-1-alpha.log\n"
    .. "  and crashed in beta (sclang ended on signal 11 after 9 s), " .. root .. "/run-1-beta.log\n"
    .. "slowest shard: zeta in run 1, 50 s\n"
  assert_true(output:find(expected, 1, true) ~= nil, "a tie goes to the workflow's first shard, an unlisted one comes last: " .. output)
  h.remove_tree(checkout)
end)

test("the 3.13 script's -c reports a run missing some of the workflow's shards as incomplete (#581)", function()
  local shell_quote, checkout = h.shell_quote, data_root .. "sc313-incomplete"
  fake_313_checkout(checkout, { "zeta", "alpha", "delta" }, "    exit 0")
  local root = checkout .. "/logs"
  local passed = "ENGINE CHECK PASSED\n"
  write_shard_fixtures(root, {
    -- run 1 is whole; run 2 has alpha alone, and it passed; run 3 lacks delta and its zeta crashed
    { "1-zeta", 0, passed }, { "1-alpha", 0, passed }, { "1-delta", 0, passed }, { "2-alpha", 0, passed },
    { "3-zeta", 1, "ENGINE CHECK FAILED: sclang ended on signal 11 after 9 s; sclang stopped\n" }, { "3-alpha", 0, passed },
    -- run 4 is in the old single-process layout, never incomplete
    { "4", 0, passed },
  })
  local output = run_fake_313(checkout, "-c -n 4 -o " .. shell_quote(root))
  for _, expected in ipairs({ "run 1: passed\n", "run 2: incomplete (no log for zeta,delta)\n", "run 3: incomplete (no log for delta)\n",
      "  and crashed in zeta (sclang ended on signal 11 after 9 s), " .. root .. "/run-3-zeta.log", "run 4: passed\n",
      "passed 2 of 4; failed 0; capped 0 (#544); killed 0; collector failure 0 (#211); crashed 0 (#131); incomplete 2",
      "shards: passed 5 of 9; failed 0; capped 0 (#544); killed 0; collector failure 0 (#211); crashed 1 (#131); missing 3", "exit=1" }) do
    assert_true(output:find(expected, 1, true) ~= nil, "the summary holds \"" .. expected .. "\": " .. output)
  end
  h.remove_tree(checkout)
end)

test("the 3.13 script classifies a run by its log (#545, #544)", function()
  local shell_quote, root = h.shell_quote, data_root .. "sc313-classify"
  os.execute("mkdir -p " .. shell_quote(root))
  -- the collector's own line (sclang spells it with an e; split here for the US spelling check)
  local COUNT_ERROR = "gr" .. "ey count error"
  local fixtures = {
    -- a FAIL line makes it failed, whatever ended it
    { status = 1, log = "ok a check\nFAIL waveform: a 300 s load\nENGINE CHECK FAILED: sclang ended on signal 9 after 752 s; sclang stopped\n" },
    -- a signal after count errors: the collector failure (#211)
    -- (the lines are as sclang 3.13 printed them in a real run: bare, and inside its exception report)
    { status = 1, log = COUNT_ERROR .. "\n" .. COUNT_ERROR .. "\ncaught exception '" .. COUNT_ERROR .. "\n' in primitive in method Meta_Thread:primitiveErrorString\nENGINE CHECK FAILED: sclang ended on signal 11 after 300 s; sclang stopped\n" },
    -- a bare signal: #131
    { status = 1, log = "ok a check\nENGINE CHECK FAILED: sclang ended on signal 6 after 90 s; sclang stopped\n" },
    -- the memory cap's kill
    { status = 1, log = COUNT_ERROR .. "\nENGINE CHECK FAILED: sclang ended on signal 9 after 400 s; sclang stopped\nstrata cgroup oom_kill: 3\n" },
    -- ERROR and an invariant line are failures too
    { status = 1, log = "ERROR: something\nENGINE CHECK FAILED: sclang ended on signal 9 after 4 s; sclang stopped\n" },
    { status = 0, log = "ENGINE CHECK PASSED\nstrata cgroup oom_kill: 0\n" },
    -- exit 137 with no cap kill: stopped from outside, not capped
    { status = 137, log = "ok a check\nstrata cgroup oom_kill: 0\n" },
    -- a count error inside sclang's exception report alone still marks the collector
    { status = 1, log = "caught exception '" .. COUNT_ERROR .. "\n' in primitive\nENGINE CHECK FAILED: sclang ended on signal 6 after 9 s; sclang stopped\n" },
  }
  for index, fixture in ipairs(fixtures) do
    local log = assert(io.open(root .. "/run-" .. index .. ".log", "w")); log:write(fixture.log); log:close()
    local status = assert(io.open(root .. "/run-" .. index .. ".status", "w")); status:write(fixture.status .. "\n"); status:close()
  end
  -- classifying alone makes no folder: -c without -o is refused
  local refused = run_313_script(root, "-c -n 1")
  assert_true(refused:find("-c needs -o", 1, true) ~= nil and refused:find("exit=2", 1, true) ~= nil, "-c without -o is refused: " .. refused)
  local listing = io.popen("ls " .. shell_quote(root))
  local made = {}
  for name in listing:lines() do if name:match("^strata%-sc313%-logs") then made[#made + 1] = name end end
  listing:close()
  assert_equal(#made, 0, "no log folder is made when only classifying")
  local output = run_313_script(root, "-c -n " .. #fixtures .. " -o " .. shell_quote(root))
  for _, expected in ipairs({ "run 1: failed (FAIL waveform", "run 2: collector failure (#211", "run 3: crashed (sclang ended on signal 6",
      "run 4: capped (", "run 5: failed (ERROR: something", "run 6: passed", "run 7: killed (exit 137", "run 8: collector failure (#211", "exit=1" }) do
    assert_true(output:find(expected, 1, true) ~= nil, "the summary holds \"" .. expected .. "\": " .. output)
  end
  assert_true(output:find("passed 1 of 8; failed 2; capped 1 (#544); killed 1; collector failure 2 (#211); crashed 1 (#131)", 1, true) ~= nil,
    "the counts: " .. output)
  -- a cap kill with no FAIL line is its own outcome
  os.execute("rm -f -- " .. shell_quote(root .. "/run-1.log") .. " " .. shell_quote(root .. "/run-1.status"))
  local capped = assert(io.open(root .. "/run-1.log", "w"))
  capped:write("ok a check\nENGINE CHECK FAILED: sclang ended on signal 9 after 400 s; sclang stopped\nstrata cgroup oom_kill: 1\n")
  capped:close()
  local capped_status = assert(io.open(root .. "/run-1.status", "w")); capped_status:write("1\n"); capped_status:close()
  output = run_313_script(root, "-c -n 1 -o " .. shell_quote(root))
  assert_true(output:find("run 1: capped (", 1, true) ~= nil and output:find("capped 1 (#544)", 1, true) ~= nil, "a cap kill is capped: " .. output)
  h.remove_tree(root)
end)

-- The workflow (#490, #533): read-only token, credentials not kept, norns
-- pinned by its full commit, actions/checkout by commit on the current major
local function read_repo_text(path)
  local file = assert(io.open(repo_root .. "/" .. path, "r")); local text = file:read("*a"); file:close()
  return text
end

test("the workflow reads only, keeps no credentials and pins by full commit (#490, #533)", function()
  local workflow = read_repo_text(".github/workflows/test.yml")
  assert_true(workflow:find("\npermissions:\n  contents: read\n") ~= nil, "a top-level permissions: contents: read")
  local checkouts = 0
  for step in workflow:gmatch("%-%s*uses:%s*actions/checkout@[^\n]*\n[^\n]*\n[^\n]*") do
    checkouts = checkouts + 1
    assert_true(step:find("persist%-credentials: false") ~= nil, "a checkout keeps no credentials: " .. step)
  end
  assert_equal(checkouts, 2, "both checkouts")
  local pins = 0
  for pin, version in workflow:gmatch("actions/checkout@(%S+)%s*#%s*v(%d+)") do
    pins = pins + 1
    assert_true(pin:match("^%x+$") ~= nil and #pin == 40, "actions/checkout is pinned by its 40-character commit: " .. pin)
    assert_true(tonumber(version) >= 7, "actions/checkout is on the current major (v7 or later), not v" .. version)
  end
  assert_equal(pins, 2, "both checkouts are pinned by commit with a version comment")
  local ref = workflow:match("NORNS_REF:%s*(%S+)")
  assert_true(ref ~= nil and #ref == 40 and ref:match("^%x+$") ~= nil, "NORNS_REF is a full 40-character commit: " .. tostring(ref))
end)

-- #491: the docs say what the runner runs, in its order, and how long a
-- full run takes (the workflow's own area times)
test("the engine notes give the runner's area order and the full run's time (#491)", function()
  local runner = read_repo_text("test/engine_check.scd"):gsub("//[^\n]*", "")
  local order = {}
  for name in runner:match("var%s+areaOrder%s*=%s*(%b[])"):gmatch("\\(%w+)") do order[#order + 1] = name end
  local notes = read_repo_text("docs/notes/engine/structure.md")
  local listed = notes:match("%(`areaOrder`: ([^)]-)%)")
  assert_true(listed ~= nil, "structure.md gives areaOrder in a parenthesis")
  local names = {}
  for name in listed:gsub("then the on%-demand ", ""):gmatch("%a+") do names[#names + 1] = name end
  assert_equal(table.concat(names, " "), table.concat(order, " "), "structure.md's areaOrder sentence, in the runner's order")
  local times = read_repo_text(".github/workflows/test.yml"):match("Area times on [^\n]*:([^\n]*\n[^\n]*\n[^\n]*)")
  times = times:match("^(.-):") or times
  local total = 0
  for seconds in times:gmatch("%a+ (%d+)") do total = total + tonumber(seconds) end
  assert_true(total > 500, "the workflow's area times sum (" .. total .. " s)")
  local minutes = math.floor(total / 60 + 0.5)
  for _, path in ipairs({ "AGENTS.md", "docs/checks.md", "docs/notes/test-harness/engine-check-runner.md",
      "docs/notes/engine/structure.md", "test/run_engine_check.sh" }) do
    local text = read_repo_text(path)
    assert_true(text:find("about " .. minutes .. " minutes", 1, true) ~= nil,
      path .. " says a full run takes about " .. minutes .. " minutes (the workflow's area times sum to " .. total .. " s)")
    assert_true(text:find("about 9 minutes", 1, true) == nil, path .. " still says 9 minutes")
  end
end)

-- The peak scan (#131): fileDecodes and every method of StrataFiles.sc it
-- calls allocate no array per sample and run no sclang function per sample.
-- Signal peak is a C primitive; maxItem and minItem are Collection methods
-- that call a function for every sample.
local function peak_scan_findings(text, name)
  local found = {}
  local body = sc_method_body(text, name) or ""
  for _, pattern in ipairs({ "%.abs", "[%s%(]abs%(", "copyRange", "collect", "maxItem", "minItem" }) do
    if body:find(pattern) then found[#found + 1] = name .. ": " .. pattern end
  end
  if body:find("FloatArray%.fill%s*%([^,]+,%s*{") then found[#found + 1] = name .. ": FloatArray.fill with a function" end
  for _, target in ipairs(stale_reads(body)) do found[#found + 1] = name .. ": stale readData " .. target end
  return found
end

test("no script file lists a folder with util.scandir (#465)", function()
  local found = {}
  for _, source in ipairs(read_lua_sources()) do
    if sync_check.sanitize_lua(source.text):find("util%.scandir") then found[#found + 1] = source.path end
  end
  assert_equal(table.concat(found, ", "), "", "util.scandir puts the folder between double quotes: list through files.lua's list_folder")
end)

test("the peak scan allocates nothing per sample", function()
  assert_equal(#peak_scan_findings("\n  caught { var a; b = c.abs; }", "caught"), 1, "caught: a per-sample abs")
  assert_equal(#peak_scan_findings("\n  caught { var a; b = chunk.maxItem; }", "caught"), 1, "caught: maxItem")
  assert_equal(#peak_scan_findings("\n  caught { x = FloatArray.fill(n, { 0 }) }", "caught"), 1, "caught: a fill with a function")
  assert_equal(#peak_scan_findings("\n  caught { chunk = this.freshReadArray(8);\nfile.readData(chunk); b = chunk.peak }", "caught"), 0, "allowed: fresh reads and peak")
  local text
  for _, file in ipairs(engine_files()) do
    if file.path:match("StrataFiles%.sc$") then text = file.text end
  end
  assert_true(text ~= nil, "the engine sources hold StrataFiles.sc")
  local names, seen = { "fileDecodes" }, { fileDecodes = true }
  for called in (sc_method_body(text, "fileDecodes") or ""):gmatch("this%.([%a_][%w_]*)") do
    if not seen[called] and sc_method_body(text, called) then
      seen[called] = true
      names[#names + 1] = called
    end
  end
  assert_true(#names >= 2, "fileDecodes calls methods of StrataFiles.sc (found " .. #names .. ")")
  for _, name in ipairs(names) do
    local findings = peak_scan_findings(text, name)
    assert_equal(#findings, 0, table.concat(findings, ", "))
  end
end)

-- A norns poll has one callback: only lib/input_level.lua names the input
-- level polls (a page's layout state may fire a value, which sets nothing)
test("only lib/input_level.lua names the input polls", function()
  local offenders = {}
  for _, source in ipairs(read_lua_sources()) do
    if source.path ~= "lib/input_level.lua" then
      for line in (source.text .. "\n"):gmatch("(.-)\n") do
        if line:find("amp_in_[lr]") and not line:find("context.polls.fire", 1, true) and not line:match("^%s*%-%-") then
          offenders[#offenders + 1] = source.path
          break
        end
      end
    end
  end
  assert_equal(table.concat(offenders, " "), "", "a norns poll has one callback")
end)

end

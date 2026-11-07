-- test/unit/structure_test.lua
-- The script's structure: includes, S, module homes, constants, the
-- static checks that every global read is defined and none is defined in
-- two files, the free-locals probe, the cleanup order and the param-type
-- comparison check
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
  ["lib/engine_sync.lua"] = { "send_param_to_engine", "engine_param_value", "toggle_voice", "toggle_freeze",
    "sync_voice_to_engine", "sync_voice_values_to_engine" },
  ["lib/buffers.lua"] = { "scratch_take_path", "confirm_buffer_audio", "settle_buffer_slot",
    "set_buffer_file_param", "empty_buffer_state", "buffer_state_before_load", "load_buffer", "record_buffer",
    "clear_buffer", "buffer_save_path", "save_buffer", "buffer_load_failed", "save_buffers_to_disk",
    "load_buffers_from_disk" },
  ["lib/lfos.lua"] = { "lfo_destination_id", "restore_lfo_destination", "apply_lfo", "lfo_phase_estimate",
    "add_lfo_params" },
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
  ["lib/ui/params.lua"] = { "param_range", "param_spans_zero", "param_default", "param_value_fraction",
    "param_fraction" },
  ["lib/ui/header.lua"] = { "draw_header", "draw_hints" },
  ["lib/ui/flash.lua"] = { "header_flash" },
  ["lib/ui/keys.lua"] = { "forget_held_keys" },
  ["lib/ui/alt.lua"] = { "alt_action" },
  ["lib/ui/detent.lua"] = { "delta_with_detent", "enc_param_delta" },
  ["lib/ui/menu_watch.lua"] = { "forget_keys_held_through_menu", "watch_menu_opening", "unwatch_menu_opening" },
  ["lib/pages/main.lua"] = { "update_voice_list", "main_param_entry", "main_param_id", "main_param_label",
    "redraw_main" },
  ["lib/pages/fx.lua"] = { "redraw_fx" },
  ["lib/pages/lfo.lua"] = { "lfo_shape_value", "redraw_lfo" },
  ["lib/pages/buffer.lua"] = { "buffer_page_flash", "redraw_buffer",
    "close_buffer_file_selector", "release_superseded_file_selector" },
  ["lib/pages/setup.lua"] = { "redraw_setup", "setup_enc" },
  ["lib/arc/core.lua"] = { "arc_sweep_param", "arc_ring_fill", "arc_ring_fill_bipolar", "arc_ring_fill_param",
    "arc_whole_steps", "forget_arc_ticks", "arc_init", "first_arc_port", "arc_delta", "arc_key", "arc_redraw",
    "forget_arc_lfo_period_ticks" },
  ["lib/grid/core.lua"] = { "grid_init", "grid_key", "grid_redraw", "select_grid_voice" },
  ["lib/grid/faders.lua"] = { "voice_level_fader_keys", "fader_param_ids", "fader_page_count",
    "fader_zero_column", "fader_column_fraction", "set_param_from_column", "set_fader_param", "fader_position",
    "grid_redraw_fader_row", "grid_redraw_faders" },
  ["lib/grid/layout_256.lua"] = { "grid_key_256", "grid_key_256_transport", "grid_key_256_freeze",
    "grid_redraw_256", "grid_redraw_256_buffers", "grid_redraw_256_sources", "grid_redraw_256_page_row",
    "grid_redraw_256_transport", "grid_redraw_256_freeze" },
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

-- Globals more than one script file may write: lib/pages/buffer.lua puts
-- back the script's own key and enc when the file selector fails
local GLOBALS_WRITTEN_IN_TWO_FILES = { key = true, enc = true }

-- Every global (a global function or any other value) that more than one
-- of a list of { path, text } files writes, as "<name>: <path>:<line>,
-- <path>:<line>, ..."
local function globals_written_twice(root, sources, allowed)
  local homes, problems = {}, {}
  for _, source in ipairs(sources) do
    local _, writes = global_accesses(root .. "/" .. source.path, source.path)
    for name, where in next, writes do
      homes[name] = homes[name] or {}
      table.insert(homes[name], where)
    end
  end
  for name, places in next, homes do
    if #places > 1 and not allowed[name] then
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
  -- written twice in the same file or allowed is not
  local scratch = data_root .. "duplicate_global_check"
  os.execute("mkdir -p '" .. scratch .. "/lib'")
  local files = {
    { path = "strata.lua", text = "function twice() end\nvalue_twice = 1\nonce = 1\nonce = 2\nfunction allowed() end\n" },
    { path = "lib/x.lua", text = "return function() function twice() end value_twice = 2 allowed = nil end\n" },
  }
  for _, source in ipairs(files) do
    local out = assert(io.open(scratch .. "/" .. source.path, "w")); out:write(source.text); out:close()
  end
  local found = globals_written_twice(scratch, files, { allowed = true })
  local names = {}
  for _, entry in ipairs(found) do table.insert(names, entry:match("^([^:]*)")) end
  assert_equal(table.concat(names, " "), "twice value_twice", "each global defined in two files is found:\n  "
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
local CLEANUP_STEPS = { "tempo handler", "menu watch", "scenes saved", "buffer paths saved", "startup clock",
  "frame clock", "drift metro", "mutation metro", "undo clock", "pattern clock", "scene sequencer", "scene transition",
  "lfos", "buffer polls and timers", "flashes", "midi handler", "voices off", "grids dark", "arc dark" }

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
  params:set("lfo_1", 2)
  record_buffer(1)
  buffer_page_flash("flash")
  randomize_voice(1)  -- after the recall, which clears the undo: its expiry clock runs
  header_flash("flash")

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
    { "flashes", S.lib.ui_flash.slots.hints.clock }, { "flashes", S.lib.ui_flash.slots.header.clock } }
  local clock_steps = {}
  for _, entry in ipairs(clocks) do
    assert_true(entry[2] ~= nil, entry[1] .. ": its clock runs before cleanup")
    clock_steps[entry[2]] = entry[1]
  end
  local param_steps = { mutation_enabled = "mutation metro", scene_sequencer_enabled = "scene sequencer" }
  for n = 1, local_value("NUM_LFOS") do param_steps["lfo_" .. n] = "lfos" end
  local file_steps = { ["scenes.data"] = "scenes saved", ["buffers.data"] = "buffer paths saved" }

  watch_field(clock, "tempo_change_handler", "tempo handler")
  watch_field(_menu, "set_mode", "menu watch")
  local real_save = tab.save
  tab.save = function(value, path)
    observe(file_steps[path:match("[^/]*$")] or ("file " .. path))
    return real_save(value, path)
  end
  local real_cancel = clock.cancel
  clock.cancel = function(id) observe(clock_steps[id] or ("clock " .. tostring(id))); return real_cancel(id) end
  watch_method(S.drift_metro, "stop", "drift metro")
  watch_method(S.mutation_metro, "stop", "mutation metro")
  local real_set = params.set
  params.set = function(self, id, ...)
    if param_steps[id] then observe(param_steps[id]) end
    return real_set(self, id, ...)
  end
  for n = 1, local_value("NUM_LFOS") do watch_method(S.lfos[n], "stop", "lfos") end
  watch_method(S.buffer_polls.state, "stop", "buffer polls and timers")
  watch_method(S.buffer_polls.load_failed, "stop", "buffer polls and timers")
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
  tab.save, clock.cancel, params.set = real_save, real_cancel, nil
  grid_redraw, arc_redraw = real_grid_redraw, real_arc_redraw
  assert_true(ok, tostring(problem))

  local expected = {}
  for _, step in ipairs(CLEANUP_STEPS) do table.insert(expected, "|"); table.insert(expected, step) end
  assert_equal(table.concat(log, ", "), table.concat(expected, ", "), "one registered step per effect, in order")
  -- S.constants.CLEANUP_ORDER names each step's order, and no two steps share one
  local orders = 0
  for _ in pairs(S.constants.CLEANUP_ORDER) do orders = orders + 1 end
  assert_equal(orders, #CLEANUP_STEPS, "CLEANUP_ORDER has one order per step")
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
  local voice_sync = { "engine.voiceOn", "engine.setGrainSource", "engine.setVoiceParam", "engine.setGrainParam" }
  for _ = 1, local_value("NUM_MOD_SLOTS") do
    for _, command in ipairs({ "engine.setModSource", "engine.setModAmpAmt", "engine.setModFreqAmt" }) do
      table.insert(voice_sync, command)
    end
  end
  for _, effect in ipairs({ "engine.setModSpeed", "engine.setVoiceParam", "voice list built", "redraw requested",
      "grid redrawn" }) do
    table.insert(voice_sync, effect)
  end
  table.insert(voice_sync, 1, "clock started")
  return {
    { "voice list", { "voice list built" } },
    { "E1 settings", { "encoder 1 accel false", "encoder 1 sens 4" } },
    { "menu watch", { "menu watched" } },
    { "drift metro", { "metro created", "drift metro started" } },
    { "mutation metro", { "metro created" } },
    { "buffer polls", { "poll set bufferState", "poll started bufferState", "poll set bufferLoadFailed",
      "poll started bufferLoadFailed" } },
    { "arc", { "arc connected" } },
    { "grids", { "grid connected", "print grid 1 connected: 16x16", "grid connected", "grid redrawn" } },
    { "midi", { "midi connected" } },
    { "scenes load", { "file read scenes.data", "print scenes loaded from scenes.data", "grid redrawn" } },
    { "buffers load", { "file read buffers.data", "engine.loadBuffer", "redraw requested", "grid redrawn",
      "print 1 buffers reloading from buffers.data" } },
    { "startup clock", voice_sync },
    { "frame clock", { "clock started" } },
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
    wrap_function(tab, "load", function(path) return "file read " .. path:match("[^/]*$") end)
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

end

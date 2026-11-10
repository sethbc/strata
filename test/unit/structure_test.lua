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
  ["lib/engine_sync.lua"] = { "send_param_to_engine", "engine_param_value", "toggle_voice", "toggle_lock",
    "sync_voice_to_engine", "sync_voice_values_to_engine" },
  ["lib/buffers.lua"] = { "scratch_take_path", "confirm_buffer_audio", "settle_buffer_slot",
    "set_buffer_file_param", "empty_buffer_state", "buffer_state_before_load", "load_buffer",
    "clear_buffer", "buffer_save_path", "save_buffer", "buffer_load_failed", "buffer_save_result",
    "save_buffers_to_disk", "load_buffers_from_disk", "save_buffer_loop" },
  ["lib/record.lua"] = { "record_buffer" },
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
  "lfos", "playheads clock", "scan holds", "waveform loop", "buffer start reload", "buffer polls and timers",
  "input meter", "flashes", "midi handler", "voices off", "grids dark", "arc dark" }

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
  context.audio.register("/tmp/long.wav", { channels = 2, frames = 48000 * 60, rate = 48000 })
  load_buffer(2, "/tmp/long.wav"); S.lib.buffers.set_start(2, 5)  -- a start reload waits
  buffer_page_flash("flash")
  randomize_voice(1)  -- after the recall, which clears the undo: its expiry clock runs
  header_flash("flash")
  S.lib.ui_keys.set_ui_page(S.constants.UI_PAGES.index.BUFFER)  -- its input meter polls run
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  S.lib.positions.hold_scan(1, true)  -- a scan hold for cleanup to end

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
    { "playheads clock", S.lib.playheads.clock_id() } }
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
  watch_method(S.lib.positions, "hold_scan", "scan holds")
  local real_set = params.set
  params.set = function(self, id, ...)
    if param_steps[id] then observe(param_steps[id]) end
    return real_set(self, id, ...)
  end
  for n = 1, local_value("NUM_LFOS") do watch_method(S.lfos[n], "stop", "lfos") end
  watch_method(S.buffer_polls.state, "stop", "buffer polls and timers")
  watch_method(S.buffer_polls.load_failed, "stop", "buffer polls and timers")
  for _, input_poll in pairs(S.lib.pages_buffer.meter.polls) do watch_method(input_poll, "stop", "input meter") end
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
  table.insert(voice_sync, "engine.setModSpeed")
  table.insert(voice_sync, "engine.setVoiceParam")
  -- the registered voice params' grain keys (lib/history.lua's history)
  if #local_value("S").registry.voice_params > 0 then table.insert(voice_sync, "engine.setGrainParam") end
  for _, effect in ipairs({ "voice list built", "redraw requested", "grid redrawn" }) do
    table.insert(voice_sync, effect)
  end
  table.insert(voice_sync, 1, "clock started")
  return {
    { "voice list", { "voice list built" } },
    { "voice layout states", {} },
    { "E1 settings", { "encoder 1 accel false", "encoder 1 sens 4" } },
    { "menu watch", { "menu watched" } },
    { "drift metro", { "metro created", "drift metro started" } },
    { "mutation metro", { "metro created" } },
    { "buffer polls", { "poll set bufferState", "poll started bufferState", "poll set bufferLoadFailed",
      "poll started bufferLoadFailed", "poll set bufferSaveResult", "poll started bufferSaveResult" } },
    { "arc", { "arc connected" } },
    { "grids", { "grid connected", "print grid 1 connected: 16x16", "grid connected", "grid redrawn" } },
    { "midi", { "midi connected" } },
    { "scenes load", { "file read scenes.data", "print scenes loaded from scenes.data", "grid redrawn" } },
    { "buffers load", { "file read buffers.data", "engine.loadBuffer", "redraw requested", "grid redrawn",
      "print 1 buffers reloading from buffers.data" } },
    { "startup clock", voice_sync },
    { "frame clock", { "clock started" } },
    { "waveform loop", { "clock started" } },
    { "playheads", { "clock started" } },
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
local ENGINE_AREAS = { performance = 10, voices = 20, grains = 30, buffers = 40, files = 50, effects = 60, rings = 70 }

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

local function constant_chunk_loop_findings(body)
  local found = {}
  local condition, loop = (body or ""):match("while%s*(%b{})%s*(%b{})")
  if not loop then return { "no while loop" } end
  for _, pattern in ipairs({ "repeating%.%(", "Signal%.newClear", "FloatArray%.newClear", "%(0%s*%.%." }) do
    if (condition .. loop):find(pattern) then table.insert(found, pattern) end
  end
  if not loop:find("writeData%(") then table.insert(found, "the loop writes nothing") end
  return found
end

test("the engine check builds a constant file's chunk once, not per chunk (#207)", function()
  local old = "{ arg file, frames, values;\n    var left = frames;\n    while { left > 0 } {\n"
    .. "        file.writeData(repeating.(left.min(65536) * values.size, values));\n        left = left - 65536;\n    };\n}"
  assert_true(#constant_chunk_loop_findings(old) > 0, "caught: a chunk built in the loop")
  local file = assert(io.open(repo_root .. "/test/engine_check.scd", "r"))
  local text = file:read("*a")
  file:close()
  local body = sc_function_body(text, "writeConstantFrames")
  assert_true(body ~= nil, "test/engine_check.scd defines writeConstantFrames")
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

local function recursive_delete(line)
  return line:match("%f[%w]rm%s+%-%-?[%a]*[rR]") ~= nil or line:match("%f[%w]rm%s+%-%-recursive") ~= nil
    or line:match("rmtree") ~= nil or line:match("deleteAll") ~= nil
end

test("recursive deletes happen only at the guarded sites", function()
  for _, line in ipairs({ "rm -rf /x", "rm -r dir", "rm -fr dir", 'os.execute("rm -Rf " .. d)', "rm --recursive d",
      "shutil.rmtree(p)", "File.deleteAll(p)" }) do
    assert_true(recursive_delete(line), "caught: " .. line)
  end
  for _, line in ipairs({ "rm file.txt", "os.remove(path)", "File.delete(path)", "-- a firm -r flag", "perform -r" }) do
    assert_true(not recursive_delete(line), "allowed: " .. line)
  end
  local listing = assert(io.popen("cd '" .. repo_root .. "' && git ls-files")):read("*a")
  local seen = {}
  for path in listing:gmatch("[^\n]+") do
    -- this file is skipped: its samples above are what the scan looks for
    if path ~= "test/unit/structure_test.lua" and (path:match("%.lua$") or path:match("%.sc$")
        or path:match("%.scd$") or path:match("%.sh$") or path:match("%.py$") or path:match("%.yml$")
        or path:match("%.in$")) then
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

local function run_runner_without_tools(case, timeout)
  local shell_quote, root = h.shell_quote, data_root .. "runner-" .. case
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
  -- a script, not a link to sleep: a multi-call coreutils refuses to run
  -- under another name. It sleeps in 1 s steps, so a stopped one leaves
  -- no long sleep behind
  local server = assert(io.open(root .. "/scsynth", "w"))
  server:write("#!/bin/sh\ncount=0\nwhile [ $count -lt 60 ]; do sleep 1; count=$((count + 1)); done\n")
  server:close()
  os.execute("chmod +x " .. shell_quote(root .. "/scsynth"))
  local lines = { "#!/bin/sh", shell_quote(root .. "/scsynth") .. " 60 &", "echo $! > " .. shell_quote(root .. "/fake.pid") }
  if case == "compile-error" then
    lines[#lines + 1] = 'echo "ERROR: syntax error, unexpected"'
    lines[#lines + 1] = "sleep 60"
  elseif case == "hang" then
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
  local pipe = io.popen("cd " .. shell_quote(repo_root) .. " && PATH=" .. shell_quote(root .. "/bin")
    .. " SCLANG=" .. shell_quote(root .. "/sclang") .. " ENGINE_CHECK_TIMEOUT=" .. (timeout or 30) .. " TMPDIR=" .. shell_quote(root)
    .. " STRATA_SC_PORT=57399 /bin/sh test/run_engine_check.sh " .. shell_quote(root .. "/norns") .. " 2>&1")
  local output = pipe:read("*a")
  pipe:close()
  local pid_file = io.open(root .. "/fake.pid", "r")
  local pid = pid_file and pid_file:read("*l")
  if pid_file then pid_file:close() end
  local alive = pid ~= nil and pid:match("^%d+$") ~= nil and os.execute("kill -0 " .. pid .. " 2>/dev/null")
  alive = alive == true or alive == 0
  if alive then os.execute("kill " .. pid .. " 2>/dev/null") end
  h.remove_tree(root)
  return output, pid, alive
end

test("the engine check runner stops sclang's scsynth without pgrep or timeout (#152)", function()
  local output, pid, alive = run_runner_without_tools("compile-error")
  assert_true(pid ~= nil, "the fake sclang started its server: " .. output)
  assert_true(output:find("sclang reported a compile error", 1, true) ~= nil, "the runner stopped sclang: " .. output)
  assert_true(not alive, "the server sclang started is stopped with it")
end)

-- 1 s timeout: without a timeout command the runner's own loop stops it
-- 15 s later
test("the engine check runner tells a hung sclang from a slow check (#131)", function()
  local output, pid, alive = run_runner_without_tools("hang", 1)
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

end

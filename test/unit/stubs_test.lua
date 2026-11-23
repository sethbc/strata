-- test/unit/stubs_test.lua
-- The harness: the norns stubs (params, clock, midi, arc, tabutil,
-- fileselect, ...), load_strata's data directories and the runner
-- Run alone: lua test/run.lua stubs

return function(h)
local test, test_dir, repo_root, stubs, signatures = h.test, h.test_dir, h.repo_root, h.stubs, h.signatures
local engine_polls, engine_spec, data_root, tests = h.engine_polls, h.engine_spec, h.data_root, h.tests
local run_test, assert_true, assert_equal = h.run_test, h.assert_true, h.assert_equal
local assert_near, load_strata, local_value = h.assert_near, h.load_strata, h.local_value
local finish_startup, patched_script, text_width = h.finish_startup, h.patched_script, h.text_width
local unit_files, load_unit_files = h.unit_files, h.load_unit_files

-- A lib/state replacement whose S has marker 2, empty registries (plus
-- `extra_registry`, a Lua table field list such as "invariants = {}") and
-- register functions that do nothing
local function stub_state_source(extra_registry)
  return "return function() return { marker = 2, registry = { pages = {}, params = {}, start = {}, cleanup = {},"
    .. " grid_layouts = {}, voice_params = {}, scene_fields = {}, source_change = {}, param_filters = {},"
    .. " lfo_destinations = {}, fx_params = {}, menu_close = {}, mod_sources = {},"
    .. " ii_devices = {}, grid_pages = {}, voice_types = {}, " .. extra_registry .. " }, lib = {}, register_start = function() end,"  -- ii_devices: lib/io/ii.lua's add_params at init
    .. " register_cleanup = function() end, register_voice_params = function() end, register_fx_params = function() end,"
    .. " register_lfo_destination = function() end, register_param_filter = function() end,"
    .. " register_source_change = function() end, register_scene_field = function() end,"
    .. " register_grain_restart = function() end, register_alt_release = function() end,"
    .. " register_menu_close = function() end, close_registries = function() end,"
    .. " register_invariant = function() end,"
    -- 3.4's (lib/state.lua): the register functions a module calls as it loads
    .. " register_scene_block = function() end,"
    .. " register_pset_hook = function() end, register_param_touch = function() end,"
    .. " register_lock_change = function() end, register_lfo_global_destination = function() end,"
    .. " register_step_output = function() end, register_mod_source = function() end,"
    -- 3.5's
    .. " register_voice_stop = function() end, register_freeze_change = function() end,"
    -- 3.6's (the lib/io modules call these as they load)
    .. " register_note_hook = function() end, register_silence_change = function() end,"
    .. " register_scene_recalled = function() end,"
    .. " register_note_target = function() end, register_macro_target = function() end,"
    .. " register_io_section = function() end, register_ii_device = function() end,"
    -- 3.7's (lib/delay_sync.lua calls it as it loads)
    .. " register_scene_applied = function() end,"
    -- 3.7's (lib/random_sequences.lua registers its voice_hit hook as it loads)
    .. " register_voice_hit = function() end,"
    -- 3.8's (each lib/grid/pages/ file registers its page as it loads)
    .. " register_grid_page = function() end,"
    -- 3.8's (each lib/types/ file registers its voice type as it loads)
    .. " register_voice_type = function() end } end"
end

test("each load gets its own data directory, even after the same random seed (#50)", function()
  math.randomseed(1); local first = load_strata()
  math.randomseed(1); local second = load_strata()
  assert_true(first.data_dir ~= second.data_dir, "two loads share " .. first.data_dir)
end)

-- 3.8 (4d): the script's folder, as Script.load sets it (with a trailing
-- /), an empty folder of the load's own unless the test names one, so no
-- test start finds a factory set
test("norns.state.path is an empty folder unless a test names one", function()
  local context = load_strata()
  local path = norns.state.path
  assert_equal(path, context.data_dir .. "script/", "the load's own script folder")
  assert_equal(context.script_dir, path, "the context names it")
  assert_true(util.file_exists(path), "it exists")
  local listing = io.popen("ls -A " .. h.shell_quote(path)):read("*a")
  assert_equal(listing, "", "and is empty")
  local named = data_root .. "named_script/"
  os.execute("mkdir -p " .. h.shell_quote(named))
  context = load_strata({ script_dir = named })
  assert_equal(norns.state.path, named, "a named folder is the script's")
  assert_equal(context.script_dir, named)
end)

-- A name that is no field of S or S.constants is looked for among the
-- global functions' upvalues; two of them holding different locals of that
-- name would make the answer depend on pairs(_G)'s order, which changes
-- from run to run (#482)
test("find_upvalue raises for a name whose upvalues hold different values (#482)", function()
  load_strata()
  local ok, message = pcall(local_value, "M")
  assert_true(not ok, "every module has its own local M")
  assert_true(tostring(message):find("script local 'M' has different values", 1, true), "the error says why: "
    .. tostring(message))
  assert_equal(local_value("S"), h.shared_state(), "a name every function shares is found")
  -- two functions, two locals of one name: one value is found, and the
  -- setter writes both; two values are an error naming both functions
  local shared = {}
  local function holder(value) local probe_local = value; return function() return probe_local end end
  rawset(_G, "probe_holder_one", holder(shared)); rawset(_G, "probe_holder_two", holder(shared))
  local value, set = h.find_upvalue("probe_local")
  assert_equal(value, shared, "one value")
  set(5)
  assert_equal(probe_holder_one(), 5, "the setter writes the first"); assert_equal(probe_holder_two(), 5, "and the second")
  rawset(_G, "probe_holder_two", holder({}))
  ok, message = pcall(h.find_upvalue, "probe_local")
  rawset(_G, "probe_holder_one", nil); rawset(_G, "probe_holder_two", nil)
  assert_true(not ok and tostring(message):find("probe_holder_one", 1, true)
    and tostring(message):find("probe_holder_two", 1, true), "both functions are named: " .. tostring(message))
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
  load_strata { module_sources = { ["lib/state"] = stub_state_source("invariants = {}") } }
  assert_equal(local_value("S").marker, 2, "load_strata's module_sources reach include")
end)

-- norns paints a path at stroke() or fill() with the level in force then,
-- not the one set when screen.line or screen.rect built it (#474)
test("the screen stub records a path at the level it is painted with (#474)", function()
  local context = load_strata(); finish_startup(context)
  screen.clear()
  screen.level(4); screen.rect(0, 0, 4, 4); screen.move(0, 10); screen.line(10, 10)
  screen.level(2); screen.stroke()
  screen.level(9); screen.rect(5, 0, 4, 4); screen.fill()
  local rects, lines = context.screen.rects, context.screen.lines
  assert_equal(rects[1].level, 2, "the rect is stroked at 2")
  assert_equal(lines[1].level, 2, "and the line with it")
  assert_equal(rects[2].level, 9, "the next path is filled at 9")
  -- SCENES draws an empty slot's box as rect, level(2), stroke
  h.show_page("SCENES")
  local boxes = 0
  for _, rect in ipairs(context.screen.rects) do
    if rect.w == 5 and rect.h == 5 and rect.filled == false then
      boxes = boxes + 1
      assert_equal(rect.level, 2, "an empty slot's box at x " .. rect.x .. ", y " .. rect.y)
    end
  end
  assert_equal(boxes, 8, "eight empty slots")
end)

-- matron reads screen.level's value with luaL_checkinteger, the texts'
-- with luaL_checkstring and move, line and rect's with luaL_checknumber
-- (weaver.cc), so a bad value raises in the draw on a norns (#475)
test("the screen stub refuses the arguments matron refuses (#475)", function()
  local context = load_strata()
  local function refused(name, expected, ...)
    local ok, message = pcall(screen[name], ...)
    assert_true(not ok and tostring(message):find(expected, 1, true),
      "screen." .. name .. " raises '" .. expected .. "': " .. tostring(message))
  end
  refused("level", "number has no integer representation", 7.5)
  refused("level", "number expected, got nil", nil)
  refused("level", "number expected, got string", "bright")
  refused("text", "string expected, got nil", nil)
  refused("text", "string expected, got table", {})
  refused("text_right", "string expected, got boolean", false)
  refused("text_center", "string expected, got nil", nil)
  refused("text_extents", "string expected, got nil", nil)
  refused("move", "number expected, got nil", nil, 3)
  refused("line", "number expected, got string", 1, "x")
  refused("rect", "number expected, got nil", 1, 2)
  -- what Lua converts passes, as on norns: a whole float, numeral strings, a number as text
  screen.clear()
  screen.level(7.0); screen.level("6"); screen.move("3", 4.5); screen.text(12)
  assert_equal(context.screen.texts[1].text, "12", "a number is drawn as its string")
  assert_equal(context.screen.texts[1].level, 6, "at the level the string gave")
  assert_equal(context.screen.texts[1].x, 3, "at the x the string gave")
end)

test("stub text_width counts UTF-8 characters, not bytes", function()
  assert_equal(text_width("\226\151\143"), 6, "a three-byte glyph is one character, 6 px")
  assert_equal(text_width("\226\151\139 ab"), 6 + 4 + 5 + 5, "glyph, space and two letters")
end)

-- The widths are norns.ttf's advances at 8 px (04B_03, measured with
-- Pillow): m, w, %, /, #, &, @ and \ are 6 px, most capitals 5 (#479)
test("stub text widths are norns' font advances (#479)", function()
  local context = load_strata()
  local expected = { m = 6, ["%"] = 6, ["/"] = 6, ["#"] = 6, ["&"] = 6, ["@"] = 6, ["\\"] = 6, w = 6,
    mod = 16, ["40%"] = 16, ["mm/ww%"] = 36, MAIN = 20, ["[L]"] = 10, ["0.5 s"] = 21, ["!i.:"] = 8 }
  for text, width in pairs(expected) do
    assert_equal(text_width(text), width, "'" .. text .. "'")
  end
  assert_equal(screen.text_extents("40%"), 16, "screen.text_extents measures the same")
  assert_equal(context.screen.text_extents("MAIN"), 20, "and for the capitals")
end)

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

-- #480: core/params/file.lua lists the folder of a file param's path
-- (File:loaddir, util.scandir: a blocking `ls` through matron) at every set
-- that changes the path, silent or not; "-" lists nothing and forgets the
-- folder. A test counts the listings by wrapping util.scandir. File.new's
-- own listing is left out (only its folder is kept): it would double the
-- suite's time
test("stub file params list their folder as norns' File:loaddir does (#480)", function()
  local context = load_strata()
  local folder = context.data_dir .. "files480/"
  util.make_dir(folder .. "sub/")
  for _, name in ipairs({ "a.wav", "b.wav" }) do io.open(folder .. name, "w"):close() end
  local listed = {}
  local scandir = util.scandir
  util.scandir = function(directory)
    table.insert(listed, directory)
    return scandir(directory)
  end
  local ok, problem = pcall(function()
    params:add_file("stub_file480", "file", folder)
    local param = params:lookup_param("stub_file480")
    assert_equal(#listed, 0, "made: not listed (File.new's listing is left out)")
    assert_equal(param.dir, folder, "but its folder is kept")
    params:set("stub_file480", folder .. "a.wav")
    assert_equal(table.concat(listed, " "), folder, "a new path: its folder is listed")
    params:set("stub_file480", folder .. "b.wav", true)
    assert_equal(#listed, 2, "a silent set lists too")
    assert_equal(listed[2], folder)
    assert_equal(param.dir, folder)
    assert_equal(table.concat(param.dirfiles, " "), "a.wav b.wav", "the files, never a folder")
    assert_equal(param.dirpos, 2, "the file's place among them")
    params:set("stub_file480", folder .. "b.wav")
    assert_equal(#listed, 2, "the same path lists nothing")
    params:set("stub_file480", "-")
    assert_equal(#listed, 2, "'-' lists nothing")
    assert_equal(param.dir, nil); assert_equal(param.dirfiles, nil); assert_equal(param.dirpos, nil)
    params:set("stub_file480", "x.wav")
    assert_equal(#listed, 2, "a bare name has no folder to list")
    params:add_file("stub_file480_none", "file")
    assert_equal(#listed, 2, "a param made without a path is '-'")
    assert_equal(params:get("stub_file480_none"), "-")
  end)
  util.scandir = scandir
  assert_true(ok, tostring(problem))
end)

-- norns cannot see where a group ends: it takes the next n params. The
-- stub requires each group's n params to end where its section does, at
-- the next group or separator, or at the end of the list after init()
test("stub params: each group is followed by exactly n params (#25)", function()
  -- the 3.0.1 review's mutation: the strata_midi group one param short or long
  for _, size in ipairs({5, 7}) do
    local mutated, count = patched_script('params:add_group%("strata_midi", "midi", 6%)',
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

-- lua/core/paramset.lua keeps each param's index in lookup and its add and
-- add_* return nothing; params/control.lua's set goes through set_raw, and
-- controlspec.lua's unmap wraps a wrapping spec into its range (#478)
test("stub params: lookup holds indices, add returns nothing, a wrapping control wraps on set (#478)", function()
  load_strata()
  local index = params.lookup.filter_freq
  assert_equal(type(index), "number", "lookup holds the param's index")
  assert_equal(params.params[index].id, "filter_freq", "the index of the param")
  assert_equal(params:lookup_param(index).id, "filter_freq", "lookup_param takes the index")
  assert_equal(params:lookup_param("filter_freq").id, "filter_freq", "or the id")
  assert_true(not pcall(params.lookup_param, params, "no_such_param"), "an unknown id is an error")
  params:add_separator("probe_section", "probe")
  assert_equal(params:add_number("probe_number", "probe", 0, 10, 5), nil, "add_number returns nothing")
  assert_equal(params:add { type = "trigger", id = "probe_trigger" }, nil, "add returns nothing")
  -- a 0-10 control that wraps, at 9
  params:add_control("probe_wrap", "probe wrap", controlspec.new(0, 10, "lin", 0, 9, "", 0.02, true))
  params:set("probe_wrap", 12); assert_near(params:get("probe_wrap"), 2, 1e-9, "set wraps 12 to 2")
  params:set("probe_wrap", -3); assert_near(params:get("probe_wrap"), 7, 1e-9, "and -3 to 7")
  params:set_raw("probe_wrap", 1.25); assert_near(params:get_raw("probe_wrap"), 0.25, 1e-9, "set_raw wraps too")
end)

test("stub params:write and params:read follow lua/core/paramset.lua", function()
  local context = load_strata()
  local pset_path = context.data_dir .. "stub.pset"
  params:set("reverb_mix", 0.25); params:set("filter_type", 2); params:set("strata_lfo1_depth", 40)
  params:write(pset_path, "my pset")
  local file = assert(io.open(pset_path, "r")); local text = file:read("*a"); file:close()
  assert_true(text:find('^%-%- my pset\n'), "the name line comes first")
  assert_true(text:find('"filter_type": 2\n', 1, true), "params are written as \"id\": value")
  assert_true(not text:find('"save_scenes"', 1, true), "triggers are not written")
  assert_true(not text:find('"strata_scenes"', 1, true), "separators are not written")
  params:set("reverb_mix", 0.5); params:set("filter_type", 1); params:set("strata_lfo1_depth", 0)
  local order, read_called = {}, nil
  params:set_action("filter_type", function() table.insert(order, "filter_type") end)
  params:set_action("reverb_mix", function() table.insert(order, "reverb_mix") end)
  params.action_read = function(filename, silent) read_called = { filename = filename, silent = silent } end
  params:read(pset_path)
  assert_equal(params:get("filter_type"), 2); assert_near(params:get("reverb_mix"), 0.25, 1e-9)
  assert_equal(params:get("strata_lfo1_depth"), 40)
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
  -- a scheduling delay on every wake-up: twenty short sleeps fall behind one
  -- long one (the script's clocks stopped: one of theirs waking less than a
  -- tick after a short sleep would share its tick and could deliver first)
  stop_frame_clock(); local_value("S").lib.waveforms.stop()
  clock.cancel(local_value("S").lib.playheads.clock_id()); local_value("S").lib.lfos.stop_clock()
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
  stop_frame_clock(); local_value("S").lib.waveforms.stop()                           -- (its 1/15 s ticks would come first)
  clock.cancel(local_value("S").lib.playheads.clock_id()); local_value("S").lib.lfos.stop_clock()
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
  assert_near(wake_after(function() clock.sync(1) end), 1, 1e-9, "beat 37, 1 s a beat")
  assert_equal(clock.get_tempo(), 60, "the clock tempo follows clock_tempo, once it has ticked")
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

-- matron's internal clock thread reads the tempo before each tick's sleep
-- and publishes it after it (clock_internal.cc): clock.get_tempo() reports
-- a tempo set on it only from the tick after next, never at once
test("stub clock: the internal clock reports a new tempo only once it has ticked", function()
  local context = load_strata(); finish_startup(context)
  assert_equal(clock.get_tempo(), 120, "120 BPM to start")
  params:set("clock_tempo", 121)
  assert_equal(clock.get_tempo(), 120, "the old tempo until the clock ticks")
  assert_near(clock.get_beat_sec(), 0.5, 1e-12, "and the old beat length")
  -- one tick at the old tempo and one at the new: 60/(24*120) + 60/(24*121) s
  context.clock.run_for(0.05)
  assert_equal(clock.get_tempo(), 121, "the new tempo once the clock has ticked")
  -- two changes before it ticks: the old tempo, then the last one
  params:set("clock_tempo", 130)
  params:set("clock_tempo", 140)
  assert_equal(clock.get_tempo(), 121, "neither change shows before a tick")
  context.clock.run_for(0.05)
  assert_equal(clock.get_tempo(), 140, "the last change once it has ticked")
  -- an external source's tempo (a test sets clock.tempo itself) reads at once
  params:set("clock_source", 2)
  clock.tempo = 100
  assert_equal(clock.get_tempo(), 100, "an external tempo reads at once")
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

-- The frame clock's parts, the playhead tick and the menu-close hooks catch
-- an error, print one "strata: ... failed" line and carry on. The harness
-- treats that line as it treats a clock error (#473)
test("an error the script catches and prints fails the test unless it claims it (#473)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local page = S.registry.pages[S.ui_page]
  local real_draw = page.draw
  -- one failed frame draw, then a good one (the frame clock prints a part's
  -- error once until that part draws again)
  local function failed_frame()
    page.draw = function() error("draw exploded") end
    request_redraw(); h.next_frame(context)
    page.draw = real_draw
    request_redraw(); h.next_frame(context)
  end
  local ok, message = run_test(failed_frame)
  assert_true(not ok, "a passing test whose frame draw failed fails")
  assert_true(tostring(message):find("draw exploded", 1, true), "with the printed error: " .. tostring(message))
  ok, message = run_test(function() failed_frame(); error("the test failed") end)
  assert_true(not ok and tostring(message):find("the test failed", 1, true), "a failing test keeps its own error")
  assert_true(tostring(message):find("draw exploded", 1, true), "and gets the printed error: " .. tostring(message))
  ok, message = run_test(function()
    failed_frame()
    local claimed = context.take_script_errors()
    assert_equal(#claimed, 1, "one printed error claimed")
    assert_true(claimed[1]:find("strata: page draw failed:", 1, true), "the line: " .. claimed[1])
  end)
  assert_true(ok, "a test that claims the printed error passes: " .. tostring(message))
  -- h.claim_script_errors claims them and checks their count, prefix and last text
  ok, message = run_test(function()
    failed_frame(); h.claim_script_errors(context, 1, "strata: page draw failed: ", "draw exploded")
  end)
  assert_true(ok, "the helper claims a matching line: " .. tostring(message))
  for _, wrong in ipairs({ { 2, "strata: page draw failed: " }, { 1, "strata: frame failed: " },
      { 1, "strata: page draw failed: ", "another error" } }) do
    ok = run_test(function() failed_frame(); h.claim_script_errors(context, wrong[1], wrong[2], wrong[3]) end)
    assert_true(not ok, "a claim that does not match fails: " .. wrong[1] .. " " .. wrong[2] .. " " .. tostring(wrong[3]))
  end
  print("strata: a line that reports no failure"); print("buffer 1 saved to /x.wav")
  assert_equal(#context.take_script_errors(), 0, "other printed lines are no errors")
end)

-- 3.4's PSET hooks run in a pcall each and print "pset hook <name>: <error>"
-- (lib/params_setup.lua): to the harness that line is a script error too
test("a PSET hook that fails is a script error the test must claim", function()
  local context = load_strata({ before_init = function()
    local_value("S").register_pset_hook({ name = "probe", write = function() error("hook exploded") end })
  end })
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  local path = context.data_dir .. "hook.pset"
  local ok, message = run_test(function() params:write(path) end)
  assert_true(not ok, "a passing test whose PSET hook failed fails")
  assert_true(tostring(message):find("hook exploded", 1, true), "with the printed error: " .. tostring(message))
  ok, message = run_test(function()
    params:write(path); h.claim_script_errors(context, 1, "pset hook probe: ", "hook exploded")
  end)
  assert_true(ok, "a test that claims it passes: " .. tostring(message))
  print("pset hook names nothing that failed"); print("pset >> write: " .. path)
  assert_equal(#context.take_script_errors(), 0, "other printed lines are no errors")
end)

test("a broken invariant is reported by name, a held one is not", function()
  load_strata()
  assert_equal(#h.check_invariants(), 0, "every invariant holds after a load")
  local S = local_value("S")
  S.pattern_playing = true  -- with no pattern clock
  local broken = h.check_invariants()
  assert_equal(#broken, 1, "one invariant broken")
  assert_equal(broken[1]:sub(1, #"pattern clock:"), "pattern clock:", "named first: " .. broken[1])
  S.register_invariant("raises", function() error("boom") end)
  broken = h.check_invariants()
  assert_equal(#broken, 2, "the raising one is listed too")
  assert_equal(broken[2]:sub(1, #"raises:"), "raises:", "named first: " .. broken[2])
  assert_true(broken[2]:find("boom", 1, true), "with its error: " .. broken[2])
  h.allow_broken_invariants("this test breaks them on purpose")
end)

test("run_test fails a passing test that leaves an invariant broken, unless it allowed it", function()
  local ok, message = run_test(function() load_strata(); local_value("S").pattern_playing = true end)
  assert_true(not ok, "the test fails")
  assert_true(tostring(message):find("invariants broken after the test:", 1, true), "says so: " .. tostring(message))
  assert_true(tostring(message):find("pattern clock", 1, true), "names the invariant: " .. tostring(message))
  ok, message = run_test(function()
    h.allow_broken_invariants("on purpose")
    load_strata(); local_value("S").pattern_playing = true
  end)
  assert_true(ok, "an allowed break passes: " .. tostring(message))
  assert_true(run_test(function() end), "a test that loaded nothing is not checked")
  assert_true(not pcall(h.allow_broken_invariants, ""), "a reason is a non-empty string")
  load_strata()  -- this test leaves nothing broken
end)

test("a script with no invariants registry fails only the test that loaded it, and the flags come back", function()
  local inner_ok, inner_message
  -- the middle test loads nothing: once the inner one returns, its own flags
  -- are back, so it is not checked against the script the inner one left
  local middle_ok, middle_message = run_test(function()
    inner_ok, inner_message = run_test(function()
      load_strata { module_sources = { ["lib/state"] = stub_state_source("") } }
    end)
  end)
  assert_true(middle_ok, "the middle test passes: " .. tostring(middle_message))
  assert_true(not inner_ok, "the inner test fails")
  assert_true(tostring(inner_message):find("invariant check failed:", 1, true), "says so: " .. tostring(inner_message))
  assert_true(tostring(inner_message):find("S.registry.invariants", 1, true), "names the field: " .. tostring(inner_message))
  load_strata()  -- this test leaves nothing broken
end)

test("stub clock.advance_until fails at once when its coroutine is canceled or nothing is pending (#51)", function()
  local context = load_strata(); finish_startup(context)
  stop_frame_clock(); local_value("S").lib.waveforms.stop()
  clock.cancel(local_value("S").lib.playheads.clock_id()); local_value("S").lib.lfos.stop_clock()
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
-- (>=), a sync once the beat is past it (>), so any tick after a sleep and a
-- sync due at one time posts both; a tick comes every 1 ms (ruling 92)
test("stub clock ties: wake-ups within a tick fire in event-slot order, a sleep and a sync due at one time too (#51)", function()
  local context = load_strata(); finish_startup(context)
  stop_frame_clock(); local_value("S").lib.waveforms.stop()
  clock.cancel(local_value("S").lib.playheads.clock_id()); local_value("S").lib.lfos.stop_clock()
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
  -- a sync (lower slot) and a sleep due at the same time: one tick posts
  -- both, in slot order
  assert_near(clock.get_beats() % 1, 0, 1e-12, "on a beat")
  local function start_sync_and_sleep()
    clock.run(function() clock.sync(1); log("sync") end)
    clock.run(function() clock.sleep(clock.get_beat_sec()); log("sleep") end)
  end
  events = {}
  start_sync_and_sleep()
  context.clock.advance()
  assert_equal(table.concat(events, " "), "sync@3.00 sleep@3.00", "one step: both, in slot order")
  events = {}
  start_sync_and_sleep()
  context.clock.run_for(1)
  assert_equal(table.concat(events, " "), "sync@3.50 sleep@3.50", "tick by tick: both in one tick too")
  -- wake-ups under a tick apart share one, in slot order: the one that wakes
  -- later, in the lower slot, first; a tick or more apart, in wake order
  for _, case in ipairs({ { gap = 0.0005, order = "late early" }, { gap = 0.0015, order = "early late" } }) do
    for _, helper in ipairs({ "advance", "run_for" }) do
      events = {}
      local start = util.time()
      local function log_name(name) table.insert(events, name) end
      local placeholder = clock.run(function() clock.sleep(100) end)
      clock.run(function() clock.sleep(0.25); log_name("early") end)
      clock.cancel(placeholder)
      clock.run(function() clock.sleep(0.25 + case.gap); log_name("late") end)
      if helper == "advance" then
        context.clock.advance()
        assert_near(util.time(), start + 0.25 + (case.gap < 0.001 and case.gap or 0), 1e-12,
          helper .. ", " .. case.gap .. " s apart: the step is at the tick's latest wake-up")
        context.clock.advance()
      else
        context.clock.run_for(1)
      end
      assert_equal(table.concat(events, " "), case.order, helper .. ", " .. case.gap .. " s apart")
    end
  end
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
  assert_equal(params:get("clock_tempo"), 60, "A changed the tempo")
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
      local param = params.lookup[param_id] and params:lookup_param(param_id)
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

-- core/paramset.lua: ParamSet:delta calls the param object's own delta, and
-- norns' PARAMS menu turns E3 with that method too, so a script that
-- replaces one param's delta changes both (#318). core/params/control.lua:
-- a control's delta is set_raw(raw + d * quantum), which wraps a wrapping
-- spec (#478): a 0-10 control at 9 with a quantum of 0.2 goes to 1
test("stub params:delta runs the param's own delta, and a wrapping control's delta wraps (#318, #478)", function()
  load_strata()
  params:add_control("stub_wrap", "wrap", controlspec.new(0, 10, "lin", 0, 9, "", 0.2, true))
  params:delta("stub_wrap", 1)
  assert_near(params:get("stub_wrap"), 1, 1e-9, "params:delta wraps past the top")
  params:lookup_param("stub_wrap"):delta(-1)
  assert_near(params:get("stub_wrap"), 9, 1e-9, "the param's own delta wraps past the bottom")
  params:add_control("stub_clamp", "clamp", controlspec.new(0, 10, "lin", 0, 9, "", 0.2))
  params:delta("stub_clamp", 1)
  assert_near(params:get("stub_clamp"), 10, 1e-9, "a control that does not wrap stops at its top")
  params:add_number("stub_steps", "steps", 0, 10, 3)
  local param = params:lookup_param("stub_steps")
  local deltas = {}
  local own_delta = param.delta
  param.delta = function(self, d)
    table.insert(deltas, d)
    own_delta(self, d)
  end
  params:delta("stub_steps", 2)
  assert_equal(#deltas, 1, "params:delta went through the replaced delta")
  assert_equal(deltas[1], 2, "with its d")
  assert_equal(params:get("stub_steps"), 5, "and the param's own delta did the work")
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
  assert_true(not pcall(vport.led, vport, 1, 1, math.huge, true), "an infinite level has no integer representation")
  vport:led(1, 2, "7"); assert_equal(device:get_led(1, 2), 7, "a numeral string converts, as luaL_checkinteger does")
end)

-- matron's _grid_set_led and _grid_all_led read x, y and the level with
-- luaL_checkinteger; rel adds to the level, clamped to 0..15
-- (dev_monome_grid_set_led, dev_monome_all_led) (#476)
test("stub grid led and all take integers and rel as matron does (#476)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 8)
  local vport = grid.connect(1)
  for _, case in ipairs({ { "led", 1, 1, 7.5 }, { "led", 1.5, 1, 7 }, { "all", nil }, { "all", "x" }, { "all", 99 },
      { "all", 16 }, { "all", 2.5 } }) do
    local method = case[1]
    assert_true(not pcall(vport[method], vport, case[2], case[3], case[4]),
      "refused: " .. method .. "(" .. tostring(case[2]) .. ", " .. tostring(case[3]) .. ", " .. tostring(case[4]) .. ")")
  end
  vport:led(1, 1, 8); vport:led(1, 1, 20, true)
  assert_equal(device:get_led(1, 1), 15, "a relative led adds, clamped to 15")
  vport:led(1, 1, -20, true); assert_equal(device:get_led(1, 1), 0, "and at 0")
  vport:all(3); vport:all(5, true)
  assert_equal(device:get_led(16, 8), 8, "a relative all adds to every LED")
  vport:all(-12, true); assert_equal(device:get_led(2, 2), 0, "clamped at 0")
  vport:led(2, 3, 7.0); assert_equal(device:get_led(2, 3), 7, "a whole float is an integer")
end)

-- SYSTEM > DEVICES (lua/core/menu/devices.lua) renames the vports and calls
-- update_devices() only (lua/core/grid.lua, arc.lua): no add, no remove
test("reassign moves a device between vports and calls no add or remove", function()
  local context = load_strata(); finish_startup(context)
  local grid_device = context.grid.plug(1, 16, 8)
  local arc_device = context.arc.plug(1)
  local calls = {}
  for _, name in ipairs({ "add", "remove" }) do
    local real_grid, real_arc = grid[name], arc[name]
    grid[name] = function(...) calls[#calls + 1] = "grid." .. name; return real_grid(...) end
    arc[name] = function(...) calls[#calls + 1] = "arc." .. name; return real_arc(...) end
  end
  _menu.set_mode(true)  -- as in SYSTEM > DEVICES
  context.grid.reassign(1, 2)
  context.arc.reassign(1, 3)
  local old_grid, new_grid = grid.connect(1), grid.connect(2)
  assert_equal(old_grid.device, nil, "port 1's grid vport holds no device")
  assert_equal(old_grid.cols, 0); assert_equal(old_grid.rows, 0)
  assert_equal(new_grid.device, grid_device, "port 2's holds the grid")
  assert_equal(new_grid.cols, 16); assert_equal(new_grid.rows, 8)
  assert_equal(grid_device.port, 2, "the grid's port is 2")
  assert_equal(arc.connect(1).device, nil, "port 1's arc vport holds no device")
  assert_equal(arc.connect(3).device, arc_device, "port 3's holds the arc")
  assert_equal(arc_device.port, 3, "the arc's port is 3")
  assert_equal(#calls, 0, "no add or remove: " .. table.concat(calls, ", "))
  _menu.set_mode(false)  -- the script catches up as the menu closes
end)

-- SYSTEM > DEVICES moves a MIDI device as it does a grid: lua/core/midi.lua's
-- update_devices() re-links devices to vports, and neither add nor remove runs
test("the stub's midi.reassign moves a device between vports as update_devices does", function()
  local context = load_strata(); finish_startup(context)
  local device = context.midi.plug(1, "keys")
  local calls = {}
  for _, name in ipairs({ "add", "remove" }) do
    local real = midi[name]
    midi[name] = function(...) calls[#calls + 1] = "midi." .. name; return real(...) end
  end
  _menu.set_mode(true)
  context.midi.reassign(1, 2)
  assert_equal(midi.connect(1).device, nil, "port 1 holds no device")
  assert_equal(midi.connect(1).connected, false, "and is not connected")
  assert_equal(midi.connect(2).device, device, "port 2 holds the device")
  assert_equal(midi.connect(2).connected, true)
  assert_equal(device.port, 2, "the device's port is 2")
  assert_equal(#calls, 0, "no add or remove: " .. table.concat(calls, ", "))
  _menu.set_mode(false)
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
  -- matron's w_handle_poll_value pushes the value with lua_pushnumber: a
  -- float on Lua 5.3, also for a whole number (LuaJIT has one number type)
  amp_poll:start()
  context.polls.fire("amp_in_l", 3)
  assert_equal(values[2], 3)
  local number_type = math.type or function() return "float" end
  assert_equal(number_type(values[2]), "float", "a whole poll value arrives as a float")
end)

-- lua/core/menu.lua's set_mode: menu mode puts norns.none in redraw and
-- refresh and routes the encoders to the menu; play mode puts back the
-- redraw and refresh Script.load stored (norns.script), routes _menu.key and
-- the encoders to the globals key and enc, and calls redraw (#521)
test("stub _menu.set_mode swaps the handlers and redraws as norns' does (#521)", function()
  local context = load_strata(); finish_startup(context)
  local script_redraw, script_key, script_enc = redraw, key, enc
  assert_equal(norns.script.redraw, script_redraw, "the script's redraw is stored as it loads")
  _menu.set_mode(true)
  assert_equal(redraw, norns.none, "the open menu blocks the script's redraw")
  assert_equal(refresh, norns.none, "and its refresh")
  assert_true(norns.encoders.callback ~= script_enc, "the menu has the encoders")
  assert_true(_menu.key ~= script_key, "and the keys")
  local draws = 0
  norns.script.redraw = function() draws = draws + 1; script_redraw() end
  context.screen.texts = { { text = "menu", x = 0, y = 8 } }
  _menu.set_mode(false)
  assert_equal(draws, 1, "closing the menu draws the script's screen once")
  assert_equal(redraw, norns.script.redraw, "and gives back the stored redraw")
  assert_equal(_menu.key, script_key, "the keys go to the script"); assert_equal(norns.encoders.callback, script_enc, "and the encoders")
  assert_true(not h.screen_shows(context, "menu"), "the menu's screen is cleared")
  assert_true(h.screen_shows(context, "MAIN"), "and the page drawn")
  norns.script.redraw, redraw = script_redraw, script_redraw
end)

-- lib/util.lua's make_dir runs "mkdir -p " .. path unquoted, lib/fileselect.lua's
-- enter indexes its folder (fs.folder:sub), and core/metro.lua's init takes
-- (event, time, count) or a table, with 30 script metros (#481)
test("stub util.make_dir, fileselect.enter and metro.init follow norns (#481)", function()
  local context = load_strata()
  local ok, message = pcall(util.make_dir, context.data_dir .. "a b")
  assert_true(not ok and tostring(message):find("unquoted", 1, true), "a path the shell would split is refused: "
    .. tostring(message))
  assert_true(not pcall(util.make_dir, context.data_dir .. "it's"), "and one with a quote")
  util.make_dir(context.data_dir .. "plain/dir")
  assert_true(util.file_exists(context.data_dir .. "plain/dir"), "a plain path is made, parents and all")
  local fileselect = require("fileselect")
  assert_true(not pcall(fileselect.enter, nil, function() end), "a nil folder raises, as fs.folder:sub does")
  assert_true(not pcall(fileselect.enter, 3, function() end), "and a number")
  local function tick() end
  local timer = metro.init(tick, 0.25, 3)
  assert_equal(timer.event, tick, "the event"); assert_equal(timer.time, 0.25, "the time"); assert_equal(timer.count, 3, "the count")
  timer = metro.init { event = tick, time = 0.5 }
  assert_equal(timer.event, tick, "a table's event"); assert_equal(timer.time, 0.5, "its time")
  assert_equal(timer.count, -1, "count -1 (forever) by default")
  timer = metro.init()
  assert_equal(timer.time, 1, "time 1 by default"); assert_equal(timer.event, nil, "and no event")
  while #context.metro.all < 30 do assert_true(metro.init() ~= nil, "a free script metro") end
  assert_equal(metro.init(), nil, "the 31st script metro is not available")
  assert_equal(context.printed[#context.printed], "metro.init: nothing available", "norns says so")
end)

-- norns' util.time() is seconds + microseconds / 1000000, and matron pushes
-- clock_get_tempo and clock_get_beats with lua_pushnumber: floats on Lua
-- 5.3, also when the stub's time, tempo or beat is a whole number (#300)
test("stub util.time, clock.get_tempo and clock.get_beats return floats, as on a norns (#300)", function()
  local context = load_strata(); finish_startup(context)
  local number_type = math.type or function() return "float" end
  params:set("clock_tempo", 120); context.set_time(3)
  assert_equal(util.time(), 3); assert_equal(number_type(util.time()), "float", "util.time() is a float")
  assert_equal(clock.get_tempo(), 120); assert_equal(number_type(clock.get_tempo()), "float", "the tempo is a float")
  assert_near(clock.get_beats(), 6, 1e-9)
  assert_equal(number_type(clock.get_beats()), "float", "the beat is a float")
end)

-- test/run.lua loads the unit files load_unit_files lists: every
-- *_test.lua in test/unit, sorted, or those whose name contains the filter
test("the runner finds unit files and filters them", function()
  local dir = data_root .. "runner_test"
  os.execute("mkdir -p '" .. dir .. "'")
  local function write(name, text)
    local file = assert(io.open(dir .. "/" .. name, "w")); file:write(text); file:close()
  end
  write("beta_test.lua", 'return function(h) h.test("beta one", function() end) end\n')
  write("alpha_test.lua", 'return function(h) h.test("alpha one", function() end); h.test("alpha two", function() end) end\n')
  write("notes.lua", 'error("not a unit file")\n')
  local registered
  local recorder = { test = function(name) table.insert(registered, name) end }
  local function load_from(filter)
    registered = {}
    return table.concat(load_unit_files(dir, filter, recorder), " "), table.concat(registered, ", ")
  end
  local names, tests = load_from(nil)
  assert_equal(names, "alpha_test.lua beta_test.lua", "every unit file, sorted, nothing else")
  assert_equal(tests, "alpha one, alpha two, beta one", "each file's tests, in file order")
  names, tests = load_from("beta")
  assert_equal(names, "beta_test.lua", "a filter keeps the files whose name contains it")
  assert_equal(tests, "beta one", "and only their tests")
  assert_equal(load_from("a."), "", "the filter is plain text, not a pattern")
  assert_equal(load_from("gamma"), "", "a filter matching no file loads none")
  -- a unit file that registers no test, or returns no function, stops the load (#484)
  write("empty_test.lua", 'return function(h) end\n')
  write("nothing_test.lua", 'local x = 1\n')
  local ok, message = pcall(load_from, "empty")
  assert_true(not ok and tostring(message):find("empty_test.lua registered no test", 1, true),
    "a unit file with no test is an error: " .. tostring(message))
  ok, message = pcall(load_from, "nothing")
  assert_true(not ok and tostring(message):find("nothing_test.lua returns no function(h)", 1, true),
    "a unit file returning nothing is an error: " .. tostring(message))
  h.remove_tree(dir)
  -- the suite's own unit files
  local unit_dir = repo_root .. "/test/unit"
  assert_equal(table.concat(unit_files(unit_dir, "lfos"), " "), "lfos_test.lua", "the lfos filter")
  local all = table.concat(unit_files(unit_dir), " ")
  assert_true(all:find("stubs_test.lua", 1, true) and all:find("structure_test.lua", 1, true), "every unit file: " .. all)
end)

-- test/run.lua under this run's interpreter (arg's lowest index), with
-- `prelude` run first: its output, exit status and the temporary folder
-- helpers.lua made (os.tmpname, reported by the prelude)
local function run_runner(prelude, filter)
  local lowest = 0
  while arg[lowest - 1] do lowest = lowest - 1 end
  local report_tmpname = 'local tmpname = os.tmpname; os.tmpname = function() local name = tmpname();'
    .. ' io.stderr:write("tmpname " .. name .. "\\n"); return name end; '
  local command = "cd " .. h.shell_quote(repo_root) .. " && " .. h.shell_quote(arg[lowest]) .. " -e "
    .. h.shell_quote(report_tmpname .. prelude) .. " test/run.lua " .. h.shell_quote(filter) .. " 2>&1; echo \"exit $?\""
  local pipe = assert(io.popen(command))
  local output = pipe:read("*a")
  pipe:close()
  return output, tonumber(output:match("exit (%d+)%s*$")), output:match("tmpname (%S+)")
end

-- helpers.lua makes the suite's temporary folder as it loads; the runner
-- removes it on every way out (#483), and a run that registers no test
-- fails (#484)
test("the runner removes its temporary folder on every way out and fails a run with no test (#483, #484)", function()
  local function exists(path)
    local file = io.open(path, "r"); if file then file:close() end
    return file ~= nil
  end
  -- planted: require("helpers") returns the harness with load_unit_files replaced
  local function planting(load_unit_files)
    return 'local real_require = require; require = function(name) local module = real_require(name);'
      .. ' if name == "helpers" then module.load_unit_files = ' .. load_unit_files .. ' end; return module end'
  end
  local cases = {
    { prelude = "", filter = "no_unit_file_has_this_name", says = "no unit file" },
    { prelude = planting('function() error("planted load failure") end'), filter = "docs", says = "planted load failure" },
    { prelude = planting('function() return { "planted_test.lua" } end'), filter = "docs", says = "registered no test" },
  }
  for _, case in ipairs(cases) do
    local output, status, folder = run_runner(case.prelude, case.filter)
    assert_equal(status, 1, "the run fails (" .. case.says .. "): " .. output)
    assert_true(output:find(case.says, 1, true), "the run says why (" .. case.says .. "): " .. output)
    assert_true(folder and folder:match("^/"), "the run made its folder: " .. output)
    assert_true(not exists(folder), "the run left no folder behind (" .. case.says .. "): " .. tostring(folder))
  end
end)

-- The parallel run and its shards (3.8's package x5). Each test builds a
-- small tree of unit files under data_root and runs test/run.lua on it
-- (--dir) under an interpreter, from the repository root. A run started
-- by a test is single-process (STRATA_TEST_INSIDE_RUN, which every command
-- a run starts carries), so these clear it to run the parallel runner
-- unless `nested` is set.
local RUNNER = {}

-- The interpreter this run is under (arg's lowest index)
function RUNNER.interpreter()
  local lowest = 0
  while arg[lowest - 1] do lowest = lowest - 1 end
  return arg[lowest]
end

-- The other interpreter of the two the suite runs under (Lua 5.3 and
-- LuaJIT, both on PATH where the suite runs, CI's runners included): its
-- path, found with `command -v`
function RUNNER.other_interpreter()
  local names = rawget(_G, "jit") and { "lua5.3", "lua" } or { "luajit" }
  for _, name in ipairs(names) do
    local pipe = assert(io.popen("command -v " .. name .. " 2>/dev/null"))
    local path = pipe:read("*l"); pipe:close()
    if path and path ~= "" then
      local probe = assert(io.popen(h.shell_quote(path) .. " -e 'io.write(_VERSION, rawget(_G, \"jit\") and \" jit\" or \"\")'"))
      local version = probe:read("*a"); probe:close()
      if (name == "luajit") == (version:find("jit", 1, true) ~= nil) and (name == "luajit" or version == "Lua 5.3") then
        return path
      end
    end
  end
  error("the shard test needs both Lua 5.3 and LuaJIT on PATH (" .. table.concat(names, " or ") .. " not found)")
end

-- A tree of unit files: `files` maps a file name to its source
function RUNNER.tree(name, files)
  local dir = data_root .. "runner-tree-" .. name
  os.execute("mkdir -p " .. h.shell_quote(dir))
  for file, source in pairs(files) do h.write_text(dir .. "/" .. file, source) end
  return dir
end

-- A unit file's source registering `count` passing tests named
-- "<label> 1" .. "<label> <count>", each busy for a moment so that
-- processes overlap; `extra` is added inside the function
function RUNNER.passing(label, count, extra)
  return "return function(h)\n  for i = 1, " .. count .. " do\n    h.test(" .. string.format("%q", label)
    .. " .. ' ' .. i, function() local x = 0; for j = 1, 20000 do x = x + j end end)\n  end\n"
    .. (extra or "") .. "end\n"
end

-- Run test/run.lua with `arguments` (a list, each quoted) under
-- options.interpreter (default: this run's), options.env (shell
-- assignments, such as "STRATA_TEST_JOBS=2 ") and options.prelude (Lua run
-- before the runner, in its process only). Returns the output (stdout and
-- stderr) without the prelude's lines, the exit status and the run's
-- temporary folder (the one os.tmpname gave helpers.lua, or nil)
function RUNNER.run(arguments, options)
  options = options or {}
  local quoted = {}
  for i, argument in ipairs(arguments) do quoted[i] = h.shell_quote(argument) end
  local report_tmpname = 'local tmpname = os.tmpname; os.tmpname = function() local name = tmpname();'
    .. ' io.stderr:write("tmpname " .. name .. "\\n"); return name end; '
  local command = "cd " .. h.shell_quote(repo_root) .. " && " .. (options.nested and "" or "unset STRATA_TEST_INSIDE_RUN; ")
    .. (options.env or "") .. h.shell_quote(options.interpreter or RUNNER.interpreter()) .. " -e "
    .. h.shell_quote(report_tmpname .. (options.prelude or "")) .. " test/run.lua " .. table.concat(quoted, " ")
    .. " 2>&1; echo \"exit $?\""
  local pipe = assert(io.popen(command))
  local output = pipe:read("*a")
  pipe:close()
  local folder = output:match("tmpname (%S+)")
  local status = tonumber(output:match("exit (%d+)%s*$"))
  output = output:gsub("tmpname %S+\n", ""):gsub("exit %d+%s*$", "")
  return output, status, folder
end

function RUNNER.exists(path)
  local file = io.open(path, "r"); if file then file:close() end
  return file ~= nil
end

-- The output's lines, and its last line
function RUNNER.lines(output)
  local lines = {}
  for line in (output .. (output:sub(-1) == "\n" and "" or "\n")):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  return lines, lines[#lines]
end

-- A run's checks every case shares: the exit status and that it left no
-- temporary folder behind
function RUNNER.check(output, status, folder, expected_status, what)
  assert_equal(status, expected_status, what .. ": the exit status\n" .. output)
  assert_true(folder == nil or not RUNNER.exists(folder), what .. ": the run left no folder behind: " .. tostring(folder))
end

-- The tree most cases share: three files of 5, 4 and 3 passing tests
function RUNNER.three_files(name)
  return RUNNER.tree(name, { ["alpha_test.lua"] = RUNNER.passing("alpha", 5), ["beta_test.lua"] = RUNNER.passing("beta", 4),
    ["gamma_test.lua"] = RUNNER.passing("gamma", 3) })
end

-- What a single-process run of three_files prints, as test/run.lua printed it before the parallel run
function RUNNER.three_files_output()
  local lines = {}
  for _, file in ipairs({ { "alpha", 5 }, { "beta", 4 }, { "gamma", 3 } }) do
    for i = 1, file[2] do lines[#lines + 1] = "ok   " .. file[1] .. " " .. i end
  end
  return table.concat(lines, "\n") .. "\n\n12 tests, 0 failures\n"
end

test("a single-process run prints what test/run.lua printed before the parallel run", function()
  local dir = RUNNER.three_files("single")
  for _, case in ipairs({ { "--jobs", "1" }, { "-j", "1" }, { "--jobs", "1", "--shard", "1/1" } }) do
    table.insert(case, 1, dir); table.insert(case, 1, "--dir")
    local output, status, folder = RUNNER.run(case)
    RUNNER.check(output, status, folder, 0, table.concat(case, " "))
    assert_equal(output, RUNNER.three_files_output(), table.concat(case, " ") .. ": the output, byte for byte")
  end
  local output, status, folder = RUNNER.run({ "--dir", dir }, { env = "STRATA_TEST_JOBS=1 " })
  RUNNER.check(output, status, folder, 0, "STRATA_TEST_JOBS=1")
  assert_equal(output, RUNNER.three_files_output(), "STRATA_TEST_JOBS=1: the output, byte for byte")
  h.remove_tree(dir)
end)

test("a parallel run prints each file's lines whole, then its processes and a single-process run's totals", function()
  local dir = RUNNER.three_files("parallel")
  local output, status, folder = RUNNER.run({ "--dir", dir, "--jobs", "3" })
  RUNNER.check(output, status, folder, 0, "--jobs 3")
  local lines, last = RUNNER.lines(output)
  assert_equal(last, "12 tests, 0 failures", "the last line is the totals")
  assert_equal(lines[#lines - 1], "", "a blank line before the totals, as a single-process run prints")
  assert_true(lines[#lines - 2]:match("^3 unit files in 3 processes, %d+ s$") ~= nil, "the processes line: " .. lines[#lines - 2])
  -- every ok line of the single-process run, each once, each file's together and in its order
  local expected = RUNNER.lines(RUNNER.three_files_output())
  local seen, first, last_at = {}, {}, {}
  for at, line in ipairs(lines) do
    local label, index = line:match("^ok   (%a+) (%d+)$")
    if label then
      assert_true(not seen[line], "printed once: " .. line); seen[line] = true
      first[label] = first[label] or at
      assert_equal(at - first[label] + 1, tonumber(index), "the file's lines are whole and in order: " .. line .. "\n" .. output)
      last_at[label] = at
    end
  end
  for i = 1, 12 do assert_true(seen[expected[i]], "the parallel run printed " .. expected[i]) end
  assert_equal(#lines, 12 + 3, "nothing else was printed:\n" .. output)
  h.remove_tree(dir)
end)

test("a parallel run's failing test fails the run and is printed again before the totals", function()
  local dir = RUNNER.tree("failing", { ["alpha_test.lua"] = RUNNER.passing("alpha", 5), ["beta_test.lua"] = RUNNER.passing("beta", 4),
    ["gamma_test.lua"] = RUNNER.passing("gamma", 2, '  h.test("gamma fails", function() error("planted failure", 0) end)\n') })
  local output, status, folder = RUNNER.run({ "--dir", dir, "--jobs", "3" })
  RUNNER.check(output, status, folder, 1, "a failing test")
  local lines, last = RUNNER.lines(output)
  assert_equal(last, "12 tests, 1 failures", "the totals count the failure")
  local at = {}
  for index, line in ipairs(lines) do
    if line == "FAIL gamma fails" then
      at[#at + 1] = index
      assert_true(lines[index + 1]:find("planted failure", 1, true) ~= nil, "its message follows it: " .. tostring(lines[index + 1]))
    end
  end
  assert_equal(#at, 2, "printed in place and again:\n" .. output)
  -- the repeat is at the end of the log: after every ok line, before the processes line
  for index = at[2], #lines do assert_true(not lines[index]:match("^ok   "), "the repeat comes after every ok line:\n" .. output) end
  assert_true(lines[#lines - 2]:match("^3 unit files in 3 processes, %d+ s$") and at[2] < #lines - 2,
    "the repeat comes before the processes line and the totals:\n" .. output)
  h.remove_tree(dir)
end)

test("a parallel run fails and names a process that crashes, a file that does not load and one that registers no test", function()
  local leave = '  h.test("%s leaves", function() io.write("data root " .. h.data_root .. "\\n"); io.flush(); %s end)\n'
  local dir = RUNNER.tree("abnormal", {
    ["alpha_test.lua"] = RUNNER.passing("alpha", 5),
    ["crash_test.lua"] = RUNNER.passing("crash", 1, string.format(leave, "crash", "os.exit(3)")),
    ["signal_test.lua"] = RUNNER.passing("signal", 1, string.format(leave, "signal", 'os.execute("kill -9 $PPID")')),
    ["quiet_test.lua"] = RUNNER.passing("quiet", 1, string.format(leave, "quiet", "os.exit(0)")),
    ["broken_test.lua"] = "return function(h) h.test('broken', function() end)\n",
    ["empty_test.lua"] = "return function(h) end\n",
  })
  local output, status, folder = RUNNER.run({ "--dir", dir, "--jobs", "6" })
  RUNNER.check(output, status, folder, 1, "abnormal endings")
  local lines, last = RUNNER.lines(output)
  local abnormal = { "crash_test.lua", "signal_test.lua", "quiet_test.lua", "broken_test.lua", "empty_test.lua" }
  for _, name in ipairs(abnormal) do
    local count = 0
    for _, line in ipairs(lines) do
      if line:match("^FAIL ") and line:find(name, 1, true) then count = count + 1 end
    end
    assert_equal(count, 2, name .. " is named in a FAIL line, in place and again before the totals:\n" .. output)
  end
  local tests, failures = last:match("^(%d+) tests, (%d+) failures$")
  assert_true(tests ~= nil, "the last line is the totals: " .. tostring(last))
  assert_true(tonumber(failures) >= #abnormal, "each abnormal ending counts as a failure: " .. last)
  assert_true(output:find("ok   alpha 5", 1, true) ~= nil, "the other file still ran")
  -- the processes that ended abnormally kept their folders inside the run's, which is gone
  local roots = 0
  for root in output:gmatch("data root (%S+)") do
    roots = roots + 1
    assert_true(folder and root:sub(1, #folder) == folder, "a process's folder is inside the run's: " .. root)
    assert_true(not RUNNER.exists(root), "and gone: " .. root)
  end
  assert_equal(roots, 3, "the three that ended in a test said where their folder was:\n" .. output)
  h.remove_tree(dir)
end)

test("a parallel run fails when no file matches, and when a file is reported by no process or by two", function()
  local dir = RUNNER.three_files("accounting")
  local output, status, folder = RUNNER.run({ "--dir", dir, "--jobs", "3", "no_file_has_this" })
  RUNNER.check(output, status, folder, 1, "no file matched")
  assert_true(output:find("no unit file", 1, true) ~= nil, "it says why: " .. output)
  -- the parent's reading of its processes' reports, planted: beta's report
  -- is dropped, alpha's comes twice
  local plant = 'local popen = io.popen; io.popen = function(command, ...) local pipe = popen(command, ...);'
    .. ' if not tostring(command):find("xargs", 1, true) then return pipe end;'
    .. ' local proxy = {}; function proxy:lines() local next_line, pending = pipe:lines(), nil; return function()'
    .. ' if pending then local line = pending; pending = nil; return line end; local line = next_line();'
    .. ' while line and line:find("beta_test.lua", 1, true) do line = next_line() end;'
    .. ' if line and line:find("alpha_test.lua", 1, true) then pending = line end; return line end end;'
    .. ' function proxy:read(...) return pipe:read(...) end; function proxy:close() return pipe:close() end; return proxy end; '
  output, status, folder = RUNNER.run({ "--dir", dir, "--jobs", "3" }, { prelude = plant })
  RUNNER.check(output, status, folder, 1, "a file reported by no process, and one reported twice")
  assert_true(output:find("FAIL beta_test.lua", 1, true) ~= nil, "the file no process reported is named: " .. output)
  assert_true(output:find("FAIL alpha_test.lua", 1, true) ~= nil, "the file reported twice is named: " .. output)
  local _, last = RUNNER.lines(output)
  assert_true(not last:match(" 0 failures$"), "the totals show failures: " .. last)
  h.remove_tree(dir)
end)

-- A process's report is trusted only whole and only when its exit status
-- agrees with it. Each file below breaks one after its tests ran: its test
-- replaces os.rename (the report is cut short once in place) or os.exit
-- (the process ends 0 or 1 whatever its report says)
test("a parallel run fails a process whose report is cut short or disagrees with its exit status", function()
  local cut = '  h.test("cut shortens its report", function() local rename, open = os.rename, io.open;'
    .. ' os.rename = function(from, to) local ok, problem = rename(from, to);'
    .. ' if tostring(to):find("%.report$") then local file = open(to, "rb"); local text = file:read("*a"); file:close();'
    .. ' file = open(to, "wb"); file:write(text:sub(1, #text - 4)); file:close() end; return ok, problem end end)\n'
  local exit_with = '  h.test("%s exits %d", function() local exit = os.exit; os.exit = function() exit(%d) end; %s end)\n'
  local dir = RUNNER.tree("reports", {
    ["alpha_test.lua"] = RUNNER.passing("alpha", 2),
    ["cut_test.lua"] = RUNNER.passing("cut", 1, cut),
    ["calm_test.lua"] = RUNNER.passing("calm", 1, string.format(exit_with, "calm", 0, 0, 'error("a failure it hides", 0)')),
    ["alarm_test.lua"] = RUNNER.passing("alarm", 1, string.format(exit_with, "alarm", 1, 1, "")),
  })
  local output, status, folder = RUNNER.run({ "--dir", dir, "--jobs", "4" })
  RUNNER.check(output, status, folder, 1, "a cut report and two exit statuses that disagree")
  for _, case in ipairs({ { "cut_test.lua", "exit 0" }, { "calm_test.lua", "exit 0" }, { "alarm_test.lua", "exit 1" } }) do
    local line = "FAIL " .. case[1] .. ": its process ended abnormally (" .. case[2]
    local _, count = output:gsub(line:gsub("%p", "%%%0"), "")
    assert_equal(count, 2, case[1] .. " is named, in place and again before the totals:\n" .. output)
  end
  local _, last = RUNNER.lines(output)
  local failures = tonumber(last:match("^%d+ tests, (%d+) failures$") or "")
  assert_equal(failures, 3, "each counts as one failure: " .. tostring(last))
  h.remove_tree(dir)
end)

test("a run reads unit files from a folder whose path holds a quote or a dollar sign", function()
  local dir = RUNNER.tree('quote"d $HOME `x`', { ["alpha_test.lua"] = RUNNER.passing("alpha", 5), ["beta_test.lua"] = RUNNER.passing("beta", 4),
    ["gamma_test.lua"] = RUNNER.passing("gamma", 3) })
  for _, jobs in ipairs({ "1", "3" }) do
    local output, status, folder = RUNNER.run({ "--dir", dir, "--jobs", jobs })
    RUNNER.check(output, status, folder, 0, "--jobs " .. jobs .. " from " .. dir)
    local _, last = RUNNER.lines(output)
    assert_equal(last, "12 tests, 0 failures", "--jobs " .. jobs .. ": every file ran\n" .. output)
  end
  h.remove_tree(dir)
end)

-- The names of the files a run's ok lines came from (each test is named
-- after its file), sorted
function RUNNER.files_run(output)
  local names = {}
  for label in output:gmatch("ok   (%a+) 1\n") do names[#names + 1] = label end
  table.sort(names)
  return names
end

test("--shard K/N runs one part of a partition of the unit files, the same on Lua 5.3 and LuaJIT", function()
  local files, all = {}, {}
  local counts = { alpha = 1, beta = 9, gamma = 3, delta = 3, epsilon = 2, zeta = 7, eta = 5 }
  for label, count in pairs(counts) do files[label .. "_test.lua"] = RUNNER.passing(label, count); all[#all + 1] = label end
  table.sort(all)
  local dir = RUNNER.tree("shards", files)
  local other = RUNNER.other_interpreter()
  local count = 3
  do
    local seen = {}
    for shard = 1, count do
      local spec = shard .. "/" .. count
      local by_interpreter = {}
      for _, case in ipairs({ { interpreter = RUNNER.interpreter(), jobs = "1" }, { interpreter = other, jobs = "1" },
          { interpreter = RUNNER.interpreter(), jobs = "2" } }) do
        local output, status, folder = RUNNER.run({ "--dir", dir, "--jobs", case.jobs, "--shard", spec }, { interpreter = case.interpreter })
        RUNNER.check(output, status, folder, 0, "--shard " .. spec .. " under " .. case.interpreter)
        by_interpreter[#by_interpreter + 1] = table.concat(RUNNER.files_run(output), " ")
      end
      assert_equal(by_interpreter[2], by_interpreter[1], "--shard " .. spec .. ": the same files under " .. other)
      assert_equal(by_interpreter[3], by_interpreter[1], "--shard " .. spec .. ": the same files run in parallel")
      for label in by_interpreter[1]:gmatch("%a+") do
        assert_true(seen[label] == nil, label .. " is in shards " .. tostring(seen[label]) .. " and " .. spec); seen[label] = spec
      end
      -- a filter keeps the shard's own files that match it (a shard with
      -- none of them fails, as a filter matching nothing does)
      local output, status, folder = RUNNER.run({ "--dir", dir, "--jobs", "1", "--shard", spec, "eta" })
      local expected = {}
      for label in by_interpreter[1]:gmatch("%a+") do if (label .. "_test.lua"):find("eta", 1, true) then expected[#expected + 1] = label end end
      RUNNER.check(output, status, folder, #expected > 0 and 0 or 1, "--shard " .. spec .. " eta")
      assert_equal(table.concat(RUNNER.files_run(output), " "), table.concat(expected, " "), "--shard " .. spec .. " eta")
    end
    for _, label in ipairs(all) do assert_true(seen[label] ~= nil, label .. " is in one of " .. count .. " shards") end
  end
  h.remove_tree(dir)
end)

test("the unit files' shards are a partition balanced by weight, a file with no weight takes the default, and no weight is stale", function()
  local names = unit_files(repo_root .. "/test/unit")
  local weights = h.UNIT_FILE_SECONDS
  assert_true(type(weights) == "table", "h.UNIT_FILE_SECONDS is the unit files' weights")
  -- a weight is optional; a line naming no unit file is stale
  assert_equal(table.concat(h.stale_unit_weights({ "a_test.lua" }, { ["a_test.lua"] = 2, ["gone_test.lua"] = 4, ["old_test.lua"] = 1 }), " "),
    "gone_test.lua old_test.lua", "the lines naming no unit file, sorted")
  assert_equal(table.concat(h.stale_unit_weights({ "a_test.lua", "new_test.lua" }, { ["a_test.lua"] = 2 }), " "), "",
    "a unit file with no line is no problem")
  assert_equal(table.concat(h.stale_unit_weights(names, weights), ", "), "",
    "UNIT_FILE_SECONDS (test/helpers.lua) names no unit file: remove these lines")
  for name, seconds in pairs(weights) do
    assert_true(type(seconds) == "number" and seconds >= 1 and seconds == math.floor(seconds), name .. "'s weight is a whole number of seconds")
  end
  assert_equal(h.unit_file_seconds("zz_new_test.lua"), h.UNIT_FILE_DEFAULT_SECONDS, "a file with no line weighs the default")
  local total, heaviest = 0, 0
  weights = setmetatable({}, { __index = function(_, name) return h.unit_file_seconds(name) end })
  for _, name in ipairs(names) do total = total + weights[name]; heaviest = math.max(heaviest, weights[name]) end
  for count = 1, 4 do
    local seen, loads = {}, {}
    for shard = 1, count do
      loads[shard] = 0
      for _, name in ipairs(h.shard_files(names, shard, count)) do
        assert_true(seen[name] == nil, name .. " is in two of " .. count .. " shards"); seen[name] = shard
        loads[shard] = loads[shard] + weights[name]
      end
      -- greedy by weight: no shard exceeds the even share by more than the heaviest file
      assert_true(loads[shard] <= total / count + heaviest, "shard " .. shard .. "/" .. count .. " is balanced: " .. loads[shard])
    end
    for _, name in ipairs(names) do assert_true(seen[name] ~= nil, name .. " is in one of " .. count .. " shards") end
  end
  -- a file with no weight still runs, in some shard
  local with_new = { "zz_new_test.lua" }
  for _, name in ipairs(names) do with_new[#with_new + 1] = name end
  local found = 0
  for shard = 1, 3 do
    for _, name in ipairs(h.shard_files(with_new, shard, 3)) do if name == "zz_new_test.lua" then found = found + 1 end end
  end
  assert_equal(found, 1, "a unit file with no weight is in exactly one shard")
end)

test("test/run.lua refuses a malformed --jobs, --shard or STRATA_TEST_JOBS with a usage line", function()
  local dir = RUNNER.three_files("usage")
  local cases = {
    { "--shard", "0/3" }, { "--shard", "4/3" }, { "--shard", "1/0" }, { "--shard", "x" }, { "--shard", "1/" },
    { "--shard", "1/3/4" }, { "--shard", "-1/3" }, { "--shard", "1.5/3" }, { "--shard" }, { "--jobs", "0" },
    { "--jobs", "x" }, { "--jobs", "-2" }, { "-j" }, { "--frob" }, { "alpha", "beta" },
  }
  for _, case in ipairs(cases) do
    table.insert(case, 1, dir); table.insert(case, 1, "--dir")
    local output, status, folder = RUNNER.run(case)
    RUNNER.check(output, status, folder, 2, table.concat(case, " "))
    assert_true(output:find("\nusage: ", 1, true) or output:find("^usage: "), table.concat(case, " ") .. ": a usage line\n" .. output)
    assert_true(not output:find("ok   ", 1, true), table.concat(case, " ") .. ": no test ran\n" .. output)
  end
  local output, status, folder = RUNNER.run({ "--dir", dir }, { env = "STRATA_TEST_JOBS=many " })
  RUNNER.check(output, status, folder, 2, "STRATA_TEST_JOBS=many")
  assert_true(output:find("usage: ", 1, true) ~= nil, "STRATA_TEST_JOBS=many: a usage line\n" .. output)
  h.remove_tree(dir)
end)

test("a run started inside a run is single-process, and STRATA_TEST_JOBS sets the default", function()
  local dir = RUNNER.three_files("nested")
  local output, status, folder = RUNNER.run({ "--dir", dir, "--jobs", "3" }, { nested = true })
  RUNNER.check(output, status, folder, 0, "a nested --jobs 3")
  assert_equal(output, RUNNER.three_files_output(), "a run inside a run prints a single-process run's output")
  output, status, folder = RUNNER.run({ "--dir", dir }, { env = "STRATA_TEST_JOBS=2 " })
  RUNNER.check(output, status, folder, 0, "STRATA_TEST_JOBS=2")
  assert_true(output:find("\n3 unit files in 2 processes, %d+ s\n\n12 tests, 0 failures\n$") ~= nil, "STRATA_TEST_JOBS=2:\n" .. output)
  output, status, folder = RUNNER.run({ "--dir", dir, "-j", "3" }, { env = "STRATA_TEST_JOBS=1 " })
  RUNNER.check(output, status, folder, 0, "-j 3 over STRATA_TEST_JOBS=1")
  assert_true(output:find("\n3 unit files in 3 processes, %d+ s\n") ~= nil, "the option wins over the variable:\n" .. output)
  -- with neither, the machine's cores (h.default_jobs), never more than the files
  local jobs = math.min(h.default_jobs(), 3)
  output, status, folder = RUNNER.run({ "--dir", dir })
  RUNNER.check(output, status, folder, 0, "the default")
  if jobs == 1 then
    assert_equal(output, RUNNER.three_files_output(), "one core: a single-process run")
  else
    assert_true(output:find("\n3 unit files in " .. jobs .. " processes, %d+ s\n") ~= nil, "the default, " .. jobs .. " processes:\n" .. output)
  end
  h.remove_tree(dir)
end)

-- The suite deletes its temporary folders only through h.remove_tree (#134)
test("remove_tree deletes only inside the suite's temporary folder", function()
  local function exists(path)
    local file = io.open(path, "r"); if file then file:close() end
    return file ~= nil
  end
  local function refused(path)
    local ok, err = pcall(h.remove_tree, path)
    return not ok and tostring(err):find("remove_tree", 1, true) ~= nil
  end
  local root = data_root:gsub("/+$", "")
  for _, path in ipairs({ "", "/", "//", "relative/dir", root:match("^(.*)/"), root .. "_sibling",
      root .. "/../escape", root .. "/a/./b", root .. "/a/../../b", "/tmp", "/" .. "home" }) do
    assert_true(refused(path), "refused: " .. path)
  end
  assert_true(refused(nil) and refused(42), "refused: not a string")
  -- a folder inside it goes, files and all, also with a quote and spaces in its name
  for _, name in ipairs({ "remove_me", "it's a dir", "-rf" }) do
    local dir = data_root .. "remove_tree/" .. name
    os.execute("mkdir -p " .. h.shell_quote(dir))
    local file = assert(io.open(dir .. "/file.txt", "w")); file:write("x"); file:close()
    h.remove_tree(dir .. "/")
    assert_true(not exists(dir .. "/file.txt"), "removed: " .. name)
  end
  assert_true(exists(data_root .. "remove_tree"), "and nothing above it")
  h.remove_tree(data_root .. "remove_tree")
  assert_equal(h.shell_quote("it's"), "'it'\\''s'", "shell_quote escapes a single quote")
end)

test("engine_sources reads Engine_Strata.sc first, then lib/engine sorted", function()
  local text = h.engine_sources()
  local files = {}; for path in text:gmatch("// file: (%S+)") do files[#files + 1] = path end
  assert_equal(files[1], "lib/Engine_Strata.sc")
  assert_true(#files > 2, "lib/engine/*.sc are read: " .. table.concat(files, " "))
  for i = 2, #files do assert_true(files[i]:match("^lib/engine/[^/]+%.sc$"), "an engine file: " .. files[i]) end
  for i = 3, #files do assert_true(files[i - 1] < files[i], "sorted") end
end)

test("a command defined in lib/engine is found with its file", function()
  local text = h.engine_sources()
  local at = text:find("addCommand%(\\voiceOn"); local before = text:sub(1, at)
  assert_equal(before:match(".*// file: (%S+)"), "lib/engine/StrataVoices.sc")
  assert_equal(stubs.parse_engine_signatures(text).voiceOn, "iffffff")
  -- the harness, sync_check and the AGENTS.md table check read the same text
  assert_equal(signatures.voiceOn, "iffffff", "the stub's signatures")
  assert_equal(h.sync_check.sc_commands(text).loadBuffer, "isf", "sync_check's commands")
  -- a parse error names the file it is in
  local ok, message = pcall(stubs.parse_engine_spec, text .. "\nSynthDef(\\open, { arg x;\n")
  assert_true(not ok and tostring(message):find(text:match(".*// file: (%S+)"), 1, true), "error names the file: " .. tostring(message))
end)

test("the stub reads a constant given as a method", function()
  assert_equal(stubs.parse_engine_spec("bufferStateStride { ^100 }").buffer_state_stride, 100)
  assert_equal(stubs.parse_engine_spec("var <>bufferSeconds = 16;").buffer_seconds, 16, "a writable var")
  assert_equal(engine_spec.buffer_state_stride, 1000, "the engine's stride")
  assert_true(engine_spec.grain_params.history, "a grainParamHandlers key is a grain param")
  assert_true(engine_spec.grain_params.bufPos and engine_spec.grain_params.posSpread, "both grainDefs' controls are grain params")
end)

-- The controls the engine sets itself are no setVoiceParam or setGrainParam
-- name (#458): kept under one, a value stays in the engine's voiceControls
-- or grainControls for good (kill 1 cut every grain synth the engine
-- started for the voice 50 ms in). setGrainParam also refuses the
-- voice-level pan and bend, which come through setVoiceParam.
test("the engine stub rejects the controls the engine sets itself (#458)", function()
  load_strata()
  local function refused(command, ...)
    local name = select(2, ...)
    local ok, message = pcall(engine[command], ...)
    return not ok and tostring(message):find('"' .. name .. '"', 1, true) ~= nil
  end
  for _, name in ipairs({ "kill", "gate", "out", "bufnumL", "bufnumR", "bufFrames", "bufRateScale", "envBuf", "windowBank", "bufL", "bufR",
      "phaseBus", "ringLevel", "rateLevel", "t_trig", "pan", "bend", "modBus1", "modBus3", "modFreqAmt1", "modFreqAmt3" }) do
    assert_true(refused("setGrainParam", 0, name, 1), "setGrainParam refuses " .. name)
  end
  for _, name in ipairs({ "kill", "gate", "out", "t_trig", "velocity", "modBus1", "modBus3", "modAmpAmt1", "modAmpAmt3",
      "modFreqAmt1", "modFreqAmt3" }) do
    assert_true(refused("setVoiceParam", 0, name, 1), "setVoiceParam refuses " .. name)
  end
  -- what Lua sends is still taken: FM's modFreq is no crossmod amount
  engine.setGrainParam(0, "grainSize", 0.1); engine.setGrainParam(0, "windowShape", 0.57); engine.setGrainParam(0, "history", 0)
  engine.setVoiceParam(0, "pan", 0); engine.setVoiceParam(0, "bend", 1); engine.setVoiceParam(1, "modFreq", 0.5)
  -- the stub reads the engine's own list: a control taken off it is a name again
  local source = h.engine_sources()
  local patched, count = source:gsub("(engineOwnedControls%s*{%s*%^%s*#%[)%s*\\out,%s*\\gate,%s*\\kill,", "%1 \\out, \\gate,")
  assert_equal(count, 1, "the patch applies")
  local spec = stubs.engine_spec_from_source(patched)
  assert_true(spec.grain_params.kill and spec.voice_params[1].kill, "kill is a name once the engine no longer owns it")
  assert_true(not spec.grain_params.gate and not spec.voice_params[1].gate, "gate is still the engine's")
end)

-- 3.8 (package 0c): a voice's synth is its type (voiceTypeDefs), so the
-- stub keeps each voice's type from the setVoiceType calls it sees and
-- checks setVoiceParam's names against that type's def
test("the stub follows each voice's type from setVoiceType", function()
  load_strata()
  local function rejected(command, ...) return not pcall(engine[command], ...) end
  assert_true(rejected("setVoiceParam", 0, "ratio", 1.5), "voice 0 starts on the Resonator, which has no ratio")
  engine.setVoiceType(0, 1)
  engine.setVoiceParam(0, "ratio", 1.5)
  assert_true(rejected("setVoiceParam", 0, "rq", 0.5), "on FM, rq is no control")
  assert_true(rejected("setVoiceType", 0, #engine_spec.voice_type_defs), "a type past the engine's list")
  assert_true(rejected("setVoiceType", 0, -1), "a type below 0")
  assert_true(rejected("setVoiceType", engine_spec.num_voices, 0), "a voice past the voices")
  engine.setVoiceParam(0, "ratio", 1.5)
  load_strata()
  assert_true(rejected("setVoiceParam", 0, "ratio", 1.5), "a new load starts voice 0 on the Resonator again")
  engine.setVoiceParam(0, "rq", 0.5)
end)

test("a voiceTypeDefs shorter than numVoices fails the parse", function()
  local patched, count = h.engine_sources():gsub(",%s*\\strataRing[%s\\%w,]*%]", "]")
  assert_equal(count, 1, "the patch applies")
  local ok, problem = pcall(stubs.engine_spec_from_source, patched)
  assert_true(not ok, "the parse fails")
  assert_true(tostring(problem):find("voiceTypeDefs", 1, true) ~= nil, "naming voiceTypeDefs: " .. tostring(problem))
end)

test("audio.file_info reads a test sound file and a registered table", function()
  local context = load_strata()
  local path = context.audio_dir .. "probe.wav"
  local function le(value, bytes)
    local out = {}
    for index = 1, bytes do out[index] = string.char(value % 256); value = math.floor(value / 256) end
    return table.concat(out)
  end
  local frames, channels, rate = 11025, 2, 22050
  local data = string.rep("\0", frames * channels * 2)
  os.execute("mkdir -p '" .. context.audio_dir .. "'")
  local file = assert(io.open(path, "wb"))
  file:write("RIFF", le(36 + #data, 4), "WAVEfmt ", le(16, 4), le(1, 2), le(channels, 2), le(rate, 4),
    le(rate * channels * 2, 4), le(channels * 2, 2), le(16, 2), "data", le(#data, 4), data)
  file:close()
  local got_channels, got_frames, got_rate = audio.file_info(path)
  assert_equal(got_channels, 2); assert_equal(got_frames, 11025); assert_equal(got_rate, 22050)
  context.audio.register("/tmp/registered.wav", { channels = 2, frames = 480000, rate = 48000 })
  got_channels, got_frames, got_rate = audio.file_info("/tmp/registered.wav")
  assert_equal(got_channels, 2); assert_equal(got_frames, 480000); assert_equal(got_rate, 48000)
  got_channels, got_frames, got_rate = audio.file_info("/tmp/missing-file.wav")
  assert_equal(got_channels, 0); assert_equal(got_frames, 0); assert_equal(got_rate, 0)
end)

-- lua/core/paramset.lua's PSET actions: params:write(filename, name) calls
-- action_write(filename, name, number), read(filename, silent) calls
-- action_read(filename, silent, number) and delete(filename, name, number)
-- calls action_delete(filename, name, number). A number is a numbered PSET
-- in norns.state.data, <shortname>-<NN>.pset; the menu's delete passes the
-- number itself
test("stub params:write, read and delete pass norns' PSET number to the actions", function()
  local context = load_strata()
  local saved = { params.action_write, params.action_read, params.action_delete }
  local calls = {}
  params.action_write = function(...) calls[#calls + 1] = { "write", ... } end
  params.action_read = function(...) calls[#calls + 1] = { "read", ... } end
  params.action_delete = function(...) calls[#calls + 1] = { "delete", ... } end
  local function last(kind, filename, second, number)
    local call = calls[#calls]
    assert_equal(call[1], kind, kind)
    assert_equal(call[2], filename, kind .. " filename")
    assert_equal(call[3], second, kind .. " second argument")
    assert_equal(call[4], number, kind .. " number")
  end
  assert_equal(norns.state.data, context.data_dir .. "strata/", "norns.state.data is the script's data folder")
  assert_equal(norns.state.shortname, "strata")
  local numbered = context.data_dir .. "strata/strata-02.pset"
  params:write(2, "two")
  last("write", numbered, "two", "02")
  local file = assert(io.open(numbered, "r")); file:close()
  params:read(2)
  last("read", numbered, nil, "02")
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  local path = context.data_dir .. "plain.pset"
  params:write(path)
  last("write", path, nil, nil)
  params:read(path, true)
  last("read", path, true, nil)
  local count = #calls
  params:read(context.data_dir .. "missing.pset")
  assert_equal(#calls, count, "a missing file runs no read action")
  params:delete(numbered, "two", "02")
  last("delete", numbered, "two", "02")
  assert_equal(io.open(numbered, "r"), nil, "delete removes the file")
  params:delete(3)
  last("delete", context.data_dir .. "strata/strata-03.pset", nil, nil)
  params.action_write, params.action_read, params.action_delete = saved[1], saved[2], saved[3]
end)

-- 3.4's five modulation commands (design §0.3): the stub refuses what the
-- engine would ignore (an index out of range, a non-finite offset) and what
-- it would clip (the continuous arguments), so a Lua package sends neither
local function assert_stub_refuses(expected_text, command, ...)
  local ok, message = pcall(engine[command], ...)
  assert_true(not ok, "engine." .. command .. " should be refused (" .. expected_text .. ")")
  assert_true(tostring(message):find(expected_text, 1, true) ~= nil,
    "engine." .. command .. "'s refusal names " .. expected_text .. ": " .. tostring(message))
end

test("the engine stub checks the five modulation commands", function()
  local context = load_strata()
  assert_stub_refuses("lfo 6 is outside 0..5", "setFastLfo", 6, 0, 0, 0, 1, 0.5, 0)
  assert_stub_refuses("voice 7 is outside 0..6", "setFastLfo", 0, 7, 0, 0, 1, 0.5, 0)
  assert_stub_refuses("destination 5 is outside 0..4", "setFastLfo", 0, 0, 5, 0, 1, 0.5, 0)
  assert_stub_refuses("shape 8 is outside 0..7", "setFastLfo", 0, 0, 0, 8, 1, 0.5, 0)
  assert_stub_refuses("rate 0.001 is outside 0.003..50", "setFastLfo", 0, 0, 0, 0, 0.001, 0.5, 0)
  assert_stub_refuses("rate 51 is outside 0.003..50", "setFastLfo", 0, 0, 0, 0, 51, 0.5, 0)
  assert_stub_refuses("depth 1.5 is outside 0..1", "setFastLfo", 0, 0, 0, 0, 1, 1.5, 0)
  assert_stub_refuses("offset 2.5 is outside -2..2", "setFastLfo", 0, 0, 0, 0, 1, 0.5, 2.5)
  assert_stub_refuses("lfo 6 is outside 0..5", "stopFastLfo", 6)
  assert_stub_refuses("phase 1.5 is outside 0..1", "syncFastLfo", 0, 1.5)
  assert_stub_refuses("depth 1.5 is outside 0..1", "setScatter", 1.5, 0.1, 3, 127)
  assert_stub_refuses("rate 2 is outside 0.01..1", "setScatter", 0.1, 2, 3, 127)
  assert_stub_refuses("destinations 32 is outside 0..31", "setScatter", 0.1, 0.1, 32, 127)
  assert_stub_refuses("voices 128 is outside 0..127", "setScatter", 0.1, 0.1, 3, 128)
  assert_stub_refuses("voice 7 is outside 0..6", "setFastOffset", 7, 0, 0, 0)
  assert_stub_refuses("note slot 1 is outside 0..0", "setFastOffset", 0, 1, 0, 0)
  assert_stub_refuses("destination 5 is outside 0..4", "setFastOffset", 0, 0, 5, 0)
  assert_stub_refuses("must be a finite number", "setFastOffset", 0, 0, 0, 0 / 0)
  -- the limits, and an offset past ±2, which the engine clamps (Lua's sum of routings)
  local calls = #context.engine_calls
  engine.setFastLfo(5, 6, 4, 7, 50, 1, -2)
  engine.stopFastLfo(0)
  engine.syncFastLfo(5, 1)
  engine.setScatter(0, 0.01, 0, 0)
  engine.setFastOffset(6, 0, 4, 2)
  engine.setFastOffset(0, 0, 0, -3.5)
  assert_equal(#context.engine_calls, calls + 6, "the six calls in range are taken")
end)

-- 3.5's four note commands (design §3.1): the stub refuses an index the
-- engine would ignore (voice, slot 0..noteSlots-1, cut 0-1, the pool
-- 0..notePoolMax) and a continuous value it would clip or ignore
test("the engine stub checks the four note commands", function()
  local context = load_strata()
  local nan = 0 / 0
  assert_stub_refuses("voice 7 is outside 0..6", "noteOn", 7, 1, 60, 440, 1, 1)
  assert_stub_refuses("slot 8 is outside 0..7", "noteOn", 0, 8, 60, 440, 1, 1)
  assert_stub_refuses("note 128 is outside 0..127", "noteOn", 0, 1, 128, 440, 1, 1)
  assert_stub_refuses("freq 7 is outside 8..20000", "noteOn", 0, 1, 60, 7, 1, 1)
  assert_stub_refuses("freq 20001 is outside 8..20000", "noteOn", 0, 1, 60, 20001, 1, 1)
  assert_stub_refuses("rate 0.2 is outside 0.25..4", "noteOn", 0, 1, 60, 440, 0.2, 1)
  assert_stub_refuses("rate 4.1 is outside 0.25..4", "noteOn", 0, 1, 60, 440, 4.1, 1)
  assert_stub_refuses("velocity 1.5 is outside 0..1", "noteOn", 0, 1, 60, 440, 1, 1.5)
  assert_stub_refuses("must be a finite number", "noteOn", 0, 1, 60, nan, 1, 1)
  assert_stub_refuses("slot 8 is outside 0..7", "noteOff", 0, 8, 0)
  assert_stub_refuses("cut 2 is outside 0..1", "noteOff", 0, 1, 2)
  assert_stub_refuses("slot 8 is outside 0..7", "noteExpression", 0, 8, 1, 1, 0, 0, 0)
  assert_stub_refuses("bend 0.05 is outside 0.0625..16", "noteExpression", 0, 1, 0.05, 1, 0, 0, 0)
  assert_stub_refuses("bend 17 is outside 0.0625..16", "noteExpression", 0, 1, 17, 1, 0, 0, 0)
  assert_stub_refuses("amp 2.5 is outside 0..2", "noteExpression", 0, 1, 1, 2.5, 0, 0, 0)
  assert_stub_refuses("position 1.5 is outside -1..1", "noteExpression", 0, 1, 1, 1, 1.5, 0, 0)
  assert_stub_refuses("size -1.5 is outside -1..1", "noteExpression", 0, 1, 1, 1, 0, -1.5, 0)
  assert_stub_refuses("must be a finite number", "noteExpression", 0, 1, 1, 1, 0, 0, nan)
  assert_stub_refuses("size 17 is outside 0..16", "setNotePool", 17)
  assert_stub_refuses("size -1 is outside 0..16", "setNotePool", -1)
  -- the limits
  local calls = #context.engine_calls
  engine.noteOn(6, 7, 127, 20000, 4, 1)
  engine.noteOn(0, 0, 0, 8, 0.25, 0)
  engine.noteOff(0, 0, 0)
  engine.noteOff(6, 7, 1)
  engine.noteExpression(6, 7, 16, 2, 1, -1, 1)
  engine.noteExpression(0, 0, 0.0625, 0, 0, 0, 0)
  engine.setNotePool(0)
  engine.setNotePool(16)
  assert_equal(#context.engine_calls, calls + 8, "the eight calls in range are taken")
end)

-- 3.7's three engine commands (design §2.4, §3.4, §4.4): noteRegion takes an
-- extra slot only (ruling 1), syncScan a voice, setSlotGain a slot; the
-- continuous values are the engine's clips. And 3.7's grain params: scanMode
-- an enumeration, rootNote a handler's key, the sync and the gain the engine's
test("the engine stub checks 3.7's three commands and grain params", function()
  local context = load_strata()
  local nan = 0 / 0
  assert_stub_refuses("slot 0 is outside 1..7", "noteRegion", 0, 0, 0.5, 0.25)
  assert_stub_refuses("slot 8 is outside 1..7", "noteRegion", 0, 8, 0.5, 0.25)
  assert_stub_refuses("voice 7 is outside 0..6", "noteRegion", 7, 1, 0.5, 0.25)
  assert_stub_refuses("start 1.5 is outside 0..1", "noteRegion", 0, 1, 1.5, 0.25)
  assert_stub_refuses("length -0.5 is outside 0..1", "noteRegion", 0, 1, 0.5, -0.5)
  assert_stub_refuses("must be a finite number", "noteRegion", 0, 1, nan, 0.25)
  assert_stub_refuses("voice 7 is outside 0..6", "syncScan", 7, 0.5)
  assert_stub_refuses("phase 2.5 is outside 0..2", "syncScan", 0, 2.5)
  assert_stub_refuses("slot 8 is outside 0..7", "setSlotGain", 8, 1)
  assert_stub_refuses("gain 17 is outside 0..16", "setSlotGain", 0, 17)
  assert_stub_refuses("scanMode 3 is outside 0..2", "setGrainParam", 0, "scanMode", 3)
  assert_stub_refuses("a control the engine sets itself", "setGrainParam", 0, "slotGain", 2)
  assert_stub_refuses("a control the engine sets itself", "setGrainParam", 0, "scanSyncPhase", 0.5)
  local calls = #context.engine_calls
  engine.noteRegion(6, 7, 1, 1)
  engine.noteRegion(0, 1, 0, 0)
  engine.syncScan(6, 2)
  engine.syncScan(0, 0)
  engine.setSlotGain(7, 16)
  engine.setSlotGain(0, 0)
  for _, param in ipairs({ "scanMode", "regionStart", "regionLength", "followRate", "rootNote" }) do
    engine.setGrainParam(0, param, 1)
  end
  assert_equal(#context.engine_calls, calls + 11, "the eleven calls in range are taken")
end)

test("fastModIn is a control the engine sets itself", function()
  load_strata()
  assert_stub_refuses('"fastModIn" is a control the engine sets itself', "setGrainParam", 0, "fastModIn", 1)
  assert_stub_refuses('"fastModIn" is a control the engine sets itself', "setVoiceParam", 0, "fastModIn", 1)
end)

test("the stub accepts the gate and mute params", function()
  local context = load_strata()
  local calls = #context.engine_calls
  engine.setGrainParam(0, "seqGate", 1)
  engine.setGrainParam(0, "gateSeconds", 0.0625)
  engine.setGrainParam(0, "gateRelease", 0.1)
  engine.setGrainParam(0, "voiceMute", 1)
  assert_equal(#context.engine_calls, calls + 4, "seqGate, gateSeconds, gateRelease and voiceMute are taken")
  assert_equal(context.engine_calls[#context.engine_calls].args[2], "voiceMute")
end)

-- The stage's gate and mute switches are 0 or 1: the engine rounds and
-- clips them (seqGate.round.clip(0, 1), voiceMute.round.clip(0, 1) in
-- StrataModulation.sc), which the stub reads as their enumerations
test("the stub rejects seqGate 2 and voiceMute 2", function()
  local context = load_strata()
  assert_stub_refuses("seqGate 2 is outside 0..1", "setGrainParam", 0, "seqGate", 2)
  assert_stub_refuses("voiceMute 2 is outside 0..1", "setGrainParam", 0, "voiceMute", 2)
  assert_stub_refuses("seqGate 0.5 must be a whole number", "setGrainParam", 0, "seqGate", 0.5)
  assert_stub_refuses("voiceMute -1 is outside 0..1", "setGrainParam", 0, "voiceMute", -1)
  local calls = #context.engine_calls
  engine.setGrainParam(0, "seqGate", 1)
  engine.setGrainParam(0, "voiceMute", 0)
  assert_equal(#context.engine_calls, calls + 2, "0 and 1 are taken")
  assert_equal(engine_spec.enumerations.seqGate[2], 1, "seqGate's enumeration, from the engine source")
  assert_equal(engine_spec.enumerations.voiceMute[2], 1, "voiceMute's enumeration, from the engine source")
end)

-- lua/core/pmap.lua and the MIDI handler of lua/core/menu/params.lua (#602)
test("the stub's MIDI map is norns' pmap, and the menu's CC handler sets a mapped param by its type", function()
  load_strata()
  local pmap = norns.pmap
  local function cc(number, value) norns.menu_midi_event({ 0xb2, number, value }, 2) end  -- channel 3, port 2
  pmap.new("master_density"); pmap.assign("master_density", 2, 3, 10)
  pmap.new("tempo"); pmap.data.tempo.out_lo, pmap.data.tempo.out_hi = 60, 120
  pmap.assign("tempo", 2, 3, 10)
  assert_equal(pmap.data.master_density, nil, "a CC assigned to a second param leaves the first")
  assert_equal(pmap.rev[2][3][10], "tempo")
  cc(10, 127); assert_equal(params:get("tempo"), 120, "a number: the output range, rounded")
  pmap.new("reverb_mix"); pmap.assign("reverb_mix", 2, 3, 11)
  cc(11, 0); assert_near(params:get("reverb_mix"), 0, 1e-9, "a control: its raw value")
  cc(11, 127); assert_near(params:get("reverb_mix"), 1, 1e-9)
  pmap.new("delay_bypass"); pmap.assign("delay_bypass", 2, 3, 12)
  cc(12, 127); assert_equal(params:get("delay_bypass"), 1, "a toggle binary toggles")
  cc(12, 0); assert_equal(params:get("delay_bypass"), 1, "and a 0 leaves it")
  norns.menu_midi_event({ 0x92, 10, 0 }, 2)  -- a note on: no CC
  assert_equal(params:get("tempo"), 120)
  pmap.write(); pmap.clear()
  assert_equal(pmap.rev[2][3][10], nil, "cleared")
  pmap.read()
  assert_equal(pmap.rev[2][3][10], "tempo", "read back from strata.pmap")
  assert_equal(pmap.data.tempo.out_hi, 120); assert_equal(pmap.data.tempo.echo, false)
  pmap.new("no_such_param"); pmap.assign("no_such_param", 2, 3, 13)
  local ok, problem = pcall(cc, 13, 1)
  assert_true(not ok and tostring(problem):find("invalid paramset index", 1, true) ~= nil,
    "a map on an id that is no param raises, as on norns: " .. tostring(problem))
end)

-- test/sync_check.lua's PENDING_COMMANDS: a command the engine has before
-- the script calls it (3.7's until their callers land). The mechanism on
-- a two-file fixture with an engine source of its own: the full sources'
-- check is docs_test.lua's
test("the sync check accepts a pending command that is not called and fails one that is", function()
  local sync_check = h.sync_check
  local engine_source = 'this.addCommand(\\checkUsed, "i", { arg msg; });\n'
    .. 'this.addCommand(\\checkPendingGhost, "i", { arg msg; });'
  local sources = { { path = "strata.lua", text = "\nengine.checkUsed(1)" }, { path = "lib/x.lua", text = "" } }
  local pending = { "checkPendingGhost" }
  local ok, problems = sync_check.check_sources(sources, engine_source, pending)
  assert_true(ok, "a pending command no file calls passes:\n" .. table.concat(problems, "\n"))
  -- once a file calls it, the check fails until its name leaves the list
  local calling = { sources[1], { path = "lib/x.lua", text = "\nengine.checkPendingGhost(1)" } }
  ok, problems = sync_check.check_sources(calling, engine_source, pending)
  local report = table.concat(problems, "\n")
  assert_true(not ok and report:find("lib/x.lua:2 engine.checkPendingGhost is called but still pending", 1, true),
    "a called pending command fails the check:\n" .. report)
  ok, problems = sync_check.check_sources(calling, engine_source, {})
  assert_true(ok, "off the list, the called command passes:\n" .. table.concat(problems, "\n"))
  -- off the list, the uncalled command is reported as ever
  ok, problems = sync_check.check_sources(sources, engine_source, {})
  report = table.concat(problems, "\n")
  assert_true(not ok and report:find("\\checkPendingGhost is never called", 1, true), "an uncalled command fails:\n" .. report)
  -- a pending name the engine does not have is a stale entry
  ok, problems = sync_check.check_sources(sources, engine_source, { "checkPendingGhost", "checkNoSuchCommand" })
  report = table.concat(problems, "\n")
  assert_true(not ok and report:find("checkNoSuchCommand is pending but the engine has no such command", 1, true),
    "a pending name with no addCommand fails:\n" .. report)
  -- the real list names engine commands only
  for _, name in ipairs(sync_check.PENDING_COMMANDS) do
    assert_true(signatures[name] ~= nil, "pending " .. name .. " is an engine command")
  end
end)

-- matron's clock_start_from_source (clock.cc): the source's beat is 0, every
-- waiting sync's beat is reset to 0 (clock_scheduler_reset_sync_events, so it
-- fires on the next tick and counts on from 0), then norns calls
-- clock.transport.start; a stop calls clock.transport.stop
test("stub clock: transport_start resets the beat and the waiting syncs, then calls the transport's start", function()
  local context = load_strata(); finish_startup(context)
  local seen = {}
  clock.transport.start = function() table.insert(seen, {name = "start", beat = clock.get_beats()}) end
  clock.transport.stop = function() table.insert(seen, {name = "stop", beat = clock.get_beats()}) end
  local wakes = {}
  local syncing = clock.run(function()
    while true do table.insert(wakes, {beat = clock.sync(1), time = util.time()}) end
  end)
  context.clock.run_for(0.75)  -- beat 2.5, waiting for beat 3
  assert_near(clock.get_beats(), 2.5, 1e-9, "on beat 2.5")
  assert_equal(#wakes, 1, "woke at beat 2")
  local reset_at = util.time()
  context.clock.transport_start()
  assert_near(clock.get_beats(), 0, 1e-9, "the beat is 0")
  assert_equal(#seen, 1, "the start handler ran once")
  assert_equal(seen[1].name, "start")
  assert_near(seen[1].beat, 0, 1e-9, "after the reset")
  context.clock.run_for(0)
  assert_equal(#wakes, 2, "the waiting sync fired on the next tick")
  assert_near(wakes[2].time, reset_at, 1e-9, "at once")
  context.clock.run_for(0.5)
  assert_equal(#wakes, 3, "then on the new beat 1")
  assert_near(wakes[3].time, reset_at + 0.5, 1e-9, "half a second on")
  context.clock.transport_stop()
  assert_equal(seen[2].name, "stop", "a stop calls the stop handler")
  clock.cancel(syncing)
  -- with no handlers set, neither helper raises
  clock.transport.start, clock.transport.stop = nil, nil
  context.clock.transport_start()
  context.clock.transport_stop()
end)

-- clock_start_from_source resets the beat and the waiting syncs, then posts
-- EVENT_CLOCK_START: Lua delivers every resume posted before it first, then
-- the start (clock.transport.start). transport_reset is the reset alone
test("stub clock: transport_reset resets the beat and the waiting syncs and calls no handler", function()
  local context = load_strata(); finish_startup(context)
  local starts = 0
  clock.transport.start = function() starts = starts + 1 end
  local wakes = {}
  local syncing = clock.run(function()
    while true do table.insert(wakes, {beat = clock.sync(1), time = util.time()}) end
  end)
  context.clock.run_for(0.75)  -- beat 2.5, waiting for beat 3
  local reset_at = util.time()
  context.clock.transport_reset()
  assert_near(clock.get_beats(), 0, 1e-9, "the beat is 0")
  assert_equal(starts, 0, "no handler runs")
  context.clock.run_for(0)
  assert_equal(#wakes, 2, "the waiting sync fired on the next tick")
  assert_near(wakes[2].time, reset_at, 1e-9, "at once")
  context.clock.run_for(0.5)
  assert_near(wakes[3].beat, 1, 1e-9, "then counted on from 0")
  clock.cancel(syncing)
end)

-- advance's hook runs once the step's resumes are posted, before any is
-- delivered: a reset in it leaves every posted resume as it was
test("stub clock: advance's hook runs between the step's posts and its deliveries", function()
  local context = load_strata(); finish_startup(context)  -- beat 1
  local woke = {}
  local function waiter(name)
    return clock.run(function()
      while true do table.insert(woke, {name = name, beat = clock.sync(1)}) end
    end)
  end
  local first, second = waiter("first"), waiter("second")
  local hooked, posted = 0, 0
  repeat
    context.clock.advance(function()
      hooked = hooked + 1
      -- the steps before (the script's own clocks) post neither
      if context.clock.events[first].ready then return end
      posted = posted + 1
      assert_equal(context.clock.events[second].ready, false, "the second's resume is posted with the first's")
      context.clock.transport_reset()
    end)
  until #woke > 0
  assert_true(hooked >= 1, "the hook runs in every step")
  assert_equal(posted, 1, "once in the step where both were due")
  assert_equal(#woke, 2, "both were delivered")
  assert_near(woke[1].beat, 2, 1e-9, "with the beat they were posted at")
  assert_near(woke[2].beat, 2, 1e-9, "both")
  assert_near(context.clock.events[first].sync_beat, 3, 1e-9, "each counts its next sync on from 2")
  clock.cancel(first); clock.cancel(second)
end)

-- A coroutine canceled after its resume was posted (Lua handled another
-- event first) still gets the resume: norns' clock.resume finds no
-- coroutine and raises, as lua/core/clock.lua's does
test("stub clock: a resume posted before advance's hook cancels its coroutine is still delivered, and raises", function()
  local context = load_strata(); finish_startup(context)
  local woke = 0
  local waiting = clock.run(function()
    while true do clock.sync(1); woke = woke + 1 end
  end)
  local canceled = false
  repeat
    context.clock.advance(function()
      if not canceled and not context.clock.events[waiting].ready then
        canceled = true
        clock.cancel(waiting)
      end
    end)
  until canceled
  assert_equal(woke, 0, "the coroutine never ran again")
  local errors = context.clock.take_errors()
  assert_equal(#errors, 1, "one error")
  -- Lua 5.3 (norns'): "bad argument #1 to 'resume' (thread expected)"; LuaJIT says "coroutine expected"
  assert_true(errors[1]:find("bad argument #1 to '[^']*resume'") ~= nil and errors[1]:find("expected)", 1, true) ~= nil,
    "norns' resume of a coroutine it no longer has: " .. errors[1])
end)

-- The same for a coroutine an earlier resume in the step cancels: matron's
-- tick posted both resumes before Lua delivered either
test("stub clock: a resume posted in the step of an earlier resume that cancels its coroutine is still delivered, and raises", function()
  local context = load_strata(); finish_startup(context)  -- beat 1
  local woke, second = {}, nil
  local first = clock.run(function()
    while true do
      clock.sync(1)
      table.insert(woke, "first")
      if second then clock.cancel(second); second = nil end
    end
  end)
  second = clock.run(function()
    while true do clock.sync(1); table.insert(woke, "second") end
  end)
  repeat context.clock.advance() until #woke > 0  -- the step at beat 2 posts both, the first's slot first
  assert_equal(table.concat(woke, " "), "first", "the canceled coroutine never ran again")
  local errors = context.clock.take_errors()
  assert_equal(#errors, 1, "one error")
  assert_true(errors[1]:find("bad argument #1 to '[^']*resume'") ~= nil and errors[1]:find("expected)", 1, true) ~= nil,
    "norns' resume of a coroutine it no longer has: " .. errors[1])
  clock.cancel(first)
end)

-- Two coroutines that sync to beat 2 (the first holding the lower event slot):
-- the first's resume cancels the second, whose resume matron's tick posted
-- with the first's. Returns their ids and the names of the deliveries that ran
local function start_same_instant_cancel()
  local woke, second = {}, nil
  local first = clock.run(function()
    while true do
      clock.sync(1)
      table.insert(woke, "first")
      if second then clock.cancel(second); second = nil end
    end
  end)
  second = clock.run(function()
    while true do clock.sync(1); table.insert(woke, "second") end
  end)
  return first, second, woke
end

local function assert_canceled_resume_raised(context, what)
  local errors = context.clock.take_errors()
  assert_equal(#errors, 1, what .. ": one error")
  -- Lua 5.3 (norns'): "bad argument #1 to 'resume' (thread expected)"; LuaJIT says "coroutine expected"
  assert_true(errors[1]:find("bad argument #1 to '[^']*resume'") ~= nil and errors[1]:find("expected)", 1, true) ~= nil,
    what .. ": norns' resume of a coroutine it no longer has: " .. errors[1])
end

-- run_for posts every resume due at an instant before it delivers any, as
-- matron's tick and advance do (#588), with or without a latency
test("stub clock: run_for delivers a resume posted at the instant of an earlier resume that cancels its coroutine, and it raises (#588)", function()
  for _, latency in ipairs({ 0, 0.001 }) do
    local context = load_strata(); finish_startup(context)  -- beat 1 (0.5 s at 120 BPM)
    local first, _, woke = start_same_instant_cancel()
    context.clock.run_for(0.75, latency)  -- beat 2 at 1 s, not beat 3
    assert_equal(table.concat(woke, " "), "first", "latency " .. latency .. ": the canceled coroutine never ran again")
    assert_canceled_resume_raised(context, "latency " .. latency)
    clock.cancel(first)
  end
end)

-- advance_until posts every resume due at an instant before it delivers any
-- (#588): on its way to a later coroutine, and for its own coroutine
-- canceled after the post
test("stub clock: advance_until delivers a resume posted at the instant of an earlier resume that cancels its coroutine, and it raises (#588)", function()
  local context = load_strata(); finish_startup(context)  -- beat 1 (0.5 s at 120 BPM)
  local first, second, woke = start_same_instant_cancel()
  local later = clock.run(function() clock.sleep(0.75) end)  -- 1.25 s, after beat 2
  context.clock.advance_until(later)
  assert_equal(table.concat(woke, " "), "first", "on the way: the canceled coroutine never ran again")
  assert_canceled_resume_raised(context, "on the way to a later coroutine")
  clock.cancel(first)

  context = load_strata(); finish_startup(context)
  first, second, woke = start_same_instant_cancel()
  local ok, message = pcall(context.clock.advance_until, second)
  assert_true(ok, "its own coroutine canceled after its resume was posted is no failure: " .. tostring(message))
  assert_equal(table.concat(woke, " "), "first", "its own coroutine never ran again")
  assert_canceled_resume_raised(context, "its own coroutine, canceled after the post")
  clock.cancel(first)
end)

-- advance_until stops once its own coroutine's resume is delivered: the
-- resumes posted at its instant after it stay posted (norns' event queue),
-- and the next helper call, whichever it is, delivers them first (#588)
test("stub clock: the resumes posted at advance_until's instant after its own are delivered by the next helper call (#588)", function()
  for _, next_call in ipairs({ "advance", "run_for", "advance_until" }) do
    local context = load_strata(); finish_startup(context)  -- beat 1 (0.5 s at 120 BPM)
    local first, second, woke = start_same_instant_cancel()
    context.clock.advance_until(first)
    local what = next_call .. " next"
    assert_equal(table.concat(woke, " "), "first", what .. ": it stops after its own coroutine")
    assert_equal(context.clock.threads[second], nil, what .. ": which canceled the second")
    assert_equal(#context.clock.take_errors(), 0, what .. ": whose resume is posted, not yet delivered")
    local before = util.time()
    if next_call == "advance" then context.clock.advance()
    elseif next_call == "run_for" then context.clock.run_for(0)
    else context.clock.advance_until(first) end
    assert_canceled_resume_raised(context, what)
    if next_call == "run_for" then assert_near(util.time(), before, 1e-12, what .. ": delivered at once") end
    clock.cancel(first)
  end
end)

-- The script's own clocks stopped, so the clocks a test starts are the only
-- ones that wake
local function quiet_clocks()
  stop_frame_clock(); local_value("S").lib.waveforms.stop()
  clock.cancel(local_value("S").lib.playheads.clock_id()); local_value("S").lib.lfos.stop_clock()
end

-- Two coroutines that sleep 0.25 s and 0.25 s + gap: the first (the lower
-- event slot) cancels the second when it wakes. Returns their ids and the
-- names of the deliveries that ran
local function start_near_cancel(gap)
  local woke, second = {}, nil
  local first = clock.run(function()
    clock.sleep(0.25); table.insert(woke, "first")
    if second then clock.cancel(second); second = nil end
  end)
  second = clock.run(function() clock.sleep(0.25 + gap); table.insert(woke, "second") end)
  return first, second, woke
end

-- matron's tick comes every 1 ms (clock_scheduler.cc's usleep(1000)), so two
-- wake-ups less than a tick apart can be posted by one tick before either is
-- delivered: a cancel by the first never stops the second's delivery, through
-- any helper (ruling 92), whether they differ by rounding or by half a tick
test("stub clock: wake-ups less than matron's 1 ms tick apart share a tick, so a cancel between them raises through every helper (#588)", function()
  for _, gap in ipairs({ 1e-10, 0.0005 }) do
    for _, helper in ipairs({ "advance", "run_for", "advance_until first", "advance_until second" }) do
      local what = helper .. ", " .. gap .. " s apart"
      local context = load_strata(); finish_startup(context); quiet_clocks()
      local first, second, woke = start_near_cancel(gap)
      if helper == "advance" then
        repeat context.clock.advance() until #woke > 0
      elseif helper == "run_for" then
        context.clock.run_for(1)
      elseif helper == "advance_until first" then
        context.clock.advance_until(first)
        context.clock.run_for(0)  -- the second's posted resume, delivered next
      else
        local ok, message = pcall(context.clock.advance_until, second)
        assert_true(ok, what .. ": its own coroutine, posted before the cancel, is no failure: " .. tostring(message))
      end
      assert_equal(table.concat(woke, " "), "first", what .. ": the canceled coroutine never ran")
      assert_canceled_resume_raised(context, what)
    end
  end
end)

-- With a latency, Lua delivers each resume after its wake-up: every tick due
-- by then has posted its resumes, so a cancel made then never stops one of
-- those deliveries; a clock due after the delivery is canceled cleanly
test("stub clock: with a latency, run_for posts every tick due by a delivery before it, so a cancel then raises (#588)", function()
  local context = load_strata(); finish_startup(context); quiet_clocks()
  local _, _, woke = start_near_cancel(0.005)  -- the second due 5 ms after the first
  context.clock.run_for(1, 0.01)                -- the first delivered 10 ms after its wake-up
  assert_equal(table.concat(woke, " "), "first", "the canceled coroutine never ran")
  assert_canceled_resume_raised(context, "a clock due before the delivery")

  context = load_strata(); finish_startup(context); quiet_clocks()
  _, _, woke = start_near_cancel(0.02)          -- the second due 20 ms after the first
  context.clock.run_for(1, 0.01)
  assert_equal(table.concat(woke, " "), "first", "the canceled coroutine never ran")
  assert_equal(#context.clock.take_errors(), 0, "a clock due after the delivery was never posted: its cancel raises nothing")
end)

-- A clock that sleeps math.huge (a waiting quantized action's flash,
-- lib/quantize.lua) is never due: matron's tick never finds clock_time >=
-- infinity. No helper takes it as the next event, posts it or moves time to
-- it: time stops at the last finite event or at the requested end (#650).
-- Returns its id and whether it woke
local function start_forever_sleeper()
  local state = { woke = false }
  state.id = clock.run(function() clock.sleep(math.huge); state.woke = true end)
  return state
end

test("stub clock: advance never moves time to a clock that sleeps forever (#650)", function()
  local context = load_strata(); finish_startup(context); quiet_clocks()
  local forever = start_forever_sleeper()
  local start = util.time()
  context.clock.advance()
  assert_equal(util.time(), start, "alone: nothing is due, and time stays")
  assert_true(not forever.woke and context.clock.events[forever.id].ready, "it still waits, never posted")
  local woke = false
  clock.run(function() clock.sleep(0.25); woke = true end)
  context.clock.advance()
  assert_true(woke, "beside a finite sleeper: the finite one wakes")
  assert_near(util.time(), start + 0.25, 1e-12, "at its own wake-up")
  context.clock.advance()
  assert_near(util.time(), start + 0.25, 1e-12, "then nothing is due: time stops at the last finite event")
  assert_true(not forever.woke and context.clock.events[forever.id].ready, "the forever sleeper still waits")
  clock.cancel(forever.id)
end)

test("stub clock: run_for never moves time to a clock that sleeps forever, and ends at its end (#650)", function()
  for _, latency in ipairs({ 0, 0.01 }) do
    local what = "latency " .. latency
    local context = load_strata(); finish_startup(context); quiet_clocks()
    local forever = start_forever_sleeper()
    local start = util.time()
    context.clock.run_for(1, latency)
    assert_near(util.time(), start + 1, 1e-12, what .. ", alone: time ends at the requested end")
    local woke = false
    clock.run(function() clock.sleep(0.25); woke = true end)
    context.clock.run_for(1, latency)
    assert_true(woke, what .. ", beside a finite sleeper: the finite one wakes")
    assert_near(util.time(), start + 2, 1e-12, what .. ": and time ends at the requested end")
    assert_true(not forever.woke and context.clock.events[forever.id].ready, what .. ": the forever sleeper still waits")
    clock.cancel(forever.id)
  end
end)

test("stub clock: advance_until fails at once for a clock that sleeps forever, and runs past it to a finite one (#650)", function()
  local context = load_strata(); finish_startup(context); quiet_clocks()
  local forever = start_forever_sleeper()
  local start = util.time()
  local ok, message = pcall(context.clock.advance_until, forever.id)
  assert_true(not ok and tostring(message):find("never wakes", 1, true), "alone: it never wakes: " .. tostring(message))
  assert_equal(util.time(), start, "and time stays")
  local woke = false
  local finite = clock.run(function() while true do clock.sleep(0.25); woke = true end end)
  ok, message = pcall(context.clock.advance_until, forever.id)
  assert_true(not ok and tostring(message):find("never wakes", 1, true), "beside a finite sleeper: at once: " .. tostring(message))
  assert_true(not woke and util.time() == start, "running nothing, time staying")
  context.clock.advance_until(finite)
  assert_true(woke, "the finite sleeper wakes")
  assert_near(util.time(), start + 0.25, 1e-12, "at its own wake-up, past the forever sleeper")
  assert_true(not forever.woke and context.clock.events[forever.id].ready, "the forever sleeper still waits")
  clock.cancel(forever.id); clock.cancel(finite)
end)

-- matron's clock_set_source (and crow's input division) reschedule every
-- waiting sync from the new source's beat (clock_scheduler_reschedule_sync_events:
-- the next multiple of its beats after the new beat, plus its offset), with
-- no transport start
test("stub clock: set_beat moves the beat and reschedules the waiting syncs from it, as a source change does", function()
  local context = load_strata(); finish_startup(context)
  local starts = 0
  clock.transport.start = function() starts = starts + 1 end
  local wakes = {}
  local syncing = clock.run(function()
    while true do table.insert(wakes, {beat = clock.sync(1, -0.25), time = util.time()}) end
  end)
  context.clock.run_for(0.5)  -- beat 2: it waited for 1.75 and now waits for 2.75
  assert_equal(#wakes, 1, "woke at beat 1.75")
  local jumped_at = util.time()
  context.clock.set_beat(10.1)
  assert_near(clock.get_beats(), 10.1, 1e-9, "the beat jumps")
  assert_equal(starts, 0, "no transport start")
  context.clock.run_for(0.4)
  assert_equal(#wakes, 2, "the waiting sync was rescheduled from 10.1")
  assert_near(wakes[2].beat, 10.75, 1e-9, "to the next multiple of 1 after it, less 0.25")
  assert_near(wakes[2].time, jumped_at + 0.325, 1e-9, "0.65 beats on")
  clock.cancel(syncing)
end)

-- matron's tick posts every resume due on it before Lua delivers any, so a
-- reset or a jump can fall between a coroutine's post and its delivery
test("stub clock: advance posts every due resume before delivering one, and advance_until can act between", function()
  local context = load_strata(); finish_startup(context)  -- beat 1
  local woke = {}
  -- the first coroutine, resumed first in the step, resets the clock
  local first, resetting = nil, true
  local real_sync = clock.sync
  clock.sync = function(...)
    local beat = real_sync(...)
    if resetting and coroutine.running() == context.clock.threads[first] then
      resetting = false
      context.clock.transport_start()
    end
    return beat
  end
  local function waiter(name)
    return clock.run(function()
      while true do table.insert(woke, {name = name, beat = clock.sync(1)}) end
    end)
  end
  first = waiter("first")
  local second = waiter("second")
  repeat context.clock.advance() until #woke > 0  -- to the step at beat 2, where both are due
  clock.sync = real_sync
  assert_equal(#woke, 2, "both woke in the step")
  assert_equal(woke[2].name, "second")
  assert_near(woke[2].beat, 2, 1e-9, "the second's resume was posted before the reset: it carries beat 2")
  assert_near(context.clock.events[second].sync_beat, 3, 1e-9,
    "and the reset left its event alone: its next sync counts on from 2, not from the reset's 0")
  -- advance_until's hook runs once the coroutine's resume is posted, before
  -- it is delivered: a reset in it leaves that resume as it was (each now
  -- waits for beat 3, counted on from beat 2), and the second's, posted at
  -- the same instant and delivered by the next helper call (#588), too
  local hooked = 0
  context.clock.advance_until(first, function()
    hooked = hooked + 1
    assert_equal(context.clock.events[first].ready, false, "posted before the hook")
    assert_equal(context.clock.events[second].ready, false, "the second's resume posted with it")
    context.clock.transport_start()
  end)
  assert_equal(hooked, 1, "the hook ran once")
  assert_equal(woke[#woke].name, "first")
  assert_near(woke[#woke].beat, 3, 1e-9, "delivered with the beat it was posted at")
  context.clock.run_for(0)
  assert_equal(woke[#woke].name, "second", "the next call delivers the second")
  assert_near(woke[#woke].beat, 3, 1e-9, "with the beat it was posted at, before the hook's reset")
  clock.cancel(first); clock.cancel(second)
end)

-- norns' lib/er.lua, required as "er": the bucket method, w shifting right
test("stub er.gen is norns' lib/er.lua", function()
  load_strata()
  local er = require("er")
  local function pattern(k, n, w)
    local marks = {}
    for index, hit in ipairs(er.gen(k, n, w)) do marks[index] = hit and "x" or "." end
    return table.concat(marks)
  end
  assert_equal(pattern(3, 8, 0), "x..x..x.", "three in eight")
  assert_equal(pattern(3, 8, 1), ".x..x..x", "shifted one step")
  assert_equal(pattern(5, 8, 0), "x.x.xx.x", "five in eight")
  assert_equal(pattern(0, 4, 0), "....", "no hits")
  assert_equal(pattern(4, 4, 0), "xxxx", "every step")
  assert_equal(pattern(3, 8, nil), "x..x..x.", "no shift given")
  assert_equal(pattern(2, 5, -1), "..x.x", "a negative shift wraps")
end)


-- norns' lib/musicutil.lua's note_num_to_name: 60 is C3, the octave only
-- with include_octave (ruling 28: the zones editor names notes as norns does)
test("stub musicutil.note_num_to_name is norns' lib/musicutil.lua", function()
  load_strata()
  local musicutil = require("musicutil")
  assert_equal(musicutil.note_num_to_name(0, true), "C-2", "the lowest note")
  assert_equal(musicutil.note_num_to_name(12, true), "C-1")
  assert_equal(musicutil.note_num_to_name(60, true), "C3", "middle C is C3")
  assert_equal(musicutil.note_num_to_name(61, true), "C#3")
  assert_equal(musicutil.note_num_to_name(127, true), "G8", "the highest note")
  assert_equal(musicutil.note_num_to_name(61), "C#", "no octave without include_octave")
  assert_equal(musicutil.note_num_to_name(1, true), "C#-2", "the widest name")
end)

-- 3.6's stubs (Task 0d): crow, OSC, softcut, nb and iii
local function captured_prints(action)
  local lines, real = {}, _G.print
  _G.print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do parts[index] = tostring((select(index, ...))) end
    table.insert(lines, table.concat(parts, "\t"))
  end
  local ok, err = pcall(action)
  _G.print = real
  assert_true(ok, tostring(err))
  return lines
end

-- norns:lua/core/crow.lua:198-223 builds each line with core/crow/quote.lua:
-- a key is "[%g]" for a number and "[%q]" for a string (the first link of a
-- chain is bare), a number "%.6g", a string "%q", arguments joined by ","
test("the crow stub sends what norns' proxy sends, only while a crow is there", function()
  local context = load_strata()
  context.crow.clear()
  crow.send("x = 1")
  assert_equal(#context.crow.sent, 0, "nothing is recorded with no crow plugged")
  context.crow.plug()
  assert_true(norns.crow.connected(), "plug sets norns.crow.dev")
  context.crow.clear()
  crow.send("x = 1")
  crow("x = 1")
  crow.output[1].volts = 3
  crow.ii.jf.play_note(0.5, 5)
  crow.input[1].mode("stream", 0.02)
  crow.state = {7}
  crow.ii.jf.run_mode(1 / 3, true)
  crow.output[2]()
  assert_equal(table.concat(context.crow.sent, "\n"), table.concat({
    "x = 1", "x = 1", 'output[1]["volts"]=3', 'ii["jf"]["play_note"](0.5,5)',
    'input[1]["mode"]("stream",0.02)', 'state={[1]=7}', 'ii["jf"]["run_mode"](0.333333,true)',
    "output[2]()" }, "\n"), "the proxy's lines")
  context.crow.clear()
  crow.reset()
  assert_equal(context.crow.sent[1], "crow.reset()", "crow.reset sends its line")
  context.crow.unplug()
  assert_true(not norns.crow.connected(), "unplug clears norns.crow.dev")
end)

test("the crow stub counts function assignments and resets", function()
  local context = load_strata()
  norns.crow.init(); context.crow.resets = 0  -- as a script clear leaves it: lib/io/crow.lua's handlers and events set aside
  crow.input[1].stream = function() end
  assert_equal(context.crow.function_assignments, 1, "counted unplugged")
  assert_equal(#context.crow.sent, 0, "and nothing sent")
  context.crow.plug()
  assert_equal(context.crow.resets, 1, "the default add resets crow")
  context.crow.clear()
  crow.input[2].stream = function() end
  assert_equal(context.crow.function_assignments, 2)
  -- norns' seven static events come first, so the first function is H, the second I
  assert_equal(context.crow.sent[1], 'input[2]["stream"]=function(...)_c.tell("I",quote(...))end',
    "norns' forwarding stub names the next event key")
  local added = {}
  norns.crow.add = function(id, name, dev) table.insert(added, id .. name .. dev) end
  context.crow.plug()
  assert_equal(#added, 1, "a script's own add runs in place of the default")
  assert_equal(context.crow.resets, 1, "and the default's reset does not")
end)

test("a fired crow event reaches the script's handler, and an unassigned one prints", function()
  local context = load_strata()
  norns.crow.init(); context.crow.resets = 0  -- as a script clear leaves it: lib/io/crow.lua's handlers and events set aside
  context.crow.plug()
  local got
  crow.input[1].stream = function(...) got = {...} end
  context.crow.fire("H", 1.5, 2)
  assert_equal(got and (got[1] .. "," .. got[2]), "1.5,2", "the handler's arguments")
  local lines = captured_prints(function() context.crow.fire("Z", 1, "a") end)
  assert_equal(lines[1], 'unused event: ^^Z(1,"a")', "norns' unused event line")
  lines = captured_prints(function() context.crow.fire("version", "v4") end)
  assert_equal(lines[1], "crow version: v4", "a static event")
end)

test("the OSC stub runs the script's handler, then norns' /param handling", function()
  local context = load_strata()
  local order = {}
  context.params:add_number("osc_test_param", "osc test", 0, 10, 0)
  context.params:set_action("osc_test_param", function(value) table.insert(order, "param " .. value) end)
  osc.event = function(path, args, from)
    table.insert(order, path .. " " .. from[1] .. ":" .. from[2])
  end
  context.osc.receive("/param/osc_test_param", {2})
  assert_equal(table.concat(order, "|"), "/param/osc_test_param 10.0.0.2:57121|param 2", "handler first, then the param")
  assert_equal(context.params:get("osc_test_param"), 2)
  local lines = captured_prints(function() context.osc.receive("/param/nope", {1}) end)
  assert_equal(#lines, 1, "an unknown id prints once")
  assert_true(lines[1]:find("osc event error: ", 1, true) and lines[1]:find("invalid paramset index: nope", 1, true),
    "the printed text names the error: " .. tostring(lines[1]))
  osc.event = function() error("script handler failed") end
  local ok, err = pcall(context.osc.receive, "/x", {})
  assert_true(not ok and tostring(err):find("script handler failed", 1, true), "a script handler's error reaches the test")
  osc.event = nil
  osc.send({"10.0.0.2", 9000}, "/x", {1})
  assert_equal(context.osc.sent[1].to[2], 9000, "send is recorded")
  assert_equal(context.osc.sent[1].path, "/x")
  assert_equal(context.osc.sent[1].args[1], 1)
end)

test("the softcut stub records calls by name and refuses a name softcut lacks", function()
  local context = load_strata()
  assert_equal(softcut.VOICE_COUNT, 6)
  assert_equal(softcut.BUFFER_SIZE, 16777216 / 48000)
  assert_equal(context.softcut.value("rate", 1), nil, "nil before any call")
  softcut.rate(1, 0.5)
  softcut.rate(1, 0.75)
  softcut.rate(2, 2)
  softcut.level_input_cut(1, 2, 0.25)
  assert_equal(context.softcut.value("rate", 1), 0.75, "the last value for voice 1")
  assert_equal(context.softcut.value("rate", 2), 2)
  assert_equal(context.softcut.value("level_input_cut", 1, 2), 0.25, "two leading arguments")
  assert_equal(context.softcut.calls[1][1], "rate")
  assert_true(not pcall(function() softcut.no_such(1) end), "a name softcut lacks raises")
  assert_equal(softcut.filter_fc ~= nil, true, "an alias is a function")
  context.audio.api.level_eng_cut(1)
  assert_equal(context.audio.levels.eng_cut, 1)
  audio.level_cut(0.5)
  assert_equal(context.audio.levels.cut, 0.5)
  assert_equal(audio.file_info("/nope"), 0, "file_info still works")
  softcut.reset()
  assert_equal(#context.softcut.calls, 0, "reset empties the calls")
  assert_equal(context.softcut.value("rate", 1), nil, "and the values")
end)

test("the nb stub's players record their calls", function()
  local context = load_strata()
  local player = context.nb.add_player("emp", {"note_on", "note_off", "modulate_note", "describe"})
  assert_true(note_players.emp == player, "the player is in note_players")
  player:note_on(60, 0.5)
  player:note_off(60)
  player:modulate_note(60, "pressure", 0.5)
  assert_equal(player.calls[1][1] .. player.calls[1][2] .. player.calls[1][3], "note_on600.5")
  assert_equal(#player.calls, 3)
  assert_equal(player.calls[3][3], "pressure")
  assert_equal(player:describe().name, "emp", "describe names the player")
end)

test("the iii stub runs a device script against iii's functions", function()
  local context = load_strata()
  local path = data_root .. "iii_stub_script.lua"
  local file = assert(io.open(path, "w"))
  file:write("function event_grid(x, y, z) midi_note_on(x * 16 + y, z * 100, 1) end\n"
    .. "function event_midi(b1, b2, b3) grid_led(2, 1, b3 % 16); grid_refresh() end\n"
    .. "function event_arc(n, d) midi_cc(n, d, 2) end\n")
  file:close()
  local device = require("stub_iii")({kind = "grid", cols = 16, rows = 8})
  device.run(path)
  device.press(2, 1, 1)
  assert_equal(table.concat(device.sent[1], ","), "144,33,100", "a note on, the status byte first")
  device.midi_in(0x90, 5, 7)
  assert_equal(device.leds[1][2], 7, "the LED as last refreshed, [y][x]")
  assert_equal(device.refreshes, 1)
  device.turn(3, 5)
  assert_equal(table.concat(device.sent[2], ","), "177,3,5", "an arc turn")
  device.connect(context, 3)
  local heard = {}
  context.midi.vports[3].event = function(data) table.insert(heard, table.concat(data, ",")) end
  device.press(1, 1, 1)
  assert_equal(heard[1], "144,17,100", "what the script sends is the port's incoming message")
  context.midi.vports[3]:note_on(60, 100, 1)
  assert_equal(device.leds[1][2], 4, "a message Strata sends reaches event_midi (100 % 16)")
  assert_equal(device.refreshes, 2)
end)

test("every global the stubs add is defined for a script that reads it", function()
  -- the structure test's list is every key of _G after an install, so a global
  -- the install sets is known to it; a script chunk reads each here
  local context = load_strata({ source = "probe = { crow ~= nil, osc ~= nil, softcut ~= nil, note_players ~= nil,"
    .. " quote ~= nil, norns_crow = norns.crow ~= nil, levels = audio.level_eng_cut ~= nil }" })
  local probe = rawget(_G, "probe")
  _G.probe = nil
  assert_true(probe, "the script chunk ran")
  for key, defined in pairs(probe) do assert_true(defined, tostring(key) .. " is defined for a script") end
  assert_equal(rawget(_G, "nb_player_refcounts"), nil, "nb_player_refcounts is nil until a host makes it")
  _G.nb_player_refcounts = { stale = 1 }
  load_strata()
  assert_equal(rawget(_G, "nb_player_refcounts"), nil, "and does not survive the next install, as norns' fresh globals")
end)

test("the crow stub models neither crow.public nor norns.crow.public, and reading them raises", function()
  load_strata()
  local ok, err = pcall(function() return crow.public end)
  assert_true(not ok and tostring(err):find("not modeled", 1, true), "crow.public raises: " .. tostring(err))
  ok, err = pcall(function() crow.public.x = 1 end)
  assert_true(not ok and tostring(err):find("not modeled", 1, true), "crow.public.x never goes through the proxy")
  ok, err = pcall(function() return norns.crow.public end)
  assert_true(not ok and tostring(err):find("not modeled", 1, true), "norns.crow.public raises")
  assert_equal(norns.crow.dev, nil, "other unset fields still read nil")
  assert_equal(quote(1, "a"), '1,"a"', "the global quote is core/crow/quote.lua's")
  assert_equal(quote.key("k"), '["k"]')
end)

test("the iii stub's script has its own libraries and no unpack, as iii runs Lua 5.3", function()
  load_strata()
  local path = data_root .. "iii_env_script.lua"
  local file = assert(io.open(path, "w")); file:write("-- nothing\n"); file:close()
  local device = require("stub_iii")({kind = "grid"})
  local env = device.run(path)
  assert_equal(env.unpack, nil, "no global unpack")
  assert_true(env.table ~= table and env.string ~= string and env.math ~= math, "its own copies")
  assert_true(type(env.table.unpack) == "function", "table.unpack exists")
  env.table.marker, env.math.marker, env.string.marker = 1, 1, 1
  assert_equal(table.marker, nil, "the host's table is untouched")
  assert_equal(math.marker, nil, "the host's math is untouched")
  assert_equal(string.marker, nil, "the host's string is untouched")
end)

test("the iii stub's midi_out sends raw bytes three at a time and models no message table", function()
  load_strata()
  local path = data_root .. "iii_out_script.lua"
  local file = assert(io.open(path, "w"))
  file:write("function event_midi(b1) if b1 == 1 then midi_out({144, 60, 100, 128, 60}) else midi_out({type = 'note_on'}) end end\n")
  file:close()
  local device = require("stub_iii")({kind = "grid"})
  device.run(path)
  device.midi_in(1)
  assert_equal(#device.sent, 2, "two calls of three bytes")
  assert_equal(table.concat(device.sent[1], ","), "144,60,100")
  assert_equal(device.sent[2][1] .. "," .. device.sent[2][2], "128,60")
  assert_equal(device.sent[2][3], nil, "the last call gets nil arguments")
  local ok, err = pcall(device.midi_in, 2)
  assert_true(not ok and tostring(err):find("not modeled", 1, true), "a message table raises: " .. tostring(err))
end)

test("the iii stub's metros free by id, share no live id, hold 15 and fire on a helper", function()
  load_strata()
  local path = data_root .. "iii_metro_script.lua"
  local file = assert(io.open(path, "w"))
  file:write("fired = 0\nfunction event_midi(b1)\n  if b1 == 1 then m = metro.init(function(n) fired = fired + 1; last = n end, 0.5)\n"
    .. "    m:start() ; id = m.id\n  elseif b1 == 2 then m.free(m.id)\n  elseif b1 == 3 then metro.free_all() end\nend\n")
  file:close()
  local device = require("stub_iii")({kind = "grid"})
  local env = device.run(path)
  device.midi_in(1)
  local first = env.id
  device.fire_metro(first)
  assert_equal(env.fired, 1, "the callback ran")
  assert_equal(env.last, 1, "with the firing's number")
  device.midi_in(2)
  assert_true(not pcall(device.fire_metro, first), "a freed metro does not fire")
  device.midi_in(1)
  assert_equal(env.id, first, "a freed id may be handed out again")
  local live = {}
  for index = 1, 14 do live[index] = device.run(path).metro.init(function() end, 1) end
  local seen = {}
  for _, metro in ipairs(live) do assert_true(not seen[metro.id], "no live id is shared"); seen[metro.id] = true end
  assert_true(not seen[env.id], "nor with the first")
  assert_equal(env.metro.init(function() end, 1), nil, "a sixteenth metro is refused (iii allows 15)")
  device.midi_in(3)
  assert_true(not pcall(device.fire_metro, env.id), "free_all frees every metro")
  assert_true(env.metro.init(function() end, 1) ~= nil, "and room is back")
  local object = env.metro.init(function() end, 1)
  object.free_all()
  assert_true(not pcall(device.fire_metro, object.id), "m.free_all() on the object frees them too")
  assert_true(not pcall(device.fire_metro, 999), "an unknown id raises")
end)

test("the iii stub's connection follows the MIDI device's port and ends when it unplugs", function()
  local context = load_strata()
  local path = data_root .. "iii_conn_script.lua"
  local file = assert(io.open(path, "w"))
  file:write("function event_grid(x, y, z) midi_note_on(60, 100, 1) end\nfunction event_midi(b1, b2, b3) got = b2 end\n")
  file:close()
  local device = require("stub_iii")({kind = "grid"})
  local env = device.run(path)
  device.connect(context, 3)
  local heard = {}
  for port = 3, 5 do
    context.midi.vports[port].event = function() table.insert(heard, port) end
  end
  context.midi.reassign(3, 5)
  device.press(1, 1, 1)
  assert_equal(table.concat(heard, ","), "5", "the script's message reaches the port the device is on now")
  context.midi.vports[5]:note_on(70, 100, 1)
  assert_equal(env.got, 70, "and Strata's message on the new port reaches the script")
  context.midi.unplug(5)
  heard = {}
  device.press(1, 1, 1)
  assert_equal(#heard, 0, "after an unplug the script's messages go nowhere")
  assert_equal(#device.sent, 2, "but are still recorded")
end)

test("the iii stub's version options set device_version and iii_version as the facts give them", function()
  load_strata()
  local path = data_root .. "iii_version_script.lua"
  local file = assert(io.open(path, "w")); file:write("-- nothing\n"); file:close()
  local env = require("stub_iii")({kind = "grid"}).run(path)
  assert_equal(env.device_version(), "v260324", "the firmware date tag")
  assert_equal(env.iii_version, "v1.1.2", "iii's own version")
  env = require("stub_iii")({kind = "arc", version = "v1.1.0"}).run(path)
  assert_equal(type(env.device_version), "function", "device_version is new in 1.1.0")
  assert_equal(env.iii_version, nil, "iii_version is present from 1.1.1")
  env = require("stub_iii")({kind = "grid", version = "v1.0.0"}).run(path)
  assert_true(type(env.device_version) ~= "function", "absent before 1.1.0")
  assert_equal(env.iii_version, nil)
  env = require("stub_iii")({kind = "grid", firmware = "v240324"}).run(path)
  assert_equal(env.device_version(), "v240324", "a firmware tag can be chosen")
end)

test("the softcut stub keeps callbacks to fire and refuses defaults and params", function()
  local context = load_strata()
  local got = {}
  softcut.event_phase(function(voice, phase) table.insert(got, "phase " .. voice .. " " .. phase) end)
  softcut.event_position(function(voice, pos) table.insert(got, "position " .. voice .. " " .. pos) end)
  softcut.event_render(function(ch, start, step, data) table.insert(got, "render " .. ch .. " " .. #data) end)
  context.softcut.fire("event_phase", 1, 0.5)
  context.softcut.fire("event_position", 2, 3)
  context.softcut.fire("event_render", 1, 0, 1, {1, 2})
  assert_equal(table.concat(got, "|"), "phase 1 0.5|position 2 3|render 1 2")
  assert_true(not pcall(context.softcut.fire, "event_phase_none"), "firing a name with no callback raises")
  for _, name in ipairs({"defaults", "params"}) do
    local ok, err = pcall(softcut[name])
    assert_true(not ok and tostring(err):find("not modeled", 1, true), "softcut." .. name .. " raises: " .. tostring(err))
  end
  softcut.reset()
  context.softcut.fire("event_phase", 1, 0.5)
  assert_equal(#got, 3, "after a reset the phase callback is norns' do-nothing, so firing it does nothing")
  assert_true(not pcall(context.softcut.fire, "event_position_none"), "a name that was never set raises")
end)

test("an nb player is a plain table with exactly the methods the test names", function()
  local context = load_strata()
  local default = context.nb.add_player("emp")
  local function method_names(player)
    local names = {}
    for key, value in pairs(player) do if type(value) == "function" then table.insert(names, key) end end
    table.sort(names)
    return table.concat(names, ",")
  end
  assert_equal(method_names(default), "add_params,note_off,note_on", "the default methods")
  assert_equal(default.count_up, nil, "no count_up")
  assert_equal(default.stop_all, nil, "no stop_all")
  assert_equal(default.name, nil, "the host sets the name")
  assert_equal(getmetatable(default), nil, "no metatable")
  local custom = context.nb.add_player("jf", {"note_on", "stop_all", "delayed_active"})
  assert_equal(method_names(custom), "delayed_active,note_on,stop_all", "exactly the named methods")
  custom:stop_all()
  custom:delayed_active()
  assert_equal(custom.calls[1][1] .. custom.calls[2][1], "stop_alldelayed_active")
  assert_true(note_players.jf == custom and note_players.emp == default, "both are in note_players")
end)

test("an nb player can inherit methods through a metatable, as another host leaves them (#698)", function()
  local context = load_strata({ before_load = function(early)
    early.nb.add_player("midi: box 1", {"note_on"}, {"count_up", "stop_all"})
  end })
  local player = note_players["midi: box 1"]
  assert_true(player ~= nil, "a player added before the script loads is in note_players")
  assert_true(player.count_up ~= nil, "an inherited method answers")
  assert_equal(rawget(player, "count_up"), nil, "but is no raw field")
  assert_true(rawget(player, "note_on") ~= nil, "a method the mod wrote is a raw field")
  assert_equal(getmetatable(player) ~= nil, true, "the player has a metatable")
  player:count_up(1)
  player:stop_all()
  player:note_on(60)
  assert_equal(player.calls[1][1] .. player.calls[1][2] .. player.calls[2][1] .. player.calls[3][1],
    "count_up1stop_allnote_on", "inherited methods record into calls too")
  assert_equal(getmetatable(context.nb.add_player("plain", {"note_on"})), nil, "no inherited list, no metatable")
  assert_equal(player.name, nil, "still no name")
end)

test("the iii stub's libraries hold only the names Lua 5.3 has, under either interpreter", function()
  load_strata()
  local path = data_root .. "iii_libs_script.lua"
  local file = assert(io.open(path, "w")); file:write("-- nothing\n"); file:close()
  local env = require("stub_iii")({kind = "grid"}).run(path)
  for _, name in ipairs({"getn", "foreach", "foreachi", "maxn", "setn"}) do
    assert_equal(env.table[name], nil, "table." .. name .. " is not Lua 5.3's")
  end
  for _, name in ipairs({"pow", "ldexp", "frexp", "cosh", "sinh", "tanh", "log10", "atan2"}) do
    assert_equal(env.math[name], nil, "math." .. name .. " is not Lua 5.3's")
  end
  for _, name in ipairs({"gfind"}) do assert_equal(env.string[name], nil, "string." .. name) end
  assert_equal(env.table.concat({1, 2}, ","), "1,2")
  assert_equal(env.table.pack(1, nil, 3).n, 3, "table.pack exists, as in 5.3")
  assert_equal(env.table.concat(env.table.move({1, 2, 3}, 1, 3, 2, {}), ",", 2, 4), "1,2,3", "table.move exists")
  assert_equal(env.math.floor(1.5), 1)
  assert_equal(env.string.upper("x"), "X")
  assert_true(not pcall(env.getmetatable, ""), "getmetatable of a string is not modeled")
  assert_equal(env.getmetatable(setmetatable({}, {__index = 1})).__index, 1, "other tables still work")
end)

test("the iii stub reads the leading v<major>.<minor>.<patch> of a version and refuses any other form", function()
  load_strata()
  local path = data_root .. "iii_beta_script.lua"
  local file = assert(io.open(path, "w")); file:write("-- nothing\n"); file:close()
  local env = require("stub_iii")({kind = "grid", version = "v1.1.0b1"}).run(path)
  assert_equal(type(env.device_version), "function", "a beta of 1.1.0 has device_version")
  assert_equal(env.iii_version, nil, "and no iii_version")
  env = require("stub_iii")({kind = "grid", version = "v1.1.1b3"}).run(path)
  assert_equal(env.iii_version, "v1.1.1b3", "iii_version keeps the tag as given")
  for _, bad in ipairs({"1.1.2", "v1.1", "latest", ""}) do
    local ok, err = pcall(require("stub_iii"), {kind = "grid", version = bad})
    assert_true(not ok and tostring(err):find("v<major>.<minor>.<patch>", 1, true), "version " .. bad .. " raises: " .. tostring(err))
  end
end)

test("the iii stub has the rest of iii's functions, and below 1.1.0 calls no event callback", function()
  load_strata()
  local path = data_root .. "iii_funcs_script.lua"
  local file = assert(io.open(path, "w"))
  file:write("function event_grid() hit = 'grid' end\nfunction event_arc() hit = 'arc' end\n"
    .. "function event_arc_key() hit = 'key' end\nfunction event_midi() hit = 'midi' end\n")
  file:close()
  local device = require("stub_iii")({kind = "grid", cols = 16, rows = 8})
  local env = device.run(path)
  local msg = env.midi_to_msg({0x91, 60, 100})
  assert_equal(msg.type .. msg.note .. msg.vel .. msg.ch, "note_on601002", "a note on")
  assert_equal(env.midi_to_msg({0x90, 60, 0}).type, "note_off", "velocity 0 is a note off")
  assert_equal(env.midi_to_msg({0xb0, 7, 9}).type, "cc")
  assert_equal(env.midi_to_msg({0xf0, 1, 2}).type, "sysex", "sysex")
  env.grid_led(2, 1, 9)
  assert_equal(env.grid_led_get(2, 1), 9, "grid_led_get reads the level set (queued)")
  env.grid_intensity(5)
  assert_equal(device.calls[#device.calls][1] .. device.calls[#device.calls][2], "grid_intensity5", "recorded")
  env.arc_intensity(3)
  env.arc_res(2, 4)
  assert_equal(device.arc_resolution[2], 4, "arc_res is kept per ring")
  assert_equal(env.clamp(5, 0, 3), 3)
  assert_equal(env.round(2.5), 3)
  assert_equal(env.linlin(5, 0, 10, 0, 100), 50)
  assert_equal(env.wrap(5, 0, 3), 1, "wrap is inclusive, as norns util.wrap")
  local old = require("stub_iii")({kind = "arc", version = "v1.0.0"})
  local old_env = old.run(path)
  old.press(1, 1, 1); old.turn(1, 1); old.arc_press(1); old.midi_in(1, 2, 3)
  assert_equal(old_env.hit, nil, "no event callback runs below 1.1.0")
end)

---------------------------------------------------------------------------
-- 3.9's package 0a: the transition tables, the notes' tables and the seeded
-- walks (h.transition_table, h.notes_table, h.walk; design section 2)
---------------------------------------------------------------------------

-- The tests `register` adds to the registry, taken out of it again (so the
-- run does not run them a second time), and what it returned
local function registered(register)
  local before = #tests
  local result = register()
  local added = {}
  for index = before + 1, #tests do added[#added + 1] = tests[index] end
  for index = #tests, before + 1, -1 do tests[index] = nil end
  return added, result
end

-- The function of the registered test named `name` among `added`
local function registered_test(added, name)
  for _, entry in ipairs(added) do
    if entry.name == name then return entry.func end
  end
  local names = {}
  for _, entry in ipairs(added) do names[#names + 1] = entry.name end
  error("no test named '" .. name .. "' among: " .. table.concat(names, " | "), 2)
end

-- A machine of two states, kept on the context: `a` and `b`, the event `go`
-- moving a to b and `stay` moving nothing
local function toy_machine(rows, extra)
  local spec = {
    name = "toy",
    states = {
      a = function(context) context.toy = "a" end,
      b = function(context) context.toy = "b" end,
    },
    events = {
      go = function(context) if context.toy == "a" then context.toy = "b" end end,
      stay = function() end,
    },
    state_of = function(context) return context.toy end,
    rows = rows,
  }
  for key, value in pairs(extra or {}) do spec[key] = value end
  return spec
end

local TOY_ROWS = {{"a", "go", "b"}, {"a", "stay", "a"}, {"b", "go", "b"}}

test("a transition table with an undecided cell fails, naming the cell", function()
  local added = registered(function() h.transition_table(toy_machine(TOY_ROWS)) end)
  local ok, message = run_test(registered_test(added, "toy: every cell is decided"))
  assert_true(not ok, "the cell b + stay has no row and no impossible entry")
  assert_true(tostring(message):find("b + stay", 1, true) ~= nil, "the cell is named: " .. tostring(message))
  assert_true(tostring(message):find("a + go", 1, true) == nil, "a decided cell is not: " .. tostring(message))
  for _, name in ipairs({"toy: a + go", "toy: a + stay", "toy: b + go"}) do
    local row_ok, row_message = run_test(registered_test(added, name))
    assert_true(row_ok, name .. " passes: " .. tostring(row_message))
  end
  -- an impossible entry decides the cell
  added = registered(function()
    h.transition_table(toy_machine(TOY_ROWS, {impossible = {{"b", "stay", "b stays b by construction"}}}))
  end)
  ok, message = run_test(registered_test(added, "toy: every cell is decided"))
  assert_true(ok, "every cell decided: " .. tostring(message))
  -- a row whose next state is wrong fails, naming what it found
  added = registered(function() h.transition_table(toy_machine({{"a", "stay", "b"}})) end)
  ok, message = run_test(registered_test(added, "toy: a + stay"))
  assert_true(not ok and tostring(message):find("a", 1, true) ~= nil, "a wrong next fails: " .. tostring(message))
  assert_true(tostring(message):find("expected b, got a", 1, true) ~= nil, "says what it found: " .. tostring(message))
  -- a row whose state is not entered fails before its event
  added = registered(function()
    local spec = toy_machine({{"a", "go", "b"}})
    spec.states.a = function(context) context.toy = "b" end
    h.transition_table(spec)
  end)
  ok, message = run_test(registered_test(added, "toy: a + go"))
  assert_true(not ok and tostring(message):find("entering a", 1, true) ~= nil, "a state not entered: " .. tostring(message))
  -- a row naming no state or event, a cell decided twice and an impossible
  -- entry with no reason are named by the cell test
  added = registered(function()
    h.transition_table(toy_machine({{"a", "go", "b"}, {"a", "go", "b"}, {"c", "go", "a"}, {"b", "jump", "a"},
      {"b", "go", "d"}}, {impossible = {{"a", "stay"}, {"b", "stay", "never"}}}))
  end)
  ok, message = run_test(registered_test(added, "toy: every cell is decided"))
  message = tostring(message)
  for _, part in ipairs({"a + go: decided twice", "no state c", "no event jump", "next state d", "a + stay: no reason"}) do
    assert_true(not ok and message:find(part, 1, true) ~= nil, "names '" .. part .. "': " .. message)
  end
  load_strata()  -- this test leaves nothing broken
end)

test("a known row passes on the fault and is listed", function()
  -- the fault: go should move b back to a, but the code leaves it at b
  local added, result = registered(function()
    return h.transition_table(toy_machine({{"a", "go", "b"}, {"a", "stay", "a"}, {"b", "go", "b", known = 999},
      {"b", "stay", "b"}}))
  end)
  local ok, message = run_test(registered_test(added, "toy: b + go"))
  assert_true(ok, "the known row asserts today's next state and passes: " .. tostring(message))
  assert_true(type(result) == "table" and type(result.known) == "table", "the helper returns its known rows")
  assert_equal(table.concat(result.known, "; "), "toy: b + go -> b (known #999)", "the known row is listed")
  ok, message = run_test(registered_test(added, "toy: every cell is decided"))
  assert_true(ok, "a known row decides its cell: " .. tostring(message))
  -- a known row's issue is a whole number
  added = registered(function() h.transition_table(toy_machine({{"a", "go", "b", known = "soon"}})) end)
  ok, message = run_test(registered_test(added, "toy: every cell is decided"))
  assert_true(not ok and tostring(message):find("known", 1, true) ~= nil, "a known with no issue: " .. tostring(message))
  -- a row's check and the invariants run after the event
  local checked
  added = registered(function()
    h.transition_table(toy_machine({{"a", "go", "b", check = function(context) checked = context.toy end}}))
  end)
  assert_true(run_test(registered_test(added, "toy: a + go")), "the row passes")
  assert_equal(checked, "b", "its check ran after the event")
  added = registered(function()
    local spec = toy_machine({{"a", "go", "b"}})
    spec.events.go = function(context) context.toy = "b"; local_value("S").pattern_playing = true end
    h.transition_table(spec)
  end)
  ok, message = run_test(registered_test(added, "toy: a + go"))
  assert_true(not ok and tostring(message):find("pattern clock", 1, true) ~= nil,
    "an invariant broken by the event fails the row: " .. tostring(message))
  load_strata()  -- this test leaves nothing broken
end)

-- A notes file under data_root holding `text`: its absolute path
local function notes_file(name, text)
  local path = data_root .. name
  h.write_text(path, text)
  return path
end

local TOY_NOTES = table.concat({
  "## Must not break", "", "- nothing", "", "## Machines", "",
  "### toy", "- **State:** `context.toy`.", "", "| State | Event | Next | Effect |", "|---|---|---|---|",
  "| `a` | `go` | `b` | moves |", "| a | stay | a | nothing |", "| b | go | %s | nothing |", "",
}, "\n")

test("a notes table that differs from the rows fails, naming the row", function()
  local rows = {{"a", "go", "b"}, {"a", "stay", "a"}, {"b", "go", "b"}}
  local impossible = {{"b", "stay", "b is left by go only"}}
  local function notes_test(path)
    local added = registered(function()
      h.transition_table(toy_machine(rows, {impossible = impossible, notes = {path, "toy"}}))
    end)
    return run_test(registered_test(added, "toy: the notes' table equals these rows"))
  end
  local ok, message = notes_test(notes_file("toy-same.md", TOY_NOTES:format("b")))
  assert_true(ok, "the same rows pass: " .. tostring(message))
  ok, message = notes_test(notes_file("toy-next.md", TOY_NOTES:format("a")))
  assert_true(not ok, "a different next state fails")
  assert_true(tostring(message):find("b + go", 1, true) ~= nil, "naming the row: " .. tostring(message))
  local fewer = TOY_NOTES:format("b"):gsub("| a | stay | a | nothing |\n", "")
  ok, message = notes_test(notes_file("toy-fewer.md", fewer))
  assert_true(not ok and tostring(message):find("a + stay", 1, true) ~= nil, "a row the notes lack: " .. tostring(message))
  local more = TOY_NOTES:format("b") .. ""
  more = more:gsub("(| b | go | b | nothing |\n)", "%1| b | stay | a | nothing |\n")
  ok, message = notes_test(notes_file("toy-more.md", more))
  assert_true(not ok and tostring(message):find("b + stay", 1, true) ~= nil, "a row only the notes have: " .. tostring(message))
end)

test("notes_table reads the table under its machine's heading and no other", function()
  local path = notes_file("machines.md", table.concat({
    "## Must not break", "", "- nothing", "",
    "```", "### toy", "| State | Event | Next |", "|---|---|---|", "| fenced | e | x |", "```", "",
    "### other", "", "| State | Event | Next | Effect |", "|---|---|---|---|", "| other | e | x | - |", "",
    "### toy", "- **Invariant:** none.", "",
    "| Event | State | Effect | Next |", "|---|---|---|---|",
    "| `go` | `a` | moves `a` to `b` | `b` |", "| stay | a, waiting | the pipe \\| kept | `a, waiting` |", "",
    "A second table under the same heading is not read:", "",
    "| State | Event | Next |", "|---|---|---|", "| second | e | x |", "",
    "### toy later", "", "| State | Event | Next |", "|---|---|---|", "| later | e | x |", "",
  }, "\n"))
  local rows = h.notes_table(path, "toy")
  local text = {}
  for _, row in ipairs(rows) do text[#text + 1] = table.concat(row, " / ") end
  assert_equal(table.concat(text, "; "), "a / go / b; a, waiting / stay / a, waiting",
    "the rows of the first table under ### toy, its State, Event and Next, backticks stripped")
  assert_true(not pcall(h.notes_table, path, "missing"), "no heading raises")
  local bare = notes_file("bare.md", "## Must not break\n\n### toy\n\nno table\n\n### next\n\n| State | Event | Next |\n|---|---|---|\n| x | y | z |\n")
  assert_true(not pcall(h.notes_table, bare, "toy"), "no table under the heading raises")
  local columns = notes_file("columns.md", "### toy\n\n| State | Effect |\n|---|---|\n| a | b |\n")
  assert_true(not pcall(h.notes_table, columns, "toy"), "a table without State, Event and Next raises")
  local relative = h.notes_table("docs/notes/test-harness/run-and-helpers.md", "The example machine")
  assert_true(#relative > 0, "a path relative to the repository's root is read")
end)

test("a walk's failure names its seed, step and ops", function()
  local added = registered(function()
    h.walk({
      name = "toy walk", seeds = {7, 8}, steps = 10,
      setup = function(context) return {context = context, n = 0} end,
      ops = {
        {3, "up", function(state) state.n = state.n + 1 end},
        {1, "draw", function(state, random) state.drawn = random(5) end},
      },
      after = function(state) if state.n == 3 then return {"n reached 3"} end end,
    })
  end)
  assert_equal(#added, 2, "one test a seed, and no reached test without reached")
  assert_equal(added[1].name .. " | " .. added[2].name, "toy walk (seed 7) | toy walk (seed 8)", "named by seed")
  local ok, message = run_test(registered_test(added, "toy walk (seed 7)"))
  message = tostring(message)
  assert_true(not ok, "the walk fails when after returns a problem")
  assert_true(message:find("seed 7", 1, true) ~= nil, "names the seed: " .. message)
  assert_true(message:find("n reached 3", 1, true) ~= nil, "gives the problem: " .. message)
  local step = tonumber(message:match("step (%d+)"))
  assert_true(step ~= nil and step >= 3, "names the step: " .. message)
  local ops = message:match("the ops so far: ([^\n]*)")
  assert_true(ops ~= nil, "lists the ops so far: " .. message)
  local names = {}
  for name in ops:gmatch("[^,%s]+") do names[#names + 1] = name end
  assert_equal(#names, step, "one name a step")
  local ups = 0
  for _, name in ipairs(names) do ups = ups + (name == "up" and 1 or 0) end
  assert_equal(ups, 3, "three ups by the failing step")
  assert_equal(names[#names], "up", "the failing step's op last")
  -- the same seed walks the same ops again
  local _, again = run_test(registered_test(added, "toy walk (seed 7)"))
  assert_equal(tostring(again):match("the ops so far: ([^\n]*)"), ops, "a seed replays its walk")
  -- every invariant runs after each op, and finish after the last
  added = registered(function()
    h.walk({
      name = "breaking walk", seeds = {3}, steps = 5,
      setup = function() return {steps = 0} end,
      ops = {{1, "count", function(state)
        state.steps = state.steps + 1
        if state.steps == 2 then local_value("S").pattern_playing = true end
      end}},
    })
  end)
  ok, message = run_test(registered_test(added, "breaking walk (seed 3)"))
  message = tostring(message)
  assert_true(not ok and message:find("step 2", 1, true) ~= nil and message:find("pattern clock", 1, true) ~= nil,
    "an invariant broken at step 2 fails there, naming it: " .. message)
  added = registered(function()
    h.walk({
      name = "ending walk", seeds = {4}, steps = 3,
      setup = function() return {steps = 0} end,
      ops = {{1, "count", function(state) state.steps = state.steps + 1 end}},
      finish = function(state) return {"finished after " .. state.steps} end,
    })
  end)
  ok, message = run_test(registered_test(added, "ending walk (seed 4)"))
  assert_true(not ok and tostring(message):find("finished after 3", 1, true) ~= nil, "finish's problems fail: " .. tostring(message))
  load_strata()  -- this test leaves nothing broken
end)

test("a walk that never reached a counter fails", function()
  local function reached_walk(name)
    return registered(function()
      h.walk({
        name = name, seeds = {1, 2}, steps = 4,
        setup = function() return {hits = 0, misses = 0} end,
        ops = {{1, "hit", function(state) state.hits = state.hits + 1 end}},
        reached = {"hits", "misses"},
        counts = function(state) return {hits = state.hits, misses = state.misses} end,
      })
    end)
  end
  local added = reached_walk("counting walk")
  assert_equal(#added, 3, "a test a seed, then the reached test")
  assert_equal(added[3].name, "counting walk: the walks reached every path", "named after the walk")
  for index = 1, 2 do
    local ok, message = run_test(added[index].func)
    assert_true(ok, added[index].name .. ": " .. tostring(message))
  end
  local ok, message = run_test(added[3].func)
  message = tostring(message)
  assert_true(not ok and message:find("misses", 1, true) ~= nil, "the counter never moved is named: " .. message)
  assert_true(message:find("hits", 1, true) == nil, "the one that moved is not: " .. message)
  load_strata()  -- this test leaves nothing broken
end)

end

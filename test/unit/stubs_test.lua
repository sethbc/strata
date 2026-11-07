-- test/unit/stubs_test.lua
-- The harness: the norns stubs (params, clock, lfo, midi, arc, tabutil,
-- fileselect, ...), load_strata's data directories and the runner
-- Run alone: lua test/run.lua stubs

return function(h)
local test, test_dir, repo_root, stubs, signatures = h.test, h.test_dir, h.repo_root, h.stubs, h.signatures
local engine_polls, engine_spec, data_root, tests = h.engine_polls, h.engine_spec, h.data_root, h.tests
local run_test, assert_true, assert_equal = h.run_test, h.assert_true, h.assert_equal
local assert_near, load_strata, local_value = h.assert_near, h.load_strata, h.local_value
local finish_startup, patched_script, text_width = h.finish_startup, h.patched_script, h.text_width
local unit_files, load_unit_files = h.unit_files, h.load_unit_files

test("each load gets its own data directory, even after the same random seed (#50)", function()
  math.randomseed(1); local first = load_strata()
  math.randomseed(1); local second = load_strata()
  assert_true(first.data_dir ~= second.data_dir, "two loads share " .. first.data_dir)
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
    "return function() return { marker = 2, registry = { pages = {}, params = {}, start = {}, cleanup = {},"
    .. " grid_layouts = {}, voice_params = {}, scene_fields = {}, source_change = {}, param_filters = {},"
    .. " lfo_destinations = {}, fx_params = {} }, lib = {}, register_start = function() end,"
    .. " register_cleanup = function() end, register_voice_params = function() end,"
    .. " register_lfo_destination = function() end, register_param_filter = function() end,"
    .. " register_source_change = function() end, register_scene_field = function() end } end" } }
  assert_equal(local_value("S").marker, 2, "load_strata's module_sources reach include")
end)

test("stub text_width counts UTF-8 characters, not bytes", function()
  assert_equal(text_width("\226\151\143"), text_width("o"), "a three-byte glyph is one character")
  assert_equal(text_width("\226\151\139 ab"), 4 * text_width("o"), "glyph, space and two letters")
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
  os.execute("rm -rf '" .. dir .. "'")
  -- the suite's own unit files
  local unit_dir = repo_root .. "/test/unit"
  assert_equal(table.concat(unit_files(unit_dir, "lfos"), " "), "lfos_test.lua", "the lfos filter")
  local all = table.concat(unit_files(unit_dir), " ")
  assert_true(all:find("stubs_test.lua", 1, true) and all:find("structure_test.lua", 1, true), "every unit file: " .. all)
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
  -- the harness, sync_check and the CLAUDE.md table check read the same text
  assert_equal(signatures.voiceOn, "iffffff", "the stub's signatures")
  assert_equal(h.sync_check.sc_commands(text).loadBuffer, "is", "sync_check's commands")
  -- a parse error names the file it is in
  local ok, message = pcall(stubs.parse_engine_spec, text .. "\nSynthDef(\\open, { arg x;\n")
  assert_true(not ok and tostring(message):find("lib/engine/StrataVoices.sc", 1, true), "error names the file: " .. tostring(message))
end)

test("the stub reads a constant given as a method", function()
  assert_equal(stubs.parse_engine_spec("bufferStateStride { ^100 }").buffer_state_stride, 100)
  assert_equal(stubs.parse_engine_spec("var <>bufferSeconds = 16;").buffer_seconds, 16, "a writable var")
  assert_equal(engine_spec.buffer_state_stride, 1000, "the engine's stride")
  assert_true(engine_spec.grain_params.envShape, "a grainParamHandlers key is a grain param")
  assert_true(engine_spec.grain_params.bufPos and engine_spec.grain_params.posSpread, "both grainDefs' controls are grain params")
end)

end

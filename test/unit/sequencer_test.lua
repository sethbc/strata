-- test/unit/sequencer_test.lua
-- The pattern sequencer: steps retrigger, velocity, the pattern clock
-- (lib/sequencer.lua)
-- Run alone: lua test/run.lua sequencer

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake

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

test("sounding_step is the step played last: nil stopped, 1 at once on start, never the next step (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local sequencer = S.lib.sequencer
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  assert_equal(sequencer.sounding_step(), nil, "stopped: no sounding step")
  pattern_toggle()  -- plays step 1 at once
  assert_equal(sequencer.sounding_step(), 1, "just started: step 1, never the last step")
  assert_equal(S.pattern_position, 2, "the position is already the next step")
  for expected = 2, 2 * PATTERN_LENGTH + 1 do
    wake(context, "pattern_clock")
    local step = (expected - 1) % PATTERN_LENGTH + 1
    assert_equal(sequencer.sounding_step(), step, "between steps: the step that played")
    assert_equal(sequencer.sounding_step(), (S.pattern_position - 2) % PATTERN_LENGTH + 1,
      "the position before the next one")
  end
  pattern_toggle()
  assert_equal(sequencer.sounding_step(), nil, "stopped again: none")
  pattern_clock_start()
  assert_equal(sequencer.sounding_step(), 1, "a restart begins at step 1, not where it stopped")
  pattern_clock_stop()
  -- out of range state never reaches a caller
  S.pattern_playing = true; S.pattern_sounding_step = PATTERN_LENGTH + 1
  assert_equal(sequencer.sounding_step(), nil, "a step past PATTERN_LENGTH is no step")
  S.pattern_playing = false; S.pattern_sounding_step = nil
end)

test("step_brightness lights the sounding step, not the next one (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.patterns[1][2] = 9; S.patterns[1][3] = 6
  assert_equal(step_brightness(1, 2), 9, "stopped: the stored level")
  pattern_toggle(); wake(context, "pattern_clock")  -- steps 1 and 2 played
  assert_equal(S.pattern_position, 3)
  assert_equal(step_brightness(1, 2), 15, "the sounding active step at 15")
  assert_equal(step_brightness(2, 2), 4, "the sounding empty step at 4")
  assert_equal(step_brightness(1, 3), 6, "the next step keeps its level")
  assert_equal(step_brightness(2, 3), 0, "the next empty step stays dark")
  pattern_toggle()
  assert_equal(step_brightness(1, 2), 9, "stopped: no playhead")
end)

test("every grid redraw while a step plays shows that step, a started voice's too (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local voices = local_value("voices")
  assert_true(not voices[3].active, "voice 3 is stopped")
  S.patterns[3][1] = 15; S.patterns[3][2] = 15  -- step 1 starts voice 3, step 2 accents it
  local seen = {}
  local original_redraw = grid_redraw
  grid_redraw = function()
    seen[#seen + 1] = S.lib.sequencer.sounding_step()
    original_redraw()
  end
  pattern_toggle(); wake(context, "pattern_clock")
  grid_redraw = original_redraw
  pattern_toggle()
  -- one redraw per step, the voice it starts included (#527)
  assert_equal(#seen, 2, "one redraw per step")
  assert_equal(seen[1], 1, "step 1's redraw, after it starts voice 3, shows step 1")
  assert_equal(seen[#seen], 2, "the last shows step 2")
  for _, step in ipairs(seen) do
    assert_true(step == 1 or step == 2, "never the last step or the next one (" .. tostring(step) .. ")")
  end
end)

-- The sequencer's own work fails (its grid redraw, at the end of a beat's
-- steps): each output's error is its own (protected, design 8.10), so an
-- error of the sequencer itself is what stops the clocks (#243)
local function failing_grid_redraw(message)
  local real_grid_redraw, state = grid_redraw, {raised = false}
  grid_redraw = function(...)
    if not state.raised then state.raised = true; error(message) end
    return real_grid_redraw(...)
  end
  function state.restore() grid_redraw = real_grid_redraw end
  return state
end

local function assert_every_voice_clock_gone(S)
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(S.pattern_clocks[voice_idx], nil, "voice " .. voice_idx .. "'s clock is gone too")
  end
end

test("an error in a step stops the pattern clock and shows it stopped (#243)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.patterns[1][2] = 15
  pattern_clock_start()
  local failing = failing_grid_redraw("step failed")  -- step 2, on the clock's first wake-up
  wake(context, "pattern_clock")
  failing.restore()
  local errors = context.clock.take_errors()
  assert_true(failing.raised, "step 2 redrew the grid")
  assert_equal(#errors, 1, "one clock error")
  assert_true(errors[1]:find("step failed", 1, true), "the step's error")
  assert_true(errors[1]:find("stack traceback:", 1, true), "with its traceback")
  assert_equal(S.pattern_playing, false, "shown stopped")
  assert_equal(S.pattern_clock, nil, "the clock id is forgotten")
  assert_every_voice_clock_gone(S)
  assert_equal(S.lib.sequencer.sounding_step(), nil, "no step sounds")
  pattern_toggle()
  assert_equal(S.pattern_playing, true, "one press plays again")
  pattern_toggle()
end)

-- The final review's item 3: the header's play mark and SEQ's column follow
test("a step's error asks the screen to redraw the stopped pattern", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local UI_PAGES = local_value("UI_PAGES")
  S.patterns[1][2] = 15
  pattern_clock_start()
  UI_PAGES.screen_dirty = false
  local failing = failing_grid_redraw("step failed")
  wake(context, "pattern_clock")
  failing.restore()
  local errors = context.clock.take_errors()
  assert_true(failing.raised, "step 2 redrew the grid")
  assert_equal(#errors, 1, "one clock error")
  assert_equal(S.pattern_playing, false, "stopped")
  assert_true(UI_PAGES.screen_dirty, "the stop asks for a redraw")
end)

test("an error in the first step leaves no clock recorded (#243)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.patterns[1][1] = 15
  local failing = failing_grid_redraw("first step failed")
  -- the stub raises a first step's error to the caller, as norns' clock.run does
  local started, start_error = pcall(pattern_clock_start)
  failing.restore()
  local errors = context.clock.take_errors()
  assert_true(failing.raised, "the first step ran")
  assert_true((not started and tostring(start_error):find("first step failed", 1, true)) or #errors == 1, "the error reached the caller or the scheduler")
  assert_equal(S.pattern_clock, nil, "no clock id recorded")
  assert_equal(S.pattern_playing, false, "shown stopped")
  assert_every_voice_clock_gone(S)
  assert_equal(S.lib.sequencer.sounding_step(), nil, "no step sounds")
  pattern_toggle()
  assert_equal(S.pattern_playing, true, "one press plays again")
  pattern_toggle()
end)

test("replace_pattern copies sixteen whole levels in range and ignores a bad voice", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  for step = 1, PATTERN_LENGTH do S.patterns[1][step] = 9 end
  S.lib.sequencer.replace_pattern(1, {15, 3.7, -2, 99, "x"})
  local expected = {15, 3, 0, 15, 0}
  for step = 1, PATTERN_LENGTH do
    assert_equal(S.patterns[1][step], expected[step] or 0, "step " .. step)
  end
  assert_equal(S.patterns[1][PATTERN_LENGTH + 1], nil, "the pattern never grows")
  local before = {}
  for voice_idx = 1, S.constants.NUM_VOICES do
    before[voice_idx] = {}
    for step = 1, PATTERN_LENGTH do before[voice_idx][step] = S.patterns[voice_idx][step] end
  end
  S.lib.sequencer.replace_pattern(0, {15, 15})
  S.lib.sequencer.replace_pattern(8, {15, 15})
  S.lib.sequencer.replace_pattern(1.5, {15, 15})
  S.lib.sequencer.replace_pattern(2, nil)
  S.lib.sequencer.replace_pattern(2, 15)
  for voice_idx = 1, S.constants.NUM_VOICES do
    for step = 1, PATTERN_LENGTH do
      assert_equal(S.patterns[voice_idx][step], before[voice_idx][step], "voice " .. voice_idx .. " step " .. step .. " unchanged")
    end
  end
  assert_equal(S.patterns[0], nil, "voice 0 never created")
  assert_equal(S.patterns[8], nil, "voice 8 never created")
end)

-- Each bounds line of toggle_pattern_step catches its own case: without the
-- voice check, voice 8 raises on a nil pattern; without the step check, step
-- 17 (or 0) grows the pattern (#414)
test("toggle_pattern_step ignores a voice or a step out of range (#414)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local NUM_VOICES, PATTERN_LENGTH = S.constants.NUM_VOICES, S.constants.PATTERN_LENGTH
  S.patterns[1][1] = 6
  local before = {}
  for voice_idx = 1, NUM_VOICES do
    before[voice_idx] = {}
    for step = 1, PATTERN_LENGTH do before[voice_idx][step] = S.patterns[voice_idx][step] end
  end
  for _, place in ipairs({ { 0, 1 }, { NUM_VOICES + 1, 1 }, { 1, 0 }, { 1, PATTERN_LENGTH + 1 } }) do
    local ok, problem = pcall(toggle_pattern_step, place[1], place[2])
    assert_true(ok, "voice " .. place[1] .. " step " .. place[2] .. " raises nothing: " .. tostring(problem))
  end
  for voice_idx = 1, NUM_VOICES do
    for step = 1, PATTERN_LENGTH do
      assert_equal(S.patterns[voice_idx][step], before[voice_idx][step], "voice " .. voice_idx .. " step " .. step .. " unchanged")
    end
  end
  assert_equal(S.patterns[1][PATTERN_LENGTH + 1], nil, "step 17 never created")
  assert_equal(S.patterns[1][0], nil, "step 0 never created")
  assert_equal(S.patterns[NUM_VOICES + 1], nil, "voice 8 never created")
  assert_equal(S.patterns[0], nil, "voice 0 never created")
  -- in range it toggles: an empty step turns on at the top level, a set one off
  toggle_pattern_step(1, PATTERN_LENGTH)
  assert_equal(S.patterns[1][PATTERN_LENGTH], S.constants.MAX_STEP_LEVEL, "the last step on at the top level")
  toggle_pattern_step(1, 1)
  assert_equal(S.patterns[1][1], 0, "a set step off")
end)

-- lib/constants.lua's text with MAX_STEP_LEVEL set to level
local function constants_with_max_step_level(level)
  local file = assert(io.open(h.repo_root .. "/lib/constants.lua"))
  local source = file:read("*a")
  file:close()
  local patched, count = source:gsub("local MAX_STEP_LEVEL = 15", "local MAX_STEP_LEVEL = " .. level)
  assert(count == 1, "lib/constants.lua sets MAX_STEP_LEVEL once")
  return patched
end

-- A toggled step and a random one follow MAX_STEP_LEVEL: with a top level
-- of 10, a toggled step is 10 and a random one 5 to 10 (half the range,
-- rounded up, to the top), never the 15 and 8 to 15 written out (#418)
test("a toggled step is at MAX_STEP_LEVEL and a random one from half of it up (#418)", function()
  local context = load_strata({ module_sources = { ["lib/constants"] = constants_with_max_step_level(10) } })
  finish_startup(context)
  local S = local_value("S")
  assert_equal(S.constants.MAX_STEP_LEVEL, 10, "the patched top level")
  toggle_pattern_step(2, 3)
  assert_equal(S.patterns[2][3], 10, "a toggled step is at the top level")
  math.randomseed(7)
  local drawn = {}
  for _ = 1, 20 do
    for voice_idx = 1, S.constants.NUM_VOICES do
      randomize_pattern(voice_idx)
      for step = 1, S.constants.PATTERN_LENGTH do
        local level = S.patterns[voice_idx][step]
        assert_true(level == 0 or (level >= 5 and level <= 10), "a random level is 0 or 5 to 10, got " .. level)
        drawn[level] = true
      end
    end
  end
  for level = 5, 10 do assert_true(drawn[level], "level " .. level .. " is drawn") end
  assert_true(drawn[0], "and empty steps")
end)

-- The grid's repaint a pattern step asks for, once for the whole step
local function count_grid_redraws(action)
  local count, real_grid_redraw = 0, grid_redraw
  grid_redraw = function(...) count = count + 1; return real_grid_redraw(...) end
  local ok, problem = pcall(action)
  grid_redraw = real_grid_redraw
  if not ok then error(problem, 0) end
  return count
end

-- A step that starts several voices repaints every grid once, after it
-- starts them all, not once per voice and again for the step (#527)
test("a step that starts three voices repaints the grid once and shows them running (#527)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local UI_PAGES = local_value("UI_PAGES")
  for voice_idx = 3, 5 do
    assert_true(not S.voices[voice_idx].active, "voice " .. voice_idx .. " is stopped")
    S.patterns[voice_idx][1] = 15
  end
  S.patterns[1][1] = 9  -- and a running voice it accents
  UI_PAGES.screen_dirty = false
  context.clear_engine_calls()
  assert_equal(count_grid_redraws(pattern_clock_start), 1, "one repaint for step 1, which plays at once")
  for voice_idx = 3, 5 do
    assert_true(S.voices[voice_idx].active, "voice " .. voice_idx .. " started")
    assert_equal(S.voice_list.entries[voice_idx]:sub(1, 2), voice_idx .. "+", "MAIN's list shows voice " .. voice_idx .. " running")
  end
  assert_equal(#context.calls_named("voiceOn"), 3, "three starts")
  assert_equal(#context.calls_named("retrigger"), 1, "one accent")
  assert_true(UI_PAGES.screen_dirty, "the screen redraws the started voices")
  -- a step that starts none repaints once too
  assert_equal(count_grid_redraws(function() wake(context, "pattern_clock") end), 1, "one repaint for step 2")
  pattern_clock_stop()
end)

-- A step that fails starting its second voice: the voices output's error is
-- printed once and the patterns play on (design 8.10); the first voice it
-- started shows running, the failed one stopped in the engine and on the
-- screen
test("a step whose second start fails shows the first voice running and the second stopped, and plays on (#527, #382)", function()
  local context = load_strata({ before_init = function()
    local_value("S").register_grain_restart(function(voice_idx)
      if voice_idx == 4 then error("start failed") end
    end)
  end })
  finish_startup(context)
  local S = local_value("S")
  S.patterns[3][1] = 15; S.patterns[4][1] = 15
  context.clear_engine_calls()
  pattern_clock_start()
  h.claim_script_errors(context, 1, "step output voices: ", "start failed")
  assert_equal(S.pattern_playing, true, "the patterns play on")
  assert_true(S.voices[3].active, "voice 3 runs")
  assert_equal(S.voice_list.entries[3]:sub(1, 2), "3+", "MAIN's list shows voice 3 running")
  assert_true(not S.voices[4].active, "voice 4 is stopped")
  assert_equal(S.voice_list.entries[4]:sub(1, 2), "4-", "MAIN's list shows voice 4 stopped")
  local engine_running = false
  for _, call in ipairs(context.engine_calls) do
    if call.args[1] == 3 and call.name == "voiceOn" then engine_running = true end
    if call.args[1] == 3 and call.name == "voiceOff" then engine_running = false end
  end
  assert_equal(engine_running, false, "the engine's voice 4 is stopped too")
  pattern_clock_stop()
end)

-- The clock_source param's options, as norns' clock.add_params has them
local CLOCK_SOURCE = { internal = 1, midi = 2, link = 3, crow = 4 }

-- norns calls clock.transport.start and stop when the clock source starts
-- or stops (a MIDI start or stop, a Link start or stop with start/stop sync):
-- the patterns follow an external source's (#530)
test("the pattern clock follows the clock's transport start and stop (#530)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local UI_PAGES = local_value("UI_PAGES")
  params:set("clock_source", CLOCK_SOURCE.midi)
  assert_equal(type(clock.transport.start), "function", "a transport start handler")
  assert_equal(type(clock.transport.stop), "function", "a transport stop handler")
  UI_PAGES.screen_dirty = false
  clock.transport.start()
  assert_equal(S.pattern_playing, true, "a transport start plays the patterns")
  assert_equal(S.lib.sequencer.sounding_step(), 1, "from step 1, at the start")
  assert_true(UI_PAGES.screen_dirty, "the header's play mark and SEQ are redrawn")
  for _ = 1, 3 do wake(context, "pattern_clock") end
  assert_equal(S.lib.sequencer.sounding_step(), 4, "step 4 plays")
  local playing_clock = S.pattern_clock
  clock.transport.start()
  assert_equal(S.lib.sequencer.sounding_step(), 1, "a start while playing starts over from step 1")
  assert_true(context.clock.threads[playing_clock] == nil, "the clock that played is canceled")
  UI_PAGES.screen_dirty = false
  clock.transport.stop()
  assert_equal(S.pattern_playing, false, "a transport stop stops the patterns")
  assert_equal(S.pattern_clock, nil, "and their clock")
  assert_true(UI_PAGES.screen_dirty, "shown stopped")
  clock.transport.stop()
  assert_equal(S.pattern_playing, false, "a stop while stopped changes nothing")
end)

-- On the internal clock norns posts a transport start for PARAMETERS >
-- CLOCK > reset: a reset must never start a stopped pattern, so the
-- patterns follow the transport only when the clock source is external
-- (MIDI, Link or crow) (#530)
test("on the internal clock a transport start or stop leaves the patterns alone (#530)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_equal(params:get("clock_source"), CLOCK_SOURCE.internal, "norns' default source")
  clock.transport.start()  -- PARAMETERS > CLOCK > reset
  assert_equal(S.pattern_playing, false, "a reset leaves a stopped pattern stopped")
  assert_equal(S.pattern_clock, nil, "with no clock")
  pattern_toggle()
  for _ = 1, 2 do wake(context, "pattern_clock") end
  clock.transport.start()
  assert_equal(S.lib.sequencer.sounding_step(), 3, "a reset leaves a playing pattern where it is")
  clock.transport.stop()
  assert_equal(S.pattern_playing, true, "and a stop leaves it playing")
  pattern_toggle()
  -- every external source is followed
  for _, source in ipairs({ CLOCK_SOURCE.midi, CLOCK_SOURCE.link, CLOCK_SOURCE.crow }) do
    params:set("clock_source", source)
    clock.transport.start()
    assert_equal(S.pattern_playing, true, "source " .. source .. ": a start plays the patterns")
    assert_equal(S.lib.sequencer.sounding_step(), 1, "source " .. source .. ": from step 1")
    clock.transport.stop()
    assert_equal(S.pattern_playing, false, "source " .. source .. ": a stop stops them")
  end
end)

test("the transport handlers call the ones found at init and give them back at cleanup (#530)", function()
  local calls = {}
  local function previous_start() table.insert(calls, "start") end
  local function previous_stop() table.insert(calls, "stop") end
  local context = load_strata({ before_init = function()
    clock.transport.start, clock.transport.stop = previous_start, previous_stop
  end })
  finish_startup(context)
  local S = local_value("S")
  assert_true(clock.transport.start ~= previous_start, "the script's start handler is installed")
  -- on the internal clock the patterns stay, and the found handlers still run
  clock.transport.start(); clock.transport.stop()
  assert_equal(S.pattern_playing, false, "the internal clock's transport starts nothing")
  params:set("clock_source", CLOCK_SOURCE.midi)
  clock.transport.start()
  assert_equal(S.pattern_playing, true, "the patterns play")
  clock.transport.stop()
  assert_equal(S.pattern_playing, false, "and stop")
  assert_equal(table.concat(calls, " "), "start stop start stop", "the handlers found at init still run")
  cleanup()
  assert_equal(clock.transport.start, previous_start, "cleanup gives the start handler back")
  assert_equal(clock.transport.stop, previous_stop, "and the stop handler")
  -- with none found, cleanup leaves none
  context = load_strata(); finish_startup(context)
  cleanup()
  assert_equal(clock.transport.start, nil, "no start handler left")
  assert_equal(clock.transport.stop, nil, "no stop handler left")
end)

test("every edit of a voice's pattern ends that voice's pattern undo, the undo's own restore does not (#557)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local SEQ = S.constants.UI_PAGES.index.SEQ
  local spec = {page = SEQ, section = "pattern", voice = 2, pattern = 2}
  local function held() return S.lib.mutation.undo_for(SEQ, "pattern", 2) == true end
  S.lib.mutation.randomize(spec); assert_true(held(), "held")
  assert_true(S.lib.mutation.undo(), "the undo runs")
  assert_true(not held(), "and ends itself")
  for _, edit in ipairs({
    function() toggle_pattern_step(2, 3) end,
    function() clear_pattern(2) end,
    function() S.lib.sequencer.replace_pattern(2, {4}) end }) do
    S.lib.mutation.randomize(spec); assert_true(held(), "held")
    edit(); assert_true(not held(), "an edit ends it")
  end
  S.lib.mutation.randomize(spec)
  toggle_pattern_step(3, 3); assert_true(held(), "another voice's edit leaves it")
end)

-- 3.4 (design 8.1-8.5, 8.8, 8.10-8.13): per-voice clocks, step attributes,
-- step outputs, the chain and the transport. The stub clock starts at 120
-- BPM, so a beat is 0.5 s and a 1/16 step 0.125 s

-- A fresh script after its start-up (voices 1 and 2 running), its S
local function setup()
  local context = load_strata(); finish_startup(context)
  return context, local_value("S")
end

-- Voice 1 (running) reading buffer 1, which holds 8 s, at position 0.2
local function buffer_voice_setup()
  local context, S = setup()
  S.buffers[1].seconds = 8
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v1_buf_pos", 0.2)
  context.clear_engine_calls()
  return context, S
end

-- A step output that keeps a copy of every event it gets, with util.time()
-- at the hit; fields adds to the record (available, stop)
local function record_output(S, name, fields)
  local events = {}
  local record = {name = name, play = function(event)
    local copy = {time = util.time()}
    for key, value in pairs(event) do copy[key] = value end
    table.insert(events, copy)
  end}
  for key, value in pairs(fields or {}) do record[key] = value end
  S.register_step_output(record)
  return events
end

local function clear_list(list) for index = #list, 1, -1 do list[index] = nil end end

-- The value command(engine_voice, name, value) last sent
local function last_sent(context, command, engine_voice, name)
  local value
  for _, call in ipairs(context.engine_calls) do
    if call.name == command and call.args[1] == engine_voice and call.args[2] == name then value = call.args[3] end
  end
  return value
end

-- The values setGrainParam(engine_voice, name, ...) sent, in order
local function grain_values(context, engine_voice, name)
  local values = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == "setGrainParam" and call.args[1] == engine_voice and call.args[2] == name then
      table.insert(values, call.args[3])
    end
  end
  return values
end

local function retriggers_of(context, engine_voice)
  local calls = {}
  for _, call in ipairs(context.calls_named("retrigger")) do
    if call.args[1] == engine_voice then table.insert(calls, call) end
  end
  return calls
end

-- The events of one voice, first hits only when first_only
local function voice_events(events, voice_idx, first_only)
  local list = {}
  for _, event in ipairs(events) do
    if event.voice == voice_idx and (event.first or not first_only) then table.insert(list, event) end
  end
  return list
end

local function assert_list_near(actual, expected, tolerance, what)
  assert_equal(type(actual), "table", what .. ": a list")
  assert_equal(#actual, #expected, what .. ": its length")
  for index, value in ipairs(expected) do assert_near(actual[index], value, tolerance, what .. " " .. index) end
end

test("each voice plays at its own division and wraps at its own length", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  for voice_idx = 1, 3 do
    for step = 1, 16 do S.patterns[voice_idx][step] = 15 end
  end
  params:set("v2_seq_division", 5)
  assert_equal(params:string("v2_seq_division"), "1/8", "option 5 is 1/8")
  params:set("v3_seq_length", 5)
  pattern_clock_start()
  context.clock.run_for(1.0)  -- two beats
  assert_equal(seq.sounding_step(1), 9, "1/16: nine steps in two beats")
  assert_equal(seq.sounding_step(2), 5, "1/8: five")
  assert_equal(seq.sounding_step(3), 4, "1/16 over five steps: 1-5, then 1-4")
  assert_equal(seq.sounding_step(), 9, "with no voice, the transport's 16ths")
  pattern_clock_stop()
  assert_equal(seq.sounding_step(1), nil, "stopped: no step sounds")
end)

test("probability draws once per step", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "prob", 50)
  seq.set_step_attr(1, 1, "ratchet", 2)
  local events = record_output(S, "probe")
  math.randomseed(1)
  local started_at = util.time()
  pattern_clock_start()
  context.clock.run_for(32 * 2 - 0.05)  -- 32 passes of 16 steps, 2 s each
  pattern_clock_stop()
  local per_pass = {}
  for _, event in ipairs(voice_events(events, 1)) do
    local pass = math.floor((event.time - started_at) / 2 + 1e-6) + 1
    per_pass[pass] = (per_pass[pass] or 0) + 1
  end
  local played = 0
  for pass = 1, 32 do
    local hits = per_pass[pass] or 0
    assert_true(hits == 0 or hits == 2, "pass " .. pass .. " plays both hits or neither, not " .. hits)
    if hits == 2 then played = played + 1 end
  end
  assert_true(played >= 8 and played <= 24, "a 50% step plays in 8 to 24 of 32 passes, not " .. played)
  assert_equal(#retriggers_of(context, 0) >= 2 * played, true, "the voices output plays the hits it gets")
  -- prob 0 never plays; 100, and no prob at all, always
  for _, case in ipairs({{0, 0}, {100, 16}, {nil, 16}}) do
    seq.set_step_attr(1, 1, "prob", case[1])
    clear_list(events)
    pattern_clock_start()
    context.clock.run_for(8 * 2 - 0.05)
    pattern_clock_stop()
    assert_equal(#voice_events(events, 1), case[2], "prob " .. tostring(case[1]) .. ": " .. case[2] .. " hits in 8 passes")
  end
end)

test("ratchets repeat the hit inside the step, never closer than 20 ms", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "ratchet", 4)
  local events = record_output(S, "probe")
  context.clear_engine_calls()
  local started_at = util.time()
  pattern_clock_start()
  context.clock.run_for(0.12)  -- inside step 1 (0.125 s)
  pattern_clock_stop()
  local retriggers = retriggers_of(context, 0)
  assert_equal(#retriggers, 4, "four retriggers in a 125 ms step")
  for _, call in ipairs(retriggers) do assert_near(call.args[2], 1, 1e-9, "each at the step's velocity") end
  local hits = voice_events(events, 1)
  assert_equal(#hits, 4, "four events")
  for index, event in ipairs(hits) do
    assert_near(event.time - started_at, (index - 1) * 0.03125, 1e-9, "hit " .. index .. " 31.25 ms after the last")
    assert_equal(event.hit, index, "hit " .. index)
    assert_equal(event.hits, 4, "of 4")
    assert_equal(event.first, index == 1, "first only on hit 1")
  end
  -- 300 BPM: a 1/16 step is 50 ms, so two hits 25 ms apart
  params:set("clock_tempo", 300)
  clear_list(events)
  started_at = util.time()
  pattern_clock_start()
  context.clock.run_for(0.045)
  pattern_clock_stop()
  hits = voice_events(events, 1)
  assert_equal(#hits, 2, "300 BPM, 1/16: two hits")
  assert_near(hits[2].time - started_at, 0.025, 1e-9, "25 ms apart")
  assert_equal(hits[1].hits, 2, "the event says 2")
  -- 1/32 at 300 BPM: 25 ms, one hit
  params:set("v1_seq_division", 1)
  clear_list(events)
  pattern_clock_start()
  context.clock.run_for(0.02)
  pattern_clock_stop()
  hits = voice_events(events, 1)
  assert_equal(#hits, 1, "300 BPM, 1/32: one hit")
  assert_equal(hits[1].hits, 1, "the event says 1")
end)

test("locks are base overrides for their step", function()
  local context, S = buffer_voice_setup()
  local seq, sync = S.lib.sequencer, S.lib.engine_sync
  S.patterns[1][1] = 15; S.patterns[1][2] = 15
  seq.set_step_attr(1, 1, "pos", 0.6)
  seq.set_step_attr(1, 1, "size", 0.3)
  seq.set_step_attr(1, 1, "pitch", 2)
  pattern_clock_start()
  assert_near(last_sent(context, "setGrainParam", 0, "bufPos"), 0.6, 1e-9, "step 1 plays at its position lock")
  assert_near(last_sent(context, "setGrainParam", 0, "grainSize"), 0.3, 1e-9, "its size lock")
  assert_near(last_sent(context, "setGrainParam", 0, "pitchShift"), 2, 1e-9, "its pitch lock")
  assert_near(params:get("v1_buf_pos"), 0.2, 1e-9, "the stored position stays")
  assert_near(sync.engine_base_value("v1_buf_pos"), 0.6, 1e-9, "the lock is the base override")
  context.clock.advance_until(S.pattern_clocks[1])  -- step 2, plain
  assert_near(last_sent(context, "setGrainParam", 0, "bufPos"), 0.2, 1e-9, "step 2 plays the stored position")
  assert_near(last_sent(context, "setGrainParam", 0, "grainSize"), params:get("v1_grain_size"), 1e-9, "and size")
  assert_near(last_sent(context, "setGrainParam", 0, "pitchShift"), params:get("v1_grain_pitch"), 1e-9, "and pitch")
  assert_near(sync.engine_base_value("v1_buf_pos"), 0.2, 1e-9, "no override")
  for _ = 1, 15 do context.clock.advance_until(S.pattern_clocks[1]) end  -- the next pass's step 1
  assert_equal(seq.sounding_step(1), 1, "step 1 again")
  assert_near(last_sent(context, "setGrainParam", 0, "bufPos"), 0.6, 1e-9, "locked again")
  -- an encoder edit ends the lock at once
  delta_with_detent("v1_buf_pos", 1)
  assert_near(params:get("v1_buf_pos"), 0.21, 1e-9, "the edit moves the stored position")
  assert_near(last_sent(context, "setGrainParam", 0, "bufPos"), 0.21, 1e-9, "and the engine plays it at once")
  assert_near(sync.engine_base_value("v1_buf_pos"), 0.21, 1e-9, "the lock has ended")
  pattern_clock_stop()
end)

test("a lock ends when the patterns stop, the pattern is replaced or cleared", function()
  local context, S = buffer_voice_setup()
  local seq, sync = S.lib.sequencer, S.lib.engine_sync
  local function lock_step(step)
    S.patterns[1][step] = 15
    seq.set_step_attr(1, step, "pos", 0.6)
  end
  local function assert_position(value, what)
    assert_near(last_sent(context, "setGrainParam", 0, "bufPos"), value, 1e-9, what .. ": the position sent")
    assert_near(sync.engine_base_value("v1_buf_pos"), value, 1e-9, what .. ": the engine's base")
  end
  lock_step(1)
  pattern_clock_start(); assert_position(0.6, "playing")
  pattern_clock_stop(); assert_position(0.2, "the stop")
  pattern_clock_start(); assert_position(0.6, "playing again")
  clear_pattern(1); assert_position(0.2, "a cleared pattern")
  lock_step(1); pattern_clock_start(); assert_position(0.6, "a new start")
  seq.replace_pattern(1, {15}); assert_position(0.2, "a replaced pattern")
  pattern_clock_stop()
  -- a scene recall (it replaces every pattern)
  lock_step(1); capture_scene(2)
  pattern_clock_start(); assert_position(0.6, "before the recall")
  recall_scene(2); assert_position(0.2, "a scene recall")
  pattern_clock_stop()
  -- the length set below the step that locked
  clear_pattern(1); seq.set_step_attr(1, 1, "pos", nil); lock_step(5)
  pattern_clock_start()
  for _ = 1, 4 do context.clock.advance_until(S.pattern_clocks[1]) end
  assert_equal(seq.sounding_step(1), 5, "step 5 played")
  assert_position(0.6, "step 5's lock")
  params:set("v1_seq_length", 4); assert_position(0.2, "a length below the locked step")
  pattern_clock_stop()
  -- a chain link (between two of the voice's steps: three steps of 1/16)
  params:set("v1_seq_length", 3); clear_pattern(1); seq.set_step_attr(1, 5, "pos", nil); lock_step(1)
  capture_scene(3)
  params:set("seq_chain", 1); params:set("seq_chain_from", 3); params:set("seq_chain_scenes", 1)
  params:set("seq_chain_bars", 1)
  pattern_clock_start(); assert_position(0.6, "the chain's first scene")
  context.clock.run_for(2.0 - 0.01)  -- step 1 again at beat 3.75 after the start
  assert_position(0.6, "before the link")
  context.clock.run_for(0.02)        -- the bar: the link, and step 2 (empty)
  assert_position(0.2, "a chain link")
  pattern_clock_stop()
end)

test("a note transposes the voice by scale degrees", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  S.patterns[1][1] = 15; S.patterns[1][2] = 15
  local function play_step_1(notes)
    seq.set_step_attr(1, 1, "notes", notes)
    pattern_clock_start()
  end
  params:set("v1_freq", 220)
  context.clear_engine_calls()
  play_step_1({3})
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), 261.63, 0.01, "scale off: three semitones up, C")
  assert_near(params:get("v1_freq"), 220, 1e-9, "the stored freq stays")
  context.clock.advance_until(S.pattern_clocks[1])
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), 220, 1e-9, "the next step without a note restores it")
  pattern_clock_stop()
  -- on the chromatic scale a degree is a semitone from the voice's own
  -- pitch, wherever it lies between two notes
  params:set("v1_freq", 225)
  assert_near(seq.degree_semitones(1, 2), 2, 1e-9, "a detuned voice: two semitones")
  assert_near(seq.degree_semitones(1, -5), -5, 1e-9, "and five down")
  params:set("v1_freq", 220)
  -- major, root C
  params:set("scale", 2); params:set("root", 1)
  assert_equal(params:string("scale"), "Major", "the major scale")
  params:set("v1_freq", 261.63)
  assert_near(seq.degree_semitones(1, 2), 4, 0.001, "C, degree 2: E, four semitones")
  play_step_1({2})
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), 329.63, 0.01, "E")
  pattern_clock_stop()
  params:set("v1_freq", 220)
  assert_near(seq.degree_semitones(1, 2), 3, 0.001, "A, degree 2: C, three semitones")
  play_step_1({2})
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), 261.63, 0.01, "C")
  pattern_clock_stop()
  params:set("v1_freq", 261.63)
  play_step_1({-1})
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), 246.94, 0.01, "degree -1 from C: B")
  pattern_clock_stop()
  -- a buffer voice at rate 1, the note a MIDI note at the root plays (C)
  S.buffers[1].seconds = 8
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v1_buf_rate", 1)
  play_step_1({2})
  assert_near(last_sent(context, "setGrainParam", 0, "bufRate"), 1.2599, 0.0001, "degree 2 from C: E, rate 1.2599")
  assert_near(params:get("v1_buf_rate"), 1, 1e-9, "the stored rate stays")
  pattern_clock_stop()
  -- an input voice takes the note on its grain pitch, on the step's pitch lock
  params:set("scale", 1)
  params:set("v1_source", S.constants.SOURCE_INPUT)
  seq.set_step_attr(1, 1, "pitch", 1.5)
  play_step_1({12})
  assert_near(last_sent(context, "setGrainParam", 0, "pitchShift"), 3.0, 1e-9, "an octave on the 1.5 lock")
  context.clock.advance_until(S.pattern_clocks[1])
  assert_near(last_sent(context, "setGrainParam", 0, "pitchShift"), params:get("v1_grain_pitch"), 1e-9,
    "the next step restores the stored pitch")
  pattern_clock_stop()
end)

test("a step with several notes plays its first and hands every output the list", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  local events = record_output(S, "probe")
  S.patterns[1][1] = 15
  params:set("v1_freq", 220)
  seq.set_step_attr(1, 1, "notes", {3, 7, -2})
  context.clear_engine_calls()
  pattern_clock_start()
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), 261.63, 0.01, "the voice plays the first note")
  local event = voice_events(events, 1)[1]
  assert_list_near(event.notes, {3, 7, -2}, 0, "the event's notes")
  assert_list_near(event.semitones, {3, 7, -2}, 1e-9, "through the scale (off: semitones)")
  pattern_clock_stop()
  -- a chord saved in a scene loads and plays its first note too
  capture_scene(1)
  seq.set_step_attr(1, 1, "notes", {5})
  recall_scene(1)
  assert_list_near(seq.step_attr(1, 1, "notes"), {3, 7, -2}, 0, "the scene's chord")
  context.clear_engine_calls()
  pattern_clock_start()
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), 261.63, 0.01, "its first note plays")
  pattern_clock_stop()
end)

test("a bookmark lock recalls only inside the voice's loop", function()
  local context, S = buffer_voice_setup()
  local seq = S.lib.sequencer
  local function scan_resets()
    local count = 0
    for _, value in ipairs(grain_values(context, 0, "t_scanReset")) do count = count + value end
    return count
  end
  S.patterns[1][1] = 15
  params:set("v1_bookmark_3", 0.5)
  seq.set_step_attr(1, 1, "bookmark", 3)
  pattern_clock_start()
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9, "inside the whole-slot loop: the bookmark is recalled")
  assert_equal(scan_resets(), 1, "with its scan reset")
  pattern_clock_stop()
  -- a loop that leaves the bookmark out: nothing
  params:set("v1_loop_start", 0.6); params:set("v1_loop_length", 0.3); params:set("v1_buf_pos", 0.2)
  context.clear_engine_calls()
  pattern_clock_start()
  assert_near(params:get("v1_loop_start"), 0.6, 1e-9, "the loop stays")
  assert_near(params:get("v1_loop_length"), 0.3, 1e-9, "its length too")
  assert_near(params:get("v1_buf_pos"), 0.2, 1e-9, "and the position")
  assert_equal(scan_resets(), 0, "no recall")
  pattern_clock_stop()
  -- inside that loop it recalls again
  params:set("v1_bookmark_3", 0.75)
  pattern_clock_start()
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9, "0.75 is half way through the loop 0.6-0.9")
  assert_equal(scan_resets(), 1, "recalled")
  pattern_clock_stop()
end)

test("the sequencer plays through the registered outputs, voices first", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  assert_equal(S.registry.step_outputs[1].name, "voices", "the voices output is registered first")
  S.patterns[1][1] = 9; S.patterns[2][1] = 15
  seq.set_step_attr(1, 1, "notes", {2}); seq.set_step_attr(1, 1, "ratchet", 2); seq.set_step_attr(1, 1, "pos", 0.4)
  local retriggers_at = {}
  local events = record_output(S, "probe", {available = function(voice_idx) return voice_idx ~= 2 end})
  local probe = S.registry.step_outputs[#S.registry.step_outputs]
  local record_play = probe.play
  probe.play = function(event)
    table.insert(retriggers_at, #retriggers_of(context, event.voice - 1))
    record_play(event)
  end
  local broken_plays, stops = 0, 0
  S.register_step_output({name = "broken", play = function()
    broken_plays = broken_plays + 1
    error("integration down")
  end, stop = function() stops = stops + 1 end})
  context.clear_engine_calls()
  local start_beat = clock.get_beats()
  pattern_clock_start()
  context.clock.run_for(0.1)  -- step 1's two hits, 62.5 ms apart
  assert_equal(#voice_events(events, 2), 0, "available false skips voice 2 for that output")
  local hits = voice_events(events, 1)
  assert_equal(#hits, 2, "one event per hit")
  assert_equal(retriggers_at[1], 1, "the voices output retriggered the hit first")
  assert_equal(retriggers_at[2], 2, "each hit")
  local first = hits[1]
  assert_equal(first.voice, 1); assert_equal(first.step, 1); assert_equal(first.hit, 1); assert_equal(first.hits, 2)
  assert_equal(first.first, true); assert_equal(first.level, 9); assert_near(first.velocity, 9 / 15, 1e-9)
  assert_list_near(first.notes, {2}, 0, "notes"); assert_list_near(first.semitones, {2}, 1e-9, "semitones")
  assert_near(first.locks.pos, 0.4, 1e-9, "the locks as stored")
  assert_equal(first.locks.pitch, nil, "only the ones set")
  assert_near(first.beat, start_beat, 1e-9, "the beat at the hit")
  assert_near(first.gate_beats, 0.125, 1e-9, "a hit's length in beats: 1/16 over two hits")
  assert_equal(hits[2].hit, 2); assert_equal(hits[2].first, false)
  assert_near(hits[2].beat, start_beat + 0.125, 1e-9, "the second hit an eighth of a beat later")
  assert_equal(broken_plays, 1, "a failing output is skipped after its first failure")
  h.claim_script_errors(context, 1, "step output broken: ", "integration down")
  assert_equal(#retriggers_of(context, 0), 2, "the voices output still plays")
  assert_equal(#retriggers_of(context, 1), 1, "every voice")
  pattern_clock_stop()
  assert_equal(stops, 1, "stop runs on every stop")
  pattern_clock_start()
  assert_equal(broken_plays, 2, "the next start plays it again")
  h.claim_script_errors(context, 1, "step output broken: ", "integration down")
  pattern_clock_stop()
  assert_equal(stops, 2, "and stops it again")
end)

-- design 8.10: play runs inside the voice's coroutine, between its syncs,
-- so an output that waits (clock.sync, clock.sleep) is a failing one
test("a step output whose play yields is reported once and skipped, and the voice keeps its time", function()
  local context, S = setup()
  for step = 1, 16 do S.patterns[1][step] = 15 end
  local waits = 0
  S.register_step_output({name = "waiting", play = function()
    waits = waits + 1
    clock.sleep(1)
  end})
  local events = record_output(S, "probe")
  local started_at = util.time()
  pattern_clock_start()
  context.clock.run_for(0.3)
  pattern_clock_stop()
  h.claim_script_errors(context, 1, "step output waiting: ", "yield")
  assert_equal(waits, 1, "skipped after its first call")
  local times = {}
  for _, event in ipairs(voice_events(events, 1)) do table.insert(times, event.time - started_at) end
  assert_list_near(times, {0, 0.125, 0.25}, 1e-9, "the outputs after it play every hit on time")
  assert_equal(#retriggers_of(context, 0), 3, "and so do the voices")
end)

test("no step ever calls voiceOn for a running voice", function()
  local context, S = buffer_voice_setup()  -- voice 1 on a buffer, voice 2 on the synth
  local seq = S.lib.sequencer
  for step = 1, 16 do S.patterns[1][step] = 15; S.patterns[2][step] = 10 end
  for step = 1, 16, 3 do
    seq.set_step_attr(1, step, "ratchet", 4)
    seq.set_step_attr(1, step, "pos", step / 16)
  end
  for step = 2, 16, 4 do
    seq.set_step_attr(2, step, "ratchet", 3)
    seq.set_step_attr(2, step, "notes", {step % 5})
    seq.set_step_attr(2, step, "pitch", 1.5)
  end
  context.clear_engine_calls()
  pattern_clock_start()
  context.clock.run_for(64 * 0.125 - 0.01)  -- 64 steps
  pattern_clock_stop()
  assert_equal(#context.calls_named("voiceOn"), 0, "no voiceOn")
  assert_true(#retriggers_of(context, 0) > 64 and #retriggers_of(context, 1) > 64, "the ratchets retriggered")
end)

test("euclid writes the first length steps and keeps the attributes", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  for step = 1, 16 do S.patterns[1][step] = 6 end
  seq.set_step_attr(1, 4, "prob", 30)
  params:set("v1_seq_length", 8)
  seq.euclid(1, 3, 0)
  local expected = {15, 0, 0, 15, 0, 0, 15, 0}
  for step = 1, 8 do assert_equal(S.patterns[1][step], expected[step], "step " .. step) end
  for step = 9, 16 do assert_equal(S.patterns[1][step], 6, "step " .. step .. " past the length is kept") end
  assert_equal(seq.step_attr(1, 4, "prob"), 30, "the attributes are kept")
  assert_equal(S.seq_euclid[1][1], 3, "the hits"); assert_equal(S.seq_euclid[1][2], 0, "the rotation")
  seq.euclid(1, 3, 1)
  expected = {0, 15, 0, 0, 15, 0, 0, 15}
  for step = 1, 8 do assert_equal(S.patterns[1][step], expected[step], "rotated: step " .. step) end
  -- nothing while a scene recall is in progress
  S.scene_recall_in_progress = true
  seq.euclid(1, 8, 0)
  S.scene_recall_in_progress = false
  for step = 1, 8 do assert_equal(S.patterns[1][step], expected[step], "a recall's fill: step " .. step .. " unchanged") end
end)

test("the chain loads the next scene's patterns every N bars and nothing else", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  -- scene 1: voice 1 on steps 1-4, 16 steps, voice 2 at 1/16
  for step = 1, 4 do S.patterns[1][step] = 15 end
  capture_scene(1)
  -- scene 2: voice 1 on step 9 at 50%, 12 steps, voice 2 at 1/8, more reverb, voice 3 running
  clear_pattern(1); S.patterns[1][9] = 15; seq.set_step_attr(1, 9, "prob", 50)
  params:set("v1_seq_length", 12); params:set("v2_seq_division", 5)
  params:set("reverb_mix", 0.9); toggle_voice(3)
  capture_scene(2)
  -- now: neither scene's patterns or sound
  clear_pattern(1); S.patterns[1][16] = 15; seq.set_step_attr(1, 9, "prob", nil)
  params:set("v1_seq_length", 16); params:set("v2_seq_division", 3)
  params:set("reverb_mix", 0.5); toggle_voice(3)
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 3)
  params:set("seq_chain_bars", 1)  -- scene 3 is empty: skipped
  pattern_clock_start()
  assert_equal(S.patterns[1][1], 15, "the start loads scene 1's patterns")
  assert_equal(S.patterns[1][16], 0, "all of them")
  context.clock.run_for(2.0 + 0.01)  -- one bar
  assert_equal(S.patterns[1][1], 0, "a bar later scene 2's")
  assert_equal(S.patterns[1][9], 15, "scene 2's step 9")
  assert_equal(seq.step_attr(1, 9, "prob"), 50, "its step attributes")
  assert_equal(params:get("v1_seq_length"), 12, "its length")
  assert_equal(params:get("v2_seq_division"), 5, "its division")
  assert_near(params:get("reverb_mix"), 0.5, 1e-9, "and nothing else: the sound stays")
  assert_true(not S.voices[3].active, "and the voices' states")
  context.clock.run_for(2.0)
  assert_equal(S.patterns[1][1], 15, "the next bar: scene 1 again, past the empty scene 3")
  assert_equal(seq.step_attr(1, 9, "prob"), nil, "with its own (no) attributes")
  assert_equal(params:get("v1_seq_length"), 16, "and length")
  pattern_clock_stop()
end)

test("seq_division_reset puts every voice back at step 1 at the next bar", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  for voice_idx = 1, 3 do
    for step = 1, 16 do S.patterns[voice_idx][step] = 15 end
  end
  params:set("v2_seq_division", 4)  -- 1/8t: a third of a beat
  params:set("v3_seq_length", 5)
  pattern_clock_start()
  context.clock.run_for(0.8)
  params:set("seq_division_reset", 1)
  context.clock.run_for(1.2 - 0.01)  -- just before the bar (2 s after the start)
  assert_equal(seq.sounding_step(2), 12, "1/8t: step 12 before the bar")
  context.clock.run_for(0.02)
  for voice_idx = 1, 3 do assert_equal(seq.sounding_step(voice_idx), 1, "voice " .. voice_idx .. " at step 1") end
  context.clock.run_for(0.125)
  assert_equal(seq.sounding_step(3), 2, "voice 3 goes on from there")
  assert_equal(seq.sounding_step(2), 1, "voice 2 at its own division")
  pattern_clock_stop()
end)

test("step attributes validate, capture and recall as a scene block", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  S.patterns[2][3] = 15
  seq.set_step_attr(2, 3, "prob", 70)
  seq.set_step_attr(2, 3, "notes", {1, -3})
  seq.set_step_attr(2, 3, "gate", 2)
  capture_scene(1)
  assert_true(validate_scene(S.scenes[1]), "a captured scene validates")
  for _, key in ipairs({"prob", "notes", "gate"}) do seq.set_step_attr(2, 3, key, nil) end
  assert_equal(S.pattern_steps[2][3], nil, "a step with no attribute left is nil")
  recall_scene(1)
  assert_equal(seq.step_attr(2, 3, "prob"), 70, "recalled: prob")
  assert_list_near(seq.step_attr(2, 3, "notes"), {1, -3}, 0, "notes")
  assert_equal(seq.step_attr(2, 3, "gate"), 2, "gate")
  seq.set_step_attr(2, 3, "prob", 10)
  assert_equal(S.scenes[1].data.steps[2][3].prob, 70, "an edit after the recall leaves the scene")
  local stored = S.scenes[1].data.steps[2][3]
  local nine = {1, 2, 3, 4, 5, 6, 7, 8, 9}
  for _, case in ipairs({{"prob", 101}, {"prob", 50.5}, {"ratchet", 5}, {"ratchet", 0}, {"notes", nine},
      {"notes", {15}}, {"notes", {[1] = 1, [3] = 3}}, {"notes", {}}, {"notes", {0.5}}, {"pos", 1.5},
      {"pitch", 5}, {"size", 0}, {"bookmark", 5}, {"gate", 17}, {"color", 1}}) do
    local before = stored[case[1]]
    stored[case[1]] = case[2]
    assert_true(not validate_scene(S.scenes[1]), "rejected: " .. case[1] .. " " .. tostring(case[2]))
    stored[case[1]] = before
  end
  assert_true(validate_scene(S.scenes[1]), "restored, it validates")
  local steps = S.scenes[1].data.steps
  steps[2][17] = {prob = 50}
  assert_true(not validate_scene(S.scenes[1]), "rejected: step 17")
  steps[2][17] = nil; steps[2][1.5] = {prob = 50}
  assert_true(not validate_scene(S.scenes[1]), "rejected: step 1.5")
  steps[2][1.5] = nil; steps[8] = {}
  assert_true(not validate_scene(S.scenes[1]), "rejected: an eighth voice")
  steps[8] = nil; steps[2][3] = 4
  assert_true(not validate_scene(S.scenes[1]), "rejected: a step that is no table")
end)

-- The clock_source param's options, as norns' clock.add_params has them
local CLOCK = { internal = 1, midi = 2 }

test("a transport start restarts every voice at step 1; follow off ignores it", function()
  local found = {}
  local context = load_strata({ before_init = function()
    clock.transport.start = function() table.insert(found, "start") end
    clock.transport.stop = function() table.insert(found, "stop") end
  end })
  finish_startup(context)
  local S = local_value("S")
  local seq = S.lib.sequencer
  for step = 1, 16 do S.patterns[1][step] = 15 end
  params:set("clock_source", CLOCK.midi)
  assert_equal(seq.follows_transport(), true, "followed: the param is on and the source external")
  pattern_clock_start()
  for _ = 1, 5 do context.clock.advance_until(S.pattern_clocks[1]) end
  assert_equal(seq.sounding_step(1), 6, "playing at step 6")
  context.clock.transport_start()
  assert_near(clock.get_beats(), 0, 1e-9, "the beat is back at 0")
  assert_equal(seq.sounding_step(1), 1, "voice 1 at step 1 at once")
  assert_equal(seq.sounding_step(), 1, "the transport's step too")
  context.clock.run_for(0.125 + 1e-6)
  assert_equal(seq.sounding_step(1), 2, "step 2 a 16th after the new beat 0")
  assert_equal(table.concat(found, " "), "start", "the handler found at init runs after")
  -- a running chain goes back to seq_chain_from
  clear_pattern(1); S.patterns[1][1] = 15; capture_scene(1)
  clear_pattern(1); S.patterns[1][3] = 15; capture_scene(2)
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 2)
  params:set("seq_chain_bars", 1)
  pattern_clock_start()
  context.clock.run_for(2.0 + 0.01)
  assert_equal(S.patterns[1][3], 15, "the chain is at scene 2")
  context.clock.transport_start()
  assert_equal(S.patterns[1][3], 0, "a start puts it back at scene 1")
  assert_equal(S.patterns[1][1], 15, "scene 1's pattern")
  params:set("seq_chain", 0)
  -- follow off: the handlers do nothing but call the ones found
  params:set("seq_follow_transport", 0)
  assert_equal(seq.follows_transport(), false, "not followed")
  context.clock.run_for(0.3)
  local step = seq.sounding_step(1)
  context.clock.transport_start()
  assert_equal(seq.sounding_step(1), step, "a start leaves the voices where they are")
  context.clock.transport_stop()
  assert_equal(S.pattern_playing, true, "a stop leaves them playing")
  assert_equal(table.concat(found, " "), "start start start stop", "the handlers found still run")
  -- a stop with ratchets pending sends no later retrigger
  params:set("seq_follow_transport", 1)
  pattern_clock_stop()
  seq.replace_pattern(1, {15})
  seq.set_step_attr(1, 1, "ratchet", 4)
  context.clock.run_for(1)
  pattern_clock_start()
  context.clear_engine_calls()
  context.clock.transport_stop()
  assert_equal(S.pattern_playing, false, "a transport stop stops the patterns")
  context.clock.run_for(0.5)
  assert_equal(#context.calls_named("retrigger"), 0, "no hit of the step after the stop")
  -- the internal clock: neither starts nor stops (#530)
  params:set("clock_source", CLOCK.internal)
  assert_equal(seq.follows_transport(), false, "the internal clock is never followed")
  context.clock.transport_start()
  assert_equal(S.pattern_playing, false, "a reset starts nothing")
  pattern_clock_start()
  context.clock.transport_stop()
  assert_equal(S.pattern_playing, true, "and stops nothing")
  pattern_clock_stop()
end)

test("the play key starts the patterns through the quantizer", function()
  local _, S = setup()
  local scheduled = {}
  local real_schedule = S.lib.quantize.schedule
  S.lib.quantize.schedule = function(key, fn, label)
    table.insert(scheduled, {key = key, fn = fn, label = label})
    return real_schedule(key, fn, label)
  end
  pattern_toggle()
  assert_equal(#scheduled, 1, "one scheduled action")
  assert_equal(scheduled[1].key, "patterns", "keyed patterns")
  assert_equal(scheduled[1].fn, pattern_clock_start, "the pattern start")
  assert_equal(scheduled[1].label, "play", "labeled play")
  assert_equal(S.pattern_playing, true, "played (the quantizer is off)")
  pattern_toggle()
  S.lib.quantize.schedule = real_schedule
  assert_equal(#scheduled, 1, "a stop is never quantized")
  assert_equal(S.pattern_playing, false, "stopped")
end)

-- Gates (design 8.12)

test("a gated voice gets its gate with its sync and a gate length only when it changes", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  context.clear_engine_calls()
  params:set("v1_seq_gate", 2)
  assert_equal(last_sent(context, "setGrainParam", 0, "seqGate"), 1, "the gate on")
  assert_list_near(grain_values(context, 0, "gateSeconds"), {0.0625}, 1e-9, "half a 1/16 step at 120 BPM")
  -- its sync sends the gate again
  context.clear_engine_calls()
  sync_voice_values_to_engine(1)
  assert_equal(last_sent(context, "setGrainParam", 0, "seqGate"), 1, "a sync sends the gate")
  -- 16 plain steps: no gate length is sent again
  for step = 1, 16 do S.patterns[1][step] = 15 end
  context.clear_engine_calls()
  pattern_clock_start()
  context.clock.run_for(16 * 0.125 - 0.01)
  pattern_clock_stop()
  assert_equal(#retriggers_of(context, 0), 16, "16 retriggers")
  assert_equal(#grain_values(context, 0, "gateSeconds"), 0, "and no gate length")
  -- a ratchet of 2: half the length before its first hit, the whole again before the next step's
  seq.set_step_attr(1, 1, "ratchet", 2)
  context.clear_engine_calls()
  pattern_clock_start()
  context.clock.run_for(0.125 + 1e-6)
  pattern_clock_stop()
  local order = {}
  for _, call in ipairs(context.engine_calls) do
    if call.args[1] == 0 and call.name == "retrigger" then table.insert(order, {kind = "hit"}) end
    if call.args[1] == 0 and call.name == "setGrainParam" and call.args[2] == "gateSeconds" then
      table.insert(order, {kind = "gate", seconds = call.args[3]})
    end
  end
  local expected = {{kind = "gate", seconds = 0.03125}, {kind = "hit"}, {kind = "hit"},
    {kind = "gate", seconds = 0.0625}, {kind = "hit"}}
  assert_equal(#order, #expected, "two gate lengths and three hits")
  for index, entry in ipairs(expected) do
    assert_equal(order[index].kind, entry.kind, "message " .. index)
    if entry.seconds then assert_near(order[index].seconds, entry.seconds, 1e-9, "message " .. index) end
  end
  -- a step's own gate of 2 steps
  seq.set_step_attr(1, 1, "ratchet", nil)
  seq.set_step_attr(1, 1, "gate", 2)
  context.clear_engine_calls()
  pattern_clock_start()
  pattern_clock_stop()
  assert_list_near(grain_values(context, 0, "gateSeconds"), {0.25}, 1e-9, "a step gate of 2")
  -- a slower tempo: sent before the next hit
  seq.set_step_attr(1, 1, "gate", nil)
  pattern_clock_start()
  params:set("clock_tempo", 60)
  context.clear_engine_calls()
  context.clock.advance_until(S.pattern_clocks[1])
  assert_list_near(grain_values(context, 0, "gateSeconds"), {0.125}, 1e-9, "60 BPM")
  assert_equal(context.engine_calls[#context.engine_calls].name, "retrigger", "before the hit")
  pattern_clock_stop()
  context.clear_engine_calls()
  params:set("v1_seq_gate", 1)
  assert_equal(last_sent(context, "setGrainParam", 0, "seqGate"), 0, "the gate off")
end)

test("a step on a stopped gated voice starts it and then retriggers it", function()
  local context, S = setup()
  assert_true(not S.voices[3].active and not S.voices[4].active, "voices 3 and 4 are stopped")
  params:set("v3_seq_gate", 2)
  S.patterns[3][1] = 15; S.patterns[4][1] = 15
  context.clear_engine_calls()
  pattern_clock_start()
  -- the voice's start, gate and hit messages in order: their names, and the
  -- gate values by name
  local function sequence(engine_voice)
    local names, values = {}, {}
    for _, call in ipairs(context.engine_calls) do
      if call.args[1] == engine_voice then
        if call.name == "voiceOn" or call.name == "retrigger" then table.insert(names, call.name) end
        if call.name == "setGrainParam" and (call.args[2] == "seqGate" or call.args[2] == "gateSeconds") then
          table.insert(names, call.args[2])
          values[call.args[2]] = call.args[3]
        end
      end
    end
    return table.concat(names, ", "), values
  end
  assert_true(S.voices[3].active, "voice 3 started")
  local names, values = sequence(2)
  assert_equal(names, "seqGate, gateSeconds, voiceOn, retrigger", "voice 3: its gate, started, then retriggered")
  assert_equal(values.seqGate, 1, "the gate on")
  assert_near(values.gateSeconds, 0.0625, 1e-9, "half a 1/16 step")
  names, values = sequence(3)
  assert_equal(names, "seqGate, voiceOn", "an ungated stopped voice is only started, as before")
  assert_equal(values.seqGate, 0, "its gate off")
  pattern_clock_stop()
end)

test("an ungated voice sends nothing per hit beyond its retrigger", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  for step = 1, 16 do S.patterns[1][step] = 15 end
  seq.set_step_attr(1, 2, "ratchet", 3)
  context.clear_engine_calls()
  pattern_clock_start()
  context.clock.run_for(16 * 0.125 - 0.01)
  pattern_clock_stop()
  local names = {}
  for _, call in ipairs(context.engine_calls) do
    if call.args[1] == 0 then names[call.name] = (names[call.name] or 0) + 1 end
  end
  assert_equal(names.retrigger, 18, "15 steps of one hit and one of three")
  for name in pairs(names) do assert_equal(name, "retrigger", "voice 1 gets only retriggers") end
end)

test("a gated voice's event carries the gate's length in beats", function()
  local _, S = setup()
  local seq = S.lib.sequencer
  local events = record_output(S, "probe")
  params:set("v1_seq_gate", 2)
  S.patterns[1][1] = 15; S.patterns[2][1] = 15
  pattern_clock_start(); pattern_clock_stop()
  assert_near(voice_events(events, 1)[1].gate_beats, 0.125, 1e-9, "0.5 steps of 1/16")
  assert_near(voice_events(events, 2)[1].gate_beats, 0.25, 1e-9, "ungated: the hit's length")
  seq.set_step_attr(1, 1, "gate", 4)
  clear_list(events)
  pattern_clock_start(); pattern_clock_stop()
  assert_near(voice_events(events, 1)[1].gate_beats, 1, 1e-9, "a step gate of 4 steps: a beat")
end)

test("scenes switch the gate at a transition's end and crossfade its length and release; old scenes load with it off", function()
  local context, S = setup()
  capture_scene(1)
  params:set("v1_seq_gate", 2); params:set("v1_seq_gate_length", 2); params:set("v1_seq_gate_release", 1)
  capture_scene(2)
  recall_scene(1)
  assert_equal(params:get("v1_seq_gate"), 1, "scene 1: off")
  assert_near(params:get("v1_seq_gate_length"), 0.5, 1e-6, "0.5 steps")
  assert_near(params:get("v1_seq_gate_release"), 0.1, 1e-6, "0.1 s")
  recall_scene(2, 1)
  context.clock.run_for(0.5)
  assert_equal(params:get("v1_seq_gate"), 1, "half way: still off")
  local length, release = params:get("v1_seq_gate_length"), params:get("v1_seq_gate_release")
  assert_true(length > 0.6 and length < 1.9, "the length crossfades: " .. length)
  assert_true(release > 0.2 and release < 0.9, "the release too: " .. release)
  context.clock.run_for(0.6)
  assert_equal(params:get("v1_seq_gate"), 2, "on at the end")
  assert_near(params:get("v1_seq_gate_length"), 2, 1e-6, "2 steps")
  assert_near(params:get("v1_seq_gate_release"), 1, 1e-6, "1 s")
  -- an old scene, without the seq record's keys and steps
  local old = h.deep_copy(S.scenes[1])
  for _, voice in ipairs(old.data.voices) do
    for _, key in ipairs({"seq_length", "seq_division", "seq_gate", "seq_gate_length", "seq_gate_release",
        "seq_swing"}) do
      voice.extras[key] = nil
    end
  end
  old.data.steps = nil
  migrate_scene(old, 5)  -- 3.3's format
  assert_true(validate_scene(old), "it loads")
  local extras = old.data.voices[1].extras
  assert_equal(extras.seq_gate, 1, "gate off"); assert_near(extras.seq_gate_length, 0.5, 1e-9, "0.5")
  assert_near(extras.seq_gate_release, 0.1, 1e-9, "0.1"); assert_equal(extras.seq_swing, 50, "straight")
  assert_equal(extras.seq_length, 16, "16 steps"); assert_equal(extras.seq_division, 3, "of 1/16")
  assert_equal(next(old.data.steps[1]), nil, "every step plain")
end)

test("a step's gate validates in 0.05..16", function()
  local _, S = setup()
  local seq = S.lib.sequencer
  for _, value in ipairs({0.04, 16.5, -1, 0 / 0}) do
    seq.set_step_attr(1, 1, "gate", value)
    assert_equal(seq.step_attr(1, 1, "gate"), nil, "refused: " .. tostring(value))
  end
  for _, value in ipairs({0.05, 16, 1.5}) do
    seq.set_step_attr(1, 1, "gate", value)
    assert_equal(seq.step_attr(1, 1, "gate"), value, "taken: " .. value)
  end
  capture_scene(1)
  local stored = S.scenes[1].data.steps[1][1]
  for _, value in ipairs({0.04, 16.01}) do
    stored.gate = value
    assert_true(not validate_scene(S.scenes[1]), "a scene's gate of " .. value .. " is refused")
  end
  stored.gate = 0.05
  assert_true(validate_scene(S.scenes[1]), "0.05 validates")
end)

-- Swing (design 8.13)

-- The times voice 1's steps play, from the start, at swing and division,
-- over run seconds
local function swung_times(context, events, swing, division, run)
  params:set("v1_seq_swing", swing)
  params:set("v1_seq_division", division)
  clear_list(events)
  local started_at = util.time()
  pattern_clock_start()
  context.clock.run_for(run)
  pattern_clock_stop()
  local times = {}
  for _, event in ipairs(voice_events(events, 1, true)) do table.insert(times, event.time - started_at) end
  return times
end

test("swing delays every second step of the voice and never drifts", function()
  local context, S = setup()
  for step = 1, 16 do S.patterns[1][step] = 15 end
  local events = record_output(S, "probe")
  for _, case in ipairs({{50, 0.125}, {66, 0.165}, {75, 0.1875}}) do
    local times = swung_times(context, events, case[1], 3, 0.3)
    assert_near(times[1], 0, 1e-9, "swing " .. case[1] .. ": step 1 at once")
    assert_near(times[2], case[2], 1e-9, "swing " .. case[1] .. ": step 2")
    assert_near(times[3], 0.25, 1e-9, "swing " .. case[1] .. ": step 3 on the grid")
  end
  local times = swung_times(context, events, 66, 3, 64 * 0.125 - 0.01)
  assert_equal(#times, 64, "64 steps")
  for index = 1, 64 do
    local pair = math.floor((index - 1) / 2) * 0.25
    assert_near(times[index], index % 2 == 1 and pair or pair + 0.165, 1e-9, "step " .. index .. " never drifts")
  end
  times = swung_times(context, events, 66, 5, 0.6)
  assert_near(times[2], 0.33, 1e-9, "1/8 swings its own grid")
  assert_near(times[3], 0.5, 1e-9, "and lands on it")
end)

test("a swung step's ratchets fit its own length", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  for step = 1, 16 do S.patterns[1][step] = 15 end
  seq.set_step_attr(1, 2, "ratchet", 2)
  local events = record_output(S, "probe")
  params:set("v1_seq_swing", 66)
  local started_at = util.time()
  pattern_clock_start()
  context.clock.run_for(0.3)
  pattern_clock_stop()
  local step_2 = {}
  for _, event in ipairs(voice_events(events, 1)) do
    if event.step == 2 then table.insert(step_2, event.time - started_at) end
  end
  assert_list_near(step_2, {0.165, 0.2075}, 1e-9, "half of the 0.085 s left, none after 0.25 s")
end)

end

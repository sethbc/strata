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

-- Strata's own voices output is the one output that is never skipped
-- (ruling 38): an error in it is a bug in Strata, so it stops the patterns
-- as it did before 3.4 (#243, #382). An error of the sequencer itself does
-- too. start_voice fails on its first call, from where the test arms it
local function failing_start_voice(S, message)
  local engine_sync = S.lib.engine_sync
  local real_start_voice, state = engine_sync.start_voice, {raised = false}
  engine_sync.start_voice = function(voice_idx)
    if not state.raised then state.raised = true; error(message) end
    return real_start_voice(voice_idx)
  end
  function state.restore() engine_sync.start_voice = real_start_voice end
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
  S.patterns[1][2] = 15  -- step 2 fails starting voice 1, on the clock's first wake-up
  if S.voices[1].active then toggle_voice(1) end
  local failing = failing_start_voice(S, "step failed")
  pattern_clock_start()
  context.clock.advance_until(S.pattern_clocks[1])  -- voice 1's clock (it stops the transport's)
  local errors = context.clock.take_errors()
  failing.restore()
  assert_true(failing.raised, "step 2 started voice 1")
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
  S.patterns[1][2] = 15  -- step 2 fails starting voice 1, on the clock's first wake-up
  if S.voices[1].active then toggle_voice(1) end
  local failing = failing_start_voice(S, "step failed")
  pattern_clock_start()
  UI_PAGES.screen_dirty = false
  context.clock.advance_until(S.pattern_clocks[1])  -- voice 1's clock (it stops the transport's)
  local errors = context.clock.take_errors()
  failing.restore()
  assert_true(failing.raised, "step 2 started voice 1")
  assert_equal(#errors, 1, "one clock error")
  assert_equal(S.pattern_playing, false, "stopped")
  assert_true(UI_PAGES.screen_dirty, "the stop asks for a redraw")
end)

test("an error in the first step leaves no clock recorded (#243)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.patterns[1][1] = 15  -- step 1 fails starting voice 1
  if S.voices[1].active then toggle_voice(1) end
  local failing = failing_start_voice(S, "first step failed")
  -- the stub raises a first step's error to the caller, as norns' clock.run does
  local started, start_error = pcall(pattern_clock_start)
  local errors = context.clock.take_errors()
  failing.restore()
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

-- An error of the sequencer's own work (here its grid repaint, at the end of
-- a beat's steps) stops every clock the same way
test("an error of the sequencer itself stops every clock and is raised again", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.patterns[1][2] = 15
  pattern_clock_start()
  local real_grid_redraw, raised = grid_redraw, false
  grid_redraw = function(...)
    if not raised then raised = true; error("repaint failed") end
    return real_grid_redraw(...)
  end
  wake(context, "pattern_clock")
  grid_redraw = real_grid_redraw
  local errors = context.clock.take_errors()
  assert_true(raised, "step 2 repainted the grid")
  assert_equal(#errors, 1, "one clock error")
  assert_true(errors[1]:find("repaint failed", 1, true), "the error, raised again")
  assert_equal(S.pattern_playing, false, "shown stopped")
  assert_equal(S.pattern_clock, nil, "the transport's clock is gone")
  assert_every_voice_clock_gone(S)
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

-- A step that fails starting its second voice: the first one it started
-- shows running, the failed one stopped in the engine and on the screen.
-- The voices output is never skipped (ruling 38): its error stops the
-- patterns and is raised again
test("a step whose second start fails shows the first voice running and the second stopped (#527, #382)", function()
  local context = load_strata({ before_init = function()
    local_value("S").register_grain_restart(function(voice_idx)
      if voice_idx == 4 then error("start failed") end
    end)
  end })
  finish_startup(context)
  local S = local_value("S")
  S.patterns[3][1] = 15; S.patterns[4][1] = 15
  context.clear_engine_calls()
  local started, start_error = pcall(pattern_clock_start)
  local errors = context.clock.take_errors()
  assert_true((not started and tostring(start_error):find("start failed", 1, true)) or #errors == 1,
    "the error reached the caller or the scheduler")
  assert_equal(#context.take_script_errors(), 0, "and was never printed as an output's")
  assert_equal(S.pattern_playing, false, "the pattern stopped")
  assert_every_voice_clock_gone(S)
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
  -- the clock that played is never canceled (its resume may be posted):
  -- it ends at its next wake, playing nothing
  assert_true(S.pattern_clock ~= playing_clock, "a new clock plays")
  context.clock.run_for(0.125 + 1e-6)
  assert_true(context.clock.threads[playing_clock] == nil, "the clock that played has ended")
  assert_equal(S.lib.sequencer.sounding_step(), 2, "one 16th on, played once")
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

-- A hit's time after the start: its scheduled time, or up to one of
-- matron's ticks later, never earlier. A hit that shares a tick with another
-- clock's later wake-up runs at the tick's time, as on a norns (#588)
local function assert_hit_time(actual, scheduled, what)
  local tick = h.stubs.MATRON_TICK_SECONDS
  assert_true(actual >= scheduled - 1e-9 and actual <= scheduled + tick + 1e-9,
    string.format("%s: at %.9f s, not %.9f s or up to a tick (%g s) after", what, actual, scheduled, tick))
end

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
    assert_hit_time(event.time - started_at, (index - 1) * 0.03125, "hit " .. index .. " 31.25 ms after the last")
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
  assert_hit_time(hits[2].time - started_at, 0.025, "25 ms apart")
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

-- The values a voice's grains need before its voiceOn (#325), and their
-- first value for the start (name -> value), and the voiceOn
local function start_messages(context, engine_voice)
  local first, voice_on = {}, nil
  for _, call in ipairs(context.engine_calls) do
    if call.args[1] == engine_voice then
      if call.name == "voiceOn" then voice_on = call; break end
      if call.name == "setGrainParam" and first[call.args[2]] == nil then first[call.args[2]] = call.args[3] end
    end
  end
  return first, voice_on
end

-- A step that starts a stopped voice plays its first grain with its locks
-- and note: the start's first values carry them (#632)
test("a locked, noted step that starts a stopped buffer voice: its first values are the step's", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  S.buffers[1].seconds = 8
  params:set("v3_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v3_buf_pos", 0.2)
  assert_true(not S.voices[3].active, "voice 3 is stopped")
  S.patterns[3][1] = 15
  seq.set_step_attr(3, 1, "pos", 0.6)
  seq.set_step_attr(3, 1, "size", 0.3)
  seq.set_step_attr(3, 1, "pitch", 2)
  seq.set_step_attr(3, 1, "notes", {12})  -- chromatic: an octave up, buf_rate 1 -> 2
  context.clear_engine_calls()
  pattern_clock_start()
  assert_true(S.voices[3].active, "the step started voice 3")
  local first, voice_on = start_messages(context, 2)
  assert_near(first.bufPos, 0.6, 1e-9, "the first bufPos is the position lock")
  assert_near(first.grainSize, 0.3, 1e-9, "the first grainSize the size lock")
  assert_near(first.pitchShift, 2, 1e-9, "the first pitchShift the pitch lock")
  assert_near(first.bufRate, 2, 1e-9, "the first bufRate the note")
  assert_near(voice_on.args[5], 0.3, 1e-9, "voiceOn's size is the lock")
  assert_near(voice_on.args[7], 2, 1e-9, "and its pitch")
  for _, case in ipairs({{"bufPos", 0.6}, {"grainSize", 0.3}, {"pitchShift", 2}, {"bufRate", 2}}) do
    for _, value in ipairs(grain_values(context, 2, case[1])) do
      assert_near(value, case[2], 1e-9, case[1] .. ": no stored value is sent for the start")
    end
  end
  pattern_clock_stop()
end)

test("a noted step that starts a stopped quantized synth voice: voiceOn's freq and the first scaleNote are the note's", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  assert_true(not S.voices[3].active, "voice 3 is stopped")
  params:set("v3_quantize", 1)
  local freq = params:get("v3_freq")
  S.patterns[3][1] = 15
  seq.set_step_attr(3, 1, "notes", {12})  -- the scale off: an octave up
  context.clear_engine_calls()
  pattern_clock_start()
  local first, voice_on = start_messages(context, 2)
  assert_near(voice_on.args[2], freq * 2, 1e-6, "voiceOn's freq is the note")
  local note = 69 + 12 * math.log(freq / 440) / math.log(2)
  assert_near(first.scaleNote, note + 12, 1e-6, "the first scaleNote is the note's")
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 2 and call.args[2] == "freq" then
      assert_near(call.args[3], freq * 2, 1e-6, "every freq the start sends is the note")
    end
  end
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

-- #679: a step's note is a base override, never a params:set, so a buffer
-- voice's sequenced note was always exact; this pins it next to MIDI's
test("a step's note on a buffer voice sends the exact rate", function()
  local context, S = buffer_voice_setup()
  local seq = S.lib.sequencer
  params:set("v1_buf_rate", 1)
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "notes", {2})
  context.clear_engine_calls()
  pattern_clock_start()
  assert_near(last_sent(context, "setGrainParam", 0, "bufRate"), 2 ^ (2 / 12), 1e-9, "two semitones up, exact")
  assert_near(params:get("v1_buf_rate"), 1, 1e-9, "the stored rate stays")
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

test("a step with several notes plays its first as the voice's own and hands every output the list", function()
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

-- A start waiting for its bar is taken back by a second press, and dropped
-- by any start or stop of the patterns meanwhile, so it never fires after
-- them (#625). quantize_actions on bar, the play key pressed at beat 1.5
local function waiting_start(context, S, clock_source)
  S.patterns[1][1] = 15
  params:set("clock_source", clock_source)
  params:set("quantize_actions", 3)  -- bar
  context.clock.run_for((1.5 - clock.get_beats()) * clock.get_beat_sec())
  pattern_toggle()
  assert_true(S.lib.quantize.waiting("patterns"), "the start waits for the bar")
  assert_equal(S.lib.ui_flash.text("header"), "play at bar", "and says so")
end

test("a second play press while the start waits takes it back (#625)", function()
  local context, S = setup()
  waiting_start(context, S, CLOCK.internal)
  pattern_toggle()
  assert_true(not S.lib.quantize.waiting("patterns"), "a second press takes it back")
  assert_equal(S.lib.ui_flash.text("header"), nil, "its flash goes with it")
  context.clock.run_for(1.5)  -- past the bar
  assert_equal(S.pattern_playing, false, "nothing starts at the bar")
  pattern_toggle()
  assert_true(S.lib.quantize.waiting("patterns"), "a third press waits again")
  context.clock.run_for(2)
  assert_equal(S.pattern_playing, true, "and starts at its bar")
  pattern_clock_stop()
end)

test("a followed transport start drops a waiting pattern start: one step 1, not two (#625)", function()
  local context, S = setup()
  waiting_start(context, S, CLOCK.midi)
  context.clear_engine_calls()
  context.clock.transport_start()
  assert_true(S.pattern_playing, "the transport start plays the patterns")
  assert_true(not S.lib.quantize.waiting("patterns"), "and drops the waiting start")
  context.clock.run_for(0.01)
  assert_equal(#retriggers_of(context, 0), 1, "one retrigger of voice 1 on beat 0, not two")
  pattern_clock_stop()
end)

test("a followed transport stop drops a waiting pattern start (#625)", function()
  local context, S = setup()
  waiting_start(context, S, CLOCK.midi)
  context.clock.transport_stop()
  assert_true(not S.lib.quantize.waiting("patterns"), "a followed stop drops it")
  assert_equal(S.lib.ui_flash.text("header"), nil, "with its flash")
  context.clock.run_for(1.5)  -- past the bar
  assert_equal(S.pattern_playing, false, "and the patterns stay stopped")
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

-- A MIDI note is no step: on a gated voice it opens the voice's own gate
-- length, never the length the last step sent (its own gate, a ratchet's
-- share), which the stage would otherwise keep (#639)
test("a MIDI note on a running gated voice opens the voice's own gate length, not a step's", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  params:set("v1_seq_gate", 2)
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "gate", 2)
  context.clear_engine_calls()
  pattern_clock_start()
  pattern_clock_stop()
  assert_list_near(grain_values(context, 0, "gateSeconds"), {0.25}, 1e-9, "the step sent its own gate of 2 steps")
  context.clear_engine_calls()
  midi_note_on(1, 60, 127)
  local order = {}
  for _, call in ipairs(context.engine_calls) do
    if call.args[1] == 0 and call.name == "retrigger" then table.insert(order, "retrigger") end
    if call.args[1] == 0 and call.name == "setGrainParam" and call.args[2] == "gateSeconds" then
      table.insert(order, string.format("gateSeconds %.4f", call.args[3]))
    end
  end
  assert_equal(table.concat(order, ", "), "gateSeconds 0.0625, retrigger", "the voice's own half step, then the note")
  context.clear_engine_calls()
  midi_note_on(1, 62, 127)
  assert_equal(#grain_values(context, 0, "gateSeconds"), 0, "a second note sends no gate length: it has not changed")
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
      voice.values[key] = nil
    end
  end
  old.data.steps = nil
  fill_scene(old)  -- a scene without them
  assert_true(validate_scene(old), "it loads")
  local extras = old.data.voices[1].values
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
  assert_equal(#step_2, 2, "half of the 0.085 s left, none after 0.25 s: two hits")
  assert_hit_time(step_2[1], 0.165, "the swung step's first hit")
  assert_hit_time(step_2[2], 0.2075, "half of the 0.085 s left")
end)

-- The package review's findings ----------------------------------------

-- AGENTS.md: scaleNote is resent on every change that moves it. A synth
-- voice's scaleNote is its freq as a note, and a noted step moves the freq
test("a noted step sends a quantized synth voice's scaleNote, and the voice's own when it ends", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  params:set("scale", 2); params:set("root", 1)  -- C major
  params:set("v1_quantize", 1)
  params:set("v1_freq", 261.63)                   -- snapped to C
  S.patterns[1][1] = 15; S.patterns[1][2] = 15
  seq.set_step_attr(1, 1, "notes", {2})
  context.clear_engine_calls()
  pattern_clock_start()
  assert_near(last_sent(context, "setGrainParam", 0, "scaleNote"), 64, 1e-6, "the noted step plays E")
  context.clock.advance_until(S.pattern_clocks[1])
  assert_near(last_sent(context, "setGrainParam", 0, "scaleNote"), 60, 1e-6, "the next step: the voice's own C")
  pattern_clock_stop()
  pattern_clock_start()
  assert_near(last_sent(context, "setGrainParam", 0, "scaleNote"), 64, 1e-6, "E again")
  pattern_clock_stop()
  assert_near(last_sent(context, "setGrainParam", 0, "scaleNote"), 60, 1e-6, "the stop gives the voice its C back")
end)

-- A step turned off leaves no step to end its locks: the wrap does
test("turning off a voice's only set step ends its lock and note at the next wrap", function()
  local context, S = buffer_voice_setup()  -- voice 1 on a buffer at 0.2, voice 2 on its synth
  local seq, sync = S.lib.sequencer, S.lib.engine_sync
  S.patterns[1][5] = 15; seq.set_step_attr(1, 5, "pos", 0.6)
  S.patterns[2][5] = 15; seq.set_step_attr(2, 5, "notes", {2})
  local freq = params:get("v2_freq")
  pattern_clock_start()
  for _ = 1, 4 do context.clock.advance_until(S.pattern_clocks[2]) end  -- (voice 1 plays each step first)
  assert_near(sync.engine_base_value("v1_buf_pos"), 0.6, 1e-9, "step 5 locks voice 1")
  assert_near(sync.engine_base_value("v2_freq"), freq * 2 ^ (2 / 12), 1e-6, "and transposes voice 2")
  toggle_pattern_step(1, 5); toggle_pattern_step(2, 5)  -- each voice's only set step, off
  context.clock.run_for(1.0)
  assert_near(sync.engine_base_value("v1_buf_pos"), 0.6, 1e-9, "before the wrap the lock holds")
  context.clock.run_for(1.0)  -- past the wrap
  assert_near(sync.engine_base_value("v1_buf_pos"), 0.2, 1e-9, "the wrap ends the lock")
  assert_near(last_sent(context, "setGrainParam", 0, "bufPos"), 0.2, 1e-9, "and sends the stored position")
  assert_near(sync.engine_base_value("v2_freq"), freq, 1e-9, "and the note")
  assert_near(last_sent(context, "setVoiceParam", 1, "freq"), freq, 1e-9, "with the stored freq")
  assert_near(last_sent(context, "setGrainParam", 1, "scaleNote"), 69 + 12 * math.log(freq / 440) / math.log(2), 1e-6,
    "and the voice's own scaleNote")
  pattern_clock_stop()
end)

-- Ruling 47: the beat count set back by a transport start the patterns do
-- not follow. Voice 1 at 1/16 and voice 2 at a bar, every step set, step 11
-- of voice 1 ratcheted; the count goes back 1.3 s after the start, between
-- two 16ths and during step 11's ratchet
local function count_reset_setup(context, S, probe_name)
  local seq = S.lib.sequencer
  for step = 1, 16 do S.patterns[1][step] = 15; S.patterns[2][step] = 15 end
  params:set("v2_seq_division", 8)  -- 1 bar
  seq.set_step_attr(1, 11, "ratchet", 2)
  local events = record_output(S, probe_name or "probe")
  pattern_clock_start()
  context.clock.run_for(1.3)  -- beat 2.6 after the start: step 11 at 2.5, its second hit due at 2.625
  context.clock.transport_start()
  return events
end

-- Over the next 6.5 s: voice 2 moves on once a bar, each time with voice 1
-- at its step 1 and the transport at its bar; voice 1's steps follow one
-- another (none twice, none skipped) on the clock's 16ths; the hit pending
-- at the reset plays once, an eighth of a beat into the new count
local function assert_count_kept(context, S, events, what)
  local seq = S.lib.sequencer
  local last_step, changes = seq.sounding_step(2), 0
  for _ = 1, 650 do
    context.clock.run_for(0.01)
    if seq.sounding_step(2) ~= last_step then
      changes, last_step = changes + 1, seq.sounding_step(2)
      assert_equal(seq.sounding_step(1), 1, what .. ": voice 1 is at its step 1 as voice 2 moves on")
      assert_equal(seq.sounding_step(), 1, what .. ": and the transport at its bar")
    end
  end
  assert_equal(changes, 3, what .. ": voice 2 moves on once a bar")
  local steps = voice_events(events, 1, true)
  for index = 2, #steps do
    assert_equal(steps[index].step, steps[index - 1].step % 16 + 1, what .. ": voice 1's step " .. index)
  end
  for index = 12, #steps do
    local sixteenths = steps[index].beat / 0.25
    assert_near(sixteenths, math.floor(sixteenths + 0.5), 1e-6, what .. ": on the clock's 16ths, step " .. index)
  end
  local pending
  for _, event in ipairs(voice_events(events, 1)) do
    if event.step == 11 and event.hit == 2 and not pending then pending = event end
  end
  assert_near(pending.beat, 0.125, 1e-6, what .. ": the pending hit waits for its place in the new count")
  pattern_clock_stop()
end

test("a reset on the internal clock keeps every voice, the bar count and the ratchets in step", function()
  local context, S = setup()
  local events = count_reset_setup(context, S)
  assert_near(clock.get_beats(), 0, 1e-9, "the clock counts from 0")
  assert_equal(S.pattern_playing, true, "the patterns play on (#530)")
  assert_count_kept(context, S, events, "internal")
end)

test("an external start with follow off keeps every voice, the bar count and the ratchets in step", function()
  local context, S = setup()
  params:set("clock_source", CLOCK_SOURCE.midi)
  params:set("seq_follow_transport", 0)
  local events = count_reset_setup(context, S)
  assert_equal(S.pattern_playing, true, "not followed: the patterns play on")
  assert_count_kept(context, S, events, "MIDI, follow off")
end)

test("a pattern start after an unfollowed reset counts from the clock again", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  local events = count_reset_setup(context, S)
  context.clock.run_for(0.3)
  assert_true(seq.count_offset() ~= 0, "the patterns kept their own count")
  pattern_clock_stop()
  local beat = clock.get_beats()
  local bar = (math.floor(beat / 4) + 1) * 4
  context.clock.run_for((bar - beat) * 0.5)  -- to the clock's next bar
  clear_list(events)
  pattern_clock_start()
  assert_equal(seq.count_offset(), 0, "a start drops the offset")
  context.clock.run_for(2.0 + 0.01)
  local bar_steps = voice_events(events, 2)
  assert_equal(#bar_steps, 2, "voice 2: its step 1 and step 2")
  assert_near(bar_steps[1].beat, bar, 1e-6, "on the clock's bar")
  assert_near(bar_steps[2].beat, bar + 4, 1e-6, "and the next")
  pattern_clock_stop()
  -- a followed start drops it too
  count_reset_setup(context, S, "second probe")
  context.clock.run_for(0.3)
  params:set("clock_source", CLOCK_SOURCE.midi)
  context.clock.transport_start()
  assert_equal(seq.count_offset(), 0, "a followed start drops the offset")
  pattern_clock_stop()
end)

-- Ruling 54: what a clock does at each wake. Voice 1 at 1/16
-- and voice 2 at a bar, every step set, playing; returns the probe's events
local function in_step_setup(context, S)
  for step = 1, 16 do S.patterns[1][step] = 15; S.patterns[2][step] = 15 end
  params:set("v2_seq_division", 8)  -- 1 bar
  local events = record_output(S, "probe")
  pattern_clock_start()
  return events
end

-- Run seconds in 10 ms steps: each time voice 2 moves on, voice 1 is at its
-- step 1 and the transport at its bar. Returns how many times it moved on
local function count_in_step(context, S, seconds, what)
  local seq = S.lib.sequencer
  local last_step, changes = seq.sounding_step(2), 0
  for _ = 1, math.floor(seconds / 0.01 + 0.5) do
    context.clock.run_for(0.01)
    if seq.sounding_step(2) ~= last_step then
      changes, last_step = changes + 1, seq.sounding_step(2)
      assert_equal(seq.sounding_step(1), 1, what .. ": voice 1 is at its step 1 as voice 2 moves on")
      assert_equal(seq.sounding_step(), 1, what .. ": and the transport at its bar")
    end
  end
  return changes
end

-- Rule 4: no voice's gap between two of its steps is longer than its
-- division plus one 16th (a beat is 0.5 s), and its steps follow one
-- another, none twice and none skipped
local function assert_gaps_bounded(events, divisions, what)
  for voice_idx, division in pairs(divisions) do
    local steps = voice_events(events, voice_idx, true)
    for index = 2, #steps do
      local gap = steps[index].time - steps[index - 1].time
      assert_true(gap <= (division + 0.25) * 0.5 + 1e-9,
        string.format("%s: voice %d's gap before its step event %d is %.4f s", what, voice_idx, index, gap))
      assert_equal(steps[index].step, steps[index - 1].step % 16 + 1, what .. ": voice " .. voice_idx .. ", event " .. index)
    end
  end
end

local DIVISIONS = {[1] = 0.25, [2] = 4}  -- in beats: voice 1 at 1/16, voice 2 at a bar

test("a wake that reads its beat a little low plays on time and keeps every voice in step", function()
  local context, S = setup()
  local events = in_step_setup(context, S)
  context.clock.run_for(0.6)
  -- one late tick: voice 1's next wake, and the beat read during it, 1e-4 beats low
  local voice_1 = context.clock.threads[S.pattern_clocks[1]]
  local real_sync, real_get_beats = clock.sync, clock.get_beats
  local armed, low = true, false
  clock.sync = function(...)
    low = false
    local beat = real_sync(...)
    if armed and coroutine.running() == voice_1 then
      armed, low = false, true
      return beat - 1e-4
    end
    return beat
  end
  clock.get_beats = function() return real_get_beats() - (low and 1e-4 or 0) end
  local ran, changes = pcall(count_in_step, context, S, 7.0, "a late tick")
  clock.sync, clock.get_beats = real_sync, real_get_beats
  if not ran then error(changes, 0) end
  assert_true(not armed, "voice 1 woke once reading low")
  assert_equal(changes, 3, "voice 2 moves on once a bar")
  assert_gaps_bounded(events, DIVISIONS, "a late tick")
  pattern_clock_stop()
end)

test("the beat set back with no transport start keeps every voice in step, with no long gap", function()
  local context, S = setup()
  local events = in_step_setup(context, S)
  context.clock.run_for(9.55)  -- beat 20.1: the count about 20
  context.clock.set_beat(5)     -- a new clock source, 15 beats behind the count
  assert_equal(S.pattern_playing, true, "the patterns play on")
  assert_equal(count_in_step(context, S, 6.3, "set back"), 3, "voice 2 moves on once a bar")
  assert_gaps_bounded(events, DIVISIONS, "set back")
  assert_true(S.lib.sequencer.count_offset() ~= 0, "the clocks keep the count")
  pattern_clock_stop()
end)

test("a reset Strata's transport handler never sees keeps every voice in step, with no long gap", function()
  local context, S = setup()
  local events = in_step_setup(context, S)
  context.clock.run_for(9.55)
  clock.transport.start = function() end  -- another script's, which never calls Strata's
  context.clock.transport_start()          -- the internal clock's reset
  assert_equal(S.pattern_playing, true, "the patterns play on")
  assert_equal(count_in_step(context, S, 6.3, "an unseen reset"), 3, "voice 2 moves on once a bar")
  assert_gaps_bounded(events, DIVISIONS, "an unseen reset")
  assert_true(S.lib.sequencer.count_offset() ~= 0, "the clocks kept the count themselves")
  pattern_clock_stop()
end)

-- Ruling 58, in matron's order: clock_start_from_source resets
-- the beat and every waiting sync, then posts the start event, so a resume
-- posted before the reset is delivered first and the start (Strata's
-- handler) after it
test("a resume posted before a reset plays on time, the start comes after it, and its voice stays in step", function()
  local context, S = setup()
  params:set("v1_seq_swing", 66)
  local events = in_step_setup(context, S)
  context.clock.run_for(0.6)  -- beat 2.2: voice 1's next step, a swung one, is due at 2.33
  context.clock.advance_until(S.pattern_clocks[1])  -- its hop onto the clock's 16th at 2.25
  local posted_at
  context.clock.advance_until(S.pattern_clocks[1], function()
    posted_at = util.time()
    context.clock.transport_reset()  -- the internal clock's reset, between the post and the delivery
  end)
  local played = voice_events(events, 1, true)
  assert_near(played[#played].time, posted_at, 1e-9, "voice 1 played its step when it was posted")
  clock.transport.start()  -- then norns delivers the start event
  assert_equal(count_in_step(context, S, 6.3, "posted before the reset"), 3, "voice 2 moves on once a bar")
  assert_gaps_bounded(events, DIVISIONS, "posted before the reset")
  pattern_clock_stop()
end)

-- A new clock source is set from a param action, on Lua's own thread, so a
-- resume already posted is delivered after the jump: delivered beats late
-- with no time gone by, which a late delivery (Lua busy) never is
test("a resume posted before a jump forward and delivered after it keeps the count, and its voice stays in step", function()
  local context, S = setup()
  params:set("v1_seq_swing", 66)
  local events = in_step_setup(context, S)
  context.clock.run_for(0.6)  -- beat 2.2: voice 1's next step, a swung one, is due at 2.33
  context.clock.advance_until(S.pattern_clocks[1])  -- its hop onto the clock's 16th at 2.25
  local posted_at
  context.clock.advance_until(S.pattern_clocks[1], function()
    posted_at = util.time()
    context.clock.set_beat(30.3)  -- a new clock source, 28 beats ahead
  end)
  local played = voice_events(events, 1, true)
  assert_near(played[#played].time, posted_at, 1e-9, "voice 1 played its step when it was posted")
  assert_equal(count_in_step(context, S, 6.3, "posted before a jump forward"), 3, "voice 2 moves on once a bar")
  assert_gaps_bounded(events, DIVISIONS, "posted before a jump forward")
  pattern_clock_stop()
end)

-- Every change of the transport's 16th (S.pattern_sounding_step) over
-- seconds, in 10 ms steps: {time, step}
local function transport_moves(context, S, seconds)
  local moves, last = {}, S.pattern_sounding_step
  for _ = 1, math.floor(seconds / 0.01 + 0.5) do
    context.clock.run_for(0.01)
    if S.pattern_sounding_step ~= last then
      last = S.pattern_sounding_step
      table.insert(moves, {time = util.time(), step = last})
    end
  end
  return moves
end

test("a transport resume posted before a reset counts on: its 16ths never freeze and never jump", function()
  local context, S = setup()
  local events = in_step_setup(context, S)
  context.clock.run_for(9.55)  -- beat 20.1: the transport waits for 20.25, after the voices due then
  local before = S.pattern_sounding_step
  context.clock.advance_until(S.pattern_clock, function() context.clock.transport_reset() end)
  assert_equal(S.pattern_sounding_step, before % 16 + 1, "the transport counted the 16th it was posted for")
  clock.transport.start()
  local moves = transport_moves(context, S, 6.3)
  local last, last_time = S.pattern_sounding_step, util.time() - 6.3
  assert_true(#moves >= 40, "the 16ths go on: " .. #moves .. " moves")
  for index, move in ipairs(moves) do
    local previous = index == 1 and before % 16 + 1 or moves[index - 1].step
    assert_equal(move.step, previous % 16 + 1, "one 16th at a time, move " .. index)
    local gap = move.time - (index == 1 and last_time or moves[index - 1].time)
    assert_true(gap <= 0.25 + 0.01 + 1e-9, string.format("move %d comes %.3f s after the one before", index, gap))
  end
  assert_true(last ~= nil, "the transport plays")
  assert_gaps_bounded(events, DIVISIONS, "the transport posted before the reset")
  pattern_clock_stop()
end)

-- A reset no handler sees whose resumes were all posted before it (every
-- clock due on the same 16th): the first clock to sync again keeps the count
test("a reset no handler sees, posted after every clock's resume, keeps every voice in step", function()
  local context, S = setup()
  local events = in_step_setup(context, S)
  context.clock.run_for(9.55)  -- beat 20.1: every clock of the patterns is due at 20.25
  clock.transport.start = function() end  -- another script's, which never calls Strata's
  local reset = false
  repeat
    context.clock.advance(function()
      if not reset and clock.get_beats() >= 20.25 then
        reset = true
        context.clock.transport_reset()
      end
    end)
  until reset
  assert_equal(count_in_step(context, S, 6.3, "every resume posted first"), 3, "voice 2 moves on once a bar")
  assert_gaps_bounded(events, DIVISIONS, "every resume posted first")
  assert_true(S.lib.sequencer.count_offset() ~= 0, "the clocks kept the count themselves")
  pattern_clock_stop()
end)

-- Rule 2: a jump a clock notices maps the transport's pending 16th to the
-- clock's first 16th after now, as the handler does, so a 1/32 voice never
-- plays two steps at one instant
local function assert_no_two_at_once(events, voice_idx, what)
  local steps = voice_events(events, voice_idx, true)
  for index = 2, #steps do
    assert_true(steps[index].time > steps[index - 1].time + 1e-9,
      string.format("%s: voice %d's steps %d and %d at one instant (%.4f s)", what, voice_idx, index - 1, index,
        steps[index].time))
  end
end

local function thirty_second_jump(run_seconds, to_beat, what)
  local context, S = setup()
  params:set("v1_seq_division", 1)  -- 1/32
  local events = in_step_setup(context, S)
  context.clock.run_for(run_seconds)
  context.clock.set_beat(to_beat)
  assert_equal(count_in_step(context, S, 6.3, what), 3, what .. ": voice 2 moves on once a bar")
  assert_no_two_at_once(events, 1, what)
  assert_gaps_bounded(events, {[1] = 0.125, [2] = 4}, what)
  pattern_clock_stop()
end

test("a 1/32 voice never plays two steps at one instant through a jump back a clock notices", function()
  thirty_second_jump(9.55, 5, "a 1/32 voice set back")
end)

test("a 1/32 voice never plays two steps at one instant through a jump forward a clock notices", function()
  thirty_second_jump(4.05, 30.3, "a 1/32 voice set forward")
end)

-- Ending a clock never cancels one whose resume matron may have posted:
-- norns would deliver that resume to a coroutine it no longer has, and
-- clock.resume raises (maiden prints the error). action runs in the
-- scheduler step that posts the patterns' clocks (the transport's among
-- them), after the posts and before any delivery, as an event Lua handles
-- first does
local function between_posts_and_deliveries(context, S, action)
  local done = false
  repeat
    context.clock.advance(function()
      local event = context.clock.events[S.pattern_clock]
      if not done and event and not event.ready then
        done = true
        action()
      end
    end)
  until done
end

-- The patterns' clocks: every voice's, then the transport's
local function pattern_clock_ids(S)
  local ids = {}
  for voice_idx = 1, S.constants.NUM_VOICES do ids[voice_idx] = S.pattern_clocks[voice_idx] end
  ids[S.constants.NUM_VOICES + 1] = S.pattern_clock
  return ids
end

local function assert_no_clock_errors(context, what)
  local errors = context.clock.take_errors()
  assert_equal(#errors, 0, what .. ": no clock error" .. (errors[1] and (", " .. errors[1]) or ""))
end

-- action, run while every clock of the patterns has its resume posted
-- (between_posts_and_deliveries): no clock error and nothing printed, the
-- step's deliveries included. Returns the clocks before it, the index of
-- the first event after it and the beat it ran at
local function while_posted(context, S, events, what, action)
  local old, printed, from, beat = pattern_clock_ids(S), #context.printed, nil, nil
  between_posts_and_deliveries(context, S, function()
    for index = 1, #old do
      local event = context.clock.events[old[index]]
      assert_true(event ~= nil and not event.ready, what .. ": clock " .. index .. "'s resume is posted")
    end
    from, beat = #events + 1, clock.get_beats()
    action()
  end)
  assert_no_clock_errors(context, what)
  local lines = {}
  for index = printed + 1, #context.printed do table.insert(lines, context.printed[index]) end
  assert_equal(table.concat(lines, "\n"), "", what .. ": nothing printed")
  return old, from, beat
end

-- One clock for every voice and one for the transport, each running and
-- none of them one of old (whose posted resumes have come: they ended)
local function assert_one_clock_each(context, S, old, what)
  local new, seen = pattern_clock_ids(S), {}
  for index = 1, #old do
    assert_true(context.clock.threads[old[index]] == nil, what .. ": the old clock " .. index .. " has ended")
    seen[old[index]] = true
  end
  for index = 1, S.constants.NUM_VOICES + 1 do
    local id = new[index]
    assert_true(id ~= nil and context.clock.threads[id] ~= nil and not seen[id],
      what .. ": clock " .. index .. " is a new one, running")
    seen[id] = true
  end
end

-- The patterns started over at beat (the events from index from on): every
-- voice and the transport at step 1 at once on a count of the clock's own;
-- over the next 6.3 s voices 1 (1/16) and 2 (a bar) play step 1 first, on
-- the start's beat, then every step on their division from it, one after
-- another, in step with each other and the transport
local function assert_started(context, S, events, from, beat, what)
  local seq = S.lib.sequencer
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(seq.sounding_step(voice_idx), 1, what .. ": voice " .. voice_idx .. " at its step 1")
  end
  assert_equal(seq.sounding_step(), 1, what .. ": the transport at its 16th 1")
  assert_equal(seq.count_offset(), 0, what .. ": the count is the clock's")
  assert_equal(count_in_step(context, S, 6.3, what), 3, what .. ": voice 2 moves on once a bar")
  assert_no_clock_errors(context, what .. ", playing on")
  local after = {}
  for index = from, #events do table.insert(after, events[index]) end
  for voice_idx, division in pairs(DIVISIONS) do
    local steps = voice_events(after, voice_idx, true)
    assert_equal(steps[1] and steps[1].step, 1, what .. ": voice " .. voice_idx .. " plays its step 1 first")
    assert_near(steps[1].beat, beat, 1e-9, what .. ": voice " .. voice_idx .. "'s step 1 on the start's beat")
    for index, event in ipairs(steps) do
      local divisions = (event.beat - beat) / division
      assert_near(divisions, math.floor(divisions + 0.5), 1e-6,
        string.format("%s: voice %d's step event %d on its division from the start", what, voice_idx, index))
    end
    assert_no_two_at_once(after, voice_idx, what)
  end
  assert_gaps_bounded(after, DIVISIONS, what)
end

-- A MIDI start the patterns follow, in matron's order: clock_start_from_source
-- resets the beat and every waiting sync, then posts the start event. The
-- resumes the tick posted just before the reset (every clock of the
-- patterns is due at 20.25) are delivered first, on the old count; each
-- clock finds the beat gone back and sleeps 0, and the next tick posts
-- those sleeps' resumes while Lua handles the start (Strata's handler)
-- first. That handler cancels no clock
local function followed_start(context, S, events, what)
  between_posts_and_deliveries(context, S, function() context.clock.transport_reset() end)
  return while_posted(context, S, events, what, function() clock.transport.start() end)
end

test("a followed start with every clock's resume posted raises and prints nothing and starts every voice at step 1", function()
  local context, S = setup()
  params:set("clock_source", CLOCK_SOURCE.midi)
  local events = in_step_setup(context, S)
  context.clock.run_for(9.55)  -- beat 20.1
  local old, from, beat = followed_start(context, S, events, "a followed start")
  assert_near(beat, 0, 1e-9, "the start comes on the reset's beat 0")
  assert_one_clock_each(context, S, old, "a followed start")
  assert_started(context, S, events, from, beat, "a followed start")
  pattern_clock_stop()
end)

-- A millisecond after the first start every clock it began waits on its
-- next 16th; the second start's reset puts those syncs on beat 0, and the
-- next tick posts them all before Lua handles the start
test("a second followed start a millisecond after the first is as clean", function()
  local context, S = setup()
  params:set("clock_source", CLOCK_SOURCE.midi)
  local events = in_step_setup(context, S)
  context.clock.run_for(9.55)  -- beat 20.1
  local first = followed_start(context, S, events, "the first start")
  assert_one_clock_each(context, S, first, "the first start")
  context.clock.run_for(0.001)
  context.clock.transport_reset()
  local old, from, beat = while_posted(context, S, events, "the second start", function() clock.transport.start() end)
  assert_one_clock_each(context, S, old, "the second start")
  assert_started(context, S, events, from, beat, "the second start")
  pattern_clock_stop()
end)

-- The play key's stop, then its start (quantize off: at once), pressed as
-- the clocks' resumes for beat 20 are posted
test("the play key's stop and start with every clock's resume posted cancel none of them", function()
  local context, S = setup()
  local events = in_step_setup(context, S)
  context.clock.run_for(9.45)  -- beat 19.9: every clock of the patterns is due at 20
  local old, from, beat = while_posted(context, S, events, "the play key", function()
    pattern_toggle()
    assert_equal(S.pattern_playing, false, "the first press stops the patterns")
    pattern_toggle()
  end)
  assert_one_clock_each(context, S, old, "the play key")
  assert_started(context, S, events, from, beat, "the play key")
  pattern_clock_stop()
end)

-- The play key's stop, pressed just before the internal clock's reset:
-- Lua handles it, then the start event, then the resumes the reset brings.
-- Every clock's sync was put on beat 0, below the beat it synced at, so
-- each resume is posted and no clock is canceled
test("the play key's stop with a reset's resumes posted cancels none of them", function()
  local context, S = setup()
  local events = in_step_setup(context, S)
  context.clock.run_for(9.55)  -- beat 20.1: every clock of the patterns waits on a sync due at 20.25
  context.clock.transport_reset()
  local old = while_posted(context, S, events, "a stop after a reset", function()
    pattern_toggle()
    clock.transport.start()  -- the internal clock's: the patterns do not follow it
  end)
  assert_equal(S.pattern_playing, false, "the patterns stopped")
  for index = 1, #old do assert_true(context.clock.threads[old[index]] == nil, "clock " .. index .. " has ended") end
  local played = #events
  context.clock.run_for(1.0)
  assert_equal(#events, played, "and nothing plays")
end)

-- At a division reset's bar the transport restarts every voice still on
-- its old anchor (restart_voice); a voice whose resume is posted on that
-- tick and delivered after the transport's is restarted with it posted
test("a voice restarted with its resume posted, as at a division reset's bar, cancels no clock", function()
  local context, S = setup()
  local events = in_step_setup(context, S)
  context.clock.run_for(9.45)  -- beat 19.9: every clock of the patterns is due at 20
  local old, from = while_posted(context, S, events, "a voice restarted", function()
    S.lib.sequencer.restart_voice(1, clock.get_beats() + S.lib.sequencer.count_offset())
  end)
  local now = pattern_clock_ids(S)
  assert_true(context.clock.threads[old[1]] == nil, "voice 1's old clock has ended")
  assert_true(now[1] ~= old[1] and context.clock.threads[now[1]] ~= nil, "a new clock runs voice 1")
  for index = 2, #old do assert_equal(now[index], old[index], "clock " .. index .. " is the same") end
  context.clock.run_for(2.0)
  assert_no_clock_errors(context, "a voice restarted, playing on")
  local after = {}
  for index = from, #events do table.insert(after, events[index]) end
  local steps = voice_events(after, 1, true)
  assert_equal(steps[1] and steps[1].step, 1, "voice 1 plays its step 1 first")
  assert_no_two_at_once(after, 1, "a voice restarted")
  assert_gaps_bounded(after, {[1] = 0.25}, "a voice restarted")
  pattern_clock_stop()
end)

-- A stop just before the clocks' next 16th leaves them to end at it, as
-- matron may post their resumes first; norns cancels every coroutine right
-- after a script's cleanup, so cleanup ends them at once
test("cleanup leaves no clock of the patterns running, those a stop left to end included", function()
  local context, S = setup()
  in_step_setup(context, S)
  context.clock.run_for(9.495)  -- beat 19.99: every clock of the patterns waits on a sync due at 20
  local old = pattern_clock_ids(S)
  pattern_clock_stop()
  cleanup()
  for index = 1, #old do assert_true(context.clock.threads[old[index]] == nil, "clock " .. index .. " has ended") end
end)

local function pattern_clock_invariant(S)
  for _, record in ipairs(S.registry.invariants) do
    if record.name == "pattern clock" then return record.fn end
  end
end

-- The invariant describes the clocks that run: a recorded clock that no
-- longer runs, or one ended and left to end at its next wake, breaks it
test("the pattern clock invariant sees a recorded clock that no longer runs or was ended", function()
  local context, S = setup()
  local check = pattern_clock_invariant(S)
  assert_true(check ~= nil, "registered")
  local events = in_step_setup(context, S)
  assert_equal(check(), nil, "it holds while the patterns play")
  clock.cancel(S.pattern_clocks[3])  -- behind the module's back, its id still recorded
  local broken = check()
  assert_true(broken ~= nil and tostring(broken):find("not running", 1, true) ~= nil,
    "a canceled clock still recorded breaks it: " .. tostring(broken))
  pattern_clock_stop()
  assert_equal(check(), nil, "stopped: it holds")
  pattern_clock_start()
  context.clock.run_for(0.2)  -- every clock of the patterns is due at the next 16th
  while_posted(context, S, events, "a restart", function()
    local ended = S.pattern_clocks[1]
    S.lib.sequencer.restart_voice(1, clock.get_beats() + S.lib.sequencer.count_offset())
    assert_equal(check(), nil, "it holds with the ended clock waiting for its posted resume")
    local running = S.pattern_clocks[1]
    S.pattern_clocks[1] = ended
    broken = check()
    S.pattern_clocks[1] = running
  end)
  assert_true(broken ~= nil and tostring(broken):find("ended", 1, true) ~= nil,
    "an ended clock recorded again breaks it: " .. tostring(broken))
  assert_equal(check(), nil, "it holds after the step")
  pattern_clock_stop()
end)

-- Rule 3: late is not a jump. Voice 1 at 1/16t (a step every 1/6 beat); its
-- 14th step, at 13/6 beats from the start, is off the 16ths
test("a resume posted 0.05 beat late on a triplet step plays once and leaves the count alone", function()
  local context, S = setup()
  params:set("v1_seq_division", 2)  -- 1/16t
  local start_beat, start_time = clock.get_beats(), util.time()
  local events = in_step_setup(context, S)
  local late_beat = start_beat + 13 / 6
  local late_time = start_time + 13 / 6 * 0.5
  context.clock.run_for(late_time - util.time() - 0.001)
  local before = #voice_events(events, 1, true)
  context.set_time(late_time + 0.025)  -- posted 0.05 beat after its beat
  context.clock.advance()
  local steps = voice_events(events, 1, true)
  assert_equal(#steps, before + 1, "the late step played")
  assert_equal(steps[#steps].step, 14, "step 14")
  assert_near(steps[#steps].beat, late_beat + 0.05, 1e-9, "late")
  assert_equal(S.lib.sequencer.count_offset(), 0, "the count did not move")
  context.clock.run_for(0.26)
  steps = voice_events(events, 1, true)
  assert_equal(#steps, before + 4, "the next three steps")
  for index = 1, 3 do
    assert_near(steps[before + 1 + index].beat, start_beat + (13 + index) / 6, 1e-9, "on its beat, step " .. 14 + index)
  end
  pattern_clock_stop()
end)

-- Rule 4: no bursts. Voice 1's resume for its tick at 2.25 is delivered two
-- beats late (Lua busy): it plays one step, the one the beat puts it at, then
-- goes on in step with the others
test("a clock held two beats plays one step when it wakes, then goes on in step", function()
  local context, S = setup()
  local events = in_step_setup(context, S)
  context.clock.run_for(0.6)  -- beat 2.2
  local delivered_at
  context.clock.advance_until(S.pattern_clocks[1], function()
    context.set_time(util.time() + 1.0)
    delivered_at = util.time()
  end)
  local at_delivery = {}
  for _, event in ipairs(voice_events(events, 1, true)) do
    if math.abs(event.time - delivered_at) < 1e-9 then table.insert(at_delivery, event) end
  end
  assert_equal(#at_delivery, 1, "one step when it wakes")
  assert_equal(at_delivery[1].step, 14, "the step the beat puts it at (beat 4.25, 13 16ths after the start)")
  assert_equal(count_in_step(context, S, 6.3, "held"), 3, "voice 2 moves on once a bar")
  local after = {}
  for _, event in ipairs(events) do
    if event.time >= delivered_at - 1e-9 then table.insert(after, event) end
  end
  assert_no_two_at_once(after, 1, "held")
  assert_gaps_bounded(after, DIVISIONS, "held")
  pattern_clock_stop()
end)

-- A jump forward is noticed the same way (a wake later than its beat by more
-- than the tolerance) and handled as an unannounced jump
test("the beat set forward keeps every voice in step and plays each late step once", function()
  local context, S = setup()
  local events = in_step_setup(context, S)
  context.clock.run_for(4.05)   -- beat 9.1
  context.clock.set_beat(30.3)  -- 21 beats ahead of the count
  assert_equal(count_in_step(context, S, 6.3, "set forward"), 3, "voice 2 moves on once a bar")
  assert_gaps_bounded(events, DIVISIONS, "set forward")
  pattern_clock_stop()
end)

test("a gated voice's event falls back to the default gate length", function()
  local _, S = setup()
  local events = record_output(S, "probe")
  params:set("v1_seq_gate", 2)
  S.patterns[1][1] = 15
  S.voices[1].values.seq_gate_length = nil
  pattern_clock_start(); pattern_clock_stop()
  assert_near(voice_events(events, 1)[1].gate_beats, 0.125, 1e-9, "0.5 steps of 1/16, the default")
end)

test("a step's notes go through the scale once per step, whatever its ratchets", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  local events = record_output(S, "probe")
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "notes", {2}); seq.set_step_attr(1, 1, "ratchet", 4)
  local calls, real_degree_semitones = 0, seq.degree_semitones
  seq.degree_semitones = function(...) calls = calls + 1; return real_degree_semitones(...) end
  pattern_clock_start()
  context.clock.run_for(0.12)
  pattern_clock_stop()
  seq.degree_semitones = real_degree_semitones
  assert_equal(calls, 1, "one conversion for the step's note")
  local hits = voice_events(events, 1)
  assert_equal(#hits, 4, "four hits")
  for index, event in ipairs(hits) do assert_list_near(event.semitones, {2}, 1e-9, "hit " .. index) end
end)

test("euclid wraps any whole rotation into the length and clamps the hits", function()
  local _, S = setup()
  local seq = S.lib.sequencer
  params:set("v1_seq_length", 8)
  seq.euclid(1, 3, 9)
  local expected = {0, 15, 0, 0, 15, 0, 0, 15}
  for step = 1, 8 do assert_equal(S.patterns[1][step], expected[step], "rotation 9 is 1: step " .. step) end
  assert_equal(S.seq_euclid[1][1], 3); assert_equal(S.seq_euclid[1][2], 1, "the wrapped rotation is kept")
  seq.euclid(1, 12, -1)
  for step = 1, 8 do assert_equal(S.patterns[1][step], 15, "12 hits clamp to 8: step " .. step) end
  assert_equal(S.seq_euclid[1][1], 8, "the clamped hits"); assert_equal(S.seq_euclid[1][2], 7, "-1 is 7")
  seq.euclid(1, 3, 1.5)
  assert_equal(S.seq_euclid[1][2], 7, "a rotation that is no whole number does nothing")
end)

-- 3.5 (design §4, rulings 13, 26 and 27): a step's notes play as a chord
-- through the note allocator (S.lib.notes): the first note is the voice's
-- own (3.4's override), the rest extra notes, each ended where 3.4 ends a
-- step's note

-- An engine call as "name(arg, ...)", numbers to 4 decimals
local function call_text(call)
  local args = {}
  for index, value in ipairs(call.args) do
    args[index] = type(value) == "number" and (string.format("%.4f", value):gsub("%.?0+$", "")) or tostring(value)
    if args[index] == "-0" or args[index] == "" then args[index] = "0" end
  end
  return call.name .. "(" .. table.concat(args, ", ") .. ")"
end

local function call_texts(context)
  local texts = {}
  for _, call in ipairs(context.engine_calls) do table.insert(texts, call_text(call)) end
  return texts
end

-- The index of the first call named name to engine voice engine_voice (nil: none)
local function first_call(context, name, engine_voice)
  for index, call in ipairs(context.engine_calls) do
    if call.name == name and call.args[1] == engine_voice then return index end
  end
  return nil
end

-- noteOn and noteOff calls to engine voice engine_voice, in order
local function note_calls(context, name, engine_voice)
  local calls = {}
  for _, call in ipairs(context.calls_named(name)) do
    if call.args[1] == engine_voice then table.insert(calls, call) end
  end
  return calls
end

-- The note synths the engine starts per engine voice: a noteOn on an extra
-- slot (engine slot 1-7) holding no live note (none yet, or ended by a
-- noteOff since); and the noteOns on a live one (an accent, no node)
local function note_starts(context)
  local live, starts, repeats = {}, {}, {}
  for _, call in ipairs(context.engine_calls) do
    local voice, slot = call.args[1], call.args[2]
    if (call.name == "noteOn" or call.name == "noteOff") and slot > 0 then
      local key = voice .. ":" .. slot
      if call.name == "noteOff" then
        live[key] = nil
      elseif live[key] then
        repeats[voice] = (repeats[voice] or 0) + 1
      else
        live[key] = true
        starts[voice] = (starts[voice] or 0) + 1
      end
    end
  end
  return starts, repeats
end

-- MIDI's key for note number on voice_idx's channel (per voice): channel * 128 + note
local function held_key(voice_idx, number) return voice_idx * 128 + number end

-- A note MIDI holds on voice, its key down (ruling 55: only a key down keeps
-- slot 1 from a step), in MIDI's key state as a note on leaves it: its own
-- note when nothing else holds the voice
local function midi_note(S, voice_idx, number)
  local key = held_key(voice_idx, number)
  S.midi_state.held[voice_idx][key] = true
  S.midi_state.note_voice[voice_idx] = S.midi_state.note_voice[voice_idx] or {}
  S.midi_state.note_voice[voice_idx][number] = {voice_idx}
  return S.lib.notes.play(voice_idx, {owner = "midi", key = key, pitch = number, velocity = 0.5, park = true,
    set_own = function() end})
end

-- That key lifted in release mode: its note released (the own note parks
-- under others), the key gone from MIDI's state
local function midi_release(S, voice_idx, number)
  local key = held_key(voice_idx, number)
  S.midi_state.held[voice_idx][key] = nil
  local channel_notes = S.midi_state.note_voice[voice_idx]
  channel_notes[number] = nil
  if next(channel_notes) == nil then S.midi_state.note_voice[voice_idx] = nil end
  return S.lib.notes.release(voice_idx, "midi", key)
end

test("a step's chord plays its first note as the override and the rest as extra notes", function()
  local context, S = setup()
  local seq, notes = S.lib.sequencer, S.lib.notes
  params:set("v1_freq", 440)
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "notes", {0, 4, 7})
  context.clear_engine_calls()
  pattern_clock_start()
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), 440, 1e-9, "the first note is the freq override")
  assert_near(S.lib.engine_sync.engine_base_value("v1_freq"), 440, 1e-9, "a base override")
  local ons = note_calls(context, "noteOn", 0)
  assert_equal(#ons, 2, "two extra notes")
  assert_true(first_call(context, "retrigger", 0) < first_call(context, "noteOn", 0), "after the voice's retrigger")
  assert_equal(#retriggers_of(context, 0), 1, "one retrigger")
  assert_near(retriggers_of(context, 0)[1].args[2], 1, 1e-9, "at the step's velocity")
  local expected = {{1, 73, 554.3653}, {2, 76, 659.2551}}
  for index, values in ipairs(expected) do
    local args = ons[index].args
    assert_equal(args[2], values[1], "note " .. index + 1 .. ": its slot")
    assert_near(args[3], values[2], 1e-9, "note " .. index + 1 .. ": its note")
    assert_near(args[4], values[3], 1e-3, "note " .. index + 1 .. ": its freq")
    assert_near(args[6], 1, 1e-9, "note " .. index + 1 .. ": the step's velocity")
  end
  assert_equal(#context.calls_named("noteExpression"), 2, "each extra note's first expression")
  assert_equal(notes.find(1, "seq", 1), 1, "the first note is slot 1")
  assert_equal(notes.find(1, "seq", 2), 2); assert_equal(notes.find(1, "seq", 3), 3)
  assert_equal(notes.held(1), 3); assert_equal(notes.pool_used(), 2)
  pattern_clock_stop()
end)

test("a chord step on a stopped voice starts it, then takes its further notes", function()
  local context, S = setup()
  local seq, notes = S.lib.sequencer, S.lib.notes
  assert_true(not S.voices[3].active, "voice 3 is stopped")
  params:set("v3_freq", 440)
  S.patterns[3][1] = 15
  seq.set_step_attr(3, 1, "notes", {0, 4})
  for _, gate in ipairs({1, 2}) do  -- ungated, then gated (a gated start is retriggered too)
    params:set("v3_seq_gate", gate)
    context.clear_engine_calls()
    pattern_clock_start()
    assert_true(S.voices[3].active, "the step started voice 3")
    local voice_on, note_on = first_call(context, "voiceOn", 2), first_call(context, "noteOn", 2)
    assert_true(voice_on ~= nil and note_on ~= nil and voice_on < note_on, "the start, then the extra note")
    if gate == 2 then assert_true(first_call(context, "retrigger", 2) < note_on, "gated: the retrigger first too") end
    assert_near(context.engine_calls[note_on].args[3], 73, 1e-9, "the second note, four semitones up")
    assert_equal(notes.find(3, "seq", 1), 1, "the first note is the voice's own")
    assert_equal(notes.find(3, "seq", 2) ~= nil, true, "the second an extra note")
    pattern_clock_stop()
    toggle_voice(3)  -- stopped again for the next case
  end
end)

-- The engine calls of a fresh script's first step 1 on voice 1 (running, at
-- 220 Hz, the scale off) with notes (nil: none), then of its plain step 2,
-- then of the stop; prepare(S) runs before the start
local function step_calls(notes, prepare)
  local context, S = setup()
  params:set("v1_freq", 220)
  S.patterns[1][1] = 15; S.patterns[1][2] = 15
  if notes then S.lib.sequencer.set_step_attr(1, 1, "notes", notes) end
  if prepare then prepare(S) end
  context.clear_engine_calls()
  pattern_clock_start()
  local first = call_texts(context)
  context.clear_engine_calls()
  context.clock.advance_until(S.pattern_clocks[1])
  local second = call_texts(context)
  context.clear_engine_calls()
  pattern_clock_stop()
  return {first = first, second = second, stop = call_texts(context)}, S, context
end

local function assert_texts(actual, expected, what)
  assert_equal(table.concat(actual, " "), table.concat(expected, " "), what)
end

test("a one-note step and a step without notes send 3.4's messages", function()
  local calls, S = step_calls({3})
  assert_texts(calls.first, {"setVoiceParam(0, freq, 261.6256)", "setGrainParam(0, scaleNote, 60)", "retrigger(0, 1)"},
    "a one-note step: the override, its scaleNote, the retrigger")
  assert_texts(calls.second, {"setVoiceParam(0, freq, 220)", "setGrainParam(0, scaleNote, 57)", "retrigger(0, 1)"},
    "the next step without notes: the voice's own freq and scaleNote back")
  assert_texts(calls.stop, {}, "the stop: nothing left to end")
  assert_equal(S.lib.notes.held(1), 0, "nothing held")
  calls = step_calls(nil)
  assert_texts(calls.first, {"retrigger(0, 1)"}, "a step without notes: 3.4's retrigger")
  assert_texts(calls.second, {"retrigger(0, 1)"})
  -- the stop of a one-note step that still holds its note
  local context
  calls, S, context = step_calls({3}, function(state) state.patterns[1][2] = 0 end)
  assert_texts(calls.stop, {"setVoiceParam(0, freq, 220)", "setGrainParam(0, scaleNote, 57)"}, "the stop ends the note")
  -- a one-note step that starts a stopped voice sends no note command
  context.clear_engine_calls()
  S.patterns[3][1] = 15
  S.lib.sequencer.set_step_attr(3, 1, "notes", {5})
  pattern_clock_start()
  assert_true(S.voices[3].active, "the step started voice 3")
  for _, name in ipairs({"noteOn", "noteOff", "noteExpression"}) do
    assert_equal(#context.calls_named(name), 0, "no " .. name)
  end
  assert_equal(S.lib.notes.find(3, "seq", 1), 1, "its note is the voice's own")
  pattern_clock_stop()
end)

-- rulings 26 and 32: a chord's further notes never fall back onto slot 1
test("with a note cap of 1 or a pool of 0 a three-note step sends what a one-note step sends in 3.4", function()
  local one = step_calls({3}, function(state) state.patterns[1][2] = 0 end)
  for _, case in ipairs({
      {"a note cap of 1", function() params:set("v1_note_cap", 1) end},
      {"a pool of 0", function(state) state.lib.notes.set_pool(0) end}}) do
    local three = step_calls({3, 7, 10}, function(state)
      case[2](state)
      state.patterns[1][2] = 0
    end)
    assert_texts(three.first, one.first, case[1] .. ": the step")
    assert_texts(three.second, one.second, case[1] .. ": the next step")
    assert_texts(three.stop, one.stop, case[1] .. ": the stop")
  end
end)

test("the next played step re-pitches the notes it keeps and releases the ones it lacks", function()
  local context, S = setup()
  local seq, notes = S.lib.sequencer, S.lib.notes
  params:set("v1_freq", 440)
  S.patterns[1][1] = 15; S.patterns[1][2] = 15
  seq.set_step_attr(1, 1, "notes", {0, 4, 7})
  seq.set_step_attr(1, 2, "notes", {0, 5})
  pattern_clock_start()
  context.clear_engine_calls()
  context.clock.advance_until(S.pattern_clocks[1])
  local ons, offs = note_calls(context, "noteOn", 0), note_calls(context, "noteOff", 0)
  assert_equal(#offs, 1, "one note released")
  assert_equal(call_text(offs[1]), "noteOff(0, 2, 0)", "the third note, released")
  assert_equal(#ons, 1, "one note re-pitched")
  assert_equal(ons[1].args[2], 1, "on its live slot"); assert_near(ons[1].args[3], 74, 1e-9, "five semitones up")
  assert_equal(#context.calls_named("noteExpression"), 0, "no new note: no first expression")
  assert_true(first_call(context, "noteOff", 0) < first_call(context, "noteOn", 0), "the release first")
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), 440, 1e-9, "the first note kept as the override")
  assert_equal(notes.held(1), 2); assert_equal(notes.pool_used(), 1)
  -- a step without notes releases every one
  context.clear_engine_calls()
  S.patterns[1][3] = 15
  context.clock.advance_until(S.pattern_clocks[1])
  assert_texts({call_text(note_calls(context, "noteOff", 0)[1])}, {"noteOff(0, 1, 0)"}, "the second note released")
  assert_equal(#note_calls(context, "noteOn", 0), 0, "nothing played")
  assert_equal(notes.held(1), 0, "and the first ended with its override")
  pattern_clock_stop()
end)

test("a chord ends when the patterns stop, the pattern is replaced or cleared, the length is cut or the wrap passes it", function()
  local context, S = setup()
  local seq, notes = S.lib.sequencer, S.lib.notes
  local function chord_step(step)
    S.patterns[1][step] = 15
    seq.set_step_attr(1, step, "notes", {0, 4, 7})
  end
  local function assert_ended(what)
    local offs = note_calls(context, "noteOff", 0)
    assert_equal(#offs, 2, what .. ": both extra notes released")
    for index, off in ipairs(offs) do
      assert_true(off.args[2] > 0 and off.args[3] == 0, what .. ": note " .. index + 1 .. " released, " .. call_text(off))
    end
    assert_equal(notes.held(1), 0, what .. ": nothing held")
    assert_equal(notes.pool_used(), 0, what .. ": the pool free")
  end
  local function playing(what)
    assert_equal(notes.held(1), 3, what .. ": the chord sounds")
    context.clear_engine_calls()
  end
  chord_step(1)
  pattern_clock_start(); playing("playing")
  pattern_clock_stop(); assert_ended("the stop")
  pattern_clock_start(); playing("again")
  clear_pattern(1); assert_ended("a cleared pattern")
  chord_step(1); pattern_clock_start(); playing("a new start")
  seq.replace_pattern(1, {15}); assert_ended("a replaced pattern")
  pattern_clock_stop()
  -- a scene recall (it replaces every pattern)
  capture_scene(2)
  pattern_clock_start(); playing("before the recall")
  recall_scene(2); assert_ended("a scene recall")
  pattern_clock_stop()
  -- the length set below the step that played it
  clear_pattern(1); seq.set_step_attr(1, 1, "notes", nil); chord_step(5)
  pattern_clock_start()
  for _ = 1, 4 do context.clock.advance_until(S.pattern_clocks[1]) end
  assert_equal(seq.sounding_step(1), 5, "step 5 played")
  playing("step 5's chord")
  params:set("v1_seq_length", 4); assert_ended("a length below the step")
  pattern_clock_stop()
  -- the wrap, with the voice's only set step turned off
  params:set("v1_seq_length", 16)
  pattern_clock_start()
  for _ = 1, 4 do context.clock.advance_until(S.pattern_clocks[1]) end
  playing("step 5 again")
  toggle_pattern_step(1, 5)
  context.clock.run_for(1.0)
  assert_equal(#note_calls(context, "noteOff", 0), 0, "before the wrap the chord holds")
  context.clock.run_for(1.0)
  assert_ended("the wrap")
  pattern_clock_stop()
  -- a chain link (between two of the voice's steps: three steps of 1/16)
  params:set("v1_seq_length", 3); clear_pattern(1); seq.set_step_attr(1, 5, "notes", nil); chord_step(1)
  capture_scene(3)
  params:set("seq_chain", 1); params:set("seq_chain_from", 3); params:set("seq_chain_scenes", 1)
  params:set("seq_chain_bars", 1)
  pattern_clock_start(); playing("the chain's first scene")
  context.clock.run_for(2.0 - 0.01)  -- step 1 again at beat 3.75 after the start
  context.clear_engine_calls()
  context.clock.run_for(0.02)        -- the bar: the link, and step 2 (empty)
  assert_ended("a chain link")
  pattern_clock_stop()
end)

test("every ratchet hit accents every chord note", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "notes", {0, 4})
  seq.set_step_attr(1, 1, "ratchet", 3)
  context.clear_engine_calls()
  pattern_clock_start()
  context.clock.run_for(0.12)  -- inside step 1 (0.125 s)
  local retriggers, ons = retriggers_of(context, 0), note_calls(context, "noteOn", 0)
  assert_equal(#retriggers, 3, "three retriggers, the first note's accents")
  assert_equal(#ons, 3, "three noteOns for the second note")
  for index, on in ipairs(ons) do assert_equal(on.args[2], 1, "hit " .. index .. ": its slot") end
  assert_true(first_call(context, "retrigger", 0) < first_call(context, "noteOn", 0), "after the retrigger")
  local starts, repeats = note_starts(context)
  assert_equal(starts[0], 1, "one node"); assert_equal(repeats[0], 2, "the later hits accent it")
  assert_equal(#context.calls_named("noteExpression"), 1, "one first expression")
  assert_equal(#context.calls_named("voiceOn"), 0, "no voiceOn")
  pattern_clock_stop()
end)

test("64 steps of chords with ratchets and locks create one node per extra note and none on a repeat", function()
  local context, S = buffer_voice_setup()  -- voice 1 on a buffer, voice 2 on its synth
  local seq = S.lib.sequencer
  for step = 1, 16 do
    S.patterns[1][step] = 15; S.patterns[2][step] = 10
    seq.set_step_attr(1, step, "notes", step % 2 == 1 and {0, 4, 7} or {0, 5})  -- the third note on odd steps
    seq.set_step_attr(2, step, "notes", {0, 3, 7})                              -- kept on every step
  end
  for step = 1, 16, 3 do
    seq.set_step_attr(1, step, "ratchet", 4)
    seq.set_step_attr(1, step, "pos", step / 16)
  end
  for step = 2, 16, 4 do
    seq.set_step_attr(2, step, "ratchet", 3)
    seq.set_step_attr(2, step, "pitch", 1.5)
  end
  context.clear_engine_calls()
  pattern_clock_start()
  context.clock.run_for(64 * 0.125 - 0.01)  -- 64 steps
  assert_equal(seq.sounding_step(1), 16, "four passes")
  local starts, repeats = note_starts(context)
  assert_equal(starts[0], 2 + 31, "voice 1: two notes, then its third note at each of 31 odd steps")
  assert_equal(starts[1], 2, "voice 2: its two extra notes, once")
  assert_true(repeats[0] > 64 and repeats[1] > 64, "every other hit accents its live notes")
  for engine_voice = 0, 1 do
    local expressions = 0
    for _, call in ipairs(context.calls_named("noteExpression")) do
      if call.args[1] == engine_voice then expressions = expressions + 1 end
    end
    assert_equal(expressions, starts[engine_voice], "voice " .. engine_voice + 1 .. ": an expression per node")
  end
  for _, call in ipairs(context.calls_named("noteOn")) do assert_true(call.args[2] > 0, "never slot 0") end
  assert_equal(#context.calls_named("voiceOn"), 0, "no voiceOn")
  assert_true(S.lib.notes.pool_used() <= S.lib.notes.pool(), "within the pool")
  pattern_clock_stop()
  assert_equal(S.lib.notes.pool_used(), 0, "the stop frees the pool")
end)

test("a chord on a voice MIDI holds plays wholly as extra notes", function()
  local context, S = setup()
  local seq, notes = S.lib.sequencer, S.lib.notes
  local freq = params:get("v1_freq")
  assert_equal(midi_note(S, 1, 60), 1, "MIDI holds slot 1")
  S.patterns[1][1] = 15; S.patterns[1][2] = 15
  seq.set_step_attr(1, 1, "notes", {0, 4})
  seq.set_step_attr(1, 1, "ratchet", 2)
  context.clear_engine_calls()
  pattern_clock_start()
  local ons = note_calls(context, "noteOn", 0)
  assert_equal(#ons, 2, "both notes extra")
  assert_equal(ons[1].args[2], 1); assert_equal(ons[2].args[2], 2)
  local pitch = 69 + 12 * math.log(freq / 440) / math.log(2)
  assert_near(ons[1].args[3], pitch, 1e-9, "the first on the voice's pitch")
  assert_near(ons[2].args[3], pitch + 4, 1e-9, "the second four semitones up")
  assert_equal(notes.find(1, "seq", 1), 2, "the first note in an extra slot")
  assert_equal(notes.find(1, "midi", held_key(1, 60)), 1, "MIDI keeps slot 1")
  assert_equal(last_sent(context, "setVoiceParam", 0, "freq"), nil, "no freq override")
  assert_near(S.lib.engine_sync.engine_base_value("v1_freq"), freq, 1e-9, "the stored freq")
  assert_equal(#retriggers_of(context, 0), 1, "the voice's retrigger")
  context.clear_engine_calls()
  context.clock.run_for(0.07)  -- the ratchet's second hit, 62.5 ms on
  ons = note_calls(context, "noteOn", 0)
  assert_equal(#ons, 2, "the second hit accents both")
  assert_equal(ons[1].args[2], 1); assert_equal(ons[2].args[2], 2)
  assert_equal(#context.calls_named("noteExpression"), 0, "no node")
  context.clear_engine_calls()
  context.clock.advance_until(S.pattern_clocks[1])  -- step 2, without notes
  local offs = note_calls(context, "noteOff", 0)
  assert_equal(#offs, 2, "both released")
  assert_equal(call_text(offs[1]), "noteOff(0, 1, 0)"); assert_equal(call_text(offs[2]), "noteOff(0, 2, 0)")
  assert_equal(notes.held(1), 1, "MIDI's note stays")
  assert_equal(last_sent(context, "setVoiceParam", 0, "freq"), nil, "and no freq is sent")
  pattern_clock_stop()
end)

test("a chord past the cap or the pool keeps its first notes", function()
  local context, S = setup()
  local seq, notes = S.lib.sequencer, S.lib.notes
  params:set("v1_freq", 440)
  params:set("v1_note_cap", 4)
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "notes", {0, 1, 2, 3, 4, 5, 6, 7})
  context.clear_engine_calls()
  pattern_clock_start()
  for key = 1, 8 do
    assert_equal(notes.find(1, "seq", key), key <= 4 and key or nil, "note " .. key)
  end
  assert_equal(#retriggers_of(context, 0), 1, "one retrigger")
  local freqs = 0
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 0 and call.args[2] == "freq" then freqs = freqs + 1 end
  end
  assert_equal(freqs, 1, "one freq: the first note's override")
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), 440, 1e-9)
  assert_equal(#note_calls(context, "noteOn", 0), 3, "three extra notes")
  pattern_clock_stop()
  -- a pool of 2 under a cap of 8
  params:set("v1_note_cap", 8)
  notes.set_pool(2)
  context.clear_engine_calls()
  pattern_clock_start()
  assert_equal(notes.find(1, "seq", 1), 1, "pool 2: the first note")
  for key = 2, 8 do
    assert_equal(notes.find(1, "seq", key) ~= nil, key <= 3, "pool 2: note " .. key .. (key <= 3 and " held" or " refused"))
  end
  assert_equal(#retriggers_of(context, 0), 1, "one retrigger")
  pattern_clock_stop()
end)

-- ruling 27: a chord's further notes are measured from its first note's base
test("an input voice's chord measures every note from the step's pitch lock", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  params:set("v1_source", S.constants.SOURCE_INPUT)
  params:set("v1_grain_pitch", 1)
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "pitch", 2)
  seq.set_step_attr(1, 1, "notes", {0, 7})
  context.clear_engine_calls()
  pattern_clock_start()
  assert_near(last_sent(context, "setGrainParam", 0, "pitchShift"), 2, 1e-9, "the first note: the lock")
  local ons = note_calls(context, "noteOn", 0)
  assert_equal(#ons, 1, "one extra note")
  assert_near(ons[1].args[5], 2 * 2 ^ (7 / 12), 1e-9, "the first note's rate times 2 ^ (7 / 12)")
  pattern_clock_stop()
end)

-- ruling 32: a chord's further notes take only free room, never a steal
-- (the review's first finding: the notes that had not fitted stole the
-- kept ones at the next step, once those were 0.05 s old)
test("a chord past the cap or the pool keeps its first notes at every step, ending and starting none after the first", function()
  for _, case in ipairs({
      {what = "pool 2", notes = {0, 2, 4, 5, 7}, held = 3, prepare = function(S) S.lib.notes.set_pool(2) end},
      {what = "note cap 4", notes = {0, 1, 2, 3, 4, 5, 6, 7}, held = 4,
        prepare = function() params:set("v1_note_cap", 4) end}}) do
    local context, S = setup()
    local seq, notes = S.lib.sequencer, S.lib.notes
    case.prepare(S)
    for step = 1, 3 do
      S.patterns[1][step] = 15
      seq.set_step_attr(1, step, "notes", case.notes)
    end
    local function assert_first_held(what)
      for key = 1, #case.notes do
        assert_equal(notes.find(1, "seq", key) ~= nil, key <= case.held,
          case.what .. ", " .. what .. ": note " .. key .. (key <= case.held and " held" or " not played"))
      end
    end
    pattern_clock_start()
    assert_first_held("step 1")
    for step = 2, 3 do
      context.clear_engine_calls()
      context.clock.advance_until(S.pattern_clocks[1])
      assert_equal(seq.sounding_step(1), step, case.what .. ": step " .. step .. " played")
      assert_first_held("step " .. step)
      assert_equal(#note_calls(context, "noteOff", 0), 0, case.what .. ", step " .. step .. ": no note ended")
      assert_equal(#note_calls(context, "noteExpression", 0), 0, case.what .. ", step " .. step .. ": no node started")
      assert_equal(#note_calls(context, "noteOn", 0), case.held - 1, case.what .. ", step " .. step .. ": the kept notes")
    end
    pattern_clock_stop()
  end
end)

-- ruling 32 (the review's second finding): a further note found slot 1
-- free once MIDI's own note parked, and took it as the voice's own
test("after MIDI lets go of a voice, a chord's further notes never take its slot 1", function()
  local context, S = setup()
  local seq, notes = S.lib.sequencer, S.lib.notes
  assert_equal(midi_note(S, 1, 60), 1, "MIDI holds slot 1")
  for step = 1, 3 do S.patterns[1][step] = 15 end
  seq.set_step_attr(1, 1, "notes", {0, 4})
  seq.set_step_attr(1, 2, "notes", {0, 4, 7}); seq.set_step_attr(1, 2, "ratchet", 2)
  seq.set_step_attr(1, 3, "notes", {0, 4, 7})
  local started_at = util.time()
  pattern_clock_start()
  assert_equal(notes.find(1, "seq", 1), 2, "the step's first note in an extra slot")
  midi_release(S, 1, 60)
  assert_equal(notes.slots(1)[1].parked, true, "MIDI's own note parks under the chord")
  -- step 2's two hits (0.125 s and 0.1875 s), then step 3 (0.25 s)
  for _, hit in ipairs({{"step 2", 0.15}, {"step 2's second hit", 0.2}, {"step 3", 0.28}}) do
    context.clear_engine_calls()
    context.clock.run_for(started_at + hit[2] - util.time())
    assert_equal(#retriggers_of(context, 0), 1, hit[1] .. ": one retrigger")
    assert_equal(last_sent(context, "setVoiceParam", 0, "freq"), nil, hit[1] .. ": no note override")
    for _, on in ipairs(note_calls(context, "noteOn", 0)) do
      assert_true(on.args[2] > 0, hit[1] .. ": no noteOn on slot 0")
    end
    local own = notes.slots(1)[1]
    assert_true(own.slot == 1 and own.owner == "midi" and own.parked, hit[1] .. ": slot 1 is MIDI's parked note")
  end
  assert_equal(notes.find(1, "seq", 3) ~= nil and notes.find(1, "seq", 3) > 1, true, "the third note an extra one")
  pattern_clock_stop()
end)

-- Ruling 35: a sequenced step never takes anything from another owner.
-- While MIDI holds a voice's slot 1, the step's first note is only an
-- extra note too: a free extra slot, or nothing

-- MIDI's notes on voice 1 as {slot, note (its key's), pitch, parked}, in slot order
local function midi_slots(S, voice_idx)
  local list = {}
  for _, used in ipairs(S.lib.notes.slots(voice_idx)) do
    if used.owner == "midi" then table.insert(list, used.slot .. ":" .. used.key % 128 .. ":" .. used.pitch
      .. (used.parked and ":parked" or "")) end
  end
  return table.concat(list, " ")
end

test("with MIDI on slot 1 at a note cap of 1, a noted step sends what a step without notes sends", function()
  local function first_hit(notes)
    local context, S = setup()
    params:set("v1_note_cap", 1)
    params:set("v1_seq_gate", 2)
    assert_equal(midi_note(S, 1, 60), 1, "MIDI holds slot 1")
    S.patterns[1][1] = 15
    if notes then S.lib.sequencer.set_step_attr(1, 1, "notes", notes) end
    context.clear_engine_calls()
    pattern_clock_start()
    local texts = call_texts(context)
    local midi = midi_slots(S, 1)
    local base = S.lib.engine_sync.engine_base_value("v1_freq")
    pattern_clock_stop()
    return texts, midi, base, params:get("v1_freq")
  end
  local plain = first_hit(nil)
  local noted, midi, base, stored = first_hit({3})
  assert_texts(noted, plain, "the gate and the retrigger, nothing more")
  assert_equal(midi, "1:60:60", "MIDI's note keeps slot 1 and its pitch")
  assert_near(base, stored, 1e-9, "no note override")
end)

test("a step's note never cuts another voice's MIDI note at a full pool", function()
  local context, S = setup()
  local seq, notes = S.lib.sequencer, S.lib.notes
  notes.set_pool(1)
  assert_equal(midi_note(S, 2, 60), 1); assert_equal(midi_note(S, 2, 64), 2, "voice 2's MIDI extra note fills the pool")
  assert_equal(midi_note(S, 1, 62), 1, "MIDI holds voice 1's slot 1")
  context.set_time(util.time() + 0.1)  -- every note old enough to steal
  for step = 1, 3 do S.patterns[1][step] = 15 end
  for step = 1, 3 do seq.set_step_attr(1, step, "notes", {0}) end
  context.clear_engine_calls()
  pattern_clock_start()
  assert_equal(#context.calls_named("noteOff"), 0, "nothing cut")
  assert_equal(notes.find(1, "seq", 1), nil, "the step's note refused")
  assert_equal(midi_slots(S, 2), "1:60:60 2:64:64", "voice 2's MIDI notes stand")
  assert_equal(midi_slots(S, 1), "1:62:62", "and voice 1's")
  -- MIDI lets go of voice 1: the next step's note is the voice's own, and
  -- the step after plays it again in place, reaching no steal either
  midi_release(S, 1, 62)
  context.clock.advance_until(S.pattern_clocks[1])
  assert_equal(notes.find(1, "seq", 1), 1, "step 2's note takes the free slot 1")
  context.clock.advance_until(S.pattern_clocks[1])  -- 0.125 s on: step 2's note is old enough to steal
  assert_equal(seq.sounding_step(1), 3, "step 3")
  assert_equal(notes.find(1, "seq", 1), 1, "step 3's note plays slot 1 again (branch 1)")
  assert_equal(#context.calls_named("noteOff"), 0, "nothing cut at any step")
  assert_equal(midi_slots(S, 2), "1:60:60 2:64:64", "voice 2's MIDI notes stand")
  pattern_clock_stop()
end)

test("a step's chord takes nothing in place from MIDI notes that fill the voice's cap", function()
  local context, S = setup()
  local seq, notes = S.lib.sequencer, S.lib.notes
  params:set("v1_note_cap", 3)
  for index, number in ipairs({60, 64, 67}) do assert_equal(midi_note(S, 1, number), index) end
  context.set_time(util.time() + 0.1)  -- every note old enough to steal
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "notes", {0, 4})
  context.clear_engine_calls()
  pattern_clock_start()
  for _, name in ipairs({"noteOn", "noteOff", "noteExpression"}) do
    assert_equal(#context.calls_named(name), 0, "no " .. name)
  end
  assert_equal(midi_slots(S, 1), "1:60:60 2:64:64 3:67:67", "MIDI's three notes stand, each at its pitch")
  assert_equal(#retriggers_of(context, 0), 1, "the step's retrigger")
  pattern_clock_stop()
end)

-- Ruling 55 (refining ruling 35): only a key physically down keeps the
-- voice's own note from the sequencer. Real MIDI on channel 1 (per voice,
-- note off auto: latch on a plain keyboard), so MIDI's key is 1 * 128 + note

local function midi_on(context, note) context.midi.send(1, {type = "note_on", note = note, vel = 100, ch = 1}) end
local function midi_off(context, note) context.midi.send(1, {type = "note_off", note = note, vel = 0, ch = 1}) end
local function midi_key(note) return 128 + note end

-- Every invariant holds now (the allocator's and MIDI's among them)
local function assert_invariants(what)
  local broken = h.check_invariants()
  assert_equal(#broken, 0, what .. ": every invariant holds (" .. table.concat(broken, "; ") .. ")")
end

-- 3.4's case: a latched MIDI note, then a pattern on the voice. At a note
-- cap of 1 and at a pool of 0 every step plays, on the voice's own note, as
-- 3.4's did: the step's note override and the retrigger, nothing else; MIDI
-- forgets its note, sending nothing
test("a latched MIDI note gives way to a pattern's steps at a note cap of 1 and a pool of 0 (ruling 55)", function()
  for _, case in ipairs({
      {"a note cap of 1", function() params:set("v1_note_cap", 1) end},
      {"a pool of 0", function(S) S.lib.notes.set_pool(0) end}}) do
    local context, S = setup()
    local seq, notes = S.lib.sequencer, S.lib.notes
    context.midi.plug(1, "keys")
    case[2](S)
    midi_on(context, 60); midi_off(context, 60)  -- latched: the key is up, the note sounds on
    assert_equal(notes.find(1, "midi", midi_key(60)), 1, case[1] .. ": MIDI's latched note holds slot 1")
    local stored = params:get("v1_freq")
    for step, semitones in ipairs({3, 5, 7}) do
      S.patterns[1][step] = 15
      seq.set_step_attr(1, step, "notes", {semitones})
    end
    context.clear_engine_calls()
    pattern_clock_start()
    for step, semitones in ipairs({3, 5, 7}) do
      local what = case[1] .. ", step " .. step
      if step > 1 then
        context.clear_engine_calls()
        context.clock.advance_until(S.pattern_clocks[1])
      end
      assert_equal(seq.sounding_step(1), step, what .. ": played")
      assert_equal(notes.find(1, "seq", 1), 1, what .. ": the step's note is the voice's own")
      assert_equal(notes.find(1, "midi", midi_key(60)), nil, what .. ": MIDI's latched note is forgotten")
      assert_near(last_sent(context, "setVoiceParam", 0, "freq"), stored * 2 ^ (semitones / 12), 1e-6,
        what .. ": its note override")
      assert_equal(#retriggers_of(context, 0), 1, what .. ": one retrigger")
      for _, name in ipairs({"noteOn", "noteOff", "noteExpression", "voiceOff"}) do
        assert_equal(#context.calls_named(name), 0, what .. ": no " .. name)
      end
      assert_invariants(what)
    end
    pattern_clock_stop()
  end
end)

-- A key held down through the steps keeps slot 1 (ruling 35 stands for
-- it): at a note cap of 1 the step's note is refused, at 8 it is an extra
-- note; lifted (latched) it gives way at the next step, where the step's
-- note leaves its extra slot for slot 1 (the reviewer's minor 1: it stayed
-- an extra note over the own note's drone)
test("a MIDI key held down keeps the voice's own note from the steps, and once lifted gives way at the next step", function()
  for _, cap in ipairs({1, 8}) do
    local context, S = setup()
    local seq, notes = S.lib.sequencer, S.lib.notes
    context.midi.plug(1, "keys")
    params:set("v1_note_cap", cap)
    local what = "note cap " .. cap
    midi_on(context, 60)  -- held
    local stored = params:get("v1_freq")
    for step = 1, 2 do
      S.patterns[1][step] = 15
      seq.set_step_attr(1, step, "notes", {3})
    end
    context.clear_engine_calls()
    pattern_clock_start()
    assert_equal(notes.find(1, "midi", midi_key(60)), 1, what .. ": the held key keeps slot 1")
    if cap == 1 then
      assert_equal(notes.find(1, "seq", 1), nil, what .. ": the step's note refused")
    else
      assert_equal(notes.find(1, "seq", 1), 2, what .. ": the step's note an extra note")
    end
    assert_equal(last_sent(context, "setVoiceParam", 0, "freq"), nil, what .. ": no note override")
    assert_invariants(what .. ", step 1")
    midi_off(context, 60)  -- latched
    context.clear_engine_calls()
    context.clock.advance_until(S.pattern_clocks[1])
    assert_equal(seq.sounding_step(1), 2, what .. ": step 2 played")
    assert_equal(notes.find(1, "seq", 1), 1, what .. ": step 2's note is the voice's own")
    assert_equal(notes.find(1, "midi", midi_key(60)), nil, what .. ": MIDI forgot its latched note")
    assert_near(last_sent(context, "setVoiceParam", 0, "freq"), stored * 2 ^ (3 / 12), 1e-6, what .. ": the note override")
    local offs = context.calls_named("noteOff")
    if cap == 1 then
      assert_equal(#offs, 0, what .. ": nothing to release")
    else
      assert_equal(#offs, 1, what .. ": the step's extra note released")
      assert_equal(call_text(offs[1]), "noteOff(0, 1, 0)", what .. ": its slot, released")
    end
    assert_equal(notes.held(1), 1, what .. ": the own note alone")
    assert_invariants(what .. ", step 2")
    pattern_clock_stop()
  end
end)

-- Ruling 54: the engine opens a gated voice's step gate at an extra note's
-- start (extraNoteOn), with no new command. A sequenced chord's further
-- notes ride the first note's retrigger as before: on a gated voice a chord
-- step sends the gate length, one retrigger, then each further note's
-- noteExpression and noteOn, and nothing more, at its first hit and at a
-- ratchet's later hit
test("on a gated voice a chord step sends its gate, one retrigger and its further notes, nothing more (ruling 54)", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  params:set("v1_freq", 220)
  params:set("v1_seq_gate", 2)
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "notes", {0, 4, 7})
  seq.set_step_attr(1, 1, "ratchet", 2)
  context.clear_engine_calls()
  pattern_clock_start()
  local names = {}
  for _, call in ipairs(context.engine_calls) do
    if call.args[1] == 0 and call.name ~= "setVoiceParam" and not (call.name == "setGrainParam" and call.args[2] == "scaleNote") then
      names[#names + 1] = call.name .. (call.name == "setGrainParam" and " " .. call.args[2] or "")
        .. ((call.name == "noteOn" or call.name == "noteExpression") and " " .. call.args[2] or "")
    end
  end
  assert_equal(table.concat(names, ", "), "setGrainParam gateSeconds, retrigger, noteExpression 1, noteOn 1, noteExpression 2, noteOn 2",
    "the first hit: the gate, one retrigger, the further notes")
  context.clear_engine_calls()
  context.clock.run_for(0.07)  -- the ratchet's second hit
  names = {}
  for _, call in ipairs(context.engine_calls) do
    if call.args[1] == 0 then names[#names + 1] = call.name .. (call.name == "noteOn" and " " .. call.args[2] or "") end
  end
  assert_equal(table.concat(names, ", "), "retrigger, noteOn 1, noteOn 2",
    "the later hit (its gate share unchanged, not resent): one retrigger, the further notes accented")
  pattern_clock_stop()
end)

-- The reviewer's minor 2: MIDI taking slot 1 from a step's note (branch 6,
-- the voice's cap full) plays MIDI's pitch at once, not the step's note
-- override until the next step
test("a MIDI note that takes the voice's own note from a step ends the step's note override", function()
  local context, S = setup()
  local seq, notes = S.lib.sequencer, S.lib.notes
  context.midi.plug(1, "keys")
  params:set("v1_note_cap", 1)
  params:set("v1_freq", 440)
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "notes", {3})
  pattern_clock_start()
  assert_equal(notes.find(1, "seq", 1), 1, "the step holds slot 1")
  assert_near(S.lib.engine_sync.engine_base_value("v1_freq"), 440 * 2 ^ (3 / 12), 1e-6, "at its note override")
  context.clear_engine_calls()
  midi_on(context, 62)
  assert_equal(notes.find(1, "midi", midi_key(62)), 1, "MIDI took slot 1")
  local midi_freq = 440 * 2 ^ ((62 - 69) / 12)
  assert_near(S.lib.engine_sync.engine_base_value("v1_freq"), midi_freq, 1e-6, "the voice plays MIDI's note")
  assert_near(last_sent(context, "setVoiceParam", 0, "freq"), midi_freq, 1e-6, "sent to the engine")
  assert_invariants("after MIDI's note")
  pattern_clock_stop()
end)

-- 3.7 (design §4.3): a buffer voice's pitch counts from its slot's file's
-- key, in the degree arithmetic and in every hit's pitches
test("a buffer voice's step pitches and degrees count from its file's key", function()
  local context, S = buffer_voice_setup()  -- voice 1 reads buffer 1
  local seq = S.lib.sequencer
  load_buffer(1, "/tmp/keyed.wav")  -- over the 8 s the setup gave the slot: its 0 s, then its audio
  context.polls.fire("bufferState", context.polls.buffer_state_value(1, 1, 0))
  context.polls.fire("bufferState", context.polls.buffer_state_value(1, 1, 8))
  assert_true(S.lib.samples.set(1, "key", 57))
  params:set("v1_buf_rate", 2)  -- 57 + 12 log2(2): note 69
  params:set("scale", 2)        -- a scale on: degrees are its tones (C major)
  -- 69 (A) is a tone of C major; the tone above it is 71 (B), below 67 (G)
  assert_near(seq.degree_semitones(1, 1), 2, 1e-9, "a degree up from 69")
  assert_near(seq.degree_semitones(1, -1), -2, 1e-9, "a degree down from 69")
  S.patterns[1][1], S.patterns[1][2] = 15, 15
  seq.set_step_attr(1, 2, "notes", {0, 2})  -- degrees: 69 and the tone two above it, 72
  local events = record_output(S, "probe")
  pattern_clock_start()
  context.clock.run_for(0.25)
  pattern_clock_stop()
  local hits = voice_events(events, 1)
  assert_list_near(hits[1].pitches, {69}, 1e-9, "a plain step: 57 at rate 2")
  assert_list_near(hits[2].pitches, {69, 72}, 1e-9, "a chord from 69 (from 72 without the key: 72, 76)")
end)

-- 3.6 (design §0.1): every hit's absolute pitches, for the targets
test("every hit's event carries its absolute pitches", function()
  local context, S = buffer_voice_setup()  -- voice 1 reads buffer 1
  local seq = S.lib.sequencer
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  params:set("v1_freq", 220)                                   -- note 57
  params:set("v2_source", S.constants.SOURCE_SYNTH + 1); params:set("v2_buf_rate", 2)  -- note 72
  params:set("v3_source", S.constants.SOURCE_INPUT)            -- grain pitch 1: note 60
  S.patterns[1][1], S.patterns[1][2], S.patterns[1][3], S.patterns[1][4] = 15, 15, 15, 15
  seq.set_step_attr(1, 2, "notes", {0, 4, 7}); seq.set_step_attr(1, 2, "ratchet", 2)
  seq.set_step_attr(1, 3, "notes", {0, 4, 7}); seq.set_step_attr(1, 3, "pitch", 2)
  seq.set_step_attr(1, 4, "pitch", 2)
  S.patterns[2][1] = 15
  S.patterns[3][1], S.patterns[3][2] = 15, 15
  seq.set_step_attr(3, 2, "pitch", 0.5); seq.set_step_attr(3, 2, "notes", {0, 3})
  local events = record_output(S, "probe")
  pattern_clock_start()
  context.clock.run_for(0.45)
  pattern_clock_stop()
  local hits = voice_events(events, 1)
  assert_equal(#hits, 5, "four steps, the second two hits")
  assert_list_near(hits[1].pitches, {57}, 1e-9, "a plain step: the voice's own pitch")
  assert_list_near(hits[2].pitches, {57, 61, 64}, 1e-9, "a chord")
  assert_list_near(hits[3].pitches, {57, 61, 64}, 1e-9, "each ratchet hit carries them")
  assert_true(hits[2].pitches ~= hits[3].pitches, "a copy per event")
  -- a synth voice's pitch lock of 2 (its grain pitch stands at 1): an octave up
  assert_list_near(hits[4].pitches, {69, 73, 76}, 1e-9, "a synth voice's chord under a pitch lock")
  assert_list_near(hits[5].pitches, {69}, 1e-9, "and its own pitch")
  assert_list_near(voice_events(events, 2)[1].pitches, {72}, 1e-9, "a buffer voice at rate 2")
  local input = voice_events(events, 3)
  assert_list_near(input[1].pitches, {60}, 1e-9, "an input voice at grain pitch 1")
  assert_list_near(input[2].pitches, {48, 51}, 1e-9, "an input voice's pitch lock moves its note")
end)

-- The review's ruling: on a synth or buffer voice a step's pitch lock (on
-- v<i>_grain_pitch, a ratio) moves every pitch by its distance from the
-- standing grain pitch, 12 x log2(lock / stored) semitones
local function locked_pitches(setup_voice, standing, lock_semitones, notes)
  local context, S = buffer_voice_setup()
  setup_voice(S)
  params:set("v1_grain_pitch", 2 ^ (standing / 12))
  S.patterns[1][1] = 15
  if lock_semitones then S.lib.sequencer.set_step_attr(1, 1, "pitch", 2 ^ (lock_semitones / 12)) end
  if notes then S.lib.sequencer.set_step_attr(1, 1, "notes", notes) end
  local events = record_output(S, "probe")
  context.clear_engine_calls()
  pattern_clock_start()
  pattern_clock_stop()
  return voice_events(events, 1)[1].pitches, context
end

local function synth_at_220(S)
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  params:set("v1_freq", 220)
end

local function buffer_at_rate_2(S)
  params:set("v1_buf_rate", 2)
end

test("a pitch lock moves a synth or buffer voice's pitches by its distance from the standing grain pitch", function()
  assert_list_near(locked_pitches(synth_at_220, 0, 7), {64}, 1e-9, "a plain step locked 7 up")
  assert_list_near(locked_pitches(synth_at_220, 3, 7), {61}, 1e-9, "from a standing grain pitch of 3: 4 up")
  assert_list_near(locked_pitches(synth_at_220, 3, nil), {57}, 1e-9, "unlocked: the standing pitch is not added")
  assert_list_near(locked_pitches(synth_at_220, 0, 7, {0, 4, 7}), {64, 68, 71}, 1e-9, "a chord moves whole")
  assert_list_near(locked_pitches(synth_at_220, 0, nil, {0, 4, 7}), {57, 61, 64}, 1e-9, "an unlocked chord")
  assert_list_near(locked_pitches(buffer_at_rate_2, 0, 7), {79}, 1e-9, "a buffer voice locked 7 up")
  assert_list_near(locked_pitches(buffer_at_rate_2, 3, 7, {0, 3}), {76, 79}, 1e-9, "its chord, from grain pitch 3")
end)

-- What the voices output sent for a locked chord step on a synth voice and
-- a locked plain step on a buffer voice before the ruling (recorded from
-- the code before step_pitches took the lock): the ruling moves only the
-- events' pitches
test("a locked step's engine calls are as before the pitch lock reached the pitches", function()
  local function sent(context)
    local texts = {}
    for _, call in ipairs(context.engine_calls) do
      local args = {}
      for index, value in ipairs(call.args) do
        args[index] = type(value) == "number" and string.format("%.4f", value) or tostring(value)
      end
      texts[#texts + 1] = call.name .. "(" .. table.concat(args, ",") .. ")"
    end
    return table.concat(texts, " ")
  end
  local _, synth = locked_pitches(synth_at_220, 3, 7, {0, 4, 7})
  assert_equal(sent(synth), table.concat({
    "setGrainParam(0.0000,pitchShift,1.4983)", "setVoiceParam(0.0000,freq,220.0000)",
    "setGrainParam(0.0000,scaleNote,57.0000)", "retrigger(0.0000,1.0000)",
    "noteExpression(0.0000,1.0000,1.0000,1.0000,0.0000,0.0000,0.0000)",
    "noteOn(0.0000,1.0000,61.0000,277.1826,1.0595,1.0000)",
    "noteExpression(0.0000,2.0000,1.0000,1.0000,0.0000,0.0000,0.0000)",
    "noteOn(0.0000,2.0000,64.0000,329.6276,1.2599,1.0000)",
    "noteOff(0.0000,1.0000,0.0000)", "noteOff(0.0000,2.0000,0.0000)", "setVoiceParam(0.0000,freq,220.0000)",
    "setGrainParam(0.0000,scaleNote,57.0000)", "setGrainParam(0.0000,pitchShift,1.1892)",
  }, " "), "a synth voice's locked chord: the lock's grain pitch, the chord at its own notes")
  local _, buffer = locked_pitches(buffer_at_rate_2, 0, 7)
  assert_equal(sent(buffer), "setGrainParam(0.0000,pitchShift,1.4983) retrigger(0.0000,1.0000) "
    .. "setGrainParam(0.0000,pitchShift,1.0000)", "a buffer voice's locked step")
end)

test("an output cannot change what another output or the next hit gets", function()
  -- what the voices output sends for a chord step with two hits, then a plain step
  local function run(empties)
    local context, S = setup()
    local seq = S.lib.sequencer
    params:set("v1_freq", 220)
    S.patterns[1][1], S.patterns[1][2] = 15, 15
    seq.set_step_attr(1, 1, "notes", {0, 4, 7}); seq.set_step_attr(1, 1, "ratchet", 2)
    if empties then
      -- an output that plays before the voices output, as one included
      -- earlier would, and empties the first hit's pitches
      local emptied = false
      table.insert(S.registry.step_outputs, 1, {name = "emptier", play = function(event)
        if emptied then return end
        emptied = true
        for index = #event.pitches, 1, -1 do event.pitches[index] = nil end
      end})
    end
    local seen = {}
    S.register_step_output({name = "after", play = function(event) table.insert(seen, #event.pitches) end})
    context.clear_engine_calls()
    pattern_clock_start()
    context.clock.run_for(0.2)
    pattern_clock_stop()
    local sent = {}
    for _, call in ipairs(context.engine_calls) do
      local args = {}
      for index, value in ipairs(call.args) do args[index] = tostring(value) end
      table.insert(sent, call.name .. "(" .. table.concat(args, ", ") .. ")")
    end
    return table.concat(sent, " "), seen
  end
  local plain = run(false)
  local emptied, seen = run(true)
  assert_equal(emptied, plain, "the voices output sends what it sent without it")
  assert_equal(table.concat(seen, " "), "0 3 1", "the emptied hit's own; the next hits' are whole")
end)

-- 3.7 (design §5.1, §5.4, §5.5): trig conditions, directions, misstep and
-- the chain's chance. A 1/16 step is 0.125 s at the stub's 120 BPM

-- Voice 1 alone set: its length and every one of its steps 1..length at 15
local function voice_1_only(S, length)
  for voice_idx = 1, 7 do
    for step = 1, 16 do S.patterns[voice_idx][step] = 0 end
  end
  for step = 1, length do S.patterns[1][step] = 15 end
  params:set("v1_seq_length", length)
end

-- The steps a voice's first hits played, as a string
local function played_steps(events, voice_idx)
  local steps = {}
  for _, event in ipairs(voice_events(events, voice_idx or 1, true)) do steps[#steps + 1] = event.step end
  return table.concat(steps, " ")
end

-- Run steps 1/16 steps from now (the first plays at once at a start)
local function run_steps(context, steps) context.clock.run_for(steps * 0.125 - 0.01) end

-- math.random replaced by one that counts its calls (each call's entry is
-- what fn returns, or true) and returns real draws; returns the calls and
-- a function that puts the real one back
local function counting_random(fn)
  local real, calls = math.random, {}
  math.random = function(...)
    calls[#calls + 1] = fn and fn() or true
    return real(...)
  end
  return calls, function() math.random = real end
end

test("a step with a condition plays only when it holds, and its probability is drawn only then", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  voice_1_only(S, 4)
  for step = 2, 4 do S.patterns[1][step] = 0 end
  seq.set_step_attr(1, 1, "cond", "1:2")
  seq.set_step_attr(1, 1, "prob", 50)
  local events = record_output(S, "probe")
  math.randomseed(1)
  local calls, restore = counting_random(function() return S.lib.conditions.pass(1) end)
  pattern_clock_start()
  run_steps(context, 32)  -- 8 passes of 4 steps
  pattern_clock_stop()
  restore()
  assert_equal(#calls, 4, "one draw on each odd pass")
  for _, pass in ipairs(calls) do assert_equal(pass % 2, 1, "drawn on pass " .. pass .. ": an odd one") end
  assert_true(#voice_events(events, 1, true) <= 4, "it plays only on odd passes")
  seq.set_step_attr(1, 1, "prob", nil)
  clear_list(events)
  pattern_clock_start(); run_steps(context, 32); pattern_clock_stop()
  assert_equal(#voice_events(events, 1, true), 4, "1:2 at 100%: passes 1, 3, 5 and 7")
end)

test("pre and nei follow the last conditioned step, played or not", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  voice_1_only(S, 2)
  for step = 1, 2 do S.patterns[2][step] = 15 end
  params:set("v2_seq_length", 2)
  seq.set_step_attr(1, 1, "cond", "first")  -- plays on pass 1 only
  seq.set_step_attr(1, 2, "cond", "pre")    -- after it: plays only when step 1 played
  seq.set_step_attr(2, 2, "cond", "nei")    -- voice 1's latest outcome (on this beat step 1's and 2's agree)
  local events = record_output(S, "probe")
  pattern_clock_start(); run_steps(context, 8)
  assert_equal(S.lib.conditions.outcome(1), false, "voice 1's last outcome: a miss")
  pattern_clock_stop()
  assert_equal(S.lib.conditions.outcome(1), nil, "a stop forgets it")
  assert_equal(played_steps(events, 1), "1 2", "pass 1: first, then pre; later passes neither")
  assert_equal(played_steps(events, 2), "1 2 1 1 1", "voice 2's nei step plays on pass 1 only")
  -- prob 0 is a conditioned step that never plays: its miss is the outcome
  seq.set_step_attr(1, 1, "cond", nil); seq.set_step_attr(1, 1, "prob", 0)
  seq.set_step_attr(1, 2, "cond", "!pre")
  clear_list(events)
  pattern_clock_start(); run_steps(context, 4); pattern_clock_stop()
  assert_equal(played_steps(events, 1), "2 2", "!pre after a miss plays")
end)

test("no draw is made at forward with no misstep and no condition", function()
  local context, S = setup()
  for step = 1, 16 do S.patterns[1][step] = 15 end
  local calls, restore = counting_random()
  pattern_clock_start(); run_steps(context, 64); pattern_clock_stop()
  restore()
  assert_equal(#calls, 0, "64 steps of a plain pattern draw nothing")
end)

local DIRECTION = {forward = 1, reverse = 2, ["ping-pong"] = 3, random = 4}

test("each direction's order over a length of 4", function()
  local context, S = setup()
  voice_1_only(S, 4)
  local events = record_output(S, "probe")
  local function order(direction, steps)
    params:set("v1_seq_direction", DIRECTION[direction])
    clear_list(events)
    pattern_clock_start(); run_steps(context, steps); pattern_clock_stop()
    return played_steps(events)
  end
  assert_equal(params:string("v1_seq_direction"), "forward", "the default")
  assert_equal(order("forward", 5), "1 2 3 4 1")
  assert_equal(order("reverse", 5), "4 3 2 1 4")
  assert_equal(order("ping-pong", 8), "1 2 3 4 3 2 1 2")
  math.randomseed(1)
  local expected = {}
  for index = 1, 8 do expected[index] = math.random(4) end
  math.randomseed(1)
  assert_equal(order("random", 8), table.concat(expected, " "), "random: seed 1's eight draws of 1..4")
  voice_1_only(S, 1)
  for direction in pairs(DIRECTION) do
    assert_equal(order(direction, 4), "1 1 1 1", direction .. " with a length of 1 plays 1")
  end
end)

-- The steps taken (1 at the start) at which voice 1 played step, as a string
local function taken_at(events, started_at, step)
  local taken = {}
  for _, event in ipairs(voice_events(events, 1, true)) do
    if event.step == step then taken[#taken + 1] = math.floor((event.time - started_at) / 0.125 + 0.5) + 1 end
  end
  return table.concat(taken, " ")
end

test("a pass ends after the length in three directions and at each end in ping-pong", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  voice_1_only(S, 4)
  seq.set_step_attr(1, 1, "cond", "1:2")
  local events = record_output(S, "probe")
  local function run(direction)
    params:set("v1_seq_direction", DIRECTION[direction])
    clear_list(events)
    local started_at = util.time()
    pattern_clock_start(); run_steps(context, 20); pattern_clock_stop()
    return started_at
  end
  local started_at = run("forward")
  assert_equal(taken_at(events, started_at, 1), "1 9 17", "forward: passes 1, 3 and 5")
  started_at = run("reverse")
  assert_equal(taken_at(events, started_at, 1), "4 12 20", "reverse: step 1 ends passes 1, 3 and 5")
  -- ping-pong: passes end at steps taken 4, 7, 10, 13, 16, 19; step 1 is
  -- taken at 1 (pass 1), 7 (2), 13 (4), 19 (6), step 4 at 4 (1), 10 (3), 16 (5)
  seq.set_step_attr(1, 4, "cond", "1:2")
  started_at = run("ping-pong")
  assert_equal(taken_at(events, started_at, 1), "1", "ping-pong: step 1 only on pass 1, the odd one")
  assert_equal(taken_at(events, started_at, 4), "4 10 16", "step 4 on passes 1, 3 and 5")
end)

test("a misstep moves one step either way with its chance", function()
  local context, S = setup()
  voice_1_only(S, 4)
  params:set("v1_seq_misstep", 100)
  local events = record_output(S, "probe")
  math.randomseed(1)
  pattern_clock_start(); run_steps(context, 24); pattern_clock_stop()
  local steps = voice_events(events, 1, true)
  assert_equal(#steps, 24)
  assert_equal(steps[1].step, 1, "the first step is the direction's")
  local ups, downs = 0, 0
  for index = 2, #steps do
    local move = (steps[index].step - steps[index - 1].step) % 4
    assert_true(move == 1 or move == 3, "step " .. index .. " is the last one +1 or -1 (wrapping)")
    if move == 1 then ups = ups + 1 else downs = downs + 1 end
  end
  assert_true(ups > 0 and downs > 0, "both ways")
  -- at 0 no draw is made
  params:set("v1_seq_misstep", 0)
  local calls, restore = counting_random()
  pattern_clock_start(); run_steps(context, 8); pattern_clock_stop()
  restore()
  assert_equal(#calls, 0, "misstep 0 draws nothing")
end)

-- Voice 1 alone, length 4, in direction, a condition on every step, started
-- at once after a seed. Returns the context, S and the time of the start
local function skip_setup(direction)
  local context, S = setup()
  voice_1_only(S, 4)
  params:set("v1_seq_direction", DIRECTION[direction])
  for step = 1, 4 do S.lib.sequencer.set_step_attr(1, step, "cond", "1:2") end
  math.randomseed(3)
  local started_at = util.time()
  pattern_clock_start()
  return context, S, started_at
end

test("skipped ticks advance the order and the pass count and test nothing", function()
  for _, direction in ipairs({"reverse", "random"}) do
    local context, S, started_at = skip_setup(direction)
    context.clock.run_for(0.6)
    local tests, records = 0, 0
    local conditions = S.lib.conditions
    local real_test, real_record = conditions.test, conditions.record
    conditions.test = function(...) tests = tests + 1; return real_test(...) end
    conditions.record = function(...) records = records + 1; return real_record(...) end
    local delivered_at
    context.clock.advance_until(S.pattern_clocks[1], function()
      context.set_time(util.time() + 1.0)  -- two beats late
      delivered_at = util.time()
    end)
    conditions.test, conditions.record = real_test, real_record
    assert_equal(tests, 1, direction .. ": the woken step is tested, the skipped ones are not")
    assert_equal(records, 1, direction .. ": and only it records")
    local held = {step = S.lib.sequencer.sounding_step(1), pass = conditions.pass(1)}
    pattern_clock_stop()
    -- the same run, uninterrupted, at the same moment
    local other, other_S = skip_setup(direction)
    other.clock.run_for(delivered_at - started_at + 0.01)
    assert_equal(held.step, other_S.lib.sequencer.sounding_step(1), direction .. ": the position")
    assert_equal(held.pass, other_S.lib.conditions.pass(1), direction .. ": the pass")
    pattern_clock_stop()
  end
end)

test("a start, a restart and a division reset put a voice back on pass 1; a chain link does not", function()
  local context, S = setup()
  local conditions = S.lib.conditions
  voice_1_only(S, 4)
  pattern_clock_start(); run_steps(context, 9)
  assert_equal(conditions.pass(1), 3, "nine steps of four: pass 3")
  pattern_clock_start()
  assert_equal(conditions.pass(1), 1, "a start")
  run_steps(context, 9)
  S.lib.sequencer.restart_voice(1, clock.get_beats())
  assert_equal(conditions.pass(1), 1, "a restart")
  run_steps(context, 5)
  assert_equal(conditions.pass(1), 2, "five steps after it: pass 2")
  params:set("seq_division_reset", 1)  -- the bar: 2 s after the start, 0.27 s from now
  context.clock.run_for(0.25)
  assert_equal(conditions.pass(1), 2, "before the bar")
  context.clock.run_for(0.05)
  assert_equal(conditions.pass(1), 1, "the division reset's bar puts it back on pass 1")
  pattern_clock_stop()
  assert_equal(conditions.pass(1), 1, "a stop too")
  -- a chain link keeps the pass
  capture_scene(1); capture_scene(2)
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 2)
  params:set("seq_chain_bars", 1)
  pattern_clock_start()
  context.clock.run_for(2.0 - 0.01)
  assert_equal(conditions.pass(1), 4, "a bar: four passes of four")
  context.clock.run_for(0.02)
  assert_equal(conditions.pass(1), 5, "the link at the bar keeps counting")
  pattern_clock_stop()
end)

test("a scene with a condition outside the 78 is refused", function()
  local _, S = setup()
  local seq = S.lib.sequencer
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "cond", "3:5")
  assert_equal(seq.step_attr(1, 1, "cond"), "3:5")
  seq.set_step_attr(1, 1, "cond", "6:5")
  assert_equal(seq.step_attr(1, 1, "cond"), "3:5", "set_step_attr refuses one outside the 78")
  capture_scene(1)
  assert_true(validate_scene(S.scenes[1]), "a captured condition validates")
  local stored = S.scenes[1].data.steps[1][1]
  for _, bad in ipairs({"9:9", "1:1", "!0:2", "last", 3, {}}) do
    stored.cond = bad
    assert_true(not validate_scene(S.scenes[1]), "rejected: " .. tostring(bad))
  end
  stored.cond = "!nei"
  assert_true(validate_scene(S.scenes[1]), "a named one validates")
end)

test("a chain link carries direction and misstep, and picks by the three chances", function()
  local context, S = setup()
  local chance = S.lib.chance
  for scene = 1, 3 do
    voice_1_only(S, 4)
    S.patterns[1][1] = scene  -- each scene's mark: step 1's level
    params:set("v1_seq_direction", scene == 2 and DIRECTION.reverse or DIRECTION.forward)
    params:set("v1_seq_misstep", scene == 2 and 30 or 0)
    capture_scene(scene)
  end
  S.patterns[1][1] = 9
  params:set("v1_seq_direction", DIRECTION.forward); params:set("v1_seq_misstep", 0)
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 3)
  params:set("seq_chain_bars", 1)
  assert_equal(params:get("seq_chain_next"), 100, "next 100 by default")
  assert_equal(params:get("seq_chain_previous"), 0)
  assert_equal(params:get("seq_chain_random"), 0)
  -- every pick runs with a math.random that raises
  local real_pick, picks = chance.pick, {}
  chance.pick = function(current, slots, chances, random)
    local real_random = math.random
    math.random = function() error("a draw was made") end
    local ran, slot, move = pcall(real_pick, current, slots, chances, random)
    math.random = real_random
    if not ran then error(slot, 0) end
    picks[#picks + 1] = {slots = table.concat(slots, " "), chances = table.concat(chances, " ")}
    return slot, move
  end
  -- step 1's level now, then after each of bars bars
  local function marks(bars)
    local seen = {S.patterns[1][1]}
    for _ = 1, bars do
      context.clock.run_for(2.0)
      seen[#seen + 1] = S.patterns[1][1]
    end
    return table.concat(seen, " ")
  end
  pattern_clock_start(); context.clock.run_for(0.01)
  assert_equal(marks(1), "1 2", "100, 0, 0: in order")
  assert_equal(params:get("v1_seq_direction"), DIRECTION.reverse, "the link carries the direction")
  assert_equal(params:get("v1_seq_misstep"), 30, "and the misstep")
  assert_equal(marks(2), "2 3 1", "then on, past the range's last")
  assert_equal(picks[1].slots, "1 2 3", "the populated slots of the range, in order")
  assert_equal(picks[1].chances, "100 0 0")
  pattern_clock_stop()
  params:set("seq_chain_next", 0); params:set("seq_chain_previous", 100)
  pattern_clock_start(); context.clock.run_for(0.01)
  assert_equal(marks(2), "1 3 2", "0, 100, 0: a start loads the first, then backward")
  params:set("seq_chain_previous", 0)
  local replaced = 0
  local real_replace = S.lib.sequencer.replace_pattern
  S.lib.sequencer.replace_pattern = function(...) replaced = replaced + 1; return real_replace(...) end
  assert_equal(marks(2), "2 2 2", "0, 0, 0: the same scene stays")
  S.lib.sequencer.replace_pattern = real_replace
  assert_equal(replaced, 0, "and nothing is replaced")
  pattern_clock_stop()
  chance.pick = real_pick
end)

-- Scenes 1-4 of a chain over 1-4 (each scene's mark: voice 1's step 1 at
-- the scene's number), playing, the chain at 1 bar; returns step 1's level
-- now, then after each of bars bars
local function chain_of_four(context, S, chances)
  for scene = 1, 4 do
    voice_1_only(S, 4)
    S.patterns[1][1] = scene
    capture_scene(scene)
  end
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 4)
  params:set("seq_chain_bars", 1)
  params:set("seq_chain_next", chances[1]); params:set("seq_chain_previous", chances[2])
  params:set("seq_chain_random", chances[3])
  return function(bars)
    local seen = {S.patterns[1][1]}
    for _ = 1, bars do
      context.clock.run_for(2.0)
      seen[#seen + 1] = S.patterns[1][1]
    end
    return table.concat(seen, " ")
  end
end

-- Run the chain to scene 3 (in order), then clear scene 3 while it plays
local function at_cleared_three(context, S)
  local real = {params:get("seq_chain_next"), params:get("seq_chain_previous"), params:get("seq_chain_random")}
  params:set("seq_chain_next", 100); params:set("seq_chain_previous", 0); params:set("seq_chain_random", 0)
  pattern_clock_start(); context.clock.run_for(4.01)  -- scenes 1, 2, 3
  assert_equal(S.patterns[1][1], 3, "the chain plays scene 3")
  S.scenes[3].populated = false
  params:set("seq_chain_next", real[1]); params:set("seq_chain_previous", real[2])
  params:set("seq_chain_random", real[3])
end

-- Ruling 29: a cleared playing scene is no longer in the list, so the chain
-- goes on to the next saved one in its range with no draw, as the scene
-- sequencer does; the chances apply from there
test("a cleared playing scene goes on to the next saved one with no draw", function()
  local context, S = setup()
  local marks = chain_of_four(context, S, {100, 0, 0})
  at_cleared_three(context, S)
  assert_equal(marks(2), "3 4 1", "the defaults: on to 4, then 1")
  pattern_clock_stop()
  -- previous at 100: on to 4 first, then backward
  context, S = setup()
  marks = chain_of_four(context, S, {0, 100, 0})
  at_cleared_three(context, S)
  assert_equal(marks(4), "3 4 2 1 4", "previous: on to 4 with no draw, then 2, 1, around to 4, past the empty 3")
  pattern_clock_stop()
  -- random at 100: on to 4, with no draw
  context, S = setup()
  marks = chain_of_four(context, S, {0, 0, 100})
  at_cleared_three(context, S)
  local real_random = math.random
  local draws = 0
  math.random = function() draws = draws + 1; return 0.5 end
  local seen = marks(1)
  math.random = real_random
  assert_equal(seen, "3 4", "random: on to 4")
  assert_equal(draws, 0, "no draw from a cleared scene")
  -- with 4 cleared too, on to 1, with no draw
  S.scenes[4].populated = false
  draws = 0
  math.random = function() draws = draws + 1; return 0.99 end
  seen = marks(1)
  math.random = real_random
  assert_equal(seen, "4 1", "4 and 3 empty: on to 1")
  assert_equal(draws, 0, "with no draw")
  pattern_clock_stop()
end)

test("random picks among the range's saved scenes, empty slots aside", function()
  -- a range of 8 with 1, 5 and 8 saved (marks 1, 5, 8), playing 1: random's
  -- one draw is among 5 and 8, never an empty slot walked on from
  local context, S = setup()
  for scene = 1, 8 do
    voice_1_only(S, 4)
    S.patterns[1][1] = scene
    capture_scene(scene)
    if scene ~= 1 and scene ~= 5 and scene ~= 8 then S.scenes[scene].populated = false end
  end
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 8)
  params:set("seq_chain_bars", 1)
  params:set("seq_chain_next", 0); params:set("seq_chain_previous", 0); params:set("seq_chain_random", 100)
  pattern_clock_start(); context.clock.run_for(0.01)
  assert_equal(S.patterns[1][1], 1, "the start loads scene 1")
  local real_random, draws = math.random, 0
  math.random = function() draws = draws + 1; return 0.5 end  -- the second of {5, 8}
  context.clock.run_for(2.0)
  math.random = real_random
  assert_equal(S.patterns[1][1], 8, "the draw's half lands on 8, the second saved scene")
  assert_equal(draws, 1, "one draw")
  pattern_clock_stop()
end)

test("a start links the range's first scene; the chances apply from the next link", function()
  -- scene 1 empty: the range's first populated scene is 2
  for _, case in ipairs({{{0, 100, 0}, "2 4 3"}, {{0, 0, 0}, "2 2 2"}, {{100, 0, 0}, "2 3 4"}}) do
    local context, S = setup()
    local marks = chain_of_four(context, S, case[1])
    S.scenes[1].populated = false
    S.patterns[1][1] = 9
    pattern_clock_start(); context.clock.run_for(0.01)
    assert_equal(marks(2), case[2], table.concat(case[1], ", ") .. ": the start at 2, then the chances")
    pattern_clock_stop()
  end
end)

test("a link validates no scene it has checked before", function()
  local context, S = setup()
  for scene = 1, 16 do
    voice_1_only(S, 4)
    S.patterns[1][1] = scene % 15 + 1
    capture_scene(scene)
  end
  params:set("seq_chain", 1); params:set("seq_chain_from", 1); params:set("seq_chain_scenes", 16)
  params:set("seq_chain_bars", 1)
  local real_validate, validations = validate_scene, 0
  validate_scene = function(...) validations = validations + 1; return real_validate(...) end
  pattern_clock_start()
  local at_start = validations
  context.clock.run_for(2.01)
  local at_link = validations - at_start
  validate_scene = real_validate
  pattern_clock_stop()
  assert_equal(at_start, 0, "the start validates nothing: each scene was checked at its capture")
  assert_equal(at_link, 0, "nor does a link over a full range of 16")
  -- a scene written into its slot from outside lib/scenes.lua (a fresh
  -- table) is checked once, by the draw that first meets it, and left out
  pattern_clock_start()
  S.scenes[2] = h.deep_copy(S.scenes[2])
  S.scenes[2].data.steps[1][1] = {cond = "9:9"}
  validations = 0
  validate_scene = function(...) validations = validations + 1; return real_validate(...) end
  context.clock.run_for(2.01)
  validate_scene = real_validate
  assert_equal(S.patterns[1][1], 4, "scene 2 is invalid: scene 3 (its mark 4) links")
  assert_equal(validations, 1, "one validation: the fresh table's")
  pattern_clock_stop()
end)

test("previous past an invalid scene goes on backward, validating only a table it has not seen", function()
  local context, S = setup()
  local marks = chain_of_four(context, S, {100, 0, 0})
  pattern_clock_start(); context.clock.run_for(4.01)  -- scenes 1, 2, 3
  assert_equal(S.patterns[1][1], 3, "the chain plays scene 3")
  params:set("seq_chain_next", 0); params:set("seq_chain_previous", 100)
  S.scenes[2] = h.deep_copy(S.scenes[2])
  S.scenes[2].data.steps[1][1] = {cond = "9:9"}
  local real_validate, validations = validate_scene, 0
  validate_scene = function(...) validations = validations + 1; return real_validate(...) end
  local seen = marks(1)
  validate_scene = real_validate
  assert_equal(seen, "3 1", "2 is invalid: previous goes on to 1")
  assert_equal(validations, 1, "one validation: the fresh table's")
  pattern_clock_stop()
end)

-- #738 (the groundwork's stepper): the chain draws among the range's
-- playable slots, populated and valid, so a random move never lands on an
-- invalid scene and never walks on from one. Scenes 1-4 (marks 1-4), 3
-- invalid on a fresh table, random at 100, playing 2: the draw is among 1
-- and 4
local function chain_at_two_with_three_invalid(context, S)
  local marks = chain_of_four(context, S, {100, 0, 0})
  pattern_clock_start(); context.clock.run_for(2.01)  -- scenes 1, 2
  assert_equal(S.patterns[1][1], 2, "the chain plays scene 2")
  S.scenes[3] = h.deep_copy(S.scenes[3])
  S.scenes[3].data.steps[1][1] = {cond = "9:9"}
  params:set("seq_chain_next", 0); params:set("seq_chain_random", 100)
  return marks
end

test("a chain move never lands on an invalid scene and never walks on from one (#738)", function()
  local real_random = math.random
  for _, case in ipairs({{0.5, "2 4", "the second half of {1, 4}"}, {0.0, "2 1", "the first"},
      {0.4, "2 1", "below the half: 1, where a walk on from 3 linked 4"}}) do
    local context, S = setup()
    local marks = chain_at_two_with_three_invalid(context, S)
    math.random = function() return case[1] end
    local seen = marks(1)
    math.random = real_random
    assert_equal(seen, case[2], "random at " .. case[1] .. ": " .. case[3])
    pattern_clock_stop()
  end
  -- over 50 seeded links (at seed 5 scenes 1 to 4 link 21, 16, 0 and 13
  -- times), 3 never plays and 4 is not favored, where the walk on from 3
  -- linked 4 about two times in three
  local context, S = setup()
  chain_at_two_with_three_invalid(context, S)
  math.randomseed(5)
  local counts = {0, 0, 0, 0}
  for _ = 1, 50 do
    context.clock.run_for(2.0)
    counts[S.patterns[1][1]] = counts[S.patterns[1][1]] + 1
  end
  pattern_clock_stop()
  assert_equal(counts[3], 0, "scene 3 never links")
  assert_true(counts[4] < 1.5 * counts[1], "4 is not favored: " .. table.concat(counts, " "))
  -- with only the playing scene playable, random keeps it: nothing is loaded again
  context, S = setup()
  local marks = chain_at_two_with_three_invalid(context, S)
  params:set("seq_chain_scenes", 2); params:set("seq_chain_from", 2)
  local replaced = 0
  local real_replace = S.lib.sequencer.replace_pattern
  S.lib.sequencer.replace_pattern = function(...) replaced = replaced + 1; return real_replace(...) end
  local seen = marks(2)
  S.lib.sequencer.replace_pattern = real_replace
  assert_equal(seen, "2 2 2", "range 2-3 with 3 invalid: 2 stays")
  assert_equal(replaced, 0, "and is never loaded again")
  pattern_clock_stop()
end)

-- 3.6's engine calls for 32 steps of voice 1 (forward, misstep 0, no
-- condition): a ratchet, a pitch and size lock, a three-note chord and a
-- position lock, recorded by running the same steps on main at 51ff1514
local CALLS_36 = {
  "retrigger(0, 1)", "retrigger(0, 1)", "setGrainParam(0, pitchShift, 1.5)", "setGrainParam(0, grainSize, 0.2)",
  "retrigger(0, 0.6)", "setGrainParam(0, pitchShift, 1)", "setGrainParam(0, grainSize, 0.1)",
  "setVoiceParam(0, freq, 100)", "setGrainParam(0, scaleNote, 43.35)", "retrigger(0, 0.8)",
  "noteExpression(0, 1, 1, 1, 0, 0, 0)", "noteOn(0, 1, 45.35, 112.2462, 0.429, 0.8)",
  "noteExpression(0, 2, 1, 1, 0, 0, 0)", "noteOn(0, 2, 47.35, 125.9921, 0.4816, 0.8)", "noteOff(0, 1, 0)",
  "noteOff(0, 2, 0)", "setVoiceParam(0, freq, 100)", "setGrainParam(0, scaleNote, 43.35)", "retrigger(0, 0.4)",
  "setGrainParam(0, bufPos, 0.3)", "retrigger(0, 1)", "setGrainParam(0, bufPos, 0)", "retrigger(0, 1)",
  "retrigger(0, 1)", "setGrainParam(0, pitchShift, 1.5)", "setGrainParam(0, grainSize, 0.2)", "retrigger(0, 0.6)",
  "setGrainParam(0, pitchShift, 1)", "setGrainParam(0, grainSize, 0.1)", "setVoiceParam(0, freq, 100)",
  "setGrainParam(0, scaleNote, 43.35)", "retrigger(0, 0.8)", "noteExpression(0, 3, 1, 1, 0, 0, 0)",
  "noteOn(0, 3, 45.35, 112.2462, 0.429, 0.8)", "noteExpression(0, 4, 1, 1, 0, 0, 0)",
  "noteOn(0, 4, 47.35, 125.9921, 0.4816, 0.8)", "noteOff(0, 3, 0)", "noteOff(0, 4, 0)",
  "setVoiceParam(0, freq, 100)", "setGrainParam(0, scaleNote, 43.35)", "retrigger(0, 0.4)",
  "setGrainParam(0, bufPos, 0.3)", "retrigger(0, 1)", "setGrainParam(0, bufPos, 0)",
}

test("a 3.6 pattern plays the same steps as before", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  local levels = {15, 0, 9, 0, 12, 0, 0, 6, 0, 0, 15, 0, 0, 0, 0, 0}
  for step = 1, 16 do S.patterns[1][step] = levels[step] end
  seq.set_step_attr(1, 1, "ratchet", 2)
  seq.set_step_attr(1, 3, "pitch", 1.5)
  seq.set_step_attr(1, 3, "size", 0.2)
  seq.set_step_attr(1, 5, "notes", {0, 2, 4})
  seq.set_step_attr(1, 11, "pos", 0.3)
  math.randomseed(1)
  context.clear_engine_calls()
  pattern_clock_start(); run_steps(context, 32); pattern_clock_stop()
  assert_equal(table.concat(call_texts(context), "\n"), table.concat(CALLS_36, "\n"), "every engine call, in order")
end)

test("a step skipped by its condition leaves the last played step's lock and note", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  voice_1_only(S, 3)
  seq.set_step_attr(1, 1, "pitch", 1.5)
  seq.set_step_attr(1, 1, "notes", {2})
  seq.set_step_attr(1, 2, "cond", "!first")  -- skipped on pass 1
  local function locked() return engine_param_value("v1_grain_pitch") end
  local function noted() return S.lib.notes.find(1, "seq", 1) ~= nil end
  pattern_clock_start()
  context.clock.run_for(0.125 + 0.01)  -- step 2, skipped
  assert_near(locked(), 1.5, 1e-9, "the skipped step leaves step 1's lock")
  assert_true(noted(), "and its note")
  context.clock.run_for(0.125)  -- step 3 plays, with neither
  assert_near(locked(), params:get("v1_grain_pitch"), 1e-9, "the next played step ends the lock")
  assert_true(not noted(), "and the note")
  pattern_clock_stop()
end)

test("a length change in reverse and in ping-pong", function()
  local context, S = setup()
  local events = record_output(S, "probe")
  local function run(direction, length, before, new_length, after)
    voice_1_only(S, length)
    params:set("v1_seq_direction", DIRECTION[direction])
    clear_list(events)
    pattern_clock_start(); run_steps(context, before)
    for step = 1, 16 do S.patterns[1][step] = 15 end
    params:set("v1_seq_length", new_length)
    context.clock.run_for(after * 0.125)
    pattern_clock_stop()
    return played_steps(events)
  end
  assert_equal(run("reverse", 8, 3, 4, 6), "8 7 6 5 4 3 2 1 4",
    "reverse: a shorter length fits the three steps taken: a pass of 4 ends at 5, then 4 down")
  assert_equal(run("reverse", 8, 5, 4, 8), "8 7 6 5 4 3 2 1 4 3 2 1 4",
    "reverse: one that does not fit waits for the pass's end")
  assert_equal(run("reverse", 4, 2, 8, 8), "4 3 2 1 8 7 6 5 8 7",
    "reverse: a longer one lengthens the pass at once: past 1 it goes on from the new length to 5, then starts at 8")
  assert_equal(run("ping-pong", 4, 3, 2, 5), "1 2 3 4 2 1 2 1",
    "ping-pong: past the new end the leg ends at its own top (#743), then turns at the new length")
  assert_equal(run("ping-pong", 2, 3, 4, 5), "1 2 1 2 3 4 3 2", "ping-pong: a longer one goes on up to it")
end)

-- #743: a shorter length applies at once while the leg can still turn at
-- it, else at the leg's turn, as reverse does (ruling 28): 8 to 4
test("a ping-pong pass finishes its leg before a shorter length (#743)", function()
  local context, S = setup()
  local events = record_output(S, "probe")
  local function run(length, before, new_length, after)
    voice_1_only(S, length)
    params:set("v1_seq_direction", DIRECTION["ping-pong"])
    clear_list(events)
    pattern_clock_start(); run_steps(context, before)
    for step = 1, 16 do S.patterns[1][step] = 15 end
    params:set("v1_seq_length", new_length)
    context.clock.run_for(after * 0.125)
    pattern_clock_stop()
    return played_steps(events)
  end
  assert_equal(run(8, 3, 4, 6), "1 2 3 4 3 2 1 2 3", "three steps up: the leg turns at 4")
  assert_equal(run(8, 5, 4, 6), "1 2 3 4 5 6 7 8 4 3 2", "five steps up, past 4: the leg ends at 8, then down from 4")
  assert_equal(run(8, 9, 4, 6), "1 2 3 4 5 6 7 8 7 6 5 4 3 2 1", "three steps down: the leg goes on down to 1")
  assert_equal(run(8, 11, 4, 6), "1 2 3 4 5 6 7 8 7 6 5 4 3 2 1 2 3", "five steps down: the same")
end)

test("a probability step's draws keep 3.6's order", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  local levels = {15, 0, 9, 0, 12, 6, 0, 3, 15, 0, 0, 8, 0, 11, 0, 5}
  for step = 1, 16 do S.patterns[1][step] = levels[step] end
  seq.set_step_attr(1, 5, "prob", 50)
  math.randomseed(1)
  -- as 3.6 plays it: forward, the 50% step drawn once a pass
  local expected = {}
  for _ = 1, 4 do
    for step = 1, 16 do
      local level = levels[step]
      if level > 0 and (step ~= 5 or math.random() * 100 < 50) then expected[#expected + 1] = level / 15 end
    end
  end
  math.randomseed(1)
  pattern_clock_start(); run_steps(context, 64)
  assert_true(S.lib.conditions.outcome(1) ~= nil, "the prob step is a conditioned one")
  pattern_clock_stop()
  local sent = {}
  for _, call in ipairs(retriggers_of(context, 0)) do sent[#sent + 1] = call.args[2] end
  assert_list_near(sent, expected, 1e-9, "voice 1's retriggers over 64 steps")
end)

-------------------------------------------------------------------------------
-- 3.7's slices on steps (design §3.5, §5.3, ruling 32; package 2b)
-------------------------------------------------------------------------------

-- Voice 1 (running) reading buffer 1: 2 s (96000 frames, its peaks read) cut
-- in count equal slices (default 4), v1_slices at option (1 off, 2 one, 3
-- overlap); a 120 BPM clock, so a 1/16 step is 0.125 s
local function sliced_setup(option, count)
  local context, S = setup()
  load_buffer(1, context.audio_dir .. "loop.wav")
  context.polls.fire("bufferState", context.polls.buffer_state_value(1, S.buffers[1].loads_sent, 2))
  local folder = S.lib.scenes.scene_data_dir
  util.make_dir(folder)
  local file = io.open(folder .. "buf1.peaks", "w")
  file:write("strata-peaks 1\nslot 1\nframes 96000\nrate 48000\ngeneration 1\npeaks " .. string.rep("0.500 ", 64) .. "\n")
  file:close()
  context.clock.run_for(2 / local_value("UI_PAGES").FRAMES_PER_SECOND + 0.001)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  S.lib.samples.set(1, "mode", 2); S.lib.samples.set(1, "count", count or 4)
  S.lib.slices.make(1)
  params:set("v1_slices", option)
  context.clear_engine_calls()
  return context, S
end

local function region_texts(context, engine_voice)
  local texts = {}
  for _, call in ipairs(context.engine_calls) do
    if (call.name == "setGrainParam" and call.args[1] == engine_voice and call.args[2]:find("^region"))
        or (call.name == "noteRegion" and call.args[1] == engine_voice) then
      table.insert(texts, call_text(call))
    end
  end
  return table.concat(texts, " ")
end

test("on a one voice a step's slice sets the own region for its hit, creates no node, and a chord shares it", function()
  for _, option in ipairs({2, 1}) do  -- one, then off: a step plays a slice as one does
    local context, S = sliced_setup(option)
    local seq = S.lib.sequencer
    S.patterns[1][1] = 15; S.patterns[1][2] = 15
    seq.set_step_attr(1, 1, "slice", 3)
    pattern_clock_start()
    local texts = call_texts(context)
    local region = first_call(context, "setGrainParam", 0)
    assert_equal(region_texts(context, 0), "setGrainParam(0, regionStart, 0.5) setGrainParam(0, regionLength, 0.25)",
      "option " .. option .. ": slice 3 on the own note")
    assert_true(region < first_call(context, "retrigger", 0), "before the hit")
    assert_equal(#note_calls(context, "noteOn", 0), 0, "no node: " .. table.concat(texts, " "))
    -- step 2 has no slice: the region ends
    context.clear_engine_calls()
    context.clock.advance_until(S.pattern_clocks[1])
    assert_equal(region_texts(context, 0), "setGrainParam(0, regionStart, 0) setGrainParam(0, regionLength, 0)",
      "a played step without a slice ends it")
    pattern_clock_stop()
  end
  -- a chord's further notes take the same region
  local context, S = sliced_setup(2)
  S.patterns[1][1] = 15
  S.lib.sequencer.set_step_attr(1, 1, "slice", 2)
  S.lib.sequencer.set_step_attr(1, 1, "notes", {0, 4})
  pattern_clock_start()
  assert_equal(region_texts(context, 0), "setGrainParam(0, regionStart, 0.25) setGrainParam(0, regionLength, 0.25) "
    .. "noteRegion(0, 1, 0.25, 0.25)", "the own note's, then the extra note's, before its noteOn")
  assert_true(first_call(context, "noteRegion", 0) < first_call(context, "noteOn", 0))
  pattern_clock_stop()
end)

-- The final review's I-2 (design §3.5, decision 23): an overlap voice's step
-- slice takes the own note first, as on one; while a step's slice still rings
-- there to its end the next step's slice plays in a slot of its own, with no
-- retrigger (the own note's slice is never restarted, and the own note never
-- plays the voice's whole loop under a slice); the own note takes the next
-- slice once its own has played out
test("on an overlap voice the own note takes a step's slice first and later slices ring in slots of their own", function()
  local context, S = sliced_setup(3)
  params:set("v1_scan_mode", 3); params:set("v1_buf_scan", 1.25)  -- one shot: a quarter of 2 s in 0.4 s
  local seq, notes = S.lib.sequencer, S.lib.notes
  for _, step in ipairs({1, 3, 5}) do S.patterns[1][step] = 15 end
  seq.set_step_attr(1, 1, "slice", 1); seq.set_step_attr(1, 3, "slice", 2); seq.set_step_attr(1, 5, "slice", 3)
  local function on_own(where, start)
    assert_equal(region_texts(context, 0), "setGrainParam(0, regionStart, " .. start .. ") setGrainParam(0, regionLength, 0.25)",
      where .. ": the slice on the own note")
    assert_true(first_call(context, "setGrainParam", 0) < first_call(context, "retrigger", 0), where .. ": before the hit")
    assert_equal(#note_calls(context, "noteOn", 0), 0, where .. ": no node")
  end
  pattern_clock_start()  -- step 1, at 0 s
  on_own("step 1", 0)
  context.clock.advance_until(S.pattern_clocks[1])
  context.clear_engine_calls()
  context.clock.advance_until(S.pattern_clocks[1])  -- step 3, at 0.25 s: slice 1 rings to 0.4 s
  assert_equal(region_texts(context, 0), "noteRegion(0, 1, 0.25, 0.25)", "step 3: slice 2 in an extra slot, the own region kept")
  assert_true(first_call(context, "noteRegion", 0) < first_call(context, "noteOn", 0), "its noteRegion before its noteOn")
  assert_equal(first_call(context, "retrigger", 0), nil, "no retrigger: slice 1 is not restarted")
  assert_equal(notes.own_region(1)[1], 0, "the own note still plays slice 1")
  assert_equal(notes.find(1, "seq", "slice3"), 2, "step 3's slice in slot 2")
  context.clock.advance_until(S.pattern_clocks[1])
  context.clear_engine_calls()
  context.clock.advance_until(S.pattern_clocks[1])  -- step 5, at 0.5 s: slice 1 has played out
  on_own("step 5", 0.5)
  assert_true(notes.find(1, "seq", "slice3") ~= nil, "step 3's slice rings on to 0.65 s")
  pattern_clock_stop()
  -- a ratchet of a step whose slice is in an extra slot hits that slice
  -- again in its slot, never the own note's
  context, S = sliced_setup(3)
  params:set("v1_scan_mode", 3); params:set("v1_buf_scan", 0.25)  -- one shot: each slice 2 s
  seq, notes = S.lib.sequencer, S.lib.notes
  S.patterns[1][1] = 15; S.patterns[1][2] = 15
  seq.set_step_attr(1, 1, "slice", 1); seq.set_step_attr(1, 2, "slice", 2); seq.set_step_attr(1, 2, "ratchet", 2)
  pattern_clock_start()
  context.clear_engine_calls()
  context.clock.run_for(0.125 + 0.0625 + 0.001)  -- step 2 and its second hit
  local slot = notes.find(1, "seq", "slice2")
  assert_true((slot or 1) > 1, "step 2's slice in an extra slot")
  assert_equal(first_call(context, "retrigger", 0), nil, "neither hit retriggers the own note")
  local ons = note_calls(context, "noteOn", 0)
  assert_equal(#ons, 2, "two noteOns: the slice's start and its ratchet")
  assert_equal(ons[2].args[2], slot - 1, "the ratchet in the slice's slot")
  pattern_clock_stop()
  -- the pool at 1: step 5's slice cuts step 3's, the oldest step slice in
  -- an extra slot, and takes its slot
  context, S = sliced_setup(3)
  params:set("v1_scan_mode", 3); params:set("v1_buf_scan", 0.25)
  seq, notes = S.lib.sequencer, S.lib.notes
  notes.set_pool(1)
  for _, step in ipairs({1, 3, 5}) do S.patterns[1][step] = 15 end
  seq.set_step_attr(1, 1, "slice", 1); seq.set_step_attr(1, 3, "slice", 2); seq.set_step_attr(1, 5, "slice", 3)
  pattern_clock_start()
  context.clock.advance_until(S.pattern_clocks[1]); context.clock.advance_until(S.pattern_clocks[1])
  local first_slot = notes.find(1, "seq", "slice3")
  assert_true((first_slot or 1) > 1, "step 3's slice in an extra slot")
  context.clear_engine_calls()
  context.clock.advance_until(S.pattern_clocks[1]); context.clock.advance_until(S.pattern_clocks[1])
  assert_equal(notes.find(1, "seq", "slice3"), nil, "step 3's slice cut")
  assert_equal(notes.find(1, "seq", "slice5"), first_slot, "step 5's in its slot")
  local texts = {}
  for _, call in ipairs(context.engine_calls) do
    if (call.name == "noteOff" or call.name == "noteRegion") and call.args[1] == 0 then table.insert(texts, call_text(call)) end
  end
  assert_equal(table.concat(texts, " "), "noteOff(0, " .. (first_slot - 1) .. ", 1) noteRegion(0, " .. (first_slot - 1)
    .. ", 0.5, 0.25)", "cut, then the slot's new region")
  assert_equal(notes.own_region(1)[1], 0, "the own note's slice 1 untouched")
  pattern_clock_stop()
  -- a MIDI note's slot is never taken
  context, S = sliced_setup(3)
  seq, notes = S.lib.sequencer, S.lib.notes
  notes.set_pool(1)
  S.patterns[1][1] = 15
  seq.set_step_attr(1, 1, "slice", 2)
  midi_note(S, 1, 60); midi_note(S, 1, 64)
  assert_equal(notes.pool_used(), 1, "MIDI holds the pool's one extra note")
  context.set_time(util.time() + 1)
  pattern_clock_start()
  assert_equal(notes.find(1, "seq", "slice1"), nil, "no room: the step's slice is refused")
  assert_true(notes.find(1, "midi", held_key(1, 64)) ~= nil, "MIDI's note plays on")
  pattern_clock_stop()
end)

-- #744: on an overlap voice, a step slice refused an extra slot while an
-- earlier slice rings on the own note takes the own note with its own slice,
-- as a voice set to one does, never restarting the ringing slice. Slices 1
-- (step 1) and 2 (step 3) in one shot, each 2 s long
local function refused_slice_setup(pool, ratchet)
  local context, S = sliced_setup(3)
  params:set("v1_scan_mode", 3); params:set("v1_buf_scan", 0.25)
  local seq, notes = S.lib.sequencer, S.lib.notes
  S.patterns[1][1] = 15; S.patterns[1][3] = 15
  seq.set_step_attr(1, 1, "slice", 1); seq.set_step_attr(1, 3, "slice", 2)
  if ratchet then seq.set_step_attr(1, 3, "ratchet", ratchet) end
  if pool == "full" then
    notes.set_pool(1)
    assert_true(S.voices[2].active, "voice 2 runs")
    midi_note(S, 2, 60); midi_note(S, 2, 64)
    assert_equal(notes.pool_used(), 1, "MIDI on voice 2 holds the pool's one extra note")
  else
    notes.set_pool(0)
  end
  pattern_clock_start()  -- step 1: slice 1 on the own note
  assert_equal(notes.own_region(1)[1], 0, "step 1: slice 1 on the own note")
  context.clock.advance_until(S.pattern_clocks[1])
  context.clear_engine_calls()
  return context, S
end

test("an overlap step slice refused a slot takes the own note with its own slice, at pool 0 and at a full pool (#744)", function()
  for _, pool in ipairs({"0", "full"}) do
    local context, S = refused_slice_setup(pool)
    local where = "pool " .. pool .. ": "
    context.clock.advance_until(S.pattern_clocks[1])  -- step 3, at 0.25 s: slice 1 still rings
    assert_equal(region_texts(context, 0), "setGrainParam(0, regionStart, 0.25) setGrainParam(0, regionLength, 0.25)",
      where .. "slice 2's region on the own note")
    assert_equal(#retriggers_of(context, 0), 1, where .. "one retrigger")
    assert_true(first_call(context, "setGrainParam", 0) < first_call(context, "retrigger", 0), where .. "after the region")
    assert_equal(#note_calls(context, "noteOn", 0), 0, where .. "no node")
    assert_equal(S.lib.notes.own_region(1)[1], 0.25, where .. "the own note plays slice 2")
    assert_equal(table.concat(S.lib.slices.playing(1), ","), "2", where .. "slice 2 is the one playing")
    pattern_clock_stop()
  end
  -- a ratchet's second hit retriggers the own note, slice 2, with no region sent again
  local context, S = refused_slice_setup("0", 2)
  context.clock.advance_until(S.pattern_clocks[1])  -- step 3's first hit
  assert_equal(S.lib.notes.own_region(1)[1], 0.25, "the ratchet's first hit: slice 2 on the own note")
  context.clear_engine_calls()
  context.clock.run_for(0.0625 + 0.001)  -- its second hit
  assert_equal(region_texts(context, 0), "", "the second hit sends no region")
  assert_equal(#retriggers_of(context, 0), 1, "and retriggers the own note")
  assert_equal(#note_calls(context, "noteOn", 0), 0, "no node")
  assert_equal(table.concat(S.lib.slices.playing(1), ","), "2", "slice 2 plays on")
  pattern_clock_stop()
end)

-- The final review's M-3: a stop leaves every one-shot step slice in an
-- extra slot ringing to its end, whether or not the last played step had a
-- chord (its chord's end releases the chord's notes only)
test("a pattern stop leaves one-shot step slices ringing whatever the last step played", function()
  for _, last in ipairs({"a chord", "a plain step"}) do
    local context, S = sliced_setup(3)
    local scan = S.lib.scan
    function scan.pass_seconds(_, fraction) return fraction * 8 end  -- 2 s
    local seq, notes = S.lib.sequencer, S.lib.notes
    for step = 1, 3 do S.patterns[1][step] = 15 end
    seq.set_step_attr(1, 1, "slice", 1); seq.set_step_attr(1, 2, "slice", 2)
    if last == "a chord" then seq.set_step_attr(1, 3, "notes", {0, 4}) end
    pattern_clock_start()
    context.clock.advance_until(S.pattern_clocks[1]); context.clock.advance_until(S.pattern_clocks[1])
    local slot = notes.find(1, "seq", "slice2")
    assert_true((slot or 1) > 1, last .. ": step 2's slice in an extra slot")
    context.clear_engine_calls()
    pattern_clock_stop()
    assert_equal(notes.find(1, "seq", "slice2"), slot, last .. ": step 2's slice rings on after the stop")
    for _, call in ipairs(note_calls(context, "noteOff", 0)) do
      assert_true(call.args[2] ~= slot - 1, last .. ": its slot is not released")
    end
    context.clock.run_for(2.1)
    assert_equal(notes.find(1, "seq", "slice2"), nil, last .. ": it ends at its time")
  end
end)

test("the region ends with the step's overrides", function()
  local context, S = sliced_setup(2)
  S.patterns[1][1] = 15
  S.lib.sequencer.set_step_attr(1, 1, "slice", 2)
  pattern_clock_start()
  assert_equal(S.lib.notes.own_region(1)[1], 0.25, "slice 2's")
  context.clear_engine_calls()
  pattern_clock_stop()
  assert_equal(S.lib.notes.own_region(1), nil, "the stop ends it")
  assert_equal(region_texts(context, 0), "setGrainParam(0, regionStart, 0) setGrainParam(0, regionLength, 0)")
end)

-- 2b's review, Minor 1 (the controller's ruling): each step's slice is a
-- hit, so the same slice on the next step restarts its scan
test("the same slice on consecutive steps sends its region at each, a chord's through its own note once", function()
  local context, S = sliced_setup(2)
  params:set("v1_buf_scan", 0.5)
  S.patterns[1][1] = 15; S.patterns[1][2] = 15
  S.lib.sequencer.set_step_attr(1, 1, "slice", 2); S.lib.sequencer.set_step_attr(1, 2, "slice", 2)
  S.lib.sequencer.set_step_attr(1, 2, "notes", {0})
  pattern_clock_start()
  assert_equal(region_texts(context, 0), "setGrainParam(0, regionStart, 0.25) setGrainParam(0, regionLength, 0.25)")
  context.clear_engine_calls()
  context.clock.advance_until(S.pattern_clocks[1])
  assert_equal(region_texts(context, 0), "setGrainParam(0, regionStart, 0.25) setGrainParam(0, regionLength, 0.25)",
    "sent again, once, at the chord step")
  S.patterns[1][3] = 15
  S.lib.sequencer.set_step_attr(1, 3, "slice", 2)
  context.clear_engine_calls()
  context.clock.advance_until(S.pattern_clocks[1])
  assert_equal(region_texts(context, 0), "setGrainParam(0, regionStart, 0.25) setGrainParam(0, regionLength, 0.25)",
    "and again at a plain step")
  pattern_clock_stop()
end)

-- The Wave 2 landing: on a one-shot voice the step's retrigger restarts the
-- engine's scan and the playhead (positionsHit, the voice_hit hook), so a
-- step that hits the same slice again restarts each once, not twice
test("in one shot the same slice on consecutive steps restarts the scan and the playhead once a step", function()
  local context, S = sliced_setup(2)
  params:set("v1_scan_mode", 3)  -- one shot
  params:set("v1_buf_scan", 0.5)
  S.patterns[1][1] = 15; S.patterns[1][2] = 15
  S.lib.sequencer.set_step_attr(1, 1, "slice", 2); S.lib.sequencer.set_step_attr(1, 2, "slice", 2)
  local resets = 0
  local real_reset = S.lib.playheads.reset
  S.lib.playheads.reset = function(voice) if voice == 1 then resets = resets + 1 end; return real_reset(voice) end
  pattern_clock_start()
  assert_equal(region_texts(context, 0), "setGrainParam(0, regionStart, 0.25) setGrainParam(0, regionLength, 0.25)",
    "the first step sends its slice")
  context.clear_engine_calls(); resets = 0
  context.clock.advance_until(S.pattern_clocks[1])
  assert_equal(region_texts(context, 0), "", "the same slice again: no region sent")
  assert_equal(#context.calls_named("retrigger"), 1, "the step's retrigger restarts the scan")
  assert_equal(resets, 1, "and the playhead, once")
  S.lib.playheads.reset = real_reset
  pattern_clock_stop()
end)

-- 2b's second review, NB2: a one-voice step's slice is playing while it
-- sounds (no slot-1 record holds it), and not once played out
test("playing names a one-voice step's slice while it sounds", function()
  local context, S = sliced_setup(2)
  S.patterns[1][1] = 15
  S.lib.sequencer.set_step_attr(1, 1, "slice", 2)
  pattern_clock_start()
  assert_equal(table.concat(S.lib.slices.playing(1), ","), "2", "the step's slice")
  pattern_clock_stop()
  assert_equal(table.concat(S.lib.slices.playing(1), ","), "", "the stop ended it")
  -- one shot: played out after its pass
  context, S = sliced_setup(2)
  params:set("v1_scan_mode", 3); params:set("v1_buf_scan", 1)  -- a quarter of 2 s: 0.5 s
  S.patterns[1][1] = 15
  S.lib.sequencer.set_step_attr(1, 1, "slice", 3)
  params:set("v1_seq_length", 16)
  pattern_clock_start()
  assert_equal(table.concat(S.lib.slices.playing(1), ","), "3", "sounding")
  context.clock.run_for(0.5 + 2 / 48)
  assert_equal(table.concat(S.lib.slices.playing(1), ","), "", "played out")
  pattern_clock_stop()
end)

-- #740 (ruling 31): a one-shot step slice's region ends with the slice's own
-- end (S.lib.playheads.finished), not a time counted from the step, so a
-- restart of its scan names it again
test("a one-shot step slice is named again after its scan restarts (#740)", function()
  local context, S = sliced_setup(2)
  params:set("v1_scan_mode", 3); params:set("v1_buf_scan", 1)  -- a quarter of 2 s: 0.5 s
  S.patterns[1][1] = 15
  S.lib.sequencer.set_step_attr(1, 1, "slice", 3)
  params:set("v1_seq_length", 16)
  local function playing() return table.concat(S.lib.slices.playing(1), ",") end
  pattern_clock_start()
  assert_equal(playing(), "3", "sounding")
  context.clock.run_for(0.5 + 2 / 48)
  assert_equal(playing(), "", "played out")
  S.lib.positions.restart_scan(1)
  assert_equal(playing(), "3", "its scan restarted: sounding again")
  context.clock.run_for(0.5 + 2 / 48)
  assert_equal(playing(), "", "and played out again")
  pattern_clock_stop()
end)

-- 2b's review, Minor 2: as the chord's first note, a step's region gives way
-- to another owner's held own note
test("a step's slice on a one voice leaves the own region of a held MIDI slice alone", function()
  local context, S = sliced_setup(2)
  local key = held_key(1, 36)
  S.midi_state.held[1][key] = true
  S.midi_state.note_voice[1] = {[36] = {1}}
  assert_equal(S.lib.slices.play(1, 1, {owner = "midi", key = key, velocity = 0.5, park = true}), 1, "MIDI's slice 1")
  S.patterns[1][1] = 15; S.patterns[1][2] = 15
  S.lib.sequencer.set_step_attr(1, 1, "slice", 3)
  context.clear_engine_calls()
  pattern_clock_start()
  assert_equal(region_texts(context, 0), "", "the step sends no region")
  assert_equal(S.lib.notes.own_region(1)[1], 0, "slice 1's stays")
  context.clock.advance_until(S.pattern_clocks[1])
  assert_equal(S.lib.notes.own_region(1)[1], 0, "and the next plain step leaves it")
  pattern_clock_stop()
  assert_equal(S.lib.notes.own_region(1)[1], 0, "and the stop")
end)

test("a step naming a slice that does not exist plays as a plain step", function()
  local context, S = sliced_setup(2)
  S.patterns[1][1] = 15
  S.lib.sequencer.set_step_attr(1, 1, "slice", 40)
  pattern_clock_start()
  assert_equal(call_texts(context)[1], "retrigger(0, 1)", "a plain step's retrigger")
  assert_equal(#context.engine_calls, 1, "and nothing else")
  assert_equal(S.lib.notes.own_region(1), nil)
  pattern_clock_stop()
  -- on a synth voice too
  context.clear_engine_calls()
  S.patterns[2][1] = 15
  S.lib.sequencer.set_step_attr(2, 1, "slice", 1)
  pattern_clock_start()
  assert_equal(#retriggers_of(context, 1), 1)
  assert_equal(region_texts(context, 1), "", "no region")
  pattern_clock_stop()
end)

end

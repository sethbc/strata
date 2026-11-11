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

test("an error in a step stops the pattern clock and shows it stopped (#243)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.patterns[1][2] = 15  -- step 2 fails starting voice 1, on the clock's first wake-up
  if S.voices[1].active then toggle_voice(1) end
  local engine_sync = S.lib.engine_sync
  local real_start_voice, raised = engine_sync.start_voice, false
  engine_sync.start_voice = function(voice_idx)
    if not raised then raised = true; error("step failed") end
    return real_start_voice(voice_idx)
  end
  pattern_clock_start()
  wake(context, "pattern_clock")
  local errors = context.clock.take_errors()
  engine_sync.start_voice = real_start_voice
  assert_true(raised, "step 2 started voice 1")
  assert_equal(#errors, 1, "one clock error")
  assert_true(errors[1]:find("step failed", 1, true), "the step's error")
  assert_true(errors[1]:find("stack traceback:", 1, true), "with its traceback")
  assert_equal(S.pattern_playing, false, "shown stopped")
  assert_equal(S.pattern_clock, nil, "the clock id is forgotten")
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
  local engine_sync = S.lib.engine_sync
  local real_start_voice, raised = engine_sync.start_voice, false
  engine_sync.start_voice = function(voice_idx)
    if not raised then raised = true; error("step failed") end
    return real_start_voice(voice_idx)
  end
  pattern_clock_start()
  UI_PAGES.screen_dirty = false
  wake(context, "pattern_clock")
  local errors = context.clock.take_errors()
  engine_sync.start_voice = real_start_voice
  assert_true(raised, "step 2 started voice 1")
  assert_equal(#errors, 1, "one clock error")
  assert_equal(S.pattern_playing, false, "stopped")
  assert_true(UI_PAGES.screen_dirty, "the stop asks for a redraw")
end)

test("an error in the first step leaves no clock recorded (#243)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.patterns[1][1] = 15  -- step 1 fails starting voice 1
  if S.voices[1].active then toggle_voice(1) end
  local engine_sync = S.lib.engine_sync
  local real_start_voice, raised = engine_sync.start_voice, false
  engine_sync.start_voice = function(voice_idx)
    if not raised then raised = true; error("first step failed") end
    return real_start_voice(voice_idx)
  end
  -- the stub raises a first step's error to the caller, as norns' clock.run does
  local started, start_error = pcall(pattern_clock_start)
  local errors = context.clock.take_errors()
  engine_sync.start_voice = real_start_voice
  assert_true(raised, "the first step ran")
  assert_true((not started and tostring(start_error):find("first step failed", 1, true)) or #errors == 1, "the error reached the caller or the scheduler")
  assert_equal(S.pattern_clock, nil, "no clock id recorded")
  assert_equal(S.pattern_playing, false, "shown stopped")
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

-- A step that fails starting its second voice: the first one it started
-- shows running, the failed one stopped in the engine and on the screen
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
  assert_equal(S.pattern_playing, false, "the pattern stopped")
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

end

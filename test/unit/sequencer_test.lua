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
  S.patterns[3][1] = 15; S.patterns[3][2] = 15  -- step 1 starts voice 3 (toggle_voice redraws the grid)
  local seen = {}
  local original_redraw = grid_redraw
  grid_redraw = function()
    seen[#seen + 1] = S.lib.sequencer.sounding_step()
    original_redraw()
  end
  pattern_toggle(); wake(context, "pattern_clock")
  grid_redraw = original_redraw
  pattern_toggle()
  assert_true(#seen >= 3, "the step redraws and the voice start's redraw (" .. #seen .. ")")
  assert_equal(seen[1], 1, "the first redraw, while step 1 starts voice 3, shows step 1")
  assert_equal(seen[#seen], 2, "the last shows step 2")
  for _, step in ipairs(seen) do
    assert_true(step == 1 or step == 2, "never the last step or the next one (" .. tostring(step) .. ")")
  end
end)

test("an error in a step stops the pattern clock and shows it stopped (#243)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.patterns[1][2] = 15  -- step 2 fails, on the clock's first wake-up
  if S.voices[1].active then toggle_voice(1) end
  local real_toggle_voice, raised = toggle_voice, false
  toggle_voice = function(voice_idx)
    if not raised then raised = true; error("step failed") end
    return real_toggle_voice(voice_idx)
  end
  pattern_clock_start()
  wake(context, "pattern_clock")
  local errors = context.clock.take_errors()
  toggle_voice = real_toggle_voice
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

test("an error in the first step leaves no clock recorded (#243)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.patterns[1][1] = 15
  if S.voices[1].active then toggle_voice(1) end
  local real_toggle_voice, raised = toggle_voice, false
  toggle_voice = function(voice_idx)
    if not raised then raised = true; error("first step failed") end
    return real_toggle_voice(voice_idx)
  end
  -- the stub raises a first step's error to the caller, as norns' clock.run does
  local started, start_error = pcall(pattern_clock_start)
  local errors = context.clock.take_errors()
  toggle_voice = real_toggle_voice
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

end

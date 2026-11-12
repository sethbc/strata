-- test/unit/gestures_test.lua
-- The gesture recorders (lib/gestures.lua, S.lib.gestures, design §7): the
-- keys' walk, what a recorder records, its loop, free and beat- or
-- bar-quantized playback, overdub, the caps, the params and their group,
-- the PSET side file and the live file, the scenes' play states, the
-- modulation sources and the cleanup
-- Run alone: lua test/run.lua gestures

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local FREE, BEAT, BAR = 1, 2, 3  -- gesture_<k>_quantize's options

local function loaded(options)
  local context = load_strata(options)
  finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.gestures
end

-- A hand edit: E3 turning a param by d detents (the touch hook's "enc")
local function hand_edit(id, d) enc_param_delta(3, id, d or 1) end

-- Run the clocks until the beat timeline reads `beat`, at the tempo the
-- beat timeline runs (it takes a change at once; clock.get_beat_sec()
-- reports one only after the clock ticks)
local function run_to_beat(context, beat)
  context.clock.run_for((beat - clock.get_beats()) * 60 / clock.tempo)
  assert_near(clock.get_beats(), beat, 1e-6, "the clock reached beat " .. beat)
end

-- Fire recorder k's free-loop metro, as matron does when its time is up
local function fire(S, k) S.gestures[k].pattern.metro.event() end

-- Record `edits` ({seconds after the previous, param id, detents}, the
-- first one's seconds a lead-in) on recorder k, then `tail` seconds, then
-- press it again (it plays)
local function record(context, gestures, k, edits, tail)
  gestures.press(k)
  for _, edit in ipairs(edits) do
    context.clock.run_for(edit[1])
    hand_edit(edit[2], edit[3])
  end
  context.clock.run_for(tail)
  gestures.press(k)
end

local function event_ids(S, k)
  local ids = {}
  for _, event in ipairs(S.gestures[k].pattern.event) do table.insert(ids, event.id) end
  return table.concat(ids, " ")
end

test("press walks empty, recording, playing, stopped, playing", function()
  local context, S, gestures = loaded()
  assert_equal(gestures.state(1), "empty")
  assert_equal(gestures.describe(1), "empty")
  gestures.press(1)
  assert_equal(gestures.state(1), "recording")
  assert_equal(gestures.describe(1), "rec 0.0 s", "nothing recorded yet")
  context.clock.run_for(0.5)
  hand_edit("reverb_mix")
  context.clock.run_for(1.2)
  assert_equal(gestures.describe(1), "rec 1.2 s", "the time since the first event")
  gestures.press(1)
  assert_equal(gestures.state(1), "playing")
  assert_equal(params:get("gesture_1_play"), 1, "the play param follows")
  assert_equal(gestures.describe(1), "play 1.2 s")
  gestures.press(1)
  assert_equal(gestures.state(1), "stopped")
  assert_equal(params:get("gesture_1_play"), 0)
  assert_equal(gestures.describe(1), "stop 1.2 s")
  gestures.press(1)
  assert_equal(gestures.state(1), "playing", "stopped -> playing")
  gestures.clear(1)
  assert_equal(gestures.state(1), "empty", "clear stops and empties it")
  assert_equal(S.gestures[1].pattern.count, 0)
  assert_equal(params:get("gesture_1_play"), 0)
  gestures.press(2); gestures.press(2)
  assert_equal(gestures.state(2), "empty", "a recording with no event is empty")
  for _, bad in ipairs({0, 5, 1.5, "1"}) do
    gestures.press(bad); gestures.clear(bad); gestures.overdub(bad)
    assert_equal(gestures.state(bad), nil, "a bad recorder index does nothing")
  end
end)

test("a recorder records hand edits of control params only", function()
  local context, S, gestures = loaded()
  record(context, gestures, 2, {{0.1, "v1_grain_size", 1}}, 1)   -- recorder 2 plays v1_grain_size
  capture_scene(1)                        -- recorder 2 playing, recorder 1 empty
  gestures.press(1)
  hand_edit("reverb_mix")
  assert_equal(S.gestures[1].pattern.count, 1, "an encoder edit of a control: one event")
  local event = S.gestures[1].pattern.event[1]
  assert_equal(event.id, "reverb_mix")
  assert_near(event.value, 0.31, 1e-9, "the value after the edit")
  hand_edit("filter_type")                -- an option
  set_binary_param("v1_freeze", 1); S.lib.ui_detent.run_touch_hooks("v1_freeze", "grid")  -- a binary
  hand_edit("v1_source")                  -- a source
  recall_scene(1, 0)                      -- a recall
  S.lib.engine_sync.deferrable(function() send_param_to_engine("reverb_mix", 0.9) end)  -- an LFO's send
  drift_update(); gentle_mutate()         -- the drift and a mutation
  fire(S, 2)                              -- the other recorder's playback
  assert_equal(event_ids(S, 1), "reverb_mix", "none of them is recorded")
  delta_with_detent("v2_grain_size", 0, {arc_ticks = 32})
  assert_equal(event_ids(S, 1), "reverb_mix v2_grain_size", "an arc ring's edit is")
  S.gesture_playing = true
  S.lib.ui_detent.run_touch_hooks("delay_mix", "enc")
  S.gesture_playing = false
  assert_equal(S.gestures[1].pattern.count, 2, "nothing is recorded while a recorder plays")
end)

test("the loop runs from the first event to the stop", function()
  local context, S, gestures = loaded()
  params:set("reverb_mix", 0.3)
  record(context, gestures, 1, {{2, "reverb_mix", 1}, {1, "reverb_mix", 1}}, 1.5)  -- 0.31, then 0.32
  local pattern = S.gestures[1].pattern
  assert_equal(pattern.count, 2)
  assert_near(pattern.time[1], 1, 1e-9, "first to second event")
  assert_near(pattern.time[2], 1.5, 1e-9, "second event to the stop: the lead-in is not in the loop")
  assert_equal(gestures.describe(1), "play 2.5 s")
  gestures.press(1)
  params:set("reverb_mix", 0.5)
  gestures.press(1)
  assert_near(params:get("reverb_mix"), 0.31, 1e-9, "the first event plays at once")
  assert_near(pattern.metro.time, 1, 1e-9, "the next in 1 s")
  fire(S, 1)
  assert_near(params:get("reverb_mix"), 0.32, 1e-9)
  assert_near(pattern.metro.time, 1.5, 1e-9, "then 1.5 s to the loop's start")
  fire(S, 1)
  assert_near(params:get("reverb_mix"), 0.31, 1e-9, "the loop starts again")
end)

test("starting a second recording ends the first, which then plays", function()
  local context, S, gestures = loaded()
  gestures.press(1)
  hand_edit("reverb_mix")
  context.clock.run_for(1)
  gestures.press(2)
  assert_equal(gestures.state(1), "playing", "the first plays")
  assert_equal(gestures.state(2), "recording")
  hand_edit("delay_mix")
  assert_equal(event_ids(S, 1), "reverb_mix", "the first records no more")
  assert_equal(event_ids(S, 2), "delay_mix", "the second does")
  gestures.overdub(1)
  assert_equal(gestures.state(2), "playing", "an overdub ends a recording too: one recorder records at a time")
  hand_edit("delay_feedback")
  assert_equal(event_ids(S, 2), "delay_mix")
  assert_equal(S.gestures[1].pattern.count, 2, "the overdub took it")
end)

test("a recording stops at 1024 events and flashes", function()
  local context, S, gestures = loaded()
  params:set("reverb_mix", 0.5)
  gestures.press(2)
  for n = 1, 1024 do
    context.set_time(util.time() + 0.01)
    hand_edit("reverb_mix", n % 2 == 1 and 1 or -1)
  end
  assert_equal(S.gestures[2].pattern.count, 1024)
  assert_equal(gestures.state(2), "playing", "the 1024th event ends the recording")
  assert_equal(S.lib.ui_flash.text("header"), "G2 full")
  hand_edit("reverb_mix")
  assert_equal(S.gestures[2].pattern.count, 1024, "nothing past it")
  gestures.overdub(2)
  hand_edit("reverb_mix")
  assert_equal(S.gestures[2].pattern.count, 1024, "an overdub is capped too")
  assert_true(not S.gestures[2].overdubbing, "and ends")
  context.clock.run_for(0.1)
end)

test("a recording stops at 10 minutes", function()
  local context, S, gestures = loaded()
  gestures.press(3)
  context.clock.run_for(30)
  hand_edit("reverb_mix")
  context.clock.run_for(599.9)
  assert_equal(gestures.state(3), "recording", "599.9 s after its first event it still records")
  context.clock.run_for(0.2)
  assert_equal(gestures.state(3), "playing", "at 10 minutes it plays")
  assert_equal(gestures.describe(3), "play 600.0 s", "a loop of 10 minutes")
end)

test("a bar loop's length rounds to whole bars and its events scale with it", function()
  local context, S, gestures = loaded()   -- 120 BPM: a beat is 0.5 s
  params:set("gesture_1_quantize", BAR)
  params:set("gesture_2_quantize", BEAT)
  params:set("gesture_3_quantize", BAR)
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}}, 1.9)          -- 3.8 beats
  record(context, gestures, 2, {{0.1, "reverb_mix", 1}}, 1.9)
  record(context, gestures, 3, {{0.1, "reverb_mix", 1}, {2.55, "delay_mix", 1}}, 2.55)  -- 10.2 beats
  assert_equal(S.gestures[1].length_beats, 4, "3.8 beats under bar: one bar")
  assert_equal(S.gestures[2].length_beats, 4, "3.8 beats under beat: 4")
  assert_equal(S.gestures[3].length_beats, 12, "10.2 beats under bar: 3 bars")
  assert_near(S.gestures[3].offsets[1], 0, 1e-9)
  assert_near(S.gestures[3].offsets[2], 6, 1e-9, "the event at 5.1 beats lands at 6")
  assert_equal(gestures.describe(1), "play 1 bar")
  assert_equal(gestures.describe(2), "play 4 beats")
  assert_equal(gestures.describe(3), "play 3 bars")

  params:set("gesture_3_quantize", FREE)
  assert_equal(S.gestures[3].offsets, nil, "free: back to seconds")
  assert_near(S.gestures[3].pattern.time[1], 3, 1e-9, "6 beats at 120 BPM")
  assert_near(S.gestures[3].pattern.time[2], 3, 1e-9)
  assert_equal(gestures.describe(3), "play 6.0 s")
  params:set("gesture_3_quantize", BEAT)
  assert_equal(S.gestures[3].length_beats, 12, "12 beats stay 12")
  assert_near(S.gestures[3].offsets[2], 6, 1e-9)
  assert_equal(gestures.state(3), "playing", "a conversion keeps it playing")
  assert_true(S.gestures[3].clock ~= nil, "on its clock")
end)

test("a bar loop starts on its bar and follows a tempo change", function()
  local context, S, gestures = loaded()
  params:set("gesture_1_quantize", BAR)
  run_to_beat(context, 1.5)
  params:set("reverb_mix", 0.3); params:set("delay_mix", 0)
  gestures.press(1)
  hand_edit("reverb_mix")                            -- 0.31 at beat 1.5
  run_to_beat(context, 3.5)
  hand_edit("delay_mix")                             -- 0.01, 2 beats later
  run_to_beat(context, 5.5)
  gestures.press(1)                                  -- 4 beats: one bar
  assert_equal(S.gestures[1].length_beats, 4)
  params:set("reverb_mix", 0.9); params:set("delay_mix", 0.5)
  run_to_beat(context, 7.98)
  assert_near(params:get("reverb_mix"), 0.9, 1e-9, "nothing plays before its bar")
  run_to_beat(context, 8.02)
  assert_near(params:get("reverb_mix"), 0.31, 1e-9, "the loop starts on bar 3 (beat 8)")
  assert_near(params:get("delay_mix"), 0.5, 1e-9)
  run_to_beat(context, 9.98)
  assert_near(params:get("delay_mix"), 0.5, 1e-9)
  run_to_beat(context, 10.02)
  assert_near(params:get("delay_mix"), 0.01, 1e-9, "its second event 2 beats in")
  params:set("reverb_mix", 0.9); params:set("delay_mix", 0.5)
  run_to_beat(context, 11)
  params:set("clock_tempo", 60)                      -- a beat is 1 s from here
  run_to_beat(context, 12.02)
  assert_near(params:get("reverb_mix"), 0.31, 1e-9, "the next loop starts on beat 12")
  run_to_beat(context, 13.98)
  assert_near(params:get("delay_mix"), 0.5, 1e-9, "2 beats are 2 s now")
  run_to_beat(context, 14.02)
  assert_near(params:get("delay_mix"), 0.01, 1e-9, "the event lands on its beat at the new tempo")
end)

-- A MIDI Start or PARAMETERS > CLOCK > reset sets the beat count back: a
-- pass sleeping between its events must not wait out the old count
test("a quantized loop follows a beat counter that goes back", function()
  local context, S, gestures = loaded()
  params:set("gesture_1_quantize", BAR)
  params:set("reverb_mix", 0.3)
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}, {0.5, "reverb_mix", 1}, {0.5, "reverb_mix", 1}}, 1)
  assert_equal(S.gestures[1].length_beats, 4, "one bar: 0.31 at 0, 0.32 at 1, 0.33 at 2")
  local bar = 4 * math.ceil(clock.get_beats() / 4)
  run_to_beat(context, bar + 0.5)
  assert_near(params:get("reverb_mix"), 0.31, 1e-9, "the pass started on its bar")
  -- the count goes back to 0.5: by a whole number of bars, so the
  -- harness's scheduler (which keeps its own count) and the count the
  -- script reads agree on where the bars fall, as matron's do
  local real_beats = clock.get_beats
  clock.get_beats = function() return real_beats() - bar end
  local ok, problem = pcall(function()
    context.clock.run_for(0.5)            -- to beat 9.5: the second event's sleep is in seconds, it plays at 9
    assert_near(params:get("reverb_mix"), 0.32, 1e-9, "the event the pass slept toward")
    params:set("reverb_mix", 0.9)
    context.clock.run_for(1.5)            -- 3 beats on (12.5), under one loop length
    assert_near(params:get("reverb_mix"), 0.31, 1e-9, "the loop starts again on the new count")
    assert_equal(S.gestures[1].loop_start, 4, "on its next bar, beat 4 of the new count")
    context.clock.run_for(0.5)
    assert_near(params:get("reverb_mix"), 0.32, 1e-9, "and plays on: its second event a beat later")
  end)
  clock.get_beats = real_beats
  assert_true(ok, tostring(problem))
end)

-- A transport start (a MIDI or Link start, PARAMETERS > CLOCK > reset) puts
-- the beat at 0 and wakes the pass-start sync at once, on beat 0: the next
-- pass starts there, never a whole loop later (#624)
test("a quantized loop waiting for its next pass starts on a transport start's beat 0 (#624)", function()
  local context, S, gestures = loaded()
  params:set("gesture_1_quantize", BAR)
  params:set("reverb_mix", 0.3)
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}}, 1.9)  -- one bar: 0.31 at its start
  assert_equal(S.gestures[1].length_beats, 4)
  local bar = 4 * math.ceil(clock.get_beats() / 4)
  run_to_beat(context, bar + 1)
  assert_near(params:get("reverb_mix"), 0.31, 1e-9, "the pass started on its bar")
  params:set("reverb_mix", 0.9)                     -- the loop now waits for its next pass
  context.clock.transport_start()
  context.clock.run_for(0.01)
  assert_near(params:get("reverb_mix"), 0.31, 1e-9, "the next pass starts on the new beat 0")
  assert_equal(S.gestures[1].loop_start, 0, "on beat 0 of the new count")
  params:set("reverb_mix", 0.9)
  run_to_beat(context, 3.98)
  assert_near(params:get("reverb_mix"), 0.9, 1e-9, "nothing more in its bar")
  run_to_beat(context, 4.02)
  assert_near(params:get("reverb_mix"), 0.31, 1e-9, "and the pass after it a bar later")
end)

test("a failed playback stops its recorder and leaves the others playing", function()
  local context, S, gestures = loaded()
  params:set("gesture_2_quantize", BAR)
  record(context, gestures, 1, {{0.1, "delay_mix", 1}, {1, "reverb_mix", 1}}, 1)  -- free: delay_mix, then reverb_mix
  record(context, gestures, 2, {{0.1, "reverb_mix", 1}}, 1)                      -- a bar loop on reverb_mix
  record(context, gestures, 3, {{0.1, "delay_feedback", 1}}, 1)                  -- free, on delay_feedback
  gestures.press(1); gestures.press(1)    -- from its start: delay_mix plays
  params:set_action("reverb_mix", function() error("broken param") end)
  fire(S, 1)                              -- reverb_mix's event raises
  assert_equal(gestures.state(1), "stopped", "the free loop stops")
  assert_true(not S.gestures[1].pattern.metro.running, "its metro is stopped")
  assert_equal(params:get("gesture_1_play"), 0)
  h.claim_script_errors(context, 1, "strata: gesture G1 failed: ", "broken param")
  assert_equal(S.gesture_playing, false, "the flags are down")
  assert_equal(S.deferrable_write, false)
  run_to_beat(context, 4 * math.ceil(clock.get_beats() / 4) + 0.02)   -- the bar loop's event raises
  assert_equal(gestures.state(2), "stopped", "the quantized loop stops")
  assert_equal(S.gestures[2].clock, nil, "with no clock")
  assert_equal(params:get("gesture_2_play"), 0)
  h.claim_script_errors(context, 1, "strata: gesture G2 failed: ", "broken param")
  assert_equal(gestures.state(3), "playing", "the others play on")
  assert_true(S.gestures[3].pattern.metro.running)
  gestures.press(1)                       -- played again from its start: its first event plays, then
  assert_equal(gestures.state(1), "playing")
  fire(S, 1)
  assert_equal(gestures.state(1), "stopped", "it stops again at the failing event")
  h.claim_script_errors(context, 1, "strata: gesture G1 failed: ", "broken param")
end)

test("overdub adds events to a playing loop, free and quantized", function()
  local context, S, gestures = loaded()
  params:set("reverb_mix", 0.3); params:set("v1_grain_size", 0.1)
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}, {2, "reverb_mix", 1}}, 2)  -- 0.31 at 0, 0.32 at 2 s
  gestures.press(1); gestures.press(1)    -- playing from its start
  context.clock.run_for(1)
  gestures.overdub(1)
  assert_true(S.gestures[1].overdubbing, "overdubbing")
  hand_edit("v1_grain_size", 5)           -- 1 s into the loop
  local edited = params:get("v1_grain_size")
  assert_near(edited, 0.12, 1e-9, "five detents of 0.0049")
  assert_equal(event_ids(S, 1), "reverb_mix v1_grain_size reverb_mix", "inserted in its place")
  assert_near(S.gestures[1].pattern.time[1], 1, 1e-9)
  assert_near(S.gestures[1].pattern.time[2], 1, 1e-9)
  assert_near(S.gestures[1].pattern.time[3], 2, 1e-9, "the loop keeps its 4 s")
  gestures.overdub(1)
  assert_true(not S.gestures[1].overdubbing, "overdub toggles off")
  hand_edit("delay_mix")
  assert_equal(S.gestures[1].pattern.count, 3, "and records no more")
  params:set("v1_grain_size", 0.2)
  fire(S, 1)
  assert_near(params:get("reverb_mix"), 0.32, 1e-9, "the next event is the one after the new one")
  fire(S, 1); fire(S, 1)
  assert_near(params:get("v1_grain_size"), edited, 1e-9, "the new event plays in the next loop")
  gestures.clear(1)

  params:set("gesture_2_quantize", BAR)
  params:set("reverb_mix", 0.3)
  record(context, gestures, 2, {{0.1, "reverb_mix", 1}, {1, "reverb_mix", 1}}, 1)  -- 4 beats: 0.31 at 0, 0.32 at 2
  assert_equal(S.gestures[2].length_beats, 4)
  local bar = 4 * math.ceil(clock.get_beats() / 4)
  assert_true(bar > clock.get_beats(), "the loop starts on the next bar")
  params:set("v1_grain_size", 0.2)
  run_to_beat(context, bar + 1)
  gestures.overdub(2)
  hand_edit("v1_grain_size", 5)           -- at beat 1 of the loop
  edited = params:get("v1_grain_size")
  assert_near(edited, 0.22, 1e-9)
  assert_near(S.gestures[2].offsets[2], 1, 1e-6, "inserted at beat 1 of 4")
  assert_equal(event_ids(S, 2), "reverb_mix v1_grain_size reverb_mix")
  gestures.overdub(2)
  params:set("v1_grain_size", 0.5); params:set("reverb_mix", 0.5)
  run_to_beat(context, bar + 2.02)
  assert_near(params:get("reverb_mix"), 0.32, 1e-9, "the next event plays")
  assert_near(params:get("v1_grain_size"), 0.5, 1e-9, "the new one waits for the next loop")
  run_to_beat(context, bar + 5.02)
  assert_near(params:get("v1_grain_size"), edited, 1e-9, "where it plays at beat 1")
end)

test("playback is deferrable and is not recorded", function()
  local context, S, gestures = loaded()
  params:set("reverb_mix", 0.3)
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}}, 1)
  gestures.press(1)
  params:set("reverb_mix", 0.5)
  context.clock.run_for(0.1)              -- a new send window
  local budget = S.constants.ENGINE_BUDGET.messages_per_window
  S.lib.engine_sync.deferrable(function()
    for _ = 1, budget do send_param_to_engine("drift_amount", 0) end
  end)
  context.clear_engine_calls()
  gestures.press(2)
  gestures.press(1)                       -- plays its first event in the full window
  assert_near(params:get("reverb_mix"), 0.31, 1e-9, "the param is set")
  assert_equal(#context.calls_named("setReverb"), 0, "its send waits for the budget")
  assert_equal(S.lib.engine_sync.budget_state().pending, 1)
  assert_equal(S.gesture_playing, false, "the flag is down again")
  assert_equal(S.deferrable_write, false)
  assert_equal(S.gestures[2].pattern.count, 0, "recorder 2 recorded none of it")
  hand_edit("delay_mix")
  assert_equal(#context.calls_named("setDelay"), 1, "a hand edit is never deferred")
  context.clock.run_for(0.1)
  assert_equal(#context.calls_named("setReverb"), 1, "the deferred send goes in the next window")
end)

test("a hand edit of a played param wins until the recorder's next event for it", function()
  local context, S, gestures = loaded()
  params:set("reverb_mix", 0.3)
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}, {1, "delay_mix", 1}, {1, "reverb_mix", 1}}, 1)
  gestures.press(1); gestures.press(1)
  assert_near(params:get("reverb_mix"), 0.31, 1e-9)
  hand_edit("reverb_mix", 9)
  assert_near(params:get("reverb_mix"), 0.40, 1e-9, "the hand edit")
  fire(S, 1)                              -- delay_mix's event
  assert_near(params:get("reverb_mix"), 0.40, 1e-9, "another param's event leaves it")
  fire(S, 1)
  assert_near(params:get("reverb_mix"), 0.32, 1e-9, "its own next event takes it back")
end)

test("the quantize and play params: a group of eight, the play params hidden scene fields", function()
  local _, S = loaded()
  local at = params.lookup["strata_gestures"]
  local group = params.params[at]
  assert_equal(group.t, params.tGROUP)
  assert_equal(group.n, 8)
  local ids = {}
  for index = at + 1, at + 8 do table.insert(ids, params.params[index].id) end
  assert_equal(table.concat(ids, " "), "gesture_1_quantize gesture_2_quantize gesture_3_quantize gesture_4_quantize "
    .. "gesture_1_play gesture_2_play gesture_3_play gesture_4_play")
  for k = 1, 4 do
    local quantize = params:lookup_param("gesture_" .. k .. "_quantize")
    assert_equal(quantize.t, params.tOPTION)
    assert_equal(table.concat(quantize.options, " "), "free beat bar")
    assert_equal(quantize.default, FREE)
    local play = params:lookup_param("gesture_" .. k .. "_play")
    assert_equal(play.t, params.tBINARY)
    assert_true(not params:visible("gesture_" .. k .. "_play"), "hidden")
    local field
    for _, record in ipairs(S.registry.scene_fields) do
      if record.id == "gesture_" .. k .. "_play" then field = record end
    end
    assert_true(field ~= nil and field.discrete and field.default == 0, "a discrete scene field, default 0")
  end
end)

test("the PSET side file and the live file round-trip; scenes store only the play states", function()
  local context, S, gestures = loaded()
  params:set("gesture_2_quantize", BAR); params:set("gesture_3_quantize", BEAT)
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}, {1, "delay_mix", 1}}, 1.5)
  record(context, gestures, 2, {{0.1, "reverb_mix", 1}, {1, "delay_mix", 1}}, 1)
  local path = context.data_dir .. "strata-01.pset"
  params:write(path)
  local side = context.data_dir .. "strata-01.gestures.data"
  assert_true(util.file_exists(side), "the PSET's side file")
  gestures.clear(1); gestures.clear(2)
  params:set("gesture_2_quantize", FREE); params:set("gesture_3_quantize", FREE)
  params:read(path)
  assert_equal(gestures.state(1), "stopped", "loaded stopped")
  assert_equal(event_ids(S, 1), "reverb_mix delay_mix")
  assert_near(S.gestures[1].pattern.time[1], 1, 1e-9); assert_near(S.gestures[1].pattern.time[2], 1.5, 1e-9)
  assert_equal(gestures.state(2), "stopped")
  assert_equal(S.gestures[2].quantize, "bar"); assert_equal(params:get("gesture_2_quantize"), BAR)
  assert_equal(S.gestures[2].length_beats, 4)
  assert_near(S.gestures[2].offsets[2], 2, 1e-9)
  assert_equal(gestures.state(3), "empty"); assert_equal(params:get("gesture_3_quantize"), BEAT)

  -- the scenes: a play state per recorder, and nothing else of a recorder
  gestures.press(1)
  capture_scene(1)
  assert_equal(S.scenes[1].data.gesture_1_play, 1)
  assert_equal(S.scenes[1].data.gesture_2_play, 0)
  for key in pairs(S.scenes[1].data) do
    assert_true(not tostring(key):find("gesture") or tostring(key):find("^gesture_%d_play$"), "scene key " .. key)
  end
  gestures.press(1); gestures.press(2)
  S.scenes[1].data.gesture_4_play = 1
  recall_scene(1, 0)
  assert_equal(gestures.state(1), "playing", "a recall plays a recorder its scene played")
  assert_equal(gestures.state(2), "stopped", "and stops one it did not")
  assert_equal(gestures.state(4), "empty", "1 on an empty recorder does nothing")
  assert_equal(params:get("gesture_4_play"), 0, "and its play param stays 0")

  -- the live file, saved at cleanup and loaded at the next start, stopped
  cleanup()
  assert_true(util.file_exists(context.data_dir .. "strata/gestures.data"), "the live file")
  local _, next_S, next_gestures = loaded({ data_subdir = context.data_dir:match("([^/]+)/$") })
  assert_equal(next_gestures.state(1), "stopped", "loaded stopped")
  assert_equal(event_ids(next_S, 1), "reverb_mix delay_mix")
  assert_equal(next_S.gestures[2].length_beats, 4)
  assert_equal(params:get("gesture_2_quantize"), BAR)
  assert_equal(params:get("gesture_3_quantize"), BEAT)
end)

test("a PSET load stops every recorder before it loads the side file", function()
  local context, S, gestures = loaded()
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}}, 1)
  local path = context.data_dir .. "strata-02.pset"
  params:write(path)
  gestures.press(2)
  hand_edit("delay_mix")
  assert_equal(gestures.state(1), "playing"); assert_equal(gestures.state(2), "recording")
  local states
  local real_read = S.lib.data_files.read
  S.lib.data_files.read = function(file, ...)
    if file:find("gestures", 1, true) then states = gestures.state(1) .. " " .. gestures.state(2) end
    return real_read(file, ...)
  end
  params:read(path)
  S.lib.data_files.read = real_read
  assert_true(states ~= nil and not states:find("playing") and not states:find("recording"),
    "nothing plays or records as the side file is read: " .. tostring(states))
  assert_equal(gestures.state(1), "stopped")
  assert_equal(gestures.state(2), "empty", "the PSET held no recording on 2")
end)

test("a PSET saved over keeps no older loops, and its delete removes the side file", function()
  local context, S, gestures = loaded()
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}}, 1)
  local path = context.data_dir .. "strata-06.pset"
  local side = context.data_dir .. "strata-06.gestures.data"
  params:write(path)
  gestures.clear(1)
  params:write(path)                      -- saved over with every recorder empty
  record(context, gestures, 2, {{0.1, "delay_mix", 1}}, 1)
  params:read(path)
  assert_equal(gestures.state(1), "empty", "the empty save replaced the loop")
  assert_equal(gestures.state(2), "empty")
  params:delete(path)
  assert_true(not util.file_exists(side), "deleted with its PSET")
end)

test("a PSET without a side file loads empty", function()
  local context, S, gestures = loaded()
  local path = context.data_dir .. "strata-03.pset"
  params:write(path)
  os.remove(context.data_dir .. "strata-03.gestures.data")
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}}, 1)
  params:read(path)
  assert_equal(gestures.state(1), "empty", "a PSET from before 3.4 held no recorders")
  assert_equal(S.gestures[1].pattern.count, 0)
end)

test("a live file that can be neither read nor set aside is never written over", function()
  local first = loaded()
  cleanup()
  local live_path = first.data_dir .. "strata/gestures.data"
  local bad = "return {\n  {1},\n"
  h.write_text(live_path, bad)
  local context = load_strata({ data_subdir = first.data_dir:match("([^/]+)/$"), before_init = function()
    local_value("S").lib.data_files.set_aside = function() return nil, "permission denied" end
  end })
  finish_startup(context)
  cleanup()
  assert_equal(h.file_text(live_path), bad, "not written over at cleanup")
  local lines = 0
  for _, line in ipairs(context.printed) do
    if line:find("gestures will not be saved", 1, true) then lines = lines + 1 end
  end
  assert_equal(lines, 1, "one console line says saves are off")
end)

test("a damaged live file that is set aside loads empty and saves normally", function()
  local first = loaded()
  cleanup()
  local live_path = first.data_dir .. "strata/gestures.data"
  h.write_text(live_path, "return {\n  {1},\n")
  local context, S, gestures = loaded({ data_subdir = first.data_dir:match("([^/]+)/$") })
  assert_true(util.file_exists(live_path .. ".bak"), "kept as a backup")
  assert_equal(gestures.state(1), "empty", "loaded empty")
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}}, 1)
  cleanup()
  assert_true(S.lib.data_files.read(live_path) ~= nil, "saved normally afterward")
  assert_true(h.file_text(live_path) ~= h.file_text(live_path .. ".bak"), "the damaged text is gone")
end)

test("an unreadable side file is set aside and the PSET still loads", function()
  local bad_bar = { version = 1, recorders = { { quantize = "bar", events = { { id = "reverb_mix", value = 0.5 } },
    beats = { 0 }, length_beats = 6 } } }  -- 6 beats is no whole number of bars
  local no_length = { version = 1, recorders = { { quantize = "free", events = { { id = "reverb_mix", value = 0.5 },
    { id = "delay_mix", value = 0.5 } }, times = { 0, 0 } } } }  -- its metro would fire without a pause
  for _, content in ipairs({ "return {\n  {1},\n", "return {\n-- Table: {1}\n{\n   [\"version\"]=2,\n},\n}\n", bad_bar,
      no_length }) do
    local context, S, gestures = loaded()
    params:set("reverb_mix", 0.7)
    local path = context.data_dir .. "strata-04.pset"
    params:write(path)
    local side = context.data_dir .. "strata-04.gestures.data"
    h.write_text(side, type(content) == "table" and S.lib.data_files.encode(content) or content)
    record(context, gestures, 1, {{0.1, "reverb_mix", 1}}, 1)
    params:set("reverb_mix", 0.2)
    params:read(path)
    assert_near(params:get("reverb_mix"), 0.7, 1e-9, "the PSET loaded")
    assert_equal(gestures.state(1), "empty", "the recorders are empty")
    assert_true(not util.file_exists(side), "the file is moved")
    assert_true(util.file_exists(side .. ".bak"), "to its first free backup name")
    local said = false
    for _, line in ipairs(context.printed) do
      if line:find("gestures", 1, true) and line:find(".bak", 1, true) then said = true end
    end
    assert_true(said, "a console line names it")
  end
end)

test("a gesture event naming an unknown param is kept and skipped", function()
  local context, S, gestures = loaded()
  local path = context.data_dir .. "strata-05.pset"
  params:write(path)
  local side = context.data_dir .. "strata-05.gestures.data"
  assert_true(S.lib.data_files.write(side, { version = 1, recorders = {
    { quantize = "free", events = { { id = "macro_17", value = 0.5 }, { id = "reverb_mix", value = 0.6 } },
      times = { 1, 1 } } } }))
  params:read(path)
  assert_equal(event_ids(S, 1), "macro_17 reverb_mix", "kept")
  gestures.press(1)
  assert_equal(gestures.state(1), "playing", "the unknown event is skipped without a word")
  fire(S, 1)
  assert_near(params:get("reverb_mix"), 0.6, 1e-9, "the known one plays")
  params:write(path)
  local saved = S.lib.data_files.read(side)
  assert_equal(saved.recorders[1].events[1].id, "macro_17", "and it is saved again as it was")
end)

test("the sources gesture1-4 read the loop's phase, 0 when not playing", function()
  local context, S, gestures = loaded()
  local sources = S.lib.mod_sources
  for k = 1, 4 do
    local source = sources.get("gesture" .. k)
    assert_true(source ~= nil, "gesture" .. k .. " is registered")
    assert_equal(source.section, "gestures")
    assert_equal(source.name, "G" .. k)
    assert_equal(source.range[1], 0); assert_equal(source.range[2], 1)
  end
  assert_equal(sources.get("gesture1").value(), 0, "empty: 0")
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}}, 2)
  assert_near(sources.get("gesture1").value(), 0, 1e-9, "at its start")
  context.clock.run_for(0.5)
  assert_near(sources.get("gesture1").value(), 0.25, 1e-9, "a quarter through its 2 s")
  assert_equal(sources.get("gesture1").describe(), "play 2.0 s")
  gestures.press(1)
  assert_equal(sources.get("gesture1").value(), 0, "stopped: 0")
  sources.get("gesture1").row.press()
  assert_equal(gestures.state(1), "playing", "the row's press is the recorder's")
end)

test("cleanup stops every recorder's metro and clock", function()
  local context, S, gestures = loaded()
  params:set("gesture_2_quantize", BAR)
  record(context, gestures, 1, {{0.1, "reverb_mix", 1}}, 1)
  record(context, gestures, 2, {{0.1, "reverb_mix", 1}}, 1)
  gestures.press(3); hand_edit("delay_mix")
  assert_true(S.gestures[1].pattern.metro.running, "a free loop's metro runs")
  assert_true(S.gestures[2].clock ~= nil, "a bar loop's clock runs")
  cleanup()
  assert_true(not S.gestures[1].pattern.metro.running, "the metro is stopped")
  assert_equal(S.gestures[2].clock, nil, "the clock is canceled")
  assert_true(gestures.state(3) ~= "recording", "the recording ends")
  context.clock.run_for(4)
end)

end

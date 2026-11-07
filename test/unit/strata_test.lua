-- test/unit/strata_test.lua
-- strata.lua's entry points: init, the start-up clock and cleanup
-- Run alone: lua test/run.lua strata

return function(h)
local test, assert_true, assert_equal, load_strata = h.test, h.assert_true, h.assert_equal, h.load_strata
local local_value, finish_startup = h.local_value, h.finish_startup

test("strata.lua loads and init() runs", function()
  local context = load_strata()
  assert_true(#context.engine_calls > 0, "init should talk to the engine")
end)

-- Voice 1 needs no such guard: clock.run resumes the startup clock at once,
-- so it starts voice 1 inside init(), before any MIDI note, grid press or
-- key can reach the script
test("the startup clock leaves a voice 2 started within STARTUP.voice_delay_seconds running", function()
  local starters = {
    { name = "toggle_voice (a grid press)", start = function() toggle_voice(2) end },
    { name = "a MIDI note on channel 2 (midi_note_on)", start = function(context)
      context.midi.plug(1, "keys")
      context.midi.send(1, { type = "note_on", ch = 2, note = 60, vel = 100 })
    end },
  }
  for _, starter in ipairs(starters) do
    local context = load_strata()
    local voices = local_value("voices")
    assert_true(voices[1].active, starter.name .. ": init started voice 1")
    assert_true(not voices[2].active, starter.name .. ": voice 2 starts stopped")
    starter.start(context)  -- before the startup sleep ends
    assert_true(voices[2].active, starter.name .. ": started voice 2")
    finish_startup(context)
    assert_true(voices[2].active, starter.name .. ": voice 2 is still running after the startup clock")
    for _, call in ipairs(context.calls_named("voiceOff")) do
      assert_true(call.args[1] ~= 1, starter.name .. ": the startup clock sent no voiceOff for voice 2")
    end
  end
end)

test("init's start-up clock is stored, ends after starting voice 2 and is canceled by cleanup (#48)", function()
  local context = load_strata()
  assert_true(type(STARTUP.voice_delay_seconds) == "number" and STARTUP.voice_delay_seconds > 0,
    "STARTUP.voice_delay_seconds")
  assert_true(context.clock.threads[STARTUP.clock] ~= nil, "the start-up clock is stored and running")
  finish_startup(context)
  assert_true(local_value("voices")[2].active, "voice 2 started")
  assert_equal(STARTUP.clock, nil, "the clock is forgotten once it has ended")
  -- a script stopped before the delay ends starts nothing afterward
  context = load_strata()
  cleanup()
  assert_equal(STARTUP.clock, nil, "cleanup forgets the start-up clock")
  local voice_ons = #context.calls_named("voiceOn")
  context.clock.run_for(STARTUP.voice_delay_seconds + 0.1)
  assert_true(not local_value("voices")[2].active, "voice 2 not started after cleanup")
  assert_equal(#context.calls_named("voiceOn"), voice_ons, "no voiceOn after cleanup")
end)

test("cleanup stops everything and darkens controllers (M9)", function()
  local context = load_strata()
  local grid_device = context.grid.plug(1, 16, 16)
  local arc_hardware = context.arc.plug(1)
  finish_startup(context)  -- finish init's voice start-up coroutine
  capture_scene(1)
  params:set("scene_sequencer_enabled", 1)
  params:set("mutation_enabled", 1)
  pattern_toggle()
  recall_scene(1, 5)
  local voices = local_value("voices")
  local expected_off = {}
  for voice_idx = 1, local_value("NUM_VOICES") do
    if voices[voice_idx].active then table.insert(expected_off, voice_idx - 1) end
  end
  assert_true(#expected_off >= 2 and expected_off[1] == 0, "voice 1 and others are running before cleanup")
  context.clear_engine_calls()
  cleanup()
  assert_equal(params:get("scene_sequencer_enabled"), 0, "scene sequencer param reset")
  assert_equal(params:get("mutation_enabled"), 0, "mutation param reset")
  assert_equal(context.clock.pending_count(), 0, "no clocks left running")
  for _, timer in ipairs(context.metro.all) do assert_true(not timer.running, "metro stopped") end
  local lit = 0
  for x = 1, 16 do for y = 1, 16 do lit = lit + grid_device:get_led(x, y) end end
  assert_equal(lit, 0, "grid LEDs cleared")
  assert_true(next(arc_hardware.segments) == nil, "arc rings cleared")
  local voices_off = {}
  for _, call in ipairs(context.calls_named("voiceOff")) do table.insert(voices_off, call.args[1]) end
  assert_equal(table.concat(voices_off, ","), table.concat(expected_off, ","),
    "exactly the running voices are turned off, by 0-based engine index")
  assert_true(util.file_exists(context.data_dir .. "strata/scenes.data"), "scenes saved on cleanup")
end)

end

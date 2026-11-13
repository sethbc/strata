-- test/unit/strata_test.lua
-- strata.lua's entry points: init, the start-up clock and cleanup; and 3.5's
-- notes played end to end against the stub (the release's whole-system test)
-- Run alone: lua test/run.lua strata

return function(h)
local test, assert_true, assert_equal, load_strata = h.test, h.assert_true, h.assert_equal, h.load_strata
local local_value, finish_startup = h.local_value, h.finish_startup
local assert_near, check_invariants, show_page, tap = h.assert_near, h.check_invariants, h.show_page, h.tap

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

---------------------------------------------------------------------------
-- 3.5 played end to end: MIDI through the real MPE, expression, allocator,
-- freeze, zones editor and scene code into the engine stub, which refuses
-- any call whose name, argument count, types or ranges the engine does not
-- take. Each stage checks the note path's engine calls against design 3.5
-- as built (the rulings that changed it are named, with the ledger's
-- numbers: docs/decisions/3.5.md), then every invariant
---------------------------------------------------------------------------

-- The note path's engine calls since the last clear, each its name and its
-- leading arguments (a voice; a slot; a cut or a source), joined by ", "
local NOTE_PATH_ARGS = { voiceOn = 1, voiceOff = 1, retrigger = 1, setGrainSource = 2, noteOn = 2,
  noteExpression = 2, noteOff = 3 }
local function note_path(context)
  local list = {}
  for _, call in ipairs(context.engine_calls) do
    local shown = NOTE_PATH_ARGS[call.name]
    if shown then
      local words = { call.name }
      for index = 1, shown do words[#words + 1] = string.format("%g", call.args[index]) end
      list[#list + 1] = table.concat(words, " ")
    end
  end
  return table.concat(list, ", ")
end

-- The arguments of the engine calls named name since the last clear for
-- engine voice and (when given) engine slot, in order
local function calls_for(context, name, voice, slot)
  local list = {}
  for _, call in ipairs(context.calls_named(name)) do
    if call.args[1] == voice and (slot == nil or call.args[2] == slot) then list[#list + 1] = call.args end
  end
  return list
end

-- The position of the first engine call since the last clear that matches(call)
local function call_index(context, matches)
  for index, call in ipairs(context.engine_calls) do
    if matches(call) then return index end
  end
  return nil
end

test("3.5 end to end: a zone learn, an MPE chord on a buffer voice, a switch, a freeze and an unfreeze under a chord, a recall, the keys lifted", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local notes, mpe = S.lib.notes, S.lib.mpe
  local SOURCE_SYNTH = S.constants.SOURCE_SYNTH
  local velocity = 100 / 127
  local function note_on(channel, note) context.midi.send(1, { type = "note_on", note = note, vel = 100, ch = channel }) end
  local function note_off(channel, note) context.midi.send(1, { type = "note_off", note = note, vel = 0, ch = channel }) end
  -- a channel's bend, as its offset from the 14-bit center, and its pressure (0-127)
  local function bend(channel, offset) context.midi.send(1, { type = "pitchbend", val = 8192 + offset, ch = channel }) end
  local function press(channel, value) context.midi.send(1, { type = "channel_pressure", val = value, ch = channel }) end
  local function lfo_step() context.clock.advance_until(S.lfo_clock) end
  local function setgrain_index(param)
    return call_index(context, function(call) return call.name == "setGrainParam" and call.args[2] == param end)
  end
  local function first_index(name) return call_index(context, function(call) return call.name == name end) end
  -- a noteExpression's values: the bend and amp given, position, size and main 0
  local function expression_is(args, bend_ratio, amp, message)
    assert_true(args ~= nil, message .. ": sent")
    assert_near(args[3], bend_ratio, 1e-9, message .. ": bend"); assert_near(args[4], amp, 1e-9, message .. ": amp")
    assert_equal(args[5], 0, message .. ": position"); assert_equal(args[6], 0, message .. ": size")
    assert_equal(args[7], 0, message .. ": main")
  end
  -- (c) each stage starts with no engine call recorded and ends with every
  -- invariant holding, the allocator's among them
  local function stage(name, body)
    context.clear_engine_calls()
    body(name)
    local broken = check_invariants()
    assert_equal(#broken, 0, name .. ": every invariant holds after it (" .. table.concat(broken, "; ") .. ")")
  end
  assert_equal(notes.pool(), 4, "the standard tier's pool")
  assert_true(S.voices[1].active and S.voices[2].active and not S.voices[3].active, "init runs voices 1 and 2")

  -- (a) A zone learn through real MIDI notes and the real note tap: the
  -- zones editor (SETUP's mpe & zones) takes the next two notes as voice
  -- 3's range and neither plays a voice; the tap goes with the learn, and
  -- the next note plays
  stage("the zone learn", function(name)
    params:set("midi_channel_mode", mpe.MPE.modes.split)
    params:set("v1_zone", 1)  -- off: only voice 3's learned range routes the lower zone
    params:set("v3_zone", 2)  -- lower
    show_page("SETUP")
    S.lib.ui_zones.open()
    enc(2, 5)                     -- the rows: lower members, upper members, bend range, v1, v2, v3
    key(1, 1); tap(3); key(1, 0)  -- ALT+K3 learns the row's voice
    assert_equal(S.lib.ui_zones.learning(), 3, name .. ": learn waits for voice 3's notes")
    context.clear_engine_calls()
    note_on(2, 72); note_on(3, 60)
    note_off(2, 72); note_off(3, 60)
    assert_equal(params:get("v3_zone_low"), 60, name .. ": the lower note is the lowest")
    assert_equal(params:get("v3_zone_high"), 72, name .. ": the higher the highest")
    assert_equal(S.lib.ui_zones.learning(), nil, name .. ": learn ends")
    assert_equal(#context.engine_calls, 0, name .. ": neither learned note sends anything")
    for voice = 1, S.constants.NUM_VOICES do
      assert_equal(notes.held(voice), 0, name .. ": voice " .. voice .. " holds no note")
    end
    assert_true(not S.voices[3].active, name .. ": voice 3 not started")
    note_on(2, 64)
    assert_equal(note_path(context), "setGrainSource 2 0, voiceOn 2, retrigger 2",
      name .. ": the tap is gone: a note in the learned range starts voice 3")
    assert_equal(notes.held(3), 1, name .. ": voice 3 holds it")
    context.clear_engine_calls()
    note_on(3, 50)
    assert_equal(#context.engine_calls, 0, name .. ": a note below the range plays no voice")
    note_off(3, 50); note_off(2, 64)  -- release in the MPE modes: voice 3 stops with its last key
    assert_equal(note_path(context), "voiceOff 2", name .. ": the last key stops voice 3")
    tap(2)  -- K2 closes the editor
    assert_true(not S.lib.ui_zones.is_open(), name .. ": the editor closed")
  end)

  -- An MPE chord of four on a buffer voice in mpe selected. The controller
  -- sends each note's first bend and pressure before its note on (design
  -- §5.4). The own note: set_own, then the start (which carries the new
  -- rate), then its first expression, then the accent (ruling 6); (b) that
  -- first noteExpression carries the channel's values before any
  -- controller moves, and the flush never sends it again. Each extra note
  -- is its noteExpression, then its noteOn (design §2.2, branch 3)
  stage("an MPE chord on a buffer voice", function(name)
    params:set("midi_channel_mode", mpe.MPE.modes.selected)
    S.lib.ui_keys.select_voice_by(3 - S.selected_voice)
    params:set("v3_source", SOURCE_SYNTH + 1)  -- buffer slot 1, set while the voice is stopped
    bend(2, 1024); press(2, 127)   -- 2 ^ (1024 / 8192 * 48 / 12) = 2 ^ 0.5; amp 1 + 127 / 127
    bend(3, -2048); press(3, 64)   -- 0.5; 1 + 64 / 127
    bend(4, 2048); press(4, 96)    -- 2; 1 + 96 / 127
    bend(5, 512); press(5, 32)     -- 2 ^ 0.25; 1 + 32 / 127
    context.clear_engine_calls()
    note_on(2, 62)
    assert_equal(note_path(context), "setGrainSource 2 1, voiceOn 2, noteExpression 2 0, retrigger 2",
      name .. ": the own note starts the stopped voice, then its expression, then the accent")
    local rate_set = setgrain_index("bufRate")
    assert_true(rate_set ~= nil and rate_set < first_index("voiceOn"), name .. ": its rate goes with the start (ruling 6)")
    -- the own note's rate is the v3_buf_rate param's, which steps in 0.01
    -- (3.4's spec): note 62 within half a step of 2 ^ (2 / 12)
    assert_equal(context.engine_calls[rate_set].args[3], params:get("v3_buf_rate"), name .. ": the param's rate")
    assert_near(context.engine_calls[rate_set].args[3], 2 ^ (2 / 12), 0.005, name .. ": note 62's rate")
    expression_is(calls_for(context, "noteExpression", 2, 0)[1], 2 ^ 0.5, 2, name .. ": the own note's first expression (b)")
    assert_near(calls_for(context, "retrigger", 2)[1][2], velocity, 1e-9, name .. ": accented at the note's velocity")
    context.clear_engine_calls()
    lfo_step()
    assert_equal(note_path(context), "", name .. ": the flush sends the own note's first expression no second time")
    note_on(3, 66); note_on(4, 69); note_on(5, 73)
    assert_equal(note_path(context), "noteExpression 2 1, noteOn 2 1, noteExpression 2 2, noteOn 2 2, "
      .. "noteExpression 2 3, noteOn 2 3", name .. ": three extra notes, each its expression then its noteOn")
    local wanted = {
      { slot = 1, note = 66, freq = 369.99442271163, rate = 2 ^ 0.5, bend = 0.5, amp = 1 + 64 / 127 },
      { slot = 2, note = 69, freq = 440, rate = 2 ^ 0.75, bend = 2, amp = 1 + 96 / 127 },
      { slot = 3, note = 73, freq = 554.36526195374, rate = 2 ^ (13 / 12), bend = 2 ^ 0.25, amp = 1 + 32 / 127 },
    }
    for _, note in ipairs(wanted) do
      local label = name .. ": engine slot " .. note.slot
      local on = calls_for(context, "noteOn", 2, note.slot)[1]
      assert_equal(on[3], note.note, label .. "'s note")
      assert_near(on[4], note.freq, 1e-6, label .. "'s freq"); assert_near(on[5], note.rate, 1e-9, label .. "'s rate")
      assert_near(on[6], velocity, 1e-9, label .. "'s velocity")
      expression_is(calls_for(context, "noteExpression", 2, note.slot)[1], note.bend, note.amp, label .. "'s first expression")
    end
    assert_equal(notes.held(3), 4, name .. ": four notes held")
    assert_equal(notes.pool_used(), 3, name .. ": three of them from the pool")
    capture_scene(1)  -- recalled under a later chord
  end)

  -- Each note bent and pressed: nothing is sent as the values arrive; the
  -- next 48 Hz step's flush sends each note's newest values once (design §6.4)
  stage("each note bent and pressed", function(name)
    bend(2, 0); press(2, 0)        -- 1; 1
    bend(3, 4096); press(3, 127)   -- 2 ^ (4096 / 8192 * 48 / 12) = 4; 2
    bend(4, -4096); press(4, 64)   -- 0.25; 1 + 64 / 127
    bend(5, 1024); press(5, 0)     -- 2 ^ 0.5; 1
    assert_equal(note_path(context), "", name .. ": nothing is sent on arrival")
    lfo_step()
    assert_equal(note_path(context), "noteExpression 2 0, noteExpression 2 1, noteExpression 2 2, noteExpression 2 3",
      name .. ": one step sends each note's expression once")
    expression_is(calls_for(context, "noteExpression", 2, 0)[1], 1, 1, name .. ": the own note")
    expression_is(calls_for(context, "noteExpression", 2, 1)[1], 4, 2, name .. ": engine slot 1")
    expression_is(calls_for(context, "noteExpression", 2, 2)[1], 0.25, 1 + 64 / 127, name .. ": engine slot 2")
    expression_is(calls_for(context, "noteExpression", 2, 3)[1], 2 ^ 0.5, 1, name .. ": engine slot 3")
    context.clear_engine_calls()
    lfo_step()
    assert_equal(note_path(context), "", name .. ": and nothing more at the next")
  end)

  -- A source switch under the chord (buffer to synth): the switch alone;
  -- the engine restarts every held extra note on the new source from the
  -- values it keeps (design §2.4), and the notes' values need no resend
  stage("a source switch under the chord", function(name)
    params:set("v3_source", SOURCE_SYNTH)
    assert_equal(note_path(context), "setGrainSource 2 0", name .. ": the switch, and no note command")
    lfo_step()
    assert_equal(#context.calls_named("noteExpression"), 0, name .. ": no expression resent")
    assert_equal(notes.held(3), 4, name .. ": every note still held"); assert_equal(notes.pool_used(), 3, name .. ": the pool's")
  end)

  -- The own key lifted under the others parks the own note; pressed again
  -- it is unparked with noteOn on slot 0, then accented by the retrigger
  -- (ruling 15; the engine's slot-0 noteOn fires no accent, ruling 47)
  stage("the own note parked and played again", function(name)
    note_off(2, 62)
    assert_equal(note_path(context), "noteOff 2 0 0", name .. ": parked under the extra notes")
    assert_equal(notes.held(3), 3, name .. ": three notes held")
    context.clear_engine_calls()
    note_on(2, 62)
    assert_equal(note_path(context), "noteOn 2 0, retrigger 2", name .. ": unparked, then accented")
    assert_near(params:get("v3_freq"), 293.66476791741, 1e-6, name .. ": set_own pitches the synth voice's freq")
  end)

  -- A synth voice's freeze under the chord: each extra note is cut and
  -- forgotten (its sound is in the frozen ring, design §2.4), in slot
  -- order after the freeze itself; the own note stays, its pitch the freeze
  -- reference, and the keys still down send nothing more
  stage("a freeze under the chord", function(name)
    params:set("v3_freeze", 1)
    assert_equal(note_path(context), "noteOff 2 1 1, noteOff 2 2 1, noteOff 2 3 1", name .. ": every extra note cut")
    assert_true(setgrain_index("freeze") < first_index("noteOff"), name .. ": after the freeze")
    assert_equal(notes.held(3), 1, name .. ": the own note alone"); assert_equal(notes.pool_used(), 0, name .. ": the pool empty")
    assert_near(notes.freeze_reference(3), 62, 1e-9, name .. ": the reference is the own note's pitch")
    context.clear_engine_calls()
    press(4, 127); bend(5, 2048)
    lfo_step()
    assert_equal(note_path(context), "", name .. ": a key whose note was cut sends nothing")
  end)

  -- A chord on the frozen voice: an extra note is a stream of the frozen
  -- ring at its rate from the reference (Question 8), in a never-used slot
  -- first; the own key lifted parks the own note, and pressed again sends
  -- slot 0's noteOn, which carries its rate, then the retrigger (rulings 15, 18)
  stage("a chord on the frozen voice", function(name)
    note_on(6, 69)
    assert_equal(note_path(context), "noteExpression 2 4, noteOn 2 4", name .. ": a never-used slot first")
    assert_near(calls_for(context, "noteOn", 2, 4)[1][5], 2 ^ (7 / 12), 1e-9, name .. ": a fifth above the reference")
    expression_is(calls_for(context, "noteExpression", 2, 4)[1], 1, 1, name .. ": a channel that sent nothing: neutral")
    context.clear_engine_calls()
    note_off(2, 62)
    assert_equal(note_path(context), "noteOff 2 0 0", name .. ": the own note parks under the stream")
    context.clear_engine_calls()
    note_on(2, 64)
    assert_equal(note_path(context), "noteOn 2 0, retrigger 2", name .. ": unparked with its rate, then accented")
    assert_near(calls_for(context, "noteOn", 2, 0)[1][5], 2 ^ (2 / 12), 1e-9, name .. ": two semitones above the reference")
    assert_near(notes.freeze_reference(3), 62, 1e-9, name .. ": the reference stays")
    assert_equal(notes.held(3), 2, name .. ": two notes held"); assert_equal(notes.pool_used(), 1, name .. ": one from the pool")
  end)

  -- The own key lifted during the freeze, then the unfreeze: Lua sends no
  -- note command (the engine keeps the park on the own voice synth and
  -- restarts the stream as a voice synth, silently: rulings 44, 45, 49);
  -- the records stand, the reference goes, and the own key pressed again
  -- unparks the own note with the retrigger as its one accent (ruling 47)
  stage("the unfreeze under the chord", function(name)
    note_off(2, 64)
    assert_equal(note_path(context), "noteOff 2 0 0", name .. ": the own key lifted during the freeze parks it")
    context.clear_engine_calls()
    params:set("v3_freeze", 0)
    assert_true(setgrain_index("freeze") ~= nil, name .. ": the unfreeze sent")
    assert_equal(note_path(context), "", name .. ": and no note command")
    assert_equal(notes.freeze_reference(3), nil, name .. ": the reference goes")
    local own = notes.slots(3)[1]
    assert_true(own.slot == 1 and own.parked, name .. ": the own note is still parked")
    assert_equal(notes.held(3), 1, name .. ": the stream's note still held"); assert_equal(notes.pool_used(), 1)
    context.clear_engine_calls()
    note_on(2, 62)
    assert_equal(note_path(context), "noteOn 2 0, retrigger 2", name .. ": unparked, then accented")
  end)

  -- A scene recall under the chord: the scene's buffer source comes back
  -- with one full sync, the engine restarts the held notes on it, and Lua
  -- plays, releases and parks nothing: a recall leaves held notes held
  -- (design §2.1)
  stage("a scene recall under the chord", function(name)
    recall_scene(1)
    assert_equal(note_path(context), "setGrainSource 2 1", name .. ": one source switch, no note command")
    assert_true(S.voices[3].active, name .. ": voice 3 runs on")
    assert_equal(notes.held(3), 2, name .. ": both notes held"); assert_equal(notes.pool_used(), 1, name .. ": the pool's one")
    lfo_step()
    assert_equal(#context.calls_named("noteExpression"), 0, name .. ": no expression resent")
  end)

  -- The keys lifted, in release mode (auto, an MPE mode): the keys whose
  -- notes the freeze cut send nothing, the stream's key releases its note,
  -- and the last key stops the voice, whose stop ends its notes; the pool
  -- ends empty
  stage("the keys lifted", function(name)
    note_off(3, 66); note_off(4, 69); note_off(5, 73)
    assert_equal(note_path(context), "", name .. ": the cut notes' keys send nothing")
    note_off(6, 69)
    assert_equal(note_path(context), "noteOff 2 4 0", name .. ": the stream's note released")
    context.clear_engine_calls()
    note_off(2, 62)
    assert_equal(note_path(context), "voiceOff 2", name .. ": the last key stops voice 3")
    assert_true(not S.voices[3].active, name .. ": voice 3 stopped")
    for voice = 1, S.constants.NUM_VOICES do
      assert_equal(notes.held(voice), 0, name .. ": voice " .. voice .. " holds no note")
    end
    assert_equal(notes.pool_used(), 0, name .. ": the pool ends empty")
    assert_equal(next(S.midi_state.note_voice), nil, name .. ": no key down")
  end)
end)

end

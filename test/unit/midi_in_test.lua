-- test/unit/midi_in_test.lua
-- MIDI input: notes, velocity, note-off modes, pitchbend, the device param
-- and hot-plug (lib/midi_in.lua)
-- Run alone: lua test/run.lua midi_in

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value = h.load_strata, h.find_upvalue, h.local_value
local next_frame, finish_startup, deep_copy = h.next_frame, h.finish_startup, h.deep_copy
local show_page, assert_screen_layout = h.show_page, h.assert_screen_layout

test("MIDI notes set pitch per source, start or retrigger the voice with velocity", function()
  local context = load_strata(); finish_startup(context)
  context.midi.send(1, { type = "note_on", note = 69, vel = 127, ch = 3 })   -- voice 3, off
  assert_near(params:get("v3_freq"), 440, 0.01); assert_true(local_value("voices")[3].active)
  local rt = context.calls_named("retrigger"); assert_equal(rt[#rt].args[1], 2); assert_near(rt[#rt].args[2], 1, 1e-9)
  params:set("v1_source", 2)
  context.midi.send(1, { type = "note_on", note = 72, vel = 64, ch = 1 })
  assert_near(params:get("v1_buf_rate"), 2, 1e-6); rt = context.calls_named("retrigger"); assert_near(rt[#rt].args[2], 64 / 127, 1e-9)
  params:set("v2_source", 10); context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 2 })  -- input source: no error
  context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 9 })  -- no voice: ignored
  params:set("v1_source", 1); params:set("midi_channel_mode", 2)        -- omni -> selected voice (1, synth again)
  context.midi.send(1, { type = "note_on", note = 57, vel = 100, ch = 9 })
  assert_near(params:get("v1_freq"), 220, 0.01)
end)

test("MIDI note details: start order, exact pitch, clamping, ignored channels", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  -- a stopped voice is started (voiceOn) before the retrigger
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 61, vel = 100, ch = 4 })
  local names = {}
  for _, call in ipairs(context.engine_calls) do table.insert(names, call.name) end
  local voice_on_at, retrigger_at
  for index, name in ipairs(names) do
    if name == "voiceOn" then voice_on_at = voice_on_at or index end
    if name == "retrigger" then retrigger_at = index end
  end
  assert_true(voice_on_at and retrigger_at and voice_on_at < retrigger_at, "voiceOn, then retrigger")
  assert_true(voices[4].active, "note on starts voice 4")
  -- equal temperament is not rounded to whole hertz
  assert_near(params:get("v4_freq"), 13.75 * 2 ^ ((61 - 9) / 12), 0.01, "note 61 = 277.18 Hz")
  -- a running voice is only retriggered (no second voiceOn)
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 62, vel = 50, ch = 4 })
  assert_equal(#context.calls_named("voiceOn"), 0, "running voice: no voiceOn")
  assert_equal(#context.calls_named("retrigger"), 1, "running voice: one retrigger")
  -- pitch is clamped to the voice's range
  context.midi.send(1, { type = "note_on", note = 127, vel = 100, ch = 4 })
  assert_near(params:get("v4_freq"), select(2, param_range("v4_freq")), 1e-9, "high notes clamp to the freq maximum")
  context.midi.send(1, { type = "note_on", note = 0, vel = 100, ch = 4 })
  assert_near(params:get("v4_freq"), (param_range("v4_freq")), 1e-9, "low notes clamp to the freq minimum")
  params:set("v5_source", 3)
  context.midi.send(1, { type = "note_on", note = 120, vel = 100, ch = 5 })
  assert_near(params:get("v5_buf_rate"), 4, 1e-9, "buffer rate clamps to 4")
  context.midi.send(1, { type = "note_on", note = 0, vel = 100, ch = 5 })
  assert_near(params:get("v5_buf_rate"), 0.25, 1e-9, "buffer rate clamps to 0.25")
  -- an input-sourced voice takes no pitch but still starts and accents
  params:set("v6_source", 10)
  local freq_before, rate_before = params:get("v6_freq"), params:get("v6_buf_rate")
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 90, vel = 127, ch = 6 })
  assert_equal(params:get("v6_freq"), freq_before); assert_equal(params:get("v6_buf_rate"), rate_before)
  assert_true(voices[6].active and #context.calls_named("retrigger") == 1, "input voice started and accented")
  -- per voice: channels 8-16 address no voice; other message types are ignored
  context.clear_engine_calls()
  for channel = 8, 16 do context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = channel }) end
  context.midi.send(1, { type = "cc", cc = 1, val = 64, ch = 1 })
  context.midi.send(1, { type = "program_change", val = 3, ch = 1 })
  context.midi.send(1, { type = "clock" })
  assert_equal(#context.engine_calls, 0, "nothing reaches the engine")
end)

test("note off mode and pitchbend", function()
  local context = load_strata(); finish_startup(context)
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 }); assert_true(local_value("voices")[1].active)
  params:set("midi_note_off", 2); context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 })
  assert_true(not local_value("voices")[1].active)
  context.midi.send(1, { type = "pitchbend", val = 8192 + 8191, ch = 2 })
  local calls = context.calls_named("setVoiceParam"); local last = calls[#calls]
  assert_equal(last.args[2], "bend"); assert_near(last.args[3], 2 ^ (2 / 12), 1e-3)
end)

test("voice off mode: the voice stops when its last held note is released", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  params:set("midi_note_off", 2)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  context.midi.send(1, { type = "note_on", note = 64, vel = 100, ch = 3 })
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 3 })
  assert_true(voices[3].active, "another note is still held")
  context.midi.send(1, { type = "note_on", note = 64, vel = 0, ch = 3 })   -- velocity 0 = note off
  assert_true(not voices[3].active, "last note released: voice off")
  -- a note during the release starts the voice again through voiceOn (the
  -- engine re-gates the releasing synths)
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 67, vel = 90, ch = 3 })
  assert_true(voices[3].active); assert_equal(#context.calls_named("voiceOn"), 1)
  -- omni: a note off reaches the voice its note on started, even if the selection moved
  params:set("midi_channel_mode", 2)
  context.midi.send(1, { type = "note_on", note = 48, vel = 100, ch = 1 })   -- selected voice 1
  local _, set_selected = find_upvalue("selected_voice"); set_selected(5)
  context.midi.send(1, { type = "note_off", note = 48, vel = 0, ch = 1 })
  assert_true(not voices[1].active, "voice 1 stops on its note's release")
  assert_true(not voices[5].active, "the newly selected voice is untouched")
  -- ignore mode leaves voices running
  params:set("midi_note_off", 1)
  context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 1 })
  context.midi.send(1, { type = "note_off", note = 50, vel = 0, ch = 1 })
  assert_true(voices[5].active, "ignore: note off does nothing")
end)

test("omni, voice off: a repeated note on after the selection moved releases the first voice", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  local midi_state = local_value("midi_state")
  params:set("midi_channel_mode", 2); params:set("midi_note_off", 2)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_true(voices[1].active, "voice 1 starts")
  local _, set_selected = find_upvalue("selected_voice"); set_selected(2)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_equal(next(midi_state.held[1]), nil, "voice 1 holds nothing")
  assert_true(not voices[1].active, "voice 1 is released by the repeated note")
  assert_true(voices[2].active, "voice 2 runs")
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 })
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 })
  assert_true(not voices[2].active, "voice 2 stops on the note off")
  assert_equal(next(midi_state.held[1]), nil); assert_equal(next(midi_state.held[2]), nil)
end)

test("omni: the same note on two channels holds the voice until both are off", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  local midi_state = local_value("midi_state")
  params:set("midi_channel_mode", 2); params:set("midi_note_off", 2)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 2 })
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 })
  assert_true(voices[1].active, "channel 2 still holds the note")
  assert_true(midi_state.held[1][60], "the note stays held")
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 2 })
  assert_true(not voices[1].active, "both off: stopped")
  assert_equal(next(midi_state.held[1]), nil)
end)

-- The final review's item 4: the hold release is the module's own
test("releasing a note's hold adds no script global", function()
  load_strata()
  assert_equal(rawget(_G, "release_note_hold"), nil, "release_note_hold is local to lib/midi_in.lua")
end)

test("omni, voice off: the previous voice keeps running while it holds another note or another channel maps the note", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  local midi_state = local_value("midi_state")
  local _, set_selected = find_upvalue("selected_voice")
  params:set("midi_channel_mode", 2); params:set("midi_note_off", 2)
  -- (a) voice 1 holds notes 60 and 64; the repeated 60 moves to voice 2
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  context.midi.send(1, { type = "note_on", note = 64, vel = 100, ch = 1 })
  set_selected(2)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_true(voices[1].active, "voice 1 still holds note 64")
  assert_true(not midi_state.held[1][60] and midi_state.held[1][64], "only note 64 stays held on voice 1")
  assert_true(midi_state.held[2][60], "voice 2 holds note 60")
  context.midi.send(1, { type = "note_off", note = 64, vel = 0, ch = 1 })
  assert_true(not voices[1].active, "voice 1 stops with its last note")
  assert_equal(next(midi_state.held[1]), nil)
  -- (b) channels 1 and 2 both map note 70 to voice 1; channel 1's repeat moves to voice 3
  set_selected(1)
  context.midi.send(1, { type = "note_on", note = 70, vel = 100, ch = 1 })
  context.midi.send(1, { type = "note_on", note = 70, vel = 100, ch = 2 })
  set_selected(3)
  context.midi.send(1, { type = "note_on", note = 70, vel = 100, ch = 1 })
  assert_true(voices[1].active, "channel 2 still maps note 70 to voice 1")
  assert_true(midi_state.held[1][70], "note 70 stays held on voice 1")
  context.midi.send(1, { type = "note_off", note = 70, vel = 0, ch = 2 })
  assert_true(not voices[1].active, "voice 1 stops when channel 2's note is off")
  assert_equal(next(midi_state.held[1]), nil)
end)

test("omni, voice off ignored: a repeated note on after the selection moved clears the first voice's hold and leaves it running", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  local midi_state = local_value("midi_state")
  params:set("midi_channel_mode", 2); params:set("midi_note_off", 1)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  local _, set_selected = find_upvalue("selected_voice"); set_selected(2)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_equal(next(midi_state.held[1]), nil, "voice 1 holds nothing")
  assert_true(voices[1].active, "ignore mode keeps voice 1 running")
  assert_true(midi_state.held[2][60], "voice 2 holds the note")
end)

test("a MIDI-held voice stopped another way: its note off changes nothing and leaves nothing held", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  local midi_state = local_value("midi_state")
  context.grid.plug(1, 16, 16)
  params:set("midi_note_off", 2)
  for voice_idx = 1, 7 do
    if voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  capture_scene(1)   -- every voice off
  local function assert_nothing_held(voice_idx, channel, note, where)
    assert_equal(next(midi_state.held[voice_idx]), nil, where .. ": no note held on voice " .. voice_idx)
    local channel_notes = midi_state.note_voice[channel]
    assert_equal(channel_notes and channel_notes[note], nil, where .. ": note " .. note .. " not mapped")
  end
  -- locking a held voice never stops it, and the note off then stops it as
  -- voice off mode says (MAIN's K3 and the arc button lock through toggle_lock)
  local _, set_selected = find_upvalue("selected_voice"); set_selected(2)
  show_page("MAIN")
  context.midi.send(1, { type = "note_on", note = 62, vel = 100, ch = 2 })
  toggle_lock(2)
  assert_true(voices[2].active and local_value("frozen")[2], "a lock keeps the held voice running")
  context.midi.send(1, { type = "note_off", note = 62, vel = 0, ch = 2 })
  assert_true(not voices[2].active, "lock: the note off stops the locked voice")
  assert_nothing_held(2, 2, 62, "lock")
  toggle_lock(2)
  local stoppers = {
    { name = "grid voice toggle", voice = 4, stop = function() context.grid.press(1, 8 + 4, 14, 1) end },
    { name = "scene recall", voice = 6, stop = function() recall_scene(1, 0) end },
  }
  for _, stopper in ipairs(stoppers) do
    local voice_idx = stopper.voice
    context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = voice_idx })
    assert_true(voices[voice_idx].active, stopper.name .. ": the note started the voice")
    assert_true(midi_state.held[voice_idx][60], stopper.name .. ": note 60 held")
    stopper.stop()
    assert_true(not voices[voice_idx].active, stopper.name .. ": the voice stopped")
    context.clear_engine_calls()
    local frozen = deep_copy(local_value("frozen"))
    context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = voice_idx })
    assert_equal(#context.engine_calls, 0, stopper.name .. ": the note off sends nothing")
    for other = 1, 7 do
      assert_true(not voices[other].active, stopper.name .. ": voice " .. other .. " still off")
      assert_equal(local_value("frozen")[other], frozen[other], stopper.name .. ": voice " .. other .. " freeze unchanged")
    end
    assert_nothing_held(voice_idx, voice_idx, 60, stopper.name)
  end
end)

test("pitchbend: range, buffer voices, stopped voices, restarts and resets", function()
  local context = load_strata(); finish_startup(context)
  local function last_bend(engine_voice)
    local value
    for _, call in ipairs(context.calls_named("setVoiceParam")) do
      if call.args[1] == engine_voice and call.args[2] == "bend" then value = call.args[3] end
    end
    return value
  end
  context.midi.send(1, { type = "pitchbend", val = 0, ch = 1 })
  assert_near(last_bend(0), 2 ^ (-2 / 12), 1e-9, "full down = -2 semitones")
  context.midi.send(1, { type = "pitchbend", val = 8192, ch = 1 })
  assert_near(last_bend(0), 1, 1e-12, "center = 1")
  -- a buffer-sourced voice gets the same voice-level bend (the engine passes it to strataGrainBuf)
  params:set("v2_source", 4)
  context.clear_engine_calls()
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 2 })
  assert_near(last_bend(1), 2 ^ (1 / 12), 1e-9, "buffer voice bend")
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    assert_true(call.args[2] ~= "bend", "bend is not a grain param")
  end
  -- bend is transient: not a param and not in scenes
  assert_equal(params.lookup["v2_bend"], nil, "no bend param")
  capture_scene(1)
  assert_equal(local_value("scenes")[1].data.voices[2].params.bend, nil, "scenes do not capture bend")
  -- a stopped voice remembers the wheel and gets it when it starts
  context.clear_engine_calls()
  context.midi.send(1, { type = "pitchbend", val = 8192 - 4096, ch = 4 })
  assert_equal(last_bend(3), nil, "stopped voice: nothing sent")
  toggle_voice(4)
  assert_near(last_bend(3), 2 ^ (-1 / 12), 1e-9, "starting the voice sends the held bend")
  -- changing the channel mode re-centers every bent voice
  context.clear_engine_calls()
  params:set("midi_channel_mode", 2)
  assert_near(last_bend(1), 1, 1e-12, "voice 2 re-centered"); assert_near(last_bend(3), 1, 1e-12, "voice 4 re-centered")
  assert_equal(last_bend(0), nil, "an unbent voice gets nothing")
end)

test("omni pitchbend follows the selection: the old voice re-centers, the new one takes the wheel", function()
  local context = load_strata(); finish_startup(context)
  local bend = local_value("midi_state").bend
  local function last_bend(engine_voice)
    local value
    for _, call in ipairs(context.calls_named("setVoiceParam")) do
      if call.args[1] == engine_voice and call.args[2] == "bend" then value = call.args[3] end
    end
    return value
  end
  local up = 2 ^ (1 / 12)
  params:set("midi_channel_mode", 2); show_page("MAIN")
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 1 })   -- bends voice 1
  context.clear_engine_calls()
  enc(2, 1)   -- voice 2, wheel still up
  assert_near(last_bend(0), 1, 1e-12, "voice 1 re-centered"); assert_equal(bend[1], 1)
  assert_near(last_bend(1), up, 1e-9, "voice 2 takes the wheel"); assert_near(bend[2], up, 1e-9)
  -- a stopped voice keeps the wheel for its start
  context.clear_engine_calls()
  enc(2, 1)   -- voice 3 (stopped)
  assert_near(last_bend(1), 1, 1e-12, "voice 2 re-centered")
  assert_equal(last_bend(2), nil, "nothing sent to a stopped voice"); assert_near(bend[3], up, 1e-9)
  toggle_voice(3); assert_near(last_bend(2), up, 1e-9, "starting it sends the wheel")
  -- MAIN's E2 again (BUFFER's E2 picks a slot since 3.1)
  show_page("MAIN"); context.clear_engine_calls()
  enc(2, -1)
  assert_near(last_bend(2), 1, 1e-12, "voice 3 re-centered"); assert_near(last_bend(1), up, 1e-9, "voice 2 bent again")
  -- E2 against the end of the list changes nothing
  show_page("MAIN"); enc(2, -1)   -- voice 1
  context.clear_engine_calls(); enc(2, -1)
  assert_equal(#context.calls_named("setVoiceParam"), 0, "no selection change, no bend")
  -- wheel centered: moving the selection sends nothing
  context.midi.send(1, { type = "pitchbend", val = 8192, ch = 1 })
  context.clear_engine_calls(); enc(2, 1)
  assert_equal(#context.calls_named("setVoiceParam"), 0, "a centered wheel moves nothing")
  -- per voice: bends stay with their channels' voices
  params:set("midi_channel_mode", 1)
  show_page("MAIN"); enc(2, -1); enc(2, -1); enc(2, -1)   -- voice 1 selected
  enc(2, 1)                                   -- voice 2 selected
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 2 })   -- bends the selected voice 2
  assert_near(bend[2], up, 1e-9)
  context.clear_engine_calls(); enc(2, 1)     -- the selection leaves the bent voice
  assert_equal(#context.calls_named("setVoiceParam"), 0, "per voice mode: the selection does not move bends")
  assert_near(bend[2], up, 1e-9, "voice 2 stays bent"); assert_equal(bend[3], 1, "voice 3 gets nothing")
end)

test("a bent stopped voice is re-centered by a reset without a message to the engine (#413)", function()
  local context = load_strata(); finish_startup(context)
  local bend = local_value("midi_state").bend
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 4 })   -- voice 4 is stopped
  assert_true(bend[4] ~= 1)
  context.clear_engine_calls()
  params:set("midi_channel_mode", 2)
  assert_equal(bend[4], 1, "re-centered")
  assert_equal(#context.calls_named("setVoiceParam"), 0, "nothing sent to a stopped voice")
end)

test("unplugging a device on another port leaves the selected port's held notes (#413)", function()
  local context = load_strata(); finish_startup(context)
  context.midi.plug(1, "keys"); context.midi.plug(2, "pads")
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  context.midi.unplug(2)
  assert_true(local_value("midi_state").held[3][60], "the note stays held")
end)

test("voice off: an unplug stops the voices its held keys were holding, and no other (#407)", function()
  local context = load_strata(); finish_startup(context)
  params:set("midi_note_off", 2)
  local voices = local_value("voices")
  context.midi.plug(1, "keys")
  assert_true(voices[2].active, "voice 2 runs from the start, no key on it")
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  assert_true(voices[3].active)
  context.midi.unplug(1)
  assert_true(not voices[3].active, "the held key's voice stops")
  assert_true(voices[2].active, "another voice is untouched")
end)

test("voice off: a key held across a channel mode change still releases its own voice (#407)", function()
  local context = load_strata(); finish_startup(context)
  params:set("midi_note_off", 2)
  local voices = local_value("voices")
  assert_true(voices[1].active, "voice 1, the selected voice, runs from the start")
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  params:set("midi_channel_mode", 2)
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 3 })
  assert_true(not voices[3].active, "voice 3 stops")
  assert_true(voices[1].active, "voice 1 is left alone")
  -- the other way round
  local_value("S").selected_voice = 5
  context.midi.send(1, { type = "note_on", note = 62, vel = 100, ch = 2 })
  assert_true(voices[5].active)
  params:set("midi_channel_mode", 1)
  context.midi.send(1, { type = "note_off", note = 62, vel = 0, ch = 2 })
  assert_true(not voices[5].active, "voice 5 stops")
  assert_true(voices[2].active, "voice 2 is left alone")
end)

test("voice off: a port change stops the voices the old port's keys held (#407)", function()
  local context = load_strata(); finish_startup(context)
  params:set("midi_note_off", 2)
  local voices = local_value("voices")
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  params:set("midi_device", 2)
  assert_true(not voices[3].active)
end)

test("a device plugged in or out before init raises nothing, and init then attaches it (#469)", function()
  local context = load_strata({ before_init = function(context)
    context.midi.plug(1, "keys")
    context.midi.unplug(1)
    context.midi.plug(1, "keys")
  end })
  finish_startup(context)
  context.midi.send(1, { type = "note_on", note = 69, vel = 100, ch = 1 })
  assert_near(params:get("v1_freq"), 440, 0.01, "the device plays")
end)

test("ignore mode: a panic CC stops a voice a released key started, never one started elsewhere (#529)", function()
  for _, cc in ipairs({ 123, 120 }) do
    local context = load_strata(); finish_startup(context)
    local voices = local_value("voices")
    assert_equal(params:get("midi_note_off"), 1, "ignore mode")
    assert_true(not voices[3].active)
    context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
    assert_true(voices[3].active, "the key starts voice 3")
    context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 3 })
    assert_true(voices[3].active, "the release leaves it sounding")
    toggle_voice(4)   -- started from the norns
    assert_true(voices[4].active)
    context.midi.send(1, { type = "cc", cc = cc, val = 0, ch = 1 })
    assert_true(not voices[3].active, "cc " .. cc .. " stops the voice the key started")
    assert_true(voices[4].active, "a voice started from the norns stays")
    assert_true(voices[1].active and voices[2].active, "the voices running at the start stay")
  end
end)

test("a voice MIDI started and the norns restarted is not the panic's (#529)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  assert_true(voices[3].active, "the key starts voice 3")
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 3 })
  toggle_voice(3); assert_true(not voices[3].active, "stopped from the norns")
  toggle_voice(3); assert_true(voices[3].active, "started again from the norns")
  context.midi.send(1, { type = "cc", cc = 123, val = 0, ch = 1 })
  assert_true(voices[3].active, "the panic leaves it")
end)

test("a source change keeps a MIDI-started voice the panic's (#529)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 3 })
  assert_true(voices[3].active, "the released key leaves voice 3 sounding")
  params:set("v3_source", 2)
  assert_true(voices[3].active)
  context.midi.send(1, { type = "cc", cc = 123, val = 0, ch = 1 })
  assert_true(not voices[3].active, "the panic stops it")
end)

test("all notes off and all sound off release every held note and stop its voice (#529)", function()
  for _, cc in ipairs({ 123, 120 }) do
    local context = load_strata(); finish_startup(context)
    params:set("midi_note_off", 2)
    local voices = local_value("voices")
    local midi_state = local_value("midi_state")
    context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
    context.midi.send(1, { type = "note_on", note = 64, vel = 100, ch = 3 })
    assert_true(voices[2].active, "voice 2 runs from the start, no key on it")
    context.midi.send(1, { type = "cc", cc = cc, val = 0, ch = 1 })
    assert_true(not voices[1].active and not voices[3].active, "cc " .. cc .. " stops the voices keys held")
    assert_true(voices[2].active, "a voice no key held stays")
    for i = 1, local_value("NUM_VOICES") do assert_equal(next(midi_state.held[i]), nil) end
    assert_equal(next(midi_state.note_voice), nil)
    -- another CC does nothing
    context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
    context.midi.send(1, { type = "cc", cc = 121, val = 0, ch = 1 })
    assert_true(voices[1].active and midi_state.held[1][60], "other CCs change nothing")
  end
end)

test("MIDI device param, hot-plug and the SETUP page", function()
  local context = load_strata(); finish_startup(context)
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  -- the value drawn on the row labeled `label`: right-aligned at x 124, on
  -- the label's baseline (nil if there is none)
  local function row_value(label)
    local label_entry
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == label and entry.align == "left" then label_entry = entry end
    end
    if not label_entry then return nil end
    for _, entry in ipairs(context.screen.texts) do
      if entry.y == label_entry.y and entry.align == "right" and entry.x == 124 then return entry.text end
    end
  end
  assert_equal(params:get("midi_device"), 1); assert_equal(params:get("midi_channel_mode"), 1)
  assert_equal(params:get("midi_note_off"), 1)
  assert_equal(params:string("midi_channel_mode"), "per voice")
  show_page("SETUP")
  assert_true(screen_has("midi 1: none"), "no device on port 1")
  assert_equal(row_value("channels"), "per voice", "the channels row shows the channel mode")
  context.midi.plug(1, "keys"); next_frame(context)
  assert_true(screen_has("midi 1: keys"), "plugging a device redraws SETUP")
  -- E3 on the first field selects the port; events on the old port no longer reach Strata
  enc(3, 1); next_frame(context); assert_equal(params:get("midi_device"), 2)
  assert_true(screen_has("midi 2: none"))
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_equal(#context.engine_calls, 0, "port 1 is no longer listened to")
  context.midi.send(2, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_true(#context.calls_named("retrigger") == 1, "port 2 is")
  -- E2 then E3 sets the channel mode
  enc(2, 1); enc(3, 1); next_frame(context); assert_equal(params:get("midi_channel_mode"), 2)
  assert_equal(row_value("channels"), "omni to selected", "the channels row shows the new mode")
  assert_true(screen_has("midi 2: stub midi"), "the device that played is shown")
  -- unplugging the selected port's device shows none on the next frame
  context.midi.unplug(2); next_frame(context)
  assert_true(screen_has("midi 2: none"), "unplugging redraws SETUP without the device")
  -- a long device name is cut to fit the screen
  context.midi.plug(2, "Very Long Manufacturer Name USB MIDI Interface Port 1"); next_frame(context)
  local midi_line
  for _, entry in ipairs(context.screen.texts) do
    if entry.text:find("^midi 2: ") then midi_line = entry.text end
  end
  assert_true(midi_line and #midi_line < #"midi 2: Very Long Manufacturer Name USB MIDI Interface Port 1", "name shortened")
  assert_screen_layout(context, "SETUP with a long MIDI device name")
  assert_equal(select(2, param_range("midi_device")), #midi.vports, "every norns port can be chosen (#333)")
  params:set("midi_device", #midi.vports)
  assert_equal(params:get("midi_device"), #midi.vports, "the last port is selectable")
  context.clear_engine_calls()
  context.midi.send(#midi.vports, { type = "note_on", note = 69, vel = 100, ch = 1 })
  assert_equal(#context.calls_named("retrigger"), 1, "a device on the last port plays")
  params:set("midi_device", 2)
  -- a re-plug reattaches: the vport still delivers to Strata
  context.clear_engine_calls()
  context.midi.send(2, { type = "note_on", note = 62, vel = 100, ch = 1 })
  assert_equal(#context.calls_named("retrigger"), 1, "re-plugged device plays")
  cleanup()
  assert_equal(midi.connect(2).event, nil, "cleanup detaches the MIDI handler")
end)


test("a quantized voice's MIDI notes snap to the scale, in its freq or buffer rate", function()
  local context = load_strata(); finish_startup(context)
  local function option_index(param_id, name)
    for index, option in ipairs(params:lookup_param(param_id).options) do if option == name then return index end end
  end
  local function freq_of(note) return 13.75 * 2 ^ ((note - 9) / 12) end
  params:set("scale", option_index("scale", "Minor Pentatonic"))  -- C, Eb, F, G, Bb
  params:set("v4_quantize", 1)
  local expected = { [60] = 60, [61] = 60, [62] = 63, [64] = 63, [66] = 65, [68] = 67, [69] = 70, [71] = 70, [72] = 72 }
  for note, tone in pairs(expected) do
    context.midi.send(1, { type = "note_on", note = note, vel = 100, ch = 4 })
    assert_near(params:get("v4_freq"), freq_of(tone), 1e-6, "note " .. note .. " plays " .. tone)
  end
  -- a note past the freq range plays the scale's last tone inside it (Bb6: 2000 Hz is note 95.2)
  context.midi.send(1, { type = "note_on", note = 127, vel = 100, ch = 4 })
  assert_near(params:get("v4_freq"), freq_of(94), 1e-6, "a high note plays the highest tone in range")
  context.midi.send(1, { type = "note_on", note = 0, vel = 100, ch = 4 })
  assert_near(params:get("v4_freq"), freq_of(17), 1e-6, "a low note plays the lowest (F0: 20 Hz is note 15.5)")
  -- a buffer voice: rate from the snapped note
  params:set("v5_source", 3); params:set("v5_quantize", 1)
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 5 })
  assert_near(params:get("v5_buf_rate"), 2 ^ (5 / 12), 0.006, "F#4 reads at F4's rate (the rate's 0.01 step)")
  -- quantize off: exact notes; scale off with quantize on: semitones
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 6 })
  assert_near(params:get("v6_freq"), freq_of(66), 1e-6, "an unquantized voice plays F#4")
  params:set("scale", 1)
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 4 })
  assert_near(params:get("v4_freq"), freq_of(66), 1e-6, "scale off quantizes to semitones: F#4 stays")
  local rt = context.calls_named("retrigger"); assert_equal(rt[#rt].args[1], 3, "and the note still accents")
end)

-- SYSTEM > DEVICES moves a device between vports through update_devices()
-- only: neither midi.add nor midi.remove runs (#295)
test("a MIDI device moved off the selected port in SYSTEM > DEVICES gives up the notes it held", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  params:set("midi_note_off", 2)
  context.midi.plug(1, "keys"); next_frame(context)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  context.midi.send(1, { type = "pitchbend", val = 16383, ch = 3 })
  local midi_state = local_value("S").midi_state
  assert_true(voices[3].active and next(midi_state.held[3]) ~= nil, "a note holds voice 3")
  assert_true(midi_state.bend[3] > 1, "bent")
  show_page("SETUP")
  _menu.set_mode(true); context.midi.reassign(1, 2); _menu.set_mode(false)
  next_frame(context)
  for i = 1, local_value("NUM_VOICES") do
    assert_equal(next(midi_state.held[i]), nil, "no note held on voice " .. i)
  end
  assert_equal(next(midi_state.note_voice), nil, "no note remembered")
  assert_equal(midi_state.bend[3], 1, "the bend is centered")
  local shown = false
  for _, entry in ipairs(context.screen.texts) do if entry.text == "midi 1: none" then shown = true end end
  assert_true(shown, "SETUP shows the port as empty")
end)

test("a menu visit that moves nothing keeps the held notes", function()
  local context = load_strata(); finish_startup(context)
  params:set("midi_note_off", 2)
  context.midi.plug(1, "keys")
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  local midi_state = local_value("S").midi_state
  _menu.set_mode(true); _menu.set_mode(false)
  assert_true(next(midi_state.held[3]) ~= nil, "the note is still held")
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 3 })
  assert_equal(next(midi_state.held[3]), nil, "its note off releases it")
  assert_true(not local_value("voices")[3].active, "and the voice stops")
end)

test("a device moved onto the selected port in SYSTEM > DEVICES plays", function()
  local context = load_strata(); finish_startup(context)
  context.midi.plug(2, "keys")
  show_page("SETUP"); next_frame(context)
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do if entry.text == text then return true end end
    return false
  end
  assert_true(screen_has("midi 1: none"), "SETUP shows port 1 with no device")
  local pages = local_value("UI_PAGES")
  assert_true(not pages.screen_dirty, "nothing waits to be drawn")
  -- the move, then the reconcile alone (the menu's other close hooks ask for
  -- redraws too, so only a direct call shows what this one asks for)
  context.midi.reassign(2, 1)
  assert_true(not pages.screen_dirty, "the move itself asks for no redraw")
  local_value("S").lib.midi_in.reconcile()
  assert_true(pages.screen_dirty, "the reconcile requested a redraw")
  next_frame(context)
  assert_true(screen_has("midi 1: keys"), "SETUP shows the device's name")
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_equal(#context.calls_named("retrigger"), 1, "port 1 plays")
end)

test("two MIDI devices swapped in SYSTEM > DEVICES give up the held notes", function()
  local context = load_strata(); finish_startup(context)
  params:set("midi_note_off", 2)
  context.midi.plug(1, "keys"); context.midi.plug(2, "pads")
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  local midi_state = local_value("S").midi_state
  assert_true(next(midi_state.held[3]) ~= nil, "a note is held from port 1")
  show_page("SETUP"); next_frame(context)
  _menu.set_mode(true)
  -- as norns ends up: keys on port 2, pads on port 1
  context.midi.reassign(1, 2)  -- port 2 takes keys' name; port 1 becomes none
  midi.connect(1).name = "pads"; midi.update_devices()
  _menu.set_mode(false); next_frame(context)
  assert_equal(midi.connect(1).device.name, "pads", "pads is on port 1")
  assert_equal(midi.connect(2).device.name, "keys", "keys is on port 2")
  for i = 1, local_value("NUM_VOICES") do
    assert_equal(next(midi_state.held[i]), nil, "no note held on voice " .. i)
  end
  assert_equal(next(midi_state.note_voice), nil, "no note remembered")
  local shown = false
  for _, entry in ipairs(context.screen.texts) do if entry.text == "midi 1: pads" then shown = true end end
  assert_true(shown, "SETUP shows the other device's name")
end)

test("an unplug of the selected port's device, then a menu visit, resets once", function()
  local context = load_strata(); finish_startup(context)
  params:set("midi_note_off", 2)
  context.midi.plug(1, "keys")
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  local midi_state = local_value("S").midi_state
  context.midi.unplug(1)
  assert_equal(next(midi_state.held[3]), nil, "the unplug reset the notes")
  context.midi.plug(1, "keys")
  context.midi.send(1, { type = "note_on", note = 62, vel = 100, ch = 3 })
  _menu.set_mode(true); _menu.set_mode(false)
  assert_true(midi_state.held[3][62], "the new note survives the menu visit: no second reset")
end)

end

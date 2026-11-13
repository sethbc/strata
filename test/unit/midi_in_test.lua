-- test/unit/midi_in_test.lua
-- MIDI input: notes and chords through the allocator, velocity, the note
-- off modes (latch and release), pitchbend, pressure and MPE, the note tap,
-- the device param and hot-plug (lib/midi_in.lua)
-- Run alone: lua test/run.lua midi_in

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value = h.load_strata, h.find_upvalue, h.local_value
local next_frame, finish_startup, deep_copy = h.next_frame, h.finish_startup, h.deep_copy
local show_page, assert_screen_layout = h.show_page, h.assert_screen_layout

local function note_on(context, channel, note, velocity, port)
  context.midi.send(port or 1, { type = "note_on", note = note, vel = velocity or 100, ch = channel })
end

local function note_off(context, channel, note, port)
  context.midi.send(port or 1, { type = "note_off", note = note, vel = 0, ch = channel })
end

-- A key pressed and lifted: in latch mode its note keeps sounding
local function press(context, channel, note, velocity)
  note_on(context, channel, note, velocity)
  note_off(context, channel, note)
end

-- MIDI's key for a note: channel * 128 + note
local function key_of(channel, note) return channel * 128 + note end

-- The names of the engine calls since the last clear, those in only (a
-- set) if given, joined by ", "
local function call_names(context, only)
  local names = {}
  for _, call in ipairs(context.engine_calls) do
    if not only or only[call.name] then table.insert(names, call.name) end
  end
  return table.concat(names, ", ")
end

local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

-- The noteExpression messages sent for voice's slot (Lua numbering) since
-- the last clear, each {bend, amp, position, size, main}
local function expressions(context, voice, slot)
  local list = {}
  for _, call in ipairs(context.calls_named("noteExpression")) do
    if call.args[1] == voice - 1 and call.args[2] == slot - 1 then
      table.insert(list, { bend = call.args[3], amp = call.args[4], position = call.args[5], size = call.args[6],
        main = call.args[7] })
    end
  end
  return list
end

local function option_index(param_id, name)
  for index, option in ipairs(params:lookup_param(param_id).options) do if option == name then return index end end
  error("no option " .. name .. " in " .. param_id)
end

local function freq_of(note) return 13.75 * 2 ^ ((note - 9) / 12) end

test("MIDI notes set pitch per source, start or retrigger the voice with velocity", function()
  local context = load_strata(); finish_startup(context)
  context.midi.send(1, { type = "note_on", note = 69, vel = 127, ch = 3 })   -- voice 3, off
  assert_near(params:get("v3_freq"), 440, 0.01); assert_true(local_value("voices")[3].active)
  local rt = context.calls_named("retrigger"); assert_equal(rt[#rt].args[1], 2); assert_near(rt[#rt].args[2], 1, 1e-9)
  params:set("v1_source", 2)
  context.midi.send(1, { type = "note_on", note = 72, vel = 64, ch = 1 })
  assert_near(params:get("v1_buf_rate"), 2, 1e-6); rt = context.calls_named("retrigger"); assert_near(rt[#rt].args[2], 64 / 127, 1e-9)
  params:set("v2_source", 10); context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 2 })
  assert_near(params:get("v2_grain_pitch"), 2 ^ (-10 / 12), 1e-9, "an input voice's grain pitch")
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
  -- the next key after the last one lifted: a running voice is only
  -- retriggered (no second voiceOn)
  note_off(context, 4, 61)
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 62, vel = 50, ch = 4 })
  assert_equal(#context.calls_named("voiceOn"), 0, "running voice: no voiceOn")
  assert_equal(#context.calls_named("retrigger"), 1, "running voice: one retrigger")
  note_off(context, 4, 62)
  -- pitch is clamped to the voice's range
  press(context, 4, 127)
  assert_near(params:get("v4_freq"), select(2, param_range("v4_freq")), 1e-9, "high notes clamp to the freq maximum")
  press(context, 4, 0)
  assert_near(params:get("v4_freq"), (param_range("v4_freq")), 1e-9, "low notes clamp to the freq minimum")
  params:set("v5_source", 3)
  press(context, 5, 120)
  assert_near(params:get("v5_buf_rate"), 4, 1e-9, "buffer rate clamps to 4")
  press(context, 5, 0)
  assert_near(params:get("v5_buf_rate"), 0.25, 1e-9, "buffer rate clamps to 0.25")
  -- an input-sourced voice takes its grain pitch (note 60 at 1, clamped to
  -- 4), starts and accents
  params:set("v6_source", 10)
  local freq_before, rate_before = params:get("v6_freq"), params:get("v6_buf_rate")
  context.clear_engine_calls()
  context.midi.send(1, { type = "note_on", note = 90, vel = 127, ch = 6 })
  assert_equal(params:get("v6_freq"), freq_before); assert_equal(params:get("v6_buf_rate"), rate_before)
  assert_near(params:get("v6_grain_pitch"), 4, 1e-9, "note 90 clamps to grain pitch 4")
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
  press(context, 1, 60); assert_true(local_value("voices")[1].active, "auto latches in per voice mode")
  params:set("midi_note_off", 2)
  -- a note off no note on played changes nothing (3.4's voice off stopped the channel's voice)
  note_off(context, 1, 62); assert_true(local_value("voices")[1].active, "a stray note off is ignored")
  press(context, 1, 60)
  assert_true(not local_value("voices")[1].active, "release: the key's lift stops the voice")
  context.midi.send(1, { type = "pitchbend", val = 8192 + 8191, ch = 2 })
  local calls = context.calls_named("setVoiceParam"); local last = calls[#calls]
  assert_equal(last.args[2], "bend"); assert_near(last.args[3], 2 ^ (2 / 12), 1e-3)
end)

test("release mode: the voice stops when its last held note is released", function()
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
  -- auto latches in a plain mode: voices keep running
  params:set("midi_note_off", 1)
  context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 1 })
  context.midi.send(1, { type = "note_off", note = 50, vel = 0, ch = 1 })
  assert_true(voices[5].active, "latch: note off does nothing")
end)

test("omni, release: a repeated note on after the selection moved releases the first voice", function()
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
  assert_true(midi_state.held[1][key_of(2, 60)], "channel 2's key stays held")
  assert_true(not midi_state.held[1][key_of(1, 60)], "channel 1's key is not")
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 2 })
  assert_true(not voices[1].active, "both off: stopped")
  assert_equal(next(midi_state.held[1]), nil)
end)

-- The final review's item 4: the hold release is the module's own
test("releasing a note's hold adds no script global", function()
  load_strata()
  assert_equal(rawget(_G, "release_note_hold"), nil, "release_note_hold is local to lib/midi_in.lua")
end)

test("omni, release: the previous voice keeps running while it holds another note or another channel maps the note", function()
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
  assert_true(not midi_state.held[1][key_of(1, 60)] and midi_state.held[1][key_of(1, 64)],
    "only note 64 stays held on voice 1")
  assert_true(midi_state.held[2][key_of(1, 60)], "voice 2 holds note 60")
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
  assert_true(midi_state.held[1][key_of(2, 70)], "channel 2's note 70 stays held on voice 1")
  context.midi.send(1, { type = "note_off", note = 70, vel = 0, ch = 2 })
  assert_true(not voices[1].active, "voice 1 stops when channel 2's note is off")
  assert_equal(next(midi_state.held[1]), nil)
end)

test("omni, latch: a repeated note on after the selection moved clears the first voice's hold and leaves it running", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  local midi_state = local_value("midi_state")
  params:set("midi_channel_mode", 2); params:set("midi_note_off", 1)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  local _, set_selected = find_upvalue("selected_voice"); set_selected(2)
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_equal(next(midi_state.held[1]), nil, "voice 1 holds no key")
  assert_true(voices[1].active, "latch keeps voice 1 running")
  assert_equal(local_value("S").lib.notes.held(1), 1, "and its note sounding")
  assert_true(midi_state.held[2][key_of(1, 60)], "voice 2 holds the note")
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
    assert_true(midi_state.held[voice_idx][key_of(voice_idx, 60)], stopper.name .. ": note 60 held")
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
  assert_true(local_value("midi_state").held[3][key_of(3, 60)], "the note stays held")
end)

test("release: an unplug stops the voices its held keys were holding, and no other (#407)", function()
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

test("release: a channel mode change stops the voices held keys were holding, and the note offs then reach none (#407)", function()
  local context = load_strata(); finish_startup(context)
  params:set("midi_note_off", 2)
  local voices = local_value("voices")
  assert_true(voices[1].active, "voice 1, the selected voice, runs from the start")
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  params:set("midi_channel_mode", 2)
  assert_true(not voices[3].active, "voice 3 stops at the change")
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 3 })
  assert_true(voices[1].active, "the note off leaves voice 1 alone")
  -- the other way round
  local_value("S").selected_voice = 5
  context.midi.send(1, { type = "note_on", note = 62, vel = 100, ch = 2 })
  assert_true(voices[5].active)
  params:set("midi_channel_mode", 1)
  assert_true(not voices[5].active, "voice 5 stops at the change")
  context.midi.send(1, { type = "note_off", note = 62, vel = 0, ch = 2 })
  assert_true(voices[2].active, "the note off leaves voice 2 alone")
end)

test("release: a port change stops the voices the old port's keys held (#407)", function()
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

test("latch: a panic CC stops a voice a released key started, never one started elsewhere (#529)", function()
  for _, cc in ipairs({ 123, 120 }) do
    local context = load_strata(); finish_startup(context)
    local voices = local_value("voices")
    assert_equal(params:get("midi_note_off"), 1, "auto: latch in per voice mode")
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
    assert_true(voices[1].active and midi_state.held[1][key_of(1, 60)], "other CCs change nothing")
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


-- #534: norns' PARAMS menu turns a param by d / 20 while K3 is held (its
-- delta_value calls the param's own delta), and norns' number param adds
-- that unrounded. Every number param Strata adds (its own and the LFO
-- library's, never norns' system params) steps whole numbers, as norns'
-- option param does, and midi_device then never raises
test("PARAMS' fine turn steps every one of Strata's number params whole; midi_device never raises (#534)", function()
  local system_count
  local context = load_strata({ before_init = function() system_count = #params.params end })
  finish_startup(context)
  local numbers = 0
  for index = system_count + 1, #params.params do
    local param = params.params[index]
    if param.t == params.tNUMBER then
      numbers = numbers + 1
      for _, d in ipairs({ 1 / 20, 1 / 20, -1 / 20, 3 / 20, -1 / 20, -1 / 20, -1 / 20 }) do
        local before = param:get()
        local turned, turn_error = pcall(param.delta, param, d)
        assert_true(turned, param.id .. ": a delta of " .. d .. " raises nothing (" .. tostring(turn_error) .. ")")
        local value = param:get()
        assert_equal(value, math.floor(value), param.id .. " stays whole after a delta of " .. d)
        local expected = util.clamp(before + (d > 0 and 1 or -1), param.min, param.max)
        assert_equal(value, expected, param.id .. ": a delta of " .. d .. " is one step")
      end
    end
  end
  -- tempo, the sequence length, midi_device, record_beats, 21 mod sources
  -- and 35 custom intervals (3.4's LFO percents are control params)
  assert_true(numbers >= 4 + 21 + 35, numbers .. " number params turned")
  assert_equal(params:get("clock_tempo"), params:get("tempo"), "norns' clock_tempo follows tempo")
  local system_delta = params:lookup_param("link_quantum")
  system_delta:delta(1 / 20)
  assert_equal(params:get("link_quantum"), 4 + 1 / 20, "norns' own number params are left as norns makes them")
  -- a fraction from elsewhere (a PSET written by an earlier Strata) attaches the nearest port
  local played = pcall(params.set, params, "midi_device", 2.4)
  assert_true(played, "a fractional midi_device raises nothing")
  context.clear_engine_calls()
  context.midi.send(2, { type = "note_on", note = 60, vel = 100, ch = 1 })
  assert_equal(#context.calls_named("retrigger"), 1, "port 2 plays")
end)

-- #679: a buffer voice's own note plays the exact rate, the one its chord's
-- extra notes play (the param's step used to round it to 0.01)
test("a buffer voice's own note and an extra note at one pitch play the same exact rate", function()
  local context = load_strata(); finish_startup(context)
  local notes = local_value("S").lib.notes
  params:set("v5_source", 3)
  for _, pitch in ipairs({ 62, 37 }) do
    local exact = notes.note_values(5, pitch).rate
    context.clear_engine_calls()
    press(context, 5, pitch)
    assert_near(params:get("v5_buf_rate"), exact, 1e-9, "note " .. pitch .. ": the param holds the exact rate")
    local sent = context.calls_named("setGrainParam")
    local bufRate
    for _, call in ipairs(sent) do if call.args[2] == "bufRate" then bufRate = call.args[3] end end
    assert_near(bufRate, exact, 1e-9, "note " .. pitch .. ": the engine gets the exact rate")
  end
  -- a chord: the own note (62) and an extra note (64), each at the one rate
  -- note_values gives its pitch, so the own note is as in tune as the extra
  press(context, 5, 60)
  context.clear_engine_calls()
  note_on(context, 5, 62)
  note_on(context, 5, 64)
  assert_near(params:get("v5_buf_rate"), notes.note_values(5, 62).rate, 1e-9, "the own note's rate")
  assert_near(params:get("v5_buf_rate"), 2 ^ (2 / 12), 1e-9, "2^(2/12) from a reference of 60")
  local extra = context.calls_named("noteOn")
  assert_equal(#extra, 1, "one extra note")
  assert_near(extra[1].args[5], notes.note_values(5, 64).rate, 1e-9, "the extra note's rate")
  -- the same pitch gets the same rate whichever slot plays it
  assert_near(notes.note_values(5, 62).rate / params:get("v5_buf_rate"), 1, 1e-9, "own = note_values at 62")
end)

test("a quantized voice's MIDI notes snap to the scale, in its freq or buffer rate", function()
  local context = load_strata(); finish_startup(context)
  params:set("scale", option_index("scale", "Minor Pentatonic"))  -- C, Eb, F, G, Bb
  params:set("v4_quantize", 1)
  local expected = { [60] = 60, [61] = 60, [62] = 63, [64] = 63, [66] = 65, [68] = 67, [69] = 70, [71] = 70, [72] = 72 }
  for note, tone in pairs(expected) do
    press(context, 4, note)
    assert_near(params:get("v4_freq"), freq_of(tone), 1e-6, "note " .. note .. " plays " .. tone)
  end
  -- a note past the freq range plays the scale's last tone inside it (Bb6: 2000 Hz is note 95.2)
  press(context, 4, 127)
  assert_near(params:get("v4_freq"), freq_of(94), 1e-6, "a high note plays the highest tone in range")
  press(context, 4, 0)
  assert_near(params:get("v4_freq"), freq_of(17), 1e-6, "a low note plays the lowest (F0: 20 Hz is note 15.5)")
  -- a buffer voice: rate from the snapped note
  params:set("v5_source", 3); params:set("v5_quantize", 1)
  press(context, 5, 66)
  assert_near(params:get("v5_buf_rate"), 2 ^ (5 / 12), 1e-9, "F#4 reads at F4's rate")
  -- quantize off: exact notes; scale off with quantize on: semitones
  press(context, 6, 66)
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

-- #602: 3.3's LFOs were norns' LFO library (lfo_depth_1, ...), 3.4's are
-- strata_lfo<n>_*. A MIDI map left on a 3.3 id makes norns' CC handler
-- (menu_midi_event) raise "invalid paramset index" on every CC it maps,
-- and the MAP menu cannot show it. norns reads strata.pmap before init;
-- at start Strata moves a map on one of 3.3's own LFO ids to the 3.4 param
-- of the same meaning or removes it, and writes the map back. A map on any
-- other id that is no param is left as it is: a mod may add its param after
-- init (norns' hook.script_post_init), or a later version may have it

-- Write maps ({id, cc, out_lo, out_hi}, device 1, channel 1) to strata.pmap
-- and read the file as norns' Script.run does before init; writes.count
-- counts the map's writes from there on
local function load_with_maps(maps, writes)
  return load_strata({ before_init = function()
    for _, map in ipairs(maps) do
      norns.pmap.new(map[1])
      norns.pmap.assign(map[1], 1, 1, map[2])
      norns.pmap.data[map[1]].out_lo, norns.pmap.data[map[1]].out_hi = map[3], map[4]
    end
    norns.pmap.write()
    norns.pmap.clear()
    norns.pmap.read()
    local real_write = norns.pmap.write
    norns.pmap.write = function() writes.count = writes.count + 1; real_write() end
  end })
end

local function pmap_path() return norns.state.data .. norns.state.shortname .. ".pmap" end

test("a MIDI map on a 3.3 LFO param moves to its 3.4 param or goes at start, so no CC raises (#602)", function()
  local maps = {
    -- 3.3 id, cc, out range (3.3's number params mapped in value units)
    { "lfo_depth_1", 20, 20, 80 }, { "lfo_offset_2", 21, -100, 100 }, { "lfo_phase_3", 22, 0, 100 },
    { "lfo_clocked_1", 23, 1, 22 },
    { "lfo_shape_1", 24, 1, 6 }, { "lfo_1", 25, 1, 2 }, { "lfo_free_2", 26, 0, 1 }, { "lfo_mode_3", 27, 1, 2 },
    { "lfo_min_1", 28, 0, 1 },
    { "strata_lfo2_phase", 30, 0, 1 }, { "lfo_phase_2", 31, 0, 100 },  -- the 3.4 param has a map of its own
    { "master_density", 32, 0, 1 },
    { "modparam_level", 33, 0.25, 0.75 },  -- a mod's param, added after init
  }
  local writes = { count = 0 }
  local context = load_with_maps(maps, writes)
  finish_startup(context)
  -- the mod adds its param after init, as norns' hook.script_post_init can
  params:add_separator("mod_section", "mod")
  params:add{ type = "control", id = "modparam_level", name = "mod level",
    controlspec = controlspec.new(0, 1, "lin", 0.01, 0) }
  local function cc(number, value)
    return pcall(norns.menu_midi_event, { 0xb0, number, value }, 1)
  end
  for _, map in ipairs(maps) do
    local ok, problem = cc(map[2], 64)
    assert_true(ok, "CC " .. map[2] .. " (" .. map[1] .. "): " .. tostring(problem))
  end
  -- moved, the range kept in the 3.4 param's units
  cc(20, 127); assert_equal(params:get("strata_lfo1_depth"), 80, "depth's map keeps its 20-80 range")
  cc(20, 0); assert_equal(params:get("strata_lfo1_depth"), 20)
  cc(21, 0); assert_equal(params:get("strata_lfo2_offset"), -100, "offset")
  cc(21, 127); assert_equal(params:get("strata_lfo2_offset"), 100)
  cc(22, 127); assert_equal(params:get("strata_lfo3_phase"), 100, "phase")
  cc(23, 127); assert_equal(params:get("strata_lfo1_division"), 22, "clocked rate to division")
  cc(23, 0); assert_equal(params:get("strata_lfo1_division"), 1)
  -- gone: the 3.3 LFO ids whose meaning changed or that 3.4 has not, and a
  -- 3.3 map on a param that has its own 3.4 map
  for _, id in ipairs({ "lfo_shape_1", "lfo_1", "lfo_free_2", "lfo_mode_3", "lfo_min_1", "lfo_phase_2",
      "lfo_depth_1", "lfo_offset_2", "lfo_phase_3", "lfo_clocked_1" }) do
    assert_equal(norns.pmap.data[id], nil, id .. " has no map")
  end
  assert_equal(norns.pmap.rev[1][1][31], nil, "lfo_phase_2's CC maps nothing")
  assert_equal(norns.pmap.rev[1][1][30], "strata_lfo2_phase", "the 3.4 map stays")
  assert_equal(norns.pmap.rev[1][1][32], "master_density", "a map on a param of this script stays")
  assert_equal(norns.pmap.data.master_density.out_hi, 1)
  -- the mod's map is left as it was, and plays its param once the mod adds it
  assert_equal(norns.pmap.rev[1][1][33], "modparam_level", "a map on an id Strata does not know stays")
  assert_equal(norns.pmap.data.modparam_level.out_lo, 0.25)
  cc(33, 127); assert_near(params:get("modparam_level"), 0.75, 1e-9, "the mod's CC sets its param")
  local said = 0
  for _, line in ipairs(context.printed) do
    if line:find("^midi map: ") then
      said = said + 1
      assert_true(not line:find("modparam_level", 1, true), "nothing said of the mod's map: " .. line)
    end
  end
  assert_equal(said, 10, "one console line per map moved or removed")
  local function said_line(text)
    for _, line in ipairs(context.printed) do if line == text then return true end end
    return false
  end
  assert_true(said_line("midi map: lfo_shape_1 (a 3.3 LFO param) removed: 3.4 has no param of its meaning"),
    "a 3.3 id with no 3.4 param says so")
  assert_true(said_line("midi map: lfo_phase_2 (a 3.3 LFO param) removed: its 3.4 param strata_lfo2_phase is "
    .. "already mapped (CC 30, channel 1, device 1)"), "a 3.3 id whose 3.4 param has its own map names that map")
  assert_true(said_line("midi map: lfo_depth_1 (a 3.3 LFO param) moved to strata_lfo1_depth"))
  assert_equal(writes.count, 1, "the repaired map is written once")
  -- written back: the file norns reads at the next start holds the repair
  -- and the mod's map
  norns.pmap.clear()
  norns.pmap.read()
  assert_equal(norns.pmap.rev[1][1][20], "strata_lfo1_depth", "the moved map is in strata.pmap")
  assert_equal(norns.pmap.data.lfo_shape_1, nil, "a removed map is not")
  assert_equal(norns.pmap.rev[1][1][32], "master_density")
  assert_equal(norns.pmap.rev[1][1][33], "modparam_level", "the mod's map is in strata.pmap")
  assert_equal(norns.pmap.data.modparam_level.out_hi, 0.75)
end)

-- A 3.3 map whose CC another map took (a file with two maps on one CC, as
-- norns' refresh leaves the reverse slot to one) goes, and the line names
-- the map on that CC
test("a 3.3 LFO map whose CC maps another param goes, and the console names that param (#602)", function()
  local context = load_strata({ before_init = function()
    norns.pmap.new("master_density"); norns.pmap.assign("master_density", 1, 1, 40)
    norns.pmap.new("lfo_depth_3"); norns.pmap.data.lfo_depth_3.cc = 40  -- the same CC, its reverse slot not its own
  end })
  finish_startup(context)
  assert_equal(norns.pmap.data.lfo_depth_3, nil, "the 3.3 map goes")
  assert_equal(norns.pmap.data.strata_lfo3_depth, nil, "and does not move")
  assert_equal(norns.pmap.rev[1][1][40], "master_density", "the CC keeps its own map")
  local found = false
  for _, line in ipairs(context.printed) do
    if line == "midi map: lfo_depth_3 (a 3.3 LFO param) removed: its CC 40 (channel 1, device 1) maps master_density" then
      found = true
    end
  end
  assert_true(found, "the console names the map on its CC")
end)

test("a MIDI map with nothing of 3.3's to repair is left as it is and never written (#602)", function()
  local writes = { count = 0 }
  local context = load_with_maps({ { "modparam_level", 33, 0.25, 0.75 }, { "v9_future", 34, 0, 1 },
    { "master_density", 32, 0, 1 } }, writes)
  local before = h.file_text(pmap_path())
  finish_startup(context)
  assert_equal(writes.count, 0, "nothing written")
  assert_equal(h.file_text(pmap_path()), before, "strata.pmap byte for byte")
  for _, id in ipairs({ "modparam_level", "v9_future", "master_density" }) do
    assert_true(norns.pmap.data[id] ~= nil, id .. " keeps its map")
  end
  assert_equal(norns.pmap.rev[1][1][33], "modparam_level"); assert_equal(norns.pmap.rev[1][1][34], "v9_future")
  assert_equal(norns.pmap.data.modparam_level.out_lo, 0.25)
  for _, line in ipairs(context.printed) do assert_true(not line:find("^midi map: "), "nothing said: " .. line) end
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
  assert_true(midi_state.held[3][key_of(3, 62)], "the new note survives the menu visit: no second reset")
end)

-- 3.5: chords through the allocator (S.lib.notes), latch and release,
-- pressure, MPE and the note tap (design §5)

test("a second held key adds a note where 3.4 re-pitched", function()
  local context = load_strata(); finish_startup(context)
  local notes = local_value("S").lib.notes
  context.clear_engine_calls()
  note_on(context, 1, 60, 100)
  assert_near(params:get("v1_freq"), 261.6256, 1e-3, "the voice's own note sets its freq")
  local accents = context.calls_named("retrigger")
  assert_equal(#accents, 1); assert_equal(accents[1].args[1], 0); assert_near(accents[1].args[2], 100 / 127, 1e-9)
  assert_equal(#context.calls_named("noteOn"), 0, "the own note sends no noteOn")
  context.clear_engine_calls()
  note_on(context, 1, 64, 100)
  assert_near(params:get("v1_freq"), 261.6256, 1e-3, "the own note keeps its pitch")
  assert_equal(call_names(context, { noteExpression = true, noteOn = true, retrigger = true }), "noteExpression, noteOn",
    "an extra note: its expression, then its noteOn, and no accent")
  local expression = context.calls_named("noteExpression")[1].args
  for index, value in ipairs({ 0, 1, 1, 1, 0, 0, 0 }) do assert_equal(expression[index], value, "noteExpression " .. index) end
  local on = context.calls_named("noteOn")[1].args
  assert_equal(on[1], 0); assert_equal(on[2], 1); assert_equal(on[3], 64)
  assert_near(on[4], 329.6276, 1e-3); assert_near(on[5], 1.259921, 1e-6); assert_near(on[6], 100 / 127, 1e-9)
  assert_equal(notes.held(1), 2, "voice 1 holds two notes")
end)

test("with the note cap at 1 every key plays as 3.4", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_note_cap", 1)
  context.clear_engine_calls()
  note_on(context, 1, 60, 100)
  local first = call_names(context)
  context.clear_engine_calls()
  note_on(context, 1, 64, 90)   -- the first key still down
  assert_near(params:get("v1_freq"), 329.6276, 1e-3, "the second key re-pitches the voice")
  assert_equal(call_names(context), first, "the same messages as the first key")
  assert_true(first:find("retrigger", 1, true) ~= nil, "a retrigger")
  local accents = context.calls_named("retrigger"); assert_near(accents[1].args[2], 90 / 127, 1e-9)
  assert_equal(#context.calls_named("noteOn") + #context.calls_named("noteExpression"), 0, "no note command")
  assert_equal(local_value("S").lib.notes.held(1), 1)
end)

test("latch: lifting changes nothing, and the next chord's first key replaces the chord", function()
  local context = load_strata(); finish_startup(context)
  local notes = local_value("S").lib.notes
  for _, note in ipairs({ 60, 64, 67 }) do note_on(context, 1, note) end
  context.clear_engine_calls()
  for _, note in ipairs({ 60, 64, 67 }) do note_off(context, 1, note) end
  lfo_step(context)
  assert_equal(#context.engine_calls, 0, "the lifts send nothing")
  assert_true(local_value("voices")[1].active, "the voice runs")
  assert_equal(notes.held(1), 3, "the chord sounds on")
  context.clear_engine_calls()
  note_on(context, 1, 62)
  assert_equal(call_names(context, { noteOff = true, retrigger = true }), "noteOff, noteOff, retrigger",
    "the chord's extra notes released, then the new key accented")
  local offs = context.calls_named("noteOff")
  assert_equal(offs[1].args[1], 0); assert_equal(offs[1].args[2], 1); assert_equal(offs[1].args[3], 0)
  assert_equal(offs[2].args[1], 0); assert_equal(offs[2].args[2], 2); assert_equal(offs[2].args[3], 0)
  assert_near(params:get("v1_freq"), 293.6648, 1e-3, "the new key is the own note")
  assert_equal(notes.held(1), 1); assert_equal(notes.pool_used(), 0)
  -- the next key while one is down adds to the chord
  note_on(context, 1, 65)
  assert_equal(notes.held(1), 2)
end)

test("release: each key's note ends with its key, the own note parks, the voice stops with the last", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  params:set("midi_note_off", 2)
  assert_true(voices[1].active, "voice 1 runs from the start: the norns started it")
  note_on(context, 1, 60); note_on(context, 1, 64)
  context.clear_engine_calls()
  note_off(context, 1, 60)
  assert_equal(call_names(context), "noteOff", "the own note parks")
  local off = context.calls_named("noteOff")[1].args
  assert_equal(off[1], 0); assert_equal(off[2], 0); assert_equal(off[3], 0)
  assert_true(voices[1].active, "another key is down")
  context.clear_engine_calls()
  note_off(context, 1, 64)
  assert_equal(call_names(context, { noteOff = true, noteOn = true, voiceOff = true }), "voiceOff",
    "the last key stops the voice, which ends its notes: no release or unpark before it")
  assert_equal(context.calls_named("voiceOff")[1].args[1], 0)
  assert_true(not voices[1].active, "a voice the norns started stops with its last key")
  -- a voice a key started stops too
  note_on(context, 3, 60)
  assert_true(voices[3].active)
  note_off(context, 3, 60)
  assert_true(not voices[3].active)
end)

test("auto is latch in the plain modes and release in the MPE modes", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local midi_in = S.lib.midi_in
  assert_equal(params:string("midi_note_off"), "auto", "the default")
  local wanted = { "latch", "latch", "release", "release" }
  for mode = 1, 4 do
    params:set("midi_channel_mode", mode)
    assert_equal(midi_in.note_off_mode(), wanted[mode], "auto in mode " .. mode)
    params:set("midi_note_off", 2); assert_equal(midi_in.note_off_mode(), "release", "release in mode " .. mode)
    params:set("midi_note_off", 3); assert_equal(midi_in.note_off_mode(), "latch", "latch in mode " .. mode)
    params:set("midi_note_off", 1)
  end
  -- mpe selected, auto: lifting the key ends the note and stops the voice
  params:set("midi_channel_mode", 3)
  S.selected_voice = 1
  press(context, 2, 60)
  assert_true(not S.voices[1].active, "release in mpe selected")
  params:set("midi_channel_mode", 1)
  press(context, 2, 60)
  assert_true(S.voices[2].active, "latch in per voice")
  assert_equal(S.lib.notes.held(2), 1, "its note sounds on")
end)

test("a note off goes to the voices its note on played", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("midi_channel_mode", 2); params:set("midi_note_off", 2)
  S.selected_voice = 1
  note_on(context, 1, 60)
  S.selected_voice = 2
  context.clear_engine_calls()
  note_off(context, 1, 60)
  local stops = context.calls_named("voiceOff")
  assert_equal(#stops, 1); assert_equal(stops[1].args[1], 0, "the release reaches voice 1")
  assert_true(S.voices[2].active, "the newly selected voice is left alone")
  assert_equal(S.midi_state.note_voice[1], nil, "nothing remembered")
end)

test("an input voice takes its pitch from a note", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_source", 10)
  local freq = params:get("v1_freq")
  press(context, 1, 72)
  assert_near(params:get("v1_grain_pitch"), 2, 1e-9, "note 72 plays at 2")
  press(context, 1, 48)
  assert_near(params:get("v1_grain_pitch"), 0.5, 1e-9, "note 48 at 0.5")
  press(context, 1, 0)
  assert_near(params:get("v1_grain_pitch"), 0.25, 1e-9, "clamped to 0.25")
  assert_equal(params:get("v1_freq"), freq, "the freq is left alone")
  -- an extra note on an input voice: its own rate
  note_on(context, 1, 60); context.clear_engine_calls(); note_on(context, 1, 67)
  local on = context.calls_named("noteOn")[1].args
  assert_equal(on[2], 1); assert_near(on[5], 2 ^ (7 / 12), 1e-9, "a fifth up")
end)

test("a quantized voice's every note is snapped", function()
  local context = load_strata(); finish_startup(context)
  params:set("scale", option_index("scale", "Major"))
  params:set("v1_quantize", 1)
  note_on(context, 1, 61)
  assert_near(params:get("v1_freq"), freq_of(60), 1e-6, "the own note: C#4 plays C4")
  context.clear_engine_calls()
  note_on(context, 1, 66)
  local on = context.calls_named("noteOn")[1].args
  assert_equal(on[2], 1, "an extra note"); assert_equal(on[3], 65, "F#4 plays F4")
  assert_near(on[4], freq_of(65), 1e-6); assert_near(on[5], 2 ^ (5 / 12), 1e-9)
  assert_near(params:get("v1_freq"), freq_of(60), 1e-6, "the own note is unchanged")
  context.clear_engine_calls()
  note_on(context, 2, 66)
  assert_near(params:get("v2_freq"), freq_of(66), 1e-6, "an unquantized voice plays F#4")
end)

test("mpe selected: a chord on member channels plays the selected voice, each note with its channel's values", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("midi_channel_mode", 3)
  S.selected_voice = 2
  context.midi.send(1, { type = "pitchbend", val = 9216, ch = 2 })
  context.midi.send(1, { type = "channel_pressure", val = 64, ch = 2 })
  context.midi.send(1, { type = "cc", cc = 74, val = 32, ch = 2 })
  context.clear_engine_calls()
  note_on(context, 2, 60)
  -- 2 ^ ((1024 / 8192) * 48 / 12) = 2 ^ 0.5; pressure 64 on amp at 100 %; the slide from where the touch began: 0
  local first = expressions(context, 2, 1)
  assert_equal(#first, 1, "the own note's first expression")
  assert_near(first[1].bend, 2 ^ 0.5, 1e-9); assert_near(first[1].amp, 1 + 64 / 127, 1e-9)
  assert_equal(first[1].position, 0); assert_equal(first[1].size, 0); assert_equal(first[1].main, 0)
  assert_near(params:get("v2_freq"), 261.6256, 1e-3)
  note_on(context, 3, 64)
  assert_equal(S.lib.notes.held(2), 2, "voice 2 holds two notes")
  local second = expressions(context, 2, 2)
  assert_equal(#second, 1); assert_equal(second[1].bend, 1, "channel 3 is unbent"); assert_equal(second[1].amp, 1)
  assert_equal(S.lib.notes.held(1), 0, "voice 1 plays nothing")
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    assert_true(call.args[2] ~= "bend", "the voice's own bend is not used")
  end
end)

test("mpe: a member channel's bend, pressure and slide update its held notes only", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("midi_channel_mode", 3)
  S.selected_voice = 2
  note_on(context, 2, 60); note_on(context, 3, 64)
  lfo_step(context, 2)
  context.clear_engine_calls()
  context.midi.send(1, { type = "channel_pressure", val = 127, ch = 3 })
  lfo_step(context)
  assert_equal(#expressions(context, 2, 1), 0, "channel 2's note is untouched")
  local pressed = expressions(context, 2, 2)
  assert_equal(#pressed, 1); assert_near(pressed[1].amp, 2, 1e-9, "channel 3's note: full pressure on amp")
  context.clear_engine_calls()
  context.midi.send(1, { type = "cc", cc = 74, val = 127, ch = 2 })
  lfo_step(context)
  local slid = expressions(context, 2, 1)
  assert_equal(#slid, 1); assert_near(slid[1].main, 0.5, 1e-9, "channel 2's slide on main at 50 %")
  assert_equal(#expressions(context, 2, 2), 0)
  -- the master channel's bend moves both
  context.clear_engine_calls()
  context.midi.send(1, { type = "pitchbend", val = 16383, ch = 1 })
  lfo_step(context)
  local master = 2 ^ ((8191 / 8192) * 2 / 12)
  for slot = 1, 2 do
    local list = expressions(context, 2, slot)
    assert_equal(#list, 1, "slot " .. slot); assert_near(list[1].bend, master, 1e-9, "slot " .. slot .. " bent")
  end
  assert_equal(#context.calls_named("setVoiceParam"), 0, "no voice bend in the MPE modes")
end)

test("mpe split: a note plays every voice whose zone and range hold it", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local notes = S.lib.notes
  params:set("midi_channel_mode", 4)
  params:set("mpe_lower_members", 7); params:set("mpe_upper_members", 7)
  params:set("v3_zone", option_index("v3_zone", "lower"))
  params:set("v3_zone_low", 60); params:set("v3_zone_high", 72)
  note_on(context, 2, 64)
  assert_equal(notes.held(1), 1, "voice 1, lower 0-127"); assert_equal(notes.held(3), 1, "voice 3, lower 60-72")
  assert_true(S.voices[3].active, "voice 3 started"); assert_equal(notes.held(2), 0, "voice 2 is upper")
  local list = S.midi_state.note_voice[2][64]
  assert_equal(#list, 2); assert_equal(list[1], 1); assert_equal(list[2], 3)
  note_on(context, 2, 50)
  assert_equal(notes.held(1), 2, "below voice 3's range: voice 1 only"); assert_equal(notes.held(3), 1)
  note_on(context, 15, 60)
  assert_equal(notes.held(2), 1, "an upper member plays voice 2")
  note_on(context, 1, 62)
  assert_equal(notes.held(1), 3, "the lower master plays the lower zone"); assert_equal(notes.held(3), 2)
  note_off(context, 1, 62)
  note_off(context, 2, 64)   -- auto: release in the MPE modes
  assert_true(not S.voices[3].active, "voice 3 stops with its last key")
  assert_true(S.voices[1].active, "voice 1 still holds a key"); assert_equal(notes.held(1), 1)
  -- a channel in neither zone plays nothing
  params:set("mpe_upper_members", 0); params:set("mpe_lower_members", 3)
  context.clear_engine_calls()
  note_on(context, 9, 60)
  assert_equal(#context.engine_calls, 0, "channel 9 is in neither zone")
end)

test("the plain modes: poly aftertouch is its note's pressure, channel pressure every held note's", function()
  local context = load_strata(); finish_startup(context)
  note_on(context, 1, 60); note_on(context, 1, 64); note_on(context, 2, 62)
  lfo_step(context, 2)
  context.clear_engine_calls()
  context.midi.send(1, { type = "key_pressure", note = 64, val = 127, ch = 1 })
  lfo_step(context)
  assert_equal(#expressions(context, 1, 1), 0, "note 60 is untouched")
  local pressed = expressions(context, 1, 2)
  assert_equal(#pressed, 1); assert_near(pressed[1].amp, 2, 1e-9, "note 64's pressure on amp")
  assert_equal(#context.calls_named("noteExpression"), 1, "voice 2's note is untouched")
  context.clear_engine_calls()
  context.midi.send(1, { type = "channel_pressure", val = 64, ch = 1 })
  lfo_step(context)
  for slot = 1, 2 do
    local list = expressions(context, 1, slot)
    assert_equal(#list, 1, "slot " .. slot); assert_near(list[1].amp, 1 + 64 / 127, 1e-9, "slot " .. slot)
  end
  assert_equal(#expressions(context, 2, 1), 0, "channel 2's note is untouched")
  -- a new key takes its channel's pressure as its first expression
  context.clear_engine_calls()
  note_on(context, 1, 67)
  assert_equal(call_names(context, { noteExpression = true, noteOn = true }), "noteExpression, noteOn")
  assert_near(expressions(context, 1, 3)[1].amp, 1 + 64 / 127, 1e-9)
  -- CC74 is not read in the plain modes; the bend is the voice's
  lfo_step(context, 2); context.clear_engine_calls()
  context.midi.send(1, { type = "cc", cc = 74, val = 127, ch = 1 })
  lfo_step(context)
  assert_equal(#context.engine_calls, 0, "CC74 moves nothing")
  context.midi.send(1, { type = "pitchbend", val = 16383, ch = 1 })
  assert_equal(context.calls_named("setVoiceParam")[1].args[2], "bend")
  assert_equal(#context.calls_named("noteExpression"), 0, "the voice's bend bends every note")
  -- a re-pressed latched key takes pressure again (its old touch is forgotten)
  note_off(context, 1, 60)                                  -- latched at its pressure
  context.midi.send(1, { type = "channel_pressure", val = 0, ch = 1 })
  lfo_step(context, 2); context.clear_engine_calls()
  note_on(context, 1, 60)                                   -- 64 and 67 still down
  assert_near(expressions(context, 1, 1)[1].amp, 1, 1e-9, "the new touch starts at the channel's 0")
  context.clear_engine_calls()
  context.midi.send(1, { type = "channel_pressure", val = 127, ch = 1 })
  lfo_step(context)
  assert_near(expressions(context, 1, 1)[1].amp, 2, 1e-9, "and takes pressure")
end)

test("latch: a lifted key keeps the highest pressure its touch reached", function()
  local context = load_strata(); finish_startup(context)
  note_on(context, 1, 60); note_on(context, 1, 64)
  context.midi.send(1, { type = "key_pressure", note = 60, val = 127, ch = 1 })
  context.midi.send(1, { type = "key_pressure", note = 60, val = 32, ch = 1 })
  lfo_step(context, 2)
  context.clear_engine_calls()
  note_off(context, 1, 60)
  lfo_step(context)
  local kept = expressions(context, 1, 1)
  assert_equal(#kept, 1, "the lift hands the peak over"); assert_near(kept[1].amp, 2, 1e-9, "full pressure, its peak")
  -- in release mode the lift ends the note instead
  params:set("midi_note_off", 2)
  note_on(context, 1, 60); note_on(context, 1, 67)
  context.clear_engine_calls()
  note_off(context, 1, 67)
  assert_equal(call_names(context, { noteOff = true, noteExpression = true }), "noteOff")
end)

-- No voice is left with a MIDI note in any slot, and no running voice's own
-- note is parked: a parked own note is silent and nothing could unpark it
local function assert_nothing_parked(S, name)
  for voice = 1, S.constants.NUM_VOICES do
    for _, used in ipairs(S.lib.notes.slots(voice)) do
      assert_true(used.owner ~= "midi", name .. ": voice " .. voice .. " slot " .. used.slot .. " holds a MIDI note")
      assert_true(not (used.parked and S.voices[voice].active),
        name .. ": voice " .. voice .. " runs silent on a parked own note")
    end
  end
end

test("a port change, an unplug, a mode change and a panic release every MIDI note and empty the pool's count", function()
  local resetters = {
    { name = "a port change", run = function() params:set("midi_device", 2) end },
    { name = "an unplug", run = function(context) context.midi.unplug(1) end },
    { name = "a channel mode change", run = function(_, mode) params:set("midi_channel_mode", mode == 1 and 2 or 1) end },
    { name = "all notes off", run = function(context) context.midi.send(1, { type = "cc", cc = 123, val = 0, ch = 1 }) end },
    { name = "all sound off", run = function(context) context.midi.send(1, { type = "cc", cc = 120, val = 0, ch = 1 }) end },
    { name = "a member count change", modes = { 3 }, run = function() params:set("mpe_lower_members", 7) end },
    { name = "a zone change", modes = { 4 }, run = function() params:set("v1_zone_high", 100) end },
    { name = "reset_midi_input", run = function() reset_midi_input() end },
  }
  for _, resetter in ipairs(resetters) do
    for _, mode in ipairs(resetter.modes or { 1, 3 }) do
      local name = resetter.name .. " in mode " .. mode
      local context = load_strata(); finish_startup(context)
      local S = local_value("S")
      context.midi.plug(1, "keys")
      params:set("midi_channel_mode", mode)
      params:set("midi_note_off", 3)    -- latch in every mode
      S.selected_voice = 1
      local mpe = mode >= 3
      if mpe then context.midi.send(1, { type = "channel_pressure", val = 64, ch = 2 }) end
      -- a latched chord of four on voice 1: member channels 2-5 in the MPE modes, channel 1 in per voice
      local chord = { 60, 64, 67, 71 }
      for index, note in ipairs(chord) do note_on(context, mpe and index + 1 or 1, note) end
      for index, note in ipairs(chord) do note_off(context, mpe and index + 1 or 1, note) end
      assert_equal(S.lib.notes.held(1), 4, name .. ": the chord sounds")
      assert_equal(S.lib.notes.pool_used(), 3, name .. ": three extra notes")
      if mpe then assert_near(S.lib.mpe.values(2).pressure, 64 / 127, 1e-9) end
      resetter.run(context, mode)
      for voice = 1, S.constants.NUM_VOICES do
        assert_true(S.lib.notes.held(voice) <= 1, name .. ": voice " .. voice .. " holds " .. S.lib.notes.held(voice))
      end
      assert_equal(S.lib.notes.pool_used(), 0, name .. ": the pool is empty")
      assert_equal(next(S.midi_state.note_voice), nil, name .. ": no key remembered")
      assert_equal(S.lib.mpe.values(2).pressure, nil, name .. ": the MPE state is reset")
      assert_nothing_parked(S, name)
    end
  end
  -- a reset whose new behavior is latch parks nothing and leaves no own note
  -- parked silent: one parked already returns, unaccented, as the voice's
  -- drone when the voice's last note ends (ruling 39)
  local function seq_note(pitch)
    return { owner = "seq", key = "chord", pitch = pitch, velocity = 0.5, set_own = function() end, extra_only = true }
  end
  local probes = {
    { name = "mpe selected to per voice with the own note parked", run = function(context, S)
      params:set("midi_channel_mode", 3); S.selected_voice = 1
      note_on(context, 2, 60); note_on(context, 3, 64); note_off(context, 2, 60)   -- auto: release; the own note parks
      assert_true(S.lib.notes.slots(1)[1].parked, "the own note parked")
      context.clear_engine_calls()
      params:set("midi_channel_mode", 1)                                          -- the reset reads latch
      assert_equal(call_names(context, { noteOff = true, noteOn = true, voiceOff = true }), "noteOff, noteOn",
        "the extra note ends, the voice's last: its own note returns")
      local back = context.calls_named("noteOn")[1].args
      assert_equal(back[2], 0, "on slot 0"); assert_equal(back[6], 0, "unaccented")
      note_off(context, 3, 64)
    end },
    { name = "the own note parked under a sequenced note, then an unplug under latch", run = function(context, S)
      params:set("midi_note_off", 2)
      note_on(context, 1, 60); note_on(context, 1, 64)
      assert_equal(S.lib.notes.play(1, seq_note(67)), 3, "the sequencer's note in slot 3")
      note_off(context, 1, 60)                                                     -- parks under 64 and the sequencer's
      params:set("midi_note_off", 3)                                               -- a reset under latch: 64 ends
      assert_true(S.lib.notes.slots(1)[1].parked, "still parked under the sequencer's note")
      context.clear_engine_calls()
      context.midi.unplug(1)
      assert_equal(#context.engine_calls, 0, "a reset meeting the parked note sends nothing")
      assert_true(S.voices[1].active and S.lib.notes.find(1, "seq", "chord") == 3, "the sequencer's note plays on")
      S.lib.notes.release(1, "seq", "chord")                                       -- the voice's last note ends
      assert_equal(call_names(context, { noteOff = true, noteOn = true, voiceOff = true }), "noteOff, noteOn",
        "the own note returns as the sequencer's note ends")
      assert_equal(context.calls_named("noteOn")[1].args[6], 0, "unaccented")
    end },
  }
  for _, probe in ipairs(probes) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    context.midi.plug(1, "keys")
    assert_true(S.voices[1].active, probe.name .. ": voice 1 runs from the start")
    probe.run(context, S)
    assert_nothing_parked(S, probe.name)
    assert_true(S.voices[1].active, probe.name .. ": voice 1 sounds on as its drone")
    assert_equal(S.lib.notes.held(1), 0, probe.name); assert_equal(S.lib.notes.pool_used(), 0, probe.name)
    -- a later panic and key find nothing stuck
    context.midi.send(1, { type = "cc", cc = 123, val = 0, ch = 1 })
    note_on(context, 1, 62)
    assert_true(S.voices[1].active and S.lib.notes.find(1, "midi", key_of(1, 62)) == 1, probe.name .. ": the next key plays")
  end
end)

-- The review's probe: a reset under latch never stops or cuts a voice
-- another owner plays
test("a reset under latch forgets MIDI's notes and leaves another owner's playing", function()
  local resets = {
    { name = "a port change", run = function() params:set("midi_device", 2) end },
    { name = "an unplug", run = function(context) context.midi.unplug(1) end },
    { name = "a channel mode change", run = function() params:set("midi_channel_mode", 2) end },
  }
  for _, reset in ipairs(resets) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    context.midi.plug(1, "keys")
    press(context, 1, 60)                                -- latched: MIDI's own note on voice 1
    assert_equal(S.lib.notes.play(1, { owner = "seq", key = "step", pitch = 67, velocity = 0.5,
      set_own = function() end, extra_only = true }), 2, reset.name .. ": a sequenced note in slot 2")
    context.clear_engine_calls()
    reset.run(context)
    assert_equal(#context.calls_named("voiceOff"), 0, reset.name .. ": no voiceOff")
    for _, call in ipairs(context.calls_named("noteOff")) do
      assert_true(not (call.args[1] == 0 and call.args[2] == 1), reset.name .. ": the sequencer's slot is not ended")
    end
    assert_equal(#context.calls_named("noteOff"), 0, reset.name .. ": nothing parked or released")
    assert_true(S.voices[1].active, reset.name .. ": voice 1 runs")
    assert_equal(S.lib.notes.find(1, "seq", "step"), 2, reset.name .. ": the sequencer's note plays on")
    assert_nothing_parked(S, reset.name)
  end
end)

test("a note off change releases every MIDI note, as a channel mode change does", function()
  -- release to latch, the own note parked under a held key
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("midi_note_off", 2)
  for _, note in ipairs({ 60, 64, 67 }) do note_on(context, 1, note) end
  note_off(context, 1, 60)
  assert_true(S.lib.notes.slots(1)[1].parked, "the own note parked")
  context.clear_engine_calls()
  params:set("midi_note_off", 3)
  assert_nothing_parked(S, "release to latch")
  assert_true(S.voices[1].active, "release to latch: the voice sounds on")
  assert_equal(call_names(context, { noteOff = true, noteOn = true, voiceOff = true }), "noteOff, noteOff, noteOn",
    "the extra notes end, then the own note returns as the voice's drone")
  assert_equal(context.calls_named("noteOn")[1].args[6], 0, "unaccented")
  assert_equal(next(S.midi_state.held[1]), nil, "no key held"); assert_equal(next(S.midi_state.note_voice), nil)
  context.clear_engine_calls()
  note_off(context, 1, 64); note_off(context, 1, 67)
  assert_equal(#context.engine_calls, 0, "the keys' later lifts send nothing")
  -- latch to release, a chord held
  context = load_strata(); finish_startup(context)
  S = local_value("S")
  params:set("midi_note_off", 3)
  for _, note in ipairs({ 60, 64, 67 }) do note_on(context, 1, note) end
  params:set("midi_note_off", 2)
  assert_nothing_parked(S, "latch to release")
  assert_true(not S.voices[1].active, "latch to release: the voice whose keys were down stops")
  assert_equal(S.lib.notes.pool_used(), 0)
  -- latch to release, a chord latched with every key up: the extra notes
  -- go, the own note sounds on as latch left it
  params:set("midi_note_off", 3)
  for _, note in ipairs({ 60, 64, 67 }) do note_on(context, 2, note) end
  for _, note in ipairs({ 60, 64, 67 }) do note_off(context, 2, note) end
  assert_equal(S.lib.notes.held(2), 3)
  params:set("midi_note_off", 2)
  assert_nothing_parked(S, "a latched chord to release")
  assert_true(S.voices[2].active, "voice 2 sounds on"); assert_equal(S.lib.notes.pool_used(), 0)
end)

test("the layout hook acts only in the MPE modes, and a second run sends nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  -- per voice: a zone edit leaves a latched chord and held keys alone
  for _, note in ipairs({ 60, 64, 67 }) do note_on(context, 1, note) end
  for _, note in ipairs({ 60, 64, 67 }) do note_off(context, 1, note) end
  note_on(context, 3, 60)
  context.clear_engine_calls()
  params:set("v5_zone_high", 100)
  assert_equal(#context.engine_calls, 0, "per voice: nothing sent")
  assert_equal(S.lib.notes.held(1), 3, "the latched chord sounds on")
  assert_true(S.midi_state.held[3][key_of(3, 60)], "the key stays down")
  -- mpe selected: the first change releases, the second finds nothing to send
  params:set("midi_channel_mode", 3); S.selected_voice = 1
  params:set("midi_note_off", 3)
  for index, note in ipairs({ 60, 64, 67 }) do note_on(context, index + 1, note) end
  for index, note in ipairs({ 60, 64, 67 }) do note_off(context, index + 1, note) end
  assert_equal(S.lib.notes.held(1), 3)
  params:set("v5_zone_high", 90)
  assert_equal(S.lib.notes.held(1), 0, "the first run releases"); assert_equal(S.lib.notes.pool_used(), 0)
  context.clear_engine_calls()
  params:set("v5_zone_high", 80)
  assert_equal(#context.engine_calls, 0, "the second run sends nothing")
  assert_nothing_parked(S, "the second run")
end)

test("RPN 6 with notes held releases them mid-handler and leaves the key state and the allocator agreeing", function()
  for _, off_mode in ipairs({ 1, 3 }) do   -- auto (release in mpe selected), latch
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    params:set("midi_channel_mode", 3); S.selected_voice = 1
    params:set("midi_note_off", off_mode)
    for index, note in ipairs({ 60, 64, 67 }) do note_on(context, index + 1, note) end
    assert_equal(S.lib.notes.held(1), 3)
    -- the controller's configuration: RPN 6 on the lower master, 7 members
    context.midi.send(1, { type = "cc", cc = 101, val = 0, ch = 1 })
    context.midi.send(1, { type = "cc", cc = 100, val = 6, ch = 1 })
    context.midi.send(1, { type = "cc", cc = 6, val = 7, ch = 1 })
    local name = "note off " .. off_mode
    assert_equal(params:get("mpe_lower_members"), 7, name .. ": RPN 6 set the count")
    assert_equal(S.lib.notes.held(1), 0, name .. ": released"); assert_equal(S.lib.notes.pool_used(), 0, name)
    assert_equal(next(S.midi_state.held[1]), nil, name .. ": no key down"); assert_equal(next(S.midi_state.note_voice), nil)
    assert_nothing_parked(S, name)
    assert_equal(S.voices[1].active, off_mode == 3, name .. ": release stops the voice its keys held, latch leaves it")
    -- the old keys' lifts find nothing; a new key plays
    context.clear_engine_calls()
    for index, note in ipairs({ 60, 64, 67 }) do note_off(context, index + 1, note) end
    assert_equal(#context.engine_calls, 0, name .. ": the lifts send nothing")
    note_on(context, 2, 62)
    assert_equal(S.lib.notes.find(1, "midi", key_of(2, 62)), 1, name .. ": the next key plays slot 1")
  end
end)

test("note offs for a stopped voice's forgotten notes send nothing", function()
  for _, off_mode in ipairs({ 2, 3 }) do   -- release, latch
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    params:set("midi_note_off", off_mode)
    for _, note in ipairs({ 60, 64, 67 }) do note_on(context, 3, note) end
    assert_true(S.voices[3].active and S.lib.notes.held(3) == 3, "the chord started voice 3")
    toggle_voice(3)   -- the norns stops it under the keys
    assert_equal(S.lib.notes.held(3), 0, "its notes are forgotten")
    context.clear_engine_calls()
    for _, note in ipairs({ 60, 64, 67 }) do note_off(context, 3, note) end
    lfo_step(context)
    assert_equal(#context.engine_calls, 0, "mode " .. off_mode .. ": the note offs send nothing")
    assert_true(not S.voices[3].active, "the voice stays stopped")
    assert_equal(next(S.midi_state.held[3]), nil, "no key held")
    -- a new key starts the voice again on slot 1
    note_on(context, 3, 62)
    assert_true(S.voices[3].active); assert_equal(S.lib.notes.find(3, "midi", key_of(3, 62)), 1)
  end
end)

test("a note tap consumes the notes it takes, and their note offs", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local midi_in = S.lib.midi_in
  params:set("midi_note_off", 2)
  local seen = {}
  midi_in.set_note_tap(function(note) table.insert(seen, note); return true end)
  context.clear_engine_calls()
  note_on(context, 3, 60)
  assert_equal(#seen, 1); assert_equal(seen[1], 60, "the tap gets the note")
  assert_equal(#context.engine_calls, 0, "nothing plays"); assert_true(not S.voices[3].active)
  assert_equal(next(S.midi_state.held[3]), nil)
  note_off(context, 3, 60)
  note_on(context, 1, 62); note_off(context, 1, 62)
  assert_equal(#context.engine_calls, 0, "the note offs do nothing")
  assert_true(S.voices[1].active, "voice 1 runs on")
  -- a tap that takes nothing lets the note play
  midi_in.set_note_tap(function() return false end)
  note_on(context, 3, 60)
  assert_true(S.voices[3].active, "a refused note plays")
  -- nil: every note plays
  midi_in.set_note_tap(nil)
  note_on(context, 4, 60)
  assert_true(S.voices[4].active)
  -- a tap that clears itself while it runs consumes its note; the next plays
  seen = {}
  midi_in.set_note_tap(function(note)
    table.insert(seen, note)
    midi_in.set_note_tap(nil)
    return true
  end)
  context.clear_engine_calls()
  note_on(context, 5, 60)
  assert_equal(#context.engine_calls, 0, "the self-clearing tap's note is consumed"); assert_equal(#seen, 1)
  note_on(context, 5, 62)
  assert_true(S.voices[5].active, "the next note plays"); assert_equal(#seen, 1, "the tap is gone")
  note_off(context, 5, 60)
  assert_true(S.voices[5].active, "the consumed note's note off does nothing")
  -- a tap that sets another: the new one takes the next note
  local second = {}
  midi_in.set_note_tap(function(note)
    midi_in.set_note_tap(function(next_note) table.insert(second, next_note); return true end)
    return true
  end)
  note_on(context, 6, 60); note_on(context, 6, 61)
  assert_equal(#second, 1); assert_equal(second[1], 61, "the new tap takes the next note")
  assert_true(not S.voices[6].active, "both consumed")
  -- the MPE modes too; a mode change (reset_midi_input) clears the tap
  params:set("midi_channel_mode", 3)
  S.selected_voice = 7
  note_on(context, 2, 60)
  assert_true(S.voices[7].active, "the mode change cleared the tap")
  midi_in.set_note_tap(function(note) table.insert(second, note); return true end)
  note_on(context, 3, 64)
  assert_equal(second[2], 64, "mpe selected: the tap takes the note")
  assert_equal(S.lib.notes.held(7), 1)
  -- a layout change (the zones editor's learn sets a range) keeps the tap
  params:set("mpe_lower_members", 3)   -- channel 9 is now in neither zone
  note_on(context, 9, 70)
  assert_equal(second[3], 70, "the tap survives a layout change")
  -- cleanup clears it
  cleanup()
  midi_event(midi.to_data({ type = "note_on", note = 71, vel = 100, ch = 9 }))
  assert_equal(#second, 3, "after cleanup the tap is gone")
end)

test("a 3.4 PSET's channel mode and note off keep their behavior", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_equal(params:string("midi_note_off"), "auto")
  params:set("midi_note_off", 2); assert_equal(params:string("midi_note_off"), "release")
  params:set("midi_note_off", 3); assert_equal(params:string("midi_note_off"), "latch")
  -- midi_channel_mode 2 is omni
  params:set("midi_channel_mode", 2); S.selected_voice = 4
  params:set("midi_note_off", 1)   -- 3.4's ignore: latch in a plain mode
  press(context, 9, 60)
  assert_true(S.voices[4].active, "omni plays the selected voice")
  assert_equal(S.lib.notes.held(4), 1, "and the note sounds on")
  params:set("midi_note_off", 2)   -- 3.4's voice off: release
  press(context, 9, 62)
  assert_true(not S.voices[4].active, "release stops it")
end)

end

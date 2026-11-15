-- test/unit/io_targets_test.lua
-- The targets core (lib/io/targets.lua, S.lib.io_targets, 3.6 design §3):
-- a voice's pattern steps and played notes to the registered note targets,
-- the offs (one list, checked each LFO step), every way a note ends, mutes,
-- a target that raises, and IO's voice section. Each test registers
-- recording targets of its own beside the real ones (or after taking
-- those out, where a test needs its own alone).
-- Run alone: lua test/run.lua io_targets

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, assert_screen_layout = h.show_page, h.assert_screen_layout

local STEP_SECONDS = 0.125   -- a 1/16 step at the stub clock's 120 BPM
local LFO_STEP_BEATS = 2 / 48  -- one 48 Hz step, in beats at 120 BPM

local function started()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.io_targets
end

-- A target that records each call ({kind, args..., beat}); routed for the
-- voices in target.routes; fields adds to (or replaces in) its record
local function recording_target(S, name, fields)
  local target = { name = name, routes = {}, calls = {} }
  local function log(kind, ...)
    table.insert(target.calls, { kind = kind, args = { ... }, beat = clock.get_beats() })
  end
  local record = { name = name,
    routed = function(voice) return target.routes[voice] == true end,
    note_on = function(...) log("on", ...) end,
    note_off = function(...) log("off", ...) end,
    stop_all = function() log("stop_all") end }
  for field, value in pairs(fields or {}) do record[field] = value end
  target.log = log
  S.register_note_target(record)
  return target
end

local function calls_of(target, kind)
  local list = {}
  for _, call in ipairs(target.calls) do
    if call.kind == kind then list[#list + 1] = call end
  end
  return list
end

local function clear(target) target.calls = {} end

-- Per id, ons minus offs a target got
local function balance(target)
  local open = {}
  for _, call in ipairs(target.calls) do
    local id = call.args[2]
    if call.kind == "on" then open[id] = (open[id] or 0) + 1
    elseif call.kind == "off" then open[id] = (open[id] or 0) - 1 end
  end
  return open
end

local function assert_balanced(target, what)
  for id, count in pairs(balance(target)) do
    assert_equal(count, 0, what .. ": " .. target.name .. "'s ons and offs of " .. tostring(id))
  end
end

local function count_ids(map)
  local n = 0
  for _ in pairs(map) do n = n + 1 end
  return n
end

-- A played note through the allocator (owner midi unless fields say so)
local function played(key, pitch, fields)
  local note = { owner = "midi", key = key, pitch = pitch, velocity = 0.5, park = true, set_own = function() end }
  for field, value in pairs(fields or {}) do note[field] = value end
  return note
end

local function midi_note(context, kind, ch, note, vel)
  midi_event(midi.to_data({ type = kind, note = note, vel = vel or 100, ch = ch }))
end

-- Only voice 1's step 1, at level, every other step of every voice off
local function one_step(S, level)
  for voice = 1, S.constants.NUM_VOICES do
    for step = 1, S.constants.PATTERN_LENGTH do S.patterns[voice][step] = 0 end
  end
  S.patterns[1][1] = level
end

test("volts puts note 60 at 0 V, a volt an octave", function()
  local _, _, targets = started()
  assert_equal(targets.volts(60), 0)
  assert_equal(targets.volts(72), 1)
  assert_equal(targets.volts(57), -0.25)
  assert_equal(targets.TARGETS.zero_volt_note, 60)
  assert_equal(targets.TARGETS.notes_per_volt, 12)
  assert_equal(table.concat(targets.TARGETS.order, " "), "midi crow jf wsyn er301 txo nb")
end)

test("a plain step plays the routed targets at the voice's pitch and ends at its gate", function()
  local context, S, targets = started()
  local a, b = recording_target(S, "a"), recording_target(S, "b")
  a.routes[1] = true
  params:set("v1_freq", 220)
  one_step(S, 12)
  pattern_clock_start()
  context.clock.run_for(0.01)
  local ons = calls_of(a, "on")
  assert_equal(#ons, 1, "one note on")
  assert_equal(ons[1].args[1], 1); assert_equal(ons[1].args[2], "s1")
  assert_near(ons[1].args[3], 57, 1e-6, "220 Hz is note 57")
  assert_near(ons[1].args[4], 0.8, 1e-9, "level 12 of 15")
  assert_equal(ons[1].args[5].source, "step")
  assert_equal(count_ids(ons[1].args[5]), 1, "info is {source = 'step'}")
  local on_beat = ons[1].beat
  -- the off at the gate less the step gap: a 1/16 is 0.25 beat, the gap 0.03 s
  local gap = targets.TARGETS.step_gap_seconds
  local ends = 0.25 - gap / clock.get_beat_sec()
  assert_near(targets.sounding(1).s1.off_beat, on_beat + ends, 1e-6, "the off at the gate, the gap early")
  context.clock.run_for(STEP_SECONDS - gap - 0.03)
  assert_equal(#calls_of(a, "off"), 0, "no off before the note's end")
  context.clock.run_for(0.08)
  pattern_clock_stop()
  local offs = calls_of(a, "off")
  assert_equal(#offs, 1, "one off")
  assert_equal(offs[1].args[2], "s1")
  assert_true(offs[1].beat >= on_beat + ends - 1e-9 and offs[1].beat <= on_beat + ends + LFO_STEP_BEATS + 0.01,
    "within one 48 Hz step of the note's end: " .. offs[1].beat - on_beat)
  assert_equal(#b.calls, 0, "b, not routed, got nothing")
end)

-- A step note's end in beats: its gate less the step gap, at most half the gate early
local function step_end(targets, beat, gate_beats)
  return beat + gate_beats - math.min(targets.TARGETS.step_gap_seconds / clock.get_beat_sec(), gate_beats / 2)
end

-- The registered step output of the targets core
local function targets_output(S)
  for _, output in ipairs(S.registry.step_outputs) do
    if output.name == "targets" then return output end
  end
end

test("a step note ends step_gap_seconds before its gate, at most half its length early; a played note is untouched", function()
  -- so a gate target sees a low before the next step raises it (seq gate off: a gate is exactly a step)
  local context, S, targets = started()
  local a = recording_target(S, "a")
  a.routes[1] = true
  local gap = targets.TARGETS.step_gap_seconds
  assert_equal(gap, 0.03)
  local gap_beats = gap / clock.get_beat_sec()
  local beat = clock.get_beats()
  local output = targets_output(S)
  output.play({ voice = 1, pitches = { 60 }, velocity = 1, beat = beat, gate_beats = 0.25 })
  assert_near(targets.sounding(1).s1.off_beat, beat + 0.25 - gap_beats, 1e-9, "a full 1/16: the gap early")
  local short = gap_beats * 1.5  -- shorter than twice the gap
  output.play({ voice = 1, pitches = { 62 }, velocity = 1, beat = beat, gate_beats = short })
  assert_near(targets.sounding(1).s1.off_beat, beat + short / 2, 1e-9, "a short note: half its length early")
  S.lib.notes.play(1, played(7740, 64))
  assert_equal(targets.sounding(1).m7740.off_beat, nil, "a played note keeps no off beat")
end)

test("a step's chord plays one note per pitch", function()
  local context, S, targets = started()
  local a = recording_target(S, "a")
  a.routes[1] = true
  params:set("v1_freq", 220)
  one_step(S, 15)
  S.lib.sequencer.set_step_attr(1, 1, "notes", { 0, 4, 7 })
  pattern_clock_start()
  context.clock.run_for(0.01)
  local ons = calls_of(a, "on")
  assert_equal(#ons, 3, "three notes")
  for k, pitch in ipairs({ 57, 61, 64 }) do
    assert_equal(ons[k].args[2], "s" .. k, "in order")
    assert_near(ons[k].args[3], pitch, 1e-6, "note " .. k)
  end
  context.clock.run_for(STEP_SECONDS)
  pattern_clock_stop()
  assert_equal(#calls_of(a, "off"), 3, "three offs at the gate")
  assert_balanced(a, "the chord")
end)

test("an id still sounding is ended before it plays again, and its old off never lands", function()
  local context, S, targets = started()
  local a = recording_target(S, "a")
  a.routes[1] = true
  one_step(S, 15)
  params:set("v1_seq_gate", 2)  -- gated: each hit's gate 4 steps / 2 hits = 0.5 beat
  S.lib.sequencer.set_step_attr(1, 1, "gate", 4)
  S.lib.sequencer.set_step_attr(1, 1, "ratchet", 2)
  pattern_clock_start()
  context.clock.run_for(0.1)  -- the second hit (0.0625 s) has played
  local kinds = {}
  for _, call in ipairs(a.calls) do kinds[#kinds + 1] = call.kind .. " " .. call.args[2] end
  assert_equal(table.concat(kinds, ", "), "on s1, off s1, on s1", "the first hit's note ends before the second")
  context.clock.run_for(0.5)  -- past the first hit's gate (0.25 s) and the second's (0.3125 s)
  assert_equal(#calls_of(a, "off"), 2, "exactly one more off")
  pattern_clock_stop()
  assert_balanced(a, "the ratchet")
end)

test("a played note reaches the routed targets; a sequencer note only through the step output", function()
  local context, S, targets = started()
  local a = recording_target(S, "a")
  a.routes[1] = true
  S.lib.notes.play(1, played(7740, 64))
  local ons = calls_of(a, "on")
  assert_equal(#ons, 1)
  assert_equal(ons[1].args[1], 1); assert_equal(ons[1].args[2], "m7740")
  assert_equal(ons[1].args[3], 64); assert_equal(ons[1].args[4], 0.5)
  local info = ons[1].args[5]
  assert_equal(info.source, "midi"); assert_equal(info.owner, "midi"); assert_equal(info.key, 7740)
  assert_equal(targets.sounding(1).m7740.off_beat, nil, "a played note has no off beat")
  S.lib.notes.release(1, "midi", 7740)
  local offs = calls_of(a, "off")
  assert_equal(#offs, 1); assert_equal(offs[1].args[2], "m7740")
  clear(a)
  S.lib.notes.play(1, played(3, 60, { owner = "seq", park = false }))
  S.lib.notes.release(1, "seq", 3)
  assert_equal(#a.calls, 0, "a seq note played through S.lib.notes: nothing from the hook")
end)

test("a re-pitched note ends and starts again; expression reaches only targets that take it", function()
  local context, S, targets = started()
  local expressed = {}
  local a = recording_target(S, "a", { express = function(voice, id) table.insert(expressed, voice .. " " .. id) end })
  local b = recording_target(S, "b")
  a.routes[1], b.routes[1] = true, true
  local slot = S.lib.notes.play(1, played(7740, 64))
  local before = #a.calls
  S.lib.notes.play(1, played(7740, 67))
  local kinds = {}
  for index = before + 1, #a.calls do kinds[#kinds + 1] = a.calls[index].kind .. " " .. a.calls[index].args[2] end
  assert_equal(table.concat(kinds, ", "), "off m7740, on m7740", "moved: off, then on")
  assert_equal(calls_of(a, "on")[2].args[3], 67, "at the new pitch")
  assert_equal(#calls_of(b, "on"), 2, "b too")
  assert_true(S.lib.notes.set_expression(1, slot, { bend = 1.5 }), "a held note's expression")
  assert_equal(table.concat(expressed, ", "), "1 m7740", "a has express")
  S.lib.notes.release(1, "midi", 7740)
  assert_balanced(a, "after the release"); assert_balanced(b, "after the release")
end)

test("an off goes to the targets its on went to", function()
  local context, S, targets = started()
  local a, b = recording_target(S, "a"), recording_target(S, "b")
  a.routes[1] = true
  S.lib.notes.play(1, played(7740, 64))
  a.routes[1], b.routes[1] = nil, true  -- no route_changed
  S.lib.notes.release(1, "midi", 7740)
  assert_equal(#calls_of(a, "off"), 1, "a's off")
  assert_equal(#b.calls, 0, "b never had the note")
end)

-- Voice 1 with held keys (channel 1: notes 60 and 64) and a step note
-- sounding mid-gate on a and b; the targets and the ids sounding
local function sounding_setup()
  local context, S, targets = started()
  local a, b = recording_target(S, "a"), recording_target(S, "b")
  a.routes[1], b.routes[1] = true, true
  one_step(S, 15)
  params:set("v1_seq_gate", 2)
  S.lib.sequencer.set_step_attr(1, 1, "gate", 8)  -- 2 beats: the note sounds through the test
  pattern_clock_start()
  context.clock.run_for(0.01)
  midi_note(context, "note_on", 1, 60)
  midi_note(context, "note_on", 1, 64)
  local ids = targets.sounding(1)
  assert_equal(count_ids(ids), 3, "a step note and two keys sound")
  assert_true(ids.s1 ~= nil, "the step note")
  return context, S, targets, a, b
end

local function assert_all_ended(targets, a, b, what)
  assert_balanced(a, what); assert_balanced(b, what)
  assert_equal(count_ids(targets.sounding(1)), 0, what .. ": nothing sounds")
end

test("every way a note ends sends its off to the targets it started on", function()
  local context, S, targets, a, b = sounding_setup()
  targets.route_changed(1)
  assert_all_ended(targets, a, b, "a route changed")
  pattern_clock_stop()

  context, S, targets, a, b = sounding_setup()
  toggle_voice(1)
  assert_all_ended(targets, a, b, "the voice stopped under its keys")
  pattern_clock_stop()

  context, S, targets, a, b = sounding_setup()
  pattern_clock_stop()
  for _, target in ipairs({ a, b }) do assert_equal(balance(target).s1, 0, "the patterns stopped mid-gate") end
  assert_equal(targets.sounding(1).s1, nil, "the step note ended")
  -- the latched chord (keys up: latch, the plain modes' default) replaced by another
  midi_note(context, "note_off", 1, 60); midi_note(context, "note_off", 1, 64)
  assert_equal(count_ids(targets.sounding(1)), 2, "latched, they sound on")
  midi_note(context, "note_on", 1, 67)
  local key = S.lib.midi_in.MIDI.notes_per_channel
  for _, target in ipairs({ a, b }) do
    assert_equal(balance(target)["m" .. (key + 60)], 0, "the latched chord replaced: 60's off")
    assert_equal(balance(target)["m" .. (key + 64)], 0, "and 64's")
  end
  assert_true(targets.sounding(1)["m" .. (key + 67)] ~= nil, "the new chord sounds")

  context, S, targets, a, b = sounding_setup()
  params:set("v1_mute", 1)
  assert_all_ended(targets, a, b, "the voice muted")
  pattern_clock_stop()

  context, S, targets, a, b = sounding_setup()
  params:set("v2_solo", 1)
  assert_all_ended(targets, a, b, "another voice soloed")
  pattern_clock_stop()

  -- a PSET load runs the route params' actions, each calling route_changed:
  -- the recording target's own param stands in for them
  context, S, targets, a, b = sounding_setup()
  params:add({ type = "number", id = "probe_route", name = "probe route", min = 0, max = 1, default = 0,
    action = function() targets.route_changed(1) end })
  local path = context.data_dir .. "strata-01.pset"
  params:write(path)
  params:set("probe_route", 1)  -- a route changed: the notes ended
  pattern_clock_stop(); pattern_clock_start(); context.clock.run_for(0.01)
  midi_note(context, "note_on", 1, 60)
  assert_equal(count_ids(targets.sounding(1)), 2, "sounding again before the load")
  params:read(path)
  assert_all_ended(targets, a, b, "a PSET loaded")
  pattern_clock_stop()

  context, S, targets, a, b = sounding_setup()
  cleanup()
  assert_all_ended(targets, a, b, "cleanup")
end)

test("a silenced voice starts no target note", function()
  local context, S, targets = started()
  local a = recording_target(S, "a")
  a.routes[1] = true
  one_step(S, 15)
  params:set("v1_mute", 1)
  pattern_clock_start()
  context.clock.run_for(0.01)
  midi_note(context, "note_on", 1, 60)
  S.lib.notes.play(1, played(7740, 64))
  assert_equal(#a.calls, 0, "muted: a step and a key send nothing")
  params:set("v1_mute", 0)
  context.clock.run_for(2)  -- the pattern comes round to step 1
  pattern_clock_stop()
  assert_equal(#calls_of(a, "on"), 1, "unmuted: the next step plays")
  assert_equal(calls_of(a, "on")[1].args[2], "s1")
end)

test("cleanup ends every note at once, with no step of the clock", function()
  local context, S, targets, a, b = sounding_setup()
  cleanup()
  for _, target in ipairs({ a, b }) do
    assert_balanced(target, "cleanup")
    assert_equal(#calls_of(target, "stop_all"), 1, target.name .. "'s stop_all")
    assert_equal(target.calls[#target.calls].kind, "stop_all", "after every off")
  end
  local count = #a.calls + #b.calls
  context.clock.run_for(0.5)  -- the clock after cleanup sends nothing more
  assert_equal(#a.calls + #b.calls, count, "every off was there as cleanup returned; nothing came later")
end)

-- The step output's own play, as the sequencer hands it a hit
local function play_hit(S, voice, pitch, beat, gate_beats)
  for _, output in ipairs(S.registry.step_outputs) do
    if output.name == "targets" then
      output.play({ voice = voice, pitches = { pitch }, velocity = 1, beat = beat, gate_beats = gate_beats })
    end
  end
end

-- A followed transport start, a reset or a new clock source can put the
-- beat back without the outputs' stop
test("a beat that jumps back ends every pending off at once", function()
  local context, S, targets = started()
  local a = recording_target(S, "a")
  a.routes[1] = true
  context.clock.set_beat(100)
  play_hit(S, 1, 60, clock.get_beats(), 2)
  assert_true(targets.sounding(1).s1 ~= nil, "the step note sounds, its off pending")
  context.clock.set_beat(0.5)
  context.clock.run_for(1 / 48 + 0.005)
  assert_equal(#calls_of(a, "off"), 1, "the off arrives within one LFO step")
  assert_equal(targets.sounding(1).s1, nil)
  -- a note started after the jump keeps its own gate
  local beat = clock.get_beats()
  play_hit(S, 1, 62, beat, 0.5)
  local ends = step_end(targets, beat, 0.5)
  context.clock.run_for(0.2)  -- 0.4 beat
  assert_equal(#calls_of(a, "off"), 1, "not before its gate")
  context.clock.run_for(0.1)
  assert_equal(#calls_of(a, "off"), 2, "at its gate")
  assert_true(calls_of(a, "off")[2].beat >= ends - 1e-9, "not early")
  assert_balanced(a, "a")
end)

-- On a MIDI or crow clock a late tick pulls the beat back a few ms: under
-- the sequencer's own tolerance that is jitter, not a jump
test("a tick's pull-back of the beat is not a jump", function()
  local context, S, targets = started()
  local a = recording_target(S, "a")
  a.routes[1] = true
  assert_equal(targets.TARGETS.jump_tolerance, S.lib.sequencer.SEQ.wake_tolerance, "the sequencer's tolerance")
  -- 20 BPM: a beat is 3 s and an LFO step 1/144 beat, so the next step
  -- reads the beat still behind the note's start
  params:set("clock_tempo", 20)
  context.clock.set_beat(10)
  local beat = clock.get_beats()
  play_hit(S, 1, 60, beat, 0.5)
  -- its end as the core read the tempo at the hit (matron reports a new
  -- tempo a tick late, as the stub's clock does)
  local ends = step_end(targets, beat, 0.5)
  context.clock.set_beat(beat - 0.01)
  context.clock.run_for(1 / 48 + 0.005)
  assert_true(clock.get_beats() < beat, "the step read the beat before the note's start")
  assert_equal(#calls_of(a, "off"), 0, "a pull-back of 0.01 beat leaves the note")
  context.clock.run_for(1.2)  -- the beat about 0.4 beat on, under the gate's end
  assert_equal(#calls_of(a, "off"), 0, "not before its gate")
  context.clock.run_for(0.4)
  assert_equal(#calls_of(a, "off"), 1, "its full gate, then the off")
  assert_true(calls_of(a, "off")[1].beat >= ends - 1e-9, "not early")
  -- just over the tolerance: a jump
  context.clock.set_beat(20)
  beat = clock.get_beats()
  play_hit(S, 1, 60, beat, 0.5)
  context.clock.set_beat(beat - targets.TARGETS.jump_tolerance - 0.01)
  context.clock.run_for(1 / 48 + 0.005)
  assert_equal(#calls_of(a, "off"), 2, "a pull-back just over the tolerance ends it within one step")
  assert_balanced(a, "a")
end)

test("a target that failed still gets the off of every note it started", function()
  local context, S, targets = started()
  local a, b = recording_target(S, "a"), recording_target(S, "b")
  local record_a = S.registry.note_targets[#S.registry.note_targets - 1]
  a.routes[1], b.routes[1] = true, true
  S.lib.notes.play(1, played(7740, 64))  -- a holds it
  local logged_on = record_a.note_on
  local attempts = 0
  record_a.note_on = function(...)
    attempts = attempts + 1
    error("probe on")
  end
  S.lib.notes.play(1, played(7741, 67))
  h.claim_script_errors(context, 1, "strata: target a failed: ", "probe on")
  S.lib.notes.release(1, "midi", 7740)
  local offs = calls_of(a, "off")
  assert_equal(#offs, 1, "the first note's off still reaches a, once")
  assert_equal(offs[1].args[2], "m7740")
  S.lib.notes.play(1, played(7742, 69))
  assert_equal(attempts, 1, "no further note_on reaches a")
  -- a note_off that raises is contained, and the other targets' offs go on
  record_a.note_on = logged_on
  targets.route_changed(1)  -- the failure lifted; b's notes end
  S.lib.notes.play(1, played(7743, 70))
  assert_equal(calls_of(a, "on")[#calls_of(a, "on")].args[2], "m7743", "a plays again after a route change")
  record_a.note_off = function() error("probe off") end
  S.lib.notes.release(1, "midi", 7743)
  h.claim_script_errors(context, 1, "strata: target a failed: ", "probe off")
  assert_equal(balance(b).m7743, 0, "b's off still went")
  assert_equal(targets.sounding(1).m7743, nil)
  assert_balanced(b, "b")
end)

test("a target that raises prints once and is skipped until the patterns stop or a route changes", function()
  local context, S, targets = started()
  local broken = true
  local a = recording_target(S, "a")
  local b = recording_target(S, "b")
  local attempts = 0
  local a_on = function(...)
    attempts = attempts + 1
    if broken then error("probe target") end
    a.log("on", ...)
  end
  S.registry.note_targets[#S.registry.note_targets - 1].note_on = a_on
  a.routes[1], b.routes[1] = true, true
  one_step(S, 15)
  S.patterns[1][2] = 15
  pattern_clock_start()
  context.clock.run_for(0.01)
  h.claim_script_errors(context, 1, "strata: target a failed: ", "probe target")
  assert_equal(attempts, 1, "a was called once")
  assert_equal(#calls_of(b, "on"), 1, "b still plays")
  context.clock.run_for(STEP_SECONDS)  -- step 2
  assert_equal(#calls_of(b, "on"), 2, "b plays step 2")
  assert_equal(attempts, 1, "a gets no further call")
  assert_equal(#context.take_script_errors(), 0, "printed once")
  broken = false
  pattern_clock_stop()
  pattern_clock_start()
  context.clock.run_for(0.01)
  assert_equal(attempts, 2, "after the patterns stopped: a is called again")
  assert_equal(#calls_of(a, "on"), 1, "and plays")
  pattern_clock_stop()
  assert_balanced(a, "a"); assert_balanced(b, "b")
  -- a route change of any voice lifts it too
  broken = true
  S.lib.notes.play(1, played(7740, 64))
  h.claim_script_errors(context, 1, "strata: target a failed: ", "probe target")
  S.lib.notes.release(1, "midi", 7740)
  broken = false
  targets.route_changed(5)
  S.lib.notes.play(1, played(7741, 64))
  assert_equal(calls_of(a, "on")[#calls_of(a, "on")].args[2], "m7741", "after route_changed: a again")
  S.lib.notes.release(1, "midi", 7741)
  assert_balanced(a, "a"); assert_balanced(b, "b")
end)

test("the targets output plays after voices, and only when something is routed", function()
  local context, S, targets = started()
  local names = {}
  for index, output in ipairs(S.registry.step_outputs) do names[output.name] = index end
  assert_true(names.voices ~= nil and names.targets ~= nil, "both outputs are registered")
  assert_true(names.voices < names.targets, "voices before targets")
  local calls = 0
  local function count() calls = calls + 1 end
  S.register_note_target({ name = "quiet", routed = function() return false end, note_on = count, note_off = count,
    express = count, stop_all = count })
  one_step(S, 15)
  S.lib.sequencer.set_step_attr(1, 1, "notes", { 0, 4 })
  assert_equal(S.registry.step_outputs[names.targets].available(1), false, "nothing routed: not available")
  pattern_clock_start()
  context.clock.run_for(0.5)
  local slot = S.lib.notes.play(1, played(7740, 64))
  S.lib.notes.set_expression(1, slot, { bend = 1.5 })
  S.lib.notes.release(1, "midi", 7740)
  pattern_clock_stop()
  assert_equal(calls, 0, "with nothing routed no target function is called")
end)

test("end_target ends that target's notes and leaves the others'", function()
  local context, S, targets = started()
  local a, b = recording_target(S, "a"), recording_target(S, "b")
  a.routes[1], b.routes[1] = true, true
  S.lib.notes.play(1, played(7740, 64))
  S.lib.notes.play(1, played(7741, 67))
  targets.end_target("a")
  assert_equal(#calls_of(a, "off"), 2, "a's two offs")
  assert_equal(#calls_of(b, "off"), 0, "b's notes sound on")
  local sounding = targets.sounding(1)
  assert_equal(table.concat(sounding.m7740.targets, " "), "b", "a is dropped from them")
  S.lib.notes.release(1, "midi", 7740); S.lib.notes.release(1, "midi", 7741)
  assert_equal(#calls_of(a, "off"), 2, "a gets no second off")
  assert_equal(#calls_of(b, "off"), 2)
  assert_balanced(a, "a"); assert_balanced(b, "b")
end)

test("the voice section shows the selected voice's rows in the targets' order", function()
  local context, S, targets = started()
  -- the probes below stand alone: every registered target goes first (two
  -- take real targets' names, plan ruling 26; the rest would add their rows)
  for index = #S.registry.note_targets, 1, -1 do table.remove(S.registry.note_targets, index) end
  local function voice_rows()
    local rows = {}
    for _, row in ipairs(S.lib.pages_io.rows()) do
      if row.section == "voice" then rows[#rows + 1] = row end
    end
    return rows
  end
  local rows = voice_rows()
  assert_equal(#rows, 1, "with no target: the title alone")
  assert_equal(rows[1].text, "voice " .. S.selected_voice)
  local function rows_of(name)
    return function(voice)
      return { { label = name .. " v" .. voice, kind = "status", text = name .. " route " .. voice, id = name } }
    end
  end
  recording_target(S, "nb", { rows = rows_of("nb"), status = function(voice) return voice == 3 and "[!]" or nil end })
  recording_target(S, "midi", { rows = rows_of("midi") })
  S.lib.ui_keys.select_voice_by(3 - S.selected_voice)
  assert_equal(S.selected_voice, 3)
  rows = voice_rows()
  assert_equal(#rows, 3, "the title and a row of each")
  assert_equal(rows[1].text, "voice 3", "the selected voice")
  assert_equal(rows[1].status, "[!]", "nb's status on the title row")
  assert_equal(rows[2].shown, "midi route 3", "midi's rows first")
  assert_equal(rows[3].shown, "nb route 3", "then nb's")
  S.lib.ui_keys.select_voice_by(-1)
  assert_equal(voice_rows()[1].status, nil, "no status for voice 2")
  show_page("IO"); redraw()
  assert_screen_layout(context, "IO voice section")
end)

-- The real targets stay registered: their rows come ahead of the probe's
test("the voice section's probe state ends with the probe's rows on screen beside the real targets'", function()
  local context, S = started()
  local real = #S.registry.note_targets
  assert_true(real > 0, "real targets are registered")
  local state
  for _, entry in ipairs(S.registry.pages[S.constants.UI_PAGES.index.IO].layout_states) do
    if entry.name == "voice: a target's rows" then state = entry end
  end
  assert_true(state ~= nil, "the state is listed")
  show_page("IO")
  state.setup(context); redraw()
  assert_equal(#S.registry.note_targets, real + 1, "the probe joins the real targets, none taken out")
  local cursor_row = S.lib.pages_io.rows()[S.io_cursor]
  assert_true(cursor_row.section == "voice" and cursor_row.id == "probe", "the cursor is on the probe's row")
  assert_true(h.screen_shows(context, "layout probe") and h.screen_shows(context, cursor_row.shown),
    "the probe's action row, its label and its text " .. tostring(cursor_row.shown))
  assert_true(h.screen_shows(context, "a target's rows"), "the probe's status row")
  assert_screen_layout(context, "IO voice section probe state")
  -- a probe whose row is gone: the state raises, the message naming the module and the row
  for _, record in ipairs(S.registry.note_targets) do
    if record.name == "layout probe" then record.rows = function() return {} end end
  end
  local ok, problem = pcall(state.setup, context)
  assert_true(not ok and tostring(problem):find("^targets layout: ") ~= nil
    and tostring(problem):find("row id probe", 1, true) ~= nil, tostring(problem))
end)

-- The title's status mark is a look of its own (nb's target gives one)
test("the voice section's status state shows the title with the probe's mark", function()
  local context, S = started()
  local names = {}
  for _, entry in ipairs(S.registry.pages[S.constants.UI_PAGES.index.IO].layout_states) do
    names[entry.name] = entry
  end
  assert_true(names["voice: nothing routed"] == nil, "no state repeats the section at the top")
  local state = names["voice: a target's status"]
  assert_true(state ~= nil, "the state is listed")
  show_page("IO")
  state.setup(context); redraw()
  assert_true(h.screen_shows(context, "voice " .. S.selected_voice), "the title row")
  assert_true(h.screen_shows(context, "[!]"), "the probe's mark on it")
  assert_screen_layout(context, "IO voice section status state")
end)

end

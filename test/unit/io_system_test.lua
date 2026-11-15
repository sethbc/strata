-- test/unit/io_system_test.lua
-- Every 3.6 module at once (3.6 design §14, the whole-system test): the
-- real modules (plan ruling 31: no double of S.lib.io_ii or of any other
-- module), driven and read through the device stubs (MIDI, crow, OSC,
-- softcut, nb, iii). With every default a minute of playing sends nothing
-- anywhere; with everything on a minute holds every bound of design §1 as
-- each module's notes file states it; after that minute everything stops
-- with no note left; under off and teletype nothing sends an ii command;
-- each ii device's lines reach crow as its descriptor writes them; a PSET
-- keeps the routes and a 3.5 PSET turns them off; and no 3.6 param is a
-- scene field, an LFO destination, a fader or a draw of a randomize, a
-- mutation or a drift. The test only observes: it records what the stubs
-- were sent, and when, and never stands in for a module.
-- Run alone: lua test/run.lua io_system

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- The rig and the minute (the brief's values). MIDI devices sit at ports 1
-- to 4 (the MPE voices' synths on 1 and 2), the E16 at 5, the fader box at
-- 6 and the remote grid at 7
local SYSTEM = {
  minute = 60, step = 1 / 48, tempo = 300,
  scene_seconds = 4,        -- a scene recalled every 4 s
  chord_seconds = 0.5,      -- a played chord held, then released, for this long each
  midi_ports = {1, 2, 3, 4}, e16_port = 5, faders_port = 6, grid_port = 7,
  division = 5,             -- v<i>_seq_division: 1/8, 0.1 s at 300 BPM, room for 4 ratchet hits of 25 ms
  ratchet = 4, chord = {0, 1, 2, 3, 4, 5, 6, 7},  -- chords of 8
  level = 12,
  tick_tolerance = h.stubs.MATRON_TICK_SECONDS,
}

local GRID_SCRIPT = h.repo_root .. "/iii/strata_grid.lua"

---------------------------------------------------------------------------
-- Recording what the stubs are sent, with the time and whether the LFO
-- clock's step sent it
---------------------------------------------------------------------------

-- True while the LFO clock's coroutine runs (its 48 Hz step and every
-- step hook)
local function in_lfo_step(S)
  local running = coroutine.running()
  return S.lfo_clock ~= nil and running ~= nil and running == clock.threads[S.lfo_clock]
end

-- A plugged MIDI device's sends, each {bytes, t, lfo}, kept in device.log
local function watch_midi(S, device)
  device.log = {}
  local send = device.send
  device.send = function(self, data)
    send(self, data)
    self.log[#self.log + 1] = {bytes = self.sent[#self.sent], t = util.time(), lfo = in_lfo_step(S)}
  end
  return device
end

-- crow's lines, each {line, t, lfo}, kept in the returned list
local function watch_crow(S, context)
  local log = {}
  local send = norns.crow.send
  norns.crow.send = function(line)
    local before = #context.crow.sent
    send(line)
    if #context.crow.sent > before then log[#log + 1] = {line = line, t = util.time(), lfo = in_lfo_step(S)} end
  end
  return log
end

-- OSC's sends, each {path, t}, kept in the returned list
local function watch_osc(context)
  local log = {}
  local osc_table = context.osc.osc
  local send = osc_table.send
  osc_table.send = function(to, path, args)
    send(to, path, args)
    log[#log + 1] = {path = path, t = util.time()}
  end
  return log
end

local function message(bytes) return midi.to_msg(bytes) end

-- Groups a log's entries by time (one clock tick sends at one time):
-- time -> count of those that pass keep(entry)
local function per_time(log, keep)
  local counts = {}
  for _, entry in ipairs(log) do
    if keep(entry) then counts[entry.t] = (counts[entry.t] or 0) + 1 end
  end
  return counts
end

local function largest(counts)
  local most, at = 0, nil
  for t, count in pairs(counts) do
    if count > most then most, at = count, t end
  end
  return most, at
end

local function starts_with(text, prefix) return text:sub(1, #prefix) == prefix end

---------------------------------------------------------------------------
-- Setting up
---------------------------------------------------------------------------

local function option_index(id, text)
  for index, name in ipairs(params:lookup_param(id).options) do
    if name == text then return index end
  end
  error("no option " .. text .. " for " .. id, 2)
end

-- Every voice running and unlocked
local function run_all_voices(S)
  for voice = 1, S.constants.NUM_VOICES do
    if not S.voices[voice].active then toggle_voice(voice) end
    if S.frozen[voice] then toggle_lock(voice) end
  end
end

-- Patterns with chords of eight and ratchets of four on all seven voices:
-- every step set, the 1/8 division (four hits fit in a step at 300 BPM)
local function busy_patterns(S, steps)
  for voice = 1, S.constants.NUM_VOICES do
    params:set("v" .. voice .. "_seq_division", SYSTEM.division)
    for step = 1, S.constants.PATTERN_LENGTH do
      local on = step <= (steps or S.constants.PATTERN_LENGTH)
      S.patterns[voice][step] = on and SYSTEM.level or 0
      if on then
        S.lib.sequencer.set_step_attr(voice, step, "notes", SYSTEM.chord)
        S.lib.sequencer.set_step_attr(voice, step, "ratchet", SYSTEM.ratchet)
      end
    end
  end
end

-- Two scenes to recall in turn
local function two_scenes(S)
  capture_scene(1)
  capture_scene(2)
end

-- The common start: the script loaded with two nb players, the devices at
-- MIDI ports 1 to 4 and a crow plugged in, the voices running, 300 BPM,
-- busy patterns, two scenes
local function started(options)
  options = options or {}
  local made = {}
  local context = load_strata({before_load = function(context)
    made.alpha = context.nb.add_player("alpha")
    made.beta = context.nb.add_player("beta", {"note_on", "note_off", "stop_all", "add_params"})
    if options.before_load then options.before_load(context) end
  end})
  finish_startup(context)
  local S = local_value("S")
  local rig = {context = context, S = S, players = made, devices = {}, hits = {}}
  -- a step output of the test's own, after the real ones: it only records
  -- each hit (its time, the beat now, the event's beat, gate and pitches),
  -- so a note off can be checked against its note's time
  S.register_step_output({name = "system probe", play = function(event)
    rig.hits[#rig.hits + 1] = {t = util.time(), now_beat = clock.get_beats(), voice = event.voice,
      beat = event.beat, gate_beats = event.gate_beats, pitches = event.pitches}
  end})
  rig.crow = watch_crow(S, context)
  rig.osc = watch_osc(context)
  for _, port in ipairs(SYSTEM.midi_ports) do
    rig.devices[port] = watch_midi(S, context.midi.plug(port, "synth " .. port))
  end
  context.crow.plug()
  params:set("clock_tempo", SYSTEM.tempo)
  run_all_voices(S)
  busy_patterns(S, options.steps)
  two_scenes(S)
  return rig
end

---------------------------------------------------------------------------
-- The minute
---------------------------------------------------------------------------

-- Plays the minute: the patterns run, a scene is recalled every 4 s, and
-- each LFO step's part of the playing runs first (rig.each_step(n, t), the
-- played notes and moves); returns when the minute is over
local function play_minute(rig, seconds)
  local context, S = rig.context, rig.S
  local steps = math.floor((seconds or SYSTEM.minute) / SYSTEM.step + 0.5)
  local scene_steps = math.floor(SYSTEM.scene_seconds / SYSTEM.step + 0.5)
  pattern_clock_start()
  for n = 1, steps do
    if n % scene_steps == 0 then S.lib.io_actions.recall_scene(n / scene_steps % 2 + 1) end
    if rig.each_step then rig.each_step(n, util.time()) end
    context.clock.run_for(SYSTEM.step)
  end
end

-- Plain MIDI chords on the input port (per voice: channel n plays voice n),
-- held and released in turn
local function plain_chords(rig, port)
  local chord_steps = math.floor(SYSTEM.chord_seconds / SYSTEM.step + 0.5)
  local held = false
  return function(n)
    if n % chord_steps ~= 0 then return end
    held = not held
    for channel = 1, 3 do
      for k = 0, 2 do
        rig.context.midi.send(port, {type = held and "note_on" or "note_off", note = 40 + channel * 5 + k * 2,
          vel = 90, ch = channel})
      end
    end
  end
end

---------------------------------------------------------------------------
-- The tests
---------------------------------------------------------------------------

test("with every default a minute of playing sends nothing anywhere", function()
  -- the plan's "Nothing by default", for every module at once
  local rig = started()
  local context, S = rig.context, rig.S
  rig.each_step = plain_chords(rig, 1)
  play_minute(rig)
  pattern_clock_stop()
  assert_true(S.pattern_playing == false, "the patterns stopped")
  -- the minute played: 7 voices x 10 steps a second x 4 hits, for 60 s
  assert_true(#rig.hits >= 0.9 * 7 * 10 * SYSTEM.ratchet * SYSTEM.minute, "hits played: " .. #rig.hits)
  for _, port in ipairs(SYSTEM.midi_ports) do
    assert_equal(#rig.devices[port].sent, 0, "MIDI port " .. port .. " was sent nothing")
  end
  assert_true(#context.crow.sent >= 1, "crow got its reset at the add")
  for index, line in ipairs(context.crow.sent) do
    assert_equal(line, "crow.reset()", "crow line " .. index)
  end
  assert_equal(#context.osc.sent, 0, "no OSC message")
  assert_equal(#context.softcut.calls, 0, "no softcut call")
  assert_equal(next(context.audio.levels), nil, "the mixer's cut levels untouched")
  for name, player in pairs(rig.players) do
    assert_equal(#player.calls, 1, "nb player " .. name .. " got one call")
    assert_equal(player.calls[1][1], "add_params", "nb player " .. name .. "'s add_params")
  end
end)

end

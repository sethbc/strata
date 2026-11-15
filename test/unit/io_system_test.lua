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
-- Everything on
---------------------------------------------------------------------------

-- The tests may set a rig setting directly (the modules only read them)
local function set_rig(S, key, value)
  assert_true(S.lib.io_rig.set(key, value), "rig " .. key .. " set to " .. tostring(value))
end

-- Each voice's routes with everything on. MIDI: voices 1 and 2 MPE on
-- ports 1 and 2 (their synths), the rest plain, each on a channel of its
-- own, on ports 3 and 4; the ER-301 ports and the TELEXo outputs are
-- shared (voices on one port play one line), voices 1, 3, 5 and 7 on the
-- TELEXo's envelope; the nb players alternate
local ROUTES = {
  midi = {{port = 1, mpe = true}, {port = 2, mpe = true}, {port = 3, channel = 3}, {port = 3, channel = 4},
    {port = 4, channel = 5}, {port = 4, channel = 6}, {port = 4, channel = 7}},
  er301 = {1, 2, 3, 1, 2, 3, 1},
  txo = {1, 2, 1, 2, 1, 2, 1}, txo_envelope = {true, false, true, false, true, false, true},
  nb = {"alpha", "beta", "alpha", "beta", "alpha", "beta", "alpha"},
  crow = {"v3 pitch", "v3 gate", "lfo3", "lfo4"},
  cc_port = 3, cc_channel = 16, cc_first = 20,
  midi_in = 4,          -- the played MPE notes arrive on port 4
  watch_extra = {"_reverb_send", "_grain_size", "_filter_freq"},  -- every voice's, beside OSC's own watch list
}

-- The MPE notes played: voice 1 takes notes below 64, voice 2 the rest
-- (mpe split, one lower zone of 15 members), each on a member channel of
-- its own: eight for voice 1, seven for voice 2, all fifteen held
local MPE_NOTES = {}
for k = 1, 8 do MPE_NOTES[k] = {channel = k + 1, note = 28 + k} end
for k = 9, 15 do MPE_NOTES[k] = {channel = k + 1, note = 92 + k} end

local function set_routes(S)
  for voice = 1, S.constants.NUM_VOICES do
    local prefix = "v" .. voice .. "_out_"
    local midi_route = ROUTES.midi[voice]
    params:set(prefix .. "port", midi_route.port)
    if midi_route.mpe then params:set(prefix .. "mode", option_index(prefix .. "mode", "mpe"))
    else params:set(prefix .. "channel", midi_route.channel) end
    params:set(prefix .. "jf", 1)
    params:set(prefix .. "wsyn", 1)
    params:set(prefix .. "er301", ROUTES.er301[voice])
    params:set(prefix .. "txo", ROUTES.txo[voice])
    if ROUTES.txo_envelope[voice] then params:set(prefix .. "txo_cv", option_index(prefix .. "txo_cv", "envelope")) end
    params:set(prefix .. "nb_key", ROUTES.nb[voice])
  end
  for n, key in ipairs(ROUTES.crow) do params:set("crow_out" .. n .. "_source_key", key) end
  for k = 1, 8 do
    params:set("cc_out" .. k .. "_source_key", "lfo" .. ((k - 1) % S.constants.NUM_LFOS + 1))
    params:set("cc_out" .. k .. "_port", ROUTES.cc_port)
    params:set("cc_out" .. k .. "_channel", ROUTES.cc_channel)
    params:set("cc_out" .. k .. "_number", ROUTES.cc_first + k - 1)
  end
  for n = 1, S.constants.NUM_LFOS do
    params:set("strata_lfo" .. n, 1)
    params:set("strata_lfo" .. n .. "_rate", 1 + n / 2)
    params:set("strata_lfo" .. n .. "_depth", 100)
  end
  params:set("tapeloop", 1)
end

-- The played MPE notes' setup: the input on port 4 in mpe split, voices 1
-- and 2 in the lower zone, split at note 64, and a pool of 16
local function mpe_input(S)
  params:set("midi_device", ROUTES.midi_in)
  params:set("midi_channel_mode", S.lib.mpe.MPE.modes.split)
  params:set("mpe_lower_members", 15)
  params:set("v1_zone", option_index("v1_zone", "lower"))
  params:set("v2_zone", option_index("v2_zone", "lower"))
  params:set("v1_zone_high", 63)
  params:set("v2_zone_low", 64)
  S.lib.notes.set_pool(S.constants.NOTE_POOL.max)
end

-- The controllers, the remote grid and OSC: plugged, set and greeted
local function surfaces(rig)
  local context, S = rig.context, rig.S
  rig.e16 = watch_midi(S, context.midi.plug(SYSTEM.e16_port, "E16"))
  rig.faders = watch_midi(S, context.midi.plug(SYSTEM.faders_port, "faders"))
  set_rig(S, "e16_port", SYSTEM.e16_port)
  set_rig(S, "faders_port", SYSTEM.faders_port)
  local grid_device = require("stub_iii")({kind = "grid"})
  grid_device.run(GRID_SCRIPT)
  rig.grid = watch_midi(S, grid_device.connect(context, SYSTEM.grid_port))
  set_rig(S, "remote_grid_port", SYSTEM.grid_port)
  assert_equal(S.lib.io_remote.status("grid"), "16x16", "the remote grid is attached")
  set_rig(S, "osc_feedback", "on")
  context.osc.receive("/strata/hello", {}, {"10.0.0.2", 57121})
  for voice = 1, S.constants.NUM_VOICES do
    for _, suffix in ipairs(ROUTES.watch_extra) do
      context.osc.receive("/strata/watch", {"v" .. voice .. suffix})
    end
  end
  assert_true(S.lib.io_osc.running(), "OSC feedback runs")
end

-- The ii queue watched as it is used: every send and send_off still goes
-- to the real module (the test only reads what it answers and how many
-- lines wait), and each call notes a send accepted while 48 or more lines
-- waited, and the most lines ever waiting beside the lines with an off
local function watch_ii(S)
  local ii = S.lib.io_ii
  local seen = {accepted_full = 0, off_lines = {}, off_line_count = 0, most = 0, most_allowed = math.huge,
    sends = 0, offs = 0}
  local send, send_off = ii.send, ii.send_off
  local function note_waiting()
    local waiting = ii.queued()
    if waiting > seen.most then seen.most = waiting end
    local allowed = ii.II.queue_max + seen.off_line_count
    if waiting > allowed then seen.over = (seen.over or 0) + 1 end
  end
  seen.note_waiting = note_waiting
  ii.send = function(device, command, ...)
    local waiting = ii.queued()
    local accepted = send(device, command, ...)
    if accepted then seen.sends = seen.sends + 1 end
    if accepted and waiting >= ii.II.queue_max then seen.accepted_full = seen.accepted_full + 1 end
    note_waiting()
    return accepted
  end
  ii.send_off = function(device, command, first, ...)
    local key = device .. " " .. command .. " " .. tostring(first)
    if not seen.off_lines[key] then
      seen.off_lines[key] = true
      seen.off_line_count = seen.off_line_count + 1
    end
    seen.offs = seen.offs + 1
    local queued = send_off(device, command, first, ...)
    note_waiting()
    return queued
  end
  return seen
end

-- Everything on: the routes, the MPE input, the surfaces, then the bus
-- given to Strata (its devices made ready), and one step for MIDI out's
-- routes to settle (ruling 29)
local function everything_on(rig)
  local context, S = rig.context, rig.S
  set_routes(S)
  mpe_input(S)
  surfaces(rig)
  rig.ii = watch_ii(S)
  set_rig(S, "ii_bus", "strata")
  assert_true(S.lib.io_ii.leads(), "Strata leads the ii bus")
  context.clock.advance_until(S.lfo_clock)
  for voice = 1, S.constants.NUM_VOICES do
    local midi_route = ROUTES.midi[voice]
    assert_true(S.lib.io_targets ~= nil and params:get("v" .. voice .. "_out_port") == midi_route.port,
      "voice " .. voice .. "'s MIDI route stands")
  end
  assert_true(S.lib.io_tape.is_on(), "the tape runs")
end

-- What each step of the minute plays with everything on: the fifteen MPE
-- notes (struck at the first step, then every value of each moving each
-- step), the faders swept and an E16 encoder turned, the watched params
-- moved, and the remote grid redrawn
local function everything_moves(rig)
  local context, S = rig.context, rig.S
  local watched = {}
  for m = 1, S.constants.NUM_MACROS do watched[#watched + 1] = "macro_" .. m end  -- moved by the faders
  local moved = {}
  for voice = 1, S.constants.NUM_VOICES do
    moved[#moved + 1] = "v" .. voice .. "_amp"
    for _, suffix in ipairs(ROUTES.watch_extra) do moved[#moved + 1] = "v" .. voice .. suffix end
  end
  assert_equal(#watched + #moved, 16 + 28, "44 watched params moved")
  -- the fifteen are struck before the patterns start: a step's chord never
  -- steals (docs/notes/lua/sequencer.md), and a chord note younger than
  -- NOTES.cut_seconds cannot be stolen either, so notes struck in the
  -- instant the patterns start would find each voice's extra slots taken
  for _, played in ipairs(MPE_NOTES) do
    context.midi.send(ROUTES.midi_in, {type = "note_on", note = played.note, vel = 100, ch = played.channel})
  end
  rig.mpe_held = true
  for voice = 1, 2 do
    assert_equal(S.lib.notes.held(voice), voice == 1 and 8 or 7, "voice " .. voice .. " holds its played notes")
  end
  return function(n)
    if rig.mpe_held then
      for k, played in ipairs(MPE_NOTES) do
        local phase = n * 0.37 + k
        context.midi.send(ROUTES.midi_in, {type = "pitchbend", val = 8192 + math.floor(3000 * math.sin(phase)),
          ch = played.channel})
        context.midi.send(ROUTES.midi_in, {type = "channel_pressure", val = math.floor(63 + 60 * math.cos(phase)),
          ch = played.channel})
        context.midi.send(ROUTES.midi_in, {type = "cc", cc = 74, val = math.floor(63 + 60 * math.sin(phase * 1.3)),
          ch = played.channel})
      end
    end
    if n % 3 == 0 then
      for m = 1, S.constants.NUM_MACROS do
        local value = (n + m * 8) % 254
        if value > 127 then value = 254 - value end
        context.midi.send(SYSTEM.faders_port, {type = "cc", cc = 32 + m - 1, val = value, ch = 1})
      end
      for index, id in ipairs(moved) do
        local spec = params:lookup_param(id)
        params:set_raw(id, 0.25 + 0.5 * ((n / 3 + index) % 10) / 10)
        assert_true(spec ~= nil, id)
      end
    end
    if n % 6 == 0 then
      context.midi.send(SYSTEM.e16_port, {type = "cc", cc = 102 + math.floor(n / 6) % 16, val = 1, ch = 16})
    end
    grid_redraw()
  end
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

-- The script loaded with everything on, then the minute played
local function minute_with_everything_on()
  local rig = started()
  everything_on(rig)
  rig.each_step = everything_moves(rig)
  local each_step = rig.each_step
  rig.each_step = function(n, t)
    each_step(n, t)
    rig.ii.note_waiting()
  end
  rig.minute_start = util.time()
  play_minute(rig)
  return rig
end

---------------------------------------------------------------------------
-- Reading the records
---------------------------------------------------------------------------

local function is_status(msg, kind) return msg.type == kind end

-- Every entry of the logs given, in one list
local function joined(...)
  local list = {}
  for _, log in ipairs({...}) do
    for _, entry in ipairs(log) do list[#list + 1] = entry end
  end
  return list
end

-- The voice a MIDI message on port and channel belongs to (ROUTES.midi)
local function voice_on(port, channel)
  for voice, route in ipairs(ROUTES.midi) do
    if route.port == port and (route.mpe or route.channel == channel) then return voice end
  end
end

-- A hit's note end, in seconds: its beat plus its gate, at the tempo
local function hit_end(hit) return hit.t + (hit.beat + hit.gate_beats - hit.now_beat) * 60 / SYSTEM.tempo end

local function time_key(voice, t) return voice .. "@" .. string.format("%.6f", t) end

-- The hits by voice and time
local function hits_at(rig)
  local index = {}
  for _, hit in ipairs(rig.hits) do index[time_key(hit.voice, hit.t)] = hit end
  return index
end

-- Each MIDI note off that ends step notes later than one LFO step after
-- the latest of their ends, as text (a note that a played key holds too,
-- or whose on matched no hit, has no end to keep). Ids on one port,
-- channel and note are counted and their off goes once, when the last
-- ends (docs/notes/lua/io/midi_out.md), so the end kept is the latest
local function late_midi_offs(rig)
  local late = {}
  local index = hits_at(rig)
  local allowed = SYSTEM.step + SYSTEM.tick_tolerance + 1e-6
  for _, port in ipairs(SYSTEM.midi_ports) do
    local open = {}
    for _, entry in ipairs(rig.devices[port].log) do
      local msg = message(entry.bytes)
      local key = msg.ch and msg.note and (msg.ch * 128 + msg.note)
      if is_status(msg, "note_on") then
        local hit = index[time_key(voice_on(port, msg.ch) or 0, entry.t)]
        local due = false  -- no end to keep
        if hit then
          for _, pitch in ipairs(hit.pitches) do
            if util.clamp(math.floor(pitch + 0.5), 0, 127) == msg.note then due = hit_end(hit) end
          end
        end
        local record = open[key]
        if not record then open[key] = {due = due}
        elseif record.due and due then record.due = math.max(record.due, due)
        else record.due = false end
      elseif is_status(msg, "note_off") then
        local record = open[key]
        open[key] = nil
        if record and record.due and entry.t > record.due + allowed then
          late[#late + 1] = string.format("port %d ch %d note %d: off at %.4f, due %.4f", port, msg.ch, msg.note,
            entry.t, record.due)
        end
      end
    end
  end
  return late
end

-- Each low of crow's gate output (voice 3's) later than one LFO step after
-- the end of the voice's latest hit before it
local function late_crow_gates(rig)
  local late = {}
  local hits = {}
  for _, hit in ipairs(rig.hits) do
    if hit.voice == 3 then hits[#hits + 1] = hit end
  end
  local allowed = SYSTEM.step + SYSTEM.tick_tolerance + 1e-6
  local next_hit = 1
  local latest
  for _, entry in ipairs(rig.crow) do
    while hits[next_hit] and hits[next_hit].t <= entry.t do
      latest = hits[next_hit]
      next_hit = next_hit + 1
    end
    if entry.line == "output[2].volts = 0" and latest and entry.t > hit_end(latest) + allowed then
      late[#late + 1] = string.format("gate low at %.4f, due %.4f", entry.t, hit_end(latest))
    end
  end
  return late
end

local function first_lines(list, count)
  local shown = {}
  for index = 1, math.min(#list, count or 5) do shown[index] = list[index] end
  return table.concat(shown, "; ")
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

test("with everything on, a minute holds every bound", function()
  -- design §1's bounds as each module's notes file states them (plan
  -- ruling 29), counted per LFO step, tick or window from the stubs' records
  local rig = minute_with_everything_on()
  local S = rig.S
  pattern_clock_stop()
  assert_true(#rig.hits >= 0.9 * 7 * 10 * SYSTEM.ratchet * SYSTEM.minute, "hits played: " .. #rig.hits)

  -- ii (docs/notes/lua/io/ii.md): at most 4 lines a step, every one from
  -- the step; no send accepted while 48 or more lines waited; never more
  -- waiting than 48 plus one off a line
  local II = S.lib.io_ii.II
  local ii_lines, ii_outside = {}, {}
  for _, entry in ipairs(rig.crow) do
    if starts_with(entry.line, "ii.") then
      ii_lines[#ii_lines + 1] = entry
      if not entry.lfo then ii_outside[#ii_outside + 1] = entry.line end
    end
  end
  local most_ii = largest(per_time(ii_lines, function() return true end))
  assert_true(most_ii <= II.sends_per_step, "at most 4 ii lines a step, got " .. most_ii)
  assert_equal(most_ii, II.sends_per_step, "the queue was busy: some step sent 4")
  assert_equal(#ii_outside, 0, "every ii line from the LFO step: " .. first_lines(ii_outside))
  assert_equal(rig.ii.accepted_full, 0, "no send accepted while 48 or more lines waited")
  assert_equal(rig.ii.over, nil, "never more than 48 plus one off a line waiting (most " .. rig.ii.most
    .. ", off lines " .. rig.ii.off_line_count .. ")")
  assert_true(rig.ii.most >= II.queue_max and S.lib.io_ii.dropped() > 0, "the queue filled and dropped")

  -- crow (docs/notes/lua/io/crow.md): no followed value (outputs 3 and 4,
  -- on LFOs) sent in a 0.1 s window that already had 32 lines
  local CROW = S.lib.io_crow.CROW
  local window_lines, crowded, followed = {}, {}, 0
  for _, entry in ipairs(rig.crow) do
    local window = math.floor(entry.t / CROW.window_seconds + 1e-9)
    local before = window_lines[window] or 0
    if starts_with(entry.line, "output[3].volts = ") or starts_with(entry.line, "output[4].volts = ") then
      followed = followed + 1
      if before >= CROW.lines_per_window then crowded[#crowded + 1] = entry.line .. " after " .. before end
    end
    window_lines[window] = before + 1
  end
  assert_true(followed > 0, "the outputs followed their LFOs")
  assert_equal(#crowded, 0, "no followed value in a full window: " .. first_lines(crowded))

  -- MIDI out (docs/notes/lua/io/midi_out.md): at most 24 MPE expression
  -- messages a step over both MPE ports, and 8 CC out
  local MIDI_OUT = S.lib.io_midi_out.MIDI_OUT
  local expression = per_time(joined(rig.devices[1].log, rig.devices[2].log), function(entry)
    if not entry.lfo then return false end
    local msg = message(entry.bytes)
    return msg.type == "pitchbend" or msg.type == "channel_pressure" or (msg.type == "cc" and msg.cc == 74)
  end)
  local most_expression = largest(expression)
  assert_true(most_expression <= MIDI_OUT.express_per_step, "at most 24 expression a step, got " .. most_expression)
  assert_equal(most_expression, MIDI_OUT.express_per_step, "fifteen moving notes fill a step's 24")
  local cc_out = per_time(rig.devices[ROUTES.cc_port].log, function(entry)
    local msg = message(entry.bytes)
    return entry.lfo and msg.type == "cc" and msg.ch == ROUTES.cc_channel
  end)
  local most_cc = largest(cc_out)
  assert_true(most_cc <= MIDI_OUT.cc_per_step, "at most 8 CC out a step, got " .. most_cc)
  assert_true(most_cc > 0, "the CC slots sent")

  -- the remote grid (docs/notes/lua/io/remote.md): at most 96 LED
  -- messages a 1/30 s tick
  local leds = per_time(rig.grid.log, function(entry) return message(entry.bytes).type == "note_on" end)
  local most_leds = largest(leds)
  assert_true(most_leds <= S.lib.io_remote.REMOTE.leds_per_tick, "at most 96 LED messages a tick, got " .. most_leds)
  assert_true(most_leds > 0, "the remote grid was drawn")

  -- OSC (docs/notes/lua/io/osc.md): at most 32 messages a 1/15 s tick
  local most_osc = largest(per_time(rig.osc, function() return true end))
  assert_true(most_osc <= S.lib.io_osc.OSC.sends_per_tick, "at most 32 OSC messages a tick, got " .. most_osc)
  assert_equal(most_osc, S.lib.io_osc.OSC.sends_per_tick, "the watched params filled a tick")

  -- the E16's echo (docs/notes/lua/io/controllers.md): at most 16 CCs and
  -- one ring frame a 1/15 s tick
  local CONTROLLERS = S.lib.io_controllers.CONTROLLERS
  local echo = per_time(rig.e16.log, function(entry) return message(entry.bytes).type == "cc" end)
  local most_echo = largest(echo)
  assert_true(most_echo <= CONTROLLERS.echo_per_tick, "at most 16 echo CCs a tick, got " .. most_echo)
  assert_true(most_echo > 0, "the macros were echoed")
  local rings = per_time(rig.e16.log, function(entry)
    return entry.bytes[1] == 0xf0 and entry.bytes[5] == 0x01
  end)
  local most_rings = largest(rings)
  assert_true(most_rings <= 1, "at most one ring frame a tick, got " .. most_rings)
  assert_equal(most_rings, 1, "ring frames were sent")

  -- note offs (docs/notes/lua/io/targets.md): checked each 48 Hz step, so
  -- every MIDI and crow note off comes within one step of its time
  local late = late_midi_offs(rig)
  assert_equal(#late, 0, "MIDI note offs within a step of their time: " .. first_lines(late))
  local late_gates = late_crow_gates(rig)
  assert_equal(#late_gates, 0, "crow's gate low within a step of its time: " .. first_lines(late_gates))
end)

test("after that minute everything stops with no note left", function()
  -- Review Focus 1 for everything at once: the patterns stopped, the keys
  -- released, then cleanup(). The ii module's leaving sequence sends at
  -- most II.cleanup_sends (14) waiting offs, and this rig can owe more
  -- (seven voices on an ER-301 and a TELEXo), so the queue is drained by
  -- steps before cleanup(); nothing more of the leaving sequence is held
  -- than its notes file promises
  local rig = minute_with_everything_on()
  local context, S = rig.context, rig.S
  pattern_clock_stop()
  for _, played in ipairs(MPE_NOTES) do
    context.midi.send(ROUTES.midi_in, {type = "note_off", note = played.note, vel = 0, ch = played.channel})
  end
  rig.mpe_held = false
  for _ = 1, 200 do
    if S.lib.io_ii.queued() == 0 then break end
    context.clock.advance_until(S.lfo_clock)
  end
  assert_equal(S.lib.io_ii.queued(), 0, "the ii queue drained by steps")
  cleanup()

  -- No MIDI note left on, on any port and channel. MIDI out counts the ids
  -- on one port, channel and note and sends their off once, when the last
  -- ends (docs/notes/lua/io/midi_out.md), so where two ids met on a note (a
  -- step note given the member channel of a held played note of the same
  -- pitch, once every member channel is busy) a channel holds more ons than
  -- offs: each note on that finds its note already on is a repeat, and a
  -- channel's ons are its offs plus its repeats
  for _, port in ipairs(SYSTEM.midi_ports) do
    local on, ons, offs, repeats = {}, {}, {}, {}
    for _, bytes in ipairs(rig.devices[port].sent) do
      local msg = message(bytes)
      local key = msg.ch and msg.note and (msg.ch * 128 + msg.note)
      if msg.type == "note_on" then
        if on[key] then repeats[msg.ch] = (repeats[msg.ch] or 0) + 1 end
        on[key] = true
        ons[msg.ch] = (ons[msg.ch] or 0) + 1
      elseif msg.type == "note_off" then
        on[key] = nil
        offs[msg.ch] = (offs[msg.ch] or 0) + 1
      end
    end
    for key in pairs(on) do
      error("port " .. port .. " channel " .. math.floor(key / 128) .. " note " .. key % 128 .. " is left on")
    end
    for channel = 1, 16 do
      assert_equal((offs[channel] or 0) + (repeats[channel] or 0), ons[channel] or 0, "port " .. port .. " channel "
        .. channel .. ": ons == offs + repeats")
    end
  end
  for name, player in pairs(rig.players) do
    local counts = {}
    for _, call in ipairs(player.calls) do counts[call[1]] = (counts[call[1]] or 0) + 1 end
    assert_true((counts.note_on or 0) > 0, "nb player " .. name .. " played")
    assert_true((counts.note_on or 0) == (counts.note_off or 0) or (counts.stop_all or 0) > 0,
      "nb player " .. name .. ": " .. (counts.note_on or 0) .. " ons, " .. (counts.note_off or 0)
      .. " offs, stop_all " .. (counts.stop_all or 0))
  end
  -- every gate line crow got high ends low: the last line crow got for its
  -- device, command and first argument is its low (an off may lower a line
  -- never raised, so lows are not matched to highs)
  local last, raised = {}, {}
  for _, line in ipairs(context.crow.sent) do
    local device, command, args = line:match("^ii%.(%w+)%.([%w_]+)%((.-)%)$")
    if device and (command == "tr" or command == "env") then
      local first, value = args:match("^([^,]+), (.+)$")
      local key = device .. "." .. command .. "(" .. first .. ")"
      last[key] = value
      if value == "1" then raised[key] = true end
    end
  end
  local count = 0
  for key in pairs(raised) do
    count = count + 1
    assert_equal(last[key], "0", "ii line " .. key .. " ends low")
  end
  -- each kind of gate line went high at least once (in this flood voice 1's
  -- chord alone fills the queue at each hit, so the lines of the ports and
  -- outputs only later voices play may never be raised: the queue drops
  -- the newest, docs/notes/lua/io/ii.md)
  local kinds = {}
  for key in pairs(raised) do kinds[key:match("^([%w_]+%.[%w_]+)%(")] = true end
  for _, kind in ipairs({"er301.tr", "txo.tr", "txo.env"}) do
    assert_true(kinds[kind], kind .. " went high on some line (" .. count .. " lines high)")
  end
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(next(S.lib.io_targets.sounding(voice)), nil, "voice " .. voice .. " sounds no target note")
  end
end)

end

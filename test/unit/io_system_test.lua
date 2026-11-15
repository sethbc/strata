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

-- The rig and the minute (the 3.6 plan's Task 3a). MIDI devices sit at ports 1
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
  -- The density, cut to keep the file's run time (never a bound): every
  -- second pattern step set (a chord of eight in four hits every 0.2 s on
  -- each voice); the fifteen MPE notes' values moving every fourth LFO step
  -- (12 Hz each: 45 values at a time, still more than MIDI out's 24 a
  -- step); the remote grid flipped between two pages and redrawn every
  -- third LFO step (16 times a second, against the remote's 30 Hz draw
  -- tick), and the faders and the watched params moved as often (an E16
  -- encoder turned at half that)
  density = {step_every = 2, mpe_every = 4, frame_every = 3, move_every = 3},
  -- the bus test's minutes, which count ii lines and no bound: one step in
  -- four, the MPE values every eighth LFO step, the grid redrawn and the
  -- faders and params moved every twelfth (4 Hz)
  light = {step_every = 4, mpe_every = 8, frame_every = 12, move_every = 12},
  tick_tolerance = h.stubs.MATRON_TICK_SECONDS,
  -- the minute with everything on: about 10 s under the ii bus's rate at
  -- 120 BPM (and a second's settle each side), then the flood for its
  -- last 48 s, the fifteen MPE keys released and struck again every 96
  -- LFO steps (2 s)
  flood_seconds = 48, restrike_steps = 96,
  -- offs the MIDI check must time against an end, in each part and on
  -- each synth port, so a part or a port whose check went silent fails:
  -- under the bus's rate the minute times 36 (ports 1 to 4: 6, 5, 10, 15),
  -- held to 20 in all and 2 a port; in the flood 7684, 7688, 15376 and
  -- 23064, held to about 40% of each
  timed_offs = {light = 20, light_port = 2, flood = {3000, 3000, 6000, 9000}},
  stretch = {tempo = 120, settle_seconds = 1},
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

-- True outside every clock's coroutine: the test's own calls (a played
-- note sent in, a param set), never a pattern's step (Lua 5.3 names the
-- main thread, LuaJIT gives nil there)
local function in_main_thread()
  local running, is_main = coroutine.running()
  return running == nil or is_main == true
end

-- A plugged MIDI device's sends, each {bytes, t, lfo, main}, kept in device.log
local function watch_midi(S, device)
  device.log = {}
  local send = device.send
  device.send = function(self, data)
    send(self, data)
    self.log[#self.log + 1] = {bytes = self.sent[#self.sent], t = util.time(), lfo = in_lfo_step(S),
      main = in_main_thread()}
  end
  return device
end

-- crow's lines, each {line, t, lfo}, kept in the returned list; each line
-- crow got is also handed to log.heard(line) when one is set
local function watch_crow(S, context)
  local log = {}
  local send = norns.crow.send
  norns.crow.send = function(line)
    local before = #context.crow.sent
    send(line)
    if #context.crow.sent > before then
      log[#log + 1] = {line = line, t = util.time(), lfo = in_lfo_step(S)}
      if log.heard then log.heard(line) end
    end
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

-- A logged MIDI send's message, parsed once
local function message_of(entry)
  if not entry.msg then entry.msg = midi.to_msg(entry.bytes) end
  return entry.msg
end

local function message(bytes) return midi.to_msg(bytes) end

-- Groups a log's entries by time (a clock's tick sends at one time, and
-- each kind counted here has one clock sending it): time -> count of those
-- that pass keep(entry)
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
-- every second step set (SYSTEM.step_every), the 1/8 division (four hits
-- fit in a step at 300 BPM)
local function busy_patterns(S, density)
  for voice = 1, S.constants.NUM_VOICES do
    params:set("v" .. voice .. "_seq_division", SYSTEM.division)
    for step = 1, S.constants.PATTERN_LENGTH do
      local on = (step - 1) % density.step_every == 0
      S.patterns[voice][step] = on and SYSTEM.level or 0
      if on then
        S.lib.sequencer.set_step_attr(voice, step, "notes", SYSTEM.chord)
        S.lib.sequencer.set_step_attr(voice, step, "ratchet", SYSTEM.ratchet)
      end
    end
  end
end

-- The hits busy_patterns plays in seconds (a minute when not given): each
-- voice's set steps (one in step_every of its 1/8 steps, 10 a second at
-- 300 BPM) times the ratchet
local function expected_hits(S, density, seconds)
  local steps_per_second = SYSTEM.tempo / 60 * 2
  return S.constants.NUM_VOICES * steps_per_second / density.step_every * SYSTEM.ratchet * (seconds or SYSTEM.minute)
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
  local rig = {context = context, S = S, players = made, devices = {}, hits = {}, print = print,
    density = options.density or SYSTEM.density}
  -- a step output of the test's own, after the real ones: it only records
  -- each hit (its time, the beat now, the event's beat, gate and pitches),
  -- so a note off can be checked against its note's time
  S.register_step_output({name = "system probe", play = function(event)
    rig.hits[#rig.hits + 1] = {t = util.time(),
      now_beat = clock.get_beats(), tempo = clock.get_tempo(), gap = S.lib.io_targets.TARGETS.step_gap_seconds,
      voice = event.voice,
      beat = event.beat, gate_beats = event.gate_beats, pitches = event.pitches}
  end})
  rig.crow = watch_crow(S, context)
  -- each followed value crow's budget made wait, with the window's count
  -- then (the positive control of "no followed value in a full window")
  rig.crow_deferred = {}
  local send_value = S.lib.io_crow.send_value
  S.lib.io_crow.send_value = function(key, line)
    local sent = send_value(key, line)
    if not sent then rig.crow_deferred[#rig.crow_deferred + 1] = S.lib.io_crow.budget_state().sent end
    return sent
  end
  rig.osc = watch_osc(context)
  for _, port in ipairs(SYSTEM.midi_ports) do
    rig.devices[port] = watch_midi(S, context.midi.plug(port, "synth " .. port))
  end
  context.crow.plug()
  params:set("clock_tempo", SYSTEM.tempo)
  run_all_voices(S)
  busy_patterns(S, rig.density)
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
-- own, on ports 3 and 4; an ER-301 port and a TELEXo output of its own
-- each (so each voice's lines can be seen high and low), voices 1, 3, 5
-- and 7 on the TELEXo's envelope; the nb players alternate
local ROUTES = {
  midi = {{port = 1, mpe = true}, {port = 2, mpe = true}, {port = 3, channel = 3}, {port = 3, channel = 4},
    {port = 4, channel = 5}, {port = 4, channel = 6}, {port = 4, channel = 7}},
  er301 = {1, 2, 3, 4, 5, 6, 7},
  txo = {1, 2, 3, 4, 5, 6, 7}, txo_envelope = {true, false, true, false, true, false, true},
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
  params:set("crow_in1_mode", option_index("crow_in1_mode", "cv"))
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

-- A line's key as crow's lines name it: "er301.tr(3)"
local function line_key(S, device, command, first)
  return device .. "." .. command .. "(" .. S.lib.io_crow.number(first) .. ")"
end

-- The ii queue watched as it is used: every send and send_off still goes
-- to the real module (the test only reads what it answers and how many
-- lines wait). Each send accepted while 48 or more lines waited is noted.
-- The offs owed are kept exactly: one joins when send_off returns true and
-- the queue grew by it, and one is paid when crow gets that line's low, so
-- the offs owed are the offs waiting; after every call and at every LFO
-- step (a step hook of the test's, after the ii module's) the lines
-- waiting are checked against 48 plus the offs owed then
local function watch_ii(rig)
  local S = rig.S
  local ii = S.lib.io_ii
  local seen = {accepted_full = 0, most = 0, sends = 0, offs = 0, calls = 0, owed = {}, owed_count = 0,
    most_owed = 0, offs_joined = 0}
  local send, send_off = ii.send, ii.send_off
  local function note_waiting()
    local waiting = ii.queued()
    if waiting > seen.most then seen.most = waiting end
    if seen.owed_count > seen.most_owed then seen.most_owed = seen.owed_count end
    if waiting > ii.II.queue_max + seen.owed_count then
      seen.over = seen.over or string.format("%d waiting, %d offs owed, at %.4f", waiting, seen.owed_count,
        util.time())
    end
  end
  seen.note_waiting = note_waiting
  seen.trace = {}  -- {t, waiting} at each step of the minute's second part
  S.lib.lfos.on_step(function()
    note_waiting()
    if rig.stretch and not rig.stretch.stop then seen.trace[#seen.trace + 1] = {t = util.time(), waiting = ii.queued()} end
  end)
  rig.crow.heard = function(line)
    local device, command, first, value = line:match("^ii%.(%w+)%.([%w_]+)%(([^,]+), (.-)%)$")
    if not device or value ~= "0" then return end
    local key = device .. "." .. command .. "(" .. first .. ")"
    if (seen.owed[key] or 0) > 0 then
      seen.owed[key] = seen.owed[key] - 1
      seen.owed_count = seen.owed_count - 1
    end
  end
  ii.send = function(device, command, ...)
    local waiting = ii.queued()
    seen.calls = seen.calls + 1
    local accepted = send(device, command, ...)
    if accepted then seen.sends = seen.sends + 1 end
    if accepted and waiting >= ii.II.queue_max then seen.accepted_full = seen.accepted_full + 1 end
    note_waiting()
    return accepted
  end
  ii.send_off = function(device, command, first, ...)
    seen.offs = seen.offs + 1
    seen.calls = seen.calls + 1
    local before = ii.queued()
    local owed = send_off(device, command, first, ...)
    if owed and ii.queued() == before + 1 then
      local key = line_key(S, device, command, first)
      seen.owed[key] = (seen.owed[key] or 0) + 1
      seen.owed_count = seen.owed_count + 1
      seen.offs_joined = seen.offs_joined + 1
    end
    note_waiting()
    return owed
  end
  return seen
end

-- Everything on: the routes, the MPE input, the surfaces, then the bus
-- given to Strata (its devices made ready), and one step for MIDI out's
-- routes to settle (plan ruling 29)
local function everything_on(rig, bus)
  local context, S = rig.context, rig.S
  set_routes(S)
  mpe_input(S)
  surfaces(rig)
  rig.ii = watch_ii(rig)
  bus = bus or "strata"
  if bus ~= S.lib.io_rig.get("ii_bus") then set_rig(S, "ii_bus", bus) end
  assert_equal(S.lib.io_ii.leads(), bus == "strata", "Strata leads the ii bus only under strata")
  context.clock.advance_until(S.lfo_clock)
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_out_port"), ROUTES.midi[voice].port,
      "voice " .. voice .. "'s MIDI route stands after the settle")
  end
  assert_true(S.lib.io_tape.is_on(), "the tape runs")
end

-- What each step of the minute plays with everything on: the held MPE
-- notes' values moved, the faders swept and an E16 encoder turned, the
-- watched params moved, the remote grid redrawn
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
  return function(n)
    -- crow's input 1 in cv mode streams a value every LFO step (crow-ii.md
    -- §1: input[n].stream calls back every 0.02 s)
    context.crow.fire("strata_in", 1, 5 * math.sin(n * 0.05))
    if rig.mpe_held and n % rig.density.mpe_every == 0 then
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
    if n % rig.density.move_every == 0 then
      for m = 1, S.constants.NUM_MACROS do
        local value = (n + m * 8) % 254
        if value > 127 then value = 254 - value end
        context.midi.send(SYSTEM.faders_port, {type = "cc", cc = 32 + m - 1, val = value, ch = 1})
      end
      for index, id in ipairs(moved) do
        params:set_raw(id, 0.25 + 0.5 * ((math.floor(n / rig.density.move_every) + index) % 10) / 10)
      end
    end
    if n % (2 * rig.density.move_every) == 0 then
      context.midi.send(SYSTEM.e16_port, {type = "cc", cc = 102 + math.floor(n / 6) % 16, val = 1, ch = 16})
    end
    -- every frame_every-th LFO step (16 times a second in the bounds
    -- minute, against the remote's 30 Hz draw tick) the remote grid flips
    -- between its second and third pages, which differ in well over a
    -- tick's 96 cells, and is redrawn (the remote clock sends only the
    -- cells that changed, so a redraw that changed little would not load
    -- its bound)
    if n % rig.density.frame_every == 0 then
      local remote = S.constants.GRID_PORTS.remote
      S.lib.grid_core.set_page(remote, S.lib.grid_core.page(remote) == 2 and 3 or 2)
      grid_redraw()
    end
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
    if n % scene_steps == 0 then S.lib.io_actions.recall_scene(math.floor(n / scene_steps) % 2 + 1) end
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

local function release_mpe_keys(rig)
  for _, key in ipairs(MPE_NOTES) do
    rig.context.midi.send(ROUTES.midi_in, {type = "note_off", note = key.note, vel = 0, ch = key.channel})
  end
  rig.mpe_held = false
end

local function strike_mpe_keys(rig)
  for _, key in ipairs(MPE_NOTES) do
    rig.context.midi.send(ROUTES.midi_in, {type = "note_on", note = key.note, vel = 100, ch = key.channel})
  end
  rig.mpe_held = true
end

-- The fifteen struck before the patterns start: a step's chord never
-- steals (docs/notes/lua/sequencer.md), and a chord note younger than
-- NOTES.cut_seconds cannot be stolen either, so notes struck in the
-- instant the patterns start would find each voice's extra slots taken
local function strike_before_patterns(rig)
  strike_mpe_keys(rig)
  for voice = 1, 2 do
    assert_equal(rig.S.lib.notes.held(voice), voice == 1 and 8 or 7, "voice " .. voice .. " holds its played notes")
  end
end

-- The minute's first part, at a load the ii bus can carry: 120 BPM, each
-- voice a single note (no chord, no ratchet) on steps v and v + 8 of its
-- 1/8 steps, so the seven take turns, one note every 0.25 s in all (about
-- 40 lines a second, under the bus's 192), no key held; the scenes
-- captured with these patterns (a recall puts its patterns back); a
-- second for the leader's start lines to drain and the tempo to settle
local function under_the_bus_rate(rig)
  local context, S = rig.context, rig.S
  params:set("clock_tempo", SYSTEM.stretch.tempo)
  for voice = 1, S.constants.NUM_VOICES do
    for step = 1, S.constants.PATTERN_LENGTH do
      S.lib.sequencer.set_step_attr(voice, step, "notes", nil)
      S.lib.sequencer.set_step_attr(voice, step, "ratchet", nil)
      S.patterns[voice][step] = (step == voice or step == voice + 8) and SYSTEM.level or 0
    end
  end
  two_scenes(S)
  context.clock.run_for(SYSTEM.stretch.settle_seconds)
  assert_equal(S.lib.io_ii.queued(), 0, "the ii queue is empty before the first part")
  rig.stretch = {start = util.time(), dropped = S.lib.io_ii.dropped()}
end

-- The minute's second part, the flood (design §14 focus 4): the first
-- part's patterns stopped, 300 BPM, chords of 8 and ratchets of 4 again,
-- the scenes captured with them, the tempo settled, then the fifteen MPE
-- notes struck before the patterns start
local function the_flood(rig)
  local context, S = rig.context, rig.S
  pattern_clock_stop()
  rig.stretch.stop = util.time()
  rig.stretch.dropped_after = S.lib.io_ii.dropped()
  params:set("clock_tempo", SYSTEM.tempo)
  busy_patterns(S, rig.density)
  two_scenes(S)
  context.clock.run_for(SYSTEM.stretch.settle_seconds)
  strike_before_patterns(rig)
end

-- The script loaded with everything on, then the minute played: first the
-- part under the bus's rate, then the flood to the minute's end, the
-- fifteen MPE notes released and struck again every two seconds (so lines
-- go low and offs are owed while the queue is full), so the minute ends,
-- and cleanup comes, with the queue full
local function minute_with_everything_on()
  local rig = started()
  everything_on(rig)
  local moves = everything_moves(rig)
  local again = SYSTEM.restrike_steps
  rig.each_step = function(n, t)
    if rig.flooding then
      if n % again == 0 then release_mpe_keys(rig)
      elseif n % again == 1 then strike_mpe_keys(rig) end
    end
    moves(n, t)
  end
  rig.minute_start = util.time()
  under_the_bus_rate(rig)
  play_minute(rig, SYSTEM.minute - SYSTEM.flood_seconds - 2 * SYSTEM.stretch.settle_seconds)
  the_flood(rig)
  rig.flooding = true
  rig.flood_start = util.time()
  play_minute(rig, SYSTEM.minute - (util.time() - rig.minute_start))
  return rig
end

-- The minute with everything on is played once for the two tests that
-- read it (the bounds during it, the stop after it): the first leaves its
-- rig here and the second takes it, or plays the minute itself when run
-- without the first (or after it failed before the minute ended)
local played = {}

local function take_played_minute()
  local rig = played.everything_on
  played.everything_on = nil
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

-- A hit's note end, in seconds: its beat plus its gate, at the tempo, less
-- the targets core's step gap (hit.gap, TARGETS.step_gap_seconds, at most
-- half the gate: lib/io/targets.lua ends every step note that early)
local function hit_end(hit)
  local seconds_per_beat = 60 / hit.tempo
  local early = math.min(hit.gap, hit.gate_beats * seconds_per_beat / 2)
  return hit.t + (hit.beat + hit.gate_beats - hit.now_beat) * seconds_per_beat - early
end

local function time_key(voice, t) return voice .. "@" .. string.format("%.6f", t) end

-- The hits by voice and time
local function hits_at(rig)
  local index = {}
  for _, hit in ipairs(rig.hits) do index[time_key(hit.voice, hit.t)] = hit end
  return index
end

-- Whether the note off at log[index] is a retrigger: a note on for the
-- same channel and note follows it at the same moment (with only other
-- messages between)
local function retriggers(log, index, msg)
  local entry = log[index]
  for later = index + 1, #log do
    local next_entry = log[later]
    if next_entry.t ~= entry.t then return false end
    local next_msg = message_of(next_entry)
    if next_msg.ch == msg.ch and next_msg.note == msg.note then return next_msg.type == "note_on" end
  end
  return false
end

-- The MIDI notes' timing, read from each synth port's log. A note (a port,
-- channel and note number) is on from its note on to the off that ends it,
-- and its record keeps when it is due to end: the latest end of the ids
-- holding it (a step note's end is its hit's beat plus its gate), and no
-- end at all once any holder has none (a played key, or a note on that
-- matched no hit). MIDI out counts the ids on a note
-- (docs/notes/lua/io/midi_out.md): a start at count 0 sends a note on; a
-- start at count 1 or more sends a note off and then a note on (#709's
-- retrigger; main's module sends the note on alone); an end at count 1
-- sends the note off; an end at count 2 or more sends nothing. So while a
-- note is on, some holder is meant to hold it, and once its record's end
-- has passed no holder is left and its last off is owed. Three rules:
-- 1. every off is timed, a retrigger's (an off followed at once by a note
--    on for the same note) and a final one alike: it fails when the
--    note's record has an end and the off comes later than one LFO step
--    (and a matron tick) after it. An off before the end is not judged: a
--    stop (the patterns', a voice's, a route's change) rightly cuts a note
--    short, and telling those apart would model the module in the test. A retrigger's off comes while a later
--    holder still holds the note, so the record's end, the latest of its
--    holders', has not passed (a held key: a 25 ms step note under it ends
--    unseen, the next step note's retrigger finds a record with no end);
--    a retrigger keeps the record and its note on adds its holder;
-- 2. a note on alone for a note already on (main's count up) is late when
--    the note's record has passed its end by more than a step: its off was
--    owed and never came;
-- 3. an off for a note that is not on fails (the fixed module never sends
--    one).
-- Returns the problems (text) and how many offs were timed against an end
-- in the minute's two parts ({light, flood}, by the time they came)
local function midi_timing(rig)
  local problems, timed = {}, {light = {total = 0}, flood = {total = 0}}
  local index = hits_at(rig)
  local allowed = SYSTEM.step + SYSTEM.tick_tolerance + 1e-6
  local function part(t)
    if rig.stretch and t >= rig.stretch.start and t <= rig.stretch.stop then return "light" end
    if rig.flood_start and t >= rig.flood_start then return "flood" end
  end
  local function problem(port, msg, t, what)
    problems[#problems + 1] = string.format("port %d ch %d note %d at %.4f: %s", port, msg.ch, msg.note, t, what)
  end
  for _, port in ipairs(SYSTEM.midi_ports) do
    local open = {}
    local log = rig.devices[port].log
    for position, entry in ipairs(log) do
      local msg = message_of(entry)
      local key = msg.ch and msg.note and (msg.ch * 128 + msg.note)
      if is_status(msg, "note_on") then
        local hit = index[time_key(voice_on(port, msg.ch) or 0, entry.t)]
        local due = false  -- no end to keep
        if hit and not entry.main then
          if not hit.notes then
            hit.notes = {}
            for _, pitch in ipairs(hit.pitches) do hit.notes[util.clamp(math.floor(pitch + 0.5), 0, 127)] = true end
          end
          if hit.notes[msg.note] then due = hit_end(hit) end
        end
        local record = open[key]
        if not record then
          open[key] = {due = due}
        else
          -- rule 2, for a note on alone (a retrigger's off was timed itself)
          if not record.retriggered and record.due and entry.t > record.due + allowed then
            problem(port, msg, entry.t, string.format("a note on over a note past its end %.4f", record.due))
          end
          record.retriggered = nil
          if record.due and due then record.due = math.max(record.due, due) else record.due = false end
        end
      elseif is_status(msg, "note_off") then
        local record = open[key]
        if not record then
          problem(port, msg, entry.t, "an off for a note that is not on")  -- rule 3
        else
          if record.due then  -- rule 1
            local which = part(entry.t)
            if which then
              timed[which].total = timed[which].total + 1
              timed[which][port] = (timed[which][port] or 0) + 1
            end
            if entry.t > record.due + allowed then
              problem(port, msg, entry.t, string.format("an off late for its end %.4f", record.due))
            end
          end
          if retriggers(log, position, msg) then record.retriggered = true else open[key] = nil end
        end
      end
    end
  end
  return problems, timed
end

-- Each low of crow's gate output (voice 3's) later than one LFO step after
-- the end of the voice's latest hit before it, and how many lows were checked
local function late_crow_gates(rig)
  local late, checked = {}, 0
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
    if entry.line == "output[2].volts = 0" and latest then
      checked = checked + 1
      if entry.t > hit_end(latest) + allowed then
        late[#late + 1] = string.format("gate low at %.4f, due %.4f", entry.t, hit_end(latest))
      end
    end
  end
  return late, checked
end

local function first_lines(list, count)
  local shown = {}
  for index = 1, math.min(#list, count or 5) do shown[index] = list[index] end
  return table.concat(shown, "; ")
end

-- What the minute's second part (under the ii bus's rate) got wrong, as
-- text: each voice's ER-301 port and TELEXo output must be seen high and
-- then low; Just Friends and W/ must play notes of every voice (a line
-- belongs to the latest hit before it: the voices take turns, one note at
-- a time); nothing may be dropped; and between each two hits the queue
-- must have been empty at some step
local function under_the_rate_problems(rig)
  local S = rig.S
  local stretch = rig.stretch
  local problems = {}
  local hits = {}
  for _, hit in ipairs(rig.hits) do
    if hit.t >= stretch.start and hit.t <= stretch.stop then hits[#hits + 1] = hit end
  end
  if #hits < 2 * S.constants.NUM_VOICES then problems[#problems + 1] = #hits .. " hits only" end
  local high, low, players = {}, {}, {jf = {}, wsyn = {}}
  local next_hit, latest = 1, nil
  for _, entry in ipairs(rig.crow) do
    if entry.t >= stretch.start and entry.t <= stretch.stop then
      while hits[next_hit] and hits[next_hit].t <= entry.t do
        latest = hits[next_hit]
        next_hit = next_hit + 1
      end
      local device, command, args = entry.line:match("^ii%.(%w+)%.([%w_]+)%((.-)%)$")
      if device == "er301" or device == "txo" then
        local first, value = args:match("^([^,]+), (.+)$")
        local key = device .. "." .. command .. "(" .. tostring(first) .. ")"
        if command == "tr" and value == "1" then high[key] = true end
        if command == "tr" and value == "0" and high[key] then low[key] = true end
      elseif command == "play_note" and players[device] and latest then
        players[device][latest.voice] = true
      end
    end
  end
  for voice = 1, S.constants.NUM_VOICES do
    for _, key in ipairs({"er301.tr(" .. ROUTES.er301[voice] .. ")", "txo.tr(" .. ROUTES.txo[voice] .. ")"}) do
      if not (high[key] and low[key]) then
        problems[#problems + 1] = "voice " .. voice .. "'s " .. key .. (high[key] and " never went low" or
          " never went high")
      end
    end
    for name, voices in pairs(players) do
      if not voices[voice] then problems[#problems + 1] = name .. " got no note of voice " .. voice end
    end
  end
  if stretch.dropped_after ~= stretch.dropped then
    problems[#problems + 1] = (stretch.dropped_after - stretch.dropped) .. " lines dropped"
  end
  for index = 1, #hits - 1 do
    local emptied = false
    for _, reading in ipairs(rig.ii.trace) do
      if reading.t > hits[index].t and reading.t <= hits[index + 1].t and reading.waiting == 0 then
        emptied = true
        break
      end
    end
    if not emptied then
      problems[#problems + 1] = string.format("the queue never emptied between the hits at %.3f and %.3f",
        hits[index].t, hits[index + 1].t)
    end
  end
  return problems
end

---------------------------------------------------------------------------
-- The tests
---------------------------------------------------------------------------

test("with every default a minute of playing sends nothing anywhere", function()
  -- the plan's "Nothing by default", for every module at once
  local rig = started()
  local context, S = rig.context, rig.S
  rig.each_step = plain_chords(rig, 1)
  -- a note hook of the test's own counts the played notes each voice's
  -- allocator started (it only counts)
  local played_notes = {}
  S.register_note_hook({name = "system probe", started = function(voice, _, note)
    if note.owner == "midi" then played_notes[voice] = (played_notes[voice] or 0) + 1 end
  end})
  play_minute(rig)
  for voice = 1, 3 do
    assert_true((played_notes[voice] or 0) >= 100, "the played chords reached voice " .. voice .. ": "
      .. tostring(played_notes[voice]))
  end
  pattern_clock_stop()
  assert_true(S.pattern_playing == false, "the patterns stopped")
  -- the minute played: the hits of every set step of seven voices
  assert_true(#rig.hits >= 0.9 * expected_hits(rig.S, rig.density), "hits played: " .. #rig.hits)
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
  played.everything_on = rig
  local S = rig.S
  pattern_clock_stop()
  assert_true(#rig.hits >= 0.9 * expected_hits(rig.S, rig.density, SYSTEM.flood_seconds), "hits played: " .. #rig.hits)

  -- ii (docs/notes/lua/io/ii.md): at most 4 lines a step, every one from
  -- the step; no send accepted while 48 or more lines waited; at every
  -- step and call, never more waiting than 48 plus the offs owed then
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
  assert_equal(rig.ii.over, nil, "never more waiting than 48 plus the offs owed (most waiting " .. rig.ii.most
    .. ", most owed " .. rig.ii.most_owed .. ")")
  assert_true(rig.ii.most >= II.queue_max and S.lib.io_ii.dropped() > 0, "the queue filled and dropped")
  assert_true(rig.ii.offs_joined > 100 and rig.ii.most_owed >= 4, "offs joined the queue while it was busy ("
    .. rig.ii.offs_joined .. " joined, at most " .. rig.ii.most_owed .. " owed at once)")
  assert_true(rig.ii.most > II.queue_max, "offs waited beyond the 48: " .. rig.ii.most)

  -- the minute's second part, under the bus's rate: every voice's ER-301
  -- port and TELEXo output seen high and then low, Just Friends and W/
  -- playing every voice's notes, nothing dropped, and the queue empty
  -- again between each two notes
  local problems = under_the_rate_problems(rig)
  assert_equal(#problems, 0, "under the bus's rate: " .. first_lines(problems, 10))

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
  -- the control: followed values came while a window was full, and each
  -- one that waited found its window's count at the limit or past it
  -- (notes and gates always go, so a window can hold more than 32)
  assert_true(#rig.crow_deferred > 0, "a followed value came while its window was full")
  assert_equal(#S.lib.mod_sources.list("crow"), 1, "crow's input 1 streamed in cv mode, a modulation source")
  for index, count in ipairs(rig.crow_deferred) do
    assert_true(count >= CROW.lines_per_window, "deferred value " .. index .. "'s window held " .. count .. " lines")
  end

  -- MIDI out (docs/notes/lua/io/midi_out.md): at most 24 MPE expression
  -- messages a step over both MPE ports, and 8 CC out
  local MIDI_OUT = S.lib.io_midi_out.MIDI_OUT
  local expression = per_time(joined(rig.devices[1].log, rig.devices[2].log), function(entry)
    if not entry.lfo then return false end
    local msg = message_of(entry)
    return msg.type == "pitchbend" or msg.type == "channel_pressure" or (msg.type == "cc" and msg.cc == 74)
  end)
  local most_expression = largest(expression)
  assert_true(most_expression <= MIDI_OUT.express_per_step, "at most 24 expression a step, got " .. most_expression)
  assert_equal(most_expression, MIDI_OUT.express_per_step, "fifteen moving notes fill a step's 24")
  local cc_out = per_time(rig.devices[ROUTES.cc_port].log, function(entry)
    local msg = message_of(entry)
    return entry.lfo and msg.type == "cc" and msg.ch == ROUTES.cc_channel
  end)
  local most_cc = largest(cc_out)
  assert_true(most_cc <= MIDI_OUT.cc_per_step, "at most 8 CC out a step, got " .. most_cc)
  assert_equal(most_cc, MIDI_OUT.cc_per_step, "the eight slots filled a step")
  -- expression sent outside the step is a note's first values: each such
  -- message comes just before a note on on its channel, at the same time
  -- (only more of the note's first values, or an off ending the note it
  -- replaces, between them)
  local stray = {}
  for _, port in ipairs({1, 2}) do
    local log = rig.devices[port].log
    for index, entry in ipairs(log) do
      local msg = message_of(entry)
      local expressive = msg.type == "pitchbend" or msg.type == "channel_pressure" or (msg.type == "cc" and msg.cc == 74)
      if expressive and not entry.lfo then
        local starts_note = false
        for later = index + 1, #log do
          local next_entry = log[later]
          if next_entry.t ~= entry.t then break end
          local next_msg = message_of(next_entry)
          if next_msg.ch == msg.ch then
            if next_msg.type == "note_on" then starts_note = true; break end
            local first_value = next_msg.type == "pitchbend" or next_msg.type == "channel_pressure"
              or (next_msg.type == "cc" and next_msg.cc == 74) or next_msg.type == "note_off"
            if not first_value then break end
          end
        end
        if not starts_note then
          stray[#stray + 1] = string.format("port %d ch %d %s at %.4f", port, msg.ch, msg.type, entry.t)
        end
      end
    end
  end
  assert_equal(#stray, 0, "expression outside the step only before a note on: " .. first_lines(stray))

  -- the remote grid (docs/notes/lua/io/remote.md): at most 96 LED
  -- messages a 1/30 s tick
  -- an LED message is a note on (status 0x90, channel 1 or 2) whatever its
  -- level: one at level 0 reads back as a note off (midi.to_msg), so the
  -- status byte is counted
  local leds = per_time(rig.grid.log, function(entry)
    return entry.bytes[1] == 0x90 or entry.bytes[1] == 0x91
  end)
  local most_leds = largest(leds)
  assert_true(most_leds <= S.lib.io_remote.REMOTE.leds_per_tick, "at most 96 LED messages a tick, got " .. most_leds)
  assert_equal(most_leds, S.lib.io_remote.REMOTE.leds_per_tick, "a redraw filled a tick")

  -- OSC (docs/notes/lua/io/osc.md): at most 32 messages a 1/15 s tick
  local most_osc = largest(per_time(rig.osc, function() return true end))
  assert_true(most_osc <= S.lib.io_osc.OSC.sends_per_tick, "at most 32 OSC messages a tick, got " .. most_osc)
  assert_equal(most_osc, S.lib.io_osc.OSC.sends_per_tick, "the watched params filled a tick")

  -- the E16's echo (docs/notes/lua/io/controllers.md): at most 16 CCs and
  -- one ring frame a 1/15 s tick
  local CONTROLLERS = S.lib.io_controllers.CONTROLLERS
  local echo = per_time(rig.e16.log, function(entry) return message_of(entry).type == "cc" end)
  local most_echo = largest(echo)
  assert_true(most_echo <= CONTROLLERS.echo_per_tick, "at most 16 echo CCs a tick, got " .. most_echo)
  assert_equal(most_echo, CONTROLLERS.echo_per_tick, "the sixteen macros' echo filled a tick")
  local rings = per_time(rig.e16.log, function(entry)
    return entry.bytes[1] == 0xf0 and entry.bytes[5] == 0x01
  end)
  local most_rings = largest(rings)
  assert_true(most_rings <= 1, "at most one ring frame a tick, got " .. most_rings)
  assert_equal(most_rings, 1, "ring frames were sent")

  -- note offs (docs/notes/lua/io/targets.md): checked each 48 Hz step, so
  -- no MIDI note off, a retrigger's included, comes later than one step
  -- after its note's end (midi_timing's three rules), and crow's gate goes
  -- low no later than a step after the end of voice 3's latest hit. An off
  -- before its note's end is not judged: a stop (the patterns', a voice's,
  -- a route's change) rightly cuts a note short, and telling those apart
  -- would be a second model of the module inside the test
  local timing, timed = midi_timing(rig)
  assert_equal(#timing, 0, "no MIDI note off later than a step after its end: " .. first_lines(timing))
  assert_true(timed.light.total >= SYSTEM.timed_offs.light,
    "offs timed against their ends under the bus's rate: " .. timed.light.total)
  for _, port in ipairs(SYSTEM.midi_ports) do
    local light, flood = timed.light[port] or 0, timed.flood[port] or 0
    assert_true(light >= SYSTEM.timed_offs.light_port, "offs timed against their ends under the bus's rate on port "
      .. port .. ": " .. light)
    assert_true(flood >= SYSTEM.timed_offs.flood[port], "offs timed against their ends in the flood on port "
      .. port .. ": " .. flood)
  end
  local late_gates, lows_checked = late_crow_gates(rig)
  assert_equal(#late_gates, 0, "crow's gate low within a step of its time: " .. first_lines(late_gates))
  assert_true(lows_checked > 100, "crow's gate lows were checked: " .. lows_checked)
end)

test("after that minute everything stops with no note left", function()
  -- Review Focus 1 for everything at once: the patterns stopped, the keys
  -- released, then cleanup() at once, whatever the ii queue holds
  local rig = take_played_minute()
  local reused = rig ~= nil
  -- the runner put its own print back after the last test: the script's
  -- lines go to the quiet install's again, which also records its errors
  if reused then print = rig.print end
  rig = rig or minute_with_everything_on()
  local context, S = rig.context, rig.S
  pattern_clock_stop()
  release_mpe_keys(rig)
  rig.waiting_at_cleanup = S.lib.io_ii.queued()
  -- the case this test is for: cleanup with the ii queue full
  assert_true(rig.waiting_at_cleanup >= S.lib.io_ii.II.queue_max, "the ii queue is full at cleanup: "
    .. rig.waiting_at_cleanup .. " lines wait")
  cleanup()

  -- Every MIDI note on has its note off (design §3.4, §14): on every port
  -- and channel as many offs as ons (held to at the test's end, so every
  -- other check runs first), and no note left on. Every unequal channel
  -- is listed in one failure
  local unbalanced = {}
  for _, port in ipairs(SYSTEM.midi_ports) do
    local on, ons, offs, per_note = {}, {}, {}, {}
    for _, bytes in ipairs(rig.devices[port].sent) do
      local msg = message(bytes)
      local key = msg.ch and msg.note and (msg.ch * 128 + msg.note)
      if msg.type == "note_on" or msg.type == "note_off" then
        local counts = per_note[key] or {on = 0, off = 0}
        per_note[key] = counts
        if msg.type == "note_on" then
          on[key] = true
          ons[msg.ch] = (ons[msg.ch] or 0) + 1
          counts.on = counts.on + 1
        else
          on[key] = nil
          offs[msg.ch] = (offs[msg.ch] or 0) + 1
          counts.off = counts.off + 1
        end
      end
    end
    for key in pairs(on) do
      error("port " .. port .. " channel " .. math.floor(key / 128) .. " note " .. key % 128 .. " is left on")
    end
    for channel = 1, 16 do
      local unequal = {}
      for note = 0, 127 do
        local counts = per_note[channel * 128 + note]
        if counts and counts.on ~= counts.off then
          unequal[#unequal + 1] = "note " .. note .. ": " .. counts.on .. " ons, " .. counts.off .. " offs"
        end
      end
      if (offs[channel] or 0) ~= (ons[channel] or 0) then
        unbalanced[#unbalanced + 1] = "port " .. port .. " channel " .. channel .. ": " .. (ons[channel] or 0)
          .. " ons, " .. (offs[channel] or 0) .. " offs (" .. table.concat(unequal, "; ") .. ")"
      end
    end
  end
  for name, player in pairs(rig.players) do
    local counts = {}
    for _, call in ipairs(player.calls) do counts[call[1]] = (counts[call[1]] or 0) + 1 end
    assert_true((counts.note_on or 0) > 0, "nb player " .. name .. " played")
    assert_equal(counts.note_on or 0, counts.note_off or 0,
      "nb player " .. name .. ": as many offs as ons (stop_all " .. (counts.stop_all or 0) .. ")")
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
  local left_high = {}
  for key in pairs(raised) do
    if last[key] ~= "0" then left_high[#left_high + 1] = key .. " ends at " .. tostring(last[key]) end
  end
  table.sort(left_high)
  assert_equal(#left_high, 0, "every ii gate line crow got high ends low (" .. rig.waiting_at_cleanup
    .. " lines waited at cleanup): " .. table.concat(left_high, ", "))
  -- every voice's lines were raised (the minute's first part plays each
  -- voice), so the check above covered them all
  for voice = 1, S.constants.NUM_VOICES do
    local lines = {"er301.tr(" .. ROUTES.er301[voice] .. ")", "txo.tr(" .. ROUTES.txo[voice] .. ")"}
    if ROUTES.txo_envelope[voice] then lines[#lines + 1] = "txo.env(" .. ROUTES.txo[voice] .. ")" end
    for _, key in ipairs(lines) do assert_true(raised[key], key .. " went high (voice " .. voice .. ")") end
  end
  -- crow's own gate output (voice 3's, output 2) ends low too
  local gate_last
  for _, line in ipairs(context.crow.sent) do
    if starts_with(line, "output[2].volts = ") then gate_last = line end
  end
  assert_equal(gate_last, "output[2].volts = 0", "crow's gate output ends low")
  -- the targets core holds no sounding note: every id it still holds is named
  for voice = 1, S.constants.NUM_VOICES do
    local ids = {}
    for id in pairs(S.lib.io_targets.sounding(voice)) do ids[#ids + 1] = tostring(id) end
    table.sort(ids)
    assert_equal(#ids, 0, "voice " .. voice .. " sounds target notes: " .. table.concat(ids, " "))
  end
  -- the harness checks the invariants of a test that loaded the script;
  -- this one, reading the minute the bounds test loaded, checks them itself
  if reused then
    local broken = h.check_invariants()
    assert_equal(#broken, 0, "invariants after cleanup: " .. table.concat(broken, "; "))
  end
  assert_equal(#unbalanced, 0, "every port and channel has as many note offs as ons: "
    .. table.concat(unbalanced, " | "))
end)

-- The ii lines crow got from index first on, in order
local function ii_lines_from(context, first)
  local lines = {}
  for index = first, #context.crow.sent do
    local line = context.crow.sent[index]
    if starts_with(line, "ii.") then lines[#lines + 1] = line end
  end
  return lines
end

-- Steps the LFO clock until the ii queue is empty (at most limit steps)
local function drain_ii(context, S, limit)
  for _ = 1, limit or 100 do
    if S.lib.io_ii.queued() == 0 then return end
    context.clock.advance_until(S.lfo_clock)
  end
  error("the ii queue did not drain", 2)
end

test("each ii device's lines are crow's, end to end", function()
  -- docs/design/3.6-facts/crow-ii.md section 2: each device's descriptor's
  -- command names and argument order, a line ii.<device>.<command>(<args>);
  -- the note goes in through the targets core's step output, as a step's
  -- hit does, and out through the real ii queue to the crow stub
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  context.crow.plug()
  params:set("v1_out_jf", 1)
  params:set("v1_out_wsyn", 1)
  params:set("v1_out_er301", 12)
  params:set("v1_out_txo", 5)
  params:set("jf_level", 5)
  params:set("wsyn_level", 5)
  local first = #context.crow.sent + 1
  set_rig(S, "ii_bus", "strata")
  drain_ii(context, S)
  assert_equal(table.concat(ii_lines_from(context, first), " | "),
    "ii.jf.mode(1) | ii.wsyn.ar_mode(1) | ii.wsyn.voices(4)", "the leader's start")
  local output
  for _, record in ipairs(S.registry.step_outputs) do
    if record.name == "targets" then output = record end
  end
  assert_true(output ~= nil, "the targets core's step output")
  first = #context.crow.sent + 1
  output.play({voice = 1, step = 1, hit = 1, hits = 1, first = true, level = 7.5, velocity = 0.5, pitches = {72},
    beat = clock.get_beats(), gate_beats = 0.25})
  drain_ii(context, S)
  assert_equal(table.concat(ii_lines_from(context, first), " | "),
    "ii.jf.play_note(1, 2.5) | ii.wsyn.play_note(1, 2.5) | ii.er301.cv(12, 1) | ii.er301.tr(12, 1)"
    .. " | ii.txo.cv(5, 1) | ii.txo.tr(5, 1)", "one note of pitch 72 at velocity 0.5 to each")
end)

-- Every row of the IO page stepped as a player steps it, from the first
-- section's first row to the last with E2: a param or rig row E3 up and
-- back down, an action K3, a detail K3 then each of its fields up and back
-- down, K2 to close. The bus row alone is left as it is (the test is of
-- what each bus setting lets through). Returns the rows visited
local function step_every_row(S)
  S.lib.ui_keys.set_ui_page(S.constants.UI_PAGES.index.IO)
  S.lib.pages_io.show_section("voice")
  local visited = 0
  for _ = 1, 1000 do
    local row = S.lib.pages_io.rows()[S.io_cursor]
    if row.kind == "rig" and row.key == "ii_bus" then
      -- left alone
    elseif row.kind == "param" or row.kind == "rig" then
      enc(3, 1); enc(3, -1)
    elseif row.kind == "action" then
      h.tap(3)
    elseif row.kind == "detail" then
      h.tap(3)
      for _ = 1, #row.fields do
        enc(3, 1); enc(3, -1); enc(2, 1)
      end
      h.tap(2)
    end
    visited = visited + 1
    local before = S.io_cursor
    enc(2, 1)
    if S.io_cursor == before then return visited end
  end
  error("the IO page's rows never ended", 2)
end

-- Every action of S.lib.io_actions run, and each through the doors that
-- reach them: Teletype's three calls, crow's trigger input and OSC's
-- addresses. A toggle runs twice, so the rig ends as it was
local function run_every_action(context, S)
  local actions = S.lib.io_actions
  actions.recall_scene(1)
  actions.next_scene()
  for _ = 1, 2 do
    actions.run_voice(1, 2)
    actions.freeze(1, 2)
    actions.mute(1, 2)
    actions.patterns(2)
  end
  actions.retrigger(1, 1)
  actions.macro(1, 0.5)
  actions.record()
  context.crow.fire("strata_tt1", 1)
  for _ = 1, 2 do
    context.crow.fire("strata_tt2", 1, 2)
    for _, k in ipairs({2, 3, 5}) do context.crow.fire("strata_tt3", k, 1, 2) end
  end
  context.crow.fire("strata_tt3", 1, 1, 100)
  context.crow.fire("strata_tt3", 4, 1, 8000)
  context.crow.fire("strata_change", 1, 1)
  context.osc.receive("/strata/scene", {1})
  for _ = 1, 2 do
    context.osc.receive("/strata/voice/1/run", {2})
    context.osc.receive("/strata/patterns", {2})
  end
  context.osc.receive("/strata/voice/1/retrigger", {1})
end

test("under off and teletype no action anywhere produces an ii command", function()
  -- design §14 focus 5 (docs/notes/lua/io/ii.md): under off and teletype no
  -- line starting ii. reaches crow but Teletype's three handlers
  local rig = started({density = SYSTEM.light})
  local context, S = rig.context, rig.S
  everything_on(rig, "off")
  rig.each_step = everything_moves(rig)
  strike_before_patterns(rig)
  local handlers = "ii.self.call1 = function(a) tell('strata_tt1', a) end"
    .. " | ii.self.call2 = function(a, b) tell('strata_tt2', a, b) end"
    .. " | ii.self.call3 = function(a, b, c) tell('strata_tt3', a, b, c) end"
  for _, bus in ipairs({"off", "teletype"}) do
    local first = #context.crow.sent + 1
    if bus == "teletype" then
      set_rig(S, "ii_bus", "teletype")
      assert_equal(table.concat(ii_lines_from(context, first), " | "), handlers, "the handlers, as the bus turns")
      first = #context.crow.sent + 1
    end
    play_minute(rig)
    assert_true(step_every_row(S) > 50, "every IO row was stepped")
    run_every_action(context, S)
    context.clock.run_for(1)
    pattern_clock_stop()
    assert_true(not S.lib.io_ii.leads(), bus .. ": Strata does not lead")
    assert_equal(table.concat(ii_lines_from(context, first), " | "), "", bus .. ": no ii line")
    -- every ii target (Just Friends, W/, the ER-301, the TELEXo) is routed
    -- only while Strata leads, so nothing even asks the module to send;
    -- the control: the minute played the voices those routes name
    assert_equal(rig.ii.calls, 0, bus .. ": nothing asked the ii module to send")
    assert_true(#rig.hits > 0 and params:get("v1_out_er301") > 0 and params:get("v1_out_txo") > 0,
      bus .. ": the voices routed to the ii devices played")
    rig.hits = {}
  end
end)

---------------------------------------------------------------------------
-- 3.6's params
---------------------------------------------------------------------------

-- The five groups every 3.6 param is in (the plan's Params constraint)
local GROUPS = {"strata_out_midi", "strata_crow", "strata_out_ii", "strata_out_nb", "strata_tape"}

-- Every param of the five groups, found from each group's span in the
-- paramset (the n params after it), hidden ones included; a separator (a
-- device's hidden filler in the ii group) holds no value and is left out
local function io_params()
  local list = {}
  for _, group in ipairs(GROUPS) do
    local index = params.lookup[group]
    assert_true(index ~= nil, "the group " .. group .. " exists")
    for position = index + 1, index + params.params[index].n do
      local param = params.params[position]
      if param.t ~= params.tSEPARATOR then list[#list + 1] = param end
    end
  end
  return list
end

local function io_id_set()
  local set = {}
  for _, param in ipairs(io_params()) do set[param.id] = true end
  return set
end

local function io_values()
  local values = {}
  for _, param in ipairs(io_params()) do values[param.id] = params:get(param.id) end
  return values
end

-- Which voices each target plays now, as text ("midi 1 2 3 | crow 3 | ...")
local function routes_now(S)
  local parts = {}
  for _, target in ipairs(S.registry.note_targets) do
    local voices = {}
    for voice = 1, S.constants.NUM_VOICES do
      if target.routed(voice) then voices[#voices + 1] = voice end
    end
    parts[#parts + 1] = target.name .. " " .. table.concat(voices, " ")
  end
  return table.concat(parts, " | ")
end

local function no_routes(S)
  local parts = {}
  for _, target in ipairs(S.registry.note_targets) do parts[#parts + 1] = target.name .. " " end
  return table.concat(parts, " | ")
end

-- A light start for the param tests: two nb players, a crow, Strata
-- leading the bus (so the ii devices' routes count)
local function started_light()
  local context = load_strata({before_load = function(context)
    context.nb.add_player("alpha")
    context.nb.add_player("beta", {"note_on", "note_off", "stop_all", "add_params"})
  end})
  finish_startup(context)
  local S = local_value("S")
  context.crow.plug()
  set_rig(S, "ii_bus", "strata")
  return context, S
end

local function file_lines(path)
  local lines = {}
  for line in io.lines(path) do lines[#lines + 1] = line end
  return lines
end

test("a PSET with everything on loads back to the same routes, and a 3.5 PSET to everything off", function()
  local context, S = started_light()
  set_routes(S)
  params:set("midi_out_bend_range", 24)
  params:set("midi_pc_in", 1)
  params:set("midi_pc_out", 1)
  context.clock.advance_until(S.lfo_clock)  -- MIDI out's routes settle (plan ruling 29)
  local on_values, on_routes = io_values(), routes_now(S)
  assert_true(on_routes ~= no_routes(S), "routes are on: " .. on_routes)
  local path = h.data_root .. "io_system_everything_on.pset"
  params:write(path)

  -- a fresh load reads it back
  context, S = started_light()
  local defaults = io_values()
  assert_equal(routes_now(S), no_routes(S), "a fresh load routes nothing")
  params:read(path)
  for id, value in pairs(on_values) do assert_equal(params:get(id), value, id .. " read back") end
  assert_equal(routes_now(S), on_routes, "the same routes")
  assert_true(S.lib.io_tape.is_on(), "the tape runs again")

  -- the same PSET without any 3.6 param's line, as 3.5 wrote it
  local ids = io_id_set()
  local kept = {}
  for _, line in ipairs(file_lines(path)) do
    local id = line:match('^"(.-)":')
    if not (id and ids[id]) then kept[#kept + 1] = line end
  end
  assert_true(#kept < #file_lines(path), "the 3.6 lines left out")
  local old_path = h.data_root .. "io_system_3_5.pset"
  local file = assert(io.open(old_path, "w"))
  file:write(table.concat(kept, "\n") .. "\n")
  file:close()
  params:read(old_path)
  for id, value in pairs(defaults) do assert_equal(params:get(id), value, id .. " back to its default") end
  assert_equal(routes_now(S), no_routes(S), "a 3.5 PSET routes nothing")
  assert_true(not S.lib.io_tape.is_on(), "the tape is off")
end)

-- A param moved off where it stands by one detent of its kind: a binary
-- flipped, an option to the next, a number up one (down at its top), a
-- control 0.37 along its range. A text param is a keyed option's key,
-- which its option's move sets
local function move_off(param)
  local id = param.id
  if param.t == params.tBINARY then
    params:set(id, 1 - params:get(id))
  elseif param.t == params.tOPTION then
    params:set(id, params:get(id) % param.count + 1)
  elseif param.t == params.tNUMBER then
    local value = params:get(id)
    params:set(id, value < param.max and value + 1 or value - 1)
  elseif param.t == params.tCONTROL then
    params:set_raw(id, param.raw < 0.5 and param.raw + 0.37 or param.raw - 0.37)
  end
end

local SOURCES = {synth = 1, buffer = 2, input = 10}  -- v<i>_source: the synth, buffer slot 1, the input

test("no 3.6 param is a scene field, an LFO destination, a fader or a draw of a randomize, a mutation or a drift",
  function()
  -- the plan's Params constraint, for the five groups at once (two of their
  -- packages check their own: test/unit/io_jf_test.lua, io_nb_test.lua)
  local context, S = started_light()
  local NUM_VOICES = S.constants.NUM_VOICES
  local defaults = io_values()
  local list = io_params()
  for _, param in ipairs(list) do move_off(param) end
  -- MIDI out settles its routes as a whole and refuses two MPE voices on a
  -- port (docs/notes/lua/io/midi_out.md): each voice on a port of its own
  for voice = 1, NUM_VOICES do params:set("v" .. voice .. "_out_port", 7 + voice) end
  context.clock.advance_until(S.lfo_clock)
  local held = io_values()
  for id, value in pairs(held) do
    assert_true(value ~= defaults[id], id .. " moved off its default " .. tostring(defaults[id]))
  end
  local ids = io_id_set()

  -- not in a captured scene, at any depth
  capture_scene(1)
  local seen = {}
  local function walk(value, path)
    if type(value) ~= "table" or seen[value] then return end
    seen[value] = true
    for key, inner in pairs(value) do
      assert_true(not ids[key], "scene 1 holds " .. tostring(key) .. " at " .. path)
      assert_true(not (type(inner) == "string" and ids[inner]), "scene 1 names " .. tostring(inner) .. " at " .. path)
      walk(inner, path .. "." .. tostring(key))
    end
  end
  walk(S.scenes[1], "scene")
  -- not an LFO destination, each resolved
  for index, destination in ipairs(S.LFO_DESTINATIONS) do
    local id = destination.resolve()
    assert_true(not ids[id or ""], "LFO destination " .. index .. " is " .. tostring(id))
  end
  -- not on a fader page, the voice on its synth, a buffer slot and the input
  for name, source in pairs(SOURCES) do
    for voice = 1, NUM_VOICES do
      params:set("v" .. voice .. "_source", source)
      for _, id in ipairs(fader_param_ids(voice)) do
        assert_true(not ids[id], "voice " .. voice .. " (" .. name .. ") has the fader " .. id)
      end
    end
  end
  -- of them only the tape's four are macro targets
  local tape_four = {}
  for _, id in ipairs(S.lib.io_tape.TAPE.macro_targets) do tape_four[id] = true end
  local function only_tape_four(found, where)
    local count = 0
    for id in pairs(found) do
      assert_true(tape_four[id], id .. " is " .. where)
      count = count + 1
    end
    assert_equal(count, 4, "the tape's four are " .. where)
  end
  local catalog, registered = {}, {}
  for _, id in ipairs(S.lib.macros.target_ids()) do
    if ids[id] then catalog[id] = true end
  end
  for _, record in ipairs(S.registry.macro_targets) do
    if ids[record.id] then registered[record.id] = true end
  end
  only_tape_four(catalog, "a macro target")
  only_tape_four(registered, "a registered macro target")

  -- by effect, on every voice (running and unlocked) and each source kind:
  -- MAIN's randomize, a mutation at probability and amount 1 and a drift
  -- leave every one of them where it was set. Each effect's positive
  -- control (plan ruling 31) starts a param it draws mid-range and records that
  -- it differed at some step, never only at the end, and leans on no seed
  -- (the mutation walks pairs() over a voice's params)
  run_all_voices(S)
  for voice = 1, NUM_VOICES do
    assert_true(S.voices[voice].active and not S.frozen[voice], "voice " .. voice .. " runs, unlocked")
  end
  params:set("mutation_probability", 1)
  params:set("mutation_amount", 1)
  local function assert_held(where)
    for id, value in pairs(held) do assert_equal(params:get(id), value, id .. " after " .. where) end
  end
  local function moved_at_some_step(id_of, start, steps, effect)
    local moved = {}
    for voice = 1, NUM_VOICES do params:set(id_of(voice), start) end
    local starts = {}
    for voice = 1, NUM_VOICES do starts[voice] = params:get(id_of(voice)) end
    for _ = 1, steps do
      effect()
      for voice = 1, NUM_VOICES do
        if params:get(id_of(voice)) ~= starts[voice] then moved[voice] = true end
      end
    end
    return moved
  end
  local function pitch_id(voice) return "v" .. voice .. "_grain_pitch" end
  local function size_id(voice) return "v" .. voice .. "_grain_size" end
  for name, source in pairs(SOURCES) do
    for voice = 1, NUM_VOICES do params:set("v" .. voice .. "_source", source) end
    -- the randomize draws the grain pitch on every source, over 0.5 to 2.5
    -- (lib/mutation.lua's voice_spec): from 1.5, five randomizes of each
    -- voice by both of MAIN's doors
    local randomized = moved_at_some_step(pitch_id, 1.5, 5, function()
      for voice = 1, NUM_VOICES do
        randomize_voice(voice)
        S.lib.mutation.randomize(S.lib.mutation.voice_spec(voice))
      end
    end)
    for voice = 1, NUM_VOICES do
      assert_true(randomized[voice], "the randomize drew voice " .. voice .. "'s grain pitch (" .. name .. ")")
    end
    assert_held("MAIN's randomize of every voice (" .. name .. ")")
    -- the mutation draws the grain size on every source, a step of at most
    -- 0.2 at amount 1, about half the steps (io_jf_test.lua works out the
    -- odds): from 0.25, the middle of its 0.01 to 0.5, forty steps
    local mutated = moved_at_some_step(size_id, 0.25, 40, gentle_mutate)
    for voice = 1, NUM_VOICES do
      assert_true(mutated[voice], "the mutation moved voice " .. voice .. "'s grain size (" .. name .. ")")
    end
    assert_held("a mutation of every voice (" .. name .. ")")
    -- the drift walks every running voice's grain pitch: from 1, far from
    -- its 0.25 and 4 clamps, twenty ticks
    local drifted = moved_at_some_step(pitch_id, 1, 20, drift_update)
    for voice = 1, NUM_VOICES do
      assert_true(drifted[voice], "the drift moved voice " .. voice .. "'s grain pitch (" .. name .. ")")
    end
    assert_held("a drift of every voice (" .. name .. ")")
  end
end)

end

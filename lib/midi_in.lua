-- lib/midi_in.lua
-- MIDI input (3.5, design §5): every note on plays one note per target
-- voice through the allocator (S.lib.notes), in four channel modes (per
-- voice, omni to selected, and MPE's mpe selected and mpe split through
-- S.lib.mpe), with the note off modes latch and release, in every channel
-- mode. Velocity, the plain modes' pitchbend per voice, poly aftertouch
-- and channel pressure, and MPE's per-note bend, pressure and slide
-- (S.lib.expression). It listens, and hears of devices and claims,
-- through S.lib.io_ports (lib/io/ports.lua), never on a port another name
-- claims. The note tap the zones editor learns through and the scale
-- editor toggles its classes through (one owner at a time), and the key
-- and bend state (S.midi_device, S.midi_state). The functions stay global. The MIDI constants are a
-- field of this module's table (S.lib.midi_in.MIDI) for the MIDI params in
-- lib/params_setup.lua. Registers the cleanup step that detaches MIDI.
-- See docs/notes/lua/midi.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local musicutil = require "musicutil"

  -- MIDI input: notes, velocity and pitchbend per voice (CC is norns' own
  -- PARAMS > MAP): the MIDI constants, in one table.
  M.MIDI = {
    velocity_max = 127,       -- retrigger velocity = note velocity / 127
    rate_root_note = 60,      -- buffer- and input-sourced voices: this note plays at rate 1
    bend_center = 8192,       -- 14-bit pitchbend value at rest
    bend_semitones = 2,       -- full wheel throw either way
    channel_mode_options = {"per voice", "omni to selected", "mpe selected", "mpe split"},
    -- index 1 is latch (3.7's auto loads as it), index 2 release; 3.7's
    -- latch, index 3, clamps to release
    note_off_options = {"latch", "release"},
    owner = "midi",           -- the allocator's owner of every MIDI note
    channels = 16,
    notes_per_channel = 128,  -- a note's key: channel * 128 + note
    pressure_max = 127,       -- a pressure (poly or channel) / 127
  }
  local MIDI = M.MIDI
  S.midi_device = nil     -- the MIDI vport (S.lib.io_ports.out) Strata listens to
  S.midi_state = {
    bend = {},                -- per voice: current pitchbend ratio (transient; never a param or in scenes)
    held = {},                -- per voice: set of the keys down on it (channel * 128 + note)
    note_voice = {},          -- per channel: note -> the list of voices its note on played
    started = {},             -- voice -> true: a MIDI note started it (a panic CC stops these)
  }
  for i = 1, NUM_VOICES do
    S.midi_state.bend[i] = 1
    S.midi_state.held[i] = {}
  end

  -- The plain modes' pressures: per channel the last channel pressure (nil
  -- before the first), per key its last poly aftertouch (until its note off)
  local plain_pressure = {channel = {}, key = {}}
  -- The note tap (set_note_tap): nil, or a function every note on goes to
  -- first, and its owner's name (3.9, #900: nil exactly while the tap is)
  local note_tap = nil
  local note_tap_owner = nil
  local tap_errors = {}

  -- MIDI input. Notes, velocity and pitchbend address a voice by channel
  -- (per voice: channel n plays voice n), always the selected voice (omni),
  -- or the voices S.lib.mpe names (the MPE modes). CC is not handled here
  -- (but the panic and MPE's): norns' PARAMS > MAP maps CCs to any param.

  -- Listen to MIDI vport `port`. The handler lives on the vport only (as for
  -- grids and arc): norns fires both device.event and vports[port].event, so
  -- setting it on the device as well would play every note twice.
  -- S.lib.io_ports sets the vport's event (its listener "midi_in").
  -- The device last seen on the selected vport (nil: none, or it was
  -- unplugged). SYSTEM > DEVICES moves a device with update_devices() only,
  -- calling neither midi.add nor midi.remove, so a swap is visible only
  -- against this record (M.reconcile, and S.lib.io_ports' change at the
  -- menu's close). listening_port: the port midi_event listens on (nil:
  -- none, the selected one claimed). port_names: each port's device name
  -- as last heard, for the unplug's console line
  local attached_device = nil
  local listening_port = nil
  local port_names = {}

  -- A port number as a vport index: rounded and kept to norns' ports, so a
  -- fraction (a PSET written before the midi_device param stepped whole
  -- numbers, #534) still names a port
  local function vport_index(port)
    return util.clamp(util.round(port), 1, S.lib.io_ports.PORTS.count)
  end

  -- A port another name claims (a controller, a remote grid) is not
  -- listened to: its notes are never played. The listening changes only
  -- when the port or its claim does, so "midi_in" keeps its place among
  -- the port's listeners through a plug or a menu move elsewhere
  function attach_midi(port)
    port = vport_index(port)
    local wanted = S.lib.io_ports.owner(port) == nil and port or nil
    if wanted ~= listening_port then
      if listening_port then S.lib.io_ports.unlisten(listening_port, "midi_in") end
      if wanted then S.lib.io_ports.listen(wanted, "midi_in", midi_event) end
      listening_port = wanted
    end
    S.midi_device = S.lib.io_ports.out(port)
    attached_device = S.midi_device.device
  end

  function midi_init()
    attach_midi(params:get("midi_device"))
  end

  -- Hot-plug, through S.lib.io_ports.on_change: norns assigns the device to
  -- its vport before calling midi.add, and clears the vport only after
  -- midi.remove returns. They read the midi_device param, which init adds,
  -- so they are registered in the start step (below), never at include
  -- time (#469).
  local function midi_added(port, name)
    port_names[port] = name
    attach_midi(params:get("midi_device"))
    -- another controller may be on the port: its master bend range is its own (#688)
    if port == vport_index(params:get("midi_device")) then S.lib.mpe.reset_ranges() end
    request_redraw()  -- SETUP shows the device
    print("midi connected: " .. tostring(name))
  end

  local function midi_removed(port)
    if port == vport_index(params:get("midi_device")) then
      reset_midi_input()
      S.lib.mpe.reset_ranges()
      attached_device = nil
    end
    -- SETUP shows the port as empty: norns clears the vport as midi.remove
    -- returns, before the next frame draws
    request_redraw()
    print("midi disconnected: " .. tostring(port_names[port]))
    port_names[port] = nil
  end

  local function port_changed(port, name)
    if name ~= nil then midi_added(port, name) else midi_removed(port) end
  end

  -- A claim of the selected port releases every MIDI note, as a port change
  -- does, and stops the listening; its release listens again
  local function port_claimed(port, owner)
    if port ~= vport_index(params:get("midi_device")) then return end
    attach_midi(port)
    if owner ~= nil then
      reset_midi_input()
      S.lib.mpe.reset_ranges()
    end
  end

  -- Called as the norns menu closes: if the device on the selected vport is
  -- not the one attached (SYSTEM > DEVICES moved it), give up the notes the
  -- old one held, as an unplug does, and show the new state. A menu visit that
  -- moves nothing changes nothing.
  function M.reconcile()
    local current = S.midi_device and S.midi_device.device
    if current == attached_device then return end
    if attached_device ~= nil then reset_midi_input() end
    S.lib.mpe.reset_ranges()
    attached_device = current
    request_redraw()
  end

  S.register_menu_close(function() M.reconcile() end)

  -- The name of the device on the selected port, or "none"
  function midi_device_name()
    local device = S.midi_device and S.midi_device.device
    if device == nil then return "none" end
    return S.midi_device.name
  end

  -- What a note off does now: "release" or "latch", in every channel mode
  function M.note_off_mode()
    return MIDI.note_off_options[params:get("midi_note_off")]
  end

  -- The note tap (the zones editor's learn, the scale editor): while fn is
  -- set, every note on, in any mode, goes to fn(note) first and plays
  -- nothing when fn returns true. It has an owner (3.9, #900: a name): a
  -- set by another owner while one holds it is refused (false), the owner's
  -- own replaces its fn; only the owner clears it (clear_note_tap). fn may
  -- set or clear the tap while it runs: that takes effect from the next
  -- note. reset_midi_input and cleanup clear it and tell the owner, calling
  -- fn(nil) (tell_tap_owner)
  function M.set_note_tap(owner, fn)
    if type(owner) ~= "string" or owner == "" then error("midi_in.set_note_tap: owner is a non-empty string", 2) end
    if type(fn) ~= "function" then error("midi_in.set_note_tap: fn is a function", 2) end
    if note_tap_owner ~= nil and note_tap_owner ~= owner then return false end
    note_tap, note_tap_owner = fn, owner
    return true
  end

  -- Clear the tap if owner holds it (true); another owner's clear does nothing
  function M.clear_note_tap(owner)
    if owner == nil or owner ~= note_tap_owner then return false end
    note_tap, note_tap_owner = nil, nil
    return true
  end

  -- The tap's owner, or nil (no tap)
  function M.note_tap_owner()
    return note_tap_owner
  end

  -- Tell a cleared tap's owner (reset_midi_input and cleanup clear the tap
  -- whoever holds it, then call this with the tap they cleared): its
  -- fn(nil), once, contained (one that raises is reported once); the owner
  -- may set the tap again while it is told. Each caller clears note_tap
  -- itself, so the name stays an upvalue of the global reset_midi_input,
  -- which the tests read (local_value("note_tap"))
  local function tell_tap_owner(told)
    if told then S.lib.ui_frame.contained_call(tap_errors, 2, "midi note tap's owner told", told, nil) end
  end

  -- Release every MIDI note: the keys and the plain pressures forgotten,
  -- S.lib.mpe's channel values reset (the master channels' bend ranges stay, #688). A
  -- voice whose keys were down stops in release mode (the mode read after
  -- the change), and, with stop_all (a panic), so does every voice a MIDI
  -- note started: nothing can release them any more (#407, #529); its notes
  -- go with its stop (the allocator's voice-stop hook forgets them). Every
  -- other voice lets go of MIDI's notes without parking anything
  -- (S.lib.notes.forget_owner, ruling 40): MIDI's extra notes end, its own
  -- note sounds on as nobody's, and another owner's notes play on; an own
  -- note MIDI parked earlier returns when the voice's last note ends
  -- (ruling 39). Cheap with nothing held: the layout hook runs it several
  -- times in one PSET load
  local function release_held_notes(stop_all)
    local release_mode = M.note_off_mode() == "release"
    local to_stop = {}
    for i = 1, NUM_VOICES do
      local wanted = next(S.midi_state.held[i]) ~= nil and (release_mode or stop_all)
      -- a panic also stops a voice a released key started and left running
      if stop_all and S.midi_state.started[i] then wanted = true end
      if wanted and S.voices[i].active then
        to_stop[#to_stop + 1] = i
      else
        S.lib.notes.forget_owner(i, MIDI.owner)
      end
      S.midi_state.held[i] = {}
    end
    S.midi_state.note_voice = {}
    plain_pressure.channel, plain_pressure.key = {}, {}
    S.lib.mpe.reset()
    if stop_all then S.midi_state.started = {} end
    for _, i in ipairs(to_stop) do
      S.midi_state.started[i] = nil
      toggle_voice(i)
    end
  end

  -- Re-center every bent voice, release every MIDI note and clear the note
  -- tap, telling its owner (last, so it sees the notes released): called
  -- when the port or channel mode changes or the device goes away, since
  -- the bend returns and note offs will not arrive
  function reset_midi_input()
    for i = 1, NUM_VOICES do
      if S.midi_state.bend[i] ~= 1 then
        S.midi_state.bend[i] = 1
        if S.voices[i].active then engine.setVoiceParam(i - 1, "bend", 1) end
      end
    end
    release_held_notes(false)
    local told = note_tap
    note_tap, note_tap_owner = nil, nil
    tell_tap_owner(told)
  end

  -- All notes off (CC 123) and all sound off (CC 120): release every held
  -- note and stop every voice a MIDI note started and left running (held or
  -- not), in either note off mode (#529)
  M.PANIC_CCS = { [120] = true, [123] = true }

  -- The voice a MIDI channel addresses in the plain modes, or nil (and
  -- always nil in the MPE modes, where S.lib.mpe.targets routes)
  function midi_target_voice(channel)
    local mode = params:get("midi_channel_mode")
    if mode == S.lib.mpe.MPE.modes.selected or mode == S.lib.mpe.MPE.modes.split then return nil end
    if MIDI.channel_mode_options[mode] == "omni to selected" then return S.selected_voice end
    if channel and channel >= 1 and channel <= NUM_VOICES then return channel end
    return nil
  end

  -- The voices a note on plays: S.lib.mpe.targets in the MPE modes, else
  -- midi_target_voice's
  local function note_targets(channel, note)
    if S.lib.mpe.active() then return S.lib.mpe.targets(channel, note) end
    local voice_idx = midi_target_voice(channel)
    return voice_idx and {voice_idx} or {}
  end

  local function key_of(channel, note) return channel * MIDI.notes_per_channel + note end

  -- A note's controller values {bend, pressure, slide}: the channel's in
  -- the MPE modes (slide absolute); in the plain modes bend 1 (the voice's
  -- bend param bends every note), the key's poly aftertouch or the
  -- channel's pressure (nil before one arrived), no slide
  local function raw_values(channel, note)
    if S.lib.mpe.active() then return S.lib.mpe.values(channel) end
    return {bend = 1, pressure = plain_pressure.key[key_of(channel, note)] or plain_pressure.channel[channel]}
  end

  local function contains(list, value)
    for _, item in ipairs(list) do if item == value then return true end end
    return false
  end

  -- A key's lift on one voice its note on played: release ends the key's
  -- note (the own note parks under others), and the voice's last key stops
  -- the voice instead, whose stop ends its notes (no release or unpark
  -- before the voiceOff); latch keeps the note sounding at the highest
  -- pressure it reached. 3.7: a voice that takes slice notes releases
  -- through S.lib.slices.note_off, and its last key leaves it running while
  -- a one-shot slice plays to its end (a key never cuts one short)
  -- 3.7: per voice, a release-mode stop its last key's lift held back while
  -- a note of it played to its end (end_key). Only that sets it; a key down,
  -- the voice's stop and its start clear it, so a restarted voice is never
  -- stopped by it. The LFO step below does the stop once no note of the
  -- voice plays to its end, whichever owner's ended last
  local stop_pending = {}

  local function end_key(voice_idx, key)
    S.midi_state.held[voice_idx][key] = nil
    local last = next(S.midi_state.held[voice_idx]) == nil and S.voices[voice_idx].active
    if M.note_off_mode() ~= "release" then
      S.lib.expression.latch(voice_idx, MIDI.owner, key)
    elseif last and not S.lib.notes.plays_to_end(voice_idx) then
      midi_note_off_for(voice_idx)
    else
      -- the last key, held back by a note playing to its end: stop later
      if last then stop_pending[voice_idx] = true end
      if S.lib.slices.takes_notes(voice_idx) then
        S.lib.slices.note_off(voice_idx, MIDI.owner, key)
      else
        S.lib.notes.release(voice_idx, MIDI.owner, key)
      end
    end
  end

  -- 3.7 (design §3.5): the slice a note plays on a voice that takes slice
  -- notes (S.lib.slices.takes_notes: note first_note + n - 1 is slice n), or
  -- nil on any other voice
  local function slice_number(voice_idx, note)
    if not S.lib.slices.takes_notes(voice_idx) then return nil end
    return note - S.lib.slices.SLICES.first_note + 1
  end

  -- 3.7: the note hooks' heard (S.registry.note_hooks, read at each note),
  -- each contained, for every MIDI note a voice receives, before the slice
  -- filter: (voice, note number, velocity 0-1). It starts nothing and never
  -- reaches the targets (the slice editor's key row hears every note)
  local heard_errors = {}
  local function hear(voice_idx, note, velocity)
    for _, hook in ipairs(S.registry.note_hooks) do
      if hook.heard then
        S.lib.ui_frame.contained_call(heard_errors, hook.name, "note hook " .. hook.name .. " heard", hook.heard,
          voice_idx, note, velocity / MIDI.velocity_max)
      end
    end
  end

  -- 3.7: a held-back release-mode stop (stop_pending) is done at the first
  -- LFO step where no note of the voice plays to its end any more, while it
  -- still runs in release mode with no key down; anything else drops it.
  -- The voice's stop and start drop it too, so a voice restarted within a
  -- step of its last key's stop is never stopped again
  S.lib.lfos.on_step(function()
    if next(stop_pending) == nil then return end
    for voice_idx in pairs(stop_pending) do
      if not (S.voices[voice_idx].active and M.note_off_mode() == "release"
          and next(S.midi_state.held[voice_idx]) == nil) then
        stop_pending[voice_idx] = nil
      elseif not S.lib.notes.plays_to_end(voice_idx) then
        stop_pending[voice_idx] = nil
        midi_note_off_for(voice_idx)
      end
    end
  end)
  S.register_voice_stop(function(voice_idx) stop_pending[voice_idx] = nil end)
  S.register_grain_restart(function(voice_idx, reason)
    if reason == "start" then stop_pending[voice_idx] = nil end
  end)

  -- Whether a note is no slice of a voice that takes slice notes: it does
  -- nothing there (no key held, nothing released)
  local function ignored(voice_idx, note)
    local n = slice_number(voice_idx, note)
    return n ~= nil and S.lib.slices.voice_region(voice_idx, n) == nil
  end

  -- The note tap, read once: true when it took the note. It may set another
  -- tap or none while it runs; one that raises is reported once and takes nothing
  local function tapped(note)
    local tap = note_tap
    if tap == nil then return false end
    local taken = false
    S.lib.ui_frame.contained_call(tap_errors, 1, "midi note tap", function() taken = tap(note) == true end)
    return taken
  end

  local function valid_note(channel, note)
    return type(channel) == "number" and channel % 1 == 0 and channel >= 1 and channel <= MIDI.channels
      and type(note) == "number" and note % 1 == 0 and note >= 0 and note < MIDI.notes_per_channel
  end

  -- A note on: every voice it plays (a repeated note on first lifts the key
  -- on the voices its earlier note on played that this one does not); on a
  -- voice with no key down the voice's MIDI notes go first (latch: the next
  -- chord replaces the last), then the key is down and the note plays
  local function note_on(channel, note, velocity)
    if not valid_note(channel, note) or tapped(note) then return end
    local key = key_of(channel, note)
    local targets = {}
    for _, voice_idx in ipairs(note_targets(channel, note)) do
      hear(voice_idx, note, velocity)
      if not ignored(voice_idx, note) then targets[#targets + 1] = voice_idx end
    end
    local channel_notes = S.midi_state.note_voice[channel] or {}
    for _, voice_idx in ipairs(channel_notes[note] or {}) do
      if not contains(targets, voice_idx) then end_key(voice_idx, key) end
    end
    channel_notes[note] = #targets > 0 and targets or nil
    S.midi_state.note_voice[channel] = next(channel_notes) ~= nil and channel_notes or nil
    local raw = raw_values(channel, note)
    for _, voice_idx in ipairs(targets) do
      if next(S.midi_state.held[voice_idx]) == nil then S.lib.notes.release_owner(voice_idx, MIDI.owner) end
      S.midi_state.held[voice_idx][key] = true
      stop_pending[voice_idx] = nil  -- a key down: its own lift decides again
      midi_note_on(voice_idx, note, velocity, channel, raw)
    end
  end

  -- A note off goes to the voices its note on played (in omni mode the
  -- selection may have moved since); a note no note on played changes nothing
  local function note_off(channel, note)
    if not valid_note(channel, note) then return end
    local key = key_of(channel, note)
    plain_pressure.key[key] = nil
    local channel_notes = S.midi_state.note_voice[channel]
    local voices = channel_notes and channel_notes[note]
    if not voices then return end
    channel_notes[note] = nil
    if next(channel_notes) == nil then S.midi_state.note_voice[channel] = nil end
    for _, voice_idx in ipairs(voices) do end_key(voice_idx, key) end
  end

  -- New controller values for every note a channel's keys hold
  local function express_channel(channel, raw_of)
    local channel_notes = S.midi_state.note_voice[channel]
    if not channel_notes then return end
    for note, voices in pairs(channel_notes) do
      local raw = raw_of(note)
      for _, voice_idx in ipairs(voices) do S.lib.expression.update(voice_idx, MIDI.owner, key_of(channel, note), raw) end
    end
  end

  -- The plain modes: poly aftertouch is its note's pressure, channel
  -- pressure every note the channel holds
  local function plain_pressure_message(msg)
    if not valid_note(msg.ch, msg.note or 0) then return end
    local pressure = util.clamp(msg.val / MIDI.pressure_max, 0, 1)
    if msg.type == "channel_pressure" then
      plain_pressure.channel[msg.ch] = pressure
      express_channel(msg.ch, function() return {pressure = pressure} end)
      return
    end
    local key = key_of(msg.ch, msg.note)
    plain_pressure.key[key] = pressure
    local channel_notes = S.midi_state.note_voice[msg.ch]
    for _, voice_idx in ipairs(channel_notes and channel_notes[msg.note] or {}) do
      S.lib.expression.update(voice_idx, MIDI.owner, key, {pressure = pressure})
    end
  end

  -- 3.6: a program change recalls a scene only with midi_pc_in on (MIDI
  -- out's param, lib/io/midi_out.lua), for program 0 to NUM_SCENES - 1, on
  -- midi_pc_channel's channel (its first option: any)
  local function program_change_wanted(msg)
    if not (S.lib.io_midi_out and params.lookup.midi_pc_in) or params:get("midi_pc_in") ~= 1 then return false end
    local value = msg.val
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value >= S.constants.NUM_SCENES then return false end
    local wanted = params:get("midi_pc_channel")
    return wanted == 1 or msg.ch == wanted - 1
  end

  function midi_event(data)
    local msg = midi.to_msg(data)
    if msg.type == "note_on" and msg.vel > 0 then
      note_on(msg.ch, msg.note, msg.vel)
    elseif msg.type == "note_on" or msg.type == "note_off" then
      note_off(msg.ch, msg.note)
    elseif msg.type == "cc" and M.PANIC_CCS[msg.cc] then
      release_held_notes(true)
    elseif msg.type == "program_change" and program_change_wanted(msg) then
      -- 3.6: a scene recall, in every channel mode (MIDI out notes the port)
      S.lib.io_midi_out.program_change_in(listening_port, msg.val)
    elseif S.lib.mpe.active() then
      -- MPE's bend, pressure, slide and RPNs: each changed channel's notes
      -- take its values
      for _, channel in ipairs(S.lib.mpe.control(msg) or {}) do
        local raw = S.lib.mpe.values(channel)
        express_channel(channel, function() return raw end)
      end
    elseif msg.type == "pitchbend" then
      local voice_idx = midi_target_voice(msg.ch)
      if voice_idx then midi_pitchbend(voice_idx, msg.val) end
    elseif msg.type == "key_pressure" or msg.type == "channel_pressure" then
      plain_pressure_message(msg)
    end
  end

  -- Per voice, how a note pitches the voice's own note (the allocator's
  -- set_own): a synth voice's freq, a buffer voice's rate, an input voice's
  -- grain pitch (rate 1 at S.lib.samples.rate_root: a buffer voice's file's
  -- key, else 60), each clamped to its param's range
  local own_setters = {}
  for i = 1, NUM_VOICES do
    local prefix = "v" .. i .. "_"
    own_setters[i] = function(pitch)
      local id, value = prefix .. "grain_pitch", 2 ^ ((pitch - S.lib.samples.rate_root(i)) / 12)
      if voice_uses_synth(i) then
        id, value = prefix .. "freq", musicutil.note_num_to_freq(pitch)
      elseif voice_uses_buffer(i) then
        id = prefix .. "buf_rate"
      end
      local low, high = param_range(id)
      params:set(id, util.clamp(value, low, high))
    end
  end

  -- One MIDI note on one voice, through the allocator (S.lib.notes.play;
  -- key channel * 128 + note, channel 1 when not given): the key's pitch in
  -- the tuning, snapped to the scale for a quantized voice
  -- (S.lib.variation.midi_note, 3.8), with velocity / 127, parking under other
  -- notes, its first expression from raw = {bend, pressure, slide} (the
  -- note's slide is measured from here). The allocator starts a stopped
  -- voice and accents the own note; a gated voice gets its own gate length
  -- first, never a step's (#639). Voices keep their attacks; the velocity
  -- lands on the accent
  function midi_note_on(voice_idx, note, velocity, channel, raw)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    raw = raw or {bend = 1}
    local key = key_of(channel or 1, note)
    -- a new touch: what the expression module kept of a latched key's goes (ruling 30)
    S.lib.expression.forget(voice_idx, MIDI.owner, key)
    -- the note's first values, for the targets its start reaches (3.6: before play's started hooks)
    S.lib.expression.first_touch(voice_idx, MIDI.owner, key, raw)
    S.lib.sequencer.note_gate(voice_idx)
    local was_stopped = not S.voices[voice_idx].active
    local expression = S.lib.expression.note_values(voice_idx, {bend = raw.bend, pressure = raw.pressure, slide = 0})
    local slot
    local n = slice_number(voice_idx, note)
    if n then
      -- 3.7: slice n at the voice's own pitch (a note outside the slices plays nothing)
      slot = S.lib.slices.play(voice_idx, n, {owner = MIDI.owner, key = key, velocity = velocity / MIDI.velocity_max,
        park = true, expression = expression})
    else
      slot = S.lib.notes.play(voice_idx, {owner = MIDI.owner, key = key,
        pitch = S.lib.variation.midi_note(voice_idx, note), velocity = velocity / MIDI.velocity_max, park = true,
        set_own = own_setters[voice_idx], expression = expression})
    end
    if was_stopped and S.voices[voice_idx].active then S.midi_state.started[voice_idx] = true end
    -- the own note, perhaps taken from a step's: its note override ends now
    if slot == 1 then S.lib.sequencer.own_note_taken(voice_idx) end
    if slot then
      S.lib.expression.update(voice_idx, MIDI.owner, key, {bend = raw.bend, pressure = raw.pressure, slide = raw.slide})
    else
      S.lib.expression.forget(voice_idx, MIDI.owner, key)  -- no note: nothing left pending
    end
  end

  -- Ruling 55 (refining ruling 35): whether MIDI keeps voice_idx's own note
  -- from a sequencer step, which only a key physically down does. MIDI's
  -- own note whose key is up (latched) gives way, as in 3.4: MIDI forgets it
  -- (S.lib.notes.forget, a reset's way for that note alone: nothing sent,
  -- the own note sounds on as nobody's, for the step to re-pitch and
  -- accent), with what the expression module kept of its touch, and false
  -- is returned. false too when MIDI holds no own note there. Its latched
  -- extra notes stay MIDI's
  function M.keeps_own(voice_idx)
    if type(voice_idx) ~= "number" or voice_idx < 1 or voice_idx > NUM_VOICES or voice_idx % 1 ~= 0 then return false end
    local own = S.lib.notes.slots(voice_idx)[1]
    if not (own and own.slot == 1 and own.held and own.owner == MIDI.owner) then return false end
    if S.midi_state.held[voice_idx][own.key] then return true end
    S.lib.notes.forget(voice_idx, MIDI.owner, own.key)
    S.lib.expression.forget(voice_idx, MIDI.owner, own.key)
    return false
  end

  -- In release mode a voice stops when no key is down on it any more,
  -- whoever started it. A note during its release starts it again (the
  -- engine re-gates the releasing synths).
  function midi_note_off_for(voice_idx)
    if M.note_off_mode() ~= "release" or not S.voices[voice_idx].active then return end
    if next(S.midi_state.held[voice_idx]) ~= nil then return end
    S.midi_state.started[voice_idx] = nil
    toggle_voice(voice_idx)
  end

  -- Pitchbend over +/-2 semitones as a frequency (or buffer rate) ratio. The
  -- engine applies it to the voice synth and to strataGrainBuf; a stopped
  -- voice gets it when it starts, with the voice-level values that follow
  -- voiceOn (S.lib.engine_sync.start_voice). Nothing on the screen or arc
  -- shows the bend, so it asks for no redraw.
  function midi_pitchbend(voice_idx, value)
    midi_set_bend(voice_idx, 2 ^ (((value - M.MIDI.bend_center) / M.MIDI.bend_center) * M.MIDI.bend_semitones / 12))
  end

  function midi_set_bend(voice_idx, ratio)
    S.midi_state.bend[voice_idx] = ratio
    if S.voices[voice_idx].active then engine.setVoiceParam(voice_idx - 1, "bend", ratio) end
  end

  -- Omni mode bends whichever voice is selected. When the selection moves with
  -- the wheel off center, the voice it leaves returns to pitch and the newly
  -- selected voice takes the wheel's current bend (a stopped voice gets it
  -- when it starts). Per voice mode leaves bends with their channels' voices.
  function midi_bend_follow_selection(previous_voice)
    if MIDI.channel_mode_options[params:get("midi_channel_mode")] ~= "omni to selected" then return end
    local ratio = S.midi_state.bend[previous_voice]
    if ratio == 1 then return end
    midi_set_bend(previous_voice, 1)
    midi_set_bend(S.selected_voice, ratio)
  end

  -- Listen for MIDI from init on
  S.register_start(S.constants.START_ORDER.midi, function()
    -- every start (the hook's reason "start") clears the flag; midi_note_on
    -- sets it after its own start. A running voice's source change runs the
    -- hook too (reason "source") and leaves the flag.
    S.register_grain_restart(function(voice_idx, reason)
      if reason == "start" then S.midi_state.started[voice_idx] = nil end
    end)
    for port = 1, S.lib.io_ports.PORTS.count do port_names[port] = S.lib.io_ports.device(port) end
    S.lib.io_ports.on_change("midi_in", port_changed)
    S.lib.io_ports.on_claim("midi_in", port_claimed)
    midi_init()
    -- a member count or zone change (the menu, RPN 6, a PSET load, the
    -- zones editor) in the MPE modes releases every MIDI note: their note
    -- offs may name a layout that no longer routes them (ruling 14). The
    -- plain modes route nothing through the zones, so there it does
    -- nothing. The tap stays (the zones editor's learn sets a range while
    -- it is set)
    S.lib.mpe.on_layout_change(function()
      if S.lib.mpe.active() then release_held_notes(false) end
    end)
  end)

  -- Stop listening to MIDI before the voices go off and clear the note tap,
  -- telling its owner (the editors' own steps, earlier, have cleared theirs;
  -- S.lib.io_ports' own step, after this one, hands hot-plug back; SLEEP
  -- runs only cleanup(), #468)
  S.register_cleanup(S.constants.CLEANUP_ORDER.midi_handler, function()
    if listening_port then S.lib.io_ports.unlisten(listening_port, "midi_in") end
    listening_port = nil
    local told = note_tap
    note_tap, note_tap_owner = nil, nil
    tell_tap_owner(told)
  end)

  -- A key is down on a voice exactly while some channel's note on lists the
  -- voice for that note: held[voice][channel * 128 + note] is set exactly
  -- when note_voice[channel][note] holds the voice; each list holds valid
  -- voices, once each, and is never empty. 3.9 (#913): a held-back stop
  -- (stop_pending) marks only a running voice with no key down on it
  S.register_invariant("midi notes", function()
    for voice_idx, flag in pairs(stop_pending) do
      if flag ~= true or not S.voices[voice_idx] then
        return "the held-back stop has a bad entry for " .. tostring(voice_idx)
      end
      if not S.voices[voice_idx].active then return "the held-back stop marks stopped voice " .. voice_idx end
      if next(S.midi_state.held[voice_idx]) ~= nil then
        return "the held-back stop marks voice " .. voice_idx .. ", which a key is down on"
      end
    end
    for voice_idx, flag in pairs(S.midi_state.started) do
      if flag ~= true or type(voice_idx) ~= "number" or voice_idx < 1 or voice_idx > NUM_VOICES then
        return "started has a bad entry for " .. tostring(voice_idx)
      end
    end
    local owned = {}
    for voice_idx = 1, NUM_VOICES do owned[voice_idx] = {} end
    for channel, channel_notes in pairs(S.midi_state.note_voice) do
      for note, voices in pairs(channel_notes) do
        if not valid_note(channel, note) or type(voices) ~= "table" or #voices == 0 then
          return "channel " .. tostring(channel) .. " note " .. tostring(note) .. " has no list of voices"
        end
        for _, voice_idx in ipairs(voices) do
          local key = key_of(channel, note)
          if not owned[voice_idx] then return "channel " .. channel .. " note " .. note .. " lists a bad voice" end
          if owned[voice_idx][key] then return "channel " .. channel .. " note " .. note .. " lists a voice twice" end
          owned[voice_idx][key] = true
        end
      end
    end
    for voice_idx = 1, NUM_VOICES do
      for key in pairs(S.midi_state.held[voice_idx]) do
        if not owned[voice_idx][key] then
          return "key " .. key .. " is down on voice " .. voice_idx .. " but no channel lists it there"
        end
      end
      for key in pairs(owned[voice_idx]) do
        if not S.midi_state.held[voice_idx][key] then
          return "key " .. key .. " lists voice " .. voice_idx .. " but is not down on it"
        end
      end
    end
  end)

  return M
end

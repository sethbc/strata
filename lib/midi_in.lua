-- lib/midi_in.lua
-- MIDI input (3.5, design §5): every note on plays one note per target
-- voice through the allocator (S.lib.notes), in four channel modes (per
-- voice, omni to selected, and MPE's mpe selected and mpe split through
-- S.lib.mpe), with the note off modes latch and release (auto: latch in
-- the plain modes, release in the MPE modes). Velocity, the plain modes'
-- pitchbend per voice, poly aftertouch and channel pressure, and MPE's
-- per-note bend, pressure and slide (S.lib.expression). The vport hot-plug
-- handlers, the note tap the zones editor learns through, and the key and
-- bend state (S.midi_device, S.midi_state). The functions stay global. The
-- MIDI constants are a field of this module's table (S.lib.midi_in.MIDI)
-- for the MIDI params in lib/params_setup.lua. Registers the cleanup step
-- that detaches MIDI. See docs/notes/lua/midi.md.

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
    -- index 1 was 3.4's ignore (auto: latch in the plain modes), index 2
    -- its voice off (release): no PSET changes meaning
    note_off_options = {"auto", "release", "latch"},
    owner = "midi",           -- the allocator's owner of every MIDI note
    channels = 16,
    notes_per_channel = 128,  -- a note's key: channel * 128 + note
    pressure_max = 127,       -- a pressure (poly or channel) / 127
  }
  local MIDI = M.MIDI
  S.midi_device = nil     -- the MIDI vport (midi.connect) Strata listens to
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
  -- The note tap (set_note_tap): nil, or a function every note on goes to first
  local note_tap = nil
  local tap_errors = {}

  -- MIDI input. Notes, velocity and pitchbend address a voice by channel
  -- (per voice: channel n plays voice n), always the selected voice (omni),
  -- or the voices S.lib.mpe names (the MPE modes). CC is not handled here
  -- (but the panic and MPE's): norns' PARAMS > MAP maps CCs to any param.

  -- Listen to MIDI vport `port`. The handler lives on the vport only (as for
  -- grids and arc): norns fires both device.event and vports[port].event, so
  -- setting it on the device as well would play every note twice.
  -- The device last seen on the selected vport (nil: none, or it was
  -- unplugged). SYSTEM > DEVICES moves a device with update_devices() only,
  -- calling neither midi.add nor midi.remove, so a swap is visible only
  -- against this record (M.reconcile).
  local attached_device = nil

  -- A port number as a vport index: rounded and kept to norns' ports, so a
  -- fraction (a PSET written before the midi_device param stepped whole
  -- numbers, #534) still names a port
  local function vport_index(port)
    return util.clamp(util.round(port), 1, #midi.vports)
  end

  function attach_midi(port)
    port = vport_index(port)
    if S.midi_device then S.midi_device.event = nil end
    S.midi_device = midi.connect(port)
    S.midi_device.event = midi_event
    attached_device = S.midi_device.device
  end

  function midi_init()
    attach_midi(params:get("midi_device"))
  end

  -- Hot-plug. norns assigns the device to its vport before calling midi.add,
  -- and clears the vport only after midi.remove returns.
  -- They read the midi_device param, which init adds, so they are assigned in
  -- the start step (below), never at include time (#469).
  local function midi_added(device)
    attach_midi(params:get("midi_device"))
    request_redraw()  -- SETUP shows the device
    print("midi connected: " .. tostring(device.name))
  end

  local function midi_removed(device)
    if device.port == vport_index(params:get("midi_device")) then
      reset_midi_input()
      attached_device = nil
    end
    -- SETUP shows the port as empty: norns clears the vport as midi.remove
    -- returns, before the next frame draws
    request_redraw()
    print("midi disconnected: " .. tostring(device.name))
  end

  -- Called as the norns menu closes: if the device on the selected vport is
  -- not the one attached (SYSTEM > DEVICES moved it), give up the notes the
  -- old one held, as an unplug does, and show the new state. A menu visit that
  -- moves nothing changes nothing.
  function M.reconcile()
    local current = S.midi_device and S.midi_device.device
    if current == attached_device then return end
    if attached_device ~= nil then reset_midi_input() end
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

  -- What a note off does now: "release" or "latch" (auto: release in the
  -- MPE modes, latch in the plain ones)
  function M.note_off_mode()
    local option = MIDI.note_off_options[params:get("midi_note_off")]
    if option == "auto" then return S.lib.mpe.active() and "release" or "latch" end
    return option
  end

  -- The note tap (the zones editor's learn): while fn is set, every note on,
  -- in any mode, goes to fn(note) first and plays nothing when fn returns
  -- true. fn may set another tap, or none, while it runs: that takes effect
  -- from the next note. reset_midi_input and cleanup clear it
  function M.set_note_tap(fn)
    if fn ~= nil and type(fn) ~= "function" then error("midi_in.set_note_tap: fn is a function or nil", 2) end
    note_tap = fn
  end

  -- Release every MIDI note: each voice's MIDI notes (release_owner), the
  -- keys and the plain pressures forgotten, S.lib.mpe's state reset. A
  -- voice whose keys were down stops in release mode, and, with stop_all
  -- (a panic), so does every voice a MIDI note started: nothing can release
  -- them any more (#407, #529). Such a voice's notes go with its stop (the
  -- allocator's voice-stop hook forgets them). Cheap with nothing held: the
  -- layout hook runs it several times in one PSET load
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
        S.lib.notes.release_owner(i, MIDI.owner)
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

  -- Re-center every bent voice, clear the note tap and release every MIDI
  -- note: called when the port or channel mode changes or the device goes
  -- away, since the bend returns and note offs will not arrive
  function reset_midi_input()
    for i = 1, NUM_VOICES do
      if S.midi_state.bend[i] ~= 1 then
        S.midi_state.bend[i] = 1
        if S.voices[i].active then engine.setVoiceParam(i - 1, "bend", 1) end
      end
    end
    note_tap = nil
    release_held_notes(false)
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
  -- note (the own note parks under others) and stops a voice left with no
  -- key; latch keeps the note sounding at the highest pressure it reached
  local function end_key(voice_idx, key)
    S.midi_state.held[voice_idx][key] = nil
    if M.note_off_mode() == "release" then
      S.lib.notes.release(voice_idx, MIDI.owner, key)
      midi_note_off_for(voice_idx)
    else
      S.lib.expression.latch(voice_idx, MIDI.owner, key)
    end
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
    local targets = note_targets(channel, note)
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

  function midi_event(data)
    local msg = midi.to_msg(data)
    if msg.type == "note_on" and msg.vel > 0 then
      note_on(msg.ch, msg.note, msg.vel)
    elseif msg.type == "note_on" or msg.type == "note_off" then
      note_off(msg.ch, msg.note)
    elseif msg.type == "cc" and M.PANIC_CCS[msg.cc] then
      release_held_notes(true)
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
  -- grain pitch (note 60 at 1), each clamped to its param's range
  local own_setters = {}
  for i = 1, NUM_VOICES do
    local prefix = "v" .. i .. "_"
    own_setters[i] = function(pitch)
      local id, value = prefix .. "grain_pitch", 2 ^ ((pitch - MIDI.rate_root_note) / 12)
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
  -- key channel * 128 + note, channel 1 when not given): snapped to the
  -- scale for a quantized voice, with velocity / 127, parking under other
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
    S.lib.sequencer.note_gate(voice_idx)
    local was_stopped = not S.voices[voice_idx].active
    local slot = S.lib.notes.play(voice_idx, {owner = MIDI.owner, key = key,
      pitch = S.lib.variation.midi_note(voice_idx, note), velocity = velocity / MIDI.velocity_max, park = true,
      set_own = own_setters[voice_idx],
      expression = S.lib.expression.note_values(voice_idx, {bend = raw.bend, pressure = raw.pressure, slide = 0})})
    if was_stopped and S.voices[voice_idx].active then S.midi_state.started[voice_idx] = true end
    if slot then
      S.lib.expression.update(voice_idx, MIDI.owner, key, {bend = raw.bend, pressure = raw.pressure, slide = raw.slide})
    end
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

  -- 3.3's own LFO param ids, which 3.4 has not: every param norns' LFO
  -- library added for each of 3.3's three LFOs (lfo_<n> its state, then
  -- lfo_<field>_<n>; lua/lib/lfo.lua's add_params, as v3.3.2 called it,
  -- with no separator) and the destinations' group, strata_lfos. moves: the
  -- fields whose 3.4 param (strata_lfo<n>_<field>) has the same meaning, as
  -- lib/lfos.lua's 3.3 import keeps their values: depth, offset and phase
  -- (3.3's numbers, 3.4's controls) and the clocked rate (the same
  -- divisions). Every other one changed meaning (the shapes and modes
  -- reordered, the free period now a rate, the state a toggle) or has no
  -- 3.4 param
  M.MIDI.lfo_maps_3_3 = {lfos = 3, group = "strata_lfos",
    fields = {"group", "shape", "depth", "phase", "offset", "scaled", "raw", "min", "max", "baseline", "mode",
      "clocked", "free", "reset", "reset_target"},
    moves = {depth = "depth", offset = "offset", phase = "phase", clocked = "division"}}

  -- Each of 3.3's own LFO ids: the 3.4 param its map moves to, or false
  local function lfo_ids_3_3()
    local maps = M.MIDI.lfo_maps_3_3
    local ids = {[maps.group] = false}
    for n = 1, maps.lfos do
      ids["lfo_" .. n] = false
      for _, field in ipairs(maps.fields) do
        local target = maps.moves[field]
        ids["lfo_" .. field .. "_" .. n] = target and S.lib.lfos.param_id(n, target) or false
      end
    end
    return ids
  end

  -- norns' MIDI map (norns.pmap: data[param id] and the reverse
  -- rev[dev][ch][cc]) is read from strata.pmap before init. A map on an id
  -- that is no param makes norns' CC handler (lua/core/menu/params.lua's
  -- menu_midi_event) raise "invalid paramset index" on every CC it maps,
  -- and the MAP menu, which lists params, cannot show it (#602). Run at
  -- start, once Strata's params exist; it touches only 3.3's own LFO ids
  -- that are no param (lfo_ids_3_3): one moves to its 3.4 param (a
  -- number's output range becomes the control's raw range) unless that
  -- param has a map of its own; every other one is removed, with one console
  -- line each. A map on any other id is left exactly as it is, silently: a
  -- mod may add its param after init (norns' hook.script_post_init), or a
  -- later version may have it. Only when something moved or went is the
  -- map written back, as norns' MAP menu writes it, every entry
  -- (norns.pmap.write), so the next start reads it repaired
  function M.repair_midi_map()
    local pmap = norns and norns.pmap
    if type(pmap) ~= "table" or type(pmap.data) ~= "table" or type(pmap.rev) ~= "table" then return end
    local known = lfo_ids_3_3()
    local stale = {}
    for id in pairs(pmap.data) do
      if known[id] ~= nil and params.lookup[id] == nil then stale[#stale + 1] = id end
    end
    table.sort(stale)
    for _, id in ipairs(stale) do
      local entry = pmap.data[id]
      local slot = type(entry) == "table" and pmap.rev[entry.dev] and pmap.rev[entry.dev][entry.ch]
      local own = slot and slot[entry.cc] == id
      if own then slot[entry.cc] = nil end
      pmap.data[id] = nil
      local target = known[id]
      if own and target and params.lookup[target] and pmap.data[target] == nil then
        local spec = params:lookup_param(target).controlspec
        if spec then entry.out_lo, entry.out_hi = spec:unmap(entry.out_lo), spec:unmap(entry.out_hi) end
        pmap.data[target] = entry
        slot[entry.cc] = target
        print("midi map: " .. id .. " (a 3.3 LFO param) moved to " .. target)
      else
        -- why it goes: no 3.4 param of its meaning, its 3.4 param mapped
        -- already (naming that map's CC), or its CC taken by another map
        local why = "3.4 has no param of its meaning"
        local kept = target and params.lookup[target] and pmap.data[target]
        if type(kept) == "table" then
          why = string.format("its 3.4 param %s is already mapped (CC %s, channel %s, device %s)", target,
            tostring(kept.cc), tostring(kept.ch), tostring(kept.dev))
        elseif target and params.lookup[target] and slot then
          why = string.format("its CC %s (channel %s, device %s) maps %s", tostring(entry.cc), tostring(entry.ch),
            tostring(entry.dev), tostring(slot[entry.cc]))
        elseif target and params.lookup[target] then
          why = "its map names no device and channel"
        end
        print("midi map: " .. id .. " (a 3.3 LFO param) removed: " .. why)
      end
    end
    if #stale > 0 and type(pmap.write) == "function" then pmap.write() end
  end

  -- Listen for MIDI from init on
  S.register_start(S.constants.START_ORDER.midi, function()
    -- every start (the voice is not yet active when the hook runs) clears the
    -- flag; midi_note_on sets it after its own start. A running voice's source
    -- change runs the hook too and leaves the flag.
    S.register_grain_restart(function(voice_idx)
      if not S.voices[voice_idx].active then S.midi_state.started[voice_idx] = nil end
    end)
    midi.add = midi_added
    midi.remove = midi_removed
    midi_init()
    M.repair_midi_map()
    -- a member count or zone change (the menu, RPN 6, a PSET load, the
    -- zones editor) releases every MIDI note: their note offs may name a
    -- layout that no longer routes them (ruling 14). The tap stays (the
    -- zones editor's learn sets a range while it is set)
    S.lib.mpe.on_layout_change(function() release_held_notes(false) end)
  end)

  -- Stop listening to MIDI before the voices go off, clear the note tap, and
  -- hand hot-plug back (no-ops, as norns' midi.cleanup() leaves them at a
  -- script change; SLEEP runs only cleanup(), #468)
  S.register_cleanup(S.constants.CLEANUP_ORDER.midi_handler, function()
    if S.midi_device then S.midi_device.event = nil end
    note_tap = nil
    midi.add = function() end
    midi.remove = function() end
  end)

  -- A key is down on a voice exactly while some channel's note on lists the
  -- voice for that note: held[voice][channel * 128 + note] is set exactly
  -- when note_voice[channel][note] holds the voice; each list holds valid
  -- voices, once each, and is never empty
  S.register_invariant("midi notes", function()
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

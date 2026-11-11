-- lib/midi_in.lua
-- MIDI input: notes, velocity and pitchbend per voice, the vport hot-plug
-- handlers and the held-note and bend state (S.midi_device, S.midi_state).
-- The functions stay global. The MIDI constants are a field of this
-- module's table (S.lib.midi_in.MIDI) for the MIDI params in
-- lib/params_setup.lua. Registers the cleanup step that detaches MIDI.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local musicutil = require "musicutil"

  -- MIDI input: notes, velocity and pitchbend per voice (CC is norns' own
  -- PARAMS > MAP): the MIDI constants, in one table.
  M.MIDI = {
    velocity_max = 127,       -- retrigger velocity = note velocity / 127
    rate_root_note = 60,      -- buffer-sourced voices: this note plays at rate 1
    bend_center = 8192,       -- 14-bit pitchbend value at rest
    bend_semitones = 2,       -- full wheel throw either way
    channel_mode_options = {"per voice", "omni to selected"},
    note_off_options = {"ignore", "voice off"},
  }
  S.midi_device = nil     -- the MIDI vport (midi.connect) Strata listens to
  S.midi_state = {
    bend = {},                -- per voice: current pitchbend ratio (transient; never a param or in scenes)
    held = {},                -- per voice: set of notes held on it
    note_voice = {},          -- per channel: note -> the voice its note on played
    started = {},             -- voice -> true: a MIDI note started it (a panic CC stops these)
  }
  for i = 1, NUM_VOICES do
    S.midi_state.bend[i] = 1
    S.midi_state.held[i] = {}
  end

  -- MIDI input. Notes, velocity and pitchbend address a voice by channel
  -- (per voice: channel n plays voice n) or always the selected voice (omni).
  -- CC is not handled here: norns' PARAMS > MAP maps CCs to any param.

  -- Listen to MIDI vport `port`. The handler lives on the vport only (as for
  -- grids and arc): norns fires both device.event and vports[port].event, so
  -- setting it on the device as well would play every note twice.
  -- The device last seen on the selected vport (nil: none, or it was
  -- unplugged). SYSTEM > DEVICES moves a device with update_devices() only,
  -- calling neither midi.add nor midi.remove, so a swap is visible only
  -- against this record (M.reconcile).
  local attached_device = nil

  function attach_midi(port)
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
    if device.port == params:get("midi_device") then
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

  -- Forget every held note. The voices those notes held are stopped when
  -- `stop_all` (a panic) or in voice off mode: nothing can release them any
  -- more (#407, #529).
  local function release_held_notes(stop_all)
    local to_stop = {}
    for i = 1, NUM_VOICES do
      local wanted = next(S.midi_state.held[i]) ~= nil
      -- a panic also stops a voice a released key started and left running
      if stop_all then wanted = wanted or S.midi_state.started[i] end
      if wanted and S.voices[i].active and (stop_all or params:get("midi_note_off") == 2) then
        to_stop[#to_stop + 1] = i
      end
      S.midi_state.held[i] = {}
    end
    S.midi_state.note_voice = {}
    if stop_all then S.midi_state.started = {} end
    for _, i in ipairs(to_stop) do
      S.midi_state.started[i] = nil
      toggle_voice(i)
    end
  end

  -- Re-center every bent voice, and (unless `keep_notes`) release the held
  -- notes: called when the port or channel mode changes or the device goes
  -- away, since the bend returns and note offs will not arrive. A channel mode
  -- change keeps the notes: their note offs still reach the voices their note
  -- ons played (note_voice).
  function reset_midi_input(keep_notes)
    for i = 1, NUM_VOICES do
      if S.midi_state.bend[i] ~= 1 then
        S.midi_state.bend[i] = 1
        if S.voices[i].active then engine.setVoiceParam(i - 1, "bend", 1) end
      end
    end
    if not keep_notes then release_held_notes(false) end
  end

  -- All notes off (CC 123) and all sound off (CC 120): release every held
  -- note and stop every voice a MIDI note started and left running (held or
  -- not), in either note off mode (#529)
  M.PANIC_CCS = { [120] = true, [123] = true }

  -- The voice a MIDI channel addresses, or nil
  function midi_target_voice(channel)
    if params:get("midi_channel_mode") == 2 then return S.selected_voice end
    if channel and channel >= 1 and channel <= NUM_VOICES then return channel end
    return nil
  end

  -- Drop the voice's hold on a note unless another channel's note on still
  -- maps that note to the voice
  local function release_note_hold(voice_idx, note)
    for _, channel_notes in pairs(S.midi_state.note_voice) do
      if channel_notes[note] == voice_idx then return end
    end
    S.midi_state.held[voice_idx][note] = nil
  end

  function midi_event(data)
    local msg = midi.to_msg(data)
    if msg.type == "note_on" and msg.vel > 0 then
      local voice_idx = midi_target_voice(msg.ch)
      if voice_idx then
        S.midi_state.note_voice[msg.ch] = S.midi_state.note_voice[msg.ch] or {}
        -- a repeated note on whose voice changed (omni, the selection moved)
        -- releases the voice that owned the note before
        local previous = S.midi_state.note_voice[msg.ch][msg.note]
        if previous and previous ~= voice_idx then
          S.midi_state.note_voice[msg.ch][msg.note] = nil
          release_note_hold(previous, msg.note)
          midi_note_off_for(previous)
        end
        S.midi_state.note_voice[msg.ch][msg.note] = voice_idx
        S.midi_state.held[voice_idx][msg.note] = true
        midi_note_on(voice_idx, msg.note, msg.vel)
      end
    elseif msg.type == "note_on" or msg.type == "note_off" then
      -- the voice this note's note on played (in omni mode the selection may
      -- have moved since), or the channel's voice for a note it never saw
      local channel_notes = S.midi_state.note_voice[msg.ch]
      local voice_idx = (channel_notes and channel_notes[msg.note]) or midi_target_voice(msg.ch)
      if channel_notes then channel_notes[msg.note] = nil end
      if voice_idx then
        release_note_hold(voice_idx, msg.note)
        midi_note_off_for(voice_idx)
      end
    elseif msg.type == "pitchbend" then
      local voice_idx = midi_target_voice(msg.ch)
      if voice_idx then midi_pitchbend(voice_idx, msg.val) end
    elseif msg.type == "cc" and M.PANIC_CCS[msg.cc] then
      release_held_notes(true)
    end
  end

  -- A note sets the voice's pitch (synth: freq; buffer: rate, note 60 = 1;
  -- input: no pitch), snapped to the scale for a quantized voice, starts the
  -- voice if it is off, then accents it at the note's velocity. Voices keep
  -- their slow attacks; the velocity lands on the accent.
  function midi_note_on(voice_idx, note, velocity)
    local prefix = "v" .. voice_idx .. "_"
    -- a quantized voice plays the scale tone nearest the note (lib/variation.lua)
    note = S.lib.variation.midi_note(voice_idx, note)
    if voice_uses_synth(voice_idx) then
      local min_freq, max_freq = param_range(prefix .. "freq")
      params:set(prefix .. "freq", util.clamp(musicutil.note_num_to_freq(note), min_freq, max_freq))
    elseif voice_uses_buffer(voice_idx) then
      local min_rate, max_rate = param_range(prefix .. "buf_rate")
      params:set(prefix .. "buf_rate", util.clamp(2 ^ ((note - M.MIDI.rate_root_note) / 12), min_rate, max_rate))
    end
    if not S.voices[voice_idx].active then
      toggle_voice(voice_idx)
      S.midi_state.started[voice_idx] = true
    end
    engine.retrigger(voice_idx - 1, velocity / M.MIDI.velocity_max)
  end

  -- In "voice off" mode a voice stops when no note is held on it any more. A
  -- note during its release starts it again (the engine re-gates the
  -- releasing synths).
  function midi_note_off_for(voice_idx)
    if params:get("midi_note_off") ~= 2 or not S.voices[voice_idx].active then return end
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
    if params:get("midi_channel_mode") ~= 2 then return end
    local ratio = S.midi_state.bend[previous_voice]
    if ratio == 1 then return end
    midi_set_bend(previous_voice, 1)
    midi_set_bend(S.selected_voice, ratio)
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
  end)

  -- Stop listening to MIDI before the voices go off
  S.register_cleanup(S.constants.CLEANUP_ORDER.midi_handler, function()
    if S.midi_device then S.midi_device.event = nil end
  end)

  -- A note is held on a voice exactly while some channel's note on maps it there
  S.register_invariant("midi notes", function()
    for voice_idx, flag in pairs(S.midi_state.started) do
      if flag ~= true or voice_idx < 1 or voice_idx > NUM_VOICES then
        return "started has a bad entry for " .. tostring(voice_idx)
      end
    end
    local owned = {}
    for _, channel_notes in pairs(S.midi_state.note_voice) do
      for note, voice_idx in pairs(channel_notes) do
        owned[voice_idx] = owned[voice_idx] or {}
        owned[voice_idx][note] = true
      end
    end
    for voice_idx = 1, NUM_VOICES do
      for note in pairs(S.midi_state.held[voice_idx]) do
        if not (owned[voice_idx] and owned[voice_idx][note]) then
          return "note " .. note .. " is held on voice " .. voice_idx .. " but no channel maps it there"
        end
      end
      for note in pairs(owned[voice_idx] or {}) do
        if not S.midi_state.held[voice_idx][note] then
          return "note " .. note .. " is mapped to voice " .. voice_idx .. " but not held on it"
        end
      end
    end
  end)

  return M
end

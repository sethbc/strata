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
    max_port = 4,             -- midi_device param range (vports 1-4)
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
  function attach_midi(port)
    if S.midi_device then S.midi_device.event = nil end
    S.midi_device = midi.connect(port)
    S.midi_device.event = midi_event
  end

  function midi_init()
    attach_midi(params:get("midi_device"))
  end

  -- Hot-plug. norns assigns the device to its vport before calling midi.add,
  -- and clears the vport only after midi.remove returns.
  function midi.add(device)
    attach_midi(params:get("midi_device"))
    request_redraw()  -- SETUP shows the device
    print("midi connected: " .. tostring(device.name))
  end

  function midi.remove(device)
    if device.port == params:get("midi_device") then reset_midi_input() end
    -- SETUP shows the port as empty: norns clears the vport as midi.remove
    -- returns, before the next frame draws
    request_redraw()
    print("midi disconnected: " .. tostring(device.name))
  end

  -- The name of the device on the selected port, or "none"
  function midi_device_name()
    local device = S.midi_device and S.midi_device.device
    if device == nil then return "none" end
    return S.midi_device.name
  end

  -- Forget held notes and re-center every bent voice: called when the port or
  -- channel mode changes or the device goes away, since the note offs and
  -- bend returns for them will not arrive
  function reset_midi_input()
    for i = 1, NUM_VOICES do
      S.midi_state.held[i] = {}
      if S.midi_state.bend[i] ~= 1 then
        S.midi_state.bend[i] = 1
        if S.voices[i].active then engine.setVoiceParam(i - 1, "bend", 1) end
      end
    end
    S.midi_state.note_voice = {}
  end

  -- The voice a MIDI channel addresses, or nil
  function midi_target_voice(channel)
    if params:get("midi_channel_mode") == 2 then return S.selected_voice end
    if channel and channel >= 1 and channel <= NUM_VOICES then return channel end
    return nil
  end

  function midi_event(data)
    local msg = midi.to_msg(data)
    if msg.type == "note_on" and msg.vel > 0 then
      local voice_idx = midi_target_voice(msg.ch)
      if voice_idx then
        S.midi_state.note_voice[msg.ch] = S.midi_state.note_voice[msg.ch] or {}
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
        S.midi_state.held[voice_idx][msg.note] = nil
        midi_note_off_for(voice_idx)
      end
    elseif msg.type == "pitchbend" then
      local voice_idx = midi_target_voice(msg.ch)
      if voice_idx then midi_pitchbend(voice_idx, msg.val) end
    end
  end

  -- A note sets the voice's pitch (synth: freq; buffer: rate, note 60 = 1;
  -- input: no pitch), starts the voice if it is off, then accents it at the
  -- note's velocity. Voices keep their slow attacks; the velocity lands on the
  -- accent.
  function midi_note_on(voice_idx, note, velocity)
    local prefix = "v" .. voice_idx .. "_"
    if voice_uses_synth(voice_idx) then
      local min_freq, max_freq = param_range(prefix .. "freq")
      params:set(prefix .. "freq", util.clamp(musicutil.note_num_to_freq(note), min_freq, max_freq))
    elseif voice_uses_buffer(voice_idx) then
      local min_rate, max_rate = param_range(prefix .. "buf_rate")
      params:set(prefix .. "buf_rate", util.clamp(2 ^ ((note - M.MIDI.rate_root_note) / 12), min_rate, max_rate))
    end
    if not S.voices[voice_idx].active then toggle_voice(voice_idx) end
    engine.retrigger(voice_idx - 1, velocity / M.MIDI.velocity_max)
  end

  -- In "voice off" mode a voice stops when no note is held on it any more. A
  -- note during its release starts it again (the engine re-gates the
  -- releasing synths).
  function midi_note_off_for(voice_idx)
    if params:get("midi_note_off") ~= 2 or not S.voices[voice_idx].active then return end
    if next(S.midi_state.held[voice_idx]) ~= nil then return end
    toggle_voice(voice_idx)
  end

  -- Pitchbend over +/-2 semitones as a frequency (or buffer rate) ratio. The
  -- engine applies it to the voice synth and to strataGrainBuf; a stopped
  -- voice gets it when it starts (sync_voice_values_to_engine). Nothing on
  -- the screen or arc shows the bend, so it asks for no redraw.
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
    midi_init()
  end)

  -- Stop listening to MIDI before the voices go off
  S.register_cleanup(S.constants.CLEANUP_ORDER.midi_handler, function()
    if S.midi_device then S.midi_device.event = nil end
  end)

  return M
end

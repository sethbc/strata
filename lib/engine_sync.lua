-- lib/engine_sync.lua
-- Param -> engine: send_param_to_engine and the engine senders
-- (S.engine_senders), the values the engine last got (S.engine_param_values),
-- the LFO offsets they add (S.lfo_last_dest, S.lfo_scaled), and starting,
-- stopping, freezing and syncing a voice. The functions that were global stay
-- global, as does engine_param_value; engine_mod_source, with_lfo_offsets and
-- send_engine_value are fields of this module's table (S.lib.engine_sync) for
-- the code that calls them: engine_mod_source in strata.lua, the other two in
-- lib/lfos.lua (apply_lfo).

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_MOD_SLOTS = S.constants.NUM_MOD_SLOTS
  local NUM_LFOS = S.constants.NUM_LFOS

  -- Convert a Lua mod source (0 = none, 1..NUM_VOICES = voice number) to the
  -- engine's 0-indexed form (-1 = none, 0..NUM_VOICES-1 = voice index)
  local function engine_mod_source(source)
    if source == 0 then return -1 end
    return source - 1
  end

  -- Param -> engine. A param action stores its value and calls
  -- send_param_to_engine(id, value), which adds the offsets of any global LFO
  -- modulating that param, so an edit (or the drift, a mutation, a scene fade)
  -- never sends the plain value under a running LFO. The LFOs drive the
  -- engine through the same path (send_engine_value). engine_senders[id]
  -- holds the engine call for a param (gated on the voice running where the
  -- engine needs that). engine_param_values remembers the last value sent per
  -- param, so a command that carries several params (setFilter, setDelay,
  -- setReverb, grain density x master density) sends the others as the engine
  -- has them: an LFO on filter res and one on filter freq do not undo each
  -- other.
  S.engine_senders = {}
  S.engine_param_values = {}
  S.lfo_last_dest = {}   -- per LFO: param id it modulates now (nil = none)
  S.lfo_scaled = {}      -- per LFO: its last scaled value (-depth..depth) at S.lfo_last_dest

  -- The value the engine last got for a param (its stored value until sent)
  function engine_param_value(param_id)
    local value = S.engine_param_values[param_id]
    if value == nil then return params:get(param_id) end
    return value
  end

  -- value plus scaled * half the range of every LFO on param_id (LFOs on one
  -- destination add up), clamped to the range; value itself when no LFO is on it
  local function with_lfo_offsets(param_id, value)
    local offset, modulated = 0, false
    for n = 1, NUM_LFOS do
      if S.lfo_last_dest[n] == param_id then
        offset = offset + S.lfo_scaled[n]
        modulated = true
      end
    end
    if not modulated then return value end
    local minval, maxval = param_range(param_id)
    return util.clamp(value + offset * 0.5 * (maxval - minval), minval, maxval)
  end

  -- Record the value as sent and run the param's engine call
  local function send_engine_value(param_id, value)
    S.engine_param_values[param_id] = value
    local sender = S.engine_senders[param_id]
    if sender then sender(value) end
  end

  -- A param's stored value, as modulated by the LFOs on it. Always sends.
  function send_param_to_engine(param_id, value)
    send_engine_value(param_id, with_lfo_offsets(param_id, value))
  end

  -- sync_voice_values_to_engine sends a voice's stored values: forget what
  -- was sent for its params before
  local function forget_sent_voice_values(voice_idx)
    local prefix = "v" .. voice_idx .. "_"
    for param_id in pairs(S.engine_param_values) do
      if param_id:sub(1, #prefix) == prefix then
        S.engine_param_values[param_id] = nil
      end
    end
  end

  -- Effects chain (filter -> delay -> reverb -> master). Each filter, delay or
  -- reverb param sends its whole command, with the values the engine has for
  -- the others.
  local function send_filter_to_engine()
    engine.setFilter(engine_param_value("filter_freq"), engine_param_value("filter_res"),
      engine_param_value("filter_type") - 1, engine_param_value("filter_mix"))
  end

  local function send_delay_to_engine()
    engine.setDelay(engine_param_value("delay_time"), engine_param_value("delay_feedback"),
      engine_param_value("delay_mix"))
  end

  local function send_reverb_to_engine()
    engine.setReverb(engine_param_value("reverb_mix"), engine_param_value("reverb_size"),
      engine_param_value("reverb_damp"))
  end

  -- Master density scales every running voice's grain density
  local function send_master_density_to_engine(density)
    for i = 1, NUM_VOICES do
      if S.voices[i].active then
        engine.setGrainParam(i - 1, "grainDensity", engine_param_value("v" .. i .. "_grain_density") * density)
      end
    end
  end

  S.engine_senders.master_density = send_master_density_to_engine
  S.engine_senders.filter_type = send_filter_to_engine
  S.engine_senders.filter_freq = send_filter_to_engine
  S.engine_senders.filter_res = send_filter_to_engine
  S.engine_senders.filter_mix = send_filter_to_engine
  S.engine_senders.delay_time = send_delay_to_engine
  S.engine_senders.delay_feedback = send_delay_to_engine
  S.engine_senders.delay_mix = send_delay_to_engine
  S.engine_senders.reverb_mix = send_reverb_to_engine
  S.engine_senders.reverb_size = send_reverb_to_engine
  S.engine_senders.reverb_damp = send_reverb_to_engine
  S.engine_senders.drift_amount = function(value) engine.setMasterDrift(value) end

  function toggle_voice(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    local voice = S.voices[voice_idx]
    
    if voice.active then
      engine.voiceOff(voice_idx - 1)
      voice.active = false
    else
      engine.voiceOn(
        voice_idx - 1,
        voice.params.freq,
        voice.params.amp,
        voice.params.pan or 0,
        voice.grain.size,
        -- the values the engine has (as the grain density sender sends them)
        engine_param_value("v" .. voice_idx .. "_grain_density") * engine_param_value("master_density"),
        voice.grain.pitch
      )
      sync_voice_to_engine(voice_idx)
      voice.active = true
    end
    
    update_voice_list()
    request_redraw()
    grid_redraw()
  end

  function toggle_freeze(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    S.frozen[voice_idx] = not S.frozen[voice_idx]
    update_voice_list()
    request_redraw()
    grid_redraw()
  end

  -- Push the complete Lua-side state of a voice to its freshly started engine
  -- synths. voiceOn only carries the initial freq/amp/pan and grain values, and
  -- param actions only reach the engine while a voice is active, so without this
  -- edits made while a voice was off (and scene recalls) would be lost. The
  -- source goes first (the engine ignores it when unchanged).
  function sync_voice_to_engine(voice_idx)
    engine.setGrainSource(voice_idx - 1, S.voices[voice_idx].source - 1)
    sync_voice_values_to_engine(voice_idx)
  end

  -- Everything sync_voice_to_engine sends after the source: synthesis, grain
  -- (including the buffer params) and crossmod values
  function sync_voice_values_to_engine(voice_idx)
    local voice = S.voices[voice_idx]
    local engine_voice = voice_idx - 1
    local engine_master_density = engine_param_value("master_density")
    -- the engine now gets this voice's stored values (LFOs re-apply theirs
    -- on their next step)
    forget_sent_voice_values(voice_idx)

    for key, value in pairs(voice.params) do
      engine.setVoiceParam(engine_voice, key, value)
    end

    engine.setGrainParam(engine_voice, "grainSize", voice.grain.size)
    engine.setGrainParam(engine_voice, "grainDensity", voice.grain.density * engine_master_density)
    engine.setGrainParam(engine_voice, "pitchShift", voice.grain.pitch)
    engine.setGrainParam(engine_voice, "posSpread", voice.grain.spread)
    engine.setGrainParam(engine_voice, "envShape", voice.grain.env - 1)
    engine.setGrainParam(engine_voice, "grainMode", voice.grain.mode - 1)
    engine.setGrainParam(engine_voice, "bufPos", voice.grain.buf_pos)
    engine.setGrainParam(engine_voice, "bufRate", voice.grain.buf_rate)
    engine.setGrainParam(engine_voice, "bufScan", voice.grain.buf_scan)

    for slot = 1, NUM_MOD_SLOTS do
      local slot_state = voice.crossmod["slot" .. slot]
      engine.setModSource(engine_voice, slot, engine_mod_source(slot_state.source))
      engine.setModAmpAmt(engine_voice, slot, slot_state.amp_amt)
      engine.setModFreqAmt(engine_voice, slot, slot_state.freq_amt)
    end

    engine.setModSpeed(engine_voice, voice.crossmod.speed)
    -- the MIDI pitchbend wheel's current position (voiceOn resets the engine's to 1)
    engine.setVoiceParam(engine_voice, "bend", S.midi_state.bend[voice_idx])
  end

  M.engine_mod_source = engine_mod_source
  M.with_lfo_offsets = with_lfo_offsets
  M.send_engine_value = send_engine_value

  return M
end

-- lib/params_setup.lua
-- init's params, in PARAMS menu order: S.registry.params holds one record
-- {name, add} per part of the menu (master, mutations, scenes, fx, lfos,
-- buffers, midi, voices), and init runs each record's add in order. Also
-- the voice params (add_voice_params, get_param_spec), the redraw-on-param
-- wrapper (redraw_on_param_changes, called by init after the records) and
-- the tempo-follow handlers; these stay global. S.fx_filter_last_mix is
-- read by the FX page's K3.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_SCENES = S.constants.NUM_SCENES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local BUFFER_SECONDS = S.constants.BUFFER_SECONDS
  local GRAIN_ENV_OPTIONS = S.constants.GRAIN_ENV_OPTIONS
  local GRAIN_MODE_OPTIONS = S.constants.GRAIN_MODE_OPTIONS
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS

  -- Last non-zero filter mix (set by the filter_mix action): FX page K3
  -- restores it after a bypass
  S.fx_filter_last_mix = 1

  -- The filter and delay params are faders on the 256 grid's FX page. A scene
  -- transition sets them on every step and redraws the grid once per step
  -- itself.
  local function fx_fader_changed()
    if S.grid_page == 4 and not S.scene_transition_active then grid_redraw() end
  end

  -- Follow the clock when its tempo is set elsewhere (PARAMETERS > CLOCK, an
  -- external clock source): norns calls the handler with the new bpm (an
  -- external source's may be outside clock_tempo's range). Set the param
  -- silently, so its action does not write the clock back, then call the
  -- handler that was installed before the script's.
  function follow_clock_tempo(bpm)
    local min_tempo, max_tempo = param_range("tempo")
    params:set("tempo", util.clamp(util.round(bpm), min_tempo, max_tempo), true)
    if previous_tempo_change_handler then previous_tempo_change_handler(bpm) end
  end

  -- Install follow_clock_tempo, keeping the handler it replaces for cleanup()
  -- (restore_tempo_change_handler). Installing it again (init run twice)
  -- changes nothing: the script's handler never chains to itself
  function install_tempo_change_handler()
    if clock.tempo_change_handler == follow_clock_tempo then return end
    previous_tempo_change_handler = clock.tempo_change_handler
    clock.tempo_change_handler = follow_clock_tempo
  end

  -- Give the clock back the handler found at install, unless a handler
  -- installed after the script's has replaced it: that one stays (and any
  -- chain through follow_clock_tempo still reaches the previous handler)
  function restore_tempo_change_handler()
    if clock.tempo_change_handler ~= follow_clock_tempo then return end
    clock.tempo_change_handler = previous_tempo_change_handler
    previous_tempo_change_handler = nil
  end

  -- cleanup()'s first step
  S.register_cleanup(S.constants.CLEANUP_ORDER.tempo_handler, function()
    restore_tempo_change_handler()
  end)

  -- Add one part of the PARAMS menu: init runs the records' add functions
  -- in the order they are registered here, which is the menu's order
  local function register_params(name, add)
    S.registry.params[#S.registry.params + 1] = {name = name, add = add}
  end

  register_params("master", function()
    params:add_separator("strata")

    -- Master controls
    params:add{
      type = "control",
      id = "master_density",
      name = "master density",
      controlspec = controlspec.new(0.1, 2.0, "lin", 0.01, 1.0),
      action = function(x)
        S.master_density = x
        send_param_to_engine("master_density", x)
      end
    }

    -- Sequencer tempo: drives norns' global clock (clock_tempo), which the
    -- pattern clock follows via clock.sync so external clock sources still work.
    -- It has clock_tempo's range, so any clock tempo is captured and recalled
    local min_tempo, max_tempo = param_range("clock_tempo")
    params:add{
      type = "number",
      id = "tempo",
      name = "tempo",
      min = min_tempo,
      max = max_tempo,
      default = util.clamp(util.round(params:get("clock_tempo")), min_tempo, max_tempo),
      action = function(x)
        params:set("clock_tempo", x)
      end
    }

    install_tempo_change_handler()
  end)

  register_params("mutations", function()
    -- Probability-based mutations
    params:add_separator("strata_mutations")

    params:add{
      type = "binary",
      id = "mutation_enabled",
      name = "mutations enabled",
      behavior = "toggle",
      default = 0,
      action = function(x)
        if x == 1 then
          S.mutation_metro:start()
        else
          S.mutation_metro:stop()
        end
      end
    }

    params:add{
      type = "control",
      id = "mutation_rate",
      name = "mutation rate",
      controlspec = controlspec.new(0.5, 10, "lin", 0.1, 2, "s"),
      action = function(x)
        S.mutation_metro.time = x
      end
    }

    params:add{
      type = "control",
      id = "mutation_probability",
      name = "mutation probability",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.15),
      action = function(x)
        -- Probability value used in gentle_mutate()
      end
    }

    params:add{
      type = "control",
      id = "mutation_amount",
      name = "mutation amount",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.25),
      action = function(x)
        -- Amount value used in gentle_mutate()
      end
    }
  end)

  register_params("scenes", function()
    -- Scene system
    params:add_separator("strata_scenes")

    params:add{
      type = "binary",
      id = "scene_sequencer_enabled",
      name = "scene sequencer",
      behavior = "toggle",
      default = 0,
      action = function(x)
        if x == 1 then
          scene_sequencer_start()
        else
          scene_sequencer_stop()
        end
      end
    }

    params:add{
      type = "control",
      id = "scene_transition_time",
      name = "transition time",
      controlspec = controlspec.new(0, 30, "lin", 0.5, 2, "s"),
      action = function(x)
        -- Transition time used in scene recall
      end
    }

    params:add{
      type = "control",
      id = "scene_duration",
      name = "scene duration",
      controlspec = controlspec.new(4, 120, "lin", 1, 16, "s"),
      action = function(x)
        -- Time before advancing to next scene
      end
    }

    params:add{
      type = "number",
      id = "scene_sequence_length",
      name = "sequence length",
      min = 1,
      max = NUM_SCENES,
      default = 4,
      action = function(x)
        -- How many scenes to cycle through; the grid's scene page shows it
        grid_redraw()
      end
    }

    params:add{
      type = "trigger",
      id = "save_scenes",
      name = "save scenes to disk",
      action = function()
        save_scenes_to_disk()
      end
    }

    params:add{
      type = "trigger",
      id = "load_scenes",
      name = "load scenes from disk",
      action = function()
        load_scenes_from_disk()
      end
    }
  end)

  register_params("fx", function()
    -- Effects chain: filter, delay, reverb and tape drift in one group. The
    -- group size must match the params below exactly.
    params:add_group("strata_fx", "fx", 11)

    params:add{
      type = "option",
      id = "filter_type",
      name = "filter type",
      options = {"lowpass", "highpass", "bandpass"},
      default = 1,
      action = function(x)
        send_param_to_engine("filter_type", x)
      end
    }

    params:add{
      type = "control",
      id = "filter_freq",
      name = "filter freq",
      controlspec = controlspec.new(20, 20000, "exp", 0, 5000, "Hz"),
      action = function(x)
        send_param_to_engine("filter_freq", x)
        fx_fader_changed()
      end
    }

    params:add{
      type = "control",
      id = "filter_res",
      name = "filter res",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5),
      action = function(x)
        send_param_to_engine("filter_res", x)
        fx_fader_changed()
      end
    }

    params:add{
      type = "control",
      id = "filter_mix",
      name = "filter mix",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0),  -- 0 = bypass
      action = function(x)
        -- FX page K3 brings back the last non-zero mix, however it was set
        if x > 0 then S.fx_filter_last_mix = x end
        send_param_to_engine("filter_mix", x)
      end
    }

    params:add{
      type = "control",
      id = "delay_time",
      name = "delay time",
      controlspec = controlspec.new(0.01, 2, "exp", 0.001, 0.375, "s"),
      action = function(x)
        send_param_to_engine("delay_time", x)
        fx_fader_changed()
      end
    }

    params:add{
      type = "control",
      id = "delay_feedback",
      name = "delay feedback",
      controlspec = controlspec.new(0, 0.95, "lin", 0.01, 0.4),
      action = function(x)
        send_param_to_engine("delay_feedback", x)
        fx_fader_changed()
      end
    }

    params:add{
      type = "control",
      id = "delay_mix",
      name = "delay mix",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0),
      action = function(x)
        send_param_to_engine("delay_mix", x)
        fx_fader_changed()
      end
    }

    params:add{
      type = "control",
      id = "reverb_mix",
      name = "reverb mix",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.3),
      action = function(x)
        send_param_to_engine("reverb_mix", x)
      end
    }

    params:add{
      type = "control",
      id = "reverb_size",
      name = "reverb size",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.8),
      action = function(x)
        send_param_to_engine("reverb_size", x)
      end
    }

    params:add{
      type = "control",
      id = "reverb_damp",
      name = "reverb damping",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5),
      action = function(x)
        send_param_to_engine("reverb_damp", x)
      end
    }

    params:add{
      type = "control",
      id = "drift_amount",
      name = "tape drift",
      controlspec = controlspec.new(0, 0.1, "lin", 0.001, 0.01),
      action = function(x)
        send_param_to_engine("drift_amount", x)
      end
    }
  end)

  register_params("lfos", function()
    -- Global LFOs (their destinations, then the library's own groups)
    add_lfo_params()
  end)

  register_params("buffers", function()
    -- Sample buffers: recording settings, then file/record/clear/save per
    -- slot. The group size must match the params below exactly.
    params:add_group("strata_buffers", "buffers", 2 + NUM_BUFFERS * 4)

    params:add{
      type = "control",
      id = "record_duration",
      name = "record duration",
      controlspec = controlspec.new(0.5, BUFFER_SECONDS, "lin", 0.5, 8, "s")
    }

    params:add{
      type = "control",
      id = "record_level",
      name = "record level",
      controlspec = controlspec.new(0, 2, "lin", 0.01, 1)
    }

    for slot = 1, NUM_BUFFERS do
      params:add_file("buf" .. slot .. "_file", "buffer " .. slot .. " file", _path.audio)
      params:set_action("buf" .. slot .. "_file", function(path) load_buffer(slot, path) end)
      params:add_trigger("buf" .. slot .. "_record", "buffer " .. slot .. " record")
      params:set_action("buf" .. slot .. "_record", function() record_buffer(slot) end)
      params:add_trigger("buf" .. slot .. "_clear", "buffer " .. slot .. " clear")
      params:set_action("buf" .. slot .. "_clear", function() clear_buffer(slot) end)
      params:add_trigger("buf" .. slot .. "_save", "buffer " .. slot .. " save")
      params:set_action("buf" .. slot .. "_save", function() save_buffer(slot) end)
    end
  end)

  register_params("midi", function()
    -- MIDI input (CC mapping is norns' own PARAMS > MAP). The group size must
    -- match the params below exactly.
    params:add_group("strata_midi", "midi", 3)

    params:add{
      type = "number",
      id = "midi_device",
      name = "midi device",
      min = 1,
      max = S.lib.midi_in.MIDI.max_port,
      default = 1,
      action = function(x)
        attach_midi(x)
        reset_midi_input()  -- the old port's note offs and bend returns will not arrive
      end
    }

    params:add{
      type = "option",
      id = "midi_channel_mode",
      name = "midi channels",
      options = S.lib.midi_in.MIDI.channel_mode_options,
      default = 1,
      action = function()
        reset_midi_input()  -- held notes and bends now belong to other voices
      end
    }

    params:add{
      type = "option",
      id = "midi_note_off",
      name = "midi note off",
      options = S.lib.midi_in.MIDI.note_off_options,
      default = 1
    }
  end)

  register_params("voices", function()
    -- Add params for each voice
    for i = 1, NUM_VOICES do
      add_voice_params(i)
    end
  end)

  -- Nearly every param is shown on a page or an arc ring, so every param
  -- action asks for a redraw: PARAMS edits, CC maps (PARAMS > MAP), pset
  -- loads, scene fades and mutations all arrive through them. Run once, after
  -- every param is added. Left out, as they are shown nowhere and change
  -- many times a second: text params (the LFO library writes each LFO's
  -- scaled and raw value into its own on every step) and the drift's 10 Hz
  -- writes (drift_update asks for the buffer positions it moves itself).
  function redraw_on_param_changes()
    for _, param in ipairs(params.params) do
      local action = param.action
      if param.t ~= params.tTEXT and type(action) == "function" then
        param.action = function(...)
          action(...)
          if not S.drift_writing then request_redraw() end
        end
      end
    end
  end

  function add_voice_params(voice_idx)
    local v = S.voices[voice_idx]
    local prefix = "v" .. voice_idx .. "_"
    local engine_voice = voice_idx - 1

    -- A voice param's engine call runs only while the voice is running
    -- (sync_voice_to_engine sends everything when it starts)
    local function add_voice_sender(param_id, send)
      S.engine_senders[param_id] = function(value)
        if S.voices[voice_idx].active then send(value) end
      end
    end

    params:add_separator("voice " .. voice_idx .. ": " .. v.name)

    -- Voice params (in param_order so the menu order is stable)
    for _, key in ipairs(v.param_order) do
      local spec = get_param_spec(key)
      spec.default = v.params[key]  -- the voices table holds each voice's defaults
      local param_id = prefix .. key
      params:add{
        type = "control",
        id = param_id,
        name = key,
        controlspec = spec,
        action = function(x)
          S.voices[voice_idx].params[key] = x
          note_param_edit(param_id)  -- randomize sets it: an edit ends its undo
          send_param_to_engine(param_id, x)
        end
      }
      add_voice_sender(param_id, function(value) engine.setVoiceParam(engine_voice, key, value) end)
    end

    -- Grain params
    params:add_separator("voice " .. voice_idx .. " granular")

    -- Source: always sent, so the engine knows it before the voice starts
    -- (a stopped voice only records it; voiceOn then builds the right synths)
    params:add{
      type = "option",
      id = prefix .. "source",
      name = "source",
      options = SOURCE_OPTIONS,
      default = v.source,
      action = function(x)
        S.voices[voice_idx].source = x
        engine.setGrainSource(voice_idx - 1, x - 1)
        -- a scene recall syncs once, after it has set every param
        if S.voices[voice_idx].active and not S.scene_recall_in_progress then
          sync_voice_values_to_engine(voice_idx)
        end
        -- the grid fader list follows the source (buffer or synth params)
        if S.grid_voice_select == voice_idx then
          S.param_page = util.clamp(S.param_page, 1, fader_page_count(voice_idx))
        end
        grid_redraw()
      end
    }

    params:add{
      type = "control",
      id = prefix .. "buf_pos",
      name = "buffer position",
      -- step 0: the drift moves in steps far smaller than 0.01
      controlspec = controlspec.new(0, 1, "lin", 0, v.grain.buf_pos),
      action = function(x)
        S.voices[voice_idx].grain.buf_pos = x
        if not S.drift_writing then
          S.buf_pos_base[voice_idx] = x
        end
        note_param_edit(prefix .. "buf_pos")
        send_param_to_engine(prefix .. "buf_pos", x)
      end
    }
    add_voice_sender(prefix .. "buf_pos", function(value)
      engine.setGrainParam(engine_voice, "bufPos", value)
    end)

    params:add{
      type = "control",
      id = prefix .. "buf_rate",
      name = "buffer rate",
      controlspec = controlspec.new(0.25, 4, "exp", 0.01, v.grain.buf_rate),
      action = function(x)
        S.voices[voice_idx].grain.buf_rate = x
        note_param_edit(prefix .. "buf_rate")
        send_param_to_engine(prefix .. "buf_rate", x)
      end
    }
    add_voice_sender(prefix .. "buf_rate", function(value)
      engine.setGrainParam(engine_voice, "bufRate", value)
    end)

    params:add{
      type = "control",
      id = prefix .. "buf_scan",
      name = "buffer scan",
      controlspec = controlspec.new(-2, 2, "lin", 0.01, v.grain.buf_scan),
      action = function(x)
        S.voices[voice_idx].grain.buf_scan = x
        note_param_edit(prefix .. "buf_scan")
        send_param_to_engine(prefix .. "buf_scan", x)
      end
    }
    add_voice_sender(prefix .. "buf_scan", function(value)
      engine.setGrainParam(engine_voice, "bufScan", value)
    end)

    params:add{
      type = "control",
      id = prefix .. "grain_size",
      name = "grain size",
      controlspec = controlspec.new(0.01, 0.5, "lin", 0.01, v.grain.size),
      action = function(x)
        S.voices[voice_idx].grain.size = x
        note_param_edit(prefix .. "grain_size")
        send_param_to_engine(prefix .. "grain_size", x)
      end
    }
    add_voice_sender(prefix .. "grain_size", function(value)
      engine.setGrainParam(engine_voice, "grainSize", value)
    end)

    params:add{
      type = "control",
      id = prefix .. "grain_density",
      name = "grain density",
      controlspec = controlspec.new(1, 100, "lin", 1, v.grain.density),
      action = function(x)
        S.voices[voice_idx].grain.density = x
        send_param_to_engine(prefix .. "grain_density", x)
      end
    }
    add_voice_sender(prefix .. "grain_density", function(value)
      engine.setGrainParam(engine_voice, "grainDensity", value * engine_param_value("master_density"))
    end)

    params:add{
      type = "control",
      id = prefix .. "grain_pitch",
      name = "grain pitch",
      -- step 0: the drift moves in steps far smaller than 0.01
      controlspec = controlspec.new(0.25, 4, "lin", 0, v.grain.pitch),
      action = function(x)
        S.voices[voice_idx].grain.pitch = x
        if not S.drift_writing then
          S.grain_pitch_base[voice_idx] = x
        end
        note_param_edit(prefix .. "grain_pitch")
        send_param_to_engine(prefix .. "grain_pitch", x)
      end
    }
    add_voice_sender(prefix .. "grain_pitch", function(value)
      engine.setGrainParam(engine_voice, "pitchShift", value)
    end)

    params:add{
      type = "control",
      id = prefix .. "grain_spread",
      name = "position spread",
      controlspec = controlspec.new(0, 1, "lin", 0.01, v.grain.spread),
      action = function(x)
        S.voices[voice_idx].grain.spread = x
        send_param_to_engine(prefix .. "grain_spread", x)
      end
    }
    add_voice_sender(prefix .. "grain_spread", function(value)
      engine.setGrainParam(engine_voice, "posSpread", value)
    end)

    params:add{
      type = "option",
      id = prefix .. "grain_env",
      name = "grain envelope",
      options = GRAIN_ENV_OPTIONS,
      default = v.grain.env,
      action = function(x)
        S.voices[voice_idx].grain.env = x
        if S.voices[voice_idx].active then
          engine.setGrainParam(voice_idx - 1, "envShape", x - 1)
        end
      end
    }

    params:add{
      type = "option",
      id = prefix .. "grain_mode",
      name = "grain mode",
      options = GRAIN_MODE_OPTIONS,
      default = v.grain.mode,
      action = function(x)
        S.voices[voice_idx].grain.mode = x
        if S.voices[voice_idx].active then
          engine.setGrainParam(voice_idx - 1, "grainMode", x - 1)
        end
      end
    }

    -- Cross-modulation params (3 slots)
    params:add_separator("voice " .. voice_idx .. " cross-modulation")

    -- Slot 1
    params:add{
      type = "number",
      id = prefix .. "mod_source_1",
      name = "mod source 1",
      min = 0,
      max = NUM_VOICES,
      default = v.crossmod.slot1.source,
      formatter = function(param)
        if param:get() == 0 then
          return "none"
        else
          return "voice " .. param:get()
        end
      end,
      action = function(x)
        S.voices[voice_idx].crossmod.slot1.source = x
        if S.voices[voice_idx].active then
          engine.setModSource(voice_idx - 1, 1, S.lib.engine_sync.engine_mod_source(x))
        end
      end
    }

    params:add{
      type = "control",
      id = prefix .. "mod_amp_amt_1",
      name = "amp mod 1",
      controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot1.amp_amt),
      action = function(x)
        S.voices[voice_idx].crossmod.slot1.amp_amt = x
        send_param_to_engine(prefix .. "mod_amp_amt_1", x)
      end
    }
    add_voice_sender(prefix .. "mod_amp_amt_1", function(value) engine.setModAmpAmt(engine_voice, 1, value) end)

    params:add{
      type = "control",
      id = prefix .. "mod_freq_amt_1",
      name = "freq mod 1",
      controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot1.freq_amt),
      action = function(x)
        S.voices[voice_idx].crossmod.slot1.freq_amt = x
        send_param_to_engine(prefix .. "mod_freq_amt_1", x)
      end
    }
    add_voice_sender(prefix .. "mod_freq_amt_1", function(value) engine.setModFreqAmt(engine_voice, 1, value) end)

    -- Slot 2
    params:add{
      type = "number",
      id = prefix .. "mod_source_2",
      name = "mod source 2",
      min = 0,
      max = NUM_VOICES,
      default = v.crossmod.slot2.source,
      formatter = function(param)
        if param:get() == 0 then
          return "none"
        else
          return "voice " .. param:get()
        end
      end,
      action = function(x)
        S.voices[voice_idx].crossmod.slot2.source = x
        if S.voices[voice_idx].active then
          engine.setModSource(voice_idx - 1, 2, S.lib.engine_sync.engine_mod_source(x))
        end
      end
    }

    params:add{
      type = "control",
      id = prefix .. "mod_amp_amt_2",
      name = "amp mod 2",
      controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot2.amp_amt),
      action = function(x)
        S.voices[voice_idx].crossmod.slot2.amp_amt = x
        send_param_to_engine(prefix .. "mod_amp_amt_2", x)
      end
    }
    add_voice_sender(prefix .. "mod_amp_amt_2", function(value) engine.setModAmpAmt(engine_voice, 2, value) end)

    params:add{
      type = "control",
      id = prefix .. "mod_freq_amt_2",
      name = "freq mod 2",
      controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot2.freq_amt),
      action = function(x)
        S.voices[voice_idx].crossmod.slot2.freq_amt = x
        send_param_to_engine(prefix .. "mod_freq_amt_2", x)
      end
    }
    add_voice_sender(prefix .. "mod_freq_amt_2", function(value) engine.setModFreqAmt(engine_voice, 2, value) end)

    -- Slot 3
    params:add{
      type = "number",
      id = prefix .. "mod_source_3",
      name = "mod source 3",
      min = 0,
      max = NUM_VOICES,
      default = v.crossmod.slot3.source,
      formatter = function(param)
        if param:get() == 0 then
          return "none"
        else
          return "voice " .. param:get()
        end
      end,
      action = function(x)
        S.voices[voice_idx].crossmod.slot3.source = x
        if S.voices[voice_idx].active then
          engine.setModSource(voice_idx - 1, 3, S.lib.engine_sync.engine_mod_source(x))
        end
      end
    }

    params:add{
      type = "control",
      id = prefix .. "mod_amp_amt_3",
      name = "amp mod 3",
      controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot3.amp_amt),
      action = function(x)
        S.voices[voice_idx].crossmod.slot3.amp_amt = x
        send_param_to_engine(prefix .. "mod_amp_amt_3", x)
      end
    }
    add_voice_sender(prefix .. "mod_amp_amt_3", function(value) engine.setModAmpAmt(engine_voice, 3, value) end)

    params:add{
      type = "control",
      id = prefix .. "mod_freq_amt_3",
      name = "freq mod 3",
      controlspec = controlspec.new(-2, 2, "lin", 0.01, v.crossmod.slot3.freq_amt),
      action = function(x)
        S.voices[voice_idx].crossmod.slot3.freq_amt = x
        send_param_to_engine(prefix .. "mod_freq_amt_3", x)
      end
    }
    add_voice_sender(prefix .. "mod_freq_amt_3", function(value) engine.setModFreqAmt(engine_voice, 3, value) end)

    -- Global mod speed (shared across all slots)
    params:add{
      type = "control",
      id = prefix .. "mod_speed",
      name = "mod speed",
      controlspec = controlspec.new(0.1, 50, "exp", 0.1, v.crossmod.speed),
      action = function(x)
        S.voices[voice_idx].crossmod.speed = x
        send_param_to_engine(prefix .. "mod_speed", x)
      end
    }
    add_voice_sender(prefix .. "mod_speed", function(value) engine.setModSpeed(engine_voice, value) end)
  end

  function get_param_spec(param_name)
    local specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 100, "Hz"),  -- step 0: MIDI notes keep exact pitch
      amp = controlspec.new(0, 1, "lin", 0.01, 0.3),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
      rq = controlspec.new(0.01, 1, "lin", 0.01, 0.1),
      noise = controlspec.new(0, 1, "lin", 0.01, 0.5),
      mod1 = controlspec.new(0.01, 1, "lin", 0.01, 0.1),
      mod2 = controlspec.new(0.01, 1, "lin", 0.01, 0.15),
      ratio = controlspec.new(0.5, 8, "lin", 0.001, 1.5),  -- fine step: Ring defaults to 1.618
      index = controlspec.new(0, 10, "lin", 0.1, 2),
      modFreq = controlspec.new(0.01, 1, "lin", 0.01, 0.05),
      fold = controlspec.new(0.1, 5, "lin", 0.1, 1),
      mod = controlspec.new(0.01, 2, "lin", 0.01, 0.2),
      drift = controlspec.new(0.001, 0.1, "lin", 0.001, 0.02),
      width = controlspec.new(0.05, 0.95, "lin", 0.01, 0.5),
      cutoff = controlspec.new(100, 8000, "exp", 10, 2000, "Hz"),
      res = controlspec.new(0.1, 1, "lin", 0.01, 0.3),
      decay = controlspec.new(0.5, 10, "lin", 0.1, 4),
      damping = controlspec.new(0.1, 0.9, "lin", 0.01, 0.5),
      excite = controlspec.new(0.1, 2, "lin", 0.01, 0.3),
      brightness = controlspec.new(0, 1, "lin", 0.01, 0.5)
    }
    return specs[param_name] or controlspec.new(0, 1, "lin", 0.01, 0.5)
  end

  return M
end

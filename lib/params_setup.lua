-- lib/params_setup.lua
-- init's params, in PARAMS menu order: S.registry.params holds one record
-- {name, add} per part of the menu (master, mutations, scenes, fx, lfos,
-- buffers, midi, voices), and init runs each record's add in order. Also
-- the voice params (add_voice_params, get_param_spec), the redraw-on-param
-- wrapper (redraw_on_param_changes, called by init after the records) and
-- the tempo-follow handlers; these stay global. S.fx_last_mix.filter is
-- read by the FX page's K3. Reads, at init, the registered voice params
-- (added through S.lib.params_setup.add_voice_extra), fx params, param
-- filters and source change hooks (lib/state.lua), and sets S.performance
-- (the standard tier's values until the "performance" record fills it).

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_SCENES = S.constants.NUM_SCENES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local GRAIN_ENV_OPTIONS = S.constants.GRAIN_ENV_OPTIONS
  local GRAIN_MODE_OPTIONS = S.constants.GRAIN_MODE_OPTIONS
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS
  local FX_GROUP_PARAMS = 11  -- the fx group's own params; registered fx params follow them

  -- The performance tier's values (tier, buffer_seconds, max_grains,
  -- history_seconds): the standard tier's, a copy so nothing changes the
  -- constant. The "performance" record (lib/performance.lua) fills it at
  -- init, before any param is added; every tier-dependent spec reads it as
  -- its params are added
  S.performance = {}
  for key, value in pairs(S.constants.STANDARD_PERFORMANCE) do S.performance[key] = value end

  -- The filter's last non-zero mix (set by filter_mix's action): the FX
  -- page's K3 sets the mix to 0 and back to it. The delay and reverb need
  -- none: K3 toggles their bypass params, which keep the mix
  S.fx_last_mix = {filter = 1}

  -- The filter and delay params are faders on the 256 grid's FX page: redraw
  -- only while a grid shows it (no other layout shows them). A scene
  -- transition sets them on every step and redraws the grid once per step
  -- itself.
  local function fx_fader_changed()
    if S.lib.grid_core.any_fx_faders() and not S.scene_transition_active then grid_redraw() end
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

  -- Run a registered record's add(...) and check it added exactly
  -- record.count params (kind names the registry in the error)
  local function add_counted(kind, record, ...)
    local before = #params.params
    record.add(...)
    local added = #params.params - before
    if added ~= record.count then
      error(string.format("%s %s: add added %d params, but its count is %d", kind, record.name, added,
        record.count), 0)
    end
  end

  -- The performance tier the engine runs (lib/performance.lua): first, so
  -- S.performance is filled before any param is added. It adds no params
  register_params("performance", function() S.lib.performance.read_active() end)

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
    -- Effects chain: filter, delay, reverb and tape drift in one group, then
    -- the registered fx params (S.registry.fx_params). The group size must
    -- match the params below exactly.
    local fx_group_size = FX_GROUP_PARAMS
    for _, record in ipairs(S.registry.fx_params) do fx_group_size = fx_group_size + record.count end
    params:add_group("strata_fx", "fx", fx_group_size)

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
        if x > 0 then S.fx_last_mix.filter = x end
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

    for _, record in ipairs(S.registry.fx_params) do
      add_counted("fx params", record)
    end
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
      controlspec = controlspec.new(0.5, S.performance.buffer_seconds, "lin", 0.5, 8, "s")
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

  -- The global scale and root grains and quantized voices snap to
  -- (lib/variation.lua), before the voices
  register_params("scale", function() S.lib.variation.add_scale_params() end)

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

  -- A voice param's engine call runs only while the voice is running
  -- (sync_voice_to_engine sends everything when it starts)
  local function add_voice_sender(voice_idx, param_id, send)
    S.engine_senders[param_id] = function(value)
      if S.voices[voice_idx].active then send(value) end
    end
  end

  -- A voice param's value through its key's registered filter
  -- (S.registry.param_filters[key]), given the value stored before. A value
  -- the filter changes is written back to the param silently, so the param
  -- shows what is stored. The filter's result is what is stored, exactly,
  -- so a filter can recognize it as the next call's previous
  local function filtered_value(voice_idx, key, param_id, value, previous)
    local filter = S.registry.param_filters[key]
    if not filter then return value end
    local result = filter(voice_idx, value, previous)
    if result ~= value then params:set(param_id, result, true) end
    return result
  end

  -- Per record name: the keys its add added through add_voice_extra (for
  -- the checks after each add)
  local extra_keys = {}

  -- Add one param of a registered voice-param record (S.registry.voice_params)
  -- for voice voice_idx: param is a params:add table without an id; the id
  -- is v<i>_<key>. Its action runs the key's param filter, stores the value
  -- in S.voices[i].extras[key], ends a randomize's undo, sends it through
  -- send_param_to_engine and then runs param.action, if any. A key in
  -- record.grain_keys gets the engine sender: setGrainParam with its engine
  -- name (and value conversion), only while the voice runs. Called by the
  -- record's add, at init
  function M.add_voice_extra(voice_idx, record, key, param)
    if type(voice_idx) ~= "number" or voice_idx < 1 or voice_idx > NUM_VOICES or voice_idx % 1 ~= 0 then
      error("add_voice_extra: voice " .. tostring(voice_idx) .. " is not 1.." .. NUM_VOICES, 2)
    end
    if type(record) ~= "table" or type(record.name) ~= "string" then
      error("add_voice_extra: a registered record is needed", 2)
    end
    if type(key) ~= "string" or not key:match("^[%w_]+$") then
      error("add_voice_extra " .. record.name .. ": key " .. tostring(key) .. " is not a param id suffix", 2)
    end
    if type(param) ~= "table" or param.id ~= nil then
      error("add_voice_extra " .. record.name .. ": a params:add table without an id", 2)
    end
    local param_id = "v" .. voice_idx .. "_" .. key
    local own_action = param.action
    local args = {}
    for field, value in pairs(param) do args[field] = value end
    args.id = param_id
    args.action = function(x)
      local extras = S.voices[voice_idx].extras
      x = filtered_value(voice_idx, key, param_id, x, extras[key])
      extras[key] = x
      note_param_edit(param_id)  -- an edit ends a randomize's undo
      send_param_to_engine(param_id, x)
      if own_action then own_action(x) end
    end
    params:add(args)
    S.voices[voice_idx].extras[key] = params:get(param_id)

    local grain_key = record.grain_keys and record.grain_keys[key]
    if grain_key then
      add_voice_sender(voice_idx, param_id, function(value)
        local name, sent = S.lib.engine_sync.grain_key_message(grain_key, value)
        engine.setGrainParam(voice_idx - 1, name, sent)
      end)
    end
    extra_keys[record.name] = extra_keys[record.name] or {}
    extra_keys[record.name][key] = true
  end

  -- Per record name: how many params its add_first added for the voice
  -- being added (counted with its add's)
  local first_added = {}

  -- Each record's add_first for voice voice_idx, ahead of the voice's
  -- built-in params: norns reads a PSET line by line in param order, so a
  -- param a built-in param's filter reads (variation's quantize, read by the
  -- freq filter) must come first, or the filter would apply the current
  -- value, not the PSET's, to the built-in param (#125)
  local function add_first_voice_params(voice_idx)
    for _, record in ipairs(S.registry.voice_params) do
      extra_keys[record.name] = {}
      first_added[record.name] = 0
      if record.add_first then
        local before = #params.params
        record.add_first(voice_idx)
        first_added[record.name] = #params.params - before
      end
    end
  end

  -- Each record's add for voice voice_idx, counted with its add_first's,
  -- then a check that every key it names (grain keys, scene keys, rows) is
  -- one of its params
  local function add_registered_voice_params(voice_idx)
    for _, record in ipairs(S.registry.voice_params) do
      local before = #params.params
      record.add(voice_idx)
      local added = first_added[record.name] + #params.params - before
      if added ~= record.count then
        error(string.format("voice params %s: add%s added %d params, but its count is %d", record.name,
          record.add_first and " and add_first" or "", added, record.count), 0)
      end
      for _, keys in ipairs({record.grain_keys or {}, record.scene_defaults or {}}) do
        for key in pairs(keys) do
          if not extra_keys[record.name][key] then
            error("voice params " .. record.name .. ": " .. key .. " is not a param its add added", 0)
          end
        end
      end
      for _, key in ipairs(record.voice_rows and record.voice_rows.rows or {}) do
        if not extra_keys[record.name][key] then
          error("voice params " .. record.name .. ": row " .. key .. " is not a param its add added", 0)
        end
      end
    end
  end

  function add_voice_params(voice_idx)
    local v = S.voices[voice_idx]
    local prefix = "v" .. voice_idx .. "_"
    local engine_voice = voice_idx - 1
    -- the registered voice params' values (add_voice_extra), fresh each init
    v.extras = {}

    local function add_sender(param_id, send) add_voice_sender(voice_idx, param_id, send) end

    params:add_separator("voice " .. voice_idx .. ": " .. v.name)

    -- The registered params a PSET must read before the built-in ones
    -- (each record's add_first), then the synthesis params
    add_first_voice_params(voice_idx)

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
          x = filtered_value(voice_idx, key, param_id, x, S.voices[voice_idx].params[key])
          S.voices[voice_idx].params[key] = x
          note_param_edit(param_id)  -- randomize sets it: an edit ends its undo
          send_param_to_engine(param_id, x)
        end
      }
      add_sender(param_id, function(value) engine.setVoiceParam(engine_voice, key, value) end)
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
        S.lib.engine_sync.send_grain_source(voice_idx)
        -- the registered hooks (S.registry.source_change), before the sync,
        -- so it sends what they set (freeze cleared, never the old freeze
        -- first); a scene recall sets every value itself, so they never run
        -- during one
        if not S.scene_recall_in_progress then
          for _, hook in ipairs(S.registry.source_change) do hook(voice_idx, x) end
        end
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
    add_sender(prefix .. "buf_pos", function(value)
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
    add_sender(prefix .. "buf_rate", function(value)
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
    add_sender(prefix .. "buf_scan", function(value)
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
    add_sender(prefix .. "grain_size", function(value)
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
    add_sender(prefix .. "grain_density", function(value)
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
    add_sender(prefix .. "grain_pitch", function(value)
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
    add_sender(prefix .. "grain_spread", function(value)
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
    add_sender(prefix .. "mod_amp_amt_1", function(value) engine.setModAmpAmt(engine_voice, 1, value) end)

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
    add_sender(prefix .. "mod_freq_amt_1", function(value) engine.setModFreqAmt(engine_voice, 1, value) end)

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
    add_sender(prefix .. "mod_amp_amt_2", function(value) engine.setModAmpAmt(engine_voice, 2, value) end)

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
    add_sender(prefix .. "mod_freq_amt_2", function(value) engine.setModFreqAmt(engine_voice, 2, value) end)

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
    add_sender(prefix .. "mod_amp_amt_3", function(value) engine.setModAmpAmt(engine_voice, 3, value) end)

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
    add_sender(prefix .. "mod_freq_amt_3", function(value) engine.setModFreqAmt(engine_voice, 3, value) end)

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
    add_sender(prefix .. "mod_speed", function(value) engine.setModSpeed(engine_voice, value) end)

    -- The registered voice params (S.registry.voice_params), under one separator
    if #S.registry.voice_params > 0 then
      params:add_separator("voice " .. voice_idx .. " extras")
      add_registered_voice_params(voice_idx)
    end
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

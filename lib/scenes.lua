-- lib/scenes.lua
-- The scene system: the eight slots (S.scenes) and the loaded one
-- (S.current_scene), capture and recall (instant, or a smooth transition
-- on S.scene_transition_clock), the scene sequencer
-- (S.scene_sequencer_clock), migration of older scene formats, validation,
-- and scenes.data on disk, with the registered voice params (voices[i].extras)
-- and scene fields (S.registry.scene_fields). The functions stay global. The tables tests and
-- other code read (S.SCENE_GLOBAL_PARAMS, S.VOICE_SCENE_DEFAULTS,
-- S.SCENE_BLOCK_DEFAULTS, S.SCENE_TRANSITION) and the scene state live on S;
-- scene_data_dir and move_aside_unloadable_file are fields of this
-- module's table (S.lib.scenes) for lib/buffers.lua. Registers its three
-- cleanup steps (saving the scenes, the sequencer, the transition) and the
-- transition's invariant.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_SCENES = S.constants.NUM_SCENES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local SCENE_DATA_VERSION = S.constants.SCENE_DATA_VERSION
  local NUM_MOD_SLOTS = S.constants.NUM_MOD_SLOTS
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL
  local NUM_LFOS = S.constants.NUM_LFOS
  local SOURCE_SYNTH = S.constants.SOURCE_SYNTH
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS
  local DISCRETE_GRAIN_KEYS = S.constants.DISCRETE_GRAIN_KEYS
  local GRAIN_PARAM_IDS = S.constants.GRAIN_PARAM_IDS

  -- Scene system
  S.scenes = {}
  S.current_scene = 0  -- 0 = no scene loaded
  S.scene_sequencer_position = 1
  S.scene_sequencer_enabled = false
  S.scene_sequencer_clock = nil
  S.scene_transition_active = false
  -- true while recall_scene_instant sets params: the source action then leaves
  -- the full sync to the end of the recall
  S.scene_recall_in_progress = false
  S.scene_transition_clock = nil  -- Track transition clock for cancellation

  -- Initialize scenes
  local function empty_scene(scene_num)
    return {
      name = "scene " .. scene_num,
      populated = false,
      data = {}
    }
  end

  for i = 1, NUM_SCENES do
    S.scenes[i] = empty_scene(i)
  end

  -- Scene management functions

  -- Global params stored in every scene, in recall order. Continuous ones are
  -- crossfaded by smooth transitions; the others switch when the fade ends.
  -- default is the param's default, which migrate_scene gives scenes written
  -- before the param existed (tempo's param default follows clock_tempo; every
  -- scene file has always stored tempo).
  S.SCENE_GLOBAL_PARAMS = {
    {id = "master_density", continuous = true, default = 1.0},
    {id = "tempo", continuous = false, default = 120},
    {id = "mutation_enabled", continuous = false, default = 0},
    {id = "mutation_rate", continuous = false, default = 2},
    {id = "mutation_probability", continuous = false, default = 0.15},
    {id = "mutation_amount", continuous = false, default = 0.25},
    {id = "filter_type", continuous = false, default = 1},
    {id = "filter_freq", continuous = true, default = 5000},
    {id = "filter_res", continuous = true, default = 0.5},
    {id = "filter_mix", continuous = true, default = 0},
    {id = "delay_time", continuous = true, default = 0.375},
    {id = "delay_feedback", continuous = true, default = 0.4},
    {id = "delay_mix", continuous = true, default = 0},
    {id = "reverb_mix", continuous = true, default = 0.3},
    {id = "reverb_size", continuous = true, default = 0.8},
    {id = "reverb_damp", continuous = true, default = 0.5},
    {id = "drift_amount", continuous = true, default = 0.01}
  }

  -- Per LFO: the library's shape, mode, clocked rate, free period, depth
  -- (percent) and offset (percent), Strata's destination, then the state, so
  -- an LFO starts with its settings in place. Depth, free period and offset
  -- crossfade. The state switch re-bangs the library's baseline, which zeroes
  -- the offset: lib/lfos.lua's lfo_<n> wrapper puts the recalled one back
  -- (#103). range (optional) is the {min, max} validate_scene allows: the
  -- offset's is the library's, -100..100 for every baseline (the param
  -- clamps a recalled value to its current baseline's range)
  for n = 1, NUM_LFOS do
    table.insert(S.SCENE_GLOBAL_PARAMS, {id = "lfo_shape_" .. n, continuous = false, default = 1})    -- sine
    table.insert(S.SCENE_GLOBAL_PARAMS, {id = "lfo_mode_" .. n, continuous = false, default = 2})     -- free
    table.insert(S.SCENE_GLOBAL_PARAMS, {id = "lfo_clocked_" .. n, continuous = false, default = 13}) -- "4" (the library's index for a period of 4)
    table.insert(S.SCENE_GLOBAL_PARAMS, {id = "lfo_free_" .. n, continuous = true, default = S.lib.lfos.LFO_DEFAULT_PERIOD})
    table.insert(S.SCENE_GLOBAL_PARAMS, {id = "lfo_depth_" .. n, continuous = true, default = 0})
    table.insert(S.SCENE_GLOBAL_PARAMS, {id = "lfo_offset_" .. n, continuous = true, default = 0,
      range = S.lib.lfos.LFO_OFFSET_RANGE})
    table.insert(S.SCENE_GLOBAL_PARAMS, {id = "strata_lfo" .. n .. "_dest", continuous = false, default = 1}) -- none
    table.insert(S.SCENE_GLOBAL_PARAMS, {id = "lfo_" .. n, continuous = false, default = 1})          -- off
  end

  -- Per-voice scene fields added after format 1, filled by migrate_scene in
  -- scenes that lack them: {path = keys inside data.voices[i], default = value}.
  -- A field is only filled when its parent table exists (a scene missing the
  -- parent is left for validate_scene to reject). Each default must equal the
  -- param's default.
  S.VOICE_SCENE_DEFAULTS = {
    {path = {"grain", "env"}, default = 1},  -- hann
    {path = {"grain", "mode"}, default = 1},  -- continuous
    {path = {"source"}, default = SOURCE_SYNTH},
    {path = {"grain", "buf_pos"}, default = 0},
    {path = {"grain", "buf_rate"}, default = 1},
    {path = {"grain", "buf_scan"}, default = 0}
  }

  -- The registered voice params' scene keys (S.registry.voice_params'
  -- scene_defaults and discrete): key -> {default, range = {min, max} for a
  -- discrete key, nil for one that crossfades}. Read at use, after init
  local function registered_voice_scene_keys()
    local keys = {}
    for _, record in ipairs(S.registry.voice_params) do
      for key, default in pairs(record.scene_defaults or {}) do
        keys[key] = {default = default, range = record.discrete and record.discrete[key],
          limits = record.scene_ranges and record.scene_ranges[key]}
      end
    end
    return keys
  end

  -- A table's keys in order, so the extras are always set in one order
  local function sorted_keys(entries)
    local keys = {}
    for key in pairs(entries) do table.insert(keys, key) end
    table.sort(keys)
    return keys
  end

  -- The registered scene fields (S.registry.scene_fields) join
  -- S.SCENE_GLOBAL_PARAMS after its own entries, at init (the scenes load's
  -- start step, before the file is read): read like the built-in ones,
  -- discrete ones switching at a transition's end. Each id must be a param
  local function add_registered_scene_fields()
    local listed = {}
    for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do listed[global.id] = global end
    for _, field in ipairs(S.registry.scene_fields) do
      local existing = listed[field.id]
      if existing and not existing.registered then
        error("register_scene_field: " .. field.id .. " is already a scene field", 0)
      elseif not existing then
        if not params.lookup[field.id] then
          error("register_scene_field: " .. field.id .. " is not a param", 0)
        end
        local global = {id = field.id, continuous = not field.discrete, default = field.default, registered = true}
        table.insert(S.SCENE_GLOBAL_PARAMS, global)
        listed[field.id] = global
      end
    end
  end

  -- Top-level scene blocks added after format 1 (such as LFO or MIDI
  -- settings): {key = field of scene data, default = value}
  S.SCENE_BLOCK_DEFAULTS = {}

  -- A smooth transition fades in `steps` steps. The scene sequencer holds a
  -- scene for max(scene duration, transition time), then, while the fade is
  -- still running (its steps run late by their scheduling delay), checks
  -- again every `settle_seconds`, so it never cuts a fade short. A transition
  -- whose next step (or end) is `overrun_seconds` late is stuck: the
  -- sequencer cancels it and moves on. next_step_due (nil when no fade runs)
  -- is the running fade's progress: util.time() when its next step or its end
  -- is due. It is set and cleared together with scene_transition_active, as
  -- wait_for_scene_transition reads it whenever the flag is set
  S.SCENE_TRANSITION = {steps = 20, settle_seconds = 0.01, overrun_seconds = 1}

  local function is_number(value)
    return type(value) == "number" and value == value  -- rejects NaN
  end

  local function is_integer_between(value, min, max)
    return is_number(value) and value == math.floor(value) and value >= min and value <= max
  end

  -- Copy a scene default so filled scenes never share tables
  local function copy_scene_default(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, inner in pairs(value) do copy[key] = copy_scene_default(inner) end
    return copy
  end

  -- Set target[path] to default unless it is already present
  local function fill_scene_default(target, path, default)
    for depth = 1, #path - 1 do
      target = target[path[depth]]
      if type(target) ~= "table" then return end
    end
    if target[path[#path]] == nil then
      target[path[#path]] = copy_scene_default(default)
    end
  end

  -- Bring a loaded scene up to the current format by filling every field it
  -- lacks with its default: globals (SCENE_GLOBAL_PARAMS), top-level blocks
  -- (SCENE_BLOCK_DEFAULTS) and per-voice fields (VOICE_SCENE_DEFAULTS).
  -- Filling only adds what is missing, so it runs for every file version;
  -- from_version is there for changes that must convert a particular format.
  -- Then each registered voice-param record's normalize_scene(extras), if it
  -- has one, brings values a hand edit may have left inconsistent back to
  -- what the params allow (a loop past the slot's end), so a recall ends
  -- where the params would. Malformed scenes are left alone for
  -- validate_scene to reject.
  function migrate_scene(scene, from_version)
    if type(scene) ~= "table" or scene.populated ~= true or type(scene.data) ~= "table" then return end
    local data = scene.data

    for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
      fill_scene_default(data, {global.id}, global.default)
    end

    for _, block in ipairs(S.SCENE_BLOCK_DEFAULTS) do
      fill_scene_default(data, {block.key}, block.default)
    end

    if type(data.voices) ~= "table" then return end
    local extras = registered_voice_scene_keys()
    for i = 1, NUM_VOICES do
      if type(data.voices[i]) == "table" then
        for _, field in ipairs(S.VOICE_SCENE_DEFAULTS) do
          fill_scene_default(data.voices[i], field.path, field.default)
        end
        -- format 3 (3.2): the registered voice params' table, and every
        -- registered voice param's default
        fill_scene_default(data.voices[i], {"extras"}, {})
        for key, entry in pairs(extras) do
          fill_scene_default(data.voices[i], {"extras", key}, entry.default)
        end
        if type(data.voices[i].extras) == "table" then
          for _, record in ipairs(S.registry.voice_params) do
            if record.normalize_scene then record.normalize_scene(data.voices[i].extras) end
          end
        end
      end
    end
  end

  function capture_scene(scene_num)
    if scene_num < 1 or scene_num > NUM_SCENES then return end

    local scene_data = {
      voices = {},
      frozen = {},
      patterns = {}
    }

    for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
      scene_data[global.id] = params:get(global.id)
    end

    -- Capture voice states
    local extra_keys = registered_voice_scene_keys()
    for i = 1, NUM_VOICES do
      scene_data.voices[i] = {
        active = S.voices[i].active,
        source = S.voices[i].source,  -- the buffer's contents are not captured
        params = {},
        grain = {},
        crossmod = {},
        extras = {}   -- the registered voice params' scene keys
      }
      for key in pairs(extra_keys) do
        scene_data.voices[i].extras[key] = S.voices[i].extras[key]
      end

      -- Copy all parameters
      for key, value in pairs(S.voices[i].params) do
        scene_data.voices[i].params[key] = value
      end
      for key, value in pairs(S.voices[i].grain) do
        scene_data.voices[i].grain[key] = value
      end
      -- Copy crossmod structure (including nested slots)
      scene_data.voices[i].crossmod = {speed = S.voices[i].crossmod.speed}
      for slot = 1, NUM_MOD_SLOTS do
        local slot_state = S.voices[i].crossmod["slot" .. slot]
        scene_data.voices[i].crossmod["slot" .. slot] = {
          source = slot_state.source,
          amp_amt = slot_state.amp_amt,
          freq_amt = slot_state.freq_amt
        }
      end

      scene_data.frozen[i] = S.frozen[i]
    end

    -- Capture patterns
    for i = 1, NUM_VOICES do
      scene_data.patterns[i] = {}
      for step = 1, PATTERN_LENGTH do
        scene_data.patterns[i][step] = S.patterns[i][step]
      end
    end

    S.scenes[scene_num].data = scene_data
    S.scenes[scene_num].populated = true
    print("captured scene " .. scene_num)
  end

  -- xpcall handler: add the traceback of where the error was raised, unless
  -- an inner handler already did, so a re-raised error still shows in maiden
  -- where the param action failed
  function with_traceback(message)
    if tostring(message):find("stack traceback:", 1, true) then return message end
    return debug.traceback(tostring(message), 2)
  end

  function cancel_scene_transition()
    if S.scene_transition_clock then
      clock.cancel(S.scene_transition_clock)
      S.scene_transition_clock = nil
    end
    S.scene_transition_active = false
    S.SCENE_TRANSITION.next_step_due = nil
  end

  -- Snapshot {id, start, target, step} for every continuous param a smooth
  -- transition crossfades. Start values are read once, before the fade, so
  -- the fade moves linearly from start to target over the whole transition.
  -- Grain sources, mod sources, discrete grain params (envelope shape, grain
  -- mode), freeze and active states switch at the end instead.
  function scene_transition_targets(scene_data)
    local targets = {}
    local function add_target(param_id, target_value)
      -- number params (the LFO depths) step in whole numbers: the fade rounds
      -- to them (the end applies the scene's exact value)
      local step = params:lookup_param(param_id).t == params.tNUMBER and 1 or nil
      table.insert(targets, {id = param_id, start = params:get(param_id), target = target_value, step = step})
    end

    for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
      if global.continuous then
        add_target(global.id, scene_data[global.id])
      end
    end

    local extra_keys = registered_voice_scene_keys()
    for i = 1, NUM_VOICES do
      local voice_data = scene_data.voices[i]
      local prefix = "v" .. i .. "_"
      for key, target_value in pairs(voice_data.params) do
        add_target(prefix .. key, target_value)
      end
      for key, target_value in pairs(voice_data.grain) do
        if not DISCRETE_GRAIN_KEYS[key] then
          add_target(prefix .. GRAIN_PARAM_IDS[key], target_value)
        end
      end
      for slot = 1, NUM_MOD_SLOTS do
        local slot_data = voice_data.crossmod["slot" .. slot]
        add_target(prefix .. "mod_amp_amt_" .. slot, slot_data.amp_amt)
        add_target(prefix .. "mod_freq_amt_" .. slot, slot_data.freq_amt)
      end
      add_target(prefix .. "mod_speed", voice_data.crossmod.speed)
      -- the registered voice params that crossfade (discrete ones switch at the end)
      for _, key in ipairs(sorted_keys(voice_data.extras)) do
        if not extra_keys[key].range then add_target(prefix .. key, voice_data.extras[key]) end
      end
    end

    return targets
  end

  function recall_scene(scene_num, transition_time)
    if scene_num < 1 or scene_num > NUM_SCENES then return end
    if not S.scenes[scene_num].populated then
      print("scene " .. scene_num .. " is empty")
      return
    end

    -- Validate scene data before recalling
    if not validate_scene(S.scenes[scene_num]) then
      print("error: scene " .. scene_num .. " has invalid data")
      return
    end

    transition_time = transition_time or 0

    -- Any new recall supersedes a transition that is still running, and
    -- ends the randomize undo
    cancel_scene_transition()
    clear_undo()

    if transition_time > 0 then
      -- the fade's end applies the scene as it was recalled: a capture into
      -- this slot during the fade stores a new table and leaves this one be
      local scene_data = S.scenes[scene_num].data
      local targets = scene_transition_targets(scene_data)

      -- scene_transition_active and SCENE_TRANSITION.next_step_due are always
      -- set and cleared together (here, at the fade's end or error, and in
      -- cancel_scene_transition): the sequencer's wait reads the due time
      -- whenever the flag is set
      S.scene_transition_active = true
      S.SCENE_TRANSITION.next_step_due = util.time()  -- the first step runs at once
      S.scene_transition_clock = clock.run(function()
        local step_time = transition_time / S.SCENE_TRANSITION.steps

        for step = 1, S.SCENE_TRANSITION.steps do
          local mix = step / S.SCENE_TRANSITION.steps
          -- the flag must not outlive an error in a param action (the
          -- sequencer waits for it): clear it, then raise the error again,
          -- with its traceback
          local stepped, step_error = xpcall(function()
            for _, target in ipairs(targets) do
              local value = util.linlin(0, 1, target.start, target.target, mix)
              if target.step then value = util.round(value, target.step) end
              params:set(target.id, value)
            end
            request_redraw()
            grid_redraw()  -- keep the parameter faders moving with the fade
          end, with_traceback)
          if not stepped then
            S.scene_transition_clock = nil
            S.scene_transition_active = false
            S.SCENE_TRANSITION.next_step_due = nil
            error(step_error, 0)
          end
          S.SCENE_TRANSITION.next_step_due = util.time() + step_time
          clock.sleep(step_time)
        end

        -- Final state: exact values plus the non-continuous params
        S.scene_transition_clock = nil
        S.scene_transition_active = false
        S.SCENE_TRANSITION.next_step_due = nil
        recall_scene_instant(scene_num, scene_data)
      end)
    else
      -- Instant recall
      recall_scene_instant(scene_num)
    end

    S.current_scene = scene_num
    request_redraw()
    -- a fade's first step redrew the grid before current_scene was set; an
    -- instant recall sets it and redraws the grid itself
    if transition_time > 0 then grid_redraw() end
  end

  -- Apply a scene immediately: scene_data, or the slot's data when nil. The
  -- scene must have passed validate_scene.
  -- A voice whose source changes gets one full sync after all its params are
  -- set (not the source action's, which would send the old values first); a
  -- voice the recall starts is synced by toggle_voice instead. A voice the
  -- recall stops is stopped before its params are set, and one it starts is
  -- started after them.
  function recall_scene_instant(scene_num, scene_data)
    scene_data = scene_data or S.scenes[scene_num].data
    clear_undo()  -- a recall ends the randomize undo (a fade's end too)
    local source_changed = {}
    S.scene_recall_in_progress = true
    -- the flag must not outlive an error in a param action: clear it, then
    -- raise the error again, with its traceback
    local recalled, recall_error = xpcall(function()
      -- Restore global parameters
      for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
        params:set(global.id, scene_data[global.id])
      end

      -- Restore voice states
      for i = 1, NUM_VOICES do
        local voice_data = scene_data.voices[i]
        local prefix = "v" .. i .. "_"

        -- A voice the scene stops is stopped first, so the engine only records
        -- its source switch instead of building a grain synth to release at
        -- once, and its release tail keeps the outgoing scene's values
        if S.voices[i].active and not voice_data.active then toggle_voice(i) end

        local previous_source = S.voices[i].source
        params:set(prefix .. "source", voice_data.source)
        source_changed[i] = S.voices[i].source ~= previous_source

        for key, value in pairs(voice_data.params) do
          params:set(prefix .. key, value)
        end

        for key, value in pairs(voice_data.grain) do
          params:set(prefix .. GRAIN_PARAM_IDS[key], value)
        end

        -- Restore crossmod slots
        for slot = 1, NUM_MOD_SLOTS do
          local slot_data = voice_data.crossmod["slot" .. slot]
          params:set(prefix .. "mod_source_" .. slot, slot_data.source)
          params:set(prefix .. "mod_amp_amt_" .. slot, slot_data.amp_amt)
          params:set(prefix .. "mod_freq_amt_" .. slot, slot_data.freq_amt)
        end
        params:set(prefix .. "mod_speed", voice_data.crossmod.speed)

        -- The registered voice params, after the source (a discrete one,
        -- such as freeze, only now: a transition crossfades the others)
        for _, key in ipairs(sorted_keys(voice_data.extras)) do
          params:set(prefix .. key, voice_data.extras[key])
        end

        S.frozen[i] = scene_data.frozen[i]

        -- Start voices last: toggle_voice syncs the restored state
        if voice_data.active and not S.voices[i].active then
          toggle_voice(i)
          source_changed[i] = false
        end
      end
    end, with_traceback)
    S.scene_recall_in_progress = false

    -- even after an error: a running voice whose source switched gets its sync
    -- (of whatever was applied), so the engine never lags the Lua state
    for i = 1, NUM_VOICES do
      if source_changed[i] and S.voices[i].active then
        sync_voice_values_to_engine(i)
      end
    end
    if not recalled then error(recall_error, 0) end

    -- Restore patterns
    for i = 1, NUM_VOICES do
      S.lib.sequencer.replace_pattern(i, scene_data.patterns[i])
    end

    -- the scene is applied: the grid's scene page lights it in this redraw
    S.current_scene = scene_num
    update_voice_list()
    request_redraw()  -- freeze and running states, and the end of a fade
    grid_redraw()
  end

  -- Called by the scene sequencer when a scene's hold ends: wait while a
  -- transition (the sequencer's or a manual recall's) is flagged, but never
  -- for ever. A transition whose next step or end is
  -- SCENE_TRANSITION.overrun_seconds late is stuck (its clock is gone) and is
  -- canceled. The bound follows the fade's progress, so a healthy fade whose
  -- steps each run late under load is never cut short, however late it ends
  function wait_for_scene_transition()
    while S.scene_transition_active do
      if util.time() >= S.SCENE_TRANSITION.next_step_due + S.SCENE_TRANSITION.overrun_seconds then
        print("scene transition overran; canceled")
        cancel_scene_transition()
        return
      end
      clock.sleep(S.SCENE_TRANSITION.settle_seconds)
    end
  end

  function scene_sequencer_start()
    if S.scene_sequencer_clock then
      clock.cancel(S.scene_sequencer_clock)
    end

    S.scene_sequencer_enabled = true
    S.scene_sequencer_position = 1
    grid_redraw()  -- the scene page shows the sequencer on

    S.scene_sequencer_clock = clock.run(function()
      -- Begin on the next scheduler tick: a PSET load sets this param partway
      -- through its read, and the params it sets later (transition time,
      -- duration, length, FX, LFOs, voices) would overwrite scene 1
      clock.sleep(0)

      while S.scene_sequencer_enabled do
        -- Defensive index guard: the position is always in range here (it
        -- starts at 1 and the advance below wraps with the current length)
        if S.scene_sequencer_position > params:get("scene_sequence_length") then
          S.scene_sequencer_position = 1
        end

        -- Recall next scene in sequence (skip empty scenes)
        local transition_time = 0
        if S.scenes[S.scene_sequencer_position].populated then
          transition_time = params:get("scene_transition_time")
          -- An error in a param action (in the first fade step or an instant
          -- recall) must not end this clock while the param shows the
          -- sequencer on. The recall has cleared its transition and recall
          -- flags, so the sequencer reports it and keeps going: the next
          -- scene may well recall fine
          local recalled, recall_error = xpcall(function()
            recall_scene(S.scene_sequencer_position, transition_time)
          end, with_traceback)
          if not recalled then
            print("scene sequencer: scene " .. S.scene_sequencer_position .. " failed: " .. tostring(recall_error))
          end
        else
          print("skipping empty scene " .. S.scene_sequencer_position)
        end

        -- Hold the scene for its duration, and at least until its transition
        -- ends: the next recall would cancel the fade before it applies the
        -- scene's discrete state (voices, sources, patterns, ...)
        local held = math.max(params:get("scene_duration"), transition_time)
        clock.sleep(held)
        wait_for_scene_transition()

        -- Advance, wrapping to scene 1 past the end of the sequence as it is
        -- now (it may have been shortened during the wait)
        S.scene_sequencer_position = S.scene_sequencer_position + 1
        if S.scene_sequencer_position > params:get("scene_sequence_length") then
          S.scene_sequencer_position = 1
        end

        request_redraw()
        grid_redraw()
      end
    end)
  end

  function scene_sequencer_stop()
    S.scene_sequencer_enabled = false
    if S.scene_sequencer_clock then
      clock.cancel(S.scene_sequencer_clock)
      S.scene_sequencer_clock = nil
    end
    request_redraw()
    grid_redraw()
  end

  -- Scene disk persistence. scene_data_dir is Strata's data folder, which
  -- lib/buffers.lua reads too (buffers.data is kept beside scenes.data)
  local scene_data_dir = _path.data .. "strata/"
  local scene_data_file = scene_data_dir .. "scenes.data"
  -- Set when a scenes file could not be loaded and could not be moved aside:
  -- cleanup() must then not overwrite it with the (empty) in-memory scenes
  S.scene_autosave_blocked = false
  -- Set once load_scenes_from_disk has run to its end in this session. A
  -- start that failed before init's load (the engine did not load, an error
  -- earlier in init) leaves it false, and cleanup() then does not save, so
  -- the empty in-memory scenes never replace the saved ones (#72)
  S.scenes_loaded = false

  function save_scenes_to_disk()
    -- Ensure data directory exists
    if util.file_exists(scene_data_dir) == false then
      util.make_dir(scene_data_dir)
    end

    -- Save scenes table to disk, tagged with the format version
    tab.save({version = SCENE_DATA_VERSION, scenes = S.scenes}, scene_data_file)
    print("scenes saved to " .. scene_data_file)
  end

  -- A data file that failed to load must survive the save in cleanup():
  -- move it to <file>.bak. Returns false if that failed, and the caller then
  -- blocks its auto-save. A field of this module's table: lib/buffers.lua
  -- uses it for buffers.data.
  local function move_aside_unloadable_file(data_file, label)
    local backup_file = data_file .. ".bak"
    local moved, move_error = os.rename(data_file, backup_file)
    if moved then
      print("unloadable " .. label .. " file kept as " .. backup_file)
      return true
    end
    print("could not move unloadable " .. label .. " file (" .. tostring(move_error) ..
      "); " .. label .. " will not be auto-saved on exit")
    return false
  end

  local function preserve_unloadable_scene_file()
    if not move_aside_unloadable_file(scene_data_file, "scenes") then
      S.scene_autosave_blocked = true
    end
  end

  -- Load scenes from disk. On any problem the current scenes (empty at
  -- startup) are kept, a message is printed and the file is preserved; a bad
  -- file never stops init.
  local function read_scenes_file()
    if not util.file_exists(scene_data_file) then
      print("no saved scenes file found")
      return
    end

    -- tab.load runs the file as Lua without protection
    local ok, loaded, load_error = pcall(tab.load, scene_data_file)
    if not ok then
      print("error: scenes file could not be read (" .. tostring(loaded) .. "), keeping current scenes")
      preserve_unloadable_scene_file()
      return
    end
    if type(loaded) ~= "table" then
      print("error loading scenes file: " .. tostring(load_error))
      preserve_unloadable_scene_file()
      return
    end

    local scene_table, file_version
    if loaded.version ~= nil then
      -- Version 1 files are migrated; newer (or invalid) versions are rejected
      if not is_integer_between(loaded.version, 1, SCENE_DATA_VERSION) then
        print("error: scenes file has version " .. tostring(loaded.version) ..
          ", expected 1 to " .. SCENE_DATA_VERSION)
        preserve_unloadable_scene_file()
        return
      end
      file_version = loaded.version
      scene_table = loaded.scenes
    else
      -- Files written before 2.1 hold the bare scenes array (format version 1)
      file_version = 1
      scene_table = loaded
    end

    -- Fill fields added since the file's format, then validate the result
    if type(scene_table) == "table" then
      for i = 1, NUM_SCENES do
        migrate_scene(scene_table[i], file_version)
      end
    end

    if not validate_scene_data(scene_table) then
      print("error: scene file corrupted or incompatible version")
      preserve_unloadable_scene_file()
      return
    end

    -- Make sure every slot exists, filling gaps with empty scenes
    local loaded_scenes = {}
    for i = 1, NUM_SCENES do
      loaded_scenes[i] = scene_table[i] or empty_scene(i)
    end
    -- a running transition ends by applying its slot: after the load that
    -- would be the file's data for the slot, or nothing if it is now empty
    cancel_scene_transition()
    S.scenes = loaded_scenes
    S.scene_autosave_blocked = false
    if file_version < SCENE_DATA_VERSION then
      print("migrated scenes file from version " .. file_version)
    end
    print("scenes loaded from " .. scene_data_file)

    -- Update grid display if grids are connected
    grid_redraw()
  end

  -- init's load (and the load_scenes trigger): from here on cleanup() saves
  function load_scenes_from_disk()
    read_scenes_file()
    S.scenes_loaded = true
  end

  -- Check that one scene slot holds everything recall_scene_instant reads
  function validate_scene(scene)
    if type(scene) ~= "table" then return false end
    if type(scene.populated) ~= "boolean" then return false end
    if not scene.populated then return true end

    local data = scene.data
    if type(data) ~= "table" then return false end

    for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
      if not is_number(data[global.id]) then return false end
      -- option params (filter type, LFO shape, destination, ...) hold an index
      local param = params:lookup_param(global.id)
      if param.options and not is_integer_between(data[global.id], 1, param.count) then return false end
      -- a global with a range (the LFO offsets) stays inside it
      if global.range and (data[global.id] < global.range[1] or data[global.id] > global.range[2]) then
        return false
      end
      -- a registered discrete field holds a whole value in its param's range
      if global.registered and not global.continuous then
        local minval, maxval = -math.huge, math.huge
        if param.t == params.tBINARY then minval, maxval = 0, 1 end
        if param.t == params.tNUMBER then minval, maxval = param.min, param.max end
        if not is_integer_between(data[global.id], minval, maxval) then return false end
      end
    end
    local extra_keys = registered_voice_scene_keys()

    if type(data.voices) ~= "table" or #data.voices ~= NUM_VOICES then return false end
    if type(data.frozen) ~= "table" then return false end
    if type(data.patterns) ~= "table" then return false end

    for i = 1, NUM_VOICES do
      local voice_data = data.voices[i]
      if type(voice_data) ~= "table" then return false end
      if type(voice_data.active) ~= "boolean" then return false end
      if not is_integer_between(voice_data.source, 1, #SOURCE_OPTIONS) then return false end
      if type(voice_data.params) ~= "table" then return false end
      if type(voice_data.grain) ~= "table" then return false end
      if type(voice_data.crossmod) ~= "table" then return false end

      for key, value in pairs(voice_data.params) do
        if S.voices[i].params[key] == nil or not is_number(value) then return false end
      end
      for key, value in pairs(voice_data.grain) do
        if GRAIN_PARAM_IDS[key] == nil or not is_number(value) then return false end
        if DISCRETE_GRAIN_KEYS[key] and not is_integer_between(value, 1, DISCRETE_GRAIN_KEYS[key]) then
          return false
        end
      end
      for slot = 1, NUM_MOD_SLOTS do
        local slot_data = voice_data.crossmod["slot" .. slot]
        if type(slot_data) ~= "table" then return false end
        if not is_integer_between(slot_data.source, 0, NUM_VOICES) then return false end
        if not is_number(slot_data.amp_amt) or not is_number(slot_data.freq_amt) then return false end
      end
      if not is_number(voice_data.crossmod.speed) then return false end
      -- the registered voice params: numbers, discrete ones whole and in range
      if type(voice_data.extras) ~= "table" then return false end
      for key, value in pairs(voice_data.extras) do
        local entry = extra_keys[key]
        if entry == nil or not is_number(value) then return false end
        if entry.range and not is_integer_between(value, entry.range[1], entry.range[2]) then return false end
        if entry.limits and (value < entry.limits[1] or value > entry.limits[2]) then return false end
      end

      if type(data.frozen[i]) ~= "boolean" then return false end

      local pattern = data.patterns[i]
      if type(pattern) ~= "table" then return false end
      for step = 1, PATTERN_LENGTH do
        if not is_integer_between(pattern[step], 0, MAX_STEP_LEVEL) then return false end
      end
    end

    return true
  end

  -- Validate a whole scenes table (as loaded from disk). Missing slots are
  -- allowed; load_scenes_from_disk fills them with empty scenes.
  function validate_scene_data(scene_table)
    if type(scene_table) ~= "table" then return false end

    for i = 1, NUM_SCENES do
      if scene_table[i] ~= nil and not validate_scene(scene_table[i]) then
        return false
      end
    end

    return true
  end

  -- init's start step: a start that fails in an earlier step never gets
  -- here, so S.scenes_loaded stays false and cleanup() does not save (#72)
  S.register_start(S.constants.START_ORDER.scenes_load, function()
    add_registered_scene_fields()  -- before the file is read: it holds them
    -- Load saved scenes from disk
    load_scenes_from_disk()
  end)

  -- cleanup()'s steps: save the scenes before anything stops, unless the
  -- scenes were never loaded in this session (a failed start) or the save
  -- would overwrite a scenes file that failed to load and could not be
  -- moved aside
  S.register_cleanup(S.constants.CLEANUP_ORDER.scenes_save, function()
    if not S.scenes_loaded then
      print("scenes not auto-saved: they were not loaded from " .. scene_data_file .. " in this session")
    elseif S.scene_autosave_blocked then
      print("scenes not auto-saved: " .. scene_data_file .. " could not be loaded")
    else
      save_scenes_to_disk()
    end
  end)

  -- Stop the scene sequencer through its param so param and state agree
  -- (a start that failed before init added the params has no param to set)
  S.register_cleanup(S.constants.CLEANUP_ORDER.scene_sequencer, function()
    if params.lookup["scene_sequencer_enabled"] then params:set("scene_sequencer_enabled", 0) end
    scene_sequencer_stop()
  end)

  -- Cancel any active transition clock
  S.register_cleanup(S.constants.CLEANUP_ORDER.scene_transition, function()
    cancel_scene_transition()
  end)

  -- A fade runs exactly while its next step is due, and no transition clock
  -- outlives the fade
  S.register_invariant("scene transition", function()
    local due = S.SCENE_TRANSITION.next_step_due
    if S.scene_transition_active ~= (due ~= nil) then
      return "scene_transition_active is " .. tostring(S.scene_transition_active)
        .. " but next_step_due is " .. tostring(due)
    end
    if not S.scene_transition_active and S.scene_transition_clock ~= nil then
      return "no transition is active but scene_transition_clock is " .. tostring(S.scene_transition_clock)
    end
  end)

  -- A user's save: capture, say so in the header, redraw. capture_scene
  -- stays silent for the callers that are not a save.
  function M.save(scene_num)
    if type(scene_num) ~= "number" or scene_num % 1 ~= 0
      or scene_num < 1 or scene_num > NUM_SCENES then
      return false
    end
    capture_scene(scene_num)
    header_flash("saved S" .. scene_num)
    grid_redraw()
    request_redraw()
    return true
  end

  M.scene_data_dir = scene_data_dir
  M.move_aside_unloadable_file = move_aside_unloadable_file
  return M
end

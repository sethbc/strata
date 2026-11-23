-- lib/scenes.lua
-- The scene system: the sixteen slots (S.scenes, two banks of eight, each
-- with the player's name: bank_of, name, set_name) and the loaded one
-- (S.current_scene), capture and recall (instant, or a smooth transition
-- on S.scene_transition_clock), the scene sequencer
-- (S.scene_sequencer_clock), the stepper under it, the pattern chain and the
-- next-scene action (playable, playable_slots and next_slot, over a local
-- validity cache), the fill of a loaded scene's missing fields
-- (fill_scene), validation, and scenes.data on disk (written through
-- lib/data_files.lua at every scene save and at exit, read at start and on
-- request; S.scene_file), each PSET's <pset>.scenes.data (through
-- S.lib.side_files, with its PSET hook), with each voice's scene keys
-- (S.lib.params_setup.voice_scene_keys), scene fields
-- (S.registry.scene_fields), scene blocks (S.registry.scene_blocks) and
-- lock hooks (S.registry.lock_change). A scene's voice is {active, source,
-- type, values} (format 10, 3.8: type its voice type's key, values its
-- type's synth keys and the shared keys): capture_voice takes one and
-- apply_voice applies one.
-- A recall is the list scene_entries builds (per voice, voice_entries'),
-- applied by apply_entries (all fields of S.lib.scenes, which morph uses
-- too). The functions stay global. The tables tests and
-- other code read (S.SCENE_GLOBAL_PARAMS,
-- S.SCENE_BLOCK_DEFAULTS, S.SCENE_TRANSITION) and the scene state live on S;
-- scene_data_dir, move_aside_unloadable_file and SCENE_LOAD are fields of
-- this module's table (S.lib.scenes) for lib/buffers.lua, and revision(slot)
-- and takeovers() for morph. Registers its three
-- cleanup steps (saving the scenes, the sequencer, the transition) and the
-- transition's invariant.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_SCENES = S.constants.NUM_SCENES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local SCENE_DATA_VERSION = S.constants.SCENE_DATA_VERSION
  local SCENE_FORMAT_FLOOR = S.constants.SCENE_FORMAT_FLOOR
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL
  local SOURCE_SYNTH = S.constants.SOURCE_SYNTH
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS

  -- Scene system
  S.scenes = {}
  S.current_scene = 0  -- 0 = no scene loaded
  S.scene_sequencer_position = 1
  S.scene_sequencer_enabled = false
  -- True from the sequencer's start and from each advance until it recalls
  -- (or skips) the scene at its position: until then that position is the
  -- slot it recalls next (S.lib.scenes.sequencer_next_slot, #303)
  S.scene_sequencer_recall_due = false
  -- The slot the sequencer recalls next (3.7, design §5.4): drawn once by
  -- each pass right after its recall (S.lib.chance.pick), nil before the
  -- first draw and always while the sequencer is off
  S.scene_sequencer_next = nil
  S.scene_sequencer_clock = nil
  S.scene_transition_active = false
  -- true while recall_scene_instant sets params: the source action then leaves
  -- the full sync to the end of the recall
  S.scene_recall_in_progress = false
  S.scene_transition_clock = nil  -- Track transition clock for cancellation

  -- Initialize scenes. A slot's name is the player's ("" for none; 3.3
  -- named every slot "scene <i>", which loads as "")
  local function empty_scene()
    return {
      name = "",
      populated = false,
      data = {}
    }
  end

  for i = 1, NUM_SCENES do
    S.scenes[i] = empty_scene()
  end

  -- Per slot, a count that rises whenever the slot's data changes (a
  -- capture, a load from disk): S.lib.scenes.revision(slot), 0 until then
  -- (and for a number that is no slot), so morph knows when to rebuild
  local revisions = {}
  local function raise_revision(slot) revisions[slot] = (revisions[slot] or 0) + 1 end
  function M.revision(slot) return revisions[slot] or 0 end

  -- The validity cache (the groundwork's ruling 27): per slot, the data
  -- table last checked and whether it passed validate_scene,
  -- {data = <table>, valid = <boolean>}. Set at a capture and a file load;
  -- M.playable checks once a data table it has not seen (one written into
  -- S.scenes outside this module: only tests do). Never written to the file
  local checked = {}

  -- Recalls and transitions started (recall_scene, past its checks): morph
  -- compares S.lib.scenes.takeovers() between a move and its apply, so a
  -- recall after the move wins even when it recalls the scene already
  -- current (#584)
  local takeover_count = 0
  function M.takeovers() return takeover_count end

  -- Scene management functions

  -- Global params stored in every scene, in recall order. Continuous ones are
  -- crossfaded by smooth transitions; the others switch when the fade ends.
  -- default is the param's default, which fill_scene gives scenes written
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
    {id = "reverb_mix", continuous = true, default = 0.43},
    {id = "reverb_size", continuous = true, default = 0.8},
    {id = "reverb_damp", continuous = true, default = 0.5},
    {id = "drift_amount", continuous = true, default = 0.01}
  }

  -- Then the LFOs' fields (lib/lfos.lua's S.lib.lfos.SCENE_FIELDS, the
  -- records themselves, in their order): per LFO its settings, then its
  -- state, so an LFO starts with its settings in place. An entry with lfo =
  -- n belongs to LFO n: a fade that stops it (S.lib.lfos.transition_stops)
  -- moves its stop_target entries there and holds the others (#408). range
  -- (optional) is the {min, max} validate_scene allows
  for _, field in ipairs(S.lib.lfos.SCENE_FIELDS) do
    table.insert(S.SCENE_GLOBAL_PARAMS, field)
  end

  -- A voice's scene keys, read at use (after init): the list of {key,
  -- default, range, limits, synth} in recall order (S.lib.params_setup's
  -- voice_scene_keys: the voice's built-in keys sorted, then its registered
  -- keys sorted) and the same entries by key, for the type type_key (3.8;
  -- nil: the voice's current type; a type this build lacks: no synth keys)
  local function voice_scene_keys(voice_idx, type_key)
    return S.lib.params_setup.voice_scene_keys(voice_idx, type_key)
  end

  -- A scene voice's type key as a string a key can be (^[%w_]+$), or nil
  local function type_key_of(voice_data)
    local key = voice_data.type
    if type(key) == "string" and key:match("^[%w_]+$") then return key end
    return nil
  end

  -- A registered field's own setter (its record's optional set =
  -- fn(value), 3.4: a macro sets itself silently), by param id: a recall,
  -- a fade step and apply_entries call it in place of set_scene_param
  local field_setters = {}

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
        field_setters[field.id] = field.set
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
  -- wait_for_scene_transition reads it whenever the flag is set; so are
  -- target (the scene the fade goes to) and previous (the current scene
  -- before it), nil when no fade runs (#253), and step (the number of the
  -- fade step applied last, set before its redraws: the target blinks by it,
  -- #254)
  S.SCENE_TRANSITION = {steps = 20, settle_seconds = 0.01, overrun_seconds = 1}

  -- Set a param as a scene sets it: a binary through set_binary_param
  -- (lib/ui/params.lua), so a controller mapped to it in PARAMS > MAP
  -- follows (norns' Binary:set sends no CC, #538); any other through
  -- params:set, whose own set sends the map's CC
  local function set_scene_param(param_id, value)
    if params:lookup_param(param_id).t == params.tBINARY then
      set_binary_param(param_id, value)
    else
      params:set(param_id, value)
    end
  end

  -- What a recall, a fade step and apply_entries set a param through: its
  -- registered field's own set when it has one, else set_scene_param
  local function set_scene_value(param_id, value)
    local set = field_setters[param_id]
    if set then
      set(value)
    else
      set_scene_param(param_id, value)
    end
  end

  -- The registered scene blocks (S.registry.scene_blocks: {key, default =
  -- fn(), capture = fn(), validate = fn(value), apply = fn(value), discrete
  -- = true, through_zero = fn(from_value, to_value)}), read at each use,
  -- after init; a block is data[key] of a scene. apply gets a copy of it;
  -- validate and through_zero get the stored value and must not modify it
  local function scene_blocks()
    return S.registry.scene_blocks
  end

  -- a finite number: NaN, inf and -inf are refused (the data files' reader
  -- reads inf and nan as numbers, and tab.load read 1e999 as inf, #464)
  local function is_number(value)
    return type(value) == "number" and value > -math.huge and value < math.huge
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

  -- A slot name as validate_scene allows it: a string of at most
  -- SCENE_NAME_MAX printable ASCII characters ("" for none)
  local function is_scene_name(value)
    return type(value) == "string" and #value <= S.constants.SCENE_NAME_MAX and not value:find("[^\32-\126]")
  end

  -- Fill a scene voice's missing fields (format 10: {active, source, type,
  -- values}): the source (the synth) and the type (the voice's default,
  -- S.lib.types.default_key), then, when values is a table, each of the
  -- voice's scene keys of the scene's type it lacks with that key's
  -- default (a type this build lacks: the shared keys alone); then each
  -- registered voice-param record's normalize_scene(values), if it has one,
  -- brings values a hand edit may have left inconsistent back to what the
  -- params allow (a loop past the slot's end), so a recall ends where the
  -- params would. A voice that is no table, or values that are none, are
  -- left for valid_voice_data to refuse
  local function fill_voice(voice_idx, voice_data)
    if type(voice_data) ~= "table" then return end
    if voice_data.source == nil then voice_data.source = SOURCE_SYNTH end
    if voice_data.type == nil then voice_data.type = S.lib.types.default_key(voice_idx) end
    local values = voice_data.values
    if type(values) ~= "table" or not type_key_of(voice_data) then return end
    for _, entry in ipairs((voice_scene_keys(voice_idx, voice_data.type))) do
      if values[entry.key] == nil then values[entry.key] = entry.default end
    end
    for _, record in ipairs(S.registry.voice_params) do
      if record.normalize_scene then record.normalize_scene(values) end
    end
  end

  -- Fill a loaded scene's missing fields with their defaults (3.7: the one
  -- rule for every file from SCENE_FORMAT_FLOOR up; no code is keyed on a
  -- file's version). A slot without a name gets none (""); a populated
  -- scene gets every field it lacks: globals (SCENE_GLOBAL_PARAMS),
  -- top-level blocks (SCENE_BLOCK_DEFAULTS, then each registered block's
  -- default()) and each voice's (fill_voice). Filling only adds what is
  -- missing, so it can run twice. Malformed scenes are left alone for
  -- validate_scene to reject.
  function fill_scene(scene)
    if type(scene) == "table" and scene.name == nil then scene.name = "" end
    if type(scene) ~= "table" or scene.populated ~= true or type(scene.data) ~= "table" then return end
    local data = scene.data

    for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
      fill_scene_default(data, {global.id}, global.default)
    end

    for _, block in ipairs(S.SCENE_BLOCK_DEFAULTS) do
      fill_scene_default(data, {block.key}, block.default)
    end
    for _, record in ipairs(scene_blocks()) do
      if data[record.key] == nil then data[record.key] = record.default() end
    end

    if type(data.voices) ~= "table" then return end
    for i = 1, NUM_VOICES do fill_voice(i, data.voices[i]) end
  end

  -- A voice as a scene holds it (format 10): a fresh {active, source, type,
  -- values}, type the voice's type's key, values holding the voice's scene
  -- keys (voice_scene_keys: its current type's synth keys) and nothing else
  -- (no note_cap, no solo); nil for a number that is no voice.
  -- The source's buffer contents are not captured
  function M.capture_voice(voice_idx)
    if not is_integer_between(voice_idx, 1, NUM_VOICES) then return nil end
    local values = {}
    for _, entry in ipairs((voice_scene_keys(voice_idx))) do
      values[entry.key] = S.voices[voice_idx].values[entry.key]
    end
    return {active = S.voices[voice_idx].active, source = S.voices[voice_idx].source, type = S.voices[voice_idx].name,
      values = values}
  end

  function capture_scene(scene_num)
    if scene_num < 1 or scene_num > NUM_SCENES then return end

    local scene_data = {
      voices = {},
      locked = {},
      patterns = {}
    }

    -- each registered block's own capture, under its key
    for _, record in ipairs(scene_blocks()) do
      scene_data[record.key] = record.capture()
    end

    for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
      scene_data[global.id] = params:get(global.id)
    end

    -- Capture voice states
    for i = 1, NUM_VOICES do
      scene_data.voices[i] = M.capture_voice(i)
      scene_data.locked[i] = S.locked[i]
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
    S.scene_file.pset = nil  -- no PSET holds these scenes now (before the write a save makes)
    checked[scene_num] = {data = scene_data, valid = validate_scene(S.scenes[scene_num]) == true}
    raise_revision(scene_num)
    print("captured scene " .. scene_num)
  end

  -- xpcall handler: add the traceback of where the error was raised, unless
  -- an inner handler already did, so a re-raised error still shows in maiden
  -- where the param action failed
  function with_traceback(message)
    if tostring(message):find("stack traceback:", 1, true) then return message end
    return debug.traceback(tostring(message), 2)
  end

  -- The fade's and the scene sequencer's clocks run on the clock helper
  -- (lib/clocks.lua, #870): their handles, beside S.scene_transition_clock
  -- and S.scene_sequencer_clock, which hold their ids for the tests
  local transition_handle, sequencer_handle = nil, nil

  -- Stop one of them: retired while its wake may be posted, canceled
  -- farther from it. One whose coroutine has gone already (a test's lost
  -- clock) is only forgotten: no resume of it can come
  local function stop_clock(handle)
    if S.lib.clocks.alive(handle) then S.lib.clocks.stop(handle) end
  end

  -- The one way a transition ends (#253), `how` it ends:
  -- - "canceled" (cancel_scene_transition) and "superseded" (a new recall,
  --   which redraws itself): the clock is canceled;
  -- - "failed" (a step raised) and "landing" (the fade's end, before
  --   recall_scene_instant): inside the clock, whose id is only forgotten.
  -- A fade that does not land never applied its scene, so the scene current
  -- before it is current again; a canceled or failed one is redrawn (also a
  -- fade back to the current scene, whose blink phase ends). A landing keeps
  -- the target current while recall_scene_instant applies it.
  -- Returns the fade's previous scene (nil when no fade ran)
  local function end_scene_transition(how)
    local previous = S.SCENE_TRANSITION.previous
    if how == "canceled" or how == "superseded" then stop_clock(transition_handle) end
    transition_handle = nil
    S.scene_transition_clock = nil
    local was_active = S.scene_transition_active
    if was_active and how ~= "landing" and S.current_scene ~= previous then S.current_scene = previous end
    S.scene_transition_active = false
    S.SCENE_TRANSITION.next_step_due = nil
    S.SCENE_TRANSITION.target = nil
    S.SCENE_TRANSITION.previous = nil
    S.SCENE_TRANSITION.step = nil
    S.SCENE_TRANSITION.released = nil
    -- a fade that ends canceled or failed is redrawn even when it went back
    -- to the current scene: the blink phase (step) changed
    if was_active and (how == "canceled" or how == "failed") then
      request_redraw()
      grid_redraw()
    end
    return previous
  end

  function cancel_scene_transition()
    end_scene_transition("canceled")
  end

  -- True while a fade step sets its params (its loop of sets and its
  -- through-zero switches), never for the whole fade: a hand edit between
  -- two steps is a hand edit (#867). setting() reads it
  local fade_step_setting = false

  -- Whether a scene is setting values now (3.9, #867): inside
  -- apply_entries (S.scene_recall_in_progress: a recall, a fade's landing,
  -- morph's discrete entries, a voice's apply) or a fade step's own sets.
  -- Never inside set_scene_value itself, which morph's continuous writes
  -- go through too, so they keep the loop pair's filter on. The readers
  -- (lib/loops.lua, lib/variation.lua, the FX faders' redraws) take a set
  -- made while it is false for a hand edit
  function M.setting()
    return S.scene_recall_in_progress == true or fade_step_setting
  end

  -- A voice's entries of a recall (scene_entries, apply_entries), from a
  -- scene voice that passed valid_voice_data: {kind = "discrete", key =
  -- "active", voice, value}, its source (v<i>_source, discrete), its type
  -- (3.8: v<i>_type, discrete, its index; none for a type this build
  -- lacks, which leaves the voice's type), then each of its scene keys of
  -- the scene's type in recall order (voice_scene_keys: the built-in keys
  -- sorted, then the registered keys sorted, so freq comes before freeze
  -- and loop_length before loop_start; a type this build lacks: the shared
  -- keys alone), continuous but a key with a range (the grain mode and
  -- cloud, the mod sources, a record's discrete keys). Each param entry is
  -- {kind, id, value, voice}, a synth key's with synth = true
  function M.voice_entries(voice_idx, voice_data)
    local prefix = "v" .. voice_idx .. "_"
    local entries = {
      {kind = "discrete", key = "active", voice = voice_idx, value = voice_data.active},
      {kind = "discrete", id = prefix .. "source", value = voice_data.source, voice = voice_idx},
    }
    local record = S.lib.types.record(voice_data.type)
    if record then
      table.insert(entries, {kind = "discrete", id = prefix .. "type", value = record.index, voice = voice_idx})
    end
    for _, entry in ipairs((voice_scene_keys(voice_idx, voice_data.type))) do
      table.insert(entries, {kind = entry.range and "discrete" or "continuous", id = prefix .. entry.key,
        value = voice_data.values[entry.key], voice = voice_idx, synth = entry.synth})
    end
    return entries
  end

  -- The ordered list a recall applies (apply_entries), from scene_data
  -- (which passed validate_scene): every registered block in registration
  -- order; the globals in S.SCENE_GLOBAL_PARAMS order; then per voice its
  -- entries (voice_entries) and its lock; then the patterns. An entry is
  -- {kind = "block", key, value}, {kind = "continuous", id, value} (a param
  -- a transition fades), {kind = "discrete", id, value} (a param set at a
  -- transition's end) or {kind = "discrete", key = "active" | "lock" |
  -- "pattern", voice, value}; a per-voice param's entry (continuous or
  -- discrete) carries its voice too, a global's none
  function M.scene_entries(scene_data)
    local entries = {}
    for _, record in ipairs(scene_blocks()) do
      table.insert(entries, {kind = "block", key = record.key, value = scene_data[record.key]})
    end
    for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
      table.insert(entries, {kind = global.continuous and "continuous" or "discrete", id = global.id,
        value = scene_data[global.id]})
    end
    for i = 1, NUM_VOICES do
      for _, entry in ipairs(M.voice_entries(i, scene_data.voices[i])) do table.insert(entries, entry) end
      table.insert(entries, {kind = "discrete", key = "lock", voice = i, value = scene_data.locked[i]})
    end
    for i = 1, NUM_VOICES do
      table.insert(entries, {kind = "discrete", key = "pattern", voice = i, value = scene_data.patterns[i]})
    end
    return entries
  end

  -- The voice an entry belongs to: its voice field (a voice state, a
  -- per-voice param), never read from an id; nil for a block, a global or
  -- a number that is no voice
  local function entry_voice(entry)
    local voice_idx = entry.voice
    if is_integer_between(voice_idx, 1, NUM_VOICES) then return voice_idx end
    return nil
  end

  -- Apply one entry of apply_entries' list. state holds the list's blocks by
  -- key, the voices whose source changed and the voices due to start. A
  -- block's apply gets a copy of the scene's value, so a module that
  -- changes its argument never changes a saved scene
  local function apply_entry(entry, state)
    local voice_idx = entry_voice(entry)
    if entry.voice ~= nil and not voice_idx then return end  -- an entry for no voice
    if entry.kind == "block" then
      local record = state.blocks[entry.key]
      if record then record.apply(copy_scene_default(entry.value)) end
    elseif entry.key == "active" then
      -- a voice the scene stops is stopped first, so the engine only records
      -- its source switch instead of building a grain synth to release at
      -- once, and its release tail keeps the outgoing scene's values; one
      -- it starts is started after its last entry (apply_entries)
      if entry.value then
        state.start_due[voice_idx] = true
      elseif S.voices[voice_idx].active then
        toggle_voice(voice_idx)
      end
    elseif entry.key == "lock" then
      local was_locked = S.locked[voice_idx]
      S.locked[voice_idx] = entry.value
      if (not was_locked) ~= (not entry.value) then
        for _, hook in ipairs(S.registry.lock_change) do hook(voice_idx, entry.value) end
      end
    elseif entry.key == "pattern" then
      S.lib.sequencer.replace_pattern(voice_idx, entry.value)
    elseif voice_idx and entry.id == "v" .. voice_idx .. "_source" then
      local previous_source = S.voices[voice_idx].source
      set_scene_value(entry.id, entry.value)
      state.source_changed[voice_idx] = S.voices[voice_idx].source ~= previous_source
    elseif voice_idx and entry.id == "v" .. voice_idx .. "_type" then
      -- 3.8: the type as the source: its action leaves the sync to the end.
      -- The voice's pending type choice is canceled outright: the param's
      -- action runs only on a change (ruling 63, P13 amended)
      S.lib.types.cancel(voice_idx)
      local previous_type = S.voices[voice_idx].name
      set_scene_value(entry.id, entry.value)
      state.type_changed[voice_idx] = S.voices[voice_idx].name ~= previous_type
    else
      set_scene_value(entry.id, entry.value)
    end
  end

  -- Apply entries (any subset of scene_entries' output, in its order) as a
  -- recall does, with S.scene_recall_in_progress set throughout and put
  -- back as it was found after (the
  -- v<i>_source and v<i>_type actions then leave the full sync to the end): a param
  -- through set_scene_value, a block through its record's apply, a lock
  -- that changes runs the lock_change hooks (S.registry.lock_change,
  -- fn(voice_idx, locked)), a pattern through
  -- S.lib.sequencer.replace_pattern. A voice whose active entry stops it is
  -- stopped there; one it starts is started after its last entry in the
  -- list (its pattern aside, which follows every voice's entries), so
  -- toggle_voice syncs what was applied. Then each running voice whose
  -- source or type (3.8) changed, and that the list did not start, gets one
  -- sync_voice_values_to_engine, even after an error in an action: the flag
  -- is cleared, the syncs run, and the error is raised again with its
  -- traceback. opts.only = "discrete" (the blocks and discrete entries) or
  -- "continuous" applies only those; any other only raises before anything
  -- is applied. opts.skip_voices (3.8, a set by voice: a fade's released
  -- voices, release_voice) drops every entry of those voices first (their
  -- active, source, type, values, lock and pattern). Redraws are the caller's
  local applied_errors = {}  -- the scene-applied hooks' last printed message, by name
  function M.apply_entries(entries, opts)
    local only = opts and opts.only
    if only ~= nil and only ~= "discrete" and only ~= "continuous" then
      error("apply_entries: only is nil, \"discrete\" or \"continuous\", not " .. tostring(only), 2)
    end
    local skip_voices = opts and opts.skip_voices or {}
    local list = {}
    for _, entry in ipairs(entries) do
      local voice_idx = entry_voice(entry)
      if (only == nil or (only == "continuous") == (entry.kind == "continuous"))
        and not (voice_idx and skip_voices[voice_idx]) then
        table.insert(list, entry)
      end
    end
    local last_entry = {}  -- per voice, the index of its last entry but its pattern
    for index, entry in ipairs(list) do
      local voice_idx = entry_voice(entry)
      if voice_idx and entry.key ~= "pattern" then last_entry[voice_idx] = index end
    end
    local state = {blocks = {}, source_changed = {}, type_changed = {}, start_due = {}}
    for _, record in ipairs(scene_blocks()) do state.blocks[record.key] = record end

    -- the flag must not outlive an error in a param action: put it back as
    -- it was found (an apply inside another leaves the outer one's set,
    -- #892), then raise the error again, with its traceback
    local outer_recall = S.scene_recall_in_progress
    S.scene_recall_in_progress = true
    local applied, apply_error = xpcall(function()
      for index, entry in ipairs(list) do
        apply_entry(entry, state)
        local voice_idx = entry_voice(entry)
        -- start the voice last: toggle_voice syncs the restored state
        if voice_idx and last_entry[voice_idx] == index and state.start_due[voice_idx] then
          state.start_due[voice_idx] = nil
          if not S.voices[voice_idx].active then
            toggle_voice(voice_idx)
            state.source_changed[voice_idx] = false
            state.type_changed[voice_idx] = false
          end
        end
      end
    end, with_traceback)
    S.scene_recall_in_progress = outer_recall
    -- the scene-applied hooks (S.registry.scene_applied), each contained
    for _, record in ipairs(S.registry.scene_applied) do
      S.lib.ui_frame.contained_call(applied_errors, record.name, "scene applied hook " .. record.name, record.fn)
    end

    -- even after an error: a running voice whose source switched gets its sync
    -- (of whatever was applied), so the engine never lags the Lua state; then
    -- its held extra notes follow what it now is (S.lib.notes.recall_switched:
    -- cut when it ends a frozen synth voice, rulings 58 and 59)
    for i = 1, NUM_VOICES do
      if (state.source_changed[i] or state.type_changed[i]) and S.voices[i].active then
        sync_voice_values_to_engine(i)
        if state.source_changed[i] then S.lib.notes.recall_switched(i) end
      end
    end
    if not applied then error(apply_error, 0) end
  end

  -- Snapshot {id, start, target, step, voice} (voice: a per-voice param's,
  -- else nil) for every continuous entry of the
  -- scene (scene_entries), the params a smooth transition crossfades. Start
  -- values are read once, before the fade, so the fade moves linearly from
  -- start to target over the whole transition. Grain sources, mod sources,
  -- discrete grain params (envelope shape, grain mode), freeze, lock and
  -- active states switch at the end instead. 3.8: a voice's synth keys of
  -- a scene whose type differs from the voice's type at the fade's start
  -- land at the end with the type (the shared keys fade).
  function scene_transition_targets(scene_data)
    local targets = {}
    local function add_target(param_id, target_value, voice_idx)
      -- number params (the LFO depths) step in whole numbers: the fade rounds
      -- to them (the end applies the scene's exact value)
      local step = params:lookup_param(param_id).t == params.tNUMBER and 1 or nil
      table.insert(targets, {id = param_id, start = params:get(param_id), target = target_value, step = step,
        voice = voice_idx})
    end

    -- an LFO the fade stops (running now, off in the scene) fades its depth
    -- out, never toward the scene's (a setting the scene never plays), and
    -- keeps its period and offset: the end sets the scene's values with the
    -- state (#408)
    local globals = {}
    for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do globals[global.id] = global end
    -- each voice's type now, read once, before the fade
    local other_type = {}
    for i = 1, NUM_VOICES do other_type[i] = scene_data.voices[i].type ~= S.voices[i].name end
    for _, entry in ipairs(M.scene_entries(scene_data)) do
      if entry.kind == "continuous" and not (entry.synth and other_type[entry.voice]) then
        local global = globals[entry.id]
        if not (global and global.lfo and S.lib.lfos.transition_stops(global.lfo, scene_data)) then
          add_target(entry.id, entry.value, entry.voice)
        elseif global.stop_target ~= nil then
          add_target(entry.id, global.stop_target, entry.voice)
        end
      end
    end

    return targets
  end

  -- A transition's ramps through 0, asked once at its start: each
  -- registered block with through_zero gets its capture now and the
  -- scene's value, and returns {{id, switch = fn()}, ...}. Each id's target
  -- is marked (step_value then fades it start x (1 - 2f) below f = 0.5 and
  -- target x (2f - 1) from it); the switches are returned, to run once at
  -- the first step with f >= 0.5. An id that is no target only switches
  local function through_zero_switches(scene_data, targets)
    local by_id = {}
    for _, target in ipairs(targets) do by_id[target.id] = target end
    local switches = {}
    for _, record in ipairs(scene_blocks()) do
      if record.through_zero then
        for _, ramp in ipairs(record.through_zero(record.capture(), scene_data[record.key]) or {}) do
          if by_id[ramp.id] then by_id[ramp.id].through_zero = true end
          if ramp.switch then table.insert(switches, ramp.switch) end
        end
      end
    end
    return switches
  end

  -- A target's value at fraction mix of a fade, rounded to its step
  local function step_value(target, mix)
    local value
    if not target.through_zero then
      value = util.linlin(0, 1, target.start, target.target, mix)
    elseif mix < 0.5 then
      value = target.start * (1 - 2 * mix)
    else
      value = target.target * (2 * mix - 1)
    end
    if target.step then value = util.round(value, target.step) end
    return value
  end

  -- 3.6's scene-recalled hooks (S.registry.scene_recalled, read at each
  -- call), each contained, with (scene_num): once per recall, when the
  -- scene becomes current and applied (an instant recall, not a fade's
  -- landing) or at a fade's first step once it ran
  local recalled_errors = {}
  local function tell_recalled(scene_num)
    for index, hook in ipairs(S.registry.scene_recalled) do
      S.lib.ui_frame.contained_call(recalled_errors, index, "scene recalled hook " .. index, hook, scene_num)
    end
  end

  function recall_scene(scene_num, transition_time)
    if scene_num < 1 or scene_num > NUM_SCENES then return end
    if not S.scenes[scene_num].populated then
      print("scene " .. scene_num .. " is empty")
      header_flash(M.label(scene_num) .. " empty")  -- the grid's recall key shows nothing else (#420)
      return
    end

    -- Validate scene data before recalling
    if not validate_scene(S.scenes[scene_num]) then
      print("error: scene " .. scene_num .. " has invalid data")
      return
    end

    transition_time = transition_time or 0
    takeover_count = takeover_count + 1

    -- Any new recall supersedes a transition that is still running (which
    -- puts its previous scene back: this recall redraws), and ends the
    -- randomize undo
    end_scene_transition("superseded")
    clear_undo()

    if transition_time > 0 then
      -- the fade's end applies the scene as it was recalled: a capture into
      -- this slot during the fade stores a new table and leaves this one be
      local scene_data = S.scenes[scene_num].data
      local targets = scene_transition_targets(scene_data)
      local switches = through_zero_switches(scene_data, targets)
      local switched = false
      -- 3.8 (ruling 45): the voices a load let go of (release_voice), kept
      -- here for the steps and the landing, reachable as
      -- SCENE_TRANSITION.released while the fade runs (end_scene_transition
      -- clears that field before the landing applies the scene)
      local released = {}

      -- scene_transition_active, SCENE_TRANSITION.next_step_due, target and
      -- previous are always set together here (step by each step) and
      -- cleared together by end_scene_transition: the sequencer's wait
      -- reads the due time whenever the flag is set. The target is current
      -- from the first step (the grids light it at once); previous is the
      -- scene the transition's end puts back
      S.scene_transition_active = true
      S.SCENE_TRANSITION.next_step_due = util.time()  -- the first step runs at once
      S.SCENE_TRANSITION.target = scene_num
      S.SCENE_TRANSITION.previous = S.current_scene
      S.SCENE_TRANSITION.released = released
      S.current_scene = scene_num
      local handle = S.lib.clocks.run(function(handle)
        local step_time = transition_time / S.SCENE_TRANSITION.steps

        for step = 1, S.SCENE_TRANSITION.steps do
          local mix = step / S.SCENE_TRANSITION.steps
          -- the flag must not outlive an error in a param action (the
          -- sequencer waits for it): end the transition (the previous scene
          -- is current again), then raise the error again, with its traceback.
          -- Its sets are a scene's (setting()) and the flag goes back to what
          -- it found, after an error too
          local outer_setting = fade_step_setting
          local stepped, step_error = xpcall(function()
            fade_step_setting = true
            for _, target in ipairs(targets) do
              if not (target.voice and released[target.voice]) then set_scene_value(target.id, step_value(target, mix)) end
            end
            -- the through-zero switches, once, at the first step from the midpoint
            if mix >= 0.5 and not switched then
              switched = true
              for _, switch in ipairs(switches) do switch() end
            end
            fade_step_setting = outer_setting
            S.SCENE_TRANSITION.step = step  -- these redraws show its phase
            request_redraw()
            grid_redraw()  -- keep the parameter faders moving with the fade
          end, with_traceback)
          fade_step_setting = outer_setting
          if not stepped then
            end_scene_transition("failed")
            error(step_error, 0)
          end
          if step == 1 then tell_recalled(scene_num) end
          S.SCENE_TRANSITION.next_step_due = util.time() + step_time
          -- stopped (a recall superseded it, a cancel): it ends here
          if not handle.sleep(step_time) then return end
        end

        -- Final state: exact values plus the non-continuous params. The
        -- target stays current while recall_scene_instant applies it (no
        -- redraw inside it shows the previous scene); only if that fails
        -- is the previous scene current again. current_if_failed covers an
        -- error in the recall's apply_entries only: one raised after it
        -- (update_voice_list) leaves the target current
        recall_scene_instant(scene_num, scene_data, end_scene_transition("landing"), true, released)
      end)
      transition_handle, S.scene_transition_clock = handle, handle.id
      -- its first step has run and drawn the target as current
    else
      -- Instant recall: it makes the scene current when it is applied
      recall_scene_instant(scene_num)
    end
  end

  -- Apply a scene immediately: scene_data, or the slot's data when nil. The
  -- scene must have passed validate_scene. It is the whole of
  -- scene_entries, through apply_entries: the blocks, the globals, each
  -- voice (a voice the recall stops is stopped before its source and
  -- params are set, one it starts is started after them, its lock set),
  -- then the patterns; a block's through_zero plays no part.
  -- A voice whose source changes gets one full sync after all its params are
  -- set (not the source action's, which would send the old values first); a
  -- voice the recall starts is synced by toggle_voice instead.
  -- current_if_failed (a fade's landing passes its previous scene) is the
  -- scene current if the recall fails; nil leaves the current scene as it is.
  -- landing (a fade's landing passes true): the fade's first step told the
  -- scene-recalled hooks already, so they are not told again.
  -- released (3.8, a fade's landing passes the fade's set): the voices a
  -- load let go of during the fade, left out of the landing (skip_voices)
  function recall_scene_instant(scene_num, scene_data, current_if_failed, landing, released)
    scene_data = scene_data or S.scenes[scene_num].data
    clear_undo()  -- a recall ends the randomize undo (a fade's end too)
    local recalled, recall_error = xpcall(function()
      M.apply_entries(M.scene_entries(scene_data), released and {skip_voices = released} or nil)
    end, with_traceback)
    -- a failed recall never makes its scene current: a fade's landing puts
    -- its previous scene back (current_if_failed); otherwise the current
    -- scene stays (the last that landed, when this recall superseded a
    -- fade). One redraw shows it and whatever was applied
    if not recalled then
      if current_if_failed ~= nil then S.current_scene = current_if_failed end
      request_redraw()
      grid_redraw()
      error(recall_error, 0)
    end

    -- the scene is applied: the grid's scene page lights it in this redraw
    S.current_scene = scene_num
    if not landing then tell_recalled(scene_num) end
    update_voice_list()
    request_redraw()  -- freeze and running states, and the end of a fade
    grid_redraw()
  end

  -- Called by the scene sequencer when a scene's hold ends: wait while a
  -- transition (the sequencer's or a manual recall's) is flagged, but never
  -- for ever. A transition whose next step or end is
  -- SCENE_TRANSITION.overrun_seconds late is stuck (its clock is gone) and is
  -- canceled. The bound follows the fade's progress, so a healthy fade whose
  -- steps each run late under load is never cut short, however late it ends.
  -- handle: the sequencer's clock (S.lib.clocks), which waits through it.
  -- Returns false when that clock was stopped meanwhile, else true
  function wait_for_scene_transition(handle)
    while S.scene_transition_active do
      if util.time() >= S.SCENE_TRANSITION.next_step_due + S.SCENE_TRANSITION.overrun_seconds then
        print("scene transition overran; canceled")
        cancel_scene_transition()
        return true
      end
      if not handle.sleep(S.SCENE_TRANSITION.settle_seconds) then return false end
    end
    return true
  end

  -- The stepper (the groundwork's design §5): one list of playable slots
  -- and one draw of the next, under the scene sequencer, the pattern chain
  -- (lib/sequencer.lua) and the next-scene action (lib/io/actions.lua)

  -- Whether `slot` can play: a whole number in 1..NUM_SCENES holding a
  -- scene that is populated and valid. Validity is the cache's (checked):
  -- a data table it has not seen is checked once, here
  function M.playable(slot)
    if not is_integer_between(slot, 1, NUM_SCENES) then return false end
    local scene = S.scenes[slot]
    if type(scene) ~= "table" or scene.populated ~= true then return false end
    local entry = checked[slot]
    if entry == nil or entry.data ~= scene.data then
      entry = {data = scene.data, valid = validate_scene(scene) == true}
      checked[slot] = entry
    end
    return entry.valid
  end

  -- The playable slots of first, first + 1, ..., count of them (at most
  -- NUM_SCENES), wrapping past NUM_SCENES to 1, in that order; {} when
  -- first is no slot or count no whole number of at least 1
  function M.playable_slots(first, count)
    local slots = {}
    if not is_integer_between(first, 1, NUM_SCENES) or not is_integer_between(count, 1, math.huge) then
      return slots
    end
    for offset = 0, math.min(count, NUM_SCENES) - 1 do
      local slot = (first - 1 + offset) % NUM_SCENES + 1
      if M.playable(slot) then slots[#slots + 1] = slot end
    end
    return slots
  end

  -- The first of slots after position in the cyclic order of the slots
  -- (position itself, if listed, comes last); slots[1] for a nil position;
  -- nil for an empty list
  local function following(position, slots)
    if position == nil then return slots[1] end
    local best, best_distance = nil, nil
    for _, slot in ipairs(slots) do
      local distance = (slot - position - 1) % NUM_SCENES
      if best_distance == nil or distance < best_distance then best, best_distance = slot, distance end
    end
    return best
  end

  -- The next slot from position over slots (an ordered list of playable
  -- slots) by chances ({next, previous, random} in percent), and its move:
  -- S.lib.chance.pick's, looked up at each call, when position is in the
  -- list (a list of one gives the playing scene: "next" at 100, 0, 0, so
  -- it is applied again, else "repeat"); with position nil or not in the
  -- list (emptied, invalid, outside the range) no draw: the first slot
  -- after it, "next". nil, nil for an empty list
  function M.next_slot(position, slots, chances, random)
    if type(slots) ~= "table" or #slots == 0 then return nil, nil end
    for _, slot in ipairs(slots) do
      if slot == position then return S.lib.chance.pick(position, slots, chances, random) end
    end
    return following(position, slots), "next"
  end

  -- The sequencer's draw (3.7, design §5.4). move: the move of the slot in
  -- S.scene_sequencer_next ("repeat" recalls nothing), nil without one
  local SEQUENCER_DRAW = {move = nil}

  -- Whether the sequencer can play `slot` in a sequence `length` long:
  -- inside it and playable (#754)
  local function plays(slot, length)
    return is_integer_between(slot, 1, length) and M.playable(slot)
  end

  -- Draw the slot after the position from the playable slots of
  -- 1..length, in order, by the three chances, and keep it with its move.
  -- When the position itself cannot play (past a shortened sequence,
  -- emptied or invalid) next_slot makes no pick, since a repeat of it could
  -- not play: the first playable slot after the position (past the length,
  -- from 1), a "next" move, with no random draw (1f's review)
  local function draw_next_scene(length)
    local chances = {params:get("scene_chance_next"), params:get("scene_chance_previous"),
      params:get("scene_chance_random")}
    S.scene_sequencer_next, SEQUENCER_DRAW.move = M.next_slot(S.scene_sequencer_position,
      M.playable_slots(1, length), chances)
  end

  -- The kept slot while it can still play. A length or chance changed since
  -- the draw draws nothing; a kept slot that can no longer play is drawn
  -- again, once (never inside a recall's apply), so the grids light the
  -- slot the pass will recall. Every slot draw_next_scene keeps can play,
  -- so the next ask finds it kept and draws nothing. nil without a kept slot
  local function kept_next_scene(length)
    local kept = S.scene_sequencer_next
    if kept == nil then return nil end
    if plays(kept, length) then return kept end
    if S.scene_recall_in_progress then return nil end
    draw_next_scene(length)
    return S.scene_sequencer_next
  end

  local function forget_next_scene()
    S.scene_sequencer_next, SEQUENCER_DRAW.move = nil, nil
  end

  function scene_sequencer_start()
    stop_clock(sequencer_handle)
    sequencer_handle = nil

    S.scene_sequencer_enabled = true
    S.scene_sequencer_position = 1
    S.scene_sequencer_recall_due = true
    forget_next_scene()
    grid_redraw()  -- the scene page shows the sequencer on

    -- One pass of the sequencer: recall the scene at the position (unless
    -- its draw was a repeat), draw the next, hold, advance to the drawn slot.
    -- handle: its clock's. Returns false when the clock was stopped during
    -- the hold (it then ends, doing nothing more), else true
    local function pass(handle)
      -- Defensive index guard: the position is always in range here (it
      -- starts at 1 and the advance below wraps with the current length)
      local length = params:get("scene_sequence_length")
      if S.scene_sequencer_position > length then
        S.scene_sequencer_position = 1
      end

      -- An empty or invalid slot is skipped at once (#513, #754): the
      -- position moves on to the next playable slot. With none in the
      -- sequence it stays, and that slot is held for the duration like a
      -- scene
      if not plays(S.scene_sequencer_position, length) then
        S.scene_sequencer_position = following(S.scene_sequencer_position, M.playable_slots(1, length))
          or S.scene_sequencer_position
      end

      -- Recall the scene, unless the draw that led here was a repeat: that
      -- holds the scene playing for another duration and recalls nothing
      S.scene_sequencer_recall_due = false
      local transition_time = 0
      local repeated = SEQUENCER_DRAW.move == "repeat"
      if not repeated and plays(S.scene_sequencer_position, length) then
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
      elseif not repeated then
        print("scene sequencer: no playable scene in slots 1-" .. length .. "; holding slot "
          .. S.scene_sequencer_position)
      end

      -- Draw the slot it recalls next, once, now the recall has returned,
      -- and light it
      draw_next_scene(length)
      request_redraw()
      grid_redraw()

      -- Hold the scene for its duration, and at least until its transition
      -- ends: the next recall would cancel the fade before it applies the
      -- scene's discrete state (voices, sources, patterns, ...)
      local held = math.max(params:get("scene_duration"), transition_time)
      if not handle.sleep(held) then return false end
      if not wait_for_scene_transition(handle) then return false end

      -- Advance to the drawn slot, as the sequence is now: the kept one if
      -- it can still play, else drawn again. With no scene in the sequence
      -- the position moves on, wrapping to 1 past its end
      local length_now = params:get("scene_sequence_length")
      local next_slot = kept_next_scene(length_now)
      if next_slot == nil then
        draw_next_scene(length_now)
        next_slot = S.scene_sequencer_next
      end
      if next_slot == nil then
        next_slot = S.scene_sequencer_position + 1
        if next_slot > length_now then next_slot = 1 end
      end
      S.scene_sequencer_position = next_slot
      S.scene_sequencer_recall_due = true

      request_redraw()
      grid_redraw()
      return true
    end

    local handle = S.lib.clocks.run(function(handle)
      -- Begin on the next scheduler tick: a PSET load sets this param partway
      -- through its read, and the params it sets later (transition time,
      -- duration, length, FX, LFOs, voices) would overwrite scene 1
      if not handle.sleep(0) then return end

      while S.scene_sequencer_enabled do
        -- An error anywhere else in a pass (a param read, the wait, a
        -- redraw) stops the sequencer through its param, as the pattern
        -- clock does, so the screen, the grids, a controller mapped to the
        -- param (set_binary_param, #538) and the state agree (#329): forget
        -- this clock's id first, so the stop never cancels it from inside
        -- itself, then raise the error again for maiden
        local passed, pass_result = xpcall(function() return pass(handle) end, with_traceback)
        if passed and not pass_result then return end  -- stopped during its hold
        if not passed then
          local pass_error = pass_result
          S.scene_sequencer_clock, sequencer_handle = nil, nil
          forget_next_scene()
          if params.lookup["scene_sequencer_enabled"] then set_binary_param("scene_sequencer_enabled", 0) end
          if S.scene_sequencer_enabled then scene_sequencer_stop() end
          error(pass_error, 0)
        end
      end
    end)
    sequencer_handle, S.scene_sequencer_clock = handle, handle.id
  end

  function scene_sequencer_stop()
    S.scene_sequencer_enabled = false
    S.scene_sequencer_recall_due = false
    forget_next_scene()
    stop_clock(sequencer_handle)
    sequencer_handle, S.scene_sequencer_clock = nil, nil
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
  -- What is known of scenes.data in this session (SETUP's status rows, the
  -- load prompt): two facts kept apart (3.9, #868): load_problem, nil,
  -- "unreadable" (the file could not be loaded) or "older" (its format is
  -- below SCENE_FORMAT_FLOOR: an older Strata's), and write_problem, nil or
  -- "not saved" (the last write failed); problem, what SETUP reads, is
  -- derived from them (SCENE_FILE_PROBLEM, below); backup, the name an unreadable or
  -- older file was kept under (nil: still in place); unsaved, true while a scene
  -- captured in this session is not in the file (a write failed, or was
  -- blocked); pset, the path without .pset of the PSET that holds exactly
  -- these scenes (nil: none does), kept in the file's field pset: cleared
  -- by a capture and a name, set by a PSET save and load, cleared when that
  -- PSET is deleted, read back at a start (a value that is no string reads
  -- as nil)
  -- start_outcome (3.8): what the start's load found, "loaded", "missing",
  -- "unreadable" or "older" (nil before it ran)
  -- problem, never stored: the write's while it is set, else the load's. A
  -- set of it (a layout state's, a test's) sets the fact it names: "not
  -- saved" the write's, anything else the load's, with no write's
  local SCENE_FILE_PROBLEM = {
    __index = function(state, key)
      if key == "problem" then return rawget(state, "write_problem") or rawget(state, "load_problem") end
    end,
    __newindex = function(state, key, value)
      if key ~= "problem" then
        rawset(state, key, value)
        return
      end
      rawset(state, "write_problem", value == "not saved" and value or nil)
      if value ~= "not saved" then rawset(state, "load_problem", value) end
    end,
  }
  S.scene_file = setmetatable({load_problem = nil, write_problem = nil, backup = nil, unsaved = false, pset = nil,
    start_outcome = nil}, SCENE_FILE_PROBLEM)
  -- The load a player asks for (request_load): while a scene is unsaved, the
  -- first request arms until armed_until, confirm_seconds long, and a second
  -- inside it loads. start_flash_seconds: how long the start's hint row names
  -- a file that could not be read (lib/buffers.lua's too)
  local SCENE_LOAD = {confirm_seconds = 2, armed_until = 0, start_flash_seconds = 4}
  M.SCENE_LOAD = SCENE_LOAD

  -- Write the scenes: true and "written" or "unchanged" (the file already
  -- held these bytes, so nothing was written), or false and why (the file
  -- is then as it was, whole). The text goes to a checked .part file
  -- renamed over scenes.data (S.lib.data_files.write, #301)
  function save_scenes_to_disk()
    local data_files = S.lib.data_files
    if util.file_exists(scene_data_dir) == false then
      util.make_dir(scene_data_dir)
    end
    local state = S.scene_file
    local saved, detail = data_files.write(scene_data_file,
      {version = SCENE_DATA_VERSION, scenes = S.scenes, pset = state.pset})
    if not saved then
      state.write_problem, state.unsaved = "not saved", true
      print("error: scenes not saved to " .. scene_data_file .. " (" .. tostring(detail) .. "); the file is as it was")
      request_redraw()
      return false, detail
    end
    -- the file holds this session's scenes: a failed write, or an unreadable
    -- or older file still in place (a save from SETUP or PARAMS replaced
    -- it), is over; one set aside stays what the load found (#868)
    state.write_problem = nil
    if state.load_problem ~= nil and not state.backup then state.load_problem = nil end
    state.unsaved = false
    S.scene_autosave_blocked = false
    if detail == "written" then print("scenes saved to " .. scene_data_file) end
    request_redraw()
    return true, detail
  end

  -- A data file that failed to load must survive the next save: move it to
  -- the first free of <file>.bak, <file>.bak.2 ... (S.lib.data_files.set_aside:
  -- a backup never replaces an earlier one, #466). Returns the backup's
  -- name, or nil if that failed, and the caller then blocks its auto-save.
  -- A field of this module's table: lib/buffers.lua uses it for
  -- buffers.data.
  local function move_aside_unloadable_file(data_file, label)
    local backup_file, move_error = S.lib.data_files.set_aside(data_file, ".bak")
    if backup_file then
      print("unloadable " .. label .. " file kept as " .. backup_file)
      return backup_file
    end
    print("could not move unloadable " .. label .. " file (" .. tostring(move_error) ..
      "); " .. label .. " will not be auto-saved")
    return nil
  end

  -- problem: "unreadable", or "older" for a format below the floor
  local function preserve_unloadable_scene_file(problem)
    problem = problem or "unreadable"
    local backup = move_aside_unloadable_file(scene_data_file, "scenes")
    if not backup then S.scene_autosave_blocked = true end
    S.scene_file.load_problem, S.scene_file.backup = problem, backup
    return problem
  end

  -- Why a scenes table from a file cannot be taken, or nil: each slot is
  -- filled (fill_scene), then the whole is validated (validate_scene_data).
  -- The live file's read and the PSET's file's spec (its validate) use it
  local function scenes_problem(scene_table)
    if type(scene_table) == "table" then
      for i = 1, NUM_SCENES do fill_scene(scene_table[i]) end
    end
    if not validate_scene_data(scene_table) then return "corrupted or incompatible" end
    return nil
  end

  -- Take a scenes table that passed scenes_problem as the sixteen slots
  -- (a gap is an empty scene), from the file `from` (named in the line): a
  -- running transition ends, the current scene stays current only if the
  -- table holds the same scene in its slot, every revision rises and the
  -- validity cache holds the populated slots. The live file's read and a
  -- PSET load use it
  local function take_scenes(scene_table, from, silent)
    local loaded_scenes = {}
    for i = 1, NUM_SCENES do
      loaded_scenes[i] = scene_table[i] or empty_scene()
    end
    -- a running transition is canceled where it is, applying nothing (the
    -- scene it left is current again), so no step of it reads the new
    -- scenes
    cancel_scene_transition()
    -- the current scene stays current only if the file holds the same scene
    -- in its slot (the text a write would give, so a scene saved and read
    -- back is the same); otherwise what plays is no longer that slot (#518)
    local current = S.current_scene
    if is_integer_between(current, 1, NUM_SCENES) and type(S.scenes[current]) == "table"
      and S.lib.data_files.encode(S.scenes[current]) ~= S.lib.data_files.encode(loaded_scenes[current]) then
      S.current_scene = 0
    end
    S.scenes = loaded_scenes
    for i = 1, NUM_SCENES do
      raise_revision(i)  -- every slot holds the file's data now
      -- scenes_problem passed every populated slot
      checked[i] = loaded_scenes[i].populated and {data = loaded_scenes[i].data, valid = true} or nil
    end
    if not silent then print("scenes loaded from " .. from) end
    -- Update grid display if grids are connected
    grid_redraw()
  end

  -- Load scenes from disk: "loaded", "missing" (no file), "unreadable" or
  -- "older" (a format below the floor).
  -- On any problem the current scenes (empty at startup) are kept, a
  -- message is printed and the file is preserved; a bad file never stops
  -- init.
  local function read_scenes_file()
    -- the file is parsed, never run as Lua (lib/data_files.lua, #464)
    local loaded, problem, detail = S.lib.data_files.read(scene_data_file)
    if loaded == nil and problem == "missing" then
      print("no saved scenes file found")
      return "missing"
    end
    if type(loaded) ~= "table" then
      print("error loading scenes file: " .. tostring(detail))
      return preserve_unloadable_scene_file()
    end

    -- Formats SCENE_FORMAT_FLOOR to SCENE_DATA_VERSION load; an older file
    -- (a version below the floor, or none: before 2.1 the file was the bare
    -- scenes array) is set aside whole, never converted, and so is a newer
    -- one or a version that is no whole number
    local version = loaded.version
    if not is_integer_between(version, SCENE_FORMAT_FLOOR, SCENE_DATA_VERSION) then
      if version == nil or (is_number(version) and version < SCENE_FORMAT_FLOOR) then
        print("error: scenes file has " .. (version and ("format " .. version) or "no version") .. ", older than format "
          .. SCENE_FORMAT_FLOOR .. ", the oldest this version loads: it is set aside, not converted")
        return preserve_unloadable_scene_file("older")
      end
      -- a floor equal to the version names one format, never "9 to 9"
      local formats = SCENE_FORMAT_FLOOR == SCENE_DATA_VERSION and ("format " .. SCENE_DATA_VERSION)
        or ("formats " .. SCENE_FORMAT_FLOOR .. " to " .. SCENE_DATA_VERSION)
      print("error: scenes file has version " .. tostring(loaded.version) .. ", expected " .. formats)
      return preserve_unloadable_scene_file()
    end
    -- Fill every field the file lacks, then validate the result
    if scenes_problem(loaded.scenes) then
      print("error: scene file corrupted or incompatible version")
      return preserve_unloadable_scene_file()
    end

    take_scenes(loaded.scenes, scene_data_file)
    S.scene_autosave_blocked = false
    S.scene_file.load_problem, S.scene_file.write_problem = nil, nil
    S.scene_file.backup, S.scene_file.unsaved = nil, false
    -- the PSET that holds these scenes (the field is no scene; a value that
    -- is no string reads as none)
    S.scene_file.pset = type(loaded.pset) == "string" and loaded.pset or nil
    return "loaded"
  end

  -- init's load (and the load_scenes trigger, through request_load): from
  -- here on the scenes are saved (at each scene save, and by cleanup()).
  -- Returns "loaded", "missing", "unreadable" or "older"
  function load_scenes_from_disk()
    local outcome = read_scenes_file()
    S.scenes_loaded = true
    request_redraw()  -- the header's current scene, SCENES' slots, SETUP's status rows
    return outcome
  end

  -- Write the scenes if this session may: nil when it may not (the scenes
  -- were never loaded in it, or an unloadable file is still in place), and
  -- the scenes are then unsaved; else what save_scenes_to_disk returns
  function M.autosave()
    if not S.scenes_loaded or S.scene_autosave_blocked then
      S.scene_file.unsaved = true
      request_redraw()
      return nil
    end
    return save_scenes_to_disk()
  end

  -- The load a player asks for (SETUP's K3, the PARAMS trigger). While a
  -- scene captured in this session is not in the file (S.scene_file.unsaved)
  -- the first request only arms and returns "confirm"; a second within
  -- SCENE_LOAD.confirm_seconds loads. Otherwise it loads at once: the file
  -- then holds what memory holds (unless it was replaced from outside).
  -- Returns "confirm", or what load_scenes_from_disk returns ("loaded",
  -- "missing", "unreadable", "older"), looked up as it runs
  function M.request_load()
    if S.scene_file.unsaved and util.time() >= SCENE_LOAD.armed_until then
      SCENE_LOAD.armed_until = util.time() + SCENE_LOAD.confirm_seconds
      return "confirm"
    end
    SCENE_LOAD.armed_until = 0
    return load_scenes_from_disk()
  end

  -- A scene voice (format 10) as a recall can apply it: a table holding
  -- exactly active (a boolean), source (a whole SOURCE_OPTIONS index), type
  -- (a key string) and values, which holds exactly the voice's scene keys
  -- of the scene's own type (voice_scene_keys(voice_idx, type): another
  -- type's synth key, a key a later version adds and a missing key are all
  -- refused), each a finite number, a key with a range a whole number
  -- inside it and one with limits a number inside them. A type this build
  -- lacks (3.8, design §2.4): every shared key as above, and any other key
  -- a finite number (that type's own, kept in the file, never applied)
  local VOICE_FIELDS = {active = true, source = true, type = true, values = true}
  local function valid_voice_data(voice_idx, voice_data)
    if type(voice_data) ~= "table" then return false end
    for field in pairs(voice_data) do
      if not VOICE_FIELDS[field] then return false end
    end
    if type(voice_data.active) ~= "boolean" then return false end
    if not is_integer_between(voice_data.source, 1, #SOURCE_OPTIONS) then return false end
    local values = voice_data.values
    if type(values) ~= "table" then return false end
    local type_key = type_key_of(voice_data)
    if not type_key then return false end
    local known = S.lib.types.record(type_key) ~= nil
    local list, by_key = voice_scene_keys(voice_idx, type_key)
    for key, value in pairs(values) do
      local entry = by_key[key]
      if not is_number(value) or (entry == nil and (known or type(key) ~= "string")) then return false end
      if entry and entry.range and not is_integer_between(value, entry.range[1], entry.range[2]) then return false end
      if entry and entry.limits and (value < entry.limits[1] or value > entry.limits[2]) then return false end
    end
    for _, entry in ipairs(list) do
      if values[entry.key] == nil then return false end
    end
    return true
  end

  -- Apply one voice's scene data (format 10, as capture_voice gives it) at
  -- once, as a recall applies a voice: a copy of data is filled
  -- (fill_voice) and checked (valid_voice_data, by the data's own type),
  -- then its entries (voice_entries) go through apply_entries with opts, so
  -- the voice stops or starts by its active, its source and then its type
  -- go first, and a running voice whose source or type changes gets one sync. Leaves the voice's pattern and
  -- lock, the globals, the blocks, S.current_scene and a running transition
  -- alone; redraws are the caller's. A number that is no voice, or data
  -- still invalid after the fill, applies nothing: one console line, and
  -- false. True once applied
  function M.apply_voice(voice_idx, data, opts)
    if not is_integer_between(voice_idx, 1, NUM_VOICES) then
      print("apply_voice: " .. tostring(voice_idx) .. " is no voice; nothing applied")
      return false
    end
    local copy = copy_scene_default(data)
    fill_voice(voice_idx, copy)
    if not valid_voice_data(voice_idx, copy) then
      print("apply_voice: voice " .. voice_idx .. "'s data is not a scene voice; nothing applied")
      return false
    end
    M.apply_entries(M.voice_entries(voice_idx, copy), opts)
    return true
  end

  -- Check that one scene slot holds everything recall_scene_instant reads,
  -- and a name (every slot, empty or not)
  function validate_scene(scene)
    if type(scene) ~= "table" then return false end
    if not is_scene_name(scene.name) then return false end
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
      -- a registered continuous field lies inside its param's range (a
      -- control's controlspec, a number's min and max)
      if global.registered and global.continuous then
        local minval, maxval = param_range(global.id)
        if is_number(minval) and is_number(maxval) and (data[global.id] < math.min(minval, maxval)
          or data[global.id] > math.max(minval, maxval)) then
          return false
        end
      end
    end
    -- every registered block passes its own validate
    for _, record in ipairs(scene_blocks()) do
      if not record.validate(data[record.key]) then return false end
    end
    if type(data.voices) ~= "table" or #data.voices ~= NUM_VOICES then return false end
    if type(data.locked) ~= "table" then return false end
    if type(data.patterns) ~= "table" then return false end

    for i = 1, NUM_VOICES do
      if not valid_voice_data(i, data.voices[i]) then return false end

      if type(data.locked[i]) ~= "boolean" then return false end

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

  -- Scenes with the PSET (the groundwork before 3.8, design §6, rulings 34
  -- and 35): each PSET's sixteen scenes in <path_base>.scenes.data, through
  -- S.lib.side_files (the live file keeps its own writer above). The spec's
  -- floor is its version: exactly the build's format (10) loads. refused: the hint row's
  -- flash when a PSET's scenes cannot be taken (the live ones stay)
  local PSET_SCENES = {side_suffix = ".scenes.data", backup_suffix = ".bak", refused = "pset scenes not loaded"}
  M.PSET_SCENES = PSET_SCENES

  -- The live file written again when this session may (its pset field
  -- changed); nothing while it may not, so the scenes' unsaved flag stays
  local function rewrite_live_pset()
    if S.scenes_loaded and not S.scene_autosave_blocked then save_scenes_to_disk() end
  end

  -- Whether the PSET the mark names still holds the live scenes: its
  -- scenes file is there, of this format, and its scenes, filled as a load
  -- fills them (scenes_problem: a key added under the format since the file
  -- was written takes its default), encode as S.scenes (the file deleted,
  -- copied without the PSET or saved over elsewhere makes the mark stale,
  -- #766)
  local function mark_holds_live()
    local mark = S.scene_file.pset
    if mark == nil then return false end
    local held = S.lib.data_files.read(mark .. PSET_SCENES.side_suffix)
    local data_files = S.lib.data_files
    return type(held) == "table" and held.version == SCENE_DATA_VERSION and type(held.scenes) == "table"
      and scenes_problem(held.scenes) == nil and data_files.encode(held.scenes) == data_files.encode(S.scenes)
  end

  -- Before a PSET load replaces them: live scenes no PSET holds (no mark,
  -- or a stale one, which is cleared) that hold anything (a populated or
  -- named slot) are written to the live file, which is then set aside as a
  -- backup (scenes.data.bak, ...). True when nothing needed keeping or it
  -- was kept; else false and why
  local function back_up_live()
    if mark_holds_live() then return true end
    S.scene_file.pset = nil
    local holds = false
    for i = 1, NUM_SCENES do
      if S.scenes[i].populated or S.scenes[i].name ~= "" then holds = true end
    end
    if not holds then return true end
    local saved, detail = M.autosave()
    if not saved then return false, tostring(detail or "the live scenes file is not written in this session") end
    local backup, why = S.lib.data_files.set_aside(scene_data_file, PSET_SCENES.backup_suffix)
    if not backup then return false, tostring(why) end
    print("scenes in no PSET kept as " .. backup)
    return true
  end
  -- 3.8 (4d): a factory set's load keeps the live scenes so first (step 3
  -- of S.lib.factory's load)
  M.back_up_live = back_up_live

  -- The PSET's scenes (side_files' load): nil (no file, or an unusable one
  -- the helper set aside) leaves the live scenes, and clears the mark when
  -- it names this PSET (#766); else the live scenes are
  -- kept first when they must be (back_up_live; when that fails one line,
  -- and the live scenes stay), then taken as a disk load takes them, and
  -- the live file is rewritten naming the PSET. Nothing is recalled: the
  -- sound is the PSET's params. A silent read (params:read's) prints no
  -- scenes loaded line; a refusal's line and flash still show
  local function load_pset_scenes(scene_table, path, silent)
    local path_base = path:sub(1, #path - #PSET_SCENES.side_suffix)
    -- the read set its sound already: a running fade ends where it is,
    -- whatever the file holds, so no later step or landing of it puts the
    -- old target's params back over it (#859; take_scenes cancels too)
    cancel_scene_transition()
    if scene_table == nil then
      if S.scene_file.pset == path_base then
        S.scene_file.pset = nil
        rewrite_live_pset()
      end
      -- a factory set without usable scenes (read only, 3.8): its load set
      -- the live file aside first, so the live scenes are written back
      if S.lib.side_files.reading_only() then M.autosave() end
      return
    end
    -- a factory set's scenes (S.lib.side_files.read_only, 3.8): its load
    -- kept the live scenes first (back_up_live), and no PSET holds them, so
    -- no mark names the set's folder in the script
    if S.lib.side_files.reading_only() then
      take_scenes(scene_table, path, silent)
      S.scene_file.pset = nil
      SCENE_LOAD.armed_until = 0
      M.autosave()
      request_redraw()
      return
    end
    local kept, why = back_up_live()
    if not kept then
      print("scenes from " .. path .. " not loaded: the scenes in no PSET could not be kept (" .. why
        .. "); the live scenes stay")
      S.lib.ui_flash.start("hints", PSET_SCENES.refused, SCENE_LOAD.start_flash_seconds)
      return
    end
    take_scenes(scene_table, path, silent)
    S.scene_file.pset = path_base
    SCENE_LOAD.armed_until = 0
    M.autosave()
    request_redraw()
  end

  local pset_scene_files = S.lib.side_files.new({
    name = "scenes", contents = "scenes", version = SCENE_DATA_VERSION, floor = SCENE_FORMAT_FLOOR,
    key = "scenes", live_file = "scenes.data", side_suffix = PSET_SCENES.side_suffix,
    backup_suffix = PSET_SCENES.backup_suffix,
    capture = function() return S.scenes end, validate = scenes_problem, load = load_pset_scenes,
  })
  -- registered at include, so it runs before morph's hook (which forgets
  -- its plan once the slots changed): a PSET save marks the live file as
  -- held by it, the delete of that PSET clears the mark
  S.register_pset_hook(pset_scene_files.pset_hook(nil, nil, function(written, path_base)
    if not written then return end
    S.scene_file.pset = path_base
    rewrite_live_pset()
  end, function(path_base)
    if S.scene_file.pset ~= path_base then return end
    S.scene_file.pset = nil
    rewrite_live_pset()
  end))

  -- init's start step: a start that fails in an earlier step never gets
  -- here, so S.scenes_loaded stays false and cleanup() does not save (#72)
  S.register_start(S.constants.START_ORDER.scenes_load, function()
    add_registered_scene_fields()  -- before the file is read: it holds them
    -- Load saved scenes from disk
    -- (a file that cannot be read, or an older Strata's, is named on the
    -- hint row of whatever page comes up; SETUP's status rows keep it)
    local outcome = load_scenes_from_disk()
    -- whether a scenes file was found at this start (3.8: the factory's
    -- first run, S.lib.factory, reads it)
    S.scene_file.start_outcome = outcome
    if outcome == "unreadable" or outcome == "older" then
      S.lib.ui_flash.start("hints", "scenes " .. outcome .. " (SETUP)", SCENE_LOAD.start_flash_seconds)
    end
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
    S.lib.clocks.cancel(sequencer_handle)  -- the script ends: at once, whatever its wait
    if params.lookup["scene_sequencer_enabled"] then params:set("scene_sequencer_enabled", 0) end
    scene_sequencer_stop()
  end)

  -- Cancel any active transition clock (at once, whatever its wait: the
  -- script ends)
  S.register_cleanup(S.constants.CLEANUP_ORDER.scene_transition, function()
    S.lib.clocks.cancel(transition_handle)
    cancel_scene_transition()
  end)

  -- A fade runs exactly while its next step is due, it has a target, a
  -- step applied last and its released set (3.8), and no transition clock
  -- outlives the fade
  S.register_invariant("scene transition", function()
    local due = S.SCENE_TRANSITION.next_step_due
    if S.scene_transition_active ~= (due ~= nil) then
      return "scene_transition_active is " .. tostring(S.scene_transition_active)
        .. " but next_step_due is " .. tostring(due)
    end
    local target = S.SCENE_TRANSITION.target
    if (target ~= nil) ~= S.scene_transition_active then
      return "scene_transition_active is " .. tostring(S.scene_transition_active)
        .. " but SCENE_TRANSITION.target is " .. tostring(target)
    end
    local step = S.SCENE_TRANSITION.step
    if (step ~= nil) ~= S.scene_transition_active then
      return "scene_transition_active is " .. tostring(S.scene_transition_active)
        .. " but SCENE_TRANSITION.step is " .. tostring(step)
    end
    local released = S.SCENE_TRANSITION.released
    if (type(released) == "table") ~= S.scene_transition_active then
      return "scene_transition_active is " .. tostring(S.scene_transition_active)
        .. " but SCENE_TRANSITION.released is " .. tostring(released)
    end
    if not S.scene_transition_active and S.scene_transition_clock ~= nil then
      return "no transition is active but scene_transition_clock is " .. tostring(S.scene_transition_clock)
    end
  end)

  -- A user's save: capture, write scenes.data at once (a crash, a power cut
  -- or ;restart no longer loses it, #327), say in the header whether the
  -- scene is on disk, redraw. capture_scene stays silent for the callers
  -- that are not a save.
  function M.save(scene_num)
    if type(scene_num) ~= "number" or scene_num % 1 ~= 0
      or scene_num < 1 or scene_num > NUM_SCENES then
      return false
    end
    capture_scene(scene_num)
    header_flash(M.autosave() and ("saved " .. M.label(scene_num)) or (M.label(scene_num) .. " not on disk"))
    grid_redraw()
    request_redraw()
    return true
  end

  -- The bank a slot is in (a bank is only a view of SCENE_BANK_SIZE slots,
  -- design Question 15): 1 for slots 1-8, 2 for 9-16; nil for a number
  -- that is no slot
  function M.bank_of(slot)
    if not is_integer_between(slot, 1, NUM_SCENES) then return nil end
    return math.ceil(slot / S.constants.SCENE_BANK_SIZE)
  end

  -- A slot's name: "" for none, and for a number that is no slot
  function M.name(slot)
    if not is_integer_between(slot, 1, NUM_SCENES) then return "" end
    return S.scenes[slot].name
  end

  -- How a flash names a slot (design §9.3): "S3 dusk" for a named slot,
  -- "S3" for one with no name and for a number that is no slot. The
  -- quantizer's label stays "S" .. slot, so "S16 at bar" always fits
  function M.label(slot)
    local name = M.name(slot)
    if name == "" then return "S" .. tostring(slot) end
    return "S" .. slot .. " " .. name
  end

  -- Name a slot, empty or not (the name stays with the slot; a capture
  -- keeps it): text's printable ASCII characters, cut to SCENE_NAME_MAX. A
  -- changed name raises the slot's revision and is written at once, as a
  -- save is (autosave, #327). False for a number that is no slot or a text
  -- that is no string (nothing changes), else true
  function M.set_name(slot, text)
    if not is_integer_between(slot, 1, NUM_SCENES) or type(text) ~= "string" then return false end
    local name = text:gsub("[^\32-\126]", ""):sub(1, S.constants.SCENE_NAME_MAX)
    if name == S.scenes[slot].name then return true end
    S.scenes[slot].name = name
    raise_revision(slot)
    S.scene_file.pset = nil  -- no PSET holds these scenes now
    M.autosave()
    request_redraw()
    return true
  end

  -- The scene a running fade goes to, else nil
  function M.fading_to()
    if S.scene_transition_active then return S.SCENE_TRANSITION.target end
    return nil
  end

  -- Let go of a voice in the running fade (3.8, design §8.3, ruling 45): a
  -- voice preset's load or copy takes the voice out of the fade's steps
  -- and its landing, so the fade never pulls the loaded sound back. True
  -- only while a fade runs; false (nothing changes) otherwise and for a
  -- number that is no voice
  function M.release_voice(voice_idx)
    if not is_integer_between(voice_idx, 1, NUM_VOICES) then return false end
    local released = S.SCENE_TRANSITION.released
    if not (S.scene_transition_active and released) then return false end
    released[voice_idx] = true
    return true
  end

  -- Whether the displays light `slot` as the current scene: the scene a fade
  -- goes to blinks, shown after its odd steps and dark after its even ones,
  -- and is steady once it lands (#254). It is lit from the recall: while
  -- step 1 sets its params no step is applied yet. The header, SCENES and
  -- the grids' recall keys all ask this
  function M.shows_current(slot)
    if slot ~= S.current_scene then return false end
    if M.fading_to() ~= slot then return true end
    local step = S.SCENE_TRANSITION.step
    return step == nil or step % 2 == 1
  end

  -- The slot the running scene sequencer recalls next, else nil (#303).
  -- Until it recalls its position, after its start and after each advance
  -- (S.scene_sequencer_recall_due), the count starts at the position, as
  -- its loop's guard reads it (1 past the sequence length). From then on,
  -- through the scene's hold, the position is the scene playing, and the
  -- count starts at the one after it, wrapped to 1 past the sequence length
  -- as it is now, as the advance does. Empty and invalid slots are skipped,
  -- as the loop skips them (#513, #754): it is the first playable slot from
  -- there, or that slot itself when none of the sequence plays. The grids'
  -- scene pages light it at 10. 3.7: once a pass has drawn its next slot
  -- (S.scene_sequencer_next), it is that slot, kept while it can still play
  -- (kept_next_scene); the reckoning above stands before the first draw and
  -- with no playable scene in the sequence
  function M.sequencer_next_slot()
    if not S.scene_sequencer_enabled then return nil end
    local length = params:get("scene_sequence_length")
    local position, due = S.scene_sequencer_position, S.scene_sequencer_recall_due
    if not due then
      local kept = kept_next_scene(length)
      if kept ~= nil then return kept end
    end
    if due and plays(position, length) then return position end
    local next_slot = following(position, M.playable_slots(1, length))
    if next_slot ~= nil then return next_slot end
    next_slot = due and position or position + 1
    if next_slot > length then next_slot = 1 end
    return next_slot
  end

  -- A recall is due and a next slot kept (3.7) only while the sequencer
  -- runs, and the sequencer runs exactly while its clock lives (#329): an
  -- id is held, and norns' clock.threads (which keeps a coroutine an error
  -- ended) does not show it dead
  S.register_invariant("scene sequencer", function()
    if S.scene_sequencer_recall_due and not S.scene_sequencer_enabled then
      return "scene_sequencer_recall_due is true but the sequencer is off"
    end
    if S.scene_sequencer_next ~= nil and not S.scene_sequencer_enabled then
      return "scene_sequencer_next is " .. tostring(S.scene_sequencer_next) .. " but the sequencer is off"
    end
    if S.scene_sequencer_enabled ~= (S.scene_sequencer_clock ~= nil) then
      return "scene_sequencer_enabled is " .. tostring(S.scene_sequencer_enabled)
        .. " but scene_sequencer_clock is " .. tostring(S.scene_sequencer_clock)
    end
    local thread = S.scene_sequencer_clock and clock.threads and clock.threads[S.scene_sequencer_clock]
    if type(thread) == "thread" and coroutine.status(thread) == "dead" then
      return "the scene sequencer is on but its clock " .. tostring(S.scene_sequencer_clock) .. " has ended"
    end
  end)

  M.scene_data_dir = scene_data_dir
  M.move_aside_unloadable_file = move_aside_unloadable_file
  M.set_value = set_scene_value  -- morph sets its continuous values as a transition's step does
  return M
end

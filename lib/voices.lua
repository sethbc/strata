-- lib/voices.lua
-- The voices: their definitions (S.voices, built fresh by each script load),
-- which voices are locked (S.locked), the master density, the selected voice,
-- and the global helpers that test a voice's grain source (exactly one of
-- voice_uses_synth, voice_uses_buffer, voice_uses_input and, 3.8,
-- voice_uses_voice holds for a voice). strata.lua runs
-- `S.lib.voices = include("lib/voices")(S)`; the constructor sets its S
-- fields itself, and its table (S.lib.voices) holds is_synth_key(voice_idx,
-- key). A voice is {name, active, source, param_order, values}: values holds
-- every value of the voice by key, its param id without "v<i>_"; name and
-- param_order are its current voice type's key and synth keys (3.8: the
-- v<i>_type param, set at init and by every type change; lib/types.lua).

return function(S)
  local M = {}

  local NUM_VOICES = S.constants.NUM_VOICES
  local SOURCE_SYNTH = S.constants.SOURCE_SYNTH
  local SOURCE_INPUT = S.constants.SOURCE_INPUT
  local SOURCE_VOICE_FIRST = S.constants.SOURCE_VOICE_FIRST
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS

  -- State. A voice's synth values (every type's keys) and its name and
  -- param_order (its current type's key and keys) are the synth record's,
  -- set at init (below): nil before it, so nothing reads them at include
  -- time. The grain defaults that differ by voice: size, density and spread
  local GRAIN_DEFAULTS = {
    {grain_size = 0.1, grain_density = 20, grain_spread = 0.5},
    {grain_size = 0.15, grain_density = 15, grain_spread = 0.3},
    {grain_size = 0.08, grain_density = 25, grain_spread = 0.4},
    {grain_size = 0.2, grain_density = 10, grain_spread = 0.2},
    {grain_size = 0.12, grain_density = 18, grain_spread = 0.35},
    {grain_size = 0.08, grain_density = 22, grain_spread = 0.25},
    {grain_size = 0.1, grain_density = 20, grain_spread = 0.4},
  }
  -- every voice's other grain, buffer and crossmod defaults
  local SHARED_DEFAULTS = {
    grain_pitch = 1,
    grain_mode = 1,  -- GRAIN_MODE_OPTIONS index
    buf_pos = 0,  -- buffer sources: position in the valid region (0-1)
    buf_rate = 1,
    buf_scan = 0,
    mod_source_1 = 0, mod_amp_amt_1 = 0, mod_freq_amt_1 = 0,  -- a source: 0 = none, 1-7 = voice number
    mod_source_2 = 0, mod_amp_amt_2 = 0, mod_freq_amt_2 = 0,
    mod_source_3 = 0, mod_amp_amt_3 = 0, mod_freq_amt_3 = 0,
    mod_speed = 10,
  }
  S.voices = {}
  for voice_idx = 1, NUM_VOICES do
    -- every value of the voice, by key (its param id without v<i>_): the
    -- grain and buffer params and crossmod here; the synth record adds
    -- every type's synth keys, lib/params_setup.lua each registered record's
    local values = {}
    for key, value in pairs(SHARED_DEFAULTS) do values[key] = value end
    for key, value in pairs(GRAIN_DEFAULTS[voice_idx]) do values[key] = value end
    S.voices[voice_idx] = {active = false, source = SOURCE_SYNTH, values = values}  -- source: a SOURCE_OPTIONS index
  end

  -- A voice's grain source: its synth, a buffer slot, the live input, or
  -- (3.8) a voice's output ring, another's or its own. Exactly one holds
  function voice_uses_synth(voice_idx)
    return S.voices[voice_idx].source == SOURCE_SYNTH
  end

  function voice_uses_buffer(voice_idx)
    local source = S.voices[voice_idx].source
    return source > SOURCE_SYNTH and source < SOURCE_INPUT
  end

  -- (the 3.8 tests below take any index: one that is no voice, 1..NUM_VOICES,
  -- is no input voice, no voice source and an empty label, never an error;
  -- the grid's keys call them)
  local function source_of(voice_idx)
    local voice = type(voice_idx) == "number" and S.voices[voice_idx] or nil
    return voice and voice.source or nil
  end

  function voice_uses_input(voice_idx)
    return source_of(voice_idx) == SOURCE_INPUT
  end

  function voice_uses_voice(voice_idx)
    local source = source_of(voice_idx)
    return source ~= nil and source >= SOURCE_VOICE_FIRST and source < SOURCE_VOICE_FIRST + NUM_VOICES
  end

  -- The voice (1..NUM_VOICES) a voice-source voice reads, or nil
  function voice_source_voice(voice_idx)
    if not voice_uses_voice(voice_idx) then return nil end
    return source_of(voice_idx) - SOURCE_VOICE_FIRST + 1
  end

  -- The source's short name: the option's, or v<j> for a voice source
  -- (MAIN's and BUFFER's, design §12); "" for no voice
  function voice_source_label(voice_idx)
    local read = voice_source_voice(voice_idx)
    if read then return "v" .. read end
    return SOURCE_OPTIONS[source_of(voice_idx)] or ""
  end

  -- The buffer slot (1..NUM_BUFFERS) a buffer-sourced voice reads, or nil for
  -- the synth and input sources
  function voice_buffer_slot(voice_idx)
    if not voice_uses_buffer(voice_idx) then return nil end
    return S.voices[voice_idx].source - SOURCE_SYNTH
  end

  S.selected_voice = 1
  S.locked = {}
  for i = 1, NUM_VOICES do
    S.locked[i] = false
  end

  -- Whether key is one of voice voice_idx's current type's synth params
  -- (its param_order; false for a number that is no voice, and before
  -- init). A synth-key test goes through it, never values[key] ~= nil: a
  -- voice's values hold every key of its params, every type's synth keys,
  -- the grain, crossmod and registered ones too
  function M.is_synth_key(voice_idx, key)
    local voice = type(voice_idx) == "number" and S.voices[voice_idx]
    if not voice or not voice.param_order then return false end
    for _, synth_key in ipairs(voice.param_order) do
      if synth_key == key then return true end
    end
    return false
  end

  -- The built-in per-voice params (the groundwork before 3.8, rulings 10
  -- to 15): three S.register_voice_params records, registered here, the
  -- first module that can, so they come first in the menu, the sends, the
  -- scene keys and the faders. Their adds run at init, through
  -- S.lib.params_setup.add_voice_param; get_param_spec, fader_page_count,
  -- voice_level_fader_keys and sync_voice_values_to_engine are globals of
  -- later modules, called only then
  do
    local NUM_MOD_SLOTS = S.constants.NUM_MOD_SLOTS
    local GRAIN_MODE_OPTIONS = S.constants.GRAIN_MODE_OPTIONS
    local function add_param(...) S.lib.params_setup.add_voice_param(...) end
    local function option_index(x) return x - 1 end
    local function uses_synth(voice_idx) return voice_uses_synth(voice_idx) end
    local function uses_buffer(voice_idx) return voice_uses_buffer(voice_idx) end
    -- an input or voice-source voice: a ring another writer writes
    local function uses_ring(voice_idx) return voice_uses_input(voice_idx) or voice_uses_voice(voice_idx) end
    -- a voice's synth keys but those listed in `except`
    local function synth_keys_but(except)
      return function(voice_idx)
        local keys = {}
        for _, key in ipairs(S.voices[voice_idx].param_order) do
          if not except[key] then keys[#keys + 1] = key end
        end
        return keys
      end
    end

    -- 3.8 (design §2.2, package 0d): every voice has every type's synth
    -- keys (S.lib.types.keys()), its default type's param_order first, then
    -- the rest in type order (so every 3.7.0 param keeps its place); a
    -- key's default is the default type's, else the first type's that has
    -- it. The voice's v<i>_type (added first, by add_first) picks its type:
    -- its name and param_order follow it, and only its keys show and reach
    -- the engine (reaches)
    local function default_type(voice_idx) return S.lib.types.record(S.lib.types.default_key(voice_idx)) end
    local function voice_synth_keys(voice_idx)
      local keys, listed = {}, {}
      local function take(key)
        if not listed[key] then
          listed[key] = true
          keys[#keys + 1] = key
        end
      end
      for _, key in ipairs(default_type(voice_idx).param_order) do take(key) end
      for _, key in ipairs(S.lib.types.keys()) do take(key) end
      return keys
    end
    local function synth_default(voice_idx, key)
      local own = default_type(voice_idx).defaults[key]
      if own ~= nil then return own end
      for _, record in ipairs(S.lib.types.list()) do
        if record.defaults[key] ~= nil then return record.defaults[key] end
      end
    end
    -- A key's formatter: its format string (three decimals where the step
    -- is finer than the default string's 0.01, #386), or nil
    local function synth_formatter(key)
      local format = S.lib.types.format(key)
      if not format then return nil end
      return function(param) return string.format(format, param:get()) end
    end

    -- The voice's fields follow its type: name its key, param_order a copy of its keys
    local function take_type(voice_idx, record)
      local order = {}
      for index, key in ipairs(record.param_order) do order[index] = key end
      S.voices[voice_idx].name = record.key
      S.voices[voice_idx].param_order = order
    end

    -- Show the voice's current type's synth params, hide the others
    local function show_type_keys(voice_idx)
      for _, key in ipairs(S.lib.types.keys()) do
        local param_id = "v" .. voice_idx .. "_" .. key
        if M.is_synth_key(voice_idx, key) then params:show(param_id) else params:hide(param_id) end
      end
    end

    -- Per voice, its heading separator's id (the text it was added with,
    -- lib/params_setup.lua's add_voice_params); its name follows the type
    local function heading_id(voice_idx) return "voice " .. voice_idx .. ": " .. S.lib.types.default_key(voice_idx) end

    -- The v<i>_type action (design §2.2, §2.3): the voice takes the type
    -- (its pending choice on VOICE canceled first: every path that sets
    -- the type cancels it, so the later act stands, ruling 63), shows its
    -- keys, renames its heading, sends setVoiceType always (a stopped
    -- voice's engine side records it), ends an undo holding a synth key
    -- of the voice, and, outside a recall, syncs a running voice once (a
    -- recall syncs after its last entry, lib/scenes.lua)
    local function type_changed(voice_idx, index)
      local record = S.lib.types.list()[index]
      S.lib.types.cancel(voice_idx)
      take_type(voice_idx, record)
      show_type_keys(voice_idx)
      if _menu and _menu.rebuild_params then _menu.rebuild_params() end
      local heading = params:lookup_param(heading_id(voice_idx))
      heading.name = "voice " .. voice_idx .. ": " .. record.name
      S.lib.engine_sync.send_voice_type(voice_idx)
      for _, key in ipairs(S.lib.types.keys()) do note_param_edit("v" .. voice_idx .. "_" .. key) end
      if S.voices[voice_idx].active and not S.scene_recall_in_progress then sync_voice_values_to_engine(voice_idx) end
      -- the grid fader list follows the type (its synth keys)
      if S.grid_voice_select == voice_idx then
        S.param_page = util.clamp(S.param_page, 1, fader_page_count(voice_idx))
      end
      update_voice_list()
      request_redraw()
      grid_redraw()
    end

    -- The voice's synth params (every type's keys, under the voice's
    -- heading, after v<i>_type): a control each with S.lib.types.spec and
    -- its default (synth_default), sent with setVoiceParam under its own
    -- name while the voice's type has it (reaches). MAIN's randomize draws
    -- all of the current type's but amp (uniform in the normalized range),
    -- the mutations move all but amp and pan, and the faders show them
    -- all, on a synth source only. A filtered key's own delta (the PARAMS
    -- menu's E3) is a turn (turn_on_own_delta, #318; this record's keys only)
    local synth_record
    synth_record = {
      name = "synth",
      synth_keys = true,  -- its scene keys are the type's synth keys (voice_scene_keys' synth flag, #840)
      count = function() return 1 + #S.lib.types.keys() end,  -- the type, then every key
      separator = false,
      add_first = function(voice_idx)
        local names = {}
        for index, record in ipairs(S.lib.types.list()) do names[index] = record.name end
        local default = default_type(voice_idx)
        take_type(voice_idx, default)
        params:add{
          type = "option",
          id = "v" .. voice_idx .. "_type",
          name = "type",
          options = names,
          default = default.index,
          action = function(x) type_changed(voice_idx, x) end,
        }
      end,
      add = function(voice_idx)
        for _, key in ipairs(voice_synth_keys(voice_idx)) do
          local spec = S.lib.types.spec(key)
          spec.default = synth_default(voice_idx, key)
          add_param(voice_idx, synth_record, key, {type = "control", name = key, controlspec = spec,
            formatter = synth_formatter(key)})
          S.lib.params_setup.turn_on_own_delta(key, "v" .. voice_idx .. "_" .. key)
        end
        show_type_keys(voice_idx)
      end,
      voice_keys = function()
        local keys = {}
        for _, key in ipairs(S.lib.types.keys()) do keys[key] = key end
        return keys
      end,
      reaches = function(voice_idx, key) return M.is_synth_key(voice_idx, key) end,
      -- a scene holds its own type's keys (nil: the voice's current type; a
      -- type this build lacks, none)
      scene_keys = function(voice_idx, type_key)
        local record = S.lib.types.record(type_key or S.voices[voice_idx].name)
        return record and record.param_order or {}
      end,
      -- VOICE's synth section: the current type's keys but amp and pan (the
      -- mix section's), or a buffer voice's buffer params; none for an input
      -- or voice-source voice
      voice_rows = {section = "synth", before = "mix", rows = function(voice_idx)
        if voice_uses_synth(voice_idx) then return synth_keys_but({amp = true, pan = true})(voice_idx) end
        if voice_uses_buffer(voice_idx) then return {"buf_pos", "buf_rate", "buf_scan"} end
        return {}
      end},
      fader = {{keys = function(voice_idx) return S.voices[voice_idx].param_order end, when = uses_synth}},
      main_randomize = {{keys = synth_keys_but({amp = true}), when = uses_synth,
        draw = function(_, _, param_id) return params:lookup_param(param_id).controlspec:map(math.random()) end}},
      mutate = {{keys = synth_keys_but({amp = true, pan = true}), when = uses_synth, warped = true}},
    }

    -- The source (an option: always sent, so the engine knows it before
    -- the voice starts; it is a voice field, no value) and the eight grain
    -- and buffer params, under "granular", sent with setGrainParam in their
    -- fixed order. The mode is an option index (discrete, sent as index -
    -- 1, no start value). MAIN's randomize draws the buffer params on a
    -- buffer source, then grain size and pitch; the mutations move the
    -- buffer params on a buffer source, then grain size, pitch and spread.
    -- The faders: a buffer source's buffer params, level and pan, then the
    -- grain params with 3.8's window shape and skew (lib/grain.lua's keys,
    -- where 3.7's envelope was: ruling 31), then an input or voice
    -- source's level and pan
    local BUFFER_DRAWS = {
      buf_pos = function() return math.random() end,
      buf_rate = function() return 2 ^ (math.random() * 2 - 1) end,  -- 0.5-2, even in octaves
      buf_scan = function() return math.random() - 0.5 end,          -- a gentle scan
    }
    local GRAIN_DRAWS = {
      grain_size = function() return math.random() * 0.3 + 0.05 end,
      grain_pitch = function() return math.random() * 2 + 0.5 end,
    }
    local function drawn_by(draws) return function(_, key) return draws[key]() end end
    local function buffer_and_level_keys(voice_idx)
      local keys = {"buf_pos", "buf_rate", "buf_scan"}
      for _, key in ipairs(voice_level_fader_keys(voice_idx)) do keys[#keys + 1] = key end
      return keys
    end
    local grain_record
    grain_record = {
      name = "grain",
      count = 9,
      separator = "granular",
      add = function(voice_idx)
        local voice = S.voices[voice_idx]
        local values = voice.values
        params:add{
          type = "option",
          id = "v" .. voice_idx .. "_source",
          name = "source",
          options = SOURCE_OPTIONS,
          default = voice.source,
          action = function(x)
            S.voices[voice_idx].source = x
            S.lib.engine_sync.send_grain_source(voice_idx)
            -- the registered hooks (S.registry.source_change), before the
            -- sync, so it sends what they set (freeze cleared, never the old
            -- freeze first); a scene recall sets every value itself, so they
            -- never run during one
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
        -- step 0: the drift moves in steps far smaller than 0.01
        add_param(voice_idx, grain_record, "buf_pos", {type = "control", name = "buffer position",
          controlspec = controlspec.new(0, 1, "lin", 0, values.buf_pos),
          action = function(x) if not S.drift_writing then S.buf_pos_base[voice_idx] = x end end})
        -- step 0 (#679): the own note of a MIDI or sequenced note plays the
        -- exact rate, as its chord's extra notes do; a turn's size is the
        -- quantum (0.01 of the range), never the step
        add_param(voice_idx, grain_record, "buf_rate", {type = "control", name = "buffer rate",
          controlspec = controlspec.new(0.25, 4, "exp", 0, values.buf_rate)})
        add_param(voice_idx, grain_record, "buf_scan", {type = "control", name = "buffer scan",
          controlspec = controlspec.new(-2, 2, "lin", 0.01, values.buf_scan)})
        add_param(voice_idx, grain_record, "grain_size", {type = "control", name = "grain size",
          controlspec = controlspec.new(0.01, 0.5, "lin", 0.01, values.grain_size, "s")})
        add_param(voice_idx, grain_record, "grain_density", {type = "control", name = "grain density",
          controlspec = controlspec.new(1, 100, "lin", 1, values.grain_density, "/s")})
        -- step 0: the drift moves in steps far smaller than 0.01
        add_param(voice_idx, grain_record, "grain_pitch", {type = "control", name = "grain pitch",
          controlspec = controlspec.new(0.25, 4, "lin", 0, values.grain_pitch, "x"),
          action = function(x) if not S.drift_writing then S.grain_pitch_base[voice_idx] = x end end})
        add_param(voice_idx, grain_record, "grain_spread", {type = "control", name = "position spread",
          controlspec = controlspec.new(0, 1, "lin", 0.01, values.grain_spread)})
        add_param(voice_idx, grain_record, "grain_mode", {type = "option", name = "grain mode",
          options = GRAIN_MODE_OPTIONS, default = values.grain_mode})
      end,
      grain_keys = {
        grain_size = "grainSize",
        grain_density = {name = "grainDensity", value = function(x) return x * engine_param_value("master_density") end},
        grain_pitch = "pitchShift",
        grain_spread = "posSpread",
        grain_mode = {name = "grainMode", value = option_index, carry = false},
        buf_pos = "bufPos",
        buf_rate = "bufRate",
        buf_scan = "bufScan",
      },
      send_order = {"grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_mode",
        "buf_pos", "buf_rate", "buf_scan"},
      discrete = {grain_mode = {1, #GRAIN_MODE_OPTIONS}},
      scene_keys = true,  -- every value its add added (the source is a voice field)
      voice_rows = {section = "grain", before = "mix",
        rows = {"grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_mode"}},
      fader = {
        {keys = buffer_and_level_keys, when = uses_buffer},
        {keys = {"grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_shape", "grain_skew", "grain_mode"}},
        {keys = function(voice_idx) return voice_level_fader_keys(voice_idx) end, when = uses_ring},
      },
      main_randomize = {
        {keys = {"buf_pos", "buf_rate", "buf_scan"}, when = uses_buffer, draw = drawn_by(BUFFER_DRAWS)},
        {keys = {"grain_size", "grain_pitch"}, draw = drawn_by(GRAIN_DRAWS)},
      },
      mutate = {
        {keys = {"buf_pos", "buf_rate", "buf_scan"}, when = uses_buffer, warped = true},
        {keys = {"grain_size"}, chance = 0.5, scale = 0.2, warped = false},
        {keys = {"grain_pitch"}, chance = 0.3, scale = 1.0, warped = false},
        {keys = {"grain_spread"}, chance = 0.2, scale = 0.3, warped = false},
      },
    }

    -- Cross-modulation: per slot (1..NUM_MOD_SLOTS) its source (a number,
    -- 0 = none, 1-7 a voice; discrete), amp mod and freq mod, in that order
    -- (the ids, names and menu order saved PSETs hold), then the speed, all
    -- sent after voiceOn with their own commands and no start value. The
    -- faders show the nine slot values
    local function mod_source_text(param)
      if param:get() == 0 then return "none" end
      return "voice " .. param:get()
    end
    local crossmod_keys, crossmod_order, crossmod_discrete, crossmod_faders = {}, {}, {}, {}
    local crossmod_rows = {"mod_speed"}  -- VOICE's crossmod section: the speed, then per slot its three
    for slot = 1, NUM_MOD_SLOTS do
      local source, amp, freq = "mod_source_" .. slot, "mod_amp_amt_" .. slot, "mod_freq_amt_" .. slot
      crossmod_keys[source] = {carry = false, send = function(voice_idx, x)
        engine.setModSource(voice_idx - 1, slot, S.lib.engine_sync.engine_mod_source(x))
      end}
      crossmod_keys[amp] = {carry = false, send = function(voice_idx, x) engine.setModAmpAmt(voice_idx - 1, slot, x) end}
      crossmod_keys[freq] = {carry = false, send = function(voice_idx, x) engine.setModFreqAmt(voice_idx - 1, slot, x) end}
      crossmod_discrete[source] = {0, NUM_VOICES}
      for _, key in ipairs({source, amp, freq}) do
        crossmod_order[#crossmod_order + 1] = key
        crossmod_faders[#crossmod_faders + 1] = key
        crossmod_rows[#crossmod_rows + 1] = key
      end
    end
    crossmod_keys.mod_speed = {carry = false, send = function(voice_idx, x) engine.setModSpeed(voice_idx - 1, x) end}
    crossmod_order[#crossmod_order + 1] = "mod_speed"
    local crossmod_record
    crossmod_record = {
      name = "crossmod",
      count = 3 * NUM_MOD_SLOTS + 1,
      separator = "cross-modulation",
      add = function(voice_idx)
        local values = S.voices[voice_idx].values
        for slot = 1, NUM_MOD_SLOTS do
          add_param(voice_idx, crossmod_record, "mod_source_" .. slot, {type = "number", name = "mod source " .. slot,
            min = 0, max = NUM_VOICES, default = values["mod_source_" .. slot], formatter = mod_source_text})
          add_param(voice_idx, crossmod_record, "mod_amp_amt_" .. slot, {type = "control", name = "amp mod " .. slot,
            controlspec = controlspec.new(-2, 2, "lin", 0.01, values["mod_amp_amt_" .. slot])})
          add_param(voice_idx, crossmod_record, "mod_freq_amt_" .. slot, {type = "control", name = "freq mod " .. slot,
            controlspec = controlspec.new(-2, 2, "lin", 0.01, values["mod_freq_amt_" .. slot])})
        end
        -- one speed for every slot
        add_param(voice_idx, crossmod_record, "mod_speed", {type = "control", name = "mod speed",
          controlspec = controlspec.new(0.1, 50, "exp", 0.1, values.mod_speed, "Hz")})
      end,
      voice_keys = crossmod_keys,
      send_order = crossmod_order,
      discrete = crossmod_discrete,
      scene_keys = true,
      voice_rows = {section = "crossmod", before = "mix", rows = crossmod_rows},
      fader = {{keys = crossmod_faders}},
    }

    S.register_voice_params(synth_record)
    S.register_voice_params(grain_record)
    S.register_voice_params(crossmod_record)
  end

  return M
end

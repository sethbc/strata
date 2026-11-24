-- lib/state.lua
-- The table S that strata.lua and its modules share: the registries, the
-- module tables (S.lib) and the script-level state that more than one
-- module uses. The one module constructor that takes no argument:
-- strata.lua runs `local S = include("lib/state")()`. Every call builds a
-- fresh table, so a script reload (which runs strata.lua again) never keeps
-- state from the previous run

return function()
  local M = {}

  -- Every key ever assigned into S, even to nil (a clock that is not
  -- running): M.__declared[name] = true. The test harness finds such a
  -- name in S while its value is nil. Assigning to a key that holds a value
  -- skips __newindex, but that key was recorded when it was first set
  rawset(M, "__declared", {})
  setmetatable(M, {
    __newindex = function(table, key, value)
      rawget(table, "__declared")[key] = true
      rawset(table, key, value)
    end,
  })

  -- Registries modules add to as they load. Their readers read them at
  -- init (inside a params record's add or later), never at include time, so
  -- a module that registers can be included before or after its reader
  M.registry = {
    pages = {},         -- one record per screen page
    io_sections = {},   -- 3.6: IO's sections {name, title, rows, status, layout_states} (register_io_section)
    params = {},        -- param-adding functions, run by init in order
    start = {},         -- {order, fn} records, run by init() by order
    cleanup = {},       -- {order, fn} records, run by cleanup() by order
    grid_layouts = {},  -- per grid layout ("256", "128h", ...), its {key, redraw, panes, pane_at, start_pages}
    grid_pages = {},    -- 3.8: per grid page index, its {name, index, press, redraw, sides?, faders?, signature?}
    voice_params = {},  -- per-voice param records (register_voice_params), in registration order
    scene_fields = {},  -- global scene fields {id, default, discrete} (register_scene_field)
    source_change = {}, -- fn(voice_idx, source), run by each v<i>_source action before its sync, never in a scene recall
    param_filters = {}, -- per voice param key: fn(voice_idx, value, previous, turned) -> value
    lfo_destinations = {},  -- per-voice LFO destinations {label, suffix}, each in its voice's group
    fx_params = {},     -- fx group records {name, count, add}, after the group's own params
    grain_restart = {}, -- fn(voice_idx, reason), run by lib/engine_sync.lua after a voiceOn ("start") and a running voice's source switch ("source")
    alt_release = {},   -- fn(), run when ALT goes from held to not held
    menu_close = {},    -- fn(), run after the norns menu closes (lib/ui/menu_watch.lua)
    invariants = {},    -- {name, fn} records, checked by the test harness after every unit test
    -- 3.4's (design §0.1, §8.10, §10.1)
    scene_blocks = {},      -- top-level scene blocks {key, default, capture, validate, apply, discrete, through_zero}
    pset_hooks = {},        -- {name, write, read, delete}, run by the PSET actions (lib/params_setup.lua) and six by a factory set's load
    param_touch = {},       -- fn(param_id, source), run after an encoder, arc or grid edit of a param
    lock_change = {},       -- fn(voice_idx, locked), run after a voice's lock flips
    step_outputs = {},      -- {name, play, stop, available}, each pattern hit's outputs
    mod_sources = {},       -- modulation sources {key, name, section, value, range, describe, visible, row}
    -- 3.5's (design §0.1)
    voice_stop = {},        -- fn(voice_idx), run after every engine.voiceOff the script sends
    freeze_change = {},     -- fn(voice_idx, frozen), run by every v<i>_freeze action
    -- 3.6's (design §0.1), read at each use
    note_hooks = {},        -- {name, started, ended, moved, expressed, heard}, run by lib/notes.lua (heard: lib/midi_in.lua)
    scene_recalled = {},    -- fn(scene_num), run once per scene recall (lib/scenes.lua)
    silence_change = {},    -- fn(voice_idx, silenced), run as a mute or solo changes silenced(voice)
    note_targets = {},      -- {name, routed, note_on, note_off, express, stop_all, rows, status}
    ii_devices = {},        -- {name, ports, ready, release, param_count, add_params}
    macro_targets = {},     -- {id, label}: control params the macros offer after the matrix depths
    -- 3.7's (design §0.2), read at each use
    voice_hit = {},         -- {name, hit = fn(voice_idx, info)}, told once per hit by lib/engine_sync.lua
    scene_applied = {},     -- {name, fn = fn()}, run once by every apply_entries after its flag clears (lib/scenes.lua)
    -- 3.8's (design §2.1), read at init
    voice_types = {},       -- the voice types (register_voice_type), in type order: lib/types/<key>.lua, S.lib.types
  }

  -- The registries init reads once (voice_params, scene_fields,
  -- lfo_destinations, fx_params, start, menu_close, scene_blocks,
  -- pset_hooks, voice_types) are closed when init begins to read them
  -- (close_registries, called by the first params record, "performance"): a
  -- registration after that is never used, so its register function raises,
  -- naming the registry (#384). The others are read at each use and stay open
  local closed = {}
  local INIT_READ = {"voice_params", "scene_fields", "lfo_destinations", "fx_params", "start", "menu_close",
    "scene_blocks", "pset_hooks", "voice_types"}

  function M.close_registries()
    for _, name in ipairs(INIT_READ) do closed[name] = true end
  end

  -- A registration is refused once its registry is closed; the error
  -- points at the registering module's line (level 3)
  local function require_open(registry, kind)
    if closed[registry] then
      error(kind .. ": the " .. registry .. " registry is read at init and closed; register at include time", 3)
    end
  end

  -- Add an {order, fn} record to one of the ordered registries (start or
  -- cleanup). Two steps never share an order (table.sort is not stable, so a
  -- tie would run in no fixed order)
  local function register_step(steps, kind, order, fn)
    if steps == M.registry.start then require_open("start", "register_start") end
    assert(type(order) == "number", "a " .. kind .. " step needs a number order")
    assert(type(fn) == "function", "a " .. kind .. " step needs a function")
    for _, record in ipairs(steps) do
      assert(record.order ~= order, "two " .. kind .. " steps at order " .. order)
    end
    steps[#steps + 1] = {order = order, fn = fn}
  end

  -- Each module adds one start step per thing it must start: init() in
  -- strata.lua runs fn of every record in ascending order, after the params
  -- are added and their actions wrapped. The orders are
  -- S.constants.START_ORDER, so the whole sequence reads in one place
  function M.register_start(order, fn)
    register_step(M.registry.start, "start", order, fn)
  end

  -- Each module adds one cleanup step per thing it must stop or save on
  -- exit: cleanup() in strata.lua runs fn of every record in ascending
  -- order. The orders are S.constants.CLEANUP_ORDER
  function M.register_cleanup(order, fn)
    register_step(M.registry.cleanup, "cleanup", order, fn)
  end

  -- Argument checks for the register functions below: the error points at
  -- the registering module's line (level 3: the register function's caller)
  local function require_arg(condition, kind, message)
    if not condition then error(kind .. ": " .. message, 3) end
  end

  local function is_whole(value, least)
    return type(value) == "number" and value == math.floor(value) and value >= least
  end

  -- Whether every entry of a table passes check(key, value); nil passes
  local function all_entries(entries, check)
    if entries == nil then return true end
    if type(entries) ~= "table" then return false end
    for key, value in pairs(entries) do
      if not check(key, value) then return false end
    end
    return true
  end

  local function name_taken(records, field, name)
    for _, record in ipairs(records) do
      if record[field] == name then return true end
    end
    return false
  end

  -- A record holds only the fields of its documented set; a misspelled
  -- optional field would be ignored without a word (#385)
  local function require_known_fields(record, allowed, where)
    for field in pairs(record) do
      require_arg(allowed[field], where, "unknown field " .. tostring(field))
    end
  end

  local VOICE_PARAM_FIELDS = {name = true, count = true, add = true, add_first = true, grain_keys = true,
    voice_keys = true, send_order = true, separator = true, sync = true, scene_defaults = true, discrete = true,
    scene_ranges = true, voice_rows = true, layout_states = true, normalize_scene = true, fader = true,
    main_randomize = true, mutate = true, randomize = true, reaches = true, scene_keys = true,
    synth_keys = true}
  local SCENE_FIELD_FIELDS = {id = true, default = true, discrete = true, set = true}
  local FX_PARAM_FIELDS = {name = true, count = true, add = true}

  -- A grain key: an engine name, or {name, value = fn, carry = false}
  local function is_grain_key(key, value)
    return type(key) == "string" and (type(value) == "string" or (type(value) == "table"
      and type(value.name) == "string" and (value.value == nil or type(value.value) == "function")
      and (value.carry == nil or value.carry == false)))
  end

  -- A voice key: an engine name, {name, value = fn, carry = false} (both
  -- setVoiceParam) or {send = fn(voice_idx, value), carry = false}
  local function is_voice_key(key, value)
    if type(value) == "table" and value.name == nil then
      return type(key) == "string" and type(value.send) == "function" and (value.carry == nil or value.carry == false)
    end
    return is_grain_key(key, value)
  end

  -- A record's fader, main_randomize or mutate groups: nil, or a list of
  -- tables, each with keys (a list of key strings, or a function of the
  -- voice that gives one) and an optional when = fn(voice_idx), and the
  -- fields check(group) accepts
  local function valid_groups(groups, check)
    if groups == nil then return true end
    if type(groups) ~= "table" then return false end
    return all_entries(groups, function(_, group)
      if type(group) ~= "table" or (group.when ~= nil and type(group.when) ~= "function") then return false end
      local keys = group.keys
      if type(keys) ~= "function" and not (type(keys) == "table"
        and all_entries(keys, function(_, key) return type(key) == "string" end)) then return false end
      return check(group)
    end)
  end
  local function is_chance(value) return value == nil or (type(value) == "number" and value >= 0 and value <= 1) end
  local function fader_group(group) return group.rank == nil or type(group.rank) == "number" end
  local function randomize_group(group) return type(group.draw) == "function" end
  local function mutate_group(group)
    return is_chance(group.chance) and (group.scale == nil or type(group.scale) == "number")
      and (group.warped == nil or type(group.warped) == "boolean")
  end

  -- A record's voice keys for voice voice_idx: its voice_keys table, the
  -- table its voice_keys function gives for the voice, or {}
  function M.voice_keys_of(record, voice_idx)
    local keys = record.voice_keys
    if type(keys) == "function" then return keys(voice_idx) end
    return keys or {}
  end

  -- A record's count for voice voice_idx: its count, or what its count
  -- function gives for the voice
  function M.voice_param_count(record, voice_idx)
    if type(record.count) == "function" then return record.count(voice_idx) end
    return record.count
  end

  -- Whether send_order names each of a record's sent keys (its grain keys
  -- and the voice's voice keys) exactly once
  local function covers_sent_keys(order, grain_keys, voice_keys)
    local listed, count = {}, 0
    for _, key in ipairs(order) do
      if type(key) ~= "string" or listed[key] or not ((grain_keys or {})[key] or voice_keys[key]) then return false end
      listed[key], count = true, count + 1
    end
    for _, keys in ipairs({grain_keys or {}, voice_keys}) do
      for key in pairs(keys) do
        if not listed[key] then return false end
      end
    end
    return count == #order
  end

  -- A voice-param record's scene defaults for voice voice_idx: its
  -- scene_defaults table, the table its scene_defaults function gives for
  -- the voice, or {} when it has none
  function M.voice_scene_defaults(record, voice_idx)
    local defaults = record.scene_defaults
    if type(defaults) == "function" then return defaults(voice_idx) end
    if defaults == nil then return {} end
    return defaults
  end

  -- A voice-param record's checks for one voice (register_voice_params'
  -- per-voice part): its count, voice keys and send_order, and its scene
  -- defaults with the discrete and scene_ranges keys they hold, every
  -- voice's scene defaults holding voice 1's keys. Run by
  -- register_voice_params for a record whose fields are all tables, else
  -- at init by S.lib.params_setup (3.8, ruling 19). level: error's (0 at init)
  function M.check_voice_params(record, voice_idx, level)
    local where = "register_voice_params " .. tostring(record.name)
    local function check(condition, message)
      if not condition then error(where .. ": " .. message, level == 0 and 0 or level + 2) end
    end
    check(is_whole(M.voice_param_count(record, voice_idx), 1),
      "count is a whole number of params, at least 1, for voice " .. voice_idx)
    local voice_keys = M.voice_keys_of(record, voice_idx)
    check(type(voice_keys) == "table" and all_entries(voice_keys, is_voice_key),
      "voice_keys maps a key to an engine name, {name, value = fn, carry = false} or {send = fn, carry = false}")
    check(record.send_order == nil or covers_sent_keys(record.send_order, record.grain_keys, voice_keys),
      "send_order names each of its grain and voice keys once")
    -- scene_defaults is a table, or a function of the voice that gives one
    -- (3.7): each voice's table is checked, and all hold the same keys. A
    -- record without them (a built-in one) has its discrete keys' defaults
    -- checked at init (S.lib.params_setup's add_voice_params)
    local first = M.voice_scene_defaults(record, 1)
    local defaults = M.voice_scene_defaults(record, voice_idx)
    check(type(first) == "table" and type(defaults) == "table" and all_entries(defaults, function(key, value)
      return type(key) == "string" and type(value) == "number" and first[key] ~= nil
    end) and all_entries(first, function(key) return defaults[key] ~= nil end),
      "scene_defaults maps a key to a number (a function: for every voice, the same keys)")
    check(all_entries(record.discrete, function(key, range)
      local default = defaults[key]
      local whole_range = type(range) == "table" and is_whole(range[1], -math.huge) and is_whole(range[2], range[1])
      if record.scene_defaults == nil then return whole_range end
      return whole_range and is_whole(default, range[1]) and default <= range[2]
    end), "discrete maps a scene key to a whole {min, max} that holds its default")
    check(all_entries(record.scene_ranges, function(key, range)
      local default = defaults[key]
      return type(range) == "table" and type(range[1]) == "number" and type(range[2]) == "number"
        and range[1] <= range[2] and not (record.discrete and record.discrete[key])
        and type(default) == "number" and default >= range[1] and default <= range[2]
    end), "scene_ranges maps a continuous scene key to a {min, max} that holds its default")
  end

  -- A module's per-voice params (3.2: freeze, variation, loops, history,
  -- the voice filter and sends; the groundwork before 3.8: the built-in
  -- synth, grain and crossmod records, which lib/voices.lua registers
  -- first). The record's fields:
  --   name: unique; count: the params add adds per voice (checked at init),
  --     or a function of the voice that gives it;
  --   add = fn(voice_idx): adds them with S.lib.params_setup.add_voice_param;
  --   grain_keys: {key = "<engine name>" | {name, value = fn(x), carry =
  --     false}}, sent with setGrainParam by the param's sender and the voice
  --     sync (a start sends them before voiceOn);
  --   voice_keys: {key = "<engine name>" | {name, value = fn(x), carry =
  --     false} | {send = fn(voice_idx, x), carry = false}}, or a function of
  --     the voice that gives that table: sent with setVoiceParam (or the
  --     entry's send) by the param's sender and the voice sync (a start
  --     sends them after voiceOn). carry = false: a start sends the stored
  --     value, never the param's override and offsets;
  --   send_order: the order its grain and voice keys go out in, naming each
  --     once (default: sorted);
  --   separator: the menu separator its params sit under, the text after
  --     "voice <i> " (false: none; nil: "extras"), added before a record
  --     whose separator differs from the record's before it;
  --   sync: optional fn(voice_idx), the voice sync's sends after grain_keys;
  --     a start runs it before voiceOn, so it sends grain params only
  --     (setGrainParam): voiceOn resets the voice-level ones (#325);
  --   scene_defaults: {key = default} (each its param's default), or a
  --     function of the voice that gives that table (defaults that differ
  --     by voice; checked at init): the keys scenes capture into
  --     voices[i].values and fill_scene fills (a built-in record has none:
  --     its scene_keys name them, S.lib.params_setup.voice_scene_keys);
  --   discrete: {key = {min, max}} (whole values): set at a transition's
  --     end, after the source; every other scene key crossfades;
  --   scene_ranges: {key = {min, max}} for a continuous scene key:
  --     validate_scene rejects a scene whose value lies outside it;
  --   voice_rows: {section, rows = {key, ...}, when = fn(voice_idx, key),
  --     before = <section>}: VOICE's rows (lib/ui/voice_rows.lua);
  --   layout_states: {{name, setup = fn(context)}}: VOICE's layout tests draw them;
  --   fader: false or nil (none), or groups {keys = {key, ...} | fn(voice_idx),
  --     when = fn(voice_idx), rank = number (default 0)}: the voice's
  --     fader pages, by rank, then registration order (fader_param_ids); a
  --     group's keys may be any key added for the voice;
  --   main_randomize: groups {keys, when, draw = fn(voice_idx, key,
  --     param_id) -> value}: what MAIN's randomize_voice draws;
  --   mutate: groups {keys, when, chance (0-1, default 1), scale (default
  --     1), warped (default true: the step moves in the normalized range;
  --     false: delta x scale in the param's units)}: what gentle_mutate moves;
  --   randomize: {key = fn(voice_idx) -> value}: the keys a press of ALT+K2
  --     on their VOICE section randomizes, each with its draw (#557);
  --   3.8 (package 0d): reaches = fn(voice_idx, key) -> boolean: whether a
  --     key's sender reaches the engine now (the synth record's: the voice's
  --     type has the key, S.lib.voices.is_synth_key); a key it refuses is
  --     left out of the voice's engine parts and counts no engine message;
  --   scene_keys = true | {key, ...} | fn(voice_idx, type_key) -> {key, ...}:
  --     the scene keys of a record without scene_defaults, each default its
  --     param's at the call (true: every key its add added; a function: a
  --     voice's keys for a type key, the synth record's own type's); in
  --     place of scene_defaults;
  --   synth_keys = true (#840): on a scene_keys record, its scene keys are
  --     the voice type's synth keys, each entry of voice_scene_keys marked
  --     synth (the synth record alone);
  --   voice_rows.rows may be a function of the voice, and voice_rows.swaps
  --     = {[key] = fn(voice_idx) -> key | nil} replaces a row of the
  --     record's section by the key it gives (nil: the row stays)
  function M.register_voice_params(record)
    local kind = "register_voice_params"
    require_open("voice_params", kind)
    require_arg(type(record) == "table", kind, "a record is a table")
    require_arg(type(record.name) == "string" and record.name ~= "", kind, "a record needs a name")
    require_arg(not name_taken(M.registry.voice_params, "name", record.name), kind,
      "a second record named " .. record.name)
    local where = kind .. " " .. record.name
    require_known_fields(record, VOICE_PARAM_FIELDS, where)
    require_arg(is_whole(record.count, 1) or type(record.count) == "function", where,
      "count is a whole number of params, at least 1, or a function of the voice")
    require_arg(type(record.add) == "function", where, "add is a function")
    require_arg(record.add_first == nil or type(record.add_first) == "function", where, "add_first is a function")
    require_arg(all_entries(record.grain_keys, is_grain_key), where,
      "grain_keys maps a key to an engine name or {name, value = fn, carry = false}")
    require_arg(record.voice_keys == nil or type(record.voice_keys) == "table" or type(record.voice_keys) == "function",
      where, "voice_keys is a table or a function of the voice")
    require_arg(record.send_order == nil or type(record.send_order) == "table", where, "send_order is a list of keys")
    require_arg(record.separator == nil or record.separator == false
      or (type(record.separator) == "string" and record.separator ~= ""), where, "a separator is a string or false")
    require_arg(record.sync == nil or type(record.sync) == "function", where, "sync is a function")
    require_arg(record.reaches == nil or type(record.reaches) == "function", where, "reaches is a function")
    local scene_keys = record.scene_keys
    require_arg(scene_keys == nil or scene_keys == true or type(scene_keys) == "function"
      or (type(scene_keys) == "table" and all_entries(scene_keys, function(_, key) return type(key) == "string" end)),
      where, "scene_keys is true, a list of keys or a function of the voice and a type key")
    require_arg(scene_keys == nil or record.scene_defaults == nil, where, "scene_keys stands in for scene_defaults")
    -- synth_keys (#840): its scene keys are the voice type's synth keys,
    -- each entry of voice_scene_keys marked synth (the synth record's)
    require_arg(record.synth_keys == nil or (record.synth_keys == true and scene_keys ~= nil), where,
      "synth_keys is true, on a scene_keys record, or absent")
    -- The per-voice checks (count, voice_keys, send_order, scene_defaults,
    -- discrete, scene_ranges): now when every field they read is a table
    -- or a number; one a function of the voice gives (the groundwork
    -- before 3.8, 3.7) is checked at init instead (3.8, ruling 19: such a
    -- function may read the voice types, which are read at init), by
    -- S.lib.params_setup, through M.check_voice_params
    if type(record.count) ~= "function" and type(record.voice_keys) ~= "function"
      and type(record.scene_defaults) ~= "function" then
      for voice_idx = 1, M.constants.NUM_VOICES do M.check_voice_params(record, voice_idx, 2) end
    end
    local rows = record.voice_rows
    require_arg(rows == nil or (type(rows) == "table" and type(rows.section) == "string"
      and (type(rows.rows) == "table" or type(rows.rows) == "function")
      and (rows.when == nil or type(rows.when) == "function")
      and (rows.before == nil or type(rows.before) == "string")), where,
      "voice_rows is {section, rows = list | fn(voice_idx), when = fn, before = <section>, swaps}")
    require_arg(rows == nil or type(rows.rows) == "function"
      or all_entries(rows.rows, function(_, key) return type(key) == "string" end), where,
      "voice_rows.rows lists param keys")
    require_arg(rows == nil or all_entries(rows.swaps, function(key, swap)
      return type(key) == "string" and type(swap) == "function"
    end), where, "voice_rows.swaps maps a row's key to fn(voice_idx) -> key | nil")
    require_arg(all_entries(record.layout_states, function(_, state)
      return type(state) == "table" and type(state.name) == "string" and type(state.setup) == "function"
    end), where, "layout_states lists {name, setup = fn}")
    require_arg(record.normalize_scene == nil or type(record.normalize_scene) == "function", where,
      "normalize_scene is a function")
    require_arg(record.fader == false or valid_groups(record.fader, fader_group), where,
      "fader is false or groups {keys = list | fn, when = fn, rank = number}")
    require_arg(valid_groups(record.main_randomize, randomize_group), where,
      "main_randomize is groups {keys = list | fn, when = fn, draw = fn}")
    require_arg(valid_groups(record.mutate, mutate_group), where,
      "mutate is groups {keys = list | fn, when = fn, chance = 0-1, scale = number, warped = boolean}")
    require_arg(all_entries(record.randomize, function(key, draw)
      return type(key) == "string" and type(draw) == "function"
    end), where, "randomize maps a key to a draw function")
    table.insert(M.registry.voice_params, record)
  end

  -- A global scene field (3.2: scale, root): {id = a param id, default =
  -- its param's default, discrete = true to set it at a transition's end
  -- instead of crossfading, set = fn(value), optional (3.4): what a recall,
  -- a transition step and apply_entries call in place of params:set, as a
  -- macro sets itself silently}. Scenes read these after S.SCENE_GLOBAL_PARAMS
  function M.register_scene_field(field)
    local kind = "register_scene_field"
    require_open("scene_fields", kind)
    require_arg(type(field) == "table" and type(field.id) == "string" and field.id ~= "", kind, "a field needs an id")
    local where = kind .. " " .. field.id
    require_known_fields(field, SCENE_FIELD_FIELDS, where)
    require_arg(type(field.default) == "number", where, "a default is a number")
    require_arg(field.discrete == nil or type(field.discrete) == "boolean", where, "discrete is a boolean")
    require_arg(field.set == nil or type(field.set) == "function", where, "set is a function")
    require_arg(not name_taken(M.registry.scene_fields, "id", field.id), kind, "a second field " .. field.id)
    table.insert(M.registry.scene_fields, {id = field.id, default = field.default, discrete = field.discrete == true,
      set = field.set})
  end

  -- fn(voice_idx, source) runs in every v<i>_source action, once the source
  -- is stored and sent and before the voice's sync, except during a scene
  -- recall
  function M.register_source_change(fn)
    require_arg(type(fn) == "function", "register_source_change", "a hook is a function")
    table.insert(M.registry.source_change, fn)
  end

  -- fn(voice_idx) runs after every engine.voiceOn and after every
  -- engine.setGrainSource that changes a running voice's source
  -- (lib/engine_sync.lua), when the voice's grain synth is new
  function M.register_grain_restart(fn)
    require_arg(type(fn) == "function", "register_grain_restart", "a hook is a function")
    table.insert(M.registry.grain_restart, fn)
  end

  -- fn() runs when ALT goes from held to not held (S.lib.ui_alt.set(false),
  -- forget_held_keys)
  function M.register_alt_release(fn)
    require_arg(type(fn) == "function", "register_alt_release", "a hook is a function")
    table.insert(M.registry.alt_release, fn)
  end

  -- fn() runs each time the norns menu closes (_menu.set_mode(false)),
  -- after norns' own set_mode returns, each in its own pcall. The menu
  -- watch reads the registry as its start step builds the wrapper, so
  -- hooks are registered at include time
  function M.register_menu_close(fn)
    require_open("menu_close", "register_menu_close")
    require_arg(type(fn) == "function", "register_menu_close", "a hook is a function")
    table.insert(M.registry.menu_close, fn)
  end

  -- A state invariant of the registering module: fn() returns nil while it
  -- holds, else a string saying what is broken. The test harness runs every
  -- one after each unit test (test/helpers.lua); nothing runs them on the
  -- device
  function M.register_invariant(name, fn)
    local kind = "register_invariant"
    require_arg(type(name) == "string" and name ~= "", kind, "a name is a non-empty string")
    require_arg(type(fn) == "function", kind .. " " .. name, "a check is a function")
    require_arg(not name_taken(M.registry.invariants, "name", name), kind, "a second invariant " .. name)
    table.insert(M.registry.invariants, {name = name, fn = fn})
  end

  -- fn(voice_idx, value, previous, turned) -> value, applied by the action of
  -- every v<i>_<key> voice param (param_order or registered) before it
  -- stores the value; previous is the value stored before, turned whether
  -- the set is a turn of the param (S.turning_param, #318). One filter per key
  function M.register_param_filter(key, fn)
    local kind = "register_param_filter"
    require_arg(type(key) == "string" and key ~= "", kind, "a key is a param id suffix")
    require_arg(type(fn) == "function", kind .. " " .. key, "a filter is a function")
    require_arg(M.registry.param_filters[key] == nil, kind, "a second filter for " .. key)
    M.registry.param_filters[key] = fn
  end

  -- A per-voice LFO destination: "v<i> <label>" modulates v<i>_<suffix>.
  -- In the destination list each joins its voice's group (a global one,
  -- register_lfo_global_destination, joins the group it names)
  function M.register_lfo_destination(label, suffix)
    local kind = "register_lfo_destination"
    require_open("lfo_destinations", kind)
    require_arg(type(label) == "string" and label ~= "", kind, "a label is a string")
    require_arg(type(suffix) == "string" and suffix ~= "", kind .. " " .. label, "a suffix is a param id suffix")
    require_arg(not name_taken(M.registry.lfo_destinations, "label", label), kind, "a second label " .. label)
    table.insert(M.registry.lfo_destinations, {label = label, suffix = suffix})
  end

  -- Params added to the fx group after its own: {name, count, add = fn()};
  -- the group's size counts them, and add must add exactly count
  function M.register_fx_params(record)
    local kind = "register_fx_params"
    require_open("fx_params", kind)
    require_arg(type(record) == "table" and type(record.name) == "string" and record.name ~= "", kind,
      "a record needs a name")
    require_known_fields(record, FX_PARAM_FIELDS, kind .. " " .. record.name)
    require_arg(not name_taken(M.registry.fx_params, "name", record.name), kind, "a second record " .. record.name)
    require_arg(is_whole(record.count, 1), kind .. " " .. record.name, "count is a whole number, at least 1")
    require_arg(type(record.add) == "function", kind .. " " .. record.name, "add is a function")
    table.insert(M.registry.fx_params, record)
  end

  -- 3.4's registries (design §0.1, §8.10, §10.1). Each register function
  -- checks its argument (a field outside the record's set too, #385) and
  -- refuses a second record of the same name or key; the error points at the
  -- registering module's line. scene_blocks and pset_hooks close at init
  -- (INIT_READ); the rest are read at each use

  -- A named record's register function's common checks: a table, its name
  -- field a non-empty string no record of registry has, only known fields.
  -- Returns the "<kind> <name>" the field checks name
  local function require_named(record, registry, kind, name_field, allowed)
    require_arg(type(record) == "table", kind, "a record is a table")
    local name = record[name_field]
    require_arg(type(name) == "string" and name ~= "", kind, "a record needs a " .. name_field)
    require_arg(not name_taken(M.registry[registry], name_field, name), kind, "a second record " .. name)
    local where = kind .. " " .. name
    require_known_fields(record, allowed, where)
    return where
  end

  -- Whether value is nil or a function
  local function optional_function(value) return value == nil or type(value) == "function" end

  -- Whether every named field of record is a function (required) or nil or one (optional)
  local function require_functions(record, where, required, optional)
    for _, field in ipairs(required) do
      require_arg(type(record[field]) == "function", where, field .. " is a function")
    end
    for _, field in ipairs(optional or {}) do
      require_arg(optional_function(record[field]), where, field .. " is a function")
    end
  end

  local SCENE_BLOCK_FIELDS = {key = true, default = true, capture = true, validate = true, apply = true,
    discrete = true, through_zero = true}
  local PSET_HOOK_FIELDS = {name = true, write = true, read = true, delete = true}
  local STEP_OUTPUT_FIELDS = {name = true, play = true, stop = true, available = true}
  local MOD_SOURCE_FIELDS = {key = true, name = true, section = true, value = true, range = true, describe = true,
    visible = true, row = true, fields = true}
  local MOD_SOURCE_ROW_FIELDS = {enc = true, fine_enc = true, press = true, alt_press = true, hints = true}
  local MOD_SOURCE_NAME_MAX = 4  -- MOD's row label
  -- 3.7 (design §0.4): a settings row of a source's fields, its label at
  -- most MOD_SOURCE_FIELD_LABEL_MAX characters
  local MOD_SOURCE_FIELD_FIELDS = {label = true, value = true, enc = true, fine_enc = true, press = true}
  local MOD_SOURCE_FIELD_LABEL_MAX = 8

  -- A top-level scene block (lib/scenes.lua, 0b): {key, default = fn() ->
  -- value, capture = fn() -> value, validate = fn(value) -> ok, apply =
  -- fn(value), discrete = true (a block switches at a transition's end),
  -- through_zero = fn(from_value, to_value) -> {{id, switch = fn()}, ...},
  -- optional: the depths that ramp through 0 in a transition and a morph}
  function M.register_scene_block(record)
    local kind = "register_scene_block"
    require_open("scene_blocks", kind)
    local where = require_named(record, "scene_blocks", kind, "key", SCENE_BLOCK_FIELDS)
    require_functions(record, where, {"default", "capture", "validate", "apply"}, {"through_zero"})
    require_arg(record.discrete == true, where, "discrete is true: a block switches at a transition's end")
    table.insert(M.registry.scene_blocks, record)
  end

  -- A PSET hook (lib/params_setup.lua runs it): {name, write = fn(path_base,
  -- number), read = fn(path_base, number, pset_path, silent), delete =
  -- fn(path_base, number)}, each function optional; path_base is the PSET's
  -- path without .pset, number norns' two-digit string or nil, silent the
  -- read's own flag
  function M.register_pset_hook(record)
    local kind = "register_pset_hook"
    require_open("pset_hooks", kind)
    local where = require_named(record, "pset_hooks", kind, "name", PSET_HOOK_FIELDS)
    require_functions(record, where, {}, {"write", "read", "delete"})
    table.insert(M.registry.pset_hooks, record)
  end

  -- fn(param_id, source) runs after each user edit of a param through an
  -- encoder ("enc", lib/ui/detent.lua), an arc ring ("arc") or a grid fader
  -- ("grid", lib/grid/faders.lua), once the param is set
  function M.register_param_touch(fn)
    require_arg(type(fn) == "function", "register_param_touch", "a hook is a function")
    table.insert(M.registry.param_touch, fn)
  end

  -- fn(voice_idx, locked) runs after a voice's lock flips (toggle_lock,
  -- lib/engine_sync.lua; a scene recall's lock states, lib/scenes.lua)
  function M.register_lock_change(fn)
    require_arg(type(fn) == "function", "register_lock_change", "a hook is a function")
    table.insert(M.registry.lock_change, fn)
  end

  -- A global LFO destination (3.4): one destination, label modulating
  -- param_id, appended to the per-voice ones in registration order
  -- ({label, param_id, global = true, group}); the labels share one
  -- namespace. group is the destination list's group it joins (#729):
  -- "global" (the default) or "macros"; any other is refused
  function M.register_lfo_global_destination(label, param_id, group)
    local kind = "register_lfo_global_destination"
    require_open("lfo_destinations", kind)
    require_arg(type(label) == "string" and label ~= "", kind, "a label is a string")
    require_arg(type(param_id) == "string" and param_id ~= "", kind .. " " .. label, "a param id is a string")
    group = group == nil and "global" or group
    require_arg(group == "global" or group == "macros", kind .. " " .. label,
      "a group is global or macros, not " .. tostring(group))
    require_arg(not name_taken(M.registry.lfo_destinations, "label", label), kind, "a second label " .. label)
    table.insert(M.registry.lfo_destinations, {label = label, param_id = param_id, global = true, group = group})
  end

  -- A pattern hit's output (lib/sequencer.lua, design §8.10): {name, play =
  -- fn(event), stop = fn(), available = fn(voice_idx) -> boolean}; stop and
  -- available optional
  function M.register_step_output(record)
    local kind = "register_step_output"
    local where = require_named(record, "step_outputs", kind, "name", STEP_OUTPUT_FIELDS)
    require_functions(record, where, {"play"}, {"stop", "available"})
    table.insert(M.registry.step_outputs, record)
  end

  local IO_SECTION_FIELDS = {name = true, title = true, rows = true, status = true, layout_states = true}

  -- A section of the IO page (3.6, lib/pages/io.lua reads them at each use,
  -- design §11): {name, title = a string or fn() -> string, rows = fn() ->
  -- {row, ...}, status = fn() -> string | nil, layout_states = {{name,
  -- setup = fn(context)}, ...}}; status and layout_states optional. The
  -- page shows them in its IO_PAGE.sections order, any other name after
  -- those in registration order
  function M.register_io_section(record)
    local kind = "register_io_section"
    local where = require_named(record, "io_sections", kind, "name", IO_SECTION_FIELDS)
    require_arg(type(record.title) == "string" or type(record.title) == "function", where,
      "a title is a string or a function")
    require_functions(record, where, {"rows"}, {"status"})
    require_arg(all_entries(record.layout_states, function(_, state)
      return type(state) == "table" and type(state.name) == "string" and type(state.setup) == "function"
    end), where, "layout_states lists {name, setup = fn}")
    table.insert(M.registry.io_sections, record)
  end

  local GRID_PAGE_FIELDS = {name = true, index = true, press = true, redraw = true, sides = true, faders = true,
    signature = true}

  -- 3.8's grid page (design §10.1; lib/grid/pane.lua reads them at each
  -- press and redraw, so it stays open): {name, index, press = fn(pane, x,
  -- y, z), redraw = fn(pane, led), sides (1 or 2, 1 when absent), faders =
  -- fn(pane) -> {{line, first, keys, id}, ...}, signature = fn(pane) ->
  -- string}, the last three optional, at S.registry.grid_pages[index]. Its
  -- index is a page of S.constants.GRID_PAGES no record holds, its name
  -- that page's name (GRID_PAGES.names[index])
  function M.register_grid_page(record)
    local kind = "register_grid_page"
    require_arg(type(record) == "table", kind, "a record is a table")
    local pages = M.constants.GRID_PAGES
    local index = record.index
    require_arg(is_whole(index, 1) and index <= pages.count, kind, "an index is a grid page 1-" .. pages.count)
    require_arg(M.registry.grid_pages[index] == nil, kind, "a second record at page " .. index)
    require_arg(record.name == pages.names[index], kind, "page " .. index .. "'s name is " .. pages.names[index])
    local where = kind .. " " .. record.name
    require_known_fields(record, GRID_PAGE_FIELDS, where)
    require_arg(record.sides == nil or record.sides == 1 or record.sides == 2, where, "sides is 1 or 2")
    require_functions(record, where, {"press", "redraw"}, {"faders", "signature"})
    M.registry.grid_pages[index] = record
  end

  -- A modulation source (lib/mod_sources.lua reads them, design §10.1):
  -- {key, name (MOD's label, at most 4 characters), section, value = fn() ->
  -- number, range = {min, max} (min < max; min < 0 is bipolar), describe =
  -- fn() -> string, visible = fn() -> boolean, row = {enc, fine_enc, press,
  -- alt_press, hints}, fields}; describe, visible, row and each row function
  -- optional. fields (3.7, design §0.4), optional: the rows of the source's
  -- settings view on MOD, a list of {label (1 to 8 characters), value = fn()
  -- -> string, enc = fn(d), fine_enc = fn(d), press = fn()} (the last three
  -- optional), or a function returning one, read at each draw (a list it
  -- returns is not checked here)
  local function require_settings_fields(fields, where)
    require_arg(fields == nil or type(fields) == "table" or type(fields) == "function", where,
      "fields is a list or a function")
    if type(fields) ~= "table" then return end
    for index, field in ipairs(fields) do
      local at = where .. " field " .. index
      require_arg(type(field) == "table", at, "a field is a table")
      require_known_fields(field, MOD_SOURCE_FIELD_FIELDS, at)
      require_arg(type(field.label) == "string" and field.label ~= "" and #field.label <= MOD_SOURCE_FIELD_LABEL_MAX,
        at, "a label is 1 to " .. MOD_SOURCE_FIELD_LABEL_MAX .. " characters")
      require_functions(field, at, {"value"}, {"enc", "fine_enc", "press"})
    end
  end

  function M.register_mod_source(record)
    local kind = "register_mod_source"
    local where = require_named(record, "mod_sources", kind, "key", MOD_SOURCE_FIELDS)
    require_arg(type(record.name) == "string" and record.name ~= "" and #record.name <= MOD_SOURCE_NAME_MAX, where,
      "a name is 1 to " .. MOD_SOURCE_NAME_MAX .. " characters")
    require_arg(type(record.section) == "string" and record.section ~= "", where, "a section is a string")
    require_functions(record, where, {"value"}, {"describe", "visible"})
    local range = record.range
    require_arg(type(range) == "table" and type(range[1]) == "number" and type(range[2]) == "number"
      and range[1] < range[2], where, "range is {min, max} with min < max")
    local row = record.row
    require_arg(row == nil or type(row) == "table", where, "row is a table")
    if row then
      require_known_fields(row, MOD_SOURCE_ROW_FIELDS, where .. " row")
      require_functions(row, where .. " row", {}, {"enc", "fine_enc", "press", "alt_press", "hints"})
    end
    require_settings_fields(record.fields, where)
    table.insert(M.registry.mod_sources, record)
  end

  -- 3.5's hooks (design §0.1), read at each use, so they stay open

  -- fn(voice_idx) runs after each engine.voiceOff the script sends
  -- (lib/engine_sync.lua: toggle_voice's stop, a start that failed once its
  -- voiceOn went, cleanup's stop of every running voice)
  function M.register_voice_stop(fn)
    require_arg(type(fn) == "function", "register_voice_stop", "a hook is a function")
    table.insert(M.registry.voice_stop, fn)
  end

  -- fn(voice_idx, frozen) runs in every v<i>_freeze action (lib/freeze.lua),
  -- once the value is stored and sent, frozen true for 1
  function M.register_freeze_change(fn)
    require_arg(type(fn) == "function", "register_freeze_change", "a hook is a function")
    table.insert(M.registry.freeze_change, fn)
  end

  -- 3.6's registries (design §0.1, plan rulings 4, 8 and 9), read at each use,
  -- so they stay open
  local NOTE_HOOK_FIELDS = {name = true, started = true, ended = true, moved = true, expressed = true, heard = true}
  local NOTE_TARGET_FIELDS = {name = true, routed = true, note_on = true, note_off = true, express = true,
    stop_all = true, rows = true, status = true, layout_states = true}
  local II_DEVICE_FIELDS = {name = true, ports = true, ready = true, release = true, param_count = true,
    add_params = true}

  -- A note hook (lib/notes.lua runs each, contained): {name, started, ended,
  -- moved, expressed}, each function optional, called with (voice_idx,
  -- slot, note = {owner, key, pitch, velocity}); a hook never yields and
  -- never calls S.lib.notes.play. 3.7's heard (lib/midi_in.lua runs it,
  -- contained): fn(voice_idx, note, velocity) for every MIDI note a voice
  -- receives (its number 0-127, velocity 0-1), a note that plays nothing
  -- there included; it starts nothing and never reaches the targets
  function M.register_note_hook(record)
    local kind = "register_note_hook"
    local where = require_named(record, "note_hooks", kind, "name", NOTE_HOOK_FIELDS)
    require_functions(record, where, {}, {"started", "ended", "moved", "expressed", "heard"})
    table.insert(M.registry.note_hooks, record)
  end

  -- fn(scene_num) runs once per scene recall (lib/scenes.lua): at a fade's
  -- first step, or at an instant recall that is not a fade's landing
  function M.register_scene_recalled(fn)
    require_arg(type(fn) == "function", "register_scene_recalled", "a hook is a function")
    table.insert(M.registry.scene_recalled, fn)
  end

  -- fn(voice_idx, silenced) runs (lib/voice_mix.lua) for each voice whose
  -- S.lib.voice_mix.silenced(voice_idx) answer a mute or solo changed
  function M.register_silence_change(fn)
    require_arg(type(fn) == "function", "register_silence_change", "a hook is a function")
    table.insert(M.registry.silence_change, fn)
  end

  -- A note target (lib/io/targets.lua reads them, design §3): {name, routed
  -- = fn, note_on = fn, note_off = fn, express, stop_all, rows, status,
  -- layout_states = {{name, setup = fn(context)}, ...}}; the last five
  -- optional (rows and status: IO's voice section, plan ruling 9; layout_states:
  -- the voice section's layout states the page lists for the target)
  function M.register_note_target(record)
    local kind = "register_note_target"
    local where = require_named(record, "note_targets", kind, "name", NOTE_TARGET_FIELDS)
    require_functions(record, where, {"routed", "note_on", "note_off"}, {"express", "stop_all", "rows", "status"})
    require_arg(all_entries(record.layout_states, function(_, state)
      return type(state) == "table" and type(state.name) == "string" and type(state.setup) == "function"
    end), where, "layout_states lists {name, setup = fn}")
    table.insert(M.registry.note_targets, record)
  end

  -- An ii device (lib/io/ii.lua reads them, plan ruling 8): {name, ports =
  -- true or false (whether every command of it with an argument takes the
  -- port it addresses first, as the ER-301's and the TELEXo's do: the
  -- queue's turns, #710, #717), ready = fn, release = fn, param_count = the
  -- params add_params adds (a finite whole number, 0 by default),
  -- add_params = fn}; name and ports required, the rest optional, and a
  -- param_count above 0 needs add_params. The registry keeps a copy with
  -- param_count filled in; the caller's table is left as it was given
  function M.register_ii_device(record)
    local kind = "register_ii_device"
    local where = require_named(record, "ii_devices", kind, "name", II_DEVICE_FIELDS)
    require_arg(type(record.ports) == "boolean", where, "ports is true or false: whether its commands address ports")
    require_functions(record, where, {}, {"ready", "release", "add_params"})
    local count = record.param_count
    if count == nil then count = 0 end
    require_arg(is_whole(count, 0) and count < math.huge, where, "param_count is a finite whole number, at least 0")
    require_arg(count == 0 or record.add_params ~= nil, where, "a param_count above 0 needs add_params")
    local stored = {}
    for field, value in pairs(record) do stored[field] = value end
    stored.param_count = count
    table.insert(M.registry.ii_devices, stored)
  end

  -- 3.7's voice_hit (design §0.2, plan ruling 12), read at each use, so it
  -- stays open: {name, hit = fn(voice_idx, info)}, info = {velocity, source
  -- ("step", "note", "action" or "start"), slot (1 the voice's own note, 2
  -- to 8 an extra one), gate_seconds (a gated step's, else nil)}.
  -- lib/engine_sync.lua tells each hook once per hit, contained; a hook
  -- never sends and never yields
  local VOICE_HIT_FIELDS = {name = true, hit = true}
  function M.register_voice_hit(record)
    local kind = "register_voice_hit"
    local where = require_named(record, "voice_hit", kind, "name", VOICE_HIT_FIELDS)
    require_functions(record, where, {"hit"})
    table.insert(M.registry.voice_hit, record)
  end

  -- 3.7's scene_applied (1d's review), read at each use, so it stays open:
  -- {name, fn = fn()}. lib/scenes.lua's apply_entries runs each once, right
  -- after it clears S.scene_recall_in_progress (an instant recall, a fade's
  -- landing, morph's discrete entries), contained, even after an error
  local SCENE_APPLIED_FIELDS = {name = true, fn = true}
  function M.register_scene_applied(record)
    local kind = "register_scene_applied"
    local where = require_named(record, "scene_applied", kind, "name", SCENE_APPLIED_FIELDS)
    require_functions(record, where, {"fn"})
    table.insert(M.registry.scene_applied, record)
  end

  -- A macro target (lib/macros.lua's catalog lists each after the matrix
  -- depths, plan ruling 4): a control param id and its label; never a macro
  function M.register_macro_target(id, label)
    local kind = "register_macro_target"
    require_arg(type(id) == "string" and id ~= "", kind, "an id is a non-empty string")
    require_arg(type(label) == "string" and label ~= "", kind .. " " .. id, "a label is a non-empty string")
    require_arg(not id:match("^macro_%d+$"), kind .. " " .. id, "a macro is never a macro's target")
    require_arg(not name_taken(M.registry.macro_targets, "id", id), kind, "a second target " .. id)
    table.insert(M.registry.macro_targets, {id = id, label = label})
  end

  -- 3.8's voice type (design §2.1, package 0d): one record a type, from its
  -- own file lib/types/<key>.lua, registered in type order (the engine's
  -- voiceTypeDefs order, a docs test). The record: {key (^[%w_]+$, unique:
  -- the scenes' name), name (the option's and separator's text), list_name
  -- (1 to VOICE_TYPE_LIST_NAME_MAX characters, MAIN's list), def (the
  -- engine def's name), param_order (its synth keys, freq first, amp then
  -- pan, when present, last), defaults, specs (controlspecs) and formats
  -- (format strings, optional) by key, main = {key, label, format} (MAIN's
  -- E3 and arc ring 2), note_main (the key the per-note main expression
  -- moves), envelope = {attack, release} (the attack and release defaults
  -- of a voice that starts on it)}. The registry keeps a copy with index
  -- (its place, 1-based; the engine's type is index - 1): a record that
  -- gives one is refused. A key an earlier type has must give the same spec (its
  -- minval, maxval, warp, step, quantum and units; the default may differ)
  -- and format. It closes at init (INIT_READ)
  local VOICE_TYPE_FIELDS = {key = true, name = true, list_name = true, def = true, param_order = true,
    defaults = true, specs = true, formats = true, main = true, note_main = true, envelope = true}
  local VOICE_TYPE_LIST_NAME_MAX = 5
  local SPEC_FIELDS = {"minval", "maxval", "warp", "warp_name", "step", "quantum", "units"}

  local function nonempty_string(value) return type(value) == "string" and value ~= "" end

  -- The first registered type's spec and format of key, or nil when none has it
  local function shared_key(key)
    for _, record in ipairs(M.registry.voice_types) do
      if record.specs[key] then return record.specs[key], record.formats[key] end
    end
  end

  -- Whether param_order is freq first and ends with amp, then pan when it has one
  local function well_ordered(order)
    local has = {}
    for _, key in ipairs(order) do has[key] = true end
    if order[1] ~= "freq" or not has.amp then return false end
    if has.pan then return order[#order] == "pan" and order[#order - 1] == "amp" end
    return order[#order] == "amp"
  end

  function M.register_voice_type(record)
    local kind = "register_voice_type"
    require_open("voice_types", kind)
    require_arg(type(record) == "table", kind, "a record is a table")
    require_arg(type(record.key) == "string" and record.key:match("^[%w_]+$") ~= nil, kind,
      "a key is a param id suffix")
    require_arg(not name_taken(M.registry.voice_types, "key", record.key), kind, "a second type " .. record.key)
    local where = kind .. " " .. record.key
    require_known_fields(record, VOICE_TYPE_FIELDS, where)
    require_arg(nonempty_string(record.name), where, "a name is a string")
    require_arg(nonempty_string(record.list_name) and #record.list_name <= VOICE_TYPE_LIST_NAME_MAX, where,
      "a list name is 1 to " .. VOICE_TYPE_LIST_NAME_MAX .. " characters")
    require_arg(nonempty_string(record.def), where, "a def is the engine def's name")
    local order = record.param_order
    require_arg(type(order) == "table" and #order > 0 and all_entries(order, function(_, key)
      return type(key) == "string" and key:match("^[%w_]+$") ~= nil
    end), where, "param_order lists its synth keys")
    require_arg(well_ordered(order), where, "param_order has freq first and amp, then pan, last")
    require_arg(type(record.defaults) == "table" and type(record.specs) == "table"
      and (record.formats == nil or type(record.formats) == "table"), where, "defaults, specs and formats are tables")
    local formats = record.formats or {}
    local listed = {}
    for _, key in ipairs(order) do
      require_arg(not listed[key], where, "param_order names " .. key .. " twice")
      listed[key] = true
      local spec, default = record.specs[key], record.defaults[key]
      require_arg(type(spec) == "table" and type(spec.minval) == "number" and type(spec.maxval) == "number", where,
        key .. " has a spec")
      require_arg(type(default) == "number" and default >= math.min(spec.minval, spec.maxval)
        and default <= math.max(spec.minval, spec.maxval), where, key .. " has a default inside its spec")
      require_arg(formats[key] == nil or type(formats[key]) == "string", where, key .. "'s format is a string")
      local first_spec, first_format = shared_key(key)
      if first_spec then
        for _, field in ipairs(SPEC_FIELDS) do
          require_arg(first_spec[field] == spec[field], where, key .. "'s spec differs from an earlier type's (" .. field .. ")")
        end
        require_arg(first_format == formats[key], where, key .. "'s format differs from an earlier type's")
      end
    end
    for _, table_name in ipairs({"defaults", "specs", "formats"}) do
      require_arg(all_entries(record[table_name], function(key) return listed[key] end), where,
        table_name .. " names only param_order's keys")
    end
    local main = record.main
    require_arg(type(main) == "table" and listed[main.key] and nonempty_string(main.label)
      and nonempty_string(main.format), where, "main is {key of param_order, label, format}")
    require_arg(listed[record.note_main] == true, where, "note_main is a key of param_order")
    local envelope = record.envelope
    require_arg(type(envelope) == "table" and type(envelope.attack) == "number" and type(envelope.release) == "number",
      where, "envelope is {attack, release}")
    -- the registry keeps a copy, its formats filled in and its index set;
    -- the caller's table is left as it was given
    local stored = {}
    for field, value in pairs(record) do stored[field] = value end
    stored.formats = formats
    stored.index = #M.registry.voice_types + 1
    table.insert(M.registry.voice_types, stored)
  end

  -- The module tables, S.lib.<name> (strata.lua stores each constructor's
  -- table here)
  M.lib = {}

  return M
end

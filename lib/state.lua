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
    params = {},        -- param-adding functions, run by init in order
    start = {},         -- {order, fn} records, run by init() by order
    cleanup = {},       -- {order, fn} records, run by cleanup() by order
    grid_layouts = {},  -- per grid layout ("256", "128h", ...), its {key, redraw, fx_faders_page?}
    voice_params = {},  -- per-voice param records (register_voice_params), in registration order
    scene_fields = {},  -- global scene fields {id, default, discrete} (register_scene_field)
    source_change = {}, -- fn(voice_idx, source), run by each v<i>_source action before its sync, never in a scene recall
    param_filters = {}, -- per voice param key: fn(voice_idx, value, previous, turned) -> value
    lfo_destinations = {},  -- per-voice LFO destinations {label, suffix}, after the built-in ones
    fx_params = {},     -- fx group records {name, count, add}, after the group's own params
    grain_restart = {}, -- fn(voice_idx), run by lib/engine_sync.lua after a voiceOn and a running voice's source switch
    alt_release = {},   -- fn(), run when ALT goes from held to not held
    menu_close = {},    -- fn(), run after the norns menu closes (lib/ui/menu_watch.lua)
    invariants = {},    -- {name, fn} records, checked by the test harness after every unit test
  }

  -- The registries init reads once (voice_params, scene_fields,
  -- lfo_destinations, fx_params, start, menu_close) are closed when init
  -- begins to read them (close_registries, called by the first params
  -- record, "performance"): a registration after that is never used, so its
  -- register function raises, naming the registry (#384)
  local closed = {}
  local INIT_READ = {"voice_params", "scene_fields", "lfo_destinations", "fx_params", "start", "menu_close"}

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
    sync = true, scene_defaults = true, discrete = true, scene_ranges = true, voice_rows = true,
    layout_states = true, normalize_scene = true, fader = true, randomize = true}
  local SCENE_FIELD_FIELDS = {id = true, default = true, discrete = true}
  local FX_PARAM_FIELDS = {name = true, count = true, add = true}

  local function is_grain_key(key, value)
    return type(key) == "string" and (type(value) == "string" or (type(value) == "table"
      and type(value.name) == "string" and (value.value == nil or type(value.value) == "function")))
  end

  -- A module's per-voice params (3.2: freeze, variation, loops, history,
  -- the voice filter and sends). The record's fields:
  --   name: unique; count: the params add adds per voice (checked at init);
  --   add = fn(voice_idx): adds them with S.lib.params_setup.add_voice_extra;
  --   grain_keys: {key = "<engine name>" | {name, value = fn(x)}}, sent with
  --     setGrainParam by the param's sender and the voice sync;
  --   sync: optional fn(voice_idx), the voice sync's sends after grain_keys;
  --     a start runs it before voiceOn, so it sends grain params only
  --     (setGrainParam): voiceOn resets the voice-level ones (#325);
  --   scene_defaults: {key = default} (each its param's default): the keys
  --     scenes capture into voices[i].extras and migration fills;
  --   discrete: {key = {min, max}} (whole values): set at a transition's
  --     end, after the source; every other scene key crossfades;
  --   scene_ranges: {key = {min, max}} for a continuous scene key:
  --     validate_scene rejects a scene whose value lies outside it;
  --   voice_rows: {section, rows = {key, ...}, when = fn(voice_idx, key),
  --     before = <section>}: VOICE's rows (lib/ui/voice_rows.lua);
  --   layout_states: {{name, setup = fn(context)}}: VOICE's layout tests draw them;
  --   fader: never true (registered params stay off the 256 fader pages);
  --   randomize: {key = fn(voice_idx) -> value}: the keys a press of ALT+K2
  --     on their VOICE section randomizes, each with its draw (#557); never
  --     MAIN's randomize_voice, the mutations or the fader pages
  function M.register_voice_params(record)
    local kind = "register_voice_params"
    require_open("voice_params", kind)
    require_arg(type(record) == "table", kind, "a record is a table")
    require_arg(type(record.name) == "string" and record.name ~= "", kind, "a record needs a name")
    require_arg(not name_taken(M.registry.voice_params, "name", record.name), kind,
      "a second record named " .. record.name)
    local where = kind .. " " .. record.name
    require_known_fields(record, VOICE_PARAM_FIELDS, where)
    require_arg(is_whole(record.count, 1), where, "count is a whole number of params, at least 1")
    require_arg(type(record.add) == "function", where, "add is a function")
    require_arg(record.add_first == nil or type(record.add_first) == "function", where, "add_first is a function")
    require_arg(all_entries(record.grain_keys, is_grain_key), where,
      "grain_keys maps a key to an engine name or {name, value = fn}")
    require_arg(record.sync == nil or type(record.sync) == "function", where, "sync is a function")
    require_arg(all_entries(record.scene_defaults, function(key, value)
      return type(key) == "string" and type(value) == "number"
    end), where, "scene_defaults maps a key to a number")
    require_arg(all_entries(record.discrete, function(key, range)
      local default = record.scene_defaults and record.scene_defaults[key]
      return type(range) == "table" and is_whole(range[1], -math.huge) and is_whole(range[2], range[1])
        and is_whole(default, range[1]) and default <= range[2]
    end), where, "discrete maps a scene key to a whole {min, max} that holds its default")
    require_arg(all_entries(record.scene_ranges, function(key, range)
      local default = record.scene_defaults and record.scene_defaults[key]
      return type(range) == "table" and type(range[1]) == "number" and type(range[2]) == "number"
        and range[1] <= range[2] and not (record.discrete and record.discrete[key])
        and type(default) == "number" and default >= range[1] and default <= range[2]
    end), where, "scene_ranges maps a continuous scene key to a {min, max} that holds its default")
    local rows = record.voice_rows
    require_arg(rows == nil or (type(rows) == "table" and type(rows.section) == "string"
      and type(rows.rows) == "table" and (rows.when == nil or type(rows.when) == "function")
      and (rows.before == nil or type(rows.before) == "string")), where,
      "voice_rows is {section, rows, when = fn, before = <section>}")
    require_arg(rows == nil or all_entries(rows.rows, function(_, key) return type(key) == "string" end), where,
      "voice_rows.rows lists param keys")
    require_arg(all_entries(record.layout_states, function(_, state)
      return type(state) == "table" and type(state.name) == "string" and type(state.setup) == "function"
    end), where, "layout_states lists {name, setup = fn}")
    require_arg(record.normalize_scene == nil or type(record.normalize_scene) == "function", where,
      "normalize_scene is a function")
    require_arg(record.fader ~= true, where, "registered params stay off the 256 fader pages (fader = false)")
    require_arg(all_entries(record.randomize, function(key, draw)
      return type(key) == "string" and type(draw) == "function"
    end), where, "randomize maps a key to a draw function")
    table.insert(M.registry.voice_params, record)
  end

  -- A global scene field (3.2: scale, root): {id = a param id, default =
  -- its param's default, discrete = true to set it at a transition's end
  -- instead of crossfading}. Scenes read these after S.SCENE_GLOBAL_PARAMS
  function M.register_scene_field(field)
    local kind = "register_scene_field"
    require_open("scene_fields", kind)
    require_arg(type(field) == "table" and type(field.id) == "string" and field.id ~= "", kind, "a field needs an id")
    local where = kind .. " " .. field.id
    require_known_fields(field, SCENE_FIELD_FIELDS, where)
    require_arg(type(field.default) == "number", where, "a default is a number")
    require_arg(field.discrete == nil or type(field.discrete) == "boolean", where, "discrete is a boolean")
    require_arg(not name_taken(M.registry.scene_fields, "id", field.id), kind, "a second field " .. field.id)
    table.insert(M.registry.scene_fields, {id = field.id, default = field.default, discrete = field.discrete == true})
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
  -- They follow every built-in destination, by registration and then voice,
  -- so saved destination indices keep their meaning
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

  -- The module tables, S.lib.<name> (strata.lua stores each constructor's
  -- table here)
  M.lib = {}

  return M
end

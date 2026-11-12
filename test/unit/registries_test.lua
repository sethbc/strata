-- test/unit/registries_test.lua
-- The registries 3.2's modules add to (lib/state.lua): voice params
-- (S.registry.voice_params, add_voice_extra), scene fields, source change
-- hooks, param filters, LFO destinations, fx params, and S.performance.
-- Their readers are lib/params_setup.lua, lib/engine_sync.lua,
-- lib/scenes.lua, lib/lfos.lua, lib/ui/voice_rows.lua and lib/pages/voice.lua.
-- Run alone: lua test/run.lua registries

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake
local deep_copy, read_lua_sources = h.deep_copy, h.read_lua_sources

-- A test record: "probe" (a control, grain key posSpread) and
-- "probe_switch" (a binary toggle, discrete), in the grain section.
-- overrides replace any of its fields
local function probe_record(overrides)
  local record = {
    name = "probe", count = 2,
    grain_keys = { probe = "posSpread" },
    scene_defaults = { probe = 0, probe_switch = 0 },
    discrete = { probe_switch = { 0, 1 } },
    voice_rows = { section = "grain", rows = { "probe", "probe_switch" } },
    fader = false,
  }
  function record.add(voice_idx)
    local add_voice_extra = local_value("S").lib.params_setup.add_voice_extra
    add_voice_extra(voice_idx, record, "probe",
      { type = "control", name = "probe", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
    add_voice_extra(voice_idx, record, "probe_switch",
      { type = "binary", name = "probe switch", behavior = "toggle", default = 0 })
  end
  for key, value in pairs(overrides or {}) do record[key] = value end
  return record
end

-- Load the script with register(S) run before init (after every include)
local function load_with(register, options)
  options = options or {}
  options.before_init = function(context) register(local_value("S"), context) end
  return load_strata(options)
end

-- The index in context.engine_calls of the first call after `from` that
-- matches name and, when given, the args
local function find_call(context, from, name, args)
  for index = from or 1, #context.engine_calls do
    local call = context.engine_calls[index]
    if call.name == name then
      local matches = true
      for position, value in pairs(args or {}) do
        local actual = call.args[position]
        if type(value) == "number" and type(actual) == "number" then
          matches = matches and math.abs(actual - value) < 1e-9
        else
          matches = matches and actual == value
        end
      end
      if matches then return index end
    end
  end
end

test("a registered voice param is added, stored, sent and synced", function()
  local context = load_with(function(S) S.register_voice_params(probe_record()) end)
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice_idx .. "_probe"), 0, "voice " .. voice_idx .. " has the param")
    assert_equal(S.voices[voice_idx].extras.probe, 0, "and its stored value")
  end
  context.clear_engine_calls()
  params:set("v1_probe", 0.4)
  assert_near(S.voices[1].extras.probe, 0.4, 1e-9, "stored into extras")
  assert_true(find_call(context, 1, "setGrainParam", { 0, "posSpread", 0.4 }), "sent while the voice runs")
  -- a stopped voice stores but sends nothing
  context.clear_engine_calls()
  params:set("v3_probe", 0.7)
  assert_near(S.voices[3].extras.probe, 0.7, 1e-9)
  assert_equal(#context.calls_named("setGrainParam"), 0, "a stopped voice gets no message")
  -- the sync sends it after the source
  toggle_voice(1)
  context.clear_engine_calls()
  toggle_voice(1)
  local source_at = find_call(context, 1, "setGrainSource", { 0 })
  assert_true(source_at, "the sync sends the source")
  assert_true(find_call(context, source_at, "setGrainParam", { 0, "posSpread", 0.4 }), "then the registered grain key")
  -- the separator and the menu order: after the cross-modulation params
  local position = {}
  for index, param in ipairs(params.params) do position[param.id] = index end
  assert_true(position["voice 1 extras"], "a separator voice 1 extras")
  assert_true(position["v1_mod_speed"] < position["voice 1 extras"], "after the cross-modulation params")
  -- after the script's own records' params (lib/history.lua's), registered
  -- at include, less those their add_first put ahead of the synthesis params
  local before = 0
  for _, record in ipairs(S.registry.voice_params) do
    if record.name == "probe" then break end
    before = before + record.count
  end
  before = before - (position["v1_" .. S.voices[1].param_order[1]] - position["voice 1: " .. S.voices[1].name] - 1)
  assert_equal(position["v1_probe"], position["voice 1 extras"] + 1 + before, "the record's params follow it")
  assert_equal(position["v1_probe_switch"], position["v1_probe"] + 1)
end)

test("a grain key can convert the value it sends", function()
  local record = probe_record({ grain_keys = { probe = "posSpread",
    probe_switch = { name = "grainMode", value = function(x) return 1 - x end } } })
  local context = load_with(function(S) S.register_voice_params(record) end)
  finish_startup(context)
  context.clear_engine_calls()
  params:set("v1_probe_switch", 1)
  assert_true(find_call(context, 1, "setGrainParam", { 0, "grainMode", 0 }), "sent as value(x)")
end)

test("a record's sync runs after its grain keys", function()
  local synced = {}
  local record = probe_record({ sync = function(voice_idx) table.insert(synced, voice_idx) end })
  local context = load_with(function(S) S.register_voice_params(record) end)
  finish_startup(context)
  synced = {}
  toggle_voice(3)
  assert_equal(table.concat(synced, ","), "3", "sync runs once for the started voice")
end)

test("a record's add must add exactly count params", function()
  for _, count in ipairs({ 1, 3 }) do
    local ok, problem = pcall(load_with, function(S) S.register_voice_params(probe_record({ count = count })) end)
    assert_true(not ok, "count " .. count .. " for two params fails")
    assert_true(tostring(problem):find("probe", 1, true) and tostring(problem):find("count", 1, true),
      "the error names the record and its count: " .. tostring(problem))
  end
  local ok, problem = pcall(load_with, function(S)
    S.register_fx_params({ name = "probe fx", count = 2, add = function()
      params:add_binary("probe_bypass", "probe bypass", "toggle", 0)
    end })
  end)
  assert_true(not ok and tostring(problem):find("probe fx", 1, true), "an fx record too: " .. tostring(problem))
end)

-- norns reads a PSET in param order (#125)
test("a record's add_first params come before the voice's synthesis params, counted with its add's", function()
  local record = probe_record({ count = 3 })
  function record.add_first(voice_idx)
    local_value("S").lib.params_setup.add_voice_extra(voice_idx, record, "probe_first",
      { type = "control", name = "probe first", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
  end
  load_with(function(S) S.register_voice_params(record) end)
  local S = local_value("S")
  local position = {}
  for index, param in ipairs(params.params) do position[param.id] = index end
  for voice_idx = 1, S.constants.NUM_VOICES do
    local prefix = "v" .. voice_idx .. "_"
    assert_true(position[prefix .. "probe_first"] < position[prefix .. S.voices[voice_idx].param_order[1]],
      prefix .. "probe_first before the synthesis params")
    assert_true(position["voice " .. voice_idx .. ": " .. S.voices[voice_idx].name] < position[prefix .. "probe_first"],
      "inside voice " .. voice_idx .. "'s block")
    assert_true(position[prefix .. "probe"] > position["voice " .. voice_idx .. " extras"], "add's params in extras")
  end
  params:set("v2_probe_first", 0.3)
  assert_near(S.voices[2].extras.probe_first, 0.3, 1e-9, "stored like any registered param")
  local ok, problem = pcall(load_with, function(S2) S2.register_voice_params(probe_record({ add_first = record.add_first })) end)
  assert_true(not ok and tostring(problem):find("add_first", 1, true), "its params count: " .. tostring(problem))
  assert_true(not pcall(S.register_voice_params, probe_record({ name = "p3", add_first = 1 })), "add_first is a function")
end)

test("the register functions check their argument and refuse duplicates", function()
  load_with(function(S)
  local function refused(fn, ...) return not pcall(fn, ...) end
  -- voice params
  S.register_voice_params(probe_record())
  assert_true(refused(S.register_voice_params, probe_record()), "a second record named probe")
  assert_true(refused(S.register_voice_params, probe_record({ name = 3 })), "a name is a string")
  assert_true(refused(S.register_voice_params, probe_record({ name = "p2", count = 0 })), "count >= 1")
  assert_true(refused(S.register_voice_params, probe_record({ name = "p2", add = "x" })), "add is a function")
  assert_true(refused(S.register_voice_params, probe_record({ name = "p2", fader = true })), "never on the faders")
  assert_true(refused(S.register_voice_params, probe_record({ name = "p2", normalize_scene = 1 })),
    "normalize_scene is a function")
  assert_true(refused(S.register_voice_params, probe_record({ name = "p2", discrete = { probe = { 0 } } })),
    "a discrete range is {min, max}")
  assert_true(refused(S.register_voice_params, probe_record({ name = "p2", discrete = { other = { 0, 1 } } })),
    "a discrete key has a scene default")
  assert_true(refused(S.register_voice_params, probe_record({ name = "p2", voice_rows = { rows = { "probe" } } })),
    "rows name their section")
  assert_true(refused(S.register_voice_params, "probe"), "a record is a table")
  -- scene fields
  assert_true(refused(S.register_scene_field, { id = "scale", default = 1 }), "a second scale")
  assert_true(refused(S.register_scene_field, { id = "probe_other" }), "a default is a number")
  assert_true(refused(S.register_scene_field, { id = 5, default = 1 }), "an id is a string")
  -- source change hooks and param filters
  S.register_source_change(function() end)
  assert_true(refused(S.register_source_change, "x"), "a hook is a function")
  S.registry.param_filters.freq = nil  -- lib/variation.lua's quantize filter; this test's in its place
  S.register_param_filter("freq", function(_, value) return value end)
  assert_true(refused(S.register_param_filter, "freq", function(_, value) return value end), "one filter per key")
  assert_true(refused(S.register_param_filter, "amp", nil), "a filter is a function")
  -- LFO destinations
  S.register_lfo_destination("probe", "probe")
  assert_true(refused(S.register_lfo_destination, "probe", "probe_switch"), "a second label probe")
  assert_true(refused(S.register_lfo_destination, "p2", nil), "a suffix is a string")
  -- fx params
  S.register_fx_params({ name = "probe fx", count = 1, add = function()
    params:add{ type = "control", id = "probe_fx", name = "probe fx", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) }
  end })
  assert_true(refused(S.register_fx_params, { name = "probe fx", count = 1, add = function() end }), "a second probe fx")
  assert_true(refused(S.register_fx_params, { name = "p2", count = 1.5, add = function() end }), "a whole count")
  end)
end)

-- #557: a record's randomize field holds the draws a VOICE press of its
-- section makes, {[key] = fn() -> value}
test("a voice param record's randomize maps its keys to draw functions (#557)", function()
  local function draw() return 0.5 end
  local context = load_with(function(S) S.register_voice_params(probe_record({ randomize = { probe = draw } })) end)
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.registry.voice_params[#S.registry.voice_params].randomize.probe == draw, "the record keeps its draws")
  load_with(function(S2)
    local function refused(fn, ...) return not pcall(fn, ...) end
    assert_true(refused(S2.register_voice_params, probe_record({ randomize = { probe = 0.5 } })), "a draw is a function")
    assert_true(refused(S2.register_voice_params, probe_record({ randomize = 1 })), "randomize is a table")
  end)
end)

test("a registry read at init refuses a registration after init, naming itself", function()
  load_strata()
  local S = local_value("S")
  local function problem_of(fn, ...)
    local ok, err = pcall(fn, ...)
    assert_true(not ok, "refused")
    return tostring(err)
  end
  local function names(text, registry)
    assert_true(text:find(registry, 1, true) ~= nil, "names " .. registry .. ": " .. text)
  end
  local voice_params, scene_fields = #S.registry.voice_params, #S.registry.scene_fields
  names(problem_of(S.register_voice_params, probe_record({ name = "late" })), "voice_params")
  names(problem_of(S.register_scene_field, { id = "late_field", default = 0 }), "scene_fields")
  names(problem_of(S.register_lfo_destination, "late", "late"), "lfo_destinations")
  names(problem_of(S.register_fx_params, { name = "late", count = 1, add = function() end }), "fx_params")
  names(problem_of(S.register_start, 999, function() end), "start")
  names(problem_of(S.register_menu_close, function() end), "menu_close")
  assert_equal(#S.registry.voice_params, voice_params, "no voice param record added")
  assert_equal(#S.registry.scene_fields, scene_fields, "no scene field added")
  assert_true(#S.registry.start == 0 or S.registry.start[#S.registry.start].order ~= 999, "no start step added")
end)

test("a record with a field outside the documented set is refused, naming the field", function()
  load_with(function(S)
    local function problem_of(fn, record)
      local ok, err = pcall(fn, record)
      assert_true(not ok, "refused")
      return tostring(err)
    end
    local function names(text, field)
      assert_true(text:find(field, 1, true) ~= nil, "names " .. field .. ": " .. text)
    end
    names(problem_of(S.register_voice_params, probe_record({ name = "typo1", scene_default = { probe = 0 } })), "scene_default")
    names(problem_of(S.register_voice_params, probe_record({ name = "typo2", grain_key = { probe = "posSpread" } })), "grain_key")
    names(problem_of(S.register_voice_params, probe_record({ name = "typo3", voice_row = {} })), "voice_row")
    names(problem_of(S.register_fx_params, { name = "typo4", count = 1, add = function() end, ad = 1 }), "ad")
    names(problem_of(S.register_scene_field, { id = "typo5", default = 0, discret = true }), "discret")
  end)
end)

test("a source change runs the hooks, but not during a scene recall", function()
  local calls = {}
  local context = load_with(function(S)
    S.register_source_change(function(voice_idx, source)
      table.insert(calls, { voice_idx = voice_idx, source = source, stored = S.voices[voice_idx].source })
    end)
  end)
  finish_startup(context)
  calls = {}
  params:set("v2_source", 3)
  assert_equal(#calls, 1, "one call per change")
  assert_equal(calls[1].voice_idx, 2); assert_equal(calls[1].source, 3)
  assert_equal(calls[1].stored, 3, "after the source action stored it")
  -- a stopped voice's change runs them too
  params:set("v5_source", 2)
  assert_equal(#calls, 2); assert_equal(calls[2].voice_idx, 5)
  -- a recall that changes sources runs none
  capture_scene(1)
  params:set("v2_source", 1); params:set("v5_source", 1)
  calls = {}
  recall_scene(1, 0)
  assert_equal(params:get("v2_source"), 3, "the recall set the source")
  assert_equal(#calls, 0, "no hook during the recall")
end)

test("a param filter changes the stored and shown value", function()
  local seen = {}
  local context = load_with(function(S)
    S.register_voice_params(probe_record())
    S.register_param_filter("probe", function(voice_idx, value, previous)
      table.insert(seen, { voice_idx = voice_idx, value = value, previous = previous })
      return math.min(value, 0.5)
    end)
    S.registry.param_filters.freq = nil  -- lib/variation.lua's quantize filter; this test's in its place
    S.register_param_filter("freq", function(_, value) return util.round(value, 100) end)
  end)
  finish_startup(context)
  local S = local_value("S")
  seen = {}
  context.clear_engine_calls()
  params:set("v1_probe", 0.8)
  assert_near(params:get("v1_probe"), 0.5, 1e-9, "the param shows the filtered value")
  assert_near(S.voices[1].extras.probe, 0.5, 1e-9, "and stores it")
  assert_true(find_call(context, 1, "setGrainParam", { 0, "posSpread", 0.5 }), "and sends it")
  assert_true(not find_call(context, 1, "setGrainParam", { 0, "posSpread", 0.8 }), "never the unfiltered value")
  assert_equal(seen[1].voice_idx, 1); assert_near(seen[1].value, 0.8, 1e-9)
  assert_equal(seen[1].previous, 0, "the previous stored value")
  params:set("v1_probe", 0.3)
  assert_near(params:get("v1_probe"), 0.3, 1e-9, "a value the filter keeps")
  assert_near(seen[#seen].previous, 0.5, 1e-9)
  -- a voice param (param_order) too
  params:set("v1_freq", 333)
  assert_near(params:get("v1_freq"), 300, 1e-6, "freq filtered")
  assert_near(S.voices[1].params.freq, 300, 1e-6, "and stored")
  assert_near(context.calls_named("setVoiceParam")[#context.calls_named("setVoiceParam")].args[3], 300, 1e-6,
    "and sent")
end)

-- 3.1's LFO destinations, in option order: their indices are stored in PSETs
-- and scenes, so they never move
local function built_in_lfo_labels()
  local labels = { "none", "density", "drift", "filt freq", "filt res", "filt mix", "dly time", "dly fdbk",
    "dly mix", "rev mix", "rev size", "rev damp" }
  for voice_idx = 1, 7 do
    for _, suffix in ipairs({ "main", "size", "dens", "pitch", "spread", "pos", "rate", "scan" }) do
      table.insert(labels, "v" .. voice_idx .. " " .. suffix)
    end
  end
  return labels
end

test("built-in LFO destinations keep their indices", function()
  local labels = built_in_lfo_labels()
  load_strata()
  local destinations = local_value("LFO_DESTINATIONS")
  -- the script's own registrations (lib/history.lua's) follow 3.1's list:
  -- seven per per-voice record, one per global (lib/macros.lua's)
  local own = 0
  for _, entry in ipairs(local_value("S").registry.lfo_destinations) do own = own + (entry.global and 1 or 7) end
  assert_equal(#destinations, #labels + own, "3.1's list exactly, then the script's registered ones")
  for index, label in ipairs(labels) do assert_equal(destinations[index].label, label, "index " .. index) end
  -- two registered destinations go after every built-in one: by
  -- registration, then voice
  load_with(function(S)
    S.register_voice_params(probe_record())
    S.register_lfo_destination("probe", "probe")
    S.register_lfo_destination("pswitch", "probe_switch")
  end)
  destinations = local_value("LFO_DESTINATIONS")
  for index, label in ipairs(labels) do assert_equal(destinations[index].label, label, "still index " .. index) end
  local option_labels = params:lookup_param("strata_lfo1_dest").options
  for voice_idx = 1, 7 do
    local first = #labels + own + voice_idx
    local second = #labels + own + 7 + voice_idx
    assert_equal(destinations[first].label, "v" .. voice_idx .. " probe")
    assert_equal(destinations[first].resolve(), "v" .. voice_idx .. "_probe")
    assert_equal(destinations[second].label, "v" .. voice_idx .. " pswitch")
    assert_equal(destinations[second].resolve(), "v" .. voice_idx .. "_probe_switch")
    assert_equal(option_labels[first], "v" .. voice_idx .. " probe", "the dest param's options follow")
  end
  assert_equal(#destinations, #labels + own + 14)
  assert_equal(params:lookup_param("strata_lfo1_dest").count, #labels + own + 14)
  -- an LFO on a registered destination modulates it around its stored value
  params:set("strata_lfo1_dest", #labels + own + 1)
  assert_equal(lfo_destination_id(1), "v1_probe")
  -- a label already used by a built-in destination is refused at init
  local ok = pcall(load_with, function(S) S.register_lfo_destination("dens", "probe") end)
  assert_true(not ok, "a registered label never repeats a built-in one")
end)

test("the LFO page's ALT+E3 groups keep each voice and add the registered destinations", function()
  local context = load_with(function(S)
    S.register_voice_params(probe_record())
    S.register_lfo_destination("probe", "probe")
  end)
  finish_startup(context)
  local S = local_value("S")
  local built_in = #built_in_lfo_labels()
  assert_equal(S.lib.lfos.BUILT_IN_DESTINATIONS, built_in)
  -- each registered destination is a group from its v1 (#511): the script's own, then the probe
  -- (the global ones, lib/macros.lua's, are one group of one each)
  local registered_starts, next_index, globals_start = {}, built_in + 1, nil
  for _, entry in ipairs(S.registry.lfo_destinations) do
    if not entry.global then
      table.insert(registered_starts, next_index)
    elseif not globals_start then
      globals_start = next_index
      table.insert(registered_starts, next_index)
    end
    next_index = next_index + (entry.global and 1 or 7)
  end
  assert_equal(table.concat(lfo_dest_group_starts(), " "), "1 2 13 21 29 37 45 53 61 " .. table.concat(registered_starts, " "))
  assert_equal(S.LFO_DESTINATIONS[registered_starts[#registered_starts]].label, "v1 probe")
  -- ALT+E3 on the destination field: none, the globals, each v<i> main, then the registered group
  h.show_page("LFO")
  S.lfo_field = 1
  params:set("strata_lfo1_dest", 1)
  local landed = {}
  key(1, 1)
  for _ = 1, 10 do
    enc(3, 1)
    table.insert(landed, S.LFO_DESTINATIONS[params:get("strata_lfo1_dest")].label)
  end
  key(1, 0)
  -- the registered groups start at the first registered destination (the
  -- script's own, lib/history.lua's, before the test's probe), then the next
  local first_registered = S.LFO_DESTINATIONS[built_in + 1].label
  local second_registered = S.LFO_DESTINATIONS[built_in + 8].label
  assert_equal(table.concat(landed, ","),
    "density,v1 main,v2 main,v3 main,v4 main,v5 main,v6 main,v7 main," .. first_registered .. "," .. second_registered)
end)

test("registered fx params grow the fx group and follow its 11 params", function()
  load_with(function(S)
    S.register_fx_params({ name = "probe fx", count = 2, add = function()
      params:add_binary("probe_bypass", "probe bypass", "toggle", 0)
      params:add_binary("probe_other", "probe other", "toggle", 0)
    end })
  end)
  -- the script's own registered fx params (lib/voice_mix.lua's bypass) come first
  local own = 0
  for _, record in ipairs(local_value("S").registry.fx_params) do
    if record.name ~= "probe fx" then own = own + record.count end
  end
  assert_equal(params:lookup_param("strata_fx").n, 13 + own, "11 plus the registered count")
  local position = {}
  for index, param in ipairs(params.params) do position[param.id] = index end
  assert_equal(position["probe_bypass"], position["drift_amount"] + own + 1, "after the 11, tape drift last of them")
  assert_equal(position["probe_other"], position["probe_bypass"] + 1)
end)

-- Three records: probe (grain), a new section "probe sect" before crossmod
-- shown only for buffer voices, and a new section "tail" with no `before`
local function register_row_records(S)
  S.register_voice_params(probe_record())
  local before = probe_record({ name = "sect", count = 1, grain_keys = {}, scene_defaults = { sect_level = 0 },
    discrete = {}, voice_rows = { section = "probe sect", rows = { "sect_level" }, before = "crossmod",
      when = function(voice_idx) return voice_uses_buffer(voice_idx) end } })
  function before.add(voice_idx)
    S.lib.params_setup.add_voice_extra(voice_idx, before, "sect_level",
      { type = "control", name = "sect level", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
  end
  S.register_voice_params(before)
  local tail = probe_record({ name = "tail", count = 1, grain_keys = {}, scene_defaults = { tail_mode = 1 },
    discrete = { tail_mode = { 1, 2 } }, voice_rows = { section = "tail", rows = { "tail_mode" } } })
  function tail.add(voice_idx)
    S.lib.params_setup.add_voice_extra(voice_idx, tail, "tail_mode",
      { type = "option", name = "tail mode", options = { "a", "b" }, default = 1 })
  end
  S.register_voice_params(tail)
end

-- "<section>" per label row and "<section>:<param id>" per field
local function row_outline(voice_idx)
  local outline = {}
  for _, row in ipairs(voice_page_rows(voice_idx)) do
    table.insert(outline, row.param_id and (row.section .. ":" .. row.param_id .. ":" .. row.kind) or row.section)
  end
  return table.concat(outline, " ")
end

test("registered rows appear in their VOICE section, new sections in place, binary rows have kind binary", function()
  load_with(register_row_records)
  local outline = row_outline(1)
  assert_true(outline:find("grain:v1_grain_mode:option grain:v1_probe:control grain:v1_probe_switch:binary crossmod ",
    1, true), "probe rows end the grain section: " .. outline)
  assert_true(not outline:find("probe sect", 1, true), "a synth voice has no probe sect section")
  -- (after mix and the sections registered before it: lib/variation.lua's)
  assert_true(outline:find("mix:v1_pan:control mix:v1_freeze:binary ", 1, true)
    and outline:find(" tail tail:v1_tail_mode:option$"), "tail after mix: " .. outline)
  params:set("v1_source", 2)   -- buffer 1
  outline = row_outline(1)
  assert_true(outline:find("grain:v1_probe_switch:binary probe sect probe sect:v1_sect_level:control crossmod ",
    1, true), "a buffer voice's probe sect goes before crossmod: " .. outline)
  -- a row on the VOICE page shows its value (binary as on or off)
  local context = load_with(register_row_records); finish_startup(context)
  h.show_page("VOICE")
  local S = local_value("S")
  S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of("v1_probe_switch"))
  redraw()
  assert_true(h.screen_shows(context, "off"), "a binary row shows off")
  params:set("v1_probe_switch", 1); redraw()
  assert_true(h.screen_shows(context, "on"), "and on")
  h.assert_screen_layout(context, "VOICE on a registered binary row")
end)

test("VOICE lays out registered rows and sections on every voice and source", function()
  local context = load_with(register_row_records); finish_startup(context)
  h.show_page("VOICE")
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    S.selected_voice = voice_idx
    for _, source in ipairs({ S.constants.SOURCE_SYNTH, 2, S.constants.SOURCE_INPUT }) do
      params:set("v" .. voice_idx .. "_source", source)
      params:set("v" .. voice_idx .. "_probe_switch", voice_idx % 2)
      for index, row in ipairs(voice_page_rows(voice_idx)) do
        if row.param_id and (row.param_id:find("probe", 1, true) or row.param_id:find("sect", 1, true)
            or row.param_id:find("tail", 1, true)) then
          S.lib.pages_voice.place_cursor(index)
          for _, alt in ipairs({ 0, 1 }) do
            key(1, alt); redraw()
            h.assert_screen_layout(context, string.format("VOICE v%d source %d on %s%s", voice_idx, source,
              row.param_id, alt == 1 and " with ALT" or ""))
          end
          key(1, 0)
        end
      end
    end
  end
end)

test("a registered record's layout states are VOICE's too", function()
  load_with(function(S)
    S.register_voice_params(probe_record({ layout_states = { { name = "probe on", setup = function()
      params:set("v1_probe_switch", 1)
    end } } }))
  end)
  local S = local_value("S")
  local states = S.registry.pages[S.constants.UI_PAGES.index.VOICE].layout_states
  local found
  for _, state in ipairs(states) do if state.name == "probe on" then found = state end end
  assert_true(found, "VOICE lists the record's state")
  assert_true(states[1].name ~= "probe on", "after VOICE's own")
end)

test("registrations made by a module included after the reader still take effect", function()
  local late_module = [[
return function(S)
  local M = {}
  local record = {name = "late", count = 1, grain_keys = {late = "posSpread"}, scene_defaults = {late = 0},
    voice_rows = {section = "mix", rows = {"late"}}, fader = false}
  function record.add(voice_idx)
    S.lib.params_setup.add_voice_extra(voice_idx, record, "late",
      {type = "control", name = "late", controlspec = controlspec.new(0, 1, "lin", 0.01, 0)})
  end
  S.register_voice_params(record)
  S.register_scene_field({id = "late_level", default = 0.25})
  S.register_fx_params({name = "late fx", count = 1, add = function()
    params:add{type = "control", id = "late_level", name = "late level", controlspec = controlspec.new(0, 1, "lin", 0.01, 0.25)}
  end})
  S.register_lfo_destination("late", "late")
  return M
end
]]
  local strata_source
  for _, source in ipairs(read_lua_sources()) do
    if source.path == "strata.lua" then strata_source = source.text end
  end
  local anchor = 'S.lib.sequencer = include("lib/sequencer")(S)\n'
  assert_true(strata_source:find(anchor, 1, true), "strata.lua includes the sequencer last")
  local patched = strata_source:gsub(anchor:gsub("%p", "%%%0"),
    anchor .. 'S.lib.probe_late = include("lib/probe_late")(S)\n')
  local context = load_strata({ source = patched, module_sources = { ["lib/probe_late"] = late_module } })
  finish_startup(context)
  local S = local_value("S")
  assert_equal(params:get("v1_late"), 0, "the voice param exists")
  assert_equal(params:get("late_level"), 0.25, "the fx param exists")
  assert_equal(S.LFO_DESTINATIONS[#S.LFO_DESTINATIONS].label, "v7 late", "the LFO destination exists")
  assert_true((row_outline(1) .. " "):find("mix:v1_late:control ", 1, true), "the VOICE row exists")
  capture_scene(1)
  assert_equal(S.scenes[1].data.late_level, 0.25, "the scene field is captured")
  assert_equal(S.scenes[1].data.voices[1].extras.late, 0, "and the voice param")
end)

test("a version 2 scene migrates to 6 with every registered default", function()
  local function register(S)
    S.register_voice_params(probe_record())
    S.register_fx_params({ name = "probe fx", count = 1, add = function()
      params:add{ type = "control", id = "probe_level", name = "probe level",
        controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5) }
    end })
    S.register_scene_field({ id = "probe_level", default = 0.5 })
  end
  local context = load_with(register, { data_subdir = "v2_to_v3" })
  finish_startup(context)
  local S = local_value("S")
  assert_equal(S.constants.SCENE_DATA_VERSION, 6)
  params:set("v2_probe", 0.6); params:set("probe_level", 0.9)
  capture_scene(2)
  local scene = deep_copy(S.scenes[2])
  assert_near(scene.data.voices[2].extras.probe, 0.6, 1e-9, "captured")
  assert_near(scene.data.probe_level, 0.9, 1e-9, "the scene field captured")
  -- as 3.1 wrote it: no extras, no registered globals
  for voice_idx = 1, 7 do scene.data.voices[voice_idx].extras = nil end
  scene.data.probe_level = nil
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  tab.save({ version = 2, scenes = { [2] = scene } }, context.data_dir .. "strata/scenes.data")
  context = load_with(register, { data_subdir = "v2_to_v3" })
  S = local_value("S")
  assert_true(S.scenes[2].populated, "the v2 file loads")
  for voice_idx = 1, 7 do
    local extras = S.scenes[2].data.voices[voice_idx].extras
    assert_equal(extras.probe, 0, "voice " .. voice_idx .. " probe default")
    assert_equal(extras.probe_switch, 0, "voice " .. voice_idx .. " probe_switch default")
  end
  assert_equal(S.scenes[2].data.probe_level, 0.5, "the scene field default")
  assert_true(table.concat(context.printed, "\n"):find("migrated scenes file from version 2"), "reported")
  params:set("v2_probe", 0.6)
  recall_scene(2, 0)
  assert_equal(params:get("v2_probe"), 0, "the recall applies the default")
  save_scenes_to_disk()
  local saved = context.tab.load(context.data_dir .. "strata/scenes.data")
  assert_equal(saved.version, 6, "saved as version 6")
  -- with nothing registered, a v2 scene still gains an empty extras table
  tab.save({ version = 2, scenes = { [2] = scene } }, context.data_dir .. "strata/scenes.data")
  context = load_strata({ data_subdir = "v2_to_v3" })
  assert_equal(type(local_value("S").scenes[2].data.voices[1].extras), "table", "extras created")
end)

test("scenes validate registered fields", function()
  load_with(function(S)
    S.register_voice_params(probe_record())
    S.register_fx_params({ name = "probe fx", count = 2, add = function()
      params:add{ type = "control", id = "probe_level", name = "probe level",
        controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5) }
      params:add_option("probe_mode", "probe mode", { "a", "b", "c" }, 1)
    end })
    S.register_scene_field({ id = "probe_level", default = 0.5 })
    S.register_scene_field({ id = "probe_mode", default = 1, discrete = true })
  end)
  capture_scene(1)
  local S = local_value("S")
  local good = deep_copy(S.scenes[1])
  assert_true(validate_scene(good), "a captured scene validates")
  local function rejected(change, what)
    local scene = deep_copy(good)
    change(scene.data)
    assert_true(not validate_scene(scene), what)
  end
  rejected(function(data) data.voices[1].extras.probe = "x" end, "an extra is a number")
  rejected(function(data) data.voices[1].extras.probe = 0 / 0 end, "never NaN")
  rejected(function(data) data.voices[1].extras.probe_switch = 2 end, "a discrete extra in its range")
  rejected(function(data) data.voices[1].extras.probe_switch = 0.5 end, "a discrete extra is whole")
  rejected(function(data) data.voices[1].extras.unknown = 1 end, "only registered keys")
  rejected(function(data) data.voices[1].extras = 3 end, "extras is a table")
  rejected(function(data) data.probe_level = "x" end, "a scene field is a number")
  rejected(function(data) data.probe_mode = 4 end, "an option field in its range")
  rejected(function(data) data.probe_mode = 1.5 end, "a discrete field is whole")
end)

test("discrete extras switch at the end of a transition, after the source", function()
  local context = load_with(function(S)
    S.register_voice_params(probe_record())
    S.register_fx_params({ name = "probe fx", count = 2, add = function()
      params:add{ type = "control", id = "probe_level", name = "probe level",
        controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5) }
      params:add_option("probe_mode", "probe mode", { "a", "b", "c" }, 1)
    end })
    S.register_scene_field({ id = "probe_level", default = 0.5 })
    S.register_scene_field({ id = "probe_mode", default = 1, discrete = true })
  end)
  finish_startup(context)
  params:set("v2_source", 3); params:set("v2_probe", 0.8); params:set("v2_probe_switch", 1)
  params:set("probe_level", 1); params:set("probe_mode", 3)
  capture_scene(1)
  params:set("v2_source", 1); params:set("v2_probe", 0); params:set("v2_probe_switch", 0)
  params:set("probe_level", 0); params:set("probe_mode", 1)
  -- the order the actions run in
  local order = {}
  for _, id in ipairs({ "v2_source", "v2_probe_switch" }) do
    local param = params:lookup_param(id)
    local action = param.action
    param.action = function(...) table.insert(order, id); return action(...) end
  end
  recall_scene(1, 4); wake(context, "scene_transition_clock")
  assert_true(params:get("v2_probe") > 0 and params:get("v2_probe") < 0.8, "a continuous extra crossfades")
  assert_true(params:get("probe_level") > 0 and params:get("probe_level") < 1, "so does a continuous field")
  assert_equal(params:get("v2_probe_switch"), 0, "a discrete extra waits")
  assert_equal(params:get("probe_mode"), 1, "so does a discrete field")
  assert_equal(#order, 0, "nothing discrete has run")
  context.clock.run_for(5)
  assert_near(params:get("v2_probe"), 0.8, 1e-9); assert_equal(params:get("v2_probe_switch"), 1)
  assert_equal(params:get("probe_mode"), 3); assert_near(params:get("probe_level"), 1, 1e-9)
  assert_equal(table.concat(order, ","), "v2_source,v2_probe_switch", "the source first, then the extra")
  for _, target in ipairs(scene_transition_targets(local_value("S").scenes[1].data)) do
    assert_true(target.id ~= "v2_probe_switch" and target.id ~= "probe_mode", target.id .. " is not crossfaded")
  end
end)

test("randomize, mutations and the fader pages never touch registered params", function()
  local context = load_with(function(S) S.register_voice_params(probe_record()) end)
  finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, 7 do params:set("v" .. voice_idx .. "_probe", 0.37) end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(5)
  for voice_idx = 1, 7 do
    params:set("v" .. voice_idx .. "_source", voice_idx % 3 == 0 and 2 or 1)
    randomize_voice(voice_idx)
  end
  for _ = 1, 20 do gentle_mutate() end
  for _ = 1, 20 do drift_update() end
  for voice_idx = 1, 7 do
    assert_near(params:get("v" .. voice_idx .. "_probe"), 0.37, 1e-9, "voice " .. voice_idx .. " untouched")
    assert_equal(params:get("v" .. voice_idx .. "_probe_switch"), 0)
    for _, param_id in ipairs(fader_param_ids(voice_idx)) do
      assert_true(not param_id:find("probe", 1, true), param_id .. " is not a registered param")
    end
  end
end)

test("every registered scene default equals its param's default", function()
  load_strata()
  local S = local_value("S")
  for _, record in ipairs(S.registry.voice_params) do
    for key, default in pairs(record.scene_defaults or {}) do
      for voice_idx = 1, S.constants.NUM_VOICES do
        local param_id = "v" .. voice_idx .. "_" .. key
        assert_equal(param_default(param_id), default, record.name .. ": " .. param_id)
      end
    end
  end
  for _, field in ipairs(S.registry.scene_fields) do
    assert_equal(param_default(field.id), field.default, "scene field " .. field.id)
  end
end)

test("S.performance starts standard and sets the record duration range", function()
  load_strata()
  local S = local_value("S")
  assert_equal(S.performance.tier, "standard")
  assert_equal(S.performance.buffer_seconds, 16)
  assert_equal(S.performance.max_grains, 128)
  assert_equal(S.performance.history_seconds, 16)
  assert_equal(S.constants.STANDARD_BUFFER_SECONDS, 16)
  assert_true(S.performance ~= S.constants.STANDARD_PERFORMANCE, "a copy, never the constant itself")
  assert_equal(params:lookup_param("record_duration").controlspec.maxval, 16)
  -- the spec follows S.performance as init fills it (lib/performance.lua)
  h.write_performance_active({ tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60 })
  load_strata()
  assert_equal(params:lookup_param("record_duration").controlspec.maxval, 60)
  assert_equal(local_value("S").constants.STANDARD_PERFORMANCE.buffer_seconds, 16, "the constant is unchanged")
end)

test("register_grain_restart and register_alt_release refuse a non-function", function()
  local context = load_strata()
  local S = local_value("S")
  local grain_restart, alt_release = #S.registry.grain_restart, #S.registry.alt_release
  assert_true(not pcall(S.register_grain_restart, 1), "a number is refused")
  assert_true(not pcall(S.register_alt_release, nil), "nil is refused")
  assert_equal(#S.registry.grain_restart, grain_restart, "no grain restart hook added")
  assert_equal(#S.registry.alt_release, alt_release, "no ALT release hook added")
end)

test("register_menu_close checks its argument, and the hooks run as the menu closes", function()
  local runs, order = 0, {}
  local context = load_with(function(S)
    assert_true(not pcall(S.register_menu_close, "x"), "a string is refused")
    assert_true(not pcall(S.register_menu_close, nil), "nil is refused")
    S.register_menu_close(function() order[#order + 1] = "raises"; error("boom") end)
    S.register_menu_close(function() runs = runs + 1; order[#order + 1] = "counts" end)
  end)
  finish_startup(context)
  local S = local_value("S")
  assert_equal(runs, 0, "nothing runs before the menu closes")
  local printed = {}
  local real_print = print
  print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
  local ok, err = pcall(function()
    _menu.set_mode(true)
    assert_equal(runs, 0, "nothing runs as the menu opens")
    _menu.set_mode(false)
  end)
  print = real_print
  assert_true(ok, "the menu closes: " .. tostring(err))
  assert_equal(_menu.mode, false, "the menu is closed")
  assert_equal(runs, 1, "the hook registered before init ran once")
  assert_equal(table.concat(order, " "), "raises counts", "a hook that raises does not stop the next one")
  assert_equal(#printed, 1, "the failure prints one line")
  assert_true(printed[1]:find("boom", 1, true) ~= nil, "naming the error: " .. tostring(printed[1]))
  local count = #S.registry.menu_close
  assert_true(not pcall(S.register_menu_close, 1), "a number is refused after init too")
  assert_equal(#S.registry.menu_close, count, "nothing refused was added")
end)

test("register_invariant checks its arguments and refuses a duplicate name", function()
  load_strata()
  local S = local_value("S")
  local count = #S.registry.invariants
  assert_true(not pcall(S.register_invariant, "", function() end), "an empty name is refused")
  assert_true(not pcall(S.register_invariant, "probe invariant", "x"), "a non-function is refused")
  assert_true(not pcall(S.register_invariant, "pattern clock", function() end), "a second pattern clock is refused")
  assert_equal(#S.registry.invariants, count, "nothing refused was added")
  local function holds() end
  S.register_invariant("probe invariant", holds)
  assert_equal(#S.registry.invariants, count + 1, "a new name with a function is accepted")
  local record = S.registry.invariants[count + 1]
  assert_equal(record.name, "probe invariant", "the record's name")
  assert_equal(record.fn, holds, "the record's function")
end)

test("a record's scene_ranges reject an extra outside its range", function()
  local context = load_with(function(S)
    S.register_voice_params(probe_record({
      scene_defaults = { probe = 0.5, probe_switch = 0 },
      scene_ranges = { probe = { 0, 1 } },
    }))
  end)
  finish_startup(context)
  capture_scene(2)
  local scene = deep_copy(local_value("scenes")[2])
  assert_true(validate_scene(scene), "a captured scene validates")
  scene.data.voices[1].extras.probe = 1.5
  assert_true(not validate_scene(scene), "1.5 lies outside 0-1")
  scene.data.voices[1].extras.probe = 0.75
  assert_true(validate_scene(scene), "0.75 lies inside it")

  local function refused(overrides)
    local S = local_value("S")
    overrides.name = "probe_range"
    return not pcall(S.register_voice_params, probe_record(overrides))
  end
  assert_true(refused({ scene_ranges = { probe_switch = { 0, 1 } } }), "a range on a discrete key is refused")
  assert_true(refused({ scene_ranges = { probe = { 0.6, 1 } }, scene_defaults = { probe = 0.5, probe_switch = 0 } }),
    "a range that excludes the default is refused")
end)

test("the 3.3 constants", function()
  load_strata()
  local constants = local_value("S").constants
  assert_equal(constants.NUM_BOOKMARKS, 4)
  local sources = constants.RECORD_SOURCES
  assert_equal(#sources, 10)
  assert_equal(sources[1], "input"); assert_equal(sources[2], "pre-master"); assert_equal(sources[3], "post-master")
  assert_equal(sources[4], "voice 1"); assert_equal(sources[10], "voice 7")
  assert_equal(constants.RECORD_SYNC.beats_per_bar, 4)
  assert_equal(constants.RECORD_SYNC.lead_seconds, 0.25)
  assert_equal(constants.FILES.restart_seconds, 0.3)
  assert_equal(constants.WAVEFORMS.refresh_seconds, 2)
  assert_equal(constants.PLAYHEADS.update_hz, 15)
  assert_equal(constants.NORNS_SAMPLE_RATE, 48000)
  assert_equal(constants.SCENE_DATA_VERSION, 6)
end)

-- 3.4's registries (lib/state.lua, design §0.1): a fresh S from lib/state,
-- so a record no reader knows yet never reaches the script's init
local function fresh_state()
  load_strata()
  return include("lib/state")()
end

local function refused(fn, ...) return not pcall(fn, ...) end

-- A complete record of each 3.4 kind, with overrides
local function scene_block(overrides)
  local record = { key = "probe_block", default = function() return {} end, capture = function() return {} end,
    validate = function() return true end, apply = function() end, discrete = true }
  for field, value in pairs(overrides or {}) do record[field] = value end
  return record
end
local function mod_source(overrides)
  local record = { key = "probe1", name = "P1", section = "probes", value = function() return 0 end,
    range = { -1, 1 } }
  for field, value in pairs(overrides or {}) do record[field] = value end
  return record
end

test("each 3.4 register function checks its argument and refuses a duplicate", function()
  local S = fresh_state()
  local function names_field(fn, record, field)
    local ok, err = pcall(fn, record)
    assert_true(not ok and tostring(err):find(field, 1, true) ~= nil, "names " .. field .. ": " .. tostring(err))
  end
  -- scene blocks, by key
  S.register_scene_block(scene_block())
  assert_equal(#S.registry.scene_blocks, 1, "a block is kept")
  assert_true(refused(S.register_scene_block, scene_block()), "a second probe_block")
  local keyless = scene_block(); keyless.key = nil
  assert_true(refused(S.register_scene_block, keyless), "a block without a key")
  assert_true(refused(S.register_scene_block, scene_block({ key = 3 })), "a key is a string")
  assert_true(refused(S.register_scene_block, scene_block({ key = "b2", apply = 1 })), "apply is a function")
  assert_true(refused(S.register_scene_block, scene_block({ key = "b2", through_zero = 1 })), "through_zero is a function")
  names_field(S.register_scene_block, scene_block({ key = "b2", captur = function() end }), "captur")
  S.register_scene_block(scene_block({ key = "b3", through_zero = function() return {} end }))
  -- scene migrations, by name
  S.register_scene_migration({ name = "probe", before_version = 6, migrate = function() end })
  assert_true(refused(S.register_scene_migration, { name = "probe", before_version = 6, migrate = function() end }),
    "a second probe migration")
  assert_true(refused(S.register_scene_migration, { before_version = 6, migrate = function() end }), "a name")
  assert_true(refused(S.register_scene_migration, { name = "m2", before_version = 5.5, migrate = function() end }),
    "a whole version")
  names_field(S.register_scene_migration, { name = "m3", before_version = 6, migrate = function() end, after = 1 }, "after")
  -- PSET hooks, by name; each function optional
  S.register_pset_hook({ name = "probe" })
  S.register_pset_hook({ name = "probe2", write = function() end, read = function() end, delete = function() end })
  assert_true(refused(S.register_pset_hook, { name = "probe" }), "a second probe hook")
  assert_true(refused(S.register_pset_hook, { write = function() end }), "a name")
  assert_true(refused(S.register_pset_hook, { name = "h3", read = "x" }), "read is a function")
  names_field(S.register_pset_hook, { name = "h4", saved = function() end }, "saved")
  -- step outputs, by name; stop and available optional
  S.register_step_output({ name = "probe", play = function() end })
  assert_true(refused(S.register_step_output, { name = "probe", play = function() end }), "a second probe output")
  assert_true(refused(S.register_step_output, { play = function() end }), "an output without a name")
  assert_true(refused(S.register_step_output, { name = "o2" }), "play is a function")
  assert_true(refused(S.register_step_output, { name = "o3", play = function() end, stop = 1 }), "stop is a function")
  names_field(S.register_step_output, { name = "o4", play = function() end, avail = function() end }, "avail")
  -- mod sources, by key
  S.register_mod_source(mod_source())
  assert_true(refused(S.register_mod_source, mod_source()), "a second probe1")
  local unkeyed = mod_source(); unkeyed.key = nil
  assert_true(refused(S.register_mod_source, unkeyed), "a source without a key")
  assert_true(refused(S.register_mod_source, mod_source({ key = "p2", name = "TOOLONG" })), "a name of at most 4")
  assert_true(refused(S.register_mod_source, mod_source({ key = "p3", range = { 1, 1 } })), "range[1] < range[2]")
  assert_true(refused(S.register_mod_source, mod_source({ key = "p4", value = 0 })), "value is a function")
  assert_true(refused(S.register_mod_source, mod_source({ key = "p5", section = "" })), "a section")
  assert_true(refused(S.register_mod_source, mod_source({ key = "p6", row = { press = 1 } })), "a row's press is a function")
  names_field(S.register_mod_source, mod_source({ key = "p7", visibl = function() end }), "visibl")
  names_field(S.register_mod_source, mod_source({ key = "p8", row = { hint = function() end } }), "hint")
  S.register_mod_source(mod_source({ key = "p9", name = "P9", describe = function() return "" end,
    visible = function() return true end, row = { enc = function() end, fine_enc = function() end,
    press = function() end, alt_press = function() end, hints = function() return "" end } }))
  -- the plain hooks
  assert_true(refused(S.register_param_touch, 1), "a touch hook is a function")
  assert_true(refused(S.register_lock_change, "x"), "a lock hook is a function")
  S.register_param_touch(function() end); S.register_lock_change(function() end)
  assert_equal(#S.registry.param_touch, 1, "a touch hook is kept")
  assert_equal(#S.registry.lock_change, 1, "a lock hook is kept")
  -- a global LFO destination joins the per-voice ones, in registration order
  S.register_lfo_destination("probe", "probe")
  S.register_lfo_global_destination("macro 1", "macro_1")
  local destination = S.registry.lfo_destinations[2]
  assert_equal(destination.label, "macro 1"); assert_equal(destination.param_id, "macro_1")
  assert_equal(destination.global, true)
  assert_true(refused(S.register_lfo_global_destination, "macro 1", "macro_2"), "a second macro 1")
  assert_true(refused(S.register_lfo_global_destination, "probe", "probe_2"), "a label a per-voice one has")
  assert_true(refused(S.register_lfo_global_destination, "macro 3", nil), "a param id is a string")
  assert_equal(#S.registry.lfo_destinations, 2, "nothing refused was added")
end)

test("scene blocks, scene migrations and PSET hooks close at init; the hooks read at use stay open", function()
  load_strata()
  local S = local_value("S")
  local function names(fn, record, registry)
    local ok, err = pcall(fn, record)
    assert_true(not ok and tostring(err):find(registry, 1, true) ~= nil, "names " .. registry .. ": " .. tostring(err))
  end
  names(S.register_scene_block, scene_block(), "scene_blocks")
  names(S.register_scene_migration, { name = "late", before_version = 6, migrate = function() end }, "scene_migrations")
  names(S.register_pset_hook, { name = "late" }, "pset_hooks")
  names(function(label) S.register_lfo_global_destination(label, "late") end, "late", "lfo_destinations")
  local touch, lock, outputs, sources = #S.registry.param_touch, #S.registry.lock_change, #S.registry.step_outputs,
    #S.registry.mod_sources
  S.register_param_touch(function() end)
  S.register_lock_change(function() end)
  S.register_step_output({ name = "late", play = function() end })
  S.register_mod_source(mod_source({ key = "late" }))
  assert_equal(#S.registry.param_touch, touch + 1, "a touch hook after init")
  assert_equal(#S.registry.lock_change, lock + 1, "a lock hook after init")
  assert_equal(#S.registry.step_outputs, outputs + 1, "a step output after init")
  assert_equal(#S.registry.mod_sources, sources + 1, "a mod source after init")
end)

test("a scene field's set function is kept on its record", function()
  local S = fresh_state()
  local function set(value) end
  S.register_scene_field({ id = "probe_field", default = 0, set = set })
  S.register_scene_field({ id = "plain_field", default = 1, discrete = true })
  assert_equal(S.registry.scene_fields[1].set, set, "the record keeps set")
  assert_equal(S.registry.scene_fields[2].set, nil, "a field without one has none")
  assert_equal(S.registry.scene_fields[2].discrete, true)
  assert_true(refused(S.register_scene_field, { id = "bad_set", default = 0, set = 1 }), "set is a function")
end)

end

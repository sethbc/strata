-- test/unit/registries_test.lua
-- The registries 3.2's modules add to (lib/state.lua): voice params
-- (S.registry.voice_params, add_voice_param), scene fields, source change
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
    local add_voice_param = local_value("S").lib.params_setup.add_voice_param
    add_voice_param(voice_idx, record, "probe",
      { type = "control", name = "probe", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
    add_voice_param(voice_idx, record, "probe_switch",
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
    assert_equal(S.voices[voice_idx].values.probe, 0, "and its stored value")
  end
  context.clear_engine_calls()
  params:set("v1_probe", 0.4)
  assert_near(S.voices[1].values.probe, 0.4, 1e-9, "stored into values")
  assert_true(find_call(context, 1, "setGrainParam", { 0, "posSpread", 0.4 }), "sent while the voice runs")
  -- a stopped voice stores but sends nothing
  context.clear_engine_calls()
  params:set("v3_probe", 0.7)
  assert_near(S.voices[3].values.probe, 0.7, 1e-9)
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
  -- (the built-in records, under their own separators, come before extras)
  local before = 0
  for _, record in ipairs(S.registry.voice_params) do
    if record.name == "probe" then break end
    if record.separator == nil then before = before + record.count end
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
    local_value("S").lib.params_setup.add_voice_param(voice_idx, record, "probe_first",
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
  assert_near(S.voices[2].values.probe_first, 0.3, 1e-9, "stored like any registered param")
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
  assert_near(S.voices[1].values.probe, 0.5, 1e-9, "and stores it")
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
  assert_near(S.voices[1].values.freq, 300, 1e-6, "and stored")
  assert_near(context.calls_named("setVoiceParam")[#context.calls_named("setVoiceParam")].args[3], 300, 1e-6,
    "and sent")
end)

-- The LFO destinations by voice (3.7, design decision 24): none, the
-- globals, then per voice its built-in ones followed by `registered` (the
-- per-voice labels registered, in registration order), then the macros
local function lfo_labels(registered)
  local labels = { "none", "density", "drift", "filt freq", "filt res", "filt mix", "dly time", "dly fdbk",
    "dly mix", "rev mix", "rev size", "rev damp" }
  for voice_idx = 1, 7 do
    for _, suffix in ipairs({ "main", "size", "dens", "pitch", "spread", "pos", "rate", "scan" }) do
      table.insert(labels, "v" .. voice_idx .. " " .. suffix)
    end
    for _, suffix in ipairs(registered) do table.insert(labels, "v" .. voice_idx .. " " .. suffix) end
  end
  for m = 1, 16 do table.insert(labels, "macro " .. m) end
  return labels
end

-- the script's own per-voice registrations (lib/history.lua's, lib/voice_mix.lua's)
local OWN_PER_VOICE = { "hist", "vfilt", "dsend", "rsend", "amp" }

local function list_labels(destinations)
  local labels = {}
  for index, destination in ipairs(destinations) do labels[index] = destination.label end
  return labels
end

test("LFO destinations come by voice, and a registered one joins its voice", function()
  load_strata()
  local destinations = local_value("LFO_DESTINATIONS")
  assert_equal(table.concat(list_labels(destinations), ","), table.concat(lfo_labels(OWN_PER_VOICE), ","),
    "the built-in ones by voice, the script's registered ones in each voice, then the macros")
  -- two registered destinations go at the end of each voice's group: by
  -- registration
  load_with(function(S)
    S.register_voice_params(probe_record())
    S.register_lfo_destination("probe", "probe")
    S.register_lfo_destination("pswitch", "probe_switch")
  end)
  destinations = local_value("LFO_DESTINATIONS")
  local registered = {}
  for _, suffix in ipairs(OWN_PER_VOICE) do registered[#registered + 1] = suffix end
  registered[#registered + 1] = "probe"; registered[#registered + 1] = "pswitch"
  local expected = lfo_labels(registered)
  assert_equal(table.concat(list_labels(destinations), ","), table.concat(expected, ","), "inside each voice")
  assert_equal(table.concat(params:lookup_param("strata_lfo1_dest").options, ","), table.concat(expected, ","),
    "the dest param's options follow")
  local probe = 0
  for index, destination in ipairs(destinations) do
    if destination.label == "v1 probe" then probe = index end
  end
  assert_equal(destinations[probe].resolve(), "v1_probe")
  assert_equal(destinations[probe + 1].resolve(), "v1_probe_switch")
  -- an LFO on a registered destination modulates it around its stored value
  params:set("strata_lfo1_dest", probe)
  assert_equal(lfo_destination_id(1), "v1_probe")
  -- a label already used by a built-in destination is refused at init
  local ok = pcall(load_with, function(S) S.register_lfo_destination("dens", "probe") end)
  assert_true(not ok, "a registered label never repeats a built-in one")
end)

test("the LFO page's ALT+E3 groups keep each voice, its registered destinations inside it", function()
  local context = load_with(function(S)
    S.register_voice_params(probe_record())
    S.register_lfo_destination("probe", "probe")
  end)
  finish_startup(context)
  local S = local_value("S")
  -- 1 + 11 + 7 x 14 + 16: each voice's group holds 14 with the probe
  assert_equal(table.concat(lfo_dest_group_starts(), " "), "1 2 13 27 41 55 69 83 97 111")
  -- ALT+E3 on the destination field: none, the globals, each v<i> main, then the macros
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
  assert_equal(table.concat(landed, ","),
    "density,v1 main,v2 main,v3 main,v4 main,v5 main,v6 main,v7 main,macro 1,macro 1")
  assert_equal(S.LFO_DESTINATIONS[110].label, "v7 probe", "the probe ends voice 7's group")
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
    S.lib.params_setup.add_voice_param(voice_idx, before, "sect_level",
      { type = "control", name = "sect level", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
  end
  S.register_voice_params(before)
  local tail = probe_record({ name = "tail", count = 1, grain_keys = {}, scene_defaults = { tail_mode = 1 },
    discrete = { tail_mode = { 1, 2 } }, voice_rows = { section = "tail", rows = { "tail_mode" } } })
  function tail.add(voice_idx)
    S.lib.params_setup.add_voice_param(voice_idx, tail, "tail_mode",
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
    S.lib.params_setup.add_voice_param(voice_idx, record, "late",
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
  local late
  for _, destination in ipairs(S.LFO_DESTINATIONS) do
    if destination.label == "v7 late" then late = destination end
  end
  assert_true(late ~= nil and late.group == "voice 7", "the LFO destination exists, in its voice's group")
  local voice7
  for _, group in ipairs(S.lib.lfos.destination_groups()) do
    if group.name == "voice 7" then voice7 = group end
  end
  assert_equal(S.LFO_DESTINATIONS[voice7.last].label, "v7 late", "and comes last in it")
  assert_true((row_outline(1) .. " "):find("mix:v1_late:control ", 1, true), "the VOICE row exists")
  capture_scene(1)
  assert_equal(S.scenes[1].data.late_level, 0.25, "the scene field is captured")
  assert_equal(S.scenes[1].data.voices[1].values.late, 0, "and the voice param")
end)

test("a scene without the registered fields loads with every registered default", function()
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
  assert_equal(S.constants.SCENE_DATA_VERSION, 9)
  params:set("v2_probe", 0.6); params:set("probe_level", 0.9)
  capture_scene(2)
  local scene = deep_copy(S.scenes[2])
  assert_near(scene.data.voices[2].values.probe, 0.6, 1e-9, "captured")
  assert_near(scene.data.probe_level, 0.9, 1e-9, "the scene field captured")
  -- no registered voice keys, no registered globals
  for voice_idx = 1, 7 do scene.data.voices[voice_idx].values.probe, scene.data.voices[voice_idx].values.probe_switch = nil, nil end
  scene.data.probe_level = nil
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  tab.save({ version = S.constants.SCENE_DATA_VERSION, scenes = { [2] = scene } }, context.data_dir .. "strata/scenes.data")
  context = load_with(register, { data_subdir = "v2_to_v3" })
  S = local_value("S")
  assert_true(S.scenes[2].populated, "the file loads")
  for voice_idx = 1, 7 do
    local extras = S.scenes[2].data.voices[voice_idx].values
    assert_equal(extras.probe, 0, "voice " .. voice_idx .. " probe default")
    assert_equal(extras.probe_switch, 0, "voice " .. voice_idx .. " probe_switch default")
  end
  assert_equal(S.scenes[2].data.probe_level, 0.5, "the scene field default")
  params:set("v2_probe", 0.6)
  recall_scene(2, 0)
  assert_equal(params:get("v2_probe"), 0, "the recall applies the default")
  save_scenes_to_disk()
  local saved = context.tab.load(context.data_dir .. "strata/scenes.data")
  assert_equal(saved.version, 9, "saved as version 9")
  -- with nothing registered, the same scene loads with the built-in keys alone
  tab.save({ version = S.constants.SCENE_FORMAT_FLOOR, scenes = { [2] = scene } }, context.data_dir .. "strata/scenes.data")
  context = load_strata({ data_subdir = "v2_to_v3" })
  assert_true(local_value("S").scenes[2].populated, "it loads")
  assert_equal(local_value("S").scenes[2].data.voices[1].values.probe, nil, "with no probe")
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
  rejected(function(data) data.voices[1].values.probe = "x" end, "an extra is a number")
  rejected(function(data) data.voices[1].values.probe = 0 / 0 end, "never NaN")
  rejected(function(data) data.voices[1].values.probe_switch = 2 end, "a discrete extra in its range")
  rejected(function(data) data.voices[1].values.probe_switch = 0.5 end, "a discrete extra is whole")
  rejected(function(data) data.voices[1].values.unknown = 1 end, "only registered keys")
  rejected(function(data) data.voices[1].values = 3 end, "values is a table")
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
    -- a record's defaults may differ by voice (lib/notes.lua's envelope
    -- times are each voice's own)
    for voice_idx = 1, S.constants.NUM_VOICES do
      for key, default in pairs(S.voice_scene_defaults(record, voice_idx)) do
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
  scene.data.voices[1].values.probe = 1.5
  assert_true(not validate_scene(scene), "1.5 lies outside 0-1")
  scene.data.voices[1].values.probe = 0.75
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
  assert_equal(constants.SCENE_DATA_VERSION, 9)
end)

test("the 3.7 tempo divisions: twelve names, each with its beats", function()
  load_strata()
  local divisions = local_value("S").constants.DIVISIONS
  assert_equal(table.concat(divisions.names, " "), "1/32 1/16T 1/16 1/16D 1/8T 1/8 1/8D 1/4T 1/4 1/4D 1/2 1 bar")
  local beats = { 1 / 8, 1 / 6, 1 / 4, 3 / 8, 1 / 3, 1 / 2, 3 / 4, 2 / 3, 1, 3 / 2, 2, 4 }
  assert_equal(#divisions.beats, #divisions.names, "one length per name")
  for index, value in ipairs(beats) do
    assert_true(math.abs(divisions.beats[index] - value) < 1e-12, divisions.names[index] .. " is " .. value .. " beats")
  end
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
  -- its group (#729): the globals unless it names the macros'; any other is refused
  assert_equal(destination.group, "global", "a global destination without a group joins the globals")
  for _, group in ipairs({ "voice 1", "macro", "none", 3, true }) do
    assert_true(refused(S.register_lfo_global_destination, "macro 3", "macro_3", group),
      "an unknown group " .. tostring(group) .. " is refused")
  end
  S.register_lfo_global_destination("macro 2", "macro_2", "macros")
  assert_equal(S.registry.lfo_destinations[3].group, "macros", "the macros' group is kept")
  S.register_lfo_global_destination("probe 4", "probe_4", "global")
  assert_equal(S.registry.lfo_destinations[4].group, "global")
  assert_equal(#S.registry.lfo_destinations, 4, "nothing refused was added")
end)

test("scene blocks and PSET hooks close at init; the hooks read at use stay open", function()
  load_strata()
  local S = local_value("S")
  local function names(fn, record, registry)
    local ok, err = pcall(fn, record)
    assert_true(not ok and tostring(err):find(registry, 1, true) ~= nil, "names " .. registry .. ": " .. tostring(err))
  end
  names(S.register_scene_block, scene_block(), "scene_blocks")
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

-- 3.7 (design decision 21): no conversion is keyed on a scenes format, so
-- no module registers one
test("there is no scene_migrations registry", function()
  load_strata()
  local S = local_value("S")
  assert_equal(S.registry.scene_migrations, nil, "no registry")
  assert_equal(S.register_scene_migration, nil, "no register function")
  local fresh = include("lib/state")()
  assert_equal(fresh.registry.scene_migrations, nil, "a fresh S has none either")
  fresh.close_registries()  -- closes what init reads, and names no scene_migrations
  for _, source in ipairs(read_lua_sources()) do
    assert_true(not source.text:find("scene_migration", 1, true), source.path .. " names no scene migration")
  end
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

-- 3.5's hooks (design §0.1): plain function hooks, read at each use, so
-- they stay open after init
test("the voice-stop and freeze-change registries take functions only", function()
  local S = fresh_state()
  assert_true(refused(S.register_voice_stop, 1), "a voice-stop hook is a function")
  assert_true(refused(S.register_voice_stop, nil), "not nil")
  assert_true(refused(S.register_freeze_change, "x"), "a freeze-change hook is a function")
  assert_equal(#S.registry.voice_stop, 0, "nothing refused was kept")
  assert_equal(#S.registry.freeze_change, 0, "nothing refused was kept")
  local stop_hook, freeze_hook = function() end, function() end
  S.register_voice_stop(stop_hook); S.register_freeze_change(freeze_hook)
  assert_equal(S.registry.voice_stop[1], stop_hook, "a voice-stop hook is kept")
  assert_equal(S.registry.freeze_change[1], freeze_hook, "a freeze-change hook is kept")
  -- after init
  load_strata()
  local script = local_value("S")
  local stops, freezes = #script.registry.voice_stop, #script.registry.freeze_change
  script.register_voice_stop(function() end)
  script.register_freeze_change(function() end)
  assert_equal(#script.registry.voice_stop, stops + 1, "a voice-stop hook after init")
  assert_equal(#script.registry.freeze_change, freezes + 1, "a freeze-change hook after init")
end)

-- 3.6's registries (design §0.1, plan rulings 4, 8 and 9): each open, read at
-- each use
test("the 3.6 registries take what their records allow", function()
  local S = fresh_state()
  local function fn() end
  -- note hooks, by name; every other field an optional function
  S.register_note_hook({ name = "x" })
  assert_equal(#S.registry.note_hooks, 1, "a hook record is kept")
  assert_true(refused(S.register_note_hook, { name = "x" }), "a second x")
  assert_true(refused(S.register_note_hook, { name = "y", started = 1 }), "started is a function")
  assert_true(refused(S.register_note_hook, { name = "z", bogus = fn }), "an unknown field")
  assert_true(refused(S.register_note_hook, { started = fn }), "a hook record needs a name")
  S.register_note_hook({ name = "all", started = fn, ended = fn, moved = fn, expressed = fn })
  assert_equal(#S.registry.note_hooks, 2, "nothing refused was kept")
  -- the scene-recalled and silence-change hooks are functions
  assert_true(refused(S.register_scene_recalled, 1), "a scene hook is a function")
  assert_true(refused(S.register_silence_change, "x"), "a silence hook is a function")
  S.register_scene_recalled(fn); S.register_silence_change(fn)
  assert_equal(S.registry.scene_recalled[1], fn, "a scene hook is kept")
  assert_equal(S.registry.silence_change[1], fn, "a silence hook is kept")
  -- note targets: name, routed, note_on, note_off required
  local function target(overrides)
    local record = { name = "t", routed = fn, note_on = fn, note_off = fn }
    for field, value in pairs(overrides or {}) do record[field] = value end
    return record
  end
  for _, field in ipairs({ "routed", "note_on", "note_off" }) do
    local record = target({ name = "no_" .. field }); record[field] = nil
    assert_true(refused(S.register_note_target, record), "a target needs " .. field)
  end
  assert_true(refused(S.register_note_target, target({ name = "bad", rows = 1 })), "rows is a function")
  assert_true(refused(S.register_note_target, target({ name = "bad2", shade = fn })), "an unknown field")
  S.register_note_target(target({ rows = fn, status = fn, express = fn, stop_all = fn }))
  assert_equal(S.registry.note_targets[1].name, "t", "a target is kept")
  assert_true(refused(S.register_note_target, target()), "a second t")
  assert_equal(#S.registry.note_targets, 1, "nothing refused was kept")
  -- layout_states: the IO section's form ({name = string, setup = fn})
  assert_true(refused(S.register_note_target, target({ name = "l1", layout_states = 1 })), "a list")
  assert_true(refused(S.register_note_target, target({ name = "l2", layout_states = { { name = "x" } } })),
    "a state needs a setup")
  assert_true(refused(S.register_note_target, target({ name = "l3", layout_states = { { setup = fn } } })),
    "a state needs a name")
  assert_true(refused(S.register_note_target, target({ name = "l4", layout_states = { { name = 1, setup = fn } } })),
    "a name is a string")
  local states = { { name = "look", setup = fn } }
  S.register_note_target(target({ name = "lay", layout_states = states }))
  assert_equal(S.registry.note_targets[2].layout_states, states, "the registry's record holds the states")
  assert_equal(#S.registry.note_targets, 2, "nothing refused was kept")
  -- ii devices: ports true or false, param_count whole, at least 0, more than 0 only with add_params
  S.register_ii_device({ name = "jf", ports = false, param_count = 8, add_params = fn })
  assert_true(refused(S.register_ii_device, { name = "jf", ports = false }), "a second jf")
  assert_true(refused(S.register_ii_device, { name = "p" }), "a device says whether its commands address ports (#717)")
  assert_true(refused(S.register_ii_device, { name = "q", ports = 1 }), "ports is true or false")
  assert_true(refused(S.register_ii_device, { name = "a", ports = false, param_count = -1, add_params = fn }),
    "a count of -1")
  assert_true(refused(S.register_ii_device, { name = "b", ports = false, param_count = 1.5, add_params = fn }),
    "a count of 1.5")
  assert_true(refused(S.register_ii_device, { name = "c", ports = false, param_count = 8 }), "a count without add_params")
  assert_true(refused(S.register_ii_device, { name = "d", ports = false, ready = 1 }), "ready is a function")
  assert_true(refused(S.register_ii_device, { name = "e", ports = false, reset = fn }), "an unknown field")
  assert_true(refused(S.register_ii_device, { name = "f", ports = false, param_count = math.huge, add_params = fn }),
    "an infinite count")
  assert_true(refused(S.register_ii_device, { name = "g", ports = false, param_count = 0 / 0, add_params = fn }),
    "a NaN count")
  local plain = { name = "plain", ports = true, ready = fn, release = fn }
  S.register_ii_device(plain)
  assert_equal(#S.registry.ii_devices, 2, "nothing refused was kept")
  assert_equal(S.registry.ii_devices[2].param_count, 0, "param_count defaults to 0 in the registry")
  assert_equal(S.registry.ii_devices[2].ready, fn, "with the record's functions")
  assert_equal(plain.param_count, nil, "the caller's table is left as it was given")
  local fields = 0
  for _ in pairs(plain) do fields = fields + 1 end
  assert_equal(S.registry.ii_devices[2].ports, true, "and its ports")
  assert_equal(fields, 4, "no field added to it")
  -- macro targets: two non-empty strings, never a macro
  S.register_macro_target("tapeloop_level", "tape level")
  assert_equal(S.registry.macro_targets[1].id, "tapeloop_level")
  assert_equal(S.registry.macro_targets[1].label, "tape level")
  assert_true(refused(S.register_macro_target, "tapeloop_level", "again"), "a second tapeloop_level")
  assert_true(refused(S.register_macro_target, "macro_3", "macro 3"), "a macro is no target")
  assert_true(refused(S.register_macro_target, "", "empty"), "an id is a non-empty string")
  assert_true(refused(S.register_macro_target, "x_level", ""), "a label is a non-empty string")
  assert_equal(#S.registry.macro_targets, 1, "nothing refused was kept")
  -- open after init
  load_strata()
  local script = local_value("S")
  script.register_note_hook({ name = "late" })
  script.register_scene_recalled(fn); script.register_silence_change(fn)
  script.register_note_target(target({ name = "late" }))
  script.register_ii_device({ name = "late", ports = false })
  script.register_macro_target("late_level", "late")
  assert_equal(script.registry.note_hooks[#script.registry.note_hooks].name, "late", "a note hook after init")
  assert_equal(script.registry.note_targets[#script.registry.note_targets].name, "late", "a target after init")
  assert_equal(script.registry.ii_devices[#script.registry.ii_devices].name, "late", "an ii device after init")
end)

-- 3.6's IO sections (design §11, plan ruling 7): a named record with a rows
-- function, read at each use, so the registry stays open
test("register_io_section takes a named record with a rows function", function()
  local S = fresh_state()
  local rows = function() return {} end
  S.register_io_section({ name = "probe", title = "probe", rows = rows })
  assert_equal(#S.registry.io_sections, 1, "a section is kept")
  assert_equal(S.registry.io_sections[1].rows, rows)
  S.register_io_section({ name = "probe2", title = function() return "p2" end, rows = rows,
    status = function() return nil end, layout_states = { { name = "s", setup = function() end } } })
  assert_true(refused(S.register_io_section, { name = "p3", title = "p3" }), "no rows")
  assert_true(refused(S.register_io_section, { name = "p3", title = "p3", rows = {} }), "rows is a function")
  assert_true(refused(S.register_io_section, { name = "probe", title = "x", rows = rows }), "a second name")
  assert_true(refused(S.register_io_section, { title = "x", rows = rows }), "a name")
  assert_true(refused(S.register_io_section, { name = "p4", rows = rows }), "a title")
  assert_true(refused(S.register_io_section, { name = "p5", title = 5, rows = rows }), "a title is a string or function")
  assert_true(refused(S.register_io_section, { name = "p6", title = "x", rows = rows, status = "x" }), "status is a function")
  assert_true(refused(S.register_io_section, { name = "p7", title = "x", rows = rows, layout_states = { { name = 1 } } }),
    "layout_states lists {name, setup}")
  local ok, err = pcall(S.register_io_section, { name = "p8", title = "x", rows = rows, shade = 1 })
  assert_true(not ok and tostring(err):find("shade", 1, true) ~= nil, "an unknown field, named: " .. tostring(err))
  assert_equal(#S.registry.io_sections, 2, "nothing refused was kept")
  -- open after init
  load_strata()
  local script = local_value("S")
  local count = #script.registry.io_sections
  script.register_io_section({ name = "late", title = "late", rows = rows })
  assert_equal(#script.registry.io_sections, count + 1, "a section after init")
end)

-- 3.7's voice_hit (design §0.2, plan ruling 12): a named record with a hit
-- function, read at each use, so the registry stays open
test("register_voice_hit checks its record and refuses a duplicate", function()
  local S = fresh_state()
  local function fn() end
  S.register_voice_hit({ name = "probe", hit = fn })
  assert_equal(#S.registry.voice_hit, 1, "a hook is kept")
  assert_equal(S.registry.voice_hit[1].hit, fn, "with its function")
  assert_true(refused(S.register_voice_hit, { name = "probe", hit = fn }), "a second probe")
  assert_true(refused(S.register_voice_hit, { hit = fn }), "a hook needs a name")
  assert_true(refused(S.register_voice_hit, { name = "", hit = fn }), "a name is not empty")
  assert_true(refused(S.register_voice_hit, { name = "p2" }), "a hook needs hit")
  assert_true(refused(S.register_voice_hit, { name = "p3", hit = 1 }), "hit is a function")
  assert_true(refused(S.register_voice_hit, fn), "a record is a table")
  local ok, err = pcall(S.register_voice_hit, { name = "p4", hit = fn, started = fn })
  assert_true(not ok and tostring(err):find("started", 1, true) ~= nil, "an unknown field, named: " .. tostring(err))
  assert_equal(#S.registry.voice_hit, 1, "nothing refused was kept")
  -- open after init
  load_strata()
  local script = local_value("S")
  local count = #script.registry.voice_hit
  script.register_voice_hit({ name = "late", hit = fn })
  assert_equal(#script.registry.voice_hit, count + 1, "a hook after init")
end)

-- 3.7's scene_applied (1d's review): a named record with an fn, run once by
-- every apply_entries after its flag clears, read at each use, so it stays
-- open
test("register_scene_applied checks its record and refuses a duplicate", function()
  local S = fresh_state()
  local function fn() end
  S.register_scene_applied({ name = "probe", fn = fn })
  assert_equal(#S.registry.scene_applied, 1, "a hook is kept")
  assert_equal(S.registry.scene_applied[1].fn, fn, "with its function")
  assert_true(refused(S.register_scene_applied, { name = "probe", fn = fn }), "a second probe")
  assert_true(refused(S.register_scene_applied, { fn = fn }), "a hook needs a name")
  assert_true(refused(S.register_scene_applied, { name = "", fn = fn }), "a name is not empty")
  assert_true(refused(S.register_scene_applied, { name = "p2" }), "a hook needs fn")
  assert_true(refused(S.register_scene_applied, { name = "p3", fn = 1 }), "fn is a function")
  assert_true(refused(S.register_scene_applied, fn), "a record is a table")
  local ok, err = pcall(S.register_scene_applied, { name = "p4", fn = fn, hit = fn })
  assert_true(not ok and tostring(err):find("hit", 1, true) ~= nil, "an unknown field, named: " .. tostring(err))
  assert_equal(#S.registry.scene_applied, 1, "nothing refused was kept")
  -- open after init
  load_strata()
  local script = local_value("S")
  local count = #script.registry.scene_applied
  script.register_scene_applied({ name = "late", fn = fn })
  assert_equal(#script.registry.scene_applied, count + 1, "a hook after init")
end)

-- 3.7's settings rows for a modulation source (design §0.4): fields is a
-- list of {label, value, enc, fine_enc, press}, or a function returning one
test("a modulation source's fields are checked", function()
  local S = fresh_state()
  local function fn() end
  local function value() return "1" end
  S.register_mod_source(mod_source({ key = "f1", fields = { { label = "rate", value = value },
    { label = "12345678", value = value, enc = fn, fine_enc = fn, press = fn } } }))
  assert_equal(#S.registry.mod_sources, 1, "a source with fields is kept")
  S.register_mod_source(mod_source({ key = "f2", fields = function() return {} end }))
  assert_equal(#S.registry.mod_sources, 2, "fields may be a function")
  local function bad(fields) return refused(S.register_mod_source, mod_source({ key = "bad", fields = fields })) end
  assert_true(bad({ { label = "123456789", value = value } }), "a label of 9 characters")
  assert_true(bad({ { label = "", value = value } }), "an empty label")
  assert_true(bad({ { label = 3, value = value } }), "a label is a string")
  assert_true(bad({ { label = "rate", value = "1" } }), "a value that is not a function")
  assert_true(bad({ { label = "rate" } }), "a field needs a value")
  assert_true(bad({ { label = "rate", value = value, enc = 1 } }), "enc is a function")
  assert_true(bad({ { label = "rate", value = value, fine_enc = 1 } }), "fine_enc is a function")
  assert_true(bad({ { label = "rate", value = value, press = 1 } }), "press is a function")
  assert_true(bad({ "rate" }), "a field is a table")
  assert_true(bad("rate"), "fields is a list or a function")
  local ok, err = pcall(S.register_mod_source, mod_source({ key = "bad", fields = { { label = "rate", value = value,
    hint = fn } } }))
  assert_true(not ok and tostring(err):find("hint", 1, true) ~= nil, "an unknown key, named: " .. tostring(err))
  assert_equal(#S.registry.mod_sources, 2, "nothing refused was kept")
end)

-- The groundwork before 3.8 (package 2a): the built-in per-voice params are
-- records too, registered by lib/voices.lua, so they come first
test("the built-in records come first: synth, grain, crossmod", function()
  local context = load_with(function(S) S.register_voice_params(probe_record()) end)
  finish_startup(context)
  local S = local_value("S")
  local names = {}
  for index = 1, 3 do names[index] = S.registry.voice_params[index].name end
  assert_equal(table.concat(names, ","), "synth,grain,crossmod", "the first three records")
  assert_equal(S.registry.voice_params[#S.registry.voice_params].name, "probe", "a registered record follows them")
  local by_name = {}
  for _, record in ipairs(S.registry.voice_params) do by_name[record.name] = record end
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(by_name.synth.count(voice_idx), #S.voices[voice_idx].param_order, "synth counts the voice's param_order")
  end
  assert_equal(by_name.grain.count, 10, "the source and the nine grain params")
  assert_equal(by_name.crossmod.count, 10, "three slots of three, then the speed")
  assert_equal(by_name.synth.separator, false, "the synth params sit under the voice's heading")
  assert_equal(by_name.grain.separator, "granular")
  assert_equal(by_name.crossmod.separator, "cross-modulation")
end)

test("count may be a function of the voice, checked per voice", function()
  -- voice 2 gets one more param than the others
  local record = probe_record({ count = function(voice_idx) return voice_idx == 2 and 3 or 2 end })
  local add = record.add
  function record.add(voice_idx)
    add(voice_idx)
    if voice_idx == 2 then
      local_value("S").lib.params_setup.add_voice_param(voice_idx, record, "probe_more",
        { type = "control", name = "probe more", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
    end
  end
  load_with(function(S) S.register_voice_params(record) end)
  assert_true(params.lookup.v2_probe_more ~= nil and params.lookup.v1_probe_more == nil, "voice 2's third param")
  -- a voice's count that is no whole number from 1 is refused at registration
  load_with(function(S)
    assert_true(refused(S.register_voice_params, probe_record({ name = "p2",
      count = function(voice_idx) return voice_idx == 5 and 0 or 2 end })), "voice 5's count 0")
    assert_true(refused(S.register_voice_params, probe_record({ name = "p3",
      count = function(voice_idx) return voice_idx == 7 and 1.5 or 2 end })), "voice 7's count 1.5")
  end)
  -- and an add that adds another number for one voice fails at init, naming it
  local ok, problem = pcall(load_with, function(S) S.register_voice_params(probe_record({ name = "p4",
    count = function(voice_idx) return voice_idx == 6 and 3 or 2 end })) end)
  assert_true(not ok and tostring(problem):find("p4", 1, true) ~= nil and tostring(problem):find("count", 1, true) ~= nil,
    "voice 6's add of two against a count of 3: " .. tostring(problem))
end)

test("a record's fader, main_randomize and mutate groups are checked", function()
  load_with(function(S)
    local index = 0
    local function bad(overrides)
      index = index + 1
      overrides.name = "bad" .. index
      return refused(S.register_voice_params, probe_record(overrides))
    end
    local function keys_of() return { "probe" } end
    local function draw() return 0 end
    -- fader
    assert_true(bad({ fader = true }), "fader = true")
    assert_true(bad({ fader = { { keys = "probe" } } }), "fader keys that are neither a list nor a function")
    assert_true(bad({ fader = { { keys = { "probe" }, when = 1 } } }), "a fader when that is no function")
    assert_true(bad({ fader = { { keys = { "probe" }, rank = "1" } } }), "a rank that is no number")
    assert_true(bad({ fader = { { keys = { 3 } } } }), "a fader key is a string")
    assert_true(bad({ fader = { "probe" } }), "a fader group is a table")
    -- main_randomize
    assert_true(bad({ main_randomize = { { keys = { "probe" } } } }), "a missing draw")
    assert_true(bad({ main_randomize = { { keys = 1, draw = draw } } }), "randomize keys neither list nor function")
    assert_true(bad({ main_randomize = { { keys = { "probe" }, draw = draw, when = true } } }), "a randomize when")
    -- mutate
    assert_true(bad({ mutate = { { keys = { "probe" }, chance = 1.5 } } }), "a chance above 1")
    assert_true(bad({ mutate = { { keys = { "probe" }, chance = -0.1 } } }), "a chance below 0")
    assert_true(bad({ mutate = { { keys = { "probe" }, scale = "x" } } }), "a scale that is no number")
    assert_true(bad({ mutate = { { keys = { "probe" }, warped = 1 } } }), "warped is a boolean")
    assert_true(bad({ mutate = { { keys = { "probe" }, when = "x" } } }), "a mutate when")
    assert_true(bad({ mutate = "probe" }), "mutate is a list of groups")
    -- accepted: every documented form (false is probe_record's own)
    S.register_voice_params(probe_record({ name = "good1", fader = { { keys = keys_of, when = keys_of, rank = 2 } },
      main_randomize = { { keys = { "probe" }, draw = draw } },
      mutate = { { keys = keys_of, chance = 0.5, scale = 0.2, warped = false } } }))
  end)
end)

test("a fader key no record added for the voice refuses at init, naming the record", function()
  local ok, problem = pcall(load_with, function(S)
    S.register_voice_params(probe_record({ name = "faded", fader = { { keys = { "probe", "never_added" } } } }))
  end)
  assert_true(not ok, "refused")
  assert_true(tostring(problem):find("faded", 1, true) ~= nil and tostring(problem):find("never_added", 1, true) ~= nil,
    "names the record and the key: " .. tostring(problem))
  -- a key another record added for the voice is allowed (grain's faders name amp and pan)
  load_with(function(S)
    S.register_voice_params(probe_record({ name = "faded", fader = { { keys = { "probe", "grain_size", "freq" } } } }))
  end)
  local ids = table.concat(fader_param_ids(1), ",")
  assert_true(ids:find("v1_probe,v1_grain_size,v1_freq", 1, true) ~= nil, "the group's keys in order: " .. ids)
end)

test("voice_keys and send_order are checked; records with one separator share it", function()
  load_with(function(S)
    local index = 0
    local function bad(overrides)
      index = index + 1
      overrides.name = "bad" .. index
      return refused(S.register_voice_params, probe_record(overrides))
    end
    local function send() end
    assert_true(bad({ voice_keys = { probe = 3 } }), "a voice key is a name, {name} or {send}")
    assert_true(bad({ voice_keys = { probe = { name = 3 } } }), "a name is a string")
    assert_true(bad({ voice_keys = { probe = { send = "x" } } }), "a send is a function")
    assert_true(bad({ voice_keys = { probe = { name = "x", carry = true } } }), "carry is only false")
    assert_true(bad({ voice_keys = function() return { probe = 1 } end }), "a function's table is checked too")
    assert_true(bad({ grain_keys = { probe = { name = "posSpread", carry = 1 } } }), "a grain key's carry is false")
    assert_true(bad({ send_order = { "probe", "probe" } }), "a key once")
    assert_true(bad({ send_order = { "other" } }), "send_order names the record's sent keys")
    assert_true(bad({ send_order = {} }), "and every one of them")
    assert_true(bad({ send_order = "probe" }), "send_order is a list")
    assert_true(bad({ separator = 3 }), "a separator is a string or false")
    S.register_voice_params(probe_record({ name = "good1", grain_keys = { probe = { name = "posSpread", carry = false } },
      voice_keys = { probe_switch = { send = send, carry = false } }, send_order = { "probe_switch", "probe" } }))
  end)
  -- two records with one separator: one separator before the first
  local function probe_named(name, separator)
    local record = { name = name, count = 1, fader = false, separator = separator }
    function record.add(voice_idx)
      local_value("S").lib.params_setup.add_voice_param(voice_idx, record, name,
        { type = "control", name = name, controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
    end
    return record
  end
  load_with(function(S)
    S.register_voice_params(probe_named("probe_a", "probes"))
    S.register_voice_params(probe_named("probe_b", "probes"))
    S.register_voice_params(probe_named("probe_c", false))
  end)
  local position, separators = {}, 0
  for index, param in ipairs(params.params) do
    position[param.id] = index
    if param.id == "voice 3 probes" then separators = separators + 1 end
  end
  assert_equal(separators, 1, "one voice 3 probes separator")
  assert_equal(position["v3_probe_a"], position["voice 3 probes"] + 1, "the first record's param follows it")
  assert_equal(position["v3_probe_b"], position["v3_probe_a"] + 1, "the second shares it")
  assert_equal(position["v3_probe_c"], position["v3_probe_b"] + 1, "false: no separator")
end)

end

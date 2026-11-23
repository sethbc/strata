-- test/unit/types_test.lua
-- The voice types (3.8, package 0d): the registry (S.register_voice_type,
-- lib/state.lua), S.lib.types (lib/types.lua), the seven built-in records
-- (lib/types/<key>.lua), the v<i>_type param and every type's synth keys on
-- every voice. A type added later gets types_<key>_test.lua of its own.
-- Run alone: lua test/run.lua types

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- 3.7's seven voices, as the records must give them (3.7's lib/voices.lua
-- voices table, VOICE_PARAM_SPECS and SYNTH_FORMATS of lib/params_setup.lua
-- and lib/voices.lua, MAIN_PARAMS of lib/constants.lua, NOTES.envelope of
-- lib/notes.lua and the engine's noteMainRanges)
local BUILT_IN = {
  {key = "resonator", def = "strataResonator", list_name = "reso", note_main = "rq",
    main = {key = "freq", label = "freq", format = "%.0f Hz"}, envelope = {attack = 4, release = 8},
    param_order = {"freq", "rq", "noise", "mod1", "mod2", "amp", "pan"},
    defaults = {freq = 100, amp = 0.3, pan = 0, rq = 0.1, noise = 0.5, mod1 = 0.1, mod2 = 0.15}},
  {key = "fm", def = "strataFM", list_name = "fm", note_main = "index",
    main = {key = "index", label = "index", format = "%.1f"}, envelope = {attack = 5, release = 10},
    param_order = {"freq", "ratio", "index", "modFreq", "amp", "pan"},
    defaults = {freq = 80, amp = 0.25, pan = 0, ratio = 1.5, index = 2, modFreq = 0.05}},
  {key = "folder", def = "strataFolder", list_name = "fold", note_main = "fold",
    main = {key = "fold", label = "fold", format = "%.1f"}, envelope = {attack = 3, release = 6},
    param_order = {"freq", "fold", "mod", "amp", "pan"},
    defaults = {freq = 60, amp = 0.3, pan = 0, fold = 1, mod = 0.2}},
  {key = "sub", def = "strataSub", list_name = "sub", note_main = "drift",
    main = {key = "drift", label = "drift", format = "%.3f"}, envelope = {attack = 8, release = 12},
    param_order = {"freq", "drift", "amp"},
    defaults = {freq = 40, amp = 0.4, drift = 0.02}},
  {key = "pulse", def = "strataPulse", list_name = "pulse", note_main = "width",
    main = {key = "width", label = "width", format = "%.2f"}, envelope = {attack = 2, release = 4},
    param_order = {"freq", "width", "cutoff", "res", "amp", "pan"},
    defaults = {freq = 120, amp = 0.3, pan = 0, width = 0.5, cutoff = 2000, res = 0.8}},
  {key = "karplus", def = "strataKarplus", list_name = "karp", note_main = "decay",
    main = {key = "decay", label = "decay", format = "%.1f s"}, envelope = {attack = 0.01, release = 2},
    param_order = {"freq", "decay", "damping", "excite", "amp", "pan"},
    defaults = {freq = 200, amp = 0.35, pan = 0, decay = 4, damping = 0.5, excite = 0.3}},
  {key = "ring", def = "strataRing", list_name = "ring", note_main = "ratio",
    main = {key = "ratio", label = "ratio", format = "%.2f"}, envelope = {attack = 3, release = 5},
    param_order = {"freq", "ratio", "mod", "brightness", "amp", "pan"},
    defaults = {freq = 300, amp = 0.25, pan = 0, ratio = 1.618, mod = 0.2, brightness = 0.5}},
}
-- 3.7's specs: {min, max, warp, step, units}, each with the quantum 0.01
local SPECS_3_7 = {
  freq = {20, 2000, "exp", 0, "Hz"}, amp = {0, 1, "lin", 0.01, ""}, pan = {-1, 1, "lin", 0.01, ""},
  rq = {0.01, 1, "lin", 0.01, ""}, noise = {0, 1, "lin", 0.01, ""}, mod1 = {0.01, 1, "lin", 0.01, "Hz"},
  mod2 = {0.01, 1, "lin", 0.01, "Hz"}, ratio = {0.5, 8, "lin", 0.001, ""}, index = {0, 10, "lin", 0.1, ""},
  modFreq = {0.01, 1, "lin", 0.01, "Hz"}, fold = {0.1, 5, "lin", 0.1, ""}, mod = {0.01, 2, "lin", 0.01, ""},
  drift = {0.001, 0.1, "lin", 0.001, ""}, width = {0.05, 0.95, "lin", 0.01, ""},
  cutoff = {100, 8000, "exp", 10, "Hz"}, res = {0.1, 1, "lin", 0.01, ""}, decay = {0.5, 10, "lin", 0.1, "s"},
  damping = {0.1, 0.9, "lin", 0.01, ""}, excite = {0.1, 2, "lin", 0.01, "Hz"}, brightness = {0, 1, "lin", 0.01, ""},
}
-- 3.7's formats (three decimals where the step is finer than 0.01, #386)
local FORMATS_3_7 = {drift = "%.3f", ratio = "%.3f"}

-- A spec's warp as a name, on norns (a warp table) and the stub (warp_name)
local function warp_of(spec)
  if spec.warp_name then return spec.warp_name end
  local probe = controlspec.new(1, 2, "exp")
  return spec.warp == probe.warp and "exp" or "lin"
end

local function spec_text(spec)
  return string.format("%s %s %s %s %s %s", tostring(spec.minval), tostring(spec.maxval), warp_of(spec),
    tostring(spec.step), tostring(spec.units), tostring(spec.quantum))
end

local function expected_spec_text(key)
  local s = SPECS_3_7[key]
  return string.format("%s %s %s %s %s %s", tostring(s[1]), tostring(s[2]), s[3], tostring(s[4]), s[5], "0.01")
end

test("the seven built-in types register in type order with 3.7's keys, defaults, specs, mains and envelopes", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local list = S.lib.types.list()
  assert_true(#list >= #BUILT_IN, "the seven built-in types, first")
  for index, want in ipairs(BUILT_IN) do
    local record = list[index]
    local where = "type " .. index .. " (" .. want.key .. ")"
    assert_equal(record.key, want.key, where .. ": its key")
    assert_equal(record.index, index, where .. ": its index, its place")
    assert_equal(record.def, want.def, where .. ": its def")
    assert_equal(record.name, want.key, where .. ": its name")
    assert_equal(record.list_name, want.list_name, where .. ": its list name")
    assert_equal(record.note_main, want.note_main, where .. ": its expression key")
    assert_equal(table.concat(record.param_order, " "), table.concat(want.param_order, " "), where .. ": 3.7's keys")
    for field, value in pairs(want.main) do assert_equal(record.main[field], value, where .. ": main " .. field) end
    assert_equal(record.envelope.attack, want.envelope.attack, where .. ": its attack")
    assert_equal(record.envelope.release, want.envelope.release, where .. ": its release")
    for _, key in ipairs(want.param_order) do
      assert_equal(record.defaults[key], want.defaults[key], where .. ": " .. key .. "'s default")
      assert_equal(spec_text(record.specs[key]), expected_spec_text(key), where .. ": " .. key .. "'s spec")
      assert_equal(record.formats[key], FORMATS_3_7[key], where .. ": " .. key .. "'s format")
    end
    assert_true(S.lib.types.record(want.key) == record, where .. ": record(key)")
  end
  assert_equal(S.lib.types.record("glass"), nil, "a type this build lacks")
  cleanup()
end)

test("S.lib.types answers for the voices: of, default_key, keys, spec and format", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(S.lib.types.default_key(voice), BUILT_IN[voice].key, "voice " .. voice .. "'s own type")
    assert_equal(S.lib.types.of(voice).key, BUILT_IN[voice].key, "voice " .. voice .. " starts on it")
  end
  assert_equal(S.lib.types.of(0), nil, "no voice 0")
  assert_equal(S.lib.types.of(S.constants.NUM_VOICES + 1), nil, "no voice past the last")
  assert_equal(S.lib.types.of("1"), nil, "a string is no voice")
  local built_in_keys =
    "freq rq noise mod1 mod2 amp pan ratio index modFreq fold mod drift width cutoff res decay damping excite brightness"
  assert_equal(table.concat(S.lib.types.keys(), " "):sub(1, #built_in_keys), built_in_keys,
    "every distinct key, in type order (the built-in types' first)")
  local spec = S.lib.types.spec("ratio")
  assert_equal(spec_text(spec), expected_spec_text("ratio"), "ratio's one spec")
  spec.maxval = 99
  assert_equal(S.lib.types.spec("ratio").maxval, 8, "spec hands out a copy")
  assert_true(not pcall(S.lib.types.spec, "nothing"), "an unknown key errors")
  assert_equal(S.lib.types.format("ratio"), "%.3f"); assert_equal(S.lib.types.format("freq"), nil)
  assert_equal(spec_text(get_param_spec("rq")), expected_spec_text("rq"), "get_param_spec reads the types")
  assert_true(not pcall(get_param_spec, "nothing"), "and an unknown key still errors (#315)")
  cleanup()
end)

-- A good record of a probe type, a fresh copy each call
local function probe_record(edit)
  local record = {key = "probe", name = "probe", list_name = "probe", def = "strataProbe",
    param_order = {"freq", "ratio", "amp", "pan"},
    defaults = {freq = 100, ratio = 2, amp = 0.3, pan = 0},
    specs = {freq = controlspec.new(20, 2000, "exp", 0, 100, "Hz"), ratio = controlspec.new(0.5, 8, "lin", 0.001, 2),
      amp = controlspec.new(0, 1, "lin", 0.01, 0.3), pan = controlspec.new(-1, 1, "lin", 0.01, 0)},
    formats = {ratio = "%.3f"}, main = {key = "ratio", label = "ratio", format = "%.2f"}, note_main = "ratio",
    envelope = {attack = 1, release = 2}}
  if edit then edit(record) end
  return record
end

test("register_voice_type refuses a record without freq or amp, a list name over five characters, a second key, " ..
    "a shared key with another spec or format, an index, and any registration after init", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function fresh()
    local state = include("lib/state")()
    state.constants = S.constants
    return state
  end
  local state = fresh()
  state.register_voice_type(probe_record())
  assert_equal(#state.registry.voice_types, 1, "a good record is kept")
  assert_equal(state.registry.voice_types[1].index, 1, "the registry gives it its index")
  local function refused(edit, first)
    local into = fresh()
    if first then into.register_voice_type(first) end
    return not pcall(into.register_voice_type, probe_record(edit))
  end
  assert_true(refused(function(r)
    r.param_order = {"ratio", "amp", "pan"}; r.defaults.freq, r.specs.freq = nil, nil
  end), "no freq")
  assert_true(refused(function(r)
    r.param_order = {"freq", "ratio", "pan"}; r.defaults.amp, r.specs.amp = nil, nil
  end), "no amp")
  assert_true(refused(function(r) r.param_order = {"ratio", "freq", "amp", "pan"} end), "freq not first")
  assert_true(refused(function(r) r.param_order = {"freq", "amp", "ratio", "pan"} end), "amp and pan not last")
  assert_true(refused(function(r) r.list_name = "probes" end), "a list name over five characters")
  assert_true(refused(nil, probe_record()), "a second record with the key")
  local other = probe_record(function(r) r.key = "other" end)
  assert_true(refused(function(r) r.specs.ratio = controlspec.new(0.5, 4, "lin", 0.001, 2) end, other),
    "a shared key with another range (ratio 0.5-4)")
  assert_true(refused(function(r) r.specs.ratio = controlspec.new(0.5, 8, "exp", 0.001, 2) end, other),
    "a shared key with another warp")
  assert_true(refused(function(r) r.formats.ratio = "%.2f" end, other), "a shared key with another format")
  assert_true(not refused(function(r) r.defaults.ratio = 3; r.specs.ratio = controlspec.new(0.5, 8, "lin", 0.001, 3) end,
    other), "a shared key's default may differ")
  assert_true(refused(function(r) r.index = 1 end), "a record that gives its index")
  assert_true(refused(function(r) r.main = {key = "nothing", label = "x", format = "%.1f"} end), "a main key it lacks")
  assert_true(refused(function(r) r.note_main = "nothing" end), "a note_main it lacks")
  assert_true(refused(function(r) r.defaults.ratio = nil end), "a key with no default")
  assert_true(refused(function(r) r.specs.ratio = nil end), "a key with no spec")
  assert_true(refused(function(r) r.envelope = {attack = 1} end), "an envelope with no release")
  assert_true(refused(function(r) r.key = "two words" end), "a key that is no param id suffix")
  assert_true(refused(function(r) r.hue = 1 end), "an unknown field")
  assert_true(not pcall(S.register_voice_type, probe_record()), "the live registry is closed at init")
  cleanup()
end)

---------------------------------------------------------------------------
-- Every key on every voice (Step 2)
---------------------------------------------------------------------------

-- A voice's synth param ids (v<i>_<key> for every key of S.lib.types.keys()), in menu order
local function synth_ids(S, voice)
  local synth, ids = {}, {}
  for _, key in ipairs(S.lib.types.keys()) do synth["v" .. voice .. "_" .. key] = true end
  for _, param in ipairs(params.params) do
    if synth[param.id] then ids[#ids + 1] = param.id end
  end
  return ids
end

local function calls(context, name, voice)
  local found = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == name and (voice == nil or call.args[1] == voice - 1) then found[#found + 1] = call end
  end
  return found
end

-- The synth keys a voice's setVoiceParam calls named, in order
local function synth_sends(context, S, voice)
  local synth, sent = {}, {}
  for _, key in ipairs(S.lib.types.keys()) do synth[key] = true end
  for _, call in ipairs(calls(context, "setVoiceParam", voice)) do
    if synth[call.args[2]] then sent[#sent + 1] = call.args[2] end
  end
  return sent
end

local function stop_all(S)
  for voice = 1, S.constants.NUM_VOICES do
    if S.voices[voice].active then toggle_voice(voice) end
  end
end

test("every voice has every type's synth key, its default type's first, in 3.7's order", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    local ids = synth_ids(S, voice)
    assert_equal(#ids, #S.lib.types.keys(), "voice " .. voice .. " has every key once")
    local own = S.lib.types.record(S.lib.types.default_key(voice)).param_order
    for index, key in ipairs(own) do
      assert_equal(ids[index], "v" .. voice .. "_" .. key, "voice " .. voice .. ": its own type's keys first")
    end
  end
  local voice_2 = synth_ids(S, 2)
  assert_equal(#voice_2, #S.lib.types.keys(), "voice 2's synth ids, one a key")
  assert_equal(table.concat(voice_2, " ", 1, 6), "v2_freq v2_ratio v2_index v2_modFreq v2_amp v2_pan",
    "fm's six first")
  assert_equal(params.lookup["v2_type"] - 1, params.lookup["voice 2: fm"], "the type is first under the voice's heading")
  assert_true(params.lookup["v2_type"] < params.lookup["v2_quantize"], "ahead of variation's quantize")
  assert_equal(params:lookup_param("v2_type").t, params.tOPTION, "an option")
  cleanup()
end)

test("a synth key's default is the voice's default type's, else the first type's", function()
  local context = load_strata(); finish_startup(context)
  assert_equal(params:get("v1_ratio"), 1.5, "voice 1's ratio: fm's")
  assert_equal(params:get("v7_ratio"), 1.618, "voice 7's ratio: ring's own")
  assert_equal(params:get("v4_pan"), 0, "voice 4's pan: resonator's")
  assert_equal(params:get("v3_mod"), 0.2, "voice 3's mod: folder's")
  assert_equal(params:get("v1_width"), 0.5, "voice 1's width: pulse's")
  for voice = 1, local_value("S").constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_type"), voice, "voice " .. voice .. " on its own type")
    assert_equal(params:lookup_param("v" .. voice .. "_type").default, voice, "by default")
  end
  cleanup()
end)

test("only the current type's keys show", function()
  local context = load_strata(); finish_startup(context)
  assert_true(params:visible("v1_rq"), "resonator's rq shows")
  assert_true(not params:visible("v1_ratio"), "fm's ratio is hidden")
  assert_true(params:visible("v1_freq") and params:visible("v1_pan"), "the shared keys show")
  assert_true(not params:visible("v4_pan"), "sub has no pan")
  local rebuilds = context.menu.rebuilds
  params:set("v1_type", 2)
  assert_true(params:visible("v1_ratio") and not params:visible("v1_rq"), "fm's keys show, resonator's hide")
  assert_equal(context.menu.rebuilds, rebuilds + 1, "the menu is rebuilt once")
  assert_equal(params:lookup_param("voice 1: resonator").name, "voice 1: fm", "the separator names the type")
  assert_equal(local_value("S").voices[1].name, "fm", "the voice's name is the type's key")
  assert_equal(table.concat(local_value("S").voices[1].param_order, " "), "freq ratio index modFreq amp pan",
    "and its param_order the type's")
  cleanup()
end)

test("a hidden key's sender sends nothing, and the budget counts nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  context.clear_engine_calls()
  params:set("v1_ratio", 2)
  assert_equal(#calls(context, "setVoiceParam", 1), 0, "no setVoiceParam for a key resonator lacks")
  assert_true(not S.lib.engine_sync.reaches_engine("v1_ratio"), "it reaches no engine")
  assert_true(S.lib.engine_sync.reaches_engine("v1_rq"), "resonator's own does")
  context.clear_engine_calls()
  params:set("v1_type", 2)
  local ratio
  for _, call in ipairs(calls(context, "setVoiceParam", 1)) do
    if call.args[2] == "ratio" then ratio = call.args[3] end
  end
  assert_equal(ratio, 2, "on fm the sync sends ratio 2")
  assert_true(S.lib.engine_sync.reaches_engine("v1_ratio") and not S.lib.engine_sync.reaches_engine("v1_rq"),
    "the gate follows the type")
  cleanup()
end)

test("the type param sends setVoiceType always; a running voice syncs once", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  stop_all(S)
  context.clear_engine_calls()
  params:set("v1_type", 2)
  local types = calls(context, "setVoiceType")
  assert_equal(#types, 1, "one setVoiceType")
  assert_equal(types[1].args[1] .. " " .. types[1].args[2], "0 1", "voice 0 to type 1")
  assert_equal(#calls(context, "setVoiceParam"), 0, "a stopped voice gets no setVoiceParam")
  params:set("v1_type", 1)
  toggle_voice(1)
  context.clear_engine_calls()
  params:set("v1_type", 2)
  types = calls(context, "setVoiceType")
  assert_equal(#types, 1, "one setVoiceType")
  assert_equal(types[1].args[1] .. " " .. types[1].args[2], "0 1", "voice 0 to type 1")
  assert_equal(context.engine_calls[1].name, "setVoiceType", "first")
  assert_equal(table.concat(synth_sends(context, S, 1), " "), "amp freq index modFreq pan ratio",
    "then exactly fm's keys, sorted, once")
  cleanup()
end)

test("voiceOn's pan is 0 on a type without pan", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  stop_all(S)
  params:set("v1_pan", 0.7)
  params:set("v1_type", S.lib.types.record("sub").index)
  context.clear_engine_calls()
  toggle_voice(1)
  local on = calls(context, "voiceOn")[1]
  assert_equal(on.args[4], 0, "sub has no pan: 0")
  assert_near(params:get("v1_pan"), 0.7, 1e-9, "the hidden pan keeps its value")
  toggle_voice(1)
  params:set("v1_type", 1)
  context.clear_engine_calls()
  toggle_voice(1)
  assert_near(calls(context, "voiceOn")[1].args[4], 0.7, 1e-9, "resonator's pan is sent")
  cleanup()
end)

test("a type change works on a locked voice, clears an undo holding a synth key, and no randomize draws it", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  toggle_lock(1)
  params:set("v1_type", 2)
  assert_equal(S.lib.types.of(1).key, "fm", "a locked voice's type changes")
  toggle_lock(1)
  math.randomseed(12)
  assert_true(randomize_voice(1), "a MAIN randomize")
  assert_true(undo_available(1), "its undo held")
  params:set("v1_type", 3)
  assert_true(not undo_available(1), "a type change ends it")
  for seed = 1, 5 do
    math.randomseed(seed)
    for voice = 1, S.constants.NUM_VOICES do randomize_voice(voice) end
    gentle_mutate()
  end
  assert_equal(params:get("v1_type"), 3, "no randomize or mutation draws voice 1's type")
  for voice = 2, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_type"), voice, "nor voice " .. voice .. "'s")
  end
  cleanup()
end)

-- The controller's ruling P13 (ruling 63): every path that sets the type
-- cancels the voice's pending choice, the cancel sitting in the param's action
test("a recall's type entry, apply_voice's and a PSET read each cancel a pending choice", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local settle = S.lib.types.TYPES.settle_seconds
  local pulse = S.lib.types.record("pulse").index
  local function pending_then(fn, want, where)
    S.lib.types.turn(1, 1)
    assert_true(S.lib.types.pending(1) ~= nil, where .. ": a choice pending")
    fn()
    assert_equal(S.lib.types.pending(1), nil, where .. ": canceled")
    context.clock.run_for(settle * 2)
    assert_equal(S.lib.types.of(1).key, want, where .. ": the later act stands")
  end
  params:set("v1_type", pulse); capture_scene(1); params:set("v1_type", 1)
  pending_then(function() recall_scene(1) end, "pulse", "a recall")
  params:set("v1_type", S.lib.types.record("ring").index)
  local data = S.lib.scenes.capture_voice(1)
  params:set("v1_type", 1)
  pending_then(function() assert_true(S.lib.scenes.apply_voice(1, data)) end, "ring", "apply_voice")
  local path = context.data_dir .. "strata-08.pset"
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  params:set("v1_type", S.lib.types.record("karplus").index)
  params:write(path)
  params:set("v1_type", 1)
  pending_then(function() params:read(path) end, "karplus", "a PSET read")
  cleanup()
end)

-- P13 amended (fix round 1): norns' Option:set runs the action only on a
-- change, so a set, a recall, apply_voice and a PSET read that give the
-- voice the type it already has cancel its pending choice outright
test("a set, a recall, apply_voice and a PSET read of the current type each cancel a pending choice", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local settle = S.lib.types.TYPES.settle_seconds
  capture_scene(1)
  local data = S.lib.scenes.capture_voice(1)
  local path = context.data_dir .. "strata-09.pset"
  os.execute("mkdir -p '" .. context.data_dir .. "'")
  params:write(path)
  local acts = {
    {"a set", function() S.lib.types.set(1, "resonator") end},
    {"a recall", function() recall_scene(1) end},
    {"apply_voice", function() assert_true(S.lib.scenes.apply_voice(1, data), "applied") end},
    {"a PSET read", function() params:read(path) end},
  }
  for _, act in ipairs(acts) do
    local where = act[1]
    S.lib.types.turn(1, 2)
    assert_equal(S.lib.types.pending(1), 3, where .. ": a choice pending toward folder")
    context.clear_engine_calls()
    act[2]()
    assert_equal(S.lib.types.pending(1), nil, where .. ": canceled")
    context.clock.run_for(settle + 0.2)
    assert_equal(S.lib.types.of(1).key, "resonator", where .. ": still on its current type")
    assert_equal(#calls(context, "setVoiceType"), 0, where .. ": no setVoiceType")
  end
  cleanup()
end)

-- 3.9 (#870): the settle clock goes through the clock helper, so a cancel
-- that falls after its wake is posted (a recall, a set, a PSET read) never
-- cancels a clock whose resume is on its way
test("the type settle stopped as its wake is posted: no clock error, and nothing more happens", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.lib.types.turn(1, 1)
  local id = S.type_settle_clocks[1]
  assert_equal(type(id), "number", "the settle clock runs")
  context.clear_engine_calls()
  -- a body that ran on after the stop would flush (with nothing pending, a
  -- flush changes nothing else): count the flushes its wake makes
  local real_flush, wake_flushes = S.lib.types.flush, 0
  context.clock.advance_until(id, function()
    S.lib.types.cancel(1)
    S.lib.types.flush = function(...) wake_flushes = wake_flushes + 1; return real_flush(...) end
  end)
  S.lib.types.flush = real_flush
  assert_equal(wake_flushes, 0, "the canceled settle's wake does nothing: no flush")
  local errors = context.clock.take_errors()
  assert_equal(#errors, 0, "no resume reaches a canceled clock" .. (errors[1] and (": " .. errors[1]) or ""))
  assert_equal(S.lib.types.pending(1), nil, "nothing pending")
  assert_equal(S.type_settle_clocks[1], nil, "and no settle clock")
  context.clock.run_for(S.lib.types.TYPES.settle_seconds * 2)
  assert_equal(S.lib.types.of(1).key, "resonator", "the settle applied no type")
  assert_equal(#calls(context, "setVoiceType"), 0, "no setVoiceType")
  -- a turn as the wake is posted: the old settle applies nothing, the new one its choice
  S.lib.types.turn(1, 1)
  context.clock.advance_until(S.type_settle_clocks[1], function() S.lib.types.turn(1, 1) end)
  assert_equal(#context.clock.take_errors(), 0, "a turn at the wake: no clock error")
  assert_equal(S.lib.types.pending(1), 3, "the new choice pending")
  assert_equal(S.lib.types.of(1).key, "resonator", "nothing applied at the old wake")
  context.clock.run_for(S.lib.types.TYPES.settle_seconds + 0.2)
  assert_equal(S.lib.types.of(1).key, "folder", "the new settle applies its choice")
  cleanup()
end)

test("a frozen voice stays frozen across a type change", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  params:set("v1_freeze", 1)
  context.clear_engine_calls()
  params:set("v1_type", 2)
  assert_equal(params:get("v1_freeze"), 1, "still frozen")
  -- fact test 14 reads "no freeze grain send", but the type change's one
  -- voice sync (fact test 7) sends every value, the held freeze among them,
  -- and the engine's freezeVoice takes a freeze 1 of a frozen voice as the
  -- freeze it holds. So exactly one freeze send, 1, after the type (#839)
  local freezes, type_at, freeze_at = {}, nil, nil
  for index, call in ipairs(context.engine_calls) do
    if call.name == "setVoiceType" and call.args[1] == 0 then type_at = type_at or index end
    if call.name == "setGrainParam" and call.args[1] == 0 and call.args[2] == "freeze" then
      freezes[#freezes + 1] = tostring(call.args[3]); freeze_at = freeze_at or index
    end
  end
  assert_equal(table.concat(freezes, ","), "1", "one freeze grain send, 1: never 0, never twice")
  assert_true(type_at ~= nil and freeze_at > type_at, "the sync's freeze comes after setVoiceType")
  assert_equal(#calls(context, "setVoiceType"), 1, "the type is sent")
  cleanup()
end)

end

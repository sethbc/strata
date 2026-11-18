-- test/unit/types_wave_test.lua
-- The wave voice type (3.8, package 1f, design §3; lib/types/wave.lua): a
-- wavetable voice that morphs across a bank of tables. Its record, its
-- place after the built-in types, the keys a voice on it sends, its shared
-- keys' specs and MAIN's E3 on morph. The engine's side is
-- test/engine_check/types/wave.scd.
-- Run alone: lua test/run.lua types_wave

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, show_page = h.load_strata, h.local_value, h.finish_startup, h.show_page

-- The record as the brief gives it: its keys, specs ({min, max, warp,
-- step, default, units}), formats, main, expression key and envelope
local WAVE = {
  key = "wave", name = "wave", list_name = "wave", def = "strataWave",
  param_order = {"freq", "morph", "morphRate", "morphDepth", "detune", "amp", "pan"},
  main = {key = "morph", label = "morph", format = "%.2f"}, note_main = "morph",
  envelope = {attack = 3, release = 6},
  own_specs = {
    morph = {0, 1, "lin", 0.01, 0.3, ""},
    morphRate = {0.01, 1, "lin", 0.01, 0.05, "Hz"},
    morphDepth = {0, 1, "lin", 0.01, 0.2, ""},
    detune = {0, 0.02, "lin", 0.001, 0.003, ""},
  },
  formats = {detune = "%.3f"},
}

-- A spec's warp as a name, on norns (a warp table) and the stub (warp_name)
local function warp_of(spec)
  if spec.warp_name then return spec.warp_name end
  local probe = controlspec.new(1, 2, "exp")
  return spec.warp == probe.warp and "exp" or "lin"
end

local function spec_text(spec)
  return string.format("%s %s %s %s %s %s", tostring(spec.minval), tostring(spec.maxval), warp_of(spec),
    tostring(spec.step), tostring(spec.units or ""), tostring(spec.quantum))
end

-- The built-in types: each voice's own type (the 3.7 roster), the last of
-- them the highest index a voice starts on
local function built_in_count(S)
  local count = 0
  for voice = 1, S.constants.NUM_VOICES do
    count = math.max(count, S.lib.types.record(S.lib.types.default_key(voice)).index)
  end
  return count
end

local function calls(context, name, voice)
  local found = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == name and (voice == nil or call.args[1] == voice - 1) then found[#found + 1] = call end
  end
  return found
end

test("wave registers at its place with its keys, specs and main", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("wave")
  assert_true(record ~= nil, "the wave type is registered")
  local list = S.lib.types.list()
  assert_equal(list[record.index].key, "wave", "its index is its place in list()")
  assert_true(record.index > built_in_count(S), "after the built-in types")
  for _, field in ipairs({"key", "name", "list_name", "def", "note_main"}) do
    assert_equal(record[field], WAVE[field], "its " .. field)
  end
  assert_equal(table.concat(record.param_order, " "), table.concat(WAVE.param_order, " "), "its keys, in order")
  for field, value in pairs(WAVE.main) do assert_equal(record.main[field], value, "main " .. field) end
  assert_equal(record.envelope.attack, WAVE.envelope.attack, "its attack")
  assert_equal(record.envelope.release, WAVE.envelope.release, "its release")
  for key, want in pairs(WAVE.own_specs) do
    local spec = record.specs[key]
    assert_equal(spec_text(spec), string.format("%s %s %s %s %s %s", tostring(want[1]), tostring(want[2]), want[3],
      tostring(want[4]), want[6], tostring(spec.quantum)), key .. "'s spec")
    assert_near(record.defaults[key], want[5], 1e-9, key .. "'s default")
  end
  for key in pairs(WAVE.own_specs) do assert_equal(record.formats[key], WAVE.formats[key], key .. "'s format") end
  for voice = 1, S.constants.NUM_VOICES do
    assert_true(params.lookup["v" .. voice .. "_morph"] ~= nil, "voice " .. voice .. " has wave's morph")
    assert_true(not params:visible("v" .. voice .. "_morph"), "hidden while the voice is on its own type")
  end
  assert_equal(params:lookup_param("v1_type").options[record.index], "wave", "an option of every voice's type")
  cleanup()
end)

test("a voice switched to wave sends only its keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("wave")
  assert_true(S.voices[1].active, "voice 1 runs")
  local synth = {}
  for _, key in ipairs(S.lib.types.keys()) do synth[key] = true end
  context.clear_engine_calls()
  params:set("v1_type", record.index)
  local types = calls(context, "setVoiceType", 1)
  assert_equal(#types, 1, "one setVoiceType")
  assert_equal(types[1].args[2], record.index - 1, "the engine's type is the index less one")
  local sent = {}
  for _, call in ipairs(calls(context, "setVoiceParam", 1)) do
    if synth[call.args[2]] then sent[#sent + 1] = call.args[2] end
  end
  table.sort(sent)
  local own = {}
  for _, key in ipairs(WAVE.param_order) do own[#own + 1] = key end
  table.sort(own)
  assert_equal(table.concat(sent, " "), table.concat(own, " "), "exactly wave's keys, once each")
  context.clear_engine_calls()
  params:set("v1_morph", 0.8)
  params:set("v1_rq", 0.5)
  local morph, rq
  for _, call in ipairs(calls(context, "setVoiceParam", 1)) do
    if call.args[2] == "morph" then morph = call.args[3] end
    if call.args[2] == "rq" then rq = call.args[3] end
  end
  assert_near(morph, 0.8, 1e-9, "morph reaches the engine")
  assert_equal(rq, nil, "resonator's rq, hidden now, sends nothing")
  cleanup()
end)

test("its shared keys keep the first type's spec", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("wave")
  local shared = 0
  for _, key in ipairs(record.param_order) do
    local first
    for _, other in ipairs(S.lib.types.list()) do
      if other.index < record.index and other.specs[key] and not first then first = other end
    end
    if first then
      shared = shared + 1
      assert_equal(spec_text(record.specs[key]), spec_text(first.specs[key]), key .. ": " .. first.key .. "'s spec")
      assert_equal(record.defaults[key], first.defaults[key], key .. ": " .. first.key .. "'s default")
      assert_equal(record.formats[key], first.formats[key], key .. ": " .. first.key .. "'s format")
    end
  end
  assert_equal(shared, 3, "freq, amp and pan are shared with the first type")
  assert_equal(record.defaults.freq, 100, "freq 100")
  assert_equal(record.defaults.amp, 0.3, "amp 0.3")
  assert_equal(record.defaults.pan, 0, "pan 0")
  cleanup()
end)

test("a wave voice's MAIN E3 moves morph", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("MAIN")
  params:set("v1_type", S.lib.types.record("wave").index)
  assert_equal(main_param_id(1), "v1_morph", "E3's param is wave's main")
  assert_equal(main_param_entry(1).label, "morph", "labeled so")
  S.main_field = 1
  local before = params:get("v1_morph")
  enc(3, 2)
  assert_true(params:get("v1_morph") > before, "E3 moves v1_morph")
  assert_equal(S.voice_list.entries[1], "1+ wave", "the list shows wave's list name")
  cleanup()
end)

end

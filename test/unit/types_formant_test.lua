-- test/unit/types_formant_test.lua
-- The formant voice type (3.8, package 1j): its record (lib/types/formant.lua),
-- its place after the built-in types, what a voice switched to it sends and
-- the specs of the keys it shares with an earlier type.
-- Run alone: lua test/run.lua types_formant

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- The record as the brief gives it: {min, max, warp, step, default, units}
local FORMANT = {
  key = "formant", name = "formant", list_name = "vox", def = "strataFormant", note_main = "formant",
  main = {key = "formant", label = "form", format = "%.2f"}, envelope = {attack = 3, release = 6},
  param_order = {"freq", "formant", "vowel", "bw", "amp", "pan"},
  specs = {
    freq = {20, 2000, "exp", 0, 100, "Hz"},
    formant = {0.5, 2, "lin", 0.01, 1, ""},
    vowel = {0, 1, "lin", 0.01, 0.5, ""},
    bw = {0.1, 1, "lin", 0.01, 0.5, ""},
    amp = {0, 1, "lin", 0.01, 0.3, ""},
    pan = {-1, 1, "lin", 0.01, 0, ""},
  },
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

local function calls(context, name, voice)
  local found = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == name and (voice == nil or call.args[1] == voice - 1) then found[#found + 1] = call end
  end
  return found
end

test("formant registers at its place with its keys, specs and main", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("formant")
  assert_true(record ~= nil, "the formant type is registered")
  local list = S.lib.types.list()
  assert_true(list[record.index] ~= nil and list[record.index].key == "formant", "list()[index] is formant")
  -- after the built-in types: every voice's own type comes before it
  for voice = 1, S.constants.NUM_VOICES do
    local own = S.lib.types.record(S.lib.types.default_key(voice))
    assert_true(record.index > own.index, "after voice " .. voice .. "'s own type, " .. own.key)
  end
  -- the engine's list holds its def at the same place (0-based there)
  local engine_index
  for index, name in ipairs(h.engine_spec.voice_type_defs) do
    if name == FORMANT.def then engine_index = index - 1 end
  end
  assert_equal(engine_index, record.index - 1, "voiceTypeDefs.indexOf(\\strataFormant) == index - 1")
  for _, field in ipairs({"key", "name", "list_name", "def", "note_main"}) do
    assert_equal(record[field], FORMANT[field], "its " .. field)
  end
  for field, value in pairs(FORMANT.main) do assert_equal(record.main[field], value, "main " .. field) end
  assert_equal(record.envelope.attack, FORMANT.envelope.attack, "its attack")
  assert_equal(record.envelope.release, FORMANT.envelope.release, "its release")
  assert_equal(table.concat(record.param_order, " "), table.concat(FORMANT.param_order, " "), "its keys")
  for _, key in ipairs(FORMANT.param_order) do
    local want = FORMANT.specs[key]
    assert_equal(spec_text(record.specs[key]),
      string.format("%s %s %s %s %s %s", tostring(want[1]), tostring(want[2]), want[3], tostring(want[4]), want[6], "0.01"),
      key .. "'s spec")
    assert_equal(record.defaults[key], want[5], key .. "'s default")
  end
  assert_equal(S.lib.types.format("formant"), nil, "formant's value has no format of its own")
  for voice = 1, S.constants.NUM_VOICES do
    for _, key in ipairs({"formant", "vowel", "bw"}) do
      local id = "v" .. voice .. "_" .. key
      assert_true(params.lookup[id] ~= nil, id .. " exists")
      assert_equal(params:get(id), FORMANT.specs[key][5], id .. "'s default")
      assert_true(not params:visible(id), id .. " is hidden on voice " .. voice .. "'s own type")
    end
  end
  cleanup()
end)

test("a voice switched to formant sends only its keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  context.clear_engine_calls()
  params:set("v1_type", S.lib.types.record("formant").index)
  local types = calls(context, "setVoiceType", 1)
  assert_equal(#types, 1, "one setVoiceType")
  assert_equal(types[1].args[2], S.lib.types.record("formant").index - 1, "to formant's engine type")
  local synth, sent = {}, {}
  for _, key in ipairs(S.lib.types.keys()) do synth[key] = true end
  for _, call in ipairs(calls(context, "setVoiceParam", 1)) do
    if synth[call.args[2]] then sent[#sent + 1] = call.args[2] end
  end
  table.sort(sent)
  assert_equal(table.concat(sent, " "), "amp bw formant freq pan vowel", "exactly formant's keys, once")
  assert_true(params:visible("v1_vowel") and not params:visible("v1_rq"), "formant's keys show, resonator's hide")
  assert_equal(S.voices[1].name, "formant", "the voice's name is the type's key")
  -- its own keys reach the engine now
  context.clear_engine_calls()
  params:set("v1_vowel", 0.8)
  params:set("v1_bw", 0.2)
  params:set("v1_formant", 1.5)
  local values = {}
  for _, call in ipairs(calls(context, "setVoiceParam", 1)) do values[call.args[2]] = call.args[3] end
  assert_equal(values.vowel, 0.8, "vowel is sent")
  assert_equal(values.bw, 0.2, "bw is sent")
  assert_equal(values.formant, 1.5, "formant is sent")
  -- and MAIN's E3 follows formant's main
  assert_equal(S.lib.types.of(1).main.key, "formant", "the main is formant")
  cleanup()
end)

test("its shared keys keep the first type's spec", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("formant")
  for _, key in ipairs(record.param_order) do
    local first
    for _, other in ipairs(S.lib.types.list()) do
      if not first and other.specs[key] then first = other end
    end
    if first ~= record then
      assert_equal(spec_text(record.specs[key]), spec_text(first.specs[key]), key .. ": " .. first.key .. "'s spec")
      assert_equal(record.defaults[key], first.defaults[key], key .. ": " .. first.key .. "'s default")
    end
  end
  assert_equal(S.lib.types.list()[1].defaults.freq, record.defaults.freq, "freq: the first type's default")
  cleanup()
end)

end

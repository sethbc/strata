-- test/unit/types_noise_test.lua
-- The noise voice type (3.8, package 1h; lib/types/noise.lua): colored
-- noise and dust through a resonant bank, the engine's \strataNoise
-- (lib/engine/StrataTypeNoise.sc). Its place is read from the list, never
-- written as a number (ruling 64): the five new types land in one batch,
-- and that order alone gives their numbers.
-- Run alone: lua test/run.lua types_noise

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- What the record must give (task 1h): {min, max, warp, step, units, default}
local NOISE = {
  key = "noise", name = "noise", list_name = "noise", def = "strataNoise",
  param_order = {"freq", "color", "grit", "dust", "q", "bank", "amp", "pan"},
  specs = {
    color = {0, 1, "lin", 0.01, "", 0.5},
    grit = {0, 1, "lin", 0.01, "", 0.3},
    dust = {0.5, 50, "exp", 0, "/s", 8},
    q = {0.005, 1, "exp", 0, "", 0.05},
    bank = {0, 1, "lin", 0.01, "", 0.7},
  },
  main = {key = "q", label = "q", format = "%.3f"},
  note_main = "q",
  envelope = {attack = 3, release = 6},
}
-- The keys noise shares with an earlier type, which keep the first type's spec and default
local SHARED = {"freq", "amp", "pan"}

-- A spec's warp as a name, on norns (a warp table) and the stub (warp_name)
local function warp_of(spec)
  if spec.warp_name then return spec.warp_name end
  local probe = controlspec.new(1, 2, "exp")
  return spec.warp == probe.warp and "exp" or "lin"
end

local function spec_text(spec)
  return string.format("%s %s %s %s %s", tostring(spec.minval), tostring(spec.maxval), warp_of(spec),
    tostring(spec.step), tostring(spec.units or ""))
end

local function calls(context, name, voice)
  local found = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == name and (voice == nil or call.args[1] == voice - 1) then found[#found + 1] = call end
  end
  return found
end

test("noise registers at its place with its keys, specs and main", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("noise")
  assert_true(record ~= nil, "a noise type")
  local list, place = S.lib.types.list(), nil
  for index, each in ipairs(list) do
    if each == record then place = index end
  end
  assert_equal(record.index, place, "its index is its place in the list")
  assert_equal(list[record.index].key, "noise", "list()[index] is noise")
  for voice = 1, S.constants.NUM_VOICES do
    local built_in = S.lib.types.record(S.lib.types.default_key(voice))
    assert_true(built_in.index < record.index, "after the built-in type " .. built_in.key)
  end
  for _, field in ipairs({"key", "name", "list_name", "def", "note_main"}) do
    assert_equal(record[field], NOISE[field], "its " .. field)
  end
  assert_equal(table.concat(record.param_order, " "), table.concat(NOISE.param_order, " "), "its keys")
  for field, value in pairs(NOISE.main) do assert_equal(record.main[field], value, "main " .. field) end
  assert_equal(record.envelope.attack, NOISE.envelope.attack, "its attack")
  assert_equal(record.envelope.release, NOISE.envelope.release, "its release")
  for key, want in pairs(NOISE.specs) do
    local text = string.format("%s %s %s %s %s", tostring(want[1]), tostring(want[2]), want[3], tostring(want[4]), want[5])
    assert_equal(spec_text(record.specs[key]), text, key .. "'s spec")
    assert_equal(record.defaults[key], want[6], key .. "'s default")
  end
  assert_equal(record.formats.q, "%.3f", "q shows three decimals (its step is under 0.01, #386)")
  assert_equal(params:string("v1_q"), "0.050", "v1_q as PARAMETERS shows it")
  cleanup()
end)

test("a voice switched to noise sends only its keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("noise")
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
  local want = {}
  for _, key in ipairs(NOISE.param_order) do want[#want + 1] = key end
  table.sort(want)
  assert_equal(table.concat(sent, " "), table.concat(want, " "), "exactly noise's keys, once each")
  assert_equal(S.voices[1].name, "noise", "the voice is on noise")
  assert_true(params:visible("v1_q") and not params:visible("v1_rq"), "noise's keys show, resonator's hide")
  context.clear_engine_calls()
  params:set("v1_grit", 0.9)
  local grit = calls(context, "setVoiceParam", 1)
  assert_equal(#grit, 1, "a noise key reaches the engine")
  assert_equal(grit[1].args[2] .. " " .. grit[1].args[3], "grit 0.9", "as grit")
  context.clear_engine_calls()
  params:set("v2_grit", 0.9)
  assert_equal(#calls(context, "setVoiceParam", 2), 0, "and nothing for a voice on another type")
  cleanup()
end)

test("its shared keys keep the first type's spec", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record, first = S.lib.types.record("noise"), S.lib.types.list()[1]
  for _, key in ipairs(SHARED) do
    assert_equal(spec_text(record.specs[key]), spec_text(first.specs[key]), key .. "'s spec is the first type's")
    assert_equal(record.specs[key].quantum, first.specs[key].quantum, key .. "'s quantum")
    assert_equal(record.defaults[key], first.defaults[key], key .. "'s default is the first type's")
    assert_equal(record.formats[key], first.formats[key], key .. "'s format")
  end
  cleanup()
end)

end

-- test/unit/types_additive_test.lua
-- The additive voice type (3.8, package 1g): its record
-- (lib/types/additive.lua), its place after the built-in types, what a
-- voice switched to it sends, and the spec of every key it shares with an
-- earlier type. Its def is checked in test/engine_check/types/additive.scd.
-- Run alone: lua test/run.lua types_additive

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- The record as the brief gives it: keys, defaults, specs ({min, max, warp,
-- step, units}), its main, expression key and envelope
local WANT = {
  key = "additive", name = "additive", list_name = "add", def = "strataAdditive",
  param_order = {"freq", "tilt", "stretch", "oddEven", "wander", "amp", "pan"},
  defaults = {freq = 100, tilt = 1, stretch = 0, oddEven = 0.5, wander = 0.2, amp = 0.3, pan = 0},
  specs = {
    freq = {20, 2000, "exp", 0, "Hz"}, tilt = {0, 3, "lin", 0.01, ""}, stretch = {-1, 1, "lin", 0.01, ""},
    oddEven = {0, 1, "lin", 0.01, ""}, wander = {0.01, 1, "lin", 0.01, "Hz"}, amp = {0, 1, "lin", 0.01, ""},
    pan = {-1, 1, "lin", 0.01, ""},
  },
  main = {key = "tilt", label = "tilt", format = "%.2f"},
  note_main = "tilt",
  envelope = {attack = 4, release = 8},
}

-- The seven types every build starts with: the new types follow them
local BUILT_IN_KEYS = {"resonator", "fm", "folder", "sub", "pulse", "karplus", "ring"}

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

test("additive registers at its place with its keys, specs and main", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("additive")
  assert_true(record ~= nil, "the additive type is registered")
  local list = S.lib.types.list()
  assert_equal(list[record.index].key, "additive", "its index is its place in the list")
  assert_true(record.index > #BUILT_IN_KEYS, "after the built-in types")
  for index, key in ipairs(BUILT_IN_KEYS) do
    assert_equal(list[index].key, key, "the built-in type " .. key .. " keeps its place")
  end
  assert_equal(record.name, WANT.name, "its name")
  assert_equal(record.list_name, WANT.list_name, "its list name")
  assert_true(#record.list_name <= 5, "a list name MAIN's list fits")
  assert_equal(record.def, WANT.def, "its def")
  assert_equal(table.concat(record.param_order, " "), table.concat(WANT.param_order, " "), "its keys, in order")
  for _, key in ipairs(WANT.param_order) do
    local s = WANT.specs[key]
    assert_equal(record.defaults[key], WANT.defaults[key], key .. "'s default")
    assert_equal(spec_text(record.specs[key]), string.format("%s %s %s %s %s", tostring(s[1]), tostring(s[2]),
      s[3], tostring(s[4]), s[5]), key .. "'s spec")
    assert_equal(record.specs[key].default, WANT.defaults[key], key .. "'s spec default")
  end
  for field, value in pairs(WANT.main) do assert_equal(record.main[field], value, "main " .. field) end
  assert_equal(record.note_main, WANT.note_main, "its expression key")
  assert_equal(record.envelope.attack, WANT.envelope.attack, "its attack")
  assert_equal(record.envelope.release, WANT.envelope.release, "its release")
  -- a voice switched to it shows its keys under its name
  params:set("v1_type", record.index)
  assert_equal(S.lib.types.of(1).key, "additive", "voice 1 is additive")
  assert_true(params:visible("v1_tilt") and params:visible("v1_wander"), "its keys show")
  assert_true(not params:visible("v1_rq"), "the resonator's hide")
  -- steps of 0.01 need no format of their own (#386); "%.2f" is MAIN's
  for _, key in ipairs(WANT.param_order) do assert_equal(record.formats[key], nil, key .. " has no format") end
  cleanup()
end)

test("a voice switched to additive sends only its keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  local index = S.lib.types.record("additive").index
  context.clear_engine_calls()
  params:set("v1_type", index)
  local types = calls(context, "setVoiceType", 1)
  assert_equal(#types, 1, "one setVoiceType")
  assert_equal(types[1].args[2], index - 1, "to the engine's type, its index less one")
  local synth, sent = {}, {}
  for _, key in ipairs(S.lib.types.keys()) do synth[key] = true end
  for _, call in ipairs(calls(context, "setVoiceParam", 1)) do
    if synth[call.args[2]] then sent[#sent + 1] = call.args[2] end
  end
  table.sort(sent)
  assert_equal(table.concat(sent, " "), "amp freq oddEven pan stretch tilt wander", "exactly additive's keys, once")
  -- its own keys reach the engine; another type's send nothing
  context.clear_engine_calls()
  params:set("v1_tilt", 2.5)
  params:set("v1_rq", 0.5)
  local tilt, rq
  for _, call in ipairs(calls(context, "setVoiceParam", 1)) do
    if call.args[2] == "tilt" then tilt = call.args[3] end
    if call.args[2] == "rq" then rq = call.args[3] end
  end
  assert_equal(tilt, 2.5, "tilt reaches the engine")
  assert_equal(rq, nil, "the resonator's hidden rq sends nothing")
  -- MAIN's E3 is tilt
  assert_equal(S.lib.types.of(1).main.key, "tilt", "MAIN's E3 follows the type to tilt")
  cleanup()
end)

test("its shared keys keep the first type's spec", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("additive")
  for _, key in ipairs(record.param_order) do
    local first
    for _, other in ipairs(S.lib.types.list()) do
      if first == nil and other.specs[key] then first = other end
    end
    assert_equal(spec_text(record.specs[key]), spec_text(first.specs[key]), key .. ": the spec of " .. first.key)
    assert_equal(record.formats[key], first.formats[key], key .. ": the format of " .. first.key)
    if first.key ~= "additive" then
      assert_equal(record.defaults[key], S.lib.types.list()[1].defaults[key] or first.defaults[key],
        key .. ": the first type's default")
    end
  end
  for _, key in ipairs({"tilt", "stretch", "oddEven", "wander"}) do
    local owners = 0
    for _, other in ipairs(S.lib.types.list()) do
      if other.specs[key] then owners = owners + 1 end
    end
    assert_equal(owners, 1, key .. " is additive's own key")
  end
  cleanup()
end)

end

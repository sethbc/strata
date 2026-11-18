-- test/unit/types_saw_test.lua
-- The saw voice type (3.8, package 1i; lib/types/saw.lua): three detuned
-- variable saws a side through a resonant lowpass, \strataSaw
-- (lib/engine/StrataTypeSaw.sc). Every key is shared: width, cutoff and res
-- are Pulse's, detune is wave's. See docs/notes/lua/types.md
-- Run alone: lua test/run.lua types_saw

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local SAW_KEYS = {"freq", "width", "detune", "cutoff", "res", "amp", "pan"}
-- detune's one spec, wave's (package 1f): 0-0.02, linear, step 0.001,
-- default 0.003, three decimals (#386's rule for steps under 0.01)
local DETUNE = {minval = 0, maxval = 0.02, warp = "lin", step = 0.001, default = 0.003, format = "%.3f"}

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

local function calls(context, name, voice)
  local found = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == name and (voice == nil or call.args[1] == voice - 1) then found[#found + 1] = call end
  end
  return found
end

-- The synth keys a voice's setVoiceParam calls named, in order, with their values
local function synth_sends(context, S, voice)
  local synth, sent, values = {}, {}, {}
  for _, key in ipairs(S.lib.types.keys()) do synth[key] = true end
  for _, call in ipairs(calls(context, "setVoiceParam", voice)) do
    if synth[call.args[2]] then
      sent[#sent + 1] = call.args[2]
      values[call.args[2]] = call.args[3]
    end
  end
  return sent, values
end

local function sorted_text(list)
  local copy = {}
  for index, value in ipairs(list) do copy[index] = value end
  table.sort(copy)
  return table.concat(copy, " ")
end

-- The first type before saw that has key, or nil
local function earlier_with(S, key)
  for _, record in ipairs(S.lib.types.list()) do
    if record.key == "saw" then return nil end
    if record.specs[key] then return record end
  end
  return nil
end

test("saw registers at its place with its keys, specs and main", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("saw")
  assert_true(record ~= nil, "saw is a type")
  local list = S.lib.types.list()
  assert_true(list[record.index] == record, "its index is its place in the list")
  assert_equal(list[record.index].key, "saw", "list()[index] is saw")
  assert_true(record.index > S.lib.types.record("ring").index, "after the seven built-in types (ring the last)")
  assert_equal(record.name, "saw", "its name")
  assert_equal(record.list_name, "saw", "its list name")
  assert_equal(record.def, "strataSaw", "its def")
  assert_equal(table.concat(record.param_order, " "), table.concat(SAW_KEYS, " "), "its keys")
  assert_equal(record.main.key, "width", "main: width")
  assert_equal(record.main.label, "width", "labeled width")
  assert_equal(record.main.format, "%.2f", "two decimals")
  assert_equal(record.note_main, "width", "the expression moves width")
  assert_equal(record.envelope.attack, 3, "a 3 s attack")
  assert_equal(record.envelope.release, 6, "a 6 s release")
  local detune = record.specs.detune
  assert_equal(spec_text(detune), spec_text(controlspec.new(DETUNE.minval, DETUNE.maxval, DETUNE.warp, DETUNE.step,
    DETUNE.default)), "detune's spec is wave's")
  assert_equal(record.defaults.detune, DETUNE.default, "detune's default is wave's")
  assert_equal(record.formats.detune, DETUNE.format, "and its format")
  assert_true(params:lookup_param("v1_detune") ~= nil, "every voice has a detune")
  cleanup()
end)

test("its shared keys keep the first type's spec", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.lib.types.record("saw")
  for _, key in ipairs(record.param_order) do
    local earlier = earlier_with(S, key)
    if key == "detune" then
      assert_true(earlier == nil or earlier.key == "wave", "detune is wave's key")
    else
      assert_true(earlier ~= nil, key .. " is an earlier type's key")
      assert_equal(spec_text(record.specs[key]), spec_text(earlier.specs[key]), key .. ": " .. earlier.key .. "'s spec")
      assert_equal(record.defaults[key], earlier.defaults[key], key .. ": " .. earlier.key .. "'s default")
      assert_equal(record.formats[key], earlier.formats[key], key .. ": " .. earlier.key .. "'s format")
    end
  end
  assert_equal(earlier_with(S, "width").key, "pulse", "width is Pulse's")
  assert_equal(earlier_with(S, "cutoff").key, "pulse", "cutoff is Pulse's")
  assert_equal(earlier_with(S, "res").key, "pulse", "res is Pulse's")
  cleanup()
end)

test("a voice switched to saw sends only its keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local saw = S.lib.types.record("saw")
  if not S.voices[2].active then toggle_voice(2) end
  context.clear_engine_calls()
  params:set("v2_type", saw.index)
  local types = calls(context, "setVoiceType", 2)
  assert_equal(#types, 1, "one setVoiceType")
  assert_equal(types[1].args[2], saw.index - 1, "to saw's engine type, index - 1")
  local sent = synth_sends(context, S, 2)
  assert_equal(sorted_text(sent), sorted_text(SAW_KEYS), "exactly saw's keys, once each")
  context.clear_engine_calls()
  params:set("v2_ratio", 3)
  assert_equal(#calls(context, "setVoiceParam", 2), 0, "fm's ratio sends nothing on saw")
  params:set("v2_detune", 0.01)
  local _, values = synth_sends(context, S, 2)
  assert_near(values.detune, 0.01, 1e-9, "saw's detune is sent")
  cleanup()
end)

test("pulse to saw keeps width, cutoff and res", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_equal(S.lib.types.of(5).key, "pulse", "voice 5 starts on pulse")
  if not S.voices[5].active then toggle_voice(5) end
  params:set("v5_width", 0.3)
  params:set("v5_cutoff", 900)
  params:set("v5_res", 0.5)
  context.clear_engine_calls()
  params:set("v5_type", S.lib.types.record("saw").index)
  assert_equal(S.lib.types.of(5).key, "saw", "voice 5 plays saw")
  assert_near(params:get("v5_width"), 0.3, 1e-9, "width is still 0.3")
  assert_near(params:get("v5_cutoff"), 900, 1e-6, "cutoff is still 900")
  assert_near(params:get("v5_res"), 0.5, 1e-9, "res is still 0.5")
  local _, values = synth_sends(context, S, 5)
  assert_near(values.width, 0.3, 1e-9, "and width 0.3 is sent on saw")
  assert_near(values.cutoff, 900, 1e-6, "cutoff 900")
  assert_near(values.res, 0.5, 1e-9, "res 0.5")
  cleanup()
end)

-- #314's rule for Pulse, on saw: the mirror its res plays through must be
-- PULSE_RES.mirror (rq = <mirror> - res.clip(min, max)) over the param's
-- range, so one res sounds the same on both types. Read from the engine
-- source with its comments stripped, as voices_test.lua's Pulse check is
test("the saw res mirror is PULSE_RES.mirror", function()
  load_strata()
  local constants = local_value("S").constants
  local source = h.stubs.strip_sc_comments(h.engine_sources())
  local start = assert(source:find("SynthDef%(\\strataSaw"), "the engine defines \\strataSaw")
  local def = source:sub(start, (source:find("}%)%.add", start)))
  local mirror, low, high = def:match("RLPF%.ar%(.-,%s*([%d%.]+)%s*%-%s*res%.clip%(%s*([%d%.]+)%s*,%s*([%d%.]+)%s*%)%s*%)")
  assert_true(mirror ~= nil, "\\strataSaw's RLPF plays rq = <mirror> - res.clip(<min>, <max>)")
  assert_near(tonumber(mirror), constants.PULSE_RES.mirror, 1e-9, "the engine's mirror is PULSE_RES.mirror")
  local spec = params:lookup_param("v5_res").controlspec
  assert_near(tonumber(low), spec.minval, 1e-9, "the engine clips res at the param's minimum")
  assert_near(tonumber(high), spec.maxval, 1e-9, "and at its maximum")
end)

end

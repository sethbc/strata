-- test/unit/voices_test.lua
-- Voice sources: synth, buffer and input voices (lib/voices.lua)
-- Run alone: lua test/run.lua voices

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, next_frame = h.load_strata, h.local_value, h.next_frame
local finish_startup, deep_copy = h.finish_startup, h.deep_copy

test("input-sourced voices: main param, faders, randomize, mutate and drift use grain params", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 running
  local device = context.arc.plug(1)
  params:set("v1_source", 10)
  assert_equal(main_param_id(1), "v1_grain_size"); assert_equal(main_param_entry(1).label, "size")
  assert_equal(fader_param_ids(1)[1], "v1_grain_size", "first grid fader")
  for _, id in ipairs(fader_param_ids(1)) do
    assert_true(not id:find("_buf_"), id .. ": no buffer faders for input")
  end
  -- the grain faders, then level and pan (the engine pans input voices), then crossmod
  assert_equal(fader_param_ids(1)[7], "v1_amp"); assert_equal(fader_param_ids(1)[8], "v1_pan")
  assert_equal(fader_param_ids(1)[9], "v1_mod_source_1")
  params:set("v4_source", 10)
  assert_equal(fader_param_ids(4)[7], "v4_amp"); assert_equal(fader_param_ids(4)[8], "v4_mod_source_1", "sub has no pan fader")
  assert_equal(#fader_param_ids(1), 6 + 2 + 9); assert_equal(fader_page_count(1), 5, "an input voice has 5 fader pages")
  assert_equal(fader_page_count(4), 4, "an input-sourced sub has 4 fader pages")
  params:set("v1_grain_size", 0.2)
  enc(3, 2); assert_true(params:get("v1_grain_size") > 0.2, "E3 on MAIN moves grain size")
  local size = params:get("v1_grain_size")
  context.arc.turn(1, 2, 200); assert_true(params:get("v1_grain_size") > size, "arc ring 2 moves grain size")
  next_frame(context)
  local param_min, param_max = param_range("v1_grain_size")
  assert_near(device.segments[2].to,
    util.linlin(param_min, param_max, 0, 64, params:get("v1_grain_size")) / 64 * math.pi * 2, 1e-9, "ring 2 shows grain size")
  redraw()
  local value
  for _, entry in ipairs(context.screen.texts) do if entry.x == 127 and entry.y == 34 then value = entry.text end end
  assert_equal(value, string.format("%.2f s", params:get("v1_grain_size")), "MAIN shows grain size")
  -- randomize, mutate and drift leave the synth and buffer params alone
  local synth_before = {}
  for _, key in ipairs(local_value("voices")[1].param_order) do synth_before[key] = local_value("voices")[1].values[key] end
  local buffer_before = {}
  for _, key in ipairs({ "buf_pos", "buf_rate", "buf_scan" }) do buffer_before[key] = params:get("v1_" .. key) end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(11)
  local grain_changed = false
  for _ = 1, 10 do
    local grain_before = params:get("v1_grain_size")
    randomize_voice(1); gentle_mutate(); for _ = 1, 10 do drift_update() end
    if params:get("v1_grain_size") ~= grain_before then grain_changed = true end
  end
  assert_true(grain_changed, "grain params still randomize and mutate")
  for key, val in pairs(synth_before) do
    assert_equal(local_value("voices")[1].values[key], val, "input voice keeps synth " .. key)
  end
  for key, val in pairs(buffer_before) do
    assert_equal(params:get("v1_" .. key), val, "input voice keeps " .. key)
  end
  -- buffer voices keep buf_pos
  params:set("v1_source", 2); assert_equal(main_param_id(1), "v1_buf_pos")
  assert_equal(fader_param_ids(1)[1], "v1_buf_pos")
end)

test("S keeps no master_density field: readers take the param (#393)", function()
  load_strata()
  local S = local_value("S")
  params:set("master_density", 1.5)
  assert_equal(rawget(S, "master_density"), nil, "nothing keeps a copy of the density")
  assert_near(params:get("master_density"), 1.5, 1e-9, "the param is the value")
end)

-- #314: the Pulse voice's res rises with resonance (the engine plays the
-- filter's rq as 1.1 - res); its default 0.8 plays rq 0.3, the sound 3.2's
-- default 0.3 had
test("the pulse voice starts at res 0.8, the sound of 3.2's default (#314)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  assert_equal(voices[5].name, "pulse")
  assert_near(voices[5].values.res, 0.8, 1e-9, "the voices table's default")
  assert_near(params:get("v5_res"), 0.8, 1e-9, "the param's default")
  if voices[5].active then toggle_voice(5) end
  context.clear_engine_calls()
  toggle_voice(5)
  local sent
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 4 and call.args[2] == "res" then sent = call.args[3] end
  end
  assert_true(sent ~= nil and math.abs(sent - 0.8) < 1e-6, "a start sends res 0.8 (sent: " .. tostring(sent) .. ")")
end)

-- #314: the mirror the res plays through (PULSE_RES.mirror, lib/constants.lua)
-- must be the one \strataPulse plays (rq = <mirror> - res.clip(min, max)), over
-- the param's range: if either side changes alone, saved sounds move. Read from
-- the engine source with its comments stripped, as the FX defaults' check is
test("the pulse res mirror is the engine's: \\strataPulse plays rq = PULSE_RES.mirror - res (#314)", function()
  load_strata()
  local constants = local_value("S").constants
  local source = h.stubs.strip_sc_comments(h.engine_sources())
  local start = assert(source:find("SynthDef%(\\strataPulse"), "the engine defines \\strataPulse")
  local def = source:sub(start, (source:find("}%)%.add", start)))
  local mirror, low, high = def:match("RLPF%.ar%(.-,%s*([%d%.]+)%s*%-%s*res%.clip%(%s*([%d%.]+)%s*,%s*([%d%.]+)%s*%)%s*%)")
  assert_true(mirror ~= nil, "\\strataPulse's RLPF plays rq = <mirror> - res.clip(<min>, <max>)")
  assert_near(tonumber(mirror), constants.PULSE_RES.mirror, 1e-9, "the engine's mirror is PULSE_RES.mirror")
  local spec = params:lookup_param("v5_res").controlspec
  assert_near(tonumber(low), spec.minval, 1e-9, "the engine clips res at the param's minimum")
  assert_near(tonumber(high), spec.maxval, 1e-9, "and at its maximum")
end)

-- The groundwork before 3.8 (design §2, ruling 8): one values table per
-- voice, and synth membership through is_synth_key
test("every voice holds its values in one table, by its param ids' keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    local v = S.voices[voice]
    for _, gone in ipairs({ "params", "grain", "crossmod", "extras" }) do
      assert_equal(v[gone], nil, "voice " .. voice .. " has no " .. gone)
    end
    local prefix = "v" .. voice .. "_"
    local listed = {}
    for _, param in ipairs(params.params) do
      local key = type(param.id) == "string" and param.id:sub(1, #prefix) == prefix and param.id:sub(#prefix + 1)
      if key and key ~= "source" and not key:match("^out_") and not key:match("^zone") then
        listed[key] = true
        assert_true(v.values[key] ~= nil, param.id .. " has a value")
        -- an exp control's get is map(unmap(x)), an ulp or two from the value
        -- it was set to (the voices table's literal default, freq's 100, reads
        -- back as 99.999999999999986): equal within 1e-9, anything else exactly
        local value = params:get(param.id)
        if type(value) == "number" then
          assert_near(v.values[key], value, 1e-9, param.id .. "'s value is its param's")
        else
          assert_equal(v.values[key], value, param.id .. "'s value is its param's")
        end
      end
    end
    for key in pairs(v.values) do assert_true(listed[key], "voice " .. voice .. "'s " .. key .. " is a param") end
  end
  params:set("v2_grain_size", 0.3); assert_near(S.voices[2].values.grain_size, 0.3, 1e-9, "a grain param")
  params:set("v2_mod_source_2", 5); assert_equal(S.voices[2].values.mod_source_2, 5, "a mod source")
  params:set("v2_mod_speed", 20); assert_near(S.voices[2].values.mod_speed, 20, 1e-9, "the mod speed")
  params:set("v2_reverb_send", 0.4); assert_near(S.voices[2].values.reverb_send, 0.4, 1e-9, "a registered param")
end)

test("is_synth_key is a voice's param_order", function()
  load_strata()
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    for _, key in ipairs(S.voices[voice].param_order) do
      assert_true(S.lib.voices.is_synth_key(voice, key), "voice " .. voice .. ": " .. key)
    end
    for _, key in ipairs({ "grain_size", "mod_speed", "scan_mode", "follow", "slices", "loop_start", "source" }) do
      assert_true(not S.lib.voices.is_synth_key(voice, key), "voice " .. voice .. ": " .. key .. " is no synth key")
    end
  end
  assert_true(not S.lib.voices.is_synth_key(4, "pan"), "the sub has no pan")
  assert_true(S.lib.voices.is_synth_key(5, "res") and not S.lib.voices.is_synth_key(1, "res"), "res is the pulse's")
  assert_true(not S.lib.voices.is_synth_key(0, "freq") and not S.lib.voices.is_synth_key(8, "freq"), "no such voice")
end)

end

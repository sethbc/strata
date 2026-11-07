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
  assert_equal(main_param_id(1), "v1_grain_size"); assert_equal(main_param_label(1), "size")
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
  local synth_before = deep_copy(local_value("voices")[1].params)
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
    assert_equal(local_value("voices")[1].params[key], val, "input voice keeps synth " .. key)
  end
  for key, val in pairs(buffer_before) do
    assert_equal(params:get("v1_" .. key), val, "input voice keeps " .. key)
  end
  -- buffer voices keep buf_pos
  params:set("v1_source", 2); assert_equal(main_param_id(1), "v1_buf_pos")
  assert_equal(fader_param_ids(1)[1], "v1_buf_pos")
end)

end

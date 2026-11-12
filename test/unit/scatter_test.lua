-- test/unit/scatter_test.lua
-- Scatter (lib/scatter.lua, S.lib.scatter, 3.4 design §6): the eight
-- params in the group strata_scatter, the setScatter each param and each
-- lock change sends (depth, rate, the destination mask and the mask of the
-- unlocked voices), affects(voice) and the scene fields
-- Run alone: lua test/run.lua scatter

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function loaded()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.scatter
end

-- The setScatter calls since the calls were cleared, and the last one's
-- four arguments
local function last_scatter(context)
  local calls = context.calls_named("setScatter")
  local call = calls[#calls]
  return #calls, call and call.args
end

local function assert_scatter(context, depth, rate, destinations, voices, where)
  local count, args = last_scatter(context)
  assert_equal(count, 1, where .. ": one setScatter")
  assert_near(args[1], depth, 1e-9, where .. ": depth")
  assert_near(args[2], rate, 1e-6, where .. ": rate")
  assert_equal(args[3], destinations, where .. ": destination mask")
  assert_equal(args[4], voices, where .. ": voice mask")
  context.clear_engine_calls()
end

local IDS = { "scatter", "scatter_depth", "scatter_rate", "scatter_pitch", "scatter_pos", "scatter_size",
  "scatter_cutoff", "scatter_amp" }

test("the scatter params are a group of eight, off at 10 %, 0.1 Hz on pitch and position", function()
  local context, S = loaded()
  assert_true(S.lib.scatter ~= nil, "S.lib.scatter is the module's table")
  local group = params:lookup_param("strata_scatter")
  assert_equal(group.t, params.tGROUP, "strata_scatter is a group")
  assert_equal(group.n, 8, "of eight params")
  local index = params.lookup["strata_scatter"]
  for offset, id in ipairs(IDS) do assert_equal(params.params[index + offset].id, id, "param " .. offset) end
  local defaults = { scatter = 0, scatter_depth = 10, scatter_rate = 0.1, scatter_pitch = 1, scatter_pos = 1,
    scatter_size = 0, scatter_cutoff = 0, scatter_amp = 0 }
  for id, default in pairs(defaults) do assert_near(params:get(id), default, 1e-6, id .. "'s default") end
  for _, id in ipairs({ "scatter", "scatter_pitch", "scatter_pos", "scatter_size", "scatter_cutoff", "scatter_amp" }) do
    assert_equal(params:lookup_param(id).t, params.tBINARY, id .. " is a toggle")
  end
  local low, high = param_range("scatter_depth")
  assert_equal(low, 0); assert_equal(high, 100)
  low, high = param_range("scatter_rate")
  assert_near(low, 0.01, 1e-9); assert_near(high, 1, 1e-9)
  assert_equal(params:lookup_param("scatter_rate").controlspec.warp_name, "exp", "the rate moves in octaves")
  assert_equal(params:string("scatter_depth"), "10 %")
  assert_equal(params:string("scatter_rate"), "0.10 Hz")
  -- nothing is sent at the start: scatter is off, as in 3.3
  assert_equal(#context.calls_named("setScatter"), 0, "the start sends no setScatter")
end)

test("scatter sends its depth, rate and masks", function()
  local context, S = loaded()
  context.clear_engine_calls()
  params:set("scatter", 1)
  assert_scatter(context, 0.1, 0.1, 3, 127, "on")
  toggle_lock(3)
  assert_scatter(context, 0.1, 0.1, 3, 123, "voice 3 locked")
  params:set("scatter_amp", 1)
  assert_scatter(context, 0.1, 0.1, 19, 123, "amp joins pitch and position")
  params:set("scatter", 0)
  assert_scatter(context, 0, 0.1, 19, 123, "off: depth 0")
  -- each param sends, off or on
  params:set("scatter_depth", 30)
  assert_scatter(context, 0, 0.1, 19, 123, "a depth set while off still sends 0")
  params:set("scatter", 1)
  assert_scatter(context, 0.3, 0.1, 19, 123, "on at 30 %")
  params:set("scatter_rate", 0.5)
  assert_scatter(context, 0.3, 0.5, 19, 123, "the rate")
  for bit, id in ipairs({ "scatter_pitch", "scatter_pos", "scatter_size", "scatter_cutoff", "scatter_amp" }) do
    local before = params:get(id)
    params:set(id, 1 - before)
    local _, args = last_scatter(context)
    local mask_bit = math.floor(args[3] / 2 ^ (bit - 1)) % 2
    assert_equal(mask_bit, 1 - before, id .. " is bit " .. (bit - 1) .. " of the destination mask")
    context.clear_engine_calls()
    params:set(id, before)
    context.clear_engine_calls()
  end
  -- unlocking sends the voice back; a scene recall's lock states send too
  toggle_lock(3)
  assert_scatter(context, 0.3, 0.5, 19, 127, "voice 3 unlocked")
  toggle_lock(1); toggle_lock(7)
  context.clear_engine_calls()
  capture_scene(1)
  toggle_lock(1); toggle_lock(7)
  context.clear_engine_calls()
  recall_scene(1, 0)
  local _, args = last_scatter(context)
  assert_equal(args[4], 127 - 1 - 64, "the recalled locks of voices 1 and 7 leave them out")
end)

test("affects is false for a locked voice and while off", function()
  local context, S, scatter = loaded()
  local NUM_VOICES = S.constants.NUM_VOICES
  for voice = 1, NUM_VOICES do assert_equal(scatter.affects(voice), false, "off: voice " .. voice) end
  params:set("scatter", 1)
  for voice = 1, NUM_VOICES do assert_equal(scatter.affects(voice), true, "on: voice " .. voice) end
  toggle_lock(2)
  assert_equal(scatter.affects(2), false, "a locked voice is left alone")
  assert_equal(scatter.affects(1), true, "the others are not")
  params:set("scatter_depth", 0)
  assert_equal(scatter.affects(1), false, "depth 0 moves nothing")
  params:set("scatter_depth", 10)
  params:set("scatter_pitch", 0); params:set("scatter_pos", 0)
  assert_equal(scatter.affects(1), false, "no destination enabled")
  params:set("scatter_cutoff", 1)
  assert_equal(scatter.affects(1), true, "one destination is enough")
  for _, voice in ipairs({ 0, NUM_VOICES + 1, 1.5, "1" }) do
    assert_equal(scatter.affects(voice), false, "no voice " .. tostring(voice))
  end
end)

test("scenes store the eight scatter params", function()
  local context, S = loaded()
  local fields = {}
  for _, field in ipairs(S.registry.scene_fields) do fields[field.id] = field end
  for _, id in ipairs(IDS) do
    assert_true(fields[id] ~= nil, id .. " is a scene field")
    assert_equal(fields[id].default, params:lookup_param(id).controlspec and params:lookup_param(id).controlspec.default
      or params:lookup_param(id).default, id .. "'s default is its param's")
  end
  assert_equal(fields.scatter_depth.discrete, false, "the depth crossfades")
  assert_equal(fields.scatter_rate.discrete, false, "the rate crossfades")
  for _, id in ipairs({ "scatter", "scatter_pitch", "scatter_pos", "scatter_size", "scatter_cutoff", "scatter_amp" }) do
    assert_equal(fields[id].discrete, true, id .. " switches at a fade's end")
  end
  local stored = { scatter = 1, scatter_depth = 40, scatter_rate = 0.4, scatter_pitch = 0, scatter_pos = 1,
    scatter_size = 1, scatter_cutoff = 0, scatter_amp = 1 }
  for id, value in pairs(stored) do params:set(id, value) end
  capture_scene(1)
  for id, value in pairs(stored) do assert_near(S.scenes[1].data[id], value, 1e-6, "scene 1 holds " .. id) end
  local other = { scatter = 0, scatter_depth = 0, scatter_rate = 0.02, scatter_pitch = 1, scatter_pos = 0,
    scatter_size = 0, scatter_cutoff = 1, scatter_amp = 0 }
  for id, value in pairs(other) do params:set(id, value) end
  capture_scene(2)
  recall_scene(1, 0)
  for id, value in pairs(stored) do assert_near(params:get(id), value, 1e-6, "recalled " .. id) end
  -- a fade crossfades the depth and the rate and switches the rest at its end
  recall_scene(2, 2)
  context.clock.run_for(1)
  local depth = params:get("scatter_depth")
  assert_true(depth > 0 and depth < 40, "the depth fades: " .. depth)
  local rate = params:get("scatter_rate")
  assert_true(rate > 0.02 and rate < 0.4, "the rate fades: " .. rate)
  assert_equal(params:get("scatter"), 1, "on until the end")
  assert_equal(params:get("scatter_cutoff"), 0, "the toggles switch at the end")
  context.clock.run_for(1.5)
  for id, value in pairs(other) do assert_near(params:get(id), value, 1e-6, "faded to " .. id) end
  -- a scene outside the params' ranges is refused
  S.scenes[3] = h.deep_copy(S.scenes[1])
  S.scenes[3].data.scatter_depth = 150
  assert_equal(validate_scene(S.scenes[3]), false, "a depth above 100 % is refused")
end)

test("a silent PSET read sends the loaded state once; a read with actions sends as each param changes", function()
  local context, S = loaded()
  params:set("scatter", 1); params:set("scatter_depth", 50); params:set("scatter_size", 1)
  local path = context.data_dir .. "strata-01.pset"
  params:write(path)
  params:set("scatter", 0); params:set("scatter_depth", 10); params:set("scatter_size", 0)
  context.clear_engine_calls()
  params:read(path, true)
  assert_scatter(context, 0.5, 0.1, 7, 127, "a silent read")
  params:set("scatter", 0); params:set("scatter_depth", 10); params:set("scatter_size", 0)
  context.clear_engine_calls()
  params:read(path)
  local calls = context.calls_named("setScatter")
  assert_equal(#calls, 3, "one send per changed param")
  local args = calls[#calls].args
  assert_near(args[1], 0.5, 1e-9); assert_equal(args[3], 7)
end)

test("an edit of the depth or the rate ends a randomize's undo", function()
  local context, S = loaded()
  for _, id in ipairs({ "scatter_depth", "scatter_rate" }) do
    S.lib.mutation.randomize({ page = 1, section = "scatter", draws = {
      { id = "scatter_depth", draw = function() return 20 end },
      { id = "scatter_rate", draw = function() return 0.2 end } } })
    assert_true(S.undo ~= nil, "the randomize holds its undo")
    params:set(id, id == "scatter_depth" and 5 or 0.05)
    assert_equal(S.undo, nil, "an edit of " .. id .. " ends it")
  end
end)
end

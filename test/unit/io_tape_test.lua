-- test/unit/io_tape_test.lua
-- The tape loop (lib/io/tape.lua, S.lib.io_tape, 3.6 design §12): two softcut
-- voices loop Strata's output as one stereo tape; every call, its order and
-- its value come from docs/design/3.6-facts/checks.md §8 (softcut's write
-- path, from its C++ source) and iii-osc-nb-softcut.md §4.
-- Run alone: lua test/run.lua io_tape

return function(h)
local test, assert_true, assert_near = h.test, h.assert_true, h.assert_near
-- softcut takes numbers: 4 and 4.0 are the same value
local function assert_equal(actual, expected, message)
  if type(actual) == "number" and type(expected) == "number" then
    assert_near(actual, expected, 1e-9, message)
  else
    h.assert_equal(actual, expected, message)
  end
end
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local TAPE_PARAMS = { "tapeloop", "tapeloop_rec", "tapeloop_length", "tapeloop_rate", "tapeloop_feedback",
  "tapeloop_wear", "tapeloop_level" }

local function started()
  local context = load_strata(); finish_startup(context)
  return context, local_value("S")
end

local function value(context, name, ...) return context.softcut.value(name, ...) end

local function clear_calls(context)
  for index = #context.softcut.calls, 1, -1 do context.softcut.calls[index] = nil end
end

local function index_of(context, name, voice)
  for index, call in ipairs(context.softcut.calls) do
    if call[1] == name and call[2] == voice then return index end
  end
end

test("with the tape off softcut and the mixer are never touched", function()
  -- checks.md §8: nothing is sent to softcut until the tape is on
  local context = started()
  assert_equal(#context.softcut.calls, 0, "after init")
  assert_equal(context.audio.levels.eng_cut, nil, "the mixer's engine level")
  for _, id in ipairs(TAPE_PARAMS) do
    if id ~= "tapeloop" then
      local param = params:lookup_param(id)
      if param.controlspec then params:set(id, param.controlspec.maxval) else params:set(id, 0) end
    end
  end
  assert_equal(#context.softcut.calls, 0, "after every tape param but tapeloop moved")
  assert_equal(context.audio.levels.eng_cut, nil, "the mixer's engine level still")
  assert_equal(context.audio.levels.adc_cut, nil)
  assert_equal(context.audio.levels.tape_cut, nil)
end)

test("the tape's params are one group of seven with their defaults", function()
  started()
  assert_equal(params:get("tapeloop"), 0)
  assert_equal(params:get("tapeloop_rec"), 1)
  assert_equal(params:get("tapeloop_length"), 4)
  assert_equal(params:get("tapeloop_rate"), 1)
  assert_equal(params:get("tapeloop_feedback"), 0.5)
  assert_near(params:get("tapeloop_wear"), 0.2, 1e-9)
  assert_near(params:get("tapeloop_level"), 0.7, 1e-9)
  local range = params:lookup_param("tapeloop_length").controlspec
  assert_equal(range.minval, 0.25); assert_equal(range.maxval, 60)
  range = params:lookup_param("tapeloop_rate").controlspec
  assert_equal(range.minval, -2); assert_equal(range.maxval, 2)
  assert_equal(params:lookup_param("strata_tape").n, 7, "the group's count is its params")
end)

test("turning the tape on sets two voices up as one stereo loop", function()
  -- checks.md §8: the values and their order, verbatim
  local context = started()
  params:set("tapeloop", 1)
  for v = 1, 2 do
    assert_equal(value(context, "enable", v), 1, "enable " .. v)
    assert_equal(value(context, "buffer", v), v, "buffer " .. v)
    assert_equal(value(context, "loop", v), 1)
    assert_equal(value(context, "loop_start", v), 0)
    assert_equal(value(context, "loop_end", v), 4)
    assert_equal(value(context, "fade_time", v), 0.02)
    assert_equal(value(context, "position", v), 0)
    assert_equal(value(context, "rate_slew_time", v), 0.2)
    assert_equal(value(context, "rate", v), 1)
    assert_near(value(context, "level", v), 0.7, 1e-9)
    assert_equal(value(context, "level_input_cut", v, v), 1)
    assert_equal(value(context, "rec", v), 1)
    assert_equal(value(context, "play", v), 1)
    assert_equal(value(context, "rec_level", v), 1)
    assert_equal(value(context, "pre_level", v), 0)
    assert_near(value(context, "level_cut_cut", v, v), 0.5 / 1.2, 1e-9)
    assert_near(value(context, "pre_filter_fc", v), 6982, 1)
    assert_equal(value(context, "pre_filter_fc_mod", v), 0)
    assert_equal(value(context, "pre_filter_rq", v), 1.414)
    assert_equal(value(context, "pre_filter_lp", v), 1)
    assert_equal(value(context, "pre_filter_dry", v), 0)
    assert_equal(value(context, "post_filter_dry", v), 1)
    assert_true(index_of(context, "pre_filter_fc_mod", v) < index_of(context, "pre_filter_fc", v),
      "the mod amount is sent before the cutoff (checks.md §8)")
    assert_true(index_of(context, "buffer", v) < index_of(context, "enable", v), "enable comes last")
  end
  assert_equal(value(context, "pan", 1), -1)
  assert_equal(value(context, "pan", 2), 1)
  assert_equal(context.audio.levels.eng_cut, 1, "the loop holds Strata's output")
  assert_equal(context.audio.levels.adc_cut, 0, "and not the inputs")
  assert_equal(context.audio.levels.tape_cut, 0)
  for _, call in ipairs(context.softcut.calls) do
    assert_true(call[2] == 1 or call[2] == 2, call[1] .. " names voice 1 or 2 only")
  end
end)

test("each param reaches both voices while the tape is on", function()
  local context = started()
  params:set("tapeloop", 1)
  params:set("tapeloop_length", 8)
  params:set("tapeloop_rate", -1)
  params:set("tapeloop_feedback", 0.8)
  params:set("tapeloop_level", 0.3)
  params:set("tapeloop_rec", 0)
  for v = 1, 2 do
    assert_equal(value(context, "loop_end", v), 8)
    assert_equal(value(context, "rate", v), -1)
    assert_near(value(context, "level_cut_cut", v, v), 0.8 / 1.2, 1e-9)
    assert_near(value(context, "level", v), 0.3, 1e-9)
    assert_equal(value(context, "rec_level", v), 0)
  end
  params:set("tapeloop_wear", 1)
  for v = 1, 2 do assert_near(value(context, "pre_filter_fc", v), 800, 1e-6) end
  params:set("tapeloop_wear", 0)
  for v = 1, 2 do assert_near(value(context, "pre_filter_fc", v), 12000, 1e-6) end
  params:set("tapeloop_rec", 1)
  for v = 1, 2 do assert_equal(value(context, "rec_level", v), 1) end
end)

test("turning the tape off, and cleanup, disable both voices and put the mixer back", function()
  local context = started()
  params:set("cut_input_eng", -6); params:set("cut_input_adc", 0); params:set("cut_input_tape", -3)
  params:set("tapeloop", 1)
  params:set("tapeloop", 0)
  for v = 1, 2 do assert_equal(value(context, "enable", v), 0, "off disables voice " .. v) end
  assert_near(context.audio.levels.eng_cut, util.dbamp(-6), 1e-9)
  assert_near(context.audio.levels.adc_cut, 1, 1e-9)
  assert_near(context.audio.levels.tape_cut, util.dbamp(-3), 1e-9)
  -- cleanup with the tape on
  params:set("tapeloop", 1)
  assert_equal(context.audio.levels.eng_cut, 1)
  cleanup()
  for v = 1, 2 do assert_equal(value(context, "enable", v), 0, "cleanup disables voice " .. v) end
  assert_near(context.audio.levels.eng_cut, util.dbamp(-6), 1e-9)
  assert_near(context.audio.levels.tape_cut, util.dbamp(-3), 1e-9)
end)

test("the tape's four are macro targets and nothing else of it is", function()
  local _, S = started()
  local targets = {}
  for _, id in ipairs(S.lib.macros.target_ids()) do targets[id] = true end
  for _, id in ipairs({ "tapeloop_level", "tapeloop_rate", "tapeloop_feedback", "tapeloop_wear" }) do
    assert_true(targets[id], id .. " is a macro target")
  end
  for _, id in ipairs({ "tapeloop", "tapeloop_rec", "tapeloop_length" }) do
    assert_true(not targets[id], id .. " is not")
  end
end)

test("a macro's modulation reaches the loop", function()
  -- the path an LFO or a matrix routing on a macro moves its targets through
  local context, S = started()
  params:set("tapeloop", 1)
  S.lib.engine_sync.set_extra_offset("macro", "tapeloop_level", -0.2)
  send_param_to_engine("tapeloop_level", 0.7)
  for v = 1, 2 do assert_near(value(context, "level", v), 0.5, 1e-9) end
  params:set("tapeloop", 0)
  clear_calls(context)
  send_param_to_engine("tapeloop_level", 0.7)
  assert_equal(#context.softcut.calls, 0, "with the tape off nothing is sent")
end)

test("no tape param is in a scene", function()
  local _, S = started()
  local function snapshot()
    capture_scene(1)
    local keys = {}
    for key, v in pairs(S.scenes[1]) do keys[#keys + 1] = key .. "=" .. (type(v) == "table" and "t" or tostring(v)) end
    table.sort(keys)
    local ids = {}
    for key in pairs(S.scenes[1].params or S.scenes[1]) do ids[#ids + 1] = key end
    return table.concat(keys, ","), ids
  end
  local before = snapshot()
  for _, id in ipairs({ "tapeloop_length", "tapeloop_rate", "tapeloop_feedback", "tapeloop_wear", "tapeloop_level" }) do
    params:set(id, params:lookup_param(id).controlspec.maxval)
  end
  local after, ids = snapshot()
  assert_equal(after, before, "a scene captured with the tape params moved equals one captured before")
  for _, key in ipairs(ids) do assert_true(not tostring(key):find("^tapeloop"), "no scene field " .. tostring(key)) end
end)

test("a 3.5 PSET loads with the tape off", function()
  local context = started()
  local path = context.data_dir .. "tape35.pset"
  params:write(path)
  local file = io.open(path, "r"); local text = file:read("a"); file:close()
  local kept = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if not line:find("tapeloop", 1, true) then kept[#kept + 1] = line end
  end
  file = io.open(path, "w"); file:write(table.concat(kept, "\n")); file:close()
  params:set("tapeloop_length", 9)
  params:read(path)
  assert_equal(params:get("tapeloop"), 0, "the tape is off")
  assert_equal(#context.softcut.calls, 0, "softcut is untouched")
  assert_equal(context.audio.levels.eng_cut, nil)
end)

end

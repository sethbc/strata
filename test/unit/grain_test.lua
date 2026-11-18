-- test/unit/grain_test.lua
-- The grain's controls (lib/grain.lua, 3.8 design §4.1, §4.2, §4.4, §4.5):
-- the six per-voice params and their specs, their engine names and
-- values, the master density in overlap mode, the window's LFO, matrix
-- and macro destinations, the fader place, the VOICE rows, what randomize
-- leaves, the scene keys, an old PSET's envelope and a triggered voice in
-- overlap mode.
-- Run alone: lua test/run.lua grain

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake

-- The six, verbatim from the task: key, spec (min, max, warp, step) or
-- options, default, engine name, and the value the engine gets for x
local SIX = {
  {key = "grain_shape", min = 0, max = 1, warp = "lin", step = 0.01, default = 0.57, engine = "windowShape",
    value = function(x) return x end},
  {key = "grain_skew", min = -1, max = 1, warp = "lin", step = 0.01, default = 0, engine = "windowSkew",
    value = function(x) return x end},
  {key = "grain_prob", min = 0, max = 100, warp = "lin", step = 1, default = 100, engine = "grainProb",
    value = function(x) return x / 100 end},
  {key = "grain_cloud", options = {"density", "overlap"}, default = 1, engine = "overlapOn",
    value = function(x) return x - 1 end},
  {key = "grain_overlap", min = 0.25, max = 16, warp = "exp", step = 0, default = 2, engine = "grainOverlap",
    value = function(x) return x * params:get("master_density") end},
  {key = "pan_wander", min = 0, max = 100, warp = "lin", step = 1, default = 50, engine = "panSpread",
    value = function(x) return x / 100 end},
}
local ENGINE_NAMES = {}
for _, entry in ipairs(SIX) do ENGINE_NAMES[entry.engine] = true end

-- The setGrainParam calls of the six's names since the calls were cleared,
-- as "voice name value" (values rounded to 1e-6)
local function sent(context)
  local lines = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if ENGINE_NAMES[call.args[2]] or call.args[2] == "grainDensity" then
      lines[#lines + 1] = string.format("%d %s %.6g", call.args[1], call.args[2], call.args[3])
    end
  end
  return lines
end

local function row_keys(voice_idx, section)
  local keys = {}
  for _, row in ipairs(voice_page_rows(voice_idx)) do
    if row.param_id and row.section == section then keys[#keys + 1] = row.param_id:match("^v%d+_(.*)$") end
  end
  return table.concat(keys, " ")
end

test("the six params: specs and defaults as the task gives them; their formats at both ends", function()
  load_strata()
  local S = local_value("S")
  assert_true(S.lib.grain ~= nil and type(S.lib.grain.GRAIN) == "table", "S.lib.grain and its GRAIN")
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, entry in ipairs(SIX) do
      local id = "v" .. voice_idx .. "_" .. entry.key
      local param = params:lookup_param(id)
      assert_true(param ~= nil, id .. " exists")
      if entry.options then
        assert_equal(param.t, params.tOPTION, id .. " is an option")
        assert_equal(table.concat(param.options, ","), table.concat(entry.options, ","), id .. "'s options")
      else
        assert_equal(param.t, params.tCONTROL, id .. " is a control")
        local spec = param.controlspec
        assert_equal(spec.minval, entry.min, id .. " min"); assert_equal(spec.maxval, entry.max, id .. " max")
        assert_equal(spec.warp_name or spec.warp, entry.warp, id .. " warp")
        assert_equal(spec.step, entry.step, id .. " step")
      end
      assert_near(param_default(id), entry.default, 1e-9, id .. " default")
      assert_near(params:get(id), entry.default, 1e-9, id .. " starts at its default")
      assert_near(S.voices[voice_idx].values[entry.key], entry.default, 1e-9, id .. " is stored")
    end
  end
  -- each one's text at both ends of its range
  local ends = {
    grain_shape = {"0.00", "1.00"}, grain_skew = {"-1.00", "1.00"}, grain_prob = {"0 %", "100 %"},
    grain_cloud = {"density", "overlap"}, grain_overlap = {"0.25 x", "16.00 x"}, pan_wander = {"0 %", "100 %"},
  }
  for _, entry in ipairs(SIX) do
    local id = "v1_" .. entry.key
    local low, high = entry.min or 1, entry.max or #entry.options
    params:set(id, low); assert_equal(params:string(id), ends[entry.key][1], id .. " at its low end")
    params:set(id, high); assert_equal(params:string(id), ends[entry.key][2], id .. " at its high end")
  end
end)

test("a running voice sends each under its engine name and value; a stopped voice only stores; a start sends them before voiceOn",
    function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active and not S.voices[3].active, "voice 1 runs, voice 3 does not")
  local values = {grain_shape = 0.2, grain_skew = -0.5, grain_prob = 40, grain_cloud = 2, grain_overlap = 4, pan_wander = 25}
  for _, entry in ipairs(SIX) do
    context.clear_engine_calls()
    params:set("v1_" .. entry.key, values[entry.key])
    local lines = sent(context)
    assert_equal(lines[1], string.format("0 %s %.6g", entry.engine, entry.value(values[entry.key])),
      entry.key .. " reaches the engine as " .. entry.engine)
    context.clear_engine_calls()
    params:set("v3_" .. entry.key, values[entry.key])
    assert_equal(#sent(context), 0, "a stopped voice's " .. entry.key .. " sends nothing")
    assert_near(S.voices[3].values[entry.key], values[entry.key], 1e-9, "but stores it")
  end
  -- a start sends the six in send_order, before voiceOn
  context.clear_engine_calls()
  toggle_voice(3)
  local order, voice_on = {}, nil
  for index, call in ipairs(context.engine_calls) do
    if call.name == "voiceOn" and call.args[1] == 2 then voice_on = voice_on or index end
    if call.name == "setGrainParam" and call.args[1] == 2 and ENGINE_NAMES[call.args[2]] then
      order[#order + 1] = call.args[2]
      assert_true(voice_on == nil, call.args[2] .. " goes before voiceOn")
    end
  end
  assert_equal(table.concat(order, ","), "windowShape,windowSkew,grainProb,overlapOn,grainOverlap,panSpread",
    "the start's six, in send_order")
end)

test("master density 2 in overlap mode sends grainOverlap 4 for overlap 2 and no grainDensity; in density mode grainDensity as today",
    function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active and S.voices[2].active, "voices 1 and 2 run")
  params:set("v1_grain_cloud", 2)
  assert_true(S.lib.grain.overlap(1) and not S.lib.grain.overlap(2), "voice 1 in overlap mode, voice 2 in density mode")
  context.clear_engine_calls()
  params:set("master_density", 2)
  local lines = sent(context)
  assert_equal(table.concat(lines, ";"), "0 grainOverlap 4;1 grainDensity " .. string.format("%.6g", params:get("v2_grain_density") * 2),
    "voice 1 its overlap, voice 2 its density, each times 2")
  -- an overlap edit carries the master density, as a density edit does
  context.clear_engine_calls()
  params:set("v1_grain_overlap", 3)
  assert_equal(table.concat(sent(context), ";"), "0 grainOverlap 6", "overlap 3 at master 2")
  -- back to density mode: the density goes out with the master density
  context.clear_engine_calls()
  params:set("v1_grain_cloud", 1)
  assert_equal(table.concat(sent(context), ";"), "0 overlapOn 0;0 grainDensity " .. string.format("%.6g", params:get("v1_grain_density") * 2),
    "the cloud's switch, then the density the engine now plays")
  context.clear_engine_calls()
  params:set("v1_grain_cloud", 2)
  assert_equal(table.concat(sent(context), ";"), "0 overlapOn 1;0 grainOverlap 6", "and to overlap mode its overlap")
end)

test("shape and skew: LFO, matrix and macro destinations v1 shape and v1 skew; an LFO never sets the param", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local found = {}
  for index, destination in ipairs(S.LFO_DESTINATIONS) do found[destination.label] = index end
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, pair in ipairs({{"shape", "grain_shape"}, {"skew", "grain_skew"}}) do
      local label = "v" .. voice_idx .. " " .. pair[1]
      assert_true(found[label] ~= nil, label .. " is an LFO destination")
      assert_equal(S.LFO_DESTINATIONS[found[label]].resolve(), "v" .. voice_idx .. "_" .. pair[2], label .. "'s param")
    end
  end
  local targets = {}
  for _, id in ipairs(S.lib.macros.target_ids()) do targets[id] = true end
  assert_true(targets.v1_grain_shape and targets.v1_grain_skew, "both are macro targets")
  -- an LFO on v1 shape sends windowShape and never sets the param
  S.lib.matrix.set_home(1, S.lib.lfos.destination_id(found["v1 shape"]))
  params:set("strata_lfo1_shape", 3); params:set("strata_lfo1_rate", 10)
  params:set("strata_lfo1_depth", 100); params:set("strata_lfo1", 1)
  context.clear_engine_calls()
  context.clock.run_for(0.3)
  local shapes = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "windowShape" then shapes[call.args[3]] = true end
  end
  local count = 0
  for _ in pairs(shapes) do count = count + 1 end
  assert_true(count >= 2, "the LFO moves windowShape (" .. count .. " values)")
  assert_near(params:get("v1_grain_shape"), 0.57, 1e-9, "and never sets v1_grain_shape")
end)

test("the fader list holds grain_shape and grain_skew where grain_env was, after grain_spread; fm has 33 faders", function()
  load_strata()
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    local ids = table.concat(fader_param_ids(voice_idx), ",")
    local prefix = "v" .. voice_idx .. "_"
    assert_true(ids:find(prefix .. "grain_spread," .. prefix .. "grain_shape," .. prefix .. "grain_skew," .. prefix
      .. "grain_mode", 1, true) ~= nil, "voice " .. voice_idx .. ": shape and skew after spread, before mode: " .. ids)
    for _, key in ipairs({"grain_env", "grain_prob", "grain_cloud", "grain_overlap", "pan_wander"}) do
      assert_true(not ids:find(prefix .. key, 1, true), "voice " .. voice_idx .. " has no " .. key .. " fader")
    end
  end
  -- fm (voice 2): 3.7's 31, plus 1a's dry, less grain_env, plus shape and skew
  assert_equal(S.lib.types.of(2).key, "fm", "voice 2 is fm")
  assert_equal(#fader_param_ids(2), 33, "fm has 33 faders")
end)

test("overlap mode: VOICE's density row is grain_overlap; MAIN's third field stays grain_density", function()
  load_strata()
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    local prefix = "v" .. voice_idx .. "_"
    local density = row_keys(voice_idx, "grain")
    assert_true(density:find("^grain_size grain_density grain_pitch grain_spread grain_mode grain_shape grain_skew grain_prob grain_cloud pan_wander") ~= nil,
      "voice " .. voice_idx .. " in density mode: " .. density)
    assert_true(not density:find("grain_overlap", 1, true), "no overlap row in density mode")
    params:set(prefix .. "grain_cloud", 2)
    local overlap = row_keys(voice_idx, "grain")
    assert_true(overlap:find("^grain_size grain_overlap grain_pitch grain_spread grain_mode grain_shape grain_skew grain_prob grain_cloud pan_wander") ~= nil,
      "voice " .. voice_idx .. " in overlap mode: " .. overlap)
    assert_true(not overlap:find("grain_density", 1, true), "no density row in overlap mode")
    assert_equal(main_fields(voice_idx)[3], prefix .. "grain_density", "MAIN's third field stays the density")
  end
end)

test("no randomize, mutation or drift moves the six", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local values = {grain_shape = 0.3, grain_skew = 0.4, grain_prob = 70, grain_cloud = 2, grain_overlap = 3, pan_wander = 20}
  for voice_idx = 1, S.constants.NUM_VOICES do
    for key, value in pairs(values) do params:set("v" .. voice_idx .. "_" .. key, value) end
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(11)
  for voice_idx = 1, S.constants.NUM_VOICES do randomize_voice(voice_idx) end
  for _ = 1, 20 do gentle_mutate() end
  for _ = 1, 20 do drift_update() end
  for voice_idx = 1, S.constants.NUM_VOICES do
    for key, value in pairs(values) do
      assert_near(params:get("v" .. voice_idx .. "_" .. key), value, 1e-9, "v" .. voice_idx .. "_" .. key .. " untouched")
    end
  end
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "grain_controls" then record = each end end
  assert_true(record ~= nil, "the record is registered as grain_controls")
  assert_true(record.main_randomize == nil and record.mutate == nil and record.randomize == nil, "it draws nothing")
end)

test("a scene captures and recalls the six; grain_cloud switches at a fade's end; grain_shape fades", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local values = {grain_shape = 1, grain_skew = -1, grain_prob = 30, grain_cloud = 2, grain_overlap = 8, pan_wander = 90}
  for key, value in pairs(values) do params:set("v2_" .. key, value) end
  capture_scene(1)
  for key, value in pairs(values) do
    assert_near(S.scenes[1].data.voices[2].values[key], value, 1e-9, key .. " captured")
  end
  local _, by_key = S.lib.params_setup.voice_scene_keys(2)
  assert_equal(table.concat(by_key.grain_cloud.range, ","), "1,2", "grain_cloud is discrete, 1 to 2")
  assert_true(by_key.grain_env == nil, "grain_env is no scene key")
  -- the cloud is no fade target (an option param floors a faded 1.5 to 1,
  -- so the fade's values alone cannot show it); the shape is
  local faded = {}
  for _, target in ipairs(scene_transition_targets(S.scenes[1].data)) do faded[target.id] = true end
  assert_true(not faded.v2_grain_cloud, "grain_cloud is not crossfaded")
  assert_true(faded.v2_grain_shape, "grain_shape is")
  for _, entry in ipairs(SIX) do params:set("v2_" .. entry.key, entry.default) end
  recall_scene(1, 4); wake(context, "scene_transition_clock")
  context.clock.run_for(2)
  local shape = params:get("v2_grain_shape")
  assert_true(shape > 0.57 and shape < 1, "grain_shape fades (midway " .. shape .. ")")
  assert_equal(params:get("v2_grain_cloud"), 1, "grain_cloud holds until the fade's end")
  context.clock.run_for(3)
  for key, value in pairs(values) do assert_near(params:get("v2_" .. key), value, 1e-9, key .. " recalled") end
end)

test("a 3.7 PSET's v<i>_grain_env lines load without error", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local path = h.data_root .. "grain-env-" .. math.random(1, 1e9) .. ".pset"
  local lines = {}
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(params.lookup["v" .. voice_idx .. "_grain_env"], nil, "v" .. voice_idx .. "_grain_env names no param")
    lines[#lines + 1] = '"v' .. voice_idx .. '_grain_env": 3'
    lines[#lines + 1] = '"v' .. voice_idx .. '_grain_size": 0.2'
  end
  h.write_text(path, table.concat(lines, "\n") .. "\n")
  local from = #context.printed + 1
  params:read(path)
  for index = from, #context.printed do
    assert_true(not tostring(context.printed[index]):lower():find("error", 1, true), "no error line: " .. tostring(context.printed[index]))
  end
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_near(params:get("v" .. voice_idx .. "_grain_size"), 0.2, 1e-9, "the lines around them load")
    assert_near(params:get("v" .. voice_idx .. "_grain_shape"), 0.57, 1e-9, "the shape stays at its default")
    assert_near(params:get("v" .. voice_idx .. "_grain_skew"), 0, 1e-9, "the skew stays at its default")
  end
  os.remove(path)
end)

test("a triggered-mode voice in overlap mode: four pattern steps give four retriggers; it sends grainMode 1 and overlapOn 1; nothing runs free",
    function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  context.clear_engine_calls()
  params:set("v1_grain_mode", 2)
  params:set("v1_grain_cloud", 2)
  local mode, cloud
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "grainMode" then mode = call.args[3] end
    if call.args[1] == 0 and call.args[2] == "overlapOn" then cloud = call.args[3] end
  end
  assert_equal(mode, 1, "it sends grainMode 1")
  assert_equal(cloud, 1, "and overlapOn 1")
  local patterns = local_value("patterns")
  for step = 1, S.constants.PATTERN_LENGTH do patterns[1][step] = 0 end
  for _, step in ipairs({1, 5, 9, 13}) do patterns[1][step] = 15 end
  context.clear_engine_calls()
  pattern_toggle()
  for _ = 1, 15 do wake(context, "pattern_clock") end
  pattern_toggle()
  local retriggers = 0
  for _, call in ipairs(context.calls_named("retrigger")) do
    if call.args[1] == 0 then retriggers = retriggers + 1 end
  end
  assert_equal(retriggers, 4, "four steps, four retriggers: one grain each")
  -- nothing runs free: no start, and the engine keeps triggered mode
  -- (grainMode 1 holds the overlap cloud's Impulse out of the trigger)
  assert_equal(#context.calls_named("voiceOn"), 0, "no start")
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    assert_true(not (call.args[1] == 0 and call.args[2] == "grainMode" and call.args[3] ~= 1), "triggered mode holds")
  end
end)

end

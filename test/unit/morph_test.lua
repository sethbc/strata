-- test/unit/morph_test.lua
-- Scene morph (lib/morph.lua, S.lib.morph, 3.4 design §5): the morph,
-- morph_a and morph_b params, the plan between two scenes, the clock that
-- applies the latest position, and the rules that keep it apart from a
-- recall (it writes params and never recalls)
-- Run alone: lua test/run.lua morph

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake
local scramble_state = h.scramble_state

-- Scene 1: reverb_mix 0.2, voice 3 stopped on its synth; scene 2:
-- reverb_mix 0.6, voice 3 running on buffer 1. The state is scene 1's, and
-- morph runs from scene 1 (A) to scene 2 (B), the defaults
local function two_scenes(options)
  local context = load_strata(options); finish_startup(context)
  local S = local_value("S")
  local synth = S.constants.SOURCE_SYNTH
  params:set("reverb_mix", 0.6); params:set("v3_source", synth + 1)
  if not S.voices[3].active then toggle_voice(3) end
  capture_scene(2)
  params:set("reverb_mix", 0.2); toggle_voice(3); params:set("v3_source", synth)
  capture_scene(1)
  return context, S
end

-- Set the morph and run the clocks until its clock has applied the position
-- and rested (an apply, then the rest tick 0.1 s later; a few more while
-- values wait in the round robin)
local function settle(context, position)
  params:set("morph", position)
  context.clock.run_for(0.5)
end

-- Every param a scene's continuous entries name, with its value now
local function continuous_values(S, slot)
  local values = {}
  for _, entry in ipairs(S.lib.scenes.scene_entries(S.scenes[slot].data)) do
    if entry.kind == "continuous" then values[entry.id] = params:get(entry.id) end
  end
  return values
end

-- The same ids with the values the scene's own data holds. Counting what
-- differs from these never depends on the order a recall set a voice's
-- params in: two reads of one value can differ in the last bit (#586)
local function scene_data_values(S, slot)
  local values = {}
  for _, entry in ipairs(S.lib.scenes.scene_entries(S.scenes[slot].data)) do
    if entry.kind == "continuous" then values[entry.id] = entry.value end
  end
  return values
end

-- The index in the engine calls of the first call named `name` whose first
-- argument is `first` (and second `second`, when given) from index `from`
local function call_index(context, name, first, second, from)
  for index = from or 1, #context.engine_calls do
    local call = context.engine_calls[index]
    if call.name == name and call.args[1] == first and (second == nil or call.args[2] == second) then
      return index
    end
  end
  return nil
end

local function count_calls(context, name, first)
  local count = 0
  for _, call in ipairs(context.engine_calls) do
    if call.name == name and call.args[1] == first then count = count + 1 end
  end
  return count
end

-- Two scenes that differ in most continuous values (every voice's synth,
-- grain, crossmod, filter and send values and the effects), state at scene
-- 1's. before_capture(S, slot), when given, runs just before each capture
local function scrambled_scenes(before_capture)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function voice_mix(freq, res, delay_send, reverb_send)
    for voice_idx = 1, S.constants.NUM_VOICES do
      local prefix = "v" .. voice_idx .. "_"
      params:set(prefix .. "filter_freq", freq + voice_idx * 100); params:set(prefix .. "filter_res", res)
      params:set(prefix .. "delay_send", delay_send); params:set(prefix .. "reverb_send", reverb_send)
    end
  end
  scramble_state(21)
  voice_mix(2000, 0.9, 0.2, 0.3)
  params:set("reverb_mix", 0.9); params:set("delay_mix", 0.7); params:set("filter_freq", 9000)
  if before_capture then before_capture(S, 2) end
  capture_scene(2)
  scramble_state(22)
  voice_mix(400, 0.1, 0.8, 0.7)
  params:set("reverb_mix", 0.1); params:set("delay_mix", 0.2); params:set("filter_freq", 300)
  if before_capture then before_capture(S, 1) end
  capture_scene(1)
  return context, S
end

-- The first continuous scene global whose param holds only whole numbers
-- and has room for low..high: a number param (3.3's LFO depths, which a
-- fade and a morph round) or a control stepped by 1 (3.4's, which round
-- themselves as they are set)
local function whole_number_global(S, low, high)
  for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do
    if global.continuous then
      local param = params:lookup_param(global.id)
      local spec = param.controlspec
      local whole = param.t == params.tNUMBER or (spec ~= nil and spec.step == 1)
      local min, max = param_range(global.id)
      if whole and min <= low and max >= high then return global.id end
    end
  end
  return nil
end

-- Scenes 1-4: reverb_mix 0.2, 0.6, 0.4 and 1.0; voice 3 stopped on its
-- synth in scene 1, running on buffer 1, 2 and 3 in scenes 2-4. The state
-- is scene 1's; the corners are the defaults (A 1, B 2, C 3, D 4)
local function four_scenes(options)
  local context = load_strata(options); finish_startup(context)
  local S = local_value("S")
  local synth = S.constants.SOURCE_SYNTH
  toggle_voice(3)
  for buffer, mix in ipairs({ 0.6, 0.4, 1.0 }) do
    params:set("reverb_mix", mix); params:set("v3_source", synth + buffer)
    capture_scene(buffer + 1)
  end
  params:set("reverb_mix", 0.2); toggle_voice(3); params:set("v3_source", synth)
  capture_scene(1)
  return context, S
end

-- Set both axes and run the clocks until the morph has applied and rested
local function settle_xy(context, x, y)
  params:set("morph", x); params:set("morph_y", y)
  context.clock.run_for(0.5)
end

test("the morph params are a group of six, defaulting to A-D = 1-4 at 0, 0, and no scene field", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local group = params:lookup_param("strata_morph")
  assert_equal(group.t, params.tGROUP, "strata_morph is a group")
  assert_equal(group.n, 6, "of six params")
  local index = params.lookup["strata_morph"]
  local ids = { "morph", "morph_a", "morph_b", "morph_c", "morph_d", "morph_y" }
  for offset, id in ipairs(ids) do
    assert_equal(params.params[index + offset].id, id, id .. " is param " .. offset .. " of the group")
  end
  assert_equal(params:get("morph"), 0, "the morph starts at 0")
  assert_equal(params:get("morph_y"), 0, "and so does its second axis")
  for corner, slot in pairs({ a = 1, b = 2, c = 3, d = 4 }) do
    local param = params:lookup_param("morph_" .. corner)
    assert_equal(param.t, params.tNUMBER, corner .. " is a number param")
    assert_equal(params:get("morph_" .. corner), slot, corner .. " is scene " .. slot)
    assert_equal(param.min, 1, corner .. " takes a scene from 1")
    assert_equal(param.max, S.constants.NUM_SCENES, corner .. " to NUM_SCENES")
  end
  assert_equal(params:lookup_param("morph_y").t, params.tCONTROL, "morph_y is a control")
  assert_equal(params:string("morph"), "0 %", "the position shows in percent")
  params:set("morph", 0.35)
  assert_equal(params:string("morph"), "35 %", "in whole percents")
  params:set("morph_y", 0.6)
  assert_equal(params:string("morph_y"), "60 %", "the second axis too")
  capture_scene(1)
  local targets, destinations = {}, {}
  for _, id in ipairs(S.lib.macros.target_ids()) do targets[id] = true end
  for _, id in ipairs(S.lib.matrix.destination_ids()) do destinations[id] = true end
  for _, id in ipairs(ids) do
    assert_equal(S.scenes[1].data[id], nil, id .. " is no scene field")
    assert_true(not targets[id], id .. " is no macro target")
    assert_true(not destinations[id], id .. " is no matrix destination")
    for _, destination in ipairs(S.LFO_DESTINATIONS) do
      assert_true(destination.resolve() ~= id, id .. " is no LFO destination (" .. destination.label .. ")")
    end
  end
  context.clock.run_for(0.5)
end)

test("at y 0 the XY morph is the two-scene morph, value for value", function()
  -- four scenes that differ in most continuous values; voice 3 stopped in
  -- A and B, running in C and D
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  scramble_state(23); params:set("reverb_mix", 0.4); toggle_voice(3); capture_scene(3)
  scramble_state(24); params:set("reverb_mix", 1.0); capture_scene(4)
  toggle_voice(3)
  scramble_state(21); params:set("reverb_mix", 0.9); capture_scene(2)
  scramble_state(22); params:set("reverb_mix", 0.1); capture_scene(1)
  assert_true(S.scenes[4].data.voices[3].active and not S.scenes[2].data.voices[3].active, "C and D differ from A and B")
  settle_xy(context, 0.5, 0)
  assert_near(params:get("reverb_mix"), 0.5, 1e-9, "reverb mix halfway from A's 0.1 to B's 0.9")
  local morphed = continuous_values(S, 2)
  assert_true(not S.voices[3].active, "voice 3 stays stopped, as in A and B, never as in C or D")
  assert_equal(S.voices[3].source, S.scenes[2].data.voices[3].source, "on B's source")
  -- the same fraction of a 20-step transition from scene 1 to scene 2
  recall_scene(1, 0)
  recall_scene(2, 2)                                              -- step 1 runs at once
  for _ = 2, 10 do wake(context, "scene_transition_clock") end    -- step 10: f = 0.5
  local faded = 0
  for _, target in ipairs(scene_transition_targets(S.scenes[2].data)) do
    faded = faded + 1
    assert_near(morphed[target.id], params:get(target.id), 1e-9, target.id .. " as the transition's step 10")
  end
  assert_true(faded > 120, "every continuous value compared (" .. faded .. ")")
  cancel_scene_transition()
end)

test("a continuous value is the weighted sum of the four corners", function()
  local context, S = four_scenes()
  settle_xy(context, 0.5, 0.5)
  local a, b, c, d = S.lib.morph.weights()
  for name, weight in pairs({ a = a, b = b, c = c, d = d }) do assert_near(weight, 0.25, 1e-12, name .. "'s weight") end
  assert_near(params:get("reverb_mix"), 0.55, 1e-9, "(0.2 + 0.6 + 0.4 + 1.0) / 4")
  settle_xy(context, 1, 1)
  assert_near(params:get("reverb_mix"), 1.0, 1e-9, "(1, 1) is D's")
  settle_xy(context, 0, 1)
  assert_near(params:get("reverb_mix"), 0.4, 1e-9, "(0, 1) is C's")
  settle_xy(context, 0.25, 0.75)
  -- A 0.1875, B 0.0625, C 0.5625, D 0.1875: 0.0375 + 0.0375 + 0.225 + 0.1875
  assert_near(params:get("reverb_mix"), 0.49, 1e-9, "0.4875, stored to 0.01")
  settle_xy(context, 1, 0)
  assert_near(params:get("reverb_mix"), 0.6, 1e-9, "(1, 0) is B's")
end)

test("discrete entries follow the current corner, which changes past a lead of 0.04", function()
  local context, S = four_scenes()
  local synth = S.constants.SOURCE_SYNTH
  local morph = S.lib.morph
  settle(context, 0.1)
  assert_equal(morph.corner(), "a", "0.1: corner a")
  assert_true(not S.voices[3].active, "voice 3 stopped, as in A")
  settle(context, 0.5)
  assert_equal(morph.corner(), "a", "from a at (0.5, 0): a and b tie, a stays")
  settle(context, 0.51)
  assert_equal(morph.corner(), "a", "0.51: b leads by 0.02, a stays")
  assert_equal(S.voices[3].source, synth, "on A's source")
  settle(context, 0.53)
  assert_equal(morph.corner(), "b", "0.53: b leads by 0.06")
  assert_true(S.voices[3].active, "voice 3 runs, as in B")
  assert_equal(S.voices[3].source, synth + 1, "on B's buffer 1")
  params:set("morph_y", 0.6); context.clock.run_for(0.5)
  local a, b, c, d = morph.weights()
  assert_near(a, 0.188, 1e-12, "A at (0.53, 0.6)"); assert_near(b, 0.212, 1e-12, "B")
  assert_near(c, 0.282, 1e-12, "C"); assert_near(d, 0.318, 1e-12, "D")
  assert_equal(morph.corner(), "d", "D leads b by 0.106: d")
  assert_equal(S.voices[3].source, synth + 3, "on D's buffer 3")
  -- from d to (0.5, 0) in one move: a and b tie at 0.5, the tie goes to a
  params:set("morph", 0.5); params:set("morph_y", 0); context.clock.run_for(0.5)
  assert_equal(morph.corner(), "a", "a tie goes to a")
  assert_true(not S.voices[3].active, "voice 3 stops, as in A")
  assert_equal(S.voices[3].source, synth, "back on A's synth")
  -- the first apply after a recall (or a plan change) takes the largest
  -- weight, a tie the later corner (at y 0: B from 0.5, as the two-scene
  -- morph)
  recall_scene(1, 0)
  settle_xy(context, 0.5, 0.5)
  assert_equal(morph.corner(), "d", "all four tie at (0.5, 0.5): the first apply takes d")
  assert_equal(S.voices[3].source, synth + 3, "on D's buffer 3")
end)

test("an empty corner's weight is shared among the others; fewer than two valid corners do nothing", function()
  local context, S = four_scenes()
  params:set("morph_d", 9)                                      -- an empty slot
  settle_xy(context, 0.5, 0.5)
  local a, b, c, d = S.lib.morph.weights()
  for name, weight in pairs({ a = a, b = b, c = c }) do assert_near(weight, 1 / 3, 1e-12, name .. " takes a third") end
  assert_equal(d, 0, "the empty corner none")
  assert_near(params:get("reverb_mix"), 0.4, 1e-9, "(0.2 + 0.6 + 0.4) / 3")
  settle_xy(context, 1, 0.5)
  a, b, c, d = S.lib.morph.weights()
  for name, pair in pairs({ a = { a, 0 }, b = { b, 1 }, c = { c, 0 }, d = { d, 0 } }) do
    assert_near(pair[1], pair[2], 1e-12, name .. " at (1, 0.5): B takes D's half")
  end
  assert_near(params:get("reverb_mix"), 0.6, 1e-9, "B's value")
  -- one valid corner: nothing happens, and the first empty one flashes
  local flashes = {}
  local real_flash = header_flash
  header_flash = function(text) table.insert(flashes, text); return real_flash(text) end
  recall_scene(1, 0)
  params:set("reverb_mix", 0.5)
  params:set("morph_b", 10); params:set("morph_c", 11)
  assert_true(not S.lib.morph.plan_ready(), "only A holds a scene")
  settle_xy(context, 0.3, 0.7)
  header_flash = real_flash
  assert_equal(table.concat(flashes, ", "), "S10 empty", "the first empty corner flashes, once")
  assert_near(params:get("reverb_mix"), 0.5, 1e-9, "nothing is set")
  assert_equal(S.current_scene, 1, "the current scene stays")
end)

-- The far edges (the XY morph's review): where every valid corner weighs 0 the
-- weights are the limit from inside the square, so along a far edge they
-- follow the position (equal shares only at a diagonal corner point)
test("on a far edge whose corners are empty the weights still follow the position", function()
  local context, S = two_scenes()                                -- A and B saved, C and D empty
  settle_xy(context, 0.25, 1)
  local a, b, c, d = S.lib.morph.weights()
  for name, pair in pairs({ a = { a, 0.75 }, b = { b, 0.25 }, c = { c, 0 }, d = { d, 0 } }) do
    assert_near(pair[1], pair[2], 1e-12, name .. " at (0.25, 1)")
  end
  assert_near(params:get("reverb_mix"), 0.3, 1e-9, "0.2 + 0.25 x 0.4, as at y 0")
  settle_xy(context, 1, 1)
  assert_near(params:get("reverb_mix"), 0.6, 1e-9, "(1, 1): B's")
  -- only C and D saved, at the default y 0
  context = load_strata(); finish_startup(context)
  S = local_value("S")
  params:set("reverb_mix", 1.0); capture_scene(4)
  params:set("reverb_mix", 0.4); capture_scene(3)
  settle(context, 0.25)
  a, b, c, d = S.lib.morph.weights()
  for name, pair in pairs({ a = { a, 0 }, b = { b, 0 }, c = { c, 0.75 }, d = { d, 0.25 } }) do
    assert_near(pair[1], pair[2], 1e-12, name .. " at (0.25, 0) with only C and D")
  end
  assert_near(params:get("reverb_mix"), 0.55, 1e-9, "0.4 + 0.25 x 0.6")
end)

-- Scenes 1-4: reverb_mix 0.2, 0.6, 0.4 and 1.0; filter_freq and voice 6
-- agree in A and B (1000 Hz, stopped) and differ in C and D (5000 Hz,
-- running); delay_mix and voice 7 agree in A and C (0.1, stopped) and
-- differ in B and D (0.7, running). The state is scene 1's
local function edge_scenes()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function scene(slot, mix, top, right)
    params:set("reverb_mix", mix)
    params:set("filter_freq", top and 5000 or 1000)
    params:set("delay_mix", right and 0.7 or 0.1)
    if S.voices[6].active ~= top then toggle_voice(6) end
    if S.voices[7].active ~= right then toggle_voice(7) end
    capture_scene(slot)
  end
  scene(4, 1.0, true, true); scene(3, 0.4, true, false); scene(2, 0.6, false, true); scene(1, 0.2, false, false)
  return context, S
end

-- ruling 87: a corner counts only while its weight is above 0, so on an
-- edge the morph is the two-scene morph of that edge, entry for entry
test("at y 0 a hand change A and B agree on survives, whatever C and D hold (ruling 87)", function()
  local context, S = edge_scenes()
  recall_scene(1, 0)
  params:set("filter_freq", 3000); toggle_voice(6)               -- by hand
  for _, x in ipairs({ 0.3, 1, 0 }) do
    settle(context, x)
    assert_near(params:get("filter_freq"), 3000, 1e-6, x .. ": the hand-set filter freq stays")
    assert_true(S.voices[6].active, x .. ": the hand-started voice 6 runs")
  end
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "the morph still moves what A and B differ in")
  -- C and D join once y is above 0: their entries apply
  settle_xy(context, 0.3, 0.1)
  assert_near(params:get("filter_freq"), 1400, 1e-6, "1000 + (0.07 + 0.03) x 4000")
  assert_true(not S.voices[6].active, "voice 6 takes the current corner A's state")
  -- what the morph set follows its blend back to the edge
  settle_xy(context, 0.3, 0)
  assert_near(params:get("filter_freq"), 1000, 1e-6, "back at y 0: A's and B's 1000 Hz, never stranded at 1400")
end)

-- A corner point is the end of its row's two-scene morph: the first apply
-- there (after a recall) sets what A and B differ in, as the morph between
-- A and B does at 0
test("a first apply at a corner point is the end of its row's two-scene morph", function()
  local context, S = edge_scenes()
  settle(context, 0.4)
  recall_scene(2, 0)
  assert_true(S.voices[7].active, "scene 2 runs voice 7")
  settle(context, 0)
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "(0, 0): A's reverb mix")
  assert_true(not S.voices[7].active, "and A's voice 7, stopped")
  assert_near(params:get("filter_freq"), 1000, 1e-6, "what A and B agree on is left as recalled")
end)

test("on the A to C edge a hand change A and C agree on survives (ruling 87)", function()
  local context, S = edge_scenes()
  recall_scene(1, 0)
  params:set("delay_mix", 0.4); toggle_voice(7)                  -- by hand
  for _, y in ipairs({ 0.3, 0.8 }) do
    settle_xy(context, 0, y)
    assert_near(params:get("delay_mix"), 0.4, 1e-9, y .. ": the hand-set delay mix stays")
    assert_true(S.voices[7].active, y .. ": the hand-started voice 7 runs")
  end
  assert_near(params:get("reverb_mix"), 0.36, 1e-9, "0.2 + 0.8 x 0.2: the morph moves what A and C differ in")
  assert_true(S.voices[6].active, "and switches voice 6 to C's at the corner change")
  -- B and D join once x is above 0
  settle_xy(context, 0.25, 0.8)
  assert_near(params:get("delay_mix"), 0.25, 1e-9, "0.1 + 0.25 x 0.6")
  assert_true(not S.voices[7].active, "voice 7 takes the current corner C's state")
end)

-- #641: the flash names the slot as every scene flash does
test("an empty corner's flash names its slot by its label (#641)", function()
  local context, S = two_scenes()
  S.lib.scenes.set_name(5, "dusk")                               -- a named empty slot
  local flashes = {}
  local real_flash = header_flash
  header_flash = function(text) table.insert(flashes, text); return real_flash(text) end
  params:set("morph_b", 5)
  settle(context, 0.3)
  header_flash = real_flash
  assert_equal(table.concat(flashes, ", "), "S5 dusk empty", "S.lib.scenes.label's name")
end)

-- #626: the PSET hook ends a clock whose resume norns may have posted while
-- the PSET was read: retired, it ends at its wake and applies nothing (a
-- cancel would make norns' clock.resume raise)
test("a PSET read while the morph clock's resume is posted raises nothing and applies nothing (#626)", function()
  local context, S = two_scenes()
  settle(context, 0.3)
  params:set("reverb_mix", 0.9)
  params:write(1)                                                -- the PSET: morph 0.3, reverb 0.9
  params:set("morph", 0.6)                                       -- a move: the clock waits on its first sleep
  context.clock.advance(function() params:read(1) end)           -- its resume posted, then the read and its hook
  context.clock.run_for(0.5)
  assert_near(params:get("morph"), 0.3, 1e-9, "the PSET's position")
  assert_near(params:get("reverb_mix"), 0.9, 1e-9, "nothing applied over the PSET's values")
  assert_equal(S.morph_clock, nil, "no clock is left")
  settle(context, 0.35)
  assert_near(params:get("reverb_mix"), 0.34, 1e-9, "the next move applies (0.2 + 0.35 x 0.4)")
end)

-- Scenes 1-4 with routing R1 to v1 size: each corner's {source, depth}
-- (nil leaves the slot empty). The state is scene 1's
local function routing_scenes(corners)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for slot = 4, 1, -1 do
    local routing = corners[slot]
    if routing then
      S.lib.matrix.set_routing(1, routing[1], "v1_grain_size"); params:set("matrix_1_depth", routing[2])
      capture_scene(slot)
    end
  end
  return context, S
end

local function assert_routing_rows(context, S, rows)
  for _, row in ipairs(rows) do
    settle_xy(context, row[1], row[2])
    local where = "(" .. row[1] .. ", " .. row[2] .. ")"
    assert_near(params:get("matrix_1_depth"), row[3], 1e-9, where .. ": R1's depth")
    assert_equal(S.lib.matrix.routing(1).source, row[4], where .. ": R1's source")
  end
end

-- Record what morph writes to R1's depth (before the param's whole step)
local function depth_writes(S)
  local log = {}
  local real_set = S.lib.scenes.set_value
  S.lib.scenes.set_value = function(id, value)
    if id == "matrix_1_depth" then log.last = value end
    return real_set(id, value)
  end
  log.stop = function() S.lib.scenes.set_value = real_set end
  return log
end

-- ruling 88a: a through-zero id ramps on its corners' lead. G is the
-- current corner's group (the counting corners that hold the same routing),
-- m the largest weight in G, w' the largest outside it:
-- (sum over G of w x v) x max(0, m - w') / m
test("a routing that differs between corners ramps on the lead of its corners", function()
  -- A: R1 lfo1 > v1 size at 40; B: lfo2 at 60; C and D as A at 40
  local context, S = routing_scenes({ { "lfo1", 40 }, { "lfo2", 60 }, { "lfo1", 40 }, { "lfo1", 40 } })
  assert_routing_rows(context, S, {
    { 0.25, 0, 20, "lfo1" },     -- 40 x (0.75 - 0.25)
    { 0.5, 0, 0, "lfo1" },       -- a and b tie: 0
    { 0, 0, 40, "lfo1" },        -- at A: A's depth
    { 0.25, 0.25, 22, "lfo1" },  -- 40 x 0.8125 x (0.5625 - 0.1875) / 0.5625 = 21.67, stored 22
    { 0.6, 0, 12, "lfo2" },      -- past the crossing: B's routing, 60 x (0.6 - 0.4)
    { 1, 0, 60, "lfo2" },
  })
end)

test("a routing two corners share never ramps between them", function()
  -- the review's probe: A and C share lfo1 > v1 size at 40, B's differs (lfo2
  -- at 60), D empty
  local context, S = routing_scenes({ { "lfo1", 40 }, { "lfo2", 60 }, { "lfo1", 40 } })
  assert_routing_rows(context, S, {
    { 0, 0.25, 40, "lfo1" },     -- the A to C edge: one group, the plain weighted mean (m - 0 over m is 1)
    { 0, 0.5, 40, "lfo1" },
    { 0, 0.75, 40, "lfo1" },
    { 0, 1, 40, "lfo1" },
  })
  -- just inside the edge, continuous with its 40 as x goes to 0
  local log = depth_writes(S)
  local expected = {
    { 0.01, 80 * 0.98 / 1.99 },    -- A and C 0.4975 each, B 0.0050: 39.40, never near 0
    { 0.001, 80 * 0.998 / 1.999 }, -- 39.94
    { 0, 40 },
  }
  for _, row in ipairs(expected) do
    settle_xy(context, row[1], 0.5)
    assert_near(log.last, row[2], 1e-9, "(" .. row[1] .. ", 0.5): morph writes R1's depth")
    assert_equal(S.lib.matrix.routing(1).source, "lfo1", "on the shared routing")
  end
  log.stop()
  -- A and C sharing the routing at 40 and 20: a straight blend between them
  context, S = routing_scenes({ { "lfo1", 40 }, { "lfo2", 60 }, { "lfo1", 20 } })
  assert_routing_rows(context, S, {
    { 0, 0.25, 35, "lfo1" },
    { 0, 0.5, 30, "lfo1" },
    { 0, 1, 20, "lfo1" },
  })
end)

-- ruling 88a: across the square the depth moves in small steps; the one
-- larger step is the hysteresis's at the corner switch, where the new group
-- starts at its value times its 0.04 lead (as the two-scene morph does at
-- 52 %). At y 0.5 with D empty, A and C weigh (1 - x) / (2 - x) each and B
-- x / (2 - x): A and C's depth is 80 (1 - 2x) / (2 - x), 0 from x 0.5
-- where B's weight passes theirs; B's, once the corner switches at 0.53,
-- is 60 (2x - 1) / (2 - x)
test("a shared routing's depth moves in small steps across the square, with no drop at the corner switch", function()
  local context, S = routing_scenes({ { "lfo1", 40 }, { "lfo2", 60 }, { "lfo1", 40 } })
  local log = depth_writes(S)
  local values, sources = {}, {}
  for step = 0, 100 do
    settle_xy(context, step / 100, 0.5)
    -- at x 0 morph writes nothing (A and C agree: ruling 87): the depth is
    -- scene 1's 40 as recalled
    values[step], sources[step] = log.last or params:get("matrix_1_depth"), S.lib.matrix.routing(1).source
  end
  log.stop()
  assert_near(values[0], 40, 1e-9, "x 0: A's and C's 40")
  local switch
  for step = 1, 100 do
    if sources[step] ~= sources[step - 1] then
      assert_true(switch == nil, "the routing switches once")
      switch = step
    end
  end
  assert_equal(switch, 53, "the corner and the routing switch to B's at x 0.53")
  assert_equal(sources[100], "lfo2", "to B's routing")
  assert_near(values[50], 0, 1e-9, "A and C's depth is 0 where B's weight passes theirs (x 0.5)")
  assert_near(values[switch - 1], 0, 1e-9, "and still 0 just before the switch: no drop")
  assert_near(values[switch], 60 * 0.06 / 1.47, 1e-9, "B starts at 60 x its 0.0408 lead: 2.45, the hysteresis's step")
  local largest, at = 0, nil
  for step = 1, 100 do
    local change = math.abs(values[step] - values[step - 1])
    if step ~= switch and change > largest then largest, at = change, step end
  end
  assert_near(largest, 60 - 60 * 0.98 / 1.01, 1e-9, "the largest other step: 1.78, B's steepest, x 0.99 to 1")
  assert_equal(at, 100, "at x 1")
end)

-- ruling 24: a PSET load sets the new params as it sets the morph, without
-- applying them
test("a PSET load restores morph y and the corners without applying them", function()
  local context, S = four_scenes()
  settle_xy(context, 0.5, 0.5)
  assert_near(params:get("reverb_mix"), 0.55, 1e-9, "the four corners' blend")
  params:set("reverb_mix", 0.9)                                  -- a hand edit after the morph
  params:set("morph_c", 4)                                       -- C is scene 4 in the PSET
  params:write(1)
  settle_xy(context, 0, 0)
  params:set("morph_c", 3)
  params:set("reverb_mix", 0.5)
  params:read(1)
  context.clock.run_for(0.5)
  assert_near(params:get("morph_y"), 0.5, 1e-9, "the PSET's y")
  assert_equal(params:get("morph_c"), 4, "and its corner C")
  assert_near(params:get("reverb_mix"), 0.9, 1e-9, "the PSET's own value, not the morph's")
  assert_equal(S.morph_clock, nil, "no apply waits")
  settle_xy(context, 0.5, 0.75)
  -- A 0.125, B 0.125, C and D 0.375 each, C and D both scene 4 (1.0)
  assert_near(params:get("reverb_mix"), 0.85, 1e-9, "the next move applies with the PSET's corners")
end)

-- #584: a move between two recalls of one scene, inside the clock's 0.1 s,
-- never applies over the second recall
test("a move between two recalls of the same scene is dropped (#584)", function()
  local context, S = two_scenes()
  recall_scene(2, 0)
  params:set("morph", 0.3)
  recall_scene(2, 0)
  context.clock.run_for(0.5)
  assert_near(params:get("reverb_mix"), 0.6, 1e-9, "scene 2's value stays")
  assert_equal(S.current_scene, 2, "scene 2 stays current")
  assert_true(S.voices[3].active, "as do its voices")
  assert_equal(S.morph_clock, nil, "the move was dropped")
  -- the same with the clock asleep between two applies
  params:set("morph", 0.2)
  context.clock.run_for(0)                                        -- applied; the clock sleeps 0.1 s
  recall_scene(2, 0)
  params:set("morph", 0.3)
  recall_scene(2, 0)
  context.clock.run_for(0.5)
  assert_near(params:get("reverb_mix"), 0.6, 1e-9, "after an apply too")
  assert_equal(S.current_scene, 2)
end)

test("a continuous value is A + morph x (B - A), as a transition's step is", function()
  -- a whole-number param among the faded ones: 10 in A, 15 in B
  local number_id
  local context, S = scrambled_scenes(function(S, slot)
    number_id = whole_number_global(S, 10, 15)
    assert_true(number_id ~= nil, "a continuous scene global holds only whole numbers (a number param or a control stepped by 1)")
    params:set(number_id, slot == 1 and 10 or 15)
  end)
  assert_true(S.lib.morph.plan_ready(), "both endpoints hold valid scenes")
  settle(context, 0.5)
  assert_near(params:get("reverb_mix"), 0.5, 1e-9, "reverb mix halfway from 0.1 to 0.9")
  assert_near(params:get("filter_freq"), 4650, 1e-9, "filter freq halfway from 300 to 9000, in raw values")
  assert_equal(params:get(number_id), 13, "12.5 rounds to 13")
  local morphed = continuous_values(S, 2)

  -- the same fraction of a 20-step transition from scene 1 to scene 2
  recall_scene(1, 0)
  recall_scene(2, 2)                                              -- step 1 runs at once
  for _ = 2, 10 do wake(context, "scene_transition_clock") end    -- step 10: f = 0.5
  local faded = 0
  for _, target in ipairs(scene_transition_targets(S.scenes[2].data)) do
    faded = faded + 1
    assert_near(morphed[target.id], params:get(target.id), 1e-9, target.id .. " as the transition's step 10")
  end
  assert_true(faded > 120, "the transition fades every continuous value (" .. faded .. ")")
  cancel_scene_transition()
end)

test("discrete entries switch at 0.52 on the way up and 0.48 on the way down", function()
  local context, S = two_scenes()
  local synth = S.constants.SOURCE_SYNTH
  local syncs = 0
  local real_sync = sync_voice_values_to_engine
  sync_voice_values_to_engine = function(...) syncs = syncs + 1; return real_sync(...) end
  settle(context, 0.1)
  assert_true(not S.voices[3].active, "0.1: voice 3 stopped")
  assert_equal(S.voices[3].source, synth, "on its synth")
  settle(context, 0.51)
  assert_true(not S.voices[3].active, "0.51: still stopped")
  assert_equal(S.voices[3].source, synth, "on its synth")
  assert_near(params:get("reverb_mix"), 0.4, 1e-9, "reverb mix 0.2 + 0.51 x 0.4, stored to its 0.01 step")

  context.clear_engine_calls()
  settle(context, 0.52)
  assert_true(S.voices[3].active, "0.52: voice 3 runs")
  assert_equal(S.voices[3].source, synth + 1, "on buffer 1")
  local source_at = call_index(context, "setGrainSource", 2, 1)
  local start_at = call_index(context, "voiceOn", 2)
  assert_true(source_at ~= nil and start_at ~= nil and source_at < start_at, "the source first, then the start")
  assert_equal(count_calls(context, "voiceOn", 2), 1, "one start")
  assert_equal(count_calls(context, "voiceOff", 2), 0, "and no stop")
  assert_equal(syncs, 0, "the start is the voice's one sync")

  context.clear_engine_calls()
  settle(context, 0.49)
  assert_true(S.voices[3].active, "back to 0.49: unchanged")
  assert_equal(S.voices[3].source, synth + 1, "on buffer 1")
  assert_equal(count_calls(context, "voiceOff", 2), 0, "nothing stops")

  settle(context, 0.48)
  assert_true(not S.voices[3].active, "0.48: voice 3 stops")
  assert_equal(S.voices[3].source, synth, "back on its synth")
  local stop_at = call_index(context, "voiceOff", 2)
  local back_at = call_index(context, "setGrainSource", 2, 0)
  assert_true(stop_at ~= nil and back_at ~= nil and stop_at < back_at, "the voice stops first, then the source returns")
  assert_equal(syncs, 0, "a stopped voice gets no sync")
  sync_voice_values_to_engine = real_sync
end)

test("the first apply after a plan change takes A below 0.5 and B from it", function()
  local context, S = two_scenes()
  -- scene 3 as scene 2
  params:set("reverb_mix", 0.6); params:set("v3_source", S.constants.SOURCE_SYNTH + 1); toggle_voice(3)
  capture_scene(3)
  recall_scene(1, 0)
  settle(context, 0.7)
  assert_true(S.voices[3].active, "0.7: B, voice 3 runs")
  settle(context, 0.49)
  assert_true(S.voices[3].active, "0.49 from B: still B")
  params:set("morph_b", 3)                                       -- a new plan
  settle(context, 0.495)
  assert_true(not S.voices[3].active, "the first apply of the new plan below 0.5 takes A")
  params:set("morph_b", 2)                                       -- the plan changes again
  settle(context, 0.5)
  assert_true(S.voices[3].active, "and at 0.5 B, though 0.5 is inside the hysteresis from A")
end)

test("moves are coalesced to 10 applies a second, with one more at rest", function()
  local context, S = two_scenes()
  local applies = 0
  local real_cancel = cancel_scene_transition
  cancel_scene_transition = function(...) applies = applies + 1; return real_cancel(...) end
  for step = 1, 100 do
    params:set("morph", step / 100)
    context.clock.run_for(0.01)
  end
  context.clock.run_for(1)
  cancel_scene_transition = real_cancel
  assert_true(applies <= 11, "100 moves over 1 s apply at most 11 times, saw " .. applies)
  assert_true(applies >= 10, "and at about 10 a second, saw " .. applies)
  assert_near(params:get("reverb_mix"), 0.6, 1e-9, "the last apply lands the final position, B's value")
  assert_true(S.voices[3].active, "past the crossing")
  assert_equal(S.morph_clock, nil, "the clock stops once the morph rests")
end)

test("an apply sets at most 120 values and a still morph converges", function()
  local context, S = scrambled_scenes()
  local a_values = continuous_values(S, 1)
  recall_scene(2, 0)
  local b_values = continuous_values(S, 2)
  recall_scene(1, 0)
  local a_data, b_data = scene_data_values(S, 1), scene_data_values(S, 2)
  local differing = 0
  for id, value in pairs(a_data) do
    assert_true(b_data[id] ~= nil, id .. " is in both scenes")
    if b_data[id] ~= value then differing = differing + 1 end
  end
  assert_true(differing > 120, "the scenes differ in more than 120 values (" .. differing .. ")")
  -- each apply cancels a transition first, then sets its continuous values
  local sizes = {}
  local real_cancel, real_set = cancel_scene_transition, S.lib.scenes.set_value
  cancel_scene_transition = function(...) table.insert(sizes, 0); return real_cancel(...) end
  S.lib.scenes.set_value = function(id, value)
    sizes[#sizes] = sizes[#sizes] + 1
    return real_set(id, value)
  end
  params:set("morph", 0.25)
  context.clock.run_for(3)
  cancel_scene_transition, S.lib.scenes.set_value = real_cancel, real_set
  assert_true(#sizes >= 2, "more than one apply reaches every value (" .. #sizes .. ")")
  local total = 0
  for index, size in ipairs(sizes) do
    assert_true(size <= 120, "apply " .. index .. " sets at most 120 values, set " .. size)
    total = total + size
  end
  assert_equal(sizes[1], 120, "the first apply sets 120")
  assert_equal(total, differing, "every value that differs, once")
  assert_equal(S.morph_clock, nil, "then the still morph rests")
  for id, a in pairs(a_values) do
    local spec = params:lookup_param(id)
    local expected = a + 0.25 * (b_values[id] - a)
    local step = spec.controlspec and spec.controlspec.step or 1
    -- to the param's step (a number param rounds), within an exp warp's round trip
    assert_near(params:get(id), expected, step / 2 + 1e-9 * math.max(1, math.abs(expected)),
      id .. " at a quarter of the way")
  end
end)

test("while the morph moves, a value that moved less than 1/1000 of its range waits for the rest", function()
  local context, S = two_scenes()
  settle(context, 0.5)
  assert_near(params:get("reverb_mix"), 0.4, 1e-9, "reverb mix at 0.5")
  local set_ids, set_values = {}, {}
  local real_set = S.lib.scenes.set_value
  S.lib.scenes.set_value = function(id, value)
    table.insert(set_ids, id); table.insert(set_values, value)
    return real_set(id, value)
  end
  params:set("morph", 0.5024)                                     -- reverb mix's target moves 0.00096 of 1
  context.clock.run_for(0)                                        -- the apply of the move
  assert_equal(#set_ids, 0, "a move under 1/1000 of the range sets nothing")
  context.clock.run_for(0.5)                                      -- the apply at rest
  assert_equal(table.concat(set_ids, ", "), "reverb_mix", "the apply at rest sets it")
  assert_near(set_values[1], 0.40096, 1e-12, "to its exact value")
  params:set("morph", 0.505)
  context.clock.run_for(0)                                        -- 0.00104 from the last value set
  assert_equal(#set_ids, 2, "a move past it sets the value at once")
  assert_near(set_values[2], 0.402, 1e-12, "0.2 + 0.505 x 0.4")
  context.clock.run_for(0.5)
  assert_equal(#set_ids, 2, "and the rest has nothing left to set")
  S.lib.scenes.set_value = real_set
end)

test("a morph at rest at 0 or 1 holds the scene's exact values", function()
  local context, S = scrambled_scenes()
  local a_values = continuous_values(S, 1)
  recall_scene(2, 0)
  local b_values = continuous_values(S, 2)
  recall_scene(1, 0)
  -- filter freq 300 to 9000 Hz: 1/1000 of its range is 19.98 Hz, and the
  -- last moves are 17.4 Hz
  for _, position in ipairs({ 0.5, 0.998 }) do settle(context, position) end
  params:set("morph", 1)
  context.clock.run_for(0)
  assert_near(params:get("filter_freq"), 8982.6, 1e-6, "the move's apply leaves filter freq where 0.998 put it")
  context.clock.run_for(1)
  for id, value in pairs(b_values) do
    assert_near(params:get(id), value, 1e-9 * math.max(1, math.abs(value)), id .. ": B's exact value at rest at 1")
  end
  for _, position in ipairs({ 0.5, 0.002 }) do settle(context, position) end
  params:set("morph", 0)
  context.clock.run_for(0)
  assert_near(params:get("filter_freq"), 317.4, 1e-6, "the move's apply leaves filter freq where 0.002 put it")
  context.clock.run_for(1)
  for id, value in pairs(a_values) do
    assert_near(params:get(id), value, 1e-9 * math.max(1, math.abs(value)), id .. ": A's exact value at rest at 0")
  end
  assert_equal(S.morph_clock, nil, "then the clock rests")
end)

test("a quantized voice's freq snaps under a morph as under a transition's step", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("v1_quantize", 1)                                    -- the chromatic scale: semitones
  params:set("v1_freq", 440); capture_scene(2)
  params:set("v1_freq", 220); capture_scene(1)
  settle(context, 0.5)
  local morphed = params:get("v1_freq")
  assert_near(morphed, 329.63, 0.01, "330 Hz snaps to E4")
  recall_scene(1, 0)
  recall_scene(2, 2)
  for _ = 2, 10 do wake(context, "scene_transition_clock") end    -- step 10: f = 0.5
  assert_near(morphed, params:get("v1_freq"), 1e-9, "the transition's step 10 gives the same")
  cancel_scene_transition()
end)

test("a voice's loop pair is written together, start before length", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("v1_loop_start", 0); params:set("v1_loop_length", 1); capture_scene(2)
  params:set("v1_loop_start", 0.5); params:set("v1_loop_length", 0.5); capture_scene(1)
  settle(context, 0.5)
  assert_near(params:get("v1_loop_start"), 0.25, 1e-9, "0.5: start halfway from 0.5 to 0")
  assert_near(params:get("v1_loop_length"), 0.75, 1e-9, "and length halfway from 0.5 to 1, not cut to the old start's room")
  -- start moves 0.0009995 (under 1/1000 of 0-1), length the same (over
  -- 1/1000 of 0.001-1): the length is due, so the start goes with it
  params:set("morph", 0.501999)
  context.clock.run_for(0)
  assert_near(params:get("v1_loop_start"), 0.2490005, 1e-9, "the start is written with the length")
  assert_near(params:get("v1_loop_length"), 0.7509995, 1e-9, "the length")
  context.clock.run_for(0.5)
  local sum = params:get("v1_loop_start") + params:get("v1_loop_length")
  assert_true(sum <= 1 + 1e-9, "at rest the loop fits its slot, start + length " .. sum)
  -- and back toward A, where the start rises while the length falls
  settle(context, 0.1)
  assert_near(params:get("v1_loop_start"), 0.45, 1e-9, "0.1: start")
  assert_near(params:get("v1_loop_length"), 0.55, 1e-9, "0.1: length")
end)

test("a recall after a pending move wins: the move is dropped", function()
  local context, S = two_scenes()
  params:set("morph", 0.31)
  context.clock.run_for(0)                                        -- applied at once
  params:set("morph", 0.35)                                       -- while the clock sleeps
  recall_scene(2, 0)
  context.clock.run_for(0.5)
  assert_near(params:get("reverb_mix"), 0.6, 1e-9, "the recalled scene's value stays")
  assert_equal(S.current_scene, 2, "and its scene stays current")
  assert_true(S.voices[3].active, "as do its voices")
  assert_equal(S.morph_clock, nil, "the move was dropped")
  assert_near(params:get("morph"), 0.35, 1e-9, "the morph stays where it was moved")
  settle(context, 0.36)
  assert_near(params:get("reverb_mix"), 0.34, 1e-9, "the next move applies again (0.344, stored to 0.01)")
  assert_equal(S.current_scene, 0, "no scene is current")
end)

test("a transition started after a pending move wins: the move is dropped", function()
  local context, S = two_scenes()
  params:set("morph", 0.31)
  context.clock.run_for(0)
  params:set("morph", 0.35)
  recall_scene(2, 2)                                              -- a 2 s fade, 20 steps
  context.clock.run_for(0.15)
  assert_true(S.scene_transition_active, "the fade runs on")
  assert_equal(S.current_scene, 2, "toward its scene")
  context.clock.run_for(2.5)
  assert_true(not S.scene_transition_active, "it landed")
  assert_near(params:get("reverb_mix"), 0.6, 1e-9, "on its scene's value")
  assert_equal(S.current_scene, 2, "its scene current")
  assert_equal(S.morph_clock, nil, "and the morph left it alone")
end)

test("a move cancels a running transition and clears the current scene", function()
  local context, S = two_scenes()
  recall_scene(1, 0)
  assert_equal(S.current_scene, 1, "scene 1 is current")
  recall_scene(2, 2)
  assert_true(S.scene_transition_active, "a transition to scene 2 runs")
  settle(context, 0.3)
  assert_true(not S.scene_transition_active, "the morph canceled it")
  assert_equal(S.scene_transition_clock, nil, "its clock is gone")
  assert_equal(S.current_scene, 0, "no scene is current")
  recall_scene(2, 0)
  assert_equal(S.current_scene, 2, "a recall makes its scene current")
  assert_near(params:get("morph"), 0.3, 1e-9, "and leaves the morph where it is")
end)

test("an empty endpoint flashes once and changes nothing", function()
  local context, S = two_scenes()
  local flashes = {}
  local real_flash = header_flash
  header_flash = function(text) table.insert(flashes, text); return real_flash(text) end
  recall_scene(1, 0)
  params:set("reverb_mix", 0.5)
  params:set("morph_b", 5)
  assert_true(not S.lib.morph.plan_ready(), "scene 5 is empty")
  settle(context, 0.3)
  settle(context, 0.7)
  assert_equal(table.concat(flashes, ", "), "S5 empty", "one flash")
  assert_near(params:get("reverb_mix"), 0.5, 1e-9, "nothing is set")
  assert_true(not S.voices[3].active, "nothing starts")
  assert_equal(S.current_scene, 1, "the current scene stays")
  -- an invalid scene in a slot counts as empty, A as B
  capture_scene(5)
  S.scenes[5].data.tempo = "fast"
  assert_true(not S.lib.morph.plan_ready(), "an invalid scene is no endpoint")
  params:set("morph_a", 6); params:set("morph_b", 2)
  settle(context, 0.2)
  assert_equal(table.concat(flashes, ", "), "S5 empty, S6 empty", "a new plan flashes its empty endpoint once")
  assert_near(params:get("reverb_mix"), 0.5, 1e-9, "still nothing set")
  header_flash = real_flash
end)

test("morph never recalls and never starts a transition", function()
  local context, S = two_scenes()
  local recalls = {}
  local real_recall, real_instant = recall_scene, recall_scene_instant
  recall_scene = function(...) table.insert(recalls, "recall_scene"); return real_recall(...) end
  recall_scene_instant = function(...) table.insert(recalls, "recall_scene_instant"); return real_instant(...) end
  for _, position in ipairs({ 0.1, 0.6, 1, 0.2, 0 }) do
    params:set("morph", position)
    context.clock.run_for(0)
    assert_true(not S.scene_transition_active, position .. ": no transition")
    context.clock.run_for(0.5)
  end
  recall_scene, recall_scene_instant = real_recall, real_instant
  assert_equal(table.concat(recalls, ", "), "", "no recall")
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "the params are A's again")
end)

test("a slot saved while morphing rebuilds the plan", function()
  local context, S = two_scenes()
  params:set("morph", 0.5)
  context.clock.run_for(0)
  assert_near(params:get("reverb_mix"), 0.4, 1e-9, "halfway")
  assert_true(S.morph_clock ~= nil, "the morph clock runs")
  params:set("reverb_mix", 1)
  S.lib.scenes.save(2)                                           -- B is now reverb 1
  settle(context, 0.75)
  assert_near(params:get("reverb_mix"), 0.8, 1e-9, "0.2 + 0.75 x (1 - 0.2): the new B")
end)

test("a block with through_zero ramps its ids through 0 and switches at the crossing, both ways", function()
  local block_value, asked, switches, applied = 1, {}, {}, {}
  local context, S = two_scenes({ before_init = function()
    local S = local_value("S")
    S.register_scene_block({ key = "morph_tz", discrete = true,
      default = function() return 0 end, capture = function() return block_value end,
      validate = function(value) return type(value) == "number" end,
      apply = function(value) table.insert(applied, value) end,
      through_zero = function(from_value, to_value)
        table.insert(asked, from_value .. ">" .. to_value)
        return { { id = "reverb_mix", switch = function()
          table.insert(switches, string.format("%d at %.2f", to_value, params:get("reverb_mix")))
        end } }
      end })
  end })
  -- A: block 1, reverb 0.4; B: block 2, reverb 0.8
  params:set("reverb_mix", 0.8); block_value = 2; capture_scene(2)
  params:set("reverb_mix", 0.4); block_value = 1; capture_scene(1)
  local expected = {
    { 0.1, 0.32, "" },                 -- A x (1 - 2m)
    { 0.25, 0.2, "" },
    { 0.51, 0, "" },                   -- 0 until the switch
    { 0.52, 0.03, "2 at 0.00" },       -- the switch at 0 at the crossing, then B x (2m - 1): 0.032
    { 0.75, 0.4, "2 at 0.00" },
    { 0.49, 0, "2 at 0.00" },
    { 0.48, 0.02, "2 at 0.00, 1 at 0.00" },  -- back: A's switch, then 0.016
    { 0.25, 0.2, "2 at 0.00, 1 at 0.00" },
    { 0.9, 0.64, "2 at 0.00, 1 at 0.00, 2 at 0.00" },  -- a jump across: the id goes to 0 first
    { 0.1, 0.32, "2 at 0.00, 1 at 0.00, 2 at 0.00, 1 at 0.00" },
  }
  for _, row in ipairs(expected) do
    settle(context, row[1])
    assert_near(params:get("reverb_mix"), row[2], 1e-9, row[1] .. ": reverb mix")
    assert_equal(table.concat(switches, ", "), row[3], row[1] .. ": the switches")
  end
  assert_equal(table.concat(asked, ", "), "1>2, 2>1", "the block is asked each way once, A's value to B's and back")
  assert_equal(table.concat(applied, ", "), "1, 2, 1, 2, 1", "the block switches with the discrete entries")
end)

test("morph's sends are deferrable", function()
  local context, S = two_scenes()
  settle(context, 0.1)
  local budget = S.constants.ENGINE_BUDGET
  -- a hand edit's sends fill this window's budget
  for _ = 1, budget.messages_per_window do send_param_to_engine("drift_amount", 0.01) end
  local flags = {}
  local real_send = send_param_to_engine
  send_param_to_engine = function(id, value)
    if id == "reverb_mix" then table.insert(flags, S.deferrable_write) end
    return real_send(id, value)
  end
  context.clear_engine_calls()
  params:set("morph", 0.2)
  context.clock.run_for(0)                                       -- the apply, in the same window
  send_param_to_engine = real_send
  assert_equal(#flags, 1, "the morph set reverb mix")
  assert_true(flags[1], "inside deferrable")
  assert_equal(S.deferrable_write, false, "the flag is down while the clock sleeps")
  assert_equal(#context.calls_named("setReverb"), 0, "the send waits for the next window")
  assert_true(S.lib.engine_sync.budget_state().pending >= 1, "as a pending value")
  context.clock.run_for(0.2)
  local sent = context.calls_named("setReverb")
  assert_true(#sent >= 1, "the next window sends it")
  assert_near(sent[#sent].args[1], 0.28, 1e-9, "the morph's value")
end)

test("a PSET load restores the morph position without applying it", function()
  local context, S = two_scenes()
  settle(context, 0.3)
  assert_near(params:get("reverb_mix"), 0.32, 1e-9, "0.2 + 0.3 x 0.4")
  params:set("reverb_mix", 0.9)                                  -- a hand edit after the morph
  params:write(1)
  settle(context, 0)
  params:set("reverb_mix", 0.5)
  params:read(1)
  context.clock.run_for(0.5)
  assert_near(params:get("morph"), 0.3, 1e-9, "the PSET's position")
  assert_near(params:get("reverb_mix"), 0.9, 1e-9, "the PSET's own value, not the morph's")
  assert_equal(S.morph_clock, nil, "no apply waits")
  settle(context, 0.35)
  assert_near(params:get("reverb_mix"), 0.34, 1e-9, "the next move applies the morph again")
end)

test("a recall stops a still morph's convergence, and the next move applies from the recalled state", function()
  local context, S = scrambled_scenes()
  params:set("morph", 0.5)
  context.clock.run_for(0)                                       -- the first apply: 120 values, more wait
  assert_true(S.morph_clock ~= nil, "values wait for the next apply")
  recall_scene(1, 0)
  local recalled = continuous_values(S, 1)
  context.clock.run_for(1)
  assert_equal(S.morph_clock, nil, "the morph clock stopped")
  assert_equal(S.current_scene, 1, "the recalled scene stays current")
  for id, value in pairs(recalled) do assert_equal(params:get(id), value, id .. " stays as recalled") end

  -- two scenes that differ in voice 3: back at A's discrete state, the
  -- next move on B's side takes B's again
  context, S = two_scenes()
  settle(context, 0.6)
  assert_true(S.voices[3].active, "0.6: B")
  recall_scene(1, 0)
  assert_true(not S.voices[3].active, "the recall stops voice 3")
  settle(context, 0.62)
  assert_true(S.voices[3].active, "the next move applies B's discrete entries again")
  assert_near(params:get("reverb_mix"), 0.45, 1e-9, "and every value of the plan (0.448, stored to 0.01)")
  assert_equal(S.current_scene, 0, "no scene is current")
end)

test("cleanup stops the morph clock", function()
  local context, S = two_scenes()
  params:set("morph", 0.4)
  assert_true(S.morph_clock ~= nil, "a move waits for the clock")
  for _, record in ipairs(S.registry.cleanup) do
    if record.order == S.constants.CLEANUP_ORDER.morph_clock then record.fn() end
  end
  assert_equal(S.morph_clock, nil, "the clock is gone")
  context.clock.run_for(0.5)
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "and nothing applies")
end)

-- #653 (ruling 94): a crossing's discrete switch is applied at most once
-- per MORPH.crossing_seconds. A single crossing is immediate; while a
-- second waits the continuous values keep moving; when the wait ends the
-- corner current then is applied (the newest wins), and a crossing there
-- and back inside the wait applies nothing

-- Move the morph and run one apply's worth of the clocks
local function move(context, x)
  params:set("morph", x)
  context.clock.run_for(0.1)
end

test("a crossing within crossing_seconds of the last waits; then the corner current then switches, once (#653)", function()
  local context, S = two_scenes()
  assert_near(S.lib.morph.MORPH.crossing_seconds, 0.3, 1e-9)
  settle(context, 0.4)
  assert_true(not S.voices[3].active, "at A: voice 3 stopped")
  context.clear_engine_calls()
  move(context, 0.6)
  assert_true(S.voices[3].active, "a first crossing switches at once")
  move(context, 0.4)
  assert_true(S.voices[3].active, "a second within the wait does not: voice 3 keeps running")
  assert_near(params:get("reverb_mix"), 0.36, 1e-9, "while the continuous value follows the morph (0.2 + 0.4 x 0.4)")
  assert_equal(count_calls(context, "voiceOff", 2), 0, "nothing stopped yet")
  context.clock.run_for(0.3)
  assert_true(not S.voices[3].active, "after the wait the corner current then, A, switches")
  assert_equal(count_calls(context, "voiceOff", 2), 1, "once")
  assert_equal(count_calls(context, "voiceOn", 2), 1, "after the one start")
  context.clock.run_for(0.5)
  assert_equal(S.morph_clock, nil, "then the clock rests")
end)

test("a crossing there and back inside the wait applies nothing at its end (#653)", function()
  local context, S = two_scenes()
  settle(context, 0.4)
  context.clear_engine_calls()
  move(context, 0.6)
  assert_true(S.voices[3].active, "the first crossing starts voice 3")
  move(context, 0.4)
  move(context, 0.6)
  context.clock.run_for(0.5)
  assert_true(S.voices[3].active, "voice 3 still runs")
  assert_equal(count_calls(context, "voiceOff", 2), 0, "it never stopped")
  assert_equal(count_calls(context, "voiceOn", 2), 1, "nor started again")
  assert_near(params:get("reverb_mix"), 0.44, 1e-9, "the continuous value is 0.6's")
  assert_equal(S.morph_clock, nil, "and the clock rests")
end)

test("a recall, a PSET load or cleanup during the wait drops the waiting crossing (#653)", function()
  local function waiting()
    local context, S = two_scenes()
    settle(context, 0.4)
    move(context, 0.6)
    move(context, 0.4)
    assert_true(S.voices[3].active, "the crossing back waits")
    context.clear_engine_calls()
    return context, S
  end
  local context, S = waiting()
  recall_scene(2, 0)    -- scene 2: voice 3 running
  context.clock.run_for(0.5)
  assert_true(S.voices[3].active, "the recalled scene's voice 3 stays")
  assert_equal(count_calls(context, "voiceOff", 2), 0, "a recall dropped the waiting crossing")
  assert_equal(S.current_scene, 2, "the recalled scene stays current")
  assert_equal(S.morph_clock, nil, "and no clock runs")
  context, S = waiting()
  for _, hook in ipairs(S.registry.pset_hooks) do
    if hook.name == "morph" then hook.read() end
  end
  context.clock.run_for(0.5)
  assert_equal(count_calls(context, "voiceOff", 2), 0, "a PSET load dropped it")
  assert_equal(S.morph_clock, nil, "and its clock")
  context, S = waiting()
  for _, record in ipairs(S.registry.cleanup) do
    if record.order == S.constants.CLEANUP_ORDER.morph_clock then record.fn() end
  end
  context.clock.run_for(0.5)
  assert_equal(count_calls(context, "voiceOff", 2), 0, "and so did cleanup")
  assert_equal(S.morph_clock, nil)
end)

test("the XY morph's corner switch waits the same (#653)", function()
  local context, S = four_scenes()
  settle_xy(context, 0, 0.4)
  assert_true(not S.voices[3].active, "on A's side of the A to C edge: voice 3 stopped")
  context.clear_engine_calls()
  params:set("morph_y", 0.6); context.clock.run_for(0.1)
  assert_true(S.voices[3].active, "crossing to C starts voice 3 at once")
  assert_equal(S.lib.morph.corner(), "c")
  params:set("morph_y", 0.4); context.clock.run_for(0.1)
  assert_true(S.voices[3].active, "the crossing back to A waits")
  assert_equal(S.lib.morph.corner(), "c", "C stays the current corner while it waits")
  assert_near(params:get("reverb_mix"), 0.28, 1e-9, "while the continuous value follows (0.2 + 0.4 x (0.4 - 0.2))")
  context.clock.run_for(0.3)
  assert_true(not S.voices[3].active, "after the wait A switches")
  assert_equal(count_calls(context, "voiceOff", 2), 1, "once")
  assert_equal(S.lib.morph.corner(), "a")
end)

test("swept across the crossing on every apply, the morph switches at most once per crossing_seconds (#653)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.drift_metro:stop()
  -- scene 2: every voice running; scene 1: every voice stopped
  for v = 1, S.constants.NUM_VOICES do
    if not S.voices[v].active then toggle_voice(v) end
  end
  capture_scene(2)
  for v = 1, S.constants.NUM_VOICES do toggle_voice(v) end
  capture_scene(1)
  settle(context, 0.4)
  context.clear_engine_calls()
  -- 2 s: 20 applies, each on the other side of the crossing
  local switches, running, start_size = 0, false, nil
  for tick = 1, 20 do
    params:set("morph", tick % 2 == 1 and 0.6 or 0.4)
    context.clock.run_for(0.1)
    if S.voices[1].active ~= running then
      switches, running = switches + 1, S.voices[1].active
    end
    if tick == 1 then start_size = #context.engine_calls end
  end
  -- 1 + floor(2 / 0.3) = 7 switches at most, starts and stops in turn:
  -- 4 starts of all seven voices and 3 stops
  local voices = S.constants.NUM_VOICES
  assert_true(start_size >= voices * 50, "the first crossing starts all seven at once: " .. start_size .. " messages")
  assert_true(switches <= 7, "at most 7 switches in 2 s, saw " .. switches)
  assert_true(switches >= 6, "and they still follow the morph, saw " .. switches)
  assert_true(#context.calls_named("voiceOn") <= 4 * voices, "at most 4 starts of every voice")
  assert_true(#context.calls_named("voiceOff") <= 3 * voices, "and 3 stops")
  local messages = #context.engine_calls
  assert_true(messages <= 4 * start_size + 3 * voices, "at most 4 starts and 3 stops' messages: " .. messages)
  assert_true(messages / 2 < S.constants.ENGINE_BUDGET.messages_per_window * 10,
    "under the budget's 1500 a second: " .. messages / 2)
end)

end

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

test("the morph params are a group of three, defaulting to A = 1, B = 2 at 0, and no scene field", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local group = params:lookup_param("strata_morph")
  assert_equal(group.t, params.tGROUP, "strata_morph is a group")
  assert_equal(group.n, 3, "of three params")
  local index = params.lookup["strata_morph"]
  assert_equal(params.params[index + 1].id, "morph", "morph first")
  assert_equal(params.params[index + 2].id, "morph_a", "then A")
  assert_equal(params.params[index + 3].id, "morph_b", "then B")
  assert_equal(params:get("morph"), 0, "the morph starts at 0")
  assert_equal(params:get("morph_a"), 1, "A is scene 1")
  assert_equal(params:get("morph_b"), 2, "B is scene 2")
  local morph_a = params:lookup_param("morph_a")
  assert_equal(morph_a.min, 1, "A takes a scene from 1")
  assert_equal(morph_a.max, S.constants.NUM_SCENES, "to NUM_SCENES")
  assert_equal(params:lookup_param("morph_b").max, S.constants.NUM_SCENES, "B too")
  assert_equal(params:string("morph"), "0 %", "the position shows in percent")
  params:set("morph", 0.35)
  assert_equal(params:string("morph"), "35 %", "in whole percents")
  capture_scene(1)
  for _, id in ipairs({ "morph", "morph_a", "morph_b" }) do
    assert_equal(S.scenes[1].data[id], nil, id .. " is no scene field")
  end
  context.clock.run_for(0.5)
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
  local differing = 0
  for id, value in pairs(a_values) do
    if b_values[id] ~= value then differing = differing + 1 end
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

end

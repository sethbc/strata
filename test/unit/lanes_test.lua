-- test/unit/lanes_test.lua
-- The value lanes (lib/lanes.lua, 3.9 grid sequencer package 2a, design
-- section 2, The values, Move's values, Locks stay): the two move targets,
-- what a level means on each, the hand's choices of a mode and a target,
-- the grid's light of a hit, and the values a voice's hits hold
-- (S.lib.sequencer.held_value: the machine `held values`)
-- Run alone: lua test/run.lua lanes

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local OWN_POSITION = 0.2

-- A fresh script after its start-up (voices 1 and 2 running), voice 1
-- reading buffer 1 (8 s; buffer 2 holds 8 s too) at position 0.2, its
-- targets at their defaults (A auto: position on a buffer voice)
local function setup()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds, S.buffers[2].seconds = 8, 8
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v1_buf_pos", OWN_POSITION)
  context.clear_engine_calls()
  return context, S
end

-- The values setGrainParam(0, name, ...) sent, in order
local function sent(context, name)
  local values = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == "setGrainParam" and call.args[1] == 0 and call.args[2] == name then values[#values + 1] = call.args[3] end
  end
  return values
end

local function assert_sends(context, name, expected, what)
  local values = sent(context, name)
  local got = {}
  for index, value in ipairs(values) do got[index] = tostring(value) end
  assert_equal(#values, #expected, what .. ": " .. #expected .. " " .. name .. " sends (got " .. table.concat(got, ", ") .. ")")
  for index, value in ipairs(expected) do assert_near(values[index], value, 1e-9, what .. ": send " .. index) end
end

-- Voice 1's clock's next tick
local function tick(context, S) context.clock.advance_until(S.pattern_clocks[1]) end

local function option_index(param_id, name)
  for index, option in ipairs(params:lookup_param(param_id).options) do
    if option == name then return index end
  end
  error("no option " .. name .. " of " .. param_id)
end

-- Step `step` of voice 1 set at level 15, with these attributes
local function set_step(S, step, attrs)
  S.lib.sequencer.set_level(1, step, 15)
  for key, value in pairs(attrs or {}) do S.lib.sequencer.set_step_attr(1, step, key, value) end
end

-- The params --------------------------------------------------------------

test("each voice has two move targets: A auto, B off, discrete scene keys", function()
  local _, S = setup()
  for voice = 1, h.voice_count() do
    local a, b = params:lookup_param("v" .. voice .. "_seq_move_a"), params:lookup_param("v" .. voice .. "_seq_move_b")
    assert_equal(table.concat(a.options, " "), "auto position pitch size cutoff", "voice " .. voice .. ": A's options")
    assert_equal(table.concat(b.options, " "), "off position pitch size cutoff", "voice " .. voice .. ": B's options")
    assert_equal(params:get("v" .. voice .. "_seq_move_a"), 1, "A's default: auto")
    assert_equal(params:get("v" .. voice .. "_seq_move_b"), 1, "B's default: off")
  end
  assert_equal(table.concat(S.lib.lanes.TARGETS, " "), "position pitch size cutoff", "the four targets")
  local record
  for _, entry in ipairs(S.registry.voice_params) do if entry.name == "seq" then record = entry end end
  assert_equal(record.count, 11, "the seq record holds eleven params")
  assert_equal(record.scene_defaults.seq_move_a, 1, "A's scene default")
  assert_equal(record.scene_defaults.seq_move_b, 1, "B's scene default")
  assert_equal(record.discrete.seq_move_a[2], 5, "A switches, 1 to 5")
  assert_equal(record.discrete.seq_move_b[2], 5, "B switches, 1 to 5")
end)

test("a scene keeps both targets, and one out of range fails its check", function()
  local _, S = setup()
  params:set("v1_seq_move_a", option_index("v1_seq_move_a", "cutoff"))
  params:set("v1_seq_move_b", option_index("v1_seq_move_b", "size"))
  capture_scene(1)
  params:set("v1_seq_move_a", 1); params:set("v1_seq_move_b", 1)
  recall_scene(1)
  assert_equal(params:get("v1_seq_move_a"), option_index("v1_seq_move_a", "cutoff"), "A comes back")
  assert_equal(params:get("v1_seq_move_b"), option_index("v1_seq_move_b", "size"), "B comes back")
  local scene = S.scenes[1]
  assert_true(validate_scene(scene), "the scene passes its check")
  scene.data.voices[1].values.seq_move_a = 6
  assert_true(not validate_scene(scene), "A of 6 is no target")
  scene.data.voices[1].values.seq_move_a = 5
  scene.data.voices[1].values.seq_move_b = 0
  assert_true(not validate_scene(scene), "B of 0 is none")
  scene.data.voices[1].values.seq_move_a, scene.data.voices[1].values.seq_move_b = nil, nil
  fill_scene(scene)
  assert_equal(scene.data.voices[1].values.seq_move_a, 1, "a scene without A gets auto")
  assert_equal(scene.data.voices[1].values.seq_move_b, 1, "and without B, off")
  assert_true(validate_scene(scene), "and passes its check")
end)

test("va and vb are step keys of 1 to 15", function()
  local _, S = setup()
  local seq = S.lib.sequencer
  for _, key in ipairs({"va", "vb"}) do
    seq.set_step_attr(1, 2, key, 15); assert_equal(seq.step_attr(1, 2, key), 15, key .. " 15")
    seq.set_step_attr(1, 2, key, 1); assert_equal(seq.step_attr(1, 2, key), 1, key .. " 1")
    for _, bad in ipairs({0, 16, 1.5, "3"}) do
      seq.set_step_attr(1, 2, key, bad); assert_equal(seq.step_attr(1, 2, key), 1, key .. " refuses " .. tostring(bad))
    end
    seq.set_step_attr(1, 2, key, nil); assert_equal(seq.step_attr(1, 2, key), nil, key .. " cleared")
  end
  local steps = {}
  for voice = 1, h.voice_count() do steps[voice] = {} end
  steps[1][3] = {va = 4, vb = 15}
  assert_true(seq.valid_steps(steps), "a steps block holds them")
  steps[1][3].vb = 0
  assert_true(not seq.valid_steps(steps), "but not a vb of 0")
end)

-- The targets and their values -------------------------------------------

test("a target: auto is position on a buffer voice, pitch on any other; off and A's own are none for B", function()
  local _, S = setup()
  local lanes = S.lib.lanes
  assert_equal(lanes.target(1, "a"), "position", "voice 1 reads a buffer")
  assert_equal(lanes.target(2, "a"), "pitch", "voice 2 is a synth voice")
  assert_equal(lanes.target(1, "b"), nil, "B off")
  params:set("v1_seq_move_b", option_index("v1_seq_move_b", "position"))
  assert_equal(lanes.target(1, "b"), nil, "B naming A's target is none")
  params:set("v1_seq_move_b", option_index("v1_seq_move_b", "cutoff"))
  assert_equal(lanes.target(1, "b"), "cutoff", "B cutoff")
  params:set("v1_seq_move_a", option_index("v1_seq_move_a", "size"))
  assert_equal(lanes.target(1, "a"), "size", "A size")
  assert_equal(lanes.target(1, "c"), nil, "no lane c")
  assert_equal(lanes.target(h.voice_count() + 1, "a"), nil, "no voice past the last")
end)

test("value maps: position 1 and 15 are the loop's start and end, size and cutoff the spec's ends", function()
  local _, S = setup()
  local lanes = S.lib.lanes
  -- buf_pos is a fraction of the loop (docs/notes/engine/loops.md), so on
  -- a loop of 0.25 to 0.75 of the slot level 1 is 0, its start, and 15 is 1
  params:set("v1_loop_start", 0.25); params:set("v1_loop_length", 0.5)
  local id, value = lanes.value(1, "position", 1)
  assert_equal(id, "v1_buf_pos", "position moves buf_pos"); assert_near(value, 0, 1e-12, "level 1: the loop's start")
  id, value = lanes.value(1, "position", 15)
  assert_near(value, 1, 1e-12, "level 15: the loop's end")
  id, value = lanes.value(1, "position", 8)
  assert_near(value, 0.5, 1e-12, "level 8: half way, in fourteen moves")
  for _, case in ipairs({{"size", "v1_grain_size"}, {"cutoff", "v1_filter_freq"}}) do
    local spec = params:lookup_param(case[2]).controlspec
    id, value = lanes.value(1, case[1], 1)
    assert_equal(id, case[2], case[1] .. " moves " .. case[2])
    assert_near(value, spec.minval, 1e-9, case[1] .. ": level 1 is the spec's low end")
    id, value = lanes.value(1, case[1], 15)
    assert_near(value, spec.maxval, 1e-6, case[1] .. ": level 15 its high end")
    id, value = lanes.value(1, case[1], 8)
    assert_near(value, spec:map(0.5), 1e-9, case[1] .. ": level 8 the middle of its own scale")
  end
  assert_equal(lanes.value(1, "position", 0), nil, "no level 0")
  assert_equal(lanes.value(1, "position", 16), nil, "no level 16")
  assert_equal(lanes.value(1, "volume", 3), nil, "no such target")
end)

-- A value stays ---------------------------------------------------------

test("a value stays through steps without one", function()
  local context, S = setup()
  set_step(S, 1, {va = 15}); set_step(S, 5); set_step(S, 9)
  context.clear_engine_calls()
  pattern_clock_start()
  for _ = 2, 9 do tick(context, S) end
  assert_equal(S.lib.sequencer.sounding_step(1), 9, "step 9 played")
  assert_sends(context, "bufPos", {1}, "one send, at step 1")
  assert_equal(S.lib.sequencer.held_value(1, "position"), 15, "held at 15")
  assert_near(S.lib.engine_sync.engine_base_value("v1_buf_pos"), 1, 1e-12, "the override still set after step 9")
  assert_near(params:get("v1_buf_pos"), OWN_POSITION, 1e-12, "the voice's own position stays")
  pattern_clock_stop()
end)

-- Fix round 1 (finding 1): a jump ends a held position value, so it is
-- heard at once, whichever way it comes: the grid's position page,
-- recall_bookmark, a step's bookmark (S.lib.positions.jump in each)
test("a jump ends a held position value: the grid's position page, recall_bookmark, a step's bookmark", function()
  local routes = {
    {"the grid's position page", function(context, S)
      -- a 128h grid on its position page: voice 1's line, cell 13 of 16
      local pane = h.grid_pane(context, "128h")
      pane.show(S.constants.GRID_PAGES.positions, 1)
      pane.tap(13, 1)
      return 12 / 16
    end},
    {"recall_bookmark", function(_, S)
      params:set("v1_bookmark_2", 0.75)
      S.lib.positions.recall_bookmark(1, 2)
      return 0.75
    end},
    {"a step's bookmark", function(context, S)
      params:set("v1_bookmark_3", 0.4)
      set_step(S, 2, {bookmark = 3})
      tick(context, S)
      return 0.4
    end},
  }
  for _, route in ipairs(routes) do
    local context, S = setup()
    set_step(S, 1, {va = 15})
    pattern_clock_start()
    assert_equal(S.lib.sequencer.held_value(1, "position"), 15, route[1] .. ": held")
    local position = route[2](context, S)
    assert_equal(S.lib.sequencer.held_value(1, "position"), nil, route[1] .. ": the jump ends the value")
    assert_near(params:get("v1_buf_pos"), position, 1e-9, route[1] .. ": the jump's position stored")
    assert_near(S.lib.engine_sync.engine_base_value("v1_buf_pos"), position, 1e-9, route[1] .. ": and heard")
    local values = sent(context, "bufPos")
    assert_near(values[#values], position, 1e-9, route[1] .. ": sent last")
    pattern_clock_stop()
  end
end)

-- Fix round 1 (finding 4): a morph's discrete source switch runs inside
-- a recall's setting, where the source change hooks do not run
test("a morph that switches the source ends the held value", function()
  local context, S = setup()
  set_step(S, 1, {va = 15})
  params:set("v1_source", S.constants.SOURCE_SYNTH + 2)
  capture_scene(2)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  capture_scene(1)
  pattern_clock_start()
  assert_equal(S.lib.sequencer.held_value(1, "position"), 15, "held")
  params:set("morph", 1)
  context.clock.run_for(0.3)
  assert_equal(S.voices[1].source, S.constants.SOURCE_SYNTH + 2, "the morph switched voice 1 to buffer 2")
  assert_equal(S.lib.sequencer.held_value(1, "position"), nil, "and ended the value")
  assert_near(S.lib.engine_sync.engine_base_value("v1_buf_pos"), params:get("v1_buf_pos"), 1e-9, "no override")
  pattern_clock_stop()
end)

-- ruling 2a-1: no grain restart hook ends a value, so the hit that starts
-- a stopped voice keeps the value it set, and its start plays it
test("the hit that starts a stopped voice sets its value, and the start keeps it", function()
  local context, S = setup()
  local voice = 3
  assert_true(not S.voices[voice].active, "voice 3 is stopped")
  params:set("v3_source", S.constants.SOURCE_SYNTH + 1)
  S.lib.sequencer.set_level(voice, 1, 15); S.lib.sequencer.set_step_attr(voice, 1, "va", 15)
  context.clear_engine_calls()
  pattern_clock_start()
  assert_true(S.voices[voice].active, "the hit started it")
  local first
  for _, call in ipairs(context.engine_calls) do
    if call.name == "setGrainParam" and call.args[1] == voice - 1 and call.args[2] == "bufPos" then first = call.args[3]; break end
  end
  assert_near(first, 1, 1e-12, "the start's position is the value")
  assert_equal(S.lib.sequencer.held_value(voice, "position"), 15, "and the value is held after the start")
  pattern_clock_stop()
end)

test("the next value replaces it", function()
  local context, S = setup()
  set_step(S, 1, {va = 15}); set_step(S, 5, {va = 8})
  context.clear_engine_calls()
  pattern_clock_start()
  for _ = 2, 6 do tick(context, S) end
  assert_sends(context, "bufPos", {1, 0.5}, "step 1's, then step 5's")
  assert_equal(S.lib.sequencer.held_value(1, "position"), 8, "held at 8")
  pattern_clock_stop()
end)

-- Voice 1 holding step 3's value 15 (position 1) at step 4, length 8,
-- steps 1 to 4 set; calls cleared
local function holding(context, S)
  params:set("v1_seq_length", 8)
  set_step(S, 1); set_step(S, 2); set_step(S, 3, {va = 15}); set_step(S, 4)
  pattern_clock_start()
  for _ = 2, 4 do tick(context, S) end
  assert_equal(S.lib.sequencer.held_value(1, "position"), 15, "held")
  context.clear_engine_calls()
end

-- Review Focus 2 (fix round 1, finding 2): from step 4 of length 8, the
-- voice's steps turned off one by one while it plays, a tick apart (the
-- value's own step 3 first: the value stays), then the wrap to step 1,
-- the pass's end with no set step. before_wrap(context, S) runs before it
local function empty_pass(context, S, before_wrap)
  for _, step in ipairs({3, 1, 2, 4}) do
    S.lib.sequencer.set_level(1, step, 0)
    tick(context, S)
  end
  assert_equal(S.lib.sequencer.sounding_step(1), 8, "the walk reaches step 8")
  if before_wrap then before_wrap(context, S) end
  tick(context, S)
  assert_equal(S.lib.sequencer.sounding_step(1), 1, "and wraps to step 1")
end

local ENDS = {
  {"a stop", function() pattern_clock_stop() end},
  -- the edit's own action sends first, under the override (the engine
  -- sync's, as for a lock), then its touch hook ends the override
  {"a hand edit", function() delta_with_detent("v1_buf_pos", 1) end, OWN_POSITION + 0.01, "under"},
  {"a replace", function(_, S) S.lib.sequencer.replace_pattern(1, {15, 15, 15, 15}) end},
  {"a target change", function() params:set("v1_seq_move_a", option_index("v1_seq_move_a", "size")) end},
  {"a mode change", function() params:set("v1_seq_gate", 1) end},
  {"a source switch", function(_, S) params:set("v1_source", S.constants.SOURCE_SYNTH + 2) end, nil, "sync"},
  {"a type switch", function() params:set("v1_type", 2) end, nil, "sync"},
  {"an empty pass", function(context, S)
    empty_pass(context, S, function()
      assert_equal(S.lib.sequencer.held_value(1, "position"), 15, "an empty pass: the value stays until the wrap")
      assert_sends(context, "bufPos", {}, "an empty pass: nothing sent before the wrap")
    end)
  end},
  {"a length cut", function() params:set("v1_seq_length", 2) end},
}

test("a value ends at a stop, a hand edit, a replace, a target change, a mode change, a source switch, a type switch, an empty pass, a length cut", function()
  for _, case in ipairs(ENDS) do
    local context, S = setup()
    holding(context, S)
    case[2](context, S)
    local own = case[3] or OWN_POSITION
    local values = sent(context, "bufPos")
    if case[4] == "sync" then
      -- the switch's own end sends the voice's position, and the voice's
      -- sync that follows sends every value again
      assert_true(#values >= 1, case[1] .. ": the position sent")
      assert_near(values[1], own, 1e-9, case[1] .. ": first the param's own value")
      assert_near(values[#values], own, 1e-9, case[1] .. ": and last")
    elseif case[4] == "under" then
      assert_sends(context, "bufPos", {1, own}, case[1] .. ": the param's own value sent again, once")
    else
      assert_sends(context, "bufPos", {own}, case[1] .. ": the param's own value sent again, once")
    end
    assert_equal(S.lib.sequencer.held_value(1, "position"), nil, case[1] .. ": nothing held")
    assert_near(S.lib.engine_sync.engine_base_value("v1_buf_pos"), own, 1e-12, case[1] .. ": no override")
    pattern_clock_stop()
  end
end)

test("a hand edit under a lock does not come back when the lock ends", function()
  local context, S = setup()
  set_step(S, 1, {va = 15}); set_step(S, 2, {pos = 0.6}); set_step(S, 3)
  pattern_clock_start(); tick(context, S)
  assert_near(S.lib.engine_sync.engine_base_value("v1_buf_pos"), 0.6, 1e-12, "the lock holds step 2")
  delta_with_detent("v1_buf_pos", 1)
  assert_equal(S.lib.sequencer.held_value(1, "position"), nil, "the hand edit ends the value")
  context.clear_engine_calls()
  tick(context, S)
  assert_sends(context, "bufPos", {}, "the lock's end sends nothing: the edit ended its override")
  assert_near(S.lib.engine_sync.engine_base_value("v1_buf_pos"), OWN_POSITION + 0.01, 1e-12, "the hand's value plays")
  pattern_clock_stop()
end)

test("a lock wins for its step and the value comes back", function()
  local context, S = setup()
  set_step(S, 1, {va = 15}); set_step(S, 2, {pos = 0.6}); set_step(S, 3); set_step(S, 4)
  context.clear_engine_calls()
  pattern_clock_start()
  for _ = 2, 4 do tick(context, S) end
  assert_sends(context, "bufPos", {1, 0.6, 1}, "the value, the lock, the value again")
  assert_equal(S.lib.sequencer.held_value(1, "position"), 15, "still held")
  pattern_clock_stop()
end)

test("a length cut past a lock but not past the value brings the value back", function()
  local context, S = setup()
  set_step(S, 1, {va = 15}); set_step(S, 5, {pos = 0.6})
  pattern_clock_start()
  for _ = 2, 5 do tick(context, S) end
  context.clear_engine_calls()
  params:set("v1_seq_length", 3)
  assert_sends(context, "bufPos", {1}, "the lock ends and the value comes back, in one send")
  assert_equal(S.lib.sequencer.held_value(1, "position"), 15, "still held")
  pattern_clock_stop()
end)

test("where A and B name one target, A's value is set and B's is not", function()
  local context, S = setup()
  params:set("v1_seq_move_a", option_index("v1_seq_move_a", "position"))
  params:set("v1_seq_move_b", option_index("v1_seq_move_b", "position"))
  set_step(S, 1, {va = 15, vb = 1})
  context.clear_engine_calls()
  pattern_clock_start()
  assert_sends(context, "bufPos", {1}, "A's value alone")
  assert_equal(S.lib.sequencer.held_value(1, "position"), 15, "A's level is held")
  pattern_clock_stop()
  -- B on its own target sets it
  params:set("v1_seq_move_b", option_index("v1_seq_move_b", "size"))
  context.clear_engine_calls()
  pattern_clock_start()
  assert_sends(context, "grainSize", {params:lookup_param("v1_grain_size").controlspec.minval}, "B's size")
  assert_equal(S.lib.sequencer.held_value(1, "size"), 1, "B's level is held")
  pattern_clock_stop()
end)

test("a hit a chance holds back sets nothing, and the last value holds", function()
  local context, S = setup()
  set_step(S, 1, {va = 15}); set_step(S, 2, {va = 1, prob = 0})
  context.clear_engine_calls()
  pattern_clock_start(); tick(context, S)
  assert_sends(context, "bufPos", {1}, "step 2 held back")
  assert_equal(S.lib.sequencer.held_value(1, "position"), 15, "step 1's value holds")
  pattern_clock_stop()
end)

-- Move and the level ------------------------------------------------------

test("a level is a strength in every mode", function()
  local context, S = setup()
  local seq = S.lib.sequencer
  params:set("v1_seq_gate", option_index("v1_seq_gate", "move"))
  seq.set_level(1, 1, 5); seq.set_step_attr(1, 1, "va", 7)
  context.clear_engine_calls()
  pattern_clock_start(); pattern_clock_stop()
  local retriggers = context.calls_named("retrigger")
  assert_equal(#retriggers, 1, "one hit")
  assert_near(retriggers[1].args[2], 0, 1e-12, "move: velocity 0 to the engine")
  params:set("v1_seq_gate", option_index("v1_seq_gate", "pulse"))
  context.clear_engine_calls()
  pattern_clock_start(); pattern_clock_stop()
  retriggers = context.calls_named("retrigger")
  assert_near(retriggers[1].args[2], 5 / 15, 1e-12, "pulse: velocity 5/15")
  assert_equal(seq.step_attr(1, 1, "va"), 7, "its va untouched")
  assert_equal(S.patterns[1][1], 5, "and its level")
end)

test("in move a tapped step takes a random value A and keeps one it has", function()
  local _, S = setup()
  local seq = S.lib.sequencer
  params:set("v1_seq_gate", option_index("v1_seq_gate", "move"))
  math.randomseed(7)
  local expected = math.random(1, S.constants.MAX_STEP_LEVEL)
  math.randomseed(7)
  toggle_pattern_step(1, 3)
  assert_equal(S.patterns[1][3], S.constants.MAX_STEP_LEVEL, "the step on at full strength")
  assert_equal(seq.step_attr(1, 3, "va"), expected, "a random value A")
  seq.set_step_attr(1, 4, "va", 9)
  toggle_pattern_step(1, 4)
  assert_equal(seq.step_attr(1, 4, "va"), 9, "a step's own value A is kept")
  toggle_pattern_step(1, 3)
  assert_equal(S.patterns[1][3], 0, "off again")
  assert_equal(seq.step_attr(1, 3, "va"), expected, "turning it off keeps its value")
  params:set("v1_seq_gate", option_index("v1_seq_gate", "accent"))
  toggle_pattern_step(1, 6)
  assert_equal(seq.step_attr(1, 6, "va"), nil, "outside move a tap gives no value")
end)

test("choosing move by hand gives the set steps values; the param's action does not", function()
  local _, S = setup()
  local seq = S.lib.sequencer
  params:set("v1_seq_length", 8)
  seq.set_level(1, 1, 15); seq.set_level(1, 5, 15); seq.set_step_attr(1, 5, "va", 3); seq.set_level(1, 14, 15)
  params:set("v1_seq_gate", option_index("v1_seq_gate", "move"))
  assert_equal(seq.step_attr(1, 1, "va"), nil, "the param's action gives none")
  params:set("v1_seq_gate", option_index("v1_seq_gate", "accent"))
  math.randomseed(11)
  local expected = math.random(1, S.constants.MAX_STEP_LEVEL)
  math.randomseed(11)
  S.lib.lanes.choose_mode(1, "move")
  assert_equal(seq.step_mode(1), "move", "the mode is move")
  assert_equal(seq.step_attr(1, 1, "va"), expected, "step 1 takes a random value")
  assert_equal(seq.step_attr(1, 5, "va"), 3, "step 5 keeps its own")
  assert_equal(seq.step_attr(1, 2, "va"), nil, "an empty step takes none")
  assert_equal(seq.step_attr(1, 14, "va"), nil, "a step past the length takes none")
  S.lib.lanes.choose_mode(1, "pulse")
  assert_equal(seq.step_mode(1), "pulse", "the other modes are set alone")
  S.lib.lanes.choose_mode(1, "loud")
  assert_equal(seq.step_mode(1), "pulse", "no such mode: nothing")
end)

test("choosing cutoff by hand opens a closed filter, and a recall that sets cutoff does not", function()
  local _, S = setup()
  local lanes = S.lib.lanes
  assert_equal(params:get("v1_filter_mix"), 0, "the voice filter is out")
  lanes.choose_target(1, "a", "cutoff")
  assert_equal(lanes.target(1, "a"), "cutoff", "A is cutoff")
  assert_equal(params:get("v1_filter_mix"), 1, "the filter mix set to 1")
  assert_equal(S.lib.ui_flash.text("header"), "filter on", "and said so")
  params:set("v1_filter_mix", 0.5)
  lanes.choose_target(1, "b", "cutoff")
  assert_equal(params:get("v1_filter_mix"), 0.5, "an open filter is left alone")
  lanes.choose_target(1, "b", "off")
  assert_equal(params:get("v1_seq_move_b"), 1, "B off")
  lanes.choose_target(1, "a", "nowhere")
  assert_equal(lanes.target(1, "a"), "cutoff", "no such target: nothing")
  -- a scene saved on cutoff with a closed filter
  params:set("v1_filter_mix", 0)
  capture_scene(1)
  params:set("v1_seq_move_a", 1)
  S.lib.ui_flash.start("header", nil)
  recall_scene(1)
  assert_equal(lanes.target(1, "a"), "cutoff", "the recall sets cutoff")
  assert_equal(params:get("v1_filter_mix"), 0, "and leaves the stored mix of 0")
  assert_equal(S.lib.ui_flash.text("header"), nil, "with no flash")
end)

test("hit_light: step_brightness in every mode but move; in move a set step's value A, or 4", function()
  local context, S = setup()
  local seq, lanes = S.lib.sequencer, S.lib.lanes
  params:set("v1_seq_length", 8)
  seq.set_level(1, 2, 9); seq.set_step_attr(1, 2, "va", 3)
  seq.set_level(1, 3, 6)
  seq.set_level(1, 12, 9); seq.set_step_attr(1, 12, "va", 3)
  for _, mode in ipairs({"accent", "gate", "pulse"}) do
    params:set("v1_seq_gate", option_index("v1_seq_gate", mode))
    for step = 1, S.constants.PATTERN_LENGTH do
      assert_equal(lanes.hit_light(1, step), step_brightness(1, step), mode .. ": step " .. step)
    end
  end
  params:set("v1_seq_gate", option_index("v1_seq_gate", "move"))
  assert_equal(lanes.hit_light(1, 2), 3, "move: a set step at its value A")
  assert_equal(lanes.hit_light(1, 3), 4, "move: a set step with none at 4")
  assert_equal(lanes.hit_light(1, 1), 0, "move: an empty step dark")
  assert_equal(lanes.hit_light(1, 12), step_brightness(1, 12), "move: past the length as every mode")
  pattern_clock_start()
  tick(context, S)
  assert_equal(lanes.hit_light(1, 2), step_brightness(1, 2), "move: the playhead as every mode")
  pattern_clock_stop()
  assert_equal(lanes.hit_light(h.voice_count() + 1, 2), 0, "no voice: dark")
  assert_equal(lanes.hit_light(1, 0), 0, "no step: dark")
end)

-- Pitch as a value (package 2b, design section 2, The values, Locks
-- stay, the ends for pitch) ----------------------------------------------

local C4 = 261.6255653005986
local OWN_FREQ = 220
local VALUE_FREQ = OWN_FREQ * 2 ^ (7 / 12)  -- level 15 with the scale off: seven semitones up
local MIDI_NOTE = 62  -- 293.66 Hz: apart from the value's 329.63 Hz (fix round 1, finding 1)
local MIDI_FREQ = 440 * 2 ^ ((MIDI_NOTE - 69) / 12)

-- Voice 1 made a synth voice at 220 Hz (the scale off: a degree is a semitone)
local function synth_voice(S)
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  params:set("v1_freq", OWN_FREQ)
end

local function base_value(id) return local_value("S").lib.engine_sync.engine_base_value(id) end

-- The values setVoiceParam(0, name, ...) sent, in order
local function voice_sent(context, name)
  local values = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == "setVoiceParam" and call.args[1] == 0 and call.args[2] == name then values[#values + 1] = call.args[3] end
  end
  return values
end

-- A MIDI key on voice 1's channel (the plain per-voice mode), down or up
local function midi_key(context, kind)
  context.midi.send(1, {type = kind, note = MIDI_NOTE, vel = kind == "note_on" and 100 or 0, ch = 1})
end

-- A step output that keeps each hit's event
local function probe(S)
  local events = {}
  S.register_step_output({name = "probe", play = function(event)
    local copy = {}
    for key, value in pairs(event) do copy[key] = value end
    events[#events + 1] = copy
  end})
  return events
end

test("pitch level 8 is the voice's own pitch, 15 seven degrees up, 1 seven down", function()
  local context, S = setup()
  params:set("scale", 2); params:set("root", 1)  -- C major: seven degrees are an octave
  params:set("v2_freq", C4)
  params:set("v3_source", S.constants.SOURCE_INPUT)
  local cases = {
    {"a synth voice", 2, "v2_freq", C4, "setVoiceParam", "freq"},
    {"a buffer voice", 1, "v1_buf_rate", 1, "setGrainParam", "bufRate"},
    {"an input voice", 3, "v3_grain_pitch", 1, "setGrainParam", "pitchShift"},
  }
  for _, case in ipairs(cases) do
    local what, voice, param_id, own = case[1], case[2], case[3], case[4]
    for _, level in ipairs({{8, 1}, {15, 2}, {1, 0.5}}) do
      local id, value = S.lib.lanes.value(voice, "pitch", level[1])
      assert_equal(id, param_id, what .. ": pitch moves " .. param_id)
      assert_near(value, own * level[2], 1e-6, what .. ": level " .. level[1])
    end
    local _, value = S.lib.lanes.value(voice, "pitch", 10)
    assert_near(value, own * 2 ^ (4 / 12), 1e-6, what .. ": level 10, two degrees up: E, four semitones")
    -- a step's value plays it through the note path (A set to pitch: auto
    -- is position on a buffer voice)
    params:set("v" .. voice .. "_seq_move_a", option_index("v1_seq_move_a", "pitch"))
    S.lib.sequencer.set_level(voice, 1, 15); S.lib.sequencer.set_step_attr(voice, 1, "va", 15)
    context.clear_engine_calls()
    pattern_clock_start()
    assert_equal(S.lib.sequencer.held_value(voice, "pitch"), 15, what .. ": the value held")
    assert_near(S.lib.engine_sync.engine_base_value(param_id), own * 2, 1e-6, what .. ": and played")
    assert_near(params:get(param_id), own, 1e-9, what .. ": the stored value stays")
    local last
    for _, call in ipairs(context.engine_calls) do
      if call.name == case[5] and call.args[1] == voice - 1 and call.args[2] == case[6] then last = call.args[3] end
    end
    assert_near(last, own * 2, 1e-6, what .. ": " .. case[6] .. " sent")
    pattern_clock_stop()
    assert_near(S.lib.engine_sync.engine_base_value(param_id), own, 1e-9, what .. ": the stop ends it")
  end
end)

test("a pitch value resends scaleNote once", function()
  local context, S = setup()
  synth_voice(S)
  set_step(S, 1, {va = 15}); set_step(S, 2); set_step(S, 3)
  -- fix round 1 (finding 3): a second value, a chord over it and its
  -- end, a pitch lock and its end (on the grain pitch: freq stays)
  set_step(S, 4, {va = 10}); set_step(S, 5, {notes = {2}}); set_step(S, 6)
  set_step(S, 7, {pitch = 1.5}); set_step(S, 8)
  context.clear_engine_calls()
  pattern_clock_start()
  tick(context, S); tick(context, S)
  assert_equal(S.lib.sequencer.sounding_step(1), 3, "step 3 played")
  assert_sends(context, "scaleNote", {57 + 7}, "the value's note, once")
  local steps = {
    {4, {57 + 2}, "a second value moves it, once"},
    {5, {57 + 4}, "a chord's note 2 on the value: degree 4, once"},
    {6, {57 + 2}, "the chord ends: the value comes back, once"},
    {7, {}, "a pitch lock leaves freq: nothing"},
    {8, {}, "and its end: nothing"},
  }
  for _, case in ipairs(steps) do
    context.clear_engine_calls()
    tick(context, S)
    assert_equal(S.lib.sequencer.sounding_step(1), case[1], "step " .. case[1] .. " played")
    assert_sends(context, "scaleNote", case[2], "step " .. case[1] .. ": " .. case[3])
  end
  context.clear_engine_calls()
  pattern_clock_stop()
  assert_sends(context, "scaleNote", {57}, "the stop: the voice's own, once")
end)

test("a pitch value gives way to a held MIDI key and comes back at the next hit that sets it", function()
  local context, S = setup()
  synth_voice(S)
  set_step(S, 1, {va = 15}); set_step(S, 2, {va = 12}); set_step(S, 3); set_step(S, 4, {va = 15})
  pattern_clock_start()
  assert_near(base_value("v1_freq"), VALUE_FREQ, 1e-6, "step 1's value plays")
  midi_key(context, "note_on")
  assert_equal(S.lib.sequencer.held_value(1, "pitch"), nil, "the key: the value gives way")
  assert_near(base_value("v1_freq"), MIDI_FREQ, 1e-6, "and the key's pitch plays")
  tick(context, S)
  assert_equal(S.lib.sequencer.held_value(1, "pitch"), nil, "step 2's value, under the key: not set")
  assert_near(base_value("v1_freq"), MIDI_FREQ, 1e-6, "the key's pitch plays on")
  midi_key(context, "note_off")
  tick(context, S)
  assert_equal(S.lib.sequencer.held_value(1, "pitch"), nil, "the key up, a step without a value: nothing comes back")
  assert_near(base_value("v1_freq"), MIDI_FREQ, 1e-6, "the latched key's pitch, now the voice's own")
  tick(context, S)
  assert_equal(S.lib.sequencer.held_value(1, "pitch"), 15, "step 4 sets it again")
  assert_near(base_value("v1_freq"), MIDI_FREQ * 2 ^ (7 / 12), 1e-6, "seven degrees from the voice's own pitch")
  pattern_clock_stop()
end)

test("on a synth voice a pitch lock adds to a pitch value; on an input voice it wins", function()
  -- a synth voice: the value moves freq, the lock the grain pitch, and the hit's pitch is both
  local context, S = setup()
  synth_voice(S)
  local events = probe(S)
  set_step(S, 1, {va = 15, pitch = 1.5}); set_step(S, 2)
  pattern_clock_start()
  assert_near(base_value("v1_freq"), VALUE_FREQ, 1e-6, "synth: the value on freq")
  assert_near(base_value("v1_grain_pitch"), 1.5, 1e-9, "synth: the lock on the grain pitch")
  assert_near(events[1].pitches[1], 57 + 7 + 12 * math.log(1.5) / math.log(2), 1e-6, "synth: the hit's pitch adds both")
  tick(context, S)
  assert_near(base_value("v1_freq"), VALUE_FREQ, 1e-6, "synth: the value stays")
  assert_near(base_value("v1_grain_pitch"), 1, 1e-9, "synth: the lock ends")
  assert_near(events[2].pitches[1], 57 + 7, 1e-6, "synth: the next hit at the value")
  pattern_clock_stop()
  -- an input voice: one param, the lock wins for its step and the value comes back
  context, S = setup()
  params:set("v1_source", S.constants.SOURCE_INPUT)
  events = probe(S)
  set_step(S, 1, {va = 15, pitch = 1.5}); set_step(S, 2)
  pattern_clock_start()
  assert_equal(S.lib.sequencer.held_value(1, "pitch"), 15, "input: the value held")
  assert_near(base_value("v1_grain_pitch"), 1.5, 1e-9, "input: the lock wins for its step")
  assert_near(events[1].pitches[1], 60 + 12 * math.log(1.5) / math.log(2), 1e-6, "input: the hit's pitch is the lock's")
  tick(context, S)
  assert_near(base_value("v1_grain_pitch"), 2 ^ (7 / 12), 1e-9, "input: the lock ends and the value comes back")
  assert_near(events[2].pitches[1], 60 + 7, 1e-6, "input: the next hit at the value")
  pattern_clock_stop()
end)

-- The machine `held values` (docs/notes/lua/lanes.md, Machines) ----------

-- Voice 1 (a buffer voice, position 0.2, length 8) at step 4 with the
-- patterns playing: steps 1 to 4 set, and (a value) step 3's value 15, or
-- (a lock over a value) that and step 4's position lock 0.6
-- (package 2b) a pitch value: voice 1 a synth voice at 220 Hz instead,
-- step 3's value 15 (seven semitones up); a held key: that, then a MIDI
-- key down on voice 1 (note 64), to which the value gives way
local function enter(context, kind)
  local S = local_value("S")
  S.buffers[1].seconds, S.buffers[2].seconds = 8, 8
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v1_buf_pos", OWN_POSITION)
  local pitch = kind == "pitch" or kind == "key"
  if pitch then synth_voice(S) end
  params:set("v1_seq_length", 8)
  set_step(S, 1); set_step(S, 2)
  set_step(S, 3, kind ~= "none" and {va = 15} or nil)
  set_step(S, 4, kind == "lock" and {pos = 0.6} or nil)
  pattern_clock_start()
  for _ = 2, 4 do tick(context, S) end
  if kind == "key" then midi_key(context, "note_on") end
  context.clear_engine_calls()
end

-- The next step (5) set with these attributes, then played
local function next_hit(attrs)
  return function(context)
    local S = local_value("S")
    set_step(S, 5, attrs)
    tick(context, S)
  end
end

local function last_position(context)
  local values = sent(context, "bufPos")
  return values[#values]
end

local function base_position() return local_value("S").lib.engine_sync.engine_base_value("v1_buf_pos") end

-- The row's checks: the position the engine was sent last (nil: none sent)
-- and the one it now starts from
local function sends(expected, base)
  return function(context)
    local last = last_position(context)
    if expected == nil then
      assert_equal(last, nil, "no bufPos sent")
    else
      assert_near(last, expected, 1e-9, "bufPos " .. expected .. " sent last")
    end
    assert_near(base_position(), base or expected, 1e-9, "the engine starts from " .. tostring(base or expected))
  end
end

local EDITED = OWN_POSITION + 0.01

-- (package 2b) The row's checks for a synth voice: the freq the engine was
-- sent last (nil: none sent) and the one it now plays
local function freq_sends(expected, base)
  return function(context)
    local values = voice_sent(context, "freq")
    local last = values[#values]
    if expected == nil then
      assert_equal(last, nil, "no freq sent")
    else
      assert_near(last, expected, 1e-6, "freq " .. expected .. " sent last")
    end
    assert_near(base_value("v1_freq"), base or expected, 1e-6, "the engine plays " .. tostring(base or expected))
  end
end

-- Whether a MIDI key down holds voice 1's own note (read without
-- S.lib.midi_in.keeps_own, which forgets a latched one)
local function key_holds_own()
  local S = local_value("S")
  local own = S.lib.notes.slots(1)[1]
  return own ~= nil and own.slot == 1 and own.held and own.owner == "midi" and S.midi_state.held[1][own.key] == true
end

-- A chord over a pitch value: its first note, note 0, at the value (it is
-- the voice's own) and its second, note 2, two degrees above the value
local function chord_on_value(context)
  freq_sends(VALUE_FREQ)(context)
  local ons = context.calls_named("noteOn")
  assert_equal(#ons, 1, "one extra note")
  assert_near(ons[1].args[3], 57 + 7 + 2, 1e-9, "note 2 on the value")
end

-- A chord under a held key: neither note is the voice's own, and freq is the key's
local function chord_under_key(context)
  freq_sends(nil, MIDI_FREQ)(context)
  assert_equal(local_value("S").lib.sequencer.held_value(1, "pitch"), nil, "no value")
end

-- Fix round 1 (finding 2): a hand edit of freq (an encoder's detent): the
-- edit's own action sends under any override, then its touch ends it, so
-- the stored freq, moved off where it was, is sent last and played
local function freq_edited(from)
  return function(context)
    local stored = params:get("v1_freq")
    assert_true(math.abs(stored - from) > 1e-3, "the detent moved freq off " .. from)
    freq_sends(stored)(context)
    assert_equal(local_value("S").lib.sequencer.held_value(1, "pitch"), nil, "no value")
  end
end

-- Fix round 1 (finding 4): a pitch lock on a synth voice is on the grain
-- pitch: freq stays where check leaves it, and the lock is played
local function pitch_locked(check)
  return function(context)
    check(context)
    assert_near(base_value("v1_grain_pitch"), 1.5, 1e-9, "the grain pitch lock plays")
  end
end

-- Fix round 1 (finding 3): the row's check, then the lock followed to its
-- end (a hit without), which brings no value back: 0.2 is sent and played
local function then_lock_ends(check)
  return function(context)
    check(context)
    next_hit(nil)(context)
    assert_near(last_position(context), OWN_POSITION, 1e-9, "the lock's end sends the voice's own position")
    assert_near(base_position(), OWN_POSITION, 1e-9, "and the engine starts from it")
  end
end

h.transition_table({
  name = "held values",
  notes = {"docs/notes/lua/lanes.md", "held values"},
  states = {
    ["none"] = function(context) enter(context, "none") end,
    ["a value"] = function(context) enter(context, "value") end,
    ["a lock over a value"] = function(context) enter(context, "lock") end,
    ["a pitch value"] = function(context) enter(context, "pitch") end,
    ["a held key"] = function(context) enter(context, "key") end,
  },
  events = {
    ["hit with a value"] = next_hit({va = 8}),
    ["hit without"] = next_hit(nil),
    ["hit with a lock"] = next_hit({pos = 0.6}),
    ["held back"] = next_hit({va = 8, prob = 0}),
    ["stop"] = function() pattern_clock_stop() end,
    ["hand edit"] = function() delta_with_detent("v1_buf_pos", 1) end,
    ["replace"] = function() local_value("S").lib.sequencer.replace_pattern(1, {15, 15, 15, 15}) end,
    ["target change"] = function() params:set("v1_seq_move_a", option_index("v1_seq_move_a", "size")) end,
    ["mode change"] = function() params:set("v1_seq_gate", 1) end,
    ["source switch"] = function() params:set("v1_source", local_value("S").constants.SOURCE_SYNTH + 2) end,
    ["type switch"] = function() params:set("v1_type", 2) end,
    ["empty pass"] = function(context) empty_pass(context, local_value("S")) end,
    ["length cut"] = function() params:set("v1_seq_length", 2) end,
    ["MIDI key"] = function(context) midi_key(context, "note_on") end,
    ["MIDI release"] = function(context) midi_key(context, "note_off") end,
    ["chord"] = next_hit({notes = {0, 2}}),
    ["freq edit"] = function() delta_with_detent("v1_freq", 1) end,
    ["hit with a pitch lock"] = next_hit({pitch = 1.5}),
  },
  state_of = function()
    local S = local_value("S")
    local level = S.lib.sequencer.held_value(1, "position")
    if level ~= nil then
      local _, value = S.lib.lanes.value(1, "position", level)
      return math.abs(base_position() - value) < 1e-9 and "a value" or "a lock over a value"
    end
    local pitch = S.lib.sequencer.held_value(1, "pitch")
    if pitch ~= nil then
      local _, value = S.lib.lanes.value(1, "pitch", pitch)
      return math.abs(base_value("v1_freq") - value) < 1e-6 and "a pitch value" or "a pitch value, not heard"
    end
    return key_holds_own() and "a held key" or "none"
  end,
  rows = {
    {"none", "hit with a value", "a value", check = sends(0.5)},
    {"none", "hit without", "none", check = sends(nil, OWN_POSITION)},
    {"none", "hit with a lock", "none", check = sends(0.6)},
    {"none", "held back", "none", check = sends(nil, OWN_POSITION)},
    {"none", "stop", "none", check = sends(nil, OWN_POSITION)},
    {"none", "hand edit", "none", check = sends(EDITED)},
    {"none", "replace", "none", check = sends(nil, OWN_POSITION)},
    {"none", "target change", "none", check = sends(nil, OWN_POSITION)},
    {"none", "mode change", "none", check = sends(nil, OWN_POSITION)},
    {"none", "source switch", "none", check = sends(OWN_POSITION)},
    {"none", "type switch", "none", check = sends(OWN_POSITION)},
    {"none", "empty pass", "none", check = sends(nil, OWN_POSITION)},
    {"none", "length cut", "none", check = sends(nil, OWN_POSITION)},
    {"a value", "hit with a value", "a value", check = sends(0.5)},
    {"a value", "hit without", "a value", check = sends(nil, 1)},
    {"a value", "hit with a lock", "a lock over a value", check = sends(0.6)},
    {"a value", "held back", "a value", check = sends(nil, 1)},
    {"a value", "stop", "none", check = sends(OWN_POSITION)},
    {"a value", "hand edit", "none", check = sends(EDITED)},
    {"a value", "replace", "none", check = sends(OWN_POSITION)},
    {"a value", "target change", "none", check = sends(OWN_POSITION)},
    {"a value", "mode change", "none", check = sends(OWN_POSITION)},
    {"a value", "source switch", "none", check = sends(OWN_POSITION)},
    {"a value", "type switch", "none", check = sends(OWN_POSITION)},
    {"a value", "empty pass", "none", check = sends(OWN_POSITION)},
    {"a value", "length cut", "none", check = sends(OWN_POSITION)},
    {"a lock over a value", "hit with a value", "a value", check = sends(0.5)},
    {"a lock over a value", "hit without", "a value", check = sends(1)},
    {"a lock over a value", "hit with a lock", "a lock over a value", check = sends(0.6)},
    {"a lock over a value", "held back", "a lock over a value", check = sends(nil, 0.6)},
    {"a lock over a value", "stop", "none", check = sends(OWN_POSITION)},
    {"a lock over a value", "hand edit", "none", check = sends(EDITED)},
    {"a lock over a value", "replace", "none", check = sends(OWN_POSITION)},
    {"a lock over a value", "target change", "none", check = then_lock_ends(sends(nil, 0.6))},
    {"a lock over a value", "mode change", "none", check = then_lock_ends(sends(nil, 0.6))},
    {"a lock over a value", "source switch", "none", check = then_lock_ends(sends(0.6))},
    {"a lock over a value", "type switch", "none", check = then_lock_ends(sends(0.6))},
    {"a lock over a value", "empty pass", "none", check = sends(OWN_POSITION)},
    {"a lock over a value", "length cut", "none", check = sends(OWN_POSITION)},
    -- package 2b: a held MIDI key, its release, a chord over a value
    {"none", "MIDI key", "a held key", check = sends(nil, OWN_POSITION)},
    {"none", "MIDI release", "none", check = sends(nil, OWN_POSITION)},
    {"none", "chord", "none", check = sends(nil, OWN_POSITION)},
    {"a value", "MIDI key", "a value", check = sends(nil, 1)},
    {"a value", "MIDI release", "a value", check = sends(nil, 1)},
    {"a value", "chord", "a value", check = sends(nil, 1)},
    {"a lock over a value", "MIDI key", "a lock over a value", check = sends(nil, 0.6)},
    {"a lock over a value", "MIDI release", "a lock over a value", check = sends(nil, 0.6)},
    {"a lock over a value", "chord", "a value", check = sends(1)},
    {"a pitch value", "hit with a value", "a pitch value", check = freq_sends(OWN_FREQ)},
    {"a pitch value", "hit without", "a pitch value", check = freq_sends(nil, VALUE_FREQ)},
    {"a pitch value", "hit with a lock", "a pitch value", check = freq_sends(nil, VALUE_FREQ)},
    {"a pitch value", "held back", "a pitch value", check = freq_sends(nil, VALUE_FREQ)},
    {"a pitch value", "stop", "none", check = freq_sends(OWN_FREQ)},
    {"a pitch value", "hand edit", "a pitch value", check = freq_sends(nil, VALUE_FREQ)},
    {"a pitch value", "replace", "none", check = freq_sends(OWN_FREQ)},
    {"a pitch value", "target change", "none", check = freq_sends(OWN_FREQ)},
    {"a pitch value", "mode change", "none", check = freq_sends(OWN_FREQ)},
    {"a pitch value", "source switch", "none", check = freq_sends(OWN_FREQ)},
    {"a pitch value", "type switch", "none", check = freq_sends(OWN_FREQ)},
    {"a pitch value", "empty pass", "none", check = freq_sends(OWN_FREQ)},
    {"a pitch value", "length cut", "none", check = freq_sends(OWN_FREQ)},
    {"a pitch value", "MIDI key", "a held key", check = freq_sends(MIDI_FREQ)},
    {"a pitch value", "MIDI release", "a pitch value", check = freq_sends(nil, VALUE_FREQ)},
    {"a pitch value", "chord", "a pitch value", check = chord_on_value},
    {"a held key", "hit with a value", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "hit without", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "hit with a lock", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "held back", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "stop", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "hand edit", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "replace", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "target change", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "mode change", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "source switch", "a held key", check = freq_sends(MIDI_FREQ)},
    {"a held key", "type switch", "a held key", check = freq_sends(MIDI_FREQ)},
    {"a held key", "empty pass", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "length cut", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "MIDI key", "a held key", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "MIDI release", "none", check = freq_sends(nil, MIDI_FREQ)},
    {"a held key", "chord", "a held key", check = chord_under_key},
    -- fix round 1 (findings 2 and 4): a hand edit of freq, a pitch lock
    {"none", "freq edit", "none", check = sends(nil, OWN_POSITION)},
    {"a value", "freq edit", "a value", check = sends(nil, 1)},
    {"a lock over a value", "freq edit", "a lock over a value", check = sends(nil, 0.6)},
    {"a pitch value", "freq edit", "none", check = freq_edited(VALUE_FREQ)},
    {"a held key", "freq edit", "a held key", check = freq_edited(MIDI_FREQ)},
    {"none", "hit with a pitch lock", "none", check = sends(nil, OWN_POSITION)},
    {"a value", "hit with a pitch lock", "a value", check = sends(nil, 1)},
    {"a lock over a value", "hit with a pitch lock", "a value", check = sends(1)},
    {"a pitch value", "hit with a pitch lock", "a pitch value", check = pitch_locked(freq_sends(nil, VALUE_FREQ))},
    {"a held key", "hit with a pitch lock", "a held key", check = pitch_locked(freq_sends(nil, MIDI_FREQ))},
  },
})

end

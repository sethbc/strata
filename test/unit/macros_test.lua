-- test/unit/macros_test.lua
-- The macros (lib/macros.lua, S.lib.macros, 3.4 design §4): the sixteen
-- params macro_1..macro_16 in four banks, each moving up to eight targets
-- between their min and max, applied by one clock at most 30 times a
-- second inside the deferrable budget, set silently by scenes and morph;
-- an LFO on a macro; learn; the shown bank; the LFO destinations and
-- modulation sources; and the targets' storage in scenes, PSETs and the
-- live file
-- Run alone: lua test/run.lua macros

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function loaded(options)
  local context = load_strata(options); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.macros
end

-- Long enough for the macro clock to apply what waits: its next tick, at
-- most 1/30 s after the last apply
local function settle(context) context.clock.run_for(0.05) end

-- The value the engine has for a param, LFO offsets and extras included
local function engine_value(S, id)
  return S.lib.engine_sync.with_lfo_offsets(id, params:get(id))
end

local function data_dir_name(context) return context.data_dir:match("([^/]+)/$") end

local function printed_with(context, text)
  for _, line in ipairs(context.printed) do
    if line:find(text, 1, true) then return line end
  end
  return nil
end

local function target_count(block)
  local count = 0
  for _, row in pairs(block or {}) do
    for _ in pairs(row) do count = count + 1 end
  end
  return count
end

test("the macro params are a group of sixteen controls, 0-1 at 0, shown in percent", function()
  local context, S, macros = loaded()
  assert_true(macros ~= nil, "S.lib.macros is the module's table")
  local group = params:lookup_param("strata_macros")
  assert_equal(group.t, params.tGROUP, "strata_macros is a group")
  assert_equal(group.n, 16, "of sixteen params")
  local index = params.lookup["strata_macros"]
  for m = 1, 16 do
    local id = "macro_" .. m
    assert_equal(params.params[index + m].id, id, "macro " .. m .. " in order")
    assert_equal(params:lookup_param(id).t, params.tCONTROL, id .. " is a control")
    local low, high = param_range(id)
    assert_equal(low, 0); assert_equal(high, 1)
    assert_equal(params:get(id), 0, id .. " starts at 0")
  end
  params:set("macro_3", 0.42)
  assert_equal(params:string("macro_3"), "42 %", "shown in whole percents")
  for m = 1, 16 do
    for k = 1, 8 do
      local target = macros.targets(m)[k]
      assert_equal(target.id, "", "no targets by default: macro " .. m .. " row " .. k)
      assert_equal(target.min, 0); assert_equal(target.max, 1)
    end
    assert_equal(S.macros[m].targets[1].id, "", "S.macros holds the rows")
  end
end)

test("a macro sets each target between its min and max", function()
  local context, S, macros = loaded()
  macros.set_target(1, 1, "reverb_mix", 0.2, 0.9)
  params:set("macro_1", 0.5)
  assert_near(params:get("reverb_mix"), 0.3, 1e-9, "the apply waits for the clock's next tick")
  settle(context)
  assert_near(params:get("reverb_mix"), 0.55, 1e-9, "0.2 + 0.5 x 0.7")
  macros.set_target(1, 1, "reverb_mix", 0.9, 0.2)
  params:set("macro_1", 0.25); settle(context)
  -- 0.9 - 0.25 x 0.7 = 0.725, stored on reverb_mix's 0.01 grid
  assert_near(params:get("reverb_mix"), util.round(0.725, 0.01), 1e-9, "min above max inverts")
  macros.set_target(2, 1, "filter_freq", 0, 1)
  params:set("macro_2", 0.5); settle(context)
  assert_near(params:get("filter_freq"), 632.46, 0.1, "along the exponential warp: 20 x 1000 ^ 0.5")
  -- several targets of one macro; a voice's main entry follows its source
  macros.set_target(3, 1, "delay_mix", 0, 1)
  macros.set_target(3, 2, "v2_main", 0, 1)
  params:set("macro_3", 1); settle(context)
  assert_near(params:get("delay_mix"), 1, 1e-9, "target 1 at its max")
  local main = main_param_id(2)
  local low, high = param_range(main)
  assert_near(params:get(main), high, 1e-6, "target 2, v2's main param, at its max")
  params:set("v2_source", S.constants.SOURCE_SYNTH + 1)  -- a buffer: the main param is the position
  params:set("macro_3", 0.25); settle(context)
  assert_near(params:get("v2_buf_pos"), 0.25, 1e-9, "the main entry resolves as the macro applies")
  assert_near(params:get(main), high, 1e-6, "the synth param stays")
  -- a macro with no target does nothing
  local reverb = params:get("reverb_mix")
  params:set("macro_9", 0.7); settle(context)
  assert_near(params:get("reverb_mix"), reverb, 1e-9, "macro 9 has no target")
  -- apply(m) applies at once, for code that must not wait, and drops m's waiting apply
  macros.set_target(4, 1, "reverb_size", 0, 0.5)
  params:set("macro_4", 0.5)
  assert_true(S.macro_clock ~= nil, "the move waits for the clock")
  macros.apply(4)
  assert_near(params:get("reverb_size"), 0.25, 1e-9, "applied at once")
  assert_equal(S.macro_clock, nil, "nothing waits any more")
  macros.apply(17)  -- no macro: nothing happens
end)

test("target ids leave out macros, morph and discrete params", function()
  local context, S, macros = loaded()
  local ids = macros.target_ids()
  local listed = {}
  for index, id in ipairs(ids) do
    assert_equal(listed[id], nil, id .. " listed once")
    listed[id] = index
  end
  for m = 1, 16 do assert_equal(listed["macro_" .. m], nil, "no macro_" .. m) end
  for _, id in ipairs({ "morph", "morph_a", "morph_b" }) do assert_equal(listed[id], nil, "no " .. id) end
  for _, id in ipairs({ "filter_type", "v1_source", "strata_lfo1", "strata_lfo1_dest", "scatter", "tempo" }) do
    assert_equal(listed[id], nil, "no discrete " .. id)
  end
  for _, id in ipairs(ids) do
    if not id:match("^v%d+_main$") then
      assert_equal(params:lookup_param(id).t, params.tCONTROL, id .. " is a control param")
    end
  end
  -- every LFO destination but none and the macros, in their order; then
  -- each LFO's rate and depth; then each matrix routing's depth (1h)
  assert_equal(ids[1], "master_density", "the LFO destinations first, without none")
  assert_equal(ids[11], "reverb_damp")
  assert_equal(ids[12], "v1_main", "a voice's main entry")
  assert_equal(listed["v3_grain_pitch"], 12 + 2 * 8 + 3, "v3 pitch")
  assert_equal(ids[102], "v7_amp", "the registered destinations, to v7 amp")
  assert_equal(ids[103], "strata_lfo1_rate", "then the LFOs' rates and depths")
  assert_equal(ids[104], "strata_lfo1_depth")
  assert_equal(ids[114], "strata_lfo6_depth")
  for k = 1, 16 do assert_equal(listed["matrix_" .. k .. "_depth"], 114 + k, "then routing " .. k .. "'s depth") end
  assert_equal(#ids, 130, "and nothing after them")
  -- set_target takes only these ids
  assert_equal(macros.set_target(1, 1, "macro_2", 0, 1), false, "a macro is no target")
  assert_equal(macros.set_target(1, 1, "morph", 0, 1), false, "nor the morph")
  assert_equal(macros.set_target(1, 1, "filter_type", 0, 1), false, "nor a discrete param")
  assert_equal(macros.targets(1)[1].id, "", "and the row stays empty")
  assert_equal(macros.set_target(1, 1, "reverb_mix", 0, 1), true, "a listed id is taken")
  assert_equal(macros.set_target(17, 1, "reverb_mix", 0, 1), false, "no macro 17")
  assert_equal(macros.set_target(1, 9, "reverb_mix", 0, 1), false, "no row 9")
  -- min and max are clamped to 0..1; "" empties a row
  macros.set_target(1, 2, "delay_mix", -1, 2)
  assert_equal(macros.targets(1)[2].min, 0); assert_equal(macros.targets(1)[2].max, 1)
  macros.set_target(1, 2, "", 0.3, 0.4)
  local row = macros.targets(1)[2]
  assert_equal(row.id, ""); assert_equal(row.min, 0); assert_equal(row.max, 1)
  -- targets(m) is a copy
  macros.targets(1)[1].id = "delay_time"
  assert_equal(macros.targets(1)[1].id, "reverb_mix", "editing the copy changes nothing")
end)

test("one coroutine applies every macro, each at most 30 times a second", function()
  local context, S, macros = loaded()
  macros.set_target(1, 1, "reverb_mix", 0, 1)
  context.clear_engine_calls()
  for step = 1, 100 do
    params:set("macro_1", step / 100)
    context.clock.run_for(0.01)
  end
  settle(context)
  -- each apply moves reverb_mix, whose action sends one setReverb
  local applies = #context.calls_named("setReverb")
  assert_true(applies <= 31, "at most 31 applies in 1 s: " .. applies)
  assert_true(applies >= 25, "and it keeps applying while the macro moves: " .. applies)
  assert_near(params:get("reverb_mix"), 1, 1e-9, "the last value is applied")
  assert_equal(S.macro_clock, nil, "the clock ends once nothing waits")
  -- sixteen macros moving share one clock
  local ids = macros.target_ids()
  for m = 1, 16 do macros.set_target(m, 1, ids[m], 0, 1) end
  local before = clock.pending_count()
  for m = 1, 16 do params:set("macro_" .. m, 0.5) end
  assert_equal(clock.pending_count() - before, 1, "one clock for all sixteen")
  assert_true(S.macro_clock ~= nil, "S.macro_clock")
  settle(context)
  for m = 1, 16 do
    local id = ids[m]:match("^v(%d+)_main$") and main_param_id(tonumber(ids[m]:match("^v(%d+)"))) or ids[m]
    local spec = params:lookup_param(id).controlspec
    assert_near(params:get(id), util.round(spec:map(0.5), spec.step), 1e-6, "macro " .. m .. " applied")
  end
end)

test("every apply's sends are deferrable, and 16 full macros moving stay inside the budget", function()
  local context, S, macros = loaded()
  for voice = 1, S.constants.NUM_VOICES do
    if not S.voices[voice].active then toggle_voice(voice) end
  end
  S.drift_metro:stop()  -- the drift's own sends are never deferred: leave the window to the macros
  local ids = macros.target_ids()
  local index = 0
  for m = 1, 16 do
    for k = 1, 8 do
      index = index % #ids + 1
      assert_true(macros.set_target(m, k, ids[index], 0, 1), "target " .. ids[index])
    end
  end
  local window_seconds = S.constants.ENGINE_BUDGET.window_seconds
  local per_window = {}
  for id, sender in pairs(S.engine_senders) do
    S.engine_senders[id] = function(value)
      local window = math.floor(util.time() / window_seconds)
      per_window[window] = (per_window[window] or 0) + 1
      return sender(value)
    end
  end
  local final
  for step = 1, 30 do
    final = step % 2 == 0 and 0.2 or 0.8
    for m = 1, 16 do params:set("macro_" .. m, final) end
    context.clock.run_for(1 / 30)
  end
  context.clock.run_for(1)  -- what waits for the budget goes out
  local busiest = 0
  for _, count in pairs(per_window) do busiest = math.max(busiest, count) end
  assert_true(busiest <= S.constants.ENGINE_BUDGET.messages_per_window, "a window sent " .. busiest)
  assert_equal(S.lib.engine_sync.budget_state().pending, 0, "nothing waits at the end")
  while #ids > 16 * 8 do table.remove(ids) end  -- the ids the 128 rows took (the last matrix depths took none)
  for _, target_id in ipairs(ids) do
    local voice = target_id:match("^v(%d+)_main$")
    local id = voice and main_param_id(tonumber(voice)) or target_id
    local spec = params:lookup_param(id).controlspec
    assert_near(params:get(id), spec:map(final), math.max(spec.step, 1e-9), id .. " holds the last value")
    if S.engine_senders[id] then
      assert_near(S.engine_param_values[id], params:get(id), 1e-9, "the engine got " .. id)
    end
  end
end)

test("scenes and morph set a macro silently", function()
  local context, S, macros = loaded()
  macros.set_target(1, 1, "reverb_mix", 0, 1)
  params:set("reverb_mix", 0.3)
  macros.set_silently(1, 0.8); settle(context)
  assert_near(params:get("macro_1"), 0.8, 1e-9, "the macro moves")
  assert_near(params:get("reverb_mix"), 0.3, 1e-9, "no target does")
  assert_equal(S.macro_clock, nil, "nothing waits")
  -- a recall: the scene's own target values stand
  params:set("macro_1", 0.6); settle(context)
  params:set("reverb_mix", 0.1)  -- a hand edit of the target afterward
  capture_scene(1)
  params:set("macro_1", 0.9); settle(context)
  assert_near(params:get("reverb_mix"), 0.9, 1e-9)
  recall_scene(1, 0); settle(context)
  assert_near(params:get("macro_1"), 0.6, 1e-9, "the recall sets the macro")
  assert_near(params:get("reverb_mix"), 0.1, 1e-9, "and the scene's reverb mix stands")
  -- a transition's step and morph's setter
  S.lib.scenes.set_value("macro_1", 0.4); settle(context)
  assert_near(params:get("macro_1"), 0.4, 1e-9)
  assert_near(params:get("reverb_mix"), 0.1, 1e-9, "a fade step sets it silently")
  -- a hand move waiting for the clock is dropped by a silent set
  params:set("macro_1", 0.7)
  macros.set_silently(1, 0.2); settle(context)
  assert_near(params:get("reverb_mix"), 0.1, 1e-9, "the waiting apply is dropped")
  assert_near(params:get("macro_1"), 0.2, 1e-9)
  -- morph between two scenes that hold different macro and reverb values
  params:set("macro_1", 0.2); settle(context); params:set("reverb_mix", 0.1)
  capture_scene(1)
  params:set("macro_1", 0.8); settle(context); params:set("reverb_mix", 0.3)
  capture_scene(2)
  params:set("morph", 0.5)
  context.clock.run_for(0.5)
  assert_near(params:get("macro_1"), 0.5, 1e-9, "morph blends the macro")
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "and its target from the scenes, not the macro's mapping")
end)

test("an LFO on a macro moves the targets' engine values and no param", function()
  local context, S, macros = loaded()
  macros.set_target(1, 1, "reverb_mix", 0, 1)
  macros.set_target(1, 2, "v3_grain_pitch", 0, 1)
  params:set("macro_1", 0.5); settle(context)
  local pitch = params:get("v3_grain_pitch")
  -- without the matrix's fast sums, a fast target moves nothing (and raises
  -- nothing); MAIN's mark still asks the stand-in which voices it moves
  S.lib.matrix = { affects = function() return false end }
  S.engine_senders.macro_1(0.7)
  context.clock.run_for(0.05)
  local fast = {}
  S.lib.matrix = { set_fast_extra = function(key, id, m) table.insert(fast, { key = key, id = id, m = m }) end,
    affects = function() return false end }
  context.clear_engine_calls()
  S.engine_senders.macro_1(0.7)
  assert_near(engine_value(S, "reverb_mix"), 0.7, 1e-9, "an extra offset of +0.2 on reverb_mix")
  context.clock.run_for(0.05)  -- the LFO clock's round robin sends it
  local reverbs = context.calls_named("setReverb")
  assert_true(#reverbs >= 1, "reverb_mix is sent")
  assert_near(reverbs[#reverbs].args[1], 0.7, 1e-9, "with the extra")
  assert_near(params:get("macro_1"), 0.5, 1e-9, "the macro param is unchanged")
  assert_near(params:get("reverb_mix"), 0.5, 1e-9, "and so is reverb_mix's stored value")
  assert_near(params:get("v3_grain_pitch"), pitch, 1e-9, "and the pitch's")
  assert_equal(#fast, 1, "the fast target goes to the matrix's sum")
  assert_equal(fast[1].key, "macro1"); assert_equal(fast[1].id, "v3_grain_pitch")
  -- 2.875 - 2.125 (0.7 and 0.5 along 0.25-4) is 0.4 of the pitch's half range 1.875
  assert_near(fast[1].m, 0.4, 1e-9, "in half ranges, by the pitch's law")
  -- the stored value clears every extra
  context.clear_engine_calls()
  S.engine_senders.macro_1(0.5)
  assert_near(engine_value(S, "reverb_mix"), 0.5, 1e-9, "the extra is cleared")
  context.clock.run_for(0.05)
  reverbs = context.calls_named("setReverb")
  assert_near(reverbs[#reverbs].args[1], 0.5, 1e-9, "and the engine gets the stored value back")
  assert_equal(#fast, 2, "the fast extra is cleared too")
  assert_equal(fast[2].id, "v3_grain_pitch"); assert_equal(fast[2].m, nil)
  -- a real LFO on the destination macro 1: square at 100 % puts the macro at 1
  S.lib.matrix = { affects = function() return false end }
  local lfos = S.lib.lfos
  local destination
  for index, entry in ipairs(S.LFO_DESTINATIONS) do
    if entry.label == "macro 1" then destination = index end
  end
  params:set(lfos.param_id(1, "dest"), destination)
  params:set(lfos.param_id(1, "shape"), 3)
  params:set(lfos.param_id(1, "depth"), 100)
  params:set(lfos.param_id(1), 1)
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "reverb_mix"), 1, 1e-9, "the LFO moves the target's engine value")
  assert_near(params:get("macro_1"), 0.5, 1e-9, "and never the macro")
  assert_near(params:get("reverb_mix"), 0.5, 1e-9, "nor the target")
  params:set(lfos.param_id(1), 0)
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "reverb_mix"), 0.5, 1e-9, "turned off, the target is back on its value")
end)

test("a target that changes or loads drops the extra an LFO on its macro gave the old one", function()
  local context, S, macros = loaded()
  capture_scene(2)  -- no targets
  macros.set_target(1, 1, "reverb_mix", 0, 1)
  macros.set_target(1, 2, "v2_main", 0, 1)
  params:set("macro_1", 0.5); settle(context)
  local main = main_param_id(2)
  local function extra(id) return engine_value(S, id) - params:get(id) end
  S.engine_senders.macro_1(0.7)
  assert_true(math.abs(extra("reverb_mix")) > 0.1 and math.abs(extra(main)) > 0, "both targets hold an extra")
  -- a new id for a row: the old one's extra goes
  macros.set_target(1, 1, "delay_mix", 0, 1)
  assert_near(extra("reverb_mix"), 0, 1e-9, "set_target drops the row's extra")
  -- a main entry that resolves elsewhere: the old param's extra goes at the
  -- next LFO value, and the position it resolves to now is a fast target
  local fast = {}
  S.lib.matrix = { set_fast_extra = function(key, id, m) fast[#fast + 1] = { key = key, id = id, m = m } end,
    affects = function() return false end }
  params:set("v2_source", S.constants.SOURCE_SYNTH + 1)
  S.engine_senders.macro_1(0.7)
  assert_near(extra(main), 0, 1e-9, "the synth param the main entry left")
  assert_true(math.abs(extra("delay_mix")) > 0.1, "the new row 1 takes the LFO")
  context.clock.run_for(0.05)
  assert_equal(fast[#fast].id, "v2_buf_pos", "the position it resolves to now")
  assert_near(fast[#fast].m, 0.4, 1e-9, "0.2 of the position's half range 0.5")
  -- a load of the targets (here a recall of a scene with none) drops them all
  recall_scene(2, 0)
  assert_near(extra("delay_mix"), 0, 1e-9, "a recall's targets drop the extras")
  context.clock.run_for(0.05)
  assert_equal(fast[#fast].id, "v2_buf_pos"); assert_equal(fast[#fast].m, nil, "the fast one too")
end)

test("an LFO on a macro skips LFO-param targets", function()
  local context, S, macros = loaded()
  macros.set_target(1, 1, "strata_lfo2_depth", 0, 1)
  macros.set_target(1, 2, "reverb_mix", 0, 1)
  macros.set_target(1, 3, "strata_lfo4_rate", 0, 1)
  params:set("macro_1", 0.5); settle(context)
  assert_near(params:get("strata_lfo2_depth"), 50, 1e-9, "the macro's own value moves an LFO's depth")
  local rate = params:get("strata_lfo4_rate")
  S.engine_senders.macro_1(0.9)
  assert_near(engine_value(S, "reverb_mix"), 0.9, 1e-9, "a destination target takes the LFO's offset")
  assert_near(engine_value(S, "strata_lfo2_depth"), 50, 1e-9, "an LFO's depth does not")
  assert_near(engine_value(S, "strata_lfo4_rate"), rate, 1e-9, "nor its rate")
  context.clock.run_for(0.05)
  assert_near(params:get("strata_lfo2_depth"), 50, 1e-9, "and its param stays")
end)

-- LFO 1 on macro m, square (u = 1 for its first 2 s at the default 0.25 Hz)
-- at depth percent: the macro plays at its value + depth / 200, clamped to 1
local function square_lfo_on_macro(S, m, depth)
  local lfos = S.lib.lfos
  for index, entry in ipairs(S.LFO_DESTINATIONS) do
    if entry.label == "macro " .. m then params:set(lfos.param_id(1, "dest"), index) end
  end
  params:set(lfos.param_id(1, "shape"), 3)
  params:set(lfos.param_id(1, "depth"), depth)
  params:set(lfos.param_id(1), 1)
end

-- The last value of reverb_mix the engine got (setReverb's first argument)
local function sent_reverb(context)
  local calls = context.calls_named("setReverb")
  return calls[#calls] and calls[#calls].args[1]
end

test("an LFO on a macro follows its stored value, even while the LFO's clamp holds the macro still", function()
  local context, S, macros = loaded()
  macros.set_target(1, 1, "reverb_mix", 0, 1)
  params:set("macro_1", 0.6); settle(context)
  square_lfo_on_macro(S, 1, 100)  -- 0.6 + 0.5, clamped: the macro plays at 1
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "reverb_mix"), 1, 1e-9, "+0.4 on the target's 0.6")
  params:set("macro_1", 0.9); settle(context)  -- still 1 under the LFO's clamp
  context.clear_engine_calls()
  params:set("reverb_mix", 0.5)                -- a hand edit of the target
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "reverb_mix"), 0.6, 1e-9, "the extra is +0.1 now, from the new stored value")
  assert_near(sent_reverb(context), 0.6, 1e-9, "and the engine has it")
  -- a silent set (a recall, a fade, morph) is followed the same way
  macros.set_silently(1, 0.7)
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "reverb_mix"), 0.8, 1e-9, "+0.3 from 0.7")
end)

test("an LFO on a macro follows a range edit of a target", function()
  local context, S, macros = loaded()
  macros.set_target(1, 1, "reverb_mix", 0, 1)
  params:set("macro_1", 0.5); settle(context)
  square_lfo_on_macro(S, 1, 50)  -- the macro plays at 0.75
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "reverb_mix"), 0.75, 1e-9, "+0.25")
  context.clear_engine_calls()
  macros.set_target(1, 1, "reverb_mix", 0, 0.4)  -- 0.2 at the stored 0.5, 0.3 at 0.75
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "reverb_mix"), 0.6, 1e-9, "the new range's extra, +0.1")
  assert_near(sent_reverb(context), 0.6, 1e-9, "sent")
  -- a new id for the row takes the LFO at once too
  macros.set_target(1, 1, "delay_mix", 0, 1)
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "delay_mix"), params:get("delay_mix") + 0.25, 1e-9, "the new target")
  assert_near(engine_value(S, "reverb_mix"), params:get("reverb_mix"), 1e-9, "and none on the old one")
end)

-- Macro 1 at 0.5 on reverb_mix 0-1, under LFO 1 square at 50 % (the macro
-- plays at 0.75), then its row emptied: no extra
local function lfo_on_macro_without_targets(context, S, macros, before_emptying)
  macros.set_target(1, 1, "reverb_mix", 0, 1)
  params:set("macro_1", 0.5); settle(context)
  square_lfo_on_macro(S, 1, 50)
  context.clock.run_for(0.1)
  before_emptying()
  macros.set_target(1, 1, "", 0, 1)
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "reverb_mix"), params:get("reverb_mix"), 1e-9, "no target, no extra")
end

test("an LFO on a macro follows a scene recall of the targets", function()
  local context, S, macros = loaded()
  lfo_on_macro_without_targets(context, S, macros, function() capture_scene(1) end)
  recall_scene(1, 0)
  context.clear_engine_calls()
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "reverb_mix"), params:get("reverb_mix") + 0.25, 1e-9, "the recalled target takes the LFO")
  assert_near(sent_reverb(context), params:get("reverb_mix") + 0.25, 1e-9, "sent")
end)

test("an LFO on a macro follows a PSET load of the targets", function()
  local context, S, macros = loaded()
  local path = context.data_dir .. "strata-07.pset"
  lfo_on_macro_without_targets(context, S, macros, function() params:write(path) end)
  params:read(path)
  context.clear_engine_calls()
  context.clock.run_for(0.1)
  assert_near(engine_value(S, "reverb_mix"), params:get("reverb_mix") + 0.25, 1e-9, "the loaded target takes the LFO")
  assert_near(sent_reverb(context), params:get("reverb_mix") + 0.25, 1e-9, "sent")
end)

test("an LFO on a macro follows a main entry that resolves elsewhere after a source change", function()
  local context, S, macros = loaded()
  local fast = {}
  S.lib.matrix = { set_fast_extra = function(key, id, m) fast[#fast + 1] = { key = key, id = id, m = m } end,
    affects = function() return false end }
  macros.set_target(1, 1, "v2_main", 0, 1)
  params:set("macro_1", 0.5); settle(context)
  local main = main_param_id(2)
  square_lfo_on_macro(S, 1, 50)
  context.clock.run_for(0.1)
  assert_true(engine_value(S, main) ~= params:get(main), "the synth param takes the LFO")
  params:set("v2_source", S.constants.SOURCE_SYNTH + 1)  -- a buffer: the main entry is the position now
  context.clock.run_for(0.1)
  assert_near(engine_value(S, main), params:get(main), 1e-9, "the param it left has no extra")
  assert_equal(fast[#fast] and fast[#fast].id, "v2_buf_pos", "the position takes it, as a fast target")
  assert_near(fast[#fast].m, 0.5, 1e-9, "0.25 of the position's half range 0.5")
end)

test("a target whose set raises leaves the macro's other rows applied, and prints once", function()
  local context, S, macros = loaded()
  macros.set_target(1, 1, "reverb_mix", 0, 1)
  macros.set_target(1, 2, "delay_mix", 0, 1)
  local param = params:lookup_param("reverb_mix")
  local real_action = param.action
  param.action = function() error("boom") end
  params:set("macro_1", 0.4); settle(context)
  assert_near(params:get("delay_mix"), 0.4, 1e-9, "row 2 is applied")
  params:set("macro_1", 0.6); settle(context)
  assert_near(params:get("delay_mix"), 0.6, 1e-9, "at every apply")
  param.action = real_action
  h.claim_script_errors(context, 1, "strata: macro 1 row 1 apply failed: ", "boom")
end)

test("a PSET load cancels every pending apply before it loads the targets", function()
  local context, S, macros = loaded()
  macros.set_target(1, 1, "reverb_mix", 0, 1)
  params:set("macro_1", 0.9); settle(context)
  params:set("reverb_mix", 0.2)
  local path = context.data_dir .. "strata-01.pset"
  params:write(path)
  params:set("macro_1", 0.3)
  assert_true(S.macro_clock ~= nil, "an apply waits")
  params:read(path)
  assert_equal(S.macro_clock, nil, "the read canceled it")
  settle(context)
  assert_near(params:get("macro_1"), 0.9, 1e-9, "the PSET's macro value")
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "the PSET's own reverb mix, not the macro's mapping of 0.9")
  assert_equal(macros.targets(1)[1].id, "reverb_mix", "the PSET's targets")
  -- a silent read sets nothing waiting either
  params:set("macro_1", 0.4)
  params:read(path, true)
  settle(context)
  assert_near(params:get("reverb_mix"), 0.2, 1e-9, "a silent read applies nothing")
end)

test("writing a PSET always writes its side file, so an overwritten PSET never keeps a stale one", function()
  local context, S, macros = loaded()
  local path = context.data_dir .. "strata-02.pset"
  local side = context.data_dir .. "strata-02.macros.data"
  macros.set_target(1, 1, "reverb_mix", 0.1, 0.9)
  params:write(path)
  assert_true(util.file_exists(side), "the PSET's side file")
  macros.set_target(1, 1, "", 0, 1)
  params:write(path)  -- saved over with no targets
  assert_true(util.file_exists(side), "an empty side file is written too")
  macros.set_target(2, 3, "delay_mix", 0, 1)
  params:read(path)
  assert_equal(macros.targets(1)[1].id, "", "the empty save replaced the targets")
  assert_equal(macros.targets(2)[3].id, "", "and nothing of the moment before stays")
  params:delete(path)
  assert_true(not util.file_exists(side), "deleted with its PSET")
end)

test("learn takes the next hand-touched target", function()
  local context, S, macros = loaded()
  local flash = S.lib.ui_flash
  macros.learn(12, 1)
  local m, k = macros.learning()
  assert_equal(m, 12); assert_equal(k, 1)
  enc_param_delta(3, "v3_grain_pitch", 1)
  local target = macros.targets(12)[1]
  assert_equal(target.id, "v3_grain_pitch", "the touched param")
  assert_equal(target.min, 0); assert_equal(target.max, 1)
  assert_equal(flash.text("header"), "M12 > v3 pitch")
  assert_equal(macros.learning(), nil, "learn ends")
  assert_equal(S.macro_learn_clock, nil, "its clock with it")
  -- a param that is no target flashes, and learn waits on
  macros.learn(12, 2)
  enc_param_delta(3, "macro_2", 1)
  assert_equal(flash.text("header"), "not a macro target")
  assert_equal(macros.targets(12)[2].id, "", "the row stays empty")
  enc_param_delta(3, "filter_type", 1)
  assert_equal(flash.text("header"), "not a macro target", "an option is no target")
  m, k = macros.learning()
  assert_equal(m, 12, "still learning"); assert_equal(k, 2)
  -- a voice's main param learns the voice's main entry
  enc_param_delta(3, main_param_id(4), 1)
  assert_equal(macros.targets(12)[2].id, "v4_main")
  assert_equal(flash.text("header"), "M12 > v4 main")
  -- 10 s without a touch cancels
  macros.learn(12, 3)
  context.clock.run_for(10.1)
  assert_equal(macros.learning(), nil, "canceled after 10 s")
  enc_param_delta(3, "reverb_mix", 1)
  assert_equal(macros.targets(12)[3].id, "", "a later touch learns nothing")
  macros.learn(5, 8)
  macros.cancel_learn()
  assert_equal(macros.learning(), nil, "cancel_learn")
  assert_equal(S.macro_learn_clock, nil)
  enc_param_delta(3, "reverb_mix", 1)
  assert_equal(macros.targets(5)[8].id, "")
end)

test("the shown bank is shared and changing it sends nothing", function()
  local context, S, macros = loaded()
  assert_equal(macros.bank(), 1, "bank 1 at the start")
  local sources = S.lib.mod_sources
  local function shown()
    local keys = {}
    for _, record in ipairs(sources.list("macros")) do keys[#keys + 1] = record.key end
    return table.concat(keys, " ")
  end
  assert_equal(shown(), "macro1 macro2 macro3 macro4", "the sources of bank 1 show")
  context.clear_engine_calls()
  macros.set_bank(2)
  assert_equal(macros.bank(), 2)
  assert_equal(S.lib.ui_flash.text("header"), "macros 5-8")
  assert_equal(#context.engine_calls, 0, "a bank change sends nothing")
  assert_equal(shown(), "macro5 macro6 macro7 macro8")
  assert_equal(table.concat(macros.bank_macros(2), " "), "5 6 7 8")
  assert_equal(table.concat(macros.bank_macros(4), " "), "13 14 15 16")
  for _, bank in ipairs({ 0, 5, 1.5 }) do
    macros.set_bank(bank)
    assert_equal(macros.bank(), 2, "no bank " .. bank)
  end
  assert_equal(macros.bank_has_targets(2), false, "an empty bank")
  macros.set_target(6, 3, "reverb_mix", 0, 1)
  assert_equal(macros.bank_has_targets(2), true, "a bank with a target")
  assert_equal(macros.bank_has_targets(1), false)
  for m = 1, 16 do assert_equal(params:get("macro_" .. m), 0, "no macro moved") end
end)

test("unknown target ids are kept verbatim through a load and a save, with a console line, and do nothing", function()
  local context, S, macros = loaded()
  local path = context.data_dir .. "strata-03.pset"
  local side = context.data_dir .. "strata-03.macros.data"
  params:write(path)
  assert_true(S.lib.data_files.write(side, { version = 1, macros = {
    [1] = { [1] = { id = "future_param", min = 0.1, max = 0.9 }, [2] = { id = "reverb_mix", min = 0, max = 1 } },
    [5] = { [4] = { id = "v9_grain_pitch", min = 0, max = 1 } } } }))
  params:read(path)
  local unknown = macros.targets(1)[1]
  assert_equal(unknown.id, "future_param", "kept")
  assert_equal(unknown.min, 0.1); assert_equal(unknown.max, 0.9)
  assert_true(printed_with(context, "future_param") ~= nil, "a console line names it")
  assert_true(printed_with(context, "v9_grain_pitch") ~= nil, "and the other")
  assert_equal(macros.bank_has_targets(2), false, "an unknown target is no target for the bank's mark")
  params:set("macro_1", 0.5); settle(context)
  assert_near(params:get("reverb_mix"), 0.5, 1e-9, "the known target applies")
  S.engine_senders.macro_1(0.7)
  context.clock.run_for(0.05)
  assert_near(engine_value(S, "reverb_mix"), 0.7, 1e-9, "an LFO skips it too")
  params:write(path)
  local saved = S.lib.data_files.read(side)
  assert_equal(saved.macros[1][1].id, "future_param", "saved again as it was")
  assert_equal(saved.macros[5][4].id, "v9_grain_pitch")
  -- the live file keeps it across a restart
  cleanup()
  local _, next_S, next_macros = loaded({ data_subdir = data_dir_name(context) })
  assert_equal(next_macros.targets(1)[1].id, "future_param", "through the live file")
end)

test("the live file, the PSET side file and the scene block round-trip, sparse", function()
  local context, S, macros = loaded()
  local function fill()
    macros.set_target(1, 1, "reverb_mix", 0.2, 0.9)
    macros.set_target(1, 3, "v2_grain_size", 0, 0.5)
    macros.set_target(7, 8, "v4_main", 1, 0)
  end
  local function assert_filled(where)
    local row = macros.targets(1)[1]
    assert_equal(row.id, "reverb_mix", where)
    assert_near(row.min, 0.2, 1e-9, where); assert_near(row.max, 0.9, 1e-9, where)
    assert_equal(macros.targets(1)[3].id, "v2_grain_size", where)
    assert_near(macros.targets(1)[3].max, 0.5, 1e-9, where)
    assert_equal(macros.targets(7)[8].id, "v4_main", where)
    assert_equal(macros.targets(7)[8].min, 1, where); assert_equal(macros.targets(7)[8].max, 0, where)
    assert_equal(macros.targets(1)[2].id, "", where .. ": an empty row stays empty")
    local count = 0
    for m = 1, 16 do
      for k = 1, 8 do if macros.targets(m)[k].id ~= "" then count = count + 1 end end
    end
    assert_equal(count, 3, where .. ": three targets")
  end
  local function clear()
    for m = 1, 16 do for k = 1, 8 do macros.set_target(m, k, "", 0, 1) end end
  end
  fill()
  -- the scene block: only the rows with an id
  capture_scene(1)
  local block = S.scenes[1].data.macros
  assert_equal(target_count(block), 3, "three entries")
  assert_equal(block[1][2], nil, "no empty row")
  assert_equal(block[2], nil, "no macro without targets")
  assert_equal(block[1][1].id, "reverb_mix")
  clear()
  capture_scene(2)
  assert_equal(next(S.scenes[2].data.macros), nil, "a scene with no targets stores an empty table")
  recall_scene(1, 0)
  assert_filled("recalled")
  recall_scene(2, 0)
  assert_equal(macros.targets(1)[1].id, "", "the empty scene empties them")
  -- the PSET side file
  fill()
  local path = context.data_dir .. "strata-04.pset"
  params:write(path)
  local side = S.lib.data_files.read(context.data_dir .. "strata-04.macros.data")
  assert_equal(target_count(side.macros), 3, "the side file is sparse too")
  clear()
  params:read(path)
  assert_filled("from the PSET")
  -- the live file: saved as the targets change and at cleanup, loaded at the start
  context.clock.run_for(0.2)  -- its write after the PSET load's change
  local live = S.lib.data_files.read(context.data_dir .. "strata/macros.data")
  assert_equal(target_count(live.macros), 3, "saved as the targets were edited")
  cleanup()
  local _, next_S, next_macros = loaded({ data_subdir = data_dir_name(context) })
  macros = next_macros
  assert_filled("after a restart")
end)

test("a burst of target edits writes the live file once, with the newest targets", function()
  local context, S, macros = loaded()
  local live_path = context.data_dir .. "strata/macros.data"
  local writes = 0
  local real_write = S.lib.data_files.write
  S.lib.data_files.write = function(path, value)
    if path == live_path then writes = writes + 1 end
    return real_write(path, value)
  end
  for step = 1, 20 do macros.set_target(1, 1, "reverb_mix", step / 20, 1) end  -- MOD's E3, a detent each
  assert_equal(writes, 0, "nothing is written during the burst")
  context.clock.run_for(0.2)
  assert_equal(writes, 1, "one write after it")
  S.lib.data_files.write = real_write
  local live = S.lib.data_files.read(live_path)
  assert_near(live.macros[1][1].min, 1, 1e-9, "with the newest targets")
  -- cleanup writes at once what still waits
  macros.set_target(2, 1, "delay_mix", 0, 1)
  cleanup()
  live = S.lib.data_files.read(live_path)
  assert_equal(live.macros[2][1].id, "delay_mix", "saved at cleanup")
end)

test("a live file that can be neither read nor set aside is never written over", function()
  local first = loaded()
  cleanup()
  local live_path = first.data_dir .. "strata/macros.data"
  local bad = "return {\n  {1},\n"
  h.write_text(live_path, bad)
  local context = load_strata({ data_subdir = data_dir_name(first), before_init = function()
    local_value("S").lib.data_files.set_aside = function() return nil, "permission denied" end
  end })
  finish_startup(context)
  local S = local_value("S")
  S.lib.macros.set_target(1, 1, "reverb_mix", 0, 1)
  context.clock.run_for(0.2)
  assert_equal(h.file_text(live_path), bad, "not written over after a change")
  cleanup()
  assert_equal(h.file_text(live_path), bad, "nor at cleanup")
  local lines = 0
  for _, line in ipairs(context.printed) do
    if line:find("targets will not be saved", 1, true) then lines = lines + 1 end
  end
  assert_equal(lines, 1, "one console line says saves are off")
end)

test("a damaged live file that is set aside loads empty and saves normally", function()
  local first = loaded()
  cleanup()
  local live_path = first.data_dir .. "strata/macros.data"
  h.write_text(live_path, "return {\n  {1},\n")
  local context = load_strata({ data_subdir = data_dir_name(first) })
  finish_startup(context)
  local S = local_value("S")
  assert_true(util.file_exists(live_path .. ".bak"), "kept as a backup")
  assert_equal(S.lib.macros.targets(1)[1].id, "", "loaded empty")
  S.lib.macros.set_target(1, 1, "reverb_mix", 0, 1)
  context.clock.run_for(0.2)
  assert_equal(S.lib.data_files.read(live_path).macros[1][1].id, "reverb_mix", "saved normally afterward")
end)

test("a PSET without a side file loads empty", function()
  local context, S, macros = loaded()
  local path = context.data_dir .. "strata-05.pset"
  params:write(path)
  os.remove(context.data_dir .. "strata-05.macros.data")
  macros.set_target(3, 2, "reverb_mix", 0, 1)
  params:read(path)
  assert_equal(macros.targets(3)[2].id, "", "a PSET from before 3.4 held no targets")
end)

test("an unreadable side file is set aside and the PSET still loads", function()
  local contents = {
    "return {\n  {1},\n",                                                   -- not a data file
    { version = 2, macros = {} },                                            -- another version
    { version = 1, macros = { [17] = { [1] = { id = "reverb_mix", min = 0, max = 1 } } } },  -- no macro 17
    { version = 1, macros = { [1] = { [9] = { id = "reverb_mix", min = 0, max = 1 } } } },   -- no row 9
    { version = 1, macros = { [1] = { [1] = { id = "reverb_mix", min = 2, max = 1 } } } },   -- a min past 1
    { version = 1, macros = { [1] = { [1] = { id = 4, min = 0, max = 1 } } } },              -- an id that is no string
  }
  for index, content in ipairs(contents) do
    local context, S, macros = loaded()
    params:set("reverb_mix", 0.7)
    local path = context.data_dir .. "strata-06.pset"
    params:write(path)
    local side = context.data_dir .. "strata-06.macros.data"
    h.write_text(side, type(content) == "table" and S.lib.data_files.encode(content) or content)
    macros.set_target(1, 1, "delay_mix", 0, 1)
    params:set("reverb_mix", 0.2)
    params:read(path)
    assert_near(params:get("reverb_mix"), 0.7, 1e-9, "case " .. index .. ": the PSET loaded")
    assert_equal(macros.targets(1)[1].id, "", "case " .. index .. ": the targets are empty")
    assert_true(not util.file_exists(side), "case " .. index .. ": the file is moved")
    assert_true(util.file_exists(side .. ".bak"), "case " .. index .. ": to its first free backup name")
    local line = printed_with(context, ".bak")
    assert_true(line ~= nil and line:find("macros", 1, true) ~= nil, "case " .. index .. ": a console line names it")
  end
end)

test("a scenes file with 16 scenes of 16 full macros loads", function()
  local context, S, macros = loaded()
  local ids = macros.target_ids()
  -- every row of every macro, the longest ids first
  table.sort(ids, function(a, b) return #a > #b end)
  local index = 0
  for m = 1, 16 do
    for k = 1, 8 do
      index = index % #ids + 1
      macros.set_target(m, k, ids[index], 0.123456789, 0.987654321)
    end
  end
  for slot = 1, S.constants.NUM_SCENES do capture_scene(slot) end
  cleanup()  -- writes scenes.data
  local text = h.file_text(context.data_dir .. "strata/scenes.data")
  local tables = select(2, text:gsub("%-%- Table: ", ""))
  assert_true(tables <= S.lib.data_files.DATA_FILES.max_tables, tables .. " tables fit the reader's bound")
  local _, next_S, next_macros = loaded({ data_subdir = data_dir_name(context) })
  for slot = 1, next_S.constants.NUM_SCENES do
    assert_true(next_S.scenes[slot].populated, "scene " .. slot .. " loaded")
    assert_equal(target_count(next_S.scenes[slot].data.macros), 128, "scene " .. slot .. " holds every target")
  end
  for m = 1, 16 do for k = 1, 8 do next_macros.set_target(m, k, "", 0, 1) end end
  recall_scene(16, 0)
  assert_equal(next_macros.targets(16)[8].id, ids[index], "the last scene recalls the last target")
  assert_near(next_macros.targets(16)[8].min, 0.123456789, 1e-9)
end)

test("the 16 macros register as destinations and sources", function()
  local context, S, macros = loaded()
  local destinations = S.LFO_DESTINATIONS
  assert_equal(#destinations, 119, "after v7 amp, 103")
  for m = 1, 16 do
    local entry = destinations[103 + m]
    assert_equal(entry.label, "macro " .. m, "destination " .. (103 + m))
    assert_equal(entry.resolve(), "macro_" .. m)
    assert_equal(entry.group, "registered globals", "the global group")
    assert_equal(entry.fast, nil, "run in Lua")
  end
  local sources = S.lib.mod_sources
  for m = 1, 16 do
    local source = sources.get("macro" .. m)
    assert_true(source ~= nil, "macro" .. m .. " is a source")
    assert_equal(source.name, "M" .. m)
    assert_equal(source.section, "macros")
    assert_equal(source.range[1], 0); assert_equal(source.range[2], 1)
    assert_equal(source.visible(), m <= 4, "macro " .. m .. " shows in bank 1 only")
  end
  params:set("macro_2", 0.25)
  assert_near(sources.get("macro2").value(), 0.25, 1e-9, "the value is the param's")
  assert_near(sources.normalized("macro2"), 0.25, 1e-9, "a unipolar source")
  assert_equal(sources.get("macro2").describe(), "-", "no targets")
  macros.set_target(2, 2, "reverb_mix", 0, 1)
  assert_equal(sources.get("macro2").describe(), "rev mix", "the first target's label")
  macros.set_target(2, 5, "v3_grain_pitch", 0, 1)
  macros.set_target(2, 7, "strata_lfo3_depth", 0, 1)
  assert_equal(sources.get("macro2").describe(), "rev mix +2", "and how many more")
  -- the row's E3 moves the value by a percent a detent
  sources.get("macro2").row.enc(1)
  assert_near(params:get("macro_2"), 0.26, 1e-9, "E3 the value")
  sources.get("macro2").row.fine_enc(1)
  assert_near(params:get("macro_2"), 0.261, 1e-9, "fine E3 a tenth of a percent")
  assert_equal(sources.get("macro2").row.hints(false), "K3:targets E3:value")
  assert_equal(sources.get("macro2").row.press, nil, "MOD opens the target view itself")
  -- an index that is no macro or bank reads nothing
  assert_equal(macros.targets(0), nil); assert_equal(macros.targets(17), nil)
  assert_equal(#macros.bank_macros(5), 0, "no bank 5")
end)
end

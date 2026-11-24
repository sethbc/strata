-- test/unit/matrix_test.lua
-- The modulation matrix (lib/matrix.lua, S.lib.matrix, 3.4 design §10.2):
-- sixteen routings from any modulation source to any LFO destination but
-- the macros, each adding depth x the source's normalized value: a Lua
-- destination's sum as one extra offset (with the LFOs', clamped once), a
-- fast destination's through setFastOffset (clamped to -2..2), every send
-- in the LFOs' round robin; the 25 % rule of a MOD edit; learn; scenes
-- (depths crossfaded, a changed routing ramped through 0), morph, the PSET
-- side file and the live file
-- Run alone: lua test/run.lua matrix

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function loaded(options)
  local context = load_strata(options); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.matrix
end

-- Run the clocks until the LFO clock (the matrix steps in it) has stepped
-- `count` times (default 1)
local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

-- A seeded source the test moves: its value is source.value
local function seeded(S, key, range, value)
  local source = { value = value }
  S.register_mod_source({ key = key, name = "PR", section = "test", range = range,
    value = function() return source.value end })
  return source
end

-- Routing k from source to dest at depth percent (on, as by default)
local function route(S, k, source, dest, depth)
  assert_true(S.lib.matrix.set_routing(k, source, dest), "routing " .. k .. " is set")
  params:set("matrix_" .. k .. "_depth", depth)
end

-- The setFastOffset calls for engine voice `voice` and fast destination `destination`
local function fast_calls(context, voice, destination)
  local found = {}
  for _, call in ipairs(context.calls_named("setFastOffset")) do
    if call.args[1] == voice and call.args[3] == destination then table.insert(found, call) end
  end
  return found
end

local function last_fast(context, voice, destination)
  local calls = fast_calls(context, voice, destination)
  return calls[#calls] and calls[#calls].args[4]
end

-- The setGrainParam calls of engine voice `voice` for `name`
local function grain_calls(context, voice, name)
  local found = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == voice and call.args[2] == name then table.insert(found, call) end
  end
  return found
end

-- The last reverb mix the engine got (setReverb's first argument)
local function sent_reverb(context)
  local calls = context.calls_named("setReverb")
  return calls[#calls] and calls[#calls].args[1]
end

-- The value the engine has for a Lua param, LFO offsets and extras included
local function engine_value(S, id) return S.lib.engine_sync.with_lfo_offsets(id, params:get(id)) end

local function data_dir_name(context) return context.data_dir:match("([^/]+)/$") end

local function printed_with(context, text)
  for _, line in ipairs(context.printed) do
    if line:find(text, 1, true) then return line end
  end
  return nil
end

local function entry_count(block)
  local count = 0
  for _ in pairs(block or {}) do count = count + 1 end
  return count
end

local function lfo_id(n, field) return "strata_lfo" .. n .. (field and ("_" .. field) or "") end

local function destination_index(S, label)
  for index, destination in ipairs(S.LFO_DESTINATIONS) do
    if destination.label == label then return index end
  end
  error("no LFO destination " .. label)
end

-- LFO n on `label`, square at the slowest rate, held at its top (value 1)
-- or, with low, its bottom (-1), at depth percent
local function hold_lfo(S, n, label, depth, low)
  assert_true(S.lib.matrix.set_home(n, S.lib.lfos.destination_id(destination_index(S, label))), "home " .. n .. " set")
  params:set(lfo_id(n, "shape"), 3)
  params:set(lfo_id(n, "rate"), 0.003)
  params:set(lfo_id(n, "phase"), low and 50 or 0)
  params:set(lfo_id(n, "depth"), depth)
  params:set(lfo_id(n), 1)
end

-- Run a scene transition's clock until it has applied step `step`
local function to_step(context, S, step)
  while S.SCENE_TRANSITION.step < step do h.wake(context, "scene_transition_clock") end
end

-- Wrap S.lib.engine_sync.send_engine_value with fn(id, value) while body
-- runs, then put it back
local function spying_sends(S, fn, body)
  local real_send = S.lib.engine_sync.send_engine_value
  S.lib.engine_sync.send_engine_value = function(id, value)
    fn(id, value)
    return real_send(id, value)
  end
  local ok, problem = pcall(body)
  S.lib.engine_sync.send_engine_value = real_send
  if not ok then error(problem, 0) end
end

-- The send budget's window filled on demand: the LFO clock stepped to a
-- step early in its window (so the next two steps share it), and a hook,
-- after the matrix's and before the round robin's sends, that spends the
-- window's messages_per_window while armed. Returns the function that arms
-- it (true) or disarms it, and the window the next step falls in
local function full_window(context, S)
  S.drift_metro:stop()  -- the drift's own sends would share the window's count
  local sync = S.lib.engine_sync
  local budget = S.constants.ENGINE_BUDGET
  repeat lfo_step(context) until util.time() % budget.window_seconds < budget.window_seconds / 4
  local armed = false
  S.lib.lfos.on_step(function()
    if not armed then return end
    sync.deferrable(function()
      while sync.budget_state().sent < budget.messages_per_window do sync.send_engine_value("drift_amount", 0.01) end
    end)
  end)
  return function(on) armed = on end, math.floor(util.time() / budget.window_seconds)
end

test("matrix: an empty or incomplete routing sends nothing", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  local function assert_quiet(where)
    context.clear_engine_calls()
    lfo_step(context, 3)
    assert_equal(#context.calls_named("setFastOffset"), 0, where .. ": no setFastOffset")
    assert_equal(#context.calls_named("setReverb"), 0, where .. ": no reverb send")
    assert_equal(matrix.offset("reverb_mix"), 0, where .. ": no sum")
    assert_equal(matrix.offset("v3_grain_pitch"), 0, where .. ": no fast sum")
    assert_near(engine_value(S, "reverb_mix"), params:get("reverb_mix"), 1e-12, where .. ": no extra offset")
  end
  params:set("matrix_1_depth", 50); params:set("matrix_2_depth", 50)
  assert_quiet("empty routings at depth 50")
  matrix.set_routing(1, "macro1", ""); matrix.set_routing(2, "", "v3_grain_pitch")
  assert_quiet("a source or a destination alone")
  matrix.set_routing(1, "macro1", "reverb_mix"); params:set("matrix_1_depth", 0)
  matrix.set_routing(2, "macro1", "v3_grain_pitch"); params:set("matrix_2", 0)
  assert_quiet("complete, at depth 0 or off")
  -- the same two, playing, move their destinations
  params:set("matrix_1_depth", 50); params:set("matrix_2", 1)
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(#context.calls_named("setFastOffset"), 1, "playing, the fast one sends")
  assert_equal(#context.calls_named("setReverb"), 1, "and the Lua one")
end)

test("matrix: a macro at 0.5 on v1 grain size at depth 40% sends 0.149", function()
  local context, S, matrix = loaded()
  params:set("v1_grain_size", 0.1)
  params:set("macro_1", 0.5)                      -- unipolar: s 0.5
  route(S, 1, "macro1", "v1_grain_size", 40)
  context.clear_engine_calls(); lfo_step(context)
  -- v1 grain size is a fast destination (2): the offset goes to the engine's bus
  local fast = fast_calls(context, 0, 2)
  assert_equal(#fast, 1, "one offset for voice 1's size")
  assert_equal(fast[1].args[2], 0, "on note slot 0")
  assert_near(fast[1].args[4], 0.2, 1e-9, "40 % of 0.5, in half ranges")
  assert_equal(#grain_calls(context, 0, "grainSize"), 0, "the base is not resent with it")
  -- the engine plays the stored 0.1 plus 0.2 of the size's half range 0.245
  assert_near(engine_param_value("v1_grain_size") + fast[1].args[4] * 0.245, 0.149, 1e-6, "0.1 + 0.049")
  assert_near(matrix.offset("v1_grain_size"), 0.2, 1e-9, "the matrix's sum")
  assert_near(params:get("v1_grain_size"), 0.1, 1e-9, "the stored value stays")
end)

test("matrix: opposite routings cancel before one clamp", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  -- the fast v1 grain size at 0.45: +100 % sends one half range, and -100 %
  -- with it brings the sum to 0, so the engine plays 0.45 (not 0.5 - 0.245)
  params:set("v1_grain_size", 0.45)
  route(S, 1, "macro1", "v1_grain_size", 100)
  context.clear_engine_calls(); lfo_step(context)
  assert_near(last_fast(context, 0, 2), 1, 1e-9, "+100 %")
  route(S, 2, "macro1", "v1_grain_size", -100)
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(last_fast(context, 0, 2), 0, "the two cancel")
  -- a Lua destination, reverb_mix at 0.9: +100 % alone is clamped to 1; both
  -- together are one sum and one clamp, 0.9 (not 1 - 0.5)
  params:set("reverb_mix", 0.9)
  route(S, 3, "macro1", "reverb_mix", 100)
  context.clear_engine_calls(); lfo_step(context)
  assert_near(sent_reverb(context), 1, 1e-9, "0.9 + 0.5, clamped to the range")
  route(S, 4, "macro1", "reverb_mix", -100)
  context.clear_engine_calls(); lfo_step(context)
  assert_near(sent_reverb(context), 0.9, 1e-9, "the routings cancel before the clamp")
  assert_near(params:get("reverb_mix"), 0.9, 1e-9, "the stored value never moved")
end)

test("matrix: a routing on top of a Lua LFO sums before the clamp", function()
  local context, S, matrix = loaded()
  params:set("v1_grain_density", 90)              -- range 1-100: half range 49.5
  params:set("macro_1", 1)
  route(S, 1, "macro1", "v1_grain_density", -30)  -- -0.3 half ranges: -14.85
  hold_lfo(S, 1, "v1 dens", 40)                   -- +0.4 half ranges: +19.8
  local sends = 0
  spying_sends(S, function(id) if id == "v1_grain_density" and S.deferrable_write then sends = sends + 1 end end,
    function()
      lfo_step(context)
      assert_equal(sends, 1, "one send in the step, for the LFO and the routing together")
      -- 90 + 19.8 - 14.85 = 94.95; a clamp after the LFO alone would give 100 - 14.85
      assert_near(S.engine_param_values.v1_grain_density, 94.95, 1e-9, "clamp(base + both)")
      sends = 0
      lfo_step(context, 3)
      assert_equal(sends, 0, "nothing moves: nothing more is sent")
    end)
  assert_equal(params:get("v1_grain_density"), 90, "the stored value stays")
end)

test("matrix: a routing to v3 pitch goes to the offset bus", function()
  local context, S, matrix = loaded()
  toggle_voice(3); toggle_lock(3)                 -- running, and locked against the drift's pitch
  params:set("macro_1", 1)
  route(S, 1, "macro1", "v3_grain_pitch", 50)
  context.clear_engine_calls(); lfo_step(context, 2)
  local fast = fast_calls(context, 2, 0)
  assert_equal(#fast, 1, "one setFastOffset on voice 3's pitch (fast destination 0)")
  assert_near(fast[1].args[4], 0.5, 1e-9, "50 % of 1")
  assert_equal(#grain_calls(context, 2, "pitchShift"), 0, "and no setGrainParam for its pitch")
end)

test("matrix: an LFO source reads its shape value, not its depth", function()
  local context, S, matrix = loaded()
  params:set(lfo_id(1, "shape"), 1)               -- sine
  params:set(lfo_id(1, "rate"), 0.003); params:set(lfo_id(1, "phase"), 25)  -- at its top: s 1
  params:set(lfo_id(1, "depth"), 10)              -- its own depth plays no part
  params:set(lfo_id(1), 1)                        -- on, with no destination of its own
  route(S, 1, "lfo1", "v3_grain_pitch", 60)
  context.clear_engine_calls(); lfo_step(context)
  assert_near(S.lib.lfos.value(1), 1, 1e-3, "the sine at its top")
  assert_near(last_fast(context, 2, 0), 0.6, 1e-3, "60 % of s 1, not of the LFO's 10 %")
end)

test("matrix: clearing a routing restores the destination", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  params:set("reverb_mix", 0.3)
  route(S, 1, "macro1", "reverb_mix", 50)
  route(S, 2, "macro1", "v3_grain_pitch", 50)
  lfo_step(context)
  assert_near(sent_reverb(context), 0.55, 1e-9, "0.3 + 0.5 x half the range")
  assert_near(last_fast(context, 2, 0), 0.5, 1e-9)
  matrix.clear(1); matrix.clear(2)
  local routing = matrix.routing(1)
  assert_equal(routing.source, ""); assert_equal(routing.dest, "")
  assert_equal(routing.depth, 0, "a cleared routing is back at depth 0")
  assert_equal(routing.on, true, "and on")
  context.clear_engine_calls(); lfo_step(context, 4)
  local reverbs = context.calls_named("setReverb")
  assert_equal(#reverbs, 1, "the Lua destination is sent once")
  assert_near(reverbs[1].args[1], 0.3, 1e-9, "with its base value")
  local fast = fast_calls(context, 2, 0)
  assert_equal(#fast, 1, "the fast destination once")
  assert_equal(fast[1].args[4], 0, "at 0")
  assert_near(engine_value(S, "reverb_mix"), 0.3, 1e-12, "no offset is left")
  assert_equal(matrix.offset("v3_grain_pitch"), 0)
end)

test("matrix: never sets a destination param", function()
  local context, S, matrix = loaded()
  params:set(lfo_id(1, "shape"), 4); params:set(lfo_id(1, "rate"), 2); params:set(lfo_id(1), 1)  -- up, no destination
  params:set("macro_1", 0.7)
  route(S, 1, "lfo1", "reverb_mix", 80)
  route(S, 2, "lfo1", "v3_grain_pitch", -60)
  route(S, 3, "macro1", "v2_main", 40)
  route(S, 4, "lfo1", "filter_freq", 30)
  local watched = { reverb_mix = true, v3_grain_pitch = true, filter_freq = true, [main_param_id(2)] = true }
  local set = {}
  local real_set = params.set
  params.set = function(self, id, ...)
    if watched[id] and not S.drift_writing then table.insert(set, id) end
    return real_set(self, id, ...)
  end
  local ok, problem = pcall(lfo_step, context, 100)
  params.set = nil
  if not ok then error(problem, 0) end
  assert_equal(#set, 0, "no destination param was set: " .. table.concat(set, " "))
  assert_true(#context.calls_named("setFastOffset") > 0 and #context.calls_named("setReverb") > 0,
    "while the routings played")
end)

test("matrix: shares the LFO cap", function()
  local context, S, matrix = loaded()
  local lfos = S.lib.lfos
  -- every voice running: every routed send reaches the engine and takes a slot (#644)
  for v = 1, S.constants.NUM_VOICES do if not S.voices[v].active then toggle_voice(v) end end
  local lfo_labels = { "rev mix", "rev size", "rev damp", "dly time", "dly fdbk", "dly mix" }
  local lfo_destinations = { "reverb_mix", "reverb_size", "reverb_damp", "delay_time", "delay_feedback", "delay_mix" }
  local taken = {}
  for _, id in ipairs(lfo_destinations) do taken[id] = true end
  -- sixteen more Lua destinations, the first of the list that run in Lua
  local routed = {}
  for _, id in ipairs(matrix.destination_ids()) do
    if #routed < 16 and not taken[id] and not lfos.fast_destination(id) and not id:match("_main$") then
      table.insert(routed, id)
    end
  end
  assert_equal(#routed, 16, "sixteen Lua destinations")
  local every = {}
  for _, id in ipairs(lfo_destinations) do table.insert(every, id) end
  for _, id in ipairs(routed) do table.insert(every, id) end
  for _, id in ipairs(every) do   -- the middle of each range, so no swing reaches an end
    local low, high = param_range(id)
    params:set(id, (low + high) / 2)
  end
  for n, label in ipairs(lfo_labels) do
    assert_true(S.lib.matrix.set_home(n, S.lib.lfos.destination_id(destination_index(S, label))), "home " .. n)
    params:set(lfo_id(n, "shape"), 4)               -- up
    params:set(lfo_id(n, "rate"), 10); params:set(lfo_id(n, "depth"), 40)
    params:set(lfo_id(n), 1)
  end
  for k, id in ipairs(routed) do route(S, k, "lfo" .. ((k - 1) % 6 + 1), id, 40) end
  local steps, sent = {}, {}
  spying_sends(S, function(id) if S.deferrable_write then table.insert(sent, id) end end, function()
    for _ = 1, 6 do
      sent = {}
      lfo_step(context)
      table.insert(steps, sent)
    end
  end)
  for index, step_sent in ipairs(steps) do
    assert_true(#step_sent <= 12, "step " .. index .. " sends " .. #step_sent .. ", at most 12")
  end
  for index = 1, #steps - 1 do
    local seen = {}
    for _, id in ipairs(steps[index]) do seen[id] = true end
    for _, id in ipairs(steps[index + 1]) do seen[id] = true end
    for _, id in ipairs(every) do assert_true(seen[id], id .. " is sent in steps " .. index .. "-" .. (index + 1)) end
  end
end)

test("matrix: its sends are deferrable", function()
  local context, S, matrix = loaded()
  S.drift_metro:stop()  -- the drift's own sends would share the window's count
  local sync = S.lib.engine_sync
  params:set("macro_1", 1)
  route(S, 1, "macro1", "reverb_mix", 40)
  route(S, 2, "macro1", "v3_grain_pitch", 40)
  -- each engine call of the round robin, with S.deferrable_write and the
  -- budget's count since the step's sends began (this hook runs after the
  -- matrix's, before the round robin sends)
  local flags, step_sends, before = {}, 0, 0
  S.lib.lfos.on_step(function() step_sends, before = 0, sync.budget_state().sent end)
  local function watch(command)
    local real = engine[command]
    engine[command] = function(...)
      step_sends = step_sends + 1
      table.insert(flags, { what = command, deferrable = S.deferrable_write,
        counted = sync.budget_state().sent - before == step_sends })
      return real(...)
    end
  end
  watch("setReverb"); watch("setFastOffset")
  local ok, problem = pcall(function()
    lfo_step(context, 2)
    matrix.clear(1); matrix.clear(2)   -- their restores too
    lfo_step(context, 2)
  end)
  rawset(engine, "setReverb", nil); rawset(engine, "setFastOffset", nil)
  if not ok then error(problem, 0) end
  assert_equal(#flags, 4, "a send and a restore of each")
  for index, flag in ipairs(flags) do
    assert_equal(flag.deferrable, true, flag.what .. " send " .. index .. " has S.deferrable_write set")
    assert_equal(flag.counted, true, flag.what .. " send " .. index .. " counts against the budget")
  end
end)

test("matrix: a fast send past the budget waits and goes out first in the next window, with its newest sum", function()
  local context, S, matrix = loaded()
  S.drift_metro:stop()
  local sync = S.lib.engine_sync
  local budget = S.constants.ENGINE_BUDGET
  params:set("macro_1", 1); context.clock.run_for(0.05)
  -- a step early in its window, so the next two share it
  repeat lfo_step(context) until util.time() % budget.window_seconds < budget.window_seconds / 4
  local fill = false
  S.lib.lfos.on_step(function()   -- after the matrix's hook, before the round robin sends
    if not fill then return end
    sync.deferrable(function()
      while sync.budget_state().sent < budget.messages_per_window do sync.send_engine_value("drift_amount", 0.01) end
    end)
  end)
  route(S, 1, "macro1", "v3_grain_pitch", 50)
  local window = math.floor(util.time() / budget.window_seconds)
  fill = true
  context.clear_engine_calls(); lfo_step(context)
  fill = false
  assert_equal(math.floor(util.time() / budget.window_seconds), window, "the step shares the window")
  assert_equal(#context.calls_named("setFastOffset"), 0, "the window's 150 are spent: the offset waits")
  assert_equal(sync.budget_state().pending, 1, "one value waits")
  params:set("macro_1", 0.6)                      -- a newer sum: 0.3
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(math.floor(util.time() / budget.window_seconds), window, "still the same window")
  assert_equal(#context.calls_named("setFastOffset"), 0, "it still waits")
  assert_equal(sync.budget_state().pending, 1, "one value for the channel, the newest")
  context.clear_engine_calls()
  h.wake(context, "engine_budget_clock")          -- the next window
  local first = context.engine_calls[1]
  assert_equal(first and first.name, "setFastOffset", "first in the next window")
  assert_equal(first.args[1], 2); assert_equal(first.args[3], 0)
  assert_near(first.args[4], 0.3, 1e-9, "with the newest sum")
  assert_equal(#context.calls_named("setFastOffset"), 1, "once")
  assert_equal(sync.budget_state().pending, 0, "nothing waits")
end)

test("matrix: a fast sum that returns to 0 while its send waits sends 0, never the stale sum", function()
  local context, S, matrix = loaded()
  S.drift_metro:stop()
  local sync = S.lib.engine_sync
  local budget = S.constants.ENGINE_BUDGET
  params:set("macro_1", 1); context.clock.run_for(0.05)
  repeat lfo_step(context) until util.time() % budget.window_seconds < budget.window_seconds / 4
  local fill = false
  S.lib.lfos.on_step(function()
    if not fill then return end
    sync.deferrable(function()
      while sync.budget_state().sent < budget.messages_per_window do sync.send_engine_value("drift_amount", 0.01) end
    end)
  end)
  route(S, 1, "macro1", "v3_grain_pitch", 50)
  fill = true
  lfo_step(context)                               -- 0.5 waits for the next window
  fill = false
  assert_equal(sync.budget_state().pending, 1, "the sum waits")
  params:set("matrix_1_depth", 0)                 -- the routing stops in the same window
  context.clear_engine_calls(); lfo_step(context)
  h.wake(context, "engine_budget_clock")
  lfo_step(context, 3)
  local fast = fast_calls(context, 2, 0)
  assert_true(#fast >= 1, "the waiting send goes out")
  for _, call in ipairs(fast) do assert_equal(call.args[4], 0, "with 0, never the stale 0.5") end
  assert_equal(matrix.offset("v3_grain_pitch"), 0)
end)

test("matrix: a fast sum back at the delivered value while another waits sends it, never the waiting one", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 0.5)
  route(S, 1, "macro1", "v3_grain_pitch", 100)
  context.clock.run_for(0.05)
  local arm, window = full_window(context, S)
  assert_near(last_fast(context, 2, 0), 0.5, 1e-9, "0.5 delivered")
  params:set("macro_1", 1)                        -- 1.0 waits in a full window
  arm(true); context.clear_engine_calls(); lfo_step(context); arm(false)
  assert_equal(S.lib.engine_sync.budget_state().pending, 1, "1.0 waits")
  params:set("macro_1", 0.5)                      -- back at the delivered 0.5, the same window
  lfo_step(context)
  assert_equal(math.floor(util.time() / S.constants.ENGINE_BUDGET.window_seconds), window, "one window")
  h.wake(context, "engine_budget_clock")
  lfo_step(context, 3)
  for _, call in ipairs(fast_calls(context, 2, 0)) do
    assert_true(math.abs(call.args[4] - 1) > 1e-9, "the waiting 1.0 never reaches the engine")
  end
  assert_near(S.engine_param_values["matrix fast 3 0"], 0.5, 1e-9, "the engine ends on the newest sum")
end)

test("matrix: a Lua sum back at the delivered value while another waits sends it, never the waiting one", function()
  local context, S, matrix = loaded()
  params:set("reverb_mix", 0.3)
  params:set("macro_1", 0.5)
  route(S, 1, "macro1", "reverb_mix", 40)         -- 0.3 + 0.2 x the macro
  context.clock.run_for(0.05)
  local arm, window = full_window(context, S)
  assert_near(sent_reverb(context), 0.4, 1e-9, "0.4 delivered")
  params:set("macro_1", 1)                        -- 0.5 waits in a full window
  arm(true); context.clear_engine_calls(); lfo_step(context); arm(false)
  assert_equal(S.lib.engine_sync.budget_state().pending, 1, "0.5 waits")
  params:set("macro_1", 0.5)                      -- back at the delivered 0.4, the same window
  lfo_step(context)
  assert_equal(math.floor(util.time() / S.constants.ENGINE_BUDGET.window_seconds), window, "one window")
  h.wake(context, "engine_budget_clock")
  lfo_step(context, 3)
  for _, call in ipairs(context.calls_named("setReverb")) do
    assert_true(math.abs(call.args[1] - 0.5) > 1e-9, "the waiting 0.5 never reaches the engine")
  end
  assert_near(S.engine_param_values.reverb_mix, 0.4, 1e-9, "the engine ends on the newest value")
end)

test("matrix: a Lua sum back at its handed value while another writer's waits sends it, never the waiting one (#647)", function()
  local context, S, matrix = loaded()
  params:set("reverb_mix", 0.3)
  params:set("macro_1", 0.5)
  route(S, 1, "macro1", "reverb_mix", 40)         -- the stored value + 0.2 x the macro
  context.clock.run_for(0.05)
  local arm, window = full_window(context, S)
  assert_near(sent_reverb(context), 0.4, 1e-9, "0.4 delivered")
  params:set("macro_1", 1)                        -- the matrix hands 0.5 to a full window
  arm(true); context.clear_engine_calls(); lfo_step(context); arm(false)
  assert_equal(S.lib.engine_sync.budget_state().pending, 1, "0.5 waits")
  -- a deferrable writer (a macro apply, morph, a gesture's playback) sets the
  -- stored value: its action's 0.4 + 0.2 waits in the matrix's place
  S.lib.engine_sync.deferrable(function() params:set("reverb_mix", 0.4) end)
  assert_equal(S.lib.engine_sync.budget_state().pending, 1, "0.6 waits for the key")
  params:set("macro_1", 0.5)                      -- 0.4 + 0.1: back at the 0.5 the matrix handed
  lfo_step(context)
  assert_equal(math.floor(util.time() / S.constants.ENGINE_BUDGET.window_seconds), window, "one window")
  h.wake(context, "engine_budget_clock")
  lfo_step(context, 3)
  for _, call in ipairs(context.calls_named("setReverb")) do
    assert_true(math.abs(call.args[1] - 0.6) > 1e-9, "the waiting 0.6 never reaches the engine")
  end
  assert_near(S.engine_param_values.reverb_mix, 0.5, 1e-9, "the engine ends on the newest value")
end)

test("matrix: a scene's unknown part prints once a session", function()
  local context, S, matrix = loaded()
  local function lines_with(text)
    local count = 0
    for _, line in ipairs(context.printed) do
      if line:find(text, 1, true) then count = count + 1 end
    end
    return count
  end
  capture_scene(1)
  S.scenes[1].data.matrix = { [3] = { source = "future_source", dest = "reverb_mix" } }
  capture_scene(2)
  S.scenes[2].data.matrix = { [4] = { source = "macro1", dest = "v9_grain_pitch" } }
  recall_scene(1, 0)
  recall_scene(1, 0)
  assert_equal(lines_with("future_source"), 1, "two recalls of one scene: one line")
  recall_scene(2, 0)
  assert_equal(lines_with("v9_grain_pitch"), 1, "a second scene's own unknown id: its own line")
  recall_scene(1, 0); recall_scene(2, 0)
  assert_equal(lines_with("future_source") + lines_with("v9_grain_pitch"), 2, "and never again")
  assert_equal(matrix.routing(4).dest, "v9_grain_pitch", "each still kept")
end)

test("matrix: a voice start or a sync resends no unmoved fast channel", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  route(S, 1, "macro1", "v3_grain_pitch", 50)
  lfo_step(context)
  assert_near(last_fast(context, 2, 0), 0.5, 1e-9)
  -- the engine's offset node keeps the channel's value through a start and a sync
  context.clear_engine_calls()
  toggle_voice(3)
  lfo_step(context, 3)
  assert_equal(#context.calls_named("voiceOn"), 1, "voice 3 started")
  assert_equal(#context.calls_named("setFastOffset"), 0, "a start resends nothing")
  sync_voice_values_to_engine(3)
  lfo_step(context, 3)
  assert_equal(#context.calls_named("setFastOffset"), 0, "nor a sync")
  params:set("macro_1", 0.5)
  lfo_step(context)
  assert_near(last_fast(context, 2, 0), 0.25, 1e-9, "a move still sends")
end)

test("matrix: a raising source or destination is skipped alone, with one console line each", function()
  local context, S, matrix = loaded()
  S.register_mod_source({ key = "broken", name = "BR", section = "test", range = { 0, 1 },
    value = function() error("source boom") end })
  route(S, 1, "broken", "v1_grain_spread", 50)    -- its source raises
  route(S, 2, "macro1", "reverb_size", 50)        -- its update raises
  route(S, 3, "macro1", "reverb_mix", 50)
  route(S, 4, "macro1", "v3_grain_pitch", 50)
  route(S, 5, "macro1", "delay_mix", 50)          -- its sender raises
  local real_offset_for = S.lib.lfos.offset_for
  S.lib.lfos.offset_for = function(id, m)
    if id == "reverb_size" then error("destination boom") end
    return real_offset_for(id, m)
  end
  S.engine_senders.delay_mix = function() error("sender boom") end
  local ok, problem = pcall(function()
    for step = 1, 4 do
      local macro = step % 2 == 0 and 1 or 0.5
      params:set("macro_1", macro)
      context.clear_engine_calls(); lfo_step(context)
      -- 50 % of the macro: m = macro / 2, half a range of 1 each way on reverb_mix
      assert_near(sent_reverb(context), params:get("reverb_mix") + macro / 2 * 0.5, 1e-9, "step " .. step .. ": reverb_mix plays")
      assert_near(last_fast(context, 2, 0), macro / 2, 1e-9, "step " .. step .. ": v3 pitch plays")
    end
  end)
  S.lib.lfos.offset_for = real_offset_for
  if not ok then error(problem, 0) end
  local lines = h.claim_script_errors(context, 3, "strata: ")
  local text = table.concat(lines, "\n")
  assert_true(text:find("matrix routing 1 failed", 1, true) ~= nil, "the source's routing, once")
  assert_true(text:find("matrix destination reverb_size failed", 1, true) ~= nil, "the destination, once")
  assert_true(text:find("sender boom", 1, true) ~= nil, "the sender, once")
end)

test("matrix: a scene's unknown parts get a console line, and its apply redraws", function()
  local context, S, matrix = loaded()
  capture_scene(1)
  S.scenes[1].data.matrix = { [3] = { source = "future_source", dest = "v9_grain_pitch" } }
  recall_scene(1, 0)
  assert_equal(matrix.routing(3).source, "future_source", "kept")
  assert_true(printed_with(context, "future_source") ~= nil, "a console line names the source")
  assert_true(printed_with(context, "v9_grain_pitch") ~= nil, "and the destination")
  -- the block's apply asks for a redraw itself (morph's crossing applies it outside a recall)
  local block
  for _, record in ipairs(S.registry.scene_blocks) do
    if record.key == "matrix" then block = record end
  end
  local asked = 0
  local real_request = request_redraw
  request_redraw = function(...) asked = asked + 1; return real_request(...) end
  local ran, problem = pcall(block.apply, { [1] = { source = "macro1", dest = "reverb_mix" } })
  request_redraw = real_request
  if not ran then error(problem, 0) end
  assert_true(asked >= 1, "the apply asked for a redraw")
  assert_equal(matrix.routing(1).dest, "reverb_mix")
end)

test("matrix: a live file that can be neither read nor set aside is never written over", function()
  local first = load_strata(); finish_startup(first)
  cleanup()
  local live_path = first.data_dir .. "strata/matrix.data"
  local bad = "return {\n  {1},\n"
  h.write_text(live_path, bad)
  local context = load_strata({ data_subdir = data_dir_name(first), before_init = function()
    local S = local_value("S")
    S.lib.data_files.set_aside = function() return nil, "permission denied" end
  end })
  finish_startup(context)
  local S = local_value("S")
  assert_true(printed_with(context, "routings will not be saved") ~= nil, "a console line says so")
  S.lib.matrix.set_routing(1, "macro1", "reverb_mix")
  context.clock.run_for(0.2)
  assert_equal(h.file_text(live_path), bad, "not written over after a change")
  cleanup()
  assert_equal(h.file_text(live_path), bad, "nor at cleanup")
end)

test("matrix: the step after a voice sync or a start leaves a Lua destination routed in the engine", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  local stored = params:get("v1_grain_spread")
  route(S, 1, "macro1", "v1_grain_spread", 40)    -- +0.2
  local function last_spread()
    local calls = grain_calls(context, 0, "posSpread")
    return calls[#calls] and calls[#calls].args[3]
  end
  lfo_step(context)
  assert_near(last_spread(), stored + 0.2, 1e-9, "routed")
  sync_voice_values_to_engine(1)
  lfo_step(context)
  assert_near(last_spread(), stored + 0.2, 1e-9, "after a sync")
  toggle_voice(1); toggle_voice(1)
  lfo_step(context)
  assert_near(last_spread(), stored + 0.2, 1e-9, "after a stop and a start")
  -- what the engine has forgotten (a sync forgets the voice's sent values) the next step sends again
  S.engine_param_values.v1_grain_spread = nil
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(#grain_calls(context, 0, "posSpread"), 1, "sent again")
  assert_near(last_spread(), stored + 0.2, 1e-9)
  assert_near(params:get("v1_grain_spread"), stored, 1e-12, "the stored value stays")
end)

-- #760: a Lua destination whose routings still play but sum to exactly 0
-- is sent once as the sum returns to 0, then only when its value moves
-- from what the engine has or the engine forgets it
local function setfilter_mixes(context)
  local mixes = {}
  for _, call in ipairs(context.calls_named("setFilter")) do table.insert(mixes, call.args[4]) end
  return mixes
end

test("matrix: routings that cancel to exactly 0 send once, then nothing (#760)", function()
  local context, S = loaded()
  params:set("filter_mix", 0.5)
  params:set("macro_1", 1)
  route(S, 1, "macro1", "filter_mix", 100)
  lfo_step(context)
  assert_near(engine_value(S, "filter_mix"), 1, 1e-9, "+100 %: 0.5 + 0.5")
  route(S, 2, "macro1", "filter_mix", -100)
  context.clear_engine_calls(); lfo_step(context, 10)
  local mixes = setfilter_mixes(context)
  assert_equal(#mixes, 1, "the return to 0 is sent once in ten steps")
  assert_near(mixes[1], 0.5, 1e-9, "with the stored value")
  assert_near(S.engine_param_values.filter_mix, 0.5, 1e-9, "the mix the engine has is the stored value")
  -- another layer moving the value is sent at the next step, once
  S.lib.engine_sync.set_extra_offset("test", "filter_mix", 0.2)
  context.clear_engine_calls(); lfo_step(context, 5)
  mixes = setfilter_mixes(context)
  assert_equal(#mixes, 1, "a move under the canceled routings is sent once")
  assert_near(mixes[1], 0.7, 1e-9, "with the other layer's offset")
  S.lib.engine_sync.set_extra_offset("test", "filter_mix", nil)
end)

test("matrix: an LFO's home and a routing that cancel to exactly 0 send once, then nothing (#760)", function()
  local context, S = loaded()
  params:set("filter_mix", 0.5)
  params:set("macro_16", 1)
  hold_lfo(S, 1, "filt mix", 100)              -- +0.5
  lfo_step(context)
  assert_near(engine_value(S, "filter_mix"), 1, 1e-9, "the home alone: 0.5 + 0.5")
  route(S, 1, "macro16", "filter_mix", -100)   -- -0.5
  context.clear_engine_calls(); lfo_step(context, 10)
  local mixes = setfilter_mixes(context)
  assert_equal(#mixes, 1, "the return to 0 is sent once in ten steps")
  assert_near(mixes[1], 0.5, 1e-9, "with the stored value")
  assert_near(S.engine_param_values.filter_mix, 0.5, 1e-9, "the mix the engine has is the stored value")
end)

test("matrix: a canceled destination is sent again when the engine forgot it (#760)", function()
  local context, S = loaded()
  params:set("filter_mix", 0.5)
  params:set("macro_1", 1)
  route(S, 1, "macro1", "filter_mix", 100)
  route(S, 2, "macro1", "filter_mix", -100)
  lfo_step(context, 3)
  S.engine_param_values.filter_mix = nil       -- what the budget's owner recorded, forgotten
  context.clear_engine_calls(); lfo_step(context, 5)
  local mixes = setfilter_mixes(context)
  assert_equal(#mixes, 1, "sent again once")
  assert_near(mixes[1], 0.5, 1e-9, "with the stored value")
  -- a voice param: a voice sync forgets what was sent for the voice
  local stored = params:get("v1_grain_spread")
  route(S, 3, "macro1", "v1_grain_spread", 40)
  route(S, 4, "macro1", "v1_grain_spread", -40)
  lfo_step(context, 3)
  context.clear_engine_calls(); lfo_step(context, 5)
  assert_equal(#grain_calls(context, 0, "posSpread"), 0, "canceled and held: nothing")
  sync_voice_values_to_engine(1)               -- forgets what was sent for voice 1
  assert_equal(S.engine_param_values.v1_grain_spread, nil, "the sync forgot the spread")
  context.clear_engine_calls(); lfo_step(context, 5)
  local spreads = grain_calls(context, 0, "posSpread")
  assert_equal(#spreads, 1, "after the sync the next step sends again, once")
  assert_near(spreads[1].args[3], stored, 1e-9, "the stored value")
end)

test("matrix: an idle step sends nothing and leaves no offset", function()
  local context, S, matrix = loaded()
  S.drift_metro:stop()
  context.clear_engine_calls(); lfo_step(context, 5)
  assert_equal(#context.engine_calls, 0, "nothing routed: nothing sent")
  for _, id in ipairs(matrix.destination_ids()) do assert_equal(matrix.offset(id), 0, id) end
  -- a routing cleared still gets its restore, once, and the matrix is idle again
  params:set("macro_1", 1)
  route(S, 1, "macro1", "reverb_mix", 40)
  route(S, 2, "macro1", "v3_grain_pitch", 40)
  lfo_step(context)
  matrix.clear(1); matrix.clear(2)
  context.clear_engine_calls(); lfo_step(context, 5)
  assert_equal(#context.calls_named("setReverb"), 1, "the Lua restore")
  assert_equal(#context.calls_named("setFastOffset"), 1, "the fast one's 0")
  context.clear_engine_calls(); lfo_step(context, 5)
  assert_equal(#context.engine_calls, 0, "idle again")
  assert_equal(matrix.offset("reverb_mix"), 0); assert_equal(matrix.offset("v3_grain_pitch"), 0)
end)

test("matrix: a hand edit of a destination is not deferrable", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  params:set("reverb_mix", 0.3)
  route(S, 1, "macro1", "reverb_mix", 40)
  lfo_step(context)
  local flags = {}
  local real_reverb = engine.setReverb
  engine.setReverb = function(...)
    table.insert(flags, S.deferrable_write)
    return real_reverb(...)
  end
  local ok, problem = pcall(enc_param_delta, 3, "reverb_mix", 1)
  rawset(engine, "setReverb", nil)
  if not ok then error(problem, 0) end
  assert_equal(#flags, 1, "the edit sends once")
  assert_equal(flags[1], false, "at once, never deferred")
  assert_near(sent_reverb(context), params:get("reverb_mix") + 0.2, 1e-9, "with the routing's offset")
end)

test("matrix: modulates around a step lock", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  -- a fast destination: the lock is the base the engine adds the offset to
  S.lib.engine_sync.set_base_override("v1_buf_pos", 0.3)
  route(S, 1, "macro1", "v1_buf_pos", 20)          -- 0.2 half ranges: +0.1
  context.clear_engine_calls(); lfo_step(context)
  assert_near(last_fast(context, 0, 1), 0.2, 1e-9, "the offset on voice 1's position (fast destination 1)")
  assert_near(engine_param_value("v1_buf_pos"), 0.3, 1e-9, "the engine holds the lock")
  assert_near(engine_param_value("v1_buf_pos") + last_fast(context, 0, 1) * 0.5, 0.4, 1e-9, "0.3 + 0.1 plays")
  -- a Lua destination: the send is the lock plus the routing
  local stored = params:get("v1_grain_spread")
  S.lib.engine_sync.set_base_override("v1_grain_spread", 0.3)
  route(S, 2, "macro1", "v1_grain_spread", 20)
  context.clear_engine_calls(); lfo_step(context)
  local spreads = grain_calls(context, 0, "posSpread")
  assert_equal(#spreads, 1, "one send")
  assert_near(spreads[1].args[3], 0.4, 1e-9, "0.3 + 0.1, around the lock")
  assert_near(params:get("v1_grain_spread"), stored, 1e-12, "the stored value stays")
end)

test("matrix: a new routing at depth 0 gets 25% from a MOD edit", function()
  local context, S, matrix = loaded()
  assert_equal(matrix.edit_routing(1, "macro1", ""), true, "a source alone")
  assert_equal(params:get("matrix_1_depth"), 0, "incomplete: the depth stays")
  assert_equal(matrix.edit_routing(1, "macro1", "reverb_mix"), true)
  assert_equal(params:get("matrix_1_depth"), 25, "completed at depth 0: 25 %, so it is heard")
  local routing = matrix.routing(1)
  assert_equal(routing.source, "macro1"); assert_equal(routing.dest, "reverb_mix")
  -- an edit of a routing that is already complete, or that completes away from 0, keeps the depth
  params:set("matrix_1_depth", -40)
  matrix.edit_routing(1, "macro1", "delay_mix")
  assert_equal(params:get("matrix_1_depth"), -40, "a new destination keeps the depth")
  params:set("matrix_2_depth", 0)
  matrix.edit_routing(2, "", "delay_mix")
  params:set("matrix_2_depth", 0)
  matrix.edit_routing(2, "lfo3", "delay_mix")
  assert_equal(params:get("matrix_2_depth"), 25, "completed from the destination's side too")
  params:set("matrix_3_depth", 10)
  matrix.edit_routing(3, "lfo1", "reverb_size")
  assert_equal(params:get("matrix_3_depth"), 10, "completed at 10: stays 10")
  -- an edit takes only known sources and destinations
  assert_equal(matrix.edit_routing(4, "no_such_source", "reverb_mix"), false, "an unknown source")
  assert_equal(matrix.edit_routing(4, "macro1", "macro_2"), false, "a macro is no destination")
  assert_equal(matrix.edit_routing(4, "macro1", "strata_lfo1_depth"), false, "nor an LFO param")
  assert_equal(matrix.edit_routing(4, "macro1", "matrix_1_depth"), false, "nor a matrix depth")
  assert_equal(matrix.edit_routing(17, "macro1", "reverb_mix"), false, "no routing 17")
  assert_equal(matrix.routing(4).source, "", "nothing was set")
end)

test("matrix: set_routing from a recall, morph or PSET load leaves depth 0", function()
  local context, S, matrix = loaded()
  assert_equal(matrix.set_routing(1, "macro1", "reverb_mix"), true)
  assert_equal(params:get("matrix_1_depth"), 0, "set_routing itself")
  capture_scene(1)                                -- R1 complete at depth 0
  matrix.set_routing(1, "", "")
  capture_scene(2)                                -- R1 empty
  recall_scene(1, 0)
  assert_equal(matrix.routing(1).dest, "reverb_mix", "recalled")
  assert_equal(params:get("matrix_1_depth"), 0, "a recall")
  local path = context.data_dir .. "strata-01.pset"
  params:write(path)
  matrix.set_routing(1, "", "")
  params:read(path)
  assert_equal(matrix.routing(1).source, "macro1", "loaded")
  assert_equal(params:get("matrix_1_depth"), 0, "a PSET load")
  recall_scene(2, 0)
  assert_equal(matrix.routing(1).source, "", "scene 2 empties it")
  params:set("morph_a", 2); params:set("morph_b", 1)
  params:set("morph", 1); context.clock.run_for(0.3)
  assert_equal(matrix.routing(1).dest, "reverb_mix", "morphed to scene 1")
  assert_equal(params:get("matrix_1_depth"), 0, "a morph")
end)

test("matrix: a routing that changes source or destination ramps through 0 in a transition and a morph", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  route(S, 1, "macro1", "v1_grain_spread", 40); capture_scene(1)
  route(S, 1, "macro1", "v1_buf_scan", 80); capture_scene(2)
  recall_scene(1, 0)
  assert_equal(matrix.routing(1).dest, "v1_grain_spread", "scene 1")
  -- a 2 s transition, 20 steps: A x (1 - 2f), the routing switched at f 0.5, then B x (2f - 1)
  recall_scene(2, 2)
  to_step(context, S, 5)
  assert_near(params:get("matrix_1_depth"), 20, 1e-9, "f 0.25: 40 x 0.5")
  assert_equal(matrix.routing(1).dest, "v1_grain_spread", "A's destination until the middle")
  to_step(context, S, 9)
  assert_near(params:get("matrix_1_depth"), 4, 1e-9, "f 0.45: 40 x 0.1")
  to_step(context, S, 10)
  assert_near(params:get("matrix_1_depth"), 0, 1e-9, "f 0.5: 0")
  assert_equal(matrix.routing(1).dest, "v1_buf_scan", "switched at the middle, at 0")
  to_step(context, S, 15)
  assert_near(params:get("matrix_1_depth"), 40, 1e-9, "f 0.75: 80 x 0.5")
  context.clock.run_for(1)
  assert_equal(S.scene_transition_active, false, "the transition ended")
  assert_near(params:get("matrix_1_depth"), 80, 1e-9, "B's depth")
  assert_equal(matrix.routing(1).dest, "v1_buf_scan")
  -- a morph from scene 1 to scene 2: the same ramp, the switch at the crossing
  recall_scene(1, 0)
  params:set("morph_a", 1); params:set("morph_b", 2)
  params:set("morph", 0.25); context.clock.run_for(0.3)
  assert_near(params:get("matrix_1_depth"), 20, 1e-9, "morph 0.25: 40 x 0.5")
  assert_equal(matrix.routing(1).dest, "v1_grain_spread")
  params:set("morph", 0.75); context.clock.run_for(0.3)
  assert_near(params:get("matrix_1_depth"), 40, 1e-9, "morph 0.75: 80 x 0.5")
  assert_equal(matrix.routing(1).dest, "v1_buf_scan")
end)

test("matrix: a macro LFO on a fast target joins the setFastOffset sum, clipped once", function()
  local context, S, matrix = loaded()
  local macros = S.lib.macros
  params:set("macro_2", 1)
  route(S, 1, "macro2", "v3_grain_pitch", 100)
  route(S, 2, "macro2", "v3_grain_pitch", 100)
  route(S, 3, "macro2", "v3_grain_pitch", 50)    -- the routings: 2.5 half ranges
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(last_fast(context, 2, 0), 2, "2.5, clamped to 2")
  -- macro 1 targets the same pitch, and LFO 1 square at its bottom at 100 %
  -- plays the macro at 0: its target 1.0 half range below the macro's 0.5
  macros.set_target(1, 1, "v3_grain_pitch", 0, 1)
  params:set("macro_1", 0.5); context.clock.run_for(0.05)
  hold_lfo(S, 1, "macro 1", 100, true)
  context.clock.run_for(0.25)
  -- one clamp of the whole sum: 2.5 - 1.0, where the routings clamped first would give 1.0
  assert_near(last_fast(context, 2, 0), 1.5, 1e-9, "the routings and the macro's extra, summed, then clamped")
  assert_near(matrix.offset("v3_grain_pitch"), 1.5, 1e-9)
  -- the macros' own call: an extra under its source key, nil clearing it
  matrix.set_fast_extra("macro9", "v3_grain_pitch", 3)
  lfo_step(context)
  assert_equal(last_fast(context, 2, 0), 2, "4.5, clamped to 2")
  matrix.set_fast_extra("macro9", "v3_grain_pitch", nil)
  lfo_step(context)
  assert_near(last_fast(context, 2, 0), 1.5, 1e-9, "the extra is gone")
  for _, call in ipairs(context.calls_named("setFastOffset")) do
    assert_true(math.abs(call.args[4]) <= 2, "never beyond 2: " .. call.args[4])
  end
  assert_near(params:get("v3_grain_pitch"), 2.125, 1e-9, "the macro's own value set the pitch, the LFO never")
end)

test("matrix: learn sets the destination from the next hand-touched param", function()
  local context, S, matrix = loaded()
  local flash = S.lib.ui_flash
  matrix.set_routing(3, "macro1", "")
  assert_equal(matrix.learn(3), true, "armed")
  assert_equal(matrix.learning(), 3)
  enc_param_delta(3, "v3_grain_pitch", 1)
  assert_equal(matrix.routing(3).dest, "v3_grain_pitch", "the touched param")
  assert_equal(flash.text("header"), "R3 > v3 pitch")
  assert_equal(params:get("matrix_3_depth"), 25, "learn is a MOD edit: completed at depth 0, it gets 25 %")
  assert_equal(matrix.learning(), nil, "learn ends")
  assert_equal(S.matrix_learn_clock, nil, "and its clock")
  -- a touched param that is no destination flashes, and learn waits on
  matrix.learn(4)
  for _, id in ipairs({ "macro_2", "strata_lfo1_depth", "matrix_1_depth", "filter_type" }) do
    enc_param_delta(3, id, 1)
    assert_equal(flash.text("header"), "not a destination", id .. " is no destination")
  end
  assert_equal(matrix.learning(), 4, "still learning")
  assert_equal(matrix.routing(4).dest, "")
  -- a voice's main param learns the voice's main entry
  enc_param_delta(3, main_param_id(4), 1)
  assert_equal(matrix.routing(4).dest, "v4_main")
  assert_equal(flash.text("header"), "R4 > v4 main")
  assert_equal(params:get("matrix_4_depth"), 0, "no source: incomplete, the depth stays")
  -- 10 s without a touch cancels
  matrix.learn(5)
  context.clock.run_for(10.1)
  assert_equal(matrix.learning(), nil, "canceled after 10 s")
  enc_param_delta(3, "reverb_mix", 1)
  assert_equal(matrix.routing(5).dest, "", "a later touch learns nothing")
  matrix.learn(6)
  matrix.cancel_learn()
  assert_equal(matrix.learning(), nil, "cancel_learn")
  assert_equal(S.matrix_learn_clock, nil)
  assert_equal(matrix.learn(17), false, "no routing 17")
end)

-- #626: learn's timeout clock is retired, never canceled, so learn ending
-- (K2, a touch, a new learn) as its 10 s resume is posted raises nothing
-- and the old clock ends nothing a newer learn armed
test("matrix: learn ending as its timeout's resume is posted retires the clock, never cancels it (#626)", function()
  local context, S, matrix = loaded()
  local function at_timeout(fn)
    context.clock.advance_until(S.matrix_learn_clock, fn)
    local errors = context.clock.take_errors()
    assert_equal(#errors, 0, "no resume reaches a canceled clock: " .. table.concat(errors, "; "))
  end
  matrix.learn(1)
  at_timeout(function() matrix.cancel_learn() end)                       -- K2
  assert_equal(matrix.learning(), nil)
  matrix.learn(2)
  at_timeout(function() enc_param_delta(3, "reverb_mix", 1) end)          -- a touch
  assert_equal(matrix.routing(2).dest, "reverb_mix", "the touch learned")
  matrix.learn(3)
  at_timeout(function() matrix.learn(4) end)                             -- a new learn
  assert_equal(matrix.learning(), 4, "the new learn still waits")
  assert_true(S.matrix_learn_clock ~= nil, "on its own clock")
  context.clock.run_for(10.1)
  assert_equal(matrix.learning(), nil, "and times out 10 s after it was armed")
  -- long before its wake no resume can be posted: the clock is canceled,
  -- so a burst of learns holds no clock slots
  matrix.learn(5)
  local early = S.matrix_learn_clock
  matrix.cancel_learn()
  assert_equal(clock.threads[early], nil, "an early end cancels the clock")
  -- cleanup cancels a retired clock still waiting
  matrix.learn(5)
  local retired = S.matrix_learn_clock
  context.clock.run_for(9.95)
  matrix.cancel_learn()
  assert_true(clock.threads[retired] ~= nil, "near its wake the clock is retired, and waits for its wake")
  cleanup()
  assert_equal(clock.threads[retired], nil, "cleanup cancels it")
end)

-- 3.9 (#870): learn's timeout clock is the clock helper's, which retires it
test("the matrix learn clock stopped as its wake is posted: no clock error, and nothing more happens", function()
  local context, S, matrix = loaded()
  matrix.learn(1)
  local id = S.matrix_learn_clock
  context.clock.advance_until(id, function()
    matrix.learn(4)  -- a new learn ends the old one
    assert_true(S.lib.clocks.retired[id] ~= nil, "the helper retired the old clock: its resume is posted")
  end)
  local errors = context.clock.take_errors()
  assert_equal(#errors, 0, "no resume reaches a canceled clock: " .. table.concat(errors, "; "))
  assert_equal(clock.threads[id], nil, "the old clock ended at its wake")
  assert_equal(S.lib.clocks.retired[id], nil, "and the helper forgot it")
  assert_equal(matrix.learning(), 4, "the newer learn still waits")
  assert_true(S.matrix_learn_clock ~= nil and S.matrix_learn_clock ~= id, "on its own clock")
end)

-- The `matrix learn` invariant (docs/notes/lua/matrix.md, Machines): learn
-- waits exactly while its clock is S.matrix_learn_clock, and a retired
-- clock is never that clock
test("the invariant matrix learn fails for learn waiting with no clock and for a retired clock kept", function()
  local _, S, matrix = loaded()
  local check
  for _, record in ipairs(S.registry.invariants) do
    if record.name == "matrix learn" then check = record.fn end
  end
  assert_true(check ~= nil, "registered")
  assert_equal(check(), nil, "idle: it holds")
  matrix.learn(3)
  assert_equal(check(), nil, "armed on its clock: it holds")
  h.allow_broken_invariants("the test breaks the matrix learn invariant on purpose")
  local id = S.matrix_learn_clock
  S.matrix_learn_clock = nil
  assert_true(tostring((check())):find("learn waits: true", 1, true) ~= nil, "learn waiting with no clock: " .. tostring((check())))
  S.matrix_learn_clock = id
  S.lib.clocks.retired[id] = true
  assert_true(tostring((check())):find("retired", 1, true) ~= nil, "a retired clock kept as learn's: " .. tostring((check())))
  S.lib.clocks.retired[id] = nil
  matrix.cancel_learn()
  S.matrix_learn_clock = id
  assert_true(tostring((check())):find("learn waits: false", 1, true) ~= nil, "a clock with no learn: " .. tostring((check())))
  S.matrix_learn_clock = nil
  assert_equal(check(), nil, "idle again: it holds")
end)

-- The machine `matrix learn` (docs/notes/lua/matrix.md, Machines): armed
-- is learn waiting (S.lib.matrix.learning()); armed for routing 3, whose
-- source is set so a learned destination completes it
local LEARN_ROUTING = 3
local function learn_enter(armed)
  return function(context)
    local S = local_value("S")
    S.lib.matrix.set_routing(LEARN_ROUTING, "macro1", "")
    if armed then
      assert_true(S.lib.matrix.learn(LEARN_ROUTING), "armed")
      context.learn_clock = S.matrix_learn_clock
    end
  end
end
local function learning_routing(k, same_clock)
  return function(context)
    local S = local_value("S")
    assert_equal(S.lib.matrix.learning(), k, "learn waits for routing " .. k)
    if same_clock then
      assert_equal(S.matrix_learn_clock, context.learn_clock, "on the same clock")
    else
      assert_true(S.matrix_learn_clock ~= context.learn_clock, "on a new clock")
      assert_equal(clock.threads[context.learn_clock], nil, "the old clock canceled")
    end
  end
end
local function learned(dest)
  return function() assert_equal(local_value("S").lib.matrix.routing(LEARN_ROUTING).dest, dest, "routing 3's destination") end
end
local function step_fn(steps, order)
  for _, record in ipairs(steps) do
    if record.order == order then return record.fn end
  end
  error("no step at order " .. tostring(order))
end

h.transition_table({
  name = "matrix learn",
  notes = { "docs/notes/lua/matrix.md", "matrix learn" },
  states = { idle = learn_enter(false), armed = learn_enter(true) },
  events = {
    ["learn"] = function() local_value("S").lib.matrix.learn(5) end,
    ["learn of no routing"] = function()
      assert_equal(local_value("S").lib.matrix.learn(local_value("S").constants.MATRIX_SLOTS + 1), false, "refused")
    end,
    ["a touch of a destination"] = function() enc_param_delta(3, "reverb_mix", 1) end,
    ["a touch of another param"] = function() enc_param_delta(3, "strata_lfo1_depth", 1) end,
    ["cancel_learn"] = function() local_value("S").lib.matrix.cancel_learn() end,
    ["the timeout"] = function(context) context.clock.run_for(10.1) end,
    ["a page change"] = function()
      local S = local_value("S")
      local index = S.constants.UI_PAGES.index
      S.lib.ui_keys.set_ui_page(S.ui_page == index.FX and index.MAIN or index.FX)
    end,
    ["the cleanup step"] = function()
      local S = local_value("S")
      step_fn(S.registry.cleanup, S.constants.CLEANUP_ORDER.matrix)()
    end,
  },
  state_of = function()
    return local_value("S").lib.matrix.learning() == nil and "idle" or "armed"
  end,
  rows = {
    { "idle", "learn", "armed", check = function()
      local S = local_value("S")
      assert_equal(S.lib.matrix.learning(), 5)
      assert_true(clock.threads[S.matrix_learn_clock] ~= nil, "its clock runs")
    end },
    { "idle", "learn of no routing", "idle" },
    { "idle", "a touch of a destination", "idle", check = learned("") },
    { "idle", "a touch of another param", "idle" },
    { "idle", "cancel_learn", "idle" },
    { "idle", "the timeout", "idle" },
    { "idle", "a page change", "idle" },
    { "idle", "the cleanup step", "idle" },
    { "armed", "learn", "armed", check = learning_routing(5, false) },
    { "armed", "learn of no routing", "armed", check = learning_routing(LEARN_ROUTING, true) },
    { "armed", "a touch of a destination", "idle", check = function(context)
      learned("reverb_mix")()
      assert_equal(clock.threads[context.learn_clock], nil, "the clock canceled")
      assert_equal(local_value("S").lib.ui_flash.text("header"), "R3 > rev mix")
      local S = local_value("S")
      assert_true(S.lib.mutation.undo_for(S.constants.UI_PAGES.index.MOD, "matrix", nil),
        "the undo holds the rewire on MOD's matrix (#927)")
    end },
    { "armed", "a touch of another param", "armed", check = function(context)
      learning_routing(LEARN_ROUTING, true)(context)
      assert_equal(local_value("S").lib.ui_flash.text("header"), "not a destination")
    end },
    { "armed", "cancel_learn", "idle", check = function(context)
      assert_equal(clock.threads[context.learn_clock], nil, "the clock canceled")
    end },
    { "armed", "the timeout", "idle" },
    { "armed", "a page change", "armed", check = learning_routing(LEARN_ROUTING, true) },
    { "armed", "the cleanup step", "idle", check = function(context)
      assert_equal(clock.threads[context.learn_clock], nil, "its clock canceled outright")
    end },
  },
})

-- Every flash learn raises fits the header's flash room
-- (S.constants.HEADER.flash_width) whole: the refusal, and a learned
-- destination for the widest routing number and the widest label
test("matrix: every flash of learn fits the header's flash room", function()
  local context, S, matrix = loaded()
  local room, flash = S.constants.HEADER.flash_width, S.lib.ui_flash
  local function touched(id)
    local voice = id:match("^v(%d+)_main$")
    return voice and main_param_id(tonumber(voice)) or id
  end
  local function learned(k, id)
    matrix.learn(k)
    enc_param_delta(3, touched(id), 1)
    return flash.text("header")
  end
  local widest_k
  for k = 1, 16 do
    if not widest_k or h.text_width("R" .. k) > h.text_width("R" .. widest_k) then widest_k = k end
  end
  local flashes, widest_id, widest = {}, nil, -1
  for _, id in ipairs(matrix.destination_ids()) do
    local text = learned(widest_k, id)
    table.insert(flashes, text)
    if h.text_width(text) > widest then widest_id, widest = id, h.text_width(text) end
  end
  for k = 1, 16 do table.insert(flashes, learned(k, widest_id)) end
  matrix.learn(1)
  enc_param_delta(3, "macro_2", 1)
  table.insert(flashes, flash.text("header"))
  matrix.cancel_learn()
  for _, text in ipairs(flashes) do
    assert_true(h.text_width(text) <= room, text .. " (" .. h.text_width(text) .. " px) fits the header's " .. room .. " px")
  end
  context.clock.run_for(2)
end)

test("matrix: unknown source keys and destination ids are kept verbatim through a load and a save, with a console line", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  params:set("matrix_1_depth", 50); params:set("matrix_2_depth", 50)
  local path = context.data_dir .. "strata-03.pset"
  local side = context.data_dir .. "strata-03.matrix.data"
  params:write(path)
  assert_true(S.lib.data_files.write(side, { version = 1, matrix = {
    [1] = { source = "future_source", dest = "reverb_mix" },
    [2] = { source = "macro1", dest = "v9_grain_pitch" } } }))
  params:read(path)
  assert_equal(matrix.routing(1).source, "future_source", "kept")
  assert_equal(matrix.routing(2).dest, "v9_grain_pitch", "kept")
  assert_true(printed_with(context, "future_source") ~= nil, "a console line names the source")
  assert_true(printed_with(context, "v9_grain_pitch") ~= nil, "and the destination")
  context.clear_engine_calls(); lfo_step(context, 3)
  assert_equal(#context.calls_named("setFastOffset"), 0, "neither plays")
  assert_equal(#context.calls_named("setReverb"), 0)
  assert_near(engine_value(S, "reverb_mix"), params:get("reverb_mix"), 1e-12, "no offset")
  assert_equal(matrix.uses_source("future_source"), false)
  params:write(path)
  local saved = S.lib.data_files.read(side)
  assert_equal(saved.matrix[1].source, "future_source", "saved again as it was")
  assert_equal(saved.matrix[2].dest, "v9_grain_pitch")
  capture_scene(1)
  assert_equal(S.scenes[1].data.matrix[1].source, "future_source", "a scene keeps it too")
  cleanup()
  local _, _, next_matrix = loaded({ data_subdir = data_dir_name(context) })
  assert_equal(next_matrix.routing(1).source, "future_source", "through the live file")
  assert_equal(next_matrix.routing(2).dest, "v9_grain_pitch")
end)

test("matrix: scenes capture routings, crossfade depths and switch routings at the end", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  route(S, 1, "macro1", "reverb_mix", 20)
  route(S, 2, "macro1", "delay_mix", 30)
  capture_scene(1)
  local data = S.scenes[1].data
  assert_equal(data.matrix[1].source, "macro1"); assert_equal(data.matrix[1].dest, "reverb_mix")
  assert_equal(data.matrix[2].dest, "delay_mix")
  assert_equal(entry_count(data.matrix), 2, "sparse: only the routings that are set")
  assert_equal(data.matrix_1_depth, 20, "the depths are scene fields")
  assert_equal(data.matrix_1, 1, "and the on/off")
  params:set("matrix_1_depth", 60); params:set("matrix_1", 0)       -- scene 2: R1 at 60, off
  route(S, 2, "macro1", "v1_grain_spread", 50)                         -- and R2 elsewhere
  capture_scene(2)
  recall_scene(1, 0)
  assert_equal(params:get("matrix_1"), 1, "scene 1: on")
  assert_equal(params:get("matrix_1_depth"), 20)
  assert_equal(matrix.routing(2).dest, "delay_mix")
  recall_scene(2, 2)
  to_step(context, S, 10)                         -- f 0.5
  assert_near(params:get("matrix_1_depth"), 40, 1e-9, "a routing that stays crossfades its depth: 20 to 60")
  assert_equal(matrix.routing(1).dest, "reverb_mix")
  to_step(context, S, 19)
  assert_equal(params:get("matrix_1"), 1, "on/off switches only at the end")
  context.clock.run_for(0.5)
  assert_equal(S.scene_transition_active, false, "the transition ended")
  assert_equal(params:get("matrix_1"), 0, "off at the end")
  assert_near(params:get("matrix_1_depth"), 60, 1e-9)
  assert_equal(matrix.routing(2).dest, "v1_grain_spread", "scene 2's routing")
  assert_near(params:get("matrix_2_depth"), 50, 1e-9)
  -- an instant recall applies the routings and every field at once
  recall_scene(1, 0)
  assert_equal(matrix.routing(2).dest, "delay_mix")
  assert_equal(params:get("matrix_2_depth"), 30)
  assert_equal(params:get("matrix_1"), 1)
end)

test("matrix: a format 5 file loads 16 empty routings at depth 0, on", function()
  local context, S, matrix = loaded()
  capture_scene(1)
  local scenes = h.deep_copy(S.scenes)
  local data = scenes[1].data
  data.matrix = nil
  for k = 1, 16 do
    data["matrix_" .. k .. "_depth"] = nil
    data["matrix_" .. k] = nil
  end
  util.make_dir(context.data_dir .. "strata")
  assert_true(S.lib.data_files.write(context.data_dir .. "strata/scenes.data", { version = 5, scenes = scenes }))
  -- what the session holds before the old file is read and recalled
  params:set("macro_1", 1)
  route(S, 1, "macro1", "reverb_mix", 40)
  route(S, 9, "lfo2", "v3_grain_pitch", -70)
  params:set("matrix_9", 0)
  load_scenes_from_disk()
  assert_true(S.scenes[1].populated and validate_scene(S.scenes[1]), "the old scene loads")
  assert_equal(next(S.scenes[1].data.matrix), nil, "with an empty block")
  recall_scene(1, 0)
  for k = 1, 16 do
    local routing = matrix.routing(k)
    assert_equal(routing.source, "", "routing " .. k .. " empty")
    assert_equal(routing.dest, "", "routing " .. k .. " empty")
    assert_equal(routing.depth, 0, "routing " .. k .. " at depth 0")
    assert_equal(routing.on, true, "routing " .. k .. " on")
  end
end)

test("matrix: the PSET side file and matrix.data round-trip", function()
  local context, S, matrix = loaded()
  local function fill(m)
    m.set_routing(1, "macro1", "reverb_mix")
    m.set_routing(5, "lfo2", "v3_main")
    m.set_routing(16, "input", "v1_amp")
  end
  local function assert_filled(where, m)
    assert_equal(m.routing(1).source, "macro1", where); assert_equal(m.routing(1).dest, "reverb_mix", where)
    assert_equal(m.routing(5).source, "lfo2", where); assert_equal(m.routing(5).dest, "v3_main", where)
    assert_equal(m.routing(16).source, "input", where); assert_equal(m.routing(16).dest, "v1_amp", where)
    local count = 0
    for k = 1, 16 do if m.routing(k).source ~= "" then count = count + 1 end end
    assert_equal(count, 3, where .. ": three routings")
  end
  local function clear_all(m) for k = 1, 16 do m.set_routing(k, "", "") end end
  fill(matrix)
  local path = context.data_dir .. "strata-04.pset"
  params:write(path)
  local side = S.lib.data_files.read(context.data_dir .. "strata-04.matrix.data")
  assert_equal(side.version, 2, "the side file's format")
  assert_equal(entry_count(side.matrix), 3, "sparse")
  assert_equal(side.matrix[5].dest, "v3_main")
  clear_all(matrix)
  params:read(path)
  assert_filled("from the PSET", matrix)
  -- the live file follows the routings, and is loaded at the next start
  context.clock.run_for(0.2)
  local live = S.lib.data_files.read(context.data_dir .. "strata/matrix.data")
  assert_equal(entry_count(live.matrix), 3, "saved as the routings changed")
  cleanup()
  local _, _, next_matrix = loaded({ data_subdir = data_dir_name(context) })
  assert_filled("after a restart", next_matrix)
end)

test("matrix: macros target matrix depths", function()
  local context, S, matrix = loaded()
  local macros = S.lib.macros
  local listed = {}
  for index, id in ipairs(macros.target_ids()) do listed[id] = index end
  -- (after the LFO destinations but none and the macros, read from the
  -- list, and the six LFOs' rates and depths)
  local destinations = #S.LFO_DESTINATIONS - 1 - 16
  for k = 1, 16 do
    assert_equal(listed["matrix_" .. k .. "_depth"], destinations + 12 + k, "R" .. k .. "'s depth, after the LFOs' rates and depths")
  end
  assert_equal(macros.target_label("matrix_3_depth"), "R3 depth")
  macros.set_target(1, 1, "matrix_1_depth", 0, 1)
  params:set("macro_2", 1)
  matrix.set_routing(1, "macro2", "v3_grain_pitch")
  context.clear_engine_calls()
  params:set("macro_1", 0.75); context.clock.run_for(0.05)
  assert_near(params:get("matrix_1_depth"), 50, 1e-9, "-100 + 0.75 x 200")
  lfo_step(context)
  assert_near(last_fast(context, 2, 0), 0.5, 1e-9, "the routing plays at the macro's depth")
  -- and no LFO reaches a depth: the LFO destinations hold none
  for _, entry in ipairs(S.LFO_DESTINATIONS) do
    assert_true(not tostring(entry.resolve()):match("^matrix_"), entry.label .. " is no matrix depth")
  end
end)

test("matrix: morph switches routings at 0.52 and 0.48", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  route(S, 1, "macro1", "v1_grain_spread", 40); capture_scene(1)
  route(S, 1, "macro1", "v1_buf_scan", 80); capture_scene(2)
  recall_scene(1, 0)
  params:set("morph_a", 1); params:set("morph_b", 2)
  local function morph_to(position)
    params:set("morph", position); context.clock.run_for(0.3)
    return matrix.routing(1).dest, params:get("matrix_1_depth")
  end
  local dest, depth = morph_to(0.2)
  assert_equal(dest, "v1_grain_spread", "A's side")
  dest, depth = morph_to(0.51)
  assert_equal(dest, "v1_grain_spread", "0.51: still A's")
  assert_equal(depth, 0, "its depth ramped to 0")
  dest, depth = morph_to(0.52)
  assert_equal(dest, "v1_buf_scan", "0.52: B's")
  assert_equal(depth, util.round(80 * 0.04), "B's depth rising from 0, on its whole-percent step")
  dest, depth = morph_to(0.49)
  assert_equal(dest, "v1_buf_scan", "0.49: still B's")
  assert_equal(depth, 0)
  dest, depth = morph_to(0.48)
  assert_equal(dest, "v1_grain_spread", "0.48: back to A's")
  assert_equal(depth, util.round(40 * 0.04))
end)

test("matrix: v<i> main follows the voice's source", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  local main = main_param_id(1)
  local low, high = param_range(main)
  params:set(main, low + 0.25 * (high - low))     -- room for the offset
  route(S, 1, "macro1", "v1_main", 50)            -- 0.5 half ranges
  context.clear_engine_calls(); lfo_step(context)
  assert_near(matrix.offset(main), 0.25 * (high - low), 1e-9, "a synth voice's main param, in Lua")
  assert_near(engine_value(S, main), params:get(main) + 0.25 * (high - low), 1e-9)
  assert_equal(#fast_calls(context, 0, 1), 0, "not on the position")
  assert_true(matrix.affects(1), "voice 1 is modulated")
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)   -- a buffer: the main param is the position
  assert_equal(main_param_id(1), "v1_buf_pos")
  context.clear_engine_calls(); lfo_step(context, 2)
  assert_near(last_fast(context, 0, 1), 0.5, 1e-9, "the position, on the fast path")
  assert_equal(matrix.offset(main), 0, "the synth param it left has no offset")
  assert_near(engine_value(S, main), params:get(main), 1e-12)
end)

-- 3.8 (package 0d): v<i>_main resolves at each step, so a type change moves
-- the routing to the new type's main param; the old one's offset returns
-- to 0, recorded only (its key is hidden: its sender reaches no engine)
test("matrix: a routing on v1_main follows a type change", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  local old_main = main_param_id(1)
  assert_equal(old_main, "v1_freq", "resonator's main is its pitch")
  route(S, 1, "macro1", "v1_main", 50)
  lfo_step(context)
  assert_true(matrix.offset(old_main) ~= 0, "the old main moves")
  params:set("v1_type", S.lib.types.record("fm").index)
  local new_main = main_param_id(1)
  assert_equal(new_main, "v1_index", "fm's main")
  local low, high = param_range(new_main)
  params:set(new_main, low + 0.25 * (high - low))
  context.clear_engine_calls(); lfo_step(context, 2)
  assert_near(matrix.offset(new_main), 0.25 * (high - low), 1e-9, "the new main gets the offset")
  assert_equal(matrix.offset(old_main), 0, "the old main gives its offset back (#839)")
  assert_equal(engine_value(S, old_main), params:get(old_main), "and holds no extra offset: its stored value")
  local index_sent
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 0 and call.args[2] == "index" then index_sent = call.args[3] end
  end
  assert_near(index_sent, params:get(new_main) + 0.25 * (high - low), 1e-9, "and it reaches the engine")
  params:set("v1_type", 1)
  context.clear_engine_calls(); lfo_step(context, 2)
  assert_equal(matrix.offset(new_main), 0, "back on resonator, fm's index holds no offset")
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    assert_true(not (call.args[1] == 0 and call.args[2] == "index"), "and its hidden key sends nothing")
  end
end)

test("matrix: uses_source and affects", function()
  local context, S, matrix = loaded()
  route(S, 1, "lfo2", "v3_grain_pitch", 40)
  assert_equal(matrix.uses_source("lfo2"), true, "lfo2 is routed")
  assert_equal(matrix.uses_source("lfo3"), false)
  assert_equal(matrix.affects(3), true, "voice 3's pitch")
  assert_equal(matrix.affects(4), false)
  params:set("matrix_1", 0)
  assert_equal(matrix.uses_source("lfo2"), false, "off")
  assert_equal(matrix.affects(3), false, "off")
end)

test("matrix: a PSET without a side file loads empty", function()
  local context, S, matrix = loaded()
  local path = context.data_dir .. "strata-05.pset"
  params:write(path)
  os.remove(context.data_dir .. "strata-05.matrix.data")
  matrix.set_routing(3, "macro1", "reverb_mix")
  params:read(path)
  assert_equal(matrix.routing(3).source, "", "a PSET from before 3.4 held no routings")
  assert_equal(matrix.routing(3).dest, "")
end)

test("matrix: an unreadable side file is set aside and the PSET still loads", function()
  local contents = {
    "return {\n  {1},\n",                                                            -- not a data file
    { version = 3, matrix = {} },                                                     -- another version
    { version = 1, matrix = { [23] = { source = "macro1", dest = "reverb_mix" } } },  -- no routing 23
    { version = 2, matrix = { [17] = { source = "lfo2", dest = "reverb_mix" } } },    -- a home's source not lfo1
    { version = 1, matrix = { [1] = { source = 4, dest = "reverb_mix" } } },          -- a source that is no string
    { version = 1, matrix = { [1] = { source = "macro1", dest = string.rep("x", 33) } } },  -- longer than 32
    { version = 1, matrix = 7 },                                                      -- no table of routings
  }
  for index, content in ipairs(contents) do
    local context, S, matrix = loaded()
    params:set("reverb_mix", 0.7)
    local path = context.data_dir .. "strata-06.pset"
    params:write(path)
    local side = context.data_dir .. "strata-06.matrix.data"
    h.write_text(side, type(content) == "table" and S.lib.data_files.encode(content) or content)
    matrix.set_routing(1, "macro1", "delay_mix")
    params:set("reverb_mix", 0.2)
    params:read(path)
    assert_near(params:get("reverb_mix"), 0.7, 1e-9, "case " .. index .. ": the PSET loaded")
    assert_equal(matrix.routing(1).source, "", "case " .. index .. ": the routings are empty")
    assert_true(not util.file_exists(side), "case " .. index .. ": the file is moved")
    assert_true(util.file_exists(side .. ".bak"), "case " .. index .. ": to its first free backup name")
    local line = printed_with(context, ".bak")
    assert_true(line ~= nil and line:find("matrix", 1, true) ~= nil, "case " .. index .. ": a console line names it")
  end
end)

test("matrix: a non-finite source value sends nothing", function()
  local context, S, matrix = loaded()
  local probe = seeded(S, "probe", { -1, 1 }, 0 / 0)
  route(S, 1, "probe", "v3_grain_pitch", 100)
  route(S, 2, "probe", "reverb_mix", 100)
  for _, value in ipairs({ 0 / 0, math.huge, -math.huge }) do
    probe.value = value
    context.clear_engine_calls(); lfo_step(context, 3)
    assert_equal(#context.calls_named("setFastOffset"), 0, tostring(value) .. ": no setFastOffset")
    assert_equal(#context.calls_named("setReverb"), 0, tostring(value) .. ": no send")
    assert_near(engine_value(S, "reverb_mix"), params:get("reverb_mix"), 1e-12, tostring(value) .. ": no extra offset")
    assert_equal(matrix.offset("reverb_mix"), 0); assert_equal(matrix.offset("v3_grain_pitch"), 0)
  end
  probe.value = 0.5                               -- bipolar: s 0.5
  context.clear_engine_calls(); lfo_step(context)
  assert_near(last_fast(context, 2, 0), 0.5, 1e-9, "a finite value plays")
end)

test("matrix: the input level ducks a voice", function()
  local context, S, matrix = loaded()
  context.polls.fire("amp_in_l", 0.125)
  assert_near(S.lib.input_level.value(), 0.5, 1e-9, "0.125 x the gain 4")
  route(S, 1, "input", "v1_amp", -50)
  context.clear_engine_calls(); lfo_step(context)
  local fast = fast_calls(context, 0, 4)
  assert_equal(#fast, 1, "voice 1's level (fast destination 4)")
  assert_near(fast[1].args[4], -0.25, 1e-9, "-50 % of 0.5")
end)

test("matrix: a fast destination's sum is clamped to -2..2 before it is sent", function()
  local context, S, matrix = loaded()
  seeded(S, "probe", { 0, 1 }, 1)
  for k = 1, 3 do route(S, k, "probe", "v3_grain_pitch", 100) end
  context.clear_engine_calls(); lfo_step(context, 2)
  local fast = fast_calls(context, 2, 0)
  assert_equal(#fast, 1, "one send")
  assert_equal(fast[1].args[4], 2, "three routings of +100 %: 2, never 3")
  for k = 1, 3 do params:set("matrix_" .. k .. "_depth", -100) end
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(last_fast(context, 2, 0), -2, "and -2 below")
end)

test("matrix: a fast destination whose sum returns to 0 is sent 0 once, however small its last offset", function()
  local context, S, matrix = loaded()
  local probe = seeded(S, "probe", { 0, 1 }, 0.0015)
  route(S, 1, "probe", "v3_grain_pitch", 100)
  context.clear_engine_calls(); lfo_step(context)
  assert_near(last_fast(context, 2, 0), 0.0015, 1e-12, "sent")
  probe.value = 0.0004                            -- moved by more than 1/1000
  lfo_step(context)
  assert_near(last_fast(context, 2, 0), 0.0004, 1e-12, "sent again")
  probe.value = 0                                 -- back to 0: a move under 1/1000, sent all the same
  context.clear_engine_calls(); lfo_step(context, 3)
  local fast = fast_calls(context, 2, 0)
  assert_equal(#fast, 1, "sent once more")
  assert_equal(fast[1].args[4], 0, "at 0, so the engine holds no offset")
end)

test("matrix: an LFO on a macro skips the macro's matrix-depth targets", function()
  local context, S, matrix = loaded()
  local macros = S.lib.macros
  macros.set_target(1, 1, "matrix_1_depth", 0, 1)
  macros.set_target(1, 2, "reverb_mix", 0, 1)
  params:set("macro_1", 0.5); context.clock.run_for(0.05)
  assert_near(params:get("matrix_1_depth"), 0, 1e-9, "the macro's own value moves the depth")
  params:set("macro_2", 1)
  matrix.set_routing(1, "macro2", "v3_grain_pitch")
  context.clear_engine_calls()
  hold_lfo(S, 1, "macro 1", 100)                  -- the macro plays at 1
  context.clock.run_for(0.25)
  assert_near(engine_value(S, "reverb_mix"), 1, 1e-9, "a destination target takes the LFO's offset")
  assert_near(engine_value(S, "matrix_1_depth"), 0, 1e-12, "the matrix depth takes none")
  assert_near(params:get("matrix_1_depth"), 0, 1e-12, "and its param stays")
  assert_equal(#fast_calls(context, 2, 0), 0, "so the routing stays at depth 0, silent")
end)

test("matrix: writing a PSET always writes its side file", function()
  local context, S, matrix = loaded()
  local path = context.data_dir .. "strata-02.pset"
  local side = context.data_dir .. "strata-02.matrix.data"
  matrix.set_routing(1, "macro1", "reverb_mix")
  params:write(path)
  assert_true(util.file_exists(side), "the PSET's side file")
  matrix.set_routing(1, "", "")
  params:write(path)                              -- saved over with no routings
  assert_true(util.file_exists(side), "an empty side file is written too")
  matrix.set_routing(7, "lfo1", "delay_mix")
  params:read(path)
  assert_equal(matrix.routing(1).source, "", "the empty save replaced the routings")
  assert_equal(matrix.routing(7).source, "", "and nothing of the moment before stays")
  params:delete(path)
  assert_true(not util.file_exists(side), "deleted with its PSET")
end)

test("matrix: its destinations are the LFO destinations but none and the macros, by param id", function()
  local context, S, matrix = loaded()
  local ids = matrix.destination_ids()
  assert_equal(#ids, 119, "the 67 built-in destinations, the 49 registered per-voice ones (1c's shape and skew among them), 1a's dly>rev and 2a's shim dly and shim rev")
  assert_equal(ids[1], "master_density", "without none")
  assert_equal(ids[11], "reverb_damp")
  assert_equal(ids[12], "delay_to_reverb", "the registered global (3.8, 1a)")
  assert_equal(ids[13], "shimmer_delay", "2a's"); assert_equal(ids[14], "shimmer_reverb")
  assert_equal(ids[15], "v1_main", "a voice's main entry")
  assert_equal(ids[16], "v1_grain_size")
  assert_equal(ids[#ids], "v7_amp", "the registered ones, to v7 amp, last")
  for _, id in ipairs(ids) do
    assert_true(not id:match("^macro_") and not id:match("^strata_lfo") and not id:match("^matrix_"),
      id .. " is no macro, LFO param or matrix depth")
  end
  ids[1] = "changed"
  assert_equal(matrix.destination_ids()[1], "master_density", "a copy")
  assert_equal(matrix.routing(0), nil, "no routing 0"); assert_equal(matrix.routing(17), nil)
end)

-- 3.7 (decision 24): the picker's order is the LFO list's, by voice
test("the routing view's destinations come in the same order", function()
  local _, S, matrix = loaded()
  local ids = matrix.destination_ids()
  local expected = {}
  for _, destination in ipairs(S.LFO_DESTINATIONS) do
    if destination.key ~= "none" and not destination.key:match("^macro_") then expected[#expected + 1] = destination.key end
  end
  assert_equal(table.concat(ids, ","), table.concat(expected, ","), "the LFO destinations' keys, in their order")
  -- each voice's destinations together: voice 3's from its main to its amp
  local voice3 = {}
  for index = 1, #ids do
    if ids[index]:match("^v3_") then voice3[#voice3 + 1] = index end
  end
  assert_equal(#voice3, 15, "15 destinations of voice 3")
  assert_equal(voice3[#voice3] - voice3[1], 14, "one run, nothing between them")
  assert_equal(ids[voice3[1]], "v3_main"); assert_equal(ids[voice3[#voice3]], "v3_amp")
  assert_equal(ids[voice3[1] - 1], "v2_amp", "after voice 2's last")
  assert_equal(ids[voice3[#voice3] + 1], "v4_main", "before voice 4's first")
end)

test("matrix: cleanup cancels learn and forgets its offsets, sending nothing", function()
  local context, S, matrix = loaded()
  params:set("macro_1", 1)
  route(S, 1, "macro1", "reverb_mix", 40)
  route(S, 2, "macro1", "v3_grain_pitch", 40)
  lfo_step(context)
  matrix.learn(3)
  local step
  for _, record in ipairs(S.registry.cleanup) do
    if record.order == S.constants.CLEANUP_ORDER.matrix then step = record.fn end
  end
  assert_true(step ~= nil, "a cleanup step at CLEANUP_ORDER.matrix")
  context.clear_engine_calls()
  step()
  assert_equal(#context.engine_calls, 0, "no engine command (norns has freed the engine, #461)")
  assert_equal(matrix.learning(), nil, "learn canceled")
  assert_equal(S.matrix_learn_clock, nil)
  assert_near(engine_value(S, "reverb_mix"), params:get("reverb_mix"), 1e-12, "the extra offset is gone")
end)

-- A scenes file of 16 scenes, each with 16 full macros, 16 routings, six
-- home routings and attributes on every step, loads
test("16 full scenes with six homes write 6898 tables", function()
  local context, S, matrix = loaded()
  local macros = S.lib.macros
  local NUM_VOICES, PATTERN_LENGTH = S.constants.NUM_VOICES, S.constants.PATTERN_LENGTH
  local ids = macros.target_ids()
  table.sort(ids, function(a, b) return #a > #b end)   -- the longest ids first
  local index = 0
  for m = 1, 16 do
    for k = 1, 8 do
      index = index % #ids + 1
      macros.set_target(m, k, ids[index], 0.123456789, 0.987654321)
    end
  end
  local destinations = matrix.destination_ids()
  table.sort(destinations, function(a, b) return #a > #b end)
  for k = 1, 16 do
    matrix.set_routing(k, "macro" .. (17 - k), destinations[k])
    params:set("matrix_" .. k .. "_depth", -100 + k)
  end
  -- each LFO's home routing on one of the longest destination keys
  local keys = {}
  for _, destination in ipairs(S.LFO_DESTINATIONS) do
    if destination.key ~= "none" then keys[#keys + 1] = destination.key end
  end
  table.sort(keys, function(a, b) return #a > #b end)
  for n = 1, S.constants.NUM_LFOS do assert_true(matrix.set_home(n, keys[n]), "home " .. n .. " is set") end
  -- every attribute the sequencer stores (design §8.1, §8.12, §9.2; 3.7's
  -- slice and cond, design §5.3: the largest slice and the longest of the
  -- 78 conditions, single values that add bytes and no table), on every
  -- step of every voice, eight notes each, through its own setter
  local sequencer = S.lib.sequencer
  local notes = { -14, -9, -5, -2, 0, 3, 7, 14 }
  local attrs = { prob = 37, ratchet = 4, pos = 0.123456789, pitch = 1.23456789, size = 0.123456789, bookmark = 4,
    gate = 7.123456789, slice = S.lib.slices.SLICES.max }
  local longest_cond = ""
  for _, value in ipairs(S.lib.conditions.values) do
    if #value > #longest_cond then longest_cond = value end
  end
  assert_equal(longest_cond, "!first", "the longest condition")
  for voice = 1, NUM_VOICES do
    for step = 1, PATTERN_LENGTH do sequencer.set_step_attr(voice, step, "cond", longest_cond) end
  end
  assert_equal(sequencer.step_attr(NUM_VOICES, PATTERN_LENGTH, "cond"), longest_cond, "the sequencer stored cond")
  for voice = 1, NUM_VOICES do
    for step = 1, PATTERN_LENGTH do
      sequencer.set_step_attr(voice, step, "notes", notes)
      for key, value in pairs(attrs) do sequencer.set_step_attr(voice, step, key, value) end
    end
  end
  for key, value in pairs(attrs) do
    assert_near(sequencer.step_attr(NUM_VOICES, PATTERN_LENGTH, key), value, 1e-12, "the sequencer stored " .. key)
  end
  assert_equal(#sequencer.step_attr(NUM_VOICES, PATTERN_LENGTH, "notes"), 8, "and eight notes")
  -- a real save of each slot: captured and written through S.lib.data_files.write
  for slot = 1, S.constants.NUM_SCENES do assert_true(S.lib.scenes.save(slot), "slot " .. slot .. " saved") end
  local text = h.file_text(context.data_dir .. "strata/scenes.data")
  local tables = select(2, text:gsub("%-%- Table: ", ""))
  assert_true(tables <= S.lib.data_files.DATA_FILES.max_tables,
    tables .. " tables fit the reader's bound of " .. S.lib.data_files.DATA_FILES.max_tables)
  local largest = S.lib.data_files.DATA_FILES.largest_scenes_tables  -- the cap keeps 4 times it (data_files_test.lua)
  assert_equal(tables, largest, "the largest scenes file the reader's cap is sized for holds exactly its figure")
  assert_equal(largest, 6898, "the figure: 6802 and six home routings a scene")
  cleanup()
  local _, next_S, next_matrix = loaded({ data_subdir = data_dir_name(context) })
  for slot = 1, next_S.constants.NUM_SCENES do
    local scene = next_S.scenes[slot]
    assert_true(scene.populated and validate_scene(scene), "scene " .. slot .. " loaded and validates")
    assert_equal(entry_count(scene.data.matrix), 22, "scene " .. slot .. " holds every routing and home")
    local last = scene.data.steps[NUM_VOICES][PATTERN_LENGTH]
    assert_equal(last.notes[8], 14, "scene " .. slot .. " holds its steps' notes")
    assert_near(last.gate, 7.123456789, 1e-9, "and their gates")
    assert_equal(last.slice, next_S.lib.slices.SLICES.max, "and their slices")
    assert_equal(last.cond, "!first", "and their conditions")
  end
  for k = 1, 16 do next_matrix.set_routing(k, "", "") end
  recall_scene(16, 0)
  assert_equal(next_matrix.routing(16).source, "macro1", "the last scene recalls the last routing")
  assert_equal(next_matrix.routing(16).dest, destinations[16])
  assert_equal(params:get("matrix_16_depth"), -84)
  for n = 1, next_S.constants.NUM_LFOS do next_matrix.set_home(n, "") end
  recall_scene(16, 0)
  assert_equal(next_matrix.home(6), keys[6], "and the homes")
end)


test("the matrix leaves an envelope's fast routing out of its sum and keeps it in its block", function()
  local context, S, matrix = loaded()
  local probe = seeded(S, "probe", {-1, 1}, 1)
  route(S, 1, "probe", "v5_filter_freq", 50)
  route(S, 3, "env2", "v5_filter_freq", 50)
  route(S, 4, "env2", "reverb_mix", 50)
  assert_true(S.lib.envelopes.owns(3), "the envelopes own routing 3")
  assert_true(not S.lib.envelopes.owns(1) and not S.lib.envelopes.owns(4), "and only it")
  params:set("v2_env_sustain", 1)
  S.lib.engine_sync.retrigger(2, 1, "step", 5)  -- a step that holds 5 s
  context.set_time(util.time() + 1)
  assert_near(S.lib.envelopes.value(2), 1, 1e-9, "the envelope holds at 1")
  context.clear_engine_calls()
  lfo_step(context, 3)
  assert_near(matrix.offset("v5_filter_freq"), 0.5, 1e-9, "the fast sum is the probe's alone")
  assert_near(last_fast(context, 4, 3), 0.5, 1e-9, "setFastOffset carries the probe's alone")
  assert_true(matrix.offset("reverb_mix") ~= 0, "the Lua routing from the envelope still sums")
  assert_true(matrix.affects(5), "routing 3 still moves voice 5")
  assert_true(matrix.uses_source("env2"))
  probe.value = 0
  lfo_step(context, 3)
  assert_near(last_fast(context, 4, 3), 0, 1e-9, "the probe at 0: nothing from the envelope")
  -- its block, its depth and its on/off are unchanged
  capture_scene(1)
  local block = S.scenes[1].data.matrix
  assert_equal(block[3].source, "env2"); assert_equal(block[3].dest, "v5_filter_freq")
  assert_equal(matrix.routing(3).depth, 50)
  assert_true(matrix.routing(3).on)
end)

---------------------------------------------------------------------------
-- Home routings (the groundwork before 3.8, design §4): slots 16 + n,
-- source lfo<n>, destination the LFO's
---------------------------------------------------------------------------

test("the home routings: slots 17 to 22, source lfo<n>, destination none at first", function()
  local _, S, matrix = loaded()
  for n = 1, S.constants.NUM_LFOS do
    assert_equal(matrix.home_slot(n), 16 + n, "LFO " .. n .. "'s slot")
    assert_equal(S.matrix[16 + n].source, "lfo" .. n, "its source")
    assert_equal(S.matrix[16 + n].dest, "", "no destination")
    assert_equal(matrix.home(n), "", "home " .. n .. " is none")
  end
  assert_equal(matrix.home(0), nil, "no LFO 0"); assert_equal(matrix.home(7), nil, "no LFO 7")
  assert_equal(matrix.routing(17), nil, "the R functions keep R1-R16")
  assert_equal(matrix.set_routing(17, "lfo1", "reverb_mix"), false)
  assert_equal(matrix.edit_routing(17, "lfo1", "reverb_mix"), false)
  assert_equal(S.constants.MATRIX_SLOTS, 16, "MATRIX_SLOTS stays 16")
end)

test("edit_home refuses an unknown id; set_home keeps one, which does not play", function()
  local context, S, matrix = loaded()
  assert_equal(matrix.edit_home(1, "nonsense"), false, "an unknown id is refused")
  assert_equal(matrix.edit_home(1, "none"), false, "none is no destination id")
  assert_equal(matrix.home(1), "")
  assert_equal(matrix.edit_home(1, "filter_mix"), true, "a known id")
  assert_equal(matrix.home(1), "filter_mix")
  assert_equal(matrix.edit_home(2, "macro_3"), true, "a macro too")
  assert_equal(matrix.edit_home(3, "v2_main"), true, "a voice's main")
  assert_equal(matrix.edit_home(1, ""), true, "none")
  assert_equal(matrix.home(1), "")
  assert_equal(matrix.edit_home(0, "filter_mix"), false, "no LFO 0")
  assert_equal(matrix.set_home(1, "future_dest"), true, "set_home keeps an unknown id")
  assert_equal(matrix.home(1), "future_dest")
  assert_equal(matrix.edit_home(1, "future_dest"), true, "edit_home takes the one held")
  assert_equal(matrix.set_home(1, string.rep("x", 33)), false, "longer than 32 characters")
  assert_equal(matrix.set_home(1, 4), false, "no string")
  assert_equal(matrix.set_home(7, "filter_mix"), false, "no LFO 7")
  assert_equal(matrix.home(1), "future_dest", "kept")
  -- saved like a routing: in the live file, sparse
  context.clock.run_for(0.2)
  local live = S.lib.data_files.read(context.data_dir .. "strata/matrix.data")
  assert_equal(live.version, 2, "version 2")
  assert_equal(live.matrix[17].source, "lfo1"); assert_equal(live.matrix[17].dest, "future_dest")
  assert_equal(live.matrix[18].dest, "macro_3")
  assert_equal(live.matrix[20], nil, "a home with no destination is not written")
end)

test("the block refuses a home whose source is not lfo<n>", function()
  local _, S, matrix = loaded()
  matrix.set_home(2, "reverb_mix")
  capture_scene(1)
  local block = S.scenes[1].data.matrix
  assert_equal(block[18].source, "lfo2", "captured with its source")
  assert_equal(block[18].dest, "reverb_mix")
  assert_equal(block[17], nil, "sparse")
  local record
  for _, entry in ipairs(S.registry.scene_blocks) do
    if entry.key == "matrix" then record = entry end
  end
  assert_true(record.validate(block), "a captured block validates")
  assert_true(not record.validate({ [18] = { source = "lfo3", dest = "reverb_mix" } }), "LFO 3's source on LFO 2's home")
  assert_true(not record.validate({ [17] = { source = "", dest = "reverb_mix" } }), "an empty source")
  assert_true(not record.validate({ [23] = { source = "lfo1", dest = "reverb_mix" } }), "no slot 23")
  assert_true(record.validate({ [17] = { source = "lfo1", dest = "future_dest" } }), "an unknown destination is kept")
end)

test("a version 1 matrix file loads with no home routing; a version 3 file is set aside", function()
  local context, S, matrix = loaded()
  -- a live file of version 1, as 3.7 wrote it
  cleanup()
  util.make_dir(context.data_dir .. "strata")
  assert_true(S.lib.data_files.write(context.data_dir .. "strata/matrix.data",
    { version = 1, matrix = { [1] = { source = "macro1", dest = "reverb_mix" } } }))
  local next_context, next_S, next_matrix = loaded({ data_subdir = data_dir_name(context) })
  assert_equal(next_matrix.routing(1).source, "macro1", "R1 loads from the live file")
  for n = 1, next_S.constants.NUM_LFOS do assert_equal(next_matrix.home(n), "", "home " .. n .. " is none") end
  -- a PSET's side file of version 1
  next_matrix.set_home(2, "filter_mix")
  local path = next_context.data_dir .. "strata-07.pset"
  params:write(path)
  local side = next_context.data_dir .. "strata-07.matrix.data"
  assert_true(next_S.lib.data_files.write(side,
    { version = 1, matrix = { [1] = { source = "macro2", dest = "delay_mix" } } }))
  params:read(path)
  assert_equal(next_matrix.routing(1).source, "macro2", "R1 from the side file")
  assert_equal(next_matrix.home(2), "", "and no home routing")
  -- a version 3 file is set aside with its line
  assert_true(next_S.lib.data_files.write(side, { version = 3, matrix = {} }))
  next_matrix.set_home(2, "filter_mix")
  params:read(path)
  assert_equal(next_matrix.home(2), "", "nothing loads")
  assert_true(util.file_exists(side .. ".bak"), "set aside")
  assert_true(printed_with(next_context, "not a version 1-2 matrix file") ~= nil, "its line names the versions")
end)

-- LFO n's home routing aimed at the LFO destination labeled `label`
local function aim(S, n, label)
  assert_true(S.lib.matrix.set_home(n, S.lib.lfos.destination_id(destination_index(S, label))), "home " .. n .. " set")
end

test("a home routing to a Lua destination is summed by the matrix: one setFilter a step", function()
  local context, S, matrix = loaded()
  params:set("filter_mix", 0.5)
  hold_lfo(S, 1, "filt mix", 40)
  context.clear_engine_calls(); lfo_step(context)
  local calls = context.calls_named("setFilter")
  assert_equal(#calls, 1, "one setFilter")
  assert_near(calls[1].args[4], 0.7, 1e-9, "the mix: 0.5 + 0.4 x 0.5")
  assert_near(matrix.offset("filter_mix"), 0.2, 1e-9, "the matrix's extra offset")
  assert_equal(#context.calls_named("setFastLfo"), 0, "no engine node")
  assert_true(not S.lib.lfos.owns(1, "filter_mix"), "the LFO does not own a Lua home")
  context.clear_engine_calls(); lfo_step(context)
  assert_equal(#context.calls_named("setFilter"), 0, "held at its top, nothing moves")
  -- rising, the mix moves every step: one setFilter a step
  params:set(lfo_id(1, "shape"), 4); params:set(lfo_id(1, "rate"), 2)
  for step = 1, 2 do
    context.clear_engine_calls(); lfo_step(context)
    assert_equal(#context.calls_named("setFilter"), 1, "step " .. step .. ": one setFilter")
  end
  assert_near(params:get("filter_mix"), 0.5, 1e-9, "the stored value stays")
end)

test("a home routing to a fast destination is the LFO's engine node", function()
  local context, S, matrix = loaded()
  context.clear_engine_calls()
  hold_lfo(S, 1, "v3 pitch", 40)
  lfo_step(context, 2)
  local calls = context.calls_named("setFastLfo")
  assert_equal(#calls, 1, "one setFastLfo")
  assert_equal(calls[1].args[1], 0, "LFO 1"); assert_equal(calls[1].args[2], 2, "voice 3")
  assert_equal(calls[1].args[3], 0, "the pitch")
  assert_equal(#fast_calls(context, 2, 0), 0, "no setFastOffset on matrix fast 3 0")
  assert_true(S.lib.lfos.owns(1, "v3_grain_pitch"), "the LFO owns its fast home")
  assert_equal(matrix.offset("v3_grain_pitch"), 0, "the matrix sums nothing")
end)

test("a home routing to a macro is handed over by the LFO, never summed", function()
  local context, S, matrix = loaded()
  assert_true(S.lib.macros.set_target(1, 1, "reverb_mix", 0, 1))
  params:set("macro_1", 0.5); context.clock.run_for(0.1)
  local handed = {}
  context.clear_engine_calls()
  spying_sends(S, function(id) handed[id] = (handed[id] or 0) + 1 end, function()
    hold_lfo(S, 1, "macro 1", 100)
    lfo_step(context, 2)
  end)
  assert_true(S.lib.lfos.owns(1, "macro_1"), "the LFO owns a macro home")
  assert_near(engine_value(S, "reverb_mix"), 1, 1e-9, "the target moves: the macro at 0.5 + 0.5")
  assert_near(sent_reverb(context), 1, 1e-9, "the target is sent")
  assert_equal(handed.macro_1, nil, "the macro itself is handed to no budget")
  assert_equal(matrix.offset("macro_1"), 0, "nor summed")
  assert_near(params:get("macro_1"), 0.5, 1e-9, "the macro's param stays")
  params:set(lfo_id(1), 0)
  assert_near(engine_value(S, "reverb_mix"), 0.5, 1e-9, "turned off, the macro's restore is at once")
end)

test("a home and an R routing on one param sum and clamp once", function()
  local context, S, matrix = loaded()
  params:set("filter_mix", 0.5)
  params:set("macro_16", 1)
  route(S, 1, "macro16", "filter_mix", -100)   -- -0.5
  hold_lfo(S, 1, "filt mix", 100)              -- +0.5
  context.clear_engine_calls(); lfo_step(context)
  -- the two cancel before the clamp: the engine already plays the stored
  -- value, so nothing is sent (#760)
  assert_equal(#context.calls_named("setFilter"), 0, "no setFilter in the step")
  assert_near(engine_value(S, "filter_mix"), 0.5, 1e-9, "the two cancel before the clamp: the stored value")
  assert_near(S.engine_param_values.filter_mix, 0.5, 1e-9, "which the engine has")
  -- the R routing off: the home alone, clamped to the range
  params:set("matrix_1", 0)
  context.clear_engine_calls(); lfo_step(context)
  assert_near(context.calls_named("setFilter")[1].args[4], 1, 1e-9, "0.5 + 0.5")
end)

test("a home whose destination differs between two scenes ramps the LFO's depth through 0", function()
  local context, S, matrix = loaded()
  hold_lfo(S, 1, "filt mix", 60); capture_scene(1)
  aim(S, 1, "rev mix"); params:set(lfo_id(1, "depth"), 40); capture_scene(2)
  recall_scene(1, 0)
  assert_equal(matrix.home(1), "filter_mix", "scene 1")
  -- a 2 s transition, 20 steps: 60 x (1 - 2f), the home switched at f 0.5, then 40 x (2f - 1)
  recall_scene(2, 2)
  to_step(context, S, 5)
  assert_near(params:get(lfo_id(1, "depth")), 30, 1e-9, "f 0.25: 60 x 0.5")
  assert_equal(matrix.home(1), "filter_mix", "A's destination until the middle")
  to_step(context, S, 9)
  assert_equal(matrix.home(1), "filter_mix")
  to_step(context, S, 10)
  assert_near(params:get(lfo_id(1, "depth")), 0, 1e-9, "f 0.5: 0")
  assert_equal(matrix.home(1), "reverb_mix", "switched at the middle, at 0")
  to_step(context, S, 15)
  assert_near(params:get(lfo_id(1, "depth")), 20, 1e-9, "f 0.75: 40 x 0.5")
  assert_equal(matrix.home(1), "reverb_mix")
  context.clock.run_for(1)
  assert_equal(S.scene_transition_active, false, "the transition ended")
  assert_near(params:get(lfo_id(1, "depth")), 40, 1e-9, "B's depth")
  -- morph: the switch at 0.52 from A and 0.48 from B
  recall_scene(1, 0)
  params:set("morph_a", 1); params:set("morph_b", 2)
  local function morph_to(position)
    params:set("morph", position); context.clock.run_for(0.3)
    return matrix.home(1), params:get(lfo_id(1, "depth"))
  end
  local home, depth = morph_to(0.2)
  assert_equal(home, "filter_mix", "A's side")
  home, depth = morph_to(0.51)
  assert_equal(home, "filter_mix", "0.51: still A's"); assert_equal(depth, 0, "its depth ramped to 0")
  home = morph_to(0.52)
  assert_equal(home, "reverb_mix", "0.52: B's")
  home = morph_to(0.49)
  assert_equal(home, "reverb_mix", "0.49: still B's")
  home = morph_to(0.48)
  assert_equal(home, "filter_mix", "0.48: back to A's")
end)

test("an unknown home is kept and does not play", function()
  local context, S, matrix = loaded()
  params:set("reverb_mix", 0.3)
  hold_lfo(S, 1, "rev mix", 40)
  lfo_step(context)
  assert_true(matrix.set_home(1, "future_dest"), "kept")
  context.clear_engine_calls(); lfo_step(context, 2)
  assert_near(engine_value(S, "reverb_mix"), 0.3, 1e-9, "the old destination is given back")
  assert_equal(S.lib.lfos.label(1), "none", "the page shows none")
  assert_equal(#context.calls_named("setFastLfo"), 0, "nothing plays")
  assert_equal(matrix.home(1), "future_dest", "still held")
end)

test("a home on a voice's main follows a source switch and leaves no stale offset", function()
  local context, S, matrix = loaded()
  toggle_voice(1)
  local main = main_param_id(1)
  local low, high = param_range(main)
  params:set(main, low + 0.25 * (high - low))       -- room for the offset
  hold_lfo(S, 1, "v1 main", 50)                      -- 0.5 half ranges
  lfo_step(context, 2)
  assert_near(matrix.offset(main), 0.25 * (high - low), 1e-9, "a synth voice's main param, in Lua")
  assert_near(S.engine_param_values[main], params:get(main) + 0.25 * (high - low), 1e-9, "the engine has it")
  assert_true(not S.lib.lfos.owns(1, main), "summed by the matrix")
  -- to a buffer: the main param is the position, a fast param the LFO does not own
  local sends = {}
  spying_sends(S, function(id, value) if id == main then sends[#sends + 1] = value end end, function()
    params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
    sends = {}
    context.clear_engine_calls()
    lfo_step(context, 3)
  end)
  assert_equal(main_param_id(1), "v1_buf_pos")
  assert_equal(matrix.offset(main), 0, "the synth param's extra is given up")
  assert_equal(#sends, 1, "with one send")
  assert_near(sends[1], params:get(main), 1e-12, "of the stored value")
  assert_near(S.engine_param_values[main], params:get(main), 1e-12, "the engine has the stored value")
  assert_near(last_fast(context, 0, 1), 0.5, 1e-9, "the position, on matrix fast 1 1")
  assert_true(not S.lib.lfos.owns(1, "v1_buf_pos"), "a main home is never the engine node's")
  assert_equal(#context.calls_named("setFastLfo"), 0)
  -- back to the synth: the fast channel goes to 0, the Lua offset comes back
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  context.clear_engine_calls(); lfo_step(context, 3)
  assert_equal(last_fast(context, 0, 1), 0, "the position's channel is sent 0")
  assert_equal(matrix.offset("v1_buf_pos"), 0)
  assert_near(matrix.offset(main), 0.25 * (high - low), 1e-9, "the synth param's offset again")
  assert_near(S.engine_param_values[main], params:get(main) + 0.25 * (high - low), 1e-9)
  context.clear_engine_calls(); lfo_step(context, 10)
  assert_equal(#fast_calls(context, 0, 1), 0, "after the 0, later steps send nothing more on the position's channel")
end)


-- #927: a learn armed by mistake rewires its routing at the next touch; the
-- one undo holds the routing as it was and the touched param's value from
-- before the touch, on MOD's matrix
test("a learn's rewiring can be undone: the routing's destination and the param's value are back (#927)", function()
  local _, S, matrix = loaded()
  local mutation = S.lib.mutation
  local MOD_PAGE = S.constants.UI_PAGES.index.MOD
  -- a complete routing at depth 0 (a learn of an incomplete one would set 25 %)
  matrix.set_routing(3, "macro1", "v2_grain_size")
  params:set("matrix_3_depth", 0)
  params:set("v3_grain_pitch", 1.5)
  matrix.learn(3)
  h.show_page("MAIN")                         -- learn waits across pages
  enc_param_delta(3, "v3_grain_pitch", 1)     -- the touch that learns
  enc_param_delta(3, "v3_grain_pitch", 1)     -- the same turn goes on
  assert_equal(matrix.routing(3).dest, "v3_grain_pitch", "rewired")
  assert_true(params:get("v3_grain_pitch") > 1.5, "the turn moved the pitch")
  assert_true(mutation.undo_for(MOD_PAGE, "matrix", nil), "held on MOD's matrix, the turn's later detents too")
  assert_true(not mutation.undo_for(MOD_PAGE, "sequences", nil), "and nowhere else")
  assert_equal(mutation.undo(), true, "undone")
  local routing = matrix.routing(3)
  assert_equal(routing.source, "macro1", "the source")
  assert_equal(routing.dest, "v2_grain_size", "the destination from before the learn")
  assert_equal(routing.depth, 0, "the depth")
  assert_near(params:get("v3_grain_pitch"), 1.5, 1e-9, "the pitch from before the touch")
  assert_equal(S.undo, nil, "the undo is used")
  -- an incomplete routing: the learn's 25 % goes too
  matrix.set_routing(4, "macro2", "")
  params:set("matrix_4_depth", 0)
  matrix.learn(4)
  enc_param_delta(3, "reverb_mix", 1)
  assert_equal(params:get("matrix_4_depth"), 25, "completed: 25 %")
  assert_equal(mutation.undo(), true, "undone")
  assert_equal(matrix.routing(4).dest, "", "no destination again")
  assert_equal(params:get("matrix_4_depth"), 0, "and depth 0")
  -- a touch that is no destination learns nothing and holds nothing
  matrix.learn(5)
  enc_param_delta(3, "filter_type", 1)
  assert_equal(S.undo, nil, "nothing held")
  matrix.cancel_learn()
end)


-- #927, review round 1: the learn's hold keeps through the turn that
-- learned (the detent path: a turn of that param, its stop at 0 included)
-- and ends at any other edit of the touched param: a set (PARAMS, MIDI, a
-- scene's value), a grid fader, a mutation step
test("a learn's hold ends at any edit of the touched param but the turn that learned (#927)", function()
  local _, S, matrix = loaded()
  local mutation = S.lib.mutation
  local MOD_PAGE = S.constants.UI_PAGES.index.MOD
  local function held() return mutation.undo_for(MOD_PAGE, "matrix", nil) end
  local function learn(param_id, value)
    matrix.set_routing(3, "macro1", "v2_grain_size")
    params:set("matrix_3_depth", 0)
    params:set(param_id, value)
    matrix.learn(3)
    enc_param_delta(3, param_id, 1)
    assert_true(held(), "the learn of " .. param_id .. " is held")
  end
  learn("v1_grain_pitch", 1.5)
  params:set("v1_grain_pitch", 2.5)
  assert_true(not held(), "a set of the touched param (PARAMS, MIDI, a scene's value) ends it")
  learn("v1_grain_pitch", 1.5)
  set_param_from_column("v1_grain_pitch", 1, 8)
  assert_true(not held(), "a grid fader ends it")
  learn("v1_grain_pitch", 1.5)
  params:set("mutation_probability", 1); params:set("mutation_amount", 0.5)
  local pitch = params:get("v1_grain_pitch")
  for _ = 1, 200 do
    gentle_mutate()
    if params:get("v1_grain_pitch") ~= pitch then break end
  end
  assert_true(params:get("v1_grain_pitch") ~= pitch, "the pitch mutated")
  assert_true(not held(), "a mutation step of the touched param ends it")
  params:set("mutation_probability", 0)
  -- the turn going on, through its stop at 0, keeps it, and the undo takes
  -- the whole turn back
  learn("v1_grain_skew", 0.02)                -- a destination whose range spans 0
  enc_param_delta(3, "v1_grain_skew", -5)
  assert_equal(params:get("v1_grain_skew"), 0, "the turn stops at 0")
  assert_true(held(), "the stop at 0 of the same turn keeps it")
  enc_param_delta(3, "v1_grain_skew", -1)
  assert_true(held(), "and a detent the hold swallows")
  assert_equal(mutation.undo(), true, "undone")
  assert_near(params:get("v1_grain_skew"), 0.02, 1e-9, "the value from before the turn's first detent")
end)

-- #927, review round 1: a learn that changes nothing (the routing already
-- has that destination) holds nothing, so an earlier undo stays
test("a learn that changes nothing keeps the earlier undo (#927)", function()
  local _, S, matrix = loaded()
  local mutation = S.lib.mutation
  matrix.set_routing(3, "macro1", "v3_grain_pitch")
  params:set("matrix_3_depth", 40)
  randomize_voice(1)
  matrix.learn(3)
  enc_param_delta(3, "v3_grain_pitch", 1)
  assert_equal(matrix.routing(3).dest, "v3_grain_pitch", "the same destination")
  assert_true(mutation.undo_for(S.constants.UI_PAGES.index.MAIN, "voice", 1), "MAIN's undo stays")
  assert_true(not mutation.undo_for(S.constants.UI_PAGES.index.MOD, "matrix", nil), "nothing held on MOD")
end)

end

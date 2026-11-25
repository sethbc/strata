-- test/unit/fx_hold_test.lua
-- The effects' freezes and the delay's clear (lib/fx_hold.lua,
-- S.lib.fx_hold, 3.8 design §7.2, §7.3): delay_freeze and delay_clear in
-- the fx group, never in a PSET or a scene and no LFO destination, what
-- each sends, a bypass ending the freeze first, a freeze refused while
-- bypassed, toggle through set_binary_param, a PSET load leaving a freeze
-- as it is (plan ruling 61), a frozen delay through a tempo move, a sync
-- switch, a bypass and a PSET load (the plan's Review Focus 3), and 3.9's
-- reverb_freeze (#819): offered on the high tier only, refused on the
-- standard tier and while bypassed, its bypass and PSET rules the delay's,
-- and its machine's table; and the delay's machine's table (#1059)
-- Run alone: lua test/run.lua fx_hold

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function loaded()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.fx_hold
end

-- The performance_active.data the engine writes on the high tier
local HIGH = {tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60, reason = "high: setting"}

-- A load on the high tier, where the reverb's freeze is offered
local function loaded_high()
  h.write_performance_active(HIGH)
  local context, S, fx_hold = loaded()
  assert_equal(S.performance.tier, "high", "the load runs the high tier")
  return context, S, fx_hold
end

-- The engine calls since they were cleared, as "name(arg, ...)" strings
local function call_names(context, names)
  local wanted, out = {}, {}
  for _, name in ipairs(names) do wanted[name] = true end
  for _, call in ipairs(context.engine_calls) do
    if wanted[call.name] then
      local args = {}
      for index, value in ipairs(call.args) do args[index] = tostring(value) end
      table.insert(out, call.name .. "(" .. table.concat(args, ", ") .. ")")
    end
  end
  return out
end

local function freeze_calls(context) return context.calls_named("setDelayFreeze") end
local function reverb_freeze_calls(context) return context.calls_named("setReverbFreeze") end

-- A controller on port 1 mapped to a param (cc 48): a function giving the
-- values it was echoed, as "v,v,..."
local function mapped_controller(context, param_id)
  local controller = context.midi.plug(1)
  norns.pmap.data[param_id] = { dev = 1, ch = 1, cc = 48, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  return function()
    local values = {}
    for _, message in ipairs(controller.sent) do
      if message[2] == 48 then table.insert(values, message[3]) end
    end
    return table.concat(values, ",")
  end
end

local function pset_lines(path)
  local file = assert(io.open(path, "r")); local text = file:read("*a"); file:close()
  return text
end

local function scene_holds(value, needle, seen)
  seen = seen or {}
  if type(value) ~= "table" or seen[value] then return false end
  seen[value] = true
  for key, entry in pairs(value) do
    if (type(key) == "string" and key:find(needle, 1, true)) or scene_holds(entry, needle, seen) then return true end
  end
  return false
end

-- Run the clocks until the LFO clock (the delay's step hook runs in it) has stepped
local function lfo_step(context) context.clock.advance_until(local_value("S").lfo_clock) end

-- Run body, then put the clock's tempo back at the stubs' 120 BPM whatever happens
local function restoring_tempo(body)
  local ran, problem = pcall(body)
  clock.tempo = 120
  params:set("clock_tempo", 120)
  if not ran then error(problem, 0) end
end

test("delay_freeze is a binary fx param, off, never written to a PSET and never a scene field", function()
  local context, S, fx_hold = loaded()
  local id = fx_hold.FX_HOLD.delay.freeze_id
  assert_equal(id, "delay_freeze")
  local param = params:lookup_param(id)
  assert_true(param ~= nil and param.t == params.tBINARY, "delay_freeze is a binary param")
  assert_equal(param.behavior, "toggle"); assert_equal(param.name, "delay freeze")
  assert_equal(params:get(id), 0, "off at its default")
  assert_equal(param.save, false, "its save is off")
  -- in the fx group, after the delay's sync params, the clear after it
  local group_index
  for index, each in ipairs(params.params) do
    if each.id == "strata_fx" then group_index = index end
  end
  local index = params.lookup[id]
  assert_true(index > group_index and index <= group_index + params:get("strata_fx"), "in the fx group")
  assert_equal(params.params[index - 1].id, "delay_pingpong", "after the delay's ping-pong")
  assert_equal(params.params[index + 1].id, "delay_clear", "the clear after it")
  -- a written PSET has no line for it, frozen or not
  params:set(id, 1)
  local pset_path = context.data_dir .. "freeze.pset"
  params:write(pset_path, "freeze")
  assert_true(not pset_lines(pset_path):find("delay_freeze", 1, true), "the PSET has no delay_freeze line")
  assert_true(not pset_lines(pset_path):find("delay_clear", 1, true), "nor a delay_clear line")
  -- a scene never holds it, and a recall leaves it alone
  capture_scene(3)
  assert_true(not scene_holds(S.scenes[3].data, "delay_freeze") and not scene_holds(S.scenes[3].data, "delay_clear"),
    "the scene holds no freeze or clear field")
  params:set(id, 0); params:set(id, 1)
  context.clear_engine_calls()
  recall_scene(3, 0)
  assert_equal(params:get(id), 1, "a recall leaves the freeze as it is")
  assert_equal(#freeze_calls(context), 0, "and sends no setDelayFreeze")
  -- no LFO destination and no macro target
  for _, target in ipairs(S.lib.macros.target_ids()) do
    assert_true(target ~= id and target ~= "delay_clear", "not an LFO destination or a macro target: " .. target)
  end
end)

test("delay_freeze sends setDelayFreeze", function()
  local context, _, fx_hold = loaded()
  context.clear_engine_calls()
  params:set("delay_freeze", 1)
  assert_equal(table.concat(call_names(context, {"setDelayFreeze"}), " "), "setDelayFreeze(1)", "a freeze sends 1")
  assert_true(fx_hold.frozen("delay") and fx_hold.any_frozen(), "frozen")
  context.clear_engine_calls()
  params:set("delay_freeze", 0)
  assert_equal(table.concat(call_names(context, {"setDelayFreeze"}), " "), "setDelayFreeze(0)", "a release sends 0")
  assert_true(not fx_hold.frozen("delay") and not fx_hold.any_frozen(), "released")
end)

test("delay_clear sends clearDelay with no argument", function()
  local context, _, fx_hold = loaded()
  local param = params:lookup_param("delay_clear")
  assert_true(param ~= nil and param.t == params.tTRIGGER, "delay_clear is a trigger")
  assert_equal(param.name, "delay clear")
  context.clear_engine_calls()
  params:set("delay_clear", 1)
  local calls = context.calls_named("clearDelay")
  assert_equal(#calls, 1, "one clearDelay")
  assert_equal(#calls[1].args, 0, "with no argument")
  fx_hold.clear()
  assert_equal(#context.calls_named("clearDelay"), 2, "clear() fires it too")
  assert_equal(#freeze_calls(context), 0, "and touches no freeze")
end)

test("a bypass ends the delay's freeze first", function()
  local context, _, fx_hold = loaded()
  params:set("delay_freeze", 1)
  context.clear_engine_calls()
  params:set("delay_bypass", 1)
  assert_equal(table.concat(call_names(context, {"setDelayFreeze", "setBypass"}), " "),
    "setDelayFreeze(0) setBypass(0, 1)", "the freeze ends before the bypass")
  assert_equal(params:get("delay_freeze"), 0, "and the param reads 0")
  assert_true(not fx_hold.frozen("delay"), "not frozen")
  context.clear_engine_calls()
  params:set("delay_bypass", 0)
  assert_equal(table.concat(call_names(context, {"setDelayFreeze", "setBypass"}), " "), "setBypass(0, 0)",
    "the lift sends no freeze")
end)

-- The refusal goes back to off through set_binary_param (the path toggle
-- echoes by), so a mapped controller hears the 0; the re-entered action
-- sends one redundant setDelayFreeze(0) (the engine keeps 0 through the
-- bypass) and does not refuse again
test("a freeze set while bypassed is refused", function()
  local context, _, fx_hold = loaded()
  local controller = context.midi.plug(1)
  norns.pmap.data.delay_freeze = { dev = 1, ch = 1, cc = 47, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  local function echoes()
    local values = {}
    for _, message in ipairs(controller.sent) do
      if message[2] == 47 then table.insert(values, message[3]) end
    end
    return table.concat(values, ",")
  end
  params:set("delay_bypass", 1)
  context.clear_engine_calls()
  params:set("delay_freeze", 1)
  assert_equal(params:get("delay_freeze"), 0, "the param goes back to off")
  local sent = call_names(context, {"setDelayFreeze"})
  for _, call in ipairs(sent) do assert_equal(call, "setDelayFreeze(0)", "no setDelayFreeze(1) goes out") end
  assert_true(#sent <= 1, "at most one setDelayFreeze(0) goes out (sent " .. table.concat(sent, " ") .. ")")
  assert_equal(echoes(), "0", "the mapped controller hears the 0")
  context.clear_engine_calls()
  fx_hold.toggle("delay")
  assert_equal(params:get("delay_freeze"), 0, "toggle does nothing while bypassed")
  assert_equal(#context.engine_calls, 0, "and sends nothing")
  assert_equal(echoes(), "0", "nor echoes anything")
  params:set("delay_bypass", 0)
  fx_hold.toggle("delay")
  assert_equal(params:get("delay_freeze"), 1, "lifted, toggle freezes")
end)

-- #538: norns' Binary:set sends no MIDI-map CC, so toggle goes through
-- set_binary_param and a controller mapped to the param follows
test("toggle echoes to a MIDI-mapped controller", function()
  local context, _, fx_hold = loaded()
  local controller = context.midi.plug(1)
  norns.pmap.data.delay_freeze = { dev = 1, ch = 1, cc = 47, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  fx_hold.toggle("delay")
  assert_equal(params:get("delay_freeze"), 1, "toggle freezes")
  fx_hold.toggle("delay")
  assert_equal(params:get("delay_freeze"), 0, "and releases")
  fx_hold.toggle("delay")
  fx_hold.release("delay")
  assert_equal(params:get("delay_freeze"), 0, "release releases")
  local values = {}
  for _, message in ipairs(controller.sent) do
    if message[2] == 47 then table.insert(values, message[3]) end
  end
  assert_equal(table.concat(values, ","), "127,0,127,0", "the controller hears each")
end)

test("a PSET load leaves a freeze as it is", function()
  local context = loaded()
  local pset_path = context.data_dir .. "unfrozen.pset"
  params:write(pset_path, "unfrozen")
  params:set("delay_freeze", 1)
  context.clear_engine_calls()
  params:read(pset_path)
  assert_equal(params:get("delay_freeze"), 1, "a PSET load leaves the freeze on")
  assert_equal(#freeze_calls(context), 0, "and sends no setDelayFreeze")
  local frozen_path = context.data_dir .. "frozen.pset"
  params:write(frozen_path, "frozen")
  params:set("delay_freeze", 0)
  context.clear_engine_calls()
  params:read(frozen_path)
  assert_equal(params:get("delay_freeze"), 0, "a PSET written while frozen loads no freeze")
  assert_equal(#freeze_calls(context), 0, "and sends no setDelayFreeze")
end)

-- The plan's ruling 26 over 61: a bypass ends its effect's freeze whatever
-- sets it, a PSET's delay_bypass 1 among them (the node is freed, and a
-- freeze that outlived it would come back unasked at the lift); a PSET
-- that leaves the delay running leaves the freeze as it is
test("a PSET that bypasses the delay ends its freeze, one that does not leaves it", function()
  local context = loaded()
  params:set("delay_bypass", 1)
  local bypassed_path = context.data_dir .. "bypassed.pset"
  params:write(bypassed_path, "bypassed")
  params:set("delay_bypass", 0)
  local running_path = context.data_dir .. "running.pset"
  params:write(running_path, "running")
  params:set("delay_freeze", 1)
  context.clear_engine_calls()
  params:read(bypassed_path)
  assert_equal(table.concat(call_names(context, {"setDelayFreeze", "setBypass"}), " "),
    "setDelayFreeze(0) setBypass(0, 1)", "a PSET's bypass ends the freeze first")
  assert_equal(params:get("delay_freeze"), 0, "and the freeze reads 0")
  params:set("delay_bypass", 0)
  params:set("delay_freeze", 1)
  context.clear_engine_calls()
  params:read(running_path)
  assert_equal(params:get("delay_freeze"), 1, "a PSET that leaves the delay running leaves the freeze on")
  assert_equal(#freeze_calls(context), 0, "and sends no setDelayFreeze")
end)

-- #883 (ruling B2: bypass wins): a silent read sets delay_bypass with no
-- action, so the bypass's release never runs and the delay was left
-- bypassed and frozen, with ALT+K3 doing nothing (freezable false). The
-- read hook releases the freeze through its action, so the engine hears
-- setDelayFreeze(0) and a lift starts unfrozen
test("a silent read that leaves the delay bypassed and frozen releases the freeze", function()
  local context, S, fx_hold = loaded()
  params:set("delay_bypass", 1)
  local bypassed_path = context.data_dir .. "silent_bypassed.pset"
  params:write(bypassed_path, "silent bypassed")
  params:set("delay_bypass", 0)
  fx_hold.toggle("delay")
  assert_true(fx_hold.frozen("delay"), "frozen first")
  context.clear_engine_calls()
  params:read(bypassed_path, true)
  assert_true(S.lib.voice_mix.bypassed("delay"), "the read bypasses the delay")
  assert_equal(params:get("delay_freeze"), 0, "and the freeze is released")
  assert_true(not fx_hold.frozen("delay"), "not frozen")
  assert_equal(table.concat(call_names(context, {"setDelayFreeze"}), " "), "setDelayFreeze(0)",
    "the engine hears the release")
  -- the lift starts unfrozen, and ALT+K3's toggle then freezes again
  params:set("delay_bypass", 0)
  fx_hold.toggle("delay")
  assert_true(fx_hold.frozen("delay"), "lifted, toggle freezes")
end)

-- The hook does nothing unless the read left both: a silent read that
-- leaves the delay running keeps the freeze and sends nothing
test("a silent read that leaves the delay running keeps its freeze and sends nothing", function()
  local context, _, fx_hold = loaded()
  local running_path = context.data_dir .. "silent_running.pset"
  params:write(running_path, "silent running")
  fx_hold.toggle("delay")
  context.clear_engine_calls()
  params:read(running_path, true)
  assert_equal(params:get("delay_freeze"), 1, "the freeze stays on")
  assert_equal(#freeze_calls(context), 0, "and no setDelayFreeze goes out")
end)

test("the invariant fx hold fails for a delay bypassed and frozen", function()
  local _, S = loaded()
  local invariant
  for _, record in ipairs(S.registry.invariants) do
    if record.name == "fx hold" then invariant = record.fn end
  end
  assert_true(invariant ~= nil, "fx hold is registered")
  assert_equal(invariant(), nil, "holds at the start")
  -- broken on purpose with silent sets (no action runs), then put right
  params:set("delay_freeze", 1)
  params:set("delay_bypass", 1, true)
  params:set("delay_freeze", 1, true)
  local problem = invariant()
  assert_true(type(problem) == "string" and problem:find("bypassed and frozen", 1, true) ~= nil,
    "names the delay bypassed and frozen: " .. tostring(problem))
  params:set("delay_freeze", 0, true)
  assert_equal(invariant(), nil, "holds once released")
end)

-- #912 (ruling B2): a clear on a frozen delay emptied the loop and left it
-- frozen on silence with its input closed. The clear releases the freeze
-- first, so the loop refills
test("clear on a frozen delay releases the freeze, then clears", function()
  local context, _, fx_hold = loaded()
  local controller = context.midi.plug(1)
  norns.pmap.data.delay_freeze = { dev = 1, ch = 1, cc = 47, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  fx_hold.toggle("delay")
  context.clear_engine_calls()
  fx_hold.clear()
  assert_equal(table.concat(call_names(context, {"setDelayFreeze", "clearDelay"}), " "),
    "setDelayFreeze(0) clearDelay()", "the release goes before the clear")
  assert_equal(params:get("delay_freeze"), 0, "the freeze param reads 0")
  local values = {}
  for _, message in ipairs(controller.sent) do
    if message[2] == 47 then table.insert(values, message[3]) end
  end
  assert_equal(table.concat(values, ","), "127,0", "a mapped controller hears the release")
  -- the trigger itself (PARAMS, a MIDI map) does the same
  fx_hold.toggle("delay")
  context.clear_engine_calls()
  params:set("delay_clear", 1)
  assert_equal(table.concat(call_names(context, {"setDelayFreeze", "clearDelay"}), " "),
    "setDelayFreeze(0) clearDelay()", "the trigger releases first too")
  -- a running delay's clear sends the clear alone
  context.clear_engine_calls()
  fx_hold.clear()
  assert_equal(table.concat(call_names(context, {"setDelayFreeze", "clearDelay"}), " "), "clearDelay()",
    "an unfrozen clear touches no freeze")
end)

test("release('reverb') does nothing while the reverb is not offered", function()
  local context, _, fx_hold = loaded()
  assert_true(fx_hold.offered("delay"), "the delay's freeze is offered")
  assert_true(not fx_hold.offered("reverb") and not fx_hold.frozen("reverb"), "the reverb's is not (the standard tier)")
  assert_true(not fx_hold.offered("filter") and not fx_hold.offered(nil), "nor anything else")
  context.clear_engine_calls()
  fx_hold.release("reverb"); fx_hold.toggle("reverb")
  assert_equal(#context.engine_calls, 0, "release and toggle of the reverb send nothing")
  params:set("reverb_bypass", 1)
  assert_equal(table.concat(call_names(context, {"setDelayFreeze", "setBypass"}), " "), "setBypass(1, 1)",
    "the reverb's bypass sends its bypass alone")
end)

-- 3.9's reverb freeze (#819, the design's section 4): the param exists on
-- both tiers, so the param list does not depend on the tier, and the freeze
-- is offered on the high tier alone (the FDN; FreeVerb2 has none)
test("the reverb's freeze is offered on the high tier only", function()
  local context, _, fx_hold = loaded_high()
  assert_true(fx_hold.offered("reverb"), "offered on high")
  assert_equal(fx_hold.FX_HOLD.reverb.freeze_id, "reverb_freeze", "the reverb's record names its param")
  assert_equal(fx_hold.FX_HOLD.reverb.clear_id, nil, "and no clear")
  context.clear_engine_calls()
  fx_hold.toggle("reverb")
  assert_true(fx_hold.frozen("reverb") and fx_hold.any_frozen(), "toggle freezes it")
  fx_hold.toggle("reverb")
  assert_true(not fx_hold.frozen("reverb") and not fx_hold.any_frozen(), "and releases it")
  assert_equal(table.concat(call_names(context, {"setReverbFreeze"}), " "), "setReverbFreeze(1) setReverbFreeze(0)",
    "the engine hears each")
  local S
  context, S, fx_hold = loaded()
  assert_equal(S.performance.tier, "standard", "a plain load runs the standard tier")
  assert_true(not fx_hold.offered("reverb"), "not offered on standard")
  assert_true(params.lookup["reverb_freeze"] ~= nil and fx_hold.FX_HOLD.reverb ~= nil, "the param and record exist")
  context.clear_engine_calls()
  fx_hold.toggle("reverb"); fx_hold.release("reverb")
  assert_equal(#context.engine_calls, 0, "toggle and release of the reverb send nothing on standard")
  assert_equal(params:get("reverb_freeze"), 0, "and leave the param at 0")
end)

test("reverb_freeze is a binary in no PSET, scene, LFO destination or macro target", function()
  local context, S, fx_hold = loaded_high()
  local id = fx_hold.FX_HOLD.reverb.freeze_id
  local param = params:lookup_param(id)
  assert_true(param ~= nil and param.t == params.tBINARY, "reverb_freeze is a binary param")
  assert_equal(param.behavior, "toggle"); assert_equal(param.name, "reverb freeze")
  assert_equal(params:get(id), 0, "off at its default")
  assert_equal(param.save, false, "its save is off")
  -- in the fx group, after the delay's clear
  local group_index
  for index, each in ipairs(params.params) do
    if each.id == "strata_fx" then group_index = index end
  end
  local index = params.lookup[id]
  assert_true(index > group_index and index <= group_index + params:get("strata_fx"), "in the fx group")
  assert_equal(params.params[index - 1].id, "delay_clear", "after the delay's clear")
  -- a written PSET has no line for it, frozen or not
  params:set(id, 1)
  local pset_path = context.data_dir .. "reverb_freeze.pset"
  params:write(pset_path, "reverb freeze")
  assert_true(not pset_lines(pset_path):find("reverb_freeze", 1, true), "the PSET has no reverb_freeze line")
  -- a scene never holds it, and a recall leaves it alone
  capture_scene(3)
  assert_true(not scene_holds(S.scenes[3].data, "reverb_freeze"), "the scene holds no reverb freeze field")
  params:set(id, 0); params:set(id, 1)
  context.clear_engine_calls()
  recall_scene(3, 0)
  assert_equal(params:get(id), 1, "a recall leaves the freeze as it is")
  assert_equal(#reverb_freeze_calls(context), 0, "and sends no setReverbFreeze")
  for _, target in ipairs(S.lib.macros.target_ids()) do
    assert_true(target ~= id, "not an LFO destination or a macro target: " .. target)
  end
end)

-- The design's call 1: refused on the standard tier as a freeze is refused
-- while bypassed, so a mapped controller's light stays honest
test("a reverb freeze set on the standard tier is refused", function()
  local context, _, fx_hold = loaded()
  local echoes = mapped_controller(context, "reverb_freeze")
  context.clear_engine_calls()
  params:set("reverb_freeze", 1)
  assert_equal(params:get("reverb_freeze"), 0, "the param goes back to off")
  assert_true(not fx_hold.frozen("reverb"), "not frozen")
  local sent = call_names(context, {"setReverbFreeze"})
  for _, call in ipairs(sent) do assert_equal(call, "setReverbFreeze(0)", "no setReverbFreeze(1) goes out") end
  assert_true(#sent <= 1, "at most one setReverbFreeze(0) goes out (sent " .. table.concat(sent, " ") .. ")")
  assert_equal(echoes(), "0", "the mapped controller hears the 0")
end)

test("a reverb freeze set while bypassed is refused", function()
  local context, _, fx_hold = loaded_high()
  local echoes = mapped_controller(context, "reverb_freeze")
  params:set("reverb_bypass", 1)
  context.clear_engine_calls()
  params:set("reverb_freeze", 1)
  assert_equal(params:get("reverb_freeze"), 0, "the param goes back to off")
  local sent = call_names(context, {"setReverbFreeze"})
  for _, call in ipairs(sent) do assert_equal(call, "setReverbFreeze(0)", "no setReverbFreeze(1) goes out") end
  assert_true(#sent <= 1, "at most one setReverbFreeze(0) goes out (sent " .. table.concat(sent, " ") .. ")")
  assert_equal(echoes(), "0", "the mapped controller hears the 0")
  context.clear_engine_calls()
  fx_hold.toggle("reverb")
  assert_equal(params:get("reverb_freeze"), 0, "toggle does nothing while bypassed")
  assert_equal(#context.engine_calls, 0, "and sends nothing")
  params:set("reverb_bypass", 0)
  fx_hold.toggle("reverb")
  assert_equal(params:get("reverb_freeze"), 1, "lifted, toggle freezes")
end)

test("a reverb bypass ends its freeze first", function()
  local context, _, fx_hold = loaded_high()
  params:set("reverb_freeze", 1)
  context.clear_engine_calls()
  params:set("reverb_bypass", 1)
  assert_equal(table.concat(call_names(context, {"setReverbFreeze", "setBypass"}), " "),
    "setReverbFreeze(0) setBypass(1, 1)", "the freeze ends before the bypass")
  assert_equal(params:get("reverb_freeze"), 0, "and the param reads 0")
  assert_true(not fx_hold.frozen("reverb"), "not frozen")
  context.clear_engine_calls()
  params:set("reverb_bypass", 0)
  assert_equal(table.concat(call_names(context, {"setReverbFreeze", "setBypass"}), " "), "setBypass(1, 0)",
    "the lift sends no freeze")
end)

test("a PSET load leaves a reverb freeze as it is", function()
  local context = loaded_high()
  local pset_path = context.data_dir .. "reverb_unfrozen.pset"
  params:write(pset_path, "reverb unfrozen")
  params:set("reverb_freeze", 1)
  context.clear_engine_calls()
  params:read(pset_path)
  assert_equal(params:get("reverb_freeze"), 1, "a PSET load leaves the freeze on")
  assert_equal(#reverb_freeze_calls(context), 0, "and sends no setReverbFreeze")
  local frozen_path = context.data_dir .. "reverb_frozen.pset"
  params:write(frozen_path, "reverb frozen")
  params:set("reverb_freeze", 0)
  context.clear_engine_calls()
  params:read(frozen_path)
  assert_equal(params:get("reverb_freeze"), 0, "a PSET written while frozen loads no freeze")
  assert_equal(#reverb_freeze_calls(context), 0, "and sends no setReverbFreeze")
end)

test("a PSET that bypasses the reverb ends its freeze", function()
  local context = loaded_high()
  params:set("reverb_bypass", 1)
  local bypassed_path = context.data_dir .. "reverb_bypassed.pset"
  params:write(bypassed_path, "reverb bypassed")
  params:set("reverb_bypass", 0)
  params:set("reverb_freeze", 1)
  context.clear_engine_calls()
  params:read(bypassed_path)
  assert_equal(table.concat(call_names(context, {"setReverbFreeze", "setBypass"}), " "),
    "setReverbFreeze(0) setBypass(1, 1)", "a PSET's bypass ends the freeze first")
  assert_equal(params:get("reverb_freeze"), 0, "and the freeze reads 0")
end)

-- #883's rule for the reverb: a silent read runs no bypass action, so the
-- read hook releases the freeze it left bypassed, before the engine params'
-- hook sends the bypass (#965)
test("a silent read that leaves the reverb bypassed and frozen releases it", function()
  local context, S, fx_hold = loaded_high()
  params:set("reverb_bypass", 1)
  local bypassed_path = context.data_dir .. "reverb_silent_bypassed.pset"
  params:write(bypassed_path, "reverb silent bypassed")
  params:set("reverb_bypass", 0)
  fx_hold.toggle("reverb")
  assert_true(fx_hold.frozen("reverb"), "frozen first")
  context.clear_engine_calls()
  params:read(bypassed_path, true)
  assert_true(S.lib.voice_mix.bypassed("reverb"), "the read bypasses the reverb")
  assert_equal(params:get("reverb_freeze"), 0, "and the freeze is released")
  assert_equal(table.concat(call_names(context, {"setReverbFreeze", "setBypass"}), " "),
    "setReverbFreeze(0) setBypass(1, 1)", "the release goes out before the bypass")
  params:set("reverb_bypass", 0)
  fx_hold.toggle("reverb")
  assert_true(fx_hold.frozen("reverb"), "lifted, toggle freezes")
end)

test("the invariant fx hold fails for a reverb bypassed and frozen", function()
  local _, S = loaded_high()
  local invariant
  for _, record in ipairs(S.registry.invariants) do
    if record.name == "fx hold" then invariant = record.fn end
  end
  assert_equal(invariant(), nil, "holds at the start")
  -- broken on purpose with silent sets (no action runs), then put right
  params:set("reverb_freeze", 1)
  params:set("reverb_bypass", 1, true)
  params:set("reverb_freeze", 1, true)
  local problem = invariant()
  assert_true(type(problem) == "string" and problem:find("the reverb is bypassed and frozen", 1, true) ~= nil,
    "names the reverb bypassed and frozen: " .. tostring(problem))
  params:set("reverb_freeze", 0, true)
  assert_equal(invariant(), nil, "holds once released")
end)

-- The reverb has no clear (a bypass empties it): the delay's clear releases
-- the delay's freeze alone
test("delay_clear leaves a frozen reverb frozen", function()
  local context, _, fx_hold = loaded_high()
  fx_hold.toggle("reverb"); fx_hold.toggle("delay")
  context.clear_engine_calls()
  fx_hold.clear()
  assert_equal(table.concat(call_names(context, {"setDelayFreeze", "setReverbFreeze", "clearDelay"}), " "),
    "setDelayFreeze(0) clearDelay()", "the delay released and cleared, the reverb untouched")
  assert_true(fx_hold.frozen("reverb") and not fx_hold.frozen("delay"), "the reverb stays frozen")
end)

-- The reverb's machine (docs/notes/lua/fx-hold.md, ### fx hold, its first
-- table, which `notes` compares): the delay's events but the clear, on the
-- high tier (running, frozen, bypassed) and on the standard tier, where
-- nothing freezes. The helper loads the script, so each state sets the tier after
-- the load (S.performance is read at each use); a reverb bypassed and frozen
-- is no state (the invariant fx hold forbids it), so state_of names it and
-- the row fails
local function reverb_state()
  local S = local_value("S")
  if S.performance.tier ~= "high" then return "standard" end
  local frozen = params:get("reverb_freeze") == 1
  if S.lib.voice_mix.bypassed("reverb") then return frozen and "bypassed and frozen" or "bypassed" end
  return frozen and "frozen" or "running"
end

-- A state: the tier, a PSET that bypasses the reverb and one that leaves it
-- running (each written at the state's tier), then the setup
local function reverb_entered(tier, setup)
  return function(context)
    local_value("S").performance.tier = tier
    params:set("reverb_bypass", 1)
    context.bypassed_pset = context.data_dir .. "table_bypassed.pset"
    params:write(context.bypassed_pset, "table bypassed")
    params:set("reverb_bypass", 0)
    context.running_pset = context.data_dir .. "table_running.pset"
    params:write(context.running_pset, "table running")
    if setup then setup() end
    context.clear_engine_calls()
  end
end

-- A row whose check is the reverb's sends, as "name(arg, ...)" strings
local function reverb_row(state, event, next_state, sends)
  return {state, event, next_state, check = function(context)
    assert_equal(table.concat(call_names(context, {"setReverbFreeze", "setBypass"}), " "), sends,
      state .. " + " .. event .. ": the reverb's sends")
  end}
end

h.transition_table({
  name = "reverb freeze",
  states = {
    running = reverb_entered("high"),
    frozen = reverb_entered("high", function() params:set("reverb_freeze", 1) end),
    bypassed = reverb_entered("high", function() params:set("reverb_bypass", 1) end),
    standard = reverb_entered("standard"),
  },
  events = {
    freeze = function() params:set("reverb_freeze", 1) end,
    release = function() params:set("reverb_freeze", 0) end,
    bypass = function() params:set("reverb_bypass", 1) end,
    lift = function() params:set("reverb_bypass", 0) end,
    ["silent bypassing read"] = function(context) params:read(context.bypassed_pset, true) end,
    ["running read"] = function(context) params:read(context.running_pset) end,
  },
  state_of = reverb_state,
  rows = {
    reverb_row("running", "freeze", "frozen", "setReverbFreeze(1)"),
    reverb_row("running", "release", "running", ""),
    reverb_row("running", "bypass", "bypassed", "setBypass(1, 1)"),
    reverb_row("running", "lift", "running", ""),
    reverb_row("running", "silent bypassing read", "bypassed", "setBypass(1, 1)"),
    reverb_row("running", "running read", "running", ""),
    reverb_row("frozen", "freeze", "frozen", ""),
    reverb_row("frozen", "release", "running", "setReverbFreeze(0)"),
    reverb_row("frozen", "bypass", "bypassed", "setReverbFreeze(0) setBypass(1, 1)"),
    reverb_row("frozen", "lift", "frozen", ""),
    reverb_row("frozen", "silent bypassing read", "bypassed", "setReverbFreeze(0) setBypass(1, 1)"),
    reverb_row("frozen", "running read", "frozen", ""),
    reverb_row("bypassed", "freeze", "bypassed", "setReverbFreeze(0)"),
    reverb_row("bypassed", "release", "bypassed", ""),
    reverb_row("bypassed", "bypass", "bypassed", ""),
    reverb_row("bypassed", "lift", "running", "setBypass(1, 0)"),
    reverb_row("bypassed", "silent bypassing read", "bypassed", ""),
    reverb_row("bypassed", "running read", "running", "setBypass(1, 0)"),
    reverb_row("standard", "freeze", "standard", "setReverbFreeze(0)"),
    reverb_row("standard", "release", "standard", ""),
    reverb_row("standard", "bypass", "standard", "setBypass(1, 1)"),
    reverb_row("standard", "lift", "standard", ""),
    reverb_row("standard", "silent bypassing read", "standard", "setBypass(1, 1)"),
    reverb_row("standard", "running read", "standard", ""),
  },
  notes = {"docs/notes/lua/fx-hold.md", "fx hold"},
})

-- The delay's machine (docs/notes/lua/fx-hold.md, ### fx hold, its second
-- table, #1059): running, frozen and bypassed on the stubs' standard tier
-- (the delay's freeze is offered on both), the reverb's events and the
-- clear, under the delay's names. A delay bypassed and frozen is no state
-- (the invariant fx hold forbids it), so state_of names it and the row fails
local function delay_state()
  local frozen = params:get("delay_freeze") == 1
  if local_value("S").lib.voice_mix.bypassed("delay") then return frozen and "bypassed and frozen" or "bypassed" end
  return frozen and "frozen" or "running"
end

-- A state: a PSET that bypasses the delay and one that leaves it running,
-- then the setup
local function delay_entered(setup)
  return function(context)
    params:set("delay_bypass", 1)
    context.bypassed_pset = context.data_dir .. "delay_table_bypassed.pset"
    params:write(context.bypassed_pset, "delay table bypassed")
    params:set("delay_bypass", 0)
    context.running_pset = context.data_dir .. "delay_table_running.pset"
    params:write(context.running_pset, "delay table running")
    if setup then setup() end
    context.clear_engine_calls()
  end
end

-- A row whose check is the delay's sends, as "name(arg, ...)" strings
local function delay_row(state, event, next_state, sends)
  return {state, event, next_state, check = function(context)
    assert_equal(table.concat(call_names(context, {"setDelayFreeze", "clearDelay", "setBypass"}), " "), sends,
      state .. " + " .. event .. ": the delay's sends")
  end}
end

local SILENT_BYPASSING_READ, RUNNING_READ = "a silent PSET read that bypasses", "a PSET read that leaves the delay running"

h.transition_table({
  name = "delay freeze",
  states = {
    running = delay_entered(),
    frozen = delay_entered(function() params:set("delay_freeze", 1) end),
    bypassed = delay_entered(function() params:set("delay_bypass", 1) end),
  },
  events = {
    freeze = function() params:set("delay_freeze", 1) end,
    release = function() params:set("delay_freeze", 0) end,
    clear = function() params:set("delay_clear", 1) end,
    bypass = function() params:set("delay_bypass", 1) end,
    lift = function() params:set("delay_bypass", 0) end,
    [SILENT_BYPASSING_READ] = function(context) params:read(context.bypassed_pset, true) end,
    [RUNNING_READ] = function(context) params:read(context.running_pset) end,
  },
  state_of = delay_state,
  rows = {
    delay_row("running", "freeze", "frozen", "setDelayFreeze(1)"),
    delay_row("running", "release", "running", ""),
    delay_row("running", "clear", "running", "clearDelay()"),
    delay_row("running", "bypass", "bypassed", "setBypass(0, 1)"),
    delay_row("running", "lift", "running", ""),
    delay_row("running", SILENT_BYPASSING_READ, "bypassed", "setBypass(0, 1)"),
    delay_row("running", RUNNING_READ, "running", ""),
    delay_row("frozen", "freeze", "frozen", ""),
    delay_row("frozen", "release", "running", "setDelayFreeze(0)"),
    delay_row("frozen", "clear", "running", "setDelayFreeze(0) clearDelay()"),
    delay_row("frozen", "bypass", "bypassed", "setDelayFreeze(0) setBypass(0, 1)"),
    delay_row("frozen", "lift", "frozen", ""),
    delay_row("frozen", SILENT_BYPASSING_READ, "bypassed", "setDelayFreeze(0) setBypass(0, 1)"),
    delay_row("frozen", RUNNING_READ, "frozen", ""),
    delay_row("bypassed", "freeze", "bypassed", "setDelayFreeze(0)"),
    delay_row("bypassed", "release", "bypassed", ""),
    delay_row("bypassed", "clear", "bypassed", "clearDelay()"),
    delay_row("bypassed", "bypass", "bypassed", ""),
    delay_row("bypassed", "lift", "running", "setBypass(0, 0)"),
    delay_row("bypassed", SILENT_BYPASSING_READ, "bypassed", ""),
    delay_row("bypassed", RUNNING_READ, "running", "setBypass(0, 0)"),
  },
  notes = {"docs/notes/lua/fx-hold.md", "fx hold", 2},
})

-- 4a's review: one answer to "would toggle freeze or release this effect
-- now", which toggle and FX's hint and key share
test("freezable is offered and not bypassed, and toggle acts only when it is true", function()
  local context, _, fx_hold = loaded()
  assert_true(fx_hold.freezable("delay"), "a running delay can freeze")
  params:set("delay_freeze", 1)
  assert_true(fx_hold.freezable("delay"), "and a frozen one can be released")
  params:set("delay_bypass", 1)
  assert_true(not fx_hold.freezable("delay"), "a bypassed delay cannot")
  params:set("delay_bypass", 0)
  for _, effect in ipairs({"reverb", "filter", false}) do
    assert_true(not fx_hold.freezable(effect or nil), tostring(effect) .. " cannot (not offered on standard)")
  end
  -- toggle asks freezable: with it false, toggle does nothing
  local real = fx_hold.freezable
  fx_hold.freezable = function() return false end
  context.clear_engine_calls()
  fx_hold.toggle("delay")
  fx_hold.freezable = real
  assert_equal(#context.engine_calls, 0, "toggle sends nothing when freezable says no")
  assert_equal(params:get("delay_freeze"), 0, "and leaves the freeze")
  fx_hold.toggle("delay")
  assert_equal(params:get("delay_freeze"), 1, "with freezable true it freezes")
end)

test("a tempo change under a frozen synced delay keeps the freeze", function()
  local context = loaded()
  restoring_tempo(function()
    params:set("clock_tempo", 120)
    params:set("delay_sync", 1)
    params:set("delay_freeze", 1)
    context.clear_engine_calls()
    params:set("clock_tempo", 90)
    lfo_step(context)
    assert_equal(params:get("delay_freeze"), 1, "the freeze stays")
    assert_equal(#freeze_calls(context), 0, "no setDelayFreeze")
    local delays = context.calls_named("setDelay")
    -- the resend goes out; the engine holds the time while frozen (the
    -- delay area's "a time change waits for the release")
    assert_true(#delays >= 1, "the tempo's setDelay goes out")
    assert_near(delays[#delays].args[1], 0.5, 1e-4, "at 1/8D of 90 BPM")
  end)
end)

-- The plan's Review Focus 3: the loop keeps its length until released (the
-- engine holds the time: the delay area's check), a bypass ends the freeze
-- and the lift starts unfrozen, a PSET load leaves the freeze as it is
test("a frozen delay through a tempo move, a sync switch, a bypass and a PSET load", function()
  local context = loaded()
  restoring_tempo(function()
    params:set("clock_tempo", 120)
    params:set("delay_sync", 1)
    params:set("delay_freeze", 1)
    context.clear_engine_calls()
    params:set("clock_tempo", 90)
    lfo_step(context)
    params:set("delay_sync", 0)
    params:set("delay_sync", 1)
    assert_equal(params:get("delay_freeze"), 1, "the freeze stays through the tempo and the sync switch")
    assert_equal(#freeze_calls(context), 0, "and nothing releases it")
    params:set("delay_freeze", 0)
    lfo_step(context)
    local delays = context.calls_named("setDelay")
    assert_true(#delays >= 1, "the tempo, the sync switch: setDelay went out (the engine held its time)")
    assert_near(delays[#delays].args[1], 0.5, 1e-4, "released, the engine's last setDelay carries 90 BPM's 1/8D")
    params:set("delay_freeze", 1)
    context.clear_engine_calls()
    params:set("delay_bypass", 1)
    assert_equal(table.concat(call_names(context, {"setDelayFreeze", "setBypass"}), " "),
      "setDelayFreeze(0) setBypass(0, 1)", "the freeze ends before the bypass")
    assert_equal(params:get("delay_freeze"), 0, "and reads 0")
    context.clear_engine_calls()
    params:set("delay_bypass", 0)
    assert_equal(#freeze_calls(context), 0, "the lift sends no setDelayFreeze(1)")
    params:set("delay_freeze", 1)
    local pset_path = context.data_dir .. "focus.pset"
    params:write(pset_path, "focus")
    context.clear_engine_calls()
    params:read(pset_path)
    assert_equal(params:get("delay_freeze"), 1, "a PSET load leaves the freeze on")
    assert_equal(#freeze_calls(context), 0, "and sends no setDelayFreeze")
  end)
end)

end

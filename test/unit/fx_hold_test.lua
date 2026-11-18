-- test/unit/fx_hold_test.lua
-- The effects' freezes and the delay's clear (lib/fx_hold.lua,
-- S.lib.fx_hold, 3.8 design §7.2, §7.3): delay_freeze and delay_clear in
-- the fx group, never in a PSET or a scene and no LFO destination, what
-- each sends, a bypass ending the freeze first, a freeze refused while
-- bypassed, toggle through set_binary_param, a PSET load leaving a freeze
-- as it is (plan ruling 61), the reverb not offered, and a frozen delay
-- through a tempo move, a sync switch, a bypass and a PSET load (the plan's
-- Review Focus 3)
-- Run alone: lua test/run.lua fx_hold

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function loaded()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.fx_hold
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

test("a freeze set while bypassed is refused", function()
  local context, _, fx_hold = loaded()
  params:set("delay_bypass", 1)
  context.clear_engine_calls()
  params:set("delay_freeze", 1)
  assert_equal(params:get("delay_freeze"), 0, "the param goes back to off")
  assert_equal(#freeze_calls(context), 0, "and no setDelayFreeze goes out")
  fx_hold.toggle("delay")
  assert_equal(params:get("delay_freeze"), 0, "toggle does nothing while bypassed")
  assert_equal(#freeze_calls(context), 0, "and sends nothing")
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

test("release('reverb') does nothing while the reverb is not offered", function()
  local context, _, fx_hold = loaded()
  assert_true(fx_hold.offered("delay"), "the delay's freeze is offered")
  assert_true(not fx_hold.offered("reverb") and not fx_hold.frozen("reverb"), "the reverb's is not (until 3a)")
  assert_true(not fx_hold.offered("filter") and not fx_hold.offered(nil), "nor anything else")
  context.clear_engine_calls()
  fx_hold.release("reverb"); fx_hold.toggle("reverb")
  assert_equal(#context.engine_calls, 0, "release and toggle of the reverb send nothing")
  params:set("reverb_bypass", 1)
  assert_equal(table.concat(call_names(context, {"setDelayFreeze", "setBypass"}), " "), "setBypass(1, 1)",
    "the reverb's bypass sends its bypass alone")
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

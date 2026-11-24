-- test/unit/modulation_walk_test.lua
-- 3.9's modulation walk (package 3c, #916): a model of the engine's
-- modulation nodes (test/modulation_model.lua), fed every setFastLfo,
-- stopFastLfo, syncFastLfo, setFastOffset, setFastEnv, stopFastEnv and
-- setScatter the stub records, against what the params imply, over seeded
-- random sequences of the LFOs' and the matrix's events
-- Run alone: lua test/run.lua modulation_walk

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- One list of calls, as the stub's: the model reads on from where it stopped
local function call_list()
  local calls = {}
  return calls, function(name, ...) calls[#calls + 1] = { name = name, args = { ... } } end
end

local function contains(problems, text)
  for _, problem in ipairs(problems) do
    if problem:find(text, 1, true) then return true end
  end
  return false
end

test("the modulation model follows the engine's LFO nodes, channels, routes and scatter", function()
  load_strata()
  local S = local_value("S")
  local Model = require("modulation_model")
  local model = Model.new(S.constants)
  local calls, call = call_list()
  call("setFastLfo", 0, 1, 0, 2, 0.5, 0.25, 0)
  model:feed(calls)
  assert_equal(model.lfos[0].voice, 1, "LFO 0's node: on voice 1")
  assert_equal(model.lfos[0].shape, 2, "its shape")
  assert_equal(model.counts.lfo_started, 1, "a node started")
  call("setFastLfo", 0, 2, 3, 2, 0.5, 0.25, 0); call("syncFastLfo", 0, 0.5)
  model:feed(calls)
  assert_equal(model.counts.lfo_replaced, 1, "a running node's settings replaced")
  assert_equal(model.counts.lfo_started, 1, "never a second node")
  assert_equal(model.lfos[0].destination, 3, "moved to the cutoff")
  call("stopFastLfo", 0)
  model:feed(calls)
  assert_equal(model.lfos[0], nil, "stopped")
  assert_equal(model.counts.lfo_stopped, 1, "a node stopped")
  assert_equal(#model.errors, 0, "nothing refused so far")
  -- a stop or a sync with no node is a no-op in the engine: Lua sent what it believed had a node
  call("stopFastLfo", 0); call("syncFastLfo", 0, 0)
  model:feed(calls)
  assert_equal(#model.errors, 2, "a stop and a sync with no node: " .. table.concat(model.errors, "; "))
  -- a guarded command the engine ignores (#916: Lua still records it as sent)
  call("setFastLfo", 6, 0, 0, 0, 1, 0.5, 0); call("setFastOffset", 0, 0, 5, 0.1); call("setFastOffset", 0, 0, 1, 0 / 0)
  model:feed(calls)
  assert_equal(#model.errors, 5, "an LFO 6, a destination 5 and a NaN offset are ignored by the engine")
  assert_equal(model.offsets[0][1], 0, "the NaN never reached the channel")
  call("setFastOffset", 2, 0, 1, 0.75)
  model:feed(calls)
  assert_equal(model.offsets[2][1], 0.75, "voice 2's position channel")
  call("setFastEnv", 3, 1, 4, 3, 0.5, 0.05, 0.05, 0.5, 0.05, -4, 0)
  model:feed(calls)
  assert_equal(model.routes[3].voice, 4, "route 3 on voice 4")
  assert_equal(model.routes[3].release, 0.05, "with its release")
  call("stopFastEnv", 3); call("stopFastEnv", 3)
  model:feed(calls)
  assert_equal(model.routes[3], nil, "route 3 stopped")
  assert_equal(#model.errors, 6, "a second stop of a stopped route")
  call("setScatter", 0.1, 0.1, 3, 127)
  model:feed(calls)
  assert_equal(model.scatter.voices, 127, "scatter's voice mask")
end)

test("the modulation model's compare names where the engine differs from what the params imply", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  local model = require("modulation_model").new(S.constants)
  model:feed(context.engine_calls)
  assert_equal(#model:compare(S), 0, "a fresh script: " .. table.concat(model:compare(S), "; "))
  S.lib.matrix.set_home(1, "v2_grain_pitch")
  params:set("strata_lfo1", 1)
  context.clock.advance_until(S.lfo_clock)
  model:feed(context.engine_calls)
  assert_equal(#model:compare(S), 0, "LFO 1 on voice 2's pitch: " .. table.concat(model:compare(S), "; "))
  -- a buffer voice's main is its position, which the matrix sends as the channel's offset (ruling 16)
  params:set("v2_source", S.constants.SOURCE_SYNTH + 1)
  S.lib.matrix.set_home(2, "v2_main")
  params:set("strata_lfo2_offset", 40)
  params:set("strata_lfo2", 1)
  context.clock.advance_until(S.lfo_clock)
  model:feed(context.engine_calls)
  assert_equal(#model:compare(S), 0, "LFO 2 on voice 2's main: " .. table.concat(model:compare(S), "; "))
  assert_true(model.offsets[1][1] > 0.5, "voice 2's position channel holds LFO 2's offset: " .. model.offsets[1][1])
  -- the engine has lost the node Lua believes it has
  local calls, call = call_list()
  for _, entry in ipairs(context.engine_calls) do calls[#calls + 1] = entry end
  call("stopFastLfo", 0)
  model:feed(calls)
  assert_true(contains(model:compare(S), "LFO 1: the params play it"), "a node missing is named")
  call("setFastLfo", 0, 1, 0, 0, 0.25, 0.9, 0)
  model:feed(calls)
  assert_true(contains(model:compare(S), "LFO 1: depth"), "a depth the params do not give is named")
  -- a channel offset and a route nothing implies
  call("setFastLfo", 0, 1, 0, 0, 0.25, 0.25, 0); call("setFastOffset", 4, 0, 2, 0.5)
  call("setFastEnv", 7, 0, 0, 0, 0.5, 0.005, 0.2, 0, 0.2, -4, 0)
  model:feed(calls)
  local problems = model:compare(S)
  assert_true(contains(problems, "voice 5's channel 2"), "the offset is named: " .. table.concat(problems, "; "))
  assert_true(contains(problems, "route 8"), "the route is named: " .. table.concat(problems, "; "))
end)

---------------------------------------------------------------------------
-- The walk (design section 6, #916): the LFOs turned on and off, their
-- depth, home, shape and mode set by hand and silently, routings set and
-- cleared, envelope routes, the envelopes' times and their hits, scenes
-- recalled, faded and a fade crossed by a recall, a voice's source
-- switched, a macro moved onto an LFO's depth, scatter. After each op one
-- LFO step runs and the model (fed every engine call) must agree with what
-- the params imply; then an idle step (no op since the last) must send
-- nothing, but what a source that moved in it moves
---------------------------------------------------------------------------

local Model = require("modulation_model")

-- The differences the walk allows, each counted (allowed_<name> among
-- reached): waiting, the one transient the compare can meet after a step,
-- legal and kept: a send due in the round robin or waiting in the send
-- budget (more than the step's 12 due, a deferrable edit past the budget),
-- sent at a later step (the fact file's other transient, an engine copy
-- kept while the params no longer play, ends inside the step the compare
-- follows); ended_runs_again, #969, a fault whose fix removes it: an
-- envelope (loop off) whose run ended runs again in Lua's model when one
-- of its times is raised past the time since its hit, which the engine's
-- ended EnvGen does not. A third, ulp_resend (#977), is the recall's
-- (needless_sends, below)
local WALK_ALLOWED = { waiting = true, ended_runs_again = true }

-- The commands that start, move or stop a modulation node, which an idle
-- step never sends but a clocked LFO's bar sync
local NODE_COMMANDS = { setFastLfo = true, stopFastLfo = true, syncFastLfo = true, setFastEnv = true,
  stopFastEnv = true, setScatter = true }

local function walk_lfo(random) return random(local_value("S").constants.NUM_LFOS) end
local function pick(random, list) return list[random(#list)] end

-- A recall's send that only repeats the last one of its kind but for
-- rounding (#977, package 2b: norns' Control:set_raw runs the action on any
-- change of the raw value, and a recalled value maps to a raw value an ulp
-- or so from the one in force): the same command, and for a voice's
-- setVoiceParam or setGrainParam the same voice and param, every argument
-- equal to the last such call's or within Model.ENGINE.ulp of it
local function same_but_rounding(entry, earlier)
  if entry.name ~= earlier.name or #entry.args ~= #earlier.args then return false end
  for index, value in ipairs(entry.args) do
    local other = earlier.args[index]
    if type(value) == "number" and type(other) == "number" then
      if math.abs(value - other) > Model.ENGINE.ulp * math.max(1, math.abs(other)) then return false end
    elseif value ~= other then
      return false
    end
  end
  return true
end

local function same_kind(entry, earlier)
  if entry.name ~= earlier.name then return false end
  if entry.name == "setVoiceParam" or entry.name == "setGrainParam" then
    return entry.args[1] == earlier.args[1] and entry.args[2] == earlier.args[2]
  end
  return true
end

-- The calls from index `from` on that are not a rounding resend of the last
-- call of their kind before them (#977's allowance, counted in
-- state.allowed.ulp_resend)
local function needless_sends(state, from)
  local calls, found = state.context.engine_calls, {}
  for index = from + 1, #calls do
    local entry, resend = calls[index], false
    for earlier = index - 1, 1, -1 do
      if same_kind(entry, calls[earlier]) then
        resend = same_but_rounding(entry, calls[earlier])
        break
      end
    end
    if resend then
      state.allowed.ulp_resend = (state.allowed.ulp_resend or 0) + 1
    else
      local args = {}
      for k, value in ipairs(entry.args) do args[k] = tostring(value) end
      found[#found + 1] = entry.name .. "(" .. table.concat(args, ", ") .. ")"
    end
  end
  return found
end

local function lfo_param(n, field) return "strata_lfo" .. n .. (field and ("_" .. field) or "") end

-- What a home key is: "engine" (a fast entry), "direct" (a macro), "lua"
-- (any other), "none"
local function home_kind(S, key)
  if key == "" then return "none" end
  if S.lib.lfos.fast_destination(key) then return "engine" end
  if key:match("^macro_%d+$") then return "direct" end
  return "lua"
end

local function count(state, name) state.counts[name] = (state.counts[name] or 0) + 1 end

-- Run the clocks until the macros have applied what was moved (their clock
-- ends once nothing is pending)
local function settle_macros(state)
  for _ = 1, 20 do
    if state.S.macro_clock == nil then return end
    state.context.clock.run_for(1 / 30)
  end
end

local MODULATION_WALK_OPS = {
  { 3, "lfo on", function(state, random) params:set(lfo_param(walk_lfo(random)), 1) end },
  { 2, "lfo off", function(state, random) params:set(lfo_param(walk_lfo(random)), 0) end },
  { 3, "depth", function(state, random)
    params:set(lfo_param(walk_lfo(random), "depth"), random(3) == 1 and 0 or random(101) - 1)
  end },
  { 3, "home", function(state, random)
    local n, key = walk_lfo(random), pick(random, state.homes)
    local before = home_kind(state.S, state.S.lib.matrix.home(n))
    state.S.lib.matrix.set_home(n, key)
    local after = home_kind(state.S, key)
    if params:get(lfo_param(n)) == 1 and params:get(lfo_param(n, "depth")) > 0
      and ((before == "engine" and after == "lua") or (before == "lua" and after == "engine")) then
      count(state, "home_engine_lua")
    end
  end },
  { 2, "shape", function(state, random)
    params:set(lfo_param(walk_lfo(random), "shape"), random(#state.S.lib.lfos.LFO.shapes))
  end },
  { 1, "mode", function(state, random) params:set(lfo_param(walk_lfo(random), "mode"), random(2)) end },
  { 1, "offset", function(state, random) params:set(lfo_param(walk_lfo(random), "offset"), random(41) - 21) end },
  -- a silent set of an LFO param (a set without its action: what a silent
  -- PSET read does to each param, which converges at the next step, #634)
  { 3, "silent set", function(state, random)
    local n, field = walk_lfo(random), pick(random, { false, "depth", "shape", "mode", "offset", "phase" })
    local values = { [false] = random(2) - 1, depth = random(3) == 1 and 0 or random(101) - 1,
      shape = random(#state.S.lib.lfos.LFO.shapes), mode = random(2), offset = random(41) - 21, phase = random(101) - 1 }
    params:set(lfo_param(n, field or nil), values[field], true)
    count(state, "silent_sets")
  end },
  { 3, "routing", function(state, random)
    local k = random(state.routing_slots)
    state.S.lib.matrix.set_routing(k, pick(random, state.sources), pick(random, state.destinations))
    params:set("matrix_" .. k .. "_depth", random(201) - 101)
    params:set("matrix_" .. k, random(4) == 1 and 0 or 1)
  end },
  { 1, "routing cleared", function(state, random) state.S.lib.matrix.clear(random(state.routing_slots)) end },
  { 2, "envelope route", function(state, random)
    local k = random(state.routing_slots)
    state.S.lib.matrix.set_routing(k, "env" .. random(state.voices), pick(random, state.fast_destinations))
    params:set("matrix_" .. k .. "_depth", random(201) - 101)
    params:set("matrix_" .. k, 1)
  end },
  -- an envelope's time set by hand (a longer or shorter run), its sustain
  -- or its loop
  { 3, "envelope time", function(state, random)
    local voice = random(state.voices)
    local field = pick(random, { "attack", "decay", "release", "decay", "sustain", "loop" })
    local value = ({ sustain = (random(3) - 1) / 2, loop = random(4) == 1 and 2 or 1 })[field]
      or 0.001 * 10 ^ (random(100) / 25)
    params:set("v" .. voice .. "_env_" .. field, value)
  end },
  { 3, "hit", function(state, random)
    local voice = random(state.voices)
    if state.S.voices[voice].active then
      state.S.lib.engine_sync.retrigger(voice, 1, "action")
    else
      toggle_voice(voice)
    end
  end },
  { 1, "voice toggle", function(state, random) toggle_voice(random(state.voices)) end },
  { 2, "time", function(state, random) state.context.clock.run_for(0.02 * random(15)) end },
  { 2, "recall", function(state, random)
    recall_scene(random(state.scenes))
    count(state, "recalls")
  end },
  -- a recall of the state in force (captured just now) sends nothing but
  -- #977's rounding resends
  { 1, "recall unchanged", function(state)
    capture_scene(state.unchanged_scene)
    local from = #state.context.engine_calls
    recall_scene(state.unchanged_scene)
    for _, text in ipairs(needless_sends(state, from)) do
      state.problems[#state.problems + 1] = "a recall of the state in force sent " .. text
    end
    count(state, "unchanged_recalls")
  end },
  { 1, "capture", function(state, random) capture_scene(random(state.scenes)) end },
  { 1, "fade", function(state, random)
    recall_scene(random(state.scenes), state.fade_seconds)
    state.context.clock.run_for(state.fade_seconds + 0.1)
    count(state, "fades")
  end },
  -- a fade crossed by an instant recall before it lands
  { 1, "fade crossed", function(state, random)
    recall_scene(random(state.scenes), state.fade_seconds)
    state.context.clock.run_for(state.fade_seconds * random(9) / 10)
    if state.S.scene_transition_active then count(state, "fades_crossed") end
    recall_scene(random(state.scenes))
  end },
  { 2, "source", function(state, random)
    local voice = random(state.voices)
    local source = pick(random, state.source_options)
    if source == "another voice" then source = state.S.constants.SOURCE_VOICE_FIRST + voice % state.voices end
    params:set("v" .. voice .. "_source", source)
  end },
  -- a macro moved onto an LFO's depth: its apply sets the depth as a
  -- deferrable source (#633: through the round robin and the budget)
  { 2, "macro on a depth", function(state, random)
    local m, n = random(2), walk_lfo(random)
    state.S.lib.macros.set_target(m, 1, lfo_param(n, "depth"), 0, 1)
    params:set("macro_" .. m, random(101) / 100 - 0.01)
    settle_macros(state)
    count(state, "macro_depths")
  end },
  -- every routing from one macro to a channel of its own: more channels
  -- move in one step than the round robin's 12, so some wait for the next
  { 0.5, "burst", function(state, random)
    local channels = state.burst_channels
    for k = 1, state.S.constants.MATRIX_SLOTS do
      state.S.lib.matrix.set_routing(k, state.burst_source, channels[(k + random(#channels)) % #channels + 1])
      params:set("matrix_" .. k .. "_depth", random(2) == 1 and 50 + random(50) or -50 - random(50))
      params:set("matrix_" .. k, 1)
    end
    params:set(state.burst_macro, random(100) / 100)
    settle_macros(state)
    count(state, "bursts")
  end },
  { 1, "scatter", function(state, random)
    params:set(pick(random, { "scatter", "scatter_depth", "scatter_pos", "scatter_size" }),
      random(2) == 1 and random(2) - 1 or random(60))
  end },
}

-- Every mod source's value now, by key (an idle step allows the sends a
-- source that moved makes)
local function source_values(S)
  local values = {}
  for _, record in ipairs(S.lib.mod_sources.registered()) do values[record.key] = S.lib.mod_sources.normalized(record.key) end
  return values
end

local function moved(before, after)
  for key, value in pairs(after) do
    if before[key] ~= value then return true end
  end
  return false
end

-- The idle step: with nothing waiting (the round robin, the budget, a fade,
-- the macros), a step with no op since the last sends nothing, but a
-- clocked engine LFO's bar sync and, while a source moved in the step, a
-- moved value (a Lua destination's; a channel's offset only when it moves
-- the channel by LFO.send_threshold, or to 0: what the matrix sends past,
-- since nothing waits); never a node's start, move or stop
local function idle_step(state)
  local S, context = state.S, state.context
  local busy = Model.anything_waiting(S) or S.scene_transition_active or S.macro_clock ~= nil
  local before, from = source_values(S), #context.engine_calls
  context.clock.advance_until(S.lfo_clock)
  if busy then
    count(state, "idle_busy")
    return {}
  end
  local source_moved, problems = moved(before, source_values(S)), {}
  local sent, offsets, threshold = 0, {}, S.lib.lfos.LFO.send_threshold
  local function needless(entry)
    problems[#problems + 1] = "an idle step sent " .. entry.name .. "(" .. table.concat(entry.args, ", ") .. ")"
  end
  for index = from + 1, #context.engine_calls do
    local entry = context.engine_calls[index]
    local lfo = entry.name == "syncFastLfo" and entry.args[1] + 1
    if lfo and params:get(lfo_param(lfo, "mode")) == 2 then
      count(state, "idle_bar_syncs")
    elseif NODE_COMMANDS[entry.name] or not source_moved then
      needless(entry)
    elseif entry.name == "setFastOffset" then
      local key = entry.args[1] .. " " .. entry.args[3]
      local had = offsets[key] or state.model.offsets[entry.args[1]][entry.args[3]]
      local value = entry.args[4]
      if math.abs(value - had) < threshold and not (value == 0 and had ~= 0) then needless(entry) end
      offsets[key] = value
    end
    sent = sent + 1
  end
  count(state, sent == 0 and "idle_quiet" or "idle_moving")
  return problems
end

h.walk({
  name = "the engine's modulation nodes agree with what the params imply over seeded random play (#916)",
  seeds = { 2026, 916, 31337, 7 },
  steps = 400,
  setup = function(context, random)
    local S = local_value("S")
    local constants = S.constants
    local state = { context = context, S = S, model = Model.new(constants), counts = {}, allowed = {}, problems = {},
      voices = 3, scenes = 3, unchanged_scene = 4, routing_slots = 6, fade_seconds = 2,
      source_options = { constants.SOURCE_SYNTH, constants.SOURCE_SYNTH + 1, constants.SOURCE_INPUT, "another voice" } }
    -- the walk's homes, routing sources and destinations: voices 1-3's, a
    -- few globals, two macros, none
    local function walked(id)
      local voice = tonumber(id:match("^v(%d+)_"))
      return (voice and voice <= state.voices) or id == "filter_freq" or id == "delay_mix" or id == "macro_1"
    end
    state.homes = { "" }
    for _, destination in ipairs(S.LFO_DESTINATIONS) do
      if destination.key ~= "none" and walked(destination.key) then state.homes[#state.homes + 1] = destination.key end
    end
    state.destinations, state.fast_destinations = {}, {}
    for _, id in ipairs(S.lib.matrix.destination_ids()) do
      if walked(id) then
        state.destinations[#state.destinations + 1] = id
        if S.lib.lfos.fast_destination(id) then state.fast_destinations[#state.fast_destinations + 1] = id end
      end
    end
    -- the burst's: every voice's fast params, and a macro no other op moves
    state.burst_channels = {}
    for _, id in ipairs(S.lib.matrix.destination_ids()) do
      if S.lib.lfos.fast_destination(id) then state.burst_channels[#state.burst_channels + 1] = id end
    end
    state.sources = {}
    for n = 1, constants.NUM_LFOS do state.sources[#state.sources + 1] = "lfo" .. n end
    for voice = 1, state.voices do state.sources[#state.sources + 1] = "env" .. voice end
    local macros = S.lib.mod_sources.registered("macros")
    state.sources[#state.sources + 1], state.sources[#state.sources + 2] = macros[1].key, macros[2].key
    state.burst_source, state.burst_macro = macros[3].key, "macro_3"
    -- slow LFOs (0.003 Hz, a clocked one 1024 bars), so an idle step finds
    -- most sources still and must then send nothing at all
    for n = 1, constants.NUM_LFOS do
      params:set(lfo_param(n, "rate"), S.lib.lfos.LFO.min_hz)
      params:set(lfo_param(n, "division"), #S.lib.lfos.LFO.divisions)
    end
    toggle_voice(1)
    -- three scenes, each with a few LFOs on homes of their own
    for scene = 1, state.scenes do
      for n = 1, constants.NUM_LFOS do
        S.lib.matrix.set_home(n, pick(random, state.homes))
        params:set(lfo_param(n, "shape"), random(#S.lib.lfos.LFO.shapes))
        params:set(lfo_param(n, "depth"), random(101) - 1)
        params:set(lfo_param(n), random(2) - 1)
      end
      capture_scene(scene)
    end
    context.clock.advance_until(S.lfo_clock)
    state.model:feed(context.engine_calls)
    return state
  end,
  ops = MODULATION_WALK_OPS,
  after = function(state)
    local S, context, model = state.S, state.context, state.model
    local problems = state.problems
    state.problems = {}
    context.clock.advance_until(S.lfo_clock)
    model:feed(context.engine_calls)
    for _, problem in ipairs(model:compare(S, WALK_ALLOWED)) do problems[#problems + 1] = problem end
    for _, problem in ipairs(idle_step(state)) do problems[#problems + 1] = problem end
    model:feed(context.engine_calls)
    for _, problem in ipairs(model:compare(S, WALK_ALLOWED)) do problems[#problems + 1] = "after the idle step: " .. problem end
    return problems
  end,
  -- the sequences reach every path: a node started, stopped and replaced
  -- (moved to another voice or destination too), a home moved between the
  -- engine and Lua, recalls, fades and a fade crossed by a recall, a
  -- recall of the state in force, silent sets, a macro on a depth, routes
  -- set, moved and stopped, channels sent, envelopes seen ended, idle steps
  -- that sent nothing, and each allowance of WALK_ALLOWED and #977's
  -- (allowed_<name>), so a fault's fix must remove its allowance
  reached = { "lfo_started", "lfo_stopped", "lfo_replaced", "lfo_moved", "home_engine_lua", "recalls", "fades",
    "fades_crossed", "unchanged_recalls", "silent_sets", "macro_depths", "routes_set", "routes_moved", "routes_stopped",
    "offsets_sent", "envelopes_ended", "idle_quiet", "allowed_waiting", "allowed_ended_runs_again",
    "allowed_ulp_resend" },
  counts = function(state)
    local counts = {}
    for name, value in pairs(state.model.counts) do counts[name] = value end
    for name, value in pairs(state.counts) do counts[name] = value end
    for name in pairs(WALK_ALLOWED) do counts["allowed_" .. name] = state.model.allowed[name] or 0 end
    counts.allowed_ulp_resend = state.allowed.ulp_resend or 0
    return counts
  end,
})

end

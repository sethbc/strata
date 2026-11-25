-- test/unit/envelopes_test.lua
-- The envelopes (lib/envelopes.lua, S.lib.envelopes, 3.7 design §7): one
-- envelope per voice (attack, decay to a sustain, the hit's hold, release),
-- fired by its voice's hits; Lua's model (shape, value) for the matrix's Lua
-- destinations and MOD; the sources env1..env7 and their settings rows; a
-- routing to a fast destination handed to the engine (setFastEnv,
-- stopFastEnv) and left out of the matrix's sum; the six params in scenes
-- Run alone: lua test/run.lua envelopes

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function loaded(options)
  local context = load_strata(options); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.envelopes
end

-- Run the clocks until the LFO clock (the envelopes and the matrix step in
-- its hooks) has stepped `count` times (default 1)
local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

-- Routing k from source to dest at depth percent (on, as by default)
local function route(S, k, source, dest, depth)
  assert_true(S.lib.matrix.set_routing(k, source, dest), "routing " .. k .. " is set")
  params:set("matrix_" .. k .. "_depth", depth)
end

-- A call's arguments as one line
local function call_text(call)
  local parts = {}
  for index, value in ipairs(call.args) do
    parts[index] = type(value) == "number" and string.format("%g", value) or tostring(value)
  end
  return call.name .. "(" .. table.concat(parts, ", ") .. ")"
end

-- The calls named `name`, one line each, in order (sorted: in any order)
local function calls_text(context, name, sorted)
  local lines = {}
  for _, call in ipairs(context.calls_named(name)) do lines[#lines + 1] = call_text(call) end
  if sorted then table.sort(lines) end
  return table.concat(lines, "; ")
end

-- Voice v's six envelope params set
local function set_envelope(v, attack, decay, sustain, release, curve, loop)
  params:set("v" .. v .. "_env_attack", attack)
  params:set("v" .. v .. "_env_decay", decay)
  params:set("v" .. v .. "_env_sustain", sustain)
  params:set("v" .. v .. "_env_release", release)
  params:set("v" .. v .. "_env_curve", curve)
  params:set("v" .. v .. "_env_loop", loop and 2 or 1)
end

local LINEAR = {attack = 0.1, decay = 0.1, sustain = 0.5, release = 0.1, curve = 0, loop = false}

test("the shape: attack to 1, decay to the sustain, hold, release to 0", function()
  local _, _, envelopes = loaded()
  local shape = envelopes.shape
  local expected = {{0, 0}, {0.05, 0.5}, {0.1, 1}, {0.15, 0.75}, {0.2, 0.5}, {0.3, 0.5}, {0.4, 0.5}, {0.45, 0.25},
    {0.5, 0}, {0.75, 0}, {10, 0}}
  for _, pair in ipairs(expected) do
    assert_near(shape(LINEAR, pair[1], 0.2, 0), pair[2], 1e-9, "at " .. pair[1] .. " s")
  end
  -- the curve bends each slope: (1 - exp(c t / T)) / (1 - exp(c))
  local bent = {attack = 0.1, decay = 0.1, sustain = 0.5, release = 0.1, curve = -4, loop = false}
  local half = (1 - math.exp(-2)) / (1 - math.exp(-4))
  assert_near(shape(bent, 0.05, 0.2, 0), half, 1e-9, "half the attack at curve -4")
  assert_near(shape(bent, 0.15, 0.2, 0), 1 + (0.5 - 1) * half, 1e-9, "half the decay")
  assert_near(shape(bent, 0.45, 0.2, 0), 0.5 - 0.5 * half, 1e-9, "half the release")
  assert_equal(envelopes.ENVELOPES.routes, 16)
  assert_equal(envelopes.ENVELOPES.time_min, 0.001)
  assert_equal(envelopes.ENVELOPES.time_max, 10)
  assert_equal(envelopes.ENVELOPES.approximate_under, 0.05)
  assert_equal(envelopes.ENVELOPES.routes, local_value("MATRIX_SLOTS"), "a route is a matrix slot")
end)

test("sustain 0 is attack and decay; a new hit starts from the level it is at; loop starts again", function()
  local context, S, envelopes = loaded()
  local shape = envelopes.shape
  local ad = {attack = 0.1, decay = 0.1, sustain = 0, release = 0.1, curve = 0, loop = false}
  assert_near(shape(ad, 0.15, 1, 0), 0.5, 1e-9, "the decay to 0")
  for _, t in ipairs({0.2, 0.3, 0.5, 1.05, 2}) do
    assert_near(shape(ad, t, 1, 0), 0, 1e-9, "sustain 0 holds nothing at " .. t .. " s, whatever the hold")
  end
  -- from a level: the attack runs from it to 1 in the attack's time
  assert_near(shape(LINEAR, 0, 0.2, 0.5), 0.5, 1e-9, "from 0.5")
  assert_near(shape(LINEAR, 0.05, 0.2, 0.5), 0.75, 1e-9, "half way from 0.5 to 1")
  assert_near(shape(LINEAR, 0.1, 0.2, 0.5), 1, 1e-9)
  -- loop: the envelope starts again from 0 each time it ends
  local looped = {attack = 0.1, decay = 0.1, sustain = 0, release = 0.1, curve = 0, loop = true}
  assert_near(shape(looped, 0.25, 0, 0), shape(ad, 0.05, 0, 0), 1e-9, "the second cycle's attack")
  assert_near(shape(looped, 0.45, 0, 0.5), shape(ad, 0.05, 0, 0), 1e-9, "a later cycle starts from 0")
  assert_near(shape(looped, 0.05, 0, 0.5), 0.75, 1e-9, "the first cycle from the level of the hit")
  -- through the model: voice 2's second hit starts from the level the first reached
  set_envelope(2, 0.1, 0.1, 0.5, 0.1, 0, false)
  context.set_time(100)
  S.lib.engine_sync.retrigger(2, 1, "step")
  context.set_time(100.05)
  assert_near(envelopes.value(2), 0.5, 1e-9, "half the attack")
  S.lib.engine_sync.retrigger(2, 1, "step")
  assert_near(envelopes.value(2), 0.5, 1e-9, "the new hit starts at 0.5")
  context.set_time(100.1)
  assert_near(envelopes.value(2), 0.75, 1e-9, "half way to 1 from 0.5")
  -- loop on: it runs with no hit, and a hit restarts it
  set_envelope(3, 0.1, 0.1, 0, 0.1, 0, true)
  context.set_time(101.05)
  local running = envelopes.value(3)
  context.set_time(101.1)
  assert_true(envelopes.value(3) ~= running, "a looping envelope moves with no hit")
  S.lib.engine_sync.retrigger(3, 1, "step")
  local from = envelopes.value(3)
  context.set_time(101.25)
  assert_near(envelopes.value(3), shape(looped, 0.15, 0, from), 1e-9, "a hit restarts the loop")
  context.set_time(101.35)
  assert_near(envelopes.value(3), shape(looped, 0.05, 0, 0), 1e-9, "and it loops on")
end)

test("a hit on a gated voice holds for its gate length, and on an ungated one for none", function()
  local context, S, envelopes = loaded()
  set_envelope(2, 0.01, 0.01, 0.5, 0.1, 0, false)
  set_envelope(3, 0.01, 0.01, 0.5, 0.1, 0, false)
  params:set("v2_seq_gate", 2)  -- on
  params:set("v2_seq_gate_length", 8)
  local gate = S.lib.sequencer.gate_seconds(2)
  assert_true(gate > 0.2, "a long gate: " .. gate)
  -- a note on the gated voice holds for its gate length
  context.set_time(200)
  S.lib.engine_sync.retrigger(2, 1, "note")
  context.set_time(200 + 0.02 + gate / 2)
  assert_near(envelopes.value(2), 0.5, 1e-9, "held at the sustain")
  context.set_time(200 + 0.02 + gate + 0.05)
  assert_near(envelopes.value(2), 0.25, 1e-9, "half the release after the gate")
  -- a step's own gate length (info.gate_seconds)
  context.set_time(210)
  S.lib.engine_sync.retrigger(2, 1, "step", 0.1)
  context.set_time(210 + 0.02 + 0.1 + 0.05)
  assert_near(envelopes.value(2), 0.25, 1e-9, "the step's hold, 0.1 s")
  -- an ungated voice: no hold, the release follows the decay
  context.set_time(220)
  S.lib.engine_sync.retrigger(3, 1, "note")
  context.set_time(220 + 0.02 + 0.05)
  assert_near(envelopes.value(3), 0.25, 1e-9, "the release at once")
  context.set_time(220 + 0.2)
  assert_near(envelopes.value(3), 0, 1e-9, "over")
end)

-- 3.9's grid sequencer, package 1b: the engine's hold is seqGate x
-- gateSeconds, and a pulse voice's seqGate is the gate rule, so the model
-- holds while S.lib.sequencer.gate_wanted(voice) is 1
test("a pulse voice's envelope model holds as the engine's does", function()
  local context, S, envelopes = loaded()
  local seq = S.lib.sequencer
  set_envelope(2, 0.01, 0.01, 0.5, 0.1, 0, false)
  params:set("v2_seq_gate_length", 8)
  local gate = seq.gate_seconds(2)
  assert_equal(seq.step_mode(2), "pulse", "the default mode")
  -- no step: the rule is 0, so no hold
  context.set_time(200)
  S.lib.engine_sync.retrigger(2, 1, "note")
  context.set_time(200 + 0.02 + 0.05)
  assert_near(envelopes.value(2), 0.25, 1e-9, "no step: the release at once")
  -- a step past step 1, the patterns playing: the rule holds, and so does the model
  seq.set_level(2, 9, 15)
  pattern_clock_start()
  assert_equal(seq.gate_wanted(2), 1, "the rule holds")
  context.set_time(210)
  S.lib.engine_sync.retrigger(2, 1, "note")
  context.set_time(210 + 0.02 + gate / 2)
  assert_near(envelopes.value(2), 0.5, 1e-9, "held at the sustain for the gate length")
  context.set_time(210 + 0.02 + gate + 0.05)
  assert_near(envelopes.value(2), 0.25, 1e-9, "half the release after the gate")
  pattern_clock_stop()
  -- stopped: open again, no hold
  context.set_time(220)
  S.lib.engine_sync.retrigger(2, 1, "note")
  context.set_time(220 + 0.02 + 0.05)
  assert_near(envelopes.value(2), 0.25, 1e-9, "the patterns stopped: the release at once")
end)

test("each voice's envelope follows its own hits", function()
  local context, S, envelopes = loaded()
  for v = 1, S.constants.NUM_VOICES do set_envelope(v, 0.1, 0.1, 0.5, 0.1, 0, false) end
  context.set_time(300)
  for v = 1, S.constants.NUM_VOICES do assert_equal(envelopes.value(v), 0, "voice " .. v .. " has had no hit") end
  local sync = S.lib.engine_sync
  -- a step on voice 3
  sync.retrigger(3, 1, "step")
  context.set_time(300.05)
  assert_near(envelopes.value(3), 0.5, 1e-9, "a step fires voice 3's")
  for v = 1, S.constants.NUM_VOICES do
    if v ~= 3 then assert_equal(envelopes.value(v), 0, "not voice " .. v .. "'s") end
  end
  -- a MIDI note on voice 4 (its channel, 4), through lib/midi_in.lua
  assert_true(not S.voices[4].active, "voice 4 is stopped: the note starts it")
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 4})
  assert_true(S.voices[4].active, "the note started voice 4")
  context.set_time(300.1)
  assert_near(envelopes.value(4), 0.5, 1e-9, "a note fires voice 4's")
  context.midi.send(1, {type = "note_off", note = 60, vel = 0, ch = 4})
  context.set_time(300.13)
  context.midi.send(1, {type = "note_on", note = 62, vel = 100, ch = 4})
  context.set_time(300.18)
  assert_near(envelopes.value(4), 0.9, 1e-9, "a second note restarts it from the 0.8 it had reached (0.08 s in)")
  -- a start of voice 5
  if S.voices[5].active then toggle_voice(5) end
  context.set_time(301)
  toggle_voice(5)
  assert_true(S.voices[5].active, "voice 5 started")
  context.set_time(301.05)
  assert_near(envelopes.value(5), 0.5, 1e-9, "a start fires voice 5's")
  -- a chord step on voice 2
  if not S.voices[2].active then toggle_voice(2) end
  context.set_time(302)
  assert_equal(envelopes.value(2), 0, "nothing on voice 2 yet")
  S.patterns[2][1] = 15
  S.lib.sequencer.set_step_attr(2, 1, "notes", {0, 4, 7})
  local hits = 0
  S.register_voice_hit({name = "envelopes test count", hit = function(v) if v == 2 then hits = hits + 1 end end})
  pattern_clock_start()
  pattern_clock_stop()
  assert_equal(hits, 1, "a chord step is one hit")
  context.set_time(302.05)
  assert_near(envelopes.value(2), 0.5, 1e-9, "a chord step fires voice 2's once")
  assert_equal(envelopes.value(0), 0, "no voice 0")
  assert_equal(envelopes.value(S.constants.NUM_VOICES + 1), 0, "no voice past the last")
end)

test("the seven are sources with six fields each", function()
  local _, S, envelopes = loaded()
  local sources = S.lib.mod_sources
  for v = 1, S.constants.NUM_VOICES do
    local record = sources.get("env" .. v)
    assert_true(record ~= nil, "env" .. v .. " is a source")
    assert_equal(record.name, "EN" .. v)
    assert_equal(record.section, "envelopes")
    assert_equal(record.range[1], 0); assert_equal(record.range[2], 1)
    assert_equal(record.describe(), "5ms 200ms", "attack and decay at their defaults")
    local labels = {}
    for index, field in ipairs(record.fields) do labels[index] = field.label end
    assert_equal(table.concat(labels, " "), "attack decay sustain release curve loop")
  end
  assert_equal(#sources.list("envelopes"), 7, "MOD's envelopes section")
  -- the params' defaults
  assert_near(params:get("v1_env_attack"), 0.005, 1e-9)
  assert_near(params:get("v1_env_decay"), 0.2, 1e-9)
  assert_near(params:get("v1_env_sustain"), 0, 1e-9)
  assert_near(params:get("v1_env_release"), 0.2, 1e-9)
  assert_near(params:get("v1_env_curve"), -4, 1e-9)
  assert_equal(params:get("v1_env_loop"), 1)
  assert_equal(params:string("v1_env_loop"), "off")
  -- each field shows and edits its param
  local fields = sources.get("env4").fields
  assert_equal(fields[1].value(), "5ms")
  assert_equal(fields[2].value(), "200ms")
  assert_equal(fields[6].value(), "off")
  fields[6].enc(1)
  assert_equal(params:string("v4_env_loop"), "on", "loop's enc")
  local before = params:get("v4_env_attack")
  fields[1].enc(10)
  assert_true(params:get("v4_env_attack") > before, "attack's enc")
  fields[3].enc(10)
  assert_true(params:get("v4_env_sustain") > 0, "sustain's enc")
  params:set("v4_env_attack", 1.5)
  assert_equal(fields[1].value(), "1.5s")
  params:set("v4_env_attack", 10)
  assert_equal(fields[1].value(), "10s")
  assert_equal(sources.get("env4").describe(), "10s 200ms")
  for _, field in ipairs(fields) do
    assert_equal(type(field.value()), "string", field.label .. "'s value is text")
  end
  assert_near(sources.get("env4").value(), envelopes.value(4), 1e-12, "the source's value is the model's")
  assert_true(S.lib.pages_mod.open_settings("env4"), "MOD opens env4's settings")
end)

test("a routing from an envelope to a fast destination is the engine's", function()
  local context, S, envelopes = loaded()
  context.clear_engine_calls()
  route(S, 3, "env2", "v5_filter_freq", 50)
  lfo_step(context, 2)
  assert_equal(calls_text(context, "setFastEnv"), "setFastEnv(2, 1, 4, 3, 0.5, 0.005, 0.2, 0, 0.2, -4, 0)")
  assert_true(envelopes.owns(3), "routing 3 is the envelopes'")
  assert_true(not envelopes.owns(1), "routing 1 is not")
  -- a hit plays it in the engine: the matrix's fast offset does not hold it
  S.lib.engine_sync.retrigger(2, 1, "step")
  context.set_time(util.time() + 0.004)
  lfo_step(context, 3)
  assert_equal(S.lib.matrix.offset("v5_filter_freq"), 0, "the matrix's sum leaves it out")
  for _, call in ipairs(context.calls_named("setFastOffset")) do
    assert_true(not (call.args[1] == 4 and call.args[3] == 3 and call.args[4] ~= 0),
      "no fast offset on v5 cutoff: " .. call_text(call))
  end
  assert_equal(#context.calls_named("setFastEnv"), 1, "sent once, nothing per hit or step")
  assert_equal(#context.calls_named("stopFastEnv"), 0)
end)

test("turning the routing off, to a Lua destination or to another source stops its route", function()
  local context, S = loaded()
  local function stops() return calls_text(context, "stopFastEnv") end
  -- off
  route(S, 3, "env2", "v5_filter_freq", 50)
  lfo_step(context, 2)
  context.clear_engine_calls()
  set_binary_param("matrix_3", 0)
  lfo_step(context, 2)
  assert_equal(stops(), "stopFastEnv(2)", "off")
  lfo_step(context, 2)
  assert_equal(stops(), "stopFastEnv(2)", "once")
  set_binary_param("matrix_3", 1)
  lfo_step(context, 2)
  assert_equal(#context.calls_named("setFastEnv"), 1, "on again: sent again")
  -- to a Lua destination
  context.clear_engine_calls()
  route(S, 3, "env2", "reverb_mix", 50)
  lfo_step(context, 2)
  assert_equal(stops(), "stopFastEnv(2)", "a Lua destination")
  assert_equal(#context.calls_named("setFastEnv"), 0)
  -- to another source
  route(S, 3, "env2", "v5_filter_freq", 50)
  lfo_step(context, 2)
  context.clear_engine_calls()
  route(S, 3, "lfo1", "v5_filter_freq", 50)
  lfo_step(context, 2)
  assert_equal(stops(), "stopFastEnv(2)", "another source")
  -- depth 0, and a cleared routing
  route(S, 3, "env2", "v5_filter_freq", 50)
  lfo_step(context, 2)
  context.clear_engine_calls()
  params:set("matrix_3_depth", 0)
  lfo_step(context, 2)
  assert_equal(stops(), "stopFastEnv(2)", "depth 0")
  route(S, 3, "env2", "v5_filter_freq", 50)
  lfo_step(context, 2)
  context.clear_engine_calls()
  S.lib.matrix.clear(3)
  lfo_step(context, 2)
  assert_equal(stops(), "stopFastEnv(2)", "cleared")
  -- moved to another fast destination or source voice: set again, never stopped
  route(S, 3, "env2", "v5_filter_freq", 50)
  lfo_step(context, 2)
  context.clear_engine_calls()
  route(S, 3, "env6", "v1_grain_pitch", -100)
  lfo_step(context, 2)
  assert_equal(calls_text(context, "setFastEnv"), "setFastEnv(2, 5, 0, 0, -1, 0.005, 0.2, 0, 0.2, -4, 0)")
  assert_equal(stops(), "", "a move is a set")
end)

test("a param change resends that voice's routes and no other's", function()
  local context, S = loaded()
  route(S, 3, "env2", "v5_filter_freq", 50)
  route(S, 5, "env4", "v1_grain_pitch", 25)
  route(S, 7, "env2", "v3_amp", 100)
  lfo_step(context, 2)
  assert_equal(#context.calls_named("setFastEnv"), 3)
  context.clear_engine_calls()
  params:set("v2_env_attack", 0.5)
  lfo_step(context, 2)
  assert_equal(calls_text(context, "setFastEnv", true),
    "setFastEnv(2, 1, 4, 3, 0.5, 0.5, 0.2, 0, 0.2, -4, 0); setFastEnv(6, 1, 2, 4, 1, 0.5, 0.2, 0, 0.2, -4, 0)")
  context.clear_engine_calls()
  params:set("v4_env_loop", 2)
  params:set("v4_env_sustain", 0.25)
  lfo_step(context, 2)
  assert_equal(calls_text(context, "setFastEnv"), "setFastEnv(4, 3, 0, 0, 0.25, 0.005, 0.2, 0.25, 0.2, -4, 1)")
  context.clear_engine_calls()
  params:set("matrix_5_depth", -50)
  lfo_step(context, 2)
  assert_equal(calls_text(context, "setFastEnv"), "setFastEnv(4, 3, 0, 0, -0.5, 0.005, 0.2, 0.25, 0.2, -4, 1)",
    "a depth change resends the route")
end)

test("a routing to a Lua destination is summed by the matrix from the model", function()
  local context, S, envelopes = loaded()
  set_envelope(2, 0.1, 0.1, 0.5, 0.1, 0, false)
  context.set_time(util.time() + 10)  -- past the start's hit at init
  params:set("reverb_mix", 0.3)
  route(S, 1, "env2", "reverb_mix", 100)
  lfo_step(context, 2)
  local function engine_value() return S.lib.engine_sync.with_lfo_offsets("reverb_mix", params:get("reverb_mix")) end
  assert_near(engine_value(), 0.3, 1e-9, "no hit: nothing")
  S.lib.engine_sync.retrigger(2, 1, "step")
  lfo_step(context, 2)
  local level = envelopes.value(2)
  assert_true(level > 0 and level < 1, "the attack: " .. level)
  assert_near(engine_value(), 0.3 + S.lib.lfos.offset_for("reverb_mix", level), 1e-9, "the model's value")
  assert_equal(#context.calls_named("setFastEnv"), 0, "never the engine's")
end)

test("fast envelopes to Lua destinations are marked approximate", function()
  local context, S = loaded()
  local describe = S.lib.mod_sources.get("env2").describe
  assert_equal(describe(), "5ms 200ms", "unrouted")
  route(S, 1, "env2", "v5_filter_freq", 50)
  assert_equal(describe(), "5ms 200ms", "a fast destination is exact")
  route(S, 2, "env2", "reverb_mix", 50)
  assert_equal(describe(), "~5ms 200ms", "a Lua destination with a 5 ms attack")
  params:set("v2_env_attack", 0.1)
  assert_equal(describe(), "100ms 200ms", "slow enough")
  params:set("v2_env_decay", 0.01)
  assert_equal(describe(), "~100ms 10ms", "a fast decay")
  -- the boundary, as the time is shown (whole ms): 50 ms is not under 50
  -- ms, 49 ms is; a time shown as 50ms is never marked
  for _, decay in ipairs({0.05, 0.0499, 0.0501}) do
    params:set("v2_env_decay", decay)
    assert_equal(describe(), "100ms 50ms", decay .. " s shows 50ms, unmarked")
  end
  params:set("v2_env_decay", 0.049)
  assert_equal(describe(), "~100ms 49ms", "49 ms is under 50 ms")
  params:set("v2_env_attack", 0.05); params:set("v2_env_decay", 0.2)
  assert_equal(describe(), "50ms 200ms", "the attack at 50 ms, unmarked")
  params:set("v2_env_attack", 0.049)
  assert_equal(describe(), "~49ms 200ms", "the attack at 49 ms, marked")
  params:set("v2_env_attack", 0.1)
  params:set("v2_env_decay", 0.01)
  set_binary_param("matrix_2", 0)
  assert_equal(describe(), "100ms 10ms", "a routing that is off")
  assert_equal(S.lib.mod_sources.get("env3").describe(), "5ms 200ms", "another voice's")
end)

test("with no envelope routed nothing is sent", function()
  local context, S = loaded()
  context.clear_engine_calls()
  for v = 1, S.constants.NUM_VOICES do S.lib.engine_sync.retrigger(v, 1, "step") end
  params:set("v2_env_attack", 1)
  params:set("v3_env_loop", 2)
  route(S, 1, "lfo1", "v5_filter_freq", 50)
  lfo_step(context, 20)
  assert_equal(#context.calls_named("setFastEnv"), 0)
  assert_equal(#context.calls_named("stopFastEnv"), 0)
end)

test("the six params are scene fields that default in a 3.6 scene", function()
  local context, S = loaded()
  capture_scene(1)
  set_envelope(1, 2, 3, 0.5, 4, 2, true)
  capture_scene(2)
  local extras = S.scenes[2].data.voices[1].values
  assert_near(extras.env_attack, 2, 1e-9); assert_near(extras.env_decay, 3, 1e-9)
  assert_near(extras.env_sustain, 0.5, 1e-9); assert_near(extras.env_release, 4, 1e-9)
  assert_near(extras.env_curve, 2, 1e-9); assert_equal(extras.env_loop, 2)
  recall_scene(1)
  assert_near(params:get("v1_env_attack"), 0.005, 1e-6, "scene 1's attack")
  assert_equal(params:get("v1_env_loop"), 1)
  recall_scene(2, 1)
  context.clock.run_for(0.5)
  assert_equal(params:get("v1_env_loop"), 1, "half way: the loop is still off")
  local sustain = params:get("v1_env_sustain")
  assert_true(sustain > 0.05 and sustain < 0.45, "the sustain crossfades: " .. sustain)
  context.clock.run_for(0.6)
  assert_equal(params:get("v1_env_loop"), 2, "on at the end")
  assert_near(params:get("v1_env_sustain"), 0.5, 1e-6)
  -- a scene saved before the envelopes
  local old = h.deep_copy(S.scenes[2])
  for _, voice in ipairs(old.data.voices) do
    for _, key in ipairs({"env_attack", "env_decay", "env_sustain", "env_release", "env_curve", "env_loop"}) do
      voice.values[key] = nil
    end
  end
  fill_scene(old)
  assert_true(validate_scene(old), "it loads")
  local filled = old.data.voices[3].values
  assert_near(filled.env_attack, 0.005, 1e-9); assert_near(filled.env_decay, 0.2, 1e-9)
  assert_near(filled.env_sustain, 0, 1e-9); assert_near(filled.env_release, 0.2, 1e-9)
  assert_near(filled.env_curve, -4, 1e-9); assert_equal(filled.env_loop, 1)
  -- a value outside its range refuses the scene
  local bad = h.deep_copy(S.scenes[2])
  bad.data.voices[1].values.env_attack = 20
  assert_true(not validate_scene(bad), "an attack of 20 s is refused")
end)


test("turning loop off finishes the cycle it is in, as the engine does", function()
  local context, S, envelopes = loaded()
  local shape = envelopes.shape
  local ad = {attack = 0.1, decay = 0.1, sustain = 0, release = 0.1, curve = 0, loop = false}
  set_envelope(3, 0.1, 0.1, 0, 0.1, 0, false)
  context.set_time(400)
  S.lib.engine_sync.retrigger(3, 1, "step")
  params:set("v3_env_loop", 2)
  -- the third cycle (0.4 to 0.6 s), 0.05 s into its attack
  context.set_time(400.45)
  assert_near(envelopes.value(3), shape(ad, 0.05, 0, 0), 1e-9, "the third cycle's attack")
  params:set("v3_env_loop", 1)
  assert_near(envelopes.value(3), shape(ad, 0.05, 0, 0), 1e-9, "loop off: the cycle runs on")
  context.set_time(400.55)
  assert_near(envelopes.value(3), shape(ad, 0.15, 0, 0), 1e-9, "its decay")
  context.set_time(400.65)
  assert_equal(envelopes.value(3), 0, "it ends and does not start again")
  context.set_time(401)
  assert_equal(envelopes.value(3), 0)
  -- loop off in the first cycle: the hit itself runs on
  params:set("v3_env_loop", 2)
  context.set_time(402)
  S.lib.engine_sync.retrigger(3, 1, "step")
  context.set_time(402.05)
  params:set("v3_env_loop", 1)
  context.set_time(402.15)
  assert_near(envelopes.value(3), shape(ad, 0.15, 0, 0), 1e-9, "the first cycle runs on")
  -- loop off on an envelope that was not looping changes nothing: an ended one stays ended
  context.set_time(410)
  params:set("v3_env_loop", 1)
  assert_equal(envelopes.value(3), 0, "an ended envelope stays at 0")
end)

-- #969: with the loop off, an envelope whose run has ended reads 0 until
-- its next hit, whatever its times are set to after: by hand, silently
-- (which the model never reads: the stored value moves only with the
-- action) or through a silent PSET read (whose hook sets each moved param
-- with its action)
test("a silent raise of a time after the end leaves the level at 0", function()
  local context, S, envelopes = loaded()
  local path = context.data_dir .. "strata-01.pset"
  params:set("v3_env_decay", 5)
  params:write(path)
  params:set("v3_env_decay", 0.2)
  context.set_time(600)
  S.lib.engine_sync.retrigger(3, 1, "step")
  context.set_time(601)
  assert_equal(envelopes.value(3), 0, "the 0.205 s run has ended")
  params:set("v3_env_release", 5, true)
  params:set("v3_env_sustain", 0.5, true)
  assert_equal(envelopes.value(3), 0, "a silent set leaves it ended")
  params:read(path, true)
  assert_equal(S.voices[3].values.env_decay, params:get("v3_env_decay"), "the read's decay is stored")
  assert_true(params:get("v3_env_decay") > 4.9, "a decay of 5 s")
  assert_equal(envelopes.value(3), 0, "a silent PSET read with a longer decay leaves it ended")
  params:set("v3_env_attack", 3)
  assert_equal(envelopes.value(3), 0, "a longer attack by hand leaves it ended")
  -- the next hit runs, from 0, with the times now set
  S.lib.engine_sync.retrigger(3, 1, "step")
  context.set_time(602)
  local now_set = {attack = params:get("v3_env_attack"), decay = params:get("v3_env_decay"), sustain = 0,
    release = 0.2, curve = -4, loop = false}
  assert_near(envelopes.value(3), envelopes.shape(now_set, 1, 0, 0), 1e-9, "the next hit runs from 0")
end)

test("an ended envelope whose times were raised starts again when the loop goes on", function()
  local context, S, envelopes = loaded()
  context.set_time(700)
  S.lib.engine_sync.retrigger(3, 1, "step")
  context.set_time(701)
  params:set("v3_env_decay", 5)
  assert_equal(envelopes.value(3), 0, "ended")
  params:set("v3_env_loop", 2)
  context.set_time(701.5)
  assert_true(envelopes.value(3) > 0, "the loop starts it at once, from 0: " .. envelopes.value(3))
end)

test("a step resolves each envelope routing once and owns reads the matrix's status", function()
  local context, S, envelopes = loaded()
  route(S, 3, "env2", "v5_filter_freq", 50)
  route(S, 4, "env3", "reverb_mix", 50)
  lfo_step(context, 2)
  local matrix = S.lib.matrix
  local real_playing, calls = matrix.playing, 0
  matrix.playing = function(k) calls = calls + 1; return real_playing(k) end
  lfo_step(context)
  matrix.playing = real_playing
  assert_equal(calls, 2, "one resolution per envelope routing a step")
  -- owns is the matrix's status (#926), never a resolution of its own
  matrix.playing = function() error("owns resolved the routing again") end
  assert_true(envelopes.owns(3), "routing 3, status owned")
  assert_true(not envelopes.owns(4), "a Lua destination is the matrix's")
  matrix.playing = real_playing
end)

-- The final review's Lua B, Minor 1: ALT+E3 turns an envelope's control
-- rows finely (enc_param_delta), and the ALT hint says so; loop, an option,
-- has no fine turn
test("MOD's ALT hint names E3:fine on an envelope's control rows, not on loop", function()
  local context, S = loaded()
  h.show_page("MOD")
  assert_true(S.lib.pages_mod.open_settings("env1"))
  key(1, 1); redraw()
  assert_equal(h.hint_text(context), "E3:fine", "attack with ALT")
  local before = params:get("v1_env_attack")
  enc(3, 1)
  local fine = params:get("v1_env_attack") - before
  key(1, 0)
  params:set("v1_env_attack", before)
  enc(3, 1)
  assert_true(fine > 0 and fine < params:get("v1_env_attack") - before, "ALT+E3 turns it finer than E3")
  enc(2, 5); key(1, 1); redraw()
  assert_equal(h.hint_text(context), "", "loop with ALT: no fine turn")
  key(1, 0)
end)

-- The machine `envelope model` (docs/notes/lua/envelopes.md, Machines):
-- voice 3's last hit (the module's hits, value's upvalue) and its stored
-- loop: no hit, running (the loop off, less time since the hit than the
-- run), ended, or looping (the loop on). The defaults: attack 0.005 s,
-- decay 0.2 s, sustain 0, so a run is 0.205 s
local MODEL_VOICE = 3
local function model_hit()
  local envelopes = local_value("S").lib.envelopes
  for index = 1, math.huge do
    local name, value = debug.getupvalue(envelopes.value, index)
    if name == nil then error("value keeps no hits") end
    if name == "hits" then return value[MODEL_VOICE] end
  end
end
local function model_param(key) return "v" .. MODEL_VOICE .. "_" .. key end
local function model_hit_now() local_value("S").lib.engine_sync.retrigger(MODEL_VOICE, 1, "step") end
-- The defaults as M.shape takes them (decay: another decay), and the
-- level they give `elapsed` s after a hit from `from`
local function model_settings(decay, loop)
  return {attack = 0.005, decay = decay or 0.2, sustain = 0, release = 0.2, curve = -4, loop = loop == true}
end
local function model_level(elapsed, decay, loop, from)
  return local_value("S").lib.envelopes.shape(model_settings(decay, loop), elapsed, 0, from or 0)
end
local function model_value() return local_value("S").lib.envelopes.value(MODEL_VOICE) end
local function hit_now_from(from)
  return function()
    local hit = model_hit()
    assert_equal(hit.time, util.time(), "a hit recorded now")
    assert_near(hit.from, from, 1e-9, "from " .. from)
    assert_equal(hit.hold, 0, "with no hold")
  end
end

-- running is entered 0.1 s into its run, in the decay, so a hit there
-- starts from a level above 0
local function model_enter(state)
  return function(context)
    context.set_time(500)
    if state == "no hit" then return end
    model_hit_now()
    if state == "running" then context.set_time(500.1) end
    if state == "ended" then context.set_time(501) end
    if state == "looping" then
      params:set(model_param("env_loop"), 2)
      context.set_time(500.5)  -- the third cycle (0.41 to 0.615 s)
    end
  end
end

h.transition_table({
  name = "envelope model",
  notes = { "docs/notes/lua/envelopes.md", "envelope model" },
  states = { ["no hit"] = model_enter("no hit"), running = model_enter("running"), ended = model_enter("ended"),
    looping = model_enter("looping") },
  events = {
    ["a hit"] = model_hit_now,
    ["time passes"] = function(context) context.set_time(util.time() + 1) end,
    ["the loop on"] = function() params:set(model_param("env_loop"), 2) end,
    ["the loop off"] = function() params:set(model_param("env_loop"), 1) end,
    ["a longer decay"] = function() params:set(model_param("env_decay"), 5) end,
  },
  state_of = function()
    local values = local_value("S").voices[MODEL_VOICE].values
    local hit = model_hit()
    if hit == nil then return "no hit" end
    if values.env_loop == 2 then return "looping" end
    if hit.ended then return "ended" end
    local held = values.env_sustain > 0
    local run = values.env_attack + values.env_decay + (held and (hit.hold + values.env_release) or 0)
    return util.time() - hit.time < run and "running" or "ended"
  end,
  rows = {
    { "no hit", "a hit", "running", check = hit_now_from(0) },
    { "no hit", "time passes", "no hit" },
    { "no hit", "the loop on", "looping", check = hit_now_from(0) },
    { "no hit", "the loop off", "no hit" },
    { "no hit", "a longer decay", "no hit" },
    { "running", "a hit", "running", check = function()
      local level = model_level(0.1)
      assert_true(level > 0, "the level 0.1 s in is above 0: " .. level)
      hit_now_from(level)()
    end },
    { "running", "time passes", "ended", check = function()
      assert_equal(model_value(), 0, "the level is 0")
    end },
    { "running", "the loop on", "looping", check = function()
      assert_equal(model_hit().time, 500, "the hit runs on")
    end },
    { "running", "the loop off", "running" },
    { "running", "a longer decay", "running", check = function()
      assert_near(model_value(), model_level(0.1, 5), 1e-9, "the level follows the longer decay")
    end },
    { "ended", "a hit", "running", check = hit_now_from(0) },
    { "ended", "time passes", "ended", check = function()
      assert_equal(model_value(), 0, "the level stays 0")
    end },
    { "ended", "the loop on", "looping", check = hit_now_from(0) },
    { "ended", "the loop off", "ended" },
    -- #969: an ended run stays ended, as the engine's done EnvGen holds
    -- its end, however long the run is set after
    { "ended", "a longer decay", "ended", check = function()
      assert_equal(model_value(), 0, "the level stays 0")
    end },
    { "looping", "a hit", "looping", check = function()
      local level = model_level(0.5, nil, true)
      assert_true(level > 0, "the level in the third cycle is above 0: " .. level)
      hit_now_from(level)()
    end },
    { "looping", "time passes", "looping", check = function()
      -- 1.5 s after the hit: 0.065 s into the eighth cycle, in its decay
      local level = model_level(1.5, nil, true)
      assert_true(level > 0, "the next cycles play: " .. level)
      assert_near(model_value(), level, 1e-9, "each cycle again from 0")
    end },
    { "looping", "the loop on", "looping" },
    { "looping", "the loop off", "running", check = function()
      assert_near(model_hit().time, 500.41, 1e-9, "the hit moved to the third cycle's start")
    end },
    { "looping", "a longer decay", "looping", check = function()
      assert_near(model_value(), model_level(0.5, 5, true), 1e-9, "the cycle follows the longer decay")
    end },
  },
})

-- The machine `envelope route` (docs/notes/lua/envelopes.md, Machines):
-- route 3 by what the send budget holds for `env route 3`: nil, a
-- settings table, or false (a stop handed on). The routing is env2 to
-- voice 5's cutoff at 50 %
local ROUTE_KEY = "env route 3"
local function route_steps(context) lfo_step(context, 2) end
local function route_it(context)
  route(local_value("S"), 3, "env2", "v5_filter_freq", 50)
  set_binary_param("matrix_3", 1)
  route_steps(context)
end
local function unroute_it(context)
  set_binary_param("matrix_3", 0)
  route_steps(context)
end
local function route_enter(state)
  return function(context)
    if state ~= "nil" then route_it(context) end
    if state == "false" then unroute_it(context) end
    context.clear_engine_calls()
  end
end
local function route_calls(set, stop)
  return function(context)
    assert_equal(#context.calls_named("setFastEnv"), set, "setFastEnv sent " .. set)
    assert_equal(#context.calls_named("stopFastEnv"), stop, "stopFastEnv sent " .. stop)
  end
end

h.transition_table({
  name = "envelope route",
  notes = { "docs/notes/lua/envelopes.md", "envelope route" },
  states = { ["nil"] = route_enter("nil"), settings = route_enter("settings"), ["false"] = route_enter("false") },
  events = {
    ["route it"] = route_it,
    ["a step"] = route_steps,
    ["a setting changed"] = function(context)
      params:set("v2_env_attack", 0.3)
      route_steps(context)
    end,
    ["unroute it"] = unroute_it,
  },
  state_of = function()
    local had = local_value("S").lib.engine_sync.expected_value(ROUTE_KEY)
    if had == nil then return "nil" end
    if had == false then return "false" end
    if type(had) == "table" then return "settings" end
    return "a record of another kind"
  end,
  rows = {
    { "nil", "route it", "settings", check = route_calls(1, 0) },
    { "nil", "a step", "nil", check = route_calls(0, 0) },
    { "nil", "a setting changed", "nil", check = route_calls(0, 0) },
    { "nil", "unroute it", "nil", check = route_calls(0, 0) },
    { "settings", "route it", "settings", check = route_calls(0, 0) },
    { "settings", "a step", "settings", check = route_calls(0, 0) },
    { "settings", "a setting changed", "settings", check = route_calls(1, 0) },
    { "settings", "unroute it", "false", check = route_calls(0, 1) },
    { "false", "route it", "settings", check = route_calls(1, 0) },
    { "false", "a step", "false", check = route_calls(0, 0) },
    { "false", "a setting changed", "false", check = route_calls(0, 0) },
    { "false", "unroute it", "false", check = route_calls(0, 0) },
  },
})

end

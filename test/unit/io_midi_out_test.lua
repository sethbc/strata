-- test/unit/io_midi_out_test.lua
-- MIDI out (lib/io/midi_out.lua, S.lib.io_midi_out, 3.6 design §4): a
-- voice's notes to a MIDI port, plain or MPE (the port's lower zone), eight
-- CC out slots and program change in and out. No device is used: a recording
-- MIDI device (test/stub_midi.lua) is plugged at each port a test sends on,
-- and its sent bytes are read back through midi.to_msg.
-- Run alone: lua test/run.lua io_midi_out

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local MPE_INDEX = 2  -- v<i>_out_mode: plain, mpe

local function started(options)
  local context = load_strata(options); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.io_midi_out
end

local function midi_target(S)
  for _, record in ipairs(S.registry.note_targets) do
    if record.name == "midi" then return record end
  end
end

local function section(S, name)
  for _, record in ipairs(S.registry.io_sections) do
    if record.name == name then return record end
  end
end

-- A message as one line: "note_on 60 64 2", "note_off 60 2", "cc 74 32 2",
-- "pitchbend 8533 2", "channel_pressure 64 2", "program_change 4 1"
local function line(msg)
  if msg.type == "note_on" then return "note_on " .. msg.note .. " " .. msg.vel .. " " .. msg.ch end
  if msg.type == "note_off" then return "note_off " .. msg.note .. " " .. msg.ch end
  if msg.type == "cc" then return "cc " .. msg.cc .. " " .. msg.val .. " " .. msg.ch end
  return tostring(msg.type) .. " " .. tostring(msg.val) .. " " .. tostring(msg.ch)
end

local function lines(device)
  local list = {}
  for _, data in ipairs(device.sent) do list[#list + 1] = line(midi.to_msg(data)) end
  return list
end

local function sent(device) return table.concat(lines(device), "|") end
local function clear(device) device.sent = {} end

local function option(id, text)
  for index, name in ipairs(params:lookup_param(id).options) do
    if name == text then return index end
  end
  error("no option " .. text .. " for " .. id)
end

local function step(context, S, count)
  for _ = 1, count or 1 do context.clock.advance_until(S.lfo_clock) end
end

-- One step: the routes settle (build ruling 25)
local function settled(context) step(context, local_value("S")) end

local function step_info() return {source = "step"} end
local function played_info(key) return {source = "midi", owner = "midi", key = key} end

-- An MPE voice on port: mode mpe, members
local function mpe_voice(voice, port, members)
  params:set("v" .. voice .. "_out_port", port)
  if members then params:set("v" .. voice .. "_out_members", members) end
  params:set("v" .. voice .. "_out_mode", MPE_INDEX)
end

local SETUP_15_48 = "cc 101 0 1|cc 100 6 1|cc 6 15 1|cc 101 0 2|cc 100 0 2|cc 6 48 2|cc 101 0 1|cc 100 0 1|cc 6 2 1"
local TAKEDOWN = "cc 101 0 1|cc 100 6 1|cc 6 0 1"

-- Every param MIDI out adds, by id
local function midi_out_ids(S)
  local ids = {}
  for voice = 1, S.constants.NUM_VOICES do
    for _, field in ipairs({"port", "channel", "mode", "members"}) do ids[#ids + 1] = "v" .. voice .. "_out_" .. field end
  end
  ids[#ids + 1] = "midi_out_bend_range"
  for k = 1, 8 do
    for _, field in ipairs({"source", "source_key", "port", "channel", "number"}) do
      ids[#ids + 1] = "cc_out" .. k .. "_" .. field
    end
  end
  for _, id in ipairs({"midi_pc_in", "midi_pc_channel", "midi_pc_out", "midi_pc_out_port", "midi_pc_out_channel"}) do
    ids[#ids + 1] = id
  end
  return ids
end

test("the group holds 74 params, each at its default", function()
  local _, S, out = started()
  assert_equal(out.MIDI_OUT.express_per_step, 24); assert_equal(out.MIDI_OUT.cc_per_step, 8)
  assert_equal(out.MIDI_OUT.slots, 8); assert_equal(out.MIDI_OUT.master_channel, 1)
  assert_equal(out.MIDI_OUT.master_bend_range, 2); assert_equal(out.MIDI_OUT.slide_cc, 74)
  local ids = midi_out_ids(S)
  assert_equal(#ids, 74)
  local group = params:lookup_param("strata_out_midi")
  assert_equal(group.n, 74, "the group's count")
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_out_port"), 0)
    assert_equal(params:get("v" .. voice .. "_out_channel"), voice)
    assert_equal(params:string("v" .. voice .. "_out_mode"), "plain")
    assert_equal(params:get("v" .. voice .. "_out_members"), 15)
  end
  assert_equal(params:get("midi_out_bend_range"), 48)
  for k = 1, 8 do
    assert_equal(S.lib.io_keyed.key("cc_out" .. k .. "_source"), "off")
    assert_equal(params:get("cc_out" .. k .. "_port"), 1)
    assert_equal(params:get("cc_out" .. k .. "_channel"), 1)
    assert_equal(params:get("cc_out" .. k .. "_number"), k)
  end
  assert_equal(params:get("midi_pc_in"), 0); assert_equal(params:get("midi_pc_out"), 0)
  assert_equal(params:string("midi_pc_channel"), "any")
  assert_equal(params:get("midi_pc_out_port"), 1); assert_equal(params:get("midi_pc_out_channel"), 1)
end)

test("with defaults nothing is sent on any port", function()
  local context, S = started()
  local devices = {}
  for port = 1, 4 do devices[port] = context.midi.plug(port, "synth " .. port) end
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 1})
  context.midi.send(1, {type = "program_change", val = 2, ch = 1})
  capture_scene(1)
  recall_scene(1, 0)
  S.patterns[1][1] = 15
  pattern_clock_start()
  context.clock.run_for(1)
  pattern_clock_stop()
  context.midi.unplug(2); devices[2] = context.midi.plug(2, "synth 2")
  cleanup()
  for port = 1, 4 do assert_equal(sent(devices[port]), "", "port " .. port) end
end)

test("a plain voice sends its notes on its port and channel", function()
  local context, S = started()
  local device = context.midi.plug(3, "synth")
  local target = midi_target(S)
  assert_equal(target.routed(2), false, "port 0: not routed")
  params:set("v2_out_port", 3); settled(context)
  assert_equal(target.routed(2), true); assert_equal(target.routed(1), false)
  clear(device)
  target.note_on(2, "s1", 60.4, 0.5, step_info())
  assert_equal(sent(device), "note_on 60 64 2")
  clear(device)
  target.note_on(2, "s2", 200, 0.001, step_info())
  assert_equal(sent(device), "note_on 127 1 2", "clamped to 127, velocity at least 1")
  clear(device)
  target.note_off(2, "s1")
  assert_equal(sent(device), "note_off 60 2")
  target.note_off(2, "s2")
end)

---------------------------------------------------------------------------
-- As many offs as ons (#709): per port, channel and note, the ids sounding
-- there are counted. An id starting where the count is 0 sends its on; at 1
-- or more, an off, then its on (a retrigger). An id ending where the count
-- is 1 sends the off; at 2 or more, nothing
---------------------------------------------------------------------------

-- Note ons and offs of one note on one channel among device's sent messages
local function ons_and_offs(device, note, channel)
  local ons, offs = 0, 0
  for _, text in ipairs(lines(device)) do
    if text:match("^note_on " .. note .. " %d+ " .. channel .. "$") then ons = ons + 1 end
    if text == "note_off " .. note .. " " .. channel then offs = offs + 1 end
  end
  return ons, offs
end

test("a note that already sounds is retriggered: an off, then its on", function()
  local context, S = started()
  local device = context.midi.plug(3, "synth")
  local target = midi_target(S)
  params:set("v2_out_port", 3); settled(context)
  clear(device)
  target.note_on(2, "s1", 60, 0.5, step_info())
  assert_equal(sent(device), "note_on 60 64 2", "the count was 0: the on alone")
  clear(device)
  target.note_on(2, "m7740", 60, 1, played_info(7740))
  assert_equal(sent(device), "note_off 60 2|note_on 60 127 2", "the count was 1: an off, then the new id's on")
  clear(device)
  target.note_off(2, "s1")
  assert_equal(sent(device), "", "the count was 2: the first's end sends nothing")
  target.note_off(2, "m7740")
  assert_equal(sent(device), "note_off 60 2", "the count was 1: the last's end sends the off")
  -- the same on an MPE member channel (members 1, so the ids share channel 2)
  params:set("v2_out_port", 0)  -- its channel 2 would be inside the zone
  mpe_voice(1, 3, 1); settled(context)
  assert_equal(target.routed(1), true, "voice 1's zone on port 3")
  clear(device)
  target.note_on(1, "s1", 62, 1, step_info())
  assert_equal(sent(device), "pitchbend 8192 2|note_on 62 127 2", "alone on its member channel")
  clear(device)
  target.note_on(1, "s2", 62, 0.5, step_info())
  assert_equal(sent(device), "note_off 62 2|note_on 62 64 2", "a retrigger on the shared member channel")
  clear(device)
  target.note_on(1, "m40", 62, 1, played_info(40))
  local list = lines(device)
  assert_equal(list[1], "note_off 62 2", "the retrigger's off before the played note's first values: " .. sent(device))
  assert_equal(list[#list], "note_on 62 127 2", sent(device))
  clear(device)
  target.note_off(1, "s1"); target.note_off(1, "m40")
  assert_equal(sent(device), "", "two ids still held it, then one")
  target.note_off(1, "s2")
  assert_equal(sent(device), "note_off 62 2", "the last")
end)

test("a step repeating under a held played note leaves as many offs as ons", function()
  local context, S = started()
  local device = context.midi.plug(2, "mpe synth")
  local output
  for _, record in ipairs(S.registry.step_outputs) do
    if record.name == "targets" then output = record end
  end
  assert_true(output ~= nil, "the targets step output")
  params:set("midi_note_off", option("midi_note_off", "release"))  -- the key's lift ends the played note
  mpe_voice(1, 2, 1); settled(context)  -- one member channel: every note shares channel 2
  clear(device)
  context.midi.send(1, {type = "note_on", note = 36, vel = 100, ch = 1})  -- held: voice 1's played note
  assert_equal(select(1, ons_and_offs(device, 36, 2)), 1, "the played note went: " .. sent(device))
  for hit = 1, 10 do
    output.play({voice = 1, pitches = {36}, velocity = 0.8, beat = clock.get_beats(), gate_beats = 0.05})
    local ons, offs = ons_and_offs(device, 36, 2)
    assert_equal(ons, offs + 1, "hit " .. hit .. ": " .. ons .. " ons, " .. offs .. " offs")
    for _ = 1, 6 do step(context, S) end  -- the step's gate ends
    ons, offs = ons_and_offs(device, 36, 2)
    assert_equal(ons, offs + 1, "after hit " .. hit .. "'s gate: " .. ons .. " ons, " .. offs .. " offs")
  end
  context.midi.send(1, {type = "note_off", note = 36, vel = 0, ch = 1})
  output.stop()
  local ons, offs = ons_and_offs(device, 36, 2)
  assert_equal(ons, 11, "the played note and ten hits")
  assert_equal(offs, ons, "nothing sounds: as many offs as ons")
end)

test("three ids on one note, ended in every order, send one off each time a new one starts and one at the last", function()
  local context, S = started()
  local device = context.midi.plug(3, "synth")
  local target = midi_target(S)
  params:set("v2_out_port", 3); settled(context)
  local ids = {"s1", "s2", "m9"}
  local orders = {{1, 2, 3}, {1, 3, 2}, {2, 1, 3}, {2, 3, 1}, {3, 1, 2}, {3, 2, 1}}
  for _, order in ipairs(orders) do
    local why = "ended " .. table.concat(order, " ")
    clear(device)
    target.note_on(2, "s1", 60, 1, step_info())
    target.note_on(2, "s2", 60, 1, step_info())
    target.note_on(2, "m9", 60, 1, played_info(9))
    assert_equal(sent(device), "note_on 60 127 2|note_off 60 2|note_on 60 127 2|note_off 60 2|note_on 60 127 2",
      why .. ": three ons, a retrigger off before the second and the third")
    clear(device)
    target.note_off(2, ids[order[1]])
    target.note_off(2, ids[order[2]])
    assert_equal(sent(device), "", why .. ": no off while an id still holds the note")
    target.note_off(2, ids[order[3]])
    assert_equal(sent(device), "note_off 60 2", why .. ": the off at the last")
  end
end)

test("an off for an id that never started sends nothing", function()
  local context, S = started()
  local device = context.midi.plug(3, "synth")
  local target = midi_target(S)
  params:set("v2_out_port", 3); settled(context)
  clear(device)
  target.note_off(2, "s9")
  target.note_off(2, "m12")
  assert_equal(sent(device), "", "nothing sounds: nothing")
  target.note_on(2, "s1", 60, 1, step_info())
  clear(device)
  target.note_off(2, "s2")
  assert_equal(sent(device), "", "another id on the note that sounds: nothing")
  target.note_off(2, "s1")
  assert_equal(sent(device), "note_off 60 2", "the id that started still gets its off")
  clear(device)
  target.note_off(2, "s1")
  assert_equal(sent(device), "", "and only once")
end)

test("a step note alone on its member channel gets its centered bend; one sharing a channel gets none", function()
  local function last_bend(device, channel)
    local value
    for _, text in ipairs(lines(device)) do
      local found = text:match("^pitchbend (%d+) " .. channel .. "$")
      if found then value = tonumber(found) end
    end
    return value
  end
  for _, members in ipairs({2, 1}) do
    local context, S = started()
    local device = context.midi.plug(2, "mpe synth")
    local target = midi_target(S)
    params:set("midi_channel_mode", 3)  -- MPE input: voice 1
    mpe_voice(1, 2, members); settled(context)
    clear(device)
    context.midi.send(1, {type = "pitchbend", val = 9000, ch = 2})
    context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 2})
    local played = lines(device)
    assert_equal(played[1], "pitchbend 9000 2", "members " .. members .. ": the played note's bend on 2: " .. sent(device))
    assert_equal(played[#played], "note_on 60 100 2", "members " .. members .. ": its on, on 2")
    clear(device)
    target.note_on(1, "s1", 64, 1, step_info())
    if members == 2 then
      assert_equal(sent(device), "pitchbend 8192 3|note_on 64 127 3", "a channel of its own: its centered bend")
    else
      assert_equal(sent(device), "note_on 64 127 2", "sharing channel 2: no bend")
      clear(device)
      target.note_on(1, "s2", 60, 1, step_info())
      assert_equal(sent(device), "note_off 60 2|note_on 60 127 2", "the played note's own note: a retrigger, no bend")
      target.note_off(1, "s2")
    end
    step(context, S, 2)
    clear(device)
    target.note_off(1, "s1")
    assert_equal(last_bend(device, 2), nil, "nothing more bent channel 2")
    step(context, S, 2)
    assert_equal(sent(device):match("pitchbend %d+ 2") , nil, "no bend sent again on channel 2: " .. sent(device))
  end
end)

---------------------------------------------------------------------------
-- A shared MPE channel (members run out): while notes share it the newest
-- value written there stands; when a played note on it ends, each played
-- note still on it sends its current values once, at the next step
---------------------------------------------------------------------------

-- The pitchbend values sent on channel among device's sent messages
local function bends(device, channel)
  local list = {}
  for _, text in ipairs(lines(device)) do
    local value = text:match("^pitchbend (%d+) " .. channel .. "$")
    if value then list[#list + 1] = value end
  end
  return table.concat(list, " ")
end

-- A started Strata with voice 1 MPE on port 2 with one member channel, MPE input
local function one_member(members)
  local context, S = started()
  local device = context.midi.plug(2, "mpe synth")
  params:set("midi_channel_mode", 3); params:set("midi_note_off", 2)  -- MPE input: voice 1, release on a key's lift
  mpe_voice(1, 2, members or 1); settled(context)
  clear(device)
  return context, S, device
end

local function press(context, channel, note, bend)
  context.midi.send(1, {type = "pitchbend", val = bend, ch = channel})
  context.midi.send(1, {type = "note_on", note = note, vel = 100, ch = channel})
end

local function lift(context, channel, note)
  context.midi.send(1, {type = "note_off", note = note, vel = 0, ch = channel})
end

test("a played note ending on a shared channel puts back the bend of the one still on it, once", function()
  local context, S, device = one_member()
  press(context, 2, 60, 9000)
  press(context, 3, 64, 7000)
  assert_equal(bends(device, 2), "9000 7000", "both on channel 2; the second's first values put it at 7000")
  clear(device)
  step(context, S, 4)
  assert_equal(bends(device, 2), "", "while both sound, no bend: they share the newest")
  lift(context, 3, 64)
  assert_equal(sent(device), "note_off 64 2", "the second's off, nothing else yet")
  clear(device)
  step(context, S)
  assert_equal(bends(device, 2), "9000", "the next step: the one still on it, once")
  clear(device)
  step(context, S, 4)
  assert_equal(sent(device), "", "and nothing after")
  lift(context, 2, 60)
end)

test("with three played notes on a shared channel, the middle one ending puts back each other's bend once", function()
  local context, S, device = one_member()
  press(context, 2, 60, 9000)
  press(context, 3, 64, 7000)
  press(context, 4, 67, 8000)
  assert_equal(bends(device, 2), "9000 7000 8000")
  clear(device)
  step(context, S, 2)
  assert_equal(bends(device, 2), "", "no resending against each other")
  lift(context, 3, 64)
  clear(device)
  step(context, S)
  local after = {}
  for value in bends(device, 2):gmatch("%d+") do after[#after + 1] = value end
  table.sort(after)
  assert_equal(table.concat(after, " "), "8000 9000", "each note still on it once: " .. sent(device))
  clear(device)
  step(context, S, 4)
  assert_equal(sent(device), "", "no resending after that")
  lift(context, 2, 60); lift(context, 4, 67)
end)

-- The bends sent on channel since the device was last cleared, the last one
local function last_bend_on(device, channel)
  return bends(device, channel):match("(%d+)$")
end

test("a new note's first values on a shared channel stand over a resend that was pending", function()
  local context, S, device = one_member()
  press(context, 2, 60, 8704)  -- A
  press(context, 3, 64, 7000)  -- B
  step(context, S, 2)
  clear(device)
  lift(context, 3, 64)         -- B ends: A would resend at the next step
  press(context, 4, 67, 8533)  -- C, before any step
  assert_equal(bends(device, 2), "8533", "C's first bend")
  step(context, S, 3)
  assert_equal(last_bend_on(device, 2), "8533", "C's bend stands: " .. sent(device))
  assert_equal(bends(device, 2), "8533", "A sent nothing")
  clear(device)
  lift(context, 4, 67)         -- C ends: A's values go once
  step(context, S)
  assert_equal(bends(device, 2), "8704", "A's bend once")
  clear(device)
  step(context, S, 3)
  assert_equal(sent(device), "", "and nothing after")
  lift(context, 2, 60)
end)

test("a played note re-pitched in place on a shared channel keeps its own values there", function()
  local context, S, device = one_member()
  press(context, 2, 60, 8704)  -- A
  press(context, 3, 64, 7000)  -- B
  step(context, S, 2)
  local hook
  for _, record in ipairs(S.registry.note_hooks) do
    if record.name == "targets" then hook = record end
  end
  local key
  for id, record in pairs(S.lib.io_targets.sounding(1)) do
    if record.pitch == 64 then key = tonumber(id:match("^m(%d+)$")) end
  end
  assert_true(hook ~= nil and key ~= nil, "the targets hook and B's key")
  clear(device)
  hook.moved(1, 2, {owner = "midi", key = key, pitch = 65, velocity = 0.8})  -- the targets' end plus start
  assert_true(sent(device):match("note_on 65 %d+ 2$") ~= nil, "B on its new note: " .. sent(device))
  assert_equal(bends(device, 2), "7000", "B's first bend again")
  step(context, S, 3)
  assert_equal(bends(device, 2), "7000", "A sent nothing over it: " .. sent(device))
  lift(context, 3, 64); lift(context, 2, 60)
end)

test("a value of the older note that changes after the new note's start is sent at the next step", function()
  local context, S, device = one_member()
  press(context, 2, 60, 8704)  -- A
  press(context, 3, 64, 7000)  -- B
  step(context, S, 2)
  lift(context, 3, 64)
  press(context, 4, 67, 8533)  -- C, before any step
  clear(device)
  context.midi.send(1, {type = "pitchbend", val = 9100, ch = 2})  -- A's bend really changes
  step(context, S)
  assert_equal(bends(device, 2), "9100", "A's new value goes: " .. sent(device))
  clear(device)
  step(context, S, 3)
  assert_equal(sent(device), "", "once")
  lift(context, 4, 67); lift(context, 2, 60)
end)

test("a step note ending on a shared channel puts nothing back: it sent nothing there", function()
  local context, S, device = one_member()
  local target = midi_target(S)
  press(context, 2, 60, 9000)
  clear(device)
  target.note_on(1, "s1", 64, 1, step_info())
  assert_equal(sent(device), "note_on 64 127 2", "no bend on the shared channel")
  clear(device)
  target.note_off(1, "s1")
  step(context, S, 3)
  assert_equal(sent(device), "note_off 64 2", "its off, and no value put back")
  lift(context, 2, 60)
end)

test("the values put back on a shared channel keep to 24 messages a step", function()
  local context, S, device = one_member()
  local target = midi_target(S)
  local real_raw = S.lib.expression.raw
  S.lib.expression.raw = function(voice, owner, key)
    if voice == 1 and owner == "midi" and type(key) == "number" and key <= 15 then
      return {bend = 2 ^ (key / 120), pressure = key / 20, slide = key / 30}
    end
    return real_raw(voice, owner, key)
  end
  for key = 1, 15 do target.note_on(1, "m" .. key, 40 + key, 1, played_info(key)) end
  step(context, S)
  clear(device)
  target.note_off(1, "m15")
  clear(device)
  step(context, S)
  local first = #lines(device)
  assert_equal(first, 24, "the first step: 24 of the 14 notes' 42 values")
  clear(device)
  step(context, S)
  assert_equal(#lines(device), 18, "the next: the other 18")
  clear(device)
  step(context, S, 3)
  assert_equal(sent(device), "", "then nothing")
  for key = 1, 14 do target.note_off(1, "m" .. key) end
  S.lib.expression.raw = real_raw
end)

test("routes that the params hold at start are settled at start", function()
  -- with defaults: nothing sent, at start or after
  local device
  local context, S = load_strata({before_init = function(ctx) device = ctx.midi.plug(2, "mpe synth") end})
  S = local_value("S")
  assert_equal(midi_target(S).routed(1), false)
  assert_equal(sent(device), "", "defaults: nothing at start")
  finish_startup(context)
  assert_equal(sent(device), "", "defaults: nothing after startup")
  -- params that hold voice 1 on port 2 in mpe as the load adds them
  context = load_strata({before_init = function(ctx)
    device = ctx.midi.plug(2, "mpe synth")
    local real_add = params.add
    params.add = function(self, args)
      if args.id == "v1_out_port" then args.default = 2 end
      if args.id == "v1_out_mode" then args.default = MPE_INDEX end
      return real_add(self, args)
    end
  end})
  S = local_value("S")
  assert_equal(params:get("v1_out_port"), 2); assert_equal(params:string("v1_out_mode"), "mpe")
  assert_equal(midi_target(S).routed(1), true, "routed before any step, no route param touched")
  assert_equal(midi_target(S).rows(1)[1].text(), "port 2  mpe 15")
  assert_equal(sent(device), SETUP_15_48, "the zone's one setup")
  step(context, S, 3)
  assert_equal(sent(device), SETUP_15_48, "and only one")
end)

test("a played note is not sent to the port it arrived on", function()
  local context, S = started()
  local device3, device4 = context.midi.plug(3, "keys"), context.midi.plug(4, "synth")
  local target = midi_target(S)
  params:set("midi_device", 3)
  params:set("v1_out_port", 3); settled(context)
  clear(device3)
  target.note_on(1, "m188", 60, 1, played_info(188))
  assert_equal(sent(device3), "", "a played note: nothing back to its own port")
  target.note_off(1, "m188")
  assert_equal(sent(device3), "", "nor its off")
  target.note_on(1, "s1", 62, 1, step_info())
  assert_equal(sent(device3), "note_on 62 127 1", "a step note goes")
  target.note_off(1, "s1")
  params:set("v1_out_port", 4); settled(context)
  clear(device4)
  target.note_on(1, "m188", 60, 1, played_info(188))
  target.note_on(1, "s1", 62, 1, step_info())
  assert_equal(sent(device4), "note_on 60 127 1|note_on 62 127 1", "on another port both go")
end)

test("an MPE voice sets its zone up and takes it down", function()
  local context = started()
  local device = context.midi.plug(2, "mpe synth")
  params:set("v1_out_port", 2); settled(context)
  clear(device)
  params:set("v1_out_mode", MPE_INDEX); settled(context)
  assert_equal(sent(device), SETUP_15_48, "the zone's setup")
  clear(device)
  params:set("v1_out_members", 7); settled(context)
  assert_equal(sent(device), (SETUP_15_48:gsub("cc 6 15 1", "cc 6 7 1")), "a members change sends it again")
  clear(device)
  params:set("midi_out_bend_range", 24); settled(context)
  assert_equal(sent(device), (SETUP_15_48:gsub("cc 6 15 1", "cc 6 7 1"):gsub("cc 6 48 2", "cc 6 24 2")),
    "and a bend range change")
  clear(device)
  params:set("v1_out_mode", 1); settled(context)
  assert_equal(sent(device), TAKEDOWN, "plain: the zone taken down")
end)

test("an MPE voice's port change takes the old zone down and sets the new one up", function()
  local context = started()
  local device2, device3 = context.midi.plug(2, "a"), context.midi.plug(3, "b")
  mpe_voice(1, 2); settled(context)
  clear(device2); clear(device3)
  params:set("v1_out_port", 3); settled(context)
  assert_equal(sent(device2), TAKEDOWN, "the old port")
  assert_equal(sent(device3), SETUP_15_48, "the new port")
  clear(device3)
  params:set("v1_out_port", 0); settled(context)
  assert_equal(sent(device3), TAKEDOWN, "the port away")
end)

test("an MPE note sends its bend, pressure and slide, then its note on, on a member channel", function()
  local context, S = started()
  local device = context.midi.plug(2, "mpe synth")
  params:set("midi_channel_mode", 3)  -- mpe selected: voice 1
  mpe_voice(1, 2); settled(context)
  clear(device)
  -- real MPE input on port 1 (midi_device), member channel 2, range 48
  context.midi.send(1, {type = "pitchbend", val = 8533, ch = 2})
  context.midi.send(1, {type = "channel_pressure", val = 64, ch = 2})
  context.midi.send(1, {type = "cc", cc = 74, val = 32, ch = 2})
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 2})
  assert_equal(sent(device), "pitchbend 8533 2|channel_pressure 64 2|cc 74 32 2|note_on 60 100 2",
    "the first values, in order, then the note on")
  -- a played note with no pressure or slide yet: the bend and the note on only
  params:set("midi_channel_mode", 1)  -- per voice: channel 1 plays voice 1
  clear(device)
  context.midi.send(1, {type = "note_on", note = 62, vel = 100, ch = 1})
  local list = lines(device)
  assert_equal(#list, 2, sent(device))
  local channel = list[2]:match("^note_on 62 100 (%d+)$")
  assert_true(channel ~= nil, sent(device))
  assert_equal(list[1], "pitchbend 8192 " .. channel)
  -- a step note: a centered bend, then its note on
  clear(device)
  midi_target(S).note_on(1, "s1", 64, 1, step_info())
  list = lines(device)
  assert_equal(#list, 2, sent(device))
  channel = list[2]:match("^note_on 64 127 (%d+)$")
  assert_true(channel ~= nil, sent(device))
  assert_equal(list[1], "pitchbend 8192 " .. channel)
end)

test("member channels go to the one released longest ago, then the least used", function()
  local context, S = started()
  local device = context.midi.plug(2, "mpe synth")
  local target = midi_target(S)
  mpe_voice(1, 2, 3); settled(context)
  local function channel_of(id)
    clear(device)
    target.note_on(1, id, 60, 1, step_info())
    local list = lines(device)
    return tonumber(list[#list]:match("(%d+)$"))
  end
  assert_equal(channel_of("s1"), 2); assert_equal(channel_of("s2"), 3); assert_equal(channel_of("s3"), 4)
  target.note_off(1, "s2"); target.note_off(1, "s1")
  assert_equal(channel_of("s4"), 3, "3 was released first")
  assert_equal(channel_of("s5"), 2, "then 2")
  assert_equal(channel_of("s6"), 4, "none free: the fewest notes, the oldest such")
  for _, id in ipairs({"s3", "s4", "s5", "s6"}) do target.note_off(1, id) end
end)

test("MPE expression sends at most 24 a step, newest values, no note starved", function()
  local context, S = started()
  local device = context.midi.plug(2, "mpe synth")
  local target = midi_target(S)
  mpe_voice(1, 2); settled(context)
  local values = {}
  local real_raw = S.lib.expression.raw
  S.lib.expression.raw = function(voice, owner, key)
    if voice == 1 and owner == "midi" and values[key] then
      local v = values[key]
      return {bend = v.bend, pressure = v.pressure, slide = v.slide}
    end
    return real_raw(voice, owner, key)
  end
  local function set_values(n)
    for key = 1, 15 do
      values[key] = {bend = 2 ^ ((n * 0.5 + key * 0.01) / 12), pressure = (n + key) % 2 == 0 and 0.2 or 0.8,
        slide = (n + key) % 2 == 0 and 0.3 or 0.7}
    end
  end
  local function encoded(key)
    local v = values[key]
    return {bend = math.floor(8192 + 8192 * 12 * (math.log(v.bend) / math.log(2)) / 48 + 0.5),
      pressure = math.floor(v.pressure * 127 + 0.5), slide = math.floor(v.slide * 127 + 0.5)}
  end
  set_values(0)
  local channel_key = {}
  for key = 1, 15 do
    clear(device)
    target.note_on(1, "m" .. key, 60, 1, played_info(key))
    local list = lines(device)
    channel_key[tonumber(list[#list]:match("(%d+)$"))] = key
  end
  local last_sent = {}
  for n = 1, 10 do
    set_values(n)
    clear(device)
    step(context, S)
    local list = lines(device)
    assert_true(#list <= 24, "step " .. n .. " sent " .. #list)
    for _, text in ipairs(list) do
      local kind, a, b, c = text:match("^(%S+) (%d+) (%d+) ?(%d*)$")
      local channel, value, field
      if kind == "pitchbend" then channel, value, field = tonumber(b), tonumber(a), "bend"
      elseif kind == "channel_pressure" then channel, value, field = tonumber(b), tonumber(a), "pressure"
      elseif kind == "cc" then channel, value, field = tonumber(c), tonumber(b), "slide"
      end
      local key = channel_key[channel]
      assert_true(key ~= nil, "a message on a note's channel: " .. text)
      assert_equal(value, encoded(key)[field], "step " .. n .. ": the value current at the send, " .. text)
      last_sent[key] = n
    end
    if n >= 2 then
      for key = 1, 15 do
        assert_true(last_sent[key] ~= nil and last_sent[key] >= n - 1, "note " .. key .. " sent within two steps")
      end
    end
  end
  target.note_off(1, "m1")
  for _ = 1, 4 do
    set_values(20 + _)
    clear(device)
    step(context, S)
    for _, text in ipairs(lines(device)) do
      local channel = tonumber(text:match("(%d+)$"))
      assert_true(channel_key[channel] ~= 1, "an ended note sends nothing more: " .. text)
    end
  end
  for key = 2, 15 do target.note_off(1, "m" .. key) end
  S.lib.expression.raw = real_raw
end)

test("pressure and slide reach an MPE output though the voice maps neither", function()
  local context, S = started()
  local device = context.midi.plug(2, "mpe synth")
  params:set("midi_channel_mode", 3)
  params:set("v1_press_target", option("v1_press_target", "off"))
  params:set("v1_slide_target", option("v1_slide_target", "off"))
  mpe_voice(1, 2); settled(context)
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 2})
  step(context, S)
  clear(device)
  context.midi.send(1, {type = "channel_pressure", val = 90, ch = 2})
  context.midi.send(1, {type = "cc", cc = 74, val = 100, ch = 2})
  step(context, S)
  assert_equal(sent(device), "channel_pressure 90 2|cc 74 100 2")
end)

test("a value that changed twice within a step is sent once, at its newest", function()
  local context, S = started()
  local device = context.midi.plug(2, "mpe synth")
  params:set("midi_channel_mode", 3)
  mpe_voice(1, 2); settled(context)
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 2})
  step(context, S)
  clear(device)
  context.midi.send(1, {type = "channel_pressure", val = 40, ch = 2})
  context.midi.send(1, {type = "channel_pressure", val = 70, ch = 2})
  step(context, S)
  assert_equal(sent(device), "channel_pressure 70 2")
  clear(device)
  step(context, S, 3)
  assert_equal(sent(device), "", "nothing changed: nothing sent")
end)

test("a second MPE voice on a port, and a plain channel inside a zone, are refused", function()
  local context, S = started()
  context.midi.plug(2, "synth")
  mpe_voice(1, 2, 7); settled(context)  -- the zone: channels 1 to 8
  params:set("v2_out_channel", 12)
  params:set("v2_out_port", 2); settled(context)
  assert_equal(params:get("v2_out_port"), 2, "plain channel 12 is outside the zone")
  params:set("v2_out_mode", MPE_INDEX); settled(context)
  assert_equal(params:string("v2_out_mode"), "plain", "a second MPE voice on port 2 is refused")
  assert_equal(S.lib.ui_flash.text("header"), "port has an mpe voice")
  S.lib.ui_flash.start("header", nil)
  params:set("v3_out_channel", 5)
  params:set("v3_out_port", 2); settled(context)
  assert_equal(params:get("v3_out_port"), 0, "plain channel 5 inside the zone: back to its previous value")
  assert_equal(S.lib.ui_flash.text("header"), "port has an mpe voice")
  params:set("v3_out_channel", 12)
  params:set("v3_out_port", 2); settled(context)
  assert_equal(params:get("v3_out_port"), 2, "channel 12 is allowed")
  params:set("v3_out_channel", 8); settled(context)
  assert_equal(params:get("v3_out_channel"), 12, "a channel moved into the zone is refused")
  params:set("v1_out_members", 15); settled(context)
  assert_equal(params:get("v1_out_members"), 7, "members that would take in a plain channel are refused")
  params:set("v4_out_port", 2); settled(context)
  assert_equal(params:get("v4_out_port"), 0, "voice 4's plain channel 4 is inside")
end)

test("a CC slot sends its source when it changed", function()
  local context, S = started()
  local device = context.midi.plug(2, "synth")
  local lfo_value = 0
  S.lib.lfos.value = function(n) if n == 1 then return lfo_value end return 0 end
  params:set("cc_out1_port", 2); params:set("cc_out1_channel", 3); params:set("cc_out1_number", 20)
  step(context, S)
  assert_equal(sent(device), "", "source off: nothing")
  params:set("cc_out1_source", option("cc_out1_source", "lfo1"))
  step(context, S)
  assert_equal(sent(device), "cc 20 64 3", "lfo1 at fraction 0.5")
  clear(device)
  step(context, S)
  assert_equal(sent(device), "", "the same value: nothing")
  lfo_value = 1
  step(context, S)
  assert_equal(sent(device), "cc 20 127 3", "a new value")
  clear(device)
  params:set("cc_out1_source", option("cc_out1_source", "off"))
  lfo_value = -1
  step(context, S, 2)
  assert_equal(sent(device), "", "off again: nothing")
  -- kept by key
  params:set("cc_out1_source", option("cc_out1_source", "lfo1"))
  local before = params:get("cc_out1_source")
  local path = h.data_root .. "cc_out_source_by_key.pset"
  params:write(path)
  context = started({before_init = function()
    local script = local_value("S")
    script.register_mod_source({key = "a later source", name = "LATE", section = "later", range = {0, 1},
      value = function() return 0 end})
    local list = script.registry.mod_sources
    table.insert(list, 1, table.remove(list))  -- registered ahead of lfo1
  end})
  S = local_value("S")
  assert_equal(option("cc_out1_source", "lfo1"), before + 1, "lfo1's option moved")
  params:read(path)
  assert_equal(params:get("cc_out1_source_key"), "lfo1")
  device = context.midi.plug(2, "synth")
  S.lib.lfos.value = function(n) if n == 1 then return 1 end return 0 end
  step(context, S)
  assert_equal(sent(device), "cc 20 127 3", "still lfo1's value")
end)

test("a program change recalls a scene only when it is turned on", function()
  local context, S = started()
  params:set("scene_transition_time", 0)
  capture_scene(3); capture_scene(6)
  local asked = {}
  local real_recall = S.lib.io_actions.recall_scene
  S.lib.io_actions.recall_scene = function(n) asked[#asked + 1] = n; return real_recall(n) end
  context.midi.send(1, {type = "program_change", val = 2, ch = 1})
  assert_equal(#asked, 0, "midi_pc_in off: nothing")
  params:set("midi_pc_in", 1)
  params:set("quantize_actions", 2)  -- the scheduler waits for the beat
  context.midi.send(1, {type = "program_change", val = 2, ch = 1})
  assert_equal(table.concat(asked, " "), "3", "program 2 asks for scene 3")
  assert_true(S.lib.quantize.waiting("scene"), "through the scheduler")
  context.clock.run_for(1)
  assert_equal(S.current_scene, 3)
  params:set("quantize_actions", 1)
  asked = {}
  context.midi.send(1, {type = "program_change", val = 16, ch = 1})
  assert_equal(#asked, 0, "program 16: no scene")
  context.midi.send(1, {type = "program_change", val = 8, ch = 1})
  assert_equal(S.current_scene, 3, "an empty scene: nothing")
  params:set("midi_pc_channel", option("midi_pc_channel", "5"))
  asked = {}
  context.midi.send(1, {type = "program_change", val = 5, ch = 4})
  assert_equal(#asked, 0, "channel 4 is not 5")
  context.midi.send(1, {type = "program_change", val = 5, ch = 5})
  assert_equal(table.concat(asked, " "), "6", "channel 5's")
  assert_equal(S.current_scene, 6)
  params:set("midi_channel_mode", 3)
  params:set("midi_pc_channel", option("midi_pc_channel", "any"))
  context.midi.send(1, {type = "program_change", val = 2, ch = 2})
  assert_equal(S.current_scene, 3, "in an MPE mode the change still recalls")
end)

test("a scene recall sends its program change, and a program change in is not echoed on its own port", function()
  local context, S = started()
  local device = context.midi.plug(2, "keys")
  params:set("scene_transition_time", 0)
  capture_scene(5); capture_scene(6)
  recall_scene(5, 0)
  assert_equal(sent(device), "", "midi_pc_out off: nothing")
  params:set("midi_pc_out", 1); params:set("midi_pc_out_port", 2); params:set("midi_pc_out_channel", 1)
  recall_scene(5, 0)
  assert_equal(sent(device), "program_change 4 1")
  clear(device)
  params:set("midi_device", 2)
  params:set("midi_pc_in", 1)
  context.midi.send(2, {type = "program_change", val = 5, ch = 1})
  assert_equal(S.current_scene, 6, "the program change recalled scene 6")
  assert_equal(sent(device), "", "not echoed to the port it came from")
  recall_scene(6, 0)
  assert_equal(sent(device), "program_change 5 1", "the next recall from the norns sends again")
end)

test("a MIDI output that returns gets the offs of its notes", function()
  local context, S = started()
  context.midi.plug(3, "synth")
  local target = midi_target(S)
  mpe_voice(1, 3, 3)  -- members 2 to 4
  params:set("v2_out_channel", 5)
  params:set("v2_out_port", 3); settled(context)
  target.note_on(1, "s1", 60, 1, step_info())  -- member channel 2
  target.note_on(2, "s1", 64, 1, step_info())  -- channel 5
  context.midi.unplug(3)
  local device = context.midi.plug(3, "synth")
  assert_equal(sent(device), "note_off 60 2|note_off 64 5|" .. SETUP_15_48:gsub("cc 6 15 1", "cc 6 3 1"),
    "the offs of its notes on 2 and 5, then the MPE setup")
  target.note_off(1, "s1"); target.note_off(2, "s1")
  context.midi.unplug(3)
  device = context.midi.plug(3, "synth")
  assert_equal(sent(device), SETUP_15_48:gsub("cc 6 15 1", "cc 6 3 1"), "no notes when it left: the setup only")
end)

test("a synth moved to another port while its notes sound gets the offs of its notes there; the one taking its port gets nothing", function()
  -- SYSTEM > DEVICES moves a device with update_devices() only, told as the menu closes
  -- (lib/io/ports.lua's reconcile): every departure, then every arrival
  local context, S = started()
  local a = context.midi.plug(2, "synth a")
  local b = context.midi.plug(4, "synth b")
  local target = midi_target(S)
  params:set("v1_out_channel", 6)
  params:set("v1_out_port", 2); settled(context)
  target.note_on(1, "s1", 60, 1, step_info())
  assert_equal(sent(a), "note_on 60 127 6", "a plays the note")
  clear(a); clear(b)
  _menu.set_mode(true)
  context.midi.reassign(2, 3)  -- synth a to port 3
  context.midi.reassign(4, 2)  -- synth b to port 2
  _menu.set_mode(false)
  assert_equal(S.lib.io_ports.device(3), "synth a"); assert_equal(S.lib.io_ports.device(2), "synth b")
  assert_equal(sent(a), "note_off 60 6", "a gets its note's off at port 3")
  assert_equal(sent(b), "", "b, now on port 2, gets nothing")
  target.note_off(1, "s1")
  assert_equal(sent(b), "", "and no off for a note it never got")
  assert_equal(sent(a), "note_off 60 6", "nothing more for a")
end)

test("a synth moved while a note goes to its old port mid-menu still gets the offs of its notes", function()
  -- the re-review's probe: the vports change at the menu's K3, the move is told as it closes,
  -- and the patterns play meanwhile
  local context, S = started()
  local a = context.midi.plug(2, "synth a")
  local b = context.midi.plug(4, "synth b")
  local target = midi_target(S)
  params:set("v1_out_channel", 6)
  params:set("v1_out_port", 2); settled(context)
  target.note_on(1, "s1", 60, 1, step_info())
  clear(a); clear(b)
  _menu.set_mode(true)
  context.midi.reassign(2, 3)
  context.midi.reassign(4, 2)
  target.note_on(1, "s2", 64, 1, step_info())  -- a step to port 2 while the menu is open: synth b's now
  assert_equal(sent(b), "note_on 64 127 6", "b got the mid-menu note")
  _menu.set_mode(false)
  assert_equal(sent(a), "note_off 60 6", "a gets its note's off at port 3")
  assert_equal(sent(b), "note_on 64 127 6", "b gets no off for a's note")
  target.note_off(1, "s1")
  assert_equal(sent(b), "note_on 64 127 6", "and no off for a's note")
  target.note_off(1, "s2")
  assert_equal(sent(b), "note_on 64 127 6|note_off 64 6", "b's own note gets its off")
  assert_equal(sent(a), "note_off 60 6", "nothing more for a")
end)

-- Per note on a device: its ons less its offs (#709: 0 for a balanced device)
local function open_notes(device)
  local open = {}
  for _, entry in ipairs(lines(device)) do
    local kind, note, rest = entry:match("^(note_%a+) (%d+) (.*)$")
    if kind then
      local channel = rest:match("(%d+)$")
      local key = note .. " ch " .. channel
      open[key] = (open[key] or 0) + (kind == "note_on" and 1 or -1)
    end
  end
  return open
end

-- Synth a on port 2 holding note 60 on channel 6, the menu opened, a moved
-- to port 3 and, when b_takes_port, synth b (port 4) moved to port 2
local function a_moving(b_takes_port)
  local context, S = started()
  local a = context.midi.plug(2, "synth a")
  local b = context.midi.plug(4, "synth b")
  local target = midi_target(S)
  params:set("v1_out_channel", 6)
  params:set("v1_out_port", 2); settled(context)
  target.note_on(1, "s1", 60, 1, step_info())
  clear(a); clear(b)
  _menu.set_mode(true)
  context.midi.reassign(2, 3)
  if b_takes_port then context.midi.reassign(4, 2) end
  return context, S, target, a, b
end

test("a moved synth whose note ends while the menu is open gets the offs of its notes at its new port", function()
  local context, S, target, a, b = a_moving(false)
  target.note_off(1, "s1")  -- its off mid-menu: port 2 has no device now
  _menu.set_mode(false)
  assert_equal(sent(a), "note_off 60 6", "a gets its note's off at port 3")
  assert_equal(sent(b), "", "b, not moved, gets nothing")
end)

test("a moved synth's mid-menu off never reaches the device that took its port", function()
  local context, S, target, a, b = a_moving(true)
  target.note_off(1, "s1")
  assert_equal(sent(b), "", "b, now on port 2, gets no off for a's note")
  _menu.set_mode(false)
  assert_equal(sent(a), "note_off 60 6", "a gets its note's off at port 3")
  assert_equal(sent(b), "", "b gets nothing for a's note")
end)

test("a same-pitch note to the old port mid-menu, then a's note ending: b gets its own on and off, a the offs of its notes", function()
  local context, S, target, a, b = a_moving(true)
  target.note_on(1, "s2", 60, 1, step_info())  -- to port 2, synth b's now: no retrigger off for a's note
  target.note_off(1, "s1")                      -- a's note ends mid-menu
  target.note_off(1, "s2")
  _menu.set_mode(false)
  assert_equal(sent(b), "note_on 60 127 6|note_off 60 6", "b gets exactly the on and the off of its own note")
  assert_equal(sent(a), "note_off 60 6", "a gets its note's off at port 3")
  for key, count in pairs(open_notes(b)) do assert_equal(count, 0, "b's " .. key .. ": as many offs as ons (#709)") end
end)

-- Voice 1 on port 2 (synth a), channel 6, holding nothing; synth b on port
-- 4; the menu opened and a moved to port 3, so port 2 is empty
local function a_left_port_empty()
  local context, S = started()
  local a = context.midi.plug(2, "synth a")
  local b = context.midi.plug(4, "synth b")
  local target = midi_target(S)
  params:set("v1_out_channel", 6)
  params:set("v1_out_port", 2); settled(context)
  _menu.set_mode(true)
  context.midi.reassign(2, 3)
  return context, S, target, a, b
end

test("a note sent to the empty old port mid-menu gives no off to the device moved in after it", function()
  local context, S, target, a, b = a_left_port_empty()
  target.note_on(1, "s1", 64, 1, step_info())  -- port 2 has no device: it reaches no one
  context.midi.reassign(4, 2)                   -- synth b takes port 2
  target.note_off(1, "s1")
  assert_equal(sent(b), "", "b never had the note: no off at the off (#748)")
  _menu.set_mode(false)
  assert_equal(sent(a), "", "a never had it either: nothing owed")
  assert_equal(sent(b), "", "and nothing for b at the close")
end)

test("a note sent to the empty old port mid-menu, held until the menu closes, gives no off to the device moved in after it", function()
  local context, S, target, a, b = a_left_port_empty()
  target.note_on(1, "s1", 64, 1, step_info())
  context.midi.reassign(4, 2)
  _menu.set_mode(false)
  assert_equal(sent(a), "", "a never had the note: nothing owed at its arrival (#748)")
  assert_equal(sent(b), "", "nor anything for b at the close")
  target.note_off(1, "s1")
  assert_equal(sent(b), "", "and no off for a note b never had")
end)

test("a played MPE note's expression never reaches the device that took its port", function()
  local context, S = started()
  local a = context.midi.plug(2, "synth a")
  local b = context.midi.plug(4, "synth b")
  params:set("midi_channel_mode", 3)  -- mpe selected: voice 1
  mpe_voice(1, 2); settled(context)
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 2})  -- played: member channel 2 on a
  step(context, S)
  clear(a); clear(b)
  _menu.set_mode(true)
  context.midi.reassign(2, 3)  -- synth a to port 3
  context.midi.reassign(4, 2)  -- synth b to port 2
  clear(b)
  context.midi.send(1, {type = "pitchbend", val = 9000, ch = 2})  -- a new bend for the played note
  step(context, S)
  assert_equal(sent(b), "", "b, now on port 2, gets no expression of a's note (#749)")
  _menu.set_mode(false)
  assert_equal(sent(b), SETUP_15_48, "b gets the zone's setup at port 2")
  assert_equal(sent(a), "note_off 60 2", "a gets its owed note's off at port 3")
end)

-- Synth a on port 2 (voice 1's, channel 6) and synth b on port 4 holding
-- voice 2's note 62 on channel 6; the menu opened and b moved to port 2.
-- Nothing is cleared: b's history starts at its note 62
local function b_moving_onto_a()
  local context, S = started()
  local a = context.midi.plug(2, "synth a")
  local b = context.midi.plug(4, "synth b")
  local target = midi_target(S)
  params:set("v1_out_channel", 6)
  params:set("v1_out_port", 2)
  params:set("v2_out_channel", 6)
  params:set("v2_out_port", 4); settled(context)
  target.note_on(2, "s1", 62, 1, step_info())
  _menu.set_mode(true)
  context.midi.reassign(4, 2)  -- synth b to port 2; synth a on no port
  return context, S, target, a, b
end

test("in a swap, a note sent to the moved device at its new port is not cut by its arrival", function()
  local context, S, target, a, b = b_moving_onto_a()
  target.note_on(1, "s1", 60, 1, step_info())  -- to port 2: synth b's now
  _menu.set_mode(false)
  assert_equal(sent(b), "note_on 62 127 6|note_on 60 127 6|note_off 62 6",
    "b gets its owed note's own off at port 2, and no cut of note 60 (#750)")
  target.note_off(1, "s1")
  assert_equal(sent(b), "note_on 62 127 6|note_on 60 127 6|note_off 62 6|note_off 60 6", "note 60 ends with its own off")
  for key, count in pairs(open_notes(b)) do assert_equal(count, 0, "b's " .. key .. ": as many offs as ons (#709)") end
  target.note_off(2, "s1")
  assert_equal(sent(b), "note_on 62 127 6|note_on 60 127 6|note_off 62 6|note_off 60 6", "the paid note's end sends nothing")
  assert_equal(sent(a), "", "a, on no port, gets nothing")
end)

test("in a swap, a note sent to the moved device at its new port is not cut by its arrival, its old note ended mid-menu", function()
  local context, S, target, a, b = b_moving_onto_a()
  target.note_on(1, "s1", 60, 1, step_info())
  target.note_off(2, "s1")  -- b's note 62 ends while b is away from port 4: owed
  _menu.set_mode(false)
  assert_equal(sent(b), "note_on 62 127 6|note_on 60 127 6|note_off 62 6",
    "b gets the off of a note that ended mid-menu, and no cut of note 60 (#750)")
  target.note_off(1, "s1")
  assert_equal(sent(b), "note_on 62 127 6|note_on 60 127 6|note_off 62 6|note_off 60 6", "note 60 ends with its own off")
  for key, count in pairs(open_notes(b)) do assert_equal(count, 0, "b's " .. key .. ": as many offs as ons (#709)") end
  assert_equal(sent(a), "", "a, on no port, gets nothing")
end)

test("an owed note that sounds again at the arrival port still gets its off", function()
  local context, S, target, a, b = b_moving_onto_a()
  target.note_on(1, "s1", 62, 1, step_info())  -- the owed pitch, on the owed channel, at b's new port
  _menu.set_mode(false)
  assert_equal(sent(b), "note_on 62 127 6|note_on 62 127 6|note_off 62 6",
    "two ons of 62 at b: the owed one's off goes, whatever sounds now (#709)")
  target.note_off(1, "s1")
  assert_equal(sent(b), "note_on 62 127 6|note_on 62 127 6|note_off 62 6|note_off 62 6", "the new note's own off")
  for key, count in pairs(open_notes(b)) do assert_equal(count, 0, "b's " .. key .. ": as many offs as ons (#709)") end
end)

test("a synth moved away and back in one visit gets its owed off at the close", function()
  local context, S, target, a, b = a_moving(false)  -- a on port 3, port 2 empty
  target.note_off(1, "s1")       -- its off mid-menu: owed to a
  context.midi.reassign(3, 2)    -- a back on port 2: the visit moves nothing in the end
  _menu.set_mode(false)
  assert_equal(sent(a), "note_off 60 6", "a gets its owed note's off as the menu closes (#747)")
  assert_equal(sent(b), "", "b, not moved, gets nothing")
  context.midi.unplug(2)
  local again = context.midi.plug(2, "synth a")
  assert_equal(sent(again), "", "nothing owed is left: a replug sends nothing")
end)

-- #767: a note started on a port a remote or midigrid holds was never sent,
-- so it owes no off when its device leaves (a move or an unplug)

-- A stand-in for the midigrid mod's object (test/unit/io_remote_test.lua's)
local function midigrid_object()
  local object = { cols = 16, rows = 8, device = { id = 999, name = "midigrid" }, leds = {}, refreshes = 0 }
  function object:led(x, y, level) self.leds[x .. "," .. y] = level end
  function object:all() self.leds = {} end
  function object:refresh() self.refreshes = self.refreshes + 1 end
  return object
end

-- A Launchpad on port 1 under midigrid, voice 2's notes routed to port 1
-- and one step note started there; run(context, S, target, launchpad)
-- then runs with grid.connect and midi.add restored after it, whatever it raises
local function under_midigrid(run)
  local context, S = started()
  local launchpad = context.midi.plug(1, "Launchpad X")
  local real_connect, real_add = grid.connect, midi.add
  grid.connect = function(...)
    if select("#", ...) > 0 then return real_connect(...) end
    launchpad.event = function() end  -- what midigrid does to the device it takes
    return midigrid_object()
  end
  -- a Launchpad plugged again gets midigrid's handler as it is added
  midi.add = function(device)
    if device.name == "Launchpad X" then device.event = function() end end
    return real_add(device)
  end
  local ok, problem = pcall(function()
    assert_true(S.lib.io_rig.set("midi_grid", "on"), "midi grid on")
    assert_true(S.lib.io_remote.holds(1), "midigrid holds port 1")
    local target = midi_target(S)
    params:set("v2_out_port", 1); settled(context)
    target.note_on(2, "s1", 60, 1, step_info())
    assert_equal(sent(launchpad), "", "the held port's note reaches nothing")
    run(context, S, target, launchpad)
  end)
  grid.connect, midi.add = real_connect, real_add
  if not ok then error(problem, 0) end
end

local function no_notes(device, why)
  for _, entry in ipairs(lines(device)) do
    assert_true(not entry:find("^note_"), why .. ": " .. entry)
  end
  for key, count in pairs(open_notes(device)) do assert_equal(count, 0, why .. ", " .. key .. " (#709)") end
end

test("a note on a port midigrid holds owes its device no off when SYSTEM > DEVICES moves it (#767)", function()
  under_midigrid(function(context, S, target, launchpad)
    _menu.set_mode(true)
    context.midi.reassign(1, 4)
    _menu.set_mode(false)
    assert_equal(S.lib.io_ports.owner(4), "midigrid", "claimed at port 4")
    no_notes(launchpad, "the moved Launchpad gets no note")
    target.note_off(2, "s1")
    no_notes(launchpad, "nor at the note's end")
  end)
end)

test("a note on a port midigrid holds owes its device no off when it is plugged in again (#767)", function()
  under_midigrid(function(context, S, target, launchpad)
    context.midi.unplug(1)
    local again = context.midi.plug(4, "Launchpad X")
    no_notes(again, "the Launchpad plugged in at port 4 gets no note")
    context.midi.unplug(4)
    again = context.midi.plug(1, "Launchpad X")
    no_notes(again, "nor plugged in again at port 1")
    target.note_off(2, "s1")
    no_notes(again, "nor at the note's end")
    no_notes(launchpad, "the first device object got none")
  end)
end)

test("a note on a port a remote grid holds owes its device no off when it is plugged in again (#767)", function()
  local context, S = started()
  assert_true(S.lib.io_rig.set("remote_grid_port", 3), "remote grid on port 3")
  context.midi.plug(3, "iii grid")
  for cc, value in pairs({ [0] = 16, [1] = 8, [2] = 1 }) do
    context.midi.send(3, { type = "cc", cc = cc, val = value, ch = 1 })
  end
  context.clock.run_for(0.2)
  assert_true(S.lib.io_remote.holds(3), "the remote holds port 3")
  local target = midi_target(S)
  params:set("v1_out_port", 3); settled(context)
  target.note_on(1, "s1", 60, 1, step_info())  -- channel 1: an LED message, were it sent
  context.midi.unplug(3)
  local again = context.midi.plug(3, "iii grid")
  for _, entry in ipairs(lines(again)) do
    assert_true(entry ~= "note_off 60 1", "no off for a note the grid never got: " .. entry)
  end
end)

-- #769: a note started on a port a remote holds sends nothing, ever, even
-- once the remote lets the port go; a note sounding on a port a remote
-- then claims gets its off before the claim, and nothing after. No hello
-- is answered, so the remote grid sends its device only its ask (CC 2)

local ASK_HELLO = "cc 2 0 1"

local function remote_grid_at(S, port)
  assert_true(S.lib.io_rig.set("remote_grid_port", port), "remote grid on port " .. port)
  assert_equal(S.lib.io_remote.holds(port), port > 0, "the remote holds the port exactly while set")
end

local function balanced(device, why)
  for key, count in pairs(open_notes(device)) do assert_equal(count, 0, why .. ", " .. key .. " (#709)") end
end

-- midigrid's stand-in attached and taking launchpad's port while run(),
-- with grid.connect put back after it, whatever it raises
local function with_midigrid(S, launchpad, run)
  local real_connect = grid.connect
  grid.connect = function(...)
    if select("#", ...) > 0 then return real_connect(...) end
    launchpad.event = function() end  -- what midigrid does to the device it takes
    return midigrid_object()
  end
  local ok, problem = pcall(function()
    assert_true(S.lib.io_rig.set("midi_grid", "on"), "midi grid on")
    run()
  end)
  grid.connect = real_connect
  if not ok then error(problem, 0) end
end

test("a note started on a port midigrid holds sends nothing when midigrid lets the port go and the note ends (#769)", function()
  under_midigrid(function(context, S, target, launchpad)
    assert_true(S.lib.io_rig.set("midi_grid", "off"), "midi grid off")
    assert_true(not S.lib.io_remote.holds(1), "the port is let go")
    target.note_off(2, "s1")
    assert_equal(sent(launchpad), "", "the Launchpad never got the note, so gets no off")
  end)
end)

test("a note started on a port a remote grid holds sends nothing when the remote lets the port go and the note ends (#769)", function()
  local context, S = started()
  local device = context.midi.plug(3, "iii grid")
  remote_grid_at(S, 3)
  local target = midi_target(S)
  params:set("v1_out_port", 3); settled(context)
  clear(device)
  target.note_on(1, "s1", 60, 1, step_info())
  remote_grid_at(S, 0)
  target.note_off(1, "s1")
  assert_equal(sent(device), "", "the device never got the note, so gets no off")
end)

test("a held port's played notes, let go, send nothing at a voice's stop or a mute (#769)", function()
  for _, ending in ipairs({"stop", "mute"}) do
    local context, S = started()
    local device = context.midi.plug(3, "iii grid")
    remote_grid_at(S, 3)
    params:set("v1_out_port", 3); settled(context)
    clear(device)
    for _, note in ipairs({60, 64, 67}) do context.midi.send(1, {type = "note_on", note = note, vel = 90, ch = 1}) end
    remote_grid_at(S, 0)
    if ending == "stop" then toggle_voice(1) else params:set("v1_mute", 1) end
    step(context, S)
    assert_equal(sent(device), "", "a " .. ending .. " sends no off for notes the device never got")
  end
end)

test("a note sounding on a port a remote grid then claims gets its off before the claim, and nothing after (#769)", function()
  local context, S = started()
  local device = context.midi.plug(3, "iii grid")
  local target = midi_target(S)
  params:set("v1_out_port", 3); settled(context)
  target.note_on(1, "s1", 60, 1, step_info())
  target.note_on(1, "s2", 64, 1, step_info())
  assert_equal(sent(device), "note_on 60 127 1|note_on 64 127 1")
  clear(device)
  remote_grid_at(S, 3)
  assert_equal(sent(device), "note_off 60 1|note_off 64 1|" .. ASK_HELLO, "the offs go before the remote's ask")
  clear(device)
  target.note_off(1, "s1")
  assert_equal(sent(device), "", "a note's end while the remote holds the port sends nothing")
  remote_grid_at(S, 0)
  target.note_off(1, "s2")
  assert_equal(sent(device), "", "nor once the port is let go")
end)

test("a note sounding on a port midigrid then claims gets its off before the claim, and nothing after (#769)", function()
  local context, S = started()
  local launchpad = context.midi.plug(1, "Launchpad X")
  local target = midi_target(S)
  params:set("v2_out_port", 1); settled(context)
  target.note_on(2, "s1", 60, 1, step_info())
  with_midigrid(S, launchpad, function()
    assert_true(S.lib.io_remote.holds(1), "midigrid holds port 1")
    assert_equal(sent(launchpad), "note_on 60 127 2|note_off 60 2", "the off goes as midigrid takes the port")
    target.note_off(2, "s1")
    assert_true(S.lib.io_rig.set("midi_grid", "off"), "midi grid off")
    target.note_on(2, "s2", 62, 1, step_info())
    target.note_off(2, "s2")
  end)
  assert_equal(sent(launchpad), "note_on 60 127 2|note_off 60 2|note_on 62 127 2|note_off 62 2",
    "nothing more for the first note; the port let go plays again")
  balanced(launchpad, "the Launchpad")
end)

test("a played MPE note on a held port sends nothing, let go, at a new value or its end (#769)", function()
  local context, S = started()
  local device = context.midi.plug(3, "iii grid")
  params:set("midi_channel_mode", 3)  -- mpe selected: voice 1
  mpe_voice(1, 3); settled(context)
  remote_grid_at(S, 3)
  clear(device)
  context.midi.send(1, {type = "pitchbend", val = 8533, ch = 2})
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 2})
  step(context, S)
  remote_grid_at(S, 0)
  context.midi.send(1, {type = "pitchbend", val = 9000, ch = 2})
  step(context, S)
  context.midi.send(1, {type = "note_off", note = 60, vel = 0, ch = 2})
  step(context, S)
  assert_equal(sent(device), SETUP_15_48, "the device never got the note: no value, no off; the port let go gets its zone's setup (#772)")
end)

test("a played MPE note sounding on a port a remote grid claims gets its member channel's off, then nothing (#769)", function()
  local context, S = started()
  local device = context.midi.plug(3, "iii grid")
  params:set("midi_channel_mode", 3)  -- mpe selected: voice 1
  mpe_voice(1, 3); settled(context)
  context.midi.send(1, {type = "pitchbend", val = 8533, ch = 2})
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 2})
  step(context, S)
  local list = lines(device)
  local channel = list[#list]:match("^note_on 60 100 (%d+)$")
  assert_true(channel ~= nil, sent(device))
  clear(device)
  remote_grid_at(S, 3)
  assert_equal(sent(device), "note_off 60 " .. channel .. "|" .. ASK_HELLO, "the member channel's off, then the ask")
  clear(device)
  context.midi.send(1, {type = "pitchbend", val = 9000, ch = 2})
  step(context, S)
  remote_grid_at(S, 0)
  context.midi.send(1, {type = "pitchbend", val = 9500, ch = 2})
  step(context, S)
  context.midi.send(1, {type = "note_off", note = 60, vel = 0, ch = 2})
  step(context, S)
  assert_equal(sent(device), SETUP_15_48, "no later value and no second off, held or let go; the port let go gets its zone's setup (#772)")
end)

-- #772: an MPE zone's setup goes once a port settles (S.lib.io_ports'
-- on_settled, after every change and claim hook) with its device not held:
-- a device a remote takes as it arrives gets none, and a port a remote
-- grid, a remote arc or midigrid lets go gets it before its first note

test("an MPE zone's setup waits while a remote grid takes its arriving device (#772)", function()
  local context, S = started()
  mpe_voice(1, 3); settled(context)
  remote_grid_at(S, 0)
  assert_true(S.lib.io_rig.set("remote_grid_port", 3), "the rig's grid port 3, with no device there")
  local device = context.midi.plug(3, "iii grid")
  assert_equal(sent(device), ASK_HELLO, "the remote's ask alone: no RPN (cc 101, 100, 6) reaches it")
  assert_true(S.lib.io_remote.holds(3), "the remote holds the port")
end)

test("a port a remote grid lets go gets its zone setup before its first MPE note (#772)", function()
  local context, S = started()
  local device = context.midi.plug(3, "iii grid")
  remote_grid_at(S, 3)
  for cc, value in pairs({ [0] = 16, [1] = 8, [2] = 1 }) do
    context.midi.send(3, { type = "cc", cc = cc, val = value, ch = 1 })
  end
  context.clock.run_for(0.2)
  clear(device)
  mpe_voice(1, 3); settled(context)
  for _, entry in ipairs(lines(device)) do
    assert_true(not entry:find("^cc 10[01] ") and not entry:find("^cc 6 "), "the route settled while held sends no RPN: " .. entry)
  end
  clear(device)
  remote_grid_at(S, 0)
  assert_equal(sent(device), "cc 4 0 1|" .. SETUP_15_48, "the remote's own clear, then the zone's one setup")
  clear(device)
  midi_target(S).note_on(1, "p1", 60, 1, played_info("k1"))
  assert_equal(sent(device), "pitchbend 8192 2|note_on 60 127 2", "the first note follows its setup")
end)

test("a port midigrid lets go gets its zone setup (#772)", function()
  local context, S = started()
  local launchpad = context.midi.plug(1, "Launchpad X")
  with_midigrid(S, launchpad, function()
    assert_true(S.lib.io_remote.holds(1), "midigrid holds port 1")
    mpe_voice(2, 1); settled(context)
    assert_equal(sent(launchpad), "", "the route settled while held sends nothing")
    assert_true(S.lib.io_rig.set("midi_grid", "off"), "midi grid off")
    assert_true(not S.lib.io_remote.holds(1), "the port is let go")
    assert_equal(sent(launchpad), SETUP_15_48, "the zone's one setup")
  end)
end)

test("a release the remote arc takes straight back sends no setup (#772)", function()
  local context, S = started()
  local device = context.midi.plug(3, "iii grid")
  remote_grid_at(S, 3)
  assert_true(S.lib.io_rig.set("remote_arc_port", 3), "the arc named on port 3 too")
  assert_equal(S.lib.io_remote.status("arc"), "in use", "the arc waits")
  mpe_voice(1, 3); settled(context)
  clear(device)
  remote_grid_at(S, 0)
  assert_equal(S.lib.io_ports.owner(3), "remote arc", "the arc claims inside the grid's release")
  assert_equal(sent(device), ASK_HELLO, "the arc's ask alone: no RPN")
  assert_true(S.lib.io_rig.set("remote_arc_port", 0), "the arc lets go")
  assert_equal(sent(device), ASK_HELLO .. "|" .. SETUP_15_48, "then the setup, once")
end)

test("a device that arrives on a port the rig still names for a remote is the remote's: it gets the ask alone, and the zone's setup once the rig lets the port go (#772)", function()
  local context, S = started()
  context.midi.plug(3, "iii grid")
  remote_grid_at(S, 3)
  mpe_voice(1, 3); settled(context)
  context.midi.unplug(3)
  local synth = context.midi.plug(3, "synth")
  assert_equal(sent(synth), ASK_HELLO, "the remote's ask alone: no RPN (cc 101, 100, 6)")
  assert_true(S.lib.io_remote.holds(3), "the remote holds the synth's port")
  clear(synth)
  remote_grid_at(S, 0)
  assert_equal(sent(synth), SETUP_15_48, "the zone's one setup as the rig lets the port go")
  clear(synth)
  midi_target(S).note_on(1, "p1", 60, 1, played_info("k1"))
  assert_equal(sent(synth), "pitchbend 8192 2|note_on 60 127 2", "the first note follows its setup")
end)

test("a synth moved in the menu onto the port the rig names for a remote gets the ask alone (#772)", function()
  local context, S = started()
  context.midi.plug(3, "iii grid")
  remote_grid_at(S, 3)
  mpe_voice(1, 3); settled(context)
  local synth = context.midi.plug(5, "synth")
  clear(synth)
  _menu.set_mode(true)
  context.midi.reassign(5, 3)  -- the synth takes port 3; the iii grid is left on no port
  _menu.set_mode(false)
  assert_equal(sent(synth), ASK_HELLO, "the remote's ask alone: no RPN (cc 101, 100, 6) before the remote claims it")
  assert_equal(S.lib.io_ports.owner(3), "remote grid", "the remote holds the synth's port")
end)

-- #788: a zone taken down while a remote or midigrid holds its port owes
-- its device the takedown (state.takedown_due), sent once the port settles
-- free with that device there

-- A synth on port 3 with voice 1's zone set up there, then a remote grid
-- named on port 3, holding it: the synth has had the setup, then the ask
local function zone_then_held(context, S)
  local synth = context.midi.plug(3, "synth")
  mpe_voice(1, 3); settled(context)
  assert_equal(sent(synth), SETUP_15_48, "the zone set up on the free port")
  clear(synth)
  remote_grid_at(S, 3)
  assert_equal(sent(synth), ASK_HELLO, "the remote's ask")
  clear(synth)
  return synth
end

test("a zone taken down while a remote grid holds its port is taken down when the port is let go (#788)", function()
  local context, S = started()
  local synth = zone_then_held(context, S)
  params:set("v1_out_mode", 1); settled(context)
  assert_equal(sent(synth), "", "the held port is sent nothing")
  remote_grid_at(S, 0)
  assert_equal(sent(synth), TAKEDOWN, "the takedown once, and no setup, as the rig lets the port go")
  clear(synth)
  settled(context)
  assert_equal(sent(synth), "", "nothing more")
end)

test("a zone that returns before the port is let go gets its setup alone (#788)", function()
  local context, S = started()
  local synth = zone_then_held(context, S)
  params:set("v1_out_mode", 1); settled(context)
  params:set("v1_out_mode", MPE_INDEX); settled(context)
  assert_equal(sent(synth), "", "the held port is sent nothing")
  remote_grid_at(S, 0)
  assert_equal(sent(synth), SETUP_15_48, "the setup once, standing for the takedown")
end)

test("a takedown owed to a device that leaves is forgotten (#788)", function()
  local context, S = started()
  zone_then_held(context, S)
  params:set("v1_out_mode", 1); settled(context)
  context.midi.unplug(3)
  local other = context.midi.plug(3, "synth b")
  assert_equal(sent(other), ASK_HELLO, "the remote takes the new device: its ask alone")
  clear(other)
  remote_grid_at(S, 0)
  assert_equal(sent(other), "", "no takedown reaches the device that came after")
end)

-- A menu close tells the departure and the arrival together, so the port
-- settles held by the remote that takes the new device: only the
-- departure itself can forget the takedown
test("a takedown owed to a device that SYSTEM > DEVICES moves off its port is forgotten (#788)", function()
  local context, S = started()
  zone_then_held(context, S)
  params:set("v1_out_mode", 1); settled(context)
  local other = context.midi.plug(5, "synth b")
  _menu.set_mode(true)
  context.midi.reassign(5, 3)  -- synth b takes port 3; the zone's synth is left on no port
  _menu.set_mode(false)
  assert_equal(S.lib.io_ports.owner(3), "remote grid", "the remote takes synth b")
  clear(other)
  remote_grid_at(S, 0)
  assert_equal(sent(other), "", "no takedown reaches the device that came after")
end)

test("a voice moved to another port while its old port is held leaves the takedown owed there (#788)", function()
  local context, S = started()
  local synth = zone_then_held(context, S)
  local other = context.midi.plug(5, "synth b")
  clear(other)
  params:set("v1_out_port", 5); settled(context)
  assert_equal(sent(other), SETUP_15_48, "the free port's setup at once")
  assert_equal(sent(synth), "", "the held port is sent nothing")
  remote_grid_at(S, 0)
  assert_equal(sent(synth), TAKEDOWN, "the old port's takedown at its release")
  assert_equal(sent(other), SETUP_15_48, "nothing more on the new port")
end)

-- Cleanup sends no zone message on a free port (the device keeps its zone),
-- and a held port does no worse: the release in the remote's cleanup step
-- comes after MIDI out's stop
test("cleanup sends no takedown, owed or not (#788)", function()
  local context, S = started()
  local synth = zone_then_held(context, S)
  params:set("v1_out_mode", 1); settled(context)
  local free = context.midi.plug(5, "synth b")
  mpe_voice(2, 5); settled(context)
  clear(free)
  cleanup()
  assert_equal(sent(synth), "", "the held port's owed takedown is not sent")
  assert_equal(sent(free), "", "nor is a free port's zone taken down")
end)

test("a zone taken down while midigrid holds its port is taken down when midigrid lets it go (#788)", function()
  local context, S = started()
  local launchpad = context.midi.plug(1, "Launchpad X")
  mpe_voice(2, 1); settled(context)
  assert_equal(sent(launchpad), SETUP_15_48, "the zone set up on the free port")
  clear(launchpad)
  with_midigrid(S, launchpad, function()
    assert_true(S.lib.io_remote.holds(1), "midigrid holds port 1")
    params:set("v2_out_mode", 1); settled(context)
    assert_equal(sent(launchpad), "", "the held port is sent nothing")
    assert_true(S.lib.io_rig.set("midi_grid", "off"), "midi grid off")
    assert_equal(sent(launchpad), TAKEDOWN, "the takedown once, and no setup")
  end)
end)

test("a zone taken down while a remote arc holds its port is taken down when the arc lets it go (#788)", function()
  local context, S = started()
  local synth = context.midi.plug(3, "synth")
  mpe_voice(1, 3); settled(context)
  clear(synth)
  assert_true(S.lib.io_rig.set("remote_arc_port", 3), "the arc on port 3")
  assert_true(S.lib.io_remote.holds(3), "the arc holds port 3")
  clear(synth)
  params:set("v1_out_mode", 1); settled(context)
  assert_equal(sent(synth), "", "the held port is sent nothing")
  assert_true(S.lib.io_rig.set("remote_arc_port", 0), "the arc lets go")
  assert_equal(sent(synth), TAKEDOWN, "the takedown once, and no setup")
end)

test("a route change, a voice stop and cleanup leave as many offs as ons on every channel", function()
  local context, S = started()
  local device = context.midi.plug(2, "synth")
  local function balanced(why)
    local open = {}
    for _, text in ipairs(lines(device)) do
      local kind, note, channel = text:match("^(note_%a+) (%d+) .-(%d+)$")
      if kind then
        local slot = channel .. " " .. note
        open[slot] = (open[slot] or 0) + (kind == "note_on" and 1 or -1)
      end
    end
    for slot, count in pairs(open) do assert_equal(count, 0, why .. ": channel and note " .. slot) end
  end
  local function play_some()
    for _, note in ipairs({60, 64, 67}) do context.midi.send(1, {type = "note_on", note = note, vel = 90, ch = 1}) end
  end
  params:set("v1_out_port", 2); settled(context)
  play_some()
  assert_true(#lines(device) >= 3, "the notes went: " .. sent(device))
  params:set("v1_out_channel", 9); settled(context)
  balanced("a route change")
  clear(device)
  play_some()
  toggle_voice(1)
  balanced("a voice stop")
  clear(device)
  mpe_voice(1, 2); settled(context)
  clear(device)
  play_some()
  S.patterns[1][1] = 15
  pattern_clock_start()
  context.clock.run_for(0.01)
  cleanup()
  balanced("cleanup")
end)

test("IO shows a voice's route and the midi section", function()
  local context, S = started()
  local target = midi_target(S)
  local rows = target.rows(1)
  assert_equal(#rows, 1); assert_equal(rows[1].kind, "detail"); assert_equal(rows[1].label, "midi")
  assert_equal(rows[1].text(), "off")
  local fields = {}
  for _, field in ipairs(rows[1].fields) do fields[#fields + 1] = field.param_id end
  assert_equal(table.concat(fields, " "), "v1_out_port v1_out_channel v1_out_mode v1_out_members")
  params:set("v1_out_port", 2); params:set("v1_out_channel", 3); settled(context)
  assert_equal(target.rows(1)[1].text(), "port 2  ch 3")
  params:set("v1_out_mode", MPE_INDEX); settled(context)
  assert_equal(target.rows(1)[1].text(), "port 2  mpe 15")
  local midi = section(S, "midi")
  assert_equal(midi.status(), "[--]", "a port in use has no device")
  context.midi.plug(2, "synth")
  assert_equal(midi.status(), nil)
  local labels = {}
  for _, row in ipairs(midi.rows()) do labels[#labels + 1] = row.label end
  assert_equal(table.concat(labels, ","),
    "bend range,cc 1,cc 2,cc 3,cc 4,cc 5,cc 6,cc 7,cc 8,pc in,pc channel,pc out,pc out port,pc out channel")
  assert_true(S.lib.pages_io.show_section("midi"))
end)

test("the voice section's midi detail list open is a layout state, reached through the page", function()
  local context, S = started()
  local state
  for _, entry in ipairs(S.registry.pages[S.constants.UI_PAGES.index.IO].layout_states) do
    if entry.name == "voice: midi detail list open" then state = entry end
  end
  assert_true(state ~= nil, "the state is listed with the voice section's")
  h.show_page("IO")
  state.setup(context); redraw()
  for _, field in ipairs({"port", "channel", "mode", "members"}) do
    assert_true(h.screen_shows(context, field), "the detail list shows " .. field)
  end
  assert_true(h.screen_shows(context, "2"), "the voice's port")
  h.assert_screen_layout(context, "voice: midi detail list open")
end)

test("no MIDI out param is in a scene, a macro's targets or a randomize", function()
  local _, S = started()
  local ids = midi_out_ids(S)
  local ours = {}
  for _, id in ipairs(ids) do ours[id] = true end
  for _, id in ipairs(S.lib.macros.target_ids()) do assert_true(not ours[id], id .. " is a macro target") end
  capture_scene(1)
  local function walk(value, path)
    if type(value) ~= "table" then return end
    for key, inner in pairs(value) do
      assert_true(not (type(key) == "string" and (ours[key] or key:match("_out_") or key:match("^cc_out")
        or key:match("^midi_pc"))), "a scene holds " .. path .. "." .. tostring(key))
      walk(inner, path .. "." .. tostring(key))
    end
  end
  walk(S.scenes[1], "scene 1")
  local before = {}
  for _, id in ipairs(ids) do before[id] = params:get(id) end
  for voice = 1, S.constants.NUM_VOICES do randomize_voice(voice) end
  gentle_mutate()
  for _, id in ipairs(ids) do assert_equal(params:get(id), before[id], id .. " unchanged") end
end)

test("cleanup drops the express queue and nothing is sent after it", function()
  local context, S = started()
  local device = context.midi.plug(2, "synth")
  params:set("midi_channel_mode", 3)
  mpe_voice(1, 2)
  params:set("cc_out1_port", 2)
  params:set("cc_out1_source", option("cc_out1_source", "lfo1"))
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 2})
  cleanup()
  clear(device)
  context.midi.send(1, {type = "channel_pressure", val = 90, ch = 2})
  context.clock.run_for(0.2)
  context.midi.unplug(2)
  device = context.midi.plug(2, "synth")
  capture_scene(2); params:set("midi_pc_out", 1); recall_scene(2, 0)
  assert_equal(sent(device), "", "after cleanup nothing")
end)

---------------------------------------------------------------------------
-- Review fixes (findings 1, 2, 5, 6)
---------------------------------------------------------------------------

-- A recording target routed for voice 1, beside midi
local function probe_target(S)
  local probe = {ons = 0, offs = 0}
  S.register_note_target({name = "probe", routed = function(voice) return voice == 1 end,
    note_on = function() probe.ons = probe.ons + 1 end, note_off = function() probe.offs = probe.offs + 1 end})
  return probe
end

-- Per port, channel and note: ons minus offs among devices' sent messages
local function assert_balanced(devices, why)
  for port, device in pairs(devices) do
    local open = {}
    for _, text in ipairs(lines(device)) do
      local kind, note, channel = text:match("^(note_%a+) (%d+) .-(%d+)$")
      if kind then
        local slot = channel .. " " .. note
        open[slot] = (open[slot] or 0) + (kind == "note_on" and 1 or -1)
      end
    end
    for slot, count in pairs(open) do assert_equal(count, 0, why .. ": port " .. port .. " channel and note " .. slot) end
  end
end

local function route_of(voice)
  local id = function(field) return "v" .. voice .. "_out_" .. field end
  return params:get(id("port")) .. " " .. params:get(id("channel")) .. " " .. params:string(id("mode")) .. " "
    .. params:get(id("members"))
end

local REFUSED = "port has an mpe voice"

-- The file's route lines (v<i>_out_...) in the opposite order, each other line where it was
local function reverse_route_lines(path)
  local file = io.open(path, "r")
  local text = file:read("*a")
  file:close()
  local all, routes, slots = {}, {}, {}
  for line in text:gmatch("[^\n]+") do
    all[#all + 1] = line
    if line:match('^"v%d_out_') then routes[#routes + 1] = line; slots[#slots + 1] = #all end
  end
  for index, slot in ipairs(slots) do all[slot] = routes[#routes - index + 1] end
  file = io.open(path, "w")
  file:write(table.concat(all, "\n") .. "\n")
  file:close()
end

local function edit_file(path, fn)
  local file = io.open(path, "r")
  local text = file:read("*a")
  file:close()
  file = io.open(path, "w")
  file:write(fn(text))
  file:close()
end

test("a route change ends the voice's notes only when the route changes", function()
  local context, S = started()
  local device = context.midi.plug(2, "synth")
  local probe = probe_target(S)
  local function play(note) context.midi.send(1, {type = "note_on", note = note, vel = 100, ch = 1}) end
  local function set(id, value) params:set(id, value); step(context, S) end
  play(60)
  assert_equal(probe.ons, 1, "the probe plays voice 1's note")
  set("v1_out_channel", 5); set("v1_out_members", 3); set("v1_out_mode", MPE_INDEX); set("v1_out_mode", 1)
  assert_equal(probe.offs, 0, "port 0: no route changed, no note ended")
  set("v1_out_port", 2)
  assert_equal(probe.offs, 1, "the port: the route changed once")
  play(62)
  set("v1_out_members", 9)
  assert_equal(probe.offs, 1, "members on a plain voice: no route change")
  set("v1_out_channel", 6)
  assert_equal(probe.offs, 2, "a plain voice's channel: a route change")
  play(64)
  params:set("v1_out_channel", 12); set("v1_out_mode", MPE_INDEX)
  assert_equal(probe.offs, 3, "plain to MPE: a route change")
  clear(device)
  play(65)
  local channel = sent(device):match("note_on 65 100 (%d+)$")
  assert_true(channel ~= nil, sent(device))
  set("v1_out_channel", 13)
  assert_equal(probe.offs, 3, "an MPE voice's channel, with a note held: no route change")
  clear(device)
  set("v1_out_members", 4)
  assert_equal(probe.offs, 4, "an MPE voice's members: its notes end once")
  assert_equal(sent(device), "note_off 65 " .. channel .. "|" .. SETUP_15_48:gsub("cc 6 15 1", "cc 6 4 1"),
    "the off where the note went, then one new setup")
end)

test("a voice's port changed while its notes sound ends them where they went", function()
  local context, S = started()
  local devices = {[2] = context.midi.plug(2, "a"), [3] = context.midi.plug(3, "b")}
  -- plain
  params:set("v1_out_port", 2); settled(context)
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 1})
  context.midi.send(1, {type = "note_on", note = 64, vel = 100, ch = 1})
  clear(devices[3])
  params:set("v1_out_port", 3); settled(context)
  assert_balanced(devices, "plain")
  assert_equal(sent(devices[3]), "", "nothing on the new port yet")
  context.midi.send(1, {type = "note_on", note = 67, vel = 100, ch = 1})
  assert_equal(sent(devices[3]), "note_on 67 100 1", "a note after the change goes to the new port")
  -- MPE
  params:set("v1_out_port", 0); settled(context)
  clear(devices[2]); clear(devices[3])
  mpe_voice(1, 2, 3); settled(context)
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 1})
  local on = lines(devices[2])[#lines(devices[2])]
  local channel = on:match("^note_on 60 100 (%d+)$")
  assert_true(channel ~= nil, sent(devices[2]))
  clear(devices[2]); clear(devices[3])
  params:set("v1_out_port", 3); settled(context)
  assert_equal(sent(devices[2]), "note_off 60 " .. channel .. "|" .. TAKEDOWN, "the off where it went, then the takedown")
  assert_equal(sent(devices[3]), (SETUP_15_48:gsub("cc 6 15 1", "cc 6 3 1")), "the new port's setup")
  clear(devices[3])
  context.midi.send(1, {type = "note_on", note = 62, vel = 100, ch = 1})
  assert_true(sent(devices[3]):match("note_on 62 100 %d+$") ~= nil, "on the new port: " .. sent(devices[3]))
end)

test("a PSET with the brief's allowed zone reads back exactly, in either line order", function()
  for _, reversed in ipairs({false, true}) do
    local context, S = started()
    mpe_voice(1, 2, 7)
    params:set("v2_out_channel", 12); params:set("v2_out_port", 2)
    local before = {route_of(1), route_of(2)}
    local path = h.data_root .. "midi_out_zone_" .. tostring(reversed) .. ".pset"
    params:write(path)
    if reversed then reverse_route_lines(path) end
    context, S = started()
    params:read(path)
    local why = reversed and "reversed" or "in order"
    assert_equal(route_of(1), before[1], why)
    assert_equal(route_of(2), before[2], why)
    assert_true(S.lib.ui_flash.text("header") ~= REFUSED, why .. ": no flash")
  end
end)

test("a PSET that swaps two MPE voices' ports reads back swapped, in either line order", function()
  for _, reversed in ipairs({false, true}) do
    local context, S = started()
    local devices = {[2] = context.midi.plug(2, "a"), [3] = context.midi.plug(3, "b")}
    mpe_voice(1, 3); mpe_voice(2, 2)
    local path = h.data_root .. "midi_out_swap_" .. tostring(reversed) .. ".pset"
    params:write(path)
    if reversed then reverse_route_lines(path) end
    context, S = started()
    devices = {[2] = context.midi.plug(2, "a"), [3] = context.midi.plug(3, "b")}
    mpe_voice(1, 2); mpe_voice(2, 3); settled(context)
    clear(devices[2]); clear(devices[3])
    params:read(path)
    local why = reversed and "reversed" or "in order"
    assert_equal(route_of(1), "3 1 mpe 15", why)
    assert_equal(route_of(2), "2 2 mpe 15", why)
    assert_true(S.lib.ui_flash.text("header") ~= REFUSED, why .. ": no flash")
    for port = 2, 3 do
      assert_equal(sent(devices[port]), TAKEDOWN .. "|" .. SETUP_15_48,
        why .. ": port " .. port .. " passes to the other voice: one takedown, one setup")
    end
  end
end)

test("a PSET with two MPE voices on one port keeps the lower voice and turns the other off", function()
  local context, S = started()
  mpe_voice(1, 2); mpe_voice(2, 3)
  local path = h.data_root .. "midi_out_illegal.pset"
  params:write(path)
  edit_file(path, function(text) return (text:gsub('"v2_out_port": 3', '"v2_out_port": 2')) end)
  context, S = started()
  params:read(path)
  assert_equal(route_of(1), "2 1 mpe 15", "voice 1 keeps port 2")
  assert_equal(params:get("v2_out_port"), 0, "voice 2 is off")
  assert_equal(S.lib.ui_flash.text("header"), REFUSED, "the flash")
end)

test("a 3.5 PSET with no MIDI out lines turns every route off and sends nothing", function()
  local context, S = started()
  local path = h.data_root .. "midi_out_3_5.pset"
  params:write(path)
  edit_file(path, function(text)
    local kept = {}
    for line in text:gmatch("[^\n]+") do
      if not (line:match('^"v%d_out_') or line:match('^"cc_out') or line:match('^"midi_out_') or line:match('^"midi_pc')) then
        kept[#kept + 1] = line
      end
    end
    return table.concat(kept, "\n") .. "\n"
  end)
  context, S = started()
  local devices = {[2] = context.midi.plug(2, "a"), [3] = context.midi.plug(3, "b")}
  params:set("v1_out_port", 2); params:set("v2_out_port", 3); params:set("v2_out_channel", 9); settled(context)
  clear(devices[2]); clear(devices[3])
  params:read(path)
  for voice = 1, S.constants.NUM_VOICES do assert_equal(params:get("v" .. voice .. "_out_port"), 0, "voice " .. voice) end
  assert_equal(params:get("v2_out_channel"), 2, "a missing line is at its default")
  local target = midi_target(S)
  assert_equal(target.routed(1), false, "voice 1's route settled off at the read")
  assert_equal(target.routed(2), false, "voice 2's too")
  settled(context)
  assert_equal(sent(devices[2]) .. sent(devices[3]), "", "nothing sent")
end)

test("a PSET read while notes sound leaves as many offs as ons on every port and channel", function()
  local context, S = started()
  params:set("v1_out_port", 3); params:set("v1_out_channel", 4)
  local path = h.data_root .. "midi_out_playing.pset"
  params:write(path)
  context, S = started()
  local devices = {[2] = context.midi.plug(2, "a"), [3] = context.midi.plug(3, "b")}
  mpe_voice(1, 2, 3); settled(context)
  for _, note in ipairs({60, 64, 67}) do context.midi.send(1, {type = "note_on", note = note, vel = 90, ch = 1}) end
  assert_true(#lines(devices[2]) > 9, "the notes went: " .. sent(devices[2]))
  params:read(path)
  assert_equal(route_of(1), "3 4 plain 15")
  assert_balanced(devices, "a PSET read while playing")
end)

test("a quantized program change in is not echoed when it lands, whatever is recalled meanwhile", function()
  local context, S = started()
  local device = context.midi.plug(2, "keys")
  params:set("scene_transition_time", 0)
  capture_scene(5); capture_scene(6)
  params:set("midi_device", 2); params:set("midi_pc_in", 1)
  params:set("midi_pc_out", 1); params:set("midi_pc_out_port", 2)
  params:set("quantize_actions", 3)  -- bar
  context.midi.send(2, {type = "program_change", val = 4, ch = 1})  -- scene 5, at the bar
  recall_scene(6, 0)  -- from the norns meanwhile
  assert_equal(sent(device), "program_change 5 1", "the norns' recall sends its own")
  clear(device)
  context.clock.run_for(2.5)
  assert_equal(S.current_scene, 5, "the program change's recall landed")
  assert_equal(sent(device), "", "and was not echoed")
end)

test("an empty scene's program change in leaves no guard", function()
  local context, S = started()
  local device = context.midi.plug(2, "keys")
  params:set("scene_transition_time", 0)
  params:set("midi_device", 2); params:set("midi_pc_in", 1)
  params:set("midi_pc_out", 1); params:set("midi_pc_out_port", 2)
  context.midi.send(2, {type = "program_change", val = 6, ch = 1})  -- scene 7, empty
  capture_scene(7)
  recall_scene(7, 0)
  assert_equal(sent(device), "program_change 6 1", "the next recall of scene 7 sends")
end)

test("a second program change in replaces the first's guard", function()
  local context, S = started()
  local device = context.midi.plug(2, "keys")
  params:set("scene_transition_time", 0)
  capture_scene(5); capture_scene(6)
  params:set("midi_device", 2); params:set("midi_pc_in", 1)
  params:set("midi_pc_out", 1); params:set("midi_pc_out_port", 2)
  params:set("quantize_actions", 3)
  context.midi.send(2, {type = "program_change", val = 4, ch = 1})  -- scene 5
  context.midi.send(2, {type = "program_change", val = 5, ch = 1})  -- scene 6 replaces it
  recall_scene(5, 0)
  assert_equal(sent(device), "program_change 4 1", "scene 5's guard was replaced: its recall sends")
  clear(device)
  context.clock.run_for(2.5)
  assert_equal(S.current_scene, 6)
  assert_equal(sent(device), "", "scene 6's landing is not echoed")
end)

---------------------------------------------------------------------------
-- Review round 2: routes settle (build ruling 25), the guard kept on a refusal
---------------------------------------------------------------------------

-- Counts route_changed per voice and the refusal's flashes
local function watch(S)
  local seen = {routes = {}, flashes = 0}
  local real_route_changed = S.lib.io_targets.route_changed
  S.lib.io_targets.route_changed = function(voice)
    seen.routes[voice] = (seen.routes[voice] or 0) + 1
    return real_route_changed(voice)
  end
  local real_start = S.lib.ui_flash.start
  S.lib.ui_flash.start = function(slot, text, ...)
    if text == REFUSED then seen.flashes = seen.flashes + 1 end
    return real_start(slot, text, ...)
  end
  return seen
end

-- A PSET written from the routes setup() makes in a fresh Strata
local function pset_of(name, setup)
  local context, S = started()
  setup(context, S)
  step(context, S)
  local path = h.data_root .. name .. ".pset"
  params:write(path)
  return path
end

local SETUP_7 = SETUP_15_48:gsub("cc 6 15 1", "cc 6 7 1")

test("a fresh read of the brief's zone: one route change a voice, one setup with members 7", function()
  local path = pset_of("midi_out_trace1", function()
    mpe_voice(1, 2, 7)
    params:set("v2_out_channel", 12); params:set("v2_out_port", 2)
  end)
  local context, S = started()
  local device = context.midi.plug(2, "synth")
  clear(device)
  local seen = watch(S)
  params:read(path)
  assert_equal(seen.routes[1], 1, "voice 1's route changed once")
  assert_equal(seen.routes[2], 1, "voice 2's route changed once")
  for voice = 3, S.constants.NUM_VOICES do assert_equal(seen.routes[voice], nil, "voice " .. voice) end
  assert_equal(sent(device), SETUP_7, "exactly one setup, with members 7")
  assert_equal(seen.flashes, 0)
end)

test("a read over another legal zone: the old port's one takedown, the new port's one setup", function()
  local path = pset_of("midi_out_trace2", function() mpe_voice(1, 2, 7) end)
  local context, S = started()
  local devices = {[2] = context.midi.plug(2, "a"), [3] = context.midi.plug(3, "b")}
  mpe_voice(1, 3, 7)
  step(context, S)
  clear(devices[2]); clear(devices[3])
  params:read(path)
  assert_equal(sent(devices[3]), TAKEDOWN, "the old port: one takedown")
  assert_equal(sent(devices[2]), SETUP_7, "the new port: one setup")
end)

test("a plain route read while an MPE zone sounds on another port sends the plain port no zone message", function()
  local path = pset_of("midi_out_trace3", function()
    params:set("v1_out_port", 3); params:set("v1_out_channel", 4)
  end)
  local context, S = started()
  local devices = {[2] = context.midi.plug(2, "a"), [3] = context.midi.plug(3, "b")}
  mpe_voice(1, 2, 7)
  step(context, S)
  clear(devices[2]); clear(devices[3])
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 1})
  params:read(path)
  assert_equal(sent(devices[3]), "", "the plain port: nothing")
  local list = lines(devices[2])
  assert_true(#list >= 3 and table.concat(list, "|"):sub(-#TAKEDOWN) == TAKEDOWN, "port 2: the off, then the takedown: "
    .. sent(devices[2]))
  assert_balanced(devices, "the read")
end)

test("a hand change settles at the next step, not before", function()
  local context, S = started()
  local device = context.midi.plug(2, "synth")
  local target = midi_target(S)
  params:set("v1_out_mode", MPE_INDEX)
  params:set("v1_out_port", 2)
  assert_equal(sent(device), "", "nothing yet")
  assert_equal(target.routed(1), false, "not routed yet")
  step(context, S)
  assert_equal(sent(device), SETUP_15_48, "the setup at the step")
  assert_equal(target.routed(1), true)
end)

test("two hand changes within a step are judged together", function()
  local context, S = started()
  context.midi.plug(2, "synth")
  mpe_voice(1, 2, 7)
  step(context, S)
  local seen = watch(S)
  params:set("v2_out_port", 2)       -- alone: channel 2 is inside the zone
  params:set("v2_out_channel", 12)   -- together: outside it
  step(context, S)
  assert_equal(params:get("v2_out_port"), 2); assert_equal(params:get("v2_out_channel"), 12)
  assert_equal(seen.flashes, 0, "no refusal")
  assert_equal(midi_target(S).rows(2)[1].text(), "port 2  ch 12")
end)

test("a refused hand change is put back with one flash and nothing sent", function()
  local context, S = started()
  local device = context.midi.plug(2, "synth")
  mpe_voice(1, 2, 7)
  step(context, S)
  clear(device)
  local seen = watch(S)
  params:set("v2_out_mode", MPE_INDEX)
  params:set("v2_out_port", 2)
  step(context, S)
  assert_equal(params:get("v2_out_port"), 0, "the port put back")
  assert_equal(params:string("v2_out_mode"), "plain", "the mode put back")
  assert_equal(seen.flashes, 1, "one flash")
  assert_equal(sent(device), "", "nothing sent")
  assert_equal(seen.routes[2], nil, "no route changed")
  step(context, S, 3)
  assert_equal(seen.flashes, 1, "still one flash")
end)

test("a bend range changed beside a refused route change stands, and the zone gets its setup", function()
  local context, S = started()
  local device = context.midi.plug(2, "synth")
  mpe_voice(1, 2, 7)
  step(context, S)
  clear(device)
  local seen = watch(S)
  params:set("midi_out_bend_range", 24)
  params:set("v2_out_mode", MPE_INDEX)
  params:set("v2_out_port", 2)
  step(context, S)
  assert_equal(params:get("v2_out_port"), 0, "the route put back")
  assert_equal(params:string("v2_out_mode"), "plain")
  assert_equal(seen.flashes, 1, "one flash")
  assert_equal(params:get("midi_out_bend_range"), 24, "the bend range stands")
  assert_equal(sent(device), (SETUP_7:gsub("cc 6 48 2", "cc 6 24 2")), "one setup carrying it")
end)

test("an illegal PSET with its lines reversed keeps the lower voice, with one flash", function()
  local path = pset_of("midi_out_illegal_reversed", function() mpe_voice(1, 2); mpe_voice(2, 3) end)
  edit_file(path, function(text) return (text:gsub('"v2_out_port": 3', '"v2_out_port": 2')) end)
  reverse_route_lines(path)
  local context, S = started()
  local seen = watch(S)
  params:read(path)
  assert_equal(route_of(1), "2 1 mpe 15", "voice 1 keeps port 2")
  assert_equal(params:get("v2_out_port"), 0, "voice 2 is off")
  assert_equal(seen.flashes, 1, "one flash")
end)

test("a swap of two MPE voices' ports read while a note sounds on each", function()
  local path = pset_of("midi_out_swap_playing", function() mpe_voice(1, 3); mpe_voice(2, 2) end)
  local context, S = started()
  local devices = {[2] = context.midi.plug(2, "a"), [3] = context.midi.plug(3, "b")}
  mpe_voice(1, 2); mpe_voice(2, 3)
  step(context, S)
  context.midi.send(1, {type = "note_on", note = 60, vel = 100, ch = 1})  -- voice 1, on port 2
  context.midi.send(1, {type = "note_on", note = 62, vel = 100, ch = 2})  -- voice 2, on port 3
  local function member(device, note)
    return sent(device):match("note_on " .. note .. " 100 (%d+)")
  end
  local channel1, channel2 = member(devices[2], 60), member(devices[3], 62)
  assert_true(channel1 ~= nil and channel2 ~= nil, sent(devices[2]) .. " / " .. sent(devices[3]))
  clear(devices[2]); clear(devices[3])
  params:read(path)
  assert_equal(sent(devices[2]), "note_off 60 " .. channel1 .. "|" .. TAKEDOWN .. "|" .. SETUP_15_48, "port 2")
  assert_equal(sent(devices[3]), "note_off 62 " .. channel2 .. "|" .. TAKEDOWN .. "|" .. SETUP_15_48, "port 3")
  assert_equal(route_of(1), "3 1 mpe 15"); assert_equal(route_of(2), "2 2 mpe 15")
end)

test("a program change for an empty scene keeps the guard of the one waiting", function()
  local context, S = started()
  local device = context.midi.plug(2, "keys")
  params:set("scene_transition_time", 0)
  capture_scene(5)
  params:set("midi_device", 2); params:set("midi_pc_in", 1)
  params:set("midi_pc_out", 1); params:set("midi_pc_out_port", 2)
  params:set("quantize_actions", 3)
  context.midi.send(2, {type = "program_change", val = 4, ch = 1})  -- scene 5, at the bar
  context.midi.send(2, {type = "program_change", val = 6, ch = 1})  -- scene 7, empty
  context.clock.run_for(2.5)
  assert_equal(S.current_scene, 5)
  assert_equal(sent(device), "", "scene 5's landing is not echoed")
end)

end

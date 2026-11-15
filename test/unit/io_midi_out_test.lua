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
  assert_equal(out.MIDI_OUT.all_notes_off_cc, 123)
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
  params:set("v2_out_port", 3)
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

test("two ids on one note send one off, at the last", function()
  local context, S = started()
  local device = context.midi.plug(3, "synth")
  local target = midi_target(S)
  params:set("v2_out_port", 3)
  clear(device)
  target.note_on(2, "s1", 60, 1, step_info())
  target.note_on(2, "m7740", 60, 1, played_info(7740))
  assert_equal(sent(device), "note_on 60 127 2|note_on 60 127 2", "two note ons")
  clear(device)
  target.note_off(2, "s1")
  assert_equal(sent(device), "", "the first's end sends nothing")
  target.note_off(2, "m7740")
  assert_equal(sent(device), "note_off 60 2", "the second's sends the off")
end)

test("a played note is not sent to the port it arrived on", function()
  local context, S = started()
  local device3, device4 = context.midi.plug(3, "keys"), context.midi.plug(4, "synth")
  local target = midi_target(S)
  params:set("midi_device", 3)
  params:set("v1_out_port", 3)
  clear(device3)
  target.note_on(1, "m188", 60, 1, played_info(188))
  assert_equal(sent(device3), "", "a played note: nothing back to its own port")
  target.note_off(1, "m188")
  assert_equal(sent(device3), "", "nor its off")
  target.note_on(1, "s1", 62, 1, step_info())
  assert_equal(sent(device3), "note_on 62 127 1", "a step note goes")
  target.note_off(1, "s1")
  params:set("v1_out_port", 4)
  clear(device4)
  target.note_on(1, "m188", 60, 1, played_info(188))
  target.note_on(1, "s1", 62, 1, step_info())
  assert_equal(sent(device4), "note_on 60 127 1|note_on 62 127 1", "on another port both go")
end)

test("an MPE voice sets its zone up and takes it down", function()
  local context = started()
  local device = context.midi.plug(2, "mpe synth")
  params:set("v1_out_port", 2)
  clear(device)
  params:set("v1_out_mode", MPE_INDEX)
  assert_equal(sent(device), SETUP_15_48, "the zone's setup")
  clear(device)
  params:set("v1_out_members", 7)
  assert_equal(sent(device), (SETUP_15_48:gsub("cc 6 15 1", "cc 6 7 1")), "a members change sends it again")
  clear(device)
  params:set("midi_out_bend_range", 24)
  assert_equal(sent(device), (SETUP_15_48:gsub("cc 6 15 1", "cc 6 7 1"):gsub("cc 6 48 2", "cc 6 24 2")),
    "and a bend range change")
  clear(device)
  params:set("v1_out_mode", 1)
  assert_equal(sent(device), TAKEDOWN, "plain: the zone taken down")
end)

test("an MPE voice's port change takes the old zone down and sets the new one up", function()
  local context = started()
  local device2, device3 = context.midi.plug(2, "a"), context.midi.plug(3, "b")
  mpe_voice(1, 2)
  clear(device2); clear(device3)
  params:set("v1_out_port", 3)
  assert_equal(sent(device2), TAKEDOWN, "the old port")
  assert_equal(sent(device3), SETUP_15_48, "the new port")
  clear(device3)
  params:set("v1_out_port", 0)
  assert_equal(sent(device3), TAKEDOWN, "the port away")
end)

test("an MPE note sends its bend, pressure and slide, then its note on, on a member channel", function()
  local context, S = started()
  local device = context.midi.plug(2, "mpe synth")
  params:set("midi_channel_mode", 3)  -- mpe selected: voice 1
  mpe_voice(1, 2)
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
  mpe_voice(1, 2, 3)
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
  mpe_voice(1, 2)
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
  mpe_voice(1, 2)
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
  mpe_voice(1, 2)
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
  mpe_voice(1, 2, 7)  -- the zone: channels 1 to 8
  params:set("v2_out_channel", 12)
  params:set("v2_out_port", 2)
  assert_equal(params:get("v2_out_port"), 2, "plain channel 12 is outside the zone")
  params:set("v2_out_mode", MPE_INDEX)
  assert_equal(params:string("v2_out_mode"), "plain", "a second MPE voice on port 2 is refused")
  assert_equal(S.lib.ui_flash.text("header"), "port has an mpe voice")
  S.lib.ui_flash.start("header", nil)
  params:set("v3_out_channel", 5)
  params:set("v3_out_port", 2)
  assert_equal(params:get("v3_out_port"), 0, "plain channel 5 inside the zone: back to its previous value")
  assert_equal(S.lib.ui_flash.text("header"), "port has an mpe voice")
  params:set("v3_out_channel", 12)
  params:set("v3_out_port", 2)
  assert_equal(params:get("v3_out_port"), 2, "channel 12 is allowed")
  params:set("v3_out_channel", 8)
  assert_equal(params:get("v3_out_channel"), 12, "a channel moved into the zone is refused")
  params:set("v1_out_members", 15)
  assert_equal(params:get("v1_out_members"), 7, "members that would take in a plain channel are refused")
  params:set("v4_out_port", 2)
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

test("a MIDI output that returns gets all notes off on the channels it had notes on", function()
  local context, S = started()
  context.midi.plug(3, "synth")
  local target = midi_target(S)
  mpe_voice(1, 3, 3)  -- members 2 to 4
  params:set("v2_out_channel", 5)
  params:set("v2_out_port", 3)
  target.note_on(1, "s1", 60, 1, step_info())  -- member channel 2
  target.note_on(2, "s1", 64, 1, step_info())  -- channel 5
  context.midi.unplug(3)
  local device = context.midi.plug(3, "synth")
  assert_equal(sent(device), "cc 123 0 2|cc 123 0 5|" .. SETUP_15_48:gsub("cc 6 15 1", "cc 6 3 1"),
    "all notes off on 2 and 5, then the MPE setup")
  target.note_off(1, "s1"); target.note_off(2, "s1")
  context.midi.unplug(3)
  device = context.midi.plug(3, "synth")
  assert_equal(sent(device), SETUP_15_48:gsub("cc 6 15 1", "cc 6 3 1"), "no notes when it left: the setup only")
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
  params:set("v1_out_port", 2)
  play_some()
  assert_true(#lines(device) >= 3, "the notes went: " .. sent(device))
  params:set("v1_out_channel", 9)
  balanced("a route change")
  clear(device)
  play_some()
  toggle_voice(1)
  balanced("a voice stop")
  clear(device)
  mpe_voice(1, 2)
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
  params:set("v1_out_port", 2); params:set("v1_out_channel", 3)
  assert_equal(target.rows(1)[1].text(), "port 2  ch 3")
  params:set("v1_out_mode", MPE_INDEX)
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

end

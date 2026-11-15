-- test/unit/io_controllers_test.lua
-- The controllers (lib/io/controllers.lua, S.lib.io_controllers): an OXI E16
-- and a box of sixteen faders on the sixteen macros, the E16's script
-- (extras/e16/strata.lua) and IO's controllers section.
-- Facts: docs/design/3.6-facts/controllers.md sections 1 and 3, checks.md
-- sections 2 and 3. No device is used: the frames and CCs below are the
-- bytes those documents give.
-- Run alone: lua test/run.lua io_controllers

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value = h.load_strata, h.local_value

local E16_PORT, FADERS_PORT = 2, 3
local HEADER = {0xF0, 0x7D, 0x53, 0x54}

local function loaded()
  local context = load_strata()
  local S = local_value("S")
  return context, S, S.lib.io_controllers
end

-- An E16 on port 2 and, when faders is true, a fader box on port 3, the rig
-- set and the devices plugged in; what the arrival sent is cleared
local function rig_with(context, S, options)
  options = options or {}
  local rig = S.lib.io_rig
  local devices = {}
  if options.e16 ~= false then
    assert_true(rig.set("e16_port", E16_PORT))
    devices.e16 = context.midi.plug(E16_PORT, "OXI E16")
    context.clock.run_for(0.1)  -- the arrival's first tick sends every macro (below); settled
    devices.e16.sent = {}
  end
  if options.faders then
    assert_true(rig.set("faders_port", FADERS_PORT))
    devices.faders = context.midi.plug(FADERS_PORT, "16n")
    devices.faders.sent = {}
  end
  return rig, devices
end

local function cc(context, port, number, value, channel)
  context.midi.send(port, {type = "cc", cc = number, val = value, ch = channel or 1})
end

-- A turn of the E16's encoder m: the macro's change
local function e16_turn(context, m, value, first_cc)
  local id = "macro_" .. m
  local before = params:get(id)
  cc(context, E16_PORT, (first_cc or 102) + m - 1, value, 16)
  return params:get(id) - before
end

-- What a device was sent, split: its CCs ({status, cc, value}) and SysEx frames
local function split_sent(device)
  local ccs, frames = {}, {}
  for _, data in ipairs(device.sent) do
    if data[1] == 0xF0 then frames[#frames + 1] = data else ccs[#ccs + 1] = data end
  end
  return ccs, frames
end

local function has_header(frame)
  for index = 1, #HEADER do
    if frame[index] ~= HEADER[index] then return false end
  end
  return true
end

local function section(S, name)
  for _, record in ipairs(S.registry.io_sections) do
    if record.name == name then return record end
  end
  error("no io section " .. name)
end

test("with no controller port nothing listens, nothing is sent and no clock runs", function()
  local context, S, controllers = loaded()
  assert_equal(controllers.clock_id(), nil, "no port set: no clock")
  for port = 1, S.lib.io_ports.PORTS.count do
    assert_true(S.lib.io_ports.owner(port) ~= "e16" and S.lib.io_ports.owner(port) ~= "faders", "no port is claimed")
  end
  local device = context.midi.plug(E16_PORT, "OXI E16")
  params:set("macro_1", 0.5)
  cc(context, E16_PORT, 102, 1, 16)
  context.clock.run_for(0.5)
  assert_equal(#device.sent, 0, "nothing is sent")
  assert_near(params:get("macro_1"), 0.5, 1e-9, "a CC on the E16's numbers moves nothing")
  local rig = S.lib.io_rig
  assert_true(rig.set("faders_port", FADERS_PORT))
  assert_true(controllers.clock_id() ~= nil, "a port set: the clock runs")
  assert_true(rig.set("faders_port", 0))
  assert_equal(controllers.clock_id(), nil, "and ends when the last port is off")
end)

test("an E16 turn moves its macro by detents, in both encodings", function()
  -- controllers.md section 1: "Relative 1 will send a value of 1 to increment
  -- the control and 127 to decrement. Relative 2 ... uses 63 to increment and
  -- 65 to decrement" (checks.md section 3); one message per detent
  local context, S = loaded()
  local rig = rig_with(context, S)
  params:set("macro_1", 0.5)
  assert_near(e16_turn(context, 1, 1), 0.01, 1e-9, "rel1: 1 is one detent up")
  assert_near(e16_turn(context, 1, 3), 0.03, 1e-9, "3 is three up")
  assert_near(e16_turn(context, 1, 127), -0.01, 1e-9, "127 is one down")
  assert_near(e16_turn(context, 1, 125), -0.03, 1e-9, "125 is three down")
  assert_near(e16_turn(context, 1, 64), 0, 1e-9, "64 does nothing in rel1")
  assert_near(e16_turn(context, 1, 0), 0, 1e-9, "nor 0")
  params:set("macro_16", 0.5)
  assert_near(e16_turn(context, 16, 1), 0.01, 1e-9, "cc 117 is macro 16")
  assert_true(rig.set("e16_encoding", "rel2"))
  assert_near(e16_turn(context, 1, 63), 0.01, 1e-9, "rel2: 63 is one up")
  assert_near(e16_turn(context, 1, 61), 0.03, 1e-9, "61 is three up")
  assert_near(e16_turn(context, 1, 65), -0.01, 1e-9, "65 is one down")
  assert_near(e16_turn(context, 1, 67), -0.03, 1e-9, "67 is three down")
  assert_near(e16_turn(context, 1, 64), 0, 1e-9, "64 does nothing in rel2")
  assert_near(e16_turn(context, 1, 0), 0, 1e-9, "nor 0")
  assert_true(rig.set("e16_channel", 3) and rig.set("e16_cc", 20))
  params:set("macro_2", 0.5)
  cc(context, E16_PORT, 21, 63, 3)
  assert_near(params:get("macro_2"), 0.51, 1e-9, "another channel and first CC are read live")
end)

test("a turn is a touch from midi", function()
  local context, S = loaded()
  rig_with(context, S)
  local touched = {}
  S.register_param_touch(function(id, source) touched[#touched + 1] = id .. " " .. tostring(source) end)
  e16_turn(context, 1, 1)
  assert_equal(table.concat(touched, ","), "macro_1 midi", "the touch hooks heard a turn from midi")
end)

test("a CC outside the sixteen is ignored", function()
  local context, S = loaded()
  rig_with(context, S)
  local before = {}
  for m = 1, 16 do before[m] = params:get("macro_" .. m) end
  cc(context, E16_PORT, 101, 1, 16)
  cc(context, E16_PORT, 118, 1, 16)
  cc(context, E16_PORT, 102, 1, 15)
  cc(context, 4, 102, 1, 16)
  context.midi.send(E16_PORT, {type = "note_on", note = 102, vel = 1, ch = 16})
  context.midi.send(E16_PORT, {type = "pitchbend", val = 100, ch = 16})
  for m = 1, 16 do assert_equal(params:get("macro_" .. m), before[m], "macro " .. m .. " stays") end
end)

test("a changed macro is echoed as a CC and one ring frame a tick", function()
  -- controllers.md section 1: leds.update takes 0-16383; design 8.1's frame
  -- F0 7D 53 54 01, sixteen pairs of 7 bits (high first), F7: 38 bytes
  local context, S, controllers = loaded()
  local _, devices = rig_with(context, S)
  params:set("macro_3", 0.5)
  context.clock.run_for(0.1)
  local ccs, frames = split_sent(devices.e16)
  assert_equal(#ccs, 1, "one CC")
  assert_equal(ccs[1][1], 0xBF, "on channel 16")
  assert_equal(ccs[1][2], 104, "macro 3 is CC 104")
  assert_equal(ccs[1][3], 64, "at round(0.5 * 127)")
  assert_equal(#frames, 1, "one ring frame")
  assert_equal(#frames[1], 38, "of 38 bytes")
  assert_true(has_header(frames[1]) and frames[1][5] == 0x01 and frames[1][38] == 0xF7, "F0 7D 53 54 01 ... F7")
  assert_equal(frames[1][10], 0x40, "the third pair's high byte")
  assert_equal(frames[1][11], 0x00, "and low byte: 8192")
  assert_equal(frames[1][6], 0, "the first pair is 0")
  devices.e16.sent = {}
  context.clock.run_for(0.3)
  assert_equal(#devices.e16.sent, 0, "a tick with no change sends nothing")
  for m = 1, 16 do params:set("macro_" .. m, 0.2); params:set("macro_" .. m, 0.4) end
  context.clock.run_for(0.1)
  ccs, frames = split_sent(devices.e16)
  assert_equal(#ccs, 16, "sixteen changed macros: sixteen CCs")
  for m = 1, 16 do
    assert_equal(ccs[m][2], 102 + m - 1, "in order, macro " .. m)
    assert_equal(ccs[m][3], 51, "each with its newest value, round(0.4 * 127)")
  end
  assert_equal(#frames, 1, "and one frame")
  assert_equal(frames[1][6] * 128 + frames[1][7], 6553, "round(0.4 * 16383)")
  assert_true(controllers.clock_id() ~= nil)
end)

test("labels and the title go at the device's arrival and when a first target changes", function()
  local context, S = loaded()
  local rig = S.lib.io_rig
  assert_true(rig.set("e16_port", E16_PORT))
  local device = context.midi.plug(E16_PORT, "OXI E16")
  local ccs, frames = split_sent(device)
  assert_equal(#ccs, 0, "no CC at arrival")
  assert_equal(#frames, 17, "sixteen labels and the title")
  for m = 1, 16 do
    local frame = frames[m]
    assert_true(has_header(frame) and frame[5] == 0x02 and frame[#frame] == 0xF7, "label frame " .. m)
    assert_equal(frame[6], m - 1, "its index byte is 0-based")
    assert_equal(#frame, 11, "four characters")
  end
  assert_equal(table.concat(frames[1], ","), "240,125,83,84,2,0,77,49,32,32,247", "macro 1: M1 and two spaces")
  assert_equal(string.char(frames[10][7], frames[10][8], frames[10][9], frames[10][10]), "M10 ", "macro 10")
  assert_equal(table.concat(frames[17], ","), "240,125,83,84,3,83,84,82,65,84,65,247", "the title STRATA")
  -- nothing has been echoed yet: the next tick gives the rings and every macro's CC
  device.sent = {}
  context.clock.run_for(0.1)
  ccs, frames = split_sent(device)
  assert_equal(#ccs, 16, "a freshly plugged E16 gets all sixteen CCs")
  assert_equal(ccs[1][2], 102)
  assert_equal(ccs[16][2], 117)
  assert_equal(#frames, 1, "and one ring frame")
  assert_equal(#frames[1], 38)
  assert_equal(frames[1][5], 0x01)
  device.sent = {}
  local id = S.lib.macros.target_ids()[1]
  assert_true(S.lib.macros.set_target(2, 1, id, 0, 1))
  context.clock.run_for(0.1)
  ccs, frames = split_sent(device)
  assert_equal(#ccs, 0, "a target is no value change")
  assert_equal(#frames, 1, "one label frame")
  assert_equal(frames[1][5], 0x02)
  assert_equal(frames[1][6], 1, "macro 2")
  local label = S.lib.macros.target_label(id)
  local expected = (label .. "    "):sub(1, 4)
  local text = {}
  for index = 7, 10 do text[#text + 1] = string.char(frames[1][index]) end
  assert_equal(table.concat(text), expected, "the label cut or padded to four")
  device.sent = {}
  context.clock.run_for(0.3)
  assert_equal(#device.sent, 0, "unchanged: nothing again")
end)

test("the echo of a macro is never read as a turn, and it costs at most one step", function()
  local context, S = loaded()
  local _, devices = rig_with(context, S)
  assert_near(e16_turn(context, 1, 1), 0.01, 1e-9, "a turn")
  context.clock.run_for(0.07)
  local ccs = split_sent(devices.e16)
  assert_equal(#ccs, 1, "Strata echoed the macro")
  assert_equal(ccs[1][3], 1, "round(0.01 * 127) = 1, which reads as a turn up")
  cc(context, E16_PORT, ccs[1][2], ccs[1][3], 16)
  assert_near(params:get("macro_1"), 0.01, 1e-9, "the echo delivered back moves nothing")
  cc(context, E16_PORT, 102, 1, 16)
  assert_near(params:get("macro_1"), 0.02, 1e-9, "the same CC a second time is a turn: an echo is used up by one CC")
end)

test("steps up after an echo that looks like a step are not swallowed", function()
  -- the review's case: from 0 the first step's echo is CC value 1, the same
  -- code as rel1's step up; with Thru off the E16 never sends it back
  local context, S = loaded()
  local _, devices = rig_with(context, S)
  assert_near(e16_turn(context, 1, 1), 0.01, 1e-9)
  context.clock.run_for(0.07)  -- the echo, value 1, goes out
  assert_equal(split_sent(devices.e16)[1][3], 1)
  for _ = 1, 9 do
    cc(context, E16_PORT, 102, 1, 16)
    context.clock.run_for(0.01)
  end
  assert_true(params:get("macro_1") >= 0.09 - 1e-9,
    "ten steps of 1 sent 10 ms apart move it by at least 0.09 (one may be taken for the echo), got "
    .. params:get("macro_1"))
end)

test("a fader moves its macro only once picked up", function()
  local context, S = loaded()
  rig_with(context, S, {e16 = false, faders = true})
  local controllers = S.lib.io_controllers
  params:set("macro_1", 0.5)
  cc(context, FADERS_PORT, 32, 10)
  assert_near(params:get("macro_1"), 0.5, 1e-9, "far from the macro: it stays")
  assert_true(not controllers.pickup(1))
  cc(context, FADERS_PORT, 32, 62)
  assert_near(params:get("macro_1"), 62 / 127, 1e-9, "within 2/127: picked up")
  assert_true(controllers.pickup(1))
  cc(context, FADERS_PORT, 32, 80)
  assert_near(params:get("macro_1"), 80 / 127, 1e-9, "then it follows")
  params:set("macro_2", 0.5)
  cc(context, FADERS_PORT, 33, 10)
  assert_near(params:get("macro_2"), 0.5, 1e-9)
  cc(context, FADERS_PORT, 33, 120)
  assert_near(params:get("macro_2"), 120 / 127, 1e-9, "a crossing picks it up")
  assert_true(controllers.pickup(2))
  cc(context, FADERS_PORT, 32, 80, 2)
  cc(context, FADERS_PORT, 31, 5)
  cc(context, FADERS_PORT, 48, 5)
  assert_near(params:get("macro_1"), 80 / 127, 1e-9, "another channel or CC is not a fader")
end)

test("a change the fader did not make drops the pickup", function()
  local context, S = loaded()
  rig_with(context, S, {e16 = false, faders = true})
  local controllers = S.lib.io_controllers
  params:set("macro_1", 0.5)
  cc(context, FADERS_PORT, 32, 64)
  cc(context, FADERS_PORT, 32, 80)
  assert_true(controllers.pickup(1))
  params:set("macro_1", 0.2)
  cc(context, FADERS_PORT, 32, 81)
  assert_near(params:get("macro_1"), 0.2, 1e-9, "the fader no longer moves it")
  assert_true(not controllers.pickup(1), "and it is waiting again")
  -- an LFO on a macro moves engine values, never the param: no drop
  cc(context, FADERS_PORT, 32, 25)
  assert_true(controllers.pickup(1), "picked up again near 0.2")
  local lfos = S.lib.lfos
  for index, entry in ipairs(S.LFO_DESTINATIONS) do
    if entry.label == "macro 1" then params:set(lfos.param_id(1, "dest"), index) end
  end
  params:set(lfos.param_id(1, "shape"), 3)
  params:set(lfos.param_id(1, "depth"), 100)
  params:set(lfos.param_id(1), 1)
  context.clock.run_for(0.3)
  assert_true(controllers.pickup(1), "an LFO on the macro drops nothing")
  params:set(lfos.param_id(1), 0)
end)

test("hires uses the low byte once one has come, and a 7-bit box still reaches both ends", function()
  local context, S = loaded()
  local rig = rig_with(context, S, {e16 = false, faders = true})
  assert_true(rig.set("faders_hires", "on"))
  params:set("macro_1", 0.5)
  cc(context, FADERS_PORT, 32, 64)
  assert_true(S.lib.io_controllers.pickup(1), "picked up")
  cc(context, FADERS_PORT, 32, 127)
  assert_equal(params:get("macro_1"), 1, "no low byte ever: 127 reaches 1")
  cc(context, FADERS_PORT, 64, 0)
  cc(context, FADERS_PORT, 32, 64)
  assert_near(params:get("macro_1"), 8192 / 16383, 1e-9, "the low byte 0, the high 64")
  cc(context, FADERS_PORT, 64, 127)
  assert_near(params:get("macro_1"), (64 * 128 + 127) / 16383, 1e-9, "a low byte alone moves it")
  assert_true(rig.set("faders_hires", "off"))
  cc(context, FADERS_PORT, 32, 64)
  assert_near(params:get("macro_1"), 64 / 127, 1e-9, "hires off: 7 bits again")
end)

test("a port a controller holds has one owner, and a port change moves the claim", function()
  local context, S = loaded()
  local rig = S.lib.io_rig
  assert_true(rig.set("e16_port", E16_PORT))
  assert_equal(S.lib.io_ports.owner(E16_PORT), "e16")
  assert_true(rig.set("e16_port", 4))
  assert_equal(S.lib.io_ports.owner(E16_PORT), nil, "the old port is released")
  assert_equal(S.lib.io_ports.owner(4), "e16")
  assert_true(rig.set("faders_port", FADERS_PORT))
  assert_equal(S.lib.io_ports.owner(FADERS_PORT), "faders")
  assert_true(rig.set("faders_port", 4))
  assert_equal(S.lib.io_ports.owner(4), "e16", "a port another owner holds is not taken")
  assert_equal(S.lib.io_ports.owner(FADERS_PORT), nil)
  assert_true(rig.set("e16_port", 0))
  assert_equal(S.lib.io_ports.owner(4), "faders", "off releases, and the controller that waited takes it")
  assert_true(S.lib.io_controllers.clock_id() ~= nil, "the faders' port is still set: the clock runs")
end)

test("a port a controller cannot take shows as taken and is claimed when released", function()
  local context, S, controllers = loaded()
  local rig = S.lib.io_rig
  local record = section(S, "controllers")
  assert_true(rig.set("e16_port", 2) and rig.set("faders_port", 2))
  assert_equal(S.lib.io_ports.owner(2), "e16", "the first has it")
  assert_equal(record.status(), "port taken", "the second does not: IO says so")
  context.midi.plug(2, "OXI E16")
  assert_equal(record.status(), "port taken", "whatever device is on it")
  params:set("macro_1", 0.5)
  cc(context, 2, 32, 64, 1)
  assert_near(params:get("macro_1"), 0.5, 1e-9, "only the first acts: the faders' CC moves nothing")
  assert_true(not controllers.pickup(1))
  assert_near(e16_turn(context, 1, 1), 0.01, 1e-9, "the E16 turns")
  assert_true(rig.set("e16_port", 3))
  assert_equal(S.lib.io_ports.owner(2), "faders", "the first leaving lets the second take port 2, with no further setting")
  cc(context, 2, 32, 64, 1)
  assert_true(controllers.pickup(1), "and it acts")
  assert_equal(record.status(), "[--]", "the E16's new port has no device: no longer taken")
  -- a port another owner holds, then released
  assert_true(rig.set("e16_port", 5))
  assert_true(S.lib.io_ports.claim(6, "midi_in"))
  assert_true(rig.set("e16_port", 6))
  assert_equal(S.lib.io_ports.owner(6), "midi_in")
  assert_equal(record.status(), "port taken")
  S.lib.io_ports.release(6, "midi_in")
  assert_equal(S.lib.io_ports.owner(6), "e16", "released by its holder: claimed")
  assert_true(record.status() ~= "port taken")
end)

test("a MIDI map on a controller's CC shows as a clash", function()
  -- design 8.3: norns' MAP acts on these CCs too and would move a macro twice
  local context, S, controllers = loaded()
  rig_with(context, S)
  local controllers_section = section(S, "controllers")
  assert_true(not controllers.map_clash(), "no map: no clash")
  assert_true(controllers_section.status() ~= "map clash")
  norns.pmap.rev[E16_PORT][16][102] = "v1_level"
  assert_true(controllers.map_clash())
  assert_equal(controllers_section.status(), "map clash")
  norns.pmap.rev[E16_PORT][16][102] = nil
  norns.pmap.rev[E16_PORT][16][118] = "v1_level"
  norns.pmap.rev[E16_PORT][15][102] = "v1_level"
  norns.pmap.rev[4][16][102] = "v1_level"
  assert_true(not controllers.map_clash(), "an entry for another CC, channel or port is no clash")
end)

test("the section shows the settings, the faders' marks and the device's state", function()
  local context, S, controllers = loaded()
  local record = section(S, "controllers")
  local rows = record.rows()
  local keys = {}
  for _, row in ipairs(rows) do
    if row.kind == "rig" then keys[#keys + 1] = row.key end
  end
  assert_equal(table.concat(keys, ","),
    "e16_port,e16_channel,e16_cc,e16_encoding,faders_port,faders_channel,faders_cc,faders_hires")
  local strip
  for _, row in ipairs(rows) do
    if row.kind == "status" then strip = type(row.text) == "function" and row.text() or row.text end
  end
  assert_equal(strip, string.rep(".", 16), "sixteen marks, none picked up")
  assert_equal(record.status(), nil, "no port set: nothing to say")
  local rig = S.lib.io_rig
  assert_true(rig.set("e16_port", E16_PORT))
  assert_equal(record.status(), "[--]", "a port with no device")
  local device = context.midi.plug(E16_PORT, "OXI E16")
  assert_equal(record.status(), nil, "with it, nothing")
  assert_true(device ~= nil)
  assert_true(rig.set("faders_port", FADERS_PORT))
  assert_equal(record.status(), "[--]", "the faders' port has none")
  context.midi.plug(FADERS_PORT, "16n")
  params:set("macro_1", 0.5); params:set("macro_16", 0.5)
  cc(context, FADERS_PORT, 32, 64)
  cc(context, FADERS_PORT, 47, 64)
  assert_true(controllers.pickup(1) and controllers.pickup(16))
  rows = record.rows()
  for _, row in ipairs(rows) do
    if row.kind == "status" then strip = type(row.text) == "function" and row.text() or row.text end
  end
  assert_equal(strip, "|" .. string.rep(".", 14) .. "|", "the picked-up faders")
end)

test("the E16 script draws rings, labels and the title from Strata's frames", function()
  -- checks.md section 2: leds.update and slots.update count encoders from 1,
  -- so the script adds 1 to the 0-based index byte of Strata's label frame
  local context, S = loaded()
  local e16 = require("stub_e16")()
  e16.run("extras/e16/strata.lua")
  local rig = S.lib.io_rig
  assert_true(rig.set("e16_port", E16_PORT))
  local device = context.midi.plug(E16_PORT, "OXI E16")
  params:set("macro_3", 0.5)
  context.clock.run_for(0.1)
  local _, frames = split_sent(device)
  assert_equal(#frames, 18, "sixteen labels, the title and one ring frame")
  for _, frame in ipairs(frames) do e16.sysex(frame) end
  local updates = 0
  for _, call in ipairs(e16.calls) do
    if call[1] == "leds.update" then updates = updates + 1 end
  end
  assert_equal(updates, 16, "sixteen ring updates")
  assert_equal(e16.leds[3].value, 8192, "encoder 3 holds macro 3's value")
  assert_equal(e16.leds[1].value, 0)
  assert_equal(e16.slots[1], "M1  ", "label 0 goes to encoder 1")
  assert_equal(e16.slots[16], "M16 ", "label 15 to encoder 16")
  assert_equal(e16.title, "STRATA")
  local calls = #e16.calls
  e16.sysex({0xF0, 0x7D, 0x00, 0x00, 0x01, 0xF7})
  e16.sysex({0xF0, 0x7D, 0x00, 0x00, 0x02, 0x00, 0x41, 0x42, 0x43, 0x44, 0xF7})
  e16.sysex({0xF0, 0x7D, 0x53, 0x54, 0x01, 0x00, 0x00, 0xF7})
  e16.sysex({0xF0, 0x7D, 0x53, 0x54, 0x02, 0x00, 0x41, 0xF7})
  e16.sysex({0xF0, 0x7D, 0x53, 0x54, 0x09, 0xF7})
  e16.sysex({0xF0, 0x7D, 0x53, 0xF7})
  e16.sysex({})
  assert_equal(#e16.calls, calls, "another header, a short frame or an unknown command: nothing")
end)

test("a device already on the port at the setting gets its labels, then every CC and the rings", function()
  local context, S = loaded()
  local device = context.midi.plug(E16_PORT, "OXI E16")
  assert_true(S.lib.io_rig.set("e16_port", E16_PORT))
  local ccs, frames = split_sent(device)
  assert_equal(#ccs, 0)
  assert_equal(#frames, 17, "sixteen labels and the title at once")
  device.sent = {}
  context.clock.run_for(0.1)
  ccs, frames = split_sent(device)
  assert_equal(#ccs, 16, "then all sixteen CCs")
  assert_equal(#frames, 1, "and the rings")
end)

test("drawing IO with the controllers section shown requests no redraw", function()
  local context, S, controllers = loaded()
  rig_with(context, S, {e16 = false, faders = true})
  params:set("macro_1", 0.5)
  cc(context, FADERS_PORT, 32, 64)
  assert_true(controllers.pickup(1))
  h.show_page("IO")
  S.lib.pages_io.show_section("controllers")
  params:set("macro_1", 0.2)  -- the pickup ends without a message from the fader
  local requests = 0
  local real_request = _G.request_redraw
  _G.request_redraw = function(...) requests = requests + 1; return real_request(...) end
  redraw()
  _G.request_redraw = real_request
  assert_equal(requests, 0, "a draw only reads")
  assert_true(not controllers.pickup(1), "and the strip already shows the pickup ended")
  context.clock.run_for(0.1)
  assert_true(not controllers.pickup(1), "it stays ended after a tick")
  params:set("macro_1", 64 / 127)
  assert_true(not controllers.pickup(1), "the param back where the fader left it does not bring it back")
end)

test("the layout states set the rig the way a user does", function()
  local context, S, controllers = loaded()
  h.show_page("IO")
  local states = S.registry.pages[S.constants.UI_PAGES.index.IO].layout_states
  local by_name = {}
  for _, state in ipairs(states) do by_name[state.name] = state end
  local record = section(S, "controllers")
  local function run(name)
    h.show_page("IO")
    by_name["controllers: " .. name].setup(context)
  end
  run("no port set")
  assert_equal(S.lib.io_rig.get("e16_port"), 0)
  assert_equal(S.lib.io_rig.get("faders_port"), 0)
  assert_equal(record.status(), nil)
  run("port without device")
  assert_equal(S.lib.io_rig.get("e16_port"), 2, "E3 on the e16 port row")
  assert_equal(S.lib.io_rig.get("faders_port"), 3, "and on the faders port row")
  assert_equal(record.status(), "[--]")
  run("both present")
  assert_true(S.lib.io_ports.device(2) ~= nil and S.lib.io_ports.device(3) ~= nil, "both plugged in")
  assert_equal(record.status(), nil)
  local marks = 0
  for m = 1, 16 do
    if controllers.pickup(m) then marks = marks + 1 end
  end
  assert_equal(marks, 7, "some faders picked up, by CCs the box sent")
  run("map clash")
  assert_equal(record.status(), "map clash")
  run("no port set")
  assert_equal(record.status(), nil, "back to none: ports off, devices gone, the map cleared")
  assert_true(S.lib.io_ports.device(2) == nil)
  for _, row in ipairs(S.lib.pages_io.rows()) do
    assert_true(row.key ~= "e16_port" or S.lib.io_rig.text("e16_port") == "off")
  end
end)

test("a failure in a tick prints one line and the clock goes on", function()
  local context, S = loaded()
  local _, devices = rig_with(context, S, {faders = true})
  params:set("macro_1", 0.5)
  cc(context, FADERS_PORT, 32, 64)  -- picked up: the strip reads the param
  assert_true(S.lib.io_controllers.pickup(1))
  context.clock.run_for(0.2)  -- the macro's own apply has run
  local failing = true
  local real_get = params.get
  params.get = function(self, id, ...)
    if failing and id == "macro_1" then error("probe failure") end
    return real_get(self, id, ...)
  end
  context.clock.run_for(0.2)
  params.get = real_get
  failing = false
  h.claim_script_errors(context, 1, "strata: controllers tick failed: ", "probe failure")
  params:set("macro_2", 0.5)
  context.clock.run_for(0.1)
  local ccs = split_sent(devices.e16)
  assert_true(#ccs > 0, "the clock still ticks and echoes")
end)

test("a setting of one controller resets only its own state", function()
  local context, S, controllers = loaded()
  local rig, devices = rig_with(context, S, {faders = true})
  params:set("macro_1", 0.5)
  cc(context, FADERS_PORT, 32, 64)
  assert_true(controllers.pickup(1))
  assert_true(rig.set("e16_channel", 5) and rig.set("e16_cc", 20) and rig.set("e16_encoding", "rel2"))
  assert_true(controllers.pickup(1), "an E16 setting leaves the faders' pickup")
  devices.e16.sent = {}
  context.clock.run_for(0.1)
  local ccs = split_sent(devices.e16)
  assert_equal(#ccs, 16, "and the E16 goes out again on its new numbers")
  assert_equal(ccs[1][1], 0xB4)
  assert_equal(ccs[1][2], 20)
  assert_true(rig.set("faders_cc", 40))
  assert_true(not controllers.pickup(1), "a faders setting drops the pickup")
  devices.e16.sent = {}
  context.clock.run_for(0.2)
  assert_equal(#devices.e16.sent, 0, "and leaves the E16's echo alone")
end)

test("an idle tick builds no label", function()
  local context, S = loaded()
  rig_with(context, S)
  local calls = 0
  local real_label, real_targets = S.lib.macros.target_label, S.lib.macros.targets
  S.lib.macros.target_label = function(...) calls = calls + 1; return real_label(...) end
  S.lib.macros.targets = function(...) calls = calls + 1; return real_targets(...) end
  context.clock.run_for(1)
  assert_equal(calls, 0, "no macro's targets are copied or labeled while no first target changes")
  assert_true(S.lib.macros.set_target(2, 1, S.lib.macros.target_ids()[1], 0, 1))
  context.clock.run_for(0.1)
  S.lib.macros.target_label, S.lib.macros.targets = real_label, real_targets
  assert_true(calls >= 1, "a changed first target is labeled")
end)

end

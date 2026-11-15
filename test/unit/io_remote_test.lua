-- test/unit/io_remote_test.lua
-- Remote grids and arcs (lib/io/remote.lua, S.lib.io_remote, 3.6 design
-- §9): the protocol of notes and CCs a grid or arc in iii mode speaks with
-- Strata (version 1, its numbers pinned here), the hello and attaching, the
-- frame buffers and their 30 Hz draw clock, the virtual arc's segment, a
-- device leaving and returning, a monome arc taking over, a MIDI grid
-- through the midigrid mod, and the two device scripts (iii/strata_grid.lua,
-- iii/strata_arc.lua) run in test/stub_iii.lua against the module.
-- Facts: docs/design/3.6-facts/iii-osc-nb-softcut.md §1b (iii's functions,
-- event_midi's three bytes), docs/design/3.6-facts/checks.md §4 (LED levels
-- 0 to 15, event_arc_key(z), device_version from 1.1.0) and §7 (midigrid's
-- connect), docs/design/3.6-facts/controllers.md §5 (midigrid's object).
-- Run alone: lua test/run.lua io_remote

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local GRID_SCRIPT = h.repo_root .. "/iii/strata_grid.lua"
local ARC_SCRIPT = h.repo_root .. "/iii/strata_arc.lua"

local function started(options)
  local context = load_strata(options)
  finish_startup(context)
  return context, local_value("S")
end

-- The tests may set a rig setting directly (the module only reads them)
local function set_rig(S, key, value)
  assert_true(S.lib.io_rig.set(key, value), "rig " .. key .. " set to " .. tostring(value))
end

-- Bytes as norns sends them: status + channel - 1, then the two data bytes
local function cc_bytes(cc, value, channel) return { 0xb0 + channel - 1, cc, value } end
local function note_bytes(note, velocity, channel) return { 0x90 + channel - 1, note, velocity } end
local function text_of(bytes) return table.concat(bytes, " ") end

local function has(sent, bytes, from)
  for index = from or 1, #sent do
    if text_of(sent[index]) == text_of(bytes) then return true end
  end
  return false
end

-- The device's hello: CC 0, 1 and 2 on channel 1 (columns, rows, version)
local function hello(context, port, cols, rows, version)
  context.midi.send(port, { type = "cc", cc = 0, val = cols, ch = 1 })
  context.midi.send(port, { type = "cc", cc = 1, val = rows, ch = 1 })
  context.midi.send(port, { type = "cc", cc = 2, val = version, ch = 1 })
end

-- One tick of the draw clock
local function tick(context, S)
  local id = S.lib.io_remote.clock_id()
  assert_true(id ~= nil, "the draw clock runs")
  context.clock.advance_until(id)
end

-- Ticks until a tick sends nothing (at most limit)
local function settle(context, S, device, limit)
  for _ = 1, limit or 20 do
    local before = #device.sent
    tick(context, S)
    if #device.sent == before then return end
  end
  error("the frames never settled")
end

-- A remote grid on port, plugged and greeted (16 by 8 unless given)
local function remote_grid(context, S, port, cols, rows)
  set_rig(S, "remote_grid_port", port)
  local device = context.midi.plug(port, "iii grid")
  hello(context, port, cols or 16, rows or 8, 1)
  context.clock.run_for(0.2)
  return device
end

local function remote_arc(context, S, port)
  set_rig(S, "remote_arc_port", port)
  local device = context.midi.plug(port, "iii arc")
  hello(context, port, 0, 4, 1)
  context.clock.run_for(0.2)
  return device
end

-- What the LED messages since from set, on top of model (index -> level):
-- a grid's notes on channels 1 and 2, an arc's on 3 and 4
local function apply_leds(model, sent, from, first_channel)
  for index = from or 1, #sent do
    local bytes = sent[index]
    local status, channel = bytes[1] - bytes[1] % 16, bytes[1] % 16 + 1
    if status == 0x90 and (channel == first_channel or channel == first_channel + 1) then
      model[(channel - first_channel) * 128 + bytes[2]] = bytes[3]
    end
  end
  return model
end

local function remote_invariant(S)
  for _, record in ipairs(S.registry.invariants) do
    if record.name == "remote" then return record.fn() end
  end
  error("no remote invariant")
end

test("with the three settings off nothing is claimed, sent or clocked", function()
  local connects = 0
  local devices = {}
  local context, S = started({
    before_load = function(context)
      for port = 2, 4 do devices[port] = context.midi.plug(port, "iii grid") end
    end,
    before_init = function()
      local real = grid.connect
      grid.connect = function(...) connects = connects + 1; return real(...) end
    end,
  })
  assert_equal(S.lib.io_rig.get("remote_grid_port"), 0, "the grid port is off")
  assert_equal(S.lib.io_rig.get("remote_arc_port"), 0, "the arc port is off")
  assert_equal(S.lib.io_rig.get("midi_grid"), "off", "midigrid is off")
  for port = 1, 16 do assert_equal(S.lib.io_ports.owner(port), nil, "port " .. port .. " has no owner") end
  for port = 2, 4 do assert_equal(#devices[port].sent, 0, "nothing sent to port " .. port) end
  assert_equal(S.lib.io_remote.clock_id(), nil, "no draw clock")
  local grid_connects = connects
  S.lib.io_remote.rescan()
  assert_equal(connects, grid_connects, "a rescan with midi grid off calls no grid.connect")
  assert_equal(S.grids[5], nil, "nothing at the remote port")
  assert_equal(S.grids[6], nil, "nothing at the midigrid port")
  assert_equal(S.lib.io_remote.status("grid"), nil, "no grid status")
  assert_equal(remote_invariant(S), nil, "the invariant holds")
end)

test("a device on the grid port is asked for its hello and attached at its size", function()
  local context, S = started()
  set_rig(S, "remote_grid_port", 3)
  assert_equal(S.lib.io_remote.status("grid"), "[--]", "a set port with no device")
  assert_equal(S.lib.io_ports.owner(3), nil, "no device: the port is not claimed")
  local device = context.midi.plug(3, "iii grid")
  -- design §9.1: CC 2 = 0 on channel 1 asks for the hello
  assert_true(has(device.sent, cc_bytes(2, 0, 1)), "asked for the hello")
  assert_equal(S.lib.io_ports.owner(3), "remote grid", "claimed as remote grid")
  assert_equal(S.lib.io_remote.status("grid"), "no hello", "a device that has not said hello")
  local before = #device.sent
  hello(context, 3, 16, 8, 1)
  local grid_port = S.grids[S.constants.GRID_PORTS.remote]
  assert_true(grid_port ~= nil, "a virtual grid at port 5")
  assert_equal(grid_port.cols, 16); assert_equal(grid_port.rows, 8)
  assert_true(has(device.sent, cc_bytes(4, 0, 1), before + 1), "attaching sends CC 4 = 0")
  assert_equal(S.lib.io_remote.status("grid"), "16x8", "the status is its size")
  -- the 128h layout plays: a key reaches its step row
  local keys = {}
  local real_key = grid_key
  grid_key = function(port, x, y, z) table.insert(keys, port .. "," .. x .. "," .. y .. "," .. z); return real_key(port, x, y, z) end
  context.midi.send(3, { type = "note_on", note = 0, vel = 127, ch = 1 })
  context.midi.send(3, { type = "note_on", note = 0, vel = 0, ch = 1 })
  assert_equal(table.concat(keys, " "), "5,1,1,1 5,1,1,0", "the key reached grid_key on port 5")
  assert_equal(S.patterns[1][1], 15, "and the 128h layout set voice 1's step 1")
  -- the section shows it
  local shown = {}
  for _, row in ipairs(S.lib.pages_io.rows()) do
    if row.section == "remote" then shown[#shown + 1] = row.kind .. ":" .. tostring(row.key or row.label or row.shown) end
  end
  assert_equal(table.concat(shown, " "),
    "title:nil rig:remote_grid_port rig:remote_arc_port rig:midi_grid status:grid: 16x8 action:rescan",
    "the remote section's rows")
  assert_equal(remote_invariant(S), nil, "the invariant holds")
end)

test("a hello of another version or size attaches nothing", function()
  local context, S = started()
  set_rig(S, "remote_grid_port", 3)
  context.midi.plug(3, "iii grid")
  hello(context, 3, 16, 8, 2)
  assert_equal(S.grids[5], nil, "version 2: nothing attached")
  assert_equal(S.lib.io_remote.status("grid"), "version 2?", "and the status says so")
  hello(context, 3, 12, 6, 1)
  assert_equal(S.grids[5], nil, "12 by 6: nothing attached")
  assert_equal(S.lib.io_remote.status("grid"), "size 12x6?")
  hello(context, 3, 0, 4, 1)
  assert_equal(S.grids[5], nil, "an arc's hello on the grid port: nothing")
  assert_equal(S.lib.io_remote.clock_id(), nil, "and no draw clock")
  -- each of the four layout sizes attaches
  for _, size in ipairs(S.lib.io_remote.REMOTE.sizes) do
    hello(context, 3, size[1], size[2], 1)
    assert_equal(S.grids[5] and (S.grids[5].cols .. "x" .. S.grids[5].rows), size[1] .. "x" .. size[2], "attached")
  end
  -- a bad hello after a good one detaches
  hello(context, 3, 16, 8, 3)
  assert_equal(S.grids[5], nil, "version 3 detaches the grid")
  assert_equal(S.lib.io_remote.status("grid"), "version 3?")
  assert_equal(S.lib.io_remote.clock_id(), nil, "and the clock ends")
  local status
  for _, section in ipairs(S.registry.io_sections) do
    if section.name == "remote" then status = section.status() end
  end
  assert_equal(status, nil, "the title shows no [--] while the device is there")
end)

test("grid keys and LEDs use the protocol's numbers", function()
  local context, S = started()
  local device = remote_grid(context, S, 3, 16, 16)
  local keys = {}
  grid_key = function(port, x, y, z) table.insert(keys, port .. "," .. x .. "," .. y .. "," .. z) end
  -- in: index = (channel - 1) * 128 + note, x = index % 16 + 1, y = index // 16 + 1
  context.midi.send(3, { type = "note_on", note = 18, vel = 127, ch = 1 })
  context.midi.send(3, { type = "note_on", note = 18, vel = 0, ch = 1 })
  context.midi.send(3, { type = "note_off", note = 18, vel = 64, ch = 1 })
  context.midi.send(3, { type = "note_on", note = 127, vel = 127, ch = 2 })
  assert_equal(table.concat(keys, " "), "5,3,2,1 5,3,2,0 5,3,2,0 5,16,16,1", "the keys' places")
  settle(context, S, device)
  -- out: index = (y - 1) * 16 + (x - 1); note on, channel index // 128 + 1,
  -- note index % 128, velocity the level
  local grid_port = S.grids[5]
  grid_port:all(0); grid_port:refresh()
  settle(context, S, device)
  local before = #device.sent
  grid_port:led(3, 2, 9)
  grid_port:led(1, 9, 4)
  grid_port:refresh()
  tick(context, S)
  local sent = {}
  for index = before + 1, #device.sent do sent[#sent + 1] = text_of(device.sent[index]) end
  assert_equal(table.concat(sent, ", "), text_of(note_bytes(18, 9, 1)) .. ", " .. text_of(note_bytes(0, 4, 2))
    .. ", " .. text_of(cc_bytes(3, 0, 1)), "the two LEDs, then the frame end")
  -- a level above 15 is sent as 15; a cell off the grid is ignored
  before = #device.sent
  grid_port:led(3, 2, 20); grid_port:led(17, 1, 5); grid_port:led(0, 1, 5); grid_port:refresh()
  tick(context, S)
  assert_equal(text_of(device.sent[before + 1]), text_of(note_bytes(18, 15, 1)), "clamped to 15")
  assert_equal(#device.sent, before + 2, "and nothing for a cell off the grid")
end)

test("an arc's turns, key and LEDs use the protocol's numbers", function()
  local context, S = started()
  local turns, keys = {}, {}
  arc_delta = function(n, d) table.insert(turns, n .. "," .. d) end
  arc_key = function(n, z) table.insert(keys, n .. "," .. z) end
  local device = remote_arc(context, S, 4)
  assert_equal(S.lib.io_ports.owner(4), "remote arc", "claimed as remote arc")
  assert_true(S.arc_device ~= nil and S.arc_device.remote == "arc", "S.arc_device is the virtual arc")
  assert_equal(S.arc_connected, true, "and the arc is connected")
  assert_equal(S.lib.io_remote.status("arc"), "4 rings")
  -- in: CC 16 to 19 on channel 3, turned by value - 64; note 0 on channel 3
  context.midi.send(4, { type = "cc", cc = 17, val = 61, ch = 3 })
  context.midi.send(4, { type = "cc", cc = 16, val = 127, ch = 3 })
  context.midi.send(4, { type = "cc", cc = 19, val = 1, ch = 3 })
  context.midi.send(4, { type = "cc", cc = 20, val = 70, ch = 3 })
  context.midi.send(4, { type = "cc", cc = 17, val = 61, ch = 1 })
  assert_equal(table.concat(turns, " "), "2,-3 1,63 4,-63", "the turns, and nothing for CC 20 or channel 1")
  context.midi.send(4, { type = "note_on", note = 0, vel = 127, ch = 3 })
  context.midi.send(4, { type = "note_on", note = 0, vel = 0, ch = 3 })
  assert_equal(table.concat(keys, " "), "1,1 1,0", "the key down and up")
  -- out: index = (ring - 1) * 64 + (led - 1); note on, channel 3 + index // 128
  context.clock.run_for(0.2)
  local arc_port = S.arc_device
  arc_port:all(0); arc_port:refresh()
  settle(context, S, device)
  local before = #device.sent
  arc_port:led(2, 5, 15)
  arc_port:led(3, 1, 7)
  arc_port:refresh()
  tick(context, S)
  local sent = {}
  for index = before + 1, #device.sent do sent[#sent + 1] = text_of(device.sent[index]) end
  assert_equal(table.concat(sent, ", "), text_of(note_bytes(68, 15, 3)) .. ", " .. text_of(note_bytes(0, 7, 4))
    .. ", " .. text_of(cc_bytes(3, 0, 1)), "the two LEDs, then the frame end")
  assert_equal(remote_invariant(S), nil, "the invariant holds")
end)

test("a full redraw lands within four ticks at 96 a tick", function()
  local context, S = started()
  local device = remote_grid(context, S, 3, 16, 16)
  local grid_port = S.grids[5]
  grid_port:all(0); grid_port:refresh()
  settle(context, S, device)
  local model = {}
  for index = 0, 255 do model[index] = 0 end
  grid_port:all(7)
  grid_port:led(16, 16, 3)  -- index 255, the last: changed twice before its turn
  grid_port:refresh()
  local per_tick, last_cell = {}, {}
  for _ = 1, 3 do
    local before = #device.sent
    tick(context, S)
    local leds = 0
    for index = before + 1, #device.sent do
      local bytes = device.sent[index]
      if bytes[1] == 0x90 or bytes[1] == 0x91 then
        leds = leds + 1
        if bytes[1] == 0x91 and bytes[2] == 127 then table.insert(last_cell, bytes[3]) end
      end
    end
    per_tick[#per_tick + 1] = leds
    assert_equal(text_of(device.sent[#device.sent]), text_of(cc_bytes(3, 0, 1)), "each tick ends with the frame end")
    assert_equal(#device.sent - before, leds + 1, "and sends one frame end")
    apply_leds(model, device.sent, before + 1, 1)
  end
  assert_equal(table.concat(per_tick, " "), "96 96 64", "at most 96 LED messages a tick")
  for index = 0, 255 do
    assert_equal(model[index], index == 255 and 3 or 7, "after three ticks the device holds cell " .. index)
  end
  assert_equal(table.concat(last_cell, " "), "3", "a cell changed twice sends its newest level once")
  local before = #device.sent
  grid_port:led(5, 5, 7); grid_port:refresh()  -- unchanged
  tick(context, S)
  assert_equal(#device.sent, before, "a tick with no difference sends nothing at all")
  grid_port:led(5, 5, 2); grid_port:refresh()
  tick(context, S)
  assert_equal(#device.sent, before + 2, "one changed cell: one LED and the frame end")
  assert_true(not has(device.sent, note_bytes(0, 7, 1), before + 1), "an unchanged cell sends nothing")
end)

test("a virtual arc's segment lights what norns' arc lights", function()
  local context, S = started()
  local device = remote_arc(context, S, 4)
  local virtual = S.arc_device
  local monome = context.arc.plug(2)  -- takes over; the virtual arc still draws
  assert_true(S.arc_device ~= virtual, "the monome arc is followed")
  local tau = math.pi * 2
  local unpack_values = table.unpack or unpack
  local cases = { { 1, 0, math.pi / 2, 15 }, { 2, 3, 0.5, 9 },
    { 3, 0, tau - S.constants.UI_PAGES.ARC_FULL_TURN_MARGIN, 12 }, { 4, 1, 1.2, 5 } }
  virtual:all(0); virtual:refresh()
  settle(context, S, device)
  local before = #device.sent
  virtual:all(0)
  monome:all(0)
  for _, case in ipairs(cases) do
    virtual:segment(unpack_values(case))
    monome:segment(unpack_values(case))
  end
  virtual:refresh()
  local expected = {}  -- before a frame redraws the followed monome arc's rings
  for ring = 1, 4 do
    expected[ring] = {}
    for led = 1, 64 do expected[ring][led] = monome.rings[ring][led] end
  end
  settle(context, S, device)
  local model = {}
  for index = 0, 255 do model[index] = 0 end
  apply_leds(model, device.sent, before + 1, 3)
  for ring = 1, 4 do
    for led = 1, 64 do
      assert_equal(model[(ring - 1) * 64 + led - 1], expected[ring][led], "ring " .. ring .. " LED " .. led)
    end
  end
end)

test("a device that leaves is detached and one that returns is asked again", function()
  local context, S = started()
  local device = remote_grid(context, S, 3)
  assert_true(S.grids[5] ~= nil and S.lib.io_remote.clock_id() ~= nil, "attached, the clock running")
  local before = #device.sent
  context.midi.unplug(3)
  assert_equal(S.grids[5], nil, "detached")
  assert_equal(S.lib.io_ports.owner(3), nil, "the claim released")
  assert_equal(S.lib.io_remote.clock_id(), nil, "the clock ended")
  assert_equal(#device.sent, before, "nothing sent to a device that left")
  assert_equal(S.lib.io_remote.status("grid"), "[--]")
  assert_equal(remote_invariant(S), nil, "the invariant holds")
  local again = context.midi.plug(3, "iii grid")
  assert_true(has(again.sent, cc_bytes(2, 0, 1)), "the one that returns is asked for its hello")
  assert_equal(S.lib.io_ports.owner(3), "remote grid", "and its port claimed again")
  -- the port set to 0 detaches, clears the device and releases
  hello(context, 3, 16, 8, 1)
  assert_true(S.grids[5] ~= nil, "attached again")
  before = #again.sent
  set_rig(S, "remote_grid_port", 0)
  assert_equal(S.grids[5], nil, "port off: detached")
  assert_true(has(again.sent, cc_bytes(4, 0, 1), before + 1), "detaching sends CC 4 = 0")
  assert_equal(S.lib.io_ports.owner(3), nil, "released")
  assert_equal(midi.vports[3].event, nil, "and no longer listened to")
  -- a port another owner holds is in use
  S.lib.io_ports.claim(6, "someone")
  context.midi.plug(6, "iii grid")
  set_rig(S, "remote_grid_port", 6)
  assert_equal(S.lib.io_remote.status("grid"), "in use", "another owner holds the port")
  S.lib.io_ports.release(6, "someone")
  assert_equal(S.lib.io_ports.owner(6), "remote grid", "taken once it is free")
end)

test("a monome arc takes over from a remote one and hands back", function()
  local context, S = started()
  local turns = {}
  arc_delta = function(n, d) table.insert(turns, n .. "," .. d) end
  remote_arc(context, S, 4)
  local virtual = S.arc_device
  assert_equal(virtual.remote, "arc", "the remote arc is followed")
  context.arc.plug(1)
  assert_equal(S.arc_device, arc.vports[1], "a monome arc takes over")
  context.midi.send(4, { type = "cc", cc = 16, val = 65, ch = 3 })
  assert_equal(#turns, 0, "the remote arc's turns reach nothing meanwhile")
  context.arc.unplug(1)
  assert_equal(S.arc_device, virtual, "and hands back")
  context.midi.send(4, { type = "cc", cc = 16, val = 65, ch = 3 })
  assert_equal(table.concat(turns, " "), "1,1", "its turns reach arc_delta again")
  assert_equal(remote_invariant(S), nil, "the invariant holds")
  set_rig(S, "remote_arc_port", 0)
  assert_true(S.arc_device ~= virtual, "the port off: no longer followed")
  assert_equal(remote_invariant(S), nil, "the invariant still holds")
end)

-- A stand-in for the midigrid mod's object (checks.md §7): cols, rows, a
-- device, led, all and refresh, no rotation
local function midigrid_object(cols, rows)
  local object = { cols = cols, rows = rows, device = { id = 999, name = "midigrid" }, leds = {}, refreshes = 0 }
  function object:led(x, y, level) self.leds[x .. "," .. y] = level end
  function object:all() self.leds = {} end
  function object:refresh() self.refreshes = self.refreshes + 1 end
  return object
end

test("a grid from the midigrid mod attaches at its own port, and norns' own grid never does", function()
  local context, S = started()
  local connects, returned = 0, nil
  local real_connect = grid.connect
  -- Strata's own ports call it with their port (checks.md §7: under the
  -- mod every call loads a fresh copy); midigrid's call has no argument
  grid.connect = function(...)
    if select("#", ...) > 0 then return real_connect(...) end
    connects = connects + 1
    return returned
  end
  returned = midigrid_object(16, 8)
  set_rig(S, "midi_grid", "on")
  assert_equal(connects, 1, "turned on: one grid.connect")
  local first = returned
  assert_equal(S.grids[6], first, "attached at port 6")
  assert_true(next(first.leds) ~= nil and first.refreshes >= 1, "its layout plays")
  assert_equal(type(first.rotation), "function", "a missing rotation is given one")
  assert_equal(S.lib.io_remote.status("midigrid"), "16x8")
  returned = midigrid_object(16, 8)
  S.lib.io_remote.rescan()
  assert_equal(connects, 2, "a rescan: exactly one more grid.connect")
  assert_equal(first.key, nil, "the old object detached first")
  assert_equal(S.grids[6], returned, "and the new one attached")
  -- norns' own grid: nothing at port 6
  context.grid.plug(1, 16, 16)
  returned = grid.vports[1]
  S.lib.io_remote.rescan()
  assert_equal(S.grids[6], nil, "norns' own vport is never attached at port 6")
  assert_equal(S.lib.io_remote.status("midigrid"), "[--]")
  -- a table without the functions is refused
  returned = { cols = 16, rows = 8 }
  S.lib.io_remote.rescan()
  assert_equal(S.grids[6], nil, "a table without led, all and refresh")
  returned = midigrid_object(16, 8)
  S.lib.io_remote.rescan()
  local attached = returned
  assert_equal(S.grids[6], attached)
  assert_equal(remote_invariant(S), nil, "the invariant holds")
  set_rig(S, "midi_grid", "off")
  assert_equal(S.grids[6], nil, "midi grid off detaches it")
  assert_equal(attached.key, nil, "and clears its key")
  assert_equal(connects, 5, "and calls no grid.connect")
end)

test("the start step attaches what the rig names", function()
  local connects = 0
  local object = midigrid_object(16, 8)
  local device
  local context, S = started({
    before_load = function(context)
      device = context.midi.plug(3, "iii grid")
    end,
    before_init = function(context)
      local S = local_value("S")
      os.execute("mkdir -p '" .. context.data_dir .. "strata'")
      h.write_text(context.data_dir .. "strata/io.data", S.lib.data_files.encode({ version = 1,
        values = { remote_grid_port = 3, midi_grid = "on" } }))
      local real = grid.connect
      -- Strata's own ports call it with their port; midigrid's call has none
      grid.connect = function(...)
        if select("#", ...) > 0 then return real(...) end
        connects = connects + 1
        return object
      end
    end,
  })
  assert_equal(connects, 1, "the start step: one grid.connect with no argument")
  assert_equal(S.grids[6], object, "the midigrid attached")
  assert_true(has(device.sent, cc_bytes(2, 0, 1)), "the grid port's device asked for its hello")
  assert_equal(S.lib.io_ports.owner(3), "remote grid")
end)

test("cleanup ends the clock, clears each device and releases everything", function()
  local context, S = started()
  local grid_device = remote_grid(context, S, 3)
  local arc_device = remote_arc(context, S, 4)
  local object = midigrid_object(16, 8)
  grid.connect = function() return object end
  set_rig(S, "midi_grid", "on")
  local grid_before, arc_before = #grid_device.sent, #arc_device.sent
  cleanup()
  assert_equal(S.lib.io_remote.clock_id(), nil, "the clock ended")
  assert_true(has(grid_device.sent, cc_bytes(4, 0, 1), grid_before + 1), "the grid cleared")
  assert_true(has(arc_device.sent, cc_bytes(4, 0, 1), arc_before + 1), "the arc cleared")
  assert_equal(S.grids[5], nil); assert_equal(S.grids[6], nil)
  assert_true(S.arc_device == nil or S.arc_device.remote == nil, "the virtual arc unfollowed")
  assert_equal(S.lib.io_ports.owner(3), nil); assert_equal(S.lib.io_ports.owner(4), nil)
  assert_equal(object.key, nil, "the midigrid detached")
end)

test("the scripts and the module agree end to end", function()
  local context, S = started()
  local iii = require("stub_iii")
  -- the grid script on a 16 by 16 grid: its start hello goes nowhere yet
  local grid_device = iii({ kind = "grid" })
  grid_device.run(GRID_SCRIPT)
  grid_device.connect(context, 3)
  set_rig(S, "remote_grid_port", 3)
  assert_equal(S.grids[5] and S.grids[5].cols .. "x" .. S.grids[5].rows, "16x16", "attached at its size")
  local keys = {}
  local real_key = grid_key
  grid_key = function(port, x, y, z) table.insert(keys, port .. "," .. x .. "," .. y .. "," .. z); return real_key(port, x, y, z) end
  grid_device.press(3, 2, 1); grid_device.press(3, 2, 0)
  assert_equal(table.concat(keys, " "), "5,3,2,1 5,3,2,0", "a press reaches the layout's key")
  local before = #grid_device.sent
  grid_device.press(16, 16, 1); grid_device.press(16, 16, 0)
  assert_equal(text_of(grid_device.sent[before + 1]), text_of(note_bytes(127, 127, 2)), "x 16, y 16: note 127, channel 2")
  assert_equal(text_of(grid_device.sent[before + 2]), text_of(note_bytes(127, 0, 2)), "up: velocity 0")
  context.clock.run_for(0.2)
  S.grids[5]:led(5, 7, 11); S.grids[5]:refresh()
  for _ = 1, 4 do tick(context, S) end
  assert_equal(grid_device.leds[7][5], 11, "a cell Strata lights is lit after the frame end")
  -- the arc script: a turn of 100 is two messages, 63 and 37
  local turns, presses = {}, {}
  arc_delta = function(n, d) table.insert(turns, n .. "," .. d) end
  arc_key = function(n, z) table.insert(presses, n .. "," .. z) end
  local arc_device = iii({ kind = "arc" })
  arc_device.run(ARC_SCRIPT)
  arc_device.connect(context, 4)
  set_rig(S, "remote_arc_port", 4)
  assert_equal(S.arc_device and S.arc_device.remote, "arc", "the arc followed")
  before = #arc_device.sent
  arc_device.turn(2, 100)
  assert_equal(#arc_device.sent - before, 2, "two messages")
  assert_equal(text_of(arc_device.sent[before + 1]), text_of(cc_bytes(17, 64 + 63, 3)))
  assert_equal(text_of(arc_device.sent[before + 2]), text_of(cc_bytes(17, 64 + 37, 3)))
  arc_device.turn(1, -3)
  assert_equal(table.concat(turns, " "), "2,63 2,37 1,-3", "the turns as arc_delta")
  arc_device.arc_press(1); arc_device.arc_press(0)
  assert_equal(table.concat(presses, " "), "1,1 1,0", "the key")
  context.clock.run_for(0.2)
  S.arc_device:led(2, 5, 13); S.arc_device:refresh()
  for _ = 1, 4 do tick(context, S) end
  assert_equal(arc_device.leds[2][5], 13, "an LED Strata lights is lit after the frame end")
  -- CC 4 sets every LED
  set_rig(S, "remote_arc_port", 0)
  for led = 1, 64 do assert_equal(arc_device.leds[2][led], 0, "detached: every LED 0") end
end)

test("a device script on firmware older than 1.1.0 shows its pattern and forwards nothing", function()
  local context, S = started()
  local iii = require("stub_iii")
  for _, case in ipairs({ { kind = "grid", script = GRID_SCRIPT, port = 3, key = "remote_grid_port" },
    { kind = "arc", script = ARC_SCRIPT, port = 4, key = "remote_arc_port" } }) do
    local old = iii({ kind = case.kind, version = "v1.0.0" })
    old.run(case.script)
    local lit = 0
    for _, row in ipairs(old.leds) do for _, level in ipairs(row) do if level > 0 then lit = lit + 1 end end end
    assert_true(lit > 0 and old.refreshes >= 1, case.kind .. ": the fixed pattern shows")
    assert_equal(#old.sent, 0, case.kind .. ": no hello")
    old.connect(context, case.port)
    set_rig(S, case.key, case.port)
    assert_equal(#old.sent, 0, case.kind .. ": asked, still no hello")
    assert_equal(S.lib.io_remote.status(case.kind), "no hello", case.kind .. ": nothing attached")
    if case.kind == "grid" then old.press(1, 1, 1) else old.turn(1, 5) end
    assert_equal(#old.sent, 0, case.kind .. ": nothing forwarded")
    local current = iii({ kind = case.kind, version = "v1.1.2" })
    current.run(case.script)
    local cols = case.kind == "grid" and 16 or 0
    local rows = case.kind == "grid" and 16 or 4
    assert_equal(text_of(current.sent[1] or {}) .. " | " .. text_of(current.sent[2] or {}) .. " | "
      .. text_of(current.sent[3] or {}), text_of(cc_bytes(0, cols, 1)) .. " | " .. text_of(cc_bytes(1, rows, 1))
      .. " | " .. text_of(cc_bytes(2, 1, 1)), case.kind .. " on 1.1.2: the hello")
  end
end)

end

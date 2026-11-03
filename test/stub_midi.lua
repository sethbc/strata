-- stub_midi.lua
-- Stand-in for norns' lua/core/midi.lua: 16 vports (name "none", no device
-- until one is plugged), midi.connect/add/remove/devices, and to_data/to_msg
-- with the same byte layout and message tables as norns. norns writes these
-- with Lua 5.3 bitwise operators; the stub uses arithmetic so LuaJIT runs it.
-- Test helpers: midi.plug(port, name), midi.unplug(port) and
-- midi.send(port, msg), which delivers msg as data bytes the way
-- _norns.midi.event does (device.event, then the vport's event).

local NUM_PORTS = 16

local function status_and_channel(byte)
  local high = math.floor(byte / 16) * 16
  return high, byte - high + 1
end

local to_data = {
  note_on = function(msg) return {0x90 + (msg.ch or 1) - 1, msg.note, msg.vel or 100} end,
  note_off = function(msg) return {0x80 + (msg.ch or 1) - 1, msg.note, msg.vel or 100} end,
  cc = function(msg) return {0xb0 + (msg.ch or 1) - 1, msg.cc, msg.val} end,
  pitchbend = function(msg)
    return {0xe0 + (msg.ch or 1) - 1, msg.val % 128, math.floor(msg.val / 128) % 128}
  end,
  key_pressure = function(msg) return {0xa0 + (msg.ch or 1) - 1, msg.note, msg.val} end,
  channel_pressure = function(msg) return {0xd0 + (msg.ch or 1) - 1, msg.val} end,
  program_change = function(msg) return {0xc0 + (msg.ch or 1) - 1, msg.val} end,
  start = function() return {0xfa} end,
  stop = function() return {0xfc} end,
  continue = function() return {0xfb} end,
  clock = function() return {0xf8} end,
  song_position = function(msg) return {0xf2, msg.lsb, msg.msb} end,
  song_select = function(msg) return {0xf3, msg.val} end,
}

local message_args = {
  note_on = {"note", "vel", "ch"}, note_off = {"note", "vel", "ch"}, cc = {"cc", "val", "ch"},
  pitchbend = {"val", "ch"}, key_pressure = {"note", "val", "ch"}, channel_pressure = {"val", "ch"},
  program_change = {"val", "ch"}, start = {}, stop = {}, continue = {}, clock = {},
  song_position = {"lsb", "msb"}, song_select = {"val"},
}

return function()
  local midi = { vports = {}, devices = {}, next_id = 1 }

  local function wrap_method(method)
    return function(self, ...)
      if self.device then self.device[method](self.device, ...) end
    end
  end

  for port = 1, NUM_PORTS do
    midi.vports[port] = {
      name = "none", device = nil, connected = false, event = nil,
      send = function(self, ...) if self.device then self.device:send(...) end end,
      note_on = wrap_method("note_on"), note_off = wrap_method("note_off"), cc = wrap_method("cc"),
      pitchbend = wrap_method("pitchbend"), key_pressure = wrap_method("key_pressure"),
      channel_pressure = wrap_method("channel_pressure"), program_change = wrap_method("program_change"),
      start = wrap_method("start"), stop = wrap_method("stop"), continue = wrap_method("continue"),
      clock = wrap_method("clock"),
    }
  end

  function midi.connect(port) return midi.vports[port or 1] end
  function midi.add(device) end
  function midi.remove(device) end

  function midi.to_data(msg)
    if msg.type then return to_data[msg.type](msg) end
    error("failed to serialize midi message")
  end

  function midi.to_msg(data)
    local status, channel = status_and_channel(data[1])
    if status == 0x90 then
      local msg = { note = data[2], vel = data[3], ch = channel }
      if data[3] > 0 then msg.type = "note_on" elseif data[3] == 0 then msg.type = "note_off" end
      return msg
    elseif status == 0x80 then
      return { type = "note_off", note = data[2], vel = data[3], ch = channel }
    elseif status == 0xb0 then
      return { type = "cc", cc = data[2], val = data[3], ch = channel }
    elseif status == 0xe0 then
      return { type = "pitchbend", val = data[2] + data[3] * 128, ch = channel }
    elseif status == 0xa0 then
      return { type = "key_pressure", note = data[2], val = data[3], ch = channel }
    elseif status == 0xd0 then
      return { type = "channel_pressure", val = data[2], ch = channel }
    elseif status == 0xc0 then
      return { type = "program_change", val = data[2], ch = channel }
    elseif data[1] == 0xfa then return { type = "start" }
    elseif data[1] == 0xfc then return { type = "stop" }
    elseif data[1] == 0xfb then return { type = "continue" }
    elseif data[1] == 0xf8 then return { type = "clock" }
    elseif data[1] == 0xf2 then return { type = "song_position", lsb = data[2], msb = data[3] }
    elseif data[1] == 0xf3 then return { type = "song_select", val = data[2] }
    elseif data[1] == 0xfe then return {}
    elseif data[1] == 0xf0 then return { type = "sysex", raw = data }
    end
    return { type = "other", raw = data }
  end

  -- test helper: plug a device into a port (norns: _norns.midi.add + update_devices)
  function midi.plug(port, name)
    local device = { id = midi.next_id, name = name or "stub midi", port = port, event = nil, sent = {} }
    midi.next_id = midi.next_id + 1
    function device:send(data)
      table.insert(self.sent, data.type and midi.to_data(data) or data)
    end
    -- the device send methods of lua/core/midi.lua, positional args as there
    for message_type, arg_names in pairs(message_args) do
      device[message_type] = function(self, ...)
        local msg = { type = message_type }
        for index, arg_name in ipairs(arg_names) do msg[arg_name] = (select(index, ...)) end
        self:send(msg)
      end
    end
    midi.devices[device.id] = device
    local vport = midi.vports[port]
    vport.name = device.name
    vport.device = device
    vport.connected = true
    if midi.add then midi.add(device) end
    return device
  end

  function midi.unplug(port)
    local vport = midi.vports[port]
    local device = vport.device
    if not device then return end
    if midi.remove then midi.remove(device) end
    midi.devices[device.id] = nil
    vport.device = nil
    vport.connected = false
  end

  -- test helper: deliver msg from the device on `port`, plugging one if needed
  function midi.send(port, msg)
    local device = midi.vports[port].device or midi.plug(port)
    local data = midi.to_data(msg)
    if device.event then device.event(data) end
    if midi.vports[device.port].event then midi.vports[device.port].event(data) end
  end

  return midi
end

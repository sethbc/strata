-- stub_iii.lua
-- Stand-in for a monome iii device (grid or arc) running a Lua script, from
-- docs/design/3.6-facts/iii-osc-nb-softcut.md section 1b.
-- require("stub_iii")({kind = "grid" | "arc", cols, rows, version, firmware})
-- returns a device. device.run(path) runs a script with iii's globals as its
-- environment (grid_led, grid_led_all, grid_refresh, grid_size_x,
-- grid_size_y, arc_led, arc_led_ring, arc_led_all, arc_refresh, midi_note_on,
-- midi_note_off, midi_cc, midi_out, midi_tx, device_version, iii_version,
-- metro, get_time, and its own copies of math, string and table; no global
-- unpack). Events: device.press(x, y, z), turn(n, d), arc_press(z) and
-- midi_in(b1, b2, b3) call the script's event_grid, event_arc,
-- event_arc_key (one argument) and event_midi. Records: sent (each
-- {b1, b2, b3}, what the script sent as USB MIDI), leds (as last
-- refreshed: leds[y][x] on a grid, leds[ring][x] on an arc, levels 0-15),
-- refreshes, metros (by id). device.fire_metro(id)
-- calls a running metro's callback with the number of its firing.
-- midi_out takes a table of bytes, sent three at a time as midi_tx_many
-- does; a message table raises "not modeled". m.free(m.id) and
-- metro.free_all() free metros.
-- device_version() returns the firmware's date tag (option firmware,
-- default "v260324"); it exists from iii v1.1.0. iii_version is iii's own
-- version (option version, default "v1.1.2"), present from v1.1.1.
-- device.connect(context, port) plugs a MIDI device named "iii grid" or
-- "iii arc", the USB name norns lists, at port: every message Strata sends there reaches midi_in, and every
-- message the script sends reaches the device's current port as incoming
-- data (the stub reads the device's port at each message, so a reassign
-- moves it, and an unplug ends it).
-- midi_to_msg, grid_led_get, grid_intensity, arc_intensity, arc_res, clamp,
-- round, linlin and wrap are there too; the facts file gives the first
-- two's behavior in part and the rest as names with arguments, so
-- grid_led_get reads the level last set (queued or refreshed), the
-- intensities and arc_res (kept per ring in device.arc_resolution, default
-- 1) are recorded in device.calls, and the helpers have norns' util
-- meanings (wrap is inclusive) and are recorded too. m.free_all() is on a
-- metro object as well as on metro; iii allows 15 metros at once and a
-- sixteenth metro.init returns nil; a freed id is handed out again (the
-- lowest free one). The script's libraries are built from Lua 5.3's names
-- (see LIBRARY_NAMES); string methods called on a string value
-- ("x"):upper() use the host's string library, not the script's copy, and
-- getmetatable of a string raises "not modeled". The version option is read
-- by its leading v<major>.<minor>.<patch>, so v1.1.0b1 is 1.1.0; below
-- 1.1.0 the event_* callbacks are never called.
-- Defaults of lib.lua: channel 1, note 66, velocity 100, cc 1, value 100.
-- Chosen here, as the sources leave them open or give a choice: a grid is
-- 16 x 16 and an arc has 4 rings of 64 (a test passes cols and rows for a
-- 16 x 8 grid); LED levels clamp to 0-15; a metro's callback gets the
-- number of its firing.

local KEPT_GLOBALS = { "pairs", "ipairs", "next", "select", "type", "tostring",
  "tonumber", "print", "pcall", "error", "assert", "setmetatable", "getmetatable", "rawget", "rawset" }

-- a script gets its own copy of each library, built from the names Lua 5.3
-- has (never from the host's whole table, which under LuaJIT also holds
-- table.getn, math.pow and the like), so it cannot change the host's
-- either. iii runs Lua 5.3 or later: table.unpack, no global unpack.
-- Names the host lacks (LuaJIT has no string.pack, string.unpack,
-- string.packsize, math.type, math.tointeger, math.ult, math.maxinteger or
-- math.mininteger) are absent here too; table.pack and table.move are
-- supplied
local LIBRARY_NAMES = {
  table = { "concat", "insert", "move", "pack", "remove", "sort", "unpack" },
  string = { "byte", "char", "dump", "find", "format", "gmatch", "gsub", "len", "lower", "match", "pack",
    "packsize", "rep", "reverse", "sub", "unpack", "upper" },
  math = { "abs", "acos", "asin", "atan", "ceil", "cos", "deg", "exp", "floor", "fmod", "huge", "log", "max",
    "maxinteger", "min", "mininteger", "modf", "pi", "rad", "random", "randomseed", "sin", "sqrt", "tan",
    "tointeger", "type", "ult" },
}

local function copy_library(library, names)
  local copy = {}
  for _, name in ipairs(names) do copy[name] = library[name] end
  return copy
end

local function table_pack(...)
  local packed = { ... }
  packed.n = select("#", ...)
  return packed
end

-- Lua 5.3's table.move
local function table_move(source, first, last, target, destination)
  destination = destination or source
  if last >= first then
    if target > last or target <= first or destination ~= source then
      for offset = 0, last - first do destination[target + offset] = source[first + offset] end
    else
      for offset = last - first, 0, -1 do destination[target + offset] = source[first + offset] end
    end
  end
  return destination
end

local MAX_METROS = 15

-- the leading "v1.1.2" of a tag such as "v1.1.2" or "v1.1.0b1" -> a number
local function parse_version(text)
  local major, minor, patch = tostring(text):match("^v(%d+)%.(%d+)%.(%d+)")
  if not major then
    error("stub_iii: version must start with v<major>.<minor>.<patch> (v1.1.2, v1.1.0b1), not " .. tostring(text), 3)
  end
  return tonumber(major) * 1000000 + tonumber(minor) * 1000 + tonumber(patch)
end

local function whole_byte(value)
  return math.floor(value) % 256
end

return function(options)
  options = options or {}
  local kind = options.kind or "grid"
  local cols = options.cols or (kind == "grid" and 16 or 64)
  local rows = options.rows or (kind == "grid" and 16 or 4)
  local device = { kind = kind, sent = {}, refreshes = 0, metros = {}, time = 0 }
  local env
  local connection
  device.calls = {}
  device.arc_resolution = {}
  local function record(name, ...) table.insert(device.calls, { name, ... }) end

  local function blank_leds()
    local leds = {}
    for row = 1, rows do
      leds[row] = {}
      for column = 1, cols do leds[row][column] = 0 end
    end
    return leds
  end
  device.leds = blank_leds()
  local pending = blank_leds()

  local function level(z, rel, current)
    local value = rel and (current + z) or z
    return math.max(0, math.min(15, math.floor(value)))
  end

  local function set_led(row, column, z, rel)
    if pending[row] and pending[row][column] then pending[row][column] = level(z, rel, pending[row][column]) end
  end

  local function refresh()
    local copy = {}
    for row = 1, rows do copy[row] = {}; for column = 1, cols do copy[row][column] = pending[row][column] end end
    device.leds = copy
    device.refreshes = device.refreshes + 1
  end

  local function midi_tx(b1, b2, b3)
    local data = { b1 and whole_byte(b1), b2 and whole_byte(b2), b3 and whole_byte(b3) }
    table.insert(device.sent, data)
    -- the connection follows the MIDI device's own port (reassign moves it)
    -- and ends when the device is unplugged
    local midi_device = connection and connection.midi_device
    if midi_device and connection.context.midi.devices[midi_device.id] == midi_device and midi_device.port then
      if midi_device.event then midi_device.event(data) end
      local vport = connection.context.midi.vports[midi_device.port]
      if vport.event then vport.event(data) end
    end
  end

  local function status_message(base, a, b, ch, default_a, default_b)
    midi_tx(base + (ch or 1) - 1, a or default_a, b or default_b)
  end

  env = {
    grid_led = function(x, y, z, rel) set_led(y, x, z, rel) end,
    grid_led_all = function(z, rel)
      for row = 1, rows do for column = 1, cols do set_led(row, column, z, rel) end end
    end,
    grid_refresh = refresh,
    grid_size_x = function() return cols end,
    grid_size_y = function() return rows end,
    arc_led = function(n, x, z, rel) set_led(n, x, z, rel) end,
    arc_led_ring = function(n, z, rel) for column = 1, cols do set_led(n, column, z, rel) end end,
    arc_led_all = function(z, rel)
      for row = 1, rows do for column = 1, cols do set_led(row, column, z, rel) end end
    end,
    arc_refresh = refresh,
    midi_note_on = function(note, vel, ch) status_message(0x90, note, vel, ch, 66, 100) end,
    midi_note_off = function(note, vel, ch) status_message(0x80, note, vel, ch, 66, 100) end,
    midi_cc = function(cc, val, ch) status_message(0xb0, cc, val, ch, 1, 100) end,
    midi_tx = midi_tx,
    -- a table of raw bytes, sent three at a time as midi_tx_many does (the
    -- last call gets nil arguments when the length is not a multiple of 3)
    midi_out = function(data)
      if type(data) ~= "table" or data.type ~= nil or (data[1] ~= nil and type(data[1]) ~= "number") then
        error("midi_out with a message table is not modeled by the iii stub; give it a table of bytes", 2)
      end
      for index = 1, #data, 3 do midi_tx(data[index], data[index + 1], data[index + 2]) end
    end,
    get_time = function() return device.time end,
    -- midi_to_msg: the note_off rule for velocity 0 and the sysex table are
    -- the facts file's; the other fields follow norns' midi.to_msg
    midi_to_msg = function(data)
      local status = math.floor(data[1] / 16) * 16
      local channel = data[1] - status + 1
      if status == 0x90 then
        return { type = data[3] > 0 and "note_on" or "note_off", note = data[2], vel = data[3], ch = channel }
      elseif status == 0x80 then return { type = "note_off", note = data[2], vel = data[3], ch = channel }
      elseif status == 0xb0 then return { type = "cc", cc = data[2], val = data[3], ch = channel }
      elseif status == 0xe0 then return { type = "pitchbend", val = data[2] + data[3] * 128, ch = channel }
      elseif data[1] == 0xf0 then return { type = "sysex", raw = data }
      end
      return { type = "other", raw = data }
    end,
    -- the level last set, queued or refreshed
    grid_led_get = function(x, y) return pending[y] and pending[y][x] or 0 end,
    -- named in the facts file with arguments only: recorded in device.calls
    grid_intensity = function(b) record("grid_intensity", b) end,
    arc_intensity = function(b) record("arc_intensity", b) end,
    arc_res = function(n, div) record("arc_res", n, div); device.arc_resolution[n] = div end,
    -- helpers named in the facts file: the usual meanings (norns' util.clamp,
    -- util.round, util.linlin, util.wrap), recorded in device.calls
    clamp = function(n, low, high) record("clamp", n, low, high); return math.min(math.max(n, low), high) end,
    round = function(n, quantum)
      record("round", n, quantum)
      quantum = quantum or 1
      return math.floor(n / quantum + 0.5) * quantum
    end,
    linlin = function(n, slo, shi, dlo, dhi)
      record("linlin", n, slo, shi, dlo, dhi)
      return dlo + (n - slo) * (dhi - dlo) / (shi - slo)
    end,
    wrap = function(n, low, high)
      record("wrap", n, low, high)
      return low + (n - low) % (high - low + 1)
    end,
    metro = {
      init = function(callback, time, count)
        local id
        for candidate = 1, MAX_METROS do
          if not device.metros[candidate] then id = candidate; break end
        end
        if not id then return nil end
        local metro = { callback = callback, time = time, count = count, id = id, fired = 0 }
        function metro.start(self, new_time) if new_time then self.time = new_time end; self.running = true end
        function metro.stop(self) self.running = false end
        -- m.free(m.id), as the docs call it
        metro.free = function(id) device.metros[id] = nil end
        metro.free_all = function() device.metros = {} end
        device.metros[metro.id] = metro
        return metro
      end,
      free_all = function() device.metros = {} end,
    },
  }
  for _, name in ipairs(KEPT_GLOBALS) do env[name] = _G[name] end
  env.math = copy_library(math, LIBRARY_NAMES.math)
  env.string = copy_library(string, LIBRARY_NAMES.string)
  env.table = copy_library(table, LIBRARY_NAMES.table)
  env.table.unpack = env.table.unpack or rawget(_G, "unpack")
  env.table.pack = env.table.pack or table_pack
  env.table.move = env.table.move or table_move
  -- a string's metatable is the host's string library: not modeled
  env.getmetatable = function(value)
    if type(value) == "string" then error("getmetatable of a string is not modeled by the iii stub", 2) end
    return getmetatable(value)
  end
  -- device_version() is new in 1.1.0 and returns the firmware's date tag;
  -- iii_version, iii's own version, exists from 1.1.1
  local version = parse_version(options.version or "v1.1.2")
  if version >= parse_version("v1.1.0") then
    env.device_version = function() return options.firmware or "v260324" end
  end
  if version >= parse_version("v1.1.1") then env.iii_version = options.version or "v1.1.2" end

  -- calls a running metro's callback with the number of its firing, as the
  -- device's timer would; stops it after `count` firings when it has one
  function device.fire_metro(id)
    local metro = device.metros[id]
    if not metro then error("stub_iii: no metro " .. tostring(id), 2) end
    if not metro.running then error("stub_iii: metro " .. tostring(id) .. " is not running", 2) end
    metro.fired = metro.fired + 1
    if metro.count and metro.count > 0 and metro.fired >= metro.count then metro.running = false end
    metro.callback(metro.fired)
  end

  function device.run(path)
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    local chunk, err
    if setfenv then
      chunk, err = loadstring(text, "@" .. path)
      if chunk then setfenv(chunk, env) end
    else
      chunk, err = load(text, "@" .. path, "t", env)
    end
    if not chunk then error(err) end
    chunk()
    return env
  end

  -- event_grid, event_arc, event_arc_key and event_midi are new in iii 1.1.0
  local has_events = version >= parse_version("v1.1.0")
  local function call(name, ...)
    if not has_events then return end
    local handler = env[name]
    if handler then return handler(...) end
  end

  function device.press(x, y, z) call("event_grid", x, y, z) end
  function device.turn(n, d) call("event_arc", n, d) end
  function device.arc_press(z) call("event_arc_key", z) end
  function device.midi_in(b1, b2, b3) call("event_midi", b1, b2, b3) end

  function device.connect(context, port)
    local midi_device = context.midi.plug(port, "iii " .. kind)
    connection = { context = context, midi_device = midi_device }
    -- every message Strata sends through the port reaches the script
    function midi_device.send(self, data)
      local midi = context.midi
      local bytes = data.type and midi.to_data(data) or data
      table.insert(self.sent, bytes)
      device.midi_in(bytes[1], bytes[2], bytes[3])
    end
    return midi_device
  end

  return device
end

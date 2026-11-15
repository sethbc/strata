-- stub_iii.lua
-- Stand-in for a monome iii device (grid or arc) running a Lua script, from
-- docs/design/3.6-facts/iii-osc-nb-softcut.md section 1b.
-- require("stub_iii")({kind = "grid" | "arc", cols, rows, version}) returns
-- a device. device.run(path) runs a script with iii's globals as its
-- environment (grid_led, grid_led_all, grid_refresh, grid_size_x,
-- grid_size_y, arc_led, arc_led_ring, arc_led_all, arc_refresh, midi_note_on,
-- midi_note_off, midi_cc, midi_out, midi_tx, device_version, metro,
-- get_time, and Lua's standard tables). Events: device.press(x, y, z),
-- turn(n, d), arc_press(z) and midi_in(b1, b2, b3) call the script's
-- event_grid, event_arc, event_arc_key (one argument, as iii's changelog
-- gives it) and event_midi. Records: sent (each {b1, b2, b3}, what the
-- script sent as USB MIDI), leds (as last refreshed: leds[y][x] on a grid,
-- leds[ring][x] on an arc, levels 0-15), refreshes, metros.
-- device.connect(context, port) plugs a MIDI device at port: every message
-- Strata sends there reaches midi_in, and every message the script sends
-- reaches the port's device and vport events as incoming data.
-- Defaults of lib.lua: channel 1, note 66, velocity 100, cc 1, value 100.
-- Unknown to the sources, so chosen here: LED levels clamp to 0-15 (as the
-- grid stub), a grid is 16 x 16, an arc has 4 rings of 64, device_version
-- returns version (default "1.1.2").

local KEPT_GLOBALS = { "math", "string", "table", "pairs", "ipairs", "next", "select", "type", "tostring",
  "tonumber", "print", "pcall", "error", "assert", "unpack", "setmetatable", "getmetatable", "rawget", "rawset" }

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
    if connection then
      local midi_device = connection.midi_device
      if midi_device.event then midi_device.event(data) end
      local vport = connection.context.midi.vports[connection.port]
      if vport.event then vport.event(data) end
    end
  end

  local function status_message(base, a, b, ch, default_a, default_b)
    midi_tx(base + (ch or 1) - 1, a or default_a, b or default_b)
  end

  local message_bases = { note_on = 0x90, note_off = 0x80, cc = 0xb0 }

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
    midi_out = function(data)
      if data.type then
        local base = message_bases[data.type]
        if not base then error("midi_out: unsupported message type " .. tostring(data.type)) end
        local a, b
        if data.type == "cc" then a, b = data.cc, data.val else a, b = data.note, data.vel end
        status_message(base, a, b, data.ch, 66, 100)
      else
        for index = 1, #data, 3 do midi_tx(data[index], data[index + 1], data[index + 2]) end
      end
    end,
    device_version = function() return options.version or "1.1.2" end,
    get_time = function() return device.time end,
    metro = {
      init = function(callback, time, count)
        local metro = { callback = callback, time = time, count = count, id = #device.metros + 1 }
        function metro.start(self, new_time) if new_time then self.time = new_time end; self.running = true end
        function metro.stop(self) self.running = false end
        table.insert(device.metros, metro)
        return metro
      end,
      free = function(id) device.metros[id] = nil end,
      free_all = function() device.metros = {} end,
    },
  }
  for _, name in ipairs(KEPT_GLOBALS) do env[name] = _G[name] end
  env.unpack = rawget(_G, "unpack") or rawget(table, "unpack")

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

  local function call(name, ...)
    local handler = env[name]
    if handler then return handler(...) end
  end

  function device.press(x, y, z) call("event_grid", x, y, z) end
  function device.turn(n, d) call("event_arc", n, d) end
  function device.arc_press(z) call("event_arc_key", z) end
  function device.midi_in(b1, b2, b3) call("event_midi", b1, b2, b3) end

  function device.connect(context, port)
    local midi_device = context.midi.plug(port, "iii " .. kind)
    connection = { context = context, port = port, midi_device = midi_device }
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

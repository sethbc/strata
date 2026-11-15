-- lib/io/controllers.lua
-- The controllers (S.lib.io_controllers, 3.6 design section 8): an OXI E16
-- (relative encoders, one per macro, with an echo of each macro as a CC, a
-- SysEx frame for its rings, labels and a title) and a box of sixteen faders
-- (absolute, 7 or 14 bits, with pickup) on the sixteen macros, whatever bank
-- is shown. Their ports and CCs are rig settings, read live through
-- S.lib.io_rig; ports are taken and listened to only through S.lib.io_ports.
-- The E16's script that draws the frames is extras/e16/strata.lua.
-- Notes: docs/notes/lua/io/controllers.md

return function(S)
  local M = {}

  local NUM_MACROS = S.constants.NUM_MACROS

  -- echo_per_tick: the most CCs one tick sends; echo_hz: the clock's rate;
  -- pickup_window: how near a fader must come to a macro's value to take it
  -- (a crossing takes it too); echo_guard_seconds: how long a CC the E16
  -- sends back is taken for the echo of the one Strata sent; header: the
  -- four bytes every frame to or from the E16's script starts with after
  -- F0 (a manufacturer byte of 0x7D, the educational one, then "ST")
  local CONTROLLERS = {echo_per_tick = 16, echo_hz = 15, pickup_window = 2 / 127, echo_guard_seconds = 0.1,
    header = {0xF0, 0x7D, 0x53, 0x54}}
  M.CONTROLLERS = CONTROLLERS

  -- The frames' command byte, and the room of a label and a rig value
  local FRAME = {rings = 0x01, label = 0x02, title = 0x03, label_chars = 4, ring_max = 16383, cc_max = 127,
    sysex_end = 0xF7, title_text = "STRATA", hires_offset = 32, pickup_epsilon = 1e-6}

  -- The eight settings the section shows, in order
  local SETTINGS = {"e16_port", "e16_channel", "e16_cc", "e16_encoding", "faders_port", "faders_channel", "faders_cc",
    "faders_hires"}

  local ports = S.lib.io_ports

  local held = {}       -- kind ("e16", "faders") -> the port it holds and listens on
  local echo = {last = {}, labels = {}, sent = {}}  -- the E16's: last values echoed, last labels sent, CCs sent
  local faders = {}     -- m -> {high, low, previous, picked, last_set}
  local clock_id = nil
  local tick_errors = {}
  local last_strip = nil
  local preview = nil   -- a layout state's stand-in for the rig's ports, devices, marks and clash

  local function setting(key) return S.lib.io_rig.get(key) end

  local function macro_param(m) return "macro_" .. m end

  local function round(value) return math.floor(value + 0.5) end

  local function clamp01(value) return math.max(0, math.min(1, value)) end

  local function configured_port(kind)
    if preview and preview[kind .. "_port"] ~= nil then return preview[kind .. "_port"] end
    return setting(kind .. "_port")
  end

  local function device_present(port)
    if preview and preview.devices then return preview.devices[port] == true end
    return ports.device(port) ~= nil
  end

  ---------------------------------------------------------------------------
  -- Sending to the E16
  ---------------------------------------------------------------------------

  -- Raw bytes to the E16's port, only while a device is on it
  local function send_bytes(bytes)
    local port = held.e16
    if not port or not device_present(port) then return end
    local vport = ports.out(port)
    if vport then vport:send(bytes) end
  end

  local function frame_start(command)
    local bytes = {}
    for index, byte in ipairs(CONTROLLERS.header) do bytes[index] = byte end
    bytes[#bytes + 1] = command
    return bytes
  end

  -- F0 7D 53 54 01, sixteen values of two 7-bit bytes (high first), F7
  local function ring_frame(values)
    local bytes = frame_start(FRAME.rings)
    for m = 1, NUM_MACROS do
      local value = round(clamp01(values[m]) * FRAME.ring_max)
      bytes[#bytes + 1] = math.floor(value / 128)
      bytes[#bytes + 1] = value % 128
    end
    bytes[#bytes + 1] = FRAME.sysex_end
    return bytes
  end

  -- The first target's label cut or padded to four characters, or M<m>;
  -- only characters a SysEx byte can hold
  local function label_text(m)
    local text = "M" .. m
    for _, row in ipairs(S.lib.macros.targets(m) or {}) do
      if row.id ~= "" then
        text = S.lib.macros.target_label(row.id)
        break
      end
    end
    text = text:gsub("[^\32-\126]", "?")
    return (text .. string.rep(" ", FRAME.label_chars)):sub(1, FRAME.label_chars)
  end

  local function label_frame(m, text)
    local bytes = frame_start(FRAME.label)
    bytes[#bytes + 1] = m - 1
    for index = 1, FRAME.label_chars do bytes[#bytes + 1] = text:byte(index) end
    bytes[#bytes + 1] = FRAME.sysex_end
    return bytes
  end

  local function title_frame()
    local bytes = frame_start(FRAME.title)
    for index = 1, #FRAME.title_text do bytes[#bytes + 1] = FRAME.title_text:byte(index) end
    bytes[#bytes + 1] = FRAME.sysex_end
    return bytes
  end

  local function macro_values()
    local values = {}
    for m = 1, NUM_MACROS do values[m] = params:get(macro_param(m)) end
    return values
  end

  -- Every label and the title, as a device arrives
  local function send_labels()
    for m = 1, NUM_MACROS do
      echo.labels[m] = label_text(m)
      send_bytes(label_frame(m, echo.labels[m]))
    end
    send_bytes(title_frame())
  end

  -- The values echoed so far are the current ones: nothing is sent until one changes
  local function prime_echo()
    echo.last = macro_values()
    echo.sent = {}
    for m = 1, NUM_MACROS do echo.labels[m] = label_text(m) end
  end

  -- One tick: a CC for each macro whose value changed since its last echo
  -- (at most echo_per_tick, the newest values) and one ring frame when any
  -- did; a label frame for each macro whose first target changed
  local function echo_tick()
    local port = held.e16
    if not port then return end
    local values = macro_values()
    local changed = {}
    for m = 1, NUM_MACROS do
      if echo.last[m] ~= values[m] and #changed < CONTROLLERS.echo_per_tick then changed[#changed + 1] = m end
    end
    local vport = device_present(port) and ports.out(port) or nil
    if vport then
      local channel = setting("e16_channel")
      for _, m in ipairs(changed) do
        local number = setting("e16_cc") + m - 1
        local value = round(clamp01(values[m]) * FRAME.cc_max)
        vport:cc(number, value, channel)
        echo.sent[number] = {value = value, channel = channel, time = util.time()}
      end
      if #changed > 0 then send_bytes(ring_frame(values)) end
      for m = 1, NUM_MACROS do
        local text = label_text(m)
        if text ~= echo.labels[m] then
          echo.labels[m] = text
          send_bytes(label_frame(m, text))
        end
      end
    end
    for _, m in ipairs(changed) do echo.last[m] = values[m] end
  end

  ---------------------------------------------------------------------------
  -- The faders
  ---------------------------------------------------------------------------

  local function new_fader() return {high = nil, low = nil, previous = nil, picked = false, last_set = nil} end

  local function reset_faders()
    faders = {}
    for m = 1, NUM_MACROS do faders[m] = new_fader() end
  end
  reset_faders()

  -- Whether fader m has the macro: picked up, and the param still where the
  -- fader left it (anything else that moved it, a scene or a turn, ended it)
  function M.pickup(m)
    if preview and preview.picked then return preview.picked[m] == true end
    local state = faders[m]
    if not state or not state.picked then return false end
    if math.abs(params:get(macro_param(m)) - state.last_set) > FRAME.pickup_epsilon then
      state.picked = false
      request_redraw()
      return false
    end
    return true
  end

  local function fader_value(state)
    if setting("faders_hires") == "on" and state.low ~= nil then
      return (state.high * 128 + state.low) / FRAME.ring_max
    end
    return state.high / FRAME.cc_max
  end

  local function fader_moved(m, value)
    local state = faders[m]
    local id = macro_param(m)
    local was_picked = M.pickup(m)
    local current = params:get(id)
    if not was_picked then
      local near = math.abs(value - current) <= CONTROLLERS.pickup_window
      local crossed = state.previous ~= nil and (state.previous - current) * (value - current) < 0
      state.picked = near or crossed
    end
    state.previous = value
    if state.picked then
      params:set(id, value)
      state.last_set = params:get(id)
    end
    if state.picked ~= was_picked then request_redraw() end
  end

  local function faders_handler(data)
    local status, number, value = data[1], data[2], data[3]
    if type(status) ~= "number" or type(number) ~= "number" or type(value) ~= "number" then return end
    if status < 0xB0 or status > 0xBF or status - 0xB0 + 1 ~= setting("faders_channel") then return end
    local first = setting("faders_cc")
    local m, low = number - first + 1, false
    if m < 1 or m > NUM_MACROS then
      if setting("faders_hires") ~= "on" then return end
      m, low = number - first - FRAME.hires_offset + 1, true
      if m < 1 or m > NUM_MACROS then return end
    end
    local state = faders[m]
    if low then
      state.low = value
      if state.high == nil then return end
    else
      state.high = value
    end
    fader_moved(m, fader_value(state))
  end

  ---------------------------------------------------------------------------
  -- The E16's turns
  ---------------------------------------------------------------------------

  -- Detents a relative value is: rel1 sends 1 up and 127 down, rel2 63 up
  -- and 65 down (the E16 manual 1.0.1a, checks.md section 3); 0 and 64 are none
  local function turn_steps(encoding, value)
    if encoding == "rel2" then
      if value > 0 and value < 64 then return 64 - value end
      if value > 64 then return -(value - 64) end
      return 0
    end
    if value >= 1 and value <= 63 then return value end
    if value >= 65 then return -(128 - value) end
    return 0
  end

  local function e16_handler(data)
    local status, number, value = data[1], data[2], data[3]
    if type(status) ~= "number" or type(number) ~= "number" or type(value) ~= "number" then return end
    if status < 0xB0 or status > 0xBF or status - 0xB0 + 1 ~= setting("e16_channel") then return end
    local m = number - setting("e16_cc") + 1
    if m < 1 or m > NUM_MACROS then return end
    local sent = echo.sent[number]
    if sent and sent.value == value and sent.channel == status - 0xB0 + 1
        and util.time() - sent.time < CONTROLLERS.echo_guard_seconds then
      return
    end
    local steps = turn_steps(setting("e16_encoding"), value)
    if steps ~= 0 then delta_with_detent(macro_param(m), steps, {source = "midi"}) end
  end

  local handlers = {e16 = e16_handler, faders = faders_handler}

  ---------------------------------------------------------------------------
  -- Ports and the clock
  ---------------------------------------------------------------------------

  local function stop_clock()
    if clock_id then
      clock.cancel(clock_id)
      clock_id = nil
    end
  end

  -- IO's strip of sixteen marks: | picked up, . waiting
  local function strip_text()
    local marks = {}
    for m = 1, NUM_MACROS do marks[m] = M.pickup(m) and "|" or "." end
    return table.concat(marks)
  end

  local function tick()
    S.lib.ui_frame.contained_call(tick_errors, "echo", "controllers tick", echo_tick)
    local strip = strip_text()
    if strip ~= last_strip then
      last_strip = strip
      request_redraw()
    end
  end

  -- Runs only while a controller port is set, one clock, canceled before its replacement
  local function update_clock()
    stop_clock()
    if setting("e16_port") == 0 and setting("faders_port") == 0 then return end
    clock_id = clock.run(function()
      while true do
        clock.sleep(1 / CONTROLLERS.echo_hz)
        tick()
      end
    end)
  end

  function M.clock_id() return clock_id end

  local function release_kind(kind)
    local port = held[kind]
    if not port then return end
    held[kind] = nil
    ports.unlisten(port, kind)
    ports.release(port, kind)
  end

  -- Take the kind's port as the rig has it now: the old one released, the
  -- new one claimed and listened to (a port another owner holds is not
  -- taken); a device already there gets its labels; quiet asks for no redraw
  local function refresh(kind, quiet)
    local want = setting(kind .. "_port")
    if held[kind] ~= want then release_kind(kind) end
    if kind == "faders" then reset_faders() end
    if want > 0 and held[kind] == nil and ports.claim(want, kind) then
      held[kind] = want
      ports.listen(want, kind, handlers[kind])
      if kind == "e16" then
        prime_echo()
        if device_present(want) then send_labels() end
      end
    end
    update_clock()
    if not quiet then request_redraw() end
  end

  local function device_changed(port, name)
    if held.e16 == port and name ~= nil then
      prime_echo()
      send_labels()
    end
    if held.faders == port then reset_faders() end
    request_redraw()
  end

  -- True when norns' MAP holds an entry for a port, channel and CC a controller uses
  function M.map_clash()
    if preview and preview.clash ~= nil then return preview.clash end
    local rev = norns and norns.pmap and norns.pmap.rev
    if not rev then return false end
    local function mapped(port, channel, first)
      local by_channel = rev[port] and rev[port][channel]
      if not by_channel then return false end
      for number = first, first + NUM_MACROS - 1 do
        if by_channel[number] ~= nil then return true end
      end
      return false
    end
    local e16_port, faders_port = setting("e16_port"), setting("faders_port")
    if e16_port > 0 and mapped(e16_port, setting("e16_channel"), setting("e16_cc")) then return true end
    if faders_port > 0 then
      local first = setting("faders_cc")
      if mapped(faders_port, setting("faders_channel"), first) then return true end
      if setting("faders_hires") == "on" and mapped(faders_port, setting("faders_channel"), first + FRAME.hires_offset) then
        return true
      end
    end
    return false
  end

  ---------------------------------------------------------------------------
  -- IO's section
  ---------------------------------------------------------------------------

  local function section_rows()
    -- the marks first, so a view at the section's top shows them
    local rows = {{label = "faders", kind = "status", id = "picked up", text = strip_text}}
    for _, key in ipairs(SETTINGS) do
      rows[#rows + 1] = {label = key:gsub("_", " "), kind = "rig", key = key}
    end
    return rows
  end

  local function section_status()
    if M.map_clash() then return "map clash" end
    for _, kind in ipairs({"e16", "faders"}) do
      local port = configured_port(kind)
      if port > 0 and not device_present(port) then return "[--]" end
    end
    return nil
  end

  -- A layout state: ports, devices, marks and clash as given, not the rig's
  local function preview_state(name, state)
    return {name = name, setup = function() preview = state end}
  end

  local PICKED = {true, true, true, true, [7] = true, [8] = true, [16] = true}
  S.register_io_section({
    name = "controllers", title = "controllers", rows = section_rows, status = section_status,
    layout_states = {
      preview_state("no port set", {e16_port = 0, faders_port = 0, devices = {}, picked = {}, clash = false}),
      preview_state("port without device", {e16_port = 2, faders_port = 3, devices = {}, picked = {}, clash = false}),
      preview_state("both present", {e16_port = 2, faders_port = 3, devices = {[2] = true, [3] = true},
        picked = PICKED, clash = false}),
      preview_state("map clash", {e16_port = 2, faders_port = 3, devices = {[2] = true, [3] = true},
        picked = PICKED, clash = true}),
    },
  })

  S.register_start(S.constants.START_ORDER.io_controllers, function()
    for _, key in ipairs(SETTINGS) do
      S.lib.io_rig.on_change(key, function()
        if key == "e16_port" then
          refresh("e16")
        elseif key == "faders_port" then
          refresh("faders")
        else
          reset_faders()  -- the mapping moved: every fader waits to be picked up again
          request_redraw()
        end
      end)
    end
    ports.on_change("io_controllers", device_changed)
    refresh("e16", true)  -- at start the page has nothing new to show
    refresh("faders", true)
  end)

  S.register_cleanup(S.constants.CLEANUP_ORDER.io_controllers, function()
    stop_clock()
    release_kind("e16")
    release_kind("faders")
    preview = nil
  end)

  return M
end

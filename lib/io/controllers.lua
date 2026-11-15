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

  -- The eight settings the section shows, in order, and which kind each
  -- belongs to (a change of one kind's setting touches only that kind's state)
  local KINDS = {"e16", "faders"}
  local SETTINGS = {"e16_port", "e16_channel", "e16_cc", "e16_encoding", "faders_port", "faders_channel", "faders_cc",
    "faders_hires"}

  local ports = S.lib.io_ports

  local held = {}       -- kind ("e16", "faders") -> the port it holds and listens on
  -- the E16's: the last values echoed, the first target each label shows, the CCs sent (one entry
  -- per number, which the first CC back to match it uses up)
  local echo = {last = {}, first = {}, sent = {}}
  local faders = {}     -- m -> {high, low, previous, picked, last_set}
  local clock_id = nil
  local tick_errors = {}
  local last_strip = nil
  local closing = false  -- cleanup has begun: a released port is not taken again

  local function setting(key) return S.lib.io_rig.get(key) end

  local function macro_param(m) return "macro_" .. m end

  local function round(value) return math.floor(value + 0.5) end

  local function clamp01(value) return math.max(0, math.min(1, value)) end

  local function device_present(port) return ports.device(port) ~= nil end

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

  -- The id of macro m's first target, "" without one (the label is built
  -- only when this changes)
  local function first_target_id(m)
    for _, row in ipairs(S.lib.macros.targets(m) or {}) do
      if row.id ~= "" then return row.id end
    end
    return ""
  end

  -- That target's label cut or padded to four characters, or M<m>; only
  -- characters a SysEx byte can hold
  local function label_text(m, id)
    local text = id == "" and ("M" .. m) or S.lib.macros.target_label(id)
    text = text:gsub("[^\32-\126]", "?")
    return (text .. string.rep(" ", FRAME.label_chars)):sub(1, FRAME.label_chars)
  end

  local function label_frame(m, id)
    local text = label_text(m, id)
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
      echo.first[m] = first_target_id(m)
      send_bytes(label_frame(m, echo.first[m]))
    end
    send_bytes(title_frame())
  end

  -- Nothing has been echoed: the next tick sends every macro's CC and the rings
  local function reset_echo()
    echo.last = {}
    echo.sent = {}
  end

  -- One tick, while a device is on the E16's port: a CC for each macro
  -- whose value changed since its last echo (at most echo_per_tick, the
  -- newest values) and one ring frame when any did; a label frame for each
  -- macro whose first target changed
  local function echo_tick()
    local port = held.e16
    if not port or not device_present(port) then return end
    local vport = ports.out(port)
    if not vport then return end
    local values = macro_values()
    local changed = {}
    for m = 1, NUM_MACROS do
      if echo.last[m] ~= values[m] and #changed < CONTROLLERS.echo_per_tick then changed[#changed + 1] = m end
    end
    local channel = setting("e16_channel")
    for _, m in ipairs(changed) do
      local number = setting("e16_cc") + m - 1
      local value = round(clamp01(values[m]) * FRAME.cc_max)
      vport:cc(number, value, channel)
      echo.sent[number] = {value = value, channel = channel, time = util.time()}
      echo.last[m] = values[m]
    end
    if #changed > 0 then send_bytes(ring_frame(values)) end
    for m = 1, NUM_MACROS do
      local id = first_target_id(m)
      if id ~= echo.first[m] then
        echo.first[m] = id
        send_bytes(label_frame(m, id))
      end
    end
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

  -- Whether the param is still where fader m left it
  local function holds_value(m)
    local state = faders[m]
    return math.abs(params:get(macro_param(m)) - state.last_set) <= FRAME.pickup_epsilon
  end

  -- Whether fader m has the macro: picked up, and the param still where the
  -- fader left it. A query only (it runs while IO draws); drop_stale makes
  -- an answer of false stick
  function M.pickup(m)
    local state = faders[m]
    return state ~= nil and state.picked and holds_value(m)
  end

  -- A param value that is not what the fader last set ends its pickup
  local function drop_stale()
    for m = 1, NUM_MACROS do
      if faders[m].picked and not holds_value(m) then faders[m].picked = false end
    end
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
    drop_stale()
    local was_picked = state.picked
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
      -- a new high byte resets the low (MIDI 1.0's 14-bit rule), once a low
      -- byte has been seen: a 7-bit box never sends one
      if state.low ~= nil then state.low = 0 end
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

  -- Whether a CC is the echo of one Strata sent: the first to match an
  -- entry (same channel and value, within the guard) uses it up, so a
  -- real turn that looks like the echo costs one step, never a run of them
  local function is_echo(number, channel, value)
    local sent = echo.sent[number]
    if not sent then return false end
    if util.time() - sent.time >= CONTROLLERS.echo_guard_seconds then
      echo.sent[number] = nil
      return false
    end
    if sent.value == value and sent.channel == channel then
      echo.sent[number] = nil
      return true
    end
    return false
  end

  local function e16_handler(data)
    local status, number, value = data[1], data[2], data[3]
    if type(status) ~= "number" or type(number) ~= "number" or type(value) ~= "number" then return end
    local channel = status - 0xB0 + 1
    if status < 0xB0 or status > 0xBF or channel ~= setting("e16_channel") then return end
    local m = number - setting("e16_cc") + 1
    if m < 1 or m > NUM_MACROS then return end
    if is_echo(number, channel, value) then return end
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

  -- All of a tick's work is contained: a failure prints one line and the clock goes on
  local function tick_work()
    drop_stale()
    echo_tick()
    local strip = strip_text()
    if strip ~= last_strip then
      last_strip = strip
      request_redraw()
    end
  end

  local function tick()
    S.lib.ui_frame.contained_call(tick_errors, "tick", "controllers tick", tick_work)
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
  -- taken until its holder releases it); a device already there gets its
  -- labels, and its CCs and rings follow at the next tick; quiet asks for no redraw
  local function refresh(kind, quiet)
    local want = setting(kind .. "_port")
    if held[kind] ~= want then release_kind(kind) end
    if kind == "faders" then reset_faders() end
    if want > 0 and held[kind] == nil and ports.claim(want, kind) then
      held[kind] = want
      ports.listen(want, kind, handlers[kind])
      if kind == "e16" then
        reset_echo()
        if device_present(want) then send_labels() end
      end
    end
    update_clock()
    if not quiet then request_redraw() end
  end

  local function device_changed(port, name)
    if held.e16 == port and name ~= nil then
      reset_echo()
      send_labels()
    end
    if held.faders == port then reset_faders() end
    request_redraw()
  end

  -- A port released while a controller wants it (it was taken) is claimed now
  local function port_released(port, owner)
    if owner ~= nil or closing then return end
    for _, kind in ipairs(KINDS) do
      if held[kind] == nil and setting(kind .. "_port") == port then refresh(kind) end
    end
  end

  -- True when norns' MAP holds an entry for a port, channel and CC a controller uses
  function M.map_clash()
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

  -- A set port the controller does not hold, a MAP entry on one of its CCs, a set port with no device
  local function section_status()
    for _, kind in ipairs(KINDS) do
      local port = setting(kind .. "_port")
      if port > 0 and held[kind] ~= port then return "port taken" end
    end
    if M.map_clash() then return "map clash" end
    for _, kind in ipairs(KINDS) do
      local port = setting(kind .. "_port")
      if port > 0 and not device_present(port) then return "[--]" end
    end
    return nil
  end

  -- The layout states set what a user sets, the way a user does: the rig
  -- rows through E2 and E3 on IO's own page, devices plugged into the
  -- stub's ports, faders moved by CCs they send, MAP by norns.pmap
  local LAYOUT = {e16_port = 2, faders_port = 3, fader_cc = 64, picked_up = {1, 2, 3, 4, 7, 8, 16},
    map_channel = 16, map_cc = 102}

  -- Turn the controllers section's rig row `key` to value with E2 and E3
  -- on IO's page, which must be shown: S.lib.pages_io.go_to_row puts the
  -- cursor on the row (raising, naming the key, when the section has none),
  -- then E3 turns
  function M.turn_rig_row(key, value)
    S.lib.pages_io.go_to_row("controllers", "controllers", {key = key})
    enc(3, value - setting(key))
  end

  local function layout_ports(e16_port, faders_port)
    M.turn_rig_row("e16_port", e16_port)
    M.turn_rig_row("faders_port", faders_port)
  end

  local function layout_devices(context, present)
    for _, port in ipairs({LAYOUT.e16_port, LAYOUT.faders_port}) do
      if present then
        if not context.midi.vports[port].device then context.midi.plug(port, port == LAYOUT.e16_port and "OXI E16" or "16n") end
      else
        context.midi.unplug(port)
      end
    end
  end

  local function layout_mapped(clash)
    local by_channel = norns.pmap.rev[LAYOUT.e16_port][LAYOUT.map_channel]
    by_channel[LAYOUT.map_cc] = clash and "v1_level" or nil
  end

  -- Faders the box sends at the macro's own value, so each is picked up
  local function layout_picked(context)
    for _, m in ipairs(LAYOUT.picked_up) do
      params:set(macro_param(m), LAYOUT.fader_cc / FRAME.cc_max)
      context.midi.send(LAYOUT.faders_port, {type = "cc", cc = setting("faders_cc") + m - 1, val = LAYOUT.fader_cc,
        ch = setting("faders_channel")})
    end
  end

  local function layout_state(name, state)
    return {name = name, setup = function(context)
      layout_ports(state.ports and LAYOUT.e16_port or 0, state.ports and LAYOUT.faders_port or 0)
      layout_devices(context, state.devices)
      layout_mapped(state.clash)
      if state.picked then layout_picked(context) end
      S.lib.pages_io.show_section("controllers")  -- back to the section's top, as the look is drawn
    end}
  end

  S.register_io_section({
    name = "controllers", title = "controllers", rows = section_rows, status = section_status,
    layout_states = {
      layout_state("no port set", {}),
      layout_state("port without device", {ports = true}),
      layout_state("both present", {ports = true, devices = true, picked = true}),
      layout_state("map clash", {ports = true, devices = true, picked = true, clash = true}),
    },
  })

  S.register_start(S.constants.START_ORDER.io_controllers, function()
    closing = false
    for _, key in ipairs(SETTINGS) do
      S.lib.io_rig.on_change(key, function()
        if key == "e16_port" then
          refresh("e16")
        elseif key == "faders_port" then
          refresh("faders")
        elseif key:sub(1, 3) == "e16" then
          reset_echo()  -- the E16's mapping moved: every macro goes out again on the new one
          request_redraw()
        else
          reset_faders()  -- the faders' mapping moved: every fader waits to be picked up again
          request_redraw()
        end
      end)
    end
    ports.on_change("io_controllers", device_changed)
    ports.on_claim("io_controllers", port_released)
    refresh("e16", true)  -- at start the page has nothing new to show
    refresh("faders", true)
  end)

  S.register_cleanup(S.constants.CLEANUP_ORDER.io_controllers, function()
    closing = true
    stop_clock()
    release_kind("e16")
    release_kind("faders")
  end)

  return M
end

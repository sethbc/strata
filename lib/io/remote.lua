-- lib/io/remote.lua
-- Remote grids and arcs (3.6 design §9), S.lib.io_remote: a grid or arc in
-- iii mode running iii/strata_grid.lua or iii/strata_arc.lua becomes one
-- more grid (S.grids[GRID_PORTS.remote]) or the arc Strata follows (a
-- virtual arc), through a small protocol of notes and CCs on the device's
-- own MIDI port (PROTOCOL, version 1); and a MIDI grid through the midigrid
-- mod attaches at GRID_PORTS.midigrid. The rig settings remote_grid_port,
-- remote_arc_port and midi_grid choose them (read only, S.lib.io_rig). A
-- remote device's LEDs go through a frame buffer that one 30 Hz clock
-- sends, at most REMOTE.leds_per_tick a tick per device, only while a
-- remote device is attached. Registers IO's remote section. See
-- docs/notes/lua/io/remote.md.

return function(S)
  local M = {}
  local GRID_PORTS = S.constants.GRID_PORTS
  local rig = S.lib.io_rig

  local REMOTE = {leds_per_tick = 96, draw_hz = 30, version = 1, sizes = {{16, 16}, {16, 8}, {8, 16}, {8, 8}},
    arc_rings = 4, arc_leds = 64}
  M.REMOTE = REMOTE

  -- The protocol's numbers (design §9.1): the hello's CCs and the two CCs
  -- Strata sends, all on hello_channel; a grid's keys and LEDs on channels
  -- 1 and 2 (index = (y - 1) * stride + (x - 1), channel index //
  -- per_channel + 1, note index % per_channel); an arc's LEDs on channels
  -- 3 and 4 (index = (ring - 1) * 64 + (led - 1)), its turns on CC
  -- first_turn_cc to + 3 of arc_channel (by value - turn_center) and its key
  -- on note arc_key_note there; a key down at key_down, up at 0
  local PROTOCOL = {hello_channel = 1, cc = {cols = 0, rows = 1, version = 2, frame_end = 3, all = 4},
    stride = 16, per_channel = 128, grid_channel = 1, arc_channel = 3, first_turn_cc = 16, turn_center = 64,
    arc_key_note = 0, key_down = 127, max_level = 15}
  M.PROTOCOL = PROTOCOL

  local TEXTS = {missing = "[--]", waiting = "no hello", in_use = "in use", arc_attached = "4 rings"}

  -- Per kind: its rig key, the name it claims its port as, its status
  -- label, the first LED channel; claimed_port (the port it claimed and
  -- listens to, or nil), in_use (the port held by another owner), parts
  -- (the hello's columns and rows so far), problem (a hello refused), the
  -- virtual device (exactly while a good hello is held), its frame (levels
  -- at the last refresh), shown (levels the device was last sent), cells
  -- (its indices in order) and cursor (where the next tick starts)
  local function new_record(kind, key, owner, label, channel)
    return {kind = kind, key = key, owner = owner, label = label, channel = channel, claimed_port = nil,
      in_use = false, parts = {}, problem = nil, virtual = nil, frame = nil, shown = nil, cells = nil, cursor = 0}
  end
  local records = {
    grid = new_record("grid", "remote_grid_port", "remote grid", "grid", PROTOCOL.grid_channel),
    arc = new_record("arc", "remote_arc_port", "remote arc", "arc", PROTOCOL.arc_channel),
  }
  local KINDS = {"grid", "arc"}
  local midigrid = {device = nil}
  local draw = {clock = nil}
  local state = {started = false, errors = {}}

  local function contained(key, label, fn, ...)
    return S.lib.ui_frame.contained_call(state.errors, key, label, fn, ...)
  end

  local function whole(value, low, high)
    return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
  end

  local function level_of(level)
    if type(level) ~= "number" or level ~= level then return 0 end
    return math.max(0, math.min(PROTOCOL.max_level, math.floor(level)))
  end

  local function send_cc(port, cc, value)
    local out = S.lib.io_ports.out(port)
    if out then out:cc(cc, value, PROTOCOL.hello_channel) end
  end

  -- A frame buffer of the given indices, all at 0: led and all write
  -- buffer, refresh copies it to the frame the clock sends
  local function new_buffer(record, cells)
    local buffer, frame, shown = {}, {}, {}
    for _, index in ipairs(cells) do buffer[index], frame[index], shown[index] = 0, 0, 0 end
    record.frame, record.shown, record.cells, record.cursor = frame, shown, cells, 0
    return buffer
  end

  local function set_level(buffer, index, level, rel)
    if buffer[index] == nil then return end
    buffer[index] = level_of(rel and (buffer[index] + (tonumber(level) or 0)) or level)
  end

  local function refresh_into(record, buffer)
    for _, index in ipairs(record.cells) do record.frame[index] = buffer[index] end
  end

  -- A virtual grid of cols x rows: S.lib.grid_core.attach_virtual's fields
  -- (device, cols, rows, led, all, refresh, rotation; rotation does nothing)
  local function new_grid(record, cols, rows)
    local cells = {}
    for y = 1, rows do
      for x = 1, cols do cells[#cells + 1] = (y - 1) * PROTOCOL.stride + (x - 1) end
    end
    table.sort(cells)
    local buffer = new_buffer(record, cells)
    local virtual = {cols = cols, rows = rows, name = "remote grid", remote = "grid",
      device = {name = "remote grid", port = record.claimed_port}}
    function virtual:led(x, y, level, rel)
      if not (whole(x, 1, cols) and whole(y, 1, rows)) then return end
      set_level(buffer, (y - 1) * PROTOCOL.stride + (x - 1), level, rel)
    end
    function virtual:all(level, rel)
      for _, index in ipairs(cells) do set_level(buffer, index, level, rel) end
    end
    function virtual:refresh() refresh_into(record, buffer) end
    function virtual:rotation() end
    function virtual:intensity() end
    return virtual
  end

  -- norns' Arc:segment arithmetic (lua/core/arc.lua): angles modulo 2*pi,
  -- each of the 64 LEDs set to round(overlap / LED width * level), with rel
  local function segment_levels(from, to, level)
    local tau = math.pi * 2
    local function overlap(a, b, c, d)
      if a > b then
        return overlap(a, tau, c, d) + overlap(0, b, c, d)
      elseif c > d then
        return overlap(a, b, c, tau) + overlap(a, b, 0, d)
      end
      return math.max(0, math.min(b, d) - math.max(a, c))
    end
    local levels, width = {}, tau / REMOTE.arc_leds
    for led = 1, REMOTE.arc_leds do
      local covered = overlap(from % tau, to % tau, (width * (led - 1)) % tau, (width * led) % tau)
      levels[led] = math.floor(covered / width * level + 0.5)
    end
    return levels
  end

  -- The virtual arc: S.lib.arc_core.follow_virtual's fields (device, all,
  -- refresh, segment, led); arc_core sets its delta and key
  local function new_arc(record)
    local cells = {}
    for index = 0, REMOTE.arc_rings * REMOTE.arc_leds - 1 do cells[#cells + 1] = index end
    local buffer = new_buffer(record, cells)
    local virtual = {name = "remote arc", remote = "arc", device = {name = "remote arc", port = record.claimed_port}}
    function virtual:led(ring, led, level, rel)
      if not (whole(ring, 1, REMOTE.arc_rings) and whole(led, 1, REMOTE.arc_leds)) then return end
      set_level(buffer, (ring - 1) * REMOTE.arc_leds + (led - 1), level, rel)
    end
    function virtual:all(level, rel)
      for _, index in ipairs(cells) do set_level(buffer, index, level, rel) end
    end
    function virtual:segment(ring, from, to, level, rel)
      for led, value in ipairs(segment_levels(from, to, level)) do self:led(ring, led, value, rel) end
    end
    function virtual:refresh() refresh_into(record, buffer) end
    function virtual:intensity() end
    return virtual
  end

  local function any_attached() return records.grid.virtual ~= nil or records.arc.virtual ~= nil end

  -- One device's tick: the cells whose frame level differs from the one
  -- last sent, from where the last tick stopped, at most leds_per_tick of
  -- them, then the frame end; nothing at all when none differs
  local function send_frame(record)
    local out = S.lib.io_ports.out(record.claimed_port)
    if not out or not record.cells then return end
    local count, total, last = 0, #record.cells, nil
    for step = 1, total do
      if count >= REMOTE.leds_per_tick then break end
      local position = (record.cursor + step - 1) % total + 1
      local index = record.cells[position]
      local level = record.frame[index]
      if level ~= record.shown[index] then
        out:note_on(index % PROTOCOL.per_channel, level, record.channel + math.floor(index / PROTOCOL.per_channel))
        record.shown[index] = level
        count, last = count + 1, position
      end
    end
    if count == 0 then return end
    record.cursor = last % total
    send_cc(record.claimed_port, PROTOCOL.cc.frame_end, 0)
  end

  local function tick()
    for _, kind in ipairs(KINDS) do
      local record = records[kind]
      if record.virtual then contained(kind .. " frame", "remote " .. kind .. " frame", send_frame, record) end
    end
  end

  -- The draw clock runs exactly while a remote device is attached
  local function update_clock()
    if any_attached() and draw.clock == nil then
      draw.clock = clock.run(function()
        while true do
          clock.sleep(1 / REMOTE.draw_hz)
          tick()
        end
      end)
    elseif not any_attached() and draw.clock ~= nil then
      clock.cancel(draw.clock)
      draw.clock = nil
    end
  end

  function M.clock_id() return draw.clock end

  -- The virtual device goes (its grid detached or its arc unfollowed);
  -- clear sends CC 4 = 0 to the device first
  local function detach(record, clear)
    if not record.virtual then return end
    if record.kind == "grid" then
      if S.grids[GRID_PORTS.remote] == record.virtual then S.lib.grid_core.detach_virtual(GRID_PORTS.remote) end
    else
      S.lib.arc_core.unfollow_virtual()
    end
    if clear and record.claimed_port then send_cc(record.claimed_port, PROTOCOL.cc.all, 0) end
    record.virtual, record.frame, record.shown, record.cells = nil, nil, nil, nil
    update_clock()
    request_redraw()
  end

  -- Every LED of the device to 0 (CC 4 = 0), and what was sent to 0
  local function clear_device(record)
    send_cc(record.claimed_port, PROTOCOL.cc.all, 0)
    for _, index in ipairs(record.cells) do record.shown[index] = 0 end
    record.cursor = 0
  end

  local function attach(record, cols, rows)
    if record.virtual and (record.kind == "arc" or (record.virtual.cols == cols and record.virtual.rows == rows)) then
      clear_device(record)  -- the same device greeting again: send it everything again
      return
    end
    detach(record, false)
    local virtual = record.kind == "grid" and new_grid(record, cols, rows) or new_arc(record)
    record.virtual = virtual
    clear_device(record)
    update_clock()
    if record.kind == "grid" then
      if not S.lib.grid_core.attach_virtual(GRID_PORTS.remote, virtual) then detach(record, true) end
    else
      S.lib.arc_core.follow_virtual(virtual)
    end
    request_redraw()
  end

  local function fits(record, cols, rows)
    if record.kind == "arc" then return cols == 0 and rows == REMOTE.arc_rings end
    for _, size in ipairs(REMOTE.sizes) do
      if size[1] == cols and size[2] == rows then return true end
    end
    return false
  end

  -- The hello is complete at its version (CC 2): of version 1 with this
  -- kind's size it attaches; otherwise nothing is attached and the problem
  -- is kept for the status. A CC 2 with no columns and rows before it does
  -- nothing
  local function on_hello(record, version)
    local cols, rows = record.parts.cols, record.parts.rows
    record.parts = {}
    if cols == nil or rows == nil then return end
    if version ~= REMOTE.version then
      detach(record, true)
      record.problem = "version " .. version .. "?"
    elseif not fits(record, cols, rows) then
      detach(record, true)
      record.problem = "size " .. cols .. "x" .. rows .. "?"
    else
      record.problem = nil
      attach(record, cols, rows)
    end
    request_redraw()
  end

  local function on_grid_input(record, msg)
    local key = record.virtual and record.virtual.key
    if not key or (msg.ch ~= 1 and msg.ch ~= 2) then return end
    local index = (msg.ch - 1) * PROTOCOL.per_channel + msg.note
    local x, y = index % PROTOCOL.stride + 1, math.floor(index / PROTOCOL.stride) + 1
    if x > record.virtual.cols or y > record.virtual.rows then return end  -- beyond the grid's size
    key(x, y, (msg.type == "note_on" and msg.vel > 0) and 1 or 0)
  end

  local function on_arc_input(record, msg)
    local virtual = record.virtual
    if not virtual or msg.ch ~= PROTOCOL.arc_channel then return end
    if msg.type == "cc" then
      local ring = msg.cc - PROTOCOL.first_turn_cc + 1
      local delta = msg.val - PROTOCOL.turn_center
      if whole(ring, 1, REMOTE.arc_rings) and delta ~= 0 and virtual.delta then virtual.delta(ring, delta) end
    elseif msg.note == PROTOCOL.arc_key_note and virtual.key then
      virtual.key(1, (msg.type == "note_on" and msg.vel > 0) and 1 or 0)
    end
  end

  -- Every message of the claimed port (through S.lib.io_ports, contained)
  local function on_message(record, data)
    local msg = midi.to_msg(data)
    if msg.type == "cc" and msg.ch == PROTOCOL.hello_channel and msg.cc <= PROTOCOL.cc.version then
      if msg.cc == PROTOCOL.cc.cols then record.parts.cols = msg.val
      elseif msg.cc == PROTOCOL.cc.rows then record.parts.rows = msg.val
      else on_hello(record, msg.val) end
    elseif msg.type == "note_on" or msg.type == "note_off" then
      if record.kind == "grid" then on_grid_input(record, msg) else on_arc_input(record, msg) end
    elseif msg.type == "cc" and record.kind == "arc" then
      on_arc_input(record, msg)
    end
  end

  local function ask_hello(record)
    send_cc(record.claimed_port, PROTOCOL.cc.version, 0)
  end

  -- The rig's port for record, with a device on it: claimed, listened to,
  -- asked for the hello. A port another owner holds is in use
  local function connect(record)
    if not state.started or record.claimed_port then return end
    local port = rig.get(record.key)
    record.in_use = false
    if port == 0 or S.lib.io_ports.device(port) == nil then return end
    if not S.lib.io_ports.claim(port, record.owner) then
      record.in_use = true
      return
    end
    record.claimed_port = port
    S.lib.io_ports.listen(port, record.owner, function(data) on_message(record, data) end)
    ask_hello(record)
    request_redraw()
  end

  -- Detached, no longer listened to, the claim released; departing: the
  -- device has left, so nothing is sent to it
  local function disconnect(record, departing)
    detach(record, not departing)
    local port = record.claimed_port
    record.parts, record.problem, record.in_use = {}, nil, false
    if port == nil then return end
    -- released while still claimed_port, so the claim hook (below) does not
    -- take the port straight back
    S.lib.io_ports.unlisten(port, record.owner)
    S.lib.io_ports.release(port, record.owner)
    record.claimed_port = nil
    request_redraw()
  end

  -- midigrid (checks.md §7): grid.connect() through the global, with no
  -- argument, once; what comes back is attached at GRID_PORTS.midigrid when
  -- it is none of norns' own vports and has whole-number cols and rows and
  -- the functions led, all and refresh (a missing rotation does nothing)
  local function midigrid_usable(candidate)
    if type(candidate) ~= "table" then return false end
    for port = 1, S.MAX_GRID_PORTS do
      if candidate == grid.vports[port] then return false end
    end
    if not (whole(candidate.cols, 1, math.huge) and whole(candidate.rows, 1, math.huge)) then return false end
    for _, method in ipairs({"led", "all", "refresh"}) do
      if type(candidate[method]) ~= "function" then return false end
    end
    return true
  end

  -- The midigrid object goes: detached, then left dark
  local function midigrid_detach()
    local device = midigrid.device
    if device == nil then return end
    midigrid.device = nil
    if S.grids[GRID_PORTS.midigrid] == device then S.lib.grid_core.detach_virtual(GRID_PORTS.midigrid) end
    contained("midigrid dark", "remote midigrid dark", function()
      device:all(0)
      device:refresh()
    end)
    request_redraw()
  end

  local function midigrid_connect()
    midigrid_detach()
    local candidate
    contained("midigrid connect", "remote midigrid connect", function() candidate = grid.connect() end)
    if midigrid_usable(candidate) then
      if candidate.rotation == nil then candidate.rotation = function() end end
      if S.lib.grid_core.attach_virtual(GRID_PORTS.midigrid, candidate) then midigrid.device = candidate end
    end
    request_redraw()
  end

  -- IO's rescan action: each remote device on its port asked for its hello
  -- again, and with midi grid on, midigrid connected again
  function M.rescan()
    if not state.started then return end
    for _, kind in ipairs(KINDS) do
      local record = records[kind]
      if record.claimed_port then ask_hello(record) else connect(record) end
    end
    if rig.get("midi_grid") == "on" then midigrid_connect() end
  end

  -- What a device's status line says: nil while its setting is off; in
  -- use, [--] (no device on the port), no hello, the hello's problem, or
  -- what is attached (a grid's size, the arc's rings)
  function M.status(kind)
    if kind == "midigrid" then
      if rig.get("midi_grid") ~= "on" then return nil end
      local device = midigrid.device
      return device and (device.cols .. "x" .. device.rows) or TEXTS.missing
    end
    local record = records[kind]
    if not record or rig.get(record.key) == 0 then return nil end
    if record.in_use then return TEXTS.in_use end
    if record.claimed_port == nil then return TEXTS.missing end
    if record.virtual then
      return record.kind == "grid" and (record.virtual.cols .. "x" .. record.virtual.rows) or TEXTS.arc_attached
    end
    return record.problem or TEXTS.waiting
  end

  for _, kind in ipairs(KINDS) do
    local record = records[kind]
    rig.on_change(record.key, function()
      if not state.started then return end
      disconnect(record, false)
      connect(record)
      request_redraw()
    end)
  end

  rig.on_change("midi_grid", function(value)
    if not state.started then return end
    if value == "on" then midigrid_connect() else midigrid_detach() end
  end)

  -- A device arriving at a set port is connected; the claimed port's device
  -- leaving disconnects it
  S.lib.io_ports.on_change("remote", function(port, name)
    if not state.started then return end
    for _, kind in ipairs(KINDS) do
      local record = records[kind]
      if name == nil and record.claimed_port == port then
        disconnect(record, true)
        request_redraw()
      elseif name == nil and record.in_use and rig.get(record.key) == port then
        record.in_use = false
        request_redraw()
      elseif name ~= nil and record.claimed_port == nil and rig.get(record.key) == port then
        connect(record)
      end
    end
  end)

  -- A port another owner held, freed: taken when the rig names it
  S.lib.io_ports.on_claim("remote", function(port, owner)
    if not state.started or owner ~= nil then return end
    for _, kind in ipairs(KINDS) do
      local record = records[kind]
      if record.claimed_port == nil and rig.get(record.key) == port then connect(record) end
    end
  end)

  -- IO's remote section
  -- the rig rows, first in the section, in this order
  local RIG_ROWS = {{key = "remote_grid_port", label = "grid port"}, {key = "remote_arc_port", label = "arc port"},
    {key = "midi_grid", label = "midi grid"}}
  local function section_rows()
    local rows = {}
    for index, rig_row in ipairs(RIG_ROWS) do rows[index] = {kind = "rig", label = rig_row.label, key = rig_row.key} end
    for _, kind in ipairs({"grid", "arc", "midigrid"}) do
      local status = M.status(kind)
      if status then rows[#rows + 1] = {kind = "status", id = kind .. " status", text = kind .. ": " .. status} end
    end
    rows[#rows + 1] = {kind = "action", label = "rescan", hint = "rescan", run = M.rescan}
    return rows
  end

  -- [--] while a set port or midi grid has no device
  local function section_status()
    for _, kind in ipairs({"grid", "arc", "midigrid"}) do
      if M.status(kind) == TEXTS.missing then return TEXTS.missing end
    end
    return nil
  end

  -- Layout states: the rig set through IO's own rows (E3 on the row, as a
  -- player does; only the IO page changes a rig setting): the cursor put
  -- on the key's row by S.lib.pages_io.go_to_row, E3 turns it, and the
  -- section is shown again at its top
  local function set_through_page(key, steps)
    S.lib.pages_io.go_to_row("remote", "remote", {key = key})
    enc(3, steps)
    S.lib.pages_io.show_section("remote")
  end

  local function greet(context, port, cols, rows, version)
    context.midi.send(port, {type = "cc", cc = PROTOCOL.cc.cols, val = cols, ch = PROTOCOL.hello_channel})
    context.midi.send(port, {type = "cc", cc = PROTOCOL.cc.rows, val = rows, ch = PROTOCOL.hello_channel})
    context.midi.send(port, {type = "cc", cc = PROTOCOL.cc.version, val = version, ch = PROTOCOL.hello_channel})
  end

  local LAYOUT_PORT = 3
  S.register_io_section({name = "remote", title = "remote", rows = section_rows, status = section_status,
    layout_states = {
      {name = "every setting off", setup = function() end},
      {name = "a port set with no device", setup = function() set_through_page("remote_grid_port", LAYOUT_PORT) end},
      {name = "a grid attached", setup = function(context)
        context.midi.plug(LAYOUT_PORT, "iii grid")
        set_through_page("remote_grid_port", LAYOUT_PORT)
        greet(context, LAYOUT_PORT, 16, 8, REMOTE.version)
      end},
      {name = "a hello of another version", setup = function(context)
        context.midi.plug(LAYOUT_PORT, "iii grid")
        set_through_page("remote_grid_port", LAYOUT_PORT)
        greet(context, LAYOUT_PORT, 16, 8, REMOTE.version + 1)
      end},
      {name = "a midigrid attached", setup = function(context)
        local object = {cols = 16, rows = 8, device = {name = "midigrid"}}
        function object:led() end
        function object:all() end
        function object:refresh() end
        local connect_grid = context.grid.connect
        context.grid.connect = function(...)
          if select("#", ...) == 0 then return object end
          return connect_grid(...)
        end
        set_through_page("midi_grid", 1)
      end},
    }})

  -- The start step: the ports the rig names claimed and asked for their
  -- hello, and with midi grid on, midigrid connected
  S.register_start(S.constants.START_ORDER.io_remote, function()
    state.started = true
    for _, kind in ipairs(KINDS) do connect(records[kind]) end
    if rig.get("midi_grid") == "on" then midigrid_connect() end
  end)

  -- The cleanup step: the clock ended, CC 4 = 0 to each device, everything
  -- detached and released
  S.register_cleanup(S.constants.CLEANUP_ORDER.io_remote, function()
    state.started = false
    if draw.clock then
      clock.cancel(draw.clock)
      draw.clock = nil
    end
    for _, kind in ipairs(KINDS) do disconnect(records[kind], false) end
    midigrid_detach()
  end)

  -- A virtual device is attached exactly while its port's hello is held,
  -- and the draw clock runs exactly while a remote one is
  S.register_invariant("remote", function()
    local grid_record = records.grid
    local attached = S.grids[GRID_PORTS.remote]
    if grid_record.virtual and attached ~= grid_record.virtual then return "a held grid hello is not attached" end
    if attached and attached.remote == "grid" and attached ~= grid_record.virtual then
      return "a remote grid is attached with no hello held"
    end
    local arc_record = records.arc
    local followed = S.arc_device
    if followed and followed.remote == "arc" and followed ~= arc_record.virtual then
      return "a remote arc is followed with no hello held"
    end
    if arc_record.virtual and followed ~= arc_record.virtual and not (followed and followed.device and followed.remote == nil) then
      return "a held arc hello is neither followed nor given way to a monome arc"
    end
    for _, kind in ipairs(KINDS) do
      local record = records[kind]
      if record.virtual and record.claimed_port == nil then return kind .. " attached on no claimed port" end
    end
    if midigrid.device and S.grids[GRID_PORTS.midigrid] ~= midigrid.device then return "the midigrid is not attached" end
    if (draw.clock ~= nil) ~= any_attached() then
      return "the draw clock " .. (draw.clock and "runs with no remote device" or "is stopped with one attached")
    end
  end)

  return M
end

-- lib/io/midi_out.lua
-- MIDI out (3.6 design §4), S.lib.io_midi_out: the note target midi (a
-- voice's steps and played notes to a MIDI port, plain on its channel or
-- MPE in the port's lower zone, one MPE voice a port), eight CC out slots
-- following modulation sources, and program change out for scene recalls
-- (program change in reaches program_change_in from lib/midi_in.lua). Every
-- message goes through the vport S.lib.io_ports.out(port) gives. A played
-- MPE note's first bend, pressure and slide go before its note on; the
-- later ones are read from S.lib.expression.raw at each LFO step, at most
-- MIDI_OUT.express_per_step messages a step, round robin. Everything is
-- off by default: with every param at its default nothing is sent.
-- Notes: docs/notes/lua/io/midi_out.md

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  local MIDI_OUT = {express_per_step = 24, cc_per_step = 8, slots = 8, master_channel = 1, master_bend_range = 2,
    slide_cc = 74, all_notes_off_cc = 123,
    -- RPNs (6: MPE configuration, 0: bend range), the 14-bit bend, 7-bit values
    rpn_msb_cc = 101, rpn_lsb_cc = 100, data_cc = 6, rpn_zone = 6, rpn_bend = 0,
    bend_center = 8192, bend_max = 16383, value_max = 127, notes = 128, channels = 16, max_members = 15,
    bend_range = {min = 1, max = 96, default = 48}, modes = {"plain", "mpe"}, mpe_mode = 2,
    param_count = 74, played_source = "midi", fields = {"bend", "pressure", "slide"},
    refused = "port has an mpe voice", absent = "[--]", approximate = " ~"}
  M.MIDI_OUT = MIDI_OUT

  -- config[voice]: the settled route {port, channel, mode (an index of
  -- MIDI_OUT.modes), members}, which only settle changes; noted: the route
  -- params (and the bend range) changed since the last settle, dirty while
  -- any is; notes[voice][id]: what a note sent {voice,
  -- port, device, channel, note, mpe, owner, key, sent = {bend, pressure,
  -- slide}} (device: the name of the device the port held as the note on
  -- went, the one that got it);
  -- counts[port][channel][note]: the ids sounding there; use[port][channel]:
  -- the notes on a channel; member_times[port][channel] = {released,
  -- assigned}; expressing: the played MPE notes the step reads, cursor the
  -- next to read; express_ports: the step's set of their ports; cc_last[k]: slot k's last value; left_with[key]: the
  -- channels with notes as a device left, by the name S.lib.io_ports hands
  -- the departure (or "port <n>" without one); asked[port]: the scene a
  -- program change in on that port asked for, until its recall lands
  local state = {config = {}, notes = {}, counts = {}, use = {}, member_times = {}, expressing = {}, cursor = 1,
    express_ports = {}, cc_last = {}, left_with = {}, asked = {}, tick = 0, stopped = false,
    bend_range = MIDI_OUT.bend_range.default, noted = {}, dirty = false}
  for voice = 1, NUM_VOICES do
    state.config[voice] = {port = 0, channel = voice, mode = 1, members = MIDI_OUT.max_members}
    state.notes[voice] = {}
  end

  local function vid(voice, field) return "v" .. voice .. "_out_" .. field end
  local function slot_id(k, field) return "cc_out" .. k .. "_" .. field end

  local function valid_voice(voice)
    return type(voice) == "number" and voice % 1 == 0 and voice >= 1 and voice <= NUM_VOICES
  end

  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end

  local function param_value(id)
    if not params.lookup[id] then return nil end
    return params:get(id)
  end

  local function is_mpe(config) return config.port > 0 and config.mode == MIDI_OUT.mpe_mode end

  -- A port a remote grid, a remote arc or midigrid holds speaks the remote's
  -- own protocol (notes on channels 1 and 2 set LEDs): MIDI out treats it
  -- as absent for everything it sends. A controller's port is sent to as set
  local function remote_holds(port)
    local remote = S.lib.io_remote
    return remote ~= nil and remote.holds ~= nil and remote.holds(port) == true
  end

  -- One message on port, through its vport: nothing after cleanup, on port
  -- 0 or on a port a remote holds
  local function send(port, method, ...)
    if state.stopped or not port or port < 1 or remote_holds(port) then return end
    local vport = S.lib.io_ports.out(port)
    if vport then vport[method](vport, ...) end
  end

  local function present(port) return S.lib.io_ports.device(port) ~= nil and not remote_holds(port) end

  local function table_at(root, ...)
    local node = root
    for _, key in ipairs({...}) do
      node[key] = node[key] or {}
      node = node[key]
    end
    return node
  end

  ---------------------------------------------------------------------------
  -- The zone: setup and takedown (RPN 6, then RPN 0 on a member and the master)
  ---------------------------------------------------------------------------

  local function rpn(port, number, value, channel)
    send(port, "cc", MIDI_OUT.rpn_msb_cc, 0, channel)
    send(port, "cc", MIDI_OUT.rpn_lsb_cc, number, channel)
    send(port, "cc", MIDI_OUT.data_cc, value, channel)
  end

  local function setup(port, members)
    local master = MIDI_OUT.master_channel
    rpn(port, MIDI_OUT.rpn_zone, members, master)
    rpn(port, MIDI_OUT.rpn_bend, state.bend_range, master + 1)
    rpn(port, MIDI_OUT.rpn_bend, MIDI_OUT.master_bend_range, master)
  end

  local function takedown(port) rpn(port, MIDI_OUT.rpn_zone, 0, MIDI_OUT.master_channel) end

  -- Why a set of routes cannot be (design §4.2): a second MPE voice on a
  -- port, or a plain voice's channel inside an MPE zone on its port; nil
  -- when it can
  local function conflict(configs)
    local zone_voice = {}
    for voice = 1, NUM_VOICES do
      local config = configs[voice]
      if is_mpe(config) then
        if zone_voice[config.port] then return "port " .. config.port .. " has two MPE voices" end
        zone_voice[config.port] = voice
      end
    end
    for voice = 1, NUM_VOICES do
      local config = configs[voice]
      local owner = config.port > 0 and not is_mpe(config) and zone_voice[config.port]
      if owner and config.channel <= MIDI_OUT.master_channel + configs[owner].members then
        return "voice " .. voice .. "'s channel " .. config.channel .. " is inside port " .. config.port .. "'s zone"
      end
    end
    return nil
  end

  ---------------------------------------------------------------------------
  -- Notes
  ---------------------------------------------------------------------------

  local function round(value) return math.floor(value + 0.5) end

  -- A field's outgoing value from raw = {bend, pressure, slide}, or nil
  local function encoded(field, raw)
    if field == "bend" then
      local bend = finite(raw.bend) and raw.bend > 0 and raw.bend or 1
      local semitones = 12 * math.log(bend) / math.log(2)
      return util.clamp(round(MIDI_OUT.bend_center + MIDI_OUT.bend_center * semitones / state.bend_range), 0,
        MIDI_OUT.bend_max)
    end
    local value = raw[field]
    if not finite(value) then return nil end
    return util.clamp(round(value * MIDI_OUT.value_max), 0, MIDI_OUT.value_max)
  end

  local function send_field(record, field, value)
    if field == "bend" then
      send(record.port, "pitchbend", value, record.channel)
    elseif field == "pressure" then
      send(record.port, "channel_pressure", value, record.channel)
    else
      send(record.port, "cc", MIDI_OUT.slide_cc, value, record.channel)
    end
  end

  local function next_tick()
    state.tick = state.tick + 1
    return state.tick
  end

  -- A member channel for a new note (design §4.2): the free one released
  -- longest ago; with none free, the one with the fewest notes, the one
  -- assigned longest ago among them
  local function allocate(port, members)
    local use, times = table_at(state.use, port), table_at(state.member_times, port)
    local first, last = MIDI_OUT.master_channel + 1, MIDI_OUT.master_channel + members
    for channel = first, last do times[channel] = times[channel] or {released = 0, assigned = 0} end
    local best
    for channel = first, last do
      if (use[channel] or 0) == 0 and (best == nil or times[channel].released < times[best].released) then
        best = channel
      end
    end
    if not best then
      for channel = first, last do
        local notes, best_notes = use[channel] or 0, best and (use[best] or 0)
        if best == nil or notes < best_notes or (notes == best_notes and times[channel].assigned < times[best].assigned) then
          best = channel
        end
      end
    end
    times[best].assigned = next_tick()
    return best
  end

  local function remove_expressing(record)
    for index, entry in ipairs(state.expressing) do
      if entry == record then
        table.remove(state.expressing, index)
        if index < state.cursor then state.cursor = state.cursor - 1 end
        return
      end
    end
  end

  -- A note whose device left the port: marked departed, out of the
  -- expression list and the port's counts and channel use, so no off or
  -- value of it goes to whatever holds the port now, and its channel owed
  -- an all notes off where key (the device's name) next arrives. A note
  -- that reached no device (key nil, #748) is owed to none
  local function set_aside(record, key)
    record.departed = true
    remove_expressing(record)
    local counts = table_at(state.counts, record.port, record.channel)
    counts[record.note] = (counts[record.note] or 1) - 1
    if counts[record.note] <= 0 then counts[record.note] = nil end
    local use = table_at(state.use, record.port)
    use[record.channel] = (use[record.channel] or 1) - 1
    if use[record.channel] <= 0 then use[record.channel] = nil end
    if key ~= nil then table_at(state.left_with, key)[record.channel] = true end
  end

  -- The notes on port that went to a device the port no longer holds (a
  -- move in SYSTEM > DEVICES changes the vports at once, but is told only
  -- as the menu closes): set aside before a note on the port ends or
  -- starts, so an off due mid-menu never reaches the device that came. A
  -- note sent while the port was empty names no device: once the port
  -- holds one it is set aside too, owed to none (#748)
  local function settle_moved(port)
    local now = S.lib.io_ports.device(port)
    for voice = 1, NUM_VOICES do
      for _, record in pairs(state.notes[voice]) do
        if record.port == port and not record.departed and record.device ~= now then
          set_aside(record, record.device)
        end
      end
    end
  end

  local function end_note(voice, id)
    local record = state.notes[voice][id]
    if not record then return end
    settle_moved(record.port)
    state.notes[voice][id] = nil
    remove_expressing(record)
    -- its device left the port, which dropped its counts: nothing to send
    if record.departed then return end
    -- a played note leaving a shared member channel: the played notes still
    -- on it forget what they last sent, so the step sends their values once
    -- and the channel goes back to what they hold (a step note sent nothing
    -- on a shared channel, so its end puts nothing back)
    if record.owner ~= nil then
      for _, other in ipairs(state.expressing) do
        if other.port == record.port and other.channel == record.channel then other.sent = {} end
      end
    end
    local counts = table_at(state.counts, record.port, record.channel)
    -- the last id on the note sends its off; one ending while another
    -- holds the note sends nothing (every start there sent an off first)
    counts[record.note] = (counts[record.note] or 1) - 1
    if counts[record.note] <= 0 then
      counts[record.note] = nil
      send(record.port, "note_off", record.note, 0, record.channel)
    end
    local use = table_at(state.use, record.port)
    use[record.channel] = (use[record.channel] or 1) - 1
    if use[record.channel] <= 0 then
      use[record.channel] = nil
      if record.mpe then table_at(state.member_times, record.port)[record.channel].released = next_tick() end
    end
  end

  -- The port Strata's MIDI input listens to (plan ruling 17)
  local function input_port()
    local port = param_value("midi_device")
    return port and util.round(port) or nil
  end

  local function start_note(voice, id, pitch, velocity, info)
    if state.stopped or not valid_voice(voice) or not finite(pitch) then return end
    info = type(info) == "table" and info or {}
    local config = state.config[voice]
    if config.port == 0 then return end
    if info.source == MIDI_OUT.played_source and config.port == input_port() then return end
    end_note(voice, id)
    settle_moved(config.port)
    local note = util.clamp(round(pitch), 0, MIDI_OUT.notes - 1)
    local level = util.clamp(math.max(1, round((finite(velocity) and velocity or 1) * MIDI_OUT.value_max)), 1,
      MIDI_OUT.value_max)
    local mpe = is_mpe(config)
    local channel = mpe and allocate(config.port, config.members) or config.channel
    local record = {voice = voice, port = config.port, device = S.lib.io_ports.device(config.port),
      channel = channel, note = note, mpe = mpe, sent = {}}
    local counts = table_at(state.counts, config.port, channel)
    local use = table_at(state.use, config.port)
    -- the note already sounds there (#709): a retrigger, its off before
    -- anything else this id sends on the channel
    if (counts[note] or 0) > 0 then send(config.port, "note_off", note, 0, channel) end
    if mpe then
      -- a played note's first values, then its note on; a step note's
      -- centered bend only on a channel no other id holds (on a shared one
      -- it takes the channel as it is)
      local raw
      local played = info.source == MIDI_OUT.played_source
      if played then
        record.owner, record.key = info.owner, info.key
        raw = S.lib.expression.raw(voice, info.owner, info.key)
        table.insert(state.expressing, record)
      end
      if played or (use[channel] or 0) == 0 then
        for _, field in ipairs(MIDI_OUT.fields) do
          local value = encoded(field, raw or {})
          if value ~= nil then
            send_field(record, field, value)
            record.sent[field] = value
          end
        end
      end
      -- a played note's first values stand on a shared channel: the other
      -- played notes there are taken as having sent their current values
      -- (a resend pending since a note on it ended is canceled; a later
      -- change of theirs still goes)
      if played then
        for _, other in ipairs(state.expressing) do
          if other ~= record and other.port == record.port and other.channel == channel then
            local now = S.lib.expression.raw(other.voice, other.owner, other.key)
            for _, field in ipairs(now and MIDI_OUT.fields or {}) do
              local value = encoded(field, now)
              if value ~= nil then other.sent[field] = value end
            end
          end
        end
      end
    end
    counts[note] = (counts[note] or 0) + 1
    use[channel] = (use[channel] or 0) + 1
    state.notes[voice][id] = record
    send(config.port, "note_on", note, level, channel)
  end

  -- The step's expression (build ruling 9): each played MPE note's bend, pressure
  -- and slide as raw has them now, each sent when its outgoing value is not
  -- the one the note last sent, at most express_per_step a step, from the
  -- note the last step stopped at. Each expressing note's port is settled
  -- first, in port order (#749): a note whose device moved is set aside,
  -- so its values never reach the device that took its port
  local function express_step()
    local list = state.expressing
    if #list == 0 then return end
    local ports = state.express_ports
    for port in pairs(ports) do ports[port] = nil end
    for _, record in ipairs(list) do ports[record.port] = true end
    for port = 1, S.lib.io_ports.PORTS.count do
      if ports[port] then settle_moved(port) end
    end
    local count = #list
    if count == 0 then return end
    if state.cursor < 1 or state.cursor > count then state.cursor = 1 end
    local budget, index = MIDI_OUT.express_per_step, state.cursor
    for _ = 1, count do
      local record = list[index]
      local raw = S.lib.expression.raw(record.voice, record.owner, record.key)
      if raw then
        for _, field in ipairs(MIDI_OUT.fields) do
          local value = encoded(field, raw)
          if value ~= nil and value ~= record.sent[field] then
            if budget == 0 then
              state.cursor = index
              return
            end
            send_field(record, field, value)
            record.sent[field] = value
            budget = budget - 1
          end
        end
      end
      index = index % count + 1
    end
    state.cursor = index
  end

  S.register_note_target({name = "midi",
    routed = function(voice) return valid_voice(voice) and state.config[voice].port > 0 end,
    note_on = start_note,
    note_off = function(voice, id)
      if valid_voice(voice) then end_note(voice, id) end
    end,
    rows = function(voice)
      if not valid_voice(voice) then return {} end
      return {{label = "midi", kind = "detail", id = "midi",
        text = function()
          local config = state.config[voice]
          if config.port == 0 then return "off" end
          if is_mpe(config) then return "port " .. config.port .. "  mpe " .. config.members end
          return "port " .. config.port .. "  ch " .. config.channel
        end,
        fields = {{label = "port", kind = "param", param_id = vid(voice, "port")},
          {label = "channel", kind = "param", param_id = vid(voice, "channel")},
          {label = "mode", kind = "param", param_id = vid(voice, "mode")},
          {label = "members", kind = "param", param_id = vid(voice, "members")}}}}
    end,
    -- The voice section's look with this row's list open (the IO page lists
    -- it with that section's): voice 1 on port 2's synth, the row reached
    -- as a player does (S.lib.pages_io.go_to_row raises when it cannot)
    layout_states = {
      {name = "midi detail list open", setup = function(context)
        context.midi.plug(2, "synth")
        params:set(vid(1, "port"), 2); params:set(vid(1, "channel"), 3)
        context.clock.advance_until(S.lfo_clock)
        S.lib.pages_io.go_to_row("midi", "voice", {id = "midi"})
        key(3, 1); key(3, 0)
      end},
    },
  })

  ---------------------------------------------------------------------------
  -- CC out, from the step
  ---------------------------------------------------------------------------

  local function slot_key(k)
    if not params.lookup[slot_id(k, "source")] then return "off" end
    return S.lib.io_keyed.key(slot_id(k, "source"))
  end

  local function cc_step()
    local sent = 0
    for k = 1, MIDI_OUT.slots do
      if sent >= MIDI_OUT.cc_per_step then return end
      local key = slot_key(k)
      local port = param_value(slot_id(k, "port"))
      if key ~= "off" and port and present(port) then
        local value = util.clamp(round(S.lib.mod_sources.fraction(key) * MIDI_OUT.value_max), 0, MIDI_OUT.value_max)
        if value ~= state.cc_last[k] then
          send(port, "cc", params:get(slot_id(k, "number")), value, params:get(slot_id(k, "channel")))
          state.cc_last[k] = value
          sent = sent + 1
        end
      end
    end
  end

  -- The routes settle at a step when a route param changed since the last
  -- settle (build ruling 25; settle is below, with the params)
  local settle
  S.lib.lfos.on_step(function()
    if state.stopped then return end
    if state.dirty then settle(false) end
    express_step()
    cc_step()
  end)

  ---------------------------------------------------------------------------
  -- Program change
  ---------------------------------------------------------------------------

  -- lib/midi_in.lua's program change (0 to NUM_SCENES - 1, wanted by
  -- midi_pc_in and midi_pc_channel) on the port it listens to: the scene
  -- recalled as a scene key does, and its program change not sent back to
  -- that port (build ruling 20): the port's one guard, asked[port] = scene, set
  -- before the recall is asked for (with quantize off it lands inside that
  -- call); a refused one (an empty scene) puts the port's earlier guard
  -- back, so the guard is set only for a recall that was asked for; a newer
  -- program change on the port replaces it
  function M.program_change_in(port, value)
    if state.stopped or type(value) ~= "number" or value % 1 ~= 0 then return false end
    local scene, previous = value + 1, state.asked[port]
    state.asked[port] = scene
    local recalled = S.lib.io_actions.recall_scene(scene)
    -- refused (an empty scene): the guard of a recall still waiting stays
    if not recalled and state.asked[port] == scene then state.asked[port] = previous end
    return recalled
  end

  -- A recall consumes every guard for its own scene, and sends nothing on
  -- a port one of them names; a recall of another scene sends its program
  -- change and leaves the guards alone, so the recall one waits for still
  -- does not echo when it lands
  S.register_scene_recalled(function(scene)
    local guarded = {}
    for port, asked in pairs(state.asked) do
      if asked == scene then
        guarded[port] = true
        state.asked[port] = nil
      end
    end
    if state.stopped or param_value("midi_pc_out") ~= 1 then return end
    local port = params:get("midi_pc_out_port")
    if guarded[port] then return end
    send(port, "program_change", scene - 1, params:get("midi_pc_out_channel"))
  end)

  ---------------------------------------------------------------------------
  -- A device leaving and returning
  ---------------------------------------------------------------------------

  -- A device leaving a port (departed_name: the one S.lib.io_ports last saw
  -- there). Its notes are the port's notes that the device now on the port
  -- did not get (a move in SYSTEM > DEVICES changes the vports before it is
  -- told, so a note sent meanwhile went to the device that came; during an
  -- unplug the port names none): each is set aside (above), owed to the
  -- device that got it; a note that names none reached no device and is
  -- owed to none (#748)
  local function departed(port)
    local now = S.lib.io_ports.device(port)
    for voice = 1, NUM_VOICES do
      for _, record in pairs(state.notes[voice]) do
        if record.port == port and not record.departed and (now == nil or record.device ~= now) then
          set_aside(record, record.device)
        end
      end
    end
  end

  -- A device arriving: all notes off where it is now on the channels it
  -- left with (by its name, wherever it was), or what a departure that
  -- named no device left on this port
  local function arrived_channels(port, name)
    local channels = {}
    for _, key in ipairs({name, "port " .. port}) do
      for channel in pairs(state.left_with[key] or {}) do channels[channel] = true end
      state.left_with[key] = nil
    end
    return channels
  end

  S.lib.io_ports.on_change("io_midi_out", function(port, name)
    if state.stopped then return end
    if name == nil then
      departed(port)
    else
      local channels = arrived_channels(port, name)
      for channel = 1, MIDI_OUT.channels do
        if channels[channel] then send(port, "cc", MIDI_OUT.all_notes_off_cc, 0, channel) end
      end
      for voice = 1, NUM_VOICES do
        local config = state.config[voice]
        if is_mpe(config) and config.port == port then setup(port, config.members) end
      end
      for k = 1, MIDI_OUT.slots do
        if param_value(slot_id(k, "port")) == port then state.cc_last[k] = nil end
      end
    end
    request_redraw()
  end)

  ---------------------------------------------------------------------------
  -- Params (PSET-only, group strata_out_midi)
  ---------------------------------------------------------------------------

  -- What a voice's notes go to (the review's finding 2): off, or the port
  -- with its channel (plain) or its zone's members (MPE). A param change
  -- that leaves it alone (a channel while the port is 0, members on a plain
  -- voice, a channel on an MPE voice) ends no note on any target
  local function route_text(config)
    if config.port == 0 then return "off" end
    if is_mpe(config) then return config.port .. " mpe " .. config.members end
    return config.port .. " ch " .. config.channel
  end

  -- Routes settle (build ruling 25). A route param's action (a voice's port,
  -- channel, mode or members, and the bend range) only notes the change:
  -- it refuses nothing, flashes nothing and sends nothing. settle compares
  -- the params with the settled routes (state.config, which every note,
  -- routed, the rows and the zones read) and applies the difference once.
  -- It runs once at the end of add_params (the routes at start), from the
  -- PSET read hook (a read is one synchronous call, so every route line of
  -- the file is judged together, whatever their order) and from the LFO
  -- step after a change made outside a read
  local ROUTE_FIELDS = {"port", "channel", "mode", "members"}
  local BEND_RANGE_ID = "midi_out_bend_range"
  local route_param = {}  -- param id -> {voice, field}
  for voice = 1, NUM_VOICES do
    for _, field in ipairs(ROUTE_FIELDS) do route_param[vid(voice, field)] = {voice = voice, field = field} end
  end

  local function note_change(id)
    state.noted[id] = true
    state.dirty = true
  end

  -- The value a noted param had at the last settle
  local function settled_value(id)
    if id == BEND_RANGE_ID then return state.bend_range end
    local where = route_param[id]
    return state.config[where.voice][where.field]
  end

  local function param_routes()
    local routes = {}
    for voice = 1, NUM_VOICES do
      routes[voice] = {}
      for _, field in ipairs(ROUTE_FIELDS) do routes[voice][field] = params:get(vid(voice, field)) end
    end
    return routes
  end

  -- An illegal set from a read (build ruling 19): the voices in index order, one
  -- that conflicts with those placed before it turned off (port 0), its
  -- other values kept
  local function placed_in_order(routes)
    local placed = {}
    for voice = 1, NUM_VOICES do
      local route = routes[voice]
      placed[voice] = {port = 0, channel = route.channel, mode = route.mode, members = route.members}
    end
    for voice = 1, NUM_VOICES do
      local off = placed[voice]
      placed[voice] = routes[voice]
      if conflict(placed) then placed[voice] = off end
    end
    return placed
  end

  -- port -> {voice, members}: the MPE zones a set of routes makes
  local function zones_of(routes)
    local zones = {}
    for voice = 1, NUM_VOICES do
      if is_mpe(routes[voice]) then zones[routes[voice].port] = {voice = voice, members = routes[voice].members} end
    end
    return zones
  end

  -- The new routes over the settled ones, once: each voice whose route
  -- changed has its notes ended (offs to where the ons went), then each
  -- port whose zone went away or passed to another voice gets one
  -- takedown, and each whose zone arrived, passed or changed (members, or
  -- the bend range) one setup, for the final state only
  local function apply(routes, bend_range)
    local new = {}
    for voice = 1, NUM_VOICES do
      local route = routes[voice]
      new[voice] = {port = route.port, channel = route.channel, mode = route.mode, members = route.members}
    end
    local before, after = zones_of(state.config), zones_of(new)
    local changed = false
    for voice = 1, NUM_VOICES do
      if route_text(state.config[voice]) ~= route_text(new[voice]) then S.lib.io_targets.route_changed(voice) end
      for _, field in ipairs(ROUTE_FIELDS) do changed = changed or state.config[voice][field] ~= new[voice][field] end
    end
    local bend_changed = bend_range ~= state.bend_range
    state.bend_range = bend_range
    for port = 1, S.lib.io_ports.PORTS.count do
      local was, now = before[port], after[port]
      if was and (not now or now.voice ~= was.voice) then takedown(port) end
    end
    for port = 1, S.lib.io_ports.PORTS.count do
      local was, now = before[port], after[port]
      if now and (not was or was.voice ~= now.voice or was.members ~= now.members or bend_changed) then
        setup(port, now.members)
      end
    end
    state.config = new
    -- the rows show the settled routes: a redraw only when they changed (the
    -- settle at start, inside init's params, changes nothing by default)
    if changed or bend_changed then request_redraw() end
  end

  -- An illegal set at a step (a change by hand, or by anything outside a
  -- read): the route params noted since the last settle go back to their
  -- settled values, silently, with the refusal's flash, and no route
  -- changes (a bend range noted beside them stands). From a read: build ruling
  -- 19's placing, with one flash
  settle = function(from_read)
    if state.stopped or not params.lookup[vid(1, "port")] then return end
    local routes = param_routes()
    local refused = conflict(routes) ~= nil
    if refused and not from_read then
      -- the route params go back; a bend range noted beside them cannot
      -- conflict, so it stands and is applied (each zone's one setup)
      for id in pairs(state.noted) do
        if route_param[id] then params:set(id, settled_value(id), true) end
      end
      state.noted, state.dirty = {}, false
      S.lib.ui_flash.start("header", MIDI_OUT.refused)
      apply(param_routes(), params:get(BEND_RANGE_ID))
      return
    end
    if refused then
      routes = placed_in_order(routes)
      for voice = 1, NUM_VOICES do params:set(vid(voice, "port"), routes[voice].port, true) end
    end
    state.noted, state.dirty = {}, false
    apply(routes, params:get(BEND_RANGE_ID))
    if refused then S.lib.ui_flash.start("header", MIDI_OUT.refused) end
  end

  -- After every PSET read, silent or not: the file's routes are in the
  -- params (a line the file lacks at its default, #628), and settle judges
  -- them together. A silent read runs no action, so it notes nothing, but
  -- its routes settle here all the same
  S.register_pset_hook({name = "io_midi_out", read = function() settle(true) end})

  -- A port's number, with its owner beside it while one holds it (as
  -- SETUP's midi row shows it)
  local function port_text(param)
    local port = param:get()
    if port == 0 then return "off" end
    local owner = S.lib.io_ports.owner(port)
    return owner and (port .. " (" .. owner .. ")") or tostring(port)
  end

  local function slot_changed(k) return function() state.cc_last[k] = nil end end

  function M.add_params()
    local keys = {"off"}
    for _, record in ipairs(S.lib.mod_sources.registered()) do keys[#keys + 1] = record.key end
    local port_count = S.lib.io_ports.PORTS.count
    params:add_group("strata_out_midi", "out midi", MIDI_OUT.param_count)
    for voice = 1, NUM_VOICES do
      local name = "v" .. voice .. " out "
      local function changed(field) return function() note_change(vid(voice, field)) end end
      params:add{type = "number", id = vid(voice, "port"), name = name .. "port", min = 0, max = port_count,
        default = 0, formatter = port_text, action = changed("port")}
      params:add{type = "number", id = vid(voice, "channel"), name = name .. "channel", min = 1,
        max = MIDI_OUT.channels, default = voice, action = changed("channel")}
      params:add{type = "option", id = vid(voice, "mode"), name = name .. "mode", options = MIDI_OUT.modes,
        default = 1, action = changed("mode")}
      params:add{type = "number", id = vid(voice, "members"), name = name .. "members", min = 1,
        max = MIDI_OUT.max_members, default = MIDI_OUT.max_members, action = changed("members")}
    end
    params:add{type = "number", id = BEND_RANGE_ID, name = "out bend range", min = MIDI_OUT.bend_range.min,
      max = MIDI_OUT.bend_range.max, default = MIDI_OUT.bend_range.default,
      action = function() note_change(BEND_RANGE_ID) end}
    for k = 1, MIDI_OUT.slots do
      local name = "cc " .. k .. " "
      -- kept by key, so a source a later release registers never moves a saved choice
      S.lib.io_keyed.add(slot_id(k, "source"), name .. "source", keys, keys, function()
        state.cc_last[k] = nil
        request_redraw()
      end)
      params:add{type = "number", id = slot_id(k, "port"), name = name .. "port", min = 1, max = port_count, default = 1,
        formatter = port_text, action = slot_changed(k)}
      params:add{type = "number", id = slot_id(k, "channel"), name = name .. "channel", min = 1,
        max = MIDI_OUT.channels, default = 1, action = slot_changed(k)}
      params:add{type = "number", id = slot_id(k, "number"), name = name .. "number", min = 0,
        max = MIDI_OUT.value_max, default = k, action = slot_changed(k)}
    end
    local channels = {"any"}
    for channel = 1, MIDI_OUT.channels do channels[#channels + 1] = tostring(channel) end
    params:add{type = "binary", behavior = "toggle", id = "midi_pc_in", name = "program change in", default = 0}
    params:add{type = "option", id = "midi_pc_channel", name = "program change channel", options = channels, default = 1}
    params:add{type = "binary", behavior = "toggle", id = "midi_pc_out", name = "program change out", default = 0}
    params:add{type = "number", id = "midi_pc_out_port", name = "program change out port", min = 1, max = port_count,
      default = 1, formatter = port_text}
    params:add{type = "number", id = "midi_pc_out_channel", name = "program change out channel", min = 1,
      max = MIDI_OUT.channels, default = 1}
    -- The routes at start (#709): settled from the params as they stand now,
    -- judged as a read's are, so state.config never holds values of its own.
    -- Init adds the params before any start step and nothing sets them
    -- before the first, and a later change is noted and settles at a step
    settle(true)
  end

  ---------------------------------------------------------------------------
  -- IO's midi section
  ---------------------------------------------------------------------------

  -- A slot following an LFO the engine runs sends Lua's model of it (decision 20): ~
  local function approximate(key)
    local lfo = tonumber(key:match("^lfo(%d+)$"))
    return lfo ~= nil and S.lib.lfos.is_engine_run(lfo)
  end

  local function slot_text(k)
    local key = slot_key(k)
    if key == "off" then return "off" end
    return key .. "  p" .. params:get(slot_id(k, "port")) .. " ch" .. params:get(slot_id(k, "channel")) .. " #"
      .. params:get(slot_id(k, "number")) .. (approximate(key) and MIDI_OUT.approximate or "")
  end

  -- The ports a setting sends on
  local function ports_in_use()
    local ports = {}
    for voice = 1, NUM_VOICES do
      if state.config[voice].port > 0 then ports[state.config[voice].port] = true end
    end
    for k = 1, MIDI_OUT.slots do
      if slot_key(k) ~= "off" then ports[params:get(slot_id(k, "port"))] = true end
    end
    if param_value("midi_pc_out") == 1 then ports[params:get("midi_pc_out_port")] = true end
    return ports
  end

  local BINARY = {[0] = "off", [1] = "on"}

  local function set_option(id, text)
    for index, name in ipairs(params:lookup_param(id).options) do
      if name == text then params:set(id, index) end
    end
  end

  -- An MPE voice and a plain voice on port 2, a slot and program change
  -- out, settled at one step (build ruling 25) so the rows show them
  local function a_setting(context)
    params:set(vid(1, "port"), 2)
    params:set(vid(2, "port"), 2); params:set(vid(2, "channel"), 16)
    params:set(vid(1, "members"), 7); params:set(vid(1, "mode"), MIDI_OUT.mpe_mode)
    params:set(slot_id(1, "port"), 2); params:set(slot_id(1, "channel"), 3); params:set(slot_id(1, "number"), 20)
    set_option(slot_id(1, "source"), "lfo1")
    params:set("midi_pc_out", 1); params:set("midi_pc_out_port", 2)
    context.clock.advance_until(S.lfo_clock)
  end

  S.register_io_section({name = "midi", title = "midi out",
    rows = function()
      local rows = {{label = "bend range", kind = "param", param_id = "midi_out_bend_range", format = "%d st"}}
      for k = 1, MIDI_OUT.slots do
        rows[#rows + 1] = {label = "cc " .. k, kind = "detail", id = "cc " .. k,
          text = function() return slot_text(k) end,
          fields = {{label = "source", kind = "param", param_id = slot_id(k, "source")},
            {label = "port", kind = "param", param_id = slot_id(k, "port")},
            {label = "channel", kind = "param", param_id = slot_id(k, "channel")},
            {label = "number", kind = "param", param_id = slot_id(k, "number")}}}
      end
      rows[#rows + 1] = {label = "pc in", kind = "param", param_id = "midi_pc_in", binary = BINARY}
      rows[#rows + 1] = {label = "pc channel", kind = "param", param_id = "midi_pc_channel"}
      rows[#rows + 1] = {label = "pc out", kind = "param", param_id = "midi_pc_out", binary = BINARY}
      rows[#rows + 1] = {label = "pc out port", kind = "param", param_id = "midi_pc_out_port"}
      rows[#rows + 1] = {label = "pc out channel", kind = "param", param_id = "midi_pc_out_channel"}
      return rows
    end,
    status = function()
      for port in pairs(ports_in_use()) do
        -- [--] means no device, so a port a remote holds is not one
        if S.lib.io_ports.device(port) == nil then return MIDI_OUT.absent end
      end
      return nil
    end,
    layout_states = {
      {name = "without its device", setup = a_setting},
      {name = "with its device", setup = function(context)
        context.midi.plug(2, "synth")
        a_setting(context)
      end},
      {name = "a detail list open", setup = function(context)
        context.midi.plug(2, "synth")
        a_setting(context)
        S.lib.pages_io.show_section("midi")
        enc(2, 1)
        key(3, 1); key(3, 0)
      end},
    }})

  ---------------------------------------------------------------------------
  -- Cleanup and the invariant
  ---------------------------------------------------------------------------

  -- Cleanup's step (after the targets ended every note): the express
  -- queue dropped, and nothing more is sent
  function M.stop()
    state.stopped = true
    state.expressing = {}
    state.cursor = 1
    state.asked = {}
  end

  S.register_cleanup(S.constants.CLEANUP_ORDER.io_midi_out, function() M.stop() end)

  S.register_invariant("midi out", function()
    local problem = conflict(state.config)
    if problem then return problem end
    for port, channels in pairs(state.counts) do
      for channel, notes in pairs(channels) do
        for note, count in pairs(notes) do
          if count < 0 then return "port " .. port .. " channel " .. channel .. " note " .. note .. " counts " .. count end
        end
      end
    end
    for port, channels in pairs(state.use) do
      for channel, count in pairs(channels) do
        if count < 0 then return "port " .. port .. " channel " .. channel .. " holds " .. count .. " notes" end
      end
    end
    return nil
  end)

  return M
end

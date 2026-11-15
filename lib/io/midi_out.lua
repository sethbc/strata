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

  -- config[voice]: the applied route {port, channel, mode (an index of
  -- MIDI_OUT.modes), members}; notes[voice][id]: what a note sent {voice,
  -- port, channel, note, mpe, owner, key, sent = {bend, pressure, slide}};
  -- counts[port][channel][note]: the ids sounding there; use[port][channel]:
  -- the notes on a channel; member_times[port][channel] = {released,
  -- assigned}; expressing: the played MPE notes the step reads, cursor the
  -- next to read; cc_last[k]: slot k's last value; left_with[port]: the
  -- channels with notes as the port's device left; asked: the recall a
  -- program change in asked for, {port, scene}
  local state = {config = {}, notes = {}, counts = {}, use = {}, member_times = {}, expressing = {}, cursor = 1,
    cc_last = {}, left_with = {}, asked = nil, tick = 0, stopped = false, bend_range = MIDI_OUT.bend_range.default,
    source_keys = {"off"}}
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

  -- One message on port, through its vport: nothing after cleanup or on port 0
  local function send(port, method, ...)
    if state.stopped or not port or port < 1 then return end
    local vport = S.lib.io_ports.out(port)
    if vport then vport[method](vport, ...) end
  end

  local function present(port) return S.lib.io_ports.device(port) ~= nil end

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

  local function zone_changed(old, new)
    if is_mpe(old) and (not is_mpe(new) or old.port ~= new.port) then takedown(old.port) end
    if is_mpe(new) and (not is_mpe(old) or old.port ~= new.port or old.members ~= new.members) then
      setup(new.port, new.members)
    end
  end

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

  local function end_note(voice, id)
    local record = state.notes[voice][id]
    if not record then return end
    state.notes[voice][id] = nil
    remove_expressing(record)
    local counts = table_at(state.counts, record.port, record.channel)
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

  -- The port Strata's MIDI input listens to (ruling 17)
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
    local note = util.clamp(round(pitch), 0, MIDI_OUT.notes - 1)
    local level = util.clamp(math.max(1, round((finite(velocity) and velocity or 1) * MIDI_OUT.value_max)), 1,
      MIDI_OUT.value_max)
    local mpe = is_mpe(config)
    local channel = mpe and allocate(config.port, config.members) or config.channel
    local record = {voice = voice, port = config.port, channel = channel, note = note, mpe = mpe, sent = {}}
    if mpe then
      -- a played note's first values, then its note on; a step note's centered bend
      local raw
      if info.source == MIDI_OUT.played_source then
        record.owner, record.key = info.owner, info.key
        raw = S.lib.expression.raw(voice, info.owner, info.key)
        table.insert(state.expressing, record)
      end
      for _, field in ipairs(MIDI_OUT.fields) do
        local value = encoded(field, raw or {})
        if value ~= nil then
          send_field(record, field, value)
          record.sent[field] = value
        end
      end
    end
    local counts = table_at(state.counts, config.port, channel)
    counts[note] = (counts[note] or 0) + 1
    local use = table_at(state.use, config.port)
    use[channel] = (use[channel] or 0) + 1
    state.notes[voice][id] = record
    send(config.port, "note_on", note, level, channel)
  end

  -- The step's expression (ruling B): each played MPE note's bend, pressure
  -- and slide as raw has them now, each sent when its outgoing value is not
  -- the one the note last sent, at most express_per_step a step, from the
  -- note the last step stopped at
  local function express_step()
    local list = state.expressing
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

  S.lib.lfos.on_step(function()
    if state.stopped then return end
    express_step()
    cc_step()
  end)

  ---------------------------------------------------------------------------
  -- Program change
  ---------------------------------------------------------------------------

  -- lib/midi_in.lua's program change (0 to NUM_SCENES - 1, wanted by
  -- midi_pc_in and midi_pc_channel) on the port it listens to: the scene
  -- recalled as a scene key does, and its program change not sent back to
  -- that port
  function M.program_change_in(port, value)
    if state.stopped or type(value) ~= "number" or value % 1 ~= 0 then return false end
    state.asked = {port = port, scene = value + 1}
    local recalled = S.lib.io_actions.recall_scene(value + 1)
    if not recalled then state.asked = nil end
    return recalled
  end

  S.register_scene_recalled(function(scene)
    local asked = state.asked
    state.asked = nil
    if state.stopped or param_value("midi_pc_out") ~= 1 then return end
    local port = params:get("midi_pc_out_port")
    if asked and asked.scene == scene and asked.port == port then return end
    send(port, "program_change", scene - 1, params:get("midi_pc_out_channel"))
  end)

  ---------------------------------------------------------------------------
  -- A device leaving and returning
  ---------------------------------------------------------------------------

  local function channels_with_notes(port, set)
    for channel, count in pairs(state.use[port] or {}) do
      if count > 0 then set[channel] = true end
    end
    return set
  end

  S.lib.io_ports.on_change("io_midi_out", function(port, name)
    if state.stopped then return end
    if name == nil then
      state.left_with[port] = channels_with_notes(port, state.left_with[port] or {})
    else
      local channels = channels_with_notes(port, state.left_with[port] or {})
      state.left_with[port] = nil
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

  local FIELD_NAMES = {port = "port", channel = "channel", mode = "mode", members = "members"}

  -- A voice's route param changed: refused (put back silently, with the
  -- flash) when it would break a zone; otherwise its notes end, then the
  -- zone follows
  local function voice_changed(voice, field, value)
    local old = state.config[voice]
    local new = {port = old.port, channel = old.channel, mode = old.mode, members = old.members}
    new[field] = value
    local proposed = {}
    for other = 1, NUM_VOICES do proposed[other] = other == voice and new or state.config[other] end
    if conflict(proposed) then
      params:set(vid(voice, field), old[field], true)
      S.lib.ui_flash.start("header", MIDI_OUT.refused)
      request_redraw()
      return
    end
    state.config[voice] = new
    S.lib.io_targets.route_changed(voice)
    zone_changed(old, new)
    request_redraw()
  end

  local function port_text(param)
    local port = param:get()
    return port == 0 and "off" or tostring(port)
  end

  local function slot_changed(k) return function() state.cc_last[k] = nil end end

  function M.add_params()
    local keys = {"off"}
    for _, record in ipairs(S.lib.mod_sources.registered()) do keys[#keys + 1] = record.key end
    state.source_keys = keys
    local port_count = S.lib.io_ports.PORTS.count
    params:add_group("strata_out_midi", "out midi", MIDI_OUT.param_count)
    for voice = 1, NUM_VOICES do
      local name = "v" .. voice .. " out "
      local function changed(field) return function(value) voice_changed(voice, field, value) end end
      params:add{type = "number", id = vid(voice, "port"), name = name .. FIELD_NAMES.port, min = 0, max = port_count,
        default = 0, formatter = port_text, action = changed("port")}
      params:add{type = "number", id = vid(voice, "channel"), name = name .. FIELD_NAMES.channel, min = 1,
        max = MIDI_OUT.channels, default = voice, action = changed("channel")}
      params:add{type = "option", id = vid(voice, "mode"), name = name .. FIELD_NAMES.mode, options = MIDI_OUT.modes,
        default = 1, action = changed("mode")}
      params:add{type = "number", id = vid(voice, "members"), name = name .. FIELD_NAMES.members, min = 1,
        max = MIDI_OUT.max_members, default = MIDI_OUT.max_members, action = changed("members")}
    end
    params:add{type = "number", id = "midi_out_bend_range", name = "out bend range", min = MIDI_OUT.bend_range.min,
      max = MIDI_OUT.bend_range.max, default = MIDI_OUT.bend_range.default, action = function(value)
        state.bend_range = value
        for voice = 1, NUM_VOICES do
          local config = state.config[voice]
          if is_mpe(config) then setup(config.port, config.members) end
        end
      end}
    for k = 1, MIDI_OUT.slots do
      local name = "cc " .. k .. " "
      -- kept by key, so a source a later release registers never moves a saved choice
      S.lib.io_keyed.add(slot_id(k, "source"), name .. "source", keys, keys, function()
        state.cc_last[k] = nil
        request_redraw()
      end)
      params:add{type = "number", id = slot_id(k, "port"), name = name .. "port", min = 1, max = port_count, default = 1,
        action = slot_changed(k)}
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
      default = 1}
    params:add{type = "number", id = "midi_pc_out_channel", name = "program change out channel", min = 1,
      max = MIDI_OUT.channels, default = 1}
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

  local function a_setting()
    params:set(vid(1, "port"), 2)
    params:set(vid(2, "port"), 2); params:set(vid(2, "channel"), 16)
    params:set(vid(1, "members"), 7); params:set(vid(1, "mode"), MIDI_OUT.mpe_mode)
    params:set(slot_id(1, "port"), 2); params:set(slot_id(1, "channel"), 3); params:set(slot_id(1, "number"), 20)
    set_option(slot_id(1, "source"), "lfo1")
    params:set("midi_pc_out", 1); params:set("midi_pc_out_port", 2)
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
        if not present(port) then return MIDI_OUT.absent end
      end
      return nil
    end,
    layout_states = {
      {name = "without its device", setup = a_setting},
      {name = "with its device", setup = function(context)
        context.midi.plug(2, "synth")
        a_setting()
      end},
      {name = "a detail list open", setup = function(context)
        context.midi.plug(2, "synth")
        a_setting()
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
    state.asked = nil
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

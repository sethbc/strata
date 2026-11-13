-- lib/mpe.lua
-- MPE (3.5, design §5.1 and §5.4), S.lib.mpe: the lower and upper zones
-- (a master channel and member channels), the per-channel bend, pressure and
-- slide last received, RPN 6 (a zone's member count) and RPN 0 (a bend
-- range), CC87's high-resolution prefix, and which voices a note plays. Pure
-- functions and one state table: it sends no engine command and plays
-- nothing; lib/midi_in.lua calls it. Adds the MPE params of the midi group
-- (add_midi_params, called inside lib/params_setup.lua's midi record) and the
-- group strata_zones (add_params). See docs/notes/lua/mpe.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- The module's constants: the CCs it reads, the master channels' default
  -- bend range, the channels, the zone member limit, the RPN numbers and the
  -- 14-bit bend's center
  local MPE = {slide_cc = 74, fine_cc = 87, master_bend = 2,
    channels = 16, lower_master = 1, upper_master = 16, max_members = 15, max_total_members = 14,
    rpn_msb_cc = 101, rpn_lsb_cc = 100, data_msb_cc = 6, data_lsb_cc = 38, rpn_bend_range = 0, rpn_zone = 6,
    rpn_null = 127, bend_center = 8192, bend_max = 16383, fine_scale = 16383,
    modes = {selected = 3, split = 4}, zone_options = {"off", "lower", "upper"},
    default_zone = {"lower", "upper"}}
  M.MPE = MPE

  -- Per channel: raw bend (14 bits), pressure and slide (0-1), fine (CC87's
  -- pending low bits), rpn_msb and rpn_lsb (the selected RPN); master_range:
  -- per zone, the master channel's bend range in semitones
  local state = {channel = {}, master_range = {}}

  function M.reset()
    state.channel = {}
    for channel = 1, MPE.channels do
      state.channel[channel] = {bend = MPE.bend_center, slide = 0}
    end
    state.master_range = {lower = MPE.master_bend, upper = MPE.master_bend}
  end
  M.reset()

  local function whole_channel(channel)
    return type(channel) == "number" and channel % 1 == 0 and channel >= 1 and channel <= MPE.channels
  end

  function M.active()
    local mode = params:get("midi_channel_mode")
    return mode == MPE.modes.selected or mode == MPE.modes.split
  end

  -- "lower" or "upper" and whether the channel is the zone's master; nil for
  -- a channel in neither zone (a zone with no members is off, its master too)
  function M.zone(channel)
    if not whole_channel(channel) then return nil end
    local lower = params:get("mpe_lower_members")
    local upper = params:get("mpe_upper_members")
    if upper > 0 then
      if channel == MPE.upper_master then return "upper", true end
      if channel >= MPE.upper_master - upper then return "upper", false end
    end
    if lower > 0 then
      if channel == MPE.lower_master then return "lower", true end
      if channel <= MPE.lower_master + lower then return "lower", false end
    end
    return nil
  end

  -- Every channel of a zone, its master included, ascending: a master's own
  -- bend and range change what a note held on the master plays
  local function zone_channels(zone)
    local list = {}
    for channel = 1, MPE.channels do
      if M.zone(channel) == zone then list[#list + 1] = channel end
    end
    return list
  end

  local function all_members()
    local list = {}
    for channel = 1, MPE.channels do
      local found, master = M.zone(channel)
      if found and not master then list[#list + 1] = channel end
    end
    return list
  end

  -- The voices a note on this channel plays: mpe selected, the selected
  -- voice; mpe split, every voice whose zone is the channel's and whose
  -- range holds the note; nothing outside both zones or the MPE modes
  function M.targets(channel, note)
    local list = {}
    if not M.active() or not whole_channel(channel) then return list end
    if type(note) ~= "number" or note % 1 ~= 0 or note < 0 or note > 127 then return list end
    local zone = M.zone(channel)
    if not zone then return list end
    if params:get("midi_channel_mode") == MPE.modes.selected then
      list[1] = S.selected_voice
      return list
    end
    for voice = 1, NUM_VOICES do
      local prefix = "v" .. voice .. "_zone"
      if params:string(prefix) == zone and note >= params:get(prefix .. "_low") and note <= params:get(prefix .. "_high") then
        list[#list + 1] = voice
      end
    end
    return list
  end

  local function ratio(raw, range)
    return 2 ^ (((raw - MPE.bend_center) / MPE.bend_center) * range / 12)
  end

  -- {bend, pressure, slide}: bend a member's ratio times its zone's master
  -- ratio (a master's is its own), pressure nil until the channel's first
  function M.values(channel)
    if not whole_channel(channel) then return {bend = 1, slide = 0} end
    local own = state.channel[channel]
    local zone, master = M.zone(channel)
    local bend = 1
    if not zone then
      -- outside both zones: a value kept from an earlier layout is not played
    elseif master then
      bend = ratio(own.bend, state.master_range[zone])
    else
      local master_channel = zone == "lower" and MPE.lower_master or MPE.upper_master
      bend = ratio(own.bend, params:get("mpe_bend_range")) *
        ratio(state.channel[master_channel].bend, state.master_range[zone])
    end
    return {bend = bend, pressure = own.pressure, slide = own.slide}
  end

  -- A seven-bit value, or fourteen with the channel's pending CC87 (used once)
  local function take_value(own, value)
    local fine = own.fine
    own.fine = nil
    if fine then return (value * 128 + fine) / MPE.fine_scale end
    return value / 127
  end

  local function rpn_data(channel, value)
    local own = state.channel[channel]
    if own.rpn_msb ~= 0 then return {} end
    local zone, master = M.zone(channel)
    if own.rpn_lsb == MPE.rpn_zone then
      local name
      if channel == MPE.lower_master then name = "lower" elseif channel == MPE.upper_master then name = "upper" end
      if not name then return {} end
      local count = util.clamp(value, 0, MPE.max_members)
      params:set(name == "lower" and "mpe_lower_members" or "mpe_upper_members", count)
      if S.lib.ui_flash then S.lib.ui_flash.start("header", "MPE " .. name .. " " .. count) end
      return {}
    elseif own.rpn_lsb == MPE.rpn_bend_range then
      if not zone then return {} end
      if master then
        state.master_range[zone] = util.clamp(value, 0, 96)
        return zone_channels(zone)
      end
      params:set("mpe_bend_range", util.clamp(value, 1, 96))
      return all_members()
    end
    return {}
  end

  local function control_change(msg)
    local channel, number, value = msg.ch, msg.cc, msg.val
    if not whole_channel(channel) then return nil end
    local own = state.channel[channel]
    if number == MPE.rpn_msb_cc then own.rpn_msb = value; return {} end
    if number == MPE.rpn_lsb_cc then own.rpn_lsb = value; return {} end
    if number == MPE.data_lsb_cc then return {} end
    if number == MPE.data_msb_cc then return rpn_data(channel, value) end
    if number ~= MPE.slide_cc and number ~= MPE.fine_cc then return nil end
    local zone, master = M.zone(channel)
    if not zone or master then return {} end
    if number == MPE.fine_cc then own.fine = value; return {} end
    own.slide = take_value(own, value)
    return {channel}
  end

  -- Apply an MPE message: the list of channels whose values changed, or nil
  -- when it is not MPE's (outside the MPE modes, a note, key pressure, a CC
  -- that is no MPE one). An MPE message with nothing to change gives {}.
  function M.control(msg)
    if not M.active() or type(msg) ~= "table" then return nil end
    if msg.type == "cc" then return control_change(msg) end
    local channel = msg.ch
    if msg.type ~= "pitchbend" and msg.type ~= "channel_pressure" then return nil end
    if not whole_channel(channel) then return nil end
    local zone, master = M.zone(channel)
    if not zone then return {} end
    local own = state.channel[channel]
    if msg.type == "pitchbend" then
      own.bend = util.clamp(msg.val, 0, MPE.bend_max)
      if master then return zone_channels(zone) end
      return {channel}
    end
    if master then return {} end
    own.pressure = take_value(own, msg.val)
    return {channel}
  end

  -- The hooks run after a change of a member count or a zone param
  local layout_hooks, layout_errors = {}, {}

  function M.on_layout_change(fn)
    if type(fn) ~= "function" then error("mpe.on_layout_change: fn is a function", 2) end
    layout_hooks[#layout_hooks + 1] = fn
  end

  -- Each hook runs contained: one that raises is reported and skipped
  local function layout_changed()
    for index, hook in ipairs(layout_hooks) do
      S.lib.ui_frame.contained_call(layout_errors, index, "mpe layout hook", hook)
    end
  end

  -- The member counts never overlap: while both are above 0, setting one
  -- lowers the other so their sum is at most 14 (that set runs its own
  -- action, so its change reaches the hooks once too)
  local function keep_apart(changed, other)
    local count, other_count = params:get(changed), params:get(other)
    if count > 0 and other_count > 0 and count + other_count > MPE.max_total_members then
      params:set(other, math.max(0, MPE.max_total_members - count))
    end
    layout_changed()
  end

  -- Inside the midi group (lib/params_setup.lua sizes it)
  function M.add_midi_params()
    params:add{type = "number", id = "mpe_lower_members", name = "mpe lower members", min = 0,
      max = MPE.max_members, default = MPE.max_members, action = function() keep_apart("mpe_lower_members", "mpe_upper_members") end}
    params:add{type = "number", id = "mpe_upper_members", name = "mpe upper members", min = 0,
      max = MPE.max_members, default = 0, action = function() keep_apart("mpe_upper_members", "mpe_lower_members") end}
    params:add{type = "number", id = "mpe_bend_range", name = "mpe bend range", min = 1, max = 96, default = 48}
  end

  -- The group strata_zones: per voice a zone and its lowest and highest note
  function M.add_params()
    params:add_group("strata_zones", "zones", NUM_VOICES * 3)
    for voice = 1, NUM_VOICES do
      local prefix = "v" .. voice .. "_zone"
      local default = 1
      for index, name in ipairs(MPE.default_zone) do
        if index == voice then default = index + 1; assert(MPE.zone_options[default] == name) end
      end
      params:add{type = "option", id = prefix, name = "voice " .. voice .. " zone", options = MPE.zone_options,
        default = default, action = layout_changed}
      params:add{type = "number", id = prefix .. "_low", name = "voice " .. voice .. " lowest note", min = 0,
        max = 127, default = 0, action = function(low)
          if low > params:get(prefix .. "_high") then params:set(prefix .. "_high", low) end
          layout_changed()
        end}
      params:add{type = "number", id = prefix .. "_high", name = "voice " .. voice .. " highest note", min = 0,
        max = 127, default = 127, action = function(high)
          if high < params:get(prefix .. "_low") then params:set(prefix .. "_low", high) end
          layout_changed()
        end}
    end
  end

  return M
end

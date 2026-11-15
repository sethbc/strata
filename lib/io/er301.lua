-- lib/io/er301.lua
-- The ER-301 as a note target over the ii bus (S.lib.io_er301, 3.6 design
-- 6.3, docs/notes/lua/io/er301.md): a port is one line that plays one note
-- at a time, whatever voices feed it (ruling 10): the newest note's pitch
-- is the port's cv, the trigger high while any note of the line sounds.
-- Every message goes through S.lib.io_ii (another module of this release);
-- where it or the params are absent the device does nothing.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  local ER301 = {
    name = "er301",
    param_count = NUM_VOICES,
    ports = {min = 0, max = 100},   -- 0 is off
    volts = {min = -10, max = 10},  -- the SC.CV range
    labels = {off = "off", port = "port %d", row = "er-301"},
  }
  M.ER301 = ER301

  -- lines[port] = the notes sounding on the port, oldest first, each
  -- {voice, id, pitch}. A note stays on the port it started on until it
  -- ends, whatever its voice's param says by then.
  local lines = {}

  local function param_id(voice) return "v" .. voice .. "_out_er301" end

  local function port_of(voice)
    if not (params.lookup and params.lookup[param_id(voice)]) then return 0 end
    return params:get(param_id(voice))
  end

  local function bus() return S.lib.io_ii end

  local function valid_voice(voice)
    return type(voice) == "number" and voice >= 1 and voice <= NUM_VOICES and voice == math.floor(voice)
  end

  local function clamp_volts(volts)
    return math.max(ER301.volts.min, math.min(ER301.volts.max, volts))
  end

  local function send_pitch(port, pitch)
    bus().send("er301", "cv", port, clamp_volts(S.lib.io_targets.volts(pitch)))
  end

  -- The line and index of voice's note id, or nil
  local function find(voice, id)
    for port, notes in pairs(lines) do
      for index, note in ipairs(notes) do
        if note.voice == voice and note.id == id then return port, index end
      end
    end
    return nil
  end

  -- Take a note off its line: the line's pitch goes to the newest left,
  -- its trigger low when it was the last. No-op for a note not held.
  local function release(voice, id)
    local port, index = find(voice, id)
    if not port then return end
    local notes = lines[port]
    table.remove(notes, index)
    if not bus() then
      if #notes == 0 then lines[port] = nil end
      return
    end
    if #notes == 0 then
      lines[port] = nil
      bus().send_off("er301", "tr", port, 0)
    elseif index == #notes + 1 then
      send_pitch(port, notes[#notes].pitch)
    end
  end

  S.register_note_target({name = "er301",
    routed = function(voice)
      return valid_voice(voice) and bus() ~= nil and port_of(voice) > 0
    end,
    note_on = function(voice, id, pitch)
      if not valid_voice(voice) or not bus() or type(pitch) ~= "number" then return end
      local port = port_of(voice)
      if port <= 0 then return end
      release(voice, id)
      local notes = lines[port] or {}
      local note = {voice = voice, id = id, pitch = pitch}
      table.insert(notes, note)
      lines[port] = notes
      -- the core records a target for a note only when this returned, so a
      -- send that raises must leave the line as it was
      local ok, err = pcall(function()
        send_pitch(port, pitch)
        bus().send("er301", "tr", port, 1)
      end)
      if not ok then
        table.remove(notes)
        if #notes == 0 then lines[port] = nil end
        error(err, 0)
      end
    end,
    note_off = function(voice, id)
      if not valid_voice(voice) then return end
      release(voice, id)
    end,
    stop_all = function()
      local ports = {}
      for port in pairs(lines) do ports[#ports + 1] = port end
      table.sort(ports)
      lines = {}
      if not bus() then return end
      for _, port in ipairs(ports) do bus().send_off("er301", "tr", port, 0) end
    end,
    rows = function(voice)
      if not (valid_voice(voice) and params.lookup and params.lookup[param_id(voice)]) then return {} end
      return {{label = ER301.labels.row, kind = "param", param_id = param_id(voice)}}
    end,
  })

  -- No ready and no release: the device needs no setup, and its notes end
  -- through the targets core before the bus is left.
  S.register_ii_device({name = "er301", param_count = ER301.param_count,
    add_params = function() M.add_params() end})

  -- The seven params, PSET-only, in the ii group (the ii module adds it)
  function M.add_params()
    for voice = 1, NUM_VOICES do
      params:add{type = "number", id = param_id(voice), name = "v" .. voice .. " er-301 port",
        min = ER301.ports.min, max = ER301.ports.max, default = 0,
        formatter = function(param)
          local port = param:get()
          return port == 0 and ER301.labels.off or string.format(ER301.labels.port, port)
        end,
        action = function()
          if S.lib.io_targets and S.lib.io_targets.route_changed then S.lib.io_targets.route_changed(voice) end
        end}
    end
  end

  return M
end

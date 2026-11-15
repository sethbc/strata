-- lib/io/txo.lua
-- The TELEXo as a note target over the ii bus (S.lib.io_txo, 3.6 design
-- 6.3, docs/notes/lua/io/txo.md): a voice plays one of the 32 outputs, the
-- newest note at a time, in pitch mode (the output's cv is the pitch, its
-- trigger the gate) or envelope mode (the cv is the level, the output's
-- envelope the gate). Every message goes through S.lib.io_ii (another
-- module of this release); where it or the params are absent the device
-- does nothing.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  local TXO = {
    name = "txo",
    param_count = NUM_VOICES * 2 + 2,
    outputs = {min = 0, max = 32},            -- 0 is off
    modes = {"pitch", "envelope"},
    envelope_mode = 2,
    volts = {min = -10, max = 10},
    level_volts = 5,                          -- an envelope's full level, at velocity 1
    attack = {min = 1, max = 10000, default = 10},    -- ms
    decay = {min = 1, max = 10000, default = 500},    -- ms
    labels = {off = "off", out = "out %d  %s", row = "txo", attack = "txo attack", decay = "txo decay",
      output = "output", mode = "mode", ms = "%d ms"},
  }
  M.TXO = TXO

  -- Per voice: the notes that sound (oldest first), the output whose
  -- trigger is high and its mode (kept from the first note on, so an off
  -- after a route change lowers what it raised), and the output whose
  -- envelope is set up on the module
  local state = {notes = {}, high = {}, active = {}}
  for voice = 1, NUM_VOICES do state.notes[voice] = {} end

  local function out_id(voice) return "v" .. voice .. "_out_txo" end
  local function mode_id(voice) return "v" .. voice .. "_out_txo_cv" end

  local function has_params()
    return params.lookup ~= nil and params.lookup[out_id(1)] ~= nil
  end

  local function output_of(voice)
    return has_params() and params:get(out_id(voice)) or 0
  end

  local function envelope_of(voice)
    return has_params() and params:get(mode_id(voice)) == TXO.envelope_mode
  end

  local function bus() return S.lib.io_ii end

  local function leading()
    local ii = bus()
    return ii ~= nil and ii.leads() == true
  end

  local function valid_voice(voice)
    return type(voice) == "number" and state.notes[voice] ~= nil
  end

  local function clamp_volts(volts)
    return math.max(TXO.volts.min, math.min(TXO.volts.max, volts))
  end

  local function forget(notes, id)
    for index, note in ipairs(notes) do
      if note.id == id then
        table.remove(notes, index)
        return index
      end
    end
    return nil
  end

  -- What the output's cv says for a note
  local function level_of(high, note)
    if high.envelope then return note.velocity * TXO.level_volts end
    return clamp_volts(S.lib.io_targets.volts(note.pitch))
  end

  ---------------------------------------------------------------------------
  -- The envelope's setup
  ---------------------------------------------------------------------------

  local function envelope_output(voice)
    local output = output_of(voice)
    if output > 0 and envelope_of(voice) then return output end
    return nil
  end

  -- Take a voice's envelope to what its params say: the output it left
  -- gets its envelope off, an envelope output gets the three setup lines
  local function sync_voice(voice)
    if not leading() then return end
    local before, now = state.active[voice], envelope_output(voice)
    if before and before ~= now then bus().send("txo", "env_act", before, 0) end
    if now then
      bus().send("txo", "env_act", now, 1)
      bus().send("txo", "env_att", now, params:get("txo_attack"))
      bus().send("txo", "env_dec", now, params:get("txo_decay"))
    end
    state.active[voice] = now
  end

  local function sync_all()
    if not has_params() then return end
    for voice = 1, NUM_VOICES do sync_voice(voice) end
  end

  local function route_changed(voice)
    local targets = S.lib.io_targets
    if targets and targets.route_changed then targets.route_changed(voice) end
  end

  ---------------------------------------------------------------------------
  -- The note target
  ---------------------------------------------------------------------------

  S.register_note_target({name = "txo",
    routed = function(voice)
      return valid_voice(voice) and bus() ~= nil and output_of(voice) > 0
    end,
    note_on = function(voice, id, pitch, velocity)
      if not valid_voice(voice) or not bus() or type(pitch) ~= "number" then return end
      local high = state.high[voice]
      if not high then
        local output = output_of(voice)
        if output <= 0 then return end
        high = {output = output, envelope = envelope_of(voice)}
      end
      local notes = state.notes[voice]
      forget(notes, id)
      local note = {id = id, pitch = pitch, velocity = type(velocity) == "number" and velocity or 1}
      table.insert(notes, note)
      state.high[voice] = high
      bus().send("txo", "cv", high.output, level_of(high, note))
      if high.envelope then bus().send("txo", "env", high.output, 1) end
      bus().send("txo", "tr", high.output, 1)
    end,
    note_off = function(voice, id)
      if not valid_voice(voice) then return end
      local notes = state.notes[voice]
      local count = #notes
      local index = forget(notes, id)
      local high = state.high[voice]
      if not (index and high and bus()) then return end
      if #notes == 0 then
        state.high[voice] = nil
        bus().send_off("txo", "tr", high.output, 0)
        if high.envelope then bus().send_off("txo", "env", high.output, 0) end
      elseif index == count then
        bus().send("txo", "cv", high.output, level_of(high, notes[#notes]))
      end
    end,
    stop_all = function()
      for voice = 1, NUM_VOICES do
        state.notes[voice] = {}
        local high = state.high[voice]
        state.high[voice] = nil
        if high and bus() then
          bus().send_off("txo", "tr", high.output, 0)
          if high.envelope then bus().send_off("txo", "env", high.output, 0) end
        end
      end
    end,
    rows = function(voice)
      if not (valid_voice(voice) and has_params()) then return {} end
      return {
        {label = TXO.labels.row, kind = "detail", id = TXO.labels.row,
          text = function()
            local output = output_of(voice)
            if output == 0 then return TXO.labels.off end
            return string.format(TXO.labels.out, output, params:string(mode_id(voice)))
          end,
          fields = {{label = TXO.labels.output, kind = "param", param_id = out_id(voice)},
            {label = TXO.labels.mode, kind = "param", param_id = mode_id(voice)}}},
        {label = TXO.labels.attack, kind = "param", param_id = "txo_attack", format = TXO.labels.ms},
        {label = TXO.labels.decay, kind = "param", param_id = "txo_decay", format = TXO.labels.ms},
      }
    end,
  })

  -- ready: the bus is led now, so every envelope voice is set up again;
  -- release: the bus is left, so each envelope that was set up is turned
  -- off (sent direct, since the bus no longer leads)
  S.register_ii_device({name = "txo", param_count = TXO.param_count,
    ready = function()
      for voice = 1, NUM_VOICES do state.active[voice] = nil end
      sync_all()
    end,
    release = function()
      for voice = 1, NUM_VOICES do
        local output = state.active[voice]
        state.active[voice] = nil
        if output and bus() then bus().send_direct("txo", "env_act", output, 0) end
      end
    end,
    add_params = function() M.add_params() end})

  ---------------------------------------------------------------------------
  -- Params (PSET-only, in the ii group the ii module adds)
  ---------------------------------------------------------------------------

  function M.add_params()
    for voice = 1, NUM_VOICES do
      local function changed()
        route_changed(voice)
        sync_voice(voice)
      end
      params:add{type = "number", id = out_id(voice), name = "v" .. voice .. " txo output",
        min = TXO.outputs.min, max = TXO.outputs.max, default = 0,
        formatter = function(param)
          local output = param:get()
          return output == 0 and TXO.labels.off or tostring(output)
        end, action = changed}
      params:add{type = "option", id = mode_id(voice), name = "v" .. voice .. " txo mode",
        options = TXO.modes, default = 1, action = changed}
    end
    for _, field in ipairs({"attack", "decay"}) do
      params:add{type = "number", id = "txo_" .. field, name = "txo " .. field,
        min = TXO[field].min, max = TXO[field].max, default = TXO[field].default,
        formatter = function(param) return string.format(TXO.labels.ms, param:get()) end,
        action = sync_all}
    end
  end

  ---------------------------------------------------------------------------
  -- Layout states: the voice section is the targets module's, which has no
  -- way for a target to add states, so this one adds its own (read when
  -- the IO page's start step builds its list)
  ---------------------------------------------------------------------------

  local function voice_section()
    for _, record in ipairs(S.registry.io_sections or {}) do
      if record.name == "voice" then return record end
    end
  end

  local function open_detail()
    S.lib.pages_io.show_section("voice")
    for index, row in ipairs(S.lib.pages_io.rows()) do
      if row.section == "voice" and row.label == TXO.labels.row then
        local moves = 0
        for at = S.io_cursor + 1, index do
          if S.lib.pages_io.rows()[at].selectable ~= false then moves = moves + 1 end
        end
        enc(2, moves)
        key(3, 1); key(3, 0)
        return
      end
    end
    error("txo layout: the IO page has no txo row", 0)
  end

  local section = voice_section()
  if section then
    section.layout_states = section.layout_states or {}
    table.insert(section.layout_states, {name = "txo on an output", setup = function()
      if not has_params() then return end
      params:set(out_id(1), 3)
      params:set(mode_id(1), TXO.envelope_mode)
    end})
    table.insert(section.layout_states, {name = "txo detail list open", setup = function()
      if not has_params() then return end
      params:set(out_id(1), 3)
      open_detail()
    end})
  end

  return M
end

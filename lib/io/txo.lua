-- lib/io/txo.lua
-- The TELEXo as a note target over the ii bus (S.lib.io_txo, 3.6 design
-- 6.3, docs/notes/lua/io/txo.md): an output is one line that plays one note
-- at a time, whatever voices feed it (ruling 10), in pitch mode (the
-- output's cv is the pitch, its trigger the gate) or envelope mode (the cv
-- is the level, the output's envelope the gate). Every message goes through
-- S.lib.io_ii (another module of this release); where it or the params are
-- absent the device does nothing.

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

  -- lines[output] = {notes = the notes sounding on it, oldest first, each
  -- {voice, id, pitch, velocity, envelope}; env_high = its envelope's gate
  -- was raised}. A note stays on the output and in the mode it started in
  -- until it ends, whatever its voice's params say by then.
  local lines = {}
  -- active[output] = true: the output's envelope is set up on the module
  local active = {}

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
    return type(voice) == "number" and voice >= 1 and voice <= NUM_VOICES and voice == math.floor(voice)
  end

  local function clamp_volts(volts)
    return math.max(TXO.volts.min, math.min(TXO.volts.max, volts))
  end

  -- What the output's cv says for a note, in the mode it started in
  local function level_of(note)
    if note.envelope then return note.velocity * TXO.level_volts end
    return clamp_volts(S.lib.io_targets.volts(note.pitch))
  end

  local function sorted_outputs(map)
    local list = {}
    for output in pairs(map) do list[#list + 1] = output end
    table.sort(list)
    return list
  end

  ---------------------------------------------------------------------------
  -- The envelope's setup: an output's envelope is active while some voice
  -- routed to it is in envelope mode
  ---------------------------------------------------------------------------

  local function envelope_output(voice)
    local output = output_of(voice)
    if output > 0 and envelope_of(voice) then return output end
    return nil
  end

  local function wanted()
    local want = {}
    if not has_params() then return want end
    for voice = 1, NUM_VOICES do
      local output = envelope_output(voice)
      if output then want[output] = true end
    end
    return want
  end

  local function set_up(output)
    bus().send("txo", "env_act", output, 1)
    bus().send("txo", "env_att", output, params:get("txo_attack"))
    bus().send("txo", "env_dec", output, params:get("txo_decay"))
    active[output] = true
  end

  -- Take the module to what the params say: an output no voice needs any
  -- more gets env_act 0 (once), and the outputs named (one voice's, or all
  -- of them) the three setup lines
  local function sync(only_voice)
    if not leading() then return end
    local want = wanted()
    for _, output in ipairs(sorted_outputs(active)) do
      if not want[output] then
        bus().send("txo", "env_act", output, 0)
        active[output] = nil
      end
    end
    if only_voice then
      local output = envelope_output(only_voice)
      if output then set_up(output) end
    else
      for _, output in ipairs(sorted_outputs(want)) do set_up(output) end
    end
  end

  local function route_changed(voice)
    local targets = S.lib.io_targets
    if targets and targets.route_changed then targets.route_changed(voice) end
  end

  ---------------------------------------------------------------------------
  -- The note target
  ---------------------------------------------------------------------------

  local function find(voice, id)
    for output, line in pairs(lines) do
      for index, note in ipairs(line.notes) do
        if note.voice == voice and note.id == id then return output, index end
      end
    end
    return nil
  end

  local function lower(output, line)
    bus().send_off("txo", "tr", output, 0)
    if line.env_high then bus().send_off("txo", "env", output, 0) end
  end

  -- Take a note off its line: the line's cv goes to the newest left (as
  -- that note's own mode says), the trigger (and the envelope's gate) low
  -- when it was the last. No-op for a note not held.
  local function end_note(voice, id)
    local output, index = find(voice, id)
    if not output then return end
    local line = lines[output]
    table.remove(line.notes, index)
    if #line.notes == 0 then lines[output] = nil end
    if not bus() then return end
    if #line.notes == 0 then
      lower(output, line)
    elseif index == #line.notes + 1 then
      bus().send("txo", "cv", output, level_of(line.notes[#line.notes]))
    end
  end

  -- The layout states reach the TELEXo's row as a player does, through
  -- S.lib.pages_io.go_to_row (its id in the voice section), which raises
  -- naming the row when it is not there or the cursor did not land on it
  local function move_to_row()
    S.lib.pages_io.go_to_row("txo", "voice", {id = TXO.labels.row})
  end

  S.register_note_target({name = "txo",
    routed = function(voice)
      return valid_voice(voice) and bus() ~= nil and output_of(voice) > 0
    end,
    note_on = function(voice, id, pitch, velocity)
      if not valid_voice(voice) or not bus() or type(pitch) ~= "number" then return end
      local output = output_of(voice)
      if output <= 0 then return end
      end_note(voice, id)
      local note = {voice = voice, id = id, pitch = pitch, envelope = envelope_of(voice),
        velocity = type(velocity) == "number" and velocity or 1}
      local line = lines[output]
      local created = line == nil
      if created then line = {notes = {}, env_high = false}; lines[output] = line end
      local was_high = line.env_high
      table.insert(line.notes, note)
      -- the core records a target for a note only when this returned, so a
      -- send that raises must leave the line as it was
      local sent_env = false
      local ok, err = pcall(function()
        bus().send("txo", "cv", output, level_of(note))
        if note.envelope then
          bus().send("txo", "env", output, 1)
          sent_env = true
          line.env_high = true
        end
        bus().send("txo", "tr", output, 1)
      end)
      if not ok then
        table.remove(line.notes)
        line.env_high = was_high
        if created then lines[output] = nil end
        -- best effort, each send protected (the first error is the one
        -- raised again), repairing only what reached the device: the newest
        -- left gets its cv back, and an envelope gate this note's env 1
        -- raised is lowered. No trigger repair exists: the trigger is sent
        -- last, and one whose own send raised was not sent
        local newest = line.notes[#line.notes]
        if newest then pcall(function() bus().send("txo", "cv", output, level_of(newest)) end) end
        if sent_env and not was_high then pcall(bus().send_off, "txo", "env", output, 0) end
        error(err, 0)
      end
    end,
    note_off = function(voice, id)
      if not valid_voice(voice) then return end
      end_note(voice, id)
    end,
    stop_all = function()
      local held = lines
      lines = {}
      if not bus() then return end
      for _, output in ipairs(sorted_outputs(held)) do lower(output, held[output]) end
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
    -- The voice section's looks with this target's rows (ruling 11: the IO
    -- page lists them with that section's; they do nothing where the
    -- params were never added)
    layout_states = {
      {name = "txo on an output", setup = function()
        if not has_params() then return end
        params:set(out_id(1), 3)
        params:set(mode_id(1), TXO.envelope_mode)
        move_to_row()
      end},
      {name = "txo detail list open", setup = function()
        if not has_params() then return end
        params:set(out_id(1), 3)
        move_to_row()
        key(3, 1); key(3, 0)
      end},
    },
  })

  -- ready: the bus is led now, so every envelope output is set up again;
  -- release: the bus is left, so each envelope that was set up is turned
  -- off (sent direct, since the bus no longer leads), each output once
  S.register_ii_device({name = "txo", param_count = TXO.param_count,
    ready = function()
      active = {}
      sync()
    end,
    release = function()
      local outputs = sorted_outputs(active)
      active = {}
      if not bus() then return end
      for _, output in ipairs(outputs) do bus().send_direct("txo", "env_act", output, 0) end
    end,
    add_params = function() M.add_params() end})

  ---------------------------------------------------------------------------
  -- Params (PSET-only, in the ii group the ii module adds)
  ---------------------------------------------------------------------------

  function M.add_params()
    for voice = 1, NUM_VOICES do
      local function changed()
        route_changed(voice)
        sync(voice)
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
        action = function() sync() end}
    end
  end

  return M
end

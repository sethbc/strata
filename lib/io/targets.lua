-- lib/io/targets.lua
-- The targets core (3.6, design §3; S.lib.io_targets): the one door through
-- which a voice's pattern steps and played notes reach the note targets
-- (S.register_note_target: MIDI out, crow, Just Friends, W/, ER-301, TELEXo,
-- nb). It keeps per voice the notes it sent on, sounding[voice][id] =
-- {pitch, targets, off_beat}, and sends each note's off to exactly the
-- targets its on went to. Registers the step output targets (at its start
-- step, so after voices), the note hook targets, one LFO step hook (the
-- offs), a voice-stop and a silence hook, IO's voice section, the cleanup
-- step and the invariant "targets".
-- Notes: docs/notes/lua/io/targets.md

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- The targets in the order IO's voice section lists them (a name not
  -- here follows them, in registration order), and the volts convention:
  -- MIDI note 60 is 0 V, 12 notes a volt
  local TARGETS = {order = {"midi", "crow", "jf", "wsyn", "er301", "txo", "nb"}, zero_volt_note = 60,
    notes_per_volt = 12, step_prefix = "s", played_prefix = "m", played_owner = "midi",
    -- beats: the beat read this far before a note's start is a jump back
    -- (its off goes at once); less is a tick's jitter (a late MIDI or crow
    -- tick pulls the beat back a few ms). The sequencer's SEQ.wake_tolerance
    -- (lib/sequencer.lua, included after this module; a test keeps them equal)
    jump_tolerance = 1 / 32,
    -- seconds: a step note ends this long before its gate's end (at most
    -- half the note's length early), about one and a half 48 Hz steps, so a
    -- gate target shows a low before the next step raises it
    step_gap_seconds = 0.03,
    -- IO's mark on a failed target's rows while it is skipped (#880)
    failed_mark = "[error]"}
  M.TARGETS = TARGETS

  -- sounding[voice][id] = {pitch, targets = {name, ...}, off_beat}; offs:
  -- the pending offs, each {voice, id, beat, note} (note the sounding record
  -- it ends); failed[name] while a target that raised is skipped; errors:
  -- contained_call's last message per target
  local sounding, offs, failed, errors = {}, {}, {}, {}
  local section_errors = {}
  for voice = 1, NUM_VOICES do sounding[voice] = {} end

  function M.volts(pitch)
    return (pitch - TARGETS.zero_volt_note) / TARGETS.notes_per_volt
  end

  local function valid_voice(voice)
    return type(voice) == "number" and voice % 1 == 0 and voice >= 1 and voice <= NUM_VOICES
  end

  -- The registered targets: those TARGETS.order names, in its order, then
  -- the others in registration order
  local function ordered_targets()
    local rank = {}
    for index, name in ipairs(TARGETS.order) do rank[name] = index end
    local entries = {}
    for index, target in ipairs(S.registry.note_targets) do
      entries[#entries + 1] = {target = target, rank = rank[target.name] or (#TARGETS.order + index)}
    end
    table.sort(entries, function(a, b) return a.rank < b.rank end)
    local list = {}
    for index, entry in ipairs(entries) do list[index] = entry.target end
    return list
  end

  local function target_named(name)
    for _, target in ipairs(S.registry.note_targets) do
      if target.name == name then return target end
    end
    return nil
  end

  -- One call of a target's field, contained: a target that raises prints
  -- once ("strata: target <name> failed: ...") and is skipped until
  -- clear_failures for starting and expressing notes (routed, note_on,
  -- express); a note_off always goes, so a note it started never hangs.
  -- Returns whether it ran and what it returned
  local ALWAYS = {note_off = true}
  local function call_target(target, field, ...)
    if (failed[target.name] and not ALWAYS[field]) or not target[field] then return false end
    local result
    local ran = S.lib.ui_frame.contained_call(errors, target.name, "target " .. target.name, function(...)
      result = target[field](...)
    end, ...)
    if not ran then failed[target.name] = true end
    return ran, result
  end

  local function clear_failures()
    failed = {}
    errors = {}
  end

  local function routed(target, voice)
    local ran, result = call_target(target, "routed", voice)
    return ran and result == true
  end

  local function drop_off(record)
    for index = #offs, 1, -1 do
      if offs[index].note == record then table.remove(offs, index) end
    end
  end

  -- End voice's note id: its pending off dropped, its off sent to the
  -- targets its on went to (each still registered, failed or not)
  local function end_note(voice, id)
    local record = sounding[voice][id]
    if not record then return end
    sounding[voice][id] = nil
    drop_off(record)
    for _, name in ipairs(record.targets) do
      local target = target_named(name)
      if target then call_target(target, "note_off", voice, id) end
    end
  end

  -- The ids of voice's sounding notes (those of prefix only, when given), sorted
  local function sounding_ids(voice, prefix)
    local ids = {}
    for id in pairs(sounding[voice]) do
      if prefix == nil or id:sub(1, #prefix) == prefix then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
  end

  local function end_voice(voice, prefix)
    for _, id in ipairs(sounding_ids(voice, prefix)) do end_note(voice, id) end
  end

  -- Start voice's note id at pitch: a sounding id ended first; a silenced
  -- voice starts nothing; every routed target gets note_on, and the note
  -- keeps the names of those that took it, with its off due at off_beat
  -- (nil: a played note, ended by its hook) and start_beat the hit's beat
  local function start_note(voice, id, pitch, velocity, info, off_beat, start_beat)
    end_note(voice, id)
    if S.lib.voice_mix.silenced(voice) then return end
    local names = {}
    for _, target in ipairs(ordered_targets()) do
      if routed(target, voice) and call_target(target, "note_on", voice, id, pitch, velocity, info) then
        names[#names + 1] = target.name
      end
    end
    if #names == 0 then return end
    local record = {pitch = pitch, targets = names, off_beat = off_beat}
    sounding[voice][id] = record
    if off_beat then offs[#offs + 1] = {voice = voice, id = id, beat = off_beat, start = start_beat, note = record} end
  end

  -- Whether some target is routed for voice and voice is not silenced
  local function available(voice)
    if not valid_voice(voice) or S.lib.voice_mix.silenced(voice) then return false end
    for _, target in ipairs(ordered_targets()) do
      if routed(target, voice) then return true end
    end
    return false
  end

  -- The step output: each pitch of the hit a note "s<k>", its off at the
  -- gate less TARGETS.step_gap_seconds (at most half the gate early)
  local function play_step(event)
    local voice = event.voice
    if not valid_voice(voice) then return end
    local gate = event.gate_beats
    local early = math.min(TARGETS.step_gap_seconds / clock.get_beat_sec(), gate / 2)
    for k, pitch in ipairs(event.pitches or {}) do
      start_note(voice, TARGETS.step_prefix .. k, pitch, event.velocity, {source = "step"},
        event.beat + gate - early, event.beat)
    end
  end

  local function stop_steps()
    clear_failures()
    for voice = 1, NUM_VOICES do end_voice(voice, TARGETS.step_prefix) end
  end

  local step_output = {name = "targets", play = play_step, stop = stop_steps, available = available}

  -- The played notes: MIDI's only (a sequencer note reaches the targets
  -- through the step output, with its gate)
  local function played_id(note) return TARGETS.played_prefix .. tostring(note.key) end

  local function played_started(voice, _, note)
    if note.owner ~= TARGETS.played_owner or not valid_voice(voice) then return end
    start_note(voice, played_id(note), note.pitch, note.velocity,
      {source = "midi", owner = note.owner, key = note.key})
  end

  S.register_note_hook({name = "targets",
    started = played_started,
    moved = played_started,  -- start_note ends the sounding id first
    ended = function(voice, _, note)
      if note.owner == TARGETS.played_owner and valid_voice(voice) then end_note(voice, played_id(note)) end
    end,
    expressed = function(voice, _, note)
      if note.owner ~= TARGETS.played_owner or not valid_voice(voice) then return end
      local id = played_id(note)
      local record = sounding[voice][id]
      if not record then return end
      for _, name in ipairs(record.targets) do
        local target = target_named(name)
        if target and target.express then call_target(target, "express", voice, id) end
      end
    end})

  -- The offs that are due, from the LFO clock's step: at their beat, or at
  -- once when the beat is now before the note's own start by more than
  -- TARGETS.jump_tolerance (a followed transport start, a reset or a new
  -- clock source put it back, not a tick's jitter, with no
  -- stop of the outputs: the off would wait until the beat climbed back)
  S.lib.lfos.on_step(function()
    if #offs == 0 then return end
    local now = clock.get_beats()
    local due = {}
    for _, off in ipairs(offs) do
      if off.beat <= now or off.start > now + TARGETS.jump_tolerance then due[#due + 1] = off end
    end
    for _, off in ipairs(due) do
      if sounding[off.voice][off.id] == off.note then end_note(off.voice, off.id) end
    end
  end)

  -- The stops
  function M.route_changed(voice)
    clear_failures()
    if valid_voice(voice) then end_voice(voice) end
  end

  function M.end_target(name)
    local target = target_named(name)
    for voice = 1, NUM_VOICES do
      for _, id in ipairs(sounding_ids(voice)) do
        local record = sounding[voice][id]
        for index = #record.targets, 1, -1 do
          if record.targets[index] == name then
            table.remove(record.targets, index)
            if target then call_target(target, "note_off", voice, id) end
          end
        end
        if #record.targets == 0 then
          sounding[voice][id] = nil
          drop_off(record)
        end
      end
    end
  end

  function M.stop_all()
    for voice = 1, NUM_VOICES do end_voice(voice) end
    for _, target in ipairs(ordered_targets()) do
      if target.stop_all then
        S.lib.ui_frame.contained_call(errors, target.name, "target " .. target.name, target.stop_all)
      end
    end
  end

  S.register_voice_stop(function(voice)
    if valid_voice(voice) then end_voice(voice) end
  end)

  S.register_silence_change(function(voice, silenced)
    if silenced and valid_voice(voice) then end_voice(voice) end
  end)

  -- A copy of voice's sounding notes: {[id] = {pitch, targets, off_beat}}
  function M.sounding(voice)
    local copy = {}
    if not valid_voice(voice) then return copy end
    for id, record in pairs(sounding[voice]) do
      local names = {}
      for index, name in ipairs(record.targets) do names[index] = name end
      copy[id] = {pitch = record.pitch, targets = names, off_beat = record.off_beat}
    end
    return copy
  end

  -- IO's voice section: the selected voice's rows from each target, in
  -- the targets' order, under their marks. One target's rows or status
  -- that raises is contained and left out; the others show
  local function target_part(target, field, voice)
    local result
    S.lib.ui_frame.contained_call(section_errors, target.name .. " " .. field,
      "target " .. target.name .. " " .. field, function() result = target[field](voice) end)
    return result
  end

  -- A failed target's rows are copies marked TARGETS.failed_mark (the
  -- target's own tables are never changed) while call_target skips it
  local function marked_failed(row)
    if type(row) ~= "table" then return row end
    local copy = {}
    for field, value in pairs(row) do copy[field] = value end
    copy.mark = TARGETS.failed_mark
    return copy
  end

  local function section_rows()
    local rows = {}
    for _, target in ipairs(ordered_targets()) do
      if target.rows then
        local given = target_part(target, "rows", S.selected_voice)
        local skipped = failed[target.name] == true
        for _, row in ipairs(type(given) == "table" and given or {}) do
          rows[#rows + 1] = skipped and marked_failed(row) or row
        end
      end
    end
    return rows
  end

  local function section_status()
    local marks = {}
    for _, target in ipairs(ordered_targets()) do
      if target.status then
        local mark = target_part(target, "status", S.selected_voice)
        if mark ~= nil then marks[#marks + 1] = tostring(mark) end
      end
    end
    return #marks > 0 and table.concat(marks, " ") or nil
  end

  -- The layout target both probe states register (once a script), after
  -- the real targets' rows: "a target's status" leaves the section at its
  -- top (the title with the probe's mark); "a target's rows" reaches the
  -- probe's row as a player does (S.lib.pages_io.go_to_row, by its id),
  -- which raises when it is not there
  local LAYOUT_TARGET = "layout probe"
  local function register_layout_target()
    if target_named(LAYOUT_TARGET) then return end
    S.register_note_target({name = LAYOUT_TARGET, routed = function() return false end,
      note_on = function() end, note_off = function() end,
      rows = function(voice)
        return {{label = "layout probe", kind = "action", hint = "probe", run = function() end, id = "probe",
          text = function() return "v" .. voice end},
          {kind = "status", text = "a target's rows"}}
      end,
      status = function() return "[!]" end})
  end

  local function layout_target_status()
    register_layout_target()
    S.lib.pages_io.show_section("voice")
  end

  local function layout_target_rows()
    register_layout_target()
    S.lib.pages_io.go_to_row("targets", "voice", {id = "probe"})
  end

  -- IO's mark for a cursor that moved by itself (#973): the cursor on voice
  -- 1's jf route, then ALT+E2 to voice 2, whose rows name voice 2's params,
  -- so the cursor falls to the row in its place and is marked
  local function layout_cursor_moved()
    S.lib.pages_io.go_to_row("targets", "voice", {param_id = "v1_out_jf"})
    key(1, 1); enc(2, 1); key(1, 0)
  end

  S.register_io_section({name = "voice",
    title = function() return "voice " .. tostring(S.selected_voice) end,
    rows = section_rows, status = section_status,
    layout_states = {{name = "a target's status", setup = layout_target_status},
      {name = "a target's rows", setup = layout_target_rows},
      {name = "a cursor that moved by itself", setup = layout_cursor_moved}}})

  -- The start step: the step output, after voices (registered as the
  -- sequencer loads); the cleanup step ends every note at once (the LFO
  -- clock has stopped: no off waits for a step)
  S.register_start(S.constants.START_ORDER.io_targets, function()
    for _, output in ipairs(S.registry.step_outputs) do
      if output == step_output then return end
    end
    S.register_step_output(step_output)
  end)

  S.register_cleanup(S.constants.CLEANUP_ORDER.io_targets, function() M.stop_all() end)

  S.register_invariant("targets", function()
    local seen = {}
    for voice = 1, NUM_VOICES do
      for id, record in pairs(sounding[voice]) do
        for _, name in ipairs(record.targets) do
          if not target_named(name) then return "voice " .. voice .. " " .. id .. " names no target " .. name end
        end
        if #record.targets == 0 then return "voice " .. voice .. " " .. id .. " sounds on no target" end
      end
    end
    for _, off in ipairs(offs) do
      local key = off.voice .. " " .. off.id
      if seen[key] then return "voice " .. key .. " is listed twice" end
      seen[key] = true
      if sounding[off.voice][off.id] ~= off.note then return "voice " .. key .. " has an off for no sounding note" end
    end
    return nil
  end)

  return M
end

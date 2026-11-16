-- lib/slices.lua
-- Slices (3.7, design §3.1-§3.6; decisions 1, 2, 5, 8, 11), S.lib.slices:
-- a slot's slices, an ascending list of at most SLICES.max markers (frames,
-- the first 0) kept in the file's settings (S.lib.samples: markers, frames,
-- rate, edited), made from equal parts or from the candidates of the
-- transients pass (engine.analyzeBuffer, the bufferOnsets poll, the slot's
-- buf<n>.onsets file in the settings folder, read by a clock, never in the
-- poll's callback) and edited by hand (add, delete, nudge). The voice
-- param v<i>_slices (off, one, overlap; a registered record whose sync
-- sends the own note's region) and the one way a slice plays: play, which
-- gives S.lib.notes a note with the slice's region. A bind or unbind of a
-- slot (S.lib.samples.on_bind) drops its candidates and, at the next LFO
-- step (a listener never sends), ends the regions of the voices that read
-- it and analyzes a transients slot whose take or overdub ended. Start step
-- slices_poll, cleanup step slices_poll. See docs/notes/lua/slices.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS

  -- The tunables (design §1): the most markers a slot holds, the shortest
  -- slice (s), the first slice's MIDI note, a grid bank's slices, the
  -- voice option's names and the onsets file's first line; the builder's:
  -- the option param's key and VOICE section, the options' and the file
  -- modes' indices (S.lib.samples' modes), the sensitivity's top, the
  -- file's length tolerance (s, as the peaks'), the poll's name and the
  -- rate used while a slot's is unknown
  local SLICES = {max = 64, min_seconds = 0.01, first_note = 36, bank_size = 16,
    options = {"off", "one", "overlap"}, magic = "strata-onsets 1",
    key = "slices", section = "synth", off = 1, one = 2, overlap = 3, equal = 2, transients = 3,
    sensitivity_max = 100, threshold_margin = 1e-9, length_tolerance = 0.01, poll = "bufferOnsets",
    default_rate = S.constants.NORNS_SAMPLE_RATE}
  M.SLICES = SLICES

  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end
  local function whole_in(value, low, high)
    return finite(value) and value % 1 == 0 and value >= low and value <= high
  end
  local function valid_slot(slot) return S.lib.buffers.valid_buffer_slot(slot) end
  local function valid_voice(voice) return whole_in(voice, 1, NUM_VOICES) end

  local function copy_list(list)
    if not list then return nil end
    local copy = {}
    for index, value in ipairs(list) do copy[index] = value end
    return copy
  end

  -- Per slot: the analyses sent (counted from 1, as the engine counts
  -- them), the one awaited (its number, nil when none), the slot's
  -- generation (raised at every bind and unbind) and the one an analysis
  -- was sent in, the candidates held, the reports waiting for the read
  -- clock, and the recordings sent at the slot's last bind
  local analyses, awaited, generations, analysis_generations = {}, {}, {}, {}
  local candidates, due_reads, records_seen = {}, {}, {}
  for slot = 1, NUM_BUFFERS do analyses[slot], generations[slot] = 0, 0 end
  local reader = {clock = nil, poll = nil}
  -- the binds the next LFO step acts on: per slot, true, and whether to analyze
  local due_binds = {}

  local function settings(slot)
    return valid_slot(slot) and S.lib.samples.settings(slot) or nil
  end

  -- The slot's frames and rate: its peaks file's (S.lib.waveforms), else
  -- the record's when they still give the slot's length; nil when unknown
  local function slot_frames(slot, record)
    local frames, rate = S.lib.waveforms.frames(slot), S.lib.waveforms.rate(slot)
    if frames and rate then return frames, rate end
    record = record or settings(slot)
    if record and record.frames and record.rate
        and math.abs(record.frames / record.rate - S.buffers[slot].seconds) <= SLICES.length_tolerance then
      return record.frames, record.rate
    end
    return nil
  end

  -- The markers that lie inside the slot's frames (a shorter slot drops
  -- the rest), and the frames; nil when the slot has none
  local function usable(slot)
    local record = settings(slot)
    if not record or not record.markers then return nil end
    local frames = slot_frames(slot, record)
    if not frames then return nil end
    local list = {}
    for _, frame in ipairs(record.markers) do
      if frame < frames then list[#list + 1] = frame end
    end
    return list, frames
  end

  -- How many slices the slot has (0: none)
  function M.count(slot)
    local list = usable(slot)
    return list and #list or 0
  end

  -- A copy of the slot's markers, or nil
  function M.markers(slot)
    local record = settings(slot)
    return record and copy_list(record.markers) or nil
  end

  -- Slice n's {start, length}, fractions of the slot's valid region, or nil
  function M.region(slot, n)
    local list, frames = usable(slot)
    if not list or not whole_in(n, 1, #list) then return nil end
    local start = list[n]
    local finish = list[n + 1] or frames
    return {start / frames, (finish - start) / frames}
  end

  -- Set the slot's markers: sorted, the 0 kept, none past the frames or
  -- within min_seconds of the one before, at most max; the frames and rate
  -- they were made on and the edited mark are kept with them. false when
  -- the slot has no settings or its frames are unknown
  function M.set_markers(slot, markers, edited)
    local record = settings(slot)
    if not record or type(markers) ~= "table" then return false end
    local frames, rate = slot_frames(slot, record)
    if not frames then return false end
    local sorted = {0}
    for _, frame in ipairs(markers) do
      if whole_in(frame, 1, frames - 1) then sorted[#sorted + 1] = frame end
    end
    table.sort(sorted)
    local gap = math.ceil(SLICES.min_seconds * (rate or SLICES.default_rate))
    local kept = {}
    for _, frame in ipairs(sorted) do
      if #kept == 0 or (frame - kept[#kept] >= gap and #kept < SLICES.max) then kept[#kept + 1] = frame end
    end
    S.lib.samples.set(slot, "markers", kept)
    S.lib.samples.set(slot, "frames", frames)
    S.lib.samples.set(slot, "rate", rate)
    S.lib.samples.set(slot, "edited", edited == true)
    grid_redraw()
    return true
  end

  -- An analysis of the slot: counted, then sent (its report names its number)
  function M.analyze(slot)
    if not valid_slot(slot) or S.buffers[slot].seconds <= 0 then return false end
    analyses[slot] = analyses[slot] + 1
    awaited[slot] = analyses[slot]
    analysis_generations[slot] = generations[slot]
    engine.analyzeBuffer(slot - 1)
    request_redraw()
    return true
  end

  function M.analyzing(slot) return valid_slot(slot) and awaited[slot] ~= nil end

  -- A copy of the candidates held for the slot ({frames, strengths}), or nil
  function M.candidates(slot)
    local held = valid_slot(slot) and candidates[slot]
    if not held then return nil end
    return {frames = copy_list(held.frames), strengths = copy_list(held.strengths)}
  end

  -- The candidates' markers at the slot's sensitivity: 0 and every
  -- candidate whose strength is at least 1 - sensitivity / 100 (within
  -- SLICES.threshold_margin: a strength printed at the threshold is taken,
  -- whatever the subtraction's rounding)
  local function transient_markers(slot, record)
    local held = candidates[slot]
    local threshold = 1 - record.sensitivity / SLICES.sensitivity_max - SLICES.threshold_margin
    local list = {0}
    for index, frame in ipairs(held.frames) do
      if held.strengths[index] >= threshold then list[#list + 1] = frame end
    end
    return list
  end

  -- Make the slot's slices from its settings' mode (clearing edited):
  -- equal, count parts; transients, the candidates held, or an analysis
  -- whose candidates make them when they arrive; off, none
  function M.make(slot)
    local record = settings(slot)
    if not record then return false end
    if record.mode == SLICES.equal then
      local frames = slot_frames(slot, record)
      if not frames then return false end
      local list = {}
      for k = 1, record.count do list[k] = math.floor((k - 1) * frames / record.count) end
      return M.set_markers(slot, list, false)
    elseif record.mode == SLICES.transients then
      if candidates[slot] then return M.set_markers(slot, transient_markers(slot, record), false) end
      S.lib.samples.set(slot, "edited", false)
      return M.analyze(slot)
    end
    S.lib.samples.set(slot, "markers", nil)
    S.lib.samples.set(slot, "edited", false)
    grid_redraw()
    return true
  end

  -- Hand edits (design §3.2): each through set_markers, marked edited
  -- An add: false at max markers, or where set_markers keeps none more
  -- (past the frames, too near another)
  function M.add_marker(slot, frame)
    local before = M.markers(slot) or {0}
    if #before >= SLICES.max or not whole_in(frame, 1, math.huge) then return false end
    local list = copy_list(before)
    list[#list + 1] = frame
    if not M.set_markers(slot, list, true) then return false end
    return #M.markers(slot) > #before
  end

  function M.delete_marker(slot, index)
    local list = M.markers(slot)
    if not list or not whole_in(index, 2, #list) then return false end
    table.remove(list, index)
    return M.set_markers(slot, list, true)
  end

  -- Move marker index (never the first) by frames, stopping min_seconds
  -- short of its neighbors (the next one, or the slot's end)
  function M.nudge_marker(slot, index, frames)
    local list = M.markers(slot)
    if not list or not whole_in(index, 2, #list) or not finite(frames) then return false end
    local total, rate = slot_frames(slot)
    if not total then return false end
    local gap = math.ceil(SLICES.min_seconds * (rate or SLICES.default_rate))
    local low = list[index - 1] + gap
    local high = (list[index + 1] or total) - gap
    if low > high then return false end
    list[index] = util.clamp(math.floor(list[index] + frames + 0.5), low, high)
    return M.set_markers(slot, list, true)
  end

  ---------------------------------------------------------------------------
  -- The onsets file and its poll
  ---------------------------------------------------------------------------

  local function onsets_path(slot) return S.lib.scenes.scene_data_dir .. "buf" .. slot .. ".onsets" end

  local function numbers(text)
    local list = {}
    for token in (text or ""):gmatch("%S+") do
      local value = tonumber(token)
      if not finite(value) then return nil end
      list[#list + 1] = value
    end
    return list
  end

  -- The candidates in an onsets file's text for slot, or nil and why
  local function parse(slot, text)
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    if lines[1] ~= SLICES.magic then return nil, "not an onsets file" end
    local fields = {}
    for index = 2, #lines do
      local key, rest = lines[index]:match("^(%a+)%s*(.*)$")
      if key then fields[key] = rest end
    end
    if tonumber(fields.slot) ~= slot then return nil, "another slot's" end
    local frames, rate = tonumber(fields.frames), tonumber(fields.rate)
    if not whole_in(frames, 1, math.huge) or not finite(rate) or rate <= 0
        or math.abs(frames / rate - S.buffers[slot].seconds) > SLICES.length_tolerance then
      return nil, "another length"
    end
    local onsets, strengths = numbers(fields.onsets), numbers(fields.strengths)
    if not onsets or not strengths or #onsets ~= #strengths then return nil, "its lists differ" end
    for index, frame in ipairs(onsets) do
      if not whole_in(frame, 0, frames - 1) or (index > 1 and frame <= onsets[index - 1]) then
        return nil, "a frame out of place"
      end
      if strengths[index] < 0 or strengths[index] > 1 then return nil, "a strength out of range" end
    end
    return {frames = onsets, strengths = strengths}
  end

  -- Read the slot's file for its count-th analysis: its candidates held
  -- when the file is for what the slot holds now (one console line when
  -- not), then a transients slot's markers made unless edited
  local function read_onsets(slot, count)
    if count ~= analyses[slot] or analysis_generations[slot] ~= generations[slot] then return end
    local file = io.open(onsets_path(slot), "r")
    local text = file and file:read("*a")
    if file then file:close() end
    local held, why = nil, "no file"
    if text then held, why = parse(slot, text) end
    if not held then
      print("strata: buf" .. slot .. ".onsets is not this slot's analysis (" .. tostring(why) .. "): ignored")
      return
    end
    candidates[slot] = held
    local record = settings(slot)
    if record and record.mode == SLICES.transients and not record.edited then
      M.set_markers(slot, transient_markers(slot, record), false)
    end
    request_redraw()
  end

  -- One clock reads the reports' files, from its first wake on (never in
  -- the poll's callback); it ends when none waits. Each read is contained,
  -- so one that raises prints once and never leaves the clock recorded
  local read_errors = {}
  local function start_reader()
    if reader.clock then return end
    reader.clock = clock.run(function()
      clock.sleep(0)
      while true do
        local slot = next(due_reads)
        if not slot then break end
        local count = due_reads[slot]
        due_reads[slot] = nil
        S.lib.ui_frame.contained_call(read_errors, slot, "onsets read", read_onsets, slot, count)
      end
      reader.clock = nil
    end)
  end

  -- bufferOnsets: ((count * 2) + failed) * NUM_BUFFERS + slot index. Only
  -- the newest analysis of a slot acts: its end stops the wait, and a
  -- written file is read by the clock
  local function onsets_reported(value)
    if not finite(value) or value < 0 then return end
    value = math.floor(value + 0.5)
    local slot = value % NUM_BUFFERS + 1
    local rest = math.floor(value / NUM_BUFFERS)
    local failed, count = rest % 2 == 1, math.floor(rest / 2)
    if count ~= awaited[slot] then return end
    awaited[slot] = nil
    request_redraw()
    if failed then return end
    due_reads[slot] = count
    start_reader()
  end

  S.register_start(S.constants.START_ORDER.slices_poll, function()
    reader.poll = poll.set(SLICES.poll, onsets_reported)
    if reader.poll then reader.poll:start() end
  end)

  S.register_cleanup(S.constants.CLEANUP_ORDER.slices_poll, function()
    if reader.poll then reader.poll:stop() end
    if reader.clock then
      clock.cancel(reader.clock)
      reader.clock = nil
    end
    due_reads = {}
  end)

  ---------------------------------------------------------------------------
  -- A slot's audio changed
  ---------------------------------------------------------------------------

  -- Every bind and unbind (a listener: it sends nothing): the candidates go
  -- (an awaited analysis is for the audio before), and the next LFO step
  -- ends the regions of the voices reading the slot and, when a take or an
  -- overdub ended (a recording since the slot's last bind) on a transients
  -- slot, analyzes it
  S.lib.samples.on_bind(function(slot)
    generations[slot] = generations[slot] + 1
    candidates[slot] = nil
    awaited[slot] = nil
    local recorded = S.buffers[slot].records_sent or 0
    local took = recorded ~= (records_seen[slot] or 0) and S.buffers[slot].path == scratch_take_path(slot)
    records_seen[slot] = recorded
    local record = settings(slot)
    due_binds[slot] = {analyze = took and record ~= nil and record.mode == SLICES.transients}
  end)

  S.lib.lfos.on_step(function()
    if next(due_binds) == nil then return end
    local binds = due_binds
    due_binds = {}
    for slot = 1, NUM_BUFFERS do
      if binds[slot] then
        for voice = 1, NUM_VOICES do
          if voice_buffer_slot(voice) == slot then S.lib.notes.end_regions(voice) end
        end
        if binds[slot].analyze then M.analyze(slot) end
      end
    end
  end)

  ---------------------------------------------------------------------------
  -- Playing them (design §3.5)
  ---------------------------------------------------------------------------

  local function option(voice) return S.voices[voice].extras[SLICES.key] or SLICES.off end

  -- The voice's option's name: "off", "one" or "overlap"
  function M.option(voice)
    if not valid_voice(voice) then return nil end
    return SLICES.options[option(voice)]
  end

  -- Slice n of the slot the voice reads, or nil (no buffer, no such slice)
  function M.voice_region(voice, n)
    if not valid_voice(voice) or not voice_uses_buffer(voice) then return nil end
    return M.region(voice_buffer_slot(voice), n)
  end

  -- Whether MIDI notes and a grid's row play the voice's slices
  function M.takes_notes(voice)
    return valid_voice(voice) and voice_uses_buffer(voice) and option(voice) ~= SLICES.off
      and M.count(voice_buffer_slot(voice)) > 0
  end

  local function play_nothing() end

  -- Play slice n of the voice's slot as note (S.lib.notes.play's owner,
  -- key, velocity, and park, quiet, extra_only, expression and steals when
  -- given) at the voice's own pitch, with the slice's region; in one shot
  -- with a moving scan it plays to its end (to_end, hold_to_end). With the
  -- option one, or off (a step's), it is the own note. The slot it took;
  -- false for a slice that does not exist (and nothing is sent)
  function M.play(voice, n, note)
    local region = M.voice_region(voice, n)
    if not region or type(note) ~= "table" then return false end
    local to_end = S.lib.notes.pass_seconds(voice, region[2])
    local slot = S.lib.notes.play(voice, {owner = note.owner, key = note.key, pitch = S.lib.notes.own_pitch(voice),
      velocity = note.velocity, set_own = play_nothing, park = note.park, quiet = note.quiet,
      extra_only = note.extra_only, expression = note.expression, steals = note.steals, region = region,
      to_end = to_end, hold_to_end = to_end ~= nil or nil, own_only = option(voice) ~= SLICES.overlap or nil})
    return slot or false
  end

  -- A slice note's key let go: released, unless it plays to its end
  function M.note_off(voice, owner, key)
    return S.lib.notes.release(voice, owner, key)
  end

  -- The slice numbers the voice's notes hold now, ascending: its held
  -- extra notes' regions and, while slot 1's note is held (not parked, not
  -- played out), the own region
  function M.playing(voice)
    local list = {}
    if not valid_voice(voice) or not voice_uses_buffer(voice) then return list end
    local slot = voice_buffer_slot(voice)
    local starts = {}
    for n = 1, M.count(slot) do starts[M.region(slot, n)[1]] = n end
    local seen = {}
    local function add(region)
      local n = region and starts[region[1]]
      if n and not seen[n] then
        seen[n] = true
        list[#list + 1] = n
      end
    end
    for _, used in ipairs(S.lib.notes.slots(voice)) do
      if used.held then add(used.slot > 1 and used.region or S.lib.notes.own_region(voice)) end
    end
    table.sort(list)
    return list
  end

  ---------------------------------------------------------------------------
  -- The option (a registered voice param)
  ---------------------------------------------------------------------------

  local function param_id(voice) return "v" .. voice .. "_" .. SLICES.key end

  -- VOICE's layout tests and page renders: voices 1 and 7 on buffer 1, the
  -- cursor on the row
  local layout_states = {}
  for _, voice in ipairs({1, NUM_VOICES}) do
    table.insert(layout_states, {
      name = string.format("v%d buffer slices", voice),
      setup = function()
        S.selected_voice = voice
        params:set("v" .. voice .. "_source", S.constants.SOURCE_SYNTH + 1)
        params:set(param_id(voice), SLICES.overlap)
        S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(param_id(voice)))
      end,
    })
  end

  local record
  record = {
    name = "slices",
    count = 1,
    add = function(voice)
      S.lib.params_setup.add_voice_extra(voice, record, SLICES.key, {
        type = "option", name = "slices", options = SLICES.options, default = SLICES.off,
        -- the own note's slice ends with the option it was played under
        action = function() S.lib.notes.set_own_region(voice, nil) end,
      })
    end,
    -- every voice sync sends the own region as it is (a clear for none),
    -- before voiceOn at a start, so a step's first slice plays
    sync = function(voice)
      local region = S.lib.notes.own_region(voice) or {0, 0}
      engine.setGrainParam(voice - 1, "regionStart", region[1])
      engine.setGrainParam(voice - 1, "regionLength", region[2])
    end,
    scene_defaults = {[SLICES.key] = SLICES.off},
    discrete = {[SLICES.key] = {1, #SLICES.options}},
    voice_rows = {section = SLICES.section, rows = {SLICES.key}, when = function(voice) return voice_uses_buffer(voice) end},
    layout_states = layout_states,
    fader = false,
  }
  S.register_voice_params(record)

  return M
end
